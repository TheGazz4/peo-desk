-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-switch-dating-authority
-- Articles implemented: precedence ratified_63.1 (generalised), ONE-DOOR LAW (the ledger is the
--   door; nothing writes a switch without passing this), Mesh Mandate 6 (refusals logged, never silent)
-- Articles verified not violated: every source that legitimately dates a switch today is declared
--   with a basis and keeps working - asserted per source in the verification block
-- Verification query attached: YES

-- ============================================================================
-- 0782  Switch dating authority - universal, and fail-closed for future sources
--
-- Gazz 2026-09-08: "The renew rule needs to apply to all sources and future
-- sources."
--
-- 0774 put the undated-source guard inside resolve_field_precedence. Too narrow:
-- switches are minted from callers that never touch precedence - obs_precedence
-- (4,622), own-5500 departures (745), form5500_mep (677),
-- residual_listing_signature (194), seed disagreement pools. A rule that lives
-- in one caller is not a rule.
--
-- Moved to the one place every switch must pass: a BEFORE INSERT trigger on
-- peo_switch_ledger. Current callers, future callers and hand inserts are all
-- bound, with no further code changes.
--
-- THE RULE: a switch date may only be set by a source that can date itself.
--   1. Explicit declaration in switch_dating_authority wins (each carries a
--      basis naming WHERE the date comes from); a refusal beats an allowance.
--   2. Otherwise normalise the source and read source_registry: M4_undated is
--      refused, any dated grade is allowed.
--   3. Undeclared and ungraded is REFUSED. Fail closed - that is what binds
--      future sources: a new feed must declare its dating authority first.
--
-- Refusals land in switch_dating_refusals, never silent.
-- ============================================================================

set role peo_gatekeeper;

create table if not exists public.switch_dating_authority (
  pattern      text primary key,
  can_date     boolean not null,
  basis        text not null,
  declared_by  text not null default 'instanceA-2026-09-08-switch-dating-authority',
  declared_at  timestamptz not null default now()
);
alter table public.switch_dating_authority enable row level security;

comment on table public.switch_dating_authority is
  '0782: who may set the DATE of a PEO switch. pattern is matched case-insensitively against peo_switch_ledger.evidence_source. Anything neither declared here nor graded as a dated source in source_registry is refused - fail closed, so a future feed must declare its dating authority before it can date a switch.';

create table if not exists public.switch_dating_refusals (
  id               bigserial primary key,
  refused_at       timestamptz not null default now(),
  company_id       uuid,
  ein              text,
  from_family_slug text,
  to_family_slug   text,
  evidence_as_of   date,
  evidence_source  text,
  detection_method text,
  reason           text not null
);
alter table public.switch_dating_refusals enable row level security;

comment on table public.switch_dating_refusals is
  '0782: every switch the dating-authority rule turned away, with the source that tried. A refusal is a finding, not a silence.';

insert into public.switch_dating_authority (pattern, can_date, basis) values
 ('^precedence_63:', true,
  'Precedence arbitration: the date is the winning observation as_of, and 0774 forbids an M4_undated source from being that winner.'),
 ('^obs_precedence', true,
  'Derived from dated field_observations under ratified_63.1; the date is the observation as_of, not the detection day.'),
 ('^obs_ledger sequence', true,
  'Derived from the dated order of observations; the date is an observed boundary.'),
 ('^own 5500', true,
  'Form 5500 departure detection: the date is a filed plan-year boundary.'),
 ('^form5500_mep', true,
  'Form 5500 MEP participation: the date is a filed plan year.'),
 ('^residual_listing_signature', true,
  'State listing sequence: the date is a state filing boundary.'),
 ('^tx_wc', true,
  'Texas WC policy dates are filed effective dates.'),
 ('^miedge_seed$', true,
  'Owner desk rulings 2026-08-11 (class-3 protocol, merge-cases 730/733): the seed supplied the PEO, the DATE came from renewal-cycle analysis ruled by Gazz. Legacy declaration, scoped to that exact string.'),
 ('seed_disagreement_pool', false,
  'REFUSED. Detected by comparing a seed value to the current record; the only date available is the day we noticed. Four such rows exist and are marked date-unreliable rather than reversed.'),
 ('^seed:', false,
  'REFUSED. A vendor seed file has no vintage of its own - as_of is the load date.'),
 ('^ca_sos', false,
  'REFUSED. Registry snapshot, M4_undated - no event date of its own.'),
 ('^peo_roster_manual', false,
  'REFUSED. Manual roster, M4_undated - no event date of its own.')
on conflict (pattern) do nothing;

reset role;

create or replace function public.switch_dating_allowed(p_evidence_source text)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public','pg_temp'
as $fn$
declare v_can boolean; v_grade text;
begin
  if nullif(btrim(p_evidence_source),'') is null then
    return false;
  end if;

  select bool_and(a.can_date) into v_can
  from switch_dating_authority a
  where p_evidence_source ~* a.pattern;
  if v_can is not null then
    return v_can;
  end if;

  select m_grade into v_grade
  from source_registry
  where source_slug = normalize_source_slug(split_part(btrim(p_evidence_source), ':', 1));

  if v_grade is null then
    return false;
  end if;
  return v_grade <> 'M4_undated';
end $fn$;

comment on function public.switch_dating_allowed(text) is
  '0782: may this evidence source set the DATE of a PEO switch? Explicit declaration wins (refusal beats allowance); otherwise the source must be graded in source_registry as something other than M4_undated. Undeclared and ungraded is REFUSED - fail closed.';

