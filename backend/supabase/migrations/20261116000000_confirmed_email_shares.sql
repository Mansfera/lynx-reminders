-- Shares bind to an email address only after its owner has proven it.
-- Before: signing up with someone else's address (unconfirmed) claimed their pending invites, and
-- share_list/share_reminder added unconfirmed accounts directly. Now both wait for confirmation.

create function public.claim_invites(p_user uuid, p_email text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  addr text := lower(coalesce(p_email, ''));
begin
  insert into public.list_members (list_id, user_id, role, added_by)
  select i.list_id, p_user, 'editor', i.invited_by from public.invites i
  where i.email = addr and i.list_id is not null
  on conflict do nothing;

  insert into public.reminder_shares (reminder_id, user_id, added_by)
  select i.reminder_id, p_user, i.invited_by from public.invites i
  where i.email = addr and i.reminder_id is not null
  on conflict do nothing;

  delete from public.invites where email = addr;
end $$;

revoke execute on function public.claim_invites(uuid, text) from public, anon, authenticated;

-- New account: always a profile; invites only if the address is already confirmed
-- (auto-confirm setups, admin-created users).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  addr text := lower(coalesce(new.email, ''));
begin
  insert into public.profiles (id, email, display_name)
  values (new.id, addr, coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(addr, '@', 1)))
  on conflict (id) do nothing;
  if new.email_confirmed_at is not null then
    perform public.claim_invites(new.id, addr);
  end if;
  return new;
end $$;

-- Confirming the address (sign-up code, email code sign-in) claims what was waiting for it.
create function public.handle_user_confirmed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.claim_invites(new.id, new.email);
  return new;
end $$;

create trigger on_auth_user_confirmed after update of email_confirmed_at on auth.users
  for each row when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
  execute function public.handle_user_confirmed();

-- A confirmed account for this address, or null (→ an invite that waits for confirmation).
create function public.confirmed_user_id(p_email text) returns uuid
language sql stable security definer set search_path = '' as $$
  select p.id from public.profiles p join auth.users u on u.id = p.id
  where p.email = lower(trim(p_email)) and u.email_confirmed_at is not null;
$$;

revoke execute on function public.confirmed_user_id(text) from public, anon, authenticated;

create or replace function public.share_list(p_list uuid, p_email text) returns jsonb
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
  target := public.confirmed_user_id(addr);
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

create or replace function public.share_reminder(p_reminder uuid, p_email text) returns jsonb
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
  target := public.confirmed_user_id(addr);
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
