// efast-pump v12: MAIN FORM OWNS SPONSOR IDENTITY (instanceA, 2026-09-11).
// The Schedule MEP header lane (sch_mep_*) was allowed to INSERT the `ein` column
// first, and flushMain's "null-enrichment" rule coalesce(existing.ein, excluded.ein)
// then refused to correct it when the main form arrived. The EIN on the Schedule
// MEP dataset is the FILER/ADMINISTRATOR's in practice (2,287 rows -> 232 EINs,
// ~10 plans per EIN; admin_name = the same TPA on every one), not the sponsor's.
// Result: 540 filings carried a TPA's EIN as their sponsor EIN, one Utah TPA
// (National Benefit Services, 20-3886993) was credited with a dozen unrelated
// plans, and a protected PEO's client roster slipped past the noncompete fence.
//   (1) flushMepHdr no longer writes `ein` at all. A schedule never owns identity.
//   (2) flushMain: when the existing row was created by a schedule lane, the main
//       form's SPONS_DFE_EIN OVERWRITES it, and lane ownership moves to main.
//   (3) Everything else byte-identical to v11.
// v11: three capture repairs (Instance B, 2026-08-17).
// (1) sch_mep_* header lanes previously had NO route in laneKindOf and fell through
//     to 'main', colliding with main_* lanes on the ack_id PK and writing the
//     Schedule MEP Part I type code into entity_type_cd (two code systems, one
//     column, load-order coin flip). New 'mep_hdr' kind writes mep_type_cd only
//     and never touches entity_type_cd.
// (2) New 'sf' kind: sf_* lanes -> efast_5500_sf_staging (Form 5500-SF small plans,
//     the ICP size band, never previously ingested). Column names verified against
//     DOL's f_5500_sf_2024_latest_layout.txt.
// (3) main lanes now capture TOT_PARTCP_BOY_CNT -> tot_participants (was never
//     requested; NULL across all ~1.28M staged filings).
// v10 contact-spine capture, v9 DISTINCT ON dedupe, v8 NULL-ENRICHMENT retained.
import { createClient } from 'jsr:@supabase/supabase-js@2';
import postgres from 'npm:postgres@3.4.5';

const WALL_BUDGET_MS = 280_000;
const DEFAULT_ROW_BUDGET = 12_000;
const FLUSH_ROWS = 1000;
const CHECKPOINT_EVERY_FLUSHES = 4;
const PASS_INTERVAL_DAYS = 7;
const CR = 0x0d, LF = 0x0a, QUOTE = 0x22;

const DEFAULT_WANT: Record<string, string[]> = {
  ack_id: ['ACK_ID'],
  ein: ['SPONS_DFE_EIN','SPONSOR_DFE_EIN'],
  plan_num: ['SPONS_DFE_PN','PLAN_NUM'],
  sponsor_name: ['SPONSOR_DFE_NAME','SPONS_DFE_NAME'],
  plan_name: ['PLAN_NAME'],
  entity_type_cd: ['TYPE_PLAN_ENTITY_CD','TYPE_DFE_PLAN_ENTITY_CD'],
  mail_city: ['SPONS_DFE_MAIL_US_CITY'],
  mail_state: ['SPONS_DFE_MAIL_US_STATE'],
  mail_zip: ['SPONS_DFE_MAIL_US_ZIP'],
  plan_year_begin: ['FORM_PLAN_YEAR_BEGIN_DATE'],
  tax_period: ['FORM_TAX_PRD'],
  date_received: ['DATE_RECEIVED'],
  last_rpt_spons_name: ['LAST_RPT_SPONS_NAME'],
  last_rpt_spons_ein: ['LAST_RPT_SPONS_EIN'],
  spons_signed_name: ['SPONS_SIGNED_NAME','SF_SPONS_SIGNED_NAME'],
  spons_signed_date: ['SPONS_SIGNED_DATE','SF_SPONS_SIGNED_DATE'],
  admin_signed_name: ['ADMIN_SIGNED_NAME','SF_ADMIN_SIGNED_NAME'],
  admin_signed_date: ['ADMIN_SIGNED_DATE','SF_ADMIN_SIGNED_DATE'],
  admin_name: ['ADMIN_NAME','SF_ADMIN_NAME'],
  spons_phone: ['SPONS_DFE_PHONE_NUM','SPONS_DFE_PHONE','SF_SPONS_PHONE_NUM'],
  admin_phone: ['ADMIN_PHONE_NUM','ADMIN_PHONE','SF_ADMIN_PHONE_NUM'],
  sponsor_dba_name: ['SPONS_DFE_DBA_NAME','SF_SPONS_DBA_NAME'],
  // v11: participant count, was never captured.
  tot_participants: ['TOT_PARTCP_BOY_CNT'],
};

