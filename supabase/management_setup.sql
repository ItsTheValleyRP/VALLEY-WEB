-- THE VALLEY management system
-- Run this entire file once in Supabase Dashboard -> SQL Editor.
-- The browser must NEVER receive a Supabase service-role/secret key.

begin;

create table if not exists public.valley_staff_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  rank text not null check (rank in (
    'Super Owner', 'Staff Owner', 'Director', 'Assistant Director',
    'Management', 'Senior Admin', 'Admin'
  )),
  assigned_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists valley_one_super_owner
  on public.valley_staff_roles ((rank))
  where rank = 'Super Owner';

create table if not exists public.valley_staff_audit (
  id bigint generated always as identity primary key,
  actor_user_id uuid references auth.users(id) on delete set null,
  target_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  old_rank text,
  new_rank text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.valley_announcements (
  id bigint generated always as identity primary key,
  title text not null check (char_length(trim(title)) between 3 and 120),
  body text not null check (char_length(trim(body)) between 3 and 12000),
  published boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.valley_staff_roles enable row level security;
alter table public.valley_staff_audit enable row level security;
alter table public.valley_announcements enable row level security;

-- No direct table access from the browser. All privileged access goes through
-- narrowly scoped functions below, which verify auth.uid() and the caller's rank.
revoke all on public.valley_staff_roles from anon, authenticated;
revoke all on public.valley_staff_audit from anon, authenticated;
revoke all on public.valley_announcements from anon, authenticated;

-- Bootstrap the one Super Owner using the Auth UID supplied by the site owner.
-- This account is hidden from every other staff member by the functions below.
insert into public.valley_staff_roles (user_id, rank)
values ('193a2e89-2bbb-496d-851d-1bb50aeb0b62'::uuid, 'Super Owner')
on conflict (user_id) do update
set rank = 'Super Owner', updated_at = now();

create or replace function public.valley_management_rank_level(p_rank text)
returns integer
language sql
immutable
as $$
  select case p_rank
    when 'Super Owner' then 100
    when 'Staff Owner' then 90
    when 'Director' then 80
    when 'Assistant Director' then 70
    when 'Management' then 60
    when 'Senior Admin' then 50
    when 'Admin' then 40
    else 0
  end;
$$;

create or replace function public.valley_management_overview()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_rank text;
  v_members jsonb := '[]'::jsonb;
  v_audit jsonb := '[]'::jsonb;
  v_announcements jsonb := '[]'::jsonb;
begin
  if v_uid is null then
    raise exception 'Authentication required';
  end if;

  select rank into v_rank
  from public.valley_staff_roles
  where user_id = v_uid;

  if v_rank is null then
    raise exception 'You do not have management access';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', r.user_id,
    'rank', r.rank,
    'display_name', coalesce(p.display_name, 'Discord member'),
    'character_name', coalesce(p.character_name, ''),
    'created_at', r.created_at
  ) order by public.valley_management_rank_level(r.rank) desc, p.display_name), '[]'::jsonb)
  into v_members
  from public.valley_staff_roles r
  left join public.profiles p on p.id = r.user_id
  where r.rank <> 'Super Owner';

  -- Admin is intentionally limited to announcements only.
  if v_rank <> 'Admin' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id,
      'actor_user_id', a.actor_user_id,
      'target_user_id', a.target_user_id,
      'action', a.action,
      'old_rank', a.old_rank,
      'new_rank', a.new_rank,
      'details', a.details,
      'created_at', a.created_at
    ) order by a.created_at desc), '[]'::jsonb)
    into v_audit
    from (
      select * from public.valley_staff_audit
      order by created_at desc
      limit 100
    ) a;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id,
    'title', a.title,
    'body', a.body,
    'published', a.published,
    'created_at', a.created_at,
    'updated_at', a.updated_at
  ) order by a.created_at desc), '[]'::jsonb)
  into v_announcements
  from public.valley_announcements a;

  return jsonb_build_object(
    'my_rank', v_rank,
    'members', case when v_rank = 'Admin' then '[]'::jsonb else v_members end,
    'audit_logs', v_audit,
    'announcements', v_announcements
  );
end;
$$;

