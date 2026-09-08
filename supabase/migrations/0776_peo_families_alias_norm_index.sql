-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-seed-observation-backfill
-- Articles implemented: NAME NORMALIZATION PROTOCOL (indexed so canonicalisation is cheap
--   everywhere, not just in this backfill)
-- Articles verified not violated: none touched; index only
-- Verification query attached: YES

-- 0776  The seed backfill canonicalises every vendor PEO string through
--       peo_families by normalised alias. With no index that is a full scan of
--       the alias table per company, and 0775 timed out at 50,000. Same defect
--       class as the twin-guard index (0751): the law was right, the lookup was
--       unindexed. Every lane that canonicalises a PEO name gets this for free.

set role peo_gatekeeper;

create index if not exists peo_families_alias_norm_idx
  on public.peo_families (regexp_replace(upper(alias), '[^A-Z0-9]', '', 'g'));

reset role;

do $verify$
begin
  if not exists (select 1 from pg_indexes
                 where schemaname='public' and indexname='peo_families_alias_norm_idx') then
    raise exception '0776 verification: alias normalisation index not created';
  end if;
  raise notice '0776 OK';
end $verify$;