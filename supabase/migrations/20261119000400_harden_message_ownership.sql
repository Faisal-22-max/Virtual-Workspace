begin;

alter table public.messages alter column sender_id set default auth.uid();

alter policy "members send messages" on public.messages with check (
  public.is_workspace_member(workspace_id) and sender_id = auth.uid()
);
alter policy "sender edits own" on public.messages
using (public.is_workspace_member(workspace_id) and sender_id = auth.uid())
with check (public.is_workspace_member(workspace_id) and sender_id = auth.uid());
alter policy "sender deletes own" on public.messages
using (public.is_workspace_member(workspace_id) and sender_id = auth.uid());

create function public.keep_message_workspace() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if new.workspace_id is distinct from old.workspace_id then
    raise exception 'Message workspace cannot change' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke execute on function public.keep_message_workspace() from public, anon, authenticated, service_role;
create trigger keep_message_workspace before update of workspace_id on public.messages
for each row execute function public.keep_message_workspace();

-- A deleted row is unavailable to Realtime's per-subscriber SELECT check.
-- Publication event selection applies to every table in the publication.
do $$
begin
  if not exists (
    select from pg_publication where pubname = 'supabase_realtime' and not puballtables
  ) or exists (
    select from pg_publication_namespace n join pg_publication p on p.oid = n.pnpubid
    where p.pubname = 'supabase_realtime'
  ) or (select count(*) from pg_publication_tables where pubname = 'supabase_realtime') <> 1
    or not exists (
      select from pg_publication_tables where pubname = 'supabase_realtime'
        and schemaname = 'public' and tablename = 'messages'
    ) then
    raise exception 'Review shared publication before changing message event delivery';
  end if;
end;
$$;
alter publication supabase_realtime set (publish = 'insert, update');

commit;
