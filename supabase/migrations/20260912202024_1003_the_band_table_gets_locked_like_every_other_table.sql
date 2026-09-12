-- =====================================================================
-- CONSTITUTIONAL COMPLIANCE
-- Migration : 1003_the_band_table_gets_locked_like_every_other_table
-- Area      : mesh_law            Holder: instanceA        Band: a (1000-1999)
-- Claim     : instanceA-0938-migration-number-bands
-- Article   : XI.1 (mechanical)
-- Why       : migration_band is a new public table. Row security before the
--             audit has to tell me, not after. Same pattern as 0906.
-- Safety    : one table. No company data. No display surface.
-- =====================================================================

alter table public.migration_band enable row level security;

drop policy if exists migration_band_read on public.migration_band;
create policy migration_band_read on public.migration_band
  for select to authenticated, service_role using (true);
;