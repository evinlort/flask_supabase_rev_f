const I18N = window.I18N;

let sb = null;
let currentUser = null;
let selectedDeviceId = null;
let currentAccess = null;
let sensorsById = new Map();
let realtimeChannel = null;
let realtimeReadingCount = 0;
let sensorHistory = new Map();
let sensorCharts = new Map();

const SPARKLINE_POINTS = 24;

function isDarkMode() {
    return window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false;
}

function sparklineColor() {
    return isDarkMode() ? "#3987e5" : "#2a78d6";
}

const loginPanel = document.getElementById("login-panel");
const loginForm = document.getElementById("login-form");
const loginError = document.getElementById("login-error");
const dashboard = document.getElementById("dashboard");
const authSummary = document.getElementById("auth-summary");
const logoutButton = document.getElementById("logout-button");
const reloadButton = document.getElementById("reload-button");
const deviceSelect = document.getElementById("device-select");
const accessBadge = document.getElementById("access-badge");
const realtimeStatus = document.getElementById("realtime-status");
const sensorCards = document.getElementById("sensor-cards");
const stationState = document.getElementById("station-state");
const readingsBody = document.getElementById("readings-body");
const eventsBody = document.getElementById("events-body");
const commandsBody = document.getElementById("commands-body");
const aiAssessment = document.getElementById("ai-assessment");
const commandMessage = document.getElementById("command-message");
const lastUpdate = document.getElementById("last-update");
const readingCounter = document.getElementById("reading-counter");
const frequencyValue = document.getElementById("frequency-value");

function formatTime(value) {
    return value ? new Date(value).toLocaleString() : "—";
}

function setRealtimeStatus(text, connected = false) {
    realtimeStatus.textContent = `${I18N.realtime.prefix}: ${text}`;
    realtimeStatus.className = connected
        ? "status status-online"
        : "status status-offline";
}

function showSignedOut() {
    currentUser = null;
    selectedDeviceId = null;
    dashboard.classList.add("hidden");
    loginPanel.classList.remove("hidden");
    authSummary.textContent = "";
}

async function showSignedIn(user) {
    currentUser = user;
    loginPanel.classList.add("hidden");
    dashboard.classList.remove("hidden");
    authSummary.textContent = user.email ?? user.id;
    await loadDevices();
}

async function loadDevices() {
    const { data, error } = await sb
        .from("devices")
        .select("device_id,display_name,device_type,last_seen_at")
        .eq("enabled", true)
        .order("device_id");

    if (error) throw error;

    deviceSelect.innerHTML = "";

    if (!data?.length) {
        const option = document.createElement("option");
        option.value = "";
        option.textContent = I18N.station.no_access;
        deviceSelect.appendChild(option);
        clearDashboardData();
        return;
    }

    for (const device of data) {
        const option = document.createElement("option");
        option.value = device.device_id;
        option.textContent = device.display_name
            ? `${device.display_name} (${device.device_id})`
            : device.device_id;
        deviceSelect.appendChild(option);
    }

    await selectDevice(data[0].device_id);
}

async function loadAccess(deviceId) {
    const { data, error } = await sb
        .from("station_access")
        .select("role,can_read,can_command")
        .eq("device_id", deviceId)
        .eq("user_id", currentUser.id)
        .maybeSingle();

    if (error) throw error;

    currentAccess = data;
    accessBadge.textContent = data
        ? `${data.role} • ${data.can_command ? I18N.access.command_enabled : I18N.access.read_only}`
        : I18N.access.no_access_row;

    document.querySelectorAll("[data-command]").forEach((button) => {
        button.disabled = !data?.can_command;
    });
}

async function loadSensors(deviceId) {
    const { data, error } = await sb
        .from("sensors")
        .select("id,name,unit")
        .eq("device_id", deviceId)
        .order("name");

    if (error) throw error;

    sensorsById = new Map(
        (data ?? []).map((sensor) => [
            String(sensor.id),
            { name: sensor.name, unit: sensor.unit ?? "" },
        ])
    );
}

