-- Admin is race-scoped. Only Owners appoint Admins or perform race resets.
begin;
alter table race_private.memberships drop constraint memberships_role_check;
alter table race_private.memberships add constraint memberships_role_check check(role in ('admin','editor','viewer'));

-- race_private.transition_visit_without_reservation
create or replace function race_private.transition_visit_without_reservation(
  p_visit uuid, p_revision integer, p_action text,
  p_bed uuid default null, p_category text default null, p_other text default null
) returns integer language plpgsql security definer set search_path = '' as $$
declare
  v race_private.visits;
  destination record;
  previous race_private.placements;
  race uuid;
  race_state text;
  stamp timestamptz;
begin
  select race_id into race from race_private.visits where id = p_visit;
  if race is null or coalesce(race_private.access_level(race), '') not in ('owner','admin','editor') then
    raise exception 'Access denied' using errcode = '42501';
  end if;
  -- Serialize commands within this small race; all future setup/close commands must use this same lock.
  select state into race_state from race_private.races where id = race for update;
  if coalesce(race_private.access_level(race),'') not in ('owner','admin','editor') then raise exception 'Access denied' using errcode = '42501'; end if;
  if race_state <> 'active' then raise exception 'Race is not active'; end if;
  select * into v from race_private.visits where id = p_visit for update;
  if p_revision is null or v.revision <> p_revision then raise exception 'Stale visit; refresh before retrying' using errcode = '40001'; end if;
  if v.dispositioned_at is not null then raise exception 'Visit already dispositioned'; end if;
  stamp := clock_timestamp();
  if p_action = 'arrived' then
    if v.arrived_at is not null then raise exception 'Arrival already recorded'; end if;
    update race_private.visits set arrived_at = stamp where id = p_visit;
  elsif p_action = 'assigned' then
    select b.id, b.cleaning, p.closed, p.kind into destination
      from race_private.beds b join race_private.pods p on p.id = b.pod_id
      where b.id = p_bed and b.race_id = race;
    if not found then raise exception 'Bed unavailable'; end if;
    if destination.closed or destination.cleaning or exists (
      select 1 from race_private.placements where bed_id = p_bed and ended_at is null
    ) then raise exception 'Bed unavailable'; end if;
    select * into previous from race_private.placements where visit_id = p_visit and ended_at is null;
    if found then
      update race_private.placements set ended_at = stamp where id = previous.id;
      update race_private.beds set cleaning = true where id = previous.bed_id;
      insert into race_private.turnovers(race_id,bed_id,started_at) values (race,previous.bed_id,stamp);
    end if;
    insert into race_private.placements(race_id,visit_id,bed_id,kind,started_at)
      values (race,p_visit,p_bed,destination.kind,stamp);
    update race_private.visits set arrived_at = coalesce(arrived_at,stamp),
      medical_started_at = coalesce(medical_started_at,stamp) where id = p_visit;
  elsif p_action = 'dispositioned' then
    if p_category is null or p_category not in ('discharged','ems','other') then raise exception 'Invalid disposition'; end if;
    if p_category = 'other' and coalesce(length(trim(p_other)),0) = 0 then raise exception 'Other description required'; end if;
    select * into previous from race_private.placements where visit_id = p_visit and ended_at is null;
    if found then
      update race_private.placements set ended_at = stamp where id = previous.id;
      update race_private.beds set cleaning = true where id = previous.bed_id;
      insert into race_private.turnovers(race_id,bed_id,started_at) values (race,previous.bed_id,stamp);
    end if;
    update race_private.visits set disposition = p_category, dispositioned_at = stamp where id = p_visit;
    update race_private.visit_details set other_disposition = case when p_category = 'other' then trim(p_other) else null end where visit_id = p_visit;
  else
    raise exception 'Invalid action';
  end if;
  update race_private.visits set revision = revision + 1 where id = p_visit;
  insert into race_private.events(race_id,visit_id,bed_id,actor_id,action,occurred_at)
    values (race,p_visit,case when p_action = 'assigned' then p_bed else null end,auth.uid(),p_action,stamp);
  return v.revision + 1;
end
$$;