revoke all on function public.switch_dating_allowed(text) from public;
revoke all on function public.switch_dating_allowed(text) from map_reader;
grant execute on function public.switch_dating_allowed(text) to peo_gatekeeper;
grant execute on function public.switch_dating_allowed(text) to service_role;

set role peo_gatekeeper;

create or replace function public.trg_switch_dating_authority()
returns trigger
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $fn$
begin
  if public.switch_dating_allowed(new.evidence_source) then
    return new;
  end if;
  insert into switch_dating_refusals
    (company_id, ein, from_family_slug, to_family_slug, evidence_as_of,
     evidence_source, detection_method, reason)
  values (new.company_id, new.ein, new.from_family_slug, new.to_family_slug,
          new.evidence_as_of, new.evidence_source, new.detection_method,
          'source_may_not_date_a_switch (0782): undeclared, ungraded, or M4_undated');
  return null;
end $fn$;

update public.peo_switch_ledger
set valid_time_known = false,
    precision = 'unknown',
    date_recoverable_from = '0782: evidence_as_of was the detection day, not the switch day. The seed disagreement pool has no vintage. The switch itself is corroborated by form5500_mep; only the date is unreliable.'
where evidence_source ilike '%seed_disagreement_pool%'
  and coalesce(valid_time_known, true);

-- the ledger is trigger-hardened: the owner grants itself TRIGGER for the install, then takes it back
grant trigger on public.peo_switch_ledger to peo_gatekeeper;

drop trigger if exists zz_switch_dating_authority on public.peo_switch_ledger;
create trigger zz_switch_dating_authority
  before insert on public.peo_switch_ledger
  for each row execute function public.trg_switch_dating_authority();

revoke trigger on public.peo_switch_ledger from peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
select 'switch_dating_authority_law', 'doctrine', 'owner ruling 2026-09-08', 'all', 'RED',
  'A PEO switch date may only be set by a source that can date itself. FAIL = a ledger row claiming a known valid time whose evidence_source is not permitted to date a switch (undeclared, ungraded, or M4_undated).',
  $q$select id, evidence_source, evidence_as_of
     from peo_switch_ledger
     where coalesce(valid_time_known, true)
       and not switch_dating_allowed(evidence_source)
     limit 50$q$,
  '{"mode":"zero_rows"}'::jsonb,
  $q$select 1 as id, 'undeclared_future_feed' as evidence_source, current_date as evidence_as_of$q$
where not exists (select 1 from public.sysaudit_registry where check_name='switch_dating_authority_law');

reset role;

do $verify$
declare v_bad int; v_ref int;
begin
  if not public.switch_dating_allowed('precedence_63:tx_wc') then
    raise exception '0782 verification: precedence/tx_wc was silenced'; end if;
  if not public.switch_dating_allowed('obs_precedence') then
    raise exception '0782 verification: obs_precedence was silenced'; end if;
  if not public.switch_dating_allowed('own 5500 FY2020-2023 to trinet PEO-book FY2024') then
    raise exception '0782 verification: own-5500 departures were silenced'; end if;
  if not public.switch_dating_allowed('form5500_mep') then
    raise exception '0782 verification: form5500_mep was silenced'; end if;
  if not public.switch_dating_allowed('residual_listing_signature') then
    raise exception '0782 verification: residual listing signature was silenced'; end if;
  if not public.switch_dating_allowed('tx_wc+form5500_mep_cross_source') then
    raise exception '0782 verification: tx_wc cross-source was silenced'; end if;
  if not public.switch_dating_allowed('precedence_63:efast_mep') then
    raise exception '0782 verification: efast_mep was silenced'; end if;
  if not public.switch_dating_allowed('miedge_seed') then
    raise exception '0782 verification: the owner-ruled legacy rows were silenced'; end if;

  if public.switch_dating_allowed('seed:miEdge') then
    raise exception '0782 verification: a vendor seed can still date a switch'; end if;
  if public.switch_dating_allowed('seed_disagreement_pool+form5500_mep_corroborated') then
    raise exception '0782 verification: the seed disagreement pool can still date a switch'; end if;
  if public.switch_dating_allowed('ca_sos') then
    raise exception '0782 verification: an undated registry snapshot can still date a switch'; end if;
  if public.switch_dating_allowed('some_feed_nobody_has_declared_yet') then
    raise exception '0782 verification: the rule is NOT fail-closed for future sources'; end if;
  if public.switch_dating_allowed(null) then
    raise exception '0782 verification: a switch with no named source is allowed'; end if;

  if not exists (select 1 from pg_trigger where tgname='zz_switch_dating_authority'
                 and tgrelid='public.peo_switch_ledger'::regclass) then
    raise exception '0782 verification: the ledger door is not installed';
  end if;

  select count(*) into v_bad from public.peo_switch_ledger
   where coalesce(valid_time_known,true) and not public.switch_dating_allowed(evidence_source);
  if v_bad > 0 then
    raise exception '0782 verification: % dated switches remain from sources that may not date one', v_bad;
  end if;

  select count(*) into v_ref from public.peo_switch_ledger
   where evidence_source ilike '%seed_disagreement_pool%' and valid_time_known = false;
  raise notice '0782 OK: door installed, fail-closed, % seed-disagreement rows marked date-unreliable', v_ref;
end $verify$;