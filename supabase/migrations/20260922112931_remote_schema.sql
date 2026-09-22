SET local check_function_bodies = off;

CREATE TABLE "public"."ai_assessments" (
  "id"             uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "device_id"      text                     NOT NULL,
  "event_id"       bigint,
  "model_version"  text                     NOT NULL,
  "diagnosis"      text,
  "recommendation" text,
  "explanation"    text,
  "created_at"     timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "ai_assessments_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."ai_assessments"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."command_requests" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "device_id"       text                     NOT NULL,
  "command_type"    text                     NOT NULL,
  "requested_value" double precision,
  "requested_at"    timestamp with time zone NOT NULL DEFAULT now(),
  "expires_at"      timestamp with time zone NOT NULL DEFAULT (now() + '00:00:30'::interval),
  "status"          text                     NOT NULL DEFAULT 'pending'::text,
  "delivered_at"    timestamp with time zone,
  "completed_at"    timestamp with time zone,
  CONSTRAINT "command_requests_command_type_check" CHECK ((command_type = ANY (ARRAY['start'::text, 'stop'::text, 'set_frequency'::text, 'reset_fault'::text]))),
  CONSTRAINT "command_requests_pkey" PRIMARY KEY (id),
  CONSTRAINT "command_requests_status_check" CHECK ((status = ANY (ARRAY['pending'::text, 'delivered'::text, 'executed'::text, 'blocked'::text, 'expired'::text]))),
  "requested_by"    uuid                     NOT NULL DEFAULT auth.uid()
);

ALTER TABLE "public"."command_requests"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."command_results" (
  "command_id"     uuid                     NOT NULL,
  "device_id"      text                     NOT NULL,
  "outcome"        text                     NOT NULL,
  "reason"         text,
  "result_payload" jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "completed_at"   timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "command_results_outcome_check" CHECK ((outcome = ANY (ARRAY['executed'::text, 'blocked'::text]))),
  CONSTRAINT "command_results_pkey" PRIMARY KEY (command_id)
);

ALTER TABLE "public"."command_results"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."courses" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "organization_id" uuid,
  "name"            text                     NOT NULL,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "courses_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."courses"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."device_credentials" (
  "device_id"   text                     NOT NULL,
  "secret_hash" bytea                    NOT NULL,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "device_credentials_pkey" PRIMARY KEY (device_id)
);

ALTER TABLE "public"."device_credentials"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."devices" (
  "device_id"       text                     NOT NULL,
  "organization_id" uuid,
  "course_id"       uuid,
  "display_name"    text                     NOT NULL,
  "device_type"     text                     NOT NULL DEFAULT 'UNO Q'::text,
  "enabled"         boolean                  NOT NULL DEFAULT true,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  "last_seen_at"    timestamp with time zone,
  CONSTRAINT "devices_pkey" PRIMARY KEY (device_id)
);

