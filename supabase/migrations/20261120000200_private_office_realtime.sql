begin;

create function public.can_access_office_topic(topic text)
returns boolean language sql stable security invoker set search_path = ''
as $$
  select case
    when topic collate "C" ~ '^office:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.is_workspace_member(substr(topic, 8)::uuid)
    else false
  end;
$$;
revoke execute on function public.can_access_office_topic(text) from public, anon, authenticated, service_role;
grant execute on function public.can_access_office_topic(text) to authenticated;

-- Supabase computes read/write permissions with probe rows and rolls them back.
-- The restrictive policies keep permissive policies for other topics from
-- granting access to the office namespace.
create policy office_topic_authenticated_only on realtime.messages
  as restrictive for all to public
  using (
    current_user = 'authenticated'
    or (lower(coalesce((select realtime.topic()), '') collate "C") not like 'office:%'
      and lower(topic collate "C") not like 'office:%')
  );

create policy office_topic_members_only on realtime.messages
  as restrictive for all to authenticated
  using (
    case when lower((select realtime.topic()) collate "C") like 'office:%'
             or lower(topic collate "C") like 'office:%'
      then extension in ('broadcast', 'presence')
        and topic = (select realtime.topic())
        and (select public.can_access_office_topic(realtime.topic()))
      else true end
  );

create policy office_topic_receive on realtime.messages
  for select to authenticated
  using (extension in ('broadcast', 'presence')
    and topic = (select realtime.topic())
    and (select public.can_access_office_topic(realtime.topic())));

create policy office_topic_publish on realtime.messages
  for insert to authenticated
  with check (extension in ('broadcast', 'presence')
    and topic = (select realtime.topic())
    and (select public.can_access_office_topic(realtime.topic())));

commit;
