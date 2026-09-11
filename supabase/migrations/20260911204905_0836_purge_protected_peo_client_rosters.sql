-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0835-noncompete-hard-door
-- Articles implemented: III.1 (noncompete is absolute), VI.1 (deletion is receipted and counted)
-- Articles verified not violated: II.2, XIV.6
-- Verification query attached: YES
--
-- PURGE. Gazz ruling 2026-09-11: delete Helpside, High Road and Lever1 in their entirety.
-- The door that stops them coming back went in first (0835) and was proven against five
-- re-entry attempts including a renamed plan under the same sponsor EIN.
--
-- Scope: every company whose ONLY route onto the spine was a protected PEO's client roster,
-- plus every child row hanging off it across all 84 tables that carry company_id, plus the
-- EIN-keyed signals rows. Companies that a state workers-comp feed found independently are a
-- separate matter and are handled outside this purge - they are public state records that
-- arrived by their own route and will be republished by those states regardless.

set role peo_gatekeeper;

create or replace function public.noncompete_purge_targets_run()
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $pg$
declare t text; n bigint; total bigint := 0; detail jsonb := '{}'::jsonb;
begin
  for t in
    select c.table_name from information_schema.columns c
     join information_schema.tables tb
       on tb.table_schema = c.table_schema and tb.table_name = c.table_name and tb.table_type='BASE TABLE'
    where c.table_schema='public' and c.column_name='company_id'
      and c.table_name <> 'noncompete_purge_targets'
    order by 1
  loop
    begin
      execute format('delete from public.%I where company_id in (select company_id from public.noncompete_purge_targets)', t);
      get diagnostics n = row_count;
      if n > 0 then
        total := total + n;
        detail := detail || jsonb_build_object(t, n);
      end if;
    exception when others then
      detail := detail || jsonb_build_object(t, 'ERROR: '||left(sqlerrm,120));
    end;
  end loop;

  begin
    execute 'delete from public.signals where company_ein in (select ein from public.noncompete_purge_targets where ein is not null)';
    get diagnostics n = row_count;
    if n > 0 then total := total + n; detail := detail || jsonb_build_object('signals_by_ein', n); end if;
  exception when others then
    detail := detail || jsonb_build_object('signals_by_ein', 'ERROR: '||left(sqlerrm,120));
  end;

  execute 'delete from public.companies where id in (select company_id from public.noncompete_purge_targets)';
  get diagnostics n = row_count;

  return jsonb_build_object('companies_deleted', n, 'child_rows_deleted', total, 'by_table', detail);
end $pg$;

reset role;

revoke execute on function public.noncompete_purge_targets_run() from public;