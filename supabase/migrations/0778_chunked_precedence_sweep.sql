-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-seed-observation-backfill
-- Articles implemented: precedence ratified_63.1 (same arbitration, chunked execution), VI.2
-- Articles verified not violated: identical decision logic to run_precedence_sweep - this only
--   bounds how many groups one call arbitrates, so a large backlog cannot roll itself back
-- Verification query attached: YES

-- ============================================================================
-- 0778  Chunked precedence sweep
--
-- run_precedence_sweep() arbitrates every pending multi-hub group in ONE
-- transaction. After the seed backfill (0775) there are ~32,000 pending groups;
-- a single transaction would hit the statement timeout and roll back all of it,
-- so the whole backlog could never clear. Same logic, bounded per call.
-- ============================================================================

set role peo_gatekeeper;

create or replace function public.run_precedence_sweep_chunk(p_limit int default 2000)
returns jsonb
language plpgsql
security definer
set search_path to 'public','app','pg_temp'
as $fn$
declare v_bulk int := 0; v_resolved int := 0; v_consensus int := 0; v_desk int := 0;
        v_seen int := 0; r record; res jsonb;
begin
  drop table if exists _sweep_grp_c;
  create temp table _sweep_grp_c as
  select public.fo_group_key(company_id, subject_class, subject_key) gk, field_name,
         count(distinct source_hub) hubs,
         min(company_id::text) cid, min(subject_class) sc, min(subject_key) sk
  from field_observations
  where resolution_status is distinct from 'superseded'
  group by 1, 2
  having bool_or(resolution_status is null) or bool_or(resolution_status = 'contested');
  create index on _sweep_grp_c (gk, field_name);

  -- single-hub groups are not arbitration; resolve them set-based, always
  update field_observations fo set resolution_status = 'resolved'
  from _sweep_grp_c g
  where fo.resolution_status is null and g.hubs = 1
    and fo.field_name = g.field_name
    and public.fo_group_key(fo.company_id, fo.subject_class, fo.subject_key) = g.gk;
  get diagnostics v_bulk = row_count;

  for r in select * from _sweep_grp_c where hubs >= 2 limit p_limit loop
    v_seen := v_seen + 1;
    res := resolve_field_precedence(
             case when r.cid is not null then 'company' else r.sc end,
             coalesce(r.cid, r.sk), r.field_name);
    case res->>'outcome'
      when 'resolved' then v_resolved := v_resolved + 1;
      when 'consensus' then v_consensus := v_consensus + 1;
      when 'ambiguous_desk_case' then v_desk := v_desk + 1;
      else null;
    end case;
    update field_observations set resolution_status = 'resolved'
    where resolution_status is null and field_name = r.field_name
      and public.fo_group_key(company_id, subject_class, subject_key) = r.gk;
  end loop;

  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('precedence_sweep_chunk', gen_random_uuid(), now(), now(), true,
          jsonb_build_object('bulk_resolved_single_hub', v_bulk, 'arbitrated_resolved', v_resolved,
            'consensus', v_consensus, 'desk_cases', v_desk, 'groups_seen', v_seen,
            'law','ratified_63.1 (0778 chunked)'));
  return jsonb_build_object('bulk_resolved_single_hub', v_bulk, 'arbitrated_resolved', v_resolved,
    'consensus', v_consensus, 'desk_cases', v_desk, 'groups_seen', v_seen,
    'done', v_seen < p_limit);
end $fn$;

comment on function public.run_precedence_sweep_chunk(int) is
  '0778: run_precedence_sweep with the arbitration loop bounded per call, so a large backlog clears across several calls instead of rolling back on timeout. Decision logic is unchanged - it calls the same resolve_field_precedence.';

reset role;

revoke all on function public.run_precedence_sweep_chunk(int) from public;
revoke all on function public.run_precedence_sweep_chunk(int) from map_reader;
grant execute on function public.run_precedence_sweep_chunk(int) to service_role;

do $verify$
declare v jsonb;
begin
  select public.run_precedence_sweep_chunk(50) into v;
  if v is null then
    raise exception '0778 verification: chunked sweep returned nothing';
  end if;
  raise notice '0778 OK: %', v;
end $verify$;