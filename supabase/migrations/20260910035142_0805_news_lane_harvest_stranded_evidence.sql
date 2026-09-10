-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-10-news-lane-harvest (#171)
-- Articles implemented: PAID EVIDENCE IS NEVER STRANDED. 396 Serper news credits were spent in
--                       August; 2,061 articles landed in serper_evidence and nothing ever read them.
--                       Same defect class as the FL promotion gap - an archive with no promoter.
--                       Harvest costs ZERO new credits.
-- Articles verified not violated: sourcing never displayed on customer surfaces (serper_news_mentions
--                       is internal, no pub shelf column added); noncompete PEOs never worked - the
--                       harvest gate excludes them; client street addresses never displayed; a name
--                       match is a CANDIDATE, never a claim (brain_knowledge id 3) - every row is
--                       tagged with how it matched and by what rule.
-- Verification query attached: YES
--
-- WHAT WAS FOUND
--   396 news responses (2026-08-18 to 08-21), 306 carrying articles, 2,061 articles, 396 companies.
--   serper_news_mentions: 0 rows. No function in the database writes it - the parser was never built.
--   Plumbing mismatch: serper_news_mentions expects retrieval_id -> serper_retrievals, but the news
--   lane wrote to serper_evidence. Fixed with an explicit evidence_id column rather than a fake id.
--
--   Relevance is POOR by construction: the queries were bare company name + city with no recency or
--   relevance filter. Only 225 of 1,854 testable articles (12.1%) even name the company in the title.
--   Examples of the other 88%: "Chicago area storms spark warnings" for a company named Spark Program;
--   "Foreign Automakers Cut 300-Plus Jobs Across Georgia" for Coldwater International.
--   This harvest keeps ONLY the name-matched rows. The rest stay in the archive, unpromoted, on record.

alter table public.serper_news_mentions
  add column if not exists evidence_id bigint references public.serper_evidence(id),
  add column if not exists match_rule  text;

create unique index if not exists ux_serper_news_mentions_subject_url
  on public.serper_news_mentions (subject_id, url) where url is not null;

-- Serper returns either a relative date ("3 weeks ago") or an absolute one ("May 20, 2026").
create or replace function public.serper_news_date(p text, p_fetched timestamptz)
returns date language sql immutable as $fn$
  select case
    when p is null or btrim(p) = '' then null
    when btrim(p) ~* '^\d+\s+minute'  then p_fetched::date
    when btrim(p) ~* '^\d+\s+hour'    then p_fetched::date
    when btrim(p) ~* '^\d+\s+day'     then p_fetched::date - (substring(btrim(p) from '^(\d+)')::int)
    when btrim(p) ~* '^\d+\s+week'    then p_fetched::date - (substring(btrim(p) from '^(\d+)')::int * 7)
    when btrim(p) ~* '^\d+\s+month'   then p_fetched::date - (substring(btrim(p) from '^(\d+)')::int * 30)
    when btrim(p) ~* '^\d+\s+year'    then p_fetched::date - (substring(btrim(p) from '^(\d+)')::int * 365)
    when btrim(p) ~* '^[A-Z][a-z]{2} \d{1,2}, \d{4}$' then to_date(btrim(p), 'Mon FMDD, YYYY')
    else null
  end
$fn$;

-- Event classes are the PEO-relevant triggers: money in, ownership change, headcount move.
create or replace function public.news_event_class(p_title text)
returns text language sql immutable as $fn$
  select case
    when p_title ~* '\m(raises?|raised|funding|series [a-f]\M|seed round|investment|valuation)\M' then 'funding'
    when p_title ~* '\m(acquires?|acquired|acquisition|merges?|merger|buys?|bought|takeover)\M'   then 'acquisition'
    when p_title ~* '\m(layoffs?|lays? off|laid off|job cuts?|downsiz|furlough|closing|shuts? down)\M' then 'contraction'
    when p_title ~* '\m(expands?|expansion|opens? new|new office|new headquarters|relocat|hiring|headcount|employees?)\M' then 'expansion'
    when p_title ~* '\m(names?|appoints?|hires?|promotes?|steps? down|resigns?)\M.*\m(ceo|cfo|coo|president|chief)\M' then 'leadership'
    when p_title ~* '\m(ceo|cfo|coo|president|chief)\M.*\m(names?|appoints?|hires?|steps? down|resigns?)\M' then 'leadership'
    when p_title ~* '\m(partners?|partnership|deal|contract|wins?|awarded)\M'                     then 'commercial'
    else 'other'
  end
$fn$;

-- THE HARVEST ---------------------------------------------------------------
-- Idempotent. Reads only what is already archived. Spends nothing.
create or replace function public.harvest_stranded_news(p_limit int default 5000)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare v_ins bigint; v_seen bigint; v_kept bigint;
begin
  with arts as (
    select e.id as evidence_id, e.company_id, e.fetched_at, e.query,
           upper(btrim(regexp_replace(e.query,
             '\s+(INC|LLC|CORPORATION|CORP|CO|LTD|COMPANY|LP|LLP|PLLC|PC|PA)\M.*$', '', 'i'))) as nm,
           art->>'title' as title, art->>'link' as url,
           art->>'source' as src, art->>'date' as dt
    from serper_evidence e,
         lateral jsonb_array_elements(coalesce(e.raw->'news','[]'::jsonb)) art
    where e.lane = 'news'
  ),
  kept as (
    select a.*
    from arts a
    join companies c on c.id = a.company_id
    where length(a.nm) >= 8
      and upper(a.title) like '%'||a.nm||'%'
      and a.url is not null
      and c.merged_into is null
      and not company_is_noncompete(c)          -- protected PEOs and their clients never worked
    limit p_limit
  )
  insert into serper_news_mentions
    (subject_type, subject_id, headline, url, source, published_at,
     event_class, graded_by, retrieved_at, evidence_id, match_rule)
  select 'company', k.company_id::text, left(k.title, 500), k.url, k.src,
         serper_news_date(k.dt, k.fetched_at),
         news_event_class(k.title),
         'harvest_stranded_news/0805',
         k.fetched_at, k.evidence_id,
         'company name (>=8 chars, entity suffix stripped) appears in headline'
  from kept k
  on conflict (subject_id, url) where url is not null do nothing;
  get diagnostics v_ins = row_count;

  select count(*) into v_seen
  from serper_evidence e, lateral jsonb_array_elements(coalesce(e.raw->'news','[]'::jsonb)) art
  where e.lane='news';
  select count(*) into v_kept from serper_news_mentions;

  return jsonb_build_object('articles_in_archive', v_seen, 'inserted_this_run', v_ins,
                            'mentions_total', v_kept, 'credits_spent', 0);
end $$;

revoke all on function public.harvest_stranded_news(int) from public, anon, authenticated;
grant execute on function public.harvest_stranded_news(int) to service_role;

-- VERIFICATION
-- select harvest_stranded_news();
-- select event_class, count(*) from serper_news_mentions group by 1 order by 2 desc;
-- select harvest_stranded_news();   -- second run must insert 0 (idempotent)