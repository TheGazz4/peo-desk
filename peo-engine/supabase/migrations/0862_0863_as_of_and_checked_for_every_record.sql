-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0862-as-of
-- Articles implemented: IX.2 (valid time vs observed time never conflated; year grain stays year grain),
--   XIV.6 (surfaces show how old a fact is; sourcing itself is never displayed), X.3 (no per-row cron scans)
-- Verification query attached: YES
--
-- Gazz 2026-09-12: "as of" on every record. Ruling: TWO dates, not one.
--   AS OF   = date of the newest evidence behind the record (valid time), at the source's grain:
--             a 5500 fact is "2024"; a WC policy is "Mar 14, 2026". Never today's date, never the DB write time.
--   CHECKED = when the platform last re-read that source (observed time; hub cron success or last delivery).
--             "As of 2024 / checked yesterday" = old fact, still current, nothing newer published.
--   FRESHNESS = checked vs the source's cadence: fresh (<=1.5x) / aging (<=3x) / stale; vendor seeds = snapshot.
--   A vendor snapshot's as_of is our LOAD date, not evidence: it never outranks real evidence (0863 fix after the
--   first run showed a Tandem client reading "as of Aug 08, 2026" off the miEdge load).
-- Display law: hub names stay internal (sources_internal key is never rendered). UI reads v_company_as_of.
-- Objects (final state live in DB):
--   table  hub_check_cadence(hub, grain, cadence_days, check_jobnames, label, note)  - 20 hubs seeded
--   table  hub_check_state(hub, checked_at, refreshed_at) + refresh_hub_check_state() + cron hub_check_state_refresh (7,22,37,52 * * * *)
--   fn     hub_last_checked(hub), as_of_display(date, grain), company_as_of(uuid) -> jsonb
--   view   v_company_as_of(company_id, as_of, as_of_grain, as_of_display, checked_at, checked_display, freshness, snapshot_only)
--   brain  as_of_display_law
-- Cost: ~0.4 ms per company; call per card/list/tile, not whole-table.

create or replace function public.company_as_of(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public','pg_temp' as $function$
declare v jsonb;
begin
  with ev as (
    select source_hub as hub, max(as_of) as as_of, max(observed_at) as delivered_at
      from public.field_observations
     where company_id = p_company_id and resolution_status is distinct from 'superseded'
       and coalesce(triage_bucket,'') <> 'QUARANTINED'
     group by source_hub
    union all
    select source, max(coalesce(window_end, as_of)), max(created_at)
      from public.company_lifecycle_events
     where company_id = p_company_id and coalesce(triage_bucket,'') <> 'QUARANTINED'
     group by source
  ), per_hub as (
    select e.hub, max(e.as_of) as as_of, max(e.delivered_at) as delivered_at,
           coalesce(c.grain, 'day') as grain, c.cadence_days,
           (c.hub is null or c.cadence_days is null) as is_snapshot,
           greatest(public.hub_last_checked(e.hub), max(e.delivered_at)) as checked_at
      from ev e left join public.hub_check_cadence c on c.hub = e.hub
     group by e.hub, c.hub, c.grain, c.cadence_days
  ), scored as (
    select *,
      case when is_snapshot then 'snapshot'
           when checked_at >= now() - (cadence_days * interval '1 day') * 1.5 then 'fresh'
           when checked_at >= now() - (cadence_days * interval '1 day') * 3   then 'aging'
           else 'stale' end as freshness
    from per_hub
  ), pick as (
    select * from scored where as_of is not null order by is_snapshot, as_of desc, grain limit 1
  )
  select jsonb_build_object(
    'as_of',          (select as_of from pick),
    'as_of_grain',    (select grain from pick),
    'as_of_display',  (select public.as_of_display(as_of, grain) from pick),
    'as_of_is_snapshot', (select is_snapshot from pick),
    'checked_at',     (select max(checked_at) from scored where not is_snapshot),
    'checked_display',(select to_char(max(checked_at),'Mon DD, YYYY') from scored where not is_snapshot),
    'freshness',      coalesce((select case when bool_or(freshness='fresh') then 'fresh'
                                            when bool_or(freshness='aging') then 'aging'
                                            when bool_or(freshness='stale') then 'stale'
                                            else 'snapshot' end from scored), 'unknown'),
    'live_sources',   (select count(*) from scored where not is_snapshot),
    'snapshot_only',  (select coalesce(bool_and(is_snapshot), true) from scored),
    'sources_internal', (select coalesce(jsonb_agg(jsonb_build_object('hub',hub,'as_of',as_of,'grain',grain,'checked_at',checked_at,'freshness',freshness) order by is_snapshot, as_of desc nulls last), '[]'::jsonb) from scored)
  ) into v;
  return v;
end $function$;

create or replace view public.v_company_as_of as
  select c.id as company_id,
         (a->>'as_of')::date as as_of, a->>'as_of_grain' as as_of_grain, a->>'as_of_display' as as_of_display,
         (a->>'checked_at')::timestamptz as checked_at, a->>'checked_display' as checked_display,
         a->>'freshness' as freshness, (a->>'snapshot_only')::boolean as snapshot_only
    from public.companies c, lateral public.company_as_of(c.id) a
   where c.merged_into is null;
