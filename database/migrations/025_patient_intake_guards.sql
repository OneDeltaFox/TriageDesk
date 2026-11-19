begin;

alter table race_private.visit_details add column planned_pod_id uuid references race_private.pods(id) on delete set null;

alter function public.save_patient(uuid,uuid,integer,jsonb,uuid) rename to save_patient_base;
alter function public.save_patient_base(uuid,uuid,integer,jsonb,uuid) set schema race_private;
revoke all on function race_private.save_patient_base(uuid,uuid,integer,jsonb,uuid) from public,anon,authenticated;

create function public.save_patient(p_race uuid,p_visit uuid,p_revision integer,p_details jsonb,p_bed uuid default null)
returns integer language plpgsql security definer set search_path='' as $$
declare duplicate_id uuid; planned uuid; result integer;
begin
  if coalesce(race_private.access_level(p_race),'') not in ('owner','editor') then raise exception 'Access denied' using errcode='42501'; end if;
  perform 1 from race_private.races where id=p_race for update;
  if coalesce(race_private.access_level(p_race),'') not in ('owner','editor') then raise exception 'Access denied' using errcode='42501'; end if;
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

-- Placement and disposition end the Incoming plan; neither changes medical timing rules.
create function race_private.clear_patient_plan() returns trigger language plpgsql set search_path='' as $$
begin
  if new.medical_started_at is not null or new.dispositioned_at is not null then
    update race_private.visit_details set planned_pod_id=null where visit_id=new.id;
  end if;
  return new;
end $$;
create trigger clear_patient_plan after update of medical_started_at,dispositioned_at on race_private.visits
  for each row execute function race_private.clear_patient_plan();
revoke all on function public.save_patient(uuid,uuid,integer,jsonb,uuid) from public,anon;
grant execute on function public.save_patient(uuid,uuid,integer,jsonb,uuid) to authenticated;
commit;
