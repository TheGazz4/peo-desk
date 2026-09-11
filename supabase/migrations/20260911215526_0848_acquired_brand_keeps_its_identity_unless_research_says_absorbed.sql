-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0848-acquisition-outcome-law
-- Articles implemented: II.1 (EIN-first: one EIN = one company), II.2 (merge only on the strongest
--   evidence - EIN equality scores 1.00 in the platform's own schema), VIII.2 (research before
--   an identity is changed)
-- Articles verified not violated: III.1, "Vensure is never aggregated" (this migration REMOVES an
--   acquired brand's EIN from the Vensure profile, it never adds one), append-only (nothing deleted
--   from peo_families or peo_brand_hierarchy - rows are re-pointed)
-- Verification query attached: YES
--
-- ACQUISITION OUTCOME LAW. Gazz 2026-09-11, on Tandem HR:
--   "Tandem HR remains Tandem HR with a family affiliation to Vensure. UNLESS when we research it,
--    Vensure states it is rebranding Tandem to Vensure (uncommon for them but possible for other
--    similar acquisitions)."
--
-- An EIN transfer or acquisition has exactly two outcomes, and only research decides which:
--   brand_retained  - the acquired PEO keeps its own identity; the acquirer is its FAMILY
--                     affiliation (peo_brand_hierarchy child -> parent). DEFAULT until research.
--   absorbed        - research confirms the acquirer is folding the brand into its own name;
--                     the acquired profile is merged into the acquirer and its clients re-point.
--
-- AND: ONE EIN = ONE PROFILE. Nine EINs sat on two profiles each; each resolved with its reason.

alter table public.peo_ein_transfer_events
  add column if not exists resolution text not null default 'pending_research';
alter table public.peo_ein_transfer_events drop constraint if exists peo_ein_transfer_events_resolution_check;
alter table public.peo_ein_transfer_events add constraint peo_ein_transfer_events_resolution_check
  check (resolution in ('pending_research','brand_retained','absorbed','restructure_same_owner','not_a_peo','dismissed'));

set role peo_gatekeeper;

