begin;
create table race_private.access_codes (
 race_id uuid primary key references race_private.races(id) on delete cascade,
 code text not null unique check (code ~ '^[A-Z0-9][A-Z0-9-]{3,23}$')
);
alter table race_private.access_codes enable row level security;
revoke all on race_private.access_codes from public,anon,authenticated;

create function public.race_access_code(p_race uuid) returns text
language plpgsql stable security definer set search_path='' as $$
begin
 if coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
 return (select code from race_private.access_codes where race_id=p_race);
end $$;

create function public.set_race_access_code(p_race uuid,p_expected text,p_code text) returns text
language plpgsql security definer set search_path='' as $$
declare current_code text; next_code text := upper(trim(p_code));
begin
 perform 1 from race_private.races where id=p_race and owner_id=auth.uid() for update;
 if not found then raise exception 'Access denied' using errcode='42501'; end if;
 if next_code is null or next_code !~ '^[A-Z0-9][A-Z0-9-]{3,23}$' then raise exception 'Use 4–24 letters, numbers or hyphens, starting with a letter or number.'; end if;
 select code into current_code from race_private.access_codes where race_id=p_race;
 if current_code is distinct from p_expected then raise exception 'Code changed. Refresh and try again.' using errcode='40001'; end if;
 insert into race_private.access_codes(race_id,code) values(p_race,next_code)
 on conflict(race_id) do update set code=excluded.code;
 return next_code;
exception when unique_violation then raise exception 'That code is already in use. Choose another.';
end $$;

create function public.request_race_access_by_code(p_code text) returns void
language plpgsql security definer set search_path='' as $$
declare target uuid;
begin
 if not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null) then raise exception 'Verify your email first' using errcode='42501'; end if;
 select race_id into target from race_private.access_codes where code=upper(trim(p_code));
 if target is null then raise exception 'Race unavailable'; end if;
 -- Serialize with code changes, and recheck after acquiring the race lock.
 perform 1 from race_private.races where id=target for update;
 if not exists(select 1 from race_private.access_codes where race_id=target and code=upper(trim(p_code))) then raise exception 'Race unavailable'; end if;
 perform public.request_race_access(target);
end $$;
revoke all on function public.race_access_code(uuid) from public,anon;
revoke all on function public.set_race_access_code(uuid,text,text) from public,anon;
revoke all on function public.request_race_access_by_code(text) from public,anon;
grant execute on function public.race_access_code(uuid) to authenticated;
grant execute on function public.set_race_access_code(uuid,text,text) to authenticated;
grant execute on function public.request_race_access_by_code(text) to authenticated;
commit;