function sensorInfo(sensorId) {
    return sensorsById.get(String(sensorId)) ?? {
        name: `sensor-${sensorId}`,
        unit: "",
    };
}

function createReadingRow(reading) {
    const sensor = sensorInfo(reading.sensor_id);
    const row = document.createElement("tr");
    row.dataset.readingId = reading.id;

    for (const value of [
        formatTime(reading.measured_at),
        sensor.name,
        reading.value,
        sensor.unit,
    ]) {
        const cell = document.createElement("td");
        cell.textContent = value;
        row.appendChild(cell);
    }

    return row;
}

function updateSensorSparkline(sensorId, canvas) {
    const history = sensorHistory.get(String(sensorId)) ?? [];
    const labels = history.map((point) => point.t);
    const values = history.map((point) => point.v);
    const color = sparklineColor();

    let chart = sensorCharts.get(String(sensorId));
    if (!chart) {
        chart = new Chart(canvas, {
            type: "line",
            data: {
                labels,
                datasets: [{
                    data: values,
                    borderColor: color,
                    backgroundColor: color + "1a",
                    borderWidth: 2,
                    pointRadius: 0,
                    fill: true,
                    tension: 0.3,
                }],
            },
            options: {
                animation: false,
                responsive: true,
                maintainAspectRatio: false,
                scales: { x: { display: false }, y: { display: false } },
                plugins: { legend: { display: false }, tooltip: { enabled: false } },
            },
        });
        sensorCharts.set(String(sensorId), chart);
    } else {
        chart.data.labels = labels;
        chart.data.datasets[0].data = values;
        chart.data.datasets[0].borderColor = color;
        chart.data.datasets[0].backgroundColor = color + "1a";
        chart.update("none");
    }
}

function updateSensorCard(reading) {
    const sensor = sensorInfo(reading.sensor_id);
    let card = document.getElementById(`sensor-card-${reading.sensor_id}`);

    if (!card) {
        card = document.createElement("article");
        card.id = `sensor-card-${reading.sensor_id}`;
        card.className = "sensor-card";
        card.innerHTML = `
            <div class="sensor-name"></div>
            <div class="sensor-value"></div>
            <div class="sensor-time muted"></div>
            <canvas class="sensor-spark"></canvas>
        `;
        sensorCards.appendChild(card);
    }

    card.querySelector(".sensor-name").textContent = sensor.name;
    card.querySelector(".sensor-value").textContent =
        `${reading.value} ${sensor.unit}`.trim();
    card.querySelector(".sensor-time").textContent = formatTime(reading.measured_at);
    lastUpdate.textContent = I18N.telemetry.updated.replace("{time}", formatTime(reading.measured_at));

    const key = String(reading.sensor_id);
    const history = sensorHistory.get(key) ?? [];
    history.push({ t: formatTime(reading.measured_at), v: Number(reading.value) });
    while (history.length > SPARKLINE_POINTS) history.shift();
    sensorHistory.set(key, history);

    updateSensorSparkline(reading.sensor_id, card.querySelector(".sensor-spark"));
}

async function loadReadings(deviceId) {
    const { data, error } = await sb
        .from("sensor_readings")
        .select("id,device_id,sensor_id,value,measured_at")
        .eq("device_id", deviceId)
        .order("measured_at", { ascending: false })
        .limit(200);

    if (error) throw error;

    readingsBody.innerHTML = "";
    sensorCards.innerHTML = "";
    sensorCharts.forEach((chart) => chart.destroy());
    sensorCharts = new Map();
    sensorHistory = new Map();

    if (!data?.length) {
        readingsBody.innerHTML = `<tr><td colspan="4" class="empty">${I18N.readings.empty}</td></tr>`;
        lastUpdate.textContent = I18N.telemetry.no_data;
        return;
    }

    for (const reading of data) {
        readingsBody.appendChild(createReadingRow(reading));
    }

    for (const reading of [...data].reverse()) {
        updateSensorCard(reading);
    }
}

