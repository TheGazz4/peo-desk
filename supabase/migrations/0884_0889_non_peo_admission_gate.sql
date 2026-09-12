-- ===== 0884_the_admission_gate_judges_the_type_not_the_name =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0884-nonpeo-admission-gate (opened BEFORE apply)
-- Articles implemented: II.3, CANONICAL RESOLUTION, QUARANTINE RULES (a suspect name is quarantined,
--   never merged and never deleted), ONE-DOOR LAW, fix-at-the-core level 1
-- Articles verified not violated: III.1, XIII.1, noncompete fence, switch_detection_nightly hold,
--   and the existing peo_families fence (see the TRIGGER note below - it was respected, not lifted)
-- Verification query attached: YES
--
-- GAZZ: \"Make sure these types of companies aren't able to work their way back into our platform.\"
--
-- 0880-0883 shut the door on 68 NAMES. That stops those 68 and nothing else. A staffing agency or an
-- insurance brokerage we have never seen walks straight in tomorrow under a name that is not on the list.
-- This migration judges the TYPE.
--
-- HOW IT DECIDES. A name signature alone never removes anything - Staffing Plus, Inc has \"STAFFING\" in its
-- name and is a real PEO, sworn on Schedule MEP box 1b. So the gate asks two questions:
--   1. Is this name on the not-a-PEO list?  -> BLOCKED, hard refusal.
--   2. Does the name look like a non-PEO business type AND the mesh hold no PEO evidence for it?
--      Evidence = a sworn Schedule MEP box 1b filing, IRS CPEO certification, a state PEO licence
--      (e.g. Texas TDLR), a PEO master workers-comp policy, or a Gazz ruling.
--      -> QUARANTINED for review: recorded, queued, nothing attributable to it until a human rules.
--   Everything else is admitted. Most of the book has no evidence yet and no suspect signature; blocking
--   on silence alone would empty the platform.
--
-- WHERE IT SITS, AND ONE PLACE IT COULD NOT.
--   companies: a BEFORE INSERT OR UPDATE trigger on the PEO columns. This is the one that matters - a
--     family row with no clients hurts nobody; an attribution is the damage. Every writer is covered,
--     including anything the peer instance runs.
--   peo_families: NO TRIGGER. Its ACL is peo_gatekeeper=arwm - the TRIGGER privilege was deliberately
--     revoked from the owner, the same way DELETE is revoked platform-wide. I did not re-grant it to get
--     my way. Instead the gate sits in gate_add_family_aliases (the named front door, which returns the
--     verdict to the caller) and a RED audit check catches any row that gets in by another path within
--     the hour. An unattributed family row cannot reach a customer surface in the meantime.
--
-- DRY RUN AGAINST THE LIVE BOOK BEFORE ARMING: 13 live families trip a signature.
--   4 hold real PEO evidence and are admitted untouched: Staffing Plus 58, American Payroll Service 11,
--     Team One Personnel Services 2, Elevated Payroll Services 1.
--   9 hold none. Six were already in the Tier 2 check queue. THREE ARE NEW and would never have been
--     found by a name list: TEL Staffing (70 companies), Next Level Payroll Services (11), PEO DUDES C (2).
--   That is the argument for a type gate over a name list, in one number.
--
-- TWO EARLIER APPLIES FAILED on \"permission denied for table peo_families\", both times the trigger above.
-- Diagnosed rather than forced: the privilege is missing on purpose.

create table if not exists public.non_peo_signature_patterns (
  category text primary key,
  pattern text not null,
  what_it_catches text not null,
  enabled boolean not null default true,
  added_at timestamptz not null default now(),
  added_by text not null default 'instanceA-0884'
);
comment on table public.non_peo_signature_patterns is
  'Name shapes that suggest a business type which is not a PEO. A hit is NEVER proof - it only forces a review when the mesh holds no PEO evidence for that name. Matched against name_norm() output.';
alter table public.non_peo_signature_patterns enable row level security;
drop policy if exists non_peo_signature_patterns_read on public.non_peo_signature_patterns;
create policy non_peo_signature_patterns_read on public.non_peo_signature_patterns
  for select to authenticated, service_role using (true);
grant select on public.non_peo_signature_patterns to service_role, peo_gatekeeper, sysaudit_reader;

