-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-tx-liveness-and-peo-codes
-- Articles implemented: none new; performance only
-- Articles verified not violated: none touched; partial index only
-- Verification query attached: YES

-- 0786  The TX projection selects leasing-coded rows out of a 6.76M-row staging
--       table. With the pump widened to the whole Texas WC universe, code 1
--       (6.5M ordinary employers) dominates and an unindexed scan of the leasing
--       codes times out. A partial index on exactly the projectable predicate
--       keeps the projection cheap no matter how wide the pump gets.

create index if not exists tx_wc_staging_leasing_code_idx
  on public.tx_wc_fingerprint_staging (peo_leasing_flag, insured_employer_name)
  where peo_leasing_flag is not null and peo_leasing_flag::text <> '1';

do $verify$
begin
  if not exists (select 1 from pg_indexes
                 where schemaname='public' and indexname='tx_wc_staging_leasing_code_idx') then
    raise exception '0786 verification: leasing-code index not created';
  end if;
  raise notice '0786 OK';
end $verify$;