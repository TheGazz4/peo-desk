// transfer-web-check v3 (2026-09-12
// v3: absorbed requires evidence the PRIOR brand is gone (site redirects/dead or an announced brand retirement). A live
//     own-brand site for PRIOR = brand_retained at most. v2 called Onondaga->ArmHR absorbed at 0.92 while oelspeo.com is live., claim instanceA-0856-transfer-web-check)
// v2: (a) query ladder - exact both-name query, then bare both names, then NEW name + PEO - because the v1 query
//     returned zero results for 2 of 7; (b) JSON extracted from the first {...} block (Haiku appended prose after
//     the JSON in 2 of 7); (c) prompt: a tracked-profile tag is a HINT not proof - v1 called two insurance agencies
//     'absorbed' at 0.92 because the tag said PEO. Both parties must be shown to be PEOs for absorbed/brand_retained.
// TIER 2 of the transfer-verdict law. For each Form 5500 line-4 beacon the rules could not settle:
//   1 Serper search + 1 Haiku grading -> verdict {absorbed | brand_retained | restructure_same_owner | dismissed | not_a_peo | unknown}
// Gates: serper_budget_ok() and brain_spend_ok() BEFORE any paid call (no-blind-spender law 0807/0808).
// Cost booked through log_brain_spend (one priced door); a failed ledger write is reported to edge_debug, never swallowed.
// Serper credits booked through serper_budget_spend. Queue cap (10/day) is enforced in SQL, not here.
// Verdict acceptance (>= 0.70) is enforced in transfer_web_check_apply(), not here.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const MODEL = 'claude-haiku-4-5-20251001';
async function dbg(step: string, detail: unknown) {
  await sb.from('edge_debug').insert({ fn: 'transfer-web-check', step, detail: JSON.stringify(detail).slice(0, 3000) });
}

const SYSTEM = `You resolve a Form 5500 "line 4" event: a retirement/welfare plan's sponsor changed from PRIOR (name+EIN) to NEW (name+EIN). Decide what happened to the PRIOR PEO's clients, using ONLY the search results given.
Verdicts:
- absorbed: PRIOR was acquired/merged and its brand retired; clients now served under NEW's brand.
- brand_retained: PRIOR was acquired by NEW's owner but keeps operating under its own brand (own live site, "a [Parent] company").
- restructure_same_owner: same business, new legal entity/EIN (reorganization, holding-company change, LLC conversion).
- dismissed: the change is administrative paperwork only (a TPA/recordkeeper EIN, a plan vendor, a fund name) - not a PEO ownership event.
- not_a_peo: neither party is a PEO/co-employer.
- unknown: results do not support any verdict.
Rules: a press release or the companies' own sites outrank directories. Do not guess from name similarity alone. A "[tracked PEO profile]" tag is only a hint from our database and can be WRONG: for absorbed or brand_retained the results themselves must show both parties are PEOs / co-employers / employee-leasing firms; if the parties are insurance agencies, staffing-only firms, plan vendors or ordinary employers, answer not_a_peo. absorbed additionally requires evidence that PRIOR's brand is gone (its site redirects to NEW or is dead, or a release says the brand was retired); if PRIOR still runs a live site under its own name, the most you may answer is brand_retained. Confidence is 0.00-1.00 and must reflect the evidence; anything below 0.70 means a human decides.
Respond ONLY with JSON: {"verdict": string, "confidence": number, "summary": string (<=300 chars, plain language, cite which result proved it), "sources": [urls used, max 4]}`;

