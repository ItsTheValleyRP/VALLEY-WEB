-- VALLEY announcement approval workflow
-- Run after management_setup.sql in Supabase SQL Editor.

begin;

alter table public.valley_announcements
  add column if not exists review_status text not null default 'pending';

alter table public.valley_announcements
  drop constraint if exists valley_announcements_review_status_check;
alter table public.valley_announcements
  add constraint valley_announcements_review_status_check
  check (review_status in ('pending','approved','rejected'));

-- Preserve existing public announcements as approved; un-published entries
-- become pending review so none can accidentally appear publicly.
update public.valley_announcements
set review_status = case when published then 'approved' else 'pending' end;

-- Replace the old immediate-publish function. All new submissions are pending.
drop function if exists public.valley_management_create_announcement(text,text,boolean);
create or replace function public.valley_management_create_announcement(
  p_title text,
  p_body text
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

  insert into public.valley_announcements(title,body,published,review_status,created_by)
  values(trim(p_title),trim(p_body),false,'pending',v_uid)
  returning id into v_id;

  insert into public.valley_staff_audit(actor_user_id,action,details)
  values(v_uid,'announcement_submitted',jsonb_build_object('announcement_id',v_id,'review_status','pending'));
  return v_id;
end;
$$;

create or replace function public.valley_management_review_announcement(
  p_announcement_id bigint,
  p_decision text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_rank text;
  v_old_status text;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  select rank into v_rank from public.valley_staff_roles where user_id = v_uid;
  if public.valley_management_rank_level(v_rank) < 70 then
    raise exception 'Only Assistant Director or higher can review announcements';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'Invalid review decision';
  end if;

  select review_status into v_old_status
  from public.valley_announcements
  where id = p_announcement_id
  for update;
  if not found then raise exception 'Announcement not found'; end if;
  if v_old_status <> 'pending' then raise exception 'This announcement has already been reviewed'; end if;

  update public.valley_announcements
  set review_status = p_decision,
      published = (p_decision = 'approved'),
      updated_at = now()
  where id = p_announcement_id;

  insert into public.valley_staff_audit(actor_user_id,action,details)
  values(v_uid,'announcement_'||p_decision,jsonb_build_object('announcement_id',p_announcement_id,'review_status',p_decision));
  return true;
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
  if v_uid is null then raise exception 'Authentication required'; end if;
  select rank into v_rank from public.valley_staff_roles where user_id = v_uid;
  if v_rank is null then raise exception 'You do not have management access'; end if;

  if v_rank <> 'Admin' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'user_id', r.user_id, 'rank', r.rank,
      'display_name', coalesce(p.display_name, 'Discord member'),
      'character_name', coalesce(p.character_name, ''),
      'created_at', r.created_at
    ) order by public.valley_management_rank_level(r.rank) desc, p.display_name), '[]'::jsonb)
    into v_members
    from public.valley_staff_roles r
    left join public.profiles p on p.id = r.user_id
    where r.rank <> 'Super Owner' or (r.user_id = v_uid and v_rank = 'Super Owner');
  end if;

  if v_rank <> 'Admin' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'actor_user_id', a.actor_user_id,
      'target_user_id', a.target_user_id, 'action', a.action,
      'old_rank', a.old_rank, 'new_rank', a.new_rank,
      'details', a.details, 'created_at', a.created_at
    ) order by a.created_at desc), '[]'::jsonb)
    into v_audit
    from (select * from public.valley_staff_audit order by created_at desc limit 100) a;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id, 'title', a.title, 'body', a.body,
    'published', a.published, 'review_status', a.review_status,
    'created_at', a.created_at, 'updated_at', a.updated_at
  ) order by a.created_at desc), '[]'::jsonb)
  into v_announcements
  from public.valley_announcements a;

  return jsonb_build_object(
    'my_rank', v_rank,
    'members', case when v_rank = 'Admin' then '[]'::jsonb else v_members end,
    'audit_logs', v_audit, 'announcements', v_announcements
  );
end;
$$;

revoke all on function public.valley_management_create_announcement(text,text) from public, anon;
revoke all on function public.valley_management_review_announcement(bigint,text) from public, anon;
grant execute on function public.valley_management_create_announcement(text,text) to authenticated;
grant execute on function public.valley_management_review_announcement(bigint,text) to authenticated;
grant execute on function public.valley_management_overview() to authenticated;

commit;
