-- =====================================================================
-- CONSTITUTIONAL COMPLIANCE
-- Migration : 0921_the_collision_alarm_moves_into_the_room_people_enter
-- Area      : mesh_law            Holder: instanceA
-- Claim     : instanceA-0902-merge-must-carry-the-switch-ledger
-- Article   : XI.1 (mechanical)
-- Why       : migration_number_collision was already RED and already correct.
--             It sat in scope 'all', which nothing runs on a schedule, so it
--             alarmed into an empty room while 51 numbers collided.
--             Moved to 'fast'. Window anchored at the 0917 allocator fix so
--             it reports only NEW collisions - history it cannot change is
--             recorded in brain_knowledge instead of held permanently red.
-- Honest limit: 0917 fixed the ALLOCATOR. It cannot fix a writer that never
--             calls the allocator, and at least two of the three instances
--             writing migrations here pick their own numbers. Enforcement
--             across instances is an operator decision, flagged to Gazz.
-- Safety    : checks and knowledge only. No company data.
-- =====================================================================

set role peo_gatekeeper;

update public.sysaudit_registry set
  scope = 'fast',
  description = 'No two migrations applied since the 0917 allocator fix share a number. Collisions before that point are recorded in brain_knowledge key migration_number_collision_2026_09_12.',
  check_sql = $sql$select substring(m.name from '^[0-9]{4}') as num,
       count(*)::bigint as files,
       string_agg(m.name, ' | ' order by m.version) as names
  from supabase_migrations.schema_migrations m
 where m.name ~ '^[0-9]{4}'
   and to_timestamp(m.version, 'YYYYMMDDHH24MISS') > timestamptz '2026-09-12 19:12:00+00'
 group by 1
having count(*) > 1
 limit 200$sql$,
  selftest_sql = $st$select '9999'::text as num, 2::bigint as files, 'a | b'::text as names$st$,
  enabled = true
where check_name = 'migration_number_collision';

reset role;

update public.brain_knowledge set content =
  'MIGRATION NUMBER COLLISIONS, measured 2026-09-12. 51 distinct numbers between 0726 and 0907 were each used by more than one migration; 0891 was used FOUR times; 0877, 0879, 0880, 0883-0892 and 0894 were used three times. At least THREE instances write migrations to this project: this instance (mesh_law / non-PEO / book work), a mesh_* instance (mesh_scorecard, mesh_pull, mesh_harvest), and a third (twin_merge, dedup_sweep, ein_harvest, naics). ROOT CAUSE, two parts: (1) next_migration_no() read a bare sequence that nothing kept in step with the repo - it sat at 895 while the repo was at 0916; fixed at the core in 0917, the allocator now lifts itself to the repo ceiling before issuing, and check migration_allocator_behind_repo (RED, fast) proves it stays ahead. (2) An instance that never calls claim_migration_no() is unaffected by that fix - it simply picks a number. Part 2 cannot be closed from inside the database on managed Supabase (no event trigger on supabase_migrations); it needs an operator rule that every instance allocates before applying. FLAGGED TO GAZZ, unresolved. Consequence for readers: in the 0726-0907 range a migration number does NOT identify a migration. Always read the full name. Also fixed 2026-09-12: migration_number_unique had been hard-wired to the 08xx range and was structurally incapable of firing, and migration_number_collision was correct but parked in scope all, which nothing runs - it is now in fast.'
where key = 'migration_number_collision_2026_09_12';
;