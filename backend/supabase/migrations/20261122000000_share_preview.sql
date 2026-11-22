-- What share_list / share_reminder would do for an address, without doing it: the share sheets check
-- the address while it's typed (SPEC §3). Same permission checks as the real calls, so it tells the
-- caller nothing that sharing wouldn't.
create function public.share_preview(p_email text, p_list uuid default null, p_reminder uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  addr text := lower(trim(p_email));
  target uuid;
  rem_list uuid;
begin
  if p_list is not null then
    if not public.is_list_owner(p_list) then
      raise exception 'Only the owner can share this list' using errcode = '42501';
    end if;
  elsif p_reminder is not null then
    if not public.reminder_visible(p_reminder) then
      raise exception 'Reminder not found' using errcode = '42501';
    end if;
    select list_id into rem_list from public.reminders where id = p_reminder;
  else
    raise exception 'Pass a list or a reminder' using errcode = '22023';
  end if;
  if addr !~ '^[^@\s]+@[^@\s]+$' then
    return jsonb_build_object('status', 'invalid', 'user_id', null);
  end if;
  target := public.confirmed_user_id(addr);
  if target is null then
    return jsonb_build_object('status', 'invited', 'user_id', null);
  end if;
  if (p_list is not null and exists (select 1 from public.list_members where list_id = p_list and user_id = target))
     or (p_reminder is not null and (
          exists (select 1 from public.list_members where list_id = rem_list and user_id = target)
          or exists (select 1 from public.reminder_shares where reminder_id = p_reminder and user_id = target))) then
    return jsonb_build_object('status', 'already', 'user_id', target);
  end if;
  return jsonb_build_object('status', 'added', 'user_id', target);
end $$;

revoke execute on function public.share_preview(text, uuid, uuid) from public, anon;
grant execute on function public.share_preview(text, uuid, uuid) to authenticated;
