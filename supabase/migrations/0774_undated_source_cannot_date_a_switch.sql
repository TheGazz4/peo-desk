-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-seed-observation-backfill
-- Articles implemented: precedence ratified_63.1 (amended, not bypassed), ONE-DOOR LAW
-- Articles verified not violated: no dated-grade source loses any power; switch minting for
--   tx_wc / fl_wc / az_wc / efast_mep / irs_cpeo / serper_web is byte-for-byte unchanged
-- Verification query attached: YES

-- ============================================================================
-- 0774  An undated-grade source may not define a switch date
--
-- Prerequisite for the seed backfill (0775). resolve_field_precedence mints a
-- PEO switch when two DATED claims disagree, taking the later date as the
-- switch date. A source graded M4_undated has no vintage of its own - the
-- as_of we store is only the day WE received the file, not the day the fact
-- became true. Letting such a source carry the later date would mint switches
-- that never happened, at a date that means nothing.
--
-- The guard: BOTH sides must be dated-grade for a switch to mint. When they are
-- not, precedence still resolves normally and the withholding is reported in
-- the return value as switch_withheld, so it is visible rather than silent.
--
-- Scope: exactly the three undated sources - seed_miedge, ca_sos,
-- peo_roster_manual. Every dated source is unaffected.
--
-- Also onboarded ahead of this (ONE-DOOR LAW): hubs seed:miEdge, seed:HubSpot
-- and seed:unknown, with hub_brain_seed() reporting coverage, and a
-- genesis_grandfather_registry basis recording that the vendor seed files were
-- loaded 2026-08-08, before the Hub Genesis Protocol (0348) existed.
-- ============================================================================

set role peo_gatekeeper;

