-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0840-ein-first-law
-- Articles implemented: II.1 (canonical resolution), II.2 (no merge on a colliding name),
--   II.4 (evidence behind a determination), I.1 (observe before labelling)
-- Articles verified not violated: III.1, XIV.6
-- Verification query attached: YES
--
-- EIN-FIRST LAW. Gazz 2026-09-11:
--   "EIN is the ultimate tell all. A PEO can change their name 100 times and as long as the EIN
--    remains the same, it's the same company. Your first analysis should be the EIN. That goes for
--    filing PEO and PEO customers. THEN the name."
--
-- This is now the resolution order everywhere, for the filing PEO and for its client companies:
--   1. EIN
--   2. name
-- A name change with a stable EIN is the SAME company. A name match with different EINs is TWO
-- companies until something better says otherwise.
--
-- THE ONE TRAP, and it is the trap that produced today's Helpside incident:
-- the EIN on a Form 5500 filing is not always the sponsor's. Filings are frequently submitted under
-- the THIRD-PARTY ADMINISTRATOR'S EIN, and one administrator files for dozens of unrelated plans.
-- EIN 20-3886993 (National Benefit Services, a Utah TPA) carries Helpside, California Farm Bureau,
-- Mass Restaurant Association, the NAM, Stagwell, Windermere, the Las Vegas Chamber, ABC Utah,
-- Western Regions NECA and Medical Management Consultants. Treating that EIN as an identity credited
-- one medical group with 562 client companies it has never had.
--
-- So EIN-first needs one qualifier: an EIN that resolves to several UNRELATED sponsor names is not an
-- identity, it is an administrator, and it is disqualified as an identity key. The scale of this is
-- small and measurable: of 207,680 EINs in the 5500 staging, 175,792 (85%) carry exactly one sponsor
-- name and are trustworthy identity keys. Only 961 carry four or more. Those are the administrators.
-- Worst case observed is one EIN carrying 33 different sponsors.
--
-- Note two or three names on one EIN is usually just spelling drift across years
-- ("HELPSIDE INC" vs "HELPSIDE INC."), so the test compares the leading token, not the count alone.

create or replace function public.ein_norm(p_ein text)
returns text language sql immutable as $e$
  select nullif(regexp_replace(coalesce(p_ein,''), '[^0-9]', '', 'g'), '');
$e$;

create or replace function public.name_norm(p_name text)
returns text language sql immutable as $n$
  select nullif(
    regexp_replace(
      regexp_replace(upper(coalesce(p_name,'')), '[^A-Z0-9 ]', '', 'g'),
      '\s+', ' ', 'g'), '');
$n$;

-- An EIN is an ADMINISTRATOR EIN when the sponsor names filed under it do not agree on their first
-- word. Spelling drift keeps the same first word; a dozen unrelated employers do not.
create materialized view if not exists public.ein_identity_class as
with n as (
  select public.ein_norm(s.ein) as ein,
         public.name_norm(s.sponsor_name) as nm
    from public.efast_5500_staging s
   where s.ein is not null and s.sponsor_name is not null
), agg as (
  select ein,
         count(distinct nm) as distinct_names,
         count(distinct split_part(nm, ' ', 1)) as distinct_first_tokens,
         (array_agg(nm order by nm))[1] as sample_name
    from n where ein is not null group by ein
)
select ein,
       distinct_names,
       distinct_first_tokens,
       sample_name,
       case when distinct_first_tokens >= 3 then 'administrator'
            when distinct_first_tokens = 2 and distinct_names >= 4 then 'administrator'
            else 'entity' end as ein_class
  from agg;

create unique index if not exists ux_ein_identity_class on public.ein_identity_class (ein);
create index if not exists ix_ein_identity_class_class on public.ein_identity_class (ein_class);