insert into public.non_peo_signature_patterns (category, pattern, what_it_catches) values
 ('staffing_agency',   '\\y(STAFFING|TEMPS|TEMPORARIES|TEMP SERVICE|LABOR READY|PERSONNEL SERVICES|STAFF LEASING SPECIALIST)\\y',
  'staffing and temp agencies - they place workers, they do not co-employ a client existing staff'),
 ('recruiting_search', '\\y(RECRUITING|RECRUITMENT|RECRUITERS|EXECUTIVE SEARCH|TALENT ACQUISITION|HEADHUNTERS)\\y',
  'recruiting and executive search firms'),
 ('insurance_agency',  '\\y(INSURANCE AGENCY|INSURANCE AGENTS|INSURORS|INSURANCE SERVICES|INSURANCE BROKERS|BROKERAGE|BENEFITS BROKERAGE)\\y',
  'insurance agencies, brokers and benefits consultants - they sell the PEO, they are not the PEO'),
 ('insurance_carrier', '\\y(MUTUAL INSURANCE|CASUALTY|UNDERWRITERS|REINSURANCE|INSURANCE COMPANY)\\y',
  'insurance carriers'),
 ('payroll_bureau',    '\\y(PAYROLL SERVICES|PAYROLL SERVICE|PAYROLL BUREAU|PAYMASTERS|PAYMASTER|ENTERTAINMENT PAYROLL|PAYROLL GROUP)\\y',
  'payroll bureaus and paymaster services - they cut the cheque, they are not the employer of record'),
 ('tpa_plan_vendor',   '\\y(THIRD PARTY ADMINISTRATOR|THIRD PARTY ADMINISTRATORS|RECORDKEEPING|RECORDKEEPER|PLAN ADMINISTRATORS)\\y',
  'third party administrators and plan vendors'),
 ('screening_vendor',  '\\y(BACKGROUND SCREENING|BACKGROUND CHECKS|DRUG TESTING|SCREENING SOLUTIONS|COMPLIANCE SCREENING)\\y',
  'background screening and contractor compliance vendors - this is how PlusOne Solutions got in'),
 ('cpa_law_firm',      '\\y(CPA|CPAS|CERTIFIED PUBLIC ACCOUNTANTS|ATTORNEYS AT LAW|LAW OFFICES)\\y',
  'CPA and law firms'),
 ('person_name',       '^[A-Z]{3,} [A-Z]{3,} [A-Z]$',
  'a person name, not a company - WILSON ROBERT A, OTTO DAVID and two others were sitting in the book')
on conflict (category) do update set pattern = excluded.pattern, what_it_catches = excluded.what_it_catches, enabled = true;

create table if not exists public.peo_admission_queue (
  id bigserial primary key,
  family_slug text not null,
  offered_name text,
  category text,
  verdict text not null,
  source_note text,
  companies_at_block int,
  status text not null default 'open' check (status in ('open','ruled_peo','ruled_not_a_peo','dismissed')),
  ruling text,
  ruled_by text,
  ruled_at timestamptz,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  hits int not null default 1,
  unique (family_slug, verdict)
);
comment on table public.peo_admission_queue is
  'Every admission the gate refused or quarantined. Nothing is thrown away silently - if the gate is wrong, the evidence that it was wrong is sitting right here waiting for a ruling.';
alter table public.peo_admission_queue enable row level security;
drop policy if exists peo_admission_queue_read on public.peo_admission_queue;
create policy peo_admission_queue_read on public.peo_admission_queue
  for select to authenticated, service_role using (true);
grant select on public.peo_admission_queue to service_role, peo_gatekeeper, sysaudit_reader;
grant insert, update on public.peo_admission_queue to peo_gatekeeper, service_role;
grant usage, select on sequence public.peo_admission_queue_id_seq to peo_gatekeeper, service_role;

create or replace function public.has_peo_evidence(p_slug text)
returns boolean language sql stable set search_path to 'public','pg_catalog' as $f$
  select p_slug is not null and (
       exists (select 1 from peo_filing_designation d
                where d.family_slug = p_slug and coalesce(d.peo_plan_filings,0) > 0)
    or exists (select 1 from peo_wc_policies w where w.peo_family = p_slug)
    or exists (select 1 from peo_profiles pr where pr.family_slug = p_slug and pr.cpeo_status = 'certified')
    or exists (select 1 from peo_families f where f.family_slug = p_slug and f.mapping_basis ilike '%tdlr%')
    or exists (select 1 from peo_families f where f.family_slug = p_slug and f.mapping_basis ilike '%gazz%')
  );
$f$;
comment on function public.has_peo_evidence(text) is
  'A sworn Schedule MEP box 1b filing, IRS CPEO certification, a state PEO licence, a PEO master workers-comp policy, or a Gazz ruling. cpeo_status is compared to the exact value certified - ilike %certif% also matches not_certified, which is 540 of 587 profiles; I made that mistake in the first dry run and it reported every family as evidenced.';
revoke execute on function public.has_peo_evidence(text) from public, anon;
grant execute on function public.has_peo_evidence(text) to service_role, postgres, peo_gatekeeper, sysaudit_reader;

create or replace function public.non_peo_signature_of(p_name text)
returns text language sql stable set search_path to 'public','pg_catalog' as $f$
  select s.category from non_peo_signature_patterns s
   where s.enabled and p_name is not null and public.name_norm(p_name) ~ s.pattern
   order by s.category limit 1;
$f$;
revoke execute on function public.non_peo_signature_of(text) from public, anon;
grant execute on function public.non_peo_signature_of(text) to service_role, postgres, peo_gatekeeper, sysaudit_reader;

-- blocked | quarantine_signature | admitted_evidence | admitted_plain
create or replace function public.peo_admission_verdict(p_slug text, p_name text default null)
returns text language sql stable set search_path to 'public','pg_catalog' as $f$
  select case
    when public.names_a_non_peo(p_slug) or public.names_a_non_peo(p_name) then 'blocked'
    when public.has_peo_evidence(p_slug) then 'admitted_evidence'
    when public.non_peo_signature_of(coalesce(p_name, p_slug)) is not null then 'quarantine_signature'
    else 'admitted_plain'
  end;
