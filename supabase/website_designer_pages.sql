-- Enable the expanded VALLEY page designer (Guide, Rules and About).
-- Run this file in Supabase SQL Editor after the existing management setup.
create or replace function public.valley_management_save_website_settings(p_settings jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_rank text;
  v_existing jsonb;
  v_key text;
  v_value text;
  v_allowed text[] := array[
    'site_title','hero_eyebrow','hero_title_line1','hero_title_line2',
    'hero_description','hero_primary_text','hero_primary_url',
    'hero_secondary_text','footer_tagline',
    'theme_primary','theme_background','theme_text','pages'
  ];
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  select rank into v_rank from public.valley_staff_roles where user_id = v_uid;
  if public.valley_management_rank_level(v_rank) < 60 then
    raise exception 'Website editing is available to Management and higher only';
  end if;
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then
    raise exception 'Invalid website settings';
  end if;

  for v_key in select jsonb_object_keys(p_settings) loop
    if not (v_key = any(v_allowed)) then raise exception 'Unsupported website setting: %',v_key; end if;
    if v_key = 'pages' then
      if jsonb_typeof(p_settings->v_key) <> 'object' then raise exception 'Page content must be a JSON object'; end if;
      if octet_length((p_settings->v_key)::text) > 60000 then raise exception 'Page content is too large'; end if;
      if exists (
        select 1 from jsonb_object_keys(p_settings->v_key) as page_key
        where page_key not in ('guide','rules','about')
      ) then raise exception 'Unsupported page content section'; end if;
      continue;
    end if;
    if jsonb_typeof(p_settings->v_key) <> 'string' then raise exception 'Website settings must be text'; end if;
    v_value := p_settings->>v_key;
    if char_length(v_value) > 2000 then raise exception 'A website field is too long'; end if;
    if v_key in ('theme_primary','theme_background','theme_text')
       and v_value !~ '^#[0-9A-Fa-f]{6}$' then
      raise exception 'Theme colours must be six-digit hex values';
    end if;
    if v_key = 'hero_primary_url' and v_value !~ '^https?://' then
      raise exception 'Button links must start with http:// or https://';
    end if;
  end loop;

  select settings into v_existing from public.valley_website_settings where id='main' for update;
  if v_existing is null then v_existing := '{}'::jsonb; end if;
  insert into public.valley_website_settings(id,settings,updated_by,updated_at)
  values('main',v_existing || p_settings,v_uid,now())
  on conflict(id) do update
    set settings = public.valley_website_settings.settings || excluded.settings,
        updated_by = excluded.updated_by,
        updated_at = now()
  returning settings into v_existing;

  insert into public.valley_staff_audit(actor_user_id,action,details)
  values(v_uid,'website_settings_updated',jsonb_build_object(
    'fields',case when p_settings ? 'pages'
      then (select coalesce(jsonb_agg(k),'[]'::jsonb) from jsonb_object_keys(p_settings) k)
      else p_settings end
  ));

  return v_existing;
end;
$$;

revoke all on function public.valley_management_save_website_settings(jsonb) from public, anon;
grant execute on function public.valley_management_save_website_settings(jsonb) to authenticated;
