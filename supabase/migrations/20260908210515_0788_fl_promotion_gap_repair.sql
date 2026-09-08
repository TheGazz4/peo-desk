-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-fl-promotion-gap-and-intake-conformance (#165)
-- Articles implemented: intake completeness (no PEO-flagged source row may sit unpromoted in an archive);
--                       mesh liveness measures projectable intake, never archive volume.
-- Articles verified not violated: sourcing never displayed; WC carrier internal-only; full street
--                       addresses of client companies never displayed; noncompete PEOs never worked;
--                       ONE-DOOR LAW; provenance on every append.
-- Verification query attached: YES
--
-- WHAT THIS FIXES
-- Florida's raw archive (wc_coverage_fl_raw, 4,271,610 rows) holds 202,817 rows the state flagged
-- peo_client = 'Y'. Only 33,482 were ever promoted into wc_coverage_fl - all of them from the FIRST
-- batch (letter A). Sixteen later batches (B..Q) promoted ZERO rows. 169,335 PEO-flagged Florida rows
-- have been stranded in the archive. Nothing alarmed because the FL adapter's liveness counted the raw
-- archive, which grows every day.

create unique index if not exists ux_wc_coverage_fl_raw_id
  on public.wc_coverage_fl (raw_id) where raw_id is not null;

create index if not exists ix_fl_raw_peo_client_y
  on public.wc_coverage_fl_raw (id) where (raw ->> 'peo_client') = 'Y';

create or replace function public.fl_raw_date(p text)
returns date language sql immutable as $fn$
  select case
    when p is null then null
    when btrim(p) ~ '^\d{1,2}/\d{1,2}/\d{4}$' then to_date(btrim(p), 'FMMM/FMDD/YYYY')
    when btrim(p) ~ '^\d{4}-\d{2}-\d{2}' then left(btrim(p),10)::date
    else null
  end
$fn$;

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
begin
  select count(*) into v_before from public.wc_coverage_fl;

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

  return jsonb_build_object(
    'promoted', v_ins,
    'coverage_before', v_before,
    'coverage_after', v_before + v_ins,
    'still_unpromoted', v_left);
end $$;

revoke all on function public.promote_fl_raw_coverage(int) from public, anon, authenticated;

update public.mesh_state_adapters
   set source_count_query = 'select count(*) from wc_coverage_fl w where exists (select 1 from fl_master_policy_book b where b.policy_number = w.policy_number)'
 where state = 'FL';

-- VERIFICATION
-- select public.promote_fl_raw_coverage(1);
-- select count(*) from wc_coverage_fl_raw r
--   where (r.raw->>'peo_client')='Y'
--     and not exists (select 1 from wc_coverage_fl c where c.raw_id=r.id);  -- must reach 0