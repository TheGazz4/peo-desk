-- ===== 0894_rerun_the_sweep_with_the_matcher_that_actually_works =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0894-rerun-the-sweep-with-the-fixed-matcher (opened BEFORE apply)
-- Articles implemented: II.3, ONE-DOOR LAW, fix-at-the-core all three levels, ENTRY PIPELINE
-- Articles verified not violated: III.1, XIII.1, noncompete fence, switch_detection_nightly hold
-- Verification query attached: YES
--
-- Audited 0892/0893. Three findings, and the first one is the worst thing I have found all day.
--
-- 1. 944 COMPANIES STILL SAY THEIR ORIGINAL PEO WAS \"PLUSONE SOLUTIONS LLC\".
--    PlusOne is a background-screening vendor. I have \"finished removing\" it three separate times -
--    0878, 0881, 0890 - and each time I reported it clean.
--    Why it survived: my 0881 backfill matched on the old name list, and \"PLUSONE SOLUTIONS LLC\" carries
--    an entity suffix. That is precisely the legal-name bypass I discovered and fixed in 0891 - and after
--    fixing the matcher I never re-ran the backfill. Level 1 changed and level 2 was left on the old
--    result. Fixing a matcher without re-sweeping the data it already mis-matched leaves the data wrong,
--    quietly, with every check still green because the checks used the same broken matcher.
--    Re-swept here with the corrected matcher: 953 peo_original rows, 2 switch-ledger legs still scored
--    cross_family, 8 live alias-registry rows.
--
-- 2. peo_original HAD NO GATE. I added the column to the trigger's UPDATE OF list in 0893 and never wrote
--    a body check for it - the mirror image of the 0892 bug, where I wrote the body and forgot the list.
--
-- 3. TWO SPINES ACCEPT A BLOCKED FAMILY WITH NO DOOR AT ALL. Proven by probe:
--        insert into form5500_mep_participants (... peo_slug 'elitestaffing' ...)  -> ACCEPTED
--        insert into peo_sponsor_eins          (... family_slug 'elitestaffing' ...) -> ACCEPTED
--    The first feeds mep_peo_book, a customer surface. The second is worse: EIN is king, so a blocked
--    family holding an EIN is how it resurrects through an EIN match. 0890 cleaned both once and left
--    them open. Both are postgres-owned and carry the TRIGGER privilege, so both get a real door.
--    peo_switch_ledger and peo_alias_registry cannot take triggers - their owner's TRIGGER privilege is
--    deliberately revoked, like peo_families - so they get audit checks as the compensating control.

-- LEVEL 2: RE-SWEEP WITH THE MATCHER THAT WORKS.
set role peo_gatekeeper;

update public.companies c
   set peo_original = null
 where c.merged_into is null and c.peo_original is not null
   and public.names_a_non_peo_fast(c.peo_original);

update public.peo_switch_ledger l
   set switch_scope = 'intra_family',
       triage_reason = coalesce(l.triage_reason,'') ||
         ' || 0894: RETIRED - one side is not a PEO. Missed by the 0880 sweep because the name carried an entity suffix and the matcher did not strip them.'
 where l.switch_scope is distinct from 'intra_family'
   and ((l.from_family_slug is not null and public.names_a_non_peo_fast(l.from_family_slug))
     or (l.to_family_slug   is not null and public.names_a_non_peo_fast(l.to_family_slug)));

update public.peo_alias_registry a
   set identity_quarantined_at = now(),
       identity_quarantine_reason = 'NOT A PEO (0894 re-sweep): missed by the 0890 pass because the alias carried an entity suffix. Never canonicalize a name to this family.'
 where a.identity_quarantined_at is null
   and public.names_a_non_peo_fast(a.alias_raw);