ALTER TABLE "public"."devices"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."organizations" (
  "id"         uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "name"       text                     NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "organizations_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."organizations"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."sensor_readings" (
  "id"          bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "device_id"   text                     NOT NULL,
  "sensor_id"   bigint                   NOT NULL,
  "value"       double precision         NOT NULL,
  "measured_at" timestamp with time zone NOT NULL,
  "received_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "sensor_readings_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."sensor_readings"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."sensors" (
  "id"         bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "device_id"  text                     NOT NULL,
  "name"       text                     NOT NULL,
  "unit"       text,
  "category"   text                     NOT NULL DEFAULT 'telemetry'::text,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "sensors_device_id_name_key" UNIQUE (device_id, name),
  CONSTRAINT "sensors_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."sensors"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."station_access" (
  "user_id"     uuid                     NOT NULL,
  "device_id"   text                     NOT NULL,
  "role"        text                     NOT NULL,
  "can_read"    boolean                  NOT NULL DEFAULT true,
  "can_command" boolean                  NOT NULL DEFAULT false,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "station_access_pkey" PRIMARY KEY (user_id, device_id),
  CONSTRAINT "station_access_role_check" CHECK ((role = ANY (ARRAY['student'::text, 'teacher'::text, 'manager'::text])))
);

ALTER TABLE "public"."station_access"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."station_events" (
  "id"          bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "device_id"   text                     NOT NULL,
  "event_type"  text                     NOT NULL,
  "severity"    text                     NOT NULL,
  "message"     text                     NOT NULL,
  "payload"     jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "happened_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "station_events_pkey" PRIMARY KEY (id),
  CONSTRAINT "station_events_severity_check" CHECK ((severity = ANY (ARRAY['info'::text, 'warning'::text, 'fault'::text])))
);

ALTER TABLE "public"."station_events"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."station_state" (
  "device_id"        text                     NOT NULL,
  "safety_ok"        boolean                  NOT NULL DEFAULT true,
  "vfd_state"        text                     NOT NULL DEFAULT 'stopped'::text,
  "vfd_frequency_hz" double precision,
  "motor_running"    boolean                  NOT NULL DEFAULT false,
  "motor_speed_rpm"  double precision,
  "fault_code"       text,
  "updated_at"       timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "station_state_pkey" PRIMARY KEY (device_id)
);

ALTER TABLE "public"."station_state"
  ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.complete_station_command (
  p_device_id      text,
  p_device_key     text,
  p_command_id     uuid,
  p_outcome        text,
  p_reason         text  DEFAULT NULL::text,
  p_result_payload jsonb DEFAULT '{}'::jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'extensions'
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.has_station_command_access (
  p_device_id text
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
    select exists (
        select 1
        from public.station_access sa
        where sa.user_id = auth.uid()
          and sa.device_id = p_device_id
          and sa.can_command = true
    );
$function$;

CREATE OR REPLACE FUNCTION public.has_station_read_access (
  p_device_id text
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
    select exists (
        select 1
        from public.station_access sa
        where sa.user_id = auth.uid()
          and sa.device_id = p_device_id
          and sa.can_read = true
    );
$function$;

CREATE OR REPLACE FUNCTION public.ingest_station_packet (
  p_device_id   text,
  p_device_key  text,
  p_measured_at timestamp with time zone,
  p_telemetry   jsonb,
  p_state       jsonb
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'extensions'
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.is_station_manager (
  p_device_id text
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public'
  AS $function$
    select exists (
        select 1
        from public.station_access sa
        where sa.user_id = auth.uid()
          and sa.device_id = p_device_id
          and sa.role = 'manager'
    );
$function$;

CREATE OR REPLACE FUNCTION public.pull_next_station_command (
  p_device_id  text,
  p_device_key text
)
  RETURNS TABLE (
    command_id      uuid,
    command_type    text,
    requested_value double precision,
    requested_at    timestamp with time zone,
    expires_at      timestamp with time zone
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'extensions'
  AS $function$
begin
    if not public.station_key_valid(
        p_device_id,
        p_device_key
    ) then
        raise exception 'invalid station credentials';
    end if;


    -- Expire old commands.
    -- IMPORTANT: every column is qualified with "cr"
    -- because RETURNS TABLE creates PL/pgSQL variables
    -- such as expires_at and requested_at.
    update public.command_requests as cr
    set
        status = 'expired',
        completed_at = now()
    where cr.device_id = p_device_id
      and cr.status = 'pending'
      and cr.expires_at <= now();


    return query

    with candidate as (
        select cr.id
        from public.command_requests as cr
        where cr.device_id = p_device_id
          and cr.status = 'pending'
          and cr.expires_at > now()
        order by cr.requested_at
        for update skip locked
        limit 1
    )

    update public.command_requests as cr
    set
        status = 'delivered',
        delivered_at = now()
    from candidate as c
    where cr.id = c.id

    returning
        cr.id,
        cr.command_type,
        cr.requested_value,
        cr.requested_at,
        cr.expires_at;
end;
$function$;

CREATE OR REPLACE FUNCTION public.rls_auto_enable()
  RETURNS event_trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'pg_catalog'
  AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.station_key_valid (
  p_device_id  text,
  p_device_key text
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public', 'extensions'
  AS $function$
    select exists (
        select 1
        from public.device_credentials dc
        join public.devices d on d.device_id = dc.device_id
        where dc.device_id = p_device_id
          and d.enabled = true
          and dc.secret_hash = digest(p_device_key, 'sha256')
    );
$function$;

ALTER TABLE "public"."command_results"
  ADD CONSTRAINT "command_results_command_id_fkey" FOREIGN KEY (command_id) REFERENCES public.command_requests(id) ON DELETE CASCADE;

ALTER TABLE "public"."devices"
  ADD CONSTRAINT "devices_course_id_fkey" FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE SET NULL;

ALTER TABLE "public"."ai_assessments"
  ADD CONSTRAINT "ai_assessments_device_id_fkey" FOREIGN KEY (device_id) REFERENCES public.devices(device_id) ON DELETE CASCADE;

ALTER TABLE "public"."command_requests"
  ADD CONSTRAINT "command_requests_device_id_fkey" FOREIGN KEY (device_id) REFERENCES public.devices(device_id) ON DELETE CASCADE;

ALTER TABLE "public"."command_results"
  ADD CONSTRAINT "command_results_device_id_fkey" FOREIGN KEY (device_id) REFERENCES public.devices(device_id) ON DELETE CASCADE;

ALTER TABLE "public"."device_credentials"
  ADD CONSTRAINT "device_credentials_device_id_fkey" FOREIGN KEY (device_id) REFERENCES public.devices(device_id) ON DELETE CASCADE;

ALTER TABLE "public"."courses"
  ADD CONSTRAINT "courses_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;

ALTER TABLE "public"."devices"
  ADD CONSTRAINT "devices_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE SET NULL;

ALTER TABLE "public"."sensor_readings"
  ADD CONSTRAINT "sensor_readings_device_id_fkey" FOREIGN KEY (device_id) REFERENCES public.devices(device_id) ON DELETE CASCADE;

ALTER TABLE "public"."sensors"
  ADD CONSTRAINT "sensors_device_id_fkey" FOREIGN KEY (device_id) REFERENCES public.devices(device_id) ON DELETE CASCADE;

ALTER TABLE "public"."sensor_readings"
  ADD CONSTRAINT "sensor_readings_sensor_id_fkey" FOREIGN KEY (sensor_id) REFERENCES public.sensors(id) ON DELETE CASCADE;

ALTER TABLE "public"."station_access"
  ADD CONSTRAINT "station_access_device_id_fkey" FOREIGN KEY (device_id) REFERENCES public.devices(device_id) ON DELETE CASCADE;

ALTER TABLE "public"."station_access"
  ADD CONSTRAINT "station_access_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."station_events"
  ADD CONSTRAINT "station_events_device_id_fkey" FOREIGN KEY (device_id) REFERENCES public.devices(device_id) ON DELETE CASCADE;

ALTER TABLE "public"."ai_assessments"
  ADD CONSTRAINT "ai_assessments_event_id_fkey" FOREIGN KEY (event_id) REFERENCES public.station_events(id) ON DELETE SET NULL;

ALTER TABLE "public"."station_state"
  ADD CONSTRAINT "station_state_device_id_fkey" FOREIGN KEY (device_id) REFERENCES public.devices(device_id) ON DELETE CASCADE;

CREATE INDEX idx_ai_assessments_device_time ON public.ai_assessments USING btree (device_id, created_at DESC);

CREATE INDEX idx_command_requests_device_status_time ON public.command_requests USING btree (device_id, status, requested_at);

CREATE INDEX idx_sensor_readings_device_time ON public.sensor_readings USING btree (device_id, measured_at DESC);

CREATE INDEX idx_sensor_readings_sensor_time ON public.sensor_readings USING btree (sensor_id, measured_at DESC);

CREATE INDEX idx_station_events_device_time ON public.station_events USING btree (device_id, happened_at DESC);

CREATE POLICY "ai_assessments_read" ON "public"."ai_assessments"
  FOR SELECT
  TO "authenticated"
  USING (public.has_station_read_access(device_id));

CREATE POLICY "command_requests_read" ON "public"."command_requests"
  FOR SELECT
  TO "authenticated"
  USING (public.has_station_read_access(device_id));

CREATE POLICY "command_results_read" ON "public"."command_results"
  FOR SELECT
  TO "authenticated"
  USING (public.has_station_read_access(device_id));

CREATE POLICY "devices_read" ON "public"."devices"
  FOR SELECT
  TO "authenticated"
  USING (public.has_station_read_access(device_id));

CREATE POLICY "sensor_readings_read" ON "public"."sensor_readings"
  FOR SELECT
  TO "authenticated"
  USING (public.has_station_read_access(device_id));

CREATE POLICY "sensors_read" ON "public"."sensors"
  FOR SELECT
  TO "authenticated"
  USING (public.has_station_read_access(device_id));

CREATE POLICY "station_access_manager_delete" ON "public"."station_access"
  FOR DELETE
  TO "authenticated"
  USING (public.is_station_manager(device_id));

CREATE POLICY "station_access_manager_insert" ON "public"."station_access"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (public.is_station_manager(device_id));

CREATE POLICY "station_access_manager_update" ON "public"."station_access"
  FOR UPDATE
  TO "authenticated"
  USING (public.is_station_manager(device_id))
  WITH CHECK (public.is_station_manager(device_id));

CREATE POLICY "station_access_read" ON "public"."station_access"
  FOR SELECT
  TO "authenticated"
  USING (((user_id = auth.uid()) OR public.is_station_manager(device_id)));

CREATE POLICY "station_events_read" ON "public"."station_events"
  FOR SELECT
  TO "authenticated"
  USING (public.has_station_read_access(device_id));

CREATE POLICY "station_state_read" ON "public"."station_state"
  FOR SELECT
  TO "authenticated"
  USING (public.has_station_read_access(device_id));

CREATE EVENT TRIGGER "ensure_rls"
  ON ddl_command_end
  WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  EXECUTE FUNCTION "public"."rls_auto_enable"();

ALTER PUBLICATION "supabase_realtime" ADD TABLE "public"."ai_assessments";

ALTER PUBLICATION "supabase_realtime" ADD TABLE "public"."command_requests";

ALTER PUBLICATION "supabase_realtime" ADD TABLE "public"."command_results";

ALTER PUBLICATION "supabase_realtime" ADD TABLE "public"."sensor_readings";

ALTER PUBLICATION "supabase_realtime" ADD TABLE "public"."station_events";

ALTER PUBLICATION "supabase_realtime" ADD TABLE "public"."station_state";

REVOKE ALL ON FUNCTION "public"."complete_station_command"(text, text, uuid, text, text, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."complete_station_command"(text, text, uuid, text, text, jsonb) TO "anon", "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "public"."has_station_command_access"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."has_station_command_access"(text) TO "anon", "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "public"."has_station_read_access"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."has_station_read_access"(text) TO "anon", "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "public"."ingest_station_packet"(text, text, timestamp WITH time zone, jsonb, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."ingest_station_packet"(text, text, timestamp WITH time zone, jsonb, jsonb) TO "anon", "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "public"."is_station_manager"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."is_station_manager"(text) TO "anon", "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "public"."pull_next_station_command"(text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."pull_next_station_command"(text, text) TO "anon", "authenticated", "postgres", "service_role";

GRANT EXECUTE ON FUNCTION "public"."rls_auto_enable"() TO PUBLIC, "anon", "authenticated", "postgres", "service_role";

REVOKE ALL ON FUNCTION "public"."station_key_valid"(text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "public"."station_key_valid"(text, text) TO "anon", "authenticated", "postgres", "service_role";

REVOKE ALL ON TABLE "public"."ai_assessments" FROM "authenticated";

GRANT SELECT ON TABLE "public"."ai_assessments" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."ai_assessments" TO "postgres", "service_role";

REVOKE ALL ON TABLE "public"."command_requests" FROM "authenticated";

GRANT INSERT, SELECT ON TABLE "public"."command_requests" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."command_requests" TO "postgres", "service_role";

REVOKE ALL ON TABLE "public"."command_results" FROM "authenticated";

GRANT SELECT ON TABLE "public"."command_results" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."command_results" TO "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."courses" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."device_credentials" TO "postgres", "service_role";

REVOKE ALL ON TABLE "public"."devices" FROM "authenticated";

GRANT SELECT ON TABLE "public"."devices" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."devices" TO "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."organizations" TO "anon", "authenticated", "postgres", "service_role";

REVOKE ALL ON TABLE "public"."sensor_readings" FROM "authenticated";

GRANT SELECT ON TABLE "public"."sensor_readings" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."sensor_readings" TO "postgres", "service_role";

REVOKE ALL ON TABLE "public"."sensors" FROM "authenticated";

GRANT SELECT ON TABLE "public"."sensors" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."sensors" TO "postgres", "service_role";

REVOKE ALL ON TABLE "public"."station_access" FROM "authenticated";

GRANT SELECT ON TABLE "public"."station_access" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."station_access" TO "postgres", "service_role";

REVOKE ALL ON TABLE "public"."station_events" FROM "authenticated";

GRANT SELECT ON TABLE "public"."station_events" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."station_events" TO "postgres", "service_role";

REVOKE ALL ON TABLE "public"."station_state" FROM "authenticated";

GRANT SELECT ON TABLE "public"."station_state" TO "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."station_state" TO "postgres", "service_role";

ALTER TABLE "public"."command_requests"
  ADD CONSTRAINT "command_requests_requested_by_fkey" FOREIGN KEY (requested_by) REFERENCES auth.users(id) ON DELETE RESTRICT;

CREATE POLICY "command_requests_insert" ON "public"."command_requests"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (((requested_by = auth.uid()) AND public.has_station_command_access(device_id)));

