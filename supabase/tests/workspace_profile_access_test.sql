-- Run in a disposable local development database after applying the migration.
-- Requires a session that can seed fixtures and SET ROLE authenticated.
begin;

do $$
declare
  alice constant uuid := '00000000-0000-0000-0000-000000018001';
  bob constant uuid := '00000000-0000-0000-0000-000000018002';
  carol constant uuid := '00000000-0000-0000-0000-000000018003';
  dan constant uuid := '00000000-0000-0000-0000-000000018004';
  first_workspace constant uuid := '00000000-0000-0000-0000-000000018010';
  second_workspace constant uuid := '00000000-0000-0000-0000-000000018020';
  test_case record;
  visible_profiles uuid[];
begin
  if exists (
    select 1
    from (values ('anon'), ('authenticated')) as client(role_name)
    cross join (values ('public.workspaces'), ('public.workspace_members')) as target(table_name)
    where has_table_privilege(client.role_name, target.table_name, 'TRUNCATE')
  ) then
    raise exception 'A client role still has TRUNCATE on a workspace table';
  end if;

  insert into auth.users (id, email) values
    (alice, 'workspace-profile-test-alice@example.com'),
    (bob, 'workspace-profile-test-bob@example.com'),
    (carol, 'workspace-profile-test-carol@example.com'),
    (dan, 'workspace-profile-test-dan@example.com');

  insert into public.users (auth_id, email)
  select id, email
  from auth.users
  where id in (alice, bob, carol, dan)
  on conflict (auth_id) do nothing;

  if (select count(*) from public.users where auth_id in (alice, bob, carol, dan)) <> 4 then
    raise exception 'Expected all four test profiles to exist';
  end if;

  insert into public.workspaces (id, name, slug) values
    (first_workspace, 'Profile Access Test A', 'profile-access-test-a'),
    (second_workspace, 'Profile Access Test B', 'profile-access-test-b');

  insert into public.workspace_members (user_id, workspace_id, role, status)
  select profile.id, fixture.workspace_id, fixture.member_role, fixture.member_status
  from (
    values
      (alice, first_workspace, 'admin', 'active'),
      (bob, first_workspace, 'employee', 'active'),
      (dan, first_workspace, 'employee', 'removed'),
      (carol, second_workspace, 'admin', 'active'),
      (alice, second_workspace, 'employee', 'removed')
  ) as fixture(auth_id, workspace_id, member_role, member_status)
  join public.users as profile on profile.auth_id = fixture.auth_id;

  set local role authenticated;

  for test_case in
    select *
    from (values
      ('active coworker, removed coworker and removed caller membership', alice, array[alice, bob]),
      ('active employee can read self and an active coworker', bob, array[alice, bob]),
      ('cross-workspace profiles and removed coworker', carol, array[carol]),
      ('self-profile with only removed membership', dan, array[dan])
    ) as expected(description, viewer, profiles)
  loop
    perform set_config('request.jwt.claim.sub', test_case.viewer::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object(
      'sub', test_case.viewer, 'role', 'authenticated'
    )::text, true);

    select array_agg(auth_id order by auth_id) into visible_profiles
    from public.users
    where auth_id in (alice, bob, carol, dan);

    if visible_profiles is distinct from test_case.profiles then
      raise exception 'Profile access test failed (%): expected %, got %',
        test_case.description, test_case.profiles, visible_profiles;
    end if;
  end loop;

  reset role;
end;
$$;

rollback;
