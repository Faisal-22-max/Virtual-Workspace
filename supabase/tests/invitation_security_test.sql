-- Run in a disposable local database as the fixture owner with ON_ERROR_STOP=1.
begin;

create function pg_temp.expect_invitation(test_name text, actual boolean)
returns void
language plpgsql
as $$
begin
  if actual is distinct from true then
    raise exception 'FAIL %', test_name;
  end if;
  raise notice 'PASS %', test_name;
end;
$$;

create function pg_temp.invitation_actor(actor uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(actor::text, ''), true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', actor, 'role', current_user
  )::text, true);
end;
$$;

do $$
declare
  workspace_a constant uuid := '00000000-0000-0000-0000-000000051001';
  workspace_b constant uuid := '00000000-0000-0000-0000-000000051002';
  admin_a constant uuid := '00000000-0000-0000-0000-000000051011';
  employee_a constant uuid := '00000000-0000-0000-0000-000000051012';
  admin_b constant uuid := '00000000-0000-0000-0000-000000051013';
  invitee_a constant uuid := '00000000-0000-0000-0000-000000051014';
  wrong_user constant uuid := '00000000-0000-0000-0000-000000051015';
  existing_member constant uuid := '00000000-0000-0000-0000-000000051016';
  removed_member constant uuid := '00000000-0000-0000-0000-000000051017';
  unverified_user constant uuid := '00000000-0000-0000-0000-000000051018';
  invitee_email constant text := 'invitation-invitee@example.com';
  fixture record;
  profile_id uuid;
  admin_a_profile uuid;
  admin_b_profile uuid;
  invitee_profile uuid;
  existing_profile uuid;
  removed_profile uuid;
  invitation_a public.invitations%rowtype;
  invitation_b public.invitations%rowtype;
  deletable_a uuid;
  revoked_invitation public.invitations%rowtype;
  expired_invitation public.invitations%rowtype;
  existing_invitation public.invitations%rowtype;
  removed_invitation public.invitations%rowtype;
  unverified_invitation public.invitations%rowtype;
  updated_expiry timestamptz;
  affected bigint;
  error_text text;
  violated_constraint text;