-- LEVEL 1a: peo_original gets the gate it was listed for but never given.
create or replace function public.trg_companies_peo_admission()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v text; v_arr text[];
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
      new.peo_user_status := null;
    end if;
  end if;

  if new.peo_name is not null
     and (tg_op = 'INSERT' or new.peo_name is distinct from old.peo_name)
     and public.names_a_non_peo_fast(new.peo_name) then
    perform public.peo_admission_log(coalesce(new.peo_family_slug, '(name only)'), new.peo_name, 'blocked_name_only',
      format('display name stripped on companies.%s for company %s', tg_op, new.id));
    new.peo_name := null;
    if new.peo_family_slug is null then
      new.peo_current := false; new.peo_user_status := null;
    end if;
  end if;

  -- peo_original: listed in the trigger's UPDATE OF since 0893, never actually checked until now.
  -- 944 companies were carrying \"PLUSONE SOLUTIONS LLC\" here through three separate removals.
  if new.peo_original is not null
     and (tg_op = 'INSERT' or new.peo_original is distinct from old.peo_original)
     and public.names_a_non_peo_fast(new.peo_original) then
    perform public.peo_admission_log(coalesce(new.peo_family_slug,'(original only)'), new.peo_original,
      'blocked_original_name',
      format('peo_original stripped on companies.%s for company %s', tg_op, new.id));
    new.peo_original := null;
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

  if new.peo_prior_name is not null
     and (tg_op = 'INSERT' or new.peo_prior_name is distinct from old.peo_prior_name)
     and public.names_a_non_peo_fast(new.peo_prior_name) then
    perform public.peo_admission_log(coalesce(new.peo_prior_family_slug,'(name only)'), new.peo_prior_name,
      'blocked_prior_name_only',
      format('prior display name stripped on companies.%s for company %s', tg_op, new.id));
    new.peo_prior_name := null;
  end if;

  if new.mep_peo_slugs is not null
     and (tg_op = 'INSERT' or new.mep_peo_slugs is distinct from old.mep_peo_slugs) then
    select array_agg(s) into v_arr
      from unnest(new.mep_peo_slugs) s
     where not exists (select 1 from not_a_peo_slugs n where n.slug = s);
    if coalesce(array_length(v_arr,1),0) < coalesce(array_length(new.mep_peo_slugs,1),0) then
      perform public.peo_admission_log('(mep_peo_slugs)', null, 'blocked_mep_array',
        format('blocked slug removed from mep_peo_slugs on companies.%s for company %s', tg_op, new.id));
      new.mep_peo_slugs := nullif(v_arr, '{}');
    end if;
  end if;

  return new;
end $f$;

reset role;

-- LEVEL 1b: DOORS ON THE TWO SPINES THAT HAD NONE.
create or replace function public.trg_participant_peo_admission()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $f$
begin
  if new.peo_slug is not null and public.names_a_non_peo_fast(new.peo_slug) then
    if new.identity_trust is null or new.identity_trust not like 'SUPERSEDED%' then
      new.identity_trust := 'SUPERSEDED: peo_slug ' || new.peo_slug ||
        ' is ruled NOT A PEO; refused at the participant door (0894). ' || coalesce(new.identity_trust,'');
    end if;
    perform public.peo_admission_log(new.peo_slug, new.employer_name_raw, 'blocked_participant_row',
      format('form5500_mep_participants row born SUPERSEDED on %s', tg_op));
  end if;
  return new;
end $f$;
revoke execute on function public.trg_participant_peo_admission() from public, anon;

drop trigger if exists participants_peo_admission_gate on public.form5500_mep_participants;
create trigger participants_peo_admission_gate
  before insert or update of peo_slug on public.form5500_mep_participants
  for each row execute function public.trg_participant_peo_admission();

create or replace function public.trg_sponsor_ein_peo_admission()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $f$
begin
  -- EIN is king, so a blocked family holding one is how it resurrects. The row is kept (DELETE is
  -- revoked platform-wide) but retired into a slug nothing can join to.
  if new.family_slug is not null
     and new.family_slug not like 'NOT_A_PEO_RETIRED::%'
     and public.names_a_non_peo_fast(new.family_slug) then
    perform public.peo_admission_log(new.family_slug, new.sponsor_ein, 'blocked_sponsor_ein',
      format('peo_sponsor_eins row retired on %s for EIN %s', tg_op, new.sponsor_ein));
    new.family_slug := 'NOT_A_PEO_RETIRED::' || new.family_slug;
  end if;
  return new;
end $f$;
revoke execute on function public.trg_sponsor_ein_peo_admission() from public, anon;

drop trigger if exists sponsor_ein_peo_admission_gate on public.peo_sponsor_eins;
create trigger sponsor_ein_peo_admission_gate
  before insert or update of family_slug on public.peo_sponsor_eins
  for each row execute function public.trg_sponsor_ein_peo_admission();

