-- ===== 0892_the_gate_covers_the_name_and_the_array_not_just_the_slug =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0892-gate-covers-name-and-array (opened BEFORE apply)
-- Articles implemented: II.3, ONE-DOOR LAW, fix-at-the-core level 1, vacuous-pass guard
-- Articles verified not violated: III.1, XIII.1, noncompete fence, switch_detection_nightly hold
-- Verification query attached: YES
--
-- Audited 0891. Two holes in the gate itself, both proven by probe before fixing:
--
--   update companies set peo_name = 'Entertainment Partners' where ...   -> SURVIVED
--   update companies set mep_peo_slugs = array['elitestaffing'] where ... -> SURVIVED
--
-- 1. THE GATE ONLY LOOKED AT peo_name WHEN A SLUG WAS ALSO BEING SET. Its whole body sits inside
--    \"if new.peo_family_slug is not null\". So a write that sets the display name alone - the exact
--    shape my own 0878 PlusOne cleanup left behind on 1,504 companies - walks straight through. I fixed
--    that data in 0881 and never stopped it recurring. peo_name is a customer-facing field; a company
--    reading \"your PEO: Entertainment Partners\" is wrong whether or not a slug sits behind it.
--
-- 2. THE GATE IGNORED mep_peo_slugs ENTIRELY. 0881 cleaned the arrays once. Nothing stopped a blocked
--    slug going straight back in, and no audit check looked at the array either - so it would not even
--    have been noticed.
--
-- PERFORMANCE. The name check runs on every write that touches peo_name, which is far more traffic than
-- slug changes. names_a_non_peo() costs ~1.7ms on a MISS, and a miss is the normal case - it falls
-- through to 68 anchored regexes. names_a_non_peo_fast() does the four indexed equality lookups and stops.
-- To make sure the fast door is never weaker than the regex door, a new check proves every pattern in
-- not_a_peo_registry has at least one enumerated name backing it in not_a_peo_names.
--
-- CHECKED AND CLEAR, reported not fixed: keying the door on norm_company_name also feeds
-- target_exclusion_patterns, so these firms are excluded as SALES TARGETS too. Measured: 10 live
-- companies, one per firm, and every one of them is the vendor itself. No collateral damage.

create or replace function public.names_a_non_peo_fast(p text)
returns boolean language sql stable set search_path to 'public','pg_catalog' as $f$
  select case
    when p is null or btrim(p) = '' then false
    when exists (select 1 from public.not_a_peo_slugs n where n.slug = p) then true
    when exists (select 1 from public.not_a_peo_names m where m.name_raw = p) then true
    when exists (select 1 from public.not_a_peo_names m where m.name_raw = public.name_norm(p)) then true
    when nullif(btrim(public.norm_company_name(p)),'') is not null
         and exists (select 1 from public.not_a_peo_names m where m.name_key = public.norm_company_name(p)) then true
    else false
  end;
$f$;
comment on function public.names_a_non_peo_fast(text) is
  'The hot-path name check: four indexed equality lookups, no regex fallback. names_a_non_peo() costs ~1.7ms on a miss and a miss is the normal case. Kept honest by the not_a_peo_pattern_has_named_backing check, which proves every regex pattern also has an enumerated name here.';
revoke execute on function public.names_a_non_peo_fast(text) from public, anon;
grant execute on function public.names_a_non_peo_fast(text) to service_role, postgres, peo_gatekeeper, sysaudit_reader;

set role peo_gatekeeper;

create or replace function public.trg_companies_peo_admission()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v text; v_arr text[];
begin
  -- CURRENT LEG, by slug
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

  -- CURRENT LEG, by NAME ALONE. peo_name is a customer-facing field and a write can set it with no slug -
  -- which is exactly the shape my 0878 PlusOne cleanup left on 1,504 companies.
  if new.peo_name is not null
     and (tg_op = 'INSERT' or new.peo_name is distinct from old.peo_name)
     and public.names_a_non_peo_fast(new.peo_name) then
    perform public.peo_admission_log(coalesce(new.peo_family_slug, '(name only)'), new.peo_name, 'blocked_name_only',
      format('display name stripped on companies.%s for company %s', tg_op, new.id));
    new.peo_name := null; new.peo_original := null;
    if new.peo_family_slug is null then
      new.peo_current := false; new.peo_user_status := null;
    end if;
  end if;

  -- PRIOR LEG
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

  -- THE MEP ARRAY. 0881 cleaned it once; nothing stopped a blocked slug going straight back in, and no
  -- check looked at it either.
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

