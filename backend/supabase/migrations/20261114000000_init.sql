-- Lynx Reminders: schema, sync versions, row-level security and sharing RPCs.
-- Contract: docs/SPEC.md §2–§4. Every rule here has a check in backend/tests/rls.test.mjs.

-- ─────────────────────────────── tables ───────────────────────────────

create sequence public.sync_version;

create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  email        text not null unique,
  display_name text not null default '',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.lists (
  id          uuid primary key,
  owner_id    uuid not null references public.profiles (id) on delete cascade,
  name        text not null default '',
  color       text not null default 'ink',
  icon        text not null default 'list',
  sort_order  double precision not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  version     bigint not null default 0
);

create table public.list_members (
  list_id    uuid not null references public.lists (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  role       text not null default 'editor' check (role in ('owner', 'editor')),
  added_by   uuid, -- no FK: keeps `select=*,profile:profiles(*)` unambiguous
  created_at timestamptz not null default now(),
  version    bigint not null default 0,
  primary key (list_id, user_id)
);

create table public.reminders (
  id                  uuid primary key,
  list_id             uuid not null references public.lists (id) on delete cascade,
  parent_id           uuid references public.reminders (id) on delete cascade,
  created_by          uuid references public.profiles (id) on delete set null,
  assignee_id         uuid references public.profiles (id) on delete set null,
  title               text not null default '',
  notes               text,
  url                 text,
  priority            smallint not null default 0 check (priority between 0 and 3),
  flagged             boolean not null default false,
  completed_at        timestamptz,
  completed_by        uuid references public.profiles (id) on delete set null,
  due_at              timestamptz,
  all_day             boolean not null default false,
  time_zone           text not null default 'UTC',
  early_alert_minutes integer check (early_alert_minutes is null or early_alert_minutes >= 0),
  repeat              jsonb,
  nag                 jsonb,
  location            jsonb,
  bluetooth           jsonb,
  app_trigger         jsonb,
  sort_order          double precision not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  version             bigint not null default 0,
  check (parent_id is null or parent_id <> id)
);

create table public.reminder_shares (
  reminder_id uuid not null references public.reminders (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  added_by    uuid, -- no FK, see list_members
  created_at  timestamptz not null default now(),
  version     bigint not null default 0,
  primary key (reminder_id, user_id)
);

create table public.invites (
  id          uuid primary key default gen_random_uuid(),
  email       text not null,
  list_id     uuid references public.lists (id) on delete cascade,
  reminder_id uuid references public.reminders (id) on delete cascade,
  invited_by  uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  check ((list_id is null) <> (reminder_id is null))
);

create index on public.lists (version);
create index on public.reminders (version);
create index on public.reminders (list_id);
create index on public.reminders (parent_id);
create index on public.list_members (user_id);
create index on public.reminder_shares (user_id);
create index on public.invites (email);
create unique index invites_unique_list on public.invites (email, list_id) where list_id is not null;
create unique index invites_unique_reminder on public.invites (email, reminder_id) where reminder_id is not null;

-- ─────────────────────────────── access helpers ───────────────────────────────
-- SECURITY DEFINER so policies can look across tables without recursing into RLS.

create function public.is_list_member(p_list uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.list_members where list_id = p_list and user_id = auth.uid());
$$;

create function public.is_list_owner(p_list uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.lists where id = p_list and owner_id = auth.uid());
$$;

create function public.is_shared_with_me(p_reminder uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.reminder_shares where reminder_id = p_reminder and user_id = auth.uid());
$$;

create function public.reminder_visible(p_reminder uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.reminders r
    where r.id = p_reminder
      and (public.is_list_member(r.list_id)
           or public.is_shared_with_me(r.id)
           or (r.parent_id is not null and public.is_shared_with_me(r.parent_id))));
$$;

-- Profiles you may see: yourself, people in a list with you, people around a reminder shared with you,
-- and recipients of reminders you can see.
create function public.knows_profile(p uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p = auth.uid()
    or exists (select 1 from public.list_members a join public.list_members b using (list_id)
               where a.user_id = auth.uid() and b.user_id = p)
    or exists (select 1 from public.reminder_shares s
               where s.user_id = p and public.reminder_visible(s.reminder_id))
    or exists (select 1 from public.reminder_shares s
               join public.reminders r on r.id = s.reminder_id
               where s.user_id = auth.uid()
                 and (s.added_by = p or r.created_by = p or r.assignee_id = p
                      or exists (select 1 from public.list_members m where m.list_id = r.list_id and m.user_id = p)));
$$;

-- ─────────────────────────────── triggers ───────────────────────────────

-- Every write gets a new sync version. Rows with updated_at: an older write than the stored one is ignored
-- (last writer wins by the client's clock), and server-owned columns can't be changed by an upsert.
create function public.lists_before_write() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then new.owner_id := auth.uid(); end if;
  else
    if new.updated_at < old.updated_at then return null; end if;
    new.owner_id := old.owner_id;
    new.created_at := old.created_at;
    if new.deleted_at is distinct from old.deleted_at and auth.uid() is distinct from old.owner_id
       and auth.uid() is not null then
      raise exception 'Only the owner can delete or restore a list' using errcode = '42501';
    end if;
  end if;
  new.version := nextval('public.sync_version');
  return new;
end $$;

create function public.reminders_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  parent record;
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then new.created_by := auth.uid(); end if;
  else
    if new.updated_at < old.updated_at then return null; end if;
    new.created_by := old.created_by;
    new.created_at := old.created_at;
    -- Someone a single reminder was shared with can't pull it out of the owner's list.
    if new.list_id <> old.list_id and auth.uid() is not null and not public.is_list_member(old.list_id) then
      raise exception 'Only list members can move this reminder' using errcode = '42501';
    end if;
  end if;
  if new.parent_id is not null then
    select list_id, parent_id into parent from public.reminders where id = new.parent_id;
    if found then
      if parent.parent_id is not null then
        raise exception 'Subtasks cannot have subtasks' using errcode = '23514';
      end if;
      new.list_id := parent.list_id;
    end if;
  end if;
  new.version := nextval('public.sync_version');
  return new;
end $$;

create function public.bump_version() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.version := nextval('public.sync_version');
  return new;
end $$;

create trigger lists_before_write before insert or update on public.lists
  for each row execute function public.lists_before_write();
create trigger reminders_before_write before insert or update on public.reminders
  for each row execute function public.reminders_before_write();
create trigger list_members_version before insert or update on public.list_members
  for each row execute function public.bump_version();
create trigger reminder_shares_version before insert or update on public.reminder_shares
  for each row execute function public.bump_version();

-- The owner is always a member: one membership check covers every list rule.
create function public.lists_after_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.list_members (list_id, user_id, role, added_by)
  values (new.id, new.owner_id, 'owner', new.owner_id)
  on conflict (list_id, user_id) do update set role = 'owner';
  return null;
end $$;

create trigger lists_after_insert after insert on public.lists
  for each row execute function public.lists_after_insert();

-- Deleting a list or a goal deletes what's inside, so other devices see it go too.
create function public.cascade_soft_delete() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    if tg_table_name = 'lists' then
      update public.reminders set deleted_at = new.deleted_at, updated_at = greatest(updated_at, new.updated_at)
      where list_id = new.id and deleted_at is null;
    else
      update public.reminders set deleted_at = new.deleted_at, updated_at = greatest(updated_at, new.updated_at)
      where parent_id = new.id and deleted_at is null;
    end if;
  end if;
  return null;
end $$;

-- Moving a goal to another list takes its subtasks along.
create function public.move_subtasks() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.reminders set list_id = new.list_id, updated_at = greatest(updated_at, new.updated_at)
  where parent_id = new.id and list_id <> new.list_id;
  return null;
end $$;

create trigger reminders_move_subtasks after update of list_id on public.reminders
  for each row when (new.list_id is distinct from old.list_id and new.parent_id is null)
  execute function public.move_subtasks();

create trigger lists_cascade_soft_delete after update of deleted_at on public.lists
  for each row execute function public.cascade_soft_delete();
create trigger reminders_cascade_soft_delete after update of deleted_at on public.reminders
  for each row execute function public.cascade_soft_delete();

-- New account: a profile, and pending invites for that email become real shares.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  addr text := lower(coalesce(new.email, ''));
begin
  insert into public.profiles (id, email, display_name)
  values (new.id, addr, coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(addr, '@', 1)))
  on conflict (id) do nothing;

  insert into public.list_members (list_id, user_id, role, added_by)
  select i.list_id, new.id, 'editor', i.invited_by from public.invites i
  where i.email = addr and i.list_id is not null
  on conflict do nothing;

  insert into public.reminder_shares (reminder_id, user_id, added_by)
  select i.reminder_id, new.id, i.invited_by from public.invites i
  where i.email = addr and i.reminder_id is not null
  on conflict do nothing;

  delete from public.invites where email = addr;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create function public.handle_user_email_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.profiles set email = lower(new.email), updated_at = now() where id = new.id;
  return new;
end $$;

create trigger on_auth_user_email_changed after update of email on auth.users
  for each row when (new.email is distinct from old.email)
  execute function public.handle_user_email_change();

-- ─────────────────────────────── row-level security ───────────────────────────────

alter table public.profiles enable row level security;
alter table public.lists enable row level security;
alter table public.list_members enable row level security;
alter table public.reminders enable row level security;
alter table public.reminder_shares enable row level security;
alter table public.invites enable row level security;

create policy profiles_select on public.profiles for select to authenticated
  using (public.knows_profile(id));
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- owner_id = auth.uid() keeps a just-inserted list visible to RETURNING before its membership row exists.
create policy lists_select on public.lists for select to authenticated
  using (owner_id = auth.uid() or public.is_list_member(id));
create policy lists_insert on public.lists for insert to authenticated
  with check (owner_id = auth.uid());
create policy lists_update on public.lists for update to authenticated
  using (owner_id = auth.uid() or public.is_list_member(id))
  with check (owner_id = auth.uid() or public.is_list_member(id));

create policy list_members_select on public.list_members for select to authenticated
  using (user_id = auth.uid() or public.is_list_member(list_id));

create policy reminders_select on public.reminders for select to authenticated
  using (public.is_list_member(list_id) or public.is_shared_with_me(id)
         or (parent_id is not null and public.is_shared_with_me(parent_id)));
-- Upserts check the INSERT policy even when the row exists, so a shared reminder's own id must pass too.
-- A brand-new id can't be in reminder_shares (FK), so this opens nothing for real inserts.
create policy reminders_insert on public.reminders for insert to authenticated
  with check (public.is_list_member(list_id) or public.is_shared_with_me(id)
              or (parent_id is not null and public.is_shared_with_me(parent_id)));
create policy reminders_update on public.reminders for update to authenticated
  using (public.is_list_member(list_id) or public.is_shared_with_me(id)
         or (parent_id is not null and public.is_shared_with_me(parent_id)))
  with check (public.is_list_member(list_id) or public.is_shared_with_me(id)
              or (parent_id is not null and public.is_shared_with_me(parent_id)));

create policy reminder_shares_select on public.reminder_shares for select to authenticated
  using (user_id = auth.uid() or added_by = auth.uid() or public.reminder_visible(reminder_id));

create policy invites_select on public.invites for select to authenticated
  using (invited_by = auth.uid());

-- No DELETE policies: lists and reminders are soft-deleted, memberships go through the RPCs below.
revoke all on all tables in schema public from anon;
revoke insert, update, delete on public.list_members, public.reminder_shares, public.invites from authenticated;
revoke delete on public.lists, public.reminders, public.profiles from authenticated;
revoke insert on public.profiles from authenticated;

-- ─────────────────────────────── RPCs ───────────────────────────────

create function public.share_list(p_list uuid, p_email text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  addr text := lower(trim(p_email));
  target uuid;
begin
  if not public.is_list_owner(p_list) then
    raise exception 'Only the owner can share this list' using errcode = '42501';
  end if;
  if addr !~ '^[^@\s]+@[^@\s]+$' then
    raise exception 'Not an email address' using errcode = '22023';
  end if;
  select id into target from public.profiles where email = addr;
  if target is null then
    insert into public.invites (email, list_id, invited_by) values (addr, p_list, auth.uid())
    on conflict do nothing;
    return jsonb_build_object('status', 'invited', 'user_id', null);
  end if;
  if exists (select 1 from public.list_members where list_id = p_list and user_id = target) then
    return jsonb_build_object('status', 'already', 'user_id', target);
  end if;
  insert into public.list_members (list_id, user_id, role, added_by) values (p_list, target, 'editor', auth.uid());
  return jsonb_build_object('status', 'added', 'user_id', target);
end $$;

create function public.unshare_list(p_list uuid, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_list_owner(p_list) then
    raise exception 'Only the owner can remove people' using errcode = '42501';
  end if;
  delete from public.list_members where list_id = p_list and user_id = p_user and role <> 'owner';
end $$;

create function public.leave_list(p_list uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if public.is_list_owner(p_list) then
    raise exception 'The owner can''t leave; delete the list instead' using errcode = '42501';
  end if;
  delete from public.list_members where list_id = p_list and user_id = auth.uid();
end $$;

create function public.share_reminder(p_reminder uuid, p_email text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  addr text := lower(trim(p_email));
  target uuid;
  rem record;
begin
  if not public.reminder_visible(p_reminder) then
    raise exception 'Reminder not found' using errcode = '42501';
  end if;
  select list_id, parent_id into rem from public.reminders where id = p_reminder;
  if rem.parent_id is not null then
    raise exception 'Share the goal, not a subtask' using errcode = '22023';
  end if;
  if addr !~ '^[^@\s]+@[^@\s]+$' then
    raise exception 'Not an email address' using errcode = '22023';
  end if;
  select id into target from public.profiles where email = addr;
  if target is null then
    insert into public.invites (email, reminder_id, invited_by) values (addr, p_reminder, auth.uid())
    on conflict do nothing;
    return jsonb_build_object('status', 'invited', 'user_id', null);
  end if;
  if exists (select 1 from public.list_members where list_id = rem.list_id and user_id = target)
     or exists (select 1 from public.reminder_shares where reminder_id = p_reminder and user_id = target) then
    return jsonb_build_object('status', 'already', 'user_id', target);
  end if;
  insert into public.reminder_shares (reminder_id, user_id, added_by) values (p_reminder, target, auth.uid());
  return jsonb_build_object('status', 'added', 'user_id', target);
end $$;

create function public.unshare_reminder(p_reminder uuid, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  share record;
begin
  select s.added_by, r.list_id into share
  from public.reminder_shares s join public.reminders r on r.id = s.reminder_id
  where s.reminder_id = p_reminder and s.user_id = p_user;
  if not found then return; end if;
  if p_user <> auth.uid() and share.added_by is distinct from auth.uid() and not public.is_list_owner(share.list_id) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  delete from public.reminder_shares where reminder_id = p_reminder and user_id = p_user;
end $$;

create function public.cancel_invite(p_invite uuid) returns void
language sql security definer set search_path = '' as $$
  delete from public.invites where id = p_invite and invited_by = auth.uid();
$$;

-- Every row the caller can see (RLS applies: SECURITY INVOKER), deleted ones included.
create function public.sync_manifest() returns table (t text, id uuid, v bigint)
language sql stable security invoker set search_path = '' as $$
  select 'lists'::text, l.id, l.version from public.lists l
  union all
  select 'reminders'::text, r.id, r.version from public.reminders r;
$$;

create function public.delete_account() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  delete from auth.users where id = auth.uid();
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.share_list(uuid, text), public.unshare_list(uuid, uuid), public.leave_list(uuid),
  public.share_reminder(uuid, text), public.unshare_reminder(uuid, uuid), public.cancel_invite(uuid),
  public.sync_manifest(), public.delete_account(),
  public.is_list_member(uuid), public.is_list_owner(uuid), public.is_shared_with_me(uuid),
  public.reminder_visible(uuid), public.knows_profile(uuid)
to authenticated;

-- ─────────────────────────────── realtime + housekeeping ───────────────────────────────

alter publication supabase_realtime add table public.lists, public.reminders, public.list_members, public.reminder_shares;

-- Soft-deleted rows are kept 30 days so offline devices learn about the delete, then purged.
create function public.purge_deleted() returns void
language sql security definer set search_path = '' as $$
  delete from public.reminders where deleted_at < now() - interval '30 days';
  delete from public.lists where deleted_at < now() - interval '30 days';
$$;

do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('lynx-purge-deleted', '17 3 * * *', 'select public.purge_deleted()');
exception when others then
  raise notice 'pg_cron unavailable, schedule public.purge_deleted() elsewhere: %', sqlerrm;
end $$;
