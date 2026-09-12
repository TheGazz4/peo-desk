-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0856-transfer-web-check
-- Articles implemented: VIII.2 (verdict before a client sees it), III.1 no-blind-spender (gated, priced, capped, registered),
--   XIV.4 (signal reaches the surface without a human bottleneck)
-- Articles verified not violated: IX.2, XIV.6 (summary is internal; narrative sentences unchanged)
-- Verification query attached: YES
--
-- TIER 2 of the transfer-verdict law (Gazz approved spend 2026-09-12). What the rules cannot settle goes to a
-- capped web check: Serper search ladder (1-3 credits) + one Haiku grading per beacon, max 10 per night. A verdict
-- is accepted only at confidence >= 0.70; weaker = unresolved + alert for a human. Human rulings never touched.
-- Edge function: supabase/functions/transfer-web-check (v3). First run 2026-09-12 on 7 beacons:
--   4 resolved (Xcel->XMT restructure; Ataraxis->ATX restructure; Staffmark restructure; J.Gregory->NestEggs dismissed TPA),
--   1 corrected by hand (Onondaga->ArmHR: brand_retained, prior site live), 1 overruled (Safebuilt: insurance, not a PEO),
--   1 unresolved (Premier Staffing->GSD Decisions). Cost: $0.018 Haiku + 12 Serper credits.

create table if not exists public.transfer_web_checks (
  id bigserial primary key,
  transfer_event_id bigint not null references public.peo_ein_transfer_events(id),
  status text not null default 'pending' check (status in ('pending','claimed','done','unresolved','error')),
  queued_at timestamptz not null default now(),
  claimed_at timestamptz, checked_at timestamptz,
  verdict text check (verdict is null or verdict in ('absorbed','brand_retained','restructure_same_owner','dismissed','not_a_peo','unknown')),
  confidence numeric(3,2),
  sources jsonb, summary text, usage jsonb,
  unique (transfer_event_id)
);
alter table public.transfer_web_checks enable row level security;
grant select, insert, update on public.transfer_web_checks to service_role;
grant usage on sequence public.transfer_web_checks_id_seq to service_role;

create or replace function public.queue_transfer_web_checks(p_cap int default 10)
returns integer language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare n int; used int;
begin
  select count(*) into used from public.transfer_web_checks where queued_at::date = current_date;
  if used >= p_cap then return 0; end if;
  insert into public.transfer_web_checks(transfer_event_id)
  select e.id from public.peo_ein_transfer_events e
   where e.resolution = 'pending_research' and coalesce(e.researched_by,'') not ilike 'gazz%'
     and not exists (select 1 from public.transfer_web_checks w where w.transfer_event_id = e.id)
     and not exists (select 1 from public.source_alerts a where a.source_name='peo_ein_transfer_events'
                        and a.change_summary like 'HELD transfer #'||e.id||' %' and not a.acknowledged)
   order by e.employers desc nulls last, e.id
   limit (p_cap - used);
  get diagnostics n = row_count;
  return n;
end $f$;

create or replace function public.transfer_web_check_next(p_limit int default 5)
returns table (check_id bigint, transfer_event_id bigint, prior_name text, prior_ein text, new_name text, new_ein text,
               plan_name text, form_year int, employers int, prior_profile text, new_profile text)
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
begin
  return query
  with c as (
    select w.id from public.transfer_web_checks w where w.status='pending' order by w.queued_at, w.id limit p_limit for update skip locked
  ), u as (
    update public.transfer_web_checks w set status='claimed', claimed_at=now() from c where w.id=c.id returning w.id, w.transfer_event_id
  )
  select u.id, u.transfer_event_id, e.prior_name, e.prior_ein, e.new_name, e.new_ein, e.plan_name, e.form_year, e.employers,
         (select p.family_slug from public.peo_profiles p where p.sponsor_eins ? e.prior_ein limit 1),
         (select p.family_slug from public.peo_profiles p where p.sponsor_eins ? e.new_ein limit 1)
    from u join public.peo_ein_transfer_events e on e.id = u.transfer_event_id;