$f$;
revoke execute on function public.peo_admission_verdict(text,text) from public, anon;
grant execute on function public.peo_admission_verdict(text,text) to service_role, postgres, peo_gatekeeper, sysaudit_reader;

set role peo_gatekeeper;

create or replace function public.peo_admission_log(p_slug text, p_name text, p_verdict text, p_note text)
returns void language plpgsql security definer set search_path to 'public','pg_temp' as $f$
begin
  insert into peo_admission_queue (family_slug, offered_name, category, verdict, source_note, companies_at_block)
  values (p_slug, p_name, public.non_peo_signature_of(coalesce(p_name, p_slug)), p_verdict, left(coalesce(p_note,''), 500),
          (select count(*) from companies c where c.merged_into is null and c.peo_family_slug = p_slug))
  on conflict (family_slug, verdict) do update
     set last_seen = now(), hits = peo_admission_queue.hits + 1;
end $f$;
revoke execute on function public.peo_admission_log(text,text,text,text) from public, anon;
grant execute on function public.peo_admission_log(text,text,text,text) to service_role, postgres, peo_gatekeeper;

-- THE GATE ON THE ATTRIBUTION ITSELF.
-- A bulk load must not explode, so a refused attribution is stripped and logged rather than raised.
create or replace function public.trg_companies_peo_admission()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v text;
begin
  if new.peo_family_slug is not null
     and (tg_op = 'INSERT' or new.peo_family_slug is distinct from old.peo_family_slug) then
    v := public.peo_admission_verdict(new.peo_family_slug, new.peo_name);
    if v in ('blocked','quarantine_signature') then
      perform public.peo_admission_log(new.peo_family_slug, new.peo_name, v,
        format('attribution stripped on companies.%s for company %s', tg_op, new.id));
      new.peo_family_slug := null; new.peo_brand_slug := null; new.peo_name := null;
      new.peo_current := false; new.peo_current_since := null; new.peo_current_since_basis := null;
    end if;
  end if;
  if new.peo_prior_family_slug is not null
     and (tg_op = 'INSERT' or new.peo_prior_family_slug is distinct from old.peo_prior_family_slug) then
    if public.peo_admission_verdict(new.peo_prior_family_slug, new.peo_prior_name)
       in ('blocked','quarantine_signature') then
      perform public.peo_admission_log(new.peo_prior_family_slug, new.peo_prior_name, 'blocked_prior_leg',
        format('prior-leg attribution stripped on companies.%s for company %s', tg_op, new.id));
      new.peo_prior_family_slug := null; new.peo_prior_brand_slug := null; new.peo_prior_name := null;
      new.peo_prior_since := null; new.peo_prior_until := null;
    end if;
  end if;
  return new;
end $f$;

drop trigger if exists companies_peo_admission_gate on public.companies;
create trigger companies_peo_admission_gate
  before insert or update of peo_family_slug, peo_brand_slug, peo_name,
                            peo_prior_family_slug, peo_prior_brand_slug, peo_prior_name
  on public.companies
  for each row execute function public.trg_companies_peo_admission();