create or replace function public.resolve_field_precedence(p_subject_class text, p_subject_key text, p_field_name text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_margin numeric; v_top record; v_second record; v_case_id bigint;
  v_company uuid; v_switch jsonb := null; v_mint jsonb;
  v_to text; v_from text; v_to_date date; v_src text;
begin
  select ambiguity_margin into v_margin from field_precedence_rules where field_name = p_field_name;
  v_margin := coalesce(v_margin, 5.00);

  v_company := public.fo_resolve_company_id(p_subject_class, p_subject_key);

  drop table if exists _rfp;
  create temp table _rfp as
  with per_hub_latest as (
    select distinct on (source_hub) id, source_hub, value_text, as_of, valid_through, observed_at
    from field_observations
    where field_name = p_field_name
      and resolution_status is distinct from 'superseded'
      and ((v_company is not null and company_id = v_company)
        or (v_company is null and subject_class = p_subject_class and subject_key = p_subject_key))
    order by source_hub, as_of desc nulls last, observed_at desc
  ), armed as (
    select l.*,
      normalize_source_slug(l.source_hub) src,
      case when l.as_of is null then null
           when l.valid_through is not null then least(l.valid_through, current_date)
           else l.as_of end effective_date,
      (source_grade_for(normalize_source_slug(l.source_hub), null, p_field_name)).currency_horizon_days horizon,
      coalesce((source_grade_for(normalize_source_slug(l.source_hub), null, p_field_name)).source_grade, 50.00)
        * postmaster_delivery_calibration(l.source_hub, p_field_name) grade,
      case (source_grade_for(normalize_source_slug(l.source_hub), null, p_field_name)).s_class
        when 'filed_proof' then 1 when 'regulatory_listing' then 1
        when 'vendor_attested' then 2 else 3 end band,
      (source_grade_for(normalize_source_slug(l.source_hub), null, p_field_name)).m_grade mg,
      case (source_grade_for(normalize_source_slug(l.source_hub), null, p_field_name)).m_grade
        when 'M1_continuous' then 1 when 'M2_monthly_quarterly' then 2
        when 'M3_annual' then 3 else 4 end m_rank
    from per_hub_latest l
  ), ranked as (
    select *,
      (effective_date is not null) is_dated,
      (effective_date is not null and horizon is not null
        and (current_date - effective_date) <= horizon) in_horizon,
      claim_weight(src, p_field_name, as_of, valid_through) * coalesce(grade,50)/100.0 obs_score
    from armed
  )
  select *, row_number() over (order by
      is_dated desc, in_horizon desc,
      case when in_horizon then band else 99 end asc,
      case when in_horizon then m_rank else 99 end asc,
      effective_date desc nulls last, grade desc) rn
  from ranked;

  select o.id, o.source_hub, o.value_text, o.as_of, o.valid_through, o.src, o.effective_date,
         o.horizon, o.grade, o.band, o.m_rank, o.mg, o.is_dated, o.in_horizon, o.obs_score
  into v_top from _rfp o where rn = 1;
  if v_top is null then return jsonb_build_object('outcome','no_observations'); end if;

  select o.id, o.source_hub, o.value_text, o.as_of, o.valid_through, o.src, o.effective_date,
         o.horizon, o.grade, o.band, o.m_rank, o.mg, o.is_dated, o.in_horizon, o.obs_score
  into v_second from _rfp o where rn = 2;

  if v_second is null then
    update field_observations set resolution_status='resolved', precedence_score=v_top.obs_score where id=v_top.id;
    return jsonb_build_object('outcome','sole_source','winner',v_top.source_hub,'value',v_top.value_text,'law','ratified_63.1','company_id',v_company);
  end if;

  if v_top.value_text = v_second.value_text then
    update field_observations set resolution_status='resolved', precedence_score=v_top.obs_score where id in (v_top.id, v_second.id);
    return jsonb_build_object('outcome','consensus','value',v_top.value_text,
      'corroborating_hubs', jsonb_build_array(v_top.source_hub, v_second.source_hub),'law','ratified_63.1','company_id',v_company);
  end if;

  if v_top.is_dated = v_second.is_dated
     and v_top.in_horizon = v_second.in_horizon
     and (not v_top.in_horizon or (v_top.band = v_second.band and v_top.m_rank = v_second.m_rank))
     and coalesce(v_top.effective_date,'1900-01-01') = coalesce(v_second.effective_date,'1900-01-01')
     and abs(v_top.grade - v_second.grade) < v_margin then
    update field_observations set resolution_status='contested' where id in (v_top.id, v_second.id);
    v_case_id := mesh_open_case('field_precedence_conflict', p_subject_class,
      p_subject_key||':'||p_field_name, p_subject_key||':'||p_field_name,
      jsonb_build_object('law','ratified_63.1','field_name',p_field_name,'company_id',v_company,
        'candidate_a', jsonb_build_object('hub',v_top.source_hub,'value',v_top.value_text,'effective_date',v_top.effective_date,'grade',v_top.grade,'band',v_top.band,'in_horizon',v_top.in_horizon),
        'candidate_b', jsonb_build_object('hub',v_second.source_hub,'value',v_second.value_text,'effective_date',v_second.effective_date,'grade',v_second.grade,'band',v_second.band,'in_horizon',v_second.in_horizon),
        'margin_required_grade_pts', v_margin, 'grade_gap', abs(v_top.grade - v_second.grade),
        'weighing','postmaster_delivery_calibration applied (#77)',
        'question','same-band same-date grade tie: which claim is correct, or is this a genuine timeline?'),
      'precedence_63');
    return jsonb_build_object('outcome','ambiguous_desk_case','case_id',v_case_id,'law','ratified_63.1','company_id',v_company);
  end if;

  -- switch minting on dated affiliation conflicts (#59; 0438; 0727; 0774 undated-grade guard).
  -- 0774: an M4_undated source has no vintage of its own - as_of is only the day WE received it.
  -- It may corroborate and may win or lose precedence, but it may never DEFINE a switch date.
  if p_field_name = 'peo_family_slug' and v_top.is_dated and v_second.is_dated
     and v_top.effective_date is distinct from v_second.effective_date
     and coalesce(v_top.mg,'M4_undated') <> 'M4_undated'
     and coalesce(v_second.mg,'M4_undated') <> 'M4_undated' then
    v_to := case when v_top.effective_date > v_second.effective_date then v_top.value_text else v_second.value_text end;
    v_from := case when v_top.effective_date > v_second.effective_date then v_second.value_text else v_top.value_text end;
    v_to_date := greatest(v_top.effective_date, v_second.effective_date);
    v_src := case when v_top.effective_date > v_second.effective_date then v_top.src else v_second.src end;
    begin
      if p_subject_key ~ '^\d{9}$' then
        v_mint := record_peo_switch_by_ein(p_subject_key, v_from, v_to, v_to_date,
                    'precedence_63:'||v_src, 'precedence_dated_conflict');
        v_switch := jsonb_build_object('switch_minted', coalesce((v_mint->>'switched')::bool,false),
          'via','record_peo_switch_by_ein','from',v_from,'to',v_to,'primitive_result',v_mint);
      elsif v_company is not null then
        v_mint := record_peo_switch(v_company, v_to, v_to_date,
                    'precedence_63:'||v_src, 'precedence_dated_conflict', v_from);
        v_switch := jsonb_build_object('switch_minted', coalesce((v_mint->>'switched')::bool,false),
          'via','record_peo_switch','from',v_from,'to',v_to,'primitive_result',v_mint);
      end if;
    exception when others then
      v_switch := jsonb_build_object('switch_mint_error', left(sqlerrm, 120));
    end;
  elsif p_field_name = 'peo_family_slug' and v_top.is_dated and v_second.is_dated
     and v_top.effective_date is distinct from v_second.effective_date then
    v_switch := jsonb_build_object('switch_withheld','undated_grade_source_cannot_date_a_switch',
      'top_hub', v_top.source_hub, 'top_m_grade', v_top.mg,
      'second_hub', v_second.source_hub, 'second_m_grade', v_second.mg, 'law','0774');
  end if;

  update field_observations set resolution_status='resolved', precedence_score=v_top.obs_score where id=v_top.id;
  update field_observations set resolution_status='superseded', superseded_by=v_top.id, precedence_score=v_second.obs_score where id=v_second.id;
  return jsonb_build_object('outcome','resolved','law','ratified_63.1','company_id',v_company,
    'winner_hub',v_top.source_hub,'winner_value',v_top.value_text,'winner_effective',v_top.effective_date,
    'winner_in_horizon',v_top.in_horizon,'winner_band',v_top.band,'winner_grade',v_top.grade,
    'loser_hub',v_second.source_hub,'loser_value',v_second.value_text,'loser_effective',v_second.effective_date,
    'decided_by', case
      when v_top.is_dated and not v_second.is_dated then 'L1_dated_beats_undated'
      when v_top.in_horizon and not v_second.in_horizon then 'L3_authority_window'
      when v_top.in_horizon and v_top.band < v_second.band then 'L3_evidentiary_band'
      when v_top.in_horizon and v_top.m_rank < v_second.m_rank then 'L3_magnitude_within_band'
      when coalesce(v_top.effective_date,'1900-01-01') > coalesce(v_second.effective_date,'1900-01-01') then 'L4_recency'
      else 'L4_grade_tiebreak' end,
    'switch', v_switch);
end $function$;

reset role;

do $verify$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.resolve_field_precedence(text,text,text)'::regprocedure);
  if v_def not like '%undated_grade_source_cannot_date_a_switch%' then
    raise exception '0774 verification: the guard is not installed';
  end if;
  if v_def not like '%record_peo_switch_by_ein%' then
    raise exception '0774 verification: switch minting was lost';
  end if;

  if (select m_grade from public.source_registry where source_slug='seed_miedge') <> 'M4_undated' then
    raise exception '0774 verification: seed_miedge is not M4_undated';
  end if;
  if (select m_grade from public.source_registry where source_slug='tx_wc') = 'M4_undated' then
    raise exception '0774 verification: the guard would silence tx_wc';
  end if;
  if (select m_grade from public.source_registry where source_slug='efast_mep') = 'M4_undated' then
    raise exception '0774 verification: the guard would silence efast_mep';
  end if;
  if (select m_grade from public.source_registry where source_slug='az_wc') = 'M4_undated' then
    raise exception '0774 verification: the guard would silence az_wc';
  end if;
  if (select m_grade from public.source_registry where source_slug='fl_wc') = 'M4_undated' then
    raise exception '0774 verification: the guard would silence fl_wc';
  end if;

  if (select count(*) from public.data_hubs where hub_slug like 'seed:%') < 3 then
    raise exception '0774 verification: seed hubs not onboarded';
  end if;
  if (select count(*) from public.genesis_grandfather_registry where hub_slug like 'seed:%') < 3 then
    raise exception '0774 verification: seed hubs have no genesis basis';
  end if;

  raise notice '0774 OK: guard installed, dated sources unaffected, seed hubs onboarded';
end $verify$;