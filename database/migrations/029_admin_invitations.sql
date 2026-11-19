begin;
alter table race_private.invitations drop constraint invitations_role_check;
alter table race_private.invitations add constraint invitations_role_check check(role in ('admin','editor','viewer'));

create or replace function public.create_race_invitation(p_race uuid,p_email text,p_role text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_owner uuid; v_id uuid; v_email text:=lower(trim(p_email));
begin
 select owner_id into v_owner from race_private.races where id=p_race for update;
 if auth.uid() is null or coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
 if p_role is null or p_role not in ('admin','editor','viewer') then raise exception 'Invalid role'; end if;
 if p_role='admin' and v_owner is distinct from auth.uid() then raise exception 'Only the Owner can invite Admins' using errcode='42501'; end if;
 if v_email is null or length(v_email) not between 3 and 320 or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid email'; end if;
 if exists(select 1 from auth.users u where lower(u.email)=v_email and (u.id=v_owner or exists(select 1 from race_private.memberships m where m.race_id=p_race and m.user_id=u.id))) then raise exception 'Account already has access'; end if;
 update race_private.invitations set closed_at=clock_timestamp() where race_id=p_race and email=v_email and closed_at is null and expires_at<=clock_timestamp();
 insert into race_private.invitations(race_id,email,role,created_by) values(p_race,v_email,p_role,auth.uid()) returning id into v_id;
 return v_id;
end $$;

create or replace function public.cancel_race_invitation(p_race uuid,p_invitation uuid) returns void
language plpgsql security definer set search_path='' as $$
declare v_owner uuid;
begin
 select owner_id into v_owner from race_private.races where id=p_race for update;
 if auth.uid() is null or coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
 if v_owner is distinct from auth.uid() and exists(select 1 from race_private.invitations where id=p_invitation and race_id=p_race and role='admin') then raise exception 'Only the Owner can manage Admin invitations' using errcode='42501'; end if;
 update race_private.invitations set closed_at=clock_timestamp() where id=p_invitation and race_id=p_race and closed_at is null;
 if not found then raise exception 'Invitation changed. Refresh.' using errcode='40001'; end if;
end $$;

create or replace function public.claim_invitation_email(p_race uuid, p_invitation uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_owner uuid; v_inv race_private.invitations;
begin
 -- Serialize sends by owner across all races before checking the hourly budget.
 perform 1 from auth.users where id=auth.uid() for update;
 select owner_id into v_owner from race_private.races where id=p_race for update;
 if auth.uid() is null or coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
 select * into v_inv from race_private.invitations where id=p_invitation and race_id=p_race for update;
 if not found or v_inv.closed_at is not null or v_inv.expires_at<=clock_timestamp() then raise exception 'Invitation unavailable'; end if;
 if v_inv.role='admin' and v_owner is distinct from auth.uid() then raise exception 'Only the Owner can send Admin invitations' using errcode='42501'; end if;
 if v_inv.email_attempted_at is not null then raise exception 'Email already attempted. Check delivery before creating another invitation.'; end if;
 if exists(select 1 from auth.users u where lower(u.email)=v_inv.email and
   (u.id=v_owner or exists(select 1 from race_private.memberships m where m.race_id=p_race and m.user_id=u.id))) then
   raise exception 'Account already has access';
 end if;
 if (select count(*) from race_private.invitations where email_attempted_by=auth.uid() and email_attempted_at>clock_timestamp()-interval '1 hour') >= 10 then
   raise exception 'Invitation email limit reached. Try again later.';
 end if;
 update race_private.invitations set email_attempted_at=clock_timestamp(),email_attempted_by=auth.uid() where id=p_invitation;
 return jsonb_build_object('email',v_inv.email);
end $$;
commit;
