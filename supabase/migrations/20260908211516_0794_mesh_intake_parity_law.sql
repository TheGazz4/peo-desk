-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-fl-promotion-gap-and-intake-conformance (#165)
-- Articles implemented: MESH INTAKE PARITY LAW. Every live state must declare, in SQL, how many
--                       distinct employers its source actually carries. The auditor compares that
--                       number to the mesh ledger every run. A state cannot go live without the
--                       declaration, and no adapter may measure liveness against a raw archive.
-- Articles verified not violated: sourcing never displayed; WC carrier internal-only; client street
--                       addresses never displayed; shared-address counts never displayed; noncompete
--                       PEOs never worked; read-only auditor path preserved; gatekeeper ownership of
--                       sysaudit_registry respected (writes made AS peo_gatekeeper).
-- Verification query attached: YES
--
-- WHY THIS EXISTS
-- Three defects found today were the same defect wearing different clothes:
--   TX    - projection silently dropped WCIO codes 4/6/7/8 (261 employers)
--   FL    - 16 of 17 source batches never promoted (169,335 rows, 31,623 employers)
--   FL/AZ - projection lanes did not partition; low-confidence policies fell between them
-- In every case the source held employers the mesh never saw, and NOTHING measured that.
-- Health checks counted rows arriving, never employers landing. This law measures the gap itself.

create table if not exists public.mesh_intake_parity_registry (
  state              text primary key,
  source_name_query  text         not null,
  tolerance_pct      numeric(5,2) not null default 2.00,
  basis              text         not null,
  registered_at      timestamptz  not null default now()
);

comment on table public.mesh_intake_parity_registry is
 'One row per live state. source_name_query returns a single bigint: DISTINCT normalised employer names the source carries as a co-employment relationship. The auditor compares it to distinct nk in mesh_state_ledger. A live adapter with no row here is itself a RED failure.';

grant select on public.mesh_intake_parity_registry to sysaudit_reader, service_role;

insert into public.mesh_intake_parity_registry (state, source_name_query, tolerance_pct, basis) values
('FL',
 'select count(distinct app.normalize_name(coalesce(nullif(btrim(raw->>''named_insured''),''''), raw->>''employer''))) from wc_coverage_fl_raw where raw->>''peo_client'' = ''Y''',
 2.00,
 'FL DWC digital download flags peo_client Y/N at source. Every Y row is a declared PEO client and must reach the ledger.'),
('TX',
 'select count(distinct app.normalize_name(insured_employer_name)) from tx_wc_fingerprint_staging where insured_employer_name ilike ''% LCF %'' or peo_leasing_flag::text in (''2'',''4'',''6'',''7'',''8'')',
 3.00,
 'WCIO Employee Leasing Policy Type codes 2,4,6,7,8 are co-employment relationships (see wcio_leasing_policy_codes). Code 3 is the PEO own-staff policy, deliberately excluded from the client ledger. Code 1 is an ordinary employer.'),
('AZ',
 'select count(distinct app.normalize_name(s.insured_name)) from az_ncci_staging s join az_master_policy_book b on b.carrier_ncci_id = s.carrier_ncci_id and b.policy_number = s.policy_number',
 2.00,
 'AZ intake is the NCCI staging rows that resolve to a known master policy.')
on conflict (state) do update
  set source_name_query = excluded.source_name_query,
      tolerance_pct     = excluded.tolerance_pct,
      basis             = excluded.basis;

create or replace function public.mesh_intake_parity()
returns table (state text, source_names bigint, mesh_names bigint,
               shortfall_pct numeric, tolerance_pct numeric)
language plpgsql
stable
security definer
set search_path to 'public','app','extensions'
as $$
declare r record; v_src bigint; v_mesh bigint;
begin
  for r in select * from public.mesh_intake_parity_registry order by state loop
    begin
      execute r.source_name_query into v_src;
    exception when others then
      v_src := null;
    end;
    select count(distinct m.nk) into v_mesh
      from public.mesh_state_ledger m where m.state = r.state;

    state         := r.state;
    source_names  := v_src;
    mesh_names    := v_mesh;
    shortfall_pct := case
                       when v_src is null then 100.00
                       when v_src = 0 then 0.00
                       else round((greatest(v_src - coalesce(v_mesh,0), 0)::numeric / v_src) * 100, 2)
                     end;
    tolerance_pct := r.tolerance_pct;
    return next;
  end loop;
end $$;

revoke all on function public.mesh_intake_parity() from public, anon, authenticated;
grant execute on function public.mesh_intake_parity() to service_role, sysaudit_reader;

set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'mesh_intake_parity_law', 'mesh_law', 'XI.2', 'all', 'RED',
 'Every live state must land in the mesh ledger substantially all of the distinct employers its own source declares as co-employment relationships. Fails when the shortfall exceeds the state declared tolerance, or when the declared source query cannot run. This is the check that would have caught the TX dropped-code gap, the FL unpromoted-batch gap, and the FL/AZ lane fall-through - each of which cost employers that no row-count health check could see.',
 'select state, source_names, mesh_names, shortfall_pct, tolerance_pct from mesh_intake_parity() where shortfall_pct > tolerance_pct',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''ZZ''::text as state, 1000::bigint as source_names, 10::bigint as mesh_names, 99.00::numeric as shortfall_pct, 2.00::numeric as tolerance_pct'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope,
      severity=excluded.severity, description=excluded.description,
      check_sql=excluded.check_sql, expectation=excluded.expectation,
      selftest_sql=excluded.selftest_sql;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'mesh_intake_parity_coverage', 'mesh_law', 'XI.2', 'all', 'RED',
 'A state cannot be live in the mesh without declaring how many employers its source carries. Any live adapter with no row in mesh_intake_parity_registry fails here. This is the mechanism that makes every FUTURE state inherit the parity law automatically instead of waiting to be inspected by hand.',
 'select a.state, a.hub_slug from mesh_state_adapters a where a.status = ''live'' and not exists (select 1 from mesh_intake_parity_registry r where r.state = a.state)',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''ZZ''::text as state, ''zz_wc''::text as hub_slug'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope,
      severity=excluded.severity, description=excluded.description,
      check_sql=excluded.check_sql, expectation=excluded.expectation,
      selftest_sql=excluded.selftest_sql;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'adapter_measures_projectable_intake', 'mesh_law', 'XI.1', 'all', 'RED',
 'A live adapter source_count_query must measure PROJECTABLE intake, not raw archive volume. An unfiltered count, or any count of a *_raw archive table, makes liveness rise forever regardless of whether the pump is working - which is exactly how the TX stall was masked and how 16 unpromoted Florida batches went unnoticed for weeks.',
 'select a.state, a.source_count_query from mesh_state_adapters a where a.status = ''live'' and (a.source_count_query is null or a.source_count_query !~* ''\m(where|exists|join)\M'' or a.source_count_query ~* ''_raw\M'')',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''ZZ''::text as state, ''select count(*) from zz_wc_raw''::text as source_count_query'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope,
      severity=excluded.severity, description=excluded.description,
      check_sql=excluded.check_sql, expectation=excluded.expectation,
      selftest_sql=excluded.selftest_sql;

reset role;

-- VERIFICATION
-- select * from mesh_intake_parity();
-- select * from mesh_intake_parity() where shortfall_pct > tolerance_pct;   -- must be empty
-- select sysaudit_selftest();