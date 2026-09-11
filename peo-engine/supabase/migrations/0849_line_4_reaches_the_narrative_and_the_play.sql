-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0849-transfers-reach-narratives
-- Articles implemented: XIV.4 (a signal the product sells is carried all the way to the surface),
--   VIII.2 (only researched/vetted events reach a client), IX.2 (temporal honesty - year grain stays year grain)
-- Articles verified not violated: III.1, XIV.6
-- Verification query attached: YES
--
-- HONEST STATUS BEFORE THIS MIGRATION, answering "how are we adding this to the profiles and
-- leveraging it for narratives and plays":
--   PROFILE   - done. name_history, latest_rebrand (0843), ein_transfers (0846), ownership (0848).
--   NARRATIVE - NOT actually wired. company_lifecycle_narrative() read ONLY 'peo_affiliation_window'.
--               The peo_rebranded events from 0843 were written and ignored. Worse: the 0843 push
--               function was owned by postgres and company_lifecycle_events is gatekeeper-fenced, so
--               it would have failed the first time it had anything to push. EIN transfers were never
--               pushed at all.
--   PLAYS     - half. A rebrand thesis exists (disabled, vetted-only). No transfer thesis.
--
-- THIS MIGRATION closes all of it. Line 4 of the Form 5500 now travels:
--   filing -> beacon -> research -> profile -> client lifecycle event -> narrative sentence -> play.
-- NOTE: the brand_retained sentence in this file was superseded by 0850 (no internal notes on surfaces).

-- WAS LAW: declare temporal semantics for both new lifecycle sources BEFORE first ingest.
insert into public.source_temporal_semantics (source_slug, valid_time_rule, observed_time_rule, valid_grain, typical_lag, was_trap)
values
 ('peo_ein_transfer_events',
  'valid time = the Form 5500 plan year (form_year) in which line 4 reported a prior sponsor; window = Jan 1 .. Dec 31 of that plan year',
  'observed time = detected_at (when the beacon was computed from the filing); the filing itself lands 7-10 months after plan-year end',
  'year', '7-10 months after plan-year end',
  'TRAP: year grain is never fabricated into a month or day. The change happened SOMETIME in or before that plan year; line 4 only proves the sponsor differed from the prior filing. Only researched (non-dismissed) transfers reach a client.'),
 ('peo_rebrand_events',
  'valid time = the plan year (new_first_seen) in which the new sponsor name first appears on the same EIN; window = Jan 1 .. Dec 31',
  'observed time = detected_at; the filing lands 7-10 months after plan-year end',
  'year', '7-10 months after plan-year end',
  'TRAP: same EIN + new name is a rebrand only after vetting; year grain never becomes a date. Abbreviation/spelling variants are not rebrands.')
on conflict (source_slug) do nothing;

set role peo_gatekeeper;

create function public.push_rebrands_to_lifecycle()
returns integer language plpgsql security definer set search_path to 'public','pg_temp' as $l$
declare n int;
begin
  insert into public.company_lifecycle_events
    (company_id, source, event_type, peo_family_slug, window_start, window_end, precision, as_of, evidence)
  select c.id, 'peo_rebrand_events', 'peo_rebranded', c.peo_family_slug,
         make_date(e.new_first_seen,1,1), make_date(e.new_first_seen,12,31), 'year', make_date(e.new_first_seen,1,1),
         jsonb_build_object('rebrand_event_id', e.id, 'sponsor_ein', e.sponsor_ein,
                            'from', e.prior_name, 'to', e.new_name, 'vetted', e.vetted)
    from public.peo_rebrand_events e
    join public.peo_profiles p on p.sponsor_eins ? e.sponsor_ein
    join public.companies c on c.peo_family_slug = p.family_slug and c.merged_into is null
   where e.kind = 'rebrand' and e.vetted
     and not public.company_is_noncompete(c)
     and not exists (select 1 from public.company_lifecycle_events x
                      where x.company_id = c.id and x.event_type = 'peo_rebranded'
                        and (x.evidence->>'rebrand_event_id')::bigint = e.id);
  get diagnostics n = row_count;
  return n;
end $l$;

