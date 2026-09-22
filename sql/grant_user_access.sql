-- 1) First create the user in Supabase Dashboard -> Authentication -> Users.
-- 2) Replace the email below.
-- 3) Run this in SQL Editor to give that user access to the demo stations.

insert into public.station_access (user_id, device_id, role, can_read, can_command)
select id, 'station-001', 'manager', true, true
from auth.users
where email = 'YOUR_EMAIL@example.com'
on conflict (user_id, device_id)
do update set role = excluded.role,
              can_read = excluded.can_read,
              can_command = excluded.can_command;

insert into public.station_access (user_id, device_id, role, can_read, can_command)
select id, 'station-002', 'teacher', true, true
from auth.users
where email = 'YOUR_EMAIL@example.com'
on conflict (user_id, device_id)
do update set role = excluded.role,
              can_read = excluded.can_read,
              can_command = excluded.can_command;

insert into public.station_access (user_id, device_id, role, can_read, can_command)
select id, 'station-003', 'student', true, false
from auth.users
where email = 'YOUR_EMAIL@example.com'
on conflict (user_id, device_id)
do update set role = excluded.role,
              can_read = excluded.can_read,
              can_command = excluded.can_command;


insert into public.station_access (user_id, device_id, role, can_read, can_command)
select id, 'station-004', 'teacher', true, true
from auth.users
where email = 'YOUR_EMAIL@example.com'
on conflict (user_id, device_id)
do update set role = excluded.role,
              can_read = excluded.can_read,
              can_command = excluded.can_command;

insert into public.station_access (user_id, device_id, role, can_read, can_command)
select id, 'station-005', 'student', true, false
from auth.users
where email = 'YOUR_EMAIL@example.com'
on conflict (user_id, device_id)
do update set role = excluded.role,
              can_read = excluded.can_read,
              can_command = excluded.can_command;
