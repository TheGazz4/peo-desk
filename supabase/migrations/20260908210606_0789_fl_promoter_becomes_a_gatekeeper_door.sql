-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-fl-promotion-gap-and-intake-conformance (#165)
-- Articles implemented: writer conformance (every writer of a protected table is a gatekeeper-owned
--                       door); no fenced write without a reconciliation receipt.
-- Articles verified not violated: sourcing never displayed; carrier internal-only; client street
--                       addresses never displayed; noncompete PEOs never worked; ONE-DOOR LAW.
-- Verification query attached: YES
--
-- 0788 created promote_fl_raw_coverage() owned by postgres. wc_coverage_fl is a fenced table: only
-- peo_gatekeeper holds INSERT. The function therefore failed with "permission denied" on first call.
-- Same defect class as 0748/0761, 0780 and 0784. Recreated here as a gatekeeper-owned door, and it
-- now files a load_reconciliation receipt for every chunk it moves.

drop function if exists public.promote_fl_raw_coverage(int);

set role peo_gatekeeper;

create or replace function public.promote_fl_raw_coverage(p_limit int default 25000)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare
  v_before bigint;
  v_ins    bigint;
  v_left   bigint;
  v_avail  bigint;
  v_key    text;
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
     carrier, policy_start, policy_end, policy_cancellation, governing_class_code,
     naics, county, agency_name, agency_city, agency_state, wrap_up_flag,
     employer_phone, employer_state, peo_leasing_flag, as_of, raw_id)
  select 'FL',
         nullif(btrim(c.raw ->> '_batch'), ''),
         nullif(btrim(c.raw ->> 'employer'), ''),
         nullif(btrim(c.raw ->> 'named_insured'), ''),
         nullif(btrim(c.raw ->> 'city'), ''),
         nullif(btrim(c.raw ->> 'zip'), ''),
         nullif(btrim(c.raw ->> 'addr1'), ''),
         nullif(btrim(c.raw ->> 'addr2'), ''),
         nullif(btrim(c.raw ->> 'carrier'), ''),
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
           c.archived_at::date,
           current_date),
         c.id
  from cand c
  where nullif(btrim(c.raw ->> 'named_insured'), '') is not null
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
       least(v_avail, p_limit), v_ins, 0, least(v_avail, p_limit) - v_ins,
       '0789',
       'select count(*) from wc_coverage_fl_raw r where (r.raw->>''peo_client'')=''Y'' and not exists (select 1 from wc_coverage_fl c where c.raw_id=r.id)',
       jsonb_build_object('still_unpromoted', v_left), now(), 'promote_fl_raw_coverage');
  end if;

  return jsonb_build_object(
    'promoted', v_ins,
    'coverage_before', v_before,
    'coverage_after', v_before + v_ins,
    'still_unpromoted', v_left);
end $$;

revoke all on function public.promote_fl_raw_coverage(int) from public, anon, authenticated;

reset role;

-- VERIFICATION
-- select pg_get_userbyid(proowner) from pg_proc where proname='promote_fl_raw_coverage';  -- peo_gatekeeper
-- select promote_fl_raw_coverage(500);                                                    -- promotes, receipts