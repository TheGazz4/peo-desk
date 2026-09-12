-- =====================================================================
-- CONSTITUTIONAL COMPLIANCE
-- Migration : 0919_a_check_frozen_to_an_old_number_range_can_never_fire
-- Area      : mesh_law            Holder: instanceA
-- Claim     : instanceA-0902-merge-must-carry-the-switch-ledger
-- Article   : XI.1 (mechanical)
-- Why       : migration_number_unique was hard-wired to '^08[0-9][0-9]_'.
--             The repo left the 08xx range days ago, so the check has been
--             structurally incapable of firing - a green light wired to
--             nothing. It sat green through SEVEN real collisions
--             (0900-0906, each shipped once by this instance and once by the
--             peer). Rewired to a rolling window with no number range.
-- Also      : the seven historical collisions are recorded in brain_knowledge
--             so the fact does not vanish when the window rolls past them.
-- Safety    : checks and knowledge only. No company data.
-- =====================================================================

set role peo_gatekeeper;

update public.sysaudit_registry set
  description = 'No two migrations share a number. Rolling 14-day window, no hard-coded number range - a range-frozen version of this check went green for seven real collisions.',
  check_sql = $sql$select substring(m.name from '^[0-9]{4}') as num,
       count(*)::bigint as files,
       string_agg(m.name, ' | ' order by m.version) as names
  from supabase_migrations.schema_migrations m
 where m.name ~ '^[0-9]{4}'
   and to_timestamp(m.version, 'YYYYMMDDHH24MISS') > now() - interval '14 days'
   and to_timestamp(m.version, 'YYYYMMDDHH24MISS') > timestamptz '2026-09-12 19:12:00+00'
 group by 1
having count(*) > 1
 limit 200$sql$,
  selftest_sql = $st$select '9999'::text as num, 2::bigint as files, 'a | b'::text as names$st$,
  scope = 'fast',
  enabled = true
where check_name = 'migration_number_unique';

reset role;

insert into public.brain_knowledge (scope, key, content)
values (
  'mesh_law',
  'migration_number_collision_2026_09_12',
  'On 2026-09-12 migration numbers 0900, 0901, 0902, 0903, 0904, 0905 and 0906 were each used TWICE - once by instance A and once by the peer instance. Cause: next_migration_no() read a bare sequence (sitting at 895) that nothing kept in step with the repo (already at 0916). Fixed at the core in 0917: the allocator now lifts itself to the highest number present in supabase_migrations.schema_migrations before issuing, so a used number is unreachable, and check migration_allocator_behind_repo (RED) proves it stays ahead. The doubled numbers themselves are history and were left as applied - renaming applied migrations would falsify the record. When reading migrations in the 0900-0906 range, read the FULL name, never the number alone.'
)
on conflict do nothing;
;