async function serper(q: string, key: string) {
  const r = await fetch('https://google.serper.dev/search', {
    method: 'POST', headers: { 'X-API-KEY': key, 'Content-Type': 'application/json' },
    body: JSON.stringify({ q, num: 10 }),
  });
  if (!r.ok) throw new Error(`serper ${r.status}: ${(await r.text()).slice(0, 500)}`);
  return await r.json();
}
async function haiku(key: string, user: string) {
  const r = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST', headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: MODEL, max_tokens: 500, system: SYSTEM, messages: [{ role: 'user', content: user }] }),
  });
  if (!r.ok) throw new Error(`anthropic ${r.status}: ${(await r.text()).slice(0, 800)}`);
  const j = await r.json();
  const txt = (j.content ?? []).filter((c: any) => c.type === 'text').map((c: any) => c.text).join('');
  let parsed;
  const m = txt.match(/\{[\s\S]*?\}(?=\s*(?:```|$|\n))/);
  try { parsed = JSON.parse((m ? m[0] : txt).replace(/```json|```/g, '').trim()); }
  catch (e) { throw new Error(`haiku_json_parse_fail: ${String(e)} raw=${txt.slice(0, 500)}`); }
  return { parsed, usage: j.usage };
}
async function bookSpend(inTok: number, outTok: number, note: string) {
  const { error } = await sb.rpc('log_brain_spend', { p_module: 'transfer-web-check', p_model: MODEL, p_in: inTok, p_out: outTok, p_note: note.slice(0, 120) });
  if (error) { await dbg('spend_ledger_write_failed', { note, inTok, outTok, err: error }); return false; }
  return true;
}

Deno.serve(async (req) => {
  const { batch_size = 10 } = await req.json().catch(() => ({}));
  const t0 = Date.now();

  const { data: serperOk } = await sb.rpc('serper_budget_ok');
  if (!serperOk) { await dbg('healthy_pause', { state: 'serper_budget_floor' }); return new Response(JSON.stringify({ skipped: 'serper budget floor' }), { status: 200 }); }
  const { data: brainOk } = await sb.rpc('brain_spend_ok');
  if (brainOk === false) { await dbg('healthy_pause', { state: 'brain_budget_capped' }); return new Response(JSON.stringify({ skipped: 'brain budget cap' }), { status: 200 }); }

  const { data: serperKey } = await sb.rpc('vault_secret', { p_name: 'serper_api_key' });
  const { data: anthKey } = await sb.rpc('vault_secret', { p_name: 'anthropic_api_key' });
  if (!serperKey || !anthKey) { await dbg('fatal', 'missing vault keys'); return new Response('keys', { status: 500 }); }

  const { data: batch, error: claimErr } = await sb.rpc('transfer_web_check_next', { p_limit: Math.min(batch_size, 10) });
  if (claimErr) { await dbg('claim_error', claimErr); return new Response('claim', { status: 500 }); }
  if (!batch?.length) return new Response(JSON.stringify({ done: 0, empty: true }), { status: 200 });

  let done = 0, unresolved = 0, errors = 0, serperCalls = 0, ledgerOk = 0, ledgerFailed = 0;
  for (const row of batch) {
    try {
      // v2 query ladder: stop at the first query that returns anything. Each step costs one credit.
      const ladder = [
        `"${row.prior_name}" "${row.new_name}"`,
        `${row.prior_name} ${row.new_name} PEO acquisition OR merger OR "now part of"`,
        `${row.new_name} PEO`,
      ];
      let organic: any[] = []; const queriesRun: string[] = [];
      for (const q of ladder) {
        const s = await serper(q, serperKey); serperCalls++; queriesRun.push(q);
        organic = (s.organic ?? []).slice(0, 8).map((o: any) => ({ title: o.title, link: o.link, snippet: o.snippet }));
        if (organic.length) break;
      }
      const user = `PRIOR sponsor: "${row.prior_name}" (EIN ${row.prior_ein})${row.prior_profile ? ` [tracked PEO profile: ${row.prior_profile}]` : ''}
NEW sponsor: "${row.new_name}" (EIN ${row.new_ein})${row.new_profile ? ` [tracked PEO profile: ${row.new_profile}]` : ''}
Plan: "${row.plan_name}", plan year ${row.form_year}, participating employers: ${row.employers ?? 'n/a'}
Search results:
${JSON.stringify(organic).slice(0, 6000)}`;
      const { parsed: v, usage } = await haiku(anthKey, user);
      const inTok = Number(usage?.input_tokens) || 0, outTok = Number(usage?.output_tokens) || 0;
      if (await bookSpend(inTok, outTok, `transfer #${row.transfer_event_id} ${row.prior_name} -> ${row.new_name}`)) ledgerOk++; else ledgerFailed++;

      const { data: status, error: applyErr } = await sb.rpc('transfer_web_check_apply', {
        p_check_id: row.check_id, p_verdict: String(v.verdict ?? 'unknown'), p_confidence: Number(v.confidence) || 0,
        p_sources: Array.isArray(v.sources) ? v.sources.slice(0, 4) : [], p_summary: String(v.summary ?? ''),
        p_usage: { input_tokens: inTok, output_tokens: outTok, serper_credits: queriesRun.length, queries: queriesRun },
      });
      if (applyErr) throw new Error(`apply: ${JSON.stringify(applyErr)}`);
      if (status === 'done') done++; else unresolved++;
    } catch (e) {
      errors++;
      await dbg('row_error', { check: row.check_id, transfer: row.transfer_event_id, err: String(e) });
      await sb.rpc('transfer_web_check_error', { p_check_id: row.check_id, p_err: String(e) });
    }
  }
  if (serperCalls) await sb.rpc('serper_budget_spend', { k: serperCalls });
  await dbg('batch_done', { done, unresolved, errors, serperCalls, ledgerOk, ledgerFailed, v: 3, ms: Date.now() - t0 });
  return new Response(JSON.stringify({ done, unresolved, errors, serperCalls, ledger_ok: ledgerOk, ledger_failed: ledgerFailed, v: 3 }), { status: 200 });
});
