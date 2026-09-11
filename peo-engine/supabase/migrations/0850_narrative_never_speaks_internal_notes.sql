-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0849-transfers-reach-narratives
-- Articles implemented: XIV.6 (no sourcing / internal notes on customer surfaces), IX.2 (year grain stays year grain)
-- Articles verified not violated: III.1, VIII.2
-- Verification query attached: YES
--
-- 0849's brand_retained sentence spliced the researcher's free-text finding (EINs, "Ruled by Gazz",
-- "reopen as absorbed if...") into the customer-facing narrative. Internal notes never reach a surface.
-- The finding stays in the lifecycle event evidence (internal) and out of the sentence.

create or replace function public.company_lifecycle_narrative(p_company_id uuid)
returns jsonb language plpgsql as $function$
declare v_narrative jsonb; v_horizon jsonb; v_peo_events jsonb;
begin
  v_horizon := company_lifecycle_horizon(p_company_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'event', ev.event_type, 'year', extract(year from ev.window_start)::int,
           'from', ev.evidence->>'from', 'to', ev.evidence->>'to',
           'resolution', ev.evidence->>'resolution',
           'narrative',
             case ev.event_type
               when 'peo_rebranded' then
                 'Their PEO changed its name from ' || initcap(ev.evidence->>'from') || ' to ' || initcap(ev.evidence->>'to') ||
                 ' during ' || to_char(ev.window_start,'YYYY') || ' - same tax ID, new paperwork.'
               when 'peo_entity_change' then
                 case coalesce(ev.evidence->>'resolution','pending_research')
                   when 'brand_retained' then
                     'Their PEO moved its plan sponsorship to a new legal entity during ' || to_char(ev.window_start,'YYYY') ||
                     ' (' || initcap(ev.evidence->>'from') || ' to ' || initcap(ev.evidence->>'to') ||
                     '). Same brand, same ownership group - new paperwork for the client.'
                   when 'absorbed' then
                     'Their PEO ' || initcap(ev.evidence->>'from') || ' was folded into ' || initcap(ev.evidence->>'to') || ' during ' ||
                     to_char(ev.window_start,'YYYY') || ' - new agreements, and often new carriers, without the client choosing.'
                   when 'restructure_same_owner' then
                     'Their PEO restructured its legal entity during ' || to_char(ev.window_start,'YYYY') ||
                     ' (' || initcap(ev.evidence->>'from') || ' to ' || initcap(ev.evidence->>'to') || '); same owner, same brand.'
                   else
                     'Their PEO''s plan sponsor changed from ' || initcap(ev.evidence->>'from') || ' to ' || initcap(ev.evidence->>'to') ||
                     ' during ' || to_char(ev.window_start,'YYYY') || ' - under research.'
                 end
             end
         ) order by ev.window_start), '[]'::jsonb)
    into v_peo_events
    from public.company_lifecycle_events ev
   where ev.company_id = p_company_id and ev.event_type in ('peo_rebranded','peo_entity_change');

  with ordered as (
    select *, row_number() over (order by window_start) as seq
    from company_lifecycle_events
    where company_id = p_company_id and event_type = 'peo_affiliation_window'
    order by window_start
  ),
  narrowed as (
    select o.*, lag(peo_family_slug) over (order by window_start) as prev_peo,
      lag(window_end) over (order by window_start) as prev_end,
      lag(precision) over (order by window_start) as prev_precision
    from ordered o
  ),
  transitions as (
    select prev_peo as from_peo, peo_family_slug as to_peo, prev_end as prior_end, window_start as new_start,
      precision as new_precision, prev_precision,
      case when prev_end is not null and window_start > prev_end then window_start - prev_end end as gap_days,
      case when prev_end is not null and window_start < prev_end then prev_end - window_start end as overlap_days
    from narrowed where prev_peo is not null and prev_peo <> peo_family_slug and prev_peo <> ''
  )
  select jsonb_build_object(
    'data_horizon', v_horizon,
    'affiliation_windows', coalesce((select jsonb_agg(jsonb_build_object(
        'peo', peo_family_slug, 'source', source, 'precision', precision,
        'window_start', window_start, 'window_end', window_end, 'as_of', as_of, 'evidence', evidence
      ) order by window_start) from ordered), '[]'::jsonb),
    'transitions', coalesce((select jsonb_agg(jsonb_build_object(
        'from', from_peo, 'to', to_peo, 'prior_window_end', prior_end, 'new_window_start', new_start,
        'gap_days', gap_days, 'overlap_days', overlap_days,
        'narrative',
          case when new_precision = 'day' and prev_precision = 'day' then
            'Was affiliated with ' || coalesce(from_peo,'unknown') || ' through ' || to_char(prior_end,'Mon DD, YYYY') ||
            ', transitioned to ' || coalesce(to_peo,'unknown') || ' ' ||
            case when gap_days is not null then 'on ' || to_char(new_start,'Mon DD, YYYY')
                 when overlap_days is not null then 'on ' || to_char(new_start,'Mon DD, YYYY') || ', with a ' || overlap_days || '-day filing overlap'
                 else 'on ' || to_char(new_start,'Mon DD, YYYY') end
          else
            'Was affiliated with ' || coalesce(from_peo,'unknown') || ', transitioned to ' || coalesce(to_peo,'unknown') ||
            ' during ' || to_char(new_start,'YYYY') ||
            case
              when overlap_days is not null then ' — appearing under both in the same filing year is the signature of the switch'
              when gap_days is not null then ', ' || gap_days || ' days after the prior window closed'
              else ''
            end
          end
      ) order by new_start) from transitions), '[]'::jsonb),
    'peo_events', v_peo_events
  ) into v_narrative;
  return v_narrative;
end $function$;

-- Play evidence: drop the free-text finding too (evidence can be echoed on a surface).
update public.play_theses
   set cohort_sql = replace(cohort_sql, ', ''resolution'', q.resolution, ''finding'', q.finding) as evidence', ', ''resolution'', q.resolution) as evidence')
 where thesis_slug = 'peo_entity_change';

-- Verification
select (company_lifecycle_narrative(company_id)->'peo_events'->0->>'narrative') as sentence
  from company_lifecycle_events where event_type='peo_entity_change' limit 1;