function renderState(state) {
    if (!state) {
        stationState.innerHTML = `<div class="empty">${I18N.station_state.empty}</div>`;
        return;
    }

    const s = I18N.station_state;
    const FREQ_MAX = 50;
    const SPEED_MAX = 3000;
    const values = [
        [s.safety, state.safety_ok ? s.ok : s.blocked, state.safety_ok, true, null],
        [s.vfd_state, state.vfd_state ?? s.unknown, state.vfd_state !== "fault", false, null],
        [s.frequency, state.vfd_frequency_hz == null ? "—" : `${state.vfd_frequency_hz} Hz`, true, false,
            state.vfd_frequency_hz == null ? null : Math.min(100, (state.vfd_frequency_hz / FREQ_MAX) * 100)],
        [s.motor, state.motor_running ? s.running : s.stopped, true, false, null],
        [s.speed, state.motor_speed_rpm == null ? "—" : `${Math.round(state.motor_speed_rpm)} rpm`, true, false,
            state.motor_speed_rpm == null ? null : Math.min(100, (state.motor_speed_rpm / SPEED_MAX) * 100)],
        [s.fault, state.fault_code ?? s.none, !state.fault_code, true, null],
        [s.updated_label, formatTime(state.updated_at), true, false, null],
    ];

    stationState.innerHTML = "";

    for (const [label, value, good, isStatusRow, meterPercent] of values) {
        const item = document.createElement("div");
        item.className = "state-item";
        item.innerHTML = `
            <div class="state-label"></div>
            <div class="state-value"></div>
        `;
        item.querySelector(".state-label").textContent = label;
        const valueNode = item.querySelector(".state-value");
        valueNode.textContent = value;
        if (isStatusRow) {
            valueNode.classList.add(good ? "state-good" : "state-bad");
        }
        if (meterPercent != null) {
            const meter = document.createElement("div");
            meter.className = "state-meter";
            meter.innerHTML = `<div class="state-meter-fill" style="width:${meterPercent}%"></div>`;
            item.appendChild(meter);
        }
        stationState.appendChild(item);
    }
}

async function loadState(deviceId) {
    const { data, error } = await sb
        .from("station_state")
        .select("*")
        .eq("device_id", deviceId)
        .maybeSingle();

    if (error) throw error;
    renderState(data);
}

function createEventRow(event) {
    const row = document.createElement("tr");
    for (const value of [
        formatTime(event.happened_at),
        event.event_type,
        event.severity,
        event.message,
    ]) {
        const cell = document.createElement("td");
        cell.textContent = value ?? "";
        row.appendChild(cell);
    }
    return row;
}

async function loadEvents(deviceId) {
    const { data, error } = await sb
        .from("station_events")
        .select("id,event_type,severity,message,happened_at")
        .eq("device_id", deviceId)
        .order("happened_at", { ascending: false })
        .limit(20);

    if (error) throw error;
    eventsBody.innerHTML = "";

    if (!data?.length) {
        eventsBody.innerHTML = `<tr><td colspan="4" class="empty">${I18N.events.empty}</td></tr>`;
        return;
    }

    data.forEach((event) => eventsBody.appendChild(createEventRow(event)));
}

function createCommandRow(command) {
    const row = document.createElement("tr");
    for (const value of [
        formatTime(command.requested_at),
        command.command_type,
        command.requested_value ?? "—",
        command.status,
    ]) {
        const cell = document.createElement("td");
        cell.textContent = value;
        row.appendChild(cell);
    }
    return row;
}

async function loadCommands(deviceId) {
    const { data, error } = await sb
        .from("command_requests")
        .select("id,command_type,requested_value,requested_at,status,expires_at")
        .eq("device_id", deviceId)
        .order("requested_at", { ascending: false })
        .limit(20);

    if (error) throw error;
    commandsBody.innerHTML = "";

    if (!data?.length) {
        commandsBody.innerHTML = `<tr><td colspan="4" class="empty">${I18N.commands_table.empty}</td></tr>`;
        return;
    }

    data.forEach((command) => commandsBody.appendChild(createCommandRow(command)));
}

