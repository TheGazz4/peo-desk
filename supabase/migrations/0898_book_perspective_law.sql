{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0898-book-perspective-law (opened BEFORE apply)
-- Articles implemented: II.3, MESH CROSS-REFERENCE MANDATE (reference data exists to APPEND, not to be
--   counted), CANONICAL RESOLUTION, noncompete fence respected
-- Articles verified not violated: III.1, XIII.1, switch_detection_nightly hold
-- Verification query attached: YES
--
-- GAZZ: \"We need to be isolating the data we have that isn't believed to be using a PEO. For example we
-- have all of California. Only a small portion of those are PEO users that we would use for appending.
-- Same goes for TX and so on. Make sure we are keeping perspective on this and only using this non-PEO
-- data for purposes of appending PEO users.\"
--
-- WHERE WE ACTUALLY STAND, measured before building anything:
--   The bulk substrate is already physically separate and is NOT in the book. 9.4M CA SOS registry rows,
--   6.2M CA entity index, 10M TX WC fingerprints, 4.3M FL WC coverage rows all live in their own tables.
--   companies holds 250,303 live rows and 241,783 of them (96.6%) carry a PEO attribution.
--   Every book view (dash_peo_book_by_family, v_peo_book_analytics, dash_peo_kpis) groups by
--   peo_family_slug, so a row with no PEO cannot appear in a book count. Checked, not assumed.
--
-- SO THE SEPARATION IS REAL - BUT IT IS INFERRED, NOT DECLARED, AND NOTHING BOUNDS IT.
-- \"Is this a PEO user\" is answered today by \"is peo_family_slug null\", nowhere written down. That holds
-- while the book is 96.6% attributed. It stops holding the moment a promotion lane adds rows at scale -
-- and one already does exactly that on a nightly cron: the MEP spine promoter deliberately never writes
-- peo_family_slug, and added 21,076 rows in a single run. Nothing would have flagged the book quietly
-- becoming mostly reference records. This gives the distinction a name, a census and a ceiling.
--
-- AND IT CORRECTS ONE OF MY OWN CHECKS. I raised 1,262 companies reading \"current PEO user\" with no PEO
-- as a RED defect. Broken out by attribution_class, 315 of them are legitimate and by design:
--     noncompete_quarantined  250   real PEO users whose PEO is Helpside/A Plus/etc - the fence blanks the name ON PURPOSE
--     lcf_verified             47   verified off a state client registry
--     pep_participant           7   verified, PEP participants who are never promoted as PEO clients
--     fingerprint_verified      6   verified off a carrier fingerprint
--     insperity_corroborated    2 · peo_entity_suppressed 2 · verified_switcher 1
-- Only the 947 claimed_source rows are \"a source said they use a PEO and we cannot name which\" - which is
-- a legitimate prospect state, not corruption. My check called all 1,262 a defect. That is the cost of
-- writing a check from a count instead of from the classes underneath it.

create or replace function public.company_record_class(
  p_peo_family_slug text, p_peo_prior_family_slug text, p_peo_user_status text, p_attribution_class text)
returns text language sql immutable as $f$
  select case
    when p_peo_family_slug is not null then 'peo_user'
    when p_peo_user_status = 'current_peo_user'
         and p_attribution_class in ('noncompete_quarantined','lcf_verified','pep_participant',
                                     'fingerprint_verified','insperity_corroborated',
                                     'peo_entity_suppressed','verified_switcher')
      then 'peo_user_unnamed'
    when p_peo_user_status = 'current_peo_user' then 'peo_claimed_unverified'
    when p_peo_prior_family_slug is not null then 'former_peo_user'
    else 'reference'
  end;
$f$;
comment on function public.company_record_class(text,text,text,text) is
  'What a company row IS. peo_user = a named PEO. peo_user_unnamed = verifiably a PEO user whose PEO we deliberately do not name (the noncompete fence, a suppressed PEO entity, a PEP participant). peo_claimed_unverified = a source claimed a PEO and we cannot name it. former_peo_user = a prior leg only. reference = in the book only so it can be appended to or appended from - never a PEO user, never counted as the book, never a PEO prospect.';
revoke execute on function public.company_record_class(text,text,text,text) from public, anon;
grant execute on function public.company_record_class(text,text,text,text) to service_role, postgres, peo_gatekeeper, sysaudit_reader;

create table if not exists public.company_book_census (
  record_class text primary key,
  n bigint not null,
  pct numeric(5,2) not null,
  counts_as_book boolean not null,
  refreshed_at timestamptz not null default now()
);
comment on table public.company_book_census is
  'One row per record class in companies, refreshed hourly. The point is perspective: the book is what counts_as_book, and reference rows exist only to append. If a promotion lane ever floods companies with reference records, this is where it shows up and the ceiling check is what catches it.';
alter table public.company_book_census enable row level security;
drop policy if exists company_book_census_read on public.company_book_census;
create policy company_book_census_read on public.company_book_census for select to authenticated, service_role using (true);
grant select on public.company_book_census to service_role, peo_gatekeeper, sysaudit_reader;
grant insert, update, delete on public.company_book_census to peo_gatekeeper, service_role;

create or replace function public.refresh_company_book_census()
returns bigint language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v_total bigint;
begin
  select count(*) into v_total from companies where merged_into is null;
  if v_total = 0 then return 0; end if;

  insert into company_book_census (record_class, n, pct, counts_as_book, refreshed_at)
  select k.cls, k.n, round(100.0 * k.n / v_total, 2),
         k.cls in ('peo_user','peo_user_unnamed','former_peo_user'), now()
    from (
      select public.company_record_class(c.peo_family_slug, c.peo_prior_family_slug,
                                         c.peo_user_status, c.attribution_class) as cls,
             count(*)::bigint as n
        from companies c where c.merged_into is null group by 1
    ) k
  on conflict (record_class) do update
     set n = excluded.n, pct = excluded.pct,
         counts_as_book = excluded.counts_as_book, refreshed_at = now();

  delete from company_book_census cbc
   where not exists (select 1 from companies c where c.merged_into is null
                      and public.company_record_class(c.peo_family_slug, c.peo_prior_family_slug,
                                                      c.peo_user_status, c.attribution_class) = cbc.record_class);
  return v_total;
end $f$;
revoke execute on function public.refresh_company_book_census() from public, anon;
grant execute on function public.refresh_company_book_census() to service_role, postgres, peo_gatekeeper;

select public.refresh_company_book_census() as companies_censused;

-- The ceiling. Reference rows are welcome in the book - they are how an append finds its subject - but
-- the moment they are a large share of it, the book has stopped being a PEO book and somebody must rule.
insert into public.repair_floor (metric, floor_value, note)
select 'reference_share_pct_ceiling', 10,
       'Maximum share of live companies that may be record_class = reference before a human rules. Today it is well under this. Raise it only with a Gazz ruling, never to silence the check.'
on conflict (metric) do nothing;

set role peo_gatekeeper;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('book_is_still_a_peo_book', 'mesh_law', 'fast', 'II.3', 'RED',
 'companies is the PEO book, not a business directory. Rows with no PEO signal at all (record_class = reference) are there only so a PEO user can be appended to or appended from - the CA SOS registry (9.4M rows), TX WC (10M) and FL WC (4.3M) stay in their own substrate tables and must never be promoted into the book at scale. If the reference share crosses the declared ceiling in repair_floor, a promotion lane has flooded the book and somebody has to rule on it. The MEP spine promoter already writes PEO-less rows nightly and added 21,076 in one run.',
 'select c.record_class, c.n, c.pct, f.floor_value as ceiling_pct from public.company_book_census c join public.repair_floor f on f.metric = ''reference_share_pct_ceiling'' where c.record_class = ''reference'' and c.pct > f.floor_value',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''reference''::text as record_class, 999999::bigint as n, 99.99::numeric as pct, 10::bigint as ceiling_pct',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('book_census_fresh', 'mesh_law', 'fast', 'II.3', 'AMBER',
 'company_book_census is what the reference-share ceiling is measured against. If it stops refreshing, that RED check keeps passing on a stale picture. Refreshed hourly; stale past six hours.',
 'select max(c.refreshed_at)::text as newest from public.company_book_census c having max(c.refreshed_at) < now() - interval ''6 hours''',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as newest',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

-- MY OWN CHECK, CORRECTED. It called 1,262 rows a defect; 315 of them are correct by design.
update public.sysaudit_registry
   set check_sql = 'with obs as (select count(*)::bigint as n from public.companies c where c.merged_into is null and c.peo_family_slug is null and c.peo_user_status = ''current_peo_user'' and public.company_record_class(c.peo_family_slug, c.peo_prior_family_slug, c.peo_user_status, c.attribution_class) = ''peo_claimed_unverified'') select obs.n, f.floor_value from obs join public.repair_floor f on f.metric = ''peo_user_status_without_a_peo'' where obs.n > f.floor_value',
       description = 'A company reading \"current PEO user\" with no PEO named is only a defect when nothing verified it. The noncompete fence blanks the PEO name ON PURPOSE (250 rows), and lcf_verified, pep_participant, fingerprint_verified, insperity_corroborated, peo_entity_suppressed and verified_switcher are all verified PEO users we deliberately do not name (65 more). Those are record_class peo_user_unnamed and are correct. Only peo_claimed_unverified - a source claimed a PEO and we cannot name which - is counted here. The original version of this check called all 1,262 a defect, which was wrong: it was written from a count instead of from the classes underneath it.'
 where check_name = 'peo_user_status_without_a_peo';

insert into public.brain_knowledge (scope, key, content)
values ('mesh_law', 'book_perspective_law',
 'companies is the PEO BOOK, not a business directory. The bulk state substrate - CA SOS registry 9.4M rows, CA entity index 6.2M, TX WC fingerprints 10M, FL WC coverage 4.3M - lives in its own tables and exists for ONE purpose: to append onto PEO users (EIN, address, domain, footprint, carrier). It is never promoted into the book at scale, never counted as PEO users, never targeted as PEO prospects. company_record_class() names what each book row is: peo_user (a named PEO), peo_user_unnamed (verifiably a PEO user whose PEO we deliberately do not name - the noncompete fence, a suppressed PEO entity, a PEP participant), peo_claimed_unverified (a source claimed a PEO, we cannot name it), former_peo_user, and reference (present only to be appended). company_book_census counts them hourly and book_is_still_a_peo_book fails RED if the reference share crosses the ceiling in repair_floor. Every book view groups by peo_family_slug, so an unattributed row cannot inflate a book count - verified 2026-09-12.')
on conflict do nothing;

reset role;

select cron.schedule('company_book_census_refresh', '41 * * * *',
  $$select public.refresh_company_book_census()$$) as jobid;

-- VERIFICATION
select record_class, n, pct, counts_as_book from public.company_book_census order by n desc;"}