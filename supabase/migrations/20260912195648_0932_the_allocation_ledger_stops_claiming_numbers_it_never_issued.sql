-- =====================================================================
-- CONSTITUTIONAL COMPLIANCE
-- Migration : 0932_the_allocation_ledger_stops_claiming_numbers_it_never_issued
-- Area      : mesh_law            Holder: instanceA
-- Claim     : instanceA-0932-allocation-ledger-honesty
-- Article   : XI.1 (mechanical)
-- Why       : My own 0904 backfilled migration_allocation with
--             generate_series(893,904) marked holder='instanceA'. Those rows
--             read as allocations this instance was issued. They were not -
--             they were recorded after the fact, and every one of those
--             numbers was ALSO used by another instance. Marking them for
--             what they are.
-- Second, structural: migration_allocation has PRIMARY KEY (migration_no).
--             One row per number means the table is incapable of recording
--             that two instances used the same number - it cannot represent
--             the very collision it exists to prevent. Recorded as a known
--             limitation; changing the key would need coordination with the
--             other instances that read this table, so it is flagged to Gazz
--             rather than changed unilaterally.
-- Safety    : allocation bookkeeping only. No company data, no display.
-- =====================================================================

update public.migration_allocation
   set holder = 'instanceA (retro-recorded in 0904, not issued by the allocator; number also used by another instance)'
 where migration_no between '0893' and '0906'
   and holder = 'instanceA';

update public.brain_knowledge set content = content || E'\n\nALLOCATION LEDGER, measured 2026-09-12 19:55 UTC. Since 2026-09-01: 350 migration files applied across 284 distinct numbers; 274 of those files have NO row in migration_allocation at all. migration_allocation holds 61 rows total and exactly 1 of them names the file it was used for (used_as_name). STRUCTURAL LIMIT: migration_allocation is PRIMARY KEY (migration_no), one row per number, so it can never record that two instances used the same number - it cannot represent the collision it exists to prevent. Rows 0893-0906 marked holder=instanceA were retro-recorded by migration 0904, not issued by the allocator, and each of those numbers was also used by another instance.'
 where key = 'migration_number_collision_2026_09_12';
;