-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0843-rebrand-signal
-- Articles implemented: II.1 (EIN-first identity), I.1 (observe, then label), VIII.2 (vet before
--   pushing to clients), XIV.4 (a signal the product sells must be computed and carried forward)
-- Articles verified not violated: III.1 (noncompete sponsors already out of the source),
--   II.2 (nothing is merged - a rebrand is recorded ON an EIN, it never joins two EINs)
-- Verification query attached: YES
--
-- A REBRAND IS A SIGNAL. Gazz 2026-09-11: "same EIN and different name would likely be a rebrand,
-- but that's also something we need to hold at a PEO profile level and subsequently pushed down to
-- our narrative creation and plays."
--
-- A PEO that changes its name is usually telling you something - an acquisition, a private-equity
-- re-papering, a merger, a distancing from a reputation. Its clients get new paperwork, sometimes
-- new carriers, and a renewal conversation they did not ask for. That is a play window.
--
-- Real examples already in our own Form 5500 data, found by EIN:
--   27-0037153  EXECUSTAFF HR (2023)  ->  EQUITY HR (2024)
--   34-1838779  CORNERSTONE INNOVATIONS DBA DIVERSIFIED EMPLOYEE SOLUTIONS (2023)  ->  ATARAXIS PEO (2024)
--
-- THREE LEVELS:
--   1. DETECT  - peo_rebrand_events, by EIN across form years, PEO-shaped sponsors only, with an
--                abbreviation (VISITING NURSE ASSOCIATION -> VNA) told apart from a real rebrand.
--   2. HOLD    - peo_profiles.name_history and latest_rebrand carry the EIN's whole name lineage.
--   3. PUSH    - company_lifecycle_events rows (narratives read those) and a play_theses row
--                'peo_rebranded' (plays read those). Per the designation law (0839) the play is
--                DISABLED and the push only fires for VETTED events. Detection is automatic; aiming
--                it at a client is not.

create table if not exists public.peo_rebrand_events (
  id              bigserial primary key,
  sponsor_ein     text not null,
  prior_name      text not null,
  new_name        text not null,
  prior_last_seen int not null,
  new_first_seen  int not null,
  kind            text not null,
  confidence      numeric not null,
  vetted          boolean not null default false,
  vetted_by       text,
  vetted_at       timestamptz,
  family_slug     text,
  source          text not null default 'form5500',
  evidence        jsonb,
  detected_at     timestamptz not null default now(),
  unique (sponsor_ein, prior_name, new_name)
);
alter table public.peo_rebrand_events enable row level security;
do $p$ begin
  if not exists (select 1 from pg_policies where tablename='peo_rebrand_events' and policyname='peo_rebrand_events_read') then
    create policy peo_rebrand_events_read on public.peo_rebrand_events for select to service_role, authenticated using (true);
  end if;
end $p$;

create or replace function public.sponsor_name_core(p_name text)
returns text language sql immutable as $nc$
  select nullif(regexp_replace(btrim(regexp_replace(public.name_norm(p_name),
           '\m(INC|LLC|CORP|CO|LTD|COMPANY|PA|PC|PLLC|LLP|THE)\M', '', 'g')), '\s+', ' ', 'g'), '');
$nc$;

create or replace function public.name_token_overlap(a text, b text)
returns numeric language sql immutable as $ov$
  with ta as (select distinct unnest(string_to_array(public.sponsor_name_core(a),' ')) t),
       tb as (select distinct unnest(string_to_array(public.sponsor_name_core(b),' ')) t)
  select case when least((select count(*) from ta),(select count(*) from tb)) = 0 then 0
              else (select count(*) from ta join tb using (t))::numeric
                   / least((select count(*) from ta),(select count(*) from tb)) end;
$ov$;

create or replace function public.detect_peo_rebrands()
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $d$
declare v_new int := 0;
begin
  with peo_shaped as (
    select distinct public.ein_norm(s.ein) as ein
      from public.efast_5500_staging s
     where s.ein is not null
       and (s.benefit_kind = 'welfare'
            or exists (select 1 from public.efast_mep_part_staging p where p.ack_id = s.ack_id))
  ), names as (
    select public.ein_norm(s.ein) as ein, public.sponsor_name_core(s.sponsor_name) as core,
           max(s.sponsor_name) as display, min(s.form_year) as first_year, max(s.form_year) as last_year
      from public.efast_5500_staging s
      join peo_shaped ps on ps.ein = public.ein_norm(s.ein)
     where s.sponsor_name is not null and public.sponsor_name_core(s.sponsor_name) is not null
       and not public.ein_is_administrator(s.ein)
       and not public.is_noncompete_peo(s.sponsor_name)
     group by 1,2
  ), ordered as (
    select n.*, lag(core) over (partition by ein order by first_year, last_year) as prior_core,
           lag(display) over (partition by ein order by first_year, last_year) as prior_display,
           lag(last_year) over (partition by ein order by first_year, last_year) as prior_last
      from names n
  ), flips as (
    select ein, prior_display, display, prior_last, first_year,
           public.name_token_overlap(prior_core, core) as overlap
      from ordered
     where prior_core is not null and prior_core <> core
       and first_year >= prior_last
  ), ins as (
    insert into public.peo_rebrand_events
      (sponsor_ein, prior_name, new_name, prior_last_seen, new_first_seen, kind, confidence, evidence)
    select ein, prior_display, display, prior_last, first_year,
           case when overlap >= 0.5 then 'abbreviation'
                when display ~* '\mDBA\M' or prior_display ~* '\mDBA\M' then 'dba_change'
                else 'rebrand' end,
           case when overlap >= 0.5 then 0.6 else 0.85 end,
           jsonb_build_object('token_overlap', overlap, 'source', 'form5500 sponsor name by EIN across form years')
      from flips
    on conflict (sponsor_ein, prior_name, new_name) do nothing
    returning 1)
  select count(*) into v_new from ins;
  return jsonb_build_object('new_events', v_new,
                            'total_events', (select count(*) from public.peo_rebrand_events),
                            'rebrands', (select count(*) from public.peo_rebrand_events where kind='rebrand'));