-- LEVEL 3: THE CHECKS USE THE CORRECTED MATCHER, AND COVER WHAT THEY MISSED.
set role peo_gatekeeper;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('not_a_peo_named_in_any_company_field', 'mesh_law', 'fast', 'II.3', 'RED',
 'No company field may name something ruled NOT A PEO, under the SUFFIX-STRIPPED matcher - not peo_name, peo_original, peo_prior_name, peo_entry_from or peo_exit_to. 944 companies still said their original PEO was \"PLUSONE SOLUTIONS LLC\" on 2026-09-12, through three removals, because the old matcher could not see past the LLC and every check used that same matcher.',
 'select c.id::text as company_id, coalesce(c.peo_name, c.peo_original, c.peo_prior_name) as offending_value from public.companies c where c.merged_into is null and ((c.peo_name is not null and public.names_a_non_peo_fast(c.peo_name)) or (c.peo_original is not null and public.names_a_non_peo_fast(c.peo_original)) or (c.peo_prior_name is not null and public.names_a_non_peo_fast(c.peo_prior_name)) or (c.peo_entry_from is not null and public.names_a_non_peo_fast(c.peo_entry_from)) or (c.peo_exit_to is not null and public.names_a_non_peo_fast(c.peo_exit_to))) limit 200',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as company_id, ''y''::text as offending_value',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('not_a_peo_in_fenced_ledgers', 'mesh_law', 'fast', 'II.3', 'RED',
 'peo_switch_ledger and peo_alias_registry cannot carry triggers - their owner''s TRIGGER privilege is revoked on purpose, like peo_families. This is the compensating control: no live switch leg and no live alias may name something ruled NOT A PEO under the suffix-stripped matcher. The 0880 sweep left 2 switch legs and 8 aliases behind for exactly that reason.',
 'select ''peo_switch_ledger''::text as spine, count(*)::bigint as n from public.peo_switch_ledger l where l.switch_scope is distinct from ''intra_family'' and ((l.from_family_slug is not null and public.names_a_non_peo_fast(l.from_family_slug)) or (l.to_family_slug is not null and public.names_a_non_peo_fast(l.to_family_slug))) having count(*) > 0 union all select ''peo_alias_registry'', count(*)::bigint from public.peo_alias_registry a where a.identity_quarantined_at is null and public.names_a_non_peo_fast(a.alias_raw) having count(*) > 0',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as spine, 1::bigint as n',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

update public.sysaudit_registry
   set check_sql = 'with want as (select unnest(array[''companies_peo_admission_gate'',''participants_peo_admission_gate'',''sponsor_ein_peo_admission_gate'']) as tg), cols as (select unnest(array[''peo_family_slug'',''peo_brand_slug'',''peo_name'',''peo_original'',''peo_prior_family_slug'',''peo_prior_brand_slug'',''peo_prior_name'',''mep_peo_slugs'']) as col), got as (select a.attname::text as col from pg_trigger g join pg_class c on c.oid = g.tgrelid join pg_attribute a on a.attrelid = c.oid and a.attnum = any(g.tgattr) where g.tgname = ''companies_peo_admission_gate'' and not g.tgisinternal) select w.tg as problem from want w where not exists (select 1 from pg_trigger g where g.tgname = w.tg and not g.tgisinternal and g.tgenabled <> ''D'') union all select ''companies gate stopped watching '' || cols.col from cols where not exists (select 1 from got where got.col = cols.col)',
       description = 'All three admission-gate triggers must exist, be enabled, and the companies gate must still watch every column it guards. 0892 added mep_peo_slugs protection to the body but not the UPDATE OF list, so the code was unreachable; 0893 added peo_original to the list but no body check, so it was unwatched in the other direction. Watching the enabled flag alone passes both.'
 where check_name = 'non_peo_admission_gate_armed';

reset role;

-- VERIFICATION
select (select count(*) from public.companies c where c.merged_into is null and c.peo_original is not null
          and public.names_a_non_peo_fast(c.peo_original)) as peo_original_left,
       (select count(*) from public.peo_switch_ledger l where l.switch_scope is distinct from 'intra_family'
          and ((l.from_family_slug is not null and public.names_a_non_peo_fast(l.from_family_slug))
            or (l.to_family_slug is not null and public.names_a_non_peo_fast(l.to_family_slug)))) as switch_legs_left,
       (select count(*) from public.peo_alias_registry a where a.identity_quarantined_at is null
          and public.names_a_non_peo_fast(a.alias_raw)) as aliases_left;"}

-- ===== 0895_the_field_check_tests_distinct_names_not_every_row =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0894-rerun-the-sweep-with-the-fixed-matcher
-- Articles implemented: II.3, slow-check budget, sysaudit_executes_as_sysaudit_reader
-- Articles verified not violated: III.1, XIII.1
-- Verification query attached: YES
--
-- not_a_peo_named_in_any_company_field, which I wrote one migration ago, took 23.2 SECONDS and pushed the
-- whole fast run from 84s to 108s. It calls names_a_non_peo_fast() once per COMPANY per FIELD - about
-- 1.25 million evaluations. It passes today and it will time out as the book grows, exactly the way three
-- earlier checks of mine did (0885, 0887, the 0880 backfill).
--
-- The question is about NAMES, and there are 897 distinct peo_name values and 1,026 distinct peo_original
-- values across 250,303 live companies. Test the ~1,900 distinct names, then find the rows that carry a
-- bad one. About 650x less work for an identical answer.
--
-- I have now made this same mistake five times in one day. It is written into the session doc as a rule:
-- inside an audit check, evaluate a predicate once per DISTINCT VALUE, never once per row.

set role peo_gatekeeper;

update public.sysaudit_registry
   set check_sql = 'with vals as (select distinct v from (select peo_name as v from public.companies where merged_into is null and peo_name is not null union select peo_original from public.companies where merged_into is null and peo_original is not null union select peo_prior_name from public.companies where merged_into is null and peo_prior_name is not null union select peo_entry_from from public.companies where merged_into is null and peo_entry_from is not null union select peo_exit_to from public.companies where merged_into is null and peo_exit_to is not null) u), bad as (select v from vals where public.names_a_non_peo_fast(v)) select b.v as offending_value, (select count(*)::bigint from public.companies c where c.merged_into is null and (c.peo_name = b.v or c.peo_original = b.v or c.peo_prior_name = b.v or c.peo_entry_from = b.v or c.peo_exit_to = b.v)) as n from bad b limit 200',
       selftest_sql = 'select ''x''::text as offending_value, 1::bigint as n',
       description = 'No company field may name something ruled NOT A PEO, under the SUFFIX-STRIPPED matcher - not peo_name, peo_original, peo_prior_name, peo_entry_from or peo_exit_to. 944 companies still said their original PEO was \"PLUSONE SOLUTIONS LLC\" on 2026-09-12, through three separate removals, because the old matcher could not see past the LLC and every check used that same matcher. Evaluated once per DISTINCT NAME (about 1,900) rather than once per company field (about 1.25 million); the per-row shape took 23 seconds and would have timed out as the book grew.'
 where check_name = 'not_a_peo_named_in_any_company_field';

reset role;

-- VERIFICATION: same answer, and how long it now takes.
with vals as (
  select distinct v from (
    select peo_name as v from public.companies where merged_into is null and peo_name is not null
    union select peo_original from public.companies where merged_into is null and peo_original is not null
    union select peo_prior_name from public.companies where merged_into is null and peo_prior_name is not null
  ) u)
select count(*) filter (where public.names_a_non_peo_fast(v)) as offending_names,
       count(*) as distinct_names_tested
from vals;"}

-- ===== 0896_one_scan_not_five_the_field_check_finally_earns_its_place =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0894-rerun-the-sweep-with-the-fixed-matcher
-- Articles implemented: II.3, slow-check budget
-- Articles verified not violated: III.1, XIII.1
-- Verification query attached: YES
--
-- 0895 rewrote this check to test distinct NAMES instead of every row - the right instinct - and it made
-- no difference at all: still 24 seconds. I assumed the cost was the function calls and never measured.
-- It was not. It was FIVE separate \"select distinct <col> from companies\" scans, each a full sequential
-- pass over 250,303 rows under row level security.
--
-- One pass with a lateral VALUES unpivot gets the same 1,459 distinct names: 819ms, measured.
-- 29x faster than the version I shipped one migration ago as the fix.
--
-- The lesson is narrower than \"avoid per-row predicates\", which is what I wrote down last time. It is:
-- MEASURE THE FIX. 0895 reasoned about where the cost was, changed the shape, declared it solved, and
-- shipped something exactly as slow. An explain analyze would have taken thirty seconds.

set role peo_gatekeeper;

update public.sysaudit_registry
   set check_sql = 'with vals as (select distinct u.v from public.companies c cross join lateral (values (c.peo_name),(c.peo_original),(c.peo_prior_name),(c.peo_entry_from),(c.peo_exit_to)) as u(v) where c.merged_into is null and u.v is not null), bad as (select v from vals where public.names_a_non_peo_fast(v)) select b.v as offending_value, (select count(*)::bigint from public.companies c where c.merged_into is null and (c.peo_name = b.v or c.peo_original = b.v or c.peo_prior_name = b.v or c.peo_entry_from = b.v or c.peo_exit_to = b.v)) as n from bad b limit 200',
       description = 'No company field may name something ruled NOT A PEO, under the SUFFIX-STRIPPED matcher - not peo_name, peo_original, peo_prior_name, peo_entry_from or peo_exit_to. 944 companies still said their original PEO was \"PLUSONE SOLUTIONS LLC\" on 2026-09-12, through three separate removals, because the old matcher could not see past the LLC and every check used that same matcher. Reads the five fields in ONE pass over companies via a lateral unpivot and tests the 1,459 distinct names: 819ms. The per-row shape took 24s, and so did the distinct-per-column rewrite that was supposed to fix it - the cost was five sequential scans, not the predicate.'
 where check_name = 'not_a_peo_named_in_any_company_field';

reset role;

select 'applied' as status;"}

-- ===== 0897_materialized_so_the_planner_cannot_undo_the_optimisation =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0894-rerun-the-sweep-with-the-fixed-matcher
-- Articles implemented: II.3, slow-check budget
-- Articles verified not violated: III.1, XIII.1
-- Verification query attached: YES
--
-- Third attempt at this one check, and the first two failed for a reason I had not even guessed at.
--
-- 0895: rewrote it to test distinct NAMES instead of rows. No change - still 24s.
-- 0896: collapsed five scans into one lateral unpivot. Measured 819ms in my own session, shipped it.
--       Still 24s in the audit runner.
--
-- What was actually happening: THE PLANNER PUSHED THE PREDICATE BELOW THE DISTINCT. explain analyze on
-- the real check SQL shows names_a_non_peo_fast() evaluated inside the Values Scan - 429,550 times,
-- 2.6 million buffer hits - instead of on the 1,459 distinct names the CTE produces. My \"test distinct
-- values\" rewrite was silently undone by the optimiser, twice, and I never looked at a plan for the
-- actual check query. My 819ms measurement in 0896 was of a DIFFERENT query shape (count(*) filter),
-- where the predicate could not be pushed down. I measured something else and called it proof.
--
-- WITH ... AS MATERIALIZED forbids the pushdown. Same answer, 851ms, and the plan confirms the filter
-- runs on 1,459 rows with 1,459 removed.
--
-- Rule for the session doc: for an audit check, read the EXPLAIN of the exact SQL the registry stores,
-- not of a query that resembles it. A CTE is a hint, not a fence, unless you say MATERIALIZED.

set role peo_gatekeeper;

update public.sysaudit_registry
   set check_sql = 'with vals as materialized (select distinct u.v from public.companies c cross join lateral (values (c.peo_name),(c.peo_original),(c.peo_prior_name),(c.peo_entry_from),(c.peo_exit_to)) as u(v) where c.merged_into is null and u.v is not null), bad as materialized (select v from vals where public.names_a_non_peo_fast(v)) select b.v as offending_value, (select count(*)::bigint from public.companies c where c.merged_into is null and (c.peo_name = b.v or c.peo_original = b.v or c.peo_prior_name = b.v or c.peo_entry_from = b.v or c.peo_exit_to = b.v)) as n from bad b limit 200',
       description = 'No company field may name something ruled NOT A PEO under the suffix-stripped matcher - peo_name, peo_original, peo_prior_name, peo_entry_from, peo_exit_to. 944 companies still said their original PEO was \"PLUSONE SOLUTIONS LLC\" on 2026-09-12, through three removals, because the old matcher could not see past the LLC and every check shared that matcher. Both CTEs are MATERIALIZED: without it the planner pushes the predicate below the DISTINCT and evaluates it 429,550 times instead of 1,459, which is why two earlier rewrites of this check changed nothing.'
 where check_name = 'not_a_peo_named_in_any_company_field';

reset role;

select 'applied' as status;"}
