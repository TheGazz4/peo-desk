-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-tx-liveness-and-peo-codes
-- Articles implemented: no-guessing doctrine (a code is read from its published definition, never
--   inferred from row shape), Mesh Cross-Reference Mandate (a leasing code is PEO evidence)
-- Articles verified not violated: nothing is attributed from this table alone; it is a dictionary
-- Verification query attached: YES

-- ============================================================================
-- 0785  The WCIO employee-leasing policy type codes, written down
--
-- The TX coverage feed carries "PEO (Employee Leasing) Policy Indicator"
-- (column peo_employee_leasing_policy on data.texas.gov dataset c4xz-httr).
-- It is the WCIO "Employee Leasing Policy Type Code", a one-digit code on the
-- WCPOLS policy record, reaching Texas through IAIABC POC 2.1 filings collected
-- by NCCI. mesh_project_tx read only code 2 and the "LCF" name convention, and
-- nobody had written down what the other seven codes mean - so codes 4, 6, 7
-- and 8 were dropped on the floor without anyone deciding to drop them.
--
-- This records the published meaning of every code, with its source, so the
-- projection can cite a definition instead of a guess.
-- ============================================================================

set role peo_gatekeeper;

create table if not exists public.wcio_leasing_policy_codes (
  code              text primary key,
  official_meaning  text not null,
  tdi_label         text,
  named_insured     text not null,
  covers_leased     boolean not null,
  is_peo_own_policy boolean not null,
  implies_peo_relationship boolean not null,
  source_url        text not null,
  recorded_at       timestamptz not null default now()
);
alter table public.wcio_leasing_policy_codes enable row level security;

comment on table public.wcio_leasing_policy_codes is
  '0785: published meaning of the WCIO Employee Leasing Policy Type Code (one digit on the WCPOLS record; reaches Texas via IAIABC POC 2.1 collected by NCCI, surfaced as peo_employee_leasing_policy on data.texas.gov c4xz-httr). implies_peo_relationship is the field the mesh reads: TRUE means the employer named on the policy is in a co-employment arrangement, whichever side holds the policy. Read from the definitions, not inferred from row shape.';

insert into public.wcio_leasing_policy_codes
 (code, official_meaning, tdi_label, named_insured, covers_leased, is_peo_own_policy,
  implies_peo_relationship, source_url) values
 ('1','Non-Employee Leasing Policy. Employer is not in any leasing arrangement.',
   'Non PEO','employer', false, false, false,
   'https://data.texas.gov/dataset/Workers-compensation-insurance-coverage-subscriber/c4xz-httr'),
 ('2','Employee Leasing Policy for leased workers of MULTIPLE client companies; INCLUDES the leasing company''s own non-leased staff.',
   'Employee Leasing Co and Client Companies','PEO', true, false, true,
   'https://www.wcio.org/sites/default/files/2026-05/PEO%20Descriptions%20Master051326.pdf'),
 ('3','Employee Leasing Policy for the NON-leased workers of the employee leasing company. Covers the PEO''s own internal staff only.',
   'Employee Leasing Co Only','PEO', false, true, true,
   'https://www.wcio.org/sites/default/files/2026-05/PEO%20Descriptions%20Master051326.pdf'),
 ('4','Client Company Policy for the leased workers of the client company. The CLIENT is the named insured.',
   'Client Co Only','client', true, false, true,
   'https://www.wcio.org/sites/default/files/2026-05/PEO%20Descriptions%20Master051326.pdf'),
 ('5','Employee Leasing Policy for leased workers of a SINGLE client company. The classic PEO-to-client record; Texas writes it as "<PEO> LCF <CLIENT>".',
   'Leased Workers of Client Co','PEO', true, false, true,
   'https://www.wcio.org/sites/default/files/2026-05/PEO%20Descriptions%20Master051326.pdf'),
 ('6','Client Company Policy for the NON-leased workers of the client company. The client holds its own policy for direct staff while a leasing arrangement exists.',
   null,'client', false, false, true,
   'https://www.wcio.org/sites/default/files/2026-05/PEO%20Descriptions%20Master051326.pdf'),
 ('7','Client Company Policy covering BOTH the leased and non-leased workers of the client company.',
   null,'client', true, false, true,
   'https://www.wcio.org/sites/default/files/2026-05/PEO%20Descriptions%20Master051326.pdf'),
 ('8','Employee Leasing Policy for leased workers of MULTIPLE client companies; EXCLUDES the leasing company''s own staff.',
   null,'PEO', true, false, true,
   'https://www.wcio.org/sites/default/files/2026-05/PEO%20Descriptions%20Master051326.pdf'),
 ('9','Policy purchased by the client, single client, client is the sole named insured. Defined by WCIO; not described on the TDI column and not present in the Texas data.',
   null,'client', true, false, true,
   'https://www.wcio.org/sites/default/files/2026-05/PEO%20Descriptions%20Master051326.pdf')
on conflict (code) do nothing;

reset role;

do $verify$
declare v_codes int; v_peo int;
begin
  select count(*) into v_codes from public.wcio_leasing_policy_codes;
  if v_codes < 9 then
    raise exception '0785 verification: only % codes recorded', v_codes;
  end if;
  -- code 1 is the only one that is NOT a leasing relationship
  select count(*) into v_peo from public.wcio_leasing_policy_codes where implies_peo_relationship;
  if v_peo <> 8 then
    raise exception '0785 verification: expected 8 leasing-relationship codes, found %', v_peo;
  end if;
  if (select implies_peo_relationship from public.wcio_leasing_policy_codes where code='1') then
    raise exception '0785 verification: code 1 (ordinary employer) is marked as a leasing relationship';
  end if;
  if not (select is_peo_own_policy from public.wcio_leasing_policy_codes where code='3') then
    raise exception '0785 verification: code 3 is not marked as the PEO own policy';
  end if;
  if (select count(*) from public.wcio_leasing_policy_codes where source_url is null) > 0 then
    raise exception '0785 verification: a code was recorded without a source';
  end if;
  raise notice '0785 OK: % WCIO leasing codes recorded with sources', v_codes;
end $verify$;