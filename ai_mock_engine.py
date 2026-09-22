"""Optional mock AI data-flow exerciser.

This is NOT an AI model. It writes deterministic demo assessments so the
Supabase -> dashboard AI path can be tested before a real AI service exists.
It requires SUPABASE_SERVICE_ROLE_KEY because it represents a trusted backend.
"""

import os
import time
import argparse
from datetime import datetime, timezone

from dotenv import load_dotenv
from supabase import Client, create_client

from logging_config import configure_logging

load_dotenv()

logger = configure_logging("ai_mock_engine")

SUPABASE_URL = os.environ["SUPABASE_URL"]
SERVICE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "").strip()
INTERVAL_SECONDS = 30

if not SERVICE_KEY:
    raise RuntimeError("SUPABASE_SERVICE_ROLE_KEY is required for ai_mock_engine.py")

supabase: Client = create_client(SUPABASE_URL, SERVICE_KEY)


def latest_value(device_id: str, sensor_name: str) -> float | None:
    sensors = (
        supabase.table("sensors")
        .select("id")
        .eq("device_id", device_id)
        .eq("name", sensor_name)
        .limit(1)
        .execute()
        .data
        or []
    )
    if not sensors:
        return None

    rows = (
        supabase.table("sensor_readings")
        .select("value")
        .eq("sensor_id", sensors[0]["id"])
        .order("measured_at", desc=True)
        .limit(1)
        .execute()
        .data
        or []
    )
    return rows[0]["value"] if rows else None


def build_mock_assessment(device_id: str) -> dict:
    temperature = latest_value(device_id, "temperature")
    vibration = latest_value(device_id, "vibration")

    if temperature is None or vibration is None:
        diagnosis = "Insufficient recent telemetry"
        recommendation = "Wait for station measurements"
        explanation = "The mock engine needs temperature and vibration values."
    elif temperature > 48 or vibration > 4:
        diagnosis = "Condition requires review"
        recommendation = "Inspect temperature/vibration before continued operation"
        explanation = (
            f"Deterministic demo rule: temperature={temperature}, vibration={vibration}."
        )
    else:
        diagnosis = "No mock-rule anomaly detected"
        recommendation = "Continue monitoring"
        explanation = (
            f"Deterministic demo rule: temperature={temperature}, vibration={vibration}."
        )

    return {
        "device_id": device_id,
        "model_version": "mock-rules-v1",
        "diagnosis": diagnosis,
        "recommendation": recommendation,
        "explanation": explanation,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }


def run_cycle() -> None:
    devices = (
        supabase.table("devices")
        .select("device_id")
        .eq("enabled", True)
        .execute()
        .data
        or []
    )

    for device in devices:
        assessment = build_mock_assessment(device["device_id"])
        supabase.table("ai_assessments").insert(assessment).execute()
        logger.info("AI MOCK %s: %s", device["device_id"], assessment["diagnosis"])


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the deterministic AI assessment producer")
    parser.add_argument("--once", action="store_true", help="write one assessment cycle and exit")
    args = parser.parse_args()

    if args.once:
        run_cycle()
        return

    while True:
        run_cycle()
        time.sleep(INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
