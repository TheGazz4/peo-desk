-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-09-hub-brain-timeout (#167)
-- Articles implemented: the TX LCF lane gets an index instead of an 8.88 million row scan;
--                       a control that does not actually work is removed rather than left in place
--                       pretending to protect the run.
-- Articles verified not violated: sourcing never displayed; carrier internal-only; client street
--                       addresses never displayed; noncompete PEOs never worked; no change to what
--                       the TX brain concludes - only to how fast it reads.
-- Verification query attached: YES
--
-- WHAT 0798's NEW TIMER FOUND IMMEDIATELY
-- hub_brain_tx_wc: 54,785 ms. Roughly 17.5s of that is two identical LCF universe counts, each
-- scanning 8,882,562 staging rows to find 37,037 LCF names. Indexed here.
--
-- AND WHAT IT DISPROVED
-- 0798 put "set local statement_timeout" around each brain to stop one slow brain taking the run
-- down. It does not work: statement_timeout is measured against the OUTERMOST statement, so a
-- timeout set inside run_hub_brains() never applies to a brain invoked by EXECUTE. tx_wc ran 54.8s
-- against a declared 20s budget and reported ok. Removing the lines rather than leaving a control
-- that reads as protection and is not. Real isolation needs one brain per transaction; logged as
-- open work, not claimed as done. The MEASUREMENT in hub_brain_runs is real and is what caught this.

create index if not exists ix_tx_stg_lcf_client
  on public.tx_wc_fingerprint_staging (
    app.normalize_name(split_part(upper(insured_employer_name), ' LCF ', 2)),
    first_seen_at
  )
  where upper(insured_employer_name) like '% LCF %';

create or replace function public.run_hub_brains()
returns void
language plpgsql
as $function$
declare
  r record; v int := 0; v_ans int := 0; v_ans_total int := 0; v_applied int := 0;
  t0 timestamptz; v_ms int;
begin
  for r in select hub_slug, brain_fn from data_hubs where brain_fn is not null and status='live'
  loop
    -- NOTE: a per-brain statement_timeout cannot be set from here - statement_timeout applies to the
    -- outermost statement only. Duration is MEASURED and alarmed instead (hub_brain_time_budget).
    t0 := clock_timestamp();
    begin
      execute format('select %I()', r.brain_fn);
      v := v + 1;
      v_ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
      insert into hub_brain_runs (hub_slug, brain_fn, duration_ms, ok)
      values (r.hub_slug, r.brain_fn, v_ms, true);
    exception when others then
      v_ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
      insert into hub_brain_runs (hub_slug, brain_fn, duration_ms, ok, err)
      values (r.hub_slug, r.brain_fn, v_ms, false, left(sqlerrm, 300));
      insert into source_alerts (source_name, change_summary)
      values ('hub_brain:'||r.hub_slug, left(sqlerrm, 300));
    end;
    begin
      v_ans := hub_brain_answer_wants(r.hub_slug);
      v_ans_total := v_ans_total + coalesce(v_ans, 0);
    exception when others then
      insert into source_alerts (source_name, change_summary)
      values ('want_answer:'||r.hub_slug, left(sqlerrm, 300));
    end;
  end loop;

  begin
    v_applied := mesh_apply_ein_answers();
  exception when others then
    insert into source_alerts (source_name, change_summary)
    values ('mesh_apply_ein_answers', left(sqlerrm, 300));
  end;

  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('hub_brains', gen_random_uuid(), now(), now(), true,
    jsonb_build_object('brains_run', v, 'wants_answered', v_ans_total,
                       'ein_applied', v_applied, 'rail', 'mandate2_0305'));
end $function$;

-- VERIFICATION
-- explain analyze select count(distinct app.normalize_name(split_part(upper(insured_employer_name),' LCF ',2)))
--   from tx_wc_fingerprint_staging where upper(insured_employer_name) like '% LCF %';   -- index scan, sub-second
-- select run_hub_brains();
-- select hub_slug, duration_ms from hub_brain_runs order by ran_at desc limit 20;