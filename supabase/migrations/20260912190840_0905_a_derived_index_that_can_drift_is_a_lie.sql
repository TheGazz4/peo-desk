-- =====================================================================
-- Migration : 0905_a_derived_index_that_can_drift_is_a_lie
-- Area      : mesh_law            Holder: instanceA
-- Claim     : instanceA-0902-merge-must-carry-the-switch-ledger
-- Article   : II.3 / XI.1
-- Why       : 0904 made is_target_excluded() read a DERIVED index instead of
--             scanning the patterns. A derived index that silently drifts
--             would quietly re-admit an excluded company. The trigger keeps
--             it in sync; this check proves the trigger is doing its job.
-- Two gotchas in sysaudit_sql_readonly_ok(), both hit on the way here:
--   1. it rejects any check_sql containing two adjacent dollar signs, so the
--      anchored-literal test is written [$]$ instead of \$$.
--   2. it btrim()s, which strips spaces but NOT newlines, so check_sql must
--      begin with the word 'with'/'select' on the very first character.
-- Safety    : read-only check. No data touched.
-- =====================================================================

grant select on public.target_exclusion_patterns to sysaudit_reader;

set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, article, module, scope, severity, description,
   check_sql, expectation, enabled, created_by, selftest_sql)
values (
  'target_exclusion_index_drifted',
  'II.3',
  'mesh_law',
  'fast',
  'RED',
  'The literal/regex index that is_target_excluded() reads must match target_exclusion_patterns exactly. If it drifts, an excluded company silently becomes targetable again.',
$sql$with expect_lit as (
  select distinct upper(substring(a.alt from 2 for length(a.alt)-2)) as lit_key, t.id as pattern_id
    from public.target_exclusion_patterns t,
         lateral unnest(string_to_array(t.pattern,'|')) a(alt)
   where not exists (select 1 from lateral unnest(string_to_array(t.pattern,'|')) b(x)
                      where b.x !~ '^\^[A-Za-z0-9 ]+[$]$')
), expect_rx as (
  select t.id as pattern_id, t.pattern
    from public.target_exclusion_patterns t
   where exists (select 1 from lateral unnest(string_to_array(t.pattern,'|')) b(x)
                  where b.x !~ '^\^[A-Za-z0-9 ]+[$]$')
)
select 'literal_missing'::text as problem, e.lit_key::text as detail
  from expect_lit e
  left join public.target_exclusion_literal l
         on l.lit_key = e.lit_key and l.pattern_id = e.pattern_id
 where l.lit_key is null
union all
select 'literal_orphan'::text, l.lit_key::text
  from public.target_exclusion_literal l
  left join expect_lit e on e.lit_key = l.lit_key and e.pattern_id = l.pattern_id
 where e.lit_key is null
union all
select 'regex_missing'::text, e.pattern::text
  from expect_rx e
  left join public.target_exclusion_regex r on r.pattern_id = e.pattern_id
 where r.pattern_id is null
union all
select 'regex_orphan'::text, r.pattern::text
  from public.target_exclusion_regex r
  left join expect_rx e on e.pattern_id = r.pattern_id
 where e.pattern_id is null
limit 200$sql$,
  '{"mode":"zero_rows"}'::jsonb,
  true,
  'instanceA-0905',
  $st$select 'literal_missing'::text as problem, 'SYNTHETIC DRIFT ROW'::text as detail$st$
)
on conflict (check_name) do update set
  check_sql    = excluded.check_sql,
  selftest_sql = excluded.selftest_sql,
  description  = excluded.description,
  severity     = excluded.severity,
  scope        = excluded.scope,
  enabled      = true;

reset role;
;