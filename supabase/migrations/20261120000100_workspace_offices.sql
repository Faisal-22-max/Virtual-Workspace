begin;

create table public.offices (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null unique references public.workspaces(id) on delete cascade,
  map_config jsonb not null default '{}'::jsonb,
  map_version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint offices_map_config_object check (jsonb_typeof(map_config) = 'object'),
  constraint offices_map_config_size check (octet_length(map_config::text) <= 65536),
  constraint offices_map_version_positive check (map_version > 0)
);

alter table public.offices enable row level security;
revoke all on table public.offices from public, anon, authenticated, service_role;
grant select, update (map_config) on table public.offices to authenticated;

create policy offices_member_read on public.offices
  for select to authenticated using (public.is_workspace_member(workspace_id));
create policy offices_admin_update on public.offices
  for update to authenticated using (public.is_workspace_admin(workspace_id))
  with check (public.is_workspace_admin(workspace_id));

create function public.create_workspace_office()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.offices (workspace_id) values (new.id);
  return new;
end;
$$;
revoke execute on function public.create_workspace_office() from public, anon, authenticated, service_role;

-- Installing the trigger takes a write-conflicting lock. Backfill afterwards
-- so workspace creation cannot slip between the backfill and trigger install.
create trigger create_workspace_office
  after insert on public.workspaces
  for each row execute function public.create_workspace_office();

insert into public.offices (workspace_id) select id from public.workspaces;

create function public.version_office_layout()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if new.map_config is distinct from old.map_config then
    new.map_version := old.map_version + 1;
    new.updated_at := clock_timestamp();
  end if;
  return new;
end;
$$;
revoke execute on function public.version_office_layout() from public, anon, authenticated, service_role;

create trigger version_office_layout
  before update of map_config on public.offices
  for each row execute function public.version_office_layout();

commit;
