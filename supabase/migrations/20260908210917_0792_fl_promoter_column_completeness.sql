-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-fl-promotion-gap-and-intake-conformance (#165)
-- Articles implemented: a promoter must carry every source field the downstream join depends on;
--                       fix-at-the-core (ingest logic + backfill of what already landed).
-- Articles verified not violated: sourcing never displayed; carrier internal-only; client street
--                       addresses never displayed; noncompete PEOs never worked.
-- Verification query attached: YES
--
-- Defect: promote_fl_raw_coverage() (0788/0789) omitted policy_number from its insert column list.
-- All 169,320 promoted rows landed with policy_number NULL, so none of them can join
-- fl_master_policy_book and none of them can reach the mesh. Found by the rebuilder reporting
-- policies_after = policies_before = 1,651 against 202,802 coverage rows.
-- Also: named_insured falls back to employer when the state file leaves it blank (15 stranded rows,
-- 2 companies).

set role peo_gatekeeper;

-- 1. BACKFILL what already landed
create or replace function public.fl_backfill_promoted_policy_numbers(p_limit int default 50000)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare v_n bigint; v_left bigint;
begin
  with tgt as (
    select c.id, r.raw
    from public.wc_coverage_fl c
    join public.wc_coverage_fl_raw r on r.id = c.raw_id
    where c.policy_number is null
      and nullif(btrim(r.raw ->> 'policy_number'), '') is not null
    limit p_limit
  )
  update public.wc_coverage_fl c
     set policy_number = nullif(btrim(t.raw ->> 'policy_number'), ''),
         named_insured = coalesce(c.named_insured, nullif(btrim(t.raw ->> 'named_insured'), ''),
                                  nullif(btrim(t.raw ->> 'employer'), ''))
    from tgt t
   where c.id = t.id;
  get diagnostics v_n = row_count;

  select count(*) into v_left from public.wc_coverage_fl where policy_number is null;
  return jsonb_build_object('updated', v_n, 'still_null_policy', v_left);
end $$;

revoke all on function public.fl_backfill_promoted_policy_numbers(int) from public, anon, authenticated;
grant execute on function public.fl_backfill_promoted_policy_numbers(int) to service_role;

-- 2. FIX THE DOOR so it can never happen again
create or replace function public.promote_fl_raw_coverage(p_limit int default 25000)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare
  v_before bigint; v_ins bigint; v_left bigint; v_avail bigint; v_key text;
begin
  select count(*) into v_before from public.wc_coverage_fl;

  select count(*) into v_avail
  from public.wc_coverage_fl_raw r
  where (r.raw ->> 'peo_client') = 'Y'
    and not exists (select 1 from public.wc_coverage_fl c where c.raw_id = r.id);

  with cand as (
    select r.id, r.raw, r.archived_at
    from public.wc_coverage_fl_raw r
    where (r.raw ->> 'peo_client') = 'Y'
      and not exists (select 1 from public.wc_coverage_fl c where c.raw_id = r.id)
    order by r.id
    limit p_limit
  )
  insert into public.wc_coverage_fl
    (state, source_ref, employer_name, named_insured, city, zip, address, address2,
     carrier, policy_number, policy_start, policy_end, policy_cancellation,
     governing_class_code, naics, county, agency_name, agency_city, agency_state,
     wrap_up_flag, employer_phone, employer_state, peo_leasing_flag, as_of, raw_id)
  select 'FL',
         nullif(btrim(c.raw ->> '_batch'), ''),
         nullif(btrim(c.raw ->> 'employer'), ''),
         coalesce(nullif(btrim(c.raw ->> 'named_insured'), ''),
                  nullif(btrim(c.raw ->> 'employer'), '')),
         nullif(btrim(c.raw ->> 'city'), ''),
         nullif(btrim(c.raw ->> 'zip'), ''),
         nullif(btrim(c.raw ->> 'addr1'), ''),
         nullif(btrim(c.raw ->> 'addr2'), ''),
         nullif(btrim(c.raw ->> 'carrier'), ''),
         nullif(btrim(c.raw ->> 'policy_number'), ''),
         public.fl_raw_date(c.raw ->> 'eff'),
         public.fl_raw_date(c.raw ->> 'exp'),
         public.fl_raw_date(c.raw ->> 'cancel'),
         nullif(btrim(c.raw ->> 'class'), ''),
         nullif(btrim(c.raw ->> 'naics'), ''),
         nullif(btrim(c.raw ->> 'county'), ''),
         nullif(btrim(c.raw ->> 'agency'), ''),
         nullif(btrim(c.raw ->> 'agency_city'), ''),
         nullif(btrim(c.raw ->> 'agency_state'), ''),
         (upper(btrim(coalesce(c.raw ->> 'wrap_up','N'))) = 'Y'),
         nullif(btrim(c.raw ->> 'phone'), ''),
         nullif(btrim(c.raw ->> 'state'), ''),
         true,
         coalesce(
           public.fl_raw_date(substring(c.raw ->> '_batch' from '(\d{4}-\d{2}-\d{2})')),
           c.archived_at::date, current_date),
         c.id
  from cand c
  where coalesce(nullif(btrim(c.raw ->> 'named_insured'), ''),
                 nullif(btrim(c.raw ->> 'employer'), '')) is not null
  on conflict (raw_id) where raw_id is not null do nothing;

  get diagnostics v_ins = row_count;

  select count(*) into v_left
  from public.wc_coverage_fl_raw r
  where (r.raw ->> 'peo_client') = 'Y'
    and not exists (select 1 from public.wc_coverage_fl c where c.raw_id = r.id);

  if v_ins > 0 then
    v_key := 'fl_raw_promote:' || to_char(now(), 'YYYYMMDDHH24MISSMS');
    insert into public.load_reconciliation
      (load_key, source_id, target_table, source_total, inserted, quarantined, skipped,
       ruleset_version, verification_query, verification_output, verified_at, created_by)
    values
      (v_key, 'fl_dwc_digital_download', 'wc_coverage_fl',
       least(v_avail, p_limit), v_ins, 0, least(v_avail, p_limit) - v_ins, '0792',
       'select count(*) from wc_coverage_fl_raw r where (r.raw->>''peo_client'')=''Y'' and not exists (select 1 from wc_coverage_fl c where c.raw_id=r.id)',
       jsonb_build_object('still_unpromoted', v_left), now(), 'promote_fl_raw_coverage');
  end if;

  return jsonb_build_object('promoted', v_ins, 'coverage_before', v_before,
    'coverage_after', v_before + v_ins, 'still_unpromoted', v_left);
end $$;

revoke all on function public.promote_fl_raw_coverage(int) from public, anon, authenticated;
grant execute on function public.promote_fl_raw_coverage(int) to service_role;

reset role;

-- VERIFICATION
-- select fl_backfill_promoted_policy_numbers(50000);   -- repeat until still_null_policy = 0
-- select count(distinct policy_number) from wc_coverage_fl;   -- must exceed 1,651