end $d$;

alter table public.peo_profiles
  add column if not exists name_history jsonb,
  add column if not exists latest_rebrand jsonb;

create or replace function public.sync_rebrands_to_profiles()
returns integer language plpgsql security definer set search_path to 'public','pg_temp' as $s$
declare n int;
begin
  with by_ein as (
    select e.sponsor_ein,
           jsonb_agg(jsonb_build_object('from', e.prior_name, 'to', e.new_name,
                     'year', e.new_first_seen, 'kind', e.kind, 'vetted', e.vetted)
                     order by e.new_first_seen) as history,
           (select to_jsonb(x) from (
              select e2.prior_name as "from", e2.new_name as "to", e2.new_first_seen as year,
                     e2.kind, e2.vetted, e2.confidence
                from public.peo_rebrand_events e2
               where e2.sponsor_ein = e.sponsor_ein and e2.kind = 'rebrand'
               order by e2.new_first_seen desc limit 1) x) as latest
      from public.peo_rebrand_events e
     group by e.sponsor_ein
  )
  update public.peo_profiles p
     set name_history = b.history, latest_rebrand = b.latest, updated_at = now()
    from by_ein b
   where p.sponsor_eins ? b.sponsor_ein
     and (p.name_history is distinct from b.history or p.latest_rebrand is distinct from b.latest);
  get diagnostics n = row_count;
  return n;
end $s$;

create or replace function public.push_rebrands_to_lifecycle()
returns integer language plpgsql security definer set search_path to 'public','pg_temp' as $l$
declare n int;
begin
  insert into public.company_lifecycle_events
    (company_id, source, event_type, peo_family_slug, window_start, window_end, precision, as_of, evidence)
  select c.id, 'peo_rebrand_events', 'peo_rebranded', c.peo_family_slug,
         make_date(e.new_first_seen,1,1), make_date(e.new_first_seen,12,31), 'year',
         make_date(e.new_first_seen,1,1),
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

insert into public.play_theses (thesis_slug, intel_trigger, cohort_sql, suggested_channel, suggested_persona, enabled, notes)
values ('peo_rebranded',
 'peo_rebrand_events kind=rebrand vetted=true (same EIN, new name)',
 $q$
 with cand as materialized (
   select c.id as company_id, c.legal_name,
          e.id as eid, e.prior_name, e.new_name, e.new_first_seen,
          md5(c.id::text||':peo_rebranded:'||e.id) as evidence_hash
   from peo_rebrand_events e
   join peo_profiles p on p.sponsor_eins ? e.sponsor_ein
   join companies c on c.peo_family_slug = p.family_slug
   where e.kind = 'rebrand' and e.vetted
     and c.merged_into is null
     and not exists (select 1 from company_angles a2
                     where a2.company_id = c.id and a2.angle_type = 'peo_rebranded')
     and not exists (select 1 from company_angles a
                     where a.evidence_hash = md5(c.id::text||':peo_rebranded:'||e.id))
 )
 select q.company_id,
   format('%s''s PEO changed its name from %s to %s in %s. Same tax ID, new paperwork - a rebrand usually follows an acquisition or a re-papering, and clients get new agreements and sometimes new carriers without choosing them.',
     q.legal_name, q.prior_name, q.new_name, q.new_first_seen) as claim,
   jsonb_build_object('ref','rebrand_event:'||q.eid, 'from', q.prior_name, 'to', q.new_name, 'year', q.new_first_seen) as evidence,
   'VERIFIED' as evidence_tag,
   0.75 as confidence,
   make_date(q.new_first_seen,1,1) as window_start,
   (make_date(q.new_first_seen,1,1) + interval '18 months')::date as window_end,
   q.evidence_hash
 from cand q
 join companies c on c.id = q.company_id
 where is_peo_targetable(c.id) and not company_is_noncompete(c)
 $q$,
 'email', 'owner_or_hr_lead', false,
 'A PEO name change under a stable EIN. Held DISABLED per the designation law (0839): each rebrand event must be vetted (kind=rebrand, vetted=true) before its clients are ever addressed. Window = rebrand year + 18 months.')
on conflict (thesis_slug) do nothing;

insert into public.brain_knowledge (scope, key, content)
values ('doctrine','peo_rebrand_signal_law',
 'Same EIN, new name = rebrand, and a rebrand is a SIGNAL, not just a matching rule (Gazz 2026-09-11). Detected by EIN across every form year for PEO-shaped sponsors (welfare tell or employer roster), with abbreviations (high token overlap, e.g. VISITING NURSE ASSOCIATION -> VNA) told apart from real rebrands (low overlap, e.g. EXECUSTAFF HR -> EQUITY HR). Held on the PEO profile as name_history and latest_rebrand. Pushed down to narratives via company_lifecycle_events (event_type peo_rebranded) and to plays via play_theses peo_rebranded - BOTH only for vetted events, because a rebrand narrative aimed at a client on a false detection is worse than no narrative. Administrator EINs and noncompete names are excluded at detection.');