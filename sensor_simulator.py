import os
import random
import time
import argparse
from dataclasses import dataclass
from datetime import datetime, timezone

from dotenv import load_dotenv
from supabase import Client, create_client

from logging_config import configure_logging

load_dotenv()

logger = configure_logging("sensor_simulator")

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_PUBLIC_KEY = os.environ["SUPABASE_PUBLIC_KEY"]
STATION_COUNT = int(os.getenv("STATION_COUNT", "3"))
SEND_INTERVAL_SECONDS = float(os.getenv("SEND_INTERVAL_SECONDS", "10"))
FAULT_PROBABILITY = float(os.getenv("FAULT_PROBABILITY", "0.01"))

supabase: Client = create_client(SUPABASE_URL, SUPABASE_PUBLIC_KEY)


@dataclass
class StationRuntime:
    device_id: str
    device_key: str
    safety_ok: bool = True
    vfd_state: str = "stopped"
    vfd_frequency_hz: float = 0.0
    motor_running: bool = False
    motor_speed_rpm: float = 0.0
    fault_code: str | None = None


def build_stations(count: int) -> list[StationRuntime]:
    return [
        StationRuntime(
            device_id=f"station-{index:03d}",
            device_key=f"demo-station-{index:03d}-key",
        )
        for index in range(1, count + 1)
    ]


def maybe_create_fault(station: StationRuntime) -> None:
    if station.fault_code is None and random.random() < FAULT_PROBABILITY:
        station.fault_code = random.choice(["OVERCURRENT", "OVERTEMP", "VFD_TRIP"])
        station.vfd_state = "fault"
        station.motor_running = False
        station.motor_speed_rpm = 0.0


def process_command(station: StationRuntime, command: dict) -> tuple[str, str | None]:
    command_type = command["command_type"]
    requested_value = command.get("requested_value")

    # This emulates the local Safety Guardian shown in the architecture.
    # Supabase never directly operates the VFD/motor.
    if command_type == "stop":
        station.motor_running = False
        station.vfd_state = "stopped"
        station.motor_speed_rpm = 0.0
        return "executed", None

    if not station.safety_ok:
        return "blocked", "local safety chain is not OK"

    if station.fault_code and command_type != "reset_fault":
        return "blocked", f"active VFD fault: {station.fault_code}"

    if command_type == "reset_fault":
        station.fault_code = None
        station.vfd_state = "stopped"
        station.motor_running = False
        station.motor_speed_rpm = 0.0
        return "executed", None

    if command_type == "set_frequency":
        if requested_value is None or not 0 <= float(requested_value) <= 50:
            return "blocked", "frequency must be between 0 and 50 Hz"

        station.vfd_frequency_hz = float(requested_value)
        if station.motor_running:
            station.motor_speed_rpm = station.vfd_frequency_hz / 50.0 * 1500.0
        return "executed", None

    if command_type == "start":
        if station.vfd_frequency_hz <= 0:
            station.vfd_frequency_hz = 25.0
        station.vfd_state = "running"
        station.motor_running = True
        station.motor_speed_rpm = station.vfd_frequency_hz / 50.0 * 1500.0
        return "executed", None

    return "blocked", f"unsupported command: {command_type}"


def pull_and_process_command(station: StationRuntime) -> None:
    response = (
        supabase.rpc(
            "pull_next_station_command",
            {
                "p_device_id": station.device_id,
                "p_device_key": station.device_key,
            },
        )
        .execute()
    )

    rows = response.data or []
    if not rows:
        return

    command = rows[0]
    outcome, reason = process_command(station, command)

    (
        supabase.rpc(
            "complete_station_command",
            {
                "p_device_id": station.device_id,
                "p_device_key": station.device_key,
                "p_command_id": command["command_id"],
                "p_outcome": outcome,
                "p_reason": reason,
                "p_result_payload": {
                    "safety_ok": station.safety_ok,
                    "vfd_state": station.vfd_state,
                    "vfd_frequency_hz": station.vfd_frequency_hz,
                    "motor_running": station.motor_running,
                },
            },
        )
        .execute()
    )

    logger.info(
        f"COMMAND {station.device_id}: {command['command_type']} -> {outcome}"
        + (f" ({reason})" if reason else "")
    )


