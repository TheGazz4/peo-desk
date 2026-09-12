-- =====================================================================
-- CONSTITUTIONAL COMPLIANCE
-- Migration : 1001_the_allocator_guard_follows_the_allocator_into_bands
-- Area      : mesh_law            Holder: instanceA        Band: a (1000-1999)
-- Claim     : instanceA-0938-migration-number-bands
-- Article   : XI.1 (mechanical)
-- Why       : migration_allocator_behind_repo (added in 0917) compared the
--             single shared sequence against the whole repo ceiling. 0938
--             retired that sequence, so the check now reads 938 vs 1000 and
--             would sit permanently RED for a reason that no longer exists -
--             exactly the dead-alarm failure this whole thread was about.
--             Rewritten to test the thing that is now true: every BAND's
--             sequence must sit at or above the highest number already used
--             inside that band.
-- Safety    : one check. No data touched.
-- =====================================================================

set role peo_gatekeeper;

update public.sysaudit_registry set
  description = 'Every migration-number band sequence sits at or above the highest number already used inside its own band. If a band falls behind, that instance can be handed a number it already shipped.',
  check_sql = $sql$select b.band_key,
       coalesce(pg_sequence_last_value(b.seq_name::regclass), b.band_lo - 1)::bigint as band_seq_at,
       max((substring(m.name from '^(\d{4})'))::int)::bigint as band_ceiling
  from public.migration_band b
  join supabase_migrations.schema_migrations m
    on m.name ~ '^\d{4}'
   and (substring(m.name from '^(\d{4})'))::int between b.band_lo and b.band_hi
 group by b.band_key, b.seq_name, b.band_lo
having coalesce(pg_sequence_last_value(b.seq_name::regclass), b.band_lo - 1)
     < max((substring(m.name from '^(\d{4})'))::int)
 limit 50$sql$,
  selftest_sql = $st$select 'x'::text as band_key, 1::bigint as band_seq_at, 999::bigint as band_ceiling$st$
where check_name = 'migration_allocator_behind_repo';

reset role;
;