{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0891-nonpeo-door-hardening (opened BEFORE apply)
-- Articles implemented: II.3, NAME NORMALIZATION PROTOCOL (drop trailing entity suffixes),
--   ENTRY PIPELINE, fix-at-the-core level 1
-- Articles verified not violated: III.1, XIII.1, noncompete fence, switch_detection_nightly hold
-- Verification query attached: YES
--
-- Audited 0890. Four defects, two of them serious.
--
-- 1. THE DOOR DOES NOT SURVIVE A LEGAL NAME. This is the bad one, and it was in the ORIGINAL 0880 design,
--    not just the fast path I added yesterday:
--        names_a_non_peo('Elite Staffing, Inc.')          -> FALSE
--        peo_admission_verdict_fast(null,'ENTERTAINMENT PARTNERS LLC') -> admitted_plain
--    Both are on the block list. Both walk straight through under the name that actually appears on a
--    Form 5500 or a state registry, which is exactly where these names come from.
--    Cause: I keyed the door on name_norm(), which uppercases and strips punctuation but does NOT drop
--    entity suffixes - \"ELITE STAFFING INC\", not \"ELITE STAFFING\". My patterns were anchored ^...$, so the
--    suffix broke every match. I was proud of that anchoring in the 0880 header.
--    The platform already has norm_company_name(), which implements the full NAME NORMALIZATION PROTOCOL
--    including suffix stripping. It existed the whole time and I did not use it.
--    Checked before arming: keying the door on norm_company_name collides with ZERO live PEO families.
--
-- 2. peo_identity_check_promote() CANNOT RUN AT ALL. \"cannot set parameter role within security-definer
--    function\" - the set local role peo_gatekeeper I added in 0890 is illegal inside SECURITY DEFINER.
--    The function would have thrown the first time anybody called it. I shipped it untested, in the same
--    migration where I complained that the previous version reported work it never did. Fixed by owning
--    the function as peo_gatekeeper so it already runs with the right rights, and proven by execution.
--
-- 3. peo_name_aliases_insert_router routes runtime aliases into peo_alias_registry with no admission
--    check. It writes them HELD_UNADJUDICATED so they are inert, but it will still happily point a new
--    alias at a family we removed. It now refuses those.
--
-- 4. peo_user_status_without_a_peo hard-codes its floor (1262) in the check SQL, so the ratchet never
--    tightens and a drop-then-rise passes silently. The floor is stored and tightens itself.

-- 1. THE DOOR, RE-KEYED ON THE REAL NORMALIZATION PROTOCOL.
alter table public.not_a_peo_names add column if not exists name_key text;
update public.not_a_peo_names set name_key = public.norm_company_name(name_raw) where name_key is null;
create index if not exists not_a_peo_names_key on public.not_a_peo_names (name_key);

create or replace function public.names_a_non_peo(p text)
returns boolean language sql stable set search_path to 'public','pg_catalog' as $f$
  select case
    when p is null or btrim(p) = '' then false
    when exists (select 1 from public.not_a_peo_slugs n where n.slug = p) then true
    when exists (select 1 from public.not_a_peo_names m where m.name_raw = p) then true
    when exists (select 1 from public.not_a_peo_names m where m.name_raw = public.name_norm(p)) then true
    -- The one that was missing: match on the suffix-stripped key, so \"Elite Staffing, Inc.\" and
    -- \"ENTERTAINMENT PARTNERS LLC\" are caught the same as the bare name.
    when nullif(btrim(public.norm_company_name(p)),'') is not null
         and exists (select 1 from public.not_a_peo_names m where m.name_key = public.norm_company_name(p)) then true
    else public.is_not_a_peo(p)
  end;
$f$;
comment on function public.names_a_non_peo(text) is
  'True when this value names something ruled NOT A PEO. Exact slug, exact name, name_norm form, then the suffix-stripped norm_company_name key, then the anchored regex door. The key match is what makes a legal name (\"Elite Staffing, Inc.\") match the plain one; without it the door passed every Form 5500 spelling.';
revoke execute on function public.names_a_non_peo(text) from public, anon;
grant execute on function public.names_a_non_peo(text) to service_role, postgres, peo_gatekeeper, sysaudit_reader;

create or replace function public.peo_admission_verdict_fast(p_slug text, p_name text default null)
returns text language plpgsql stable set search_path to 'public','pg_catalog' as $f$
declare r record; v_key text;
begin
  if p_slug is not null and exists (select 1 from not_a_peo_slugs n where n.slug = p_slug) then return 'blocked'; end if;
  if p_name is not null and exists (select 1 from not_a_peo_names m where m.name_raw = p_name) then return 'blocked'; end if;
  if p_slug is not null and exists (select 1 from not_a_peo_names m where m.name_raw = p_slug) then return 'blocked'; end if;

  -- suffix-stripped key, on both the name and the slug
  v_key := nullif(btrim(public.norm_company_name(coalesce(p_name, p_slug))), '');
  if v_key is not null and exists (select 1 from not_a_peo_names m where m.name_key = v_key) then return 'blocked'; end if;
  if p_name is not null and p_slug is not null then
    v_key := nullif(btrim(public.norm_company_name(p_slug)), '');
    if v_key is not null and exists (select 1 from not_a_peo_names m where m.name_key = v_key) then return 'blocked'; end if;
  end if;

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
revoke execute on function public.peo_admission_verdict_fast(text,text) from public, anon;
grant execute on function public.peo_admission_verdict_fast(text,text) to service_role, postgres, peo_gatekeeper, sysaudit_reader;

-- 2. PROMOTE, OWNED BY THE ROLE IT NEEDS SO IT CAN ACTUALLY RUN.
drop function if exists public.peo_identity_check_promote(numeric);

set role peo_gatekeeper;

create function public.peo_identity_check_promote(p_min_confidence numeric default 0.80)
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

    insert into not_a_peo_names (name_raw, slug, name_key)
    select distinct v.nm, r.family_slug, public.norm_company_name(v.nm) from (
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

    update peo_identity_web_checks set promoted_at = now() where check_id = r.check_id;

    family_slug := r.family_slug; confidence := r.confidence;
    companies_cleared := v_c; observations_superseded := v_o;
    return next;
  end loop;

  perform public.refresh_peo_family_evidence();
end $f$;

-- 3. THE ALIAS ROUTER STOPS POINTING NEW NAMES AT REMOVED FAMILIES.
create or replace function public.peo_name_aliases_insert_router()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $function$
begin
  if public.names_a_non_peo(new.family_slug) or public.names_a_non_peo(new.alias_raw) then
    insert into edge_debug(fn,step,detail) values
      ('alias_insert_router','refused_not_a_peo',
       jsonb_build_object('family', new.family_slug, 'alias', left(new.alias_raw,80),
                          'note','family or alias is on the not-a-PEO list; nothing may canonicalize to it'));
    return null;
  end if;

  insert into peo_alias_registry (family_slug, alias_raw, alias_norm, source, verdict, evidence)
  values (new.family_slug, new.alias_raw, new.alias_norm,
          coalesce(new.source,'runtime_writer'), 'HELD_UNADJUDICATED',
          jsonb_build_object('routed_from','peo_name_aliases view','at',now()))
  on conflict (family_slug, alias_raw) do nothing;

  insert into edge_debug(fn,step,detail) values
    ('alias_insert_router','routed',
     jsonb_build_object('family',new.family_slug,'alias',left(new.alias_raw,80),
                        'note','held pending adjudication - inert until confirmed'));
  return new;
end $function$;

-- 4. A FLOOR THAT TIGHTENS ITSELF.
create table if not exists public.repair_floor (
  metric text primary key,
  floor_value bigint not null,
  note text,
  updated_at timestamptz not null default now()
);
alter table public.repair_floor enable row level security;
drop policy if exists repair_floor_read on public.repair_floor;
create policy repair_floor_read on public.repair_floor for select to authenticated, service_role using (true);
grant select on public.repair_floor to service_role, peo_gatekeeper, sysaudit_reader;
grant insert, update on public.repair_floor to peo_gatekeeper, service_role;

insert into public.repair_floor (metric, floor_value, note)
select 'peo_user_status_without_a_peo',
       (select count(*) from public.companies c where c.merged_into is null
          and c.peo_family_slug is null and c.peo_user_status = 'current_peo_user'),
       'Companies reading current_peo_user with no PEO attributed. Pre-dates the non-PEO sweep. The floor only ever moves down.'
on conflict (metric) do nothing;

create or replace function public.repair_floor_tighten(p_metric text, p_observed bigint)
returns bigint language sql security definer set search_path to 'public','pg_temp' as $f$
  update public.repair_floor set floor_value = p_observed, updated_at = now()
   where metric = p_metric and p_observed < floor_value
  returning floor_value;
$f$;
revoke execute on function public.repair_floor_tighten(text,bigint) from public, anon;
grant execute on function public.repair_floor_tighten(text,bigint) to service_role, postgres, peo_gatekeeper;

update public.sysaudit_registry
   set check_sql = 'with obs as (select count(*)::bigint as n from public.companies c where c.merged_into is null and c.peo_family_slug is null and c.peo_user_status = ''current_peo_user'') select obs.n, f.floor_value from obs join public.repair_floor f on f.metric = ''peo_user_status_without_a_peo'' where obs.n > f.floor_value',
       selftest_sql = 'select 9999::bigint as n, 1::bigint as floor_value',
       description = 'A company cannot read \"current PEO user\" with no PEO attributed - a customer surface asserting something we cannot name. Found on 2026-09-12 while auditing the non-PEO sweep; pre-dates it, so the repair needs a ruling. Compared against a STORED floor in repair_floor that only moves down, so a drop-then-rise cannot pass silently the way a hard-coded number let it.'
 where check_name = 'peo_user_status_without_a_peo';

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('not_a_peo_door_survives_legal_names', 'mesh_law', 'fast', 'II.3', 'RED',
 'Every name on the not-a-PEO list must still be refused when it appears with its entity suffix, which is the form that actually shows up on a Form 5500 or a state registry. On 2026-09-12 \"Elite Staffing, Inc.\" and \"ENTERTAINMENT PARTNERS LLC\" both passed the door because it was keyed on name_norm(), which does not strip suffixes.',
 'select m.name_raw, m.name_key from public.not_a_peo_names m where m.name_key is not null and btrim(m.name_key) <> '''' and not public.names_a_non_peo(m.name_key || '' LLC'') limit 100',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as name_raw, ''y''::text as name_key',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

reset role;

revoke execute on function public.peo_identity_check_promote(numeric) from public, anon;
grant execute on function public.peo_identity_check_promote(numeric) to service_role, postgres, peo_gatekeeper;

-- VERIFICATION
select public.names_a_non_peo('Elite Staffing, Inc.')                          as elite_legal_name,
       public.names_a_non_peo('ENTERTAINMENT PARTNERS LLC')                    as ep_legal_name,
       public.peo_admission_verdict_fast(null,'Elite Staffing, Inc.')          as fast_elite,
       public.peo_admission_verdict_fast(null,'ENTERTAINMENT PARTNERS LLC')    as fast_ep,
       public.peo_admission_verdict_fast('adp_totalsource','ADP TotalSource, Inc.') as adp_still_fine,
       public.peo_admission_verdict_fast('insperity','Insperity, Inc.')        as insperity_still_fine,
       (select count(*) from public.not_a_peo_names where name_key is null)    as unkeyed_rows;"}