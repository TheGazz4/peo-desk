// peo-identity-check v1 (2026-09-12, claim instanceA-0880-nonpeo-sweep)
// TIER 2 of the non-PEO sweep. One question per family: is this a PEO / co-employer, or is it something else
// (staffing agency, insurance broker, payroll bureau, software vendor, ordinary operating company)?
// Free mesh evidence - sworn Schedule MEP box 1b, IRS CPEO list, state PEO licence - is checked in SQL first.
// Only families the mesh is silent on ever reach this paid lane.
//   1 Serper search (query ladder) + 1 Haiku grading -> {peo | not_a_peo | unknown} + confidence.
// Gates: serper_budget_ok() and brain_spend_ok() BEFORE any paid call (no-blind-spender law 0807/0808).
// Cost booked through log_brain_spend (one priced door); a failed ledger write goes to edge_debug, never swallowed.
// Serper credits booked through serper_budget_spend. Caps live in SQL (15 queued, 5 per batch).
// A verdict REMOVES NOTHING. peo_identity_check_promote() is a separate explicit call at 0.80+.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const MODEL = 'claude-haiku-4-5-20251001';
async function dbg(step: string, detail: unknown) {
  await sb.from('edge_debug').insert({ fn: 'peo-identity-check', step, detail: JSON.stringify(detail).slice(0, 3000) });
}

const SYSTEM = `You decide one thing about a named company, using ONLY the search results given: is it a PEO (a professional employer organization / co-employer / employee-leasing company that becomes the employer of record for other companies staff and provides their payroll, benefits and workers comp), or is it something else?
Answer not_a_peo when the company is any of: a staffing or temp agency that places workers but does not co-employ a client existing staff; a recruiting or executive search firm; an insurance agency, broker or benefits consultant; an insurance carrier; a payroll bureau or paymaster service; a third-party administrator or plan vendor; a background screening or compliance vendor; an HR software or IT company; a CPA or consulting firm; or an ordinary operating company that simply employs its own people.
Answer peo only when the results actually show co-employment: the company own site or a credible source describes it as a PEO, co-employer, employee leasing firm, or says it becomes the employer of record for client employees, or it holds a state PEO licence or IRS CPEO certification.
Answer unknown when the results do not settle it, including when the name is too generic to be sure the results are about the right company.
Rules: the company own website and a state or federal registry outrank directories and listicles. A staffing firm that ALSO sells a PEO service is peo. Do not infer from the name alone - "staffing" in a name is not proof either way, and neither is "HR". Being listed in some PEO directory is weak evidence on its own. Confidence is 0.00-1.00 and must reflect the evidence actually shown; below 0.70 a human decides, and anything at or above 0.80 can be acted on automatically, so be conservative.
Respond ONLY with JSON: {"verdict": string, "confidence": number, "summary": string (<=300 chars, plain language, say which result proved it), "sources": [urls used, max 4]}`;

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
  const { error } = await sb.rpc('log_brain_spend', { p_module: 'peo-identity-check', p_model: MODEL, p_in: inTok, p_out: outTok, p_note: note.slice(0, 120) });
  if (error) { await dbg('spend_ledger_write_failed', { note, inTok, outTok, err: error }); return false; }
  return true;
}

Deno.serve(async (req) => {
  const { batch_size = 5 } = await req.json().catch(() => ({}));
  const t0 = Date.now();

  const { data: serperOk } = await sb.rpc('serper_budget_ok');
  if (!serperOk) { await dbg('healthy_pause', { state: 'serper_budget_floor' }); return new Response(JSON.stringify({ skipped: 'serper budget floor' }), { status: 200 }); }
  const { data: brainOk } = await sb.rpc('brain_spend_ok');
  if (brainOk === false) { await dbg('healthy_pause', { state: 'brain_budget_capped' }); return new Response(JSON.stringify({ skipped: 'brain budget cap' }), { status: 200 }); }

  const { data: serperKey } = await sb.rpc('vault_secret', { p_name: 'serper_api_key' });
  const { data: anthKey } = await sb.rpc('vault_secret', { p_name: 'anthropic_api_key' });
  if (!serperKey || !anthKey) { await dbg('fatal', 'missing vault keys'); return new Response('keys', { status: 500 }); }

  const { data: batch, error: claimErr } = await sb.rpc('peo_identity_check_next', { p_limit: Math.min(batch_size, 5) });
  if (claimErr) { await dbg('claim_error', claimErr); return new Response('claim', { status: 500 }); }
  if (!batch?.length) return new Response(JSON.stringify({ done: 0, empty: true }), { status: 200 });

  let done = 0, unresolved = 0, errors = 0, serperCalls = 0, ledgerOk = 0, ledgerFailed = 0;
  const verdicts: any[] = [];
  for (const row of batch) {
    const name = row.family_display || row.family_slug;
    try {
      const ladder = [
        `"${name}" PEO OR "professional employer" OR co-employment OR "employee leasing"`,
        `"${name}" what we do services company`,
        `${name} company`,
      ];
      let organic: any[] = []; const queriesRun: string[] = [];
      for (const q of ladder) {
        const s = await serper(q, serperKey); serperCalls++; queriesRun.push(q);
        organic = (s.organic ?? []).slice(0, 8).map((o: any) => ({ title: o.title, link: o.link, snippet: o.snippet }));
        if (organic.length) break;
      }
      const user = `Company: "${name}"
Our database currently attributes ${row.clients ?? 'an unknown number of'} client companies to this name as their PEO.
Why it is being checked: ${row.why_queued}
Search results:
${JSON.stringify(organic).slice(0, 6000)}`;
      const { parsed: v, usage } = await haiku(anthKey, user);
      const inTok = Number(usage?.input_tokens) || 0, outTok = Number(usage?.output_tokens) || 0;
      if (await bookSpend(inTok, outTok, `identity ${row.family_slug}`)) ledgerOk++; else ledgerFailed++;

      const { data: status, error: applyErr } = await sb.rpc('peo_identity_check_apply', {
        p_check_id: row.check_id, p_verdict: String(v.verdict ?? 'unknown'), p_confidence: Number(v.confidence) || 0,
        p_sources: Array.isArray(v.sources) ? v.sources.slice(0, 4) : [], p_summary: String(v.summary ?? ''),
        p_usage: { input_tokens: inTok, output_tokens: outTok, serper_credits: queriesRun.length, queries: queriesRun },
      });
      if (applyErr) throw new Error(`apply: ${JSON.stringify(applyErr)}`);
      verdicts.push({ slug: row.family_slug, verdict: v.verdict, confidence: v.confidence, summary: v.summary });
      if (status === 'done') done++; else unresolved++;
    } catch (e) {
      errors++;
      await dbg('row_error', { check: row.check_id, slug: row.family_slug, err: String(e) });
      await sb.rpc('peo_identity_check_error', { p_check_id: row.check_id, p_err: String(e) });
    }
  }
  if (serperCalls) await sb.rpc('serper_budget_spend', { k: serperCalls });
  await dbg('batch_done', { done, unresolved, errors, serperCalls, ledgerOk, ledgerFailed, v: 1, ms: Date.now() - t0 });
  return new Response(JSON.stringify({ done, unresolved, errors, serperCalls, ledger_ok: ledgerOk, ledger_failed: ledgerFailed, verdicts, v: 1 }), { status: 200 });
});