end $f$;

create or replace function public.transfer_web_check_apply(p_check_id bigint, p_verdict text, p_confidence numeric, p_sources jsonb, p_summary text, p_usage jsonb default null)
returns text language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v_eid bigint; v_status text; v_pushed int;
begin
  select transfer_event_id into v_eid from public.transfer_web_checks where id = p_check_id;
  if v_eid is null then return 'no_such_check'; end if;
  if p_verdict in ('absorbed','brand_retained','restructure_same_owner','dismissed','not_a_peo') and p_confidence >= 0.70 then
    update public.peo_ein_transfer_events
       set resolution = p_verdict, research_status = 'researched', researched_by = 'auto_web', researched_at = now(),
           finding = 'WEB CHECK ('||round(p_confidence,2)||'): '||left(coalesce(p_summary,''),600)
     where id = v_eid and coalesce(researched_by,'') not ilike 'gazz%';
    v_status := 'done';
  else
    v_status := 'unresolved';
    insert into public.source_alerts(source_name, change_summary)
    values ('peo_ein_transfer_events', 'UNRESOLVED after web check: transfer #'||v_eid||' verdict='||coalesce(p_verdict,'none')||
            ' conf='||coalesce(round(p_confidence,2)::text,'?')||' - human call needed');
  end if;
  update public.transfer_web_checks
     set status = v_status, checked_at = now(), verdict = p_verdict, confidence = p_confidence,
         sources = p_sources, summary = left(p_summary, 2000), usage = p_usage
   where id = p_check_id;
  if v_status = 'done' then
    v_pushed := public.push_ein_transfers_to_lifecycle();
    perform public.sync_ein_transfers_to_profiles();
  end if;
  return v_status;
end $f$;

create or replace function public.transfer_web_check_error(p_check_id bigint, p_err text)
returns void language sql security definer set search_path to 'public','pg_temp' as $f$
  update public.transfer_web_checks set status='error', checked_at=now(), summary=left(p_err,2000) where id=p_check_id;
$f$;

insert into public.ai_caller_registry(fn_slug, calls_llm, models, cost_path, cost_module, budget_gated, gate_fn, is_blind, can_reach_fable, verified_at, verified_by, note)
values ('transfer-web-check', true, array['claude-haiku-4-5-20251001'], 'api_spend_ledger', 'transfer-web-check', true, 'brain_spend_ok', false, false, now(), 'deploy-v3-2026-09-12',
        'Tier 2 transfer verdicts: serper_budget_ok + brain_spend_ok gates; books via log_brain_spend; serper_budget_spend per search; hard cap 10 checks/day in queue_transfer_web_checks')
on conflict (fn_slug) do update set models=excluded.models, cost_path=excluded.cost_path, cost_module=excluded.cost_module,
  budget_gated=true, gate_fn=excluded.gate_fn, is_blind=false, can_reach_fable=false, verified_at=now(), verified_by=excluded.verified_by, note=excluded.note;

select cron.unschedule(jobname) from cron.job where jobname='transfer_web_check_nightly';
select cron.schedule('transfer_web_check_nightly', '20 5 * * *', $c2$
  do $b$ begin
    perform public.queue_transfer_web_checks(10);
    if (select count(*) from public.transfer_web_checks where status='pending') > 0
       and serper_budget_ok() and brain_spend_ok() then
      perform net.http_post('https://lzasgflrxxrssjntrfmt.supabase.co/functions/v1/transfer-web-check',
        '{"batch_size":10}'::jsonb, '{}'::jsonb,
        jsonb_build_object('Content-Type','application/json','Authorization','Bearer <publishable key>'),
        timeout_milliseconds := 115000);
    end if;
  end $b$;
$c2$);
