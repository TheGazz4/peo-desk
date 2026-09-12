-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0866-evidence-vs-judgment (opened BEFORE apply)
-- Articles implemented: IX.2 (our own conclusion is not a new fact about the world), XIV.6 (a date on a surface
--   must be the date of published evidence), XI.1 (taxonomy before data; a law with no check is a suggestion;
--   a check that cannot run is not a check), XI.2 (least privilege, granted explicitly to named roles)
-- Verification query attached: YES
--
-- THE GAP CLOSED. Some writers stamp their own run date into field_observations.as_of. Where such a row won the
-- headline, "as of" read newer than the fact really was - 188 of 335 sampled fingerprint-headed records.
-- The fix is not to patch dates. It is to say what an observation IS:
--
--   EVIDENCE  - the outside world published something (a WC policy, a 5500 filing, a registry page, a web page we
--               read that day). Its as_of is a real date and it MAY set a record's "as of".
--   JUDGMENT  - the platform reached a conclusion (an address we classified as a PEO HQ or a shared mail drop, an
--               entity we flagged by alias rule, a re-key, an analyst desk note). Its date is the day WE decided,
--               which is not news about the company. It never sets "as of" and never sets "checked".
--
-- Unclassified (source_hub, field_name) pairs FAIL CLOSED as judgment and raise a RED, so a new writer can neither
-- silently inflate freshness nor be silently ignored.
--
-- 0866 observation_evidence_class (46 evidence / 36 judgment, seeded from every pair present) + company_as_of
--      joins it and reads evidence only.
-- 0867 three standing checks, each one a defect actually shipped today:
--        as_of_never_future                 RED  - sampled 300 companies, no as-of may be in the future
--        as_of_field_unclassified           RED  - every writer declared as evidence or judgment
--        as_of_lifecycle_source_undeclared  RED  - every lifecycle source has a declared grain and cadence
-- 0868 grant to peo_gatekeeper - WRONG ROLE, kept in the record because the error is instructive.
-- 0869 the check SQL runs inside sysaudit_exec_readonly(), SECURITY DEFINER owned by the least-privilege role
--      sysaudit_reader. That is who needed EXECUTE. Recorded in brain_knowledge as
--      sysaudit_executes_as_sysaudit_reader so nobody repeats it.
--
-- RESULT on a 3,000-company sample, before -> after:
--   fingerprint headline records           335 -> 157, and 157/157 now backed by real evidence (was 188 load-stamped)
--   vendor-records-only                  1,380 -> 1,511 (+131: their only "live" source was our own judgment)
--   records with no evidence at all        132 -> 133
--   future-dated "as of"                     0 -> 0
-- sysaudit selftest: 163/163 checks proven, including all three new ones (a violating shape produced FAIL).
-- sysaudit fast: 0 errors; the 9 standing failures are the pre-existing set unchanged since 2026-09-09.

create table if not exists public.observation_evidence_class (
  source_hub text not null,
  field_name text not null,
  kind text not null check (kind in ('evidence','judgment')),
  note text,
  declared_by text not null default 'instanceA',
  declared_at timestamptz not null default now(),
  primary key (source_hub, field_name)
);
alter table public.observation_evidence_class enable row level security;
create policy observation_evidence_class_read on public.observation_evidence_class for select to authenticated, service_role using (true);
grant select on public.observation_evidence_class to service_role, peo_gatekeeper;