type LaneKind = 'main' | 'mep_part' | 'mep_hdr' | 'sch_a' | 'sf';
const laneKindOf = (lane: string): LaneKind =>
  lane.startsWith('sch_mep_part') ? 'mep_part'
  : lane.startsWith('sch_mep') ? 'mep_hdr'
  : lane.startsWith('sch_a') ? 'sch_a'
  : lane.startsWith('sf_') ? 'sf'
  : 'main';
const CRITICAL_KEYS: Record<LaneKind, string[]> = {
  main: ['ack_id', 'ein'],
  mep_part: ['ack_id', 'employer_name'],
  mep_hdr: ['ack_id', 'mep_type_cd'],
  sch_a: ['ack_id', 'carrier_name'],
  sf: ['ack_id', 'ein'],
};

const u16 = (b: Uint8Array, o: number) => b[o] | (b[o + 1] << 8);
const u32 = (b: Uint8Array, o: number) => (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16)) + b[o + 3] * 0x1000000;
const dateOr = (s: string | null) => (s && /^\d{4}-\d{2}-\d{2}/.test(s) ? s.slice(0, 10) : null);

function asObj<T>(v: unknown): T | null {
  if (v == null) return null;
  if (typeof v === 'string') { try { return JSON.parse(v) as T; } catch { return null; } }
  if (typeof v === 'object') return v as T;
  return null;
}

function parseCsvLine(line: string): string[] {
  const out: string[] = [];
  let cur = '', inQ = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (inQ) {
      if (ch === '"') { if (line[i + 1] === '"') { cur += '"'; i++; } else inQ = false; }
      else cur += ch;
    } else if (ch === '"') inQ = true;
    else if (ch === ',') { out.push(cur); cur = ''; }
    else cur += ch;
  }
  out.push(cur);
  return out;
}

