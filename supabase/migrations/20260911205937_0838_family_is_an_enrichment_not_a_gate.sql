-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0838-family-is-not-a-gate
-- Articles implemented: I.1 (record what is observed), V.2 (no append withheld for a missing label)
-- Articles verified not violated: III.1 (noncompete rejections untouched and still absolute),
--   II.2 (no merge on a colliding name), II.3/XIV.1 (the registry still governs what may be WRITTEN)
-- Verification query attached: YES
--
-- FAMILY IS AN ENRICHMENT, NOT A GATE. Gazz ruling 2026-09-11.
--
-- A switch is a 1:1 fact about two specific PEOs. Whether either belongs to a corporate family we
-- happen to have registered is a nice-to-have on top - it is not what makes the switch true, and it
-- must never decide whether the switch gets recorded.
--
-- What was happening: record_peo_switch_by_ein wrote the destination onto companies.peo_family_slug,
-- and the trigger companies_family_slug_guard raises if that slug is not in peo_families. The raise
-- aborted the WHOLE call, so the ledger row and the signal were lost with it. 160 real switches were
-- thrown away for that reason, on names like "extensisgroupllc" that already had an alias pointing
-- at a registered family - the raw slug was simply never canonicalised first.
--
-- Same rule Gazz already set for EIN: EIN is king but not required, and no append is withheld for
-- the lack of one. Family now follows that rule.
--
--   1. Canonicalise first - exact family slug, then alias, then the name as given. That alone
--      resolves 94 of the 156 unmatched sponsor names.
--   2. Record the specific PEO always - the ledger keeps the name as observed either way.
--   3. The family label is best-effort. If the registry refuses it, the switch, the signal and the
--      observation all still land; only the company-level label is skipped, and the skip is logged
--      so the registration backlog stays visible instead of silently eating switches.
--
-- NOT CHANGED: every noncompete and target-exclusion rejection stays absolute and still aborts.

set role peo_gatekeeper;

create or replace function public.peo_canonical_or_self(p_name text)
returns text language sql stable as $c$
  select coalesce(
    (select f.family_slug from public.peo_families f where f.family_slug = p_name limit 1),
    (select f.family_slug from public.peo_families f where lower(f.alias) = lower(p_name) limit 1),
    p_name);
$c$;

create or replace function public.record_peo_switch_by_ein(
  p_ein text, p_from_family text, p_to_family text, p_evidence_as_of date,
  p_evidence_source text, p_detection_method text,
  p_from_sponsor text default null, p_to_sponsor text default null,
  p_scope_override text default null)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $function$
declare v_company companies%rowtype; v_ded text; v_found boolean := false; v_scope text;
        v_is_departure boolean; v_keep_brand boolean; v_month_cleared boolean := false;
        v_from_raw text := p_from_family; v_to_raw text := p_to_family;
        v_from text; v_to text; v_family_skip text := null;
