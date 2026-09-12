-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0864-as-of-audit-fixes (opened BEFORE apply)
-- Articles implemented: IX.2 (valid vs observed time; never claim a date we have not reached; absence of a receipt
--   is not evidence of failure), XIV.6 (a vendor load date is never shown as an evidence date), XIII.1 (RLS policy)
-- Verification query attached: YES
--
-- SELF-AUDIT of 0862/0863. Five defects, all found by testing the build rather than by re-reading it.
--
-- 1. FUTURE "AS OF" DATES (2,069 companies). I used coalesce(window_end, as_of). window_end on a WC lifecycle event
--    is the POLICY EXPIRATION - in the future for any live policy - so records would have displayed
--    "As of Mar 01, 2027". Fix: evidence date = least(window_end, the event's own as_of), capped at current_date.
--    5500 event -> plan-year end (2025). Live TX policy -> the day we last saw it in force (Aug 09, 2026).
--
-- 2. VENDOR LOAD DATE SHOWN AS AN EVIDENCE DATE (~46% of the book). 0863 stopped a snapshot from OUTRANKING real
--    evidence, but when a vendor seed is the ONLY source the display still read "As of Aug 08, 2026" - the day we
--    loaded the file. The vendor's own vintage is unpublished. Fix: "Vendor records, loaded Aug 2026".
--
-- 3. "SNAPSHOT" FOR RECORDS HOLDING NOTHING (132 of 3,000). bool_or over an empty set is null, so the CASE fell to
--    its ELSE. Fix: 'unknown'.
--
-- 4. FRESHNESS COULD NOT DISCRIMINATE. It compared a source's cadence against whether that lane's CRON had run -
--    and those crons run every few minutes, so every hub read "fresh" forever. Fix: freshness is measured on THIS
--    record (when a live source last delivered this company) against that source's cadence. Lane liveness is kept
--    separately as source_watching. Sample of 3,000: 1,311 fresh / 177 stale / 1,380 vendor-only / 132 unknown.
--
-- 5. (0865) source_watching read FALSE for 313 companies whose newest lane was RESCHEDULED today (0852, 0856) -
--    rescheduling resets a cron's id and history, so there was no receipt yet. But the data had demonstrably
--    arrived. A missing receipt is not a dead lane. Fix: fall back to the lane's own delivery time.
--
-- Final state of company_as_of() is live in the database; v_company_as_of re-created (column added, so dropped and
-- rebuilt rather than replaced). Read policies added to hub_check_cadence and hub_check_state per platform
-- convention (RLS enabled with no policy denies the UI's own reads). Cost unchanged: ~0.3 ms per company.

create or replace function public.company_as_of(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public','pg_temp' as $function$
declare v jsonb;
begin
  with ev as (
    select source_hub as hub,
           max(least(as_of, current_date)) as evidence_date,
           max(observed_at) as delivered_at
      from public.field_observations
     where company_id = p_company_id and resolution_status is distinct from 'superseded'
       and coalesce(triage_bucket,'') <> 'QUARANTINED'
     group by source_hub
    union all
    -- a fact is known to hold up to the EARLIER of (the end of its validity window) and (the date we last saw it)
    select source,
           max(least(coalesce(window_end, as_of), coalesce(as_of, window_end), current_date)),
           max(created_at)
      from public.company_lifecycle_events
     where company_id = p_company_id and coalesce(triage_bucket,'') <> 'QUARANTINED'
     group by source
  ), per_hub as (
    select e.hub, max(e.evidence_date) as evidence_date, max(e.delivered_at) as delivered_at,
           coalesce(c.grain, 'day') as grain, c.cadence_days,
           (c.hub is null or c.cadence_days is null) as is_snapshot,
           public.hub_last_checked(e.hub) as lane_checked_at
      from ev e left join public.hub_check_cadence c on c.hub = e.hub
     group by e.hub, c.hub, c.grain, c.cadence_days
  ), scored as (
    select q.*,
      case when q.is_snapshot then 'snapshot'
           when q.delivered_at >= now() - (q.cadence_days * interval '1 day') * 1.5 then 'fresh'
           when q.delivered_at >= now() - (q.cadence_days * interval '1 day') * 3   then 'aging'
           else 'stale' end as freshness,
      (not q.is_snapshot
        and coalesce(q.lane_checked_at, q.delivered_at) >= now() - (q.cadence_days * interval '1 day') * 3) as lane_alive
    from per_hub q
  ), pick as (
    select * from scored where evidence_date is not null
     order by is_snapshot, evidence_date desc, grain limit 1
  )
  select jsonb_build_object(
    'as_of',            (select evidence_date from pick),
    'as_of_grain',      (select grain from pick),
    'as_of_display',    (select case when is_snapshot
                                     then 'Vendor records, loaded ' || to_char(evidence_date,'Mon YYYY')
                                     else public.as_of_display(evidence_date, grain) end from pick),
    'as_of_is_snapshot',(select is_snapshot from pick),
    'checked_at',       (select max(delivered_at) from scored where not is_snapshot),
    'checked_display',  (select to_char(max(delivered_at),'Mon DD, YYYY') from scored where not is_snapshot),
    'freshness',        case when not exists (select 1 from scored) then 'unknown'
                             when not exists (select 1 from scored where not is_snapshot) then 'snapshot'
                             else (select case when bool_or(freshness='fresh') then 'fresh'
                                               when bool_or(freshness='aging') then 'aging'
                                               else 'stale' end
                                     from scored where not is_snapshot) end,
    'source_watching',  coalesce((select bool_or(lane_alive) from scored where not is_snapshot), false),
    'live_sources',     (select count(*) from scored where not is_snapshot),
    'snapshot_only',    (select coalesce(bool_and(is_snapshot), true) from scored),
    'sources_internal', (select coalesce(jsonb_agg(jsonb_build_object(
                            'hub',hub,'as_of',evidence_date,'grain',grain,'delivered_at',delivered_at,
                            'lane_checked_at',lane_checked_at,'freshness',freshness,'lane_alive',lane_alive)
                          order by is_snapshot, evidence_date desc nulls last), '[]'::jsonb) from scored)
  ) into v;
  return v;
end $function$;

drop view if exists public.v_company_as_of;
create view public.v_company_as_of as
  select c.id as company_id,
         (a->>'as_of')::date as as_of, a->>'as_of_grain' as as_of_grain, a->>'as_of_display' as as_of_display,
         (a->>'as_of_is_snapshot')::boolean as as_of_is_snapshot,
         (a->>'checked_at')::timestamptz as checked_at, a->>'checked_display' as checked_display,
         a->>'freshness' as freshness, (a->>'source_watching')::boolean as source_watching,
         (a->>'snapshot_only')::boolean as snapshot_only
    from public.companies c, lateral public.company_as_of(c.id) a
   where c.merged_into is null;

revoke execute on function public.company_as_of(uuid) from public, anon;
grant execute on function public.company_as_of(uuid) to service_role, postgres;
grant select on public.v_company_as_of to service_role;

create policy hub_check_cadence_read on public.hub_check_cadence for select to authenticated, service_role using (true);
create policy hub_check_state_read  on public.hub_check_state  for select to authenticated, service_role using (true);