create or replace function public.valley_management_set_rank(
  p_target_user_id uuid,
  p_new_rank text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_rank text;
  v_old_rank text;
  v_actor_level integer;
  v_new_level integer;
begin
  if v_actor is null then raise exception 'Authentication required'; end if;
  if p_target_user_id is null or p_target_user_id = v_actor then
    raise exception 'You cannot change your own staff rank';
  end if;
  if p_new_rank not in ('Staff Owner','Director','Assistant Director','Management','Senior Admin','Admin') then
    raise exception 'Invalid staff rank';
  end if;

  select rank into v_actor_rank
  from public.valley_staff_roles where user_id = v_actor;
  if v_actor_rank is null or v_actor_rank = 'Admin' or v_actor_rank = 'Senior Admin' then
    raise exception 'You do not have permission to change staff ranks';
  end if;

  select rank into v_old_rank
  from public.valley_staff_roles where user_id = p_target_user_id;

  -- Super Owner is never a valid target for staff management.
  if v_old_rank = 'Super Owner' then
    raise exception 'That account is protected';
  end if;

  v_actor_level := public.valley_management_rank_level(v_actor_rank);
  v_new_level := public.valley_management_rank_level(p_new_rank);

  if v_actor_rank = 'Staff Owner' then
    if v_new_level > 90 then raise exception 'Insufficient rank authority'; end if;
    if v_old_rank is not null and public.valley_management_rank_level(v_old_rank) > 90 then
      raise exception 'Insufficient rank authority';
    end if;
  else
    if v_new_level >= v_actor_level then raise exception 'You may only assign ranks below your own'; end if;
    if v_old_rank is not null and public.valley_management_rank_level(v_old_rank) >= v_actor_level then
      raise exception 'You may only manage staff below your own rank';
    end if;
  end if;

  insert into public.valley_staff_roles (user_id, rank, assigned_by)
  values (p_target_user_id, p_new_rank, v_actor)
  on conflict (user_id) do update
    set rank = excluded.rank, assigned_by = excluded.assigned_by, updated_at = now();

  insert into public.valley_staff_audit
    (actor_user_id, target_user_id, action, old_rank, new_rank)
  values (v_actor, p_target_user_id, case when v_old_rank is null then 'staff_added' else 'rank_changed' end, v_old_rank, p_new_rank);

  return true;
end;
$$;

create or replace function public.valley_management_remove_staff(p_target_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_rank text;
  v_old_rank text;
  v_actor_level integer;
begin
  if v_actor is null then raise exception 'Authentication required'; end if;
  if p_target_user_id is null or p_target_user_id = v_actor then
    raise exception 'You cannot remove your own staff position';
  end if;

  select rank into v_actor_rank from public.valley_staff_roles where user_id = v_actor;
  if v_actor_rank is null or v_actor_rank in ('Admin','Senior Admin') then
    raise exception 'You do not have permission to remove staff';
  end if;

  select rank into v_old_rank from public.valley_staff_roles where user_id = p_target_user_id;
  if v_old_rank is null then raise exception 'Staff member not found'; end if;
  if v_old_rank = 'Super Owner' then raise exception 'That account is protected'; end if;

  v_actor_level := public.valley_management_rank_level(v_actor_rank);
  if v_actor_rank = 'Staff Owner' then
    if public.valley_management_rank_level(v_old_rank) > 90 then raise exception 'Insufficient rank authority'; end if;
  else
    if public.valley_management_rank_level(v_old_rank) >= v_actor_level then
      raise exception 'You may only manage staff below your own rank';
    end if;
  end if;

  delete from public.valley_staff_roles where user_id = p_target_user_id;
  insert into public.valley_staff_audit
    (actor_user_id, target_user_id, action, old_rank, new_rank)
  values (v_actor, p_target_user_id, 'staff_removed', v_old_rank, null);

  return true;
end;
$$;

create or replace function public.valley_management_create_announcement(
  p_title text,
  p_body text,
  p_publish boolean default true
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_rank text;
  v_id bigint;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  select rank into v_rank from public.valley_staff_roles where user_id = v_uid;
  if v_rank is null then raise exception 'Staff access required'; end if;
  if char_length(trim(coalesce(p_title,''))) not between 3 and 120 then
    raise exception 'Title must be between 3 and 120 characters';
  end if;
  if char_length(trim(coalesce(p_body,''))) not between 3 and 12000 then
    raise exception 'Announcement must be between 3 and 12000 characters';
  end if;

  insert into public.valley_announcements (title, body, published, created_by)
  values (trim(p_title), trim(p_body), coalesce(p_publish,true), v_uid)
  returning id into v_id;

  insert into public.valley_staff_audit
    (actor_user_id, action, details)
  values (v_uid, 'announcement_created', jsonb_build_object('announcement_id',v_id,'published',coalesce(p_publish,true)));

  return v_id;
end;
$$;

create or replace function public.valley_public_announcements()
returns table (
  id bigint,
  title text,
  body text,
  created_at timestamptz
)
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select a.id, a.title, a.body, a.created_at
  from public.valley_announcements a
  where a.published = true
  order by a.created_at desc
  limit 50;
$$;

revoke all on function public.valley_management_rank_level(text) from public, anon, authenticated;
revoke all on function public.valley_management_overview() from public, anon;
revoke all on function public.valley_management_set_rank(uuid,text) from public, anon;
revoke all on function public.valley_management_remove_staff(uuid) from public, anon;
revoke all on function public.valley_management_create_announcement(text,text,boolean) from public, anon;
revoke all on function public.valley_public_announcements() from public;

grant execute on function public.valley_management_overview() to authenticated;
grant execute on function public.valley_management_set_rank(uuid,text) to authenticated;
grant execute on function public.valley_management_remove_staff(uuid) to authenticated;
grant execute on function public.valley_management_create_announcement(text,text,boolean) to authenticated;
grant execute on function public.valley_public_announcements() to anon, authenticated;

commit;

-- Permission summary:
-- Super Owner: hidden from all other accounts; can manage every rank below Super Owner.
-- Staff Owner: manages Staff Owner and every lower rank, but cannot view or alter Super Owner.
-- Director: manages Assistant Director and below.
-- Assistant Director: manages Management and below.
-- Management: manages Senior Admin and Admin.
-- Senior Admin: view staff records and audit logs; cannot change ranks.
-- Admin: announcements only; no staff records or audit logs.