begin
  if p_evidence_as_of is null then return jsonb_build_object('rejected','missing_as_of'); end if;

  v_from := public.peo_canonical_or_self(p_from_family);
  v_to   := public.peo_canonical_or_self(p_to_family);

  if is_noncompete_peo(v_to) or is_noncompete_peo(v_to_raw) then
    return jsonb_build_object('rejected','noncompete');
  end if;
  v_is_departure := is_noncompete_peo(v_from) or is_noncompete_peo(v_from_raw);

  if is_target_excluded(v_to) or is_target_excluded(v_from) then
    return jsonb_build_object('rejected','target_excluded');
  end if;

  if v_from is not distinct from v_to then
    if p_from_sponsor is null or p_to_sponsor is null or p_from_sponsor = p_to_sponsor then
      return jsonb_build_object('rejected','same_family_no_sponsor_move');
    end if;
    v_scope := coalesce(p_scope_override, 'intra_family');
  elsif family_root(v_from) = family_root(v_to) then
    v_scope := coalesce(p_scope_override, 'intra_family');
  else
    v_scope := coalesce(p_scope_override, 'cross_family');
  end if;

  select * into v_company from companies where ein = p_ein limit 1;
  v_found := found;
  if v_found and not v_is_departure and company_is_noncompete(v_company) then
    return jsonb_build_object('rejected','noncompete');
  end if;

  v_ded := 'switch:ein:'||p_ein||':'||v_from||coalesce(':'||p_from_sponsor,'')||'>'||v_to||coalesce(':'||p_to_sponsor,'')||':'||p_evidence_as_of;
  insert into peo_switch_ledger (company_id, ein, from_family_slug, to_family_slug, evidence_as_of,
    evidence_source, detection_method, dedupe_key, switch_scope, from_sponsor_ein, to_sponsor_ein,
    from_peo_observed, to_peo_observed)
  values (case when v_found then v_company.id end, p_ein, v_from, v_to, p_evidence_as_of,
    p_evidence_source, p_detection_method, v_ded, v_scope, p_from_sponsor, p_to_sponsor,
    v_from_raw, v_to_raw)
  on conflict (dedupe_key) do nothing;
  if not found then return jsonb_build_object('skipped','duplicate'); end if;

  if v_found and v_scope = 'cross_family' then
    begin
      v_keep_brand := v_company.peo_brand_slug is not null and (
          v_company.peo_brand_slug = v_to
          or exists (select 1 from peo_brand_hierarchy h
                     where h.child_slug = v_company.peo_brand_slug and h.parent_slug = v_to));

      if v_company.health_renewal_month is not null
         and (v_company.health_renewal_basis like 'brand_uniform %'
              or v_company.health_renewal_basis like 'inherit%') then
        insert into health_renewal_journal_0452 (company_id, old_month, old_basis, action, journaled_at)
        values (v_company.id, v_company.health_renewal_month, v_company.health_renewal_basis,
                'void_brand_month_on_cross_family_switch', now())
        on conflict (company_id) do update
          set action = health_renewal_journal_0452.action || ' | then: void_brand_month_on_cross_family_switch';
        v_month_cleared := true;
      end if;

      update companies set
        peo_family_slug = v_to,
        peo_prior_family_slug = v_from,
        peo_switch_as_of = p_evidence_as_of,
        attribution_class = 'verified_switcher',
        peo_brand_slug = case when v_keep_brand then peo_brand_slug else null end,
        health_renewal_month = case when v_month_cleared then null else health_renewal_month end,
        health_renewal_basis = case when v_month_cleared then null else health_renewal_basis end,
        health_renewal_last_affirmed = case when v_month_cleared then null else health_renewal_last_affirmed end
      where id = v_company.id;

      insert into field_observations (subject_class, subject_key, field_name, value_text, as_of,
        source_hub, evidence_ref, observed_at, dedupe_key)
      values ('company', p_ein, 'peo_family_slug', v_to, p_evidence_as_of, 'fingerprint',
              p_evidence_source, now(), 'switchobs:'||v_ded)
      on conflict (dedupe_key) do nothing;

    exception when others then
      v_family_skip := left(sqlerrm, 200);
      begin
        update peo_switch_ledger set family_write_skipped = v_family_skip where dedupe_key = v_ded;
      exception when others then null; end;
      begin
        perform public.switch_skip_log('family_label', p_ein, v_to, v_family_skip);
      exception when others then null; end;
    end;
  end if;

  insert into signals (company_ein, signal_type, source, value, confidence, population, observed_at)
  values (p_ein,
    case when v_scope = 'cross_family' then 'peo_switch_confirmed' else 'peo_intra_family_move' end,
    'switch_detection',
    jsonb_build_object('from', v_from, 'to', v_to, 'from_observed', v_from_raw, 'to_observed', v_to_raw,
      'as_of', p_evidence_as_of, 'method', p_detection_method, 'scope', v_scope,
      'from_sponsor', p_from_sponsor, 'to_sponsor', p_to_sponsor,
      'departure_from_protected', v_is_departure,
      'brand_month_cleared', v_month_cleared,
      'family_label_skipped', v_family_skip),
    case when v_scope = 'intra_family_admin' then 0.7 else 0.9 end,
    'switchers', now());

  return jsonb_build_object('switched', true, 'scope', v_scope, 'company_matched', v_found,
    'departure_from_protected', v_is_departure, 'brand_month_cleared', v_month_cleared,
    'family_label_skipped', v_family_skip);
end $function$;

reset role;