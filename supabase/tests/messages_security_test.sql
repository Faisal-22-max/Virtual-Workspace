begin;
set local plpgsql.check_asserts = on;

do $$
declare
  a constant uuid := '00000000-0000-0000-0000-000000061101';
  b constant uuid := '00000000-0000-0000-0000-000000061102';
  fixture record;
  actors uuid[] := array[]::uuid[];
  actor uuid;
  own_message uuid;
  disposable uuid;
  b_message uuid;
  sender uuid;
  affected integer;
  p text;
begin
  insert into public.workspaces(id,name,slug) values
    (a,'Messages A','messages-test-a'), (b,'Messages B','messages-test-b');
  -- 1 admin A, 2 employee A, 3 removed A, 4 admin B, 5 employee B, 6 outsider.
  for fixture in select * from (values
    (1,a,'admin','active'), (2,a,'employee','active'), (3,a,'employee','removed'),
    (4,b,'admin','active'), (5,b,'employee','active'), (6,null,null,null)
  ) as cases(n,ws,r,s) order by n loop
    actor := ('00000000-0000-0000-0000-' || lpad((61000+fixture.n)::text,12,'0'))::uuid;
    insert into auth.users(id,email) values (actor,'messages-'||fixture.n||'@example.com');
    -- Exercise the old policy's alternate sender ID with a valid foreign Auth UUID.
    if fixture.n = 2 then
      update public.users set id = '00000000-0000-0000-0000-000000061005' where auth_id = actor;
    end if;
    select id into strict sender from public.users where auth_id=actor;
    if fixture.ws is not null then
      insert into public.workspace_members(workspace_id,user_id,role,status)
      values (fixture.ws,sender,fixture.r,fixture.s);
      assert exists(select from public.workspace_members where workspace_id=fixture.ws
        and user_id=sender and role=fixture.r and status=fixture.s);
    else
      assert not exists(select from public.workspace_members where user_id=sender);
    end if;
    actors := array_append(actors,actor);
  end loop;
  insert into public.messages(workspace_id,sender_id,content) values
    (a,actors[2],'fixture A') returning id into strict own_message;
  insert into public.messages(workspace_id,sender_id,content) values
    (b,actors[5],'fixture B') returning id into strict b_message;

  foreach p in array array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE'] loop
    assert has_table_privilege('anon','public.messages',p) = (p='SELECT');
    assert has_table_privilege('authenticated','public.messages',p) = (p<>'TRUNCATE');
  end loop;
  set local role authenticated;
  assert row_security_active('public.messages');
  for fixture in select * from (values
    (1,2,a,true),(2,2,b,false),(3,1,b,false),(4,6,a,false),(5,3,a,false),
    (24,2,b,false)
  ) as cases(n,person,ws,allowed) loop
    perform set_config('request.jwt.claims',jsonb_build_object('sub',actors[fixture.person],'role','authenticated')::text,true);
    assert exists(select from public.messages where workspace_id=fixture.ws) = fixture.allowed;
    raise notice 'PASS M%',fixture.n;
  end loop;
  for fixture in select * from (values
    (7,2,2,a,true),(8,1,1,a,true),(9,2,2,b,false),(10,6,6,a,false),
    (11,3,3,a,false),(13,2,2,a,true),(14,2,1,a,false),(15,1,2,a,false),
    (16,2,5,a,false),(23,2,2,b,false)
  ) as cases(n,person,author,ws,allowed) loop
    perform set_config('request.jwt.claims',jsonb_build_object('sub',actors[fixture.person],'role','authenticated')::text,true);
    begin
      insert into public.messages(workspace_id,sender_id,content)
      values (fixture.ws,actors[fixture.author],'insert test') returning sender_id into strict sender;
      assert fixture.allowed and sender=actors[fixture.person];
    exception when insufficient_privilege then
      assert not fixture.allowed and sqlerrm like 'new row violates row-level security policy% for table "messages"';
    end;
    raise notice 'PASS M%',fixture.n;
  end loop;
  set local role anon;
  perform set_config('request.jwt.claims','{"role":"anon"}',true);
  begin
    insert into public.messages(workspace_id,sender_id,content) values(a,actors[2],'anon');
    raise exception 'M12 unexpected insert';
  exception when insufficient_privilege then raise notice 'PASS M12';
  end;
  set local role authenticated;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actors[2],'role','authenticated')::text,true);
  insert into public.messages(workspace_id,content) values(a,'self') returning id into strict disposable;
  update public.messages set content='edited' where id=own_message returning sender_id into strict sender;
  assert sender=actors[2] and exists(select from public.messages where id=own_message and content='edited');
  raise notice 'PASS M17';
  delete from public.messages where id=disposable;
  get diagnostics affected=row_count;
  assert affected=1;
  raise notice 'PASS M19';
  update public.messages set content='foreign edit' where id=b_message;
  get diagnostics affected=row_count;
  assert affected=0;
  delete from public.messages where id=b_message;
  get diagnostics affected=row_count;
  assert affected=0;
  raise notice 'PASS M22';

  reset role;
  select id into strict sender from public.users where auth_id=actors[5];
  insert into public.workspace_members(workspace_id,user_id,role,status) values(a,sender,'employee','active');
  set local role authenticated;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actors[5],'role','authenticated')::text,true);
  assert exists(select from public.messages where workspace_id=a and id=own_message)
    and exists(select from public.messages where workspace_id=b and id=b_message)
    and not exists(select from public.messages where workspace_id=b and id=own_message);
  begin
    update public.messages set workspace_id=a where id=b_message;
    raise exception 'Workspace reassignment succeeded';
  exception when check_violation then assert sqlerrm='Message workspace cannot change';
  end;
  raise notice 'PASS M6';
  update public.messages set content='peer edit' where id=own_message;
  get diagnostics affected=row_count;
  assert affected=0;
  raise notice 'PASS M18';
  delete from public.messages where id=own_message;
  get diagnostics affected=row_count;
  assert affected=0;
  raise notice 'PASS M20';
  perform set_config('request.jwt.claims',jsonb_build_object('sub',actors[1],'role','authenticated')::text,true);
  delete from public.messages where id=own_message;
  get diagnostics affected=row_count;
  assert affected=0;
  raise notice 'PASS M21';
end;
$$;
rollback;