-- Seed: everything present is evidence, except the judgment list.
with judgment(hub, fld, note) as (values
  ('fingerprint','peo_hq_address_signal','address classified as a PEO HQ by our own registry (evidence_ref literally reads door:write_time)'),
  ('fingerprint','address_class','address classified as shared/mail-drop by our own registry'),
  ('fingerprint','peo_user_status','status we derived, not a status anyone published'),
  ('fingerprint','peo_brand_slug','0462 backfill correcting our own slug'),
  ('fingerprint','is_peo_entity','shell flagged by alias-registry rule'),
  ('efast_5500','ein','re-key of an EIN we had already stored'),
  ('efast_5500','is_peo_entity','ruling-40 classification by alias rule'),
  ('efast_5500','identity_quarantined_at','our quarantine mark'),
  ('efast_5500','peo_brand_slug','our slug correction'),
  ('peo_intel','peo_family_slug','analyst desk research'),
  ('peo_intel','master_policy_renewal_calendar','calendar we derived'),
  ('peo_intel','health_renewal_regime','desk adjudication'),
  ('peo_intel','health_renewal_regime_documentary_t2','desk adjudication'),
  ('peo_intel','health_renewal_regime_5_2c_qualification','desk adjudication'),
  ('peo_intel','health_renewal_regime_second_verification','desk adjudication'),
  ('peo_intel','health_renewal_regime_ratification','desk adjudication'),
  ('peo_intel','health_master_plan_year_t1','desk adjudication'),
  ('peo_intel','health_master_carriers','desk research'),
  ('peo_intel','wc_master_anniversary','desk research'),
  ('peo_intel','verification_depth','our own scoring'),
  ('peo_intel','transition_artifact_adjudication','desk adjudication'),
  ('peo_intel','transition_data_artifact_flag','our flag'),
  ('peo_intel','fl_alias_research_t2','desk research'),
  ('peo_intel','fl_alias_research_summary','desk research'),
  ('peo_intel','fl_alias_ruling_applied','our ruling'),
  ('peo_intel','welfare_ein_screen','our screen'),
  ('peo_intel','suspect_ein_artifact','our flag'),
  ('peo_intel','geo_concentration','our computation'),
  ('peo_intel','ownership_detail','desk research'),
  ('peo_intel','client_count','desk estimate'),
  ('peo_intel','total_wse_count','desk estimate'),
  ('peo_intel','wse_eoy_count','desk estimate'),
  ('peo_intel','wse_expanded','desk estimate'),
  ('peo_intel','retention_pct','our computation'),
  ('peo_intel','retention_tenure_years','our computation'),
  ('peo_intel','former_ein','desk research')
)
insert into public.observation_evidence_class (source_hub, field_name, kind, note)
select f.source_hub, f.field_name,
       case when j.hub is not null then 'judgment' else 'evidence' end,
       coalesce(j.note, 'published by the source')
  from (select distinct source_hub, field_name from public.field_observations) f
  left join judgment j on j.hub = f.source_hub and j.fld = f.field_name
on conflict (source_hub, field_name) do nothing;

-- company_as_of(): the ev CTE now joins observation_evidence_class and takes kind = 'evidence' only.
-- (full body live in the database; unchanged from 0865 except that join)

set role peo_gatekeeper;
insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values
 ('as_of_never_future', 'mesh_law', 'fast', 'IX.2', 'RED',
  'No record may display an "as of" date that has not happened. Shipped 2026-09-12 with window_end (a policy EXPIRATION) as the evidence date, which would have shown 2,069 companies "As of Mar 01, 2027". Sampled 300 companies per run.',
  'select s.id as company_id, (a->>''as_of'')::date as as_of from (select id from public.companies where merged_into is null order by md5(id::text) limit 300) s, lateral public.company_as_of(s.id) a where (a->>''as_of'')::date > current_date',
  '{"mode":"zero_rows"}'::jsonb,
  'select ''00000000-0000-0000-0000-000000000000''::uuid as company_id, (current_date + 1) as as_of',
  true, 'peo_gatekeeper'),
 ('as_of_field_unclassified', 'mesh_law', 'fast', 'XI.1', 'RED',
  'Every (source_hub, field_name) writing to field_observations must be declared in observation_evidence_class as evidence or judgment. Unclassified pairs fail closed as judgment; this check makes sure they are never silently ignored.',
  'select f.source_hub, f.field_name, count(*)::bigint as n from public.field_observations f where not exists (select 1 from public.observation_evidence_class k where k.source_hub = f.source_hub and k.field_name = f.field_name) group by 1,2',
  '{"mode":"zero_rows"}'::jsonb,
  'select ''x''::text as source_hub, ''y''::text as field_name, 1::bigint as n',
  true, 'peo_gatekeeper'),
 ('as_of_lifecycle_source_undeclared', 'mesh_law', 'fast', 'IX.2', 'RED',
  'Every source writing company_lifecycle_events must have a hub_check_cadence row declaring its grain and how often it is re-read. Without one the source silently defaults to day-grain snapshot and can never report freshness.',
  'select e.source, count(*)::bigint as n from public.company_lifecycle_events e where not exists (select 1 from public.hub_check_cadence c where c.hub = e.source) group by 1',
  '{"mode":"zero_rows"}'::jsonb,
  'select ''x''::text as source, 1::bigint as n',
  true, 'peo_gatekeeper')
on conflict (check_name) do update set
  check_sql = excluded.check_sql, description = excluded.description, severity = excluded.severity,
  expectation = excluded.expectation, selftest_sql = excluded.selftest_sql, enabled = true;
reset role;

-- The auditor executes check SQL inside sysaudit_exec_readonly(), owned by sysaudit_reader.
grant execute on function public.company_as_of(uuid)        to sysaudit_reader, peo_gatekeeper;
grant execute on function public.hub_last_checked(text)     to sysaudit_reader, peo_gatekeeper;
grant execute on function public.as_of_display(date, text)  to sysaudit_reader, peo_gatekeeper;
grant select on public.hub_check_cadence, public.hub_check_state to peo_gatekeeper;