begin
  insert into public.workspaces (id, name, slug) values
    (workspace_a, 'Invitation Test A', 'invitation-test-a'),
    (workspace_b, 'Invitation Test B', 'invitation-test-b');

  for fixture in select * from (values
    (admin_a, 'invitation-admin-a@example.com', workspace_a, 'admin', 'active'),
    (employee_a, 'invitation-employee-a@example.com', workspace_a, 'employee', 'active'),
    (admin_b, 'invitation-admin-b@example.com', workspace_b, 'admin', 'active'),
    (invitee_a, invitee_email, null, null, null),
    (wrong_user, 'invitation-wrong-user@example.com', null, null, null),
    (existing_member, 'invitation-existing@example.com', workspace_a, 'employee', 'active'),
    (removed_member, 'invitation-removed@example.com', workspace_a, 'employee', 'removed'),
    (unverified_user, 'invitation-unverified@example.com', null, null, null)
  ) as fixtures(auth_id, email, workspace_id, member_role, member_status)
  loop
    insert into auth.users (id, email, email_confirmed_at)
    values (fixture.auth_id, fixture.email,
      case when fixture.auth_id <> unverified_user then transaction_timestamp() end);
    select id into strict profile_id from public.users as profile
    where profile.auth_id = fixture.auth_id and profile.email = fixture.email;

    if fixture.workspace_id is null then
      if exists (select 1 from public.workspace_members where user_id = profile_id) then
        raise exception 'Unexpected membership for fixture %', fixture.email;
      end if;
    else
      insert into public.workspace_members (user_id, workspace_id, role, status)
      values (profile_id, fixture.workspace_id, fixture.member_role, fixture.member_status);

      if not exists (
        select 1 from public.workspace_members as membership
        where membership.user_id = profile_id
          and membership.workspace_id = fixture.workspace_id
          and membership.role = fixture.member_role
          and membership.status = fixture.member_status
      ) then
        raise exception 'Missing or incorrect membership fixture for %', fixture.email;
      end if;
    end if;
  end loop;

  select id into strict admin_a_profile from public.users where auth_id = admin_a;
  select id into strict admin_b_profile from public.users where auth_id = admin_b;
  select id into strict invitee_profile from public.users where auth_id = invitee_a;
  select id into strict existing_profile from public.users where auth_id = existing_member;
  select id into strict removed_profile from public.users where auth_id = removed_member;

  set local role authenticated;
  if not row_security_active('public.invitations'::regclass) then
    raise exception 'Invitation RLS must be active for authenticated';
  end if;

  perform pg_temp.invitation_actor(admin_a);
  insert into public.invitations (workspace_id, email, invited_by)
  values (workspace_a, upper(invitee_email), admin_a_profile) returning * into invitation_a;
  perform pg_temp.expect_invitation('I1 admin creates an invitation in their own workspace',
    invitation_a.id is not null);

  for fixture in select * from (values
    ('I2 employee cannot create an invitation', employee_a, workspace_a),
    ('I3 admin cannot create an invitation in another workspace', admin_a, workspace_b)
  ) as denied(test_name, actor, target_workspace)
  loop
    perform pg_temp.invitation_actor(fixture.actor);
    select id into strict profile_id from public.users where auth_id = fixture.actor;
    begin
      insert into public.invitations (workspace_id, email, invited_by)
      values (fixture.target_workspace, invitee_email, profile_id);
      perform pg_temp.expect_invitation(fixture.test_name, false);
    exception when insufficient_privilege then
      get stacked diagnostics error_text = message_text;
      if error_text not like 'new row violates row-level security policy% for table "invitations"' then
        raise;
      end if;
      perform pg_temp.expect_invitation(fixture.test_name, true);
    end;
  end loop;

  set local role anon;
  perform pg_temp.invitation_actor(null);
  begin
    insert into public.invitations (workspace_id, email, invited_by)
    values (workspace_a, invitee_email, admin_a_profile);
    perform pg_temp.expect_invitation('I4 anon cannot create an invitation', false);
  exception when insufficient_privilege then
    perform pg_temp.expect_invitation('I4 anon cannot create an invitation',
      auth.uid() is null and not has_table_privilege('anon', 'public.invitations', 'INSERT'));
  end;
  begin
    perform public.accept_workspace_invitation(invitation_a.token);
    perform pg_temp.expect_invitation('I4 anon cannot execute the acceptance RPC', false);
  exception when insufficient_privilege then
    perform pg_temp.expect_invitation('I4 anon cannot execute the acceptance RPC',
      not has_function_privilege('anon', 'public.accept_workspace_invitation(uuid)', 'EXECUTE'));
  end;

  set local role authenticated;
  perform pg_temp.invitation_actor(admin_a);
  perform pg_temp.expect_invitation('I5 invitation fields and schema defaults',
    invitation_a.workspace_id = workspace_a and invitation_a.email = upper(invitee_email)
      and invitation_a.invited_by = admin_a_profile and invitation_a.status = 'pending'
      and invitation_a.token is not null and invitation_a.created_at = transaction_timestamp()
      and invitation_a.expires_at = transaction_timestamp() + interval '7 days');

  begin
    insert into public.invitations (workspace_id, email, invited_by)
    values (workspace_a, invitee_email, admin_a_profile);
    perform pg_temp.expect_invitation('I6 pending invitation email is unique per workspace, case-insensitively', false);
  exception when unique_violation then
    get stacked diagnostics violated_constraint = constraint_name;
    perform pg_temp.expect_invitation('I6 pending invitation email is unique per workspace, case-insensitively',
      violated_constraint = 'invitations_pending_workspace_email_key');
  end;

  insert into public.invitations (workspace_id, email, invited_by)
  values (workspace_a, 'invitation-deletable@example.com', admin_a_profile) returning id into strict deletable_a;

  perform pg_temp.expect_invitation('I7 admin can view their own workspace invitation', exists (
    select 1 from public.invitations where id = invitation_a.id and token = invitation_a.token
  ));

  perform pg_temp.invitation_actor(admin_b);
  insert into public.invitations (workspace_id, email, invited_by)
  values (workspace_b, invitee_email, admin_b_profile) returning * into strict invitation_b;
  perform pg_temp.expect_invitation('I6 the same email can have a pending invitation in a different workspace',
    invitation_b.workspace_id = workspace_b and invitation_b.status = 'pending');

  for fixture in select * from (values
    ('I8 employee cannot read their workspace invitation', employee_a, invitation_a.id),
    ('I9 Workspace A admin cannot read Workspace B invitation', admin_a, invitation_b.id),
    ('I10 direct read by the matching invitee is denied by current policy', invitee_a, invitation_a.id),
    ('I11 unrelated user cannot read private invitation', wrong_user, invitation_a.id)
  ) as denied(test_name, actor, target_invitation)
  loop
    perform pg_temp.invitation_actor(fixture.actor);
    perform pg_temp.expect_invitation(fixture.test_name, not exists (
      select 1 from public.invitations where id = fixture.target_invitation
    ));
  end loop;

  -- Acceptance is available through the RPC, with direct client writes still restricted.
  for fixture in select * from (values
    ('I12 direct status change by the matching invitee is denied', invitee_a),
    ('I13/I14 direct status change by another account is denied', wrong_user)
  ) as denied(test_name, actor)
  loop
    perform pg_temp.invitation_actor(fixture.actor);
    update public.invitations set status = 'accepted' where token = invitation_a.token;
    get diagnostics affected = row_count;
    perform pg_temp.expect_invitation(fixture.test_name, affected = 0);
  end loop;

  perform pg_temp.invitation_actor(admin_a);
  begin
    insert into public.workspace_members (user_id, workspace_id, role, status)
    values (existing_profile, workspace_a, 'employee', 'active');
    perform pg_temp.expect_invitation('I18 membership uniqueness', false);
  exception when unique_violation then
    get stacked diagnostics violated_constraint = constraint_name;
    perform pg_temp.expect_invitation('I18 membership uniqueness',
      violated_constraint = 'workspace_members_user_id_workspace_id_key');
  end;

  update public.invitations set expires_at = transaction_timestamp() + interval '8 days'
  where id = invitation_a.id and status = 'pending' returning expires_at into updated_expiry;
  perform pg_temp.expect_invitation('I20 admin can update expiration in their workspace',
    updated_expiry = transaction_timestamp() + interval '8 days');

  for fixture in select * from (values
    ('I21 other admin cannot update invitation', admin_b),
    ('I22 employee cannot update invitation', employee_a)
  ) as denied(test_name, actor)
  loop
    perform pg_temp.invitation_actor(fixture.actor);
    update public.invitations set status = 'revoked' where id = invitation_a.id;
    get diagnostics affected = row_count;
    perform pg_temp.expect_invitation(fixture.test_name, affected = 0);
  end loop;

  for fixture in select * from (values
    ('I24 other admin cannot delete invitation', admin_b),
    ('I25 unrelated user cannot delete invitation', wrong_user)
  ) as denied(test_name, actor)
  loop
    perform pg_temp.invitation_actor(fixture.actor);
    delete from public.invitations where id = deletable_a;
    get diagnostics affected = row_count;
    perform pg_temp.expect_invitation(fixture.test_name, affected = 0);
  end loop;

  perform pg_temp.invitation_actor(admin_a);
  delete from public.invitations where id = deletable_a;
  get diagnostics affected = row_count;
  perform pg_temp.expect_invitation('I23 admin can delete an invitation in their workspace', affected = 1);

  begin
    update public.invitations set workspace_id = workspace_b where token = invitation_a.token;
    perform pg_temp.expect_invitation('I26 admin cannot move invitation to an unauthorized workspace', false);
  exception when insufficient_privilege then
    get stacked diagnostics error_text = message_text;
    perform pg_temp.expect_invitation('I26 admin cannot move invitation to an unauthorized workspace',
      error_text = 'Invitation identity cannot be changed');
  end;

  begin
    insert into public.workspace_members (workspace_id, user_id, role, status)
    values (workspace_b, invitee_profile, 'employee', 'active');
    perform pg_temp.expect_invitation('I26 admin cannot add invitee in unauthorized workspace', false);
  exception when insufficient_privilege then
    get stacked diagnostics error_text = message_text;
    perform pg_temp.expect_invitation('I26 admin cannot add invitee in unauthorized workspace',
      error_text like 'new row violates row-level security policy% for table "workspace_members"');
  end;

  perform pg_temp.expect_invitation('I26 invitation stayed in the original workspace', exists (
    select 1 from public.invitations
    where id = invitation_a.id and workspace_id = workspace_a and status = 'pending'
  ));

  insert into public.invitations (workspace_id, email)
  values (workspace_a, 'invitation-no-attribution@example.com')
  returning invited_by into strict profile_id;
  perform pg_temp.expect_invitation('I29 inviter attribution can still be omitted', profile_id is null);

  begin
    insert into public.invitations (workspace_id, email, invited_by)
    values (workspace_a, 'invitation-attribution@example.com', admin_b_profile);
    perform pg_temp.expect_invitation('I29 admin cannot attribute a new invitation to another user', false);
  exception when insufficient_privilege then
    get stacked diagnostics error_text = message_text;
    perform pg_temp.expect_invitation('I29 admin cannot attribute a new invitation to another user',
      error_text = 'invited_by must reference the authenticated inviter');
  end;

  begin
    update public.invitations set invited_by = admin_b_profile where id = invitation_a.id;
    perform pg_temp.expect_invitation('I29 admin cannot rewrite the inviter', false);
  exception when insufficient_privilege then
    get stacked diagnostics error_text = message_text;
    perform pg_temp.expect_invitation('I29 admin cannot rewrite the inviter',
      error_text = 'invited_by cannot be changed by an authenticated client');
  end;

  begin
    update public.invitations set status = 'accepted' where id = invitation_a.id;
    perform pg_temp.expect_invitation('I20 admin cannot record acceptance directly', false);
  exception when insufficient_privilege then
    get stacked diagnostics error_text = message_text;
    perform pg_temp.expect_invitation('I20 admin cannot record acceptance directly',
      error_text = 'Invitation status transition is not allowed');
  end;

  insert into public.invitations (workspace_id, email)
  values (workspace_a, 'invitation-wrong-user@example.com') returning * into strict revoked_invitation;
  update public.invitations set status = 'revoked' where id = revoked_invitation.id;
  get diagnostics affected = row_count;
  perform pg_temp.expect_invitation('I23 owning admin can revoke a pending invitation', affected = 1);
  begin
    update public.invitations set status = 'pending' where id = revoked_invitation.id;
    perform pg_temp.expect_invitation('I17 revoked status is terminal for clients', false);
  exception when insufficient_privilege then
    get stacked diagnostics error_text = message_text;
    perform pg_temp.expect_invitation('I17 revoked status is terminal for clients',
      error_text = 'Invitation status transition is not allowed');
  end;

  insert into public.invitations (workspace_id, email, token)
  values (workspace_a, 'invitation-existing@example.com', revoked_invitation.token)
  returning * into strict existing_invitation;
  perform pg_temp.expect_invitation('I15 clients cannot choose or recycle issued tokens',
    existing_invitation.token <> revoked_invitation.token);

  insert into public.invitations (workspace_id, email)
  values (workspace_a, 'invitation-removed@example.com') returning * into strict removed_invitation;
  insert into public.invitations (workspace_id, email)
  values (workspace_a, 'invitation-unverified@example.com') returning * into strict unverified_invitation;

  reset role;
  perform pg_temp.expect_invitation('I29 original inviter is unchanged', exists (
    select 1 from public.invitations where id = invitation_a.id and invited_by = admin_a_profile
  ));
  insert into public.invitations (workspace_id, email, expires_at)
  values (workspace_a, 'invitation-wrong-user@example.com', transaction_timestamp() - interval '1 day')
  returning * into strict expired_invitation;

  -- A user who administers both workspaces still cannot retarget an issued token.
  insert into public.workspace_members (workspace_id, user_id, role, status)
  values (workspace_b, admin_a_profile, 'admin', 'active');
  set local role authenticated;
  perform pg_temp.invitation_actor(admin_a);
  perform pg_temp.expect_invitation('I27 actor administers both workspaces',
    public.is_workspace_admin(workspace_a) and public.is_workspace_admin(workspace_b));

  for fixture in select * from (values
    ('I27 workspace cannot be reassigned', workspace_b, invitation_a.email, invitation_a.token),
    ('I27 recipient email cannot be reassigned', workspace_a, invitee_email, invitation_a.token),
    ('I27 issued token cannot be changed', workspace_a, invitation_a.email, invitation_b.token)
  ) as denied(test_name, workspace_id, email, token)
  loop
    begin
      update public.invitations
      set workspace_id = fixture.workspace_id, email = fixture.email, token = fixture.token
      where id = invitation_a.id;
      perform pg_temp.expect_invitation(fixture.test_name, false);
    exception when insufficient_privilege then
      get stacked diagnostics error_text = message_text;
      perform pg_temp.expect_invitation(fixture.test_name, error_text = 'Invitation identity cannot be changed');
    end;
  end loop;

  perform pg_temp.invitation_actor(wrong_user);
  perform pg_temp.expect_invitation('I13 another authenticated account cannot accept the token',
    public.accept_workspace_invitation(invitation_a.token) = 'invalid_invitation');
  update public.users set email = upper(invitee_email) where auth_id = wrong_user;
  get diagnostics affected = row_count;
  if affected <> 1 then
    raise exception 'Missing editable profile for the email mismatch test';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', wrong_user, 'role', 'authenticated', 'email', invitee_email
  )::text, true);
  perform pg_temp.expect_invitation('I14 matching profile and JWT email cannot replace the Auth email',
    public.accept_workspace_invitation(invitation_a.token) = 'invalid_invitation');
  perform pg_temp.expect_invitation('I16 elapsed pending invitation cannot be accepted',
    public.accept_workspace_invitation(expired_invitation.token) = 'invalid_invitation');
  perform pg_temp.expect_invitation('I17 revoked invitation cannot be accepted',
    public.accept_workspace_invitation(revoked_invitation.token) = 'invalid_invitation');

  perform pg_temp.invitation_actor(admin_a);
  begin
    update public.invitations set expires_at = transaction_timestamp() + interval '1 day'
    where id = expired_invitation.id;
    perform pg_temp.expect_invitation('I16 elapsed invitation cannot be revived by changing expiration', false);
  exception when insufficient_privilege then
    get stacked diagnostics error_text = message_text;
    perform pg_temp.expect_invitation('I16 elapsed invitation cannot be revived by changing expiration',
      error_text = 'Only an unexpired pending invitation can receive a new future expiration');
  end;
  update public.invitations set status = 'expired' where id = expired_invitation.id;
  get diagnostics affected = row_count;
  perform pg_temp.expect_invitation('I16 admin can mark an elapsed invitation expired', affected = 1);
  perform pg_temp.invitation_actor(wrong_user);
  perform pg_temp.expect_invitation('I16 expired status cannot be accepted',
    public.accept_workspace_invitation(expired_invitation.token) = 'invalid_invitation');

  perform pg_temp.invitation_actor(existing_member);
  perform pg_temp.expect_invitation('I18 active member receives already_member',
    public.accept_workspace_invitation(existing_invitation.token) = 'already_member');
  perform pg_temp.invitation_actor(removed_member);
  perform pg_temp.expect_invitation('I19 removed member requires admin action',
    public.accept_workspace_invitation(removed_invitation.token) = 'membership_requires_admin_action');
  perform pg_temp.invitation_actor(unverified_user);
  perform pg_temp.expect_invitation('I14 matching unverified Auth email cannot accept',
    public.accept_workspace_invitation(unverified_invitation.token) = 'invalid_invitation');

  perform pg_temp.invitation_actor(invitee_a);
  begin
    insert into public.workspace_members (workspace_id, user_id, role, status)
    values (workspace_a, invitee_profile, 'admin', 'active');
    perform pg_temp.expect_invitation('I28 invitee cannot grant themselves admin membership directly', false);
  exception when insufficient_privilege then
    get stacked diagnostics error_text = message_text;
    perform pg_temp.expect_invitation('I28 invitee cannot grant themselves admin membership directly',
      error_text like 'new row violates row-level security policy% for table "workspace_members"');
  end;
  perform pg_temp.expect_invitation('I28 the RPC has one token-only signature and is unavailable to service_role',
    (select count(*) = 1 from pg_proc
      where pronamespace = 'public'::regnamespace and proname = 'accept_workspace_invitation')
    and to_regprocedure('public.accept_workspace_invitation(uuid)') is not null
    and not has_function_privilege('service_role', 'public.accept_workspace_invitation(uuid)', 'EXECUTE'));
  perform pg_temp.expect_invitation('I12 matching confirmed email accepts case-insensitively',
    public.accept_workspace_invitation(invitation_a.token) = 'accepted');
  perform pg_temp.expect_invitation('I15 accepted token cannot be used again',
    public.accept_workspace_invitation(invitation_a.token) = 'invalid_invitation');

  reset role;
  perform pg_temp.expect_invitation('I12 stored membership is active employee in the original workspace',
    (select count(*) = 1 from public.workspace_members where user_id = invitee_profile)
    and exists (
      select 1 from public.workspace_members
      where user_id = invitee_profile and workspace_id = workspace_a and role = 'employee' and status = 'active'
    ));
  perform pg_temp.expect_invitation('I30 accepting the token from A leaves no B membership or accepted invitation',
    exists (select 1 from public.invitations where id = invitation_a.id and status = 'accepted')
    and exists (select 1 from public.invitations where id = invitation_b.id and status = 'pending')
    and not exists (select 1 from public.workspace_members where user_id = invitee_profile and workspace_id = workspace_b));
  perform pg_temp.expect_invitation('I18/I19 existing memberships and invitation statuses are unchanged',
    (select count(*) = 1 from public.workspace_members where user_id = existing_profile and workspace_id = workspace_a)
    and exists (
      select 1 from public.workspace_members where user_id = existing_profile and workspace_id = workspace_a
        and status = 'active' and role = 'employee'
    )
    and exists (
      select 1 from public.workspace_members where user_id = removed_profile and workspace_id = workspace_a
        and status = 'removed' and role = 'employee'
    )
    and (select count(*) = 2 from public.invitations
      where id in (existing_invitation.id, removed_invitation.id) and status = 'pending'));
end;
$$;

rollback;