create or replace function public.profile_merge(p_from text, p_into text, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $m$
declare v_companies int; v_eins jsonb;
begin
  if p_from = p_into then return jsonb_build_object('skipped','same'); end if;
  if not exists (select 1 from public.peo_profiles where family_slug = p_into) then
    raise exception 'survivor profile % does not exist', p_into;
  end if;
  select coalesce(sponsor_eins,'[]'::jsonb) into v_eins from public.peo_profiles where family_slug = p_from;

  update public.peo_profiles p
     set sponsor_eins = (select jsonb_agg(distinct x) from (
           select jsonb_array_elements_text(coalesce(p.sponsor_eins,'[]'::jsonb)) x
           union select jsonb_array_elements_text(v_eins)) u),
         notes = coalesce(p.notes,'') || format(' [0848 merge: absorbed profile %s - %s]', p_from, p_reason),
         updated_at = now()
   where p.family_slug = p_into;

  -- aliases are re-pointed, never deleted (append-only)
  update public.peo_families set family_slug = p_into where family_slug = p_from;

  update public.companies set peo_family_slug = p_into where peo_family_slug = p_from;
  get diagnostics v_companies = row_count;
  update public.companies set peo_brand_slug = p_into where peo_brand_slug = p_from;

  -- hierarchy: re-point the child if the survivor has no row of its own; otherwise leave the old
  -- row pointing at the survivor's parent (child_slug is the PK, so it cannot be renamed onto a taken key)
  if not exists (select 1 from public.peo_brand_hierarchy where child_slug = p_into) then
    update public.peo_brand_hierarchy set child_slug = p_into where child_slug = p_from;
  end if;

  delete from public.peo_profiles where family_slug = p_from;

  insert into public.noncompete_door_log (table_name, reason, sample)
  values ('_profile_merge', 'profile merged (EIN equality)',
          jsonb_build_object('from', p_from, 'into', p_into, 'reason', p_reason, 'companies_repointed', v_companies));
  return jsonb_build_object('from', p_from, 'into', p_into, 'companies_repointed', v_companies);
end $m$;
revoke execute on function public.profile_merge(text,text,text) from public;

select public.profile_merge('alliedworkforceinc','alliedworkforce','same EIN 75-2133642; slug variant of the same company');
select public.profile_merge('thrivepartnersllc','thrivepartners','same EIN 84-4818583; slug variant');
select public.profile_merge('americanonesourceinc','americanonesource','same EIN 71-0934616; slug variant');
select public.profile_merge('tandemprofessionalemployerservicesinc','tandemhr','same EIN 36-3968652; Tandem Professional Employer Services Inc is Tandem HR''s legal entity');
select public.profile_merge('stafflink','stafflinkoutsourcinginc','same EIN 65-0233907; StaffLink is the brand, StaffLink Outsourcing Inc the entity; survivor carries 382 clients');
select public.profile_merge('professionalemployerresources','perhumanresources','same EIN 59-3450115; same company, two slugs; survivor carries 89 clients');
select public.profile_merge('execustaffhr','equityhr','same EIN 27-0037153; ExecuStaff HR became Equity HR in 2024 (Form 5500 sponsor name by EIN). Rebrand law 0843');
select public.profile_merge('businesssolutions','idilushr','same EIN 47-2545618; "Business Solutions" is a generic legal-name stub for Idilus HR (174 clients vs 2). Merged on EIN, flagged for a look.');

update public.peo_profiles set display_name = 'StaffLink' where family_slug = 'stafflinkoutsourcinginc';
update public.peo_profiles set display_name = 'Professional Employer Resources' where family_slug = 'perhumanresources';
update public.peo_profiles set display_name = 'Equity HR' where family_slug = 'equityhr';

-- THE VENSURE CASE: an acquired brand's EIN does not belong on the acquirer's profile
update public.peo_profiles
   set sponsor_eins = (select jsonb_agg(x) from jsonb_array_elements_text(sponsor_eins) x where x <> '383522117'),
       notes = coalesce(notes,'') || ' [0848: removed EIN 38-3522117 - AccessPoint LLC, an acquired brand that keeps its own identity under the never-aggregate law; the family affiliation lives in peo_brand_hierarchy, not in a shared EIN]',
       updated_at = now()
 where family_slug = 'vensure';
insert into public.peo_brand_hierarchy (child_slug, parent_slug)
select 'accesspoint','vensure' where not exists (select 1 from public.peo_brand_hierarchy where child_slug='accesspoint');
update public.peo_profiles set ownership_type = 'acquired',
       ownership_detail = 'Acquired by Vensure. Brand retained; family affiliation = vensure (0848).', updated_at = now()
 where family_slug = 'accesspoint' and ownership_type is null;

-- Tandem HR, the worked example
update public.peo_profiles
   set sponsor_eins = (select jsonb_agg(distinct x) from (
         select jsonb_array_elements_text(coalesce(sponsor_eins,'[]'::jsonb)) x union select '364231315') u),
       display_name = 'Tandem HR',
       ownership_type = 'acquired',
       ownership_detail = 'Acquired by Vensure. Brand retained: Tandem HR remains Tandem HR with a family affiliation to Vensure (peo_brand_hierarchy tandemhr -> vensure). 2024 Form 5500 line 4 shows the plan sponsor EIN moved from Tandem HR LLC (20-5628549) to Tandem Management LLC (36-4231315) - a restructure inside the same ownership, not a change of identity. Becomes "absorbed" only if research shows Vensure folding the Tandem brand into its own name, which is uncommon for Vensure. Gazz 2026-09-11.',
       updated_at = now()
 where family_slug = 'tandemhr';

update public.peo_ein_transfer_events
   set resolution = 'brand_retained', research_status = 'researched',
       finding = 'Restructure inside Vensure ownership: Tandem HR LLC (20-5628549) -> Tandem Management LLC (36-4231315); plan still named TANDEM HR, LLC 401(K) PLAN, 343 employers. Identity stays Tandem HR; family = Vensure. Reopen as absorbed only if Vensure is found to be retiring the Tandem brand. Ruled by Gazz 2026-09-11 as the worked example.',
       researched_by = 'gazz', researched_at = now()
 where new_ein = '364231315' and prior_ein = '205628549';

insert into public.sysaudit_registry
 (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'profile_ein_unique','mesh_law','II.1/II.2','fast','RED',
 'ONE EIN = ONE PEO PROFILE. A sponsor EIN on two profiles is either a duplicate profile (merge on EIN, the platform''s own 1.00 match) or an acquired brand''s EIN wrongly placed on the acquirer (a violation of the never-aggregate law). Either way it is a RED (0848).',
 'select e as ein, string_agg(p.family_slug, '' | '') as profiles, count(*)::bigint as n from public.peo_profiles p, jsonb_array_elements_text(coalesce(p.sponsor_eins,''[]''::jsonb)) e group by e having count(*) > 1',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''000000000''::text as ein, ''a | b''::text as profiles, 2::bigint as n')
on conflict (check_name) do nothing;

reset role;
select public.sysaudit_ratify('check','profile_ein_unique','gazz');

insert into public.brain_knowledge (scope, key, content) values
('doctrine','acquisition_outcome_law',
 'An EIN transfer or acquisition has exactly two outcomes and only research decides which. BRAND_RETAINED (the default until research): the acquired PEO keeps its own identity and profile; the acquirer is its FAMILY affiliation, recorded in peo_brand_hierarchy (child -> parent), never by putting the acquired EIN on the acquirer''s profile. ABSORBED (research-confirmed only): the acquirer is folding the brand into its own name; the acquired profile merges into the acquirer and its clients re-point. Worked example, Gazz 2026-09-11: Tandem HR remains Tandem HR with family = Vensure even though its plan sponsor EIN moved to Tandem Management LLC in 2024; absorbed only if Vensure were found retiring the Tandem brand - uncommon for Vensure, common for other acquirers. Corollary: ONE EIN = ONE PROFILE (check profile_ein_unique). Two profiles on one EIN are a duplicate (merge on EIN, 1.00) or an aggregation error (remove the EIN from the acquirer).');