-- race_private.ready_bed
create or replace function race_private.ready_bed(p_bed uuid, p_turnover uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare race uuid; race_state text; stamp timestamptz;
begin
  select race_id into race from race_private.beds where id = p_bed;
  if race is null or coalesce(race_private.access_level(race),'') not in ('owner','admin','editor') then
    raise exception 'Access denied' using errcode = '42501';
  end if;
  select state into race_state from race_private.races where id = race for update;
  if coalesce(race_private.access_level(race),'') not in ('owner','admin','editor') then raise exception 'Access denied' using errcode = '42501'; end if;
  if race_state <> 'active' then raise exception 'Race is not active'; end if;
  if not exists (select 1 from race_private.turnovers where id = p_turnover and bed_id = p_bed and ended_at is null) then
    raise exception 'Stale turnover; refresh before retrying' using errcode = '40001';
  end if;
  stamp := clock_timestamp();
  update race_private.turnovers set ended_at = stamp where id = p_turnover;
  update race_private.beds set cleaning = false where id = p_bed;
  insert into race_private.events(race_id,bed_id,actor_id,action,occurred_at) values (race,p_bed,auth.uid(),'ready',stamp);
end
$$;

-- public.create_pods
create or replace function public.create_pods(p_race uuid, p_pods jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  race_state text;
  item jsonb;
  pod_id uuid;
  pod_name text;
  bed_count integer;
  caps text[];
begin
  if coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then
    raise exception 'Access denied' using errcode = '42501';
  end if;
  select state into race_state from race_private.races where id=p_race for update;
  if coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then
    raise exception 'Access denied' using errcode = '42501';
  end if;
  if race_state <> 'active' then raise exception 'Race is not active'; end if;
  if p_pods is null or jsonb_typeof(p_pods) <> 'array' then raise exception 'Invalid pod batch'; end if;
  if jsonb_array_length(p_pods) not between 1 and 50 then raise exception 'Use 1 to 50 pods per batch'; end if;
  for item in select value from jsonb_array_elements(p_pods) loop
    pod_name := trim(item->>'name');
    if jsonb_typeof(item) <> 'object' or pod_name is null or length(pod_name) not between 1 and 80
      or coalesce(item->>'color','') !~ '^#[0-9a-fA-F]{6}$'
      or coalesce(item->>'kind','') not in ('regular','pool')
      or coalesce(item->>'beds','') !~ '^[0-9]{1,2}$' then raise exception 'Invalid pod settings'; end if;
    bed_count := (item->>'beds')::integer;
    if bed_count not between 1 and 20 then raise exception 'Use 1 to 20 beds per pod'; end if;
    if jsonb_typeof(item->'capabilities') is distinct from 'array' then raise exception 'Invalid capabilities'; end if;
    if jsonb_array_length(item->'capabilities') > 20 or exists (
      select 1 from jsonb_array_elements(item->'capabilities') c where jsonb_typeof(c) <> 'string'
    ) then raise exception 'Invalid capabilities'; end if;
    if exists(select 1 from jsonb_array_elements_text(item->'capabilities') c where length(trim(c)) not between 1 and 80)
      then raise exception 'Invalid capabilities'; end if;
    select coalesce(array_agg(distinct trim(c)),array[]::text[]) into caps
      from jsonb_array_elements_text(item->'capabilities') c;
    insert into race_private.pods(race_id,name,kind,color,capabilities)
      values(p_race,pod_name,item->>'kind',item->>'color',caps) returning id into pod_id;
    insert into race_private.beds(race_id,pod_id,label)
      select p_race,pod_id,pod_name || '-' || n from generate_series(1,bed_count) n;
  end loop;
  return jsonb_array_length(p_pods);
end
$$;

-- public.patient_board_without_reservations
create or replace function public.patient_board_without_reservations(p_race uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if coalesce(race_private.access_level(p_race),'') not in ('owner','admin','editor') then
    raise exception 'Access denied' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'pods', public.race_layout(p_race),
    'visits', (select coalesce(jsonb_agg(to_jsonb(v) || to_jsonb(d) || jsonb_build_object('id',v.id)), '[]'::jsonb)
      from race_private.visits v join race_private.visit_details d on d.visit_id=v.id where v.race_id=p_race),
    'placements', (select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from race_private.placements p where p.race_id=p_race),
    'turnovers', (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from race_private.turnovers t where t.race_id=p_race and t.ended_at is null)
  );
end $$;

-- race_private.save_patient_base
create or replace function race_private.save_patient_base(p_race uuid, p_visit uuid, p_revision integer, p_details jsonb, p_bed uuid default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare v race_private.visits; race_state text; next_revision integer;
begin
  if coalesce(race_private.access_level(p_race),'') not in ('owner','admin','editor') then raise exception 'Access denied' using errcode='42501'; end if;
  select state into race_state from race_private.races where id=p_race for update;
  if coalesce(race_private.access_level(p_race),'') not in ('owner','admin','editor') then raise exception 'Access denied' using errcode='42501'; end if;
  if race_state <> 'active' then raise exception 'Race is not active'; end if;
  if p_visit is null or p_details is null or jsonb_typeof(p_details) <> 'object'
    or coalesce(length(trim(p_details->>'bib')),0) not between 1 and 100
    or coalesce(p_details->>'triage','untriaged') not in ('untriaged','immediate','delayed','minor')
    or coalesce(length(p_details->>'complaint'),0)>1000
    or coalesce(length(p_details->>'notes'),0)>2000
    or coalesce(length(p_details->>'source'),0)>200
    or coalesce(length(p_details->>'eta'),0)>100 then raise exception 'Invalid patient details'; end if;
  select * into v from race_private.visits where id=p_visit;
  if found then
    if v.race_id <> p_race then raise exception 'Access denied' using errcode='42501'; end if;
    if p_revision is null or v.revision <> p_revision then raise exception 'Stale visit; refresh before retrying' using errcode='40001'; end if;
    if v.dispositioned_at is not null then raise exception 'Visit already dispositioned'; end if;
  else
    if p_revision is not null then raise exception 'Visit not found'; end if;
    insert into race_private.visits(id,race_id,notified_at) values(p_visit,p_race,case when p_bed is null then clock_timestamp() else null end);
    insert into race_private.visit_details(visit_id,race_id,bib) values(p_visit,p_race,trim(p_details->>'bib'));
  end if;
  update race_private.visit_details set bib=trim(p_details->>'bib'), triage=coalesce(p_details->>'triage','untriaged'),
    complaint=coalesce(p_details->>'complaint',''), notes=coalesce(p_details->>'notes',''),
    source=coalesce(p_details->>'source',source), eta=coalesce(p_details->>'eta',eta) where visit_id=p_visit;
  if p_bed is not null then
    return race_private.transition_visit(p_visit,coalesce(v.revision,0),'assigned',p_bed);
  end if;
  update race_private.visits set revision=revision+1 where id=p_visit returning revision into next_revision;
  return next_revision;
end $$;

-- public.update_pod
create or replace function public.update_pod(p_pod uuid, p_expected jsonb, p_closed boolean, p_capabilities jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare race uuid; race_state text; current_pod race_private.pods; caps text[];
begin
  select race_id into race from race_private.pods where id=p_pod;
  if race is null or coalesce(race_private.access_level(race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
  select state into race_state from race_private.races where id=race for update;
  if coalesce(race_private.access_level(race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
  if race_state <> 'active' then raise exception 'Race is not active'; end if;
  select * into current_pod from race_private.pods where id=p_pod;
  if p_expected is distinct from jsonb_build_object('name',current_pod.name,'closed',current_pod.closed,'capabilities',current_pod.capabilities) then
    raise exception 'Pod changed; refresh before retrying' using errcode='40001';
  end if;
  if p_closed is null or jsonb_typeof(p_capabilities) is distinct from 'array' then raise exception 'Invalid pod settings'; end if;
  if jsonb_array_length(p_capabilities)>20 or exists(select 1 from jsonb_array_elements(p_capabilities) c where jsonb_typeof(c)<>'string') then raise exception 'Invalid capabilities'; end if;
  if exists(select 1 from jsonb_array_elements_text(p_capabilities) c where length(trim(c)) not between 1 and 80) then raise exception 'Invalid capabilities'; end if;
  select coalesce(array_agg(distinct trim(c)),array[]::text[]) into caps from jsonb_array_elements_text(p_capabilities) c;
  update race_private.pods set closed=p_closed,capabilities=caps where id=p_pod;
end $$;

-- race_private.section_plan
create or replace function race_private.section_plan(p_race uuid,p_color text,p_count integer,p_beds integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare boundary integer; first_number integer; prefix text; shifts jsonb; names jsonb;
begin
  if coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
  if not exists(select 1 from race_private.races where id=p_race and state='active') then raise exception 'Race is not active'; end if;
  if p_color is null or p_color !~ '^#[0-9a-fA-F]{6}$' or p_count is null or p_count not between 1 and 50 or p_beds is null or p_beds not between 1 and 20 then raise exception 'Invalid section batch'; end if;
  if exists(select 1 from race_private.pods where race_id=p_race and kind='regular' and name !~* '^(pod[[:space:]]+)?[1-9][0-9]{0,5}$') then
    raise exception 'Section insertion requires numbered regular pods (1 or Pod 1)';
  end if;
  select max(substring(name from '([0-9]+)$')::integer),min(substring(name from '([0-9]+)$')::integer)
    into boundary,first_number from race_private.pods where race_id=p_race and kind='regular' and lower(color)=lower(p_color);
  if boundary is null then raise exception 'Color section not found'; end if;
  if exists(select 1 from race_private.pods where race_id=p_race and kind='regular' and lower(color)<>lower(p_color)
    and substring(name from '([0-9]+)$')::integer between first_number and boundary) then raise exception 'Color section is not contiguous'; end if;
  if exists(select 1 from race_private.pods where race_id=p_race and kind='regular' and substring(name from '([0-9]+)$')::integer+p_count>999999) then raise exception 'Pod number limit exceeded'; end if;
  select regexp_replace(name,'[0-9]+$','') into prefix from race_private.pods where race_id=p_race and kind='regular' and substring(name from '([0-9]+)$')::integer=boundary;
  if exists(select 1 from race_private.beds b join race_private.pods p on p.id=b.pod_id
    where p.race_id=p_race and p.kind='regular' and substring(p.name from '([0-9]+)$')::integer>boundary and b.label !~ '-[1-9][0-9]?$') then
    raise exception 'Cannot renumber custom bed labels';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'from',p.name,
    'to',regexp_replace(p.name,'[0-9]+$','')||(substring(p.name from '([0-9]+)$')::integer+p_count),
    'beds',(select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'from',b.label,
      'to',(substring(p.name from '([0-9]+)$')::integer+p_count)||'-'||substring(b.label from '([0-9]+)$')) order by b.label),'[]'::jsonb) from race_private.beds b where b.pod_id=p.id))
    order by substring(p.name from '([0-9]+)$')::integer desc),'[]'::jsonb)
    into shifts from race_private.pods p where p.race_id=p_race and p.kind='regular' and substring(p.name from '([0-9]+)$')::integer>boundary;
  select jsonb_agg(prefix||n order by n) into names from generate_series(boundary+1,boundary+p_count) n;
  return jsonb_build_object('token',md5(public.race_layout(p_race)::text),'new_names',names,'changes',shifts,'color',lower(p_color),'beds_per_pod',p_beds);
end $$;

-- public.add_section_pods
create or replace function public.add_section_pods(p_race uuid,p_color text,p_count integer,p_beds integer,p_capabilities jsonb,p_expected_token text)
returns integer language plpgsql security definer set search_path='' as $$
declare plan jsonb; change jsonb; bed_change jsonb; batch jsonb;
begin
  if coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
  perform 1 from race_private.races where id=p_race for update;
  plan := race_private.section_plan(p_race,p_color,p_count,p_beds);
  if p_expected_token is distinct from plan->>'token' then raise exception 'Layout changed; preview again' using errcode='40001'; end if;
  -- Highest numbers first avoid transient uniqueness conflicts. IDs and placements never change.
  for change in select value from jsonb_array_elements(plan->'changes') loop
    update race_private.pods set name=change->>'to' where id=(change->>'id')::uuid;
    for bed_change in select value from jsonb_array_elements(change->'beds') loop
      update race_private.beds set label=bed_change->>'to' where id=(bed_change->>'id')::uuid;
    end loop;
  end loop;
  select jsonb_agg(jsonb_build_object('name',n,'kind','regular','color',lower(p_color),'beds',p_beds,'capabilities',p_capabilities))
    into batch from jsonb_array_elements_text(plan->'new_names') n;
  return public.create_pods(p_race,batch);
end $$;

-- race_private.transition_visit
create or replace function race_private.transition_visit(p_visit uuid,p_revision integer,p_action text,p_bed uuid default null,p_category text default null,p_other text default null)
returns integer language plpgsql security definer set search_path='' as $$
declare v race_private.visits; previous race_private.placements; held race_private.bed_reservations;
  destination_kind text; race uuid; race_state text; result integer; stamp timestamptz;
begin
  select race_id into race from race_private.visits where id=p_visit;
  if race is null or coalesce(race_private.access_level(race),'') not in ('owner','admin','editor') then raise exception 'Access denied' using errcode='42501'; end if;
  select state into race_state from race_private.races where id=race for update;
  if coalesce(race_private.access_level(race),'') not in ('owner','admin','editor') then raise exception 'Access denied' using errcode='42501'; end if;
  if race_state <> 'active' then raise exception 'Race is not active'; end if;
  select * into v from race_private.visits where id=p_visit for update;
  if p_revision is null or v.revision <> p_revision then raise exception 'Stale visit; refresh before retrying' using errcode='40001'; end if;
  if v.dispositioned_at is not null then raise exception 'Visit already dispositioned'; end if;
  select * into held from race_private.bed_reservations where visit_id=p_visit;
  if p_action='assigned' then
    if exists(select 1 from race_private.bed_reservations where bed_id=p_bed and visit_id<>p_visit) then raise exception 'Bed reserved for another patient'; end if;
    select p.kind into destination_kind from race_private.beds b join race_private.pods p on p.id=b.pod_id where b.id=p_bed and b.race_id=race;
    select * into previous from race_private.placements where visit_id=p_visit and ended_at is null;
    if previous.kind='regular' and destination_kind='pool' then
      stamp := clock_timestamp();
      insert into race_private.bed_reservations(race_id,visit_id,bed_id,started_at) values(race,p_visit,previous.bed_id,stamp);
      -- End physical occupancy, but skip turnover while the bed is held.
      update race_private.placements set ended_at=stamp where id=previous.id;
    end if;
  end if;
  result := race_private.transition_visit_without_reservation(p_visit,p_revision,p_action,p_bed,p_category,p_other);
  if held.visit_id is not null and (p_action='dispositioned' or (p_action='assigned' and destination_kind='regular')) then
    delete from race_private.bed_reservations where visit_id=p_visit;
    if p_action='dispositioned' or held.bed_id<>p_bed then
      stamp := clock_timestamp();
      update race_private.beds set cleaning=true where id=held.bed_id;
      insert into race_private.turnovers(race_id,bed_id,started_at) values(race,held.bed_id,stamp);
    end if;
  end if;
  return result;
end $$;

-- public.race_team
create or replace function public.race_team(p_race uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
 return (select jsonb_agg(jsonb_build_object('id',t.user_id,'email',u.email,'role',t.role) order by t.role,u.email)
 from (select r.owner_id user_id,'owner'::text role from race_private.races r where r.id=p_race
 union all select m.user_id,m.role from race_private.memberships m join race_private.races r on r.id=m.race_id where m.race_id=p_race and m.user_id<>r.owner_id) t
 join auth.users u on u.id=t.user_id);
end $$;

-- public.set_race_member
create or replace function public.set_race_member(p_race uuid,p_email text,p_expected_role text,p_role text) returns void
language plpgsql security definer set search_path='' as $$
declare owner_id uuid; target_id uuid; old_role text;
begin
 if coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
 select r.owner_id into owner_id from race_private.races r where r.id=p_race for update;
 if coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
 if p_role is not null and p_role not in ('admin','editor','viewer') then raise exception 'Invalid role'; end if;
 if p_expected_role is not null and p_expected_role not in ('admin','editor','viewer') then raise exception 'Invalid expected role'; end if;
 if p_email is null or length(trim(p_email)) not between 3 and 320 then raise exception 'Invalid email'; end if;
 select u.id into target_id from auth.users u where lower(u.email)=lower(trim(p_email));
 if target_id is null then raise exception 'Account not found' using errcode='P0002'; end if;
 if target_id=owner_id then raise exception 'Owner access cannot be changed'; end if;
 select m.role into old_role from race_private.memberships m where m.race_id=p_race and m.user_id=target_id;
 if race_private.access_level(p_race) <> 'owner' and (old_role='admin' or p_role='admin') then raise exception 'Only the Owner can manage Admin access' using errcode='42501'; end if;
 if old_role is distinct from p_expected_role then raise exception 'Membership changed. Refresh and review again.' using errcode='40001'; end if;
 if old_role is not distinct from p_role then return; end if;
 if p_role is null then delete from race_private.memberships where race_id=p_race and user_id=target_id;
 else insert into race_private.memberships(race_id,user_id,role) values(p_race,target_id,p_role)
 on conflict(race_id,user_id) do update set role=excluded.role; end if;
 insert into race_private.team_events(race_id,actor_id,user_id,old_role,new_role) values(p_race,auth.uid(),target_id,old_role,p_role);
end $$;

-- public.create_race_invitation
create or replace function public.create_race_invitation(p_race uuid,p_email text,p_role text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_owner uuid; v_id uuid; v_email text:=lower(trim(p_email));
begin
 select owner_id into v_owner from race_private.races where id=p_race for update;
 if auth.uid() is null or coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
 if p_role is null or p_role not in ('editor','viewer') then raise exception 'Invalid role'; end if;
 if v_email is null or length(v_email) not between 3 and 320 or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid email'; end if;
 if exists(select 1 from auth.users u where lower(u.email)=v_email and (u.id=v_owner or exists(select 1 from race_private.memberships m where m.race_id=p_race and m.user_id=u.id))) then raise exception 'Account already has access'; end if;
 update race_private.invitations set closed_at=clock_timestamp() where race_id=p_race and email=v_email and closed_at is null and expires_at<=clock_timestamp();
 insert into race_private.invitations(race_id,email,role,created_by) values(p_race,v_email,p_role,auth.uid()) returning id into v_id;
 return v_id;
end $$;

-- public.cancel_race_invitation
create or replace function public.cancel_race_invitation(p_race uuid,p_invitation uuid) returns void
language plpgsql security definer set search_path='' as $$
declare v_owner uuid;
begin
 select owner_id into v_owner from race_private.races where id=p_race for update;
 if auth.uid() is null or coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
 update race_private.invitations set closed_at=clock_timestamp() where id=p_invitation and race_id=p_race and closed_at is null;
 if not found then raise exception 'Invitation changed. Refresh.' using errcode='40001'; end if;
end $$;

-- public.claim_invitation_email
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

-- public.race_invitations
create or replace function public.race_invitations(p_race uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'email',i.email,'role',i.role,'expires_at',i.expires_at,'email_attempted_at',i.email_attempted_at) order by i.created_at)
 from race_private.invitations i where i.race_id=p_race and i.closed_at is null),'[]'::jsonb);
end $$;

-- public.rename_race
create or replace function public.rename_race(p_race uuid,p_expected_name text,p_name text)
returns void language plpgsql security definer set search_path='' as $$
declare current_name text;
begin
  select name into current_name from race_private.races where id=p_race and race_private.access_level(p_race) in ('owner','admin') for update;
  if not found then raise exception 'Access denied' using errcode='42501'; end if;
  if p_name is null or length(trim(p_name)) not between 1 and 200 then raise exception 'Invalid race name'; end if;
  if current_name=trim(p_name) then return; end if;
  if current_name is distinct from p_expected_name then raise exception 'Race changed; refresh before retrying' using errcode='40001'; end if;
  update race_private.races set name=trim(p_name) where id=p_race;
end $$;

-- public.edit_pod_settings
create or replace function public.edit_pod_settings(p_pod uuid,p_expected jsonb,p_name text,p_color text,p_kind text,p_beds integer,p_closed boolean,p_capabilities jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare race uuid; current_pod race_private.pods; old_count integer; removed uuid[]; ordered uuid[]; prefix text;
begin
  select race_id into race from race_private.pods where id=p_pod;
  if coalesce(race_private.access_level(race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
  perform 1 from race_private.races where id=race for update;
  if coalesce(race_private.access_level(race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
  if not exists(select 1 from race_private.races where id=race and state='active') then raise exception 'Race is not active'; end if;
  select * into current_pod from race_private.pods where id=p_pod;
  select count(*) into old_count from race_private.beds where pod_id=p_pod;
  if p_expected is distinct from jsonb_build_object('name',current_pod.name,'color',current_pod.color,'kind',current_pod.kind,'beds',old_count,'closed',current_pod.closed,'capabilities',current_pod.capabilities) then
    raise exception 'Pod changed; refresh before retrying' using errcode='40001';
  end if;
  p_name := trim(p_name);
  if p_name is null or length(p_name) not between 1 and 80 or coalesce(p_color,'') !~ '^#[0-9a-fA-F]{6}$'
    or coalesce(p_kind,'') not in ('regular','pool') or p_beds is null or p_beds not between 1 and 20 then raise exception 'Invalid pod settings'; end if;
  if p_kind <> current_pod.kind and (exists(select 1 from race_private.placements x join race_private.beds b on b.id=x.bed_id where b.pod_id=p_pod and x.ended_at is null)
    or exists(select 1 from race_private.bed_reservations x join race_private.beds b on b.id=x.bed_id where b.pod_id=p_pod)) then
    raise exception 'Cannot change type while occupied or reserved';
  end if;
  -- Reuse existing validation and owner/state protections for capabilities and closure.
  perform public.update_pod(p_pod,jsonb_build_object('name',current_pod.name,'closed',current_pod.closed,'capabilities',current_pod.capabilities),p_closed,p_capabilities);
  if p_beds < old_count then
    select array_agg(id) into removed from (select id from race_private.beds where pod_id=p_pod
      order by substring(label from '([0-9]+)$')::numeric nulls last,label,id offset p_beds) x;
    if exists(select 1 from race_private.placements where bed_id=any(removed))
      or exists(select 1 from race_private.events where bed_id=any(removed))
      or exists(select 1 from race_private.turnovers where bed_id=any(removed))
      or exists(select 1 from race_private.bed_reservations where bed_id=any(removed))
      or exists(select 1 from race_private.beds where id=any(removed) and cleaning) then
      raise exception 'Cannot remove used or reserved beds';
    end if;
    delete from race_private.beds where id=any(removed);
  end if;
  update race_private.pods set name=p_name,color=lower(p_color),kind=p_kind where id=p_pod;
  -- Keep bed IDs and all placements; only display labels change when renamed.
  prefix := case when p_kind='regular' and p_name ~* '^(pod[[:space:]]+)?[0-9]+$' then substring(p_name from '([0-9]+)$') else p_name end;
  if p_name <> current_pod.name then
    select array_agg(id order by substring(label from '([0-9]+)$')::numeric nulls last,label,id) into ordered from race_private.beds where pod_id=p_pod;
    update race_private.beds set label=id::text where pod_id=p_pod;
    update race_private.beds b set label=prefix||'-'||n.n from unnest(ordered) with ordinality n(id,n) where b.id=n.id;
  end if;
  if p_beds > old_count then
    insert into race_private.beds(race_id,pod_id,label) select race,p_pod,prefix||'-'||n from generate_series(old_count+1,p_beds) n;
  end if;
exception when unique_violation then raise exception 'Pod name or number already exists';
end $$;

-- public.delete_pod
create or replace function public.delete_pod(p_pod uuid,p_expected jsonb,p_confirm text) returns void
language plpgsql security definer set search_path='' as $$
declare race uuid; current_pod race_private.pods; bed_ids uuid[];
begin
  select race_id into race from race_private.pods where id=p_pod;
  if coalesce(race_private.access_level(race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
  perform 1 from race_private.races where id=race for update;
  if coalesce(race_private.access_level(race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
  if not exists(select 1 from race_private.races where id=race and state='active') then raise exception 'Race is not active'; end if;
  select * into current_pod from race_private.pods where id=p_pod;
  if not found then raise exception 'Pod changed; refresh before retrying'; end if;
  if p_confirm is distinct from current_pod.name then raise exception 'Type the pod name to confirm'; end if;
  if p_expected is distinct from jsonb_build_object('name',current_pod.name,'color',current_pod.color,'kind',current_pod.kind,'closed',current_pod.closed,'capabilities',current_pod.capabilities,'beds',(select count(*) from race_private.beds where pod_id=p_pod)) then
    raise exception 'Pod changed; refresh before retrying' using errcode='40001';
  end if;
  select array_agg(id) into bed_ids from race_private.beds where pod_id=p_pod;
  if exists(select 1 from race_private.placements where bed_id=any(bed_ids) and ended_at is null)
    or exists(select 1 from race_private.bed_reservations where bed_id=any(bed_ids)) then
    raise exception 'Move or disposition assigned patients and release reserved beds before deleting this pod';
  end if;
  update race_private.placements x set removed_bed_label=b.label,removed_pod_name=current_pod.name,bed_id=null from race_private.beds b where x.bed_id=b.id and b.pod_id=p_pod;
  update race_private.turnovers x set removed_bed_label=b.label,removed_pod_name=current_pod.name,bed_id=null,ended_at=coalesce(x.ended_at,clock_timestamp()) from race_private.beds b where x.bed_id=b.id and b.pod_id=p_pod;
  update race_private.events x set removed_bed_label=b.label,removed_pod_name=current_pod.name,bed_id=null from race_private.beds b where x.bed_id=b.id and b.pod_id=p_pod;
  delete from race_private.beds where pod_id=p_pod;
  delete from race_private.pods where id=p_pod;
end $$;

-- public.race_complaints
create or replace function public.race_complaints(p_race uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if coalesce(race_private.access_level(p_race),'') not in ('owner','admin','editor') then raise exception 'Access denied' using errcode='42501'; end if;
  return coalesce((select options from race_private.complaint_lists where race_id=p_race),
    (select jsonb_agg(jsonb_build_object('label',label,'enabled',true) order by label) from unnest(array['Abd Pain','Abrasions','Arm Pain/Inj','Back Pain','Bleeding','Chest Pain','Dif. Breathing','Dizziness','Foot Pain/Inj','Gen. Weakness','Hand Pain/Inj','Head Pain','Heat Exhaustion','Inj/Fall','Knee Pain/Inj','Laceration','Leg Pain/Inj','Nausea/Vomiting','Near Syncope','Syncope','Unconscious']) label));
end $$;

-- public.save_race_complaints
create or replace function public.save_race_complaints(p_race uuid,p_expected jsonb,p_options jsonb) returns void
language plpgsql security definer set search_path='' as $$
begin
  perform 1 from race_private.races where id=p_race and race_private.access_level(p_race) in ('owner','admin') and state='active' for update;
  if not found then raise exception 'Access denied or race closed' using errcode='42501'; end if;
  if p_expected is distinct from public.race_complaints(p_race) then raise exception 'Complaint list changed; reopen and review' using errcode='40001'; end if;
  if jsonb_typeof(p_options) is distinct from 'array' then raise exception 'Invalid complaint list'; end if;
  if jsonb_array_length(p_options)>100 then raise exception 'Maximum 100 complaints'; end if;
  if exists(select 1 from jsonb_array_elements(p_options) x where jsonb_typeof(x) is distinct from 'object'
    or jsonb_typeof(x->'label') is distinct from 'string' or length(trim(x->>'label')) not between 1 and 80
    or lower(trim(x->>'label'))='other' or jsonb_typeof(x->'enabled') is distinct from 'boolean'
    or (x - 'label' - 'enabled') <> '{}'::jsonb) then raise exception 'Invalid complaint list'; end if;
  if (select count(*) from jsonb_array_elements(p_options)) <> (select count(distinct lower(trim(x->>'label'))) from jsonb_array_elements(p_options) x) then raise exception 'Duplicate complaint'; end if;
  insert into race_private.complaint_lists values(p_race,p_options) on conflict(race_id) do update set options=excluded.options;
end $$;

-- public.save_patient
create or replace function public.save_patient(p_race uuid,p_visit uuid,p_revision integer,p_details jsonb,p_bed uuid default null)
returns integer language plpgsql security definer set search_path='' as $$
declare duplicate_id uuid; planned uuid; result integer;
begin
  if coalesce(race_private.access_level(p_race),'') not in ('owner','admin','editor') then raise exception 'Access denied' using errcode='42501'; end if;
  perform 1 from race_private.races where id=p_race for update;
  if coalesce(race_private.access_level(p_race),'') not in ('owner','admin','editor') then raise exception 'Access denied' using errcode='42501'; end if;
  -- The race lock serializes intake and edits across devices. Discharged visits may return.
  select d.visit_id into duplicate_id from race_private.visit_details d
    join race_private.visits v on v.id=d.visit_id
    where d.race_id=p_race and v.dispositioned_at is null and d.visit_id<>p_visit
      and lower(trim(d.bib))=lower(trim(p_details->>'bib')) limit 1;
  if duplicate_id is not null then
    raise exception 'An active patient already has this race number' using errcode='P0002',detail=duplicate_id::text;
  end if;
  if p_details ? 'planned_pod_id' then
    planned := nullif(p_details->>'planned_pod_id','')::uuid;
    if planned is not null and (p_bed is not null or exists(select 1 from race_private.placements where visit_id=p_visit and ended_at is null)) then
      raise exception 'Preassignment is only available for Incoming patients';
    end if;
    if planned is not null and not exists(select 1 from race_private.pods where id=planned and race_id=p_race and not closed and kind='regular') then
      raise exception 'Preassigned pod is unavailable';
    end if;
  end if;
  result := race_private.save_patient_base(p_race,p_visit,p_revision,p_details,p_bed);
  if p_details ? 'planned_pod_id' then
    update race_private.visit_details set planned_pod_id=planned where visit_id=p_visit;
  end if;
  return result;
end $$;

-- public.race_access_requests
create or replace function public.race_access_requests(p_race uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id',a.user_id,'email',u.email,'requested_at',a.requested_at) order by a.requested_at)
    from race_private.access_requests a join auth.users u on u.id=a.user_id where a.race_id=p_race),'[]'::jsonb);
end $$;

-- public.review_race_access
create or replace function public.review_race_access(p_race uuid,p_user uuid,p_requested_at timestamptz,p_approve boolean) returns void
language plpgsql security definer set search_path='' as $$
declare requested timestamptz; target_email text;
begin
  if coalesce(race_private.access_level(p_race),'') not in ('owner','admin') then raise exception 'Access denied' using errcode='42501'; end if;
  perform 1 from race_private.races where id=p_race and race_private.access_level(p_race) in ('owner','admin') and state='active' and not archived for update;
  if not found then raise exception 'Race unavailable'; end if;
  select requested_at into requested from race_private.access_requests where race_id=p_race and user_id=p_user for update;
  if requested is null or requested is distinct from p_requested_at then raise exception 'Request changed. Refresh.' using errcode='40001'; end if;
  if p_approve is null then raise exception 'Decision required'; end if;
  if p_approve and race_private.access_level(p_race) in ('owner','admin') then
    select email into target_email from auth.users where id=p_user and email_confirmed_at is not null;
    if target_email is null then raise exception 'Verified account required'; end if;
    if not exists(select 1 from race_private.memberships where race_id=p_race and user_id=p_user)
      and not exists(select 1 from race_private.races where id=p_race and owner_id=p_user) then
      perform public.set_race_member(p_race,target_email,null,'viewer');
    end if;
  end if;
  delete from race_private.access_requests where race_id=p_race and user_id=p_user;
end $$;

alter policy visit_read on race_private.visits using (race_private.access_level(race_id) in ('owner','admin','editor'));
alter policy details_read on race_private.visit_details using (race_private.access_level(race_id) in ('owner','admin','editor'));
alter policy placement_read on race_private.placements using (race_private.access_level(race_id) in ('owner','admin','editor'));
alter policy turnover_read on race_private.turnovers using (race_private.access_level(race_id) in ('owner','admin','editor'));
alter policy membership_read on race_private.memberships using (race_private.access_level(race_id) in ('owner','admin') or user_id=auth.uid());
commit;
