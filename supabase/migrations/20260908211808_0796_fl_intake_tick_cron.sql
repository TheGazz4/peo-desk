-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-fl-promotion-gap-and-intake-conformance (#165)
-- Articles implemented: a source that lands must promote itself - no ingest step may depend on a
--                       human remembering to run it. Promotion, book rebuild and mesh refresh run on
--                       a schedule and are idempotent.
-- Articles verified not violated: sourcing never displayed; carrier internal-only; client street
--                       addresses never displayed; noncompete PEOs never worked; researched attribution
--                       never overwritten by a mechanical rebuild; writer conformance.
-- Verification query attached: YES
--
-- ROOT CAUSE OF THE FL GAP: promotion out of wc_coverage_fl_raw ran once, by hand, for batch A.
-- Nothing ever ran it again. This installs the tick that makes that impossible.

set role peo_gatekeeper;

create or replace function public.fl_intake_tick()
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare v_p jsonb; v_b jsonb; v_moved bigint;
begin
  select public.promote_fl_raw_coverage(25000) into v_p;
  v_moved := (v_p ->> 'promoted')::bigint;

  if v_moved > 0 then
    select public.rebuild_fl_master_policy_book() into v_b;
    perform public.mesh_ledger_refresh(true, 'FL');
  end if;

  return jsonb_build_object('promoted', v_moved, 'promote', v_p, 'book', v_b,
                            'ledger_refreshed', v_moved > 0);
end $$;

revoke all on function public.fl_intake_tick() from public, anon, authenticated;
grant execute on function public.fl_intake_tick() to service_role;

reset role;

select cron.schedule('fl_intake_tick', '13,43 * * * *', 'select public.fl_intake_tick()');

-- VERIFICATION
-- select jobname, schedule from cron.job where jobname = 'fl_intake_tick';
-- select public.fl_intake_tick();   -- {"promoted":0,...} when the archive is fully drained