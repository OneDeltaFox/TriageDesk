begin;
create table race_private.access_requests (
  race_id uuid not null references race_private.races(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  requested_at timestamptz not null default clock_timestamp(),
  primary key (race_id,user_id)
);
alter table race_private.access_requests enable row level security;
revoke all on race_private.access_requests from public,anon,authenticated;

create function public.request_race_access(p_race uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null) then
    raise exception 'Verify your email first' using errcode='42501';
  end if;
  perform 1 from race_private.races where id=p_race and state='active' and not archived for update;
  if not found then raise exception 'Race unavailable'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(auth.uid()::text,26));
  if race_private.access_level(p_race) is not null then return; end if;
  if exists(select 1 from race_private.access_requests where race_id=p_race and user_id=auth.uid()) then return; end if;
  if (select count(*) from race_private.access_requests where user_id=auth.uid()) >= 10 then raise exception 'Too many pending requests'; end if;
  insert into race_private.access_requests(race_id,user_id) values(p_race,auth.uid());
end $$;

create function public.race_access_requests(p_race uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if coalesce(race_private.access_level(p_race),'') <> 'owner' then raise exception 'Access denied' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id',a.user_id,'email',u.email,'requested_at',a.requested_at) order by a.requested_at)
    from race_private.access_requests a join auth.users u on u.id=a.user_id where a.race_id=p_race),'[]'::jsonb);
end $$;

create function public.review_race_access(p_race uuid,p_user uuid,p_requested_at timestamptz,p_approve boolean) returns void
language plpgsql security definer set search_path='' as $$
declare requested timestamptz; target_email text;
begin
  if coalesce(race_private.access_level(p_race),'') <> 'owner' then raise exception 'Access denied' using errcode='42501'; end if;
  perform 1 from race_private.races where id=p_race and owner_id=auth.uid() and state='active' and not archived for update;
  if not found then raise exception 'Race unavailable'; end if;
  select requested_at into requested from race_private.access_requests where race_id=p_race and user_id=p_user for update;
  if requested is null or requested is distinct from p_requested_at then raise exception 'Request changed. Refresh.' using errcode='40001'; end if;
  if p_approve is null then raise exception 'Decision required'; end if;
  if p_approve and race_private.access_level(p_race)='owner' then
    select email into target_email from auth.users where id=p_user and email_confirmed_at is not null;
    if target_email is null then raise exception 'Verified account required'; end if;
    if not exists(select 1 from race_private.memberships where race_id=p_race and user_id=p_user)
      and not exists(select 1 from race_private.races where id=p_race and owner_id=p_user) then
      perform public.set_race_member(p_race,target_email,null,'viewer');
    end if;
  end if;
  delete from race_private.access_requests where race_id=p_race and user_id=p_user;
end $$;
revoke all on function public.request_race_access(uuid) from public,anon;
revoke all on function public.race_access_requests(uuid) from public,anon;
revoke all on function public.review_race_access(uuid,uuid,timestamptz,boolean) from public,anon;
grant execute on function public.request_race_access(uuid) to authenticated;
grant execute on function public.race_access_requests(uuid) to authenticated;
grant execute on function public.review_race_access(uuid,uuid,timestamptz,boolean) to authenticated;
commit;
