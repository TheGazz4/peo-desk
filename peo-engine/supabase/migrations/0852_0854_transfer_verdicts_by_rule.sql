-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0852-auto-verdicts
-- Articles implemented: VIII.2 (only resolved events reach a client; a client carries only what happened to ITS PEO),
--   XIV.4 (signal carried to the surface without a human bottleneck), IX.2 (one dated fact per client per year)
-- Articles verified not violated: III.1 (tier 1 is rule-only, zero spend), XIV.6
-- Verification query attached: YES
--
-- Consolidated file for three migrations applied 2026-09-11 (0852, 0853, 0854). Final state of each object below.
--
-- 0852: auto_resolve_ein_transfers() - TIER 1 rules. Human rulings (researched_by gazz%) never overwritten.
--       D cases >= 500 employers are HELD (source_alert) instead of auto-resolved.
-- 0853: push_ein_transfers_to_lifecycle() - one event per (client, PEO, year); pension+welfare duplicates fold.
-- 0854: push + play cohort target the PRIOR sponsor's clients only (acquirer's own clients never told
--       "X was folded into you"). Mis-targeted rows deleted under a logged fence lift
--       (noncompete_fence_lift_log: company_lifecycle_events). Narrative: same-name restructure reads
--       "re-registered under a new tax ID".
-- Run result 2026-09-11: dismissed 192, not_a_peo 4137, restructure_same_owner 14, absorbed 1 (StaffLink->Prestige),
--   brand_retained 1 (CBR under Resourcing Edge), held 0, still ambiguous 7.

create or replace function public.auto_resolve_ein_transfers(p_hold_threshold integer default 500)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $function$
declare r record; n_dismiss int:=0; n_notpeo int:=0; n_restr int:=0; n_abs int:=0; n_brand int:=0; n_hold int:=0; n_left int:=0;
        v_res text; v_rule text; v_prior_prof text; v_new_prof text; v_ov numeric; v_plan_prior numeric; v_plan_new numeric;
begin
  for r in select * from public.peo_ein_transfer_events
            where resolution = 'pending_research' and coalesce(researched_by,'') not ilike 'gazz%'
  loop
    v_res := null; v_rule := null;
    select family_slug into v_prior_prof from public.peo_profiles where sponsor_eins ? r.prior_ein limit 1;
    select family_slug into v_new_prof   from public.peo_profiles where sponsor_eins ? r.new_ein   limit 1;
    v_ov := public.name_token_overlap(r.prior_name, r.new_name);

    if public.ein_is_administrator(r.prior_ein) or public.ein_is_administrator(r.new_ein) then
      v_res := 'dismissed'; v_rule := 'A_admin_ein: one side is a TPA/administrator EIN (paperwork firm), not a sponsor change';
    elsif v_prior_prof is null and v_new_prof is null then
      v_res := 'not_a_peo'; v_rule := 'B_not_our_book: neither EIN belongs to a tracked PEO';
    elsif v_prior_prof is not null and v_prior_prof = v_new_prof then
      v_res := 'restructure_same_owner'; v_rule := 'C_same_profile: both EINs already keyed to '||v_prior_prof;
    elsif v_prior_prof is not null and v_new_prof is not null then
      v_plan_prior := public.name_token_overlap(r.plan_name, r.prior_name);
      v_plan_new   := public.name_token_overlap(r.plan_name, r.new_name);
      if r.employers >= p_hold_threshold then
        v_rule := 'HOLD'; n_hold := n_hold + 1;
        insert into public.source_alerts(source_name, change_summary)
        values ('peo_ein_transfer_events',
                'HELD transfer #'||r.id||' '||r.prior_name||' -> '||r.new_name||' ('||r.employers||' employers): human review before push');
      elsif v_plan_new > v_plan_prior then
        v_res := 'absorbed'; v_rule := 'D_plan_renamed: plan now carries the new sponsor''s brand ('||v_prior_prof||' -> '||v_new_prof||')';
      elsif v_plan_prior > v_plan_new then
        v_res := 'brand_retained'; v_rule := 'D_plan_kept_brand: plan still carries the prior brand ('||v_prior_prof||' under '||v_new_prof||')';
      end if;
    elsif r.same_name or v_ov >= 0.6 then
      v_res := 'restructure_same_owner'; v_rule := 'E_same_name: '||round(v_ov,2)||' name overlap, one side unprofiled';
    end if;

    if v_res is not null then
      update public.peo_ein_transfer_events
         set resolution = v_res, research_status = 'researched',
             researched_by = 'auto_rule', researched_at = now(), finding = v_rule
       where id = r.id;
      case v_res when 'dismissed' then n_dismiss := n_dismiss+1; when 'not_a_peo' then n_notpeo := n_notpeo+1;
                 when 'restructure_same_owner' then n_restr := n_restr+1; when 'absorbed' then n_abs := n_abs+1;
                 when 'brand_retained' then n_brand := n_brand+1; else null; end case;
    elsif v_rule is null then
      n_left := n_left + 1;
    end if;
  end loop;
  return jsonb_build_object('dismissed',n_dismiss,'not_a_peo',n_notpeo,'restructure_same_owner',n_restr,
                            'absorbed',n_abs,'brand_retained',n_brand,'held_for_review',n_hold,'still_ambiguous',n_left);
