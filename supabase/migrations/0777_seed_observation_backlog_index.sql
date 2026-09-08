-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-seed-observation-backfill
-- Articles implemented: none new; performance only
-- Articles verified not violated: none touched; partial index only
-- Verification query attached: YES

-- 0777  The backfill's "what is still missing" test scans field_observations for
--       a seed row per company. As seed rows accumulate that scan grows and the
--       selection step began timing out mid-run. A partial index on exactly that
--       predicate makes the backlog test constant-time, and also makes
--       hub_brain_seed()'s coverage report cheap.

set role peo_gatekeeper;

create index if not exists field_observations_seed_peo_name_idx
  on public.field_observations (company_id)
  where source_hub like 'seed:%' and field_name = 'peo_name';

reset role;

do $verify$
begin
  if not exists (select 1 from pg_indexes
                 where schemaname='public' and indexname='field_observations_seed_peo_name_idx') then
    raise exception '0777 verification: seed backlog index not created';
  end if;
  raise notice '0777 OK';
end $verify$;