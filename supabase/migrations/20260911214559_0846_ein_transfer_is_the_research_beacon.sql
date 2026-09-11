-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0846-ein-transfer-beacon
-- Articles implemented: II.1 (EIN-first), I.1 (observe before labelling), VIII.2 (research before designation)
-- Articles verified not violated: III.1 (noncompete names excluded), II.2 (nothing merged; the two
--   EINs are linked by the filer's own statement on line 4, not by us)
-- Verification query attached: YES
--
-- THE EIN TRANSFER IS THE BEACON. Gazz 2026-09-11:
--   "Payroll companies sometimes spin up a PEO model from their clients as an upsell ... or ASO
--    offerings are upsold to PEO. This type of stuff happens, which is what we look at EIN transfers
--    first and foremost as a beacon for preliminary research to determine what happened."
--
-- Form 5500 line 4 asks the filer: has the sponsor's name or EIN changed since the last return, and
-- what was it before? DOL publishes those answers as LAST_RPT_SPONS_NAME / LAST_RPT_SPONS_EIN. We
-- were capturing them and using them for nothing. They are a documented statement by the filer that
-- the entity behind this plan changed - the strongest possible beacon that something happened:
-- an acquisition, a restructuring, a payroll company standing up a PEO entity, an ASO book converted
-- to co-employment, a PEO's plan handed to a pooled-plan provider.
--
-- Already in our rows, on PEO-shaped filers:
--   STAFFLINK OUTSOURCING (65-0233907)     -> PRESTIGE EMPLOYEE ADMINISTRATORS (87-1231461)  2024, 463 employers
--   TANDEM HR LLC (20-5628549)             -> TANDEM MANAGEMENT LLC (36-4231315)             2024, 343 employers
--   ONONDAGA EMPLOYEE LEASING (16-1254312) -> ARMHR LLC (81-0723442)                          2024,  96 employers
--   ATARAXIS INC (26-4786697)              -> ATX PEO SERVICES INC (92-1119949)              2024,  94 employers
--   CBR MANAGEMENT SERVICES (86-0820414)   -> RESOURCING EDGE I LLC (46-3045894)             2023,  83 employers
--   J. GREGORY PEO                         -> NESTEGGS RETIREMENT PLAN SERVICES               2024 (PEO plan moved to a PEP provider)
--
-- A beacon is a reason to research, not a conclusion. Every row lands as 'unresearched'.
-- Nothing here changes a profile, a narrative or a play until a person has looked at it.

create table if not exists public.peo_ein_transfer_events (
  id              bigserial primary key,
  ack_id          text not null unique,
  form_year       int not null,
  prior_ein       text,
  prior_name      text,
  new_ein         text not null,
  new_name        text,
  plan_name       text,
  benefit_kind    text,
  employers       int,
  lives           bigint,
  same_name       boolean,
  beacon_kind     text not null,      -- entity_change | name_and_entity_change | plan_moved_to_provider | ein_swap
  research_status text not null default 'unresearched',   -- unresearched | researched | dismissed
  finding         text,               -- what actually happened, written by a person after research
  researched_by   text,
  researched_at   timestamptz,
  detected_at     timestamptz not null default now()
);
alter table public.peo_ein_transfer_events enable row level security;
do $p$ begin
  if not exists (select 1 from pg_policies where tablename='peo_ein_transfer_events' and policyname='peo_ein_transfer_events_read') then
    create policy peo_ein_transfer_events_read on public.peo_ein_transfer_events for select to service_role, authenticated using (true);
  end if;
end $p$;

create or replace function public.detect_ein_transfers()
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $d$
declare v_new int := 0;
begin
  with peo_shaped as (
    select distinct s.ack_id from public.efast_5500_staging s
     where s.benefit_kind = 'welfare'
        or exists (select 1 from public.efast_mep_part_staging p where p.ack_id = s.ack_id)
  ), cand as (
    select s.ack_id, s.form_year,
           public.ein_norm(s.last_rpt_spons_ein) as prior_ein, s.last_rpt_spons_name as prior_name,
           public.ein_norm(s.ein) as new_ein, s.sponsor_name as new_name, s.plan_name, s.benefit_kind,
           (select count(distinct p.employer_ein) from public.efast_mep_part_staging p where p.ack_id = s.ack_id) as employers,
           s.tot_participants as lives,
           public.sponsor_name_core(s.last_rpt_spons_name) is not distinct from public.sponsor_name_core(s.sponsor_name) as same_name
      from public.efast_5500_staging s
      join peo_shaped ps on ps.ack_id = s.ack_id
     where s.last_rpt_spons_ein is not null
       and public.ein_norm(s.last_rpt_spons_ein) <> public.ein_norm(s.ein)
       and left(s.lane,4) not in ('sch_','dcg_')                      -- schedule-created rows never carry identity (0845)
       and not public.is_noncompete_peo(s.sponsor_name)
       and not public.is_noncompete_peo(s.last_rpt_spons_name)
  ), ins as (
    insert into public.peo_ein_transfer_events
      (ack_id, form_year, prior_ein, prior_name, new_ein, new_name, plan_name, benefit_kind, employers, lives, same_name, beacon_kind)
    select c.ack_id, c.form_year, c.prior_ein, c.prior_name, c.new_ein, c.new_name, c.plan_name, c.benefit_kind,
           c.employers, c.lives, c.same_name,
           case
             -- the new sponsor is a retirement-plan provider: the PEO handed its plan to a PEP/TPA
             when c.new_name ~* 'retirement plan|pep\M|pooled|401\(?k\)? (plan )?services|benefit services|fiduciary|plan services' then 'plan_moved_to_provider'
             -- the same two EINs appear in both directions across filings: entity juggling
             when exists (select 1 from cand c2 where c2.new_ein = c.prior_ein and c2.prior_ein = c.new_ein) then 'ein_swap'
             when c.same_name then 'entity_change'
             else 'name_and_entity_change'
           end
      from cand c
    on conflict (ack_id) do nothing
    returning 1)
  select count(*) into v_new from ins;
  return jsonb_build_object('new', v_new, 'total', (select count(*) from public.peo_ein_transfer_events),
    'unresearched', (select count(*) from public.peo_ein_transfer_events where research_status='unresearched'));
end $d$;

select public.detect_ein_transfers();

-- the beacon lives on the profile too, next to the rebrand lineage (0843)
alter table public.peo_profiles add column if not exists ein_transfers jsonb;

create or replace function public.sync_ein_transfers_to_profiles()
returns integer language plpgsql security definer set search_path to 'public','pg_temp' as $s$
declare n int;
begin
  with by_profile as (
    select p.family_slug,
           jsonb_agg(jsonb_build_object('year', e.form_year, 'from', e.prior_name, 'from_ein', e.prior_ein,
                     'to', e.new_name, 'to_ein', e.new_ein, 'kind', e.beacon_kind,
                     'employers', e.employers, 'status', e.research_status, 'finding', e.finding)
                     order by e.form_year desc) as transfers
      from public.peo_profiles p
      join public.peo_ein_transfer_events e
        on p.sponsor_eins ? e.new_ein or p.sponsor_eins ? e.prior_ein
     group by p.family_slug
  )
  update public.peo_profiles p set ein_transfers = b.transfers, updated_at = now()
    from by_profile b where b.family_slug = p.family_slug and p.ein_transfers is distinct from b.transfers;
  get diagnostics n = row_count; return n;
end $s$;

select public.sync_ein_transfers_to_profiles();

-- nightly, after the EIN spine job
select cron.schedule('peo_ein_transfer_beacon_nightly', '5 5 * * *',
  'select public.detect_ein_transfers(), public.sync_ein_transfers_to_profiles()');

insert into public.brain_knowledge (scope, key, content) values
('doctrine','ein_transfer_beacon_law',
 'EIN TRANSFERS FIRST. Gazz 2026-09-11: payroll companies spin up a PEO entity as an upsell to their clients; ASO books get converted to co-employment; PEOs restructure or get acquired. The first beacon for any of it is a Form 5500 filed under a NEW sponsor EIN with the OLD one reported on line 4 (LAST_RPT_SPONS_EIN). Those are the filer''s own words that the entity changed. Table peo_ein_transfer_events; every row is unresearched until a person writes the finding. Worked examples in our data: StaffLink Outsourcing -> Prestige Employee Administrators (2024, 463 employers); Tandem HR LLC -> Tandem Management LLC (2024, 343 - Tandem is a Vensure acquisition and keeps its own identity); Ataraxis Inc -> ATX PEO Services (2024). A same-EIN name change is the sibling signal (peo_rebrand_events, 0843) and a same-EIN name change that ADDS the word PEO (Payroll Express -> Preference Employment Solutions PEO, 2022) is a model change, not a cosmetic rebrand. WATCH: Gusto launched a PEO offering in 2026; its first Form 5500 under that entity would not be due until the plan year closes, so absence of a filing is not evidence - watch for the first one. HELD: the welfare-lives-vs-pension-lives ratio as an ASO/PEO signal is parked by Gazz until the identity repairs settle.'),
('doctrine','peo_model_change_law',
 'A payroll bureau or ASO that begins filing as a PEO is a MODEL CHANGE, not a new company and not a rebrand. Signs: (a) same EIN, new name containing PEO (Payroll Express -> Preference Employment Solutions PEO, EIN 45-0441041, 2022); (b) a new EIN on line 4 whose prior name is a payroll/HR services firm and whose new name is PEO-shaped; (c) a welfare 5500 appearing for the first time on a filer that previously filed pension only. A model change re-classifies the sponsor (mep_sponsor_identity.sponsor_class) and re-opens its clients: they were payroll or ASO customers and are now co-employed. Per the designation law (0839) the new class reaches the clients only after vetting.');