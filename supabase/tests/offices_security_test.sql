-- Run as postgres on a disposable local Supabase database.
begin;

-- A permissive policy for another feature must never bypass office isolation.
create policy test_existing_realtime_policy on realtime.messages
  for all to anon, authenticated using (true) with check (true);

do $$
declare
  admin_auth uuid := gen_random_uuid();
  employee_auth uuid := gen_random_uuid();
  outsider_auth uuid := gen_random_uuid();
  removed_auth uuid := gen_random_uuid();
  workspace_a uuid;
  workspace_b uuid := gen_random_uuid();
  office_a uuid;
  office_b uuid;
  actor record;
  target record;
  kind text;
  rows_seen integer;
  current_version integer;
begin
  insert into auth.users (id, email)
  select id, id || '@example.com'
  from unnest(array[admin_auth, employee_auth, outsider_auth, removed_auth]) as fixtures(id);

  perform set_config('request.jwt.claim.sub', admin_auth::text, true);
  set local role authenticated;
  workspace_a := public.create_workspace('Office A', 'office-a-' || admin_auth, 'medium', 'default');
  reset role;

  insert into public.workspaces (id, name, slug)
    values (workspace_b, 'Office B', 'office-b-' || admin_auth);
  select id into strict office_a from public.offices where workspace_id = workspace_a;
  select id into strict office_b from public.offices where workspace_id = workspace_b;
  insert into public.workspace_members (user_id, workspace_id, role, status)
  select u.id, fixture.workspace_id, fixture.role, fixture.status
  from (values (employee_auth, workspace_a, 'employee', 'active'),
               (removed_auth, workspace_a, 'employee', 'removed'),
               (admin_auth, workspace_b, 'employee', 'active')) fixture(auth_id, workspace_id, role, status)
  join public.users u using (auth_id);

  if exists (
    select 1 from public.workspaces w
    left join public.offices o on o.workspace_id = w.id
    where o.id is null
  ) then raise exception 'Workspace missing its office'; end if;
  begin
    insert into public.offices (workspace_id) values (workspace_a);
    raise exception 'Second office accepted';
  exception when unique_violation then null;
  end;

  insert into realtime.messages (topic, extension)
  select 'office:' || workspace, extension
  from unnest(array[workspace_a, workspace_b]) workspace
  cross join unnest(array['broadcast', 'presence']) extension;

  set local role authenticated;
  for actor in select * from (values
    (admin_auth, 2, true), (employee_auth, 1, false),
    (outsider_auth, 0, false), (removed_auth, 0, false)
  ) as actors(auth_id, readable, writable)
  loop
    perform set_config('request.jwt.claim.sub', actor.auth_id::text, true);
    select count(*) into rows_seen from public.offices where id in (office_a, office_b);
    if rows_seen <> actor.readable or exists(select 1 from public.offices where id = office_b)
        is distinct from (actor.auth_id = admin_auth) then
      raise exception 'Incorrect office visibility for %', actor.auth_id;
    end if;
    update public.offices set map_config = '{"rooms":[]}' where id = office_a
      returning map_version into current_version;
    if found is distinct from actor.writable then
      raise exception 'Incorrect office update authorization for %', actor.auth_id;
    end if;
    if actor.writable and current_version <> 2 then
      raise exception 'Office update failed to increment the version';
    end if;

    for target in select * from (values
      ('office:' || workspace_a, actor.readable > 0),
      ('office:' || workspace_b, actor.auth_id = admin_auth),
      ('office:' || workspace_a || ':extra', false),
      ('OFFICE:' || workspace_a, false),
      ('office:AAAAAAAA-0000-4000-8000-000000000000', false),
      ('office:not-a-uuid', false),
      ('office:', false)
    ) as topics(topic, allowed)
    loop
      perform set_config('realtime.topic', target.topic, true);
      select count(*) into rows_seen from realtime.messages where topic in (
        'office:' || workspace_a, 'office:' || workspace_b);
      if rows_seen <> (case when target.allowed then 2 else 0 end) then
        raise exception 'Incorrect Realtime read isolation on %', target.topic;
      end if;
      foreach kind in array array['broadcast', 'presence', 'other'] loop
        begin
          insert into realtime.messages (topic, extension) values (target.topic, kind);
          if not target.allowed or kind = 'other' then
            raise exception 'Unexpected realtime publish authorization';
          end if;
          if not exists (select 1 from realtime.messages where topic = target.topic and extension = kind) then
            raise exception 'Missing realtime read authorization';
          end if;
          raise sqlstate 'PT001';
        exception
          when sqlstate 'PT001' then null;  -- Roll back each successful authorization probe.
          when insufficient_privilege then
            if target.allowed and kind <> 'other' then raise; end if;
        end;
      end loop;
    end loop;
  end loop;

  perform set_config('request.jwt.claim.sub', admin_auth::text, true);
  update public.offices set map_config = map_config where id = office_a returning map_version into strict current_version;
  if current_version <> 2 then raise exception 'No-op layout incremented the version'; end if;
  update public.offices set map_config = '{}' where id = office_a and map_version = 1;
  if found then raise exception 'Stale layout write succeeded'; end if;
  begin
    update public.offices set map_version = 100 where id = office_a;
    raise exception 'Client can overwrite map_version';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.offices (workspace_id) values (workspace_a);
    raise exception 'Client has direct insert privilege';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.offices where id = office_a;
    raise exception 'Client has direct delete privilege';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.offices set map_config = '[]' where id = office_a;
    raise exception 'Array layout accepted';
  exception when check_violation then null;
  end;
  begin
    update public.offices set map_config = jsonb_build_object('text', repeat('x', 65536)) where id = office_a;
    raise exception 'Oversized layout accepted';
  exception when check_violation then null;
  end;

  reset role;
  perform set_config('realtime.topic', 'office:' || workspace_a, true);
  set local role anon;
  if exists (select 1 from realtime.messages where topic = 'office:' || workspace_a) then
    raise exception 'Anonymous client read an office broadcast';
  end if;
  begin
    insert into realtime.messages (topic, extension) values ('office:' || workspace_a, 'presence');
    raise exception 'Anonymous client can write office presence';
  exception when insufficient_privilege then null;
  end;
  reset role;

  delete from public.workspaces where id in (workspace_a, workspace_b);
  if exists (select 1 from public.offices where id in (office_a, office_b)) then
    raise exception 'Office did not follow workspace deletion';
  end if;
  raise notice 'PASS office cardinality, RLS, grants, layout validation/versioning, and Realtime policy probes';
end;
$$;

rollback;
