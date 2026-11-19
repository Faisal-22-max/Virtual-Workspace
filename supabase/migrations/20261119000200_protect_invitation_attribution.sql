-- Keep invited_by optional and preserve inviter attribution for client writes.
begin;

create function public.protect_invitation_attribution()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if current_user <> 'authenticated' then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.invited_by is distinct from old.invited_by then
      raise exception 'invited_by cannot be changed by an authenticated client'
        using errcode = '42501';
    end if;
  elsif new.invited_by is not null and not exists (
    select 1 from public.users as profile
    where profile.id = new.invited_by and profile.auth_id = auth.uid()
  ) then
    raise exception 'invited_by must reference the authenticated inviter'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

revoke execute on function public.protect_invitation_attribution() from public, anon, authenticated;

create trigger protect_invitation_attribution
before insert or update of invited_by on public.invitations
for each row execute function public.protect_invitation_attribution();

commit;