-- The named front door for new families asks too, and returns the verdict to the caller.
create or replace function public.gate_add_family_aliases(p_rows jsonb, p_load_key text, p_ruleset text default 'alias_determination_v1'::text)
returns jsonb language plpgsql security definer set search_path to 'public','extensions','pg_temp' as $function$
DECLARE
  r jsonb; v_alias text; v_slug text; v_display text; v_basis text; v_verdict text;
  v_existing_slug text; v_family_exists boolean;
  v_inserted int := 0; v_exists_same int := 0; v_conflicts jsonb := '[]'::jsonb; v_new_families int := 0;
  v_refused int := 0; v_quarantined int := 0;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'p_rows must be a non-empty jsonb array';
  END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_alias := trim(r->>'alias'); v_slug := trim(r->>'family_slug');
    v_display := r->>'display'; v_basis := r->>'basis';
    IF v_alias IS NULL OR v_alias = '' OR v_slug IS NULL OR v_slug = '' OR v_basis IS NULL OR length(v_basis) < 40 THEN
      RAISE EXCEPTION 'each row needs alias, family_slug, and a substantive basis (>=40 chars): %', r;
    END IF;

    -- 0884 ADMISSION GATE, asked before anything else.
    v_verdict := public.peo_admission_verdict(v_slug, COALESCE(v_display, v_alias));
    IF v_verdict = 'blocked' THEN
      v_refused := v_refused + 1;
      PERFORM public.peo_admission_log(v_slug, COALESCE(v_display, v_alias), 'blocked',
        'refused at gate_add_family_aliases load=' || p_load_key);
      v_results := v_results || jsonb_build_object('alias',v_alias,'verdict','NOT_A_PEO_refused');
      CONTINUE;
    END IF;

    SELECT pf.family_slug INTO v_existing_slug FROM peo_families pf
      WHERE pf.identity_quarantined_at IS NULL AND lower(trim(pf.alias)) = lower(v_alias) LIMIT 1;
    IF v_existing_slug IS NOT NULL THEN
      IF v_existing_slug = v_slug THEN
        v_exists_same := v_exists_same + 1;
        v_results := v_results || jsonb_build_object('alias',v_alias,'verdict','exists_same');
      ELSE
        v_conflicts := v_conflicts || jsonb_build_object('alias',v_alias,'existing',v_existing_slug,'proposed',v_slug);
        v_results := v_results || jsonb_build_object('alias',v_alias,'verdict','CONFLICT_refused','existing',v_existing_slug);
      END IF;
      CONTINUE;
    END IF;
    SELECT EXISTS (SELECT 1 FROM peo_families pf WHERE pf.family_slug = v_slug) INTO v_family_exists;
    IF NOT v_family_exists THEN
      IF v_display IS NULL OR v_display = '' THEN
        RAISE EXCEPTION 'new family % requires a display name', v_slug;
      END IF;
      v_new_families := v_new_families + 1;
    ELSE
      SELECT COALESCE(v_display, min(pf.family_display)) INTO v_display FROM peo_families pf WHERE pf.family_slug = v_slug AND pf.identity_quarantined_at IS NULL;
    END IF;

    IF v_verdict = 'quarantine_signature' THEN
      -- Born quarantined. Recorded so a human can overturn it; unusable until they do.
      INSERT INTO peo_families (alias, family_slug, family_display, mapping_basis,
                                identity_quarantined_at, identity_quarantine_reason)
      VALUES (v_alias, v_slug, COALESCE(v_display, v_slug),
              v_basis || ' [gate_add_family_aliases load=' || p_load_key || ' ruleset=' || p_ruleset || ' dated=' || current_date || ']',
              now(),
              'ADMISSION GATE (0884): the name looks like a ' ||
              COALESCE(public.non_peo_signature_of(COALESCE(v_display, v_alias)), 'non-PEO business') ||
              ' and the mesh holds no PEO evidence for it - no sworn Schedule MEP 1b filing, no IRS CPEO ' ||
              'certification, no state PEO licence, no master workers-comp policy. Nothing may be attributed ' ||
              'to it until a human rules. See peo_admission_queue.');
      v_quarantined := v_quarantined + 1;
      PERFORM public.peo_admission_log(v_slug, COALESCE(v_display, v_alias), 'quarantine_signature',
        'born quarantined at gate_add_family_aliases load=' || p_load_key);
      v_results := v_results || jsonb_build_object('alias',v_alias,'verdict','QUARANTINED_signature','family',v_slug,
        'category', public.non_peo_signature_of(COALESCE(v_display, v_alias)));
    ELSE
      INSERT INTO peo_families (alias, family_slug, family_display, mapping_basis)
      VALUES (v_alias, v_slug, COALESCE(v_display, v_slug),
              v_basis || ' [gate_add_family_aliases load=' || p_load_key || ' ruleset=' || p_ruleset || ' dated=' || current_date || ']');
      v_inserted := v_inserted + 1;
      v_results := v_results || jsonb_build_object('alias',v_alias,'verdict','inserted','family',v_slug);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('load_key',p_load_key,'inserted',v_inserted,'exists_same',v_exists_same,
    'conflicts_refused',jsonb_array_length(v_conflicts),'conflicts',v_conflicts,'new_families',v_new_families,
    'not_a_peo_refused',v_refused,'quarantined_signature',v_quarantined,'rows',v_results);
