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
  fixture record;
  profile_id uuid;
  test_case record;
  visible_profiles uuid[];
  client record;
  truncate_tables text[];
begin
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

  insert into public.workspaces (id, name, slug) values
    (first_workspace, 'Profile Access Test A', 'profile-access-test-a'),
    (second_workspace, 'Profile Access Test B', 'profile-access-test-b');

  for fixture in
    select * from (values
      (alice, first_workspace, 'admin', 'active'),
      (bob, first_workspace, 'employee', 'active'),
      (dan, first_workspace, 'employee', 'removed'),
      (carol, second_workspace, 'admin', 'active'),
      (alice, second_workspace, 'employee', 'removed')
    ) as expected(auth_id, workspace_id, member_role, member_status)
  loop
    select id into strict profile_id from public.users where auth_id = fixture.auth_id;
    insert into public.workspace_members (user_id, workspace_id, role, status)
    values (profile_id, fixture.workspace_id, fixture.member_role, fixture.member_status);

    if not exists (
      select 1 from public.workspace_members as membership
      where membership.user_id = profile_id
        and membership.workspace_id = fixture.workspace_id
        and membership.role = fixture.member_role
        and membership.status = fixture.member_status
    ) then
      raise exception 'Missing membership fixture for profile % in workspace % (expected % / %)',
        profile_id, fixture.workspace_id, fixture.member_role, fixture.member_status;
    end if;
  end loop;

  set local role authenticated;

  for test_case in
    select *
    from (values
      (27, 'Active coworker, removed coworker and removed caller membership', alice, array[alice, bob]),
      (32, 'Workspace A employee sees only self and active coworker', bob, array[alice, bob]),
      (27, 'Workspace B admin cannot see Workspace A profiles', carol, array[carol]),
      (25, 'Self-profile with only removed membership', dan, array[dan])
    ) as expected(test_number, description, viewer, profiles)
  loop
    perform set_config('request.jwt.claim.sub', test_case.viewer::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object(
      'sub', test_case.viewer, 'role', 'authenticated'
    )::text, true);

    select array_agg(auth_id order by auth_id) into visible_profiles
    from public.users
    where auth_id in (alice, bob, carol, dan);

    if visible_profiles is distinct from test_case.profiles then
      raise exception 'FAIL %: % (expected %, got %)',
        test_case.test_number, test_case.description, test_case.profiles, visible_profiles;
    end if;
    raise notice 'PASS %: %', test_case.test_number, test_case.description;
  end loop;

  reset role;
  raise notice 'PASS 26: Authenticated profile queries completed without policy recursion';

  for client in
    select * from (values (28, 'anon'), (29, 'authenticated')) as roles(test_number, role_name)
  loop
    select array_agg(target.table_name order by target.table_name) into truncate_tables
    from (values ('public.users'), ('public.workspaces'), ('public.workspace_members'),
      ('public.invitations'), ('public.messages')) as target(table_name)
    where has_table_privilege(client.role_name, target.table_name, 'TRUNCATE');

    if truncate_tables is not null then
      raise exception 'FAIL %: % has TRUNCATE on %',
        client.test_number, client.role_name, truncate_tables;
    end if;
    raise notice 'PASS %: % has no TRUNCATE on the five application tables',
      client.test_number, client.role_name;
  end loop;
end;
$$;

rollback;
