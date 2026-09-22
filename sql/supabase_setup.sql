-- TLM Rev F prototype schema
-- Data flow represented by this schema:
-- station -> telemetry/state/events -> Supabase
-- dashboard user -> command request -> Supabase
-- Supabase -> station polls request -> local Safety Guardian -> execute/block -> result back to Supabase
-- AI engine -> assessment linked to station/event -> Supabase
-- dashboard receives only data permitted by station_access + RLS

create extension if not exists pgcrypto;
set search_path = public, extensions;

-- -----------------------------------------------------------------------------
-- Ownership / course context
-- -----------------------------------------------------------------------------

create table if not exists public.organizations (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    created_at timestamptz not null default now()
);

create table if not exists public.courses (
    id uuid primary key default gen_random_uuid(),
    organization_id uuid references public.organizations(id) on delete cascade,
    name text not null,
    created_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Stations and access
-- -----------------------------------------------------------------------------

create table if not exists public.devices (
    device_id text primary key,
    organization_id uuid references public.organizations(id) on delete set null,
    course_id uuid references public.courses(id) on delete set null,
    display_name text not null,
    device_type text not null default 'UNO Q',
    enabled boolean not null default true,
    created_at timestamptz not null default now(),
    last_seen_at timestamptz
);

-- Credentials are deliberately separated from devices so browser users can never
-- select even a hash of a station secret.
create table if not exists public.device_credentials (
    device_id text primary key references public.devices(device_id) on delete cascade,
    secret_hash bytea not null,
    created_at timestamptz not null default now()
);

-- Migration helpers for the earlier prototype schema.
alter table public.devices add column if not exists organization_id uuid references public.organizations(id) on delete set null;
alter table public.devices add column if not exists course_id uuid references public.courses(id) on delete set null;
alter table public.devices add column if not exists display_name text;
alter table public.devices add column if not exists device_type text default 'UNO Q';
alter table public.devices add column if not exists enabled boolean not null default true;
alter table public.devices add column if not exists created_at timestamptz not null default now();
alter table public.devices add column if not exists last_seen_at timestamptz;

create table if not exists public.station_access (
    user_id uuid not null references auth.users(id) on delete cascade,
    device_id text not null references public.devices(device_id) on delete cascade,
    role text not null check (role in ('student', 'teacher', 'manager')),
    can_read boolean not null default true,
    can_command boolean not null default false,
    created_at timestamptz not null default now(),
    primary key (user_id, device_id)
);

-- -----------------------------------------------------------------------------
-- Telemetry and station state
-- -----------------------------------------------------------------------------

create table if not exists public.sensors (
    id bigint generated always as identity primary key,
    device_id text not null references public.devices(device_id) on delete cascade,
    name text not null,
    unit text,
    category text not null default 'telemetry',
    created_at timestamptz not null default now(),
    unique (device_id, name)
);

alter table public.sensors add column if not exists category text not null default 'telemetry';

create table if not exists public.sensor_readings (
    id bigint generated always as identity primary key,
    device_id text not null references public.devices(device_id) on delete cascade,
    sensor_id bigint not null references public.sensors(id) on delete cascade,
    value double precision not null,
    measured_at timestamptz not null,
    received_at timestamptz not null default now()
);

alter table public.sensor_readings add column if not exists device_id text references public.devices(device_id) on delete cascade;
alter table public.sensor_readings add column if not exists received_at timestamptz not null default now();

create index if not exists idx_sensor_readings_device_time
    on public.sensor_readings(device_id, measured_at desc);

create index if not exists idx_sensor_readings_sensor_time
    on public.sensor_readings(sensor_id, measured_at desc);

create table if not exists public.station_state (
    device_id text primary key references public.devices(device_id) on delete cascade,
    safety_ok boolean not null default true,
    vfd_state text not null default 'stopped',
    vfd_frequency_hz double precision,
    motor_running boolean not null default false,
    motor_speed_rpm double precision,
    fault_code text,
    updated_at timestamptz not null default now()
);

create table if not exists public.station_events (
    id bigint generated always as identity primary key,
    device_id text not null references public.devices(device_id) on delete cascade,
    event_type text not null,
    severity text not null check (severity in ('info', 'warning', 'fault')),
    message text not null,
    payload jsonb not null default '{}'::jsonb,
    happened_at timestamptz not null default now()
);

create index if not exists idx_station_events_device_time
    on public.station_events(device_id, happened_at desc);

-- -----------------------------------------------------------------------------
-- AI output. The AI engine is external; Supabase stores the documented result.
-- -----------------------------------------------------------------------------

create table if not exists public.ai_assessments (
    id uuid primary key default gen_random_uuid(),
    device_id text not null references public.devices(device_id) on delete cascade,
    event_id bigint references public.station_events(id) on delete set null,
    model_version text not null,
    diagnosis text,
    recommendation text,
    explanation text,
    created_at timestamptz not null default now()
);

create index if not exists idx_ai_assessments_device_time
    on public.ai_assessments(device_id, created_at desc);

-- -----------------------------------------------------------------------------
-- Cloud command requests and station execution results
-- -----------------------------------------------------------------------------

create table if not exists public.command_requests (
    id uuid primary key default gen_random_uuid(),
    device_id text not null references public.devices(device_id) on delete cascade,
    requested_by uuid not null default auth.uid() references auth.users(id) on delete restrict,
    command_type text not null check (
        command_type in ('start', 'stop', 'set_frequency', 'reset_fault')
    ),
    requested_value double precision,
    requested_at timestamptz not null default now(),
    expires_at timestamptz not null default (now() + interval '30 seconds'),
    status text not null default 'pending' check (
        status in ('pending', 'delivered', 'executed', 'blocked', 'expired')
    ),
    delivered_at timestamptz,
    completed_at timestamptz
);

create index if not exists idx_command_requests_device_status_time
    on public.command_requests(device_id, status, requested_at);

create table if not exists public.command_results (
    command_id uuid primary key references public.command_requests(id) on delete cascade,
    device_id text not null references public.devices(device_id) on delete cascade,
    outcome text not null check (outcome in ('executed', 'blocked')),
    reason text,
    result_payload jsonb not null default '{}'::jsonb,
    completed_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- RLS helper functions
-- -----------------------------------------------------------------------------

create or replace function public.has_station_read_access(p_device_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.station_access sa
        where sa.user_id = auth.uid()
          and sa.device_id = p_device_id
          and sa.can_read = true
    );
$$;

create or replace function public.has_station_command_access(p_device_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.station_access sa
        where sa.user_id = auth.uid()
          and sa.device_id = p_device_id
          and sa.can_command = true
    );
$$;

create or replace function public.is_station_manager(p_device_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.station_access sa
        where sa.user_id = auth.uid()
          and sa.device_id = p_device_id
          and sa.role = 'manager'
    );
$$;

revoke all on function public.has_station_read_access(text) from public;
revoke all on function public.has_station_command_access(text) from public;
revoke all on function public.is_station_manager(text) from public;
grant execute on function public.has_station_read_access(text) to authenticated;
grant execute on function public.has_station_command_access(text) to authenticated;
grant execute on function public.is_station_manager(text) to authenticated;

-- -----------------------------------------------------------------------------
-- RLS policies
-- -----------------------------------------------------------------------------

alter table public.devices enable row level security;
alter table public.device_credentials enable row level security;
alter table public.station_access enable row level security;
alter table public.sensors enable row level security;
alter table public.sensor_readings enable row level security;
alter table public.station_state enable row level security;
alter table public.station_events enable row level security;
alter table public.ai_assessments enable row level security;
alter table public.command_requests enable row level security;
alter table public.command_results enable row level security;

-- Remove permissive policies/functions from the earlier anonymous-read prototype.
drop policy if exists "prototype read devices" on public.devices;
drop policy if exists "prototype read sensors" on public.sensors;
drop policy if exists "prototype read readings" on public.sensor_readings;
drop function if exists public.ingest_sensor_batch(text, jsonb);

-- Replace policies idempotently.
drop policy if exists devices_read on public.devices;
create policy devices_read on public.devices
for select to authenticated
using (public.has_station_read_access(device_id));

drop policy if exists station_access_read on public.station_access;
create policy station_access_read on public.station_access
for select to authenticated
using (user_id = auth.uid() or public.is_station_manager(device_id));

drop policy if exists station_access_manager_insert on public.station_access;
create policy station_access_manager_insert on public.station_access
for insert to authenticated
with check (public.is_station_manager(device_id));

drop policy if exists station_access_manager_update on public.station_access;
create policy station_access_manager_update on public.station_access
for update to authenticated
using (public.is_station_manager(device_id))
with check (public.is_station_manager(device_id));

drop policy if exists station_access_manager_delete on public.station_access;
create policy station_access_manager_delete on public.station_access
for delete to authenticated
using (public.is_station_manager(device_id));

drop policy if exists sensors_read on public.sensors;
create policy sensors_read on public.sensors
for select to authenticated
using (public.has_station_read_access(device_id));

drop policy if exists sensor_readings_read on public.sensor_readings;
create policy sensor_readings_read on public.sensor_readings
for select to authenticated
using (public.has_station_read_access(device_id));

drop policy if exists station_state_read on public.station_state;
create policy station_state_read on public.station_state
for select to authenticated
using (public.has_station_read_access(device_id));

drop policy if exists station_events_read on public.station_events;
create policy station_events_read on public.station_events
for select to authenticated
using (public.has_station_read_access(device_id));

drop policy if exists ai_assessments_read on public.ai_assessments;
create policy ai_assessments_read on public.ai_assessments
for select to authenticated
using (public.has_station_read_access(device_id));

drop policy if exists command_requests_read on public.command_requests;
create policy command_requests_read on public.command_requests
for select to authenticated
using (public.has_station_read_access(device_id));

drop policy if exists command_requests_insert on public.command_requests;
create policy command_requests_insert on public.command_requests
for insert to authenticated
with check (
    requested_by = auth.uid()
    and public.has_station_command_access(device_id)
);

drop policy if exists command_results_read on public.command_results;
create policy command_results_read on public.command_results
for select to authenticated
using (public.has_station_read_access(device_id));

-- Browser privileges. No direct station telemetry writes are granted.
revoke all on table public.devices from anon, authenticated;
revoke all on table public.device_credentials from anon, authenticated;
revoke all on table public.station_access from anon, authenticated;
revoke all on table public.sensors from anon, authenticated;
revoke all on table public.sensor_readings from anon, authenticated;
revoke all on table public.station_state from anon, authenticated;
revoke all on table public.station_events from anon, authenticated;
revoke all on table public.ai_assessments from anon, authenticated;
revoke all on table public.command_requests from anon, authenticated;
revoke all on table public.command_results from anon, authenticated;

grant select on public.devices to authenticated;
grant select on public.station_access to authenticated;
grant select on public.sensors to authenticated;
grant select on public.sensor_readings to authenticated;
grant select on public.station_state to authenticated;
grant select on public.station_events to authenticated;
grant select on public.ai_assessments to authenticated;
grant select, insert on public.command_requests to authenticated;
grant select on public.command_results to authenticated;

-- -----------------------------------------------------------------------------
-- Device-authenticated station functions
-- -----------------------------------------------------------------------------

create or replace function public.station_key_valid(
    p_device_id text,
    p_device_key text
)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
    select exists (
        select 1
        from public.device_credentials dc
        join public.devices d on d.device_id = dc.device_id
        where dc.device_id = p_device_id
          and d.enabled = true
          and dc.secret_hash = digest(p_device_key, 'sha256')
    );
$$;

revoke all on function public.station_key_valid(text, text) from public;

create or replace function public.ingest_station_packet(
    p_device_id text,
    p_device_key text,
    p_measured_at timestamptz,
    p_telemetry jsonb,
    p_state jsonb
)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    item jsonb;
    sensor_name text;
    sensor_unit text;
    sensor_category text;
    sensor_value double precision;
    current_sensor_id bigint;
    inserted_count integer := 0;
    old_fault text;
    old_safety boolean;
    new_fault text;
    new_safety boolean;
    new_vfd_state text;
    new_frequency double precision;
    new_motor_running boolean;
    new_speed double precision;
begin
    if not public.station_key_valid(p_device_id, p_device_key) then
        raise exception 'invalid station credentials';
    end if;

    if p_measured_at is null then
        raise exception 'measured_at is required';
    end if;

    if jsonb_typeof(p_telemetry) <> 'array' then
        raise exception 'telemetry must be a JSON array';
    end if;

    select ss.fault_code, ss.safety_ok
    into old_fault, old_safety
    from public.station_state ss
    where ss.device_id = p_device_id;

    update public.devices
    set last_seen_at = now()
    where device_id = p_device_id;

    for item in
        select value from jsonb_array_elements(p_telemetry)
    loop
        sensor_name := nullif(btrim(item ->> 'name'), '');
        sensor_unit := item ->> 'unit';
        sensor_category := coalesce(nullif(btrim(item ->> 'category'), ''), 'telemetry');

        if sensor_name is null then
            raise exception 'sensor name is required';
        end if;

        sensor_value := (item ->> 'value')::double precision;

        insert into public.sensors (device_id, name, unit, category)
        values (p_device_id, sensor_name, sensor_unit, sensor_category)
        on conflict (device_id, name)
        do update set
            unit = excluded.unit,
            category = excluded.category
        returning id into current_sensor_id;

        insert into public.sensor_readings (
            device_id,
            sensor_id,
            value,
            measured_at
        )
        values (
            p_device_id,
            current_sensor_id,
            sensor_value,
            p_measured_at
        );

        inserted_count := inserted_count + 1;
    end loop;

    new_safety := coalesce((p_state ->> 'safety_ok')::boolean, true);
    new_vfd_state := coalesce(nullif(p_state ->> 'vfd_state', ''), 'unknown');
    new_frequency := nullif(p_state ->> 'vfd_frequency_hz', '')::double precision;
    new_motor_running := coalesce((p_state ->> 'motor_running')::boolean, false);
    new_speed := nullif(p_state ->> 'motor_speed_rpm', '')::double precision;
    new_fault := nullif(btrim(p_state ->> 'fault_code'), '');

    insert into public.station_state (
        device_id,
        safety_ok,
        vfd_state,
        vfd_frequency_hz,
        motor_running,
        motor_speed_rpm,
        fault_code,
        updated_at
    )
    values (
        p_device_id,
        new_safety,
        new_vfd_state,
        new_frequency,
        new_motor_running,
        new_speed,
        new_fault,
        p_measured_at
    )
    on conflict (device_id)
    do update set
        safety_ok = excluded.safety_ok,
        vfd_state = excluded.vfd_state,
        vfd_frequency_hz = excluded.vfd_frequency_hz,
        motor_running = excluded.motor_running,
        motor_speed_rpm = excluded.motor_speed_rpm,
        fault_code = excluded.fault_code,
        updated_at = excluded.updated_at;

    if old_safety is distinct from new_safety then
        insert into public.station_events (
            device_id, event_type, severity, message, payload, happened_at
        )
        values (
            p_device_id,
            'safety_state',
            case when new_safety then 'info' else 'fault' end,
            case when new_safety then 'Safety chain restored' else 'Safety chain blocked operation' end,
            jsonb_build_object('safety_ok', new_safety),
            p_measured_at
        );
    end if;

    if old_fault is distinct from new_fault then
        insert into public.station_events (
            device_id, event_type, severity, message, payload, happened_at
        )
        values (
            p_device_id,
            'vfd_fault',
            case when new_fault is null then 'info' else 'fault' end,
            case when new_fault is null then 'VFD fault cleared' else 'VFD fault: ' || new_fault end,
            jsonb_build_object('fault_code', new_fault),
            p_measured_at
        );
    end if;

    return inserted_count;
end;
$$;

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
    where device_id = p_device_id
      and status = 'pending'
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

create or replace function public.complete_station_command(
    p_device_id text,
    p_device_key text,
    p_command_id uuid,
    p_outcome text,
    p_reason text default null,
    p_result_payload jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    command_name text;
begin
    if not public.station_key_valid(p_device_id, p_device_key) then
        raise exception 'invalid station credentials';
    end if;

    if p_outcome not in ('executed', 'blocked') then
        raise exception 'outcome must be executed or blocked';
    end if;

    select cr.command_type
    into command_name
    from public.command_requests cr
    where cr.id = p_command_id
      and cr.device_id = p_device_id
      and cr.status in ('pending', 'delivered');

    if command_name is null then
        raise exception 'command not found or already completed';
    end if;

    update public.command_requests
    set status = p_outcome,
        completed_at = now()
    where id = p_command_id;

    insert into public.command_results (
        command_id, device_id, outcome, reason, result_payload, completed_at
    )
    values (
        p_command_id, p_device_id, p_outcome, p_reason, p_result_payload, now()
    )
    on conflict (command_id)
    do update set
        outcome = excluded.outcome,
        reason = excluded.reason,
        result_payload = excluded.result_payload,
        completed_at = excluded.completed_at;

    insert into public.station_events (
        device_id,
        event_type,
        severity,
        message,
        payload,
        happened_at
    )
    values (
        p_device_id,
        'command_result',
        case when p_outcome = 'executed' then 'info' else 'warning' end,
        command_name || ': ' || p_outcome || coalesce(' (' || p_reason || ')', ''),
        jsonb_build_object(
            'command_id', p_command_id,
            'command_type', command_name,
            'outcome', p_outcome,
            'reason', p_reason
        ) || coalesce(p_result_payload, '{}'::jsonb),
        now()
    );
end;
$$;

revoke all on function public.ingest_station_packet(text, text, timestamptz, jsonb, jsonb) from public;
revoke all on function public.pull_next_station_command(text, text) from public;
revoke all on function public.complete_station_command(text, text, uuid, text, text, jsonb) from public;
revoke all on function public.station_key_valid(text, text) from anon, authenticated;
revoke all on function public.has_station_read_access(text) from anon, authenticated;
revoke all on function public.has_station_command_access(text) from anon, authenticated;
revoke all on function public.is_station_manager(text) from anon, authenticated;
revoke all on function public.rls_auto_enable() from public, anon, authenticated;

grant execute on function public.ingest_station_packet(text, text, timestamptz, jsonb, jsonb) to anon, authenticated;
grant execute on function public.pull_next_station_command(text, text) to anon, authenticated;
grant execute on function public.complete_station_command(text, text, uuid, text, text, jsonb) to anon, authenticated;

-- -----------------------------------------------------------------------------
-- Realtime publication
-- -----------------------------------------------------------------------------

do $$
declare
    table_name text;
begin
    foreach table_name in array array[
        'sensor_readings',
        'station_state',
        'station_events',
        'ai_assessments',
        'command_requests',
        'command_results'
    ]
    loop
        if not exists (
            select 1
            from pg_publication_tables
            where pubname = 'supabase_realtime'
              and schemaname = 'public'
              and tablename = table_name
        ) then
            execute format('alter publication supabase_realtime add table public.%I', table_name);
        end if;
    end loop;
end
$$;

-- -----------------------------------------------------------------------------
-- Demo stations. These keys are for local development only.
-- Replace before using real hardware.
-- -----------------------------------------------------------------------------

insert into public.devices (device_id, display_name, device_type)
values
    ('station-001', 'Station 001', 'UNO Q'),
    ('station-002', 'Station 002', 'UNO Q'),
    ('station-003', 'Station 003', 'UNO Q'),
    ('station-004', 'Station 004', 'UNO Q'),
    ('station-005', 'Station 005', 'UNO Q'),
    ('station-006', 'Station 006', 'UNO Q'),
    ('station-007', 'Station 007', 'UNO Q'),
    ('station-008', 'Station 008', 'UNO Q'),
    ('station-009', 'Station 009', 'UNO Q'),
    ('station-010', 'Station 010', 'UNO Q')
on conflict (device_id)
do update set
    display_name = excluded.display_name,
    device_type = excluded.device_type;

insert into public.device_credentials (device_id, secret_hash)
values
    ('station-001', digest('demo-station-001-key', 'sha256')),
    ('station-002', digest('demo-station-002-key', 'sha256')),
    ('station-003', digest('demo-station-003-key', 'sha256')),
    ('station-004', digest('demo-station-004-key', 'sha256')),
    ('station-005', digest('demo-station-005-key', 'sha256')),
    ('station-006', digest('demo-station-006-key', 'sha256')),
    ('station-007', digest('demo-station-007-key', 'sha256')),
    ('station-008', digest('demo-station-008-key', 'sha256')),
    ('station-009', digest('demo-station-009-key', 'sha256')),
    ('station-010', digest('demo-station-010-key', 'sha256'))
on conflict (device_id)
do update set secret_hash = excluded.secret_hash;
