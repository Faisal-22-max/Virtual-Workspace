-- Run in a disposable local database with psql -v ON_ERROR_STOP=1.
begin;

create function pg_temp.expect_test(test_number integer, description text, actual boolean)
returns void
language plpgsql
as $$
begin
  if actual is distinct from true then
    raise exception 'FAIL %: % (expected true, got %)', test_number, description, actual;
  end if;
  raise notice 'PASS %: %', test_number, description;
end;
$$;

create function pg_temp.set_test_user(auth_user uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claim.sub', auth_user::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', auth_user, 'role', 'authenticated'
  )::text, true);
end;
$$;

do $$
declare
  workspace_a constant uuid := '00000000-0000-0000-0000-00000000aaaa';
  workspace_b constant uuid := '00000000-0000-0000-0000-00000000bbbb';
  admin_a constant uuid := '00000000-0000-0000-0000-0000000000a1';
  employee_a constant uuid := '00000000-0000-0000-0000-0000000000a2';
  removed_admin constant uuid := '00000000-0000-0000-0000-0000000000a3';
  admin_b constant uuid := '00000000-0000-0000-0000-0000000000b1';
  employee_b constant uuid := '00000000-0000-0000-0000-0000000000b2';
  outsider constant uuid := '00000000-0000-0000-0000-0000000000c1';
  test_message constant text := 'Membership test employee message';
  admin_a_profile uuid;
  employee_a_profile uuid;
  removed_admin_profile uuid;
  admin_b_profile uuid;
  employee_b_profile uuid;
  outsider_profile uuid;
  fixture record;
  candidate_status text;
  invitation_a uuid;
  affected bigint;
  removed_admin_change record;
  error_message text;
