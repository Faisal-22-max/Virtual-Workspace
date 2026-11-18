do $$
declare
  ws constant uuid := '00000000-0000-0000-0000-00000000aaaa';
  ua constant uuid := '00000000-0000-0000-0000-0000000000a1';
  ub constant uuid := '00000000-0000-0000-0000-0000000000b2';
  a_m boolean; a_a boolean; b_m boolean; b_a boolean;
begin
  insert into auth.users (id, email) values
    (ua, 'test-a@example.com'), (ub, 'test-b@example.com');

  insert into public.workspaces (id, name, slug) values (ws, 'WS Test', 'ws-test-rollback');

  insert into public.workspace_members (user_id, workspace_id, role, status)
  select id, ws, 'admin', 'active'  from public.users where auth_id = ua;
  insert into public.workspace_members (user_id, workspace_id, role, status)
  select id, ws, 'admin', 'removed' from public.users where auth_id = ub;

  set local role authenticated;

  perform set_config('request.jwt.claims', '{"sub":"' || ua || '","role":"authenticated"}', true);
  select public.is_workspace_member(ws), public.is_workspace_admin(ws) into a_m, a_a;

  perform set_config('request.jwt.claims', '{"sub":"' || ub || '","role":"authenticated"}', true);
  select public.is_workspace_member(ws), public.is_workspace_admin(ws) into b_m, b_a;

  reset role;

  raise exception 'RESULT (rolled back) | expected A: true,true | B: false,false | actual A: %,% | B: %,%',
    a_m, a_a, b_m, b_a;
end $$;