async function inspectZip(url: string): Promise<{ dataStart: number; compSize: number; uncompSize: number; method: number; lastModified: string | null }> {
  const head = await fetch(url, { method: 'HEAD' });
  if (!head.ok) throw new Error('HEAD ' + head.status);
  const total = Number(head.headers.get('content-length'));
  const lastModified = head.headers.get('last-modified');
  if (!Number.isFinite(total) || total < 60) throw new Error('bad content-length');
  const tailLen = Math.min(66_000, total);
  const tail = new Uint8Array(await (await fetch(url, { headers: { Range: `bytes=${total - tailLen}-${total - 1}` } })).arrayBuffer());
  let eocd = -1;
  for (let i = tail.length - 22; i >= 0; i--) {
    if (tail[i] === 0x50 && tail[i + 1] === 0x4b && tail[i + 2] === 0x05 && tail[i + 3] === 0x06) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('EOCD not found');
  const cdOff = u32(tail, eocd + 16);
  const cdSize = u32(tail, eocd + 12);
  const cd = new Uint8Array(await (await fetch(url, { headers: { Range: `bytes=${cdOff}-${cdOff + Math.min(cdSize, 65_000) - 1}` } })).arrayBuffer());
  if (!(cd[0] === 0x50 && cd[1] === 0x4b && cd[2] === 0x01 && cd[3] === 0x02)) throw new Error('CD sig mismatch');
  const method = u16(cd, 10);
  const compSize = u32(cd, 20);
  const uncompSize = u32(cd, 24);
  const lfhOff = u32(cd, 42);
  const lfh = new Uint8Array(await (await fetch(url, { headers: { Range: `bytes=${lfhOff}-${lfhOff + 29}` } })).arrayBuffer());
  const dataStart = lfhOff + 30 + u16(lfh, 26) + u16(lfh, 28);
  return { dataStart, compSize, uncompSize, method, lastModified };
}

async function run(runId: string, rowBudget: number) {
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { prepare: false, max: 1 });
  const started = Date.now();
  const dec = new TextDecoder('utf-8', { fatal: false });
  let lane: string | null = null;
  let ok = false, err: string | null = null, finished = false, versionReset = false, truncated = false;
  let rowsRun = 0, rowsPersisted = 0, upserted = 0, committed = 0, produced = 0;
  try {
    const claimed = await sql`select * from claim_efast_lane(${runId})`;
    if (claimed.length === 0) { ok = true; err = 'nothing_to_claim'; return; }
    const st = claimed[0] as Record<string, unknown>;
    lane = String(st.lane);
    const kind = laneKindOf(lane);
    const critical = CRITICAL_KEYS[kind];
    const url = String(st.url);
    const formYear = Number(st.form_year);
    let startCkpt = Number(st.checkpoint_bytes);
    let dataStart = st.entry_data_start == null ? null : Number(st.entry_data_start);
    let compSize = st.entry_comp_size == null ? null : Number(st.entry_comp_size);
    let uncompSize = st.entry_uncomp_size == null ? null : Number(st.entry_uncomp_size);
    let method = st.entry_method == null ? null : Number(st.entry_method);
    let headerMap = asObj<Record<string, number>>(st.header_map);
    const WANT = asObj<Record<string, string[]>>(st.want_map) ?? DEFAULT_WANT;
    const passNo = Number(st.pass_no);

    if (startCkpt > 0 && (!headerMap || critical.some((k) => headerMap![k] === undefined))) {
      startCkpt = 0; headerMap = null;
      await sql`update efast_load_state set checkpoint_bytes=0, header_map=null,
        last_error='pass reset: header map invalid on resume', updated_at=now() where lane=${lane}`;
    }

    const info = await inspectZip(url);
    if (startCkpt === 0 || dataStart == null || st.file_last_modified !== info.lastModified) {
      if (startCkpt > 0 && st.file_last_modified !== info.lastModified) {
        versionReset = true;
        startCkpt = 0; headerMap = null;
      }
      dataStart = info.dataStart; compSize = info.compSize; uncompSize = info.uncompSize; method = info.method;
      await sql`update efast_load_state set entry_data_start=${dataStart}, entry_comp_size=${compSize},
        entry_uncomp_size=${uncompSize}, entry_method=${method}, file_last_modified=${info.lastModified},
        checkpoint_bytes=${startCkpt}, header_map=null, updated_at=now() where lane=${lane}`;
    }
    committed = startCkpt;

    const resp = await fetch(url, { headers: { Range: `bytes=${dataStart}-${dataStart! + compSize! - 1}` } });
    if (!resp.ok || !resp.body) throw new Error('range fetch ' + resp.status);
    const reader = method === 0 ? resp.body.getReader() : resp.body.pipeThrough(new DecompressionStream('deflate-raw')).getReader();

    let carry = new Uint8Array(0);
    let carryStart = startCkpt;
    let batch: Record<string, unknown>[] = [];
    let flushes = 0;
    let headerPersisted = startCkpt > 0;
    const nowIso = new Date().toISOString();

    // v12: the main form is the ONLY authority for sponsor identity. If the row was
    // first created by a schedule lane, the main form's EIN overwrites it and takes
    // lane ownership. Otherwise the v8 null-enrichment rule is unchanged.
    const flushMain = async (payload: string) => {
      return await sql.unsafe(`
        insert into efast_5500_staging (ack_id, form_year, ein, plan_num, sponsor_name, sponsor_name_norm,
          plan_name, entity_type_cd, mail_city, mail_state, mail_zip, plan_year_begin, tax_period,
          date_received, last_rpt_spons_name, last_rpt_spons_ein, last_seen_at, last_seen_pass, lane,
          spons_signed_name, spons_signed_date, admin_signed_name, admin_signed_date, admin_name,
          spons_phone, admin_phone, sponsor_dba_name, tot_participants)
        select distinct on (r.ack_id)
          r.ack_id, r.form_year, nullif(r.ein,''), nullif(r.plan_num,''), nullif(r.sponsor_name,''),
          app.normalize_name(coalesce(r.sponsor_name,'')), nullif(r.plan_name,''), nullif(r.entity_type_cd,''),
          nullif(r.mail_city,''), nullif(r.mail_state,''), nullif(r.mail_zip,''),
          r.plan_year_begin::date, r.tax_period::date, r.date_received::date,
          nullif(r.last_rpt_spons_name,''), nullif(r.last_rpt_spons_ein,''),
          r.last_seen_at::timestamptz, r.last_seen_pass, r.lane,
          nullif(r.spons_signed_name,''), r.spons_signed_date::date,
          nullif(r.admin_signed_name,''), r.admin_signed_date::date, nullif(r.admin_name,''),
          nullif(r.spons_phone,''), nullif(r.admin_phone,''), nullif(r.sponsor_dba_name,''),
          case when r.tot_participants ~ '^\\d+$' then r.tot_participants::bigint end
        from jsonb_to_recordset(case when jsonb_typeof($1::jsonb)='string' then ($1::jsonb #>> '{}')::jsonb else $1::jsonb end) as r(
          ack_id text, form_year int, ein text, plan_num text, sponsor_name text, plan_name text,
          entity_type_cd text, mail_city text, mail_state text, mail_zip text, plan_year_begin text,
          tax_period text, date_received text, last_rpt_spons_name text, last_rpt_spons_ein text,
          last_seen_at text, last_seen_pass int, lane text,
          spons_signed_name text, spons_signed_date text, admin_signed_name text, admin_signed_date text,
          admin_name text, spons_phone text, admin_phone text, sponsor_dba_name text, tot_participants text)
        where r.ack_id is not null and r.ack_id <> ''
        order by r.ack_id, (nullif(r.ein,'') is null) asc
        on conflict (ack_id) do update set
          last_seen_at = excluded.last_seen_at,
          last_seen_pass = excluded.last_seen_pass,
          ein = case when left(efast_5500_staging.lane,4) in ('sch_','dcg_')
                     then coalesce(excluded.ein, efast_5500_staging.ein)
                     else coalesce(efast_5500_staging.ein, excluded.ein) end,
          plan_num = coalesce(efast_5500_staging.plan_num, excluded.plan_num),
          sponsor_name = coalesce(efast_5500_staging.sponsor_name, excluded.sponsor_name),
          sponsor_name_norm = coalesce(nullif(efast_5500_staging.sponsor_name_norm,''), excluded.sponsor_name_norm),
          plan_name = coalesce(efast_5500_staging.plan_name, excluded.plan_name),
          entity_type_cd = case when efast_5500_staging.lane like 'sch_mep%' then excluded.entity_type_cd
                                else coalesce(efast_5500_staging.entity_type_cd, excluded.entity_type_cd) end,
          mail_city = coalesce(efast_5500_staging.mail_city, excluded.mail_city),
          mail_state = coalesce(efast_5500_staging.mail_state, excluded.mail_state),
          mail_zip = coalesce(efast_5500_staging.mail_zip, excluded.mail_zip),
          plan_year_begin = coalesce(efast_5500_staging.plan_year_begin, excluded.plan_year_begin),
          tax_period = coalesce(efast_5500_staging.tax_period, excluded.tax_period),
          date_received = coalesce(efast_5500_staging.date_received, excluded.date_received),
          last_rpt_spons_name = coalesce(efast_5500_staging.last_rpt_spons_name, excluded.last_rpt_spons_name),
          last_rpt_spons_ein = coalesce(efast_5500_staging.last_rpt_spons_ein, excluded.last_rpt_spons_ein),
          spons_signed_name = coalesce(efast_5500_staging.spons_signed_name, excluded.spons_signed_name),
          spons_signed_date = coalesce(efast_5500_staging.spons_signed_date, excluded.spons_signed_date),
          admin_signed_name = coalesce(efast_5500_staging.admin_signed_name, excluded.admin_signed_name),
          admin_signed_date = coalesce(efast_5500_staging.admin_signed_date, excluded.admin_signed_date),
          admin_name = coalesce(efast_5500_staging.admin_name, excluded.admin_name),
          spons_phone = coalesce(efast_5500_staging.spons_phone, excluded.spons_phone),
          admin_phone = coalesce(efast_5500_staging.admin_phone, excluded.admin_phone),
          sponsor_dba_name = coalesce(efast_5500_staging.sponsor_dba_name, excluded.sponsor_dba_name),
          tot_participants = coalesce(efast_5500_staging.tot_participants, excluded.tot_participants),
          lane = case when (efast_5500_staging.ein is null
                            or left(efast_5500_staging.lane,4) in ('sch_','dcg_'))
                           and excluded.ein is not null
                      then excluded.lane else efast_5500_staging.lane end`,
        [payload]);
    };

    // v12: Schedule MEP header lane never writes `ein`. It owns mep_type_cd only.
    // A schedule is a supplement to a filing, not the identity of one.
    const flushMepHdr = async (payload: string) => {
      return await sql.unsafe(`
        insert into efast_5500_staging (ack_id, form_year, plan_num, mep_type_cd,
          plan_year_begin, tax_period, last_seen_at, last_seen_pass, lane)
        select distinct on (r.ack_id)
          r.ack_id, r.form_year, nullif(r.plan_num,''), nullif(r.mep_type_cd,''),
          r.plan_year_begin::date, r.tax_period::date, r.last_seen_at::timestamptz, r.last_seen_pass, r.lane
        from jsonb_to_recordset(case when jsonb_typeof($1::jsonb)='string' then ($1::jsonb #>> '{}')::jsonb else $1::jsonb end) as r(
          ack_id text, form_year int, plan_num text, mep_type_cd text,
          plan_year_begin text, tax_period text, last_seen_at text, last_seen_pass int, lane text)
        where r.ack_id is not null and r.ack_id <> ''
        order by r.ack_id
        on conflict (ack_id) do update set
          mep_type_cd = coalesce(excluded.mep_type_cd, efast_5500_staging.mep_type_cd),
          plan_num = coalesce(efast_5500_staging.plan_num, excluded.plan_num),
          plan_year_begin = coalesce(efast_5500_staging.plan_year_begin, excluded.plan_year_begin),
          tax_period = coalesce(efast_5500_staging.tax_period, excluded.tax_period),
          last_seen_at = excluded.last_seen_at,
          last_seen_pass = excluded.last_seen_pass`,
        [payload]);
    };

    // v11: Form 5500-SF header lane -> efast_5500_sf_staging. Column names verified
    // against DOL f_5500_sf_2024_latest_layout.txt. NULL-ENRICHMENT on conflict.
    const flushSF = async (payload: string) => {
      return await sql.unsafe(`
        insert into efast_5500_sf_staging (ack_id, form_year, ein, plan_num, sponsor_name, sponsor_name_norm,
          sponsor_dba_name, plan_name, plan_entity_cd, business_code, mail_city, mail_state, mail_zip,
          plan_year_begin, tax_period, date_received, tot_participants, tot_active_participants,
          welfare_codes, pension_codes, spons_signed_name, spons_signed_date, admin_signed_name,
          admin_signed_date, admin_name, spons_phone, admin_phone, last_rpt_spons_name, last_rpt_spons_ein,
          lane, last_seen_at, last_seen_pass)
        select distinct on (r.ack_id)
          r.ack_id, r.form_year, nullif(r.ein,''), nullif(r.plan_num,''), nullif(r.sponsor_name,''),
          app.normalize_name(coalesce(r.sponsor_name,'')), nullif(r.sponsor_dba_name,''), nullif(r.plan_name,''),
          nullif(r.plan_entity_cd,''), nullif(r.business_code,''), nullif(r.mail_city,''), nullif(r.mail_state,''),
          nullif(r.mail_zip,''), r.plan_year_begin::date, r.tax_period::date, r.date_received::date,
          case when r.tot_participants ~ '^\\d+$' then r.tot_participants::bigint end,
          case when r.tot_active_participants ~ '^\\d+$' then r.tot_active_participants::bigint end,
          nullif(r.welfare_codes,''), nullif(r.pension_codes,''),
          nullif(r.spons_signed_name,''), r.spons_signed_date::date,
          nullif(r.admin_signed_name,''), r.admin_signed_date::date, nullif(r.admin_name,''),
          nullif(r.spons_phone,''), nullif(r.admin_phone,''),
          nullif(r.last_rpt_spons_name,''), nullif(r.last_rpt_spons_ein,''),
          r.lane, r.last_seen_at::timestamptz, r.last_seen_pass
        from jsonb_to_recordset(case when jsonb_typeof($1::jsonb)='string' then ($1::jsonb #>> '{}')::jsonb else $1::jsonb end) as r(
          ack_id text, form_year int, ein text, plan_num text, sponsor_name text, sponsor_dba_name text,
          plan_name text, plan_entity_cd text, business_code text, mail_city text, mail_state text, mail_zip text,
          plan_year_begin text, tax_period text, date_received text, tot_participants text, tot_active_participants text,
          welfare_codes text, pension_codes text, spons_signed_name text, spons_signed_date text,
          admin_signed_name text, admin_signed_date text, admin_name text, spons_phone text, admin_phone text,
          last_rpt_spons_name text, last_rpt_spons_ein text, last_seen_at text, last_seen_pass int, lane text)
        where r.ack_id is not null and r.ack_id <> ''
        order by r.ack_id, (nullif(r.ein,'') is null) asc
        on conflict (ack_id) do update set
          last_seen_at = excluded.last_seen_at,
          last_seen_pass = excluded.last_seen_pass,
          ein = coalesce(efast_5500_sf_staging.ein, excluded.ein),
          plan_num = coalesce(efast_5500_sf_staging.plan_num, excluded.plan_num),
          sponsor_name = coalesce(efast_5500_sf_staging.sponsor_name, excluded.sponsor_name),
          sponsor_name_norm = coalesce(nullif(efast_5500_sf_staging.sponsor_name_norm,''), excluded.sponsor_name_norm),
          sponsor_dba_name = coalesce(efast_5500_sf_staging.sponsor_dba_name, excluded.sponsor_dba_name),
          plan_name = coalesce(efast_5500_sf_staging.plan_name, excluded.plan_name),
          plan_entity_cd = coalesce(efast_5500_sf_staging.plan_entity_cd, excluded.plan_entity_cd),
          business_code = coalesce(efast_5500_sf_staging.business_code, excluded.business_code),
          mail_city = coalesce(efast_5500_sf_staging.mail_city, excluded.mail_city),
          mail_state = coalesce(efast_5500_sf_staging.mail_state, excluded.mail_state),
          mail_zip = coalesce(efast_5500_sf_staging.mail_zip, excluded.mail_zip),
          plan_year_begin = coalesce(efast_5500_sf_staging.plan_year_begin, excluded.plan_year_begin),
          tax_period = coalesce(efast_5500_sf_staging.tax_period, excluded.tax_period),
          date_received = coalesce(efast_5500_sf_staging.date_received, excluded.date_received),
          tot_participants = coalesce(efast_5500_sf_staging.tot_participants, excluded.tot_participants),
          tot_active_participants = coalesce(efast_5500_sf_staging.tot_active_participants, excluded.tot_active_participants),
          welfare_codes = coalesce(efast_5500_sf_staging.welfare_codes, excluded.welfare_codes),
          pension_codes = coalesce(efast_5500_sf_staging.pension_codes, excluded.pension_codes),
          spons_signed_name = coalesce(efast_5500_sf_staging.spons_signed_name, excluded.spons_signed_name),
          spons_signed_date = coalesce(efast_5500_sf_staging.spons_signed_date, excluded.spons_signed_date),
          admin_signed_name = coalesce(efast_5500_sf_staging.admin_signed_name, excluded.admin_signed_name),
          admin_signed_date = coalesce(efast_5500_sf_staging.admin_signed_date, excluded.admin_signed_date),
          admin_name = coalesce(efast_5500_sf_staging.admin_name, excluded.admin_name),
          spons_phone = coalesce(efast_5500_sf_staging.spons_phone, excluded.spons_phone),
          admin_phone = coalesce(efast_5500_sf_staging.admin_phone, excluded.admin_phone),
          last_rpt_spons_name = coalesce(efast_5500_sf_staging.last_rpt_spons_name, excluded.last_rpt_spons_name),
          last_rpt_spons_ein = coalesce(efast_5500_sf_staging.last_rpt_spons_ein, excluded.last_rpt_spons_ein)`,
        [payload]);
    };

    const flushMepPart = async (payload: string) => {
      return await sql.unsafe(`
        insert into efast_mep_part_staging (ack_id, form_year, row_order, employer_name, employer_ein,
          contrib_pct, account_balance, lane, last_seen_at, last_seen_pass)
        select r.ack_id, r.form_year, nullif(r.row_order,'')::int, nullif(r.employer_name,''), nullif(r.employer_ein,''),
          nullif(r.contrib_pct,''), nullif(r.account_balance,''), r.lane, r.last_seen_at::timestamptz, r.last_seen_pass
        from jsonb_to_recordset(case when jsonb_typeof($1::jsonb)='string' then ($1::jsonb #>> '{}')::jsonb else $1::jsonb end) as r(
          ack_id text, form_year int, row_order text, employer_name text, employer_ein text,
          contrib_pct text, account_balance text, last_seen_at text, last_seen_pass int, lane text)
        where r.ack_id is not null and r.ack_id <> ''
        on conflict (ack_id, row_order) do update set last_seen_at=excluded.last_seen_at, last_seen_pass=excluded.last_seen_pass`,
        [payload]);
    };

    const flushSchA = async (payload: string) => {
      return await sql.unsafe(`
        insert into f5500_sch_a_staging (ack_id, form_year, row_order, carrier_name, carrier_ein, carrier_naic,
          persons_covered_eoy, policy_from, policy_to, benefit_lines, lane, loaded_at)
        select r.ack_id, r.form_year, nullif(r.row_order,'')::int, nullif(r.carrier_name,''), nullif(r.carrier_ein,''),
          nullif(r.carrier_naic,''), nullif(r.persons_covered,'')::int,
          r.policy_from::date, r.policy_to::date,
          jsonb_strip_nulls(jsonb_build_object(
            'health', case when r.b_health in ('1','X','Y','x','y') then true end,
            'dental', case when r.b_dental in ('1','X','Y','x','y') then true end,
            'vision', case when r.b_vision in ('1','X','Y','x','y') then true end,
            'life_insur', case when r.b_life in ('1','X','Y','x','y') then true end,
            'temp_disab', case when r.b_temp_disab in ('1','X','Y','x','y') then true end,
            'long_term_disab', case when r.b_ltd in ('1','X','Y','x','y') then true end,
            'hmo', case when r.b_hmo in ('1','X','Y','x','y') then true end,
            'ppo', case when r.b_ppo in ('1','X','Y','x','y') then true end,
            'indemnity', case when r.b_indemnity in ('1','X','Y','x','y') then true end,
            'other', case when r.b_other in ('1','X','Y','x','y') then true end,
            'other_text', nullif(r.b_other_text,'')
          )), r.lane, now()
        from jsonb_to_recordset(case when jsonb_typeof($1::jsonb)='string' then ($1::jsonb #>> '{}')::jsonb else $1::jsonb end) as r(
          ack_id text, form_year int, row_order text, carrier_name text, carrier_ein text, carrier_naic text,
          persons_covered text, policy_from text, policy_to text,
          b_health text, b_dental text, b_vision text, b_life text, b_temp_disab text, b_ltd text,
          b_hmo text, b_ppo text, b_indemnity text, b_other text, b_other_text text,
          last_seen_at text, last_seen_pass int, lane text)
        where r.ack_id is not null and r.ack_id <> ''
        on conflict (ack_id, row_order) where row_order is not null do update set loaded_at=now()`,
        [payload]);
    };

    const flush = async (upTo: number) => {
      if (batch.length > 0) {
        const submitted = batch.length;
        const payload = JSON.stringify(batch);
        const res = kind === 'main' ? await flushMain(payload)
          : kind === 'mep_part' ? await flushMepPart(payload)
          : kind === 'mep_hdr' ? await flushMepHdr(payload)
          : kind === 'sf' ? await flushSF(payload)
          : await flushSchA(payload);
        const wrote = Number(res?.count ?? 0);
        if (wrote === 0) {
          throw new Error(`zero-write: submitted ${submitted} rows, persisted 0 (extraction/attribution failure)`);
        }
        rowsPersisted += wrote;
        upserted += wrote;
        batch = [];
      }
      committed = upTo;
      flushes++;
      if (flushes % CHECKPOINT_EVERY_FLUSHES === 0) {
        await sql`update efast_load_state set checkpoint_bytes=${committed}, rows_loaded=rows_loaded+${upserted}, updated_at=now() where lane=${lane}`;
        upserted = 0;
      }
    };

    const handleRow = (line: string, isFirst: boolean) => {
      const fields = parseCsvLine(line);
      if (isFirst && headerMap == null) {
        const idx: Record<string, number> = {};
        const up = fields.map((f) => f.trim().toUpperCase());
        for (const [k, names] of Object.entries(WANT)) {
          for (const n of names) { const i = up.indexOf(n); if (i >= 0) { idx[k] = i; break; } }
        }
        if (critical.some((k) => idx[k] === undefined)) {
          throw new Error('critical column missing (' + critical.join('+') + '): ' + JSON.stringify({ have: up.slice(0, 40) }));
        }
        headerMap = idx;
        return;
      }
      if (!headerMap || critical.some((k) => headerMap![k] === undefined)) throw new Error('no valid header map');
      const g = (k: string) => { const i = headerMap![k]; return i === undefined ? null : (fields[i] ?? null); };
      rowsRun++;
      if (kind === 'main') {
        batch.push({
          ack_id: g('ack_id'), form_year: formYear, ein: g('ein'), plan_num: g('plan_num'),
          sponsor_name: g('sponsor_name'), plan_name: g('plan_name'), entity_type_cd: g('entity_type_cd'),
          mail_city: g('mail_city'), mail_state: g('mail_state'), mail_zip: g('mail_zip'),
          plan_year_begin: dateOr(g('plan_year_begin')), tax_period: dateOr(g('tax_period')),
          date_received: dateOr(g('date_received')),
          last_rpt_spons_name: g('last_rpt_spons_name'), last_rpt_spons_ein: g('last_rpt_spons_ein'),
          spons_signed_name: g('spons_signed_name'), spons_signed_date: dateOr(g('spons_signed_date')),
          admin_signed_name: g('admin_signed_name'), admin_signed_date: dateOr(g('admin_signed_date')),
          admin_name: g('admin_name'), spons_phone: g('spons_phone'), admin_phone: g('admin_phone'),
          sponsor_dba_name: g('sponsor_dba_name'), tot_participants: g('tot_participants'),
          last_seen_at: nowIso, last_seen_pass: passNo, lane,
        });
      } else if (kind === 'mep_hdr') {
        batch.push({
          ack_id: g('ack_id'), form_year: formYear, plan_num: g('plan_num'),
          mep_type_cd: g('mep_type_cd'),
          plan_year_begin: dateOr(g('plan_year_begin')), tax_period: dateOr(g('tax_period')),
          last_seen_at: nowIso, last_seen_pass: passNo, lane,
        });
      } else if (kind === 'sf') {
        batch.push({
          ack_id: g('ack_id'), form_year: formYear, ein: g('ein'), plan_num: g('plan_num'),
          sponsor_name: g('sponsor_name'), sponsor_dba_name: g('sponsor_dba_name'), plan_name: g('plan_name'),
          plan_entity_cd: g('plan_entity_cd'), business_code: g('business_code'),
          mail_city: g('mail_city'), mail_state: g('mail_state'), mail_zip: g('mail_zip'),
          plan_year_begin: dateOr(g('plan_year_begin')), tax_period: dateOr(g('tax_period')),
          date_received: dateOr(g('date_received')),
          tot_participants: g('tot_participants'), tot_active_participants: g('tot_active_participants'),
          welfare_codes: g('welfare_codes'), pension_codes: g('pension_codes'),
          spons_signed_name: g('spons_signed_name'), spons_signed_date: dateOr(g('spons_signed_date')),
          admin_signed_name: g('admin_signed_name'), admin_signed_date: dateOr(g('admin_signed_date')),
          admin_name: g('admin_name'), spons_phone: g('spons_phone'), admin_phone: g('admin_phone'),
          last_rpt_spons_name: g('last_rpt_spons_name'), last_rpt_spons_ein: g('last_rpt_spons_ein'),
          last_seen_at: nowIso, last_seen_pass: passNo, lane,
        });
      } else if (kind === 'mep_part') {
        batch.push({
          ack_id: g('ack_id'), form_year: formYear, row_order: g('row_order'),
          employer_name: g('employer_name'), employer_ein: g('employer_ein'),
          contrib_pct: g('contrib_pct'), account_balance: g('account_balance'),
          last_seen_at: nowIso, last_seen_pass: passNo, lane,
        });
      } else {
        batch.push({
          ack_id: g('ack_id'), form_year: formYear, row_order: g('row_order'),
          carrier_name: g('carrier_name'), carrier_ein: g('carrier_ein'), carrier_naic: g('carrier_naic'),
          persons_covered: g('persons_covered'), policy_from: dateOr(g('policy_from')), policy_to: dateOr(g('policy_to')),
          b_health: g('b_health'), b_dental: g('b_dental'), b_vision: g('b_vision'), b_life: g('b_life'),
          b_temp_disab: g('b_temp_disab'), b_ltd: g('b_ltd'), b_hmo: g('b_hmo'), b_ppo: g('b_ppo'),
          b_indemnity: g('b_indemnity'), b_other: g('b_other'), b_other_text: g('b_other_text'),
          last_seen_at: nowIso, last_seen_pass: passNo, lane,
        });
      }
    };

    let quoteOpen = false;
    let streamEnded = false;
    while (true) {
      const { done, value } = await reader.read();
      if (done) { streamEnded = true; break; }
      const chunkStart = produced;
      produced += value.length;
      if (produced <= startCkpt) continue;
      let piece = value;
      if (chunkStart < startCkpt) { piece = value.subarray(startCkpt - chunkStart); carryStart = startCkpt; }
      const merged = new Uint8Array(carry.length + piece.length);
      merged.set(carry, 0); merged.set(piece, carry.length);
      carry = merged;

      let scan = 0, lineStart = 0;
      while (scan < carry.length - 1) {
        const iq = carry.indexOf(QUOTE, scan);
        const ic = carry.indexOf(CR, scan);
        if (quoteOpen) {
          if (iq === -1) { scan = carry.length; break; }
          quoteOpen = false; scan = iq + 1; continue;
        }
        if (ic === -1 && iq === -1) { scan = carry.length; break; }
        if (iq !== -1 && (ic === -1 || iq < ic)) { quoteOpen = true; scan = iq + 1; continue; }
        if (ic >= carry.length - 1) break;
        if (carry[ic + 1] !== LF) { scan = ic + 1; continue; }
        const lineBytes = carry.subarray(lineStart, ic);
        const abs = carryStart + lineStart;
        if (lineBytes.length > 0) handleRow(dec.decode(lineBytes), abs === 0);
        lineStart = ic + 2; scan = ic + 2;
        if (batch.length >= FLUSH_ROWS) { await flush(carryStart + lineStart); }
      }
      if (lineStart > 0) { carryStart += lineStart; carry = carry.slice(lineStart); }

      if (!headerPersisted && headerMap) {
        await sql`update efast_load_state set header_map=${JSON.stringify(headerMap)}::jsonb, updated_at=now() where lane=${lane}`;
        headerPersisted = true;
      }
      if (rowsRun >= rowBudget || Date.now() - started > WALL_BUDGET_MS) break;
    }

    if (streamEnded && carry.length > 0 && !quoteOpen) {
      let end = carry.length;
      while (end > 0 && (carry[end - 1] === CR || carry[end - 1] === LF)) end--;
      if (end > 0) handleRow(dec.decode(carry.subarray(0, end)), carryStart === 0);
      carryStart += carry.length;
    }
    await flush(carryStart);
    reader.cancel().catch(() => {});

    finished = streamEnded;
    if (versionReset) finished = false;
    if (finished && uncompSize != null && produced !== uncompSize) {
      truncated = true;
      finished = false;
      err = `truncation: produced ${produced} != uncomp ${uncompSize}`;
    }
    if (finished) {
      await sql`update efast_load_state set checkpoint_bytes=0, rows_loaded=rows_loaded+${upserted},
        status='idle', claimed_at=null, pass_no=pass_no+1, last_pass_completed_at=now(),
        next_pass_due=now() + make_interval(days => ${PASS_INTERVAL_DAYS}), header_map=null, last_error=null, updated_at=now()
        where lane=${lane}`;
    } else if (truncated) {
      await sql`update efast_load_state set checkpoint_bytes=0, status='error', claimed_at=null,
        header_map=null, last_error=${err}, updated_at=now() where lane=${lane}`;
    } else {
      await sql`update efast_load_state set checkpoint_bytes=${versionReset ? 0 : committed},
        rows_loaded=rows_loaded+${upserted},
        status='pending', claimed_at=null, last_error=${versionReset ? 'version_reset: file replaced mid-pass' : null}, updated_at=now()
        where lane=${lane}`;
    }
    upserted = 0;
    ok = !truncated;
  } catch (e) {
    err = String(e).slice(0, 500);
    if (lane) {
      await sql`update efast_load_state set status=${err.includes('critical column') ? 'error' : 'pending'},
        claimed_at=null, last_error=${err}, updated_at=now() where lane=${lane}`.catch(() => {});
    }
  } finally {
    await sql`insert into jobs (name, run_id, started_at, finished_at, ok, detail)
      values ('efast_pump', ${runId}, ${new Date(started).toISOString()}, now(), ${ok},
        ${JSON.stringify({ lane, rows_run: rowsRun, rows_persisted: rowsPersisted, committed, produced, finished, version_reset: versionReset, truncated, error: err, elapsed_ms: Date.now() - started })}::jsonb)`
      .catch(() => {});
    await sql.end({ timeout: 5 }).catch(() => {});
  }
}

Deno.serve(async (req: Request) => {
  const { row_budget = DEFAULT_ROW_BUDGET } = await req.json().catch(() => ({}));
  const runId = crypto.randomUUID();
  EdgeRuntime.waitUntil(run(runId, Number(row_budget)));
  return new Response(JSON.stringify({ accepted: true, run_id: runId }), {
    status: 202, headers: { 'Content-Type': 'application/json' },
  });
});
