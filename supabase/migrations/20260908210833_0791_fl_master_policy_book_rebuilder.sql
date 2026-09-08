-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-fl-promotion-gap-and-intake-conformance (#165)
-- Articles implemented: every derived table must have a repeatable builder (no one-off scripts);
--                       researched attribution is never overwritten by a mechanical rebuild;
--                       writer conformance (fenced table written only by a gatekeeper-owned door).
-- Articles verified not violated: sourcing never displayed; WC carrier internal-only; client street
--                       addresses never displayed; noncompete PEOs never worked; shared-address counts
--                       never displayed.
-- Verification query attached: YES
--
-- fl_master_policy_book was built once by hand and never rebuilt. It covers 1,651 policies - all of
-- them from batch A. With 169,320 newly promoted rows, 31,858 of 38,241 distinct Florida PEO-flagged
-- employer names cannot reach the mesh because their policy is not in the book. This installs the
-- rebuilder that was missing.

create index if not exists ix_wc_coverage_fl_policy_number
  on public.wc_coverage_fl (policy_number) where policy_number is not null;

set role peo_gatekeeper;

create or replace function public.rebuild_fl_master_policy_book()
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare
  v_before int;
  v_after  int;
  v_named_before int;
  v_named_after  int;
begin
  select count(*), count(*) filter (where peo_name is not null)
    into v_before, v_named_before from public.fl_master_policy_book;

  with agg as (
    select w.policy_number,
           mode() within group (order by w.carrier)      as carrier,
           mode() within group (order by w.agency_name)  as agency,
           count(*)                                       as row_count,
           count(distinct app.normalize_name(coalesce(w.named_insured, w.employer_name))) as client_count,
           min(w.policy_start)                            as eff_min,
           max(w.policy_start)                            as eff_max
    from public.wc_coverage_fl w
    where w.policy_number is not null
    group by w.policy_number
  ),
  anch as (
    select a.policy_number,
           (select to_char(w2.policy_start, 'MM-DD')
              from public.wc_coverage_fl w2
             where w2.policy_number = a.policy_number and w2.policy_start is not null
             group by to_char(w2.policy_start, 'MM-DD')
             order by count(*) desc, 1
             limit 1) as anchor_mmdd,
           (select round(count(*) filter (where to_char(w3.policy_start,'MM-DD') = (
                      select to_char(w4.policy_start,'MM-DD')
                        from public.wc_coverage_fl w4
                       where w4.policy_number = a.policy_number and w4.policy_start is not null
                       group by to_char(w4.policy_start,'MM-DD')
                       order by count(*) desc, 1 limit 1))::numeric
                    / nullif(count(*) filter (where w3.policy_start is not null),0), 3)
              from public.wc_coverage_fl w3
             where w3.policy_number = a.policy_number) as anchor_share
    from agg a
  )
  insert into public.fl_master_policy_book
    (policy_number, carrier, agency, row_count, client_count, eff_min, eff_max,
     anchor_mmdd, anchor_share)
  select a.policy_number, a.carrier, a.agency, a.row_count, a.client_count,
         a.eff_min, a.eff_max, n.anchor_mmdd, n.anchor_share
  from agg a join anch n on n.policy_number = a.policy_number
  on conflict (policy_number) do update
    set carrier      = excluded.carrier,
        agency       = excluded.agency,
        row_count    = excluded.row_count,
        client_count = excluded.client_count,
        eff_min      = excluded.eff_min,
        eff_max      = excluded.eff_max,
        anchor_mmdd  = excluded.anchor_mmdd,
        anchor_share = excluded.anchor_share;
        -- peo_name / peo_match_source / peo_confidence are researched attribution.
        -- A mechanical rebuild NEVER touches them.

  select count(*), count(*) filter (where peo_name is not null)
    into v_after, v_named_after from public.fl_master_policy_book;

  return jsonb_build_object(
    'policies_before', v_before, 'policies_after', v_after,
    'attributed_before', v_named_before, 'attributed_after', v_named_after,
    'attribution_preserved', v_named_after >= v_named_before);
end $$;

revoke all on function public.rebuild_fl_master_policy_book() from public, anon, authenticated;
grant execute on function public.rebuild_fl_master_policy_book() to service_role;

reset role;

-- VERIFICATION
-- select rebuild_fl_master_policy_book();   -- attribution_preserved must be true
-- select count(*) from fl_master_policy_book;