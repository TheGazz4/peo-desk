{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0890-nonpeo-audit-fixes (opened BEFORE apply)
-- Articles implemented: II.3, ENTRY PIPELINE (canonicalize through peo_families/peo_alias_registry),
--   QUARANTINE RULES, fix-at-the-core all three levels, no-blind-spender law
-- Articles verified not violated: III.1, XIII.1, noncompete fence, switch_detection_nightly hold
-- Verification query attached: YES
--
-- I audited my own 0880-0889 work and found seven holes:
--
-- 1. peo_alias_registry - 80 LIVE ROWS still map real names onto the 68 removed families. The ENTRY
--    PIPELINE law says every PEO name is canonicalized through peo_families AND peo_alias_registry before
--    writing. I quarantined the peo_families side and never touched the registry.
-- 2. form5500_mep_participants - 114 live peo_book rows still attribute clients to removed families,
--    110 of them to United Benefits Consulting, a benefits broker. They surface on the mep_peo_book VIEW,
--    a customer-facing surface. A level-3 display miss of the kind I keep writing laws about.
-- 3. peo_timeline_facts 96, peo_sponsor_eins 24, peo_departure_ledger 2. The EINs matter most: an EIN
--    mapped to a non-PEO family is how the family gets recreated by an EIN match. All three columns are
--    NOT NULL and DELETE is revoked platform-wide, so the retirement is a marked prefix,
--    NOT_A_PEO_RETIRED::, which no live family can match while the provenance survives.
-- 4. The admission trigger did not clear peo_user_status. My own arming probe left a real company reading
--    \"current PEO user\" with no PEO attached. Every future strip would have added one more.
-- 5. The trigger cost 10.7ms per attribution change (874 buffers) because it asked has_peo_evidence()
--    live - four RLS-protected tables including a leading-wildcard scan. On a 50,000-row attribution load
--    that is nine minutes of pure gate overhead.
-- 6. peo_identity_check_promote() wrote the three registries and reported a \"companies_cleared\" count it
--    had counted and never acted on. Promoting a not_a_peo verdict left every attribution in place.
-- 7. The identity-check queue cap was 15 with 15 already queued, so the next find was silently dropped.
--
-- ALSO FOUND, NOT MINE, NOT FIXED HERE: 1,262 companies carry peo_user_status = 'current_peo_user' with no
-- PEO attributed at all - a customer surface asserting something we cannot name. They pre-date this session
-- and spread over weeks; my own cleared rows are not among them. A RED check makes it visible so Gazz can
-- rule on the repair rather than me guessing at it.
--
-- TWO EARLIER APPLIES FAILED: peo_sponsor_eins.family_slug is NOT NULL (fixed with the marked prefix), and
-- peo_identity_check_promote gained OUT columns so it needed an explicit drop first.

set role peo_gatekeeper;

update public.peo_alias_registry a
   set identity_quarantined_at = now(),
       identity_quarantine_reason = 'NOT A PEO: family ' || a.family_slug ||
         ' was removed on 2026-09-12 (0880-0881). Never canonicalize a name to this family. See not_a_peo_registry.'
 where a.identity_quarantined_at is null
   and exists (select 1 from public.not_a_peo_slugs n where n.slug = a.family_slug);

update public.form5500_mep_participants p
   set identity_trust = 'SUPERSEDED: attributed to ' || p.peo_slug ||
         ', ruled NOT A PEO on 2026-09-12 (0880). ' || coalesce(p.identity_trust, '')
 where (p.identity_trust is null or p.identity_trust not like 'SUPERSEDED%')
   and exists (select 1 from public.not_a_peo_slugs n where n.slug = p.peo_slug);

update public.peo_sponsor_eins e
   set family_slug = 'NOT_A_PEO_RETIRED::' || e.family_slug
 where exists (select 1 from public.not_a_peo_slugs n where n.slug = e.family_slug);

update public.peo_timeline_facts t
   set family_slug = 'NOT_A_PEO_RETIRED::' || t.family_slug
 where exists (select 1 from public.not_a_peo_slugs n where n.slug = t.family_slug);

update public.peo_departure_ledger d
   set from_family_slug = 'NOT_A_PEO_RETIRED::' || d.from_family_slug
 where exists (select 1 from public.not_a_peo_slugs n where n.slug = d.from_family_slug);

reset role;

create or replace function public.peo_admission_verdict_fast(p_slug text, p_name text default null)
returns text language plpgsql stable set search_path to 'public','pg_catalog' as $f$
declare r record;
begin
  if p_slug is not null and exists (select 1 from not_a_peo_slugs n where n.slug = p_slug) then return 'blocked'; end if;
  if p_name is not null and exists (select 1 from not_a_peo_names m where m.name_raw = p_name) then return 'blocked'; end if;
  if p_slug is not null and exists (select 1 from not_a_peo_names m where m.name_raw = p_slug) then return 'blocked'; end if;

  select e.has_evidence, e.signature_category into r
    from peo_family_evidence e where e.family_slug = p_slug;
  if found then
    if r.has_evidence then return 'admitted_evidence'; end if;
    if r.signature_category is not null then return 'quarantine_signature'; end if;
    if p_name is not null and public.non_peo_signature_of(p_name) is not null then return 'quarantine_signature'; end if;
    return 'admitted_plain';
  end if;

  return public.peo_admission_verdict(p_slug, p_name);
end $f$;
comment on function public.peo_admission_verdict_fast(text,text) is
  'The hot-path verdict used by the companies trigger. The block list is always read live and exact; the evidence and signature half reads peo_family_evidence and falls back to the full live verdict for any family the index has never seen. Replaces a 10.7ms per-row call that would have added nine minutes to a 50,000-row attribution load.';
revoke execute on function public.peo_admission_verdict_fast(text,text) from public, anon;
grant execute on function public.peo_admission_verdict_fast(text,text) to service_role, postgres, peo_gatekeeper, sysaudit_reader;

set role peo_gatekeeper;

create or replace function public.trg_companies_peo_admission()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v text;
begin
  if new.peo_family_slug is not null
     and (tg_op = 'INSERT' or new.peo_family_slug is distinct from old.peo_family_slug) then
    v := public.peo_admission_verdict_fast(new.peo_family_slug, new.peo_name);
    if v in ('blocked','quarantine_signature') then
      perform public.peo_admission_log(new.peo_family_slug, new.peo_name, v,
        format('attribution stripped on companies.%s for company %s', tg_op, new.id));
      new.peo_family_slug := null; new.peo_brand_slug := null; new.peo_name := null;
      new.peo_original := null;
      new.peo_current := false; new.peo_current_since := null; new.peo_current_since_basis := null;
      new.peo_current_since_precision := null; new.peo_current_since_censored := null;
      new.peo_entry_from := null; new.peo_exit_to := null; new.peo_switch_as_of := null;
      new.peo_observation_floor := null; new.peo_observation_floor_basis := null;
      -- Without this the company reads \"current PEO user\" with no PEO attached. My own arming probe
      -- left exactly one of those behind before I caught it.
      new.peo_user_status := null;
    end if;
  end if;
  if new.peo_prior_family_slug is not null
     and (tg_op = 'INSERT' or new.peo_prior_family_slug is distinct from old.peo_prior_family_slug) then
    if public.peo_admission_verdict_fast(new.peo_prior_family_slug, new.peo_prior_name)
       in ('blocked','quarantine_signature') then
      perform public.peo_admission_log(new.peo_prior_family_slug, new.peo_prior_name, 'blocked_prior_leg',
        format('prior-leg attribution stripped on companies.%s for company %s', tg_op, new.id));
      new.peo_prior_family_slug := null; new.peo_prior_brand_slug := null; new.peo_prior_name := null;
      new.peo_prior_since := null; new.peo_prior_until := null; new.peo_prior_basis := null;
    end if;
  end if;
  return new;
end $f$;

update public.companies
   set peo_user_status = null
 where id = '2291aa5b-563e-4c69-a010-4075e13c35ec'
   and peo_family_slug is null and peo_user_status = 'current_peo_user';

reset role;

create or replace function public.peo_identity_check_promote(p_min_confidence numeric default 0.80)
returns table (family_slug text, confidence numeric, companies_cleared int, observations_superseded int)
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare r record; v_c int; v_o int;
begin
  for r in
    select c.* from peo_identity_web_checks c
     where c.status = 'done' and c.verdict = 'not_a_peo'
       and c.confidence >= p_min_confidence and c.promoted_at is null
  loop
    insert into not_a_peo_slugs (slug, label, what_it_is, bucket, ruled_by)
    values (r.family_slug, coalesce(r.family_display, r.family_slug),
            left(coalesce(r.summary,'web check found no PEO or co-employer evidence'), 300),
            'web_checked', 'peo-identity-check')
    on conflict (slug) do nothing;

    insert into not_a_peo_names (name_raw, slug)
    select distinct v.nm, r.family_slug from (
      select r.family_slug as nm
      union select r.family_display
      union select public.name_norm(r.family_display)
      union select f.alias from peo_families f where f.family_slug = r.family_slug
      union select public.name_norm(f.alias) from peo_families f where f.family_slug = r.family_slug
    ) v where v.nm is not null and btrim(v.nm) <> ''
    on conflict (name_raw) do nothing;

    insert into not_a_peo_registry (pattern, label, what_it_actually_is, basis, ruled_by)
    select '^' || upper(r.family_slug) || '$' ||
           coalesce((select '|' || string_agg(distinct '^' || public.name_norm(f.alias) || '$', '|')
                       from peo_families f where f.family_slug = r.family_slug
                        and public.name_norm(f.alias) <> '' and public.name_norm(f.alias) <> upper(r.family_slug)), ''),
           coalesce(r.family_display, r.family_slug),
           left(coalesce(r.summary,'no PEO evidence found'), 300),
           'peo-identity-check verdict not_a_peo at confidence ' || r.confidence || ' (0883 lane), under the Gazz non-PEO ruling of 2026-09-12',
           'peo-identity-check'
    on conflict (pattern) do nothing;

    -- THE PART THAT WAS MISSING.
    set local role peo_gatekeeper;

    update companies c
       set peo_family_slug = null, peo_brand_slug = null, peo_name = null, peo_original = null,
           peo_current = false, peo_current_since = null, peo_current_since_basis = null,
           peo_current_since_precision = null, peo_current_since_censored = null,
           peo_entry_from = null, peo_exit_to = null, peo_switch_as_of = null,
           peo_observation_floor = null, peo_observation_floor_basis = null, peo_user_status = null
     where c.peo_family_slug = r.family_slug or c.peo_brand_slug = r.family_slug;
    get diagnostics v_c = row_count;

    update companies c
       set peo_prior_family_slug = null, peo_prior_brand_slug = null, peo_prior_name = null,
           peo_prior_since = null, peo_prior_until = null, peo_prior_basis = null
     where c.peo_prior_family_slug = r.family_slug or c.peo_prior_brand_slug = r.family_slug;

    update field_observations o set resolution_status = 'superseded'
     where o.resolution_status <> 'superseded' and o.value_text = r.family_slug;
    get diagnostics v_o = row_count;

    update peo_families f
       set identity_quarantined_at = now(),
           identity_quarantine_reason = 'NOT A PEO: web check verdict at confidence ' || r.confidence ||
             ' (0883 lane). ' || left(coalesce(r.summary,''), 200)
     where f.family_slug = r.family_slug and f.identity_quarantined_at is null;

    update peo_alias_registry a
       set identity_quarantined_at = now(),
           identity_quarantine_reason = 'NOT A PEO: family ruled by peo-identity-check at confidence ' || r.confidence
     where a.family_slug = r.family_slug and a.identity_quarantined_at is null;

    update form5500_mep_participants p
       set identity_trust = 'SUPERSEDED: attributed to ' || r.family_slug || ', ruled NOT A PEO by peo-identity-check. '
                            || coalesce(p.identity_trust,'')
     where p.peo_slug = r.family_slug
       and (p.identity_trust is null or p.identity_trust not like 'SUPERSEDED%');

    update peo_sponsor_eins e set family_slug = 'NOT_A_PEO_RETIRED::' || e.family_slug where e.family_slug = r.family_slug;
    update peo_timeline_facts t set family_slug = 'NOT_A_PEO_RETIRED::' || t.family_slug where t.family_slug = r.family_slug;
    update peo_departure_ledger d set from_family_slug = 'NOT_A_PEO_RETIRED::' || d.from_family_slug where d.from_family_slug = r.family_slug;

    update peo_switch_ledger l
       set switch_scope = 'intra_family',
           triage_reason = coalesce(l.triage_reason,'') ||
             ' || RETIRED: one side ruled NOT A PEO by peo-identity-check (0883 lane).'
     where (l.from_family_slug = r.family_slug or l.to_family_slug = r.family_slug)
       and l.switch_scope is distinct from 'intra_family';

    reset role;

    update peo_identity_web_checks set promoted_at = now() where check_id = r.check_id;

    family_slug := r.family_slug; confidence := r.confidence;
    companies_cleared := v_c; observations_superseded := v_o;
    return next;
  end loop;

  perform public.refresh_peo_family_evidence();
end $f$;
revoke execute on function public.peo_identity_check_promote(numeric) from public, anon;
grant execute on function public.peo_identity_check_promote(numeric) to service_role, postgres, peo_gatekeeper;

drop function if exists public.queue_peo_identity_checks(text[],text,int);
create function public.queue_peo_identity_checks(p_slugs text[], p_why text, p_cap int default 40)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v_open int; v_room int; v_n int; v_dropped text[];
begin
  if p_cap > 40 then p_cap := 40; end if;
  select count(*) into v_open from peo_identity_web_checks where status in ('queued','claimed');
  v_room := greatest(p_cap - v_open, 0);

  with cand as (
    select s as family_slug,
           (select max(f.family_display) from peo_families f where f.family_slug = s) as disp,
           (select count(*) from companies c where c.merged_into is null and c.peo_family_slug = s) as n
    from unnest(p_slugs) s
    where not exists (select 1 from not_a_peo_slugs nn where nn.slug = s)
      and not exists (select 1 from peo_identity_web_checks w where w.family_slug = s)
    order by n desc nulls last
    limit v_room
  )
  insert into peo_identity_web_checks (family_slug, family_display, clients_at_queue, why_queued)
  select family_slug, disp, n, p_why from cand
  on conflict (family_slug) do nothing;
  get diagnostics v_n = row_count;

  select coalesce(array_agg(s), '{}') into v_dropped
    from unnest(p_slugs) s
   where not exists (select 1 from peo_identity_web_checks w where w.family_slug = s)
     and not exists (select 1 from not_a_peo_slugs nn where nn.slug = s);

  if coalesce(array_length(v_dropped, 1), 0) > 0 then
    insert into source_alerts (source_name, change_summary, acknowledged)
    values ('peo_identity_web_checks',
      format('IDENTITY CHECK QUEUE FULL — %s refused: %s. Open: %s, cap: %s. They are still attributed and still unverified.',
             array_length(v_dropped,1), array_to_string(v_dropped, ', '), v_open, p_cap), false);
  end if;

  return jsonb_build_object('queued', v_n, 'open_before', v_open, 'cap', p_cap,
                            'dropped', coalesce(array_length(v_dropped,1), 0), 'dropped_slugs', v_dropped);
end $f$;
revoke execute on function public.queue_peo_identity_checks(text[],text,int) from public, anon;
grant execute on function public.queue_peo_identity_checks(text[],text,int) to service_role, postgres, peo_gatekeeper;

set role peo_gatekeeper;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('non_peo_residue_outside_companies', 'mesh_law', 'fast', 'II.3', 'RED',
 'A family ruled NOT A PEO must be gone from every spine, not just the companies table. Auditing my own 0880-0889 work found 80 live alias-registry rows, 114 live Form 5500 participant rows feeding the customer-facing mep_peo_book view (110 of them a benefits broker), 96 timeline facts, 24 sponsor EINs and 2 departure-ledger rows still pointing at removed families.',
 'select ''peo_alias_registry''::text as spine, count(*)::bigint as n from public.peo_alias_registry a where a.identity_quarantined_at is null and exists (select 1 from public.not_a_peo_slugs n where n.slug = a.family_slug) having count(*) > 0 union all select ''form5500_mep_participants'', count(*)::bigint from public.form5500_mep_participants p where (p.identity_trust is null or p.identity_trust not like ''SUPERSEDED%'') and exists (select 1 from public.not_a_peo_slugs n where n.slug = p.peo_slug) having count(*) > 0 union all select ''peo_sponsor_eins'', count(*)::bigint from public.peo_sponsor_eins e where exists (select 1 from public.not_a_peo_slugs n where n.slug = e.family_slug) having count(*) > 0 union all select ''peo_timeline_facts'', count(*)::bigint from public.peo_timeline_facts t where exists (select 1 from public.not_a_peo_slugs n where n.slug = t.family_slug) having count(*) > 0 union all select ''peo_departure_ledger'', count(*)::bigint from public.peo_departure_ledger d where exists (select 1 from public.not_a_peo_slugs n where n.slug = d.from_family_slug) having count(*) > 0',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as spine, 1::bigint as n',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('peo_user_status_without_a_peo', 'mesh_law', 'fast', 'II.3', 'RED',
 'A company cannot read \"current PEO user\" with no PEO attributed - that is a customer surface asserting something we cannot name. 1,262 such rows were found on 2026-09-12 while auditing the non-PEO sweep; they pre-date it and spread over weeks, so the repair needs a ruling rather than a guess. The admission gate now clears the status when it strips an attribution, so the count cannot grow from that path. Ratchet the threshold down as they are repaired.',
 'select count(*)::bigint as n from public.companies c where c.merged_into is null and c.peo_family_slug is null and c.peo_user_status = ''current_peo_user'' having count(*) > 1262',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select 9999::bigint as n',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

reset role;

select public.refresh_peo_family_evidence() as families_reindexed;

select (select count(*) from public.peo_alias_registry a where a.identity_quarantined_at is null
          and exists (select 1 from public.not_a_peo_slugs n where n.slug = a.family_slug)) as alias_rows_left,
       (select count(*) from public.form5500_mep_participants p
          where (p.identity_trust is null or p.identity_trust not like 'SUPERSEDED%')
            and exists (select 1 from public.not_a_peo_slugs n where n.slug = p.peo_slug)) as participant_rows_left,
       (select count(*) from public.mep_peo_book m
          where exists (select 1 from public.not_a_peo_slugs n where n.slug = m.peo_slug)) as mep_book_view_left,
       (select count(*) from public.peo_sponsor_eins e
          where exists (select 1 from public.not_a_peo_slugs n where n.slug = e.family_slug)) as sponsor_eins_left,
       (select count(*) from public.peo_timeline_facts t
          where exists (select 1 from public.not_a_peo_slugs n where n.slug = t.family_slug)) as timeline_facts_left,
       (select count(*) from public.peo_departure_ledger d
          where exists (select 1 from public.not_a_peo_slugs n where n.slug = d.from_family_slug)) as departures_left,
       (select count(*) from public.companies c where c.merged_into is null
          and c.peo_family_slug is null and c.peo_user_status = 'current_peo_user') as status_without_peo;"}