-- The audit check now watches the array and the name-only shape too.
insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('not_a_peo_in_mep_slug_array', 'mesh_law', 'fast', 'II.3', 'RED',
 'companies.mep_peo_slugs must not contain a slug ruled NOT A PEO. 0881 cleaned the arrays once and nothing watched them afterwards - a probe on 2026-09-12 put a blocked slug straight back in and neither the gate nor any check noticed.',
 'select c.id::text as company_id, array_to_string(c.mep_peo_slugs, '','') as slugs from public.companies c where c.merged_into is null and c.mep_peo_slugs && (select coalesce(array_agg(slug), ''{}''::text[]) from public.not_a_peo_slugs) limit 200',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as company_id, ''y''::text as slugs',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

-- The fast door must never be weaker than the regex door it replaces on the hot path.
insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('not_a_peo_pattern_has_named_backing', 'mesh_law', 'fast', 'II.3', 'RED',
 'The companies trigger uses names_a_non_peo_fast(), which is equality-only - no regex - because the regex door costs 1.7ms on every miss and misses are the normal case. That is only safe while every pattern in not_a_peo_registry also has at least one enumerated spelling in not_a_peo_names. If a pattern is ever added without one, the hot path goes quietly weaker than the audit path.',
 'select r.label, r.pattern from public.not_a_peo_registry r where not exists (select 1 from public.not_a_peo_slugs s join public.not_a_peo_names m on m.slug = s.slug where s.label = r.label) limit 100',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as label, ''y''::text as pattern',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

reset role;

select 'applied' as status;"}

-- ===== 0893_the_trigger_listens_to_the_column_it_now_guards =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0892-gate-covers-name-and-array
-- Articles implemented: II.3, ONE-DOOR LAW, vacuous-pass guard
-- Articles verified not violated: III.1, XIII.1
-- Verification query attached: YES
--
-- 0892 added mep_peo_slugs guarding to the trigger BODY and left the trigger DEFINITION alone. The trigger
-- is declared BEFORE INSERT OR UPDATE OF (six named columns) and mep_peo_slugs was not one of them, so an
-- update touching only that column never fired it. The new code was unreachable.
--
-- The probe caught it immediately - \"FAIL: blocked slug survived in mep_peo_slugs\" - which is the whole
-- argument for asserting on a real write instead of reading the function body and calling it done.
-- Same class as 0886: code that looks right and can never run.

set role peo_gatekeeper;

drop trigger if exists companies_peo_admission_gate on public.companies;
create trigger companies_peo_admission_gate
  before insert or update of peo_family_slug, peo_brand_slug, peo_name, peo_original,
                            peo_prior_family_slug, peo_prior_brand_slug, peo_prior_name,
                            mep_peo_slugs
  on public.companies
  for each row execute function public.trg_companies_peo_admission();

update public.sysaudit_registry
   set check_sql = 'with want as (select unnest(array[''peo_family_slug'',''peo_brand_slug'',''peo_name'',''peo_original'',''peo_prior_family_slug'',''peo_prior_brand_slug'',''peo_prior_name'',''mep_peo_slugs'']) as col), got as (select a.attname::text as col from pg_trigger g join pg_class c on c.oid = g.tgrelid join pg_attribute a on a.attrelid = c.oid and a.attnum = any(g.tgattr) where g.tgname = ''companies_peo_admission_gate'' and not g.tgisinternal) select w.col as missing_watched_column from want w where not exists (select 1 from got where got.col = w.col) union all select ''TRIGGER_MISSING_OR_DISABLED'' where not exists (select 1 from pg_trigger g where g.tgname = ''companies_peo_admission_gate'' and not g.tgisinternal and g.tgenabled <> ''D'')',
       description = 'The companies admission-gate trigger must exist, be enabled, AND still watch every column it guards. 0892 added mep_peo_slugs protection to the trigger body but not to its UPDATE OF list, so the new code was unreachable and a blocked slug went straight back into the array. Watching the enabled flag alone would have passed that.'
 where check_name = 'non_peo_admission_gate_armed';

reset role;

select 'applied' as status;"}
