-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-seed-observation-backfill
-- Articles implemented: none new; performance only
-- Articles verified not violated: none touched; index only
-- Verification query attached: YES

-- 0779  fo_group_key(company_id, subject_class, subject_key) is the canonical
--       grouping key for the precedence sweep, and the sweep resolves each group
--       with an UPDATE ... where fo_group_key(...) = <key>. That expression was
--       unindexed, so every arbitration iteration scanned field_observations.
--       Tolerable at 600K rows and a few thousand groups; not at 1.1M rows and
--       32,000 groups after the seed backfill. Third instance of the same defect
--       class today (0751 twin guard, 0776 alias norm): the law was right, the
--       lookup was unindexed.

set role peo_gatekeeper;

create index if not exists field_observations_group_key_field_idx
  on public.field_observations (public.fo_group_key(company_id, subject_class, subject_key), field_name)
  where resolution_status is null;

reset role;

do $verify$
begin
  if not exists (select 1 from pg_indexes
                 where schemaname='public' and indexname='field_observations_group_key_field_idx') then
    raise exception '0779 verification: group-key index not created';
  end if;
  raise notice '0779 OK';
end $verify$;