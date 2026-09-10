-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-10-news-lane-harvest (#171)
-- Articles implemented: a classifier writes the vocabulary the table already declares - it does not
--                       invent its own. serper_news_mentions_event_class_check permits exactly
--                       acquisition, funding, layoff, expansion, legal, leadership, other.
-- Articles verified not violated: sourcing never displayed; noncompete PEOs never worked; a name
--                       match stays a candidate, never a claim.
-- Verification query attached: YES
--
-- 0805 invented 'contraction' and 'commercial'. The check constraint refused them on the first row -
-- correctly. Mapped onto the declared vocabulary instead of widening the constraint: 'contraction'
-- is 'layoff', and a partnership or contract win is 'other' until someone rules it deserves a class.
-- Added the 'legal' branch the vocabulary already had and the classifier was missing.

create or replace function public.news_event_class(p_title text)
returns text language sql immutable as $fn$
  select case
    when p_title ~* '\m(raises?|raised|funding|series [a-f]\M|seed round|investment|valuation)\M' then 'funding'
    when p_title ~* '\m(acquires?|acquired|acquisition|merges?|merger|buys?|bought|takeover)\M'   then 'acquisition'
    when p_title ~* '\m(layoffs?|lays? off|laid off|job cuts?|downsiz|furlough|shuts? down)\M'    then 'layoff'
    when p_title ~* '\m(lawsuits?|sued|sues|settlement|probe|investigation|indict|fraud|violation|fined?|penalt)\M' then 'legal'
    when p_title ~* '\m(expands?|expansion|opens? new|new office|new headquarters|relocat|hiring|headcount|employees?)\M' then 'expansion'
    when p_title ~* '\m(names?|appoints?|hires?|promotes?|steps? down|resigns?)\M.*\m(ceo|cfo|coo|president|chief)\M' then 'leadership'
    when p_title ~* '\m(ceo|cfo|coo|president|chief)\M.*\m(names?|appoints?|hires?|steps? down|resigns?)\M' then 'leadership'
    else 'other'
  end
$fn$;

-- VERIFICATION
-- select harvest_stranded_news();
-- select distinct event_class from serper_news_mentions;   -- must be a subset of the declared list