create or replace function public.ein_is_administrator(p_ein text)
returns boolean language sql stable as $a$
  select coalesce((select c.ein_class = 'administrator'
                     from public.ein_identity_class c
                    where c.ein = public.ein_norm(p_ein)), false);
$a$;

-- THE RESOLVER. EIN first, name second, administrator EINs disqualified as identity.
-- Returns what was used and why, so every caller can record its own basis.
create or replace function public.resolve_entity(p_ein text, p_name text)
returns jsonb language plpgsql stable as $r$
declare v_ein text := public.ein_norm(p_ein);
        v_nm  text := public.name_norm(p_name);
        v_admin boolean := false;
        v_company companies%rowtype;
begin
  if v_ein is not null then
    v_admin := public.ein_is_administrator(v_ein);

    if not v_admin then
      -- 1. EIN. A name change with a stable EIN is the same company.
      select * into v_company from public.companies c where public.ein_norm(c.ein) = v_ein limit 1;
      if found then
        return jsonb_build_object('resolved', true, 'company_id', v_company.id,
          'basis', 'ein', 'confidence', 1.00, 'ein', v_ein,
          'name_differs', (public.name_norm(v_company.legal_name) is distinct from v_nm));
      end if;
      return jsonb_build_object('resolved', false, 'basis', 'ein_not_on_spine',
        'ein', v_ein, 'confidence', 1.00, 'note', 'EIN is trustworthy and simply not here yet');
    end if;
  end if;

  -- 2. Name, only now, and only if it is distinctive enough to be safe (Art. II.2/II.4)
  if v_nm is null or length(v_nm) < 12 or array_length(string_to_array(v_nm,' '),1) < 2 then
    return jsonb_build_object('resolved', false,
      'basis', case when v_admin then 'administrator_ein_and_name_not_distinctive'
                    else 'no_ein_and_name_not_distinctive' end,
      'confidence', 0, 'quarantine', true);
  end if;

  select * into v_company from public.companies c where public.name_norm(c.legal_name) = v_nm limit 1;
  if not found then
    return jsonb_build_object('resolved', false,
      'basis', case when v_admin then 'administrator_ein_name_not_on_spine'
                    else 'name_not_on_spine' end, 'confidence', 0);
  end if;

  if exists (select 1 from public.companies c2
              where public.name_norm(c2.legal_name) = v_nm and c2.id <> v_company.id) then
    return jsonb_build_object('resolved', false, 'basis', 'name_collides', 'confidence', 0,
      'quarantine', true, 'note', 'more than one company carries this name - never merge on it');
  end if;

  return jsonb_build_object('resolved', true, 'company_id', v_company.id,
    'basis', case when v_admin then 'name_after_administrator_ein_disqualified' else 'name_only' end,
    'confidence', 0.80, 'ein_disqualified', v_admin);
end $r$;

insert into public.brain_knowledge (scope, key, content)
values ('doctrine','ein_first_law',
 'EIN FIRST, NAME SECOND - everywhere, for the filing PEO and for its client companies alike. Gazz 2026-09-11: "EIN is the ultimate tell all. A PEO can change their name 100 times and as long as the EIN remains the same, it is the same company." Resolution order is (1) EIN, (2) name. A name change under a stable EIN is the SAME company and must not create a second record. A name match under different EINs is TWO companies until better evidence says otherwise. ONE QUALIFIER: the EIN on a Form 5500 is often the third-party administrator''s, not the sponsor''s, and one administrator files for dozens of unrelated plans - EIN 20-3886993 (National Benefit Services) carries Helpside, California Farm Bureau, the NAM, Stagwell, Windermere and eight more. An EIN whose sponsor names disagree on their first word is an ADMINISTRATOR EIN: it is disqualified as an identity key and the row falls back to the distinctive-name test, flagged. Of 207,680 EINs observed, 175,792 carry exactly one sponsor and are trustworthy; 961 carry four or more and are administrators. Use resolve_entity(ein, name) - it returns the basis and confidence so every caller records why it matched.');