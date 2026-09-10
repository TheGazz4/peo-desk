-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-10-peo-intel-brain (#169)
-- Articles implemented: A BRAIN IS A REPORTER (same law applied to peo_intel that 0801 applied to
--                       tx_wc). Minting sales plays is work, not reporting - it gets its own slot,
--                       its own real timeout and its own receipt.
--                       A control that cannot work is removed rather than left reading as protection.
-- Articles verified not violated: noncompete PEOs never worked - company_is_noncompete stays in every
--                       cohort query unchanged; sourcing never displayed; carrier internal-only;
--                       client street addresses never displayed; no cohort SQL altered, so no play
--                       changes who it targets or what it claims.
-- Verification query attached: YES
--
-- MEASUREMENT
-- hub_brain_peo_intel: 7,420ms, of which mint_thesis_plays() is 7,299ms - 98%. The reporting half
-- (the M&A conclusion loop and its mesh forwards) is about 120ms and usually processes zero events.
-- mint_thesis_plays minted 0 rows on the measured run: the 7.3s is the three cohort queries deciding
-- there is nothing new, every hour, inside the reporting tick.
--
-- proven_switcher alone is 2,984ms: a sequential scan of peo_switch_ledger where a correlated
-- max(evidence_as_of) subplan runs once per row (6,198 executions), then is_peo_targetable() and the
-- noncompete regex gate applied per surviving row. Priced below so the planner defers them; the
-- cohort SQL itself is left ALONE - it is correct, and on its own slot 7s is a non-issue.

-- 1. PRICE THE GATE ---------------------------------------------------------
alter function public.is_peo_targetable(uuid) cost 500;

-- 2. THE IN-FUNCTION TIMEOUT CANNOT WORK - REMOVE IT ------------------------
-- mint_thesis_plays() called set_config('statement_timeout','240000',true) hoping to buy itself four
-- minutes. statement_timeout is measured against the OUTERMOST statement, so a value set inside a
-- function invoked by another statement never applies - the same fact that sank 0798's per-brain
-- budget. The real timeout now lives in the cron command, where it binds.
create or replace function public.mint_thesis_plays()
returns jsonb
language plpgsql
as $function$
declare t record; v_minted int; v_total int := 0; v_res jsonb := '[]'::jsonb; v_err text;
begin
  -- NOTE: no set_config('statement_timeout') here. It would not bind. The budget is set by the
  -- caller as its own top-level statement (see the mint_thesis_plays cron job).
  for t in select * from play_theses where enabled loop
    v_minted := 0; v_err := null;
    begin
      execute format($f$
        insert into company_angles (company_id, angle_type, claim, evidence, evidence_tag, confidence, timing_window, suggested_channel, suggested_persona, status, evidence_hash)
        select q.company_id, %L, q.claim, q.evidence, q.evidence_tag, q.confidence,
               daterange(q.window_start, q.window_end, '[]'), %L, %L, 'live', q.evidence_hash
        from (%s) q
        where not exists (select 1 from company_angles a where a.evidence_hash = q.evidence_hash)
        limit 1000
        on conflict (company_id, angle_type) do nothing
      $f$, t.thesis_slug, t.suggested_channel, t.suggested_persona, t.cohort_sql);
      get diagnostics v_minted = row_count;
    exception when others then
      v_err := left(sqlerrm, 240);
      insert into source_alerts (source_name, change_summary)
      values ('mint_thesis_plays', t.thesis_slug||': '||v_err);
    end;
    v_res := v_res || case when v_err is null
      then jsonb_build_object('thesis', t.thesis_slug, 'minted', v_minted)
      else jsonb_build_object('thesis', t.thesis_slug, 'minted', v_minted, 'ERRORED', v_err) end;
    v_total := v_total + v_minted;
  end loop;
  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('mint_thesis_plays', gen_random_uuid(), now(), clock_timestamp(), true,
    jsonb_build_object('total_minted', v_total, 'by_thesis', v_res));
  return v_res;
end $function$;

-- 3. THE REPORTER ----------------------------------------------------------
-- Identical to before minus the mint call. Every M&A conclusion, mesh forward and aggregation-ruling
-- case is unchanged.
create or replace function public.hub_brain_peo_intel()
returns void
language plpgsql
as $function$
declare w timestamptz; r record; v_concl int := 0; v_cases int := 0; v_fwd int := 0;
begin
  select coalesce(max(concluded_at), now() - interval '7 days') into w
  from hub_conclusions where hub_slug='peo_intel';

  for r in
    select * from peo_ma_events where researched_at > w and event_kind <> 'no_relationship'
  loop
    insert into hub_conclusions (hub_slug, window_start, conclusion_kind, subject, as_of, detection_method, significance,
      changed_to, evidence_refs, affected, confidence, suggested_action, dedupe_key, detail)
    values ('peo_intel', w, 'ma_event_recorded', r.acquirer_slug||' -> '||r.counterparty_name,
      coalesce(r.event_date, r.researched_at::date),
      'peo_ma_events ledger (press-release sourced)',
      'acquired books fold into acquirer; renewal architecture and carrier lineup may shift; aggregation ruling may be needed if counterparty has own slug in our data',
      jsonb_build_object('event', r.event_kind, 'line', r.narrative_line),
      r.evidence, jsonb_build_object('family', r.acquirer_slug), 0.9,
      case when r.counterparty_slug is not null then 'aggregation ruling needed (Gazz-only per doctrine 61)' else 'narrative refresh only' end,
      'ma_concl:'||r.id, jsonb_build_object('ma_event_id', r.id))
    on conflict do nothing;
    v_concl := v_concl + 1;

    if mesh_send_mail(
         p_from => 'peo_intel', p_to => 'fingerprint', p_kind => 'offer',
         p_subject_class => 'peo', p_subject_key => r.acquirer_slug,
         p_payload => jsonb_build_object('ma_event', r.event_kind, 'acquirer', r.acquirer_slug,
           'counterparty', r.counterparty_name, 'counterparty_slug', r.counterparty_slug,
           'line', r.narrative_line),
         p_evidence_refs => jsonb_build_array(jsonb_build_object('table','peo_ma_events','id',r.id)),
         p_origin_hub => 'peo_intel',
         p_as_of => coalesce(r.event_date, r.researched_at::date),
         p_confidence => 0.9,
         p_dedupe_key => 'ma_fwd:'||r.id) is not null then
      v_fwd := v_fwd + 1;
    end if;

    if r.counterparty_slug is not null and exists (select 1 from companies c where c.peo_family_slug = r.counterparty_slug) then
      perform mesh_open_case('ma_aggregation_ruling_needed','peo', r.counterparty_slug,
        'acquired-by|'||r.acquirer_slug,
        jsonb_build_object('acquirer', r.acquirer_slug, 'counterparty', r.counterparty_name,
          'counterparty_slug', r.counterparty_slug, 'event_date', r.event_date,
          'question','Counterparty has attributed companies under its own slug and was acquired: does a family-aggregation ruling apply? Gazz-only per doctrine 61.'),
        'hub_brain_peo_intel');
      v_cases := v_cases + 1;
    end if;
  end loop;

  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('hub_brain_peo_intel', gen_random_uuid(), now(), clock_timestamp(), true,
    jsonb_build_object('ma_conclusions', v_concl, 'aggregation_cases', v_cases,
                       'letters_forwarded', v_fwd, 'worker', 'mint_thesis_plays (split out 0803)'));
exception when others then
  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('hub_brain_peo_intel', gen_random_uuid(), now(), clock_timestamp(), false,
    jsonb_build_object('error', left(sqlerrm,300), 'sqlstate', sqlstate));
  insert into edge_debug (fn, step, detail, at)
  values ('hub_brain_peo_intel','failed', left(sqlerrm,200), now());
end $function$;

-- 4. THE WORKER GETS ITS OWN SLOT, with a timeout that actually binds -------
select cron.schedule('mint_thesis_plays', '46 * * * *',
  'set statement_timeout = ''240s''; select public.mint_thesis_plays()');

-- VERIFICATION
-- select run_one_hub_brain('peo_intel');   -- duration_ms should fall from ~7,400 to ~120
-- select jobname, schedule, command from cron.job where jobname = 'mint_thesis_plays';
-- select name, ok, detail from jobs where name in ('hub_brain_peo_intel','mint_thesis_plays') order by finished_at desc limit 4;