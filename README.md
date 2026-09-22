# TLM Rev F — Flask + Supabase Realtime prototype

This version changes the previous simple sensor demo to match the supplied TLM data-flow diagram.

## What is implemented

### Station -> Supabase

Each simulated UNO Q station sends:

- three-phase voltage: `voltage_l1`, `voltage_l2`, `voltage_l3`
- three-phase current: `current_l1`, `current_l2`, `current_l3`
- temperature
- vibration
- motor speed
- VFD frequency
- safety state
- VFD state
- fault code
- station ID
- measurement timestamp

The station does **not** get direct write access to database tables. It calls `ingest_station_packet(...)` with a per-station secret. The PostgreSQL function authenticates the station and normalizes the packet into:

- `devices`
- `sensors`
- `sensor_readings`
- `station_state`
- `station_events`

### Dashboard user -> Supabase

The browser signs in through Supabase Auth.

`station_access` controls, per user and station:

- role: `student`, `teacher`, or `manager`
- read permission
- command permission

RLS makes the device selector return only authorized stations.

The dashboard shows in realtime:

- latest telemetry
- station safety/VFD state
- faults/events
- command status/results
- latest AI assessment

### Supabase -> station command path

The dashboard only creates a `command_requests` record.

The simulator then does:

```text
Supabase command request
        ↓
UNO Q / Linux polls request
        ↓
local Safety Guardian
        ↓
execute OR block
        ↓
VFD / motor only after local approval
        ↓
result returned to Supabase
```

Implemented command types:

- `start`
- `stop`
- `set_frequency`
- `reset_fault`

This follows the diagram requirement that Supabase must **not directly operate the motor** and that the local safety chain remains authoritative.

### AI path

`ai_assessments` stores:

- diagnosis
- recommendation
- explanation
- model version
- optional related event

`ai_mock_engine.py` is optional and is explicitly **not AI**. It is only a deterministic test producer for exercising the AI -> Supabase -> dashboard data path.

---

# 1. Apply the Supabase schema

Open:

**Supabase Dashboard -> SQL Editor**

Run the complete file:

```text
sql/supabase_setup.sql
```

The script also removes the anonymous-read policies from the earlier prototype and adds migration columns where possible.

It creates ten development stations (the simulator uses the first five by default):

```text
station-001 ... station-010
```

with development-only station keys:

```text
station-NNN -> demo-station-NNN-key
```

Do not use these keys on real hardware.

---

# 2. Create a dashboard user

In Supabase:

```text
Authentication -> Users -> Add user
```

Create an email/password user.

Then open:

```text
sql/grant_user_access.sql
```

Replace:

```sql
YOUR_EMAIL@example.com
```

with the user's email and run it in SQL Editor.

The sample grants:

```text
station-001 -> manager -> read + command
station-002 -> teacher -> read + command
station-003 -> student -> read only
station-004 -> teacher -> read + command
station-005 -> student -> read only
```

This is deliberately configurable rather than assuming that a particular role always has command rights.

---

# 3. Python environment

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Copy the environment file:

```bash
cp .env.example .env
```

Set:

```env
SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
SUPABASE_PUBLIC_KEY=YOUR_PUBLISHABLE_OR_ANON_KEY
```

Do not put a Supabase service-role key into browser or station code.

---

# 4. Run the UNO Q station simulator

```bash
source .venv/bin/activate
python sensor_simulator.py
```

Default:

```text
5 stations
10 telemetry measurements per station
one packet every 10 seconds
```

The station uses its own device secret when calling the Supabase RPC.

It also polls for cloud command requests. Before executing a command, `process_command()` emulates the local Safety Guardian.

---

# 5. Run Flask

```bash
source .venv/bin/activate
python app.py
```

Open:

```text
http://127.0.0.1:5000
```

Sign in with the Supabase Auth user created above.

You should see only stations assigned to that user.

---

# 6. Test the command path

For a station with `can_command=true` (for example `station-001`, `station-002`, or `station-004`):

1. Select the station.
2. Click **Start**.
3. The request appears as `pending`.
4. The station simulator polls it.
5. The local Safety Guardian executes or blocks it.
6. Supabase stores the result.
7. Realtime updates the dashboard.

For a read-only assignment such as `station-003` or `station-005`, the command controls are disabled.

---

# 7. Optional mock AI producer

Only if you want to test the AI-output section before a real AI service exists, add to `.env`:

```env
SUPABASE_SERVICE_ROLE_KEY=YOUR_SERVICE_ROLE_KEY
```

Then run:

```bash
python ai_mock_engine.py
```

The service-role key is appropriate only for a trusted backend process. Never expose it to the browser or physical station.

---

# Realtime tables

The setup adds these tables to the `supabase_realtime` publication:

- `sensor_readings`
- `station_state`
- `station_events`
- `ai_assessments`
- `command_requests`
- `command_results`

The browser subscribes only to the currently selected `device_id`.

---

# Database structure

```text
organizations
     │
     └── courses

users (Supabase Auth)
     │
     └── station_access ─────────┐
                                │
                           devices
                                │
             ┌──────────────────┼─────────────────┐
             │                  │                 │
          sensors          station_state     station_events
             │
      sensor_readings

users -> command_requests -> command_results

devices -> ai_assessments
```

`device_credentials` is separate and is not readable by browser users.

---

# Important boundary

This is still a prototype. It models the architecture correctly, including authentication/authorization and the local safety decision, but it is **not a certified motor-control or safety system**. Emergency-stop and safety functions must remain independent of the cloud exactly as the supplied architecture requires.
