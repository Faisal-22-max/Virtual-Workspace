-- Purpose: members with status <> 'active' must fail authorization.
-- Depends on: workspace_members, users (existing). Rollback: see bottom.

create or replace function public.is_workspace_member(ws uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1
    from public.workspace_members wm
    join public.users u on u.id = wm.user_id
    where wm.workspace_id = ws
      and u.auth_id = auth.uid()
      and wm.status = 'active'
  );
$$;

create or replace function public.is_workspace_admin(ws uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1
    from public.workspace_members wm
    join public.users u on u.id = wm.user_id
    where wm.workspace_id = ws
      and u.auth_id = auth.uid()
      and wm.status = 'active'
      and wm.role = 'admin'
  );
$$;

-- Only logged-in users may call these (policies for role authenticated use them)
revoke execute on function public.is_workspace_member(uuid) from public, anon;
revoke execute on function public.is_workspace_admin(uuid)  from public, anon;
grant  execute on function public.is_workspace_member(uuid) to authenticated;
grant  execute on function public.is_workspace_admin(uuid)  to authenticated;

-- ROLLBACK: re-run the previous definitions (without the status check).