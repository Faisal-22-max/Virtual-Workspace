-- Purpose: remove client TRUNCATE privileges and fix recursive profile reads.
-- Dependencies: the existing users SELECT policy and workspace_members RLS.
-- "members read members" uses public.is_workspace_member(uuid), whose
-- SECURITY DEFINER context checks the caller's active membership without
-- re-entering the users policy. Keep the memberships SELECT policy scoped to
-- active workspace members if it is changed in the future.
-- Security: TRUNCATE bypasses RLS and row-level DELETE triggers. For profile
-- reads, the visible membership must also be active for the target coworker.

begin;

revoke truncate on table public.workspaces, public.workspace_members
from anon, authenticated;

alter policy "read self or coworkers" on public.users
using (
  auth_id = auth.uid()
  or exists (
    select 1
    from public.workspace_members as membership
    where membership.user_id = users.id
      and membership.status = 'active'
  )
);

commit;

-- Recommended rollback if coworker reads need to be disabled: keep the
-- privilege revocation and restrict the policy to self-profile reads.
-- alter policy "read self or coworkers" on public.users
-- using (auth_id = auth.uid());