function renderAiAssessment(item) {
    if (!item) {
        aiAssessment.className = "ai-box empty";
        aiAssessment.textContent = I18N.ai.empty;
        return;
    }

    aiAssessment.className = "ai-box";
    aiAssessment.innerHTML = "";

    const rows = [
        [I18N.ai.diagnosis, item.diagnosis],
        [I18N.ai.recommendation, item.recommendation],
        [I18N.ai.explanation, item.explanation],
        [I18N.ai.model, item.model_version],
        [I18N.ai.created, formatTime(item.created_at)],
    ];

    for (const [label, value] of rows) {
        const div = document.createElement("div");
        div.className = "ai-row";
        const labelNode = document.createElement("span");
        labelNode.className = "ai-label";
        labelNode.textContent = `${label}: `;
        div.appendChild(labelNode);
        div.appendChild(document.createTextNode(value ?? "—"));
        aiAssessment.appendChild(div);
    }
}

async function loadAiAssessment(deviceId) {
    const { data, error } = await sb
        .from("ai_assessments")
        .select("diagnosis,recommendation,explanation,model_version,created_at")
        .eq("device_id", deviceId)
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();

    if (error) throw error;
    renderAiAssessment(data);
}

async function unsubscribeRealtime() {
    if (realtimeChannel && sb) {
        await sb.removeChannel(realtimeChannel);
    }
    realtimeChannel = null;
    setRealtimeStatus(I18N.realtime.disconnected, false);
}

async function subscribeRealtime(deviceId) {
    await unsubscribeRealtime();
    realtimeReadingCount = 0;
    readingCounter.textContent = I18N.readings.counter.replace("{n}", "0");

    realtimeChannel = sb
        .channel(`station-${deviceId}-${Date.now()}`)
        .on(
            "postgres_changes",
            {
                event: "INSERT",
                schema: "public",
                table: "sensor_readings",
                filter: `device_id=eq.${deviceId}`,
            },
            (payload) => {
                if (payload.new.device_id !== selectedDeviceId) return;
                const empty = readingsBody.querySelector(".empty");
                if (empty) readingsBody.innerHTML = "";
                readingsBody.prepend(createReadingRow(payload.new));
                updateSensorCard(payload.new);
                while (readingsBody.children.length > 200) {
                    readingsBody.lastElementChild.remove();
                }
                realtimeReadingCount += 1;
                readingCounter.textContent = I18N.readings.counter.replace("{n}", realtimeReadingCount);
            }
        )
        .on(
            "postgres_changes",
            {
                event: "*",
                schema: "public",
                table: "station_state",
                filter: `device_id=eq.${deviceId}`,
            },
            (payload) => renderState(payload.new)
        )
        .on(
            "postgres_changes",
            {
                event: "INSERT",
                schema: "public",
                table: "station_events",
                filter: `device_id=eq.${deviceId}`,
            },
            (payload) => {
                const empty = eventsBody.querySelector(".empty");
                if (empty) eventsBody.innerHTML = "";
                eventsBody.prepend(createEventRow(payload.new));
                while (eventsBody.children.length > 20) {
                    eventsBody.lastElementChild.remove();
                }
            }
        )
        .on(
            "postgres_changes",
            {
                event: "INSERT",
                schema: "public",
                table: "ai_assessments",
                filter: `device_id=eq.${deviceId}`,
            },
            (payload) => renderAiAssessment(payload.new)
        )
        .on(
            "postgres_changes",
            {
                event: "*",
                schema: "public",
                table: "command_requests",
                filter: `device_id=eq.${deviceId}`,
            },
            () => loadCommands(deviceId).catch(console.error)
        )
        .subscribe((status) => {
            if (status === "SUBSCRIBED") {
                setRealtimeStatus(I18N.realtime.connected, true);
            } else {
                setRealtimeStatus(status.toLowerCase(), false);
            }
        });
}

