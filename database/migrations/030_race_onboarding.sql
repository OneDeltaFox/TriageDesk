begin;
-- The directory discloses only active race names and the caller's access state.
create function public.available_races() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null) then raise exception 'Verify your email first' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'state',r.state,
 'role',race_private.access_level(r.id),'requested',exists(select 1 from race_private.access_requests a where a.race_id=r.id and a.user_id=auth.uid()),
 'invitation',(select i.id from race_private.invitations i join auth.users u on u.id=auth.uid() and lower(u.email)=i.email where i.race_id=r.id and i.closed_at is null and i.expires_at>now() limit 1)) order by r.name,r.id)
 from race_private.races r where r.state='active' and not r.archived),'[]'::jsonb);
end $$;

create function public.review_race_access_as(p_race uuid,p_user uuid,p_requested_at timestamptz,p_approve boolean,p_role text) returns void
language plpgsql security definer set search_path='' as $$
declare target_email text; already_member boolean;
begin
 if coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
 perform 1 from race_private.races where id=p_race for update;
 if p_role is null or p_role not in ('viewer','editor') then raise exception 'Choose Viewer or Editor'; end if;
 select exists(select 1 from race_private.memberships where race_id=p_race and user_id=p_user) or exists(select 1 from race_private.races where id=p_race and owner_id=p_user) into already_member;
 perform public.review_race_access(p_race,p_user,p_requested_at,p_approve);
 if p_approve and not already_member and p_role='editor' then
   select email into target_email from auth.users where id=p_user;
   perform public.set_race_member(p_race,target_email,'viewer','editor');
 end if;
end $$;
alter table race_private.access_requests add column notification_id uuid not null default gen_random_uuid();
alter table race_private.access_requests add column notification_attempted_at timestamptz;
create table race_private.access_notification_attempts (
 user_id uuid not null references auth.users(id) on delete cascade,
 attempted_at timestamptz not null default clock_timestamp()
);
alter table race_private.access_notification_attempts enable row level security;
revoke all on race_private.access_notification_attempts from public,anon,authenticated;
create index access_notification_rate on race_private.access_notification_attempts(user_id,attempted_at);

-- Only the server can read recipient addresses. No addresses are returned to requesters.
create function public.claim_access_request_notification(p_race uuid,p_user uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare req race_private.access_requests; result jsonb;
begin
 perform 1 from race_private.races where id=p_race and state='active' and not archived for update;
 if not found then return null; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user::text,30));
 select * into req from race_private.access_requests where race_id=p_race and user_id=p_user for update;
 if not found or req.notification_attempted_at is not null then return null; end if;
 if (select count(*) from race_private.access_notification_attempts where user_id=p_user and attempted_at>clock_timestamp()-interval '1 hour')>=10 then raise exception 'Notification limit reached'; end if;
 select jsonb_build_object('id',req.notification_id,'race',r.name,'requester',u.email,'recipients',
 (select coalesce(jsonb_agg(jsonb_build_object('id',manager.id,'email',manager.email)),'[]'::jsonb) from auth.users manager where manager.email_confirmed_at is not null and (manager.id=r.owner_id or exists(select 1 from race_private.memberships m where m.race_id=r.id and m.user_id=manager.id and m.role='admin'))))
 into result from race_private.races r join auth.users u on u.id=p_user and u.email_confirmed_at is not null where r.id=p_race;
 if result is null then return null; end if;
 update race_private.access_requests set notification_attempted_at=clock_timestamp() where race_id=p_race and user_id=p_user;
 insert into race_private.access_notification_attempts(user_id) values(p_user);
 delete from race_private.access_notification_attempts where attempted_at<clock_timestamp()-interval '1 day';
 return result;
end $$;
revoke all on function public.available_races(),public.review_race_access_as(uuid,uuid,timestamptz,boolean,text) from public,anon;
grant execute on function public.available_races(),public.review_race_access_as(uuid,uuid,timestamptz,boolean,text) to authenticated;
revoke all on function public.claim_access_request_notification(uuid,uuid) from public,anon,authenticated;
grant execute on function public.claim_access_request_notification(uuid,uuid) to service_role;
-- Retire codes without deleting stored data or disrupting already-pending requests.
revoke execute on function public.race_access_code(uuid),public.set_race_access_code(uuid,text,text),public.request_race_access_by_code(text) from authenticated;
commit;
