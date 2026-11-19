begin;

alter table public.invitations drop constraint invitations_status_check;
alter table public.invitations add constraint invitations_status_check
  check (status in ('pending', 'accepted', 'expired', 'revoked'));

-- Existing duplicate invitations need an explicit choice about which links to keep.
do $$
begin
  if exists (
    select 1 from public.invitations
    where status = 'pending'
    group by workspace_id, pg_catalog.lower(email)
    having count(*) > 1
  ) then
    raise exception 'Resolve duplicate pending invitations before enforcing uniqueness';
  end if;
end;
$$;

create unique index invitations_pending_workspace_email_key
  on public.invitations (workspace_id, pg_catalog.lower(email))
  where status = 'pending';

create function public.enforce_invitation_lifecycle()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  checked_at constant timestamptz := pg_catalog.clock_timestamp();
begin
  -- The acceptance RPC and trusted database maintenance run under their own roles.
  if current_user <> 'authenticated' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'pending' or new.expires_at is null or new.expires_at <= checked_at then
      raise exception 'A new invitation must be pending with a future expiration'
        using errcode = '42501';
    end if;

    new.token := pg_catalog.gen_random_uuid();
    return new;
  end if;

  if new.id is distinct from old.id or new.token is distinct from old.token
      or new.workspace_id is distinct from old.workspace_id
      or new.email is distinct from old.email then
    raise exception 'Invitation identity cannot be changed'
      using errcode = '42501';
  end if;

  if new.expires_at is distinct from old.expires_at and (
    old.status <> 'pending' or old.expires_at is null or old.expires_at <= checked_at
      or new.expires_at is null or new.expires_at <= checked_at
  ) then
    raise exception 'Only an unexpired pending invitation can receive a new future expiration'
      using errcode = '42501';
  end if;

  if new.status is distinct from old.status and not (
    old.status = 'pending' and (
      new.status = 'revoked' or
      (new.status = 'expired' and (old.expires_at is null or old.expires_at <= checked_at))
    )
  ) then
    raise exception 'Invitation status transition is not allowed'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

revoke execute on function public.enforce_invitation_lifecycle() from public, anon, authenticated, service_role;

create trigger enforce_invitation_lifecycle
before insert or update on public.invitations
for each row execute function public.enforce_invitation_lifecycle();

create function public.accept_workspace_invitation(p_token uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitee_profile_id uuid;
  invitee_email text;
  invitation_id uuid;
  target_workspace_id uuid;
  invitation_expiry timestamptz;
  existing_status text;
begin
  select profile.id, account.email into invitee_profile_id, invitee_email
  from auth.users as account
  join public.users as profile on profile.auth_id = account.id
  where account.id = auth.uid()
    and account.email is not null
    and account.email_confirmed_at is not null
  for share of account, profile;

  if not found then
    return 'invalid_invitation';
  end if;

  -- Match the identity before locking so other accounts cannot lock this invitation.
  select invitation.id, invitation.workspace_id, invitation.expires_at
  into invitation_id, target_workspace_id, invitation_expiry
  from public.invitations as invitation
  where invitation.token = p_token
    and invitation.status = 'pending'
    and pg_catalog.lower(invitation.email) = pg_catalog.lower(invitee_email)
  for update;

  if not found or invitation_expiry is null or invitation_expiry <= pg_catalog.clock_timestamp() then
    return 'invalid_invitation';
  end if;

  insert into public.workspace_members (user_id, workspace_id, role, status)
  values (invitee_profile_id, target_workspace_id, 'employee', 'active')
  on conflict (user_id, workspace_id) do nothing;

  if not found then
    select membership.status into existing_status
    from public.workspace_members as membership
    where membership.user_id = invitee_profile_id
      and membership.workspace_id = target_workspace_id
    for update;

    if existing_status = 'active' then
      return 'already_member';
    elsif existing_status = 'removed' then
      return 'membership_requires_admin_action';
    end if;
    return 'invalid_invitation';
  end if;

  update public.invitations
  set status = 'accepted'
  where id = invitation_id and expires_at > pg_catalog.clock_timestamp();

  if not found then
    -- Roll back membership creation if the invitation elapsed while the insert waited.
    raise exception 'Invitation expired during acceptance' using errcode = '22023';
  end if;

  return 'accepted';
end;
$$;

revoke execute on function public.accept_workspace_invitation(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.accept_workspace_invitation(uuid) to authenticated;

commit;