function clearDashboardData() {
    sensorCards.innerHTML = "";
    sensorCharts.forEach((chart) => chart.destroy());
    sensorCharts = new Map();
    sensorHistory = new Map();
    stationState.innerHTML = `<div class="empty">${I18N.station_state.no_station_selected}</div>`;
    readingsBody.innerHTML = `<tr><td colspan="4" class="empty">${I18N.readings.no_station_selected}</td></tr>`;
    eventsBody.innerHTML = `<tr><td colspan="4" class="empty">${I18N.events.no_station_selected}</td></tr>`;
    commandsBody.innerHTML = `<tr><td colspan="4" class="empty">${I18N.commands_table.no_station_selected}</td></tr>`;
    renderAiAssessment(null);
    accessBadge.textContent = "";
}

async function selectDevice(deviceId) {
    if (!deviceId) {
        selectedDeviceId = null;
        await unsubscribeRealtime();
        clearDashboardData();
        return;
    }

    selectedDeviceId = deviceId;
    deviceSelect.value = deviceId;
    commandMessage.textContent = "";
    setRealtimeStatus(I18N.realtime.connecting, false);

    await loadAccess(deviceId);
    await loadSensors(deviceId);
    await subscribeRealtime(deviceId);

    await Promise.all([
        loadReadings(deviceId),
        loadState(deviceId),
        loadEvents(deviceId),
        loadCommands(deviceId),
        loadAiAssessment(deviceId),
    ]);
}

async function sendCommand(commandType) {
    if (!selectedDeviceId || !currentAccess?.can_command) return;

    let requestedValue = null;
    if (commandType === "set_frequency") {
        requestedValue = Number(frequencyValue.value);
        if (!Number.isFinite(requestedValue)) {
            commandMessage.textContent = I18N.command.invalid_frequency;
            return;
        }
    }

    const expiresAt = new Date(Date.now() + 30_000).toISOString();

    const { error } = await sb
        .from("command_requests")
        .insert({
            device_id: selectedDeviceId,
            command_type: commandType,
            requested_value: requestedValue,
            expires_at: expiresAt,
        });

    if (error) {
        commandMessage.textContent = I18N.command.rejected.replace("{message}", error.message);
        return;
    }

    commandMessage.textContent = I18N.command.stored;
    await loadCommands(selectedDeviceId);
}

async function reloadSelectedDevice() {
    if (!selectedDeviceId) return;
    await loadAccess(selectedDeviceId);
    await loadSensors(selectedDeviceId);
    await Promise.all([
        loadReadings(selectedDeviceId),
        loadState(selectedDeviceId),
        loadEvents(selectedDeviceId),
        loadCommands(selectedDeviceId),
        loadAiAssessment(selectedDeviceId),
    ]);
}

async function init() {
    try {
        const response = await fetch("/api/config");
        if (!response.ok) throw new Error("Failed to load Flask config");
        const config = await response.json();

        sb = window.supabase.createClient(config.supabaseUrl, config.supabaseKey);

        const { data: { session } } = await sb.auth.getSession();
        if (session?.user) {
            await showSignedIn(session.user);
        } else {
            showSignedOut();
        }

        sb.auth.onAuthStateChange(async (_event, session) => {
            if (session?.user) {
                await showSignedIn(session.user);
            } else {
                await unsubscribeRealtime();
                showSignedOut();
            }
        });
    } catch (error) {
        console.error(error);
        loginError.textContent = error.message;
    }
}

loginForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    loginError.textContent = "";

    const email = document.getElementById("email").value.trim();
    const password = document.getElementById("password").value;

    const { error } = await sb.auth.signInWithPassword({ email, password });
    if (error) loginError.textContent = error.message;
});

logoutButton.addEventListener("click", async () => {
    await sb.auth.signOut();
});

deviceSelect.addEventListener("change", async (event) => {
    try {
        await selectDevice(event.target.value);
    } catch (error) {
        console.error(error);
        setRealtimeStatus(I18N.realtime.error, false);
    }
});

reloadButton.addEventListener("click", () => {
    reloadSelectedDevice().catch(console.error);
});

document.querySelectorAll("[data-command]").forEach((button) => {
    button.addEventListener("click", () => {
        sendCommand(button.dataset.command).catch(console.error);
    });
});

window.addEventListener("beforeunload", () => {
    if (realtimeChannel && sb) sb.removeChannel(realtimeChannel);
});

init();