create function public.push_ein_transfers_to_lifecycle()
returns integer language plpgsql security definer set search_path to 'public','pg_temp' as $l$
declare n int;
begin
  insert into public.company_lifecycle_events
    (company_id, source, event_type, peo_family_slug, window_start, window_end, precision, as_of, evidence)
  select c.id, 'peo_ein_transfer_events', 'peo_entity_change', c.peo_family_slug,
         make_date(e.form_year,1,1), make_date(e.form_year,12,31), 'year', make_date(e.form_year,1,1),
         jsonb_build_object('transfer_event_id', e.id, 'from', e.prior_name, 'from_ein', e.prior_ein,
                            'to', e.new_name, 'to_ein', e.new_ein, 'kind', e.beacon_kind,
                            'resolution', e.resolution, 'finding', e.finding)
    from public.peo_ein_transfer_events e
    join public.peo_profiles p on p.sponsor_eins ? e.new_ein or p.sponsor_eins ? e.prior_ein
    join public.companies c on c.peo_family_slug = p.family_slug and c.merged_into is null
   where e.research_status = 'researched' and e.resolution <> 'dismissed'
     and not public.company_is_noncompete(c)
     and not exists (select 1 from public.company_lifecycle_events x
                      where x.company_id = c.id and x.event_type = 'peo_entity_change'
                        and (x.evidence->>'transfer_event_id')::bigint = e.id);
  get diagnostics n = row_count;
  return n;
end $l$;

reset role;

-- company_lifecycle_narrative(): adds 'peo_events' section (rebrand + entity change sentences).
-- Final body lives in 0850_narrative_never_speaks_internal_notes.sql.

insert into public.play_theses (thesis_slug, intel_trigger, cohort_sql, suggested_channel, suggested_persona, enabled, notes)
values ('peo_entity_change',
 'peo_ein_transfer_events researched, resolution in (absorbed, brand_retained) (Form 5500 line 4)',
 $q$
 with cand as materialized (
   select c.id as company_id, c.legal_name,
          e.id as eid, e.prior_name, e.new_name, e.form_year, e.resolution, e.finding,
          md5(c.id::text||':peo_entity_change:'||e.id) as evidence_hash
   from peo_ein_transfer_events e
   join peo_profiles p on p.sponsor_eins ? e.new_ein or p.sponsor_eins ? e.prior_ein
   join companies c on c.peo_family_slug = p.family_slug
   where e.research_status = 'researched' and e.resolution in ('absorbed','brand_retained')
     and c.merged_into is null
     and not exists (select 1 from company_angles a2 where a2.company_id = c.id and a2.angle_type = 'peo_entity_change')
     and not exists (select 1 from company_angles a where a.evidence_hash = md5(c.id::text||':peo_entity_change:'||e.id))
 )
 select q.company_id,
   case q.resolution
     when 'absorbed' then format('%s''s PEO, %s, was folded into %s in %s. New agreements and often new carriers, without them choosing - the highest-churn moment in a PEO client''s life.',
                                 q.legal_name, q.prior_name, q.new_name, q.form_year)
     else format('%s''s PEO moved its plan sponsorship to a new legal entity in %s (%s to %s). Same brand, new paperwork - a re-papering is a natural moment to compare.',
                 q.legal_name, q.form_year, q.prior_name, q.new_name)
   end as claim,
   jsonb_build_object('ref','transfer_event:'||q.eid, 'from', q.prior_name, 'to', q.new_name,
                      'year', q.form_year, 'resolution', q.resolution) as evidence,
   'VERIFIED' as evidence_tag,
   case q.resolution when 'absorbed' then 0.85 else 0.65 end as confidence,
   make_date(q.form_year,1,1) as window_start,
   (make_date(q.form_year,1,1) + interval '18 months')::date as window_end,
   q.evidence_hash
 from cand q
 join companies c on c.id = q.company_id
 where is_peo_targetable(c.id) and not company_is_noncompete(c)
 $q$,
 'email', 'owner_or_hr_lead', false,
 'Form 5500 line 4: the PEO reported a new sponsor EIN. Fires only for RESEARCHED transfers. absorbed = strongest (forced transition); brand_retained = softer (re-papering). DISABLED until switched on per the designation law (0839). Window = filing year + 18 months.')
on conflict (thesis_slug) do nothing;

select public.push_ein_transfers_to_lifecycle() as transfers_pushed;   -- 292 (Tandem HR clients)
select public.push_rebrands_to_lifecycle() as rebrands_pushed;         -- 0 (no vetted rebrands yet)

select cron.unschedule('peo_ein_transfer_beacon_nightly');
select cron.schedule('peo_ein_transfer_beacon_nightly', '5 5 * * *',
  'select public.detect_ein_transfers(), public.sync_ein_transfers_to_profiles(), public.push_ein_transfers_to_lifecycle(), public.push_rebrands_to_lifecycle()');
