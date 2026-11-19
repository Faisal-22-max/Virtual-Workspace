-- Run with ON_ERROR_STOP=1 only after resetting the disposable local database
-- through 20261118000200. Then apply the remaining Deployable migrations and run
-- workspace_profile_access_test.sql (assertions 28 and 29).
begin;

do $$
begin
  if not exists (
    select 1 from supabase_migrations.schema_migrations where version = '20261118000000'
  ) or not exists (
    select 1 from supabase_migrations.schema_migrations where version = '20261118000200'
  ) or exists (
    select 1 from supabase_migrations.schema_migrations where version >= '20261119000100'
  ) then
    raise exception 'This fixture requires the local-only baseline and pre-hardening migration ledger';
  end if;
end;
$$;

-- Simulate the elevated direct grants observed in Production, retaining the
-- baseline's ordinary CRUD permissions for the rest of the local tests.
grant truncate, trigger, references, maintain
on table public.users, public.workspaces, public.workspace_members,
  public.invitations, public.messages
to anon, authenticated;

do $$
declare
  missing_grants text[];
begin
  select array_agg(format('%s %s on %s', client.role_name, grant_type.privilege, target.table_name))
  into missing_grants
  from (values ('anon'), ('authenticated')) as client(role_name)
  cross join (values ('public.users'), ('public.workspaces'), ('public.workspace_members'),
    ('public.invitations'), ('public.messages')) as target(table_name)
  cross join (values ('TRUNCATE'), ('TRIGGER'), ('REFERENCES'), ('MAINTAIN')) as grant_type(privilege)
  where not has_table_privilege(client.role_name, target.table_name, grant_type.privilege);

  if missing_grants is not null then
    raise exception 'Missing pre-hardening grants: %', missing_grants;
  end if;
  raise notice 'PASS pre-hardening: both client roles have all four elevated grants on all five tables';
end;
$$;

commit;