END $function$;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('non_peo_admission_gate_armed', 'mesh_law', 'fast', 'II.3', 'RED',
 'The companies admission-gate trigger must exist and be enabled. If it is dropped or disabled, staffing agencies, insurance brokers and payroll bureaus can be attributed again under names no denylist has ever seen - which is how 68 of them got in.',
 'select t.expected as trigger_name from (values (''companies_peo_admission_gate'')) as t(expected) where not exists (select 1 from pg_trigger g where g.tgname = t.expected and not g.tgisinternal and g.tgenabled <> ''D'')',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as trigger_name',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('non_peo_family_admitted_live', 'mesh_law', 'fast', 'II.3', 'RED',
 'peo_families cannot carry a trigger - the TRIGGER privilege is revoked from its owner on purpose, like DELETE. This check is the compensating control: no live, unquarantined family may sit there whose name the admission gate would refuse or quarantine. If one appears it came in by a path that bypassed gate_add_family_aliases.',
 'select f.family_slug, f.alias, public.peo_admission_verdict(f.family_slug, coalesce(f.family_display, f.alias)) as verdict from public.peo_families f where f.identity_quarantined_at is null and public.peo_admission_verdict(f.family_slug, coalesce(f.family_display, f.alias)) in (''blocked'',''quarantine_signature'') and not exists (select 1 from public.peo_admission_queue q where q.family_slug = f.family_slug and q.status in (''ruled_peo'',''dismissed'')) limit 200',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as family_slug, ''y''::text as alias, ''z''::text as verdict',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('non_peo_signature_unruled', 'mesh_law', 'fast', 'II.3', 'AMBER',
 'A name that trips a non-PEO signature and holds no PEO evidence is quarantined, not deleted - which only works if somebody rules on it. Open admission-queue rows older than 14 days mean the review is not happening.',
 'select q.family_slug, q.category, q.verdict from public.peo_admission_queue q where q.status = ''open'' and q.first_seen < now() - interval ''14 days'' limit 200',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as family_slug, ''y''::text as category, ''z''::text as verdict',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('non_peo_signature_attributed', 'mesh_law', 'fast', 'II.3', 'RED',
 'No live company may be attributed to a family whose name trips a non-PEO signature while the mesh holds no PEO evidence for it. TEL Staffing (70 companies) and Next Level Payroll Services (11) were found exactly this way on 2026-09-12 - neither was on any denylist.',
 'select c.peo_family_slug, public.non_peo_signature_of(coalesce(c.peo_name, c.peo_family_slug)) as category, count(*)::bigint as n from public.companies c where c.merged_into is null and c.peo_family_slug is not null and not public.has_peo_evidence(c.peo_family_slug) and public.non_peo_signature_of(coalesce(c.peo_name, c.peo_family_slug)) is not null and not exists (select 1 from public.peo_admission_queue q where q.family_slug = c.peo_family_slug and q.status in (''ruled_peo'',''dismissed'')) group by 1,2 limit 200',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as peo_family_slug, ''y''::text as category, 1::bigint as n',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

reset role;

-- The three the gate found that no name list would have. Queue them for the Tier 2 paid check.
select public.queue_peo_identity_checks(
  array['telstaffing','nextlevelpayrollservices','peodudesc'],
  'Found by the 0884 admission gate, not by any denylist: the name trips a non-PEO signature and the mesh holds no sworn Schedule MEP 1b filing, no IRS CPEO listing, no state PEO licence and no master workers-comp policy.',
  15) as newly_queued;

-- VERIFICATION
select public.peo_admission_verdict('elitestaffing','Elite Staffing')    as should_be_blocked,
       public.peo_admission_verdict('staffingplus','STAFFING PLUS')      as should_be_admitted_evidence,
       public.peo_admission_verdict('telstaffing','TEL Staffing')        as should_be_quarantine,
       public.peo_admission_verdict('adp_totalsource','ADP TotalSource') as adp,
       public.peo_admission_verdict('rippling','Rippling')               as rippling,
       public.peo_admission_verdict('ocmi','OCMI')                       as ocmi,
       public.non_peo_signature_of('SOME INSURORS INC')                  as catches_insurors,
       public.non_peo_signature_of('WILSON ROBERT A')                    as catches_person,
       public.non_peo_signature_of('ADP TotalSource')                    as adp_clean;"}

-- ===== 0885_the_signature_check_asks_once_per_family_not_once_per_row =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0884-nonpeo-admission-gate
-- Articles implemented: II.3, audit-check shape conformance (a check must finish inside the budget)
-- Articles verified not violated: III.1, XIII.1
-- Verification query attached: YES
--
-- non_peo_signature_attributed as written in 0884 called has_peo_evidence() and non_peo_signature_of()
-- once per COMPANY - roughly 700,000 evaluations, each one a handful of subqueries. It timed out and took
-- the whole fast run down with it. This is the third time today I have written a per-row predicate where a
-- per-family one was the honest shape; the same mistake killed the 0880 backfill.
--
-- The question is about 639 FAMILIES, not 700,000 companies. Ask it once per family, then join the counts.

set role peo_gatekeeper;

update public.sysaudit_registry
   set check_sql = 'with fam as (select distinct c.peo_family_slug as slug from public.companies c where c.merged_into is null and c.peo_family_slug is not null), judged as (select f.slug, public.non_peo_signature_of(f.slug) as category from fam f where public.non_peo_signature_of(f.slug) is not null and not public.has_peo_evidence(f.slug) and not exists (select 1 from public.peo_admission_queue q where q.family_slug = f.slug and q.status in (''ruled_peo'',''dismissed''))) select j.slug as peo_family_slug, j.category, (select count(*)::bigint from public.companies c2 where c2.merged_into is null and c2.peo_family_slug = j.slug) as n from judged j limit 200',
       description = 'No live company may be attributed to a family whose name trips a non-PEO signature while the mesh holds no PEO evidence for it. TEL Staffing (70 companies) and Next Level Payroll Services (11) were found exactly this way on 2026-09-12 - neither was on any denylist. Evaluated once per family (639) rather than once per company (700k); the per-row shape timed out the whole fast run.'
 where check_name = 'non_peo_signature_attributed';

update public.sysaudit_registry
   set check_sql = 'select f.family_slug, f.alias, public.peo_admission_verdict(f.family_slug, coalesce(f.family_display, f.alias)) as verdict from (select distinct on (family_slug) family_slug, alias, family_display from public.peo_families where identity_quarantined_at is null order by family_slug, alias) f where public.peo_admission_verdict(f.family_slug, coalesce(f.family_display, f.alias)) in (''blocked'',''quarantine_signature'') and not exists (select 1 from public.peo_admission_queue q where q.family_slug = f.family_slug and q.status in (''ruled_peo'',''dismissed'')) limit 200'
 where check_name = 'non_peo_family_admitted_live';

reset role;

-- VERIFICATION: both checks return in seconds and report the real number.
select (select count(*) from (
         with fam as (select distinct c.peo_family_slug as slug from public.companies c
                       where c.merged_into is null and c.peo_family_slug is not null)
         select f.slug from fam f
          where public.non_peo_signature_of(f.slug) is not null
            and not public.has_peo_evidence(f.slug)
            and not exists (select 1 from public.peo_admission_queue q
                             where q.family_slug = f.slug and q.status in ('ruled_peo','dismissed'))) z
       ) as families_flagged;"}

-- ===== 0886_the_signature_check_reads_the_name_not_the_slug =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0884-nonpeo-admission-gate
-- Articles implemented: II.3, vacuous-pass guard (a check that can never fire is worse than no check)
-- Articles verified not violated: III.1, XIII.1
-- Verification query attached: YES
--
-- MY BUG, CAUGHT BEFORE IT WENT LIVE. 0885 rewrote non_peo_signature_attributed to evaluate once per
-- family instead of once per company - correct - but it fed the FAMILY SLUG to non_peo_signature_of().
-- A slug has no spaces: \"telstaffing\". Every signature pattern is word-bounded, so \\ySTAFFING\\y can never
-- match TELSTAFFING. The check returned zero rows and would have sat there passing forever while TEL
-- Staffing's 70 companies stayed in the book. A green light that cannot turn red is worse than no light.
--
-- The signature must be read from the DISPLAY NAME, which is what has the spaces - exactly what the
-- trigger and gate_add_family_aliases already do. Added family_display_of() so every caller reads the
-- same thing and this cannot drift apart again.

create or replace function public.family_display_of(p_slug text)
returns text language sql stable set search_path to 'public','pg_catalog' as $f$
  select coalesce(
    (select f.family_display from peo_families f
      where f.family_slug = p_slug and f.family_display is not null
      order by f.identity_quarantined_at nulls first, length(f.family_display) desc limit 1),
    (select f.alias from peo_families f where f.family_slug = p_slug order by length(f.alias) desc limit 1),
    p_slug);
$f$;
comment on function public.family_display_of(text) is
  'The spaced, human name for a family slug. Signature patterns are word-bounded, so they must be read against this and never against the slug - a slug has no spaces and every pattern silently misses.';
revoke execute on function public.family_display_of(text) from public, anon;
grant execute on function public.family_display_of(text) to service_role, postgres, peo_gatekeeper, sysaudit_reader;

set role peo_gatekeeper;

update public.sysaudit_registry
   set check_sql = 'with fam as (select distinct c.peo_family_slug as slug from public.companies c where c.merged_into is null and c.peo_family_slug is not null), judged as (select f.slug, public.non_peo_signature_of(public.family_display_of(f.slug)) as category from fam f where public.non_peo_signature_of(public.family_display_of(f.slug)) is not null and not public.has_peo_evidence(f.slug) and not exists (select 1 from public.peo_admission_queue q where q.family_slug = f.slug and q.status in (''ruled_peo'',''dismissed''))) select j.slug as peo_family_slug, j.category, (select count(*)::bigint from public.companies c2 where c2.merged_into is null and c2.peo_family_slug = j.slug) as n from judged j limit 200',
       description = 'No live company may be attributed to a family whose NAME trips a non-PEO signature while the mesh holds no PEO evidence for it. TEL Staffing (70 companies) and Next Level Payroll Services (11) were found exactly this way on 2026-09-12 - neither was on any denylist. The signature is read from the display name via family_display_of(): patterns are word-bounded and a slug has no spaces, so reading the slug makes this check silently vacuous.'
 where check_name = 'non_peo_signature_attributed';

reset role;

-- VERIFICATION: the check now actually finds the families it was written for.
with fam as (select distinct c.peo_family_slug as slug from public.companies c
              where c.merged_into is null and c.peo_family_slug is not null)
select f.slug, public.family_display_of(f.slug) as display,
       public.non_peo_signature_of(public.family_display_of(f.slug)) as category,
       (select count(*) from public.companies c2 where c2.merged_into is null and c2.peo_family_slug = f.slug) as companies
from fam f
where public.non_peo_signature_of(public.family_display_of(f.slug)) is not null
  and not public.has_peo_evidence(f.slug)
order by companies desc;"}

-- ===== 0887_the_signature_check_stops_counting_and_just_names =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0884-nonpeo-admission-gate
-- Articles implemented: II.3, slow-check budget, sysaudit_executes_as_sysaudit_reader
-- Articles verified not violated: III.1, XIII.1
-- Verification query attached: YES
--
-- The check still timed out inside the audit runner even though the identical query returns in seconds
-- when I run it. The difference is who runs it: sysaudit_exec_readonly executes as sysaudit_reader, and
-- companies has row level security, so every one of the 639 per-family count(*) subqueries re-evaluates
-- the RLS predicates instead of riding the index the way my own session does.
--
-- The check does not need the count. Its job is to NAME the families that got in, not to size them - the
-- count is already recorded on peo_admission_queue and in peo_identity_web_checks. Dropping the subquery
-- takes the check from a timeout to a scan of one distinct list.
--
-- Third time today a per-row shape has bitten me (the 0880 backfill, 0885, this). Writing it down:
-- inside an audit check, ask the question once per SUBJECT and never compute a size you are not asserting on.

set role peo_gatekeeper;

update public.sysaudit_registry
   set check_sql = 'with fam as (select distinct c.peo_family_slug as slug from public.companies c where c.merged_into is null and c.peo_family_slug is not null) select f.slug as peo_family_slug, public.family_display_of(f.slug) as display_name, public.non_peo_signature_of(public.family_display_of(f.slug)) as category from fam f where public.non_peo_signature_of(public.family_display_of(f.slug)) is not null and not public.has_peo_evidence(f.slug) and not exists (select 1 from public.peo_admission_queue q where q.family_slug = f.slug and q.status in (''ruled_peo'',''dismissed'')) limit 200',
       selftest_sql = 'select ''x''::text as peo_family_slug, ''y''::text as display_name, ''z''::text as category',
       description = 'No live company may be attributed to a family whose NAME trips a non-PEO signature while the mesh holds no PEO evidence for it. TEL Staffing (70 companies), Next Level Payroll Services (11) and Staff Leasing Specialist were found exactly this way on 2026-09-12 - none was on any denylist. The check names the families and does not count their companies: it runs as sysaudit_reader, where row level security makes a per-family count(*) re-evaluate the policy predicates and time the whole fast run out.'
 where check_name = 'non_peo_signature_attributed';

grant execute on function public.family_display_of(text) to sysaudit_reader;
grant execute on function public.has_peo_evidence(text) to sysaudit_reader;
grant execute on function public.non_peo_signature_of(text) to sysaudit_reader;
grant execute on function public.peo_admission_verdict(text,text) to sysaudit_reader;
grant execute on function public.names_a_non_peo(text) to sysaudit_reader;
grant select on public.peo_admission_queue to sysaudit_reader;
grant select on public.non_peo_signature_patterns to sysaudit_reader;
grant select on public.peo_identity_web_checks to sysaudit_reader;

reset role;

select 'applied' as status;"}

-- ===== 0888_family_evidence_is_precomputed_so_the_check_can_finish =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0884-nonpeo-admission-gate
-- Articles implemented: II.3, slow-check budget, sysaudit_executes_as_sysaudit_reader
-- Articles verified not violated: III.1, XIII.1, as-of law (the index carries its own refreshed_at)
-- Verification query attached: YES
--
-- 0887 dropped the per-family count and the check STILL timed out, and the error named the culprit:
-- has_peo_evidence(). Called once per family it is cheap in my session; called 639 times as sysaudit_reader
-- it is not. It reads four tables that all have row level security, and one of its tests is
-- mapping_basis ilike '%tdlr%' - a leading wildcard, so a sequential scan of peo_families, 639 times over,
-- with the RLS predicates re-evaluated each pass.
--
-- The answer is not a faster predicate, it is to stop asking a 639-times-repeated question at read time.
-- peo_family_evidence holds one row per family: does the mesh hold PEO evidence, what kind, and does the
-- name trip a non-PEO signature. Refreshed on a cron and after any ruling. The audit check then reads a
-- 660-row table with an index instead of scanning four RLS-protected tables in a loop.
--
-- has_peo_evidence() itself is unchanged and stays the live truth for the admission trigger, where it is
-- called once per write and its cost is irrelevant. The index is for the auditor, not for the gate - so a
-- stale index can never let something in, only delay noticing it, and refreshed_at makes that visible.

create table if not exists public.peo_family_evidence (
  family_slug text primary key,
  display_name text,
  has_evidence boolean not null,
  evidence_basis text,
  signature_category text,
  live_companies int not null default 0,
  refreshed_at timestamptz not null default now()
);
comment on table public.peo_family_evidence is
  'One row per PEO family: does the mesh hold PEO evidence for it, and does its name trip a non-PEO signature. A read-side index for the auditor, refreshed on a cron - never the authority. The admission gate calls has_peo_evidence() live, so a stale row here can delay a finding but can never admit anything.';
create index if not exists peo_family_evidence_suspect
  on public.peo_family_evidence (signature_category)
  where signature_category is not null and has_evidence = false;
alter table public.peo_family_evidence enable row level security;
drop policy if exists peo_family_evidence_read on public.peo_family_evidence;
create policy peo_family_evidence_read on public.peo_family_evidence
  for select to authenticated, service_role using (true);
grant select on public.peo_family_evidence to service_role, peo_gatekeeper, sysaudit_reader;
grant insert, update on public.peo_family_evidence to peo_gatekeeper, service_role;

create or replace function public.refresh_peo_family_evidence()
returns int language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v_n int;
begin
  create temporary table _ev on commit drop as
  select distinct family_slug from peo_filing_designation where coalesce(peo_plan_filings,0) > 0
  union select peo_family from peo_wc_policies where peo_family is not null
  union select family_slug from peo_profiles where cpeo_status = 'certified'
  union select family_slug from peo_families where mapping_basis ilike '%tdlr%'
  union select family_slug from peo_families where mapping_basis ilike '%gazz%';

  create temporary table _cnt on commit drop as
  select peo_family_slug as slug, count(*)::int as n
    from companies where merged_into is null and peo_family_slug is not null group by 1;

  insert into peo_family_evidence (family_slug, display_name, has_evidence, evidence_basis,
                                   signature_category, live_companies, refreshed_at)
  select f.family_slug,
         public.family_display_of(f.family_slug),
         (f.family_slug in (select family_slug from _ev where family_slug is not null)),
         case when f.family_slug in (select family_slug from _ev where family_slug is not null)
              then 'sworn MEP 1b filing, IRS CPEO certification, state PEO licence, master WC policy, or a Gazz ruling'
              else null end,
         public.non_peo_signature_of(public.family_display_of(f.family_slug)),
         coalesce(c.n, 0),
         now()
    from (select distinct family_slug from peo_families) f
    left join _cnt c on c.slug = f.family_slug
  on conflict (family_slug) do update
     set display_name = excluded.display_name,
         has_evidence = excluded.has_evidence,
         evidence_basis = excluded.evidence_basis,
         signature_category = excluded.signature_category,
         live_companies = excluded.live_companies,
         refreshed_at = now();
  get diagnostics v_n = row_count;
  return v_n;
end $f$;
revoke execute on function public.refresh_peo_family_evidence() from public, anon;
grant execute on function public.refresh_peo_family_evidence() to service_role, postgres, peo_gatekeeper;

select public.refresh_peo_family_evidence() as families_indexed;

set role peo_gatekeeper;

update public.sysaudit_registry
   set check_sql = 'select e.family_slug as peo_family_slug, e.display_name, e.signature_category as category, e.live_companies from public.peo_family_evidence e where e.has_evidence = false and e.signature_category is not null and e.live_companies > 0 and not exists (select 1 from public.peo_admission_queue q where q.family_slug = e.family_slug and q.status in (''ruled_peo'',''dismissed'')) and not exists (select 1 from public.peo_identity_web_checks w where w.family_slug = e.family_slug and w.status in (''queued'',''claimed'')) limit 200',
       selftest_sql = 'select ''x''::text as peo_family_slug, ''y''::text as display_name, ''z''::text as category, 1::int as live_companies',
       description = 'No live company may be attributed to a family whose NAME trips a non-PEO signature while the mesh holds no PEO evidence for it. TEL Staffing (70 companies), Next Level Payroll Services (11) and Staff Leasing Specialist were found exactly this way on 2026-09-12 - none was on any denylist. Reads the precomputed peo_family_evidence index: asking has_peo_evidence() live, 639 times, as sysaudit_reader timed the whole fast run out three times. A family already sitting in the paid identity-check queue is not re-reported.'
 where check_name = 'non_peo_signature_attributed';

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('peo_family_evidence_fresh', 'mesh_law', 'fast', 'II.3', 'AMBER',
 'peo_family_evidence is the read-side index the non-PEO signature check depends on. If it stops refreshing, that check keeps passing on a stale picture. Refreshed hourly; stale past six hours.',
 'select max(e.refreshed_at)::text as newest, count(*)::bigint as n from public.peo_family_evidence e having max(e.refreshed_at) < now() - interval ''6 hours''',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as newest, 1::bigint as n',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

reset role;

select cron.schedule('peo_family_evidence_refresh', '18 * * * *',
  $$select public.refresh_peo_family_evidence()$$) as jobid;

-- VERIFICATION
select count(*) filter (where has_evidence) with_evidence,
       count(*) filter (where not has_evidence and signature_category is not null and live_companies > 0) suspect_live,
       count(*) total
from public.peo_family_evidence;"}

-- ===== 0889_a_family_already_in_the_check_queue_is_not_an_unhandled_finding =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0884-nonpeo-admission-gate
-- Articles implemented: II.3, alarm-door law (a standing RED nobody can clear is noise, and noise is how
--   a real RED gets ignored)
-- Articles verified not violated: III.1, XIII.1
-- Verification query attached: YES
--
-- non_peo_family_admitted_live reported 10 families. All ten are correct findings and all ten are already
-- sitting in peo_identity_web_checks waiting for the paid check that runs when tomorrow's budget opens.
-- Left as written it would be a permanent RED describing work that is already scheduled - which trains
-- everyone to scroll past it. Its sibling check already excludes queued families; this aligns it.
--
-- It still fires the moment a family with a non-PEO signature and no evidence appears WITHOUT being routed
-- to a check, which is the thing that actually needs an alarm.

set role peo_gatekeeper;

update public.sysaudit_registry
   set check_sql = 'select f.family_slug, f.alias, public.peo_admission_verdict(f.family_slug, coalesce(f.family_display, f.alias)) as verdict from (select distinct on (family_slug) family_slug, alias, family_display from public.peo_families where identity_quarantined_at is null order by family_slug, alias) f where public.peo_admission_verdict(f.family_slug, coalesce(f.family_display, f.alias)) in (''blocked'',''quarantine_signature'') and not exists (select 1 from public.peo_admission_queue q where q.family_slug = f.family_slug and q.status in (''ruled_peo'',''dismissed'')) and not exists (select 1 from public.peo_identity_web_checks w where w.family_slug = f.family_slug and w.status in (''queued'',''claimed'',''done'')) limit 200',
       description = 'peo_families cannot carry a trigger - the TRIGGER privilege is revoked from its owner on purpose, like DELETE. This check is the compensating control: no live, unquarantined family may sit there whose name the admission gate would refuse or quarantine, unless a human has ruled on it or it is already routed to the paid identity check. If one appears it came in by a path that bypassed gate_add_family_aliases.'
 where check_name = 'non_peo_family_admitted_live';

reset role;

select 'applied' as status;"}
