#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <time.h>

// Fill these values locally before uploading the sketch.
const char* WIFI_SSID = "YOUR_WIFI_SSID";
const char* WIFI_PASSWORD = "YOUR_WIFI_PASSWORD";

const char* SUPABASE_URL = "https://YOUR_PROJECT_REF.supabase.co";
const char* SUPABASE_KEY = "YOUR_SUPABASE_PUBLISHABLE_KEY";

// These values must match the device credential registered in Supabase.
const char* DEVICE_ID = "esp32-001";
const char* DEVICE_KEY = "demo-station-011-key";

const int TRIG_PIN = 5;
const int ECHO_PIN = 18;
const unsigned long MEASUREMENT_INTERVAL_MS = 1000;
const size_t BATCH_SIZE = 10;

float distanceBatch[BATCH_SIZE];
size_t distanceBatchCount = 0;
unsigned long lastMeasurementAt = 0;

void connectWiFi() {
  if (WiFi.status() == WL_CONNECTED) {
    return;
  }

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  Serial.print("Connecting to Wi-Fi");
  const unsigned long startedAt = millis();

  while (WiFi.status() != WL_CONNECTED && millis() - startedAt < 30000) {
    delay(500);
    Serial.print(".");
  }

  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("Wi-Fi connected, IP: ");
    Serial.println(WiFi.localIP());
  } else {
    Serial.println("Wi-Fi connection failed");
  }
}

bool syncTime() {
  configTime(0, 0, "pool.ntp.org", "time.nist.gov");

  struct tm timeInfo;
  Serial.print("Synchronizing time");

  for (int attempt = 0; attempt < 20; attempt++) {
    if (getLocalTime(&timeInfo)) {
      Serial.println(" OK");
      return true;
    }

    delay(500);
    Serial.print(".");
  }

  Serial.println(" FAILED");
  return false;
}

String isoTimestamp() {
  struct tm timeInfo;

  if (!getLocalTime(&timeInfo)) {
    return "";
  }

  char buffer[25];
  strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &timeInfo);
  return String(buffer);
}

float readDistanceCm() {
  digitalWrite(TRIG_PIN, LOW);
  delayMicroseconds(2);

  digitalWrite(TRIG_PIN, HIGH);
  delayMicroseconds(10);
  digitalWrite(TRIG_PIN, LOW);

  const unsigned long duration = pulseIn(ECHO_PIN, HIGH, 30000);

  if (duration == 0) {
    return -1.0f;
  }

  return duration * 0.0343f / 2.0f;
}

bool sendDistanceBatchToSupabase(const float* distances, size_t count) {
  if (WiFi.status() != WL_CONNECTED) {
    connectWiFi();
  }

  if (WiFi.status() != WL_CONNECTED) {
    return false;
  }

  const String measuredAt = isoTimestamp();
  if (measuredAt.length() == 0) {
    Serial.println("No valid timestamp");
    return false;
  }

  StaticJsonDocument<3072> request;
  request["p_device_id"] = DEVICE_ID;
  request["p_device_key"] = DEVICE_KEY;
  request["p_measured_at"] = measuredAt;

  JsonArray telemetry = request.createNestedArray("p_telemetry");

  for (size_t index = 0; index < count; index++) {
    JsonObject distanceReading = telemetry.createNestedObject();
    distanceReading["name"] = "distance";
    distanceReading["unit"] = "cm";
    distanceReading["category"] = "condition";
    distanceReading["value"] = distances[index];
  }

  JsonObject state = request.createNestedObject("p_state");
  state["safety_ok"] = true;
  state["vfd_state"] = "unknown";
  state["motor_running"] = false;
  state["fault_code"] = nullptr;

  String body;
  serializeJson(request, body);

  const String url = String(SUPABASE_URL) +
                     "/rest/v1/rpc/ingest_station_packet";

  HTTPClient http;
  if (!http.begin(url)) {
    Serial.println("HTTP initialization failed");
    return false;
  }

  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", SUPABASE_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_KEY);

  const int statusCode = http.POST(body);
  const String response = http.getString();

  Serial.print("Sent batch of ");
  Serial.print(count);
  Serial.println(" readings");
  Serial.print("HTTP status: ");
  Serial.println(statusCode);
  Serial.print("Response: ");
  Serial.println(response);

  http.end();
  return statusCode >= 200 && statusCode < 300;
}

void setup() {
  Serial.begin(115200);

  pinMode(TRIG_PIN, OUTPUT);
  pinMode(ECHO_PIN, INPUT);

  connectWiFi();
  if (WiFi.status() == WL_CONNECTED) {
    syncTime();
  }

  lastMeasurementAt = millis();
}

void loop() {
  if (millis() - lastMeasurementAt < MEASUREMENT_INTERVAL_MS) {
    delay(100);
    return;
  }

  lastMeasurementAt = millis();

  const float distanceCm = readDistanceCm();
  Serial.print("Distance: ");
  Serial.print(distanceCm);
  Serial.println(" cm");

  if (distanceCm >= 0) {
    distanceBatch[distanceBatchCount] = distanceCm;
    distanceBatchCount++;

    Serial.print("Batch: ");
    Serial.print(distanceBatchCount);
    Serial.print("/");
    Serial.println(BATCH_SIZE);

    if (distanceBatchCount == BATCH_SIZE) {
      sendDistanceBatchToSupabase(distanceBatch, distanceBatchCount);
      distanceBatchCount = 0;
    }
  } else {
    Serial.println("Sensor timeout; packet was not sent");
  }
}
