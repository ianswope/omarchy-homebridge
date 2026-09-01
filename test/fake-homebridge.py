#!/usr/bin/env python3
"""A stand-in for homebridge-config-ui-x, just large enough to exercise the
three bash helpers end to end: python3 test/fake-homebridge.py [port]

It speaks the three routes the plugin uses and nothing else —

  POST /api/auth/login          username/password  ->  {access_token, expires_in}
  GET  /api/accessories         Bearer token       ->  the accessory list
  PUT  /api/accessories/{id}    {characteristicType, value}

— and keeps accessory state in memory, so a PUT from omarchy-homebridge-set is
visible in the next poll from omarchy-homebridge-status. That round trip is the
whole point: it is the one thing the helpers cannot be trusted about until they
have actually done it.

Two extra routes exist only for the test and have no counterpart on a real
server: /_control/expire invalidates every issued token, so the 401-and-retry
path can be reached on purpose rather than waited for, and /_control/stats
reports how many logins and PUTs arrived, which is how the test tells a cached
token from one fetched again.
"""

import base64
import json
import os
import secrets
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USERNAME = os.environ.get("FAKE_HB_USER", "omarchy-bar")
PASSWORD = os.environ.get("FAKE_HB_PASS", "correct horse battery staple")

# config-ui-x shape, chosen so every branch of the status helper's jq reduction
# is taken by something: a dimmable light, a plain outlet, an On reported as 1
# rather than true, a light whose Brightness cannot be written, an On that is
# read-only, a security system that declares only three of the four modes,
# every class of sensor, and the camera plumbing a real bridge is full of and
# this plugin must leave out.
ACCESSORIES = [
    {
        "uniqueId": "a1b2c3d4e5",
        "type": "Lightbulb", "humanType": "Lightbulb", "serviceName": "Desk Lamp",
        "serviceCharacteristics": [
            {"type": "On", "value": True, "canRead": True, "canWrite": True},
            {"type": "Brightness", "value": 40, "canRead": True, "canWrite": True},
        ],
    },
    {
        "uniqueId": "ff00ff00ff",
        "type": "Outlet", "humanType": "Outlet", "serviceName": "Kettle",
        "serviceCharacteristics": [
            {"type": "On", "value": False, "canRead": True, "canWrite": True},
        ],
    },
    {
        "uniqueId": "5e0509a1b2",
        "type": "TemperatureSensor", "humanType": "Temperature Sensor",
        "serviceName": "Hallway Temp",
        "serviceCharacteristics": [
            {"type": "CurrentTemperature", "value": 21.5, "canRead": True, "canWrite": False},
        ],
    },
    {
        "uniqueId": "d00rb3114a",
        "type": "Switch", "humanType": "Switch", "serviceName": "Doorbell",
        "serviceCharacteristics": [
            {"type": "On", "value": True, "canRead": True, "canWrite": False},
        ],
    },
    {
        "uniqueId": "fa0fa0fa01",
        "type": "Fan", "humanType": "Fan", "serviceName": "Ceiling Fan",
        "serviceCharacteristics": [
            {"type": "On", "value": 1, "canRead": True, "canWrite": True},
            {"type": "RotationSpeed", "value": 50, "canRead": True, "canWrite": True},
        ],
    },
    {
        "uniqueId": "p0rch11ght",
        "type": "Lightbulb", "humanType": "Lightbulb", "serviceName": "Porch Light",
        "serviceCharacteristics": [
            {"type": "On", "value": False, "canRead": True, "canWrite": True},
            {"type": "Brightness", "value": 80, "canRead": True, "canWrite": False},
        ],
    },
    {
        # Mirrors a SimpliSafe bridge: it declares [0, 1, 3] and has no Night
        # mode at all, so a panel offering a hardcoded four would offer one the
        # server is bound to refuse.
        "uniqueId": "5ecur17y01",
        "type": "SecuritySystem", "humanType": "Security System",
        "serviceName": "Alarm",
        "serviceCharacteristics": [
            {"type": "SecuritySystemCurrentState", "value": 3, "canRead": True, "canWrite": False,
             "validValues": [0, 1, 3, 4]},
            {"type": "SecuritySystemTargetState", "value": 3, "canRead": True, "canWrite": True,
             "validValues": [0, 1, 3]},
            {"type": "StatusFault", "value": 0, "canRead": True, "canWrite": False},
            {"type": "StatusTampered", "value": 0, "canRead": True, "canWrite": False},
        ],
    },
    {
        "uniqueId": "c0n7ac7001",
        "type": "ContactSensor", "humanType": "Contact Sensor", "serviceName": "Front Door",
        "serviceCharacteristics": [
            # 0 is CONTACT_DETECTED, which is a door that is shut. The least
            # intuitive value in HomeKit, and the one a panel reads backwards.
            {"type": "ContactSensorState", "value": 0, "canRead": True, "canWrite": False},
            {"type": "StatusLowBattery", "value": 1, "canRead": True, "canWrite": False},
        ],
    },
    {
        "uniqueId": "c0n7ac7002",
        "type": "ContactSensor", "humanType": "Contact Sensor", "serviceName": "Garage",
        "serviceCharacteristics": [
            {"type": "ContactSensorState", "value": 1, "canRead": True, "canWrite": False},
            {"type": "StatusLowBattery", "value": 0, "canRead": True, "canWrite": False},
        ],
    },
    {
        "uniqueId": "m0710n0001",
        "type": "MotionSensor", "humanType": "Motion Sensor", "serviceName": "Hallway",
        "serviceCharacteristics": [
            {"type": "MotionDetected", "value": True, "canRead": True, "canWrite": False},
        ],
    },
    {
        # Carries a temperature too, so the reading-priority order is exercised:
        # a smoke sensor is a smoke sensor, not a thermometer.
        "uniqueId": "5m0ke00001",
        "type": "SmokeSensor", "humanType": "Smoke Sensor", "serviceName": "Kitchen",
        "serviceCharacteristics": [
            {"type": "CurrentTemperature", "value": 19.5, "canRead": True, "canWrite": False},
            {"type": "SmokeDetected", "value": 0, "canRead": True, "canWrite": False},
            {"type": "StatusLowBattery", "value": 0, "canRead": True, "canWrite": False},
        ],
    },
    {
        "uniqueId": "7hermo0001",
        "type": "TemperatureSensor", "humanType": "Temperature Sensor", "serviceName": "Nursery",
        "serviceCharacteristics": [
            {"type": "CurrentTemperature", "value": 21.5, "canRead": True, "canWrite": False},
        ],
    },
    {
        # Camera plumbing: writable, and entirely beside the point. A bridge with
        # four cameras carries eight of these and would bury the real rows.
        "uniqueId": "camera0001",
        "type": "CameraRTPStreamManagement", "humanType": "Camera Rtp Stream Management",
        "serviceName": "Driveway",
        "serviceCharacteristics": [
            {"type": "Active", "value": 1, "canRead": True, "canWrite": True},
            {"type": "StreamingStatus", "value": 0, "canRead": True, "canWrite": False},
        ],
    },
    {
        "uniqueId": "m1cr0ph01",
        "type": "Microphone", "humanType": "Microphone", "serviceName": "Driveway",
        "serviceCharacteristics": [
            {"type": "Mute", "value": False, "canRead": True, "canWrite": True},
            {"type": "Volume", "value": 100, "canRead": True, "canWrite": True},
        ],
    },
    {
        # Stateless: it fires an event, it does not hold a reading.
        "uniqueId": "d00rbe1101",
        "type": "Doorbell", "humanType": "Doorbell", "serviceName": "Front Door",
        "serviceCharacteristics": [
            {"type": "ProgrammableSwitchEvent", "value": None, "canRead": True, "canWrite": False},
        ],
    },
]