begin
  insert into auth.users (id, email) values
    (admin_a, 'membership-admin-a@example.com'),
    (employee_a, 'membership-employee-a@example.com'),
    (removed_admin, 'membership-removed-admin@example.com'),
    (admin_b, 'membership-admin-b@example.com'),
    (employee_b, 'membership-employee-b@example.com'),
    (outsider, 'membership-outsider@example.com');

  select id into strict admin_a_profile from public.users where auth_id = admin_a;
  select id into strict employee_a_profile from public.users where auth_id = employee_a;
  select id into strict removed_admin_profile from public.users where auth_id = removed_admin;
  select id into strict admin_b_profile from public.users where auth_id = admin_b;
  select id into strict employee_b_profile from public.users where auth_id = employee_b;
  select id into strict outsider_profile from public.users where auth_id = outsider;

  insert into public.workspaces (id, name, slug) values
    (workspace_a, 'Membership Test A', 'membership-test-a'),
    (workspace_b, 'Membership Test B', 'membership-test-b');

  for fixture in
    select * from (values
      (admin_a_profile, workspace_a, 'admin', 'active'),
      (employee_a_profile, workspace_a, 'employee', 'active'),
      (removed_admin_profile, workspace_a, 'admin', 'removed'),
      (admin_b_profile, workspace_b, 'admin', 'active'),
      (employee_b_profile, workspace_b, 'employee', 'active')
    ) as expected(profile_id, workspace_id, member_role, member_status)
  loop
    insert into public.workspace_members (user_id, workspace_id, role, status)
    values (fixture.profile_id, fixture.workspace_id, fixture.member_role, fixture.member_status);

    if not exists (
      select 1 from public.workspace_members as membership
      where membership.user_id = fixture.profile_id
        and membership.workspace_id = fixture.workspace_id
        and membership.role = fixture.member_role
        and membership.status = fixture.member_status
    ) then
      raise exception 'Missing membership fixture for profile % in workspace % (expected % / %)',
        fixture.profile_id, fixture.workspace_id, fixture.member_role, fixture.member_status;
    end if;
  end loop;

  insert into public.messages (workspace_id, sender_id, content) values
    (workspace_a, admin_a, 'Membership test message A'),
    (workspace_b, admin_b, 'Membership test message B');
  if not exists (
    select 1 from public.messages where workspace_id = workspace_b and sender_id = admin_b
  ) then
    raise exception 'Missing message fixture in Workspace B';
  end if;

  set local role authenticated;

  perform pg_temp.set_test_user(employee_a);
  perform pg_temp.expect_test(1, 'Active member', public.is_workspace_member(workspace_a));
  perform pg_temp.set_test_user(removed_admin);
  perform pg_temp.expect_test(2, 'Removed member', public.is_workspace_member(workspace_a) = false);
  perform pg_temp.set_test_user(employee_b);
  perform pg_temp.expect_test(3, 'Member of another workspace', public.is_workspace_member(workspace_a) = false);
  perform pg_temp.set_test_user(outsider);
  perform pg_temp.expect_test(4, 'User with no memberships', public.is_workspace_member(workspace_a) = false);

  perform pg_temp.set_test_user(admin_a);
  perform pg_temp.expect_test(5, 'Active admin', public.is_workspace_admin(workspace_a));
  perform pg_temp.set_test_user(employee_a);
  perform pg_temp.expect_test(6, 'Active employee is not an admin', public.is_workspace_admin(workspace_a) = false);
  perform pg_temp.set_test_user(removed_admin);
  perform pg_temp.expect_test(7, 'Removed admin', public.is_workspace_admin(workspace_a) = false);
  perform pg_temp.set_test_user(admin_b);
  perform pg_temp.expect_test(8, 'Admin of another workspace', public.is_workspace_admin(workspace_a) = false);

  perform pg_temp.set_test_user(employee_a);
  perform pg_temp.expect_test(9, 'Employee can read own workspace coworkers', exists (
    select 1 from public.workspace_members where workspace_id = workspace_a and user_id = admin_a_profile
  ));
  perform pg_temp.set_test_user(employee_b);
  perform pg_temp.expect_test(10, 'Employee cannot read another workspace membership', not exists (
    select 1 from public.workspace_members where workspace_id = workspace_a
  ));

  perform pg_temp.set_test_user(employee_a);
  foreach candidate_status in array array['active', 'removed']
  loop
    begin
      insert into public.workspace_members (workspace_id, user_id, role, status)
      values (workspace_a, outsider_profile, 'employee', candidate_status);
      perform pg_temp.expect_test(11, format('Employee cannot insert a membership with status %s', candidate_status), false);
    exception when insufficient_privilege then
      get stacked diagnostics error_message = message_text;
      if error_message not like 'new row violates row-level security policy% for table "workspace_members"' then
        raise;
      end if;
      perform pg_temp.expect_test(11, format('RLS blocks employee inserting a membership with status %s', candidate_status), true);
    end;
  end loop;

  perform pg_temp.set_test_user(admin_a);
  insert into public.workspace_members (workspace_id, user_id, role, status)
  values (workspace_a, outsider_profile, 'employee', 'removed');
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(12, 'Admin can insert a membership', affected = 1);

  perform pg_temp.set_test_user(employee_a);
  update public.workspace_members set status = 'active'
  where workspace_id = workspace_a and user_id = outsider_profile;
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(13, 'Employee cannot update a membership', affected = 0);

  perform pg_temp.set_test_user(admin_a);
  update public.workspace_members set status = 'active'
  where workspace_id = workspace_a and user_id = outsider_profile and status = 'removed';
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(14, 'Admin can update a membership', affected = 1);

  perform pg_temp.set_test_user(employee_a);
  delete from public.workspace_members where workspace_id = workspace_a and user_id = outsider_profile;
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(15, 'Employee cannot delete a membership', affected = 0);

  perform pg_temp.set_test_user(admin_a);
  delete from public.workspace_members where workspace_id = workspace_a
    and user_id = outsider_profile and role = 'employee' and status = 'active';
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(16, 'Admin can delete an employee membership', affected = 1);

  for removed_admin_change in
    select * from (values
      (17, 'Trigger blocks deleting the last active admin',
        'delete from public.workspace_members where workspace_id = $1 and user_id = $2'),
      (18, 'Trigger blocks demoting the last active admin',
        'update public.workspace_members set role = ''employee'' where workspace_id = $1 and user_id = $2'),
      (19, 'Trigger blocks deactivating the last active admin',
        'update public.workspace_members set status = ''removed'' where workspace_id = $1 and user_id = $2')
    ) as changes(test_number, description, statement)
  loop
    begin
      execute removed_admin_change.statement using workspace_a, admin_a_profile;
      perform pg_temp.expect_test(removed_admin_change.test_number, removed_admin_change.description, false);
    exception when check_violation then
      get stacked diagnostics error_message = message_text;
      if error_message <> 'Cannot remove or demote the last active workspace admin' then
        raise;
      end if;
      perform pg_temp.expect_test(removed_admin_change.test_number, removed_admin_change.description, true);
    end;
  end loop;

  insert into public.workspace_members (workspace_id, user_id, role)
  values (workspace_a, outsider_profile, 'admin');
  delete from public.workspace_members where workspace_id = workspace_a and user_id = outsider_profile;
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(20, 'Another active admin permits deletion',
    affected = 1 and public.is_workspace_admin(workspace_a));

  insert into public.workspace_members (workspace_id, user_id, role)
  values (workspace_a, outsider_profile, 'admin');
  update public.workspace_members set role = 'employee'
  where workspace_id = workspace_a and user_id = outsider_profile and role = 'admin' and status = 'active';
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(21, 'Another active admin permits demotion',
    affected = 1 and public.is_workspace_admin(workspace_a) and exists (
      select 1 from public.workspace_members
      where workspace_id = workspace_a and user_id = outsider_profile and role = 'employee' and status = 'active'
    ));

  update public.workspace_members set role = 'admin'
  where workspace_id = workspace_a and user_id = outsider_profile;
  update public.workspace_members set status = 'removed'
  where workspace_id = workspace_a and user_id = outsider_profile and role = 'admin' and status = 'active';
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(22, 'Another active admin permits deactivation',
    affected = 1 and public.is_workspace_admin(workspace_a) and exists (
      select 1 from public.workspace_members
      where workspace_id = workspace_a and user_id = outsider_profile and role = 'admin' and status = 'removed'
    ));

  perform pg_temp.set_test_user(employee_a);
  delete from public.workspace_members where workspace_id = workspace_a and user_id = admin_a_profile;
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(23, 'RLS blocks employee deleting an admin', affected = 0);
  update public.workspace_members set role = 'employee' where workspace_id = workspace_a and user_id = admin_a_profile;
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(24, 'RLS blocks employee demoting an admin', affected = 0);

  perform pg_temp.expect_test(30, 'Workspace A employee cannot read Workspace B memberships', not exists (
    select 1 from public.workspace_members where workspace_id = workspace_b
  ));

  perform pg_temp.set_test_user(admin_a);
  update public.workspace_members set status = 'removed'
  where workspace_id = workspace_b and user_id = employee_b_profile;
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(31, 'Workspace A admin cannot modify Workspace B memberships', affected = 0);
  perform pg_temp.expect_test(33, 'Workspace A admin has no admin or member access in Workspace B',
    public.is_workspace_admin(workspace_b) = false and public.is_workspace_member(workspace_b) = false);

  begin
    insert into public.invitations (workspace_id, email, invited_by)
    values (workspace_b, 'membership-invite@example.com', admin_a_profile);
    perform pg_temp.expect_test(34, 'Admin cannot invite into another workspace', false);
  exception when insufficient_privilege then
    get stacked diagnostics error_message = message_text;
    if error_message not like 'new row violates row-level security policy% for table "invitations"' then
      raise;
    end if;
    perform pg_temp.expect_test(34, 'Admin cannot invite into another workspace', true);
  end;

  insert into public.invitations (workspace_id, email, invited_by)
  values (workspace_a, 'membership-invite@example.com', admin_a_profile)
  returning id into invitation_a;
  perform pg_temp.expect_test(35, 'Admin can invite into own workspace', invitation_a is not null);

  perform pg_temp.set_test_user(admin_b);
  update public.invitations set status = 'expired' where id = invitation_a;
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(36, 'Other workspace admin cannot update an invitation', affected = 0);
  delete from public.invitations where id = invitation_a;
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(36, 'Other workspace admin cannot delete an invitation', affected = 0);

  perform pg_temp.set_test_user(admin_a);
  update public.invitations set status = 'expired' where id = invitation_a and status = 'pending';
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(36, 'Admin can update an invitation in their own workspace', affected = 1);
  delete from public.invitations where id = invitation_a and status = 'expired';
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(36, 'Admin can delete an invitation in their own workspace', affected = 1);

  perform pg_temp.set_test_user(employee_a);
  perform pg_temp.expect_test(37, 'Employee can read own workspace messages', exists (
    select 1 from public.messages where workspace_id = workspace_a and sender_id = admin_a
  ));
  perform pg_temp.expect_test(38, 'Employee cannot read another workspace messages', not exists (
    select 1 from public.messages where workspace_id = workspace_b
  ));

  insert into public.messages (workspace_id, sender_id, content)
  values (workspace_a, employee_a, test_message);
  get diagnostics affected = row_count;
  perform pg_temp.expect_test(39, 'Employee can send into their own workspace with RLS active',
    affected = 1 and row_security_active('public.messages'::regclass));

  begin
    insert into public.messages (workspace_id, sender_id, content)
    values (workspace_b, employee_a, test_message);
    perform pg_temp.expect_test(39, 'Employee cannot send into another workspace', false);
  exception when insufficient_privilege then
    get stacked diagnostics error_message = message_text;
    if error_message not like 'new row violates row-level security policy% for table "messages"' then
      raise;
    end if;
  end;

  -- Check stored rows as the fixture owner so SELECT RLS cannot hide an insert.
  reset role;
  perform pg_temp.expect_test(39, 'Own message exists and cross-workspace message was not inserted',
    not row_security_active('public.messages'::regclass) and exists (
      select 1 from public.messages
      where workspace_id = workspace_a and sender_id = employee_a and content = test_message
    ) and not exists (
      select 1 from public.messages
      where workspace_id = workspace_b and sender_id = employee_a and content = test_message
    ));
end;
$$;

rollback;