end $function$;

set role peo_gatekeeper;
create or replace function public.push_ein_transfers_to_lifecycle()
returns integer language plpgsql security definer set search_path to 'public','pg_temp' as $function$
declare n int;
begin
  insert into public.company_lifecycle_events
    (company_id, source, event_type, peo_family_slug, window_start, window_end, precision, as_of, evidence)
  select distinct on (c.id, c.peo_family_slug, e.form_year)
         c.id, 'peo_ein_transfer_events', 'peo_entity_change', c.peo_family_slug,
         make_date(e.form_year,1,1), make_date(e.form_year,12,31), 'year', make_date(e.form_year,1,1),
         jsonb_build_object('transfer_event_id', e.id, 'from', e.prior_name, 'from_ein', e.prior_ein,
                            'to', e.new_name, 'to_ein', e.new_ein, 'kind', e.beacon_kind,
                            'resolution', e.resolution, 'finding', e.finding, 'researched_by', e.researched_by)
    from public.peo_ein_transfer_events e
    -- the PRIOR sponsor's profile is whose clients lived through the change
    join public.peo_profiles p on p.sponsor_eins ? e.prior_ein
    join public.companies c on c.peo_family_slug = p.family_slug and c.merged_into is null
   where e.research_status = 'researched'
     and e.resolution in ('brand_retained','absorbed','restructure_same_owner')
     and not public.company_is_noncompete(c)
     and not exists (select 1 from public.company_lifecycle_events x
                      where x.company_id = c.id and x.event_type = 'peo_entity_change'
                        and x.source = 'peo_ein_transfer_events' and x.peo_family_slug = c.peo_family_slug
                        and x.window_start = make_date(e.form_year,1,1))
   order by c.id, c.peo_family_slug, e.form_year, e.employers desc nulls last, e.id
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $function$;
reset role;

-- Play cohort: prior sponsor's clients only
update public.play_theses
   set cohort_sql = replace(cohort_sql,
       'join peo_profiles p on p.sponsor_eins ? e.new_ein or p.sponsor_eins ? e.prior_ein',
       'join peo_profiles p on p.sponsor_eins ? e.prior_ein')
 where thesis_slug = 'peo_entity_change';

-- company_lifecycle_narrative(): restructure_same_owner with identical names now reads
--   'Their PEO, <name>, re-registered under a new tax ID during YYYY; same name, same owner.'
-- (full body: see 0850 + this amendment in the live function)

select cron.unschedule('peo_ein_transfer_beacon_nightly');
select cron.schedule('peo_ein_transfer_beacon_nightly', '5 5 * * *',
  'select public.detect_ein_transfers(), public.auto_resolve_ein_transfers(), public.sync_ein_transfers_to_profiles(), public.push_ein_transfers_to_lifecycle(), public.push_rebrands_to_lifecycle()');

insert into public.brain_knowledge(scope, key, content) values ('doctrine','transfer_verdict_automation_law',
'Form 5500 line 4 beacons (peo_ein_transfer_events) are resolved in tiers. TIER 1 (auto_rule, zero spend, nightly): A) either EIN is a TPA/administrator EIN -> dismissed; B) neither EIN on a PEO profile -> not_a_peo; C) both EINs on the same profile -> restructure_same_owner; D) two different profiles -> plan name decides: renamed to new brand = absorbed, still old brand = brand_retained; E) same/near-same name (overlap >= 0.6) -> restructure_same_owner. HOLD: any D case with >= 500 employers is not auto-resolved; a source_alert asks for human review. TIER 2 (web check, capped spend) for what rules cannot settle - pending Gazz approval. TIER 3 (human): held cases and anything researched_by gazz% - never overwritten by rules. Only brand_retained/absorbed/restructure_same_owner ever reach a client lifecycle event or a play. Events land on the PRIOR sponsor''s clients only.')
on conflict (scope, key) do update set content = excluded.content;

select public.auto_resolve_ein_transfers();
select public.push_ein_transfers_to_lifecycle();