state = {
    "accessories": json.loads(json.dumps(ACCESSORIES)),
    "tokens": set(),
    "logins": 0,
    "puts": 0,
}
lock = threading.Lock()


def make_token():
    """JWT-shaped, because the helpers refuse anything that is not before it
    reaches an Authorization header."""
    def seg(obj):
        raw = json.dumps(obj, separators=(",", ":")).encode()
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()
    return ".".join([
        seg({"alg": "HS256", "typ": "JWT"}),
        seg({"username": USERNAME, "admin": False}),
        secrets.token_urlsafe(24).rstrip("="),
    ])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode())
        except Exception:
            return {}

    def _authed(self):
        header = self.headers.get("Authorization") or ""
        if not header.startswith("Bearer "):
            return False
        with lock:
            return header[7:] in state["tokens"]

    def do_POST(self):
        if self.path == "/_control/expire":
            with lock:
                state["tokens"].clear()
            return self._send(200, {"expired": True})

        # Let every security system finish arming, so the test can look at the
        # in-between state on purpose and then move past it.
        if self.path == "/_control/settle":
            with lock:
                for acc in state["accessories"]:
                    chars = acc["serviceCharacteristics"]
                    tgt = next((c for c in chars if c["type"] == "SecuritySystemTargetState"), None)
                    cur = next((c for c in chars if c["type"] == "SecuritySystemCurrentState"), None)
                    if tgt is not None and cur is not None:
                        cur["value"] = tgt["value"]
            return self._send(200, {"settled": True})

        if self.path != "/api/auth/login":
            return self._send(404, {"message": "Not found"})

        body = self._body()
        with lock:
            state["logins"] += 1
        if body.get("username") != USERNAME or body.get("password") != PASSWORD:
            return self._send(401, {"message": "Unauthorized"})
        token = make_token()
        with lock:
            state["tokens"].add(token)
        self._send(201, {"access_token": token, "token_type": "Bearer", "expires_in": 28800})

    def do_GET(self):
        if self.path == "/_control/stats":
            with lock:
                return self._send(200, {"logins": state["logins"], "puts": state["puts"]})
        if self.path != "/api/accessories":
            return self._send(404, {"message": "Not found"})
        if not self._authed():
            return self._send(401, {"message": "Unauthorized"})
        with lock:
            return self._send(200, state["accessories"])

    def do_PUT(self):
        prefix = "/api/accessories/"
        if not self.path.startswith(prefix):
            return self._send(404, {"message": "Not found"})
        if not self._authed():
            return self._send(401, {"message": "Unauthorized"})

        unique_id = self.path[len(prefix):]
        body = self._body()
        char_type = body.get("characteristicType")
        value = body.get("value")
        with lock:
            state["puts"] += 1
            target = next((a for a in state["accessories"] if a["uniqueId"] == unique_id), None)
            if target is None:
                return self._send(404, {"message": "Accessory not found"})
            char = next((c for c in target["serviceCharacteristics"] if c["type"] == char_type), None)
            if char is None or not char.get("canWrite"):
                return self._send(400, {"message": "Characteristic not writable"})
            valid = char.get("validValues")
            if valid is not None and value not in valid:
                # What a real bridge does when asked for a mode the panel on the
                # wall does not have a button for.
                return self._send(400, {"message": "Value not in validValues"})
            char["value"] = value
            # Arming takes time on a real system: the target moves at once, the
            # current state follows when the house is actually secured. The test
            # settles it explicitly through /_control/settle.
            # A real bulb lights up when its brightness is raised, and the panel
            # counts on that: setBrightness sends Brightness alone and expects
            # the light to be on next poll.
            if char_type == "Brightness":
                on = next((c for c in target["serviceCharacteristics"] if c["type"] == "On"), None)
                if on is not None:
                    on["value"] = bool(value)
        self._send(200, {})


class QuietServer(ThreadingHTTPServer):
    """A client that hangs up mid-request is curl finishing, not a fault worth a
    traceback in the middle of the test output."""
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = QuietServer(("127.0.0.1", port), Handler)
    # The test needs the port before it can build a config, and 0 means the
    # kernel picked it, so say which one out loud.
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