def generate_telemetry(station: StationRuntime) -> list[dict]:
    # Three-phase voltage/current + temperature + vibration + speed + VFD frequency.
    # These are plausible demo ranges, not measurements from real equipment.
    load_factor = max(station.vfd_frequency_hz / 50.0, 0.05) if station.motor_running else 0.05

    speed = (
        max(0.0, station.vfd_frequency_hz / 50.0 * 1500.0 + random.uniform(-12, 12))
        if station.motor_running
        else 0.0
    )
    station.motor_speed_rpm = speed

    base_current = 7.0 * load_factor if station.motor_running else 0.25

    return [
        {"name": "voltage_l1", "unit": "V", "category": "electrical", "value": round(random.uniform(226, 234), 2)},
        {"name": "voltage_l2", "unit": "V", "category": "electrical", "value": round(random.uniform(226, 234), 2)},
        {"name": "voltage_l3", "unit": "V", "category": "electrical", "value": round(random.uniform(226, 234), 2)},
        {"name": "current_l1", "unit": "A", "category": "electrical", "value": round(max(0, random.gauss(base_current, 0.25)), 2)},
        {"name": "current_l2", "unit": "A", "category": "electrical", "value": round(max(0, random.gauss(base_current, 0.25)), 2)},
        {"name": "current_l3", "unit": "A", "category": "electrical", "value": round(max(0, random.gauss(base_current, 0.25)), 2)},
        {"name": "temperature", "unit": "C", "category": "condition", "value": round(random.uniform(24, 46) + load_factor * 5, 2)},
        {"name": "vibration", "unit": "mm/s", "category": "condition", "value": round(random.uniform(0.2, 2.5) * (1 + load_factor), 3)},
        {"name": "motor_speed", "unit": "rpm", "category": "motion", "value": round(speed, 1)},
        {"name": "vfd_frequency", "unit": "Hz", "category": "vfd", "value": round(station.vfd_frequency_hz, 2)},
    ]


def send_station_packet(station: StationRuntime) -> None:
    measured_at = datetime.now(timezone.utc).isoformat()
    telemetry = generate_telemetry(station)

    (
        supabase.rpc(
            "ingest_station_packet",
            {
                "p_device_id": station.device_id,
                "p_device_key": station.device_key,
                "p_measured_at": measured_at,
                "p_telemetry": telemetry,
                "p_state": {
                    "safety_ok": station.safety_ok,
                    "vfd_state": station.vfd_state,
                    "vfd_frequency_hz": station.vfd_frequency_hz,
                    "motor_running": station.motor_running,
                    "motor_speed_rpm": station.motor_speed_rpm,
                    "fault_code": station.fault_code,
                },
            },
        )
        .execute()
    )

    # Successful telemetry packets are intentionally not logged because they
    # are high-volume and do not represent an actionable event.


def run_cycle(stations: list[StationRuntime]) -> None:
    for station in stations:
        try:
            pull_and_process_command(station)
            maybe_create_fault(station)
            send_station_packet(station)
        except Exception:
            logger.exception("ERROR [%s]", station.device_id)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run UNO Q station simulators")
    parser.add_argument("--once", action="store_true", help="send one telemetry cycle and exit")
    args = parser.parse_args()
    stations = build_stations(STATION_COUNT)

    logger.info(
        f"Starting {len(stations)} UNO Q station simulators, "
        f"interval={SEND_INTERVAL_SECONDS}s"
    )

    if args.once:
        run_cycle(stations)
        return

    while True:
        cycle_started = time.monotonic()

        run_cycle(stations)

        elapsed = time.monotonic() - cycle_started
        time.sleep(max(0.0, SEND_INTERVAL_SECONDS - elapsed))


if __name__ == "__main__":
    main()
