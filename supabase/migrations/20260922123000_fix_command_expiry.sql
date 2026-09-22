create or replace function public.pull_next_station_command(
    p_device_id text,
    p_device_key text
)
returns table (
    command_id uuid,
    command_type text,
    requested_value double precision,
    requested_at timestamptz,
    expires_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if not public.station_key_valid(p_device_id, p_device_key) then
        raise exception 'invalid station credentials';
    end if;

    update public.command_requests
    set status = 'expired', completed_at = now()
    where command_requests.device_id = p_device_id
      and command_requests.status = 'pending'
      and command_requests.expires_at <= now();

    return query
    with candidate as (
        select cr.id
        from public.command_requests cr
        where cr.device_id = p_device_id
          and cr.status = 'pending'
          and cr.expires_at > now()
        order by cr.requested_at
        for update skip locked
        limit 1
    )
    update public.command_requests cr
    set status = 'delivered', delivered_at = now()
    from candidate c
    where cr.id = c.id
    returning
        cr.id,
        cr.command_type,
        cr.requested_value,
        cr.requested_at,
        cr.expires_at;
end;
$$;

revoke all on function public.station_key_valid(text, text) from anon, authenticated;
revoke all on function public.has_station_read_access(text) from anon, authenticated;
revoke all on function public.has_station_command_access(text) from anon, authenticated;
revoke all on function public.is_station_manager(text) from anon, authenticated;
revoke all on function public.rls_auto_enable() from public, anon, authenticated;
