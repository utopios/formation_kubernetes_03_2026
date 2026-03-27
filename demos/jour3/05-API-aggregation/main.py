"""
Weather API Server — Serveur d'API agrégé pour Kubernetes (Python)

Ce serveur implémente les endpoints nécessaires pour être
reconnu comme un API server Kubernetes valide :
- /apis                              → Discovery des groupes
- /apis/weather.example.com          → Discovery du groupe
- /apis/weather.example.com/v1alpha1 → Discovery des ressources
- /apis/weather.example.com/v1alpha1/weathers        → LIST
- /apis/weather.example.com/v1alpha1/weathers/{name} → GET
- /healthz et /readyz                → Health checks
"""

import json
import logging
import math
import os
import random
import ssl
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Optional

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)

API_GROUP = "weather.example.com"
API_VERSION = "v1alpha1"
CERT_FILE = os.environ.get("CERT_FILE", "/certs/tls.crt")
KEY_FILE = os.environ.get("KEY_FILE", "/certs/tls.key")
PORT = int(os.environ.get("PORT", 8443))


# ---- Modèles de données ----

@dataclass
class ObjectMeta:
    name: str
    creationTimestamp: str
    labels: dict = field(default_factory=dict)


@dataclass
class WeatherSpec:
    country: str
    latitude: float
    longitude: float


@dataclass
class WeatherStatus:
    temperature: float
    humidity: int
    condition: str
    windSpeedKmh: float
    updatedAt: str


@dataclass
class Weather:
    apiVersion: str
    kind: str
    metadata: ObjectMeta
    spec: WeatherSpec
    status: WeatherStatus

    def to_dict(self):
        return {
            "apiVersion": self.apiVersion,
            "kind": self.kind,
            "metadata": asdict(self.metadata),
            "spec": asdict(self.spec),
            "status": asdict(self.status),
        }


@dataclass
class ListMeta:
    resourceVersion: str


@dataclass
class WeatherList:
    apiVersion: str
    kind: str
    metadata: ListMeta
    items: list

    def to_dict(self):
        return {
            "apiVersion": self.apiVersion,
            "kind": self.kind,
            "metadata": asdict(self.metadata),
            "items": [w.to_dict() for w in self.items],
        }


# ---- Données simulées des villes ----

CITIES = {
    "paris":     {"country": "France",    "lat": 48.8566,  "lon":   2.3522,  "temp_base": 15, "condition": "Cloudy"},
    "lyon":      {"country": "France",    "lat": 45.7640,  "lon":   4.8357,  "temp_base": 16, "condition": "Sunny"},
    "london":    {"country": "UK",        "lat": 51.5074,  "lon":  -0.1278,  "temp_base": 12, "condition": "Rainy"},
    "berlin":    {"country": "Germany",   "lat": 52.5200,  "lon":  13.4050,  "temp_base": 11, "condition": "Cloudy"},
    "tokyo":     {"country": "Japan",     "lat": 35.6762,  "lon": 139.6503,  "temp_base": 18, "condition": "Sunny"},
    "new-york":  {"country": "USA",       "lat": 40.7128,  "lon": -74.0060,  "temp_base": 14, "condition": "Partly Cloudy"},
    "sydney":    {"country": "Australia", "lat": -33.8688, "lon": 151.2093,  "temp_base": 22, "condition": "Sunny"},
    "moscow":    {"country": "Russia",    "lat": 55.7558,  "lon":  37.6173,  "temp_base":  3, "condition": "Snowy"},
    "marrakech": {"country": "Morocco",   "lat": 31.6295,  "lon":  -7.9811,  "temp_base": 28, "condition": "Sunny"},
    "mumbai":    {"country": "India",     "lat": 19.0760,  "lon":  72.8777,  "temp_base": 30, "condition": "Humid"},
}


def generate_weather(name: str, city: dict) -> Weather:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    temp = city["temp_base"] + (random.random() * 6 - 3)          # ±3°C
    humidity = random.randint(40, 80)                               # 40-80%
    wind = 5 + random.random() * 30                                 # 5-35 km/h

    return Weather(
        apiVersion=f"{API_GROUP}/{API_VERSION}",
        kind="Weather",
        metadata=ObjectMeta(
            name=name,
            creationTimestamp=now,
            labels={
                "country": city["country"].lower(),
                "source":  "weather-apiserver",
            },
        ),
        spec=WeatherSpec(
            country=city["country"],
            latitude=city["lat"],
            longitude=city["lon"],
        ),
        status=WeatherStatus(
            temperature=round(temp, 1),
            humidity=humidity,
            condition=city["condition"],
            windSpeedKmh=round(wind, 1),
            updatedAt=now,
        ),
    )


# ---- Handler HTTP ----

class WeatherHandler(BaseHTTPRequestHandler):
    """Handles all incoming HTTP requests."""

    # Silence default access log — we do our own
    def log_message(self, fmt, *args):
        pass

    def _send_json(self, data: dict, status: int = 200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]  # ignore query params

        weathers_prefix = f"/apis/{API_GROUP}/{API_VERSION}/weathers/"
        weathers_list   = f"/apis/{API_GROUP}/{API_VERSION}/weathers"
        resource_disc   = f"/apis/{API_GROUP}/{API_VERSION}"
        group_disc      = f"/apis/{API_GROUP}"

        if path in ("/healthz", "/readyz"):
            log.info("[Health] GET %s", path)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")

        elif path in ("/apis", group_disc):
            log.info("[Discovery] GET %s", path)
            self._send_json(self._discovery_response())

        elif path == resource_disc:
            log.info("[ResourceDiscovery] GET %s", path)
            self._send_json(self._resource_discovery_response())

        elif path == weathers_list:
            log.info("[List] GET %s", path)
            self._send_json(self._weather_list_response())

        elif path.startswith(weathers_prefix):
            name = path[len(weathers_prefix):]
            log.info("[Get] GET %s (city=%s)", path, name)
            self._handle_weather_get(name)

        else:
            log.warning("[404] GET %s", path)
            self.send_response(404)
            self.end_headers()

    # Kubernetes also issues HEAD requests on health endpoints
    def do_HEAD(self):
        path = self.path.split("?")[0]
        if path in ("/healthz", "/readyz"):
            self.send_response(200)
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    # ---- Response builders ----

    def _discovery_response(self) -> dict:
        return {
            "kind": "APIGroup",
            "apiVersion": "v1",
            "name": API_GROUP,
            "versions": [
                {
                    "groupVersion": f"{API_GROUP}/{API_VERSION}",
                    "version": API_VERSION,
                }
            ],
            "preferredVersion": {
                "groupVersion": f"{API_GROUP}/{API_VERSION}",
                "version": API_VERSION,
            },
        }

    def _resource_discovery_response(self) -> dict:
        return {
            "kind": "APIResourceList",
            "apiVersion": "v1",
            "groupVersion": f"{API_GROUP}/{API_VERSION}",
            "resources": [
                {
                    "name": "weathers",
                    "singularName": "weather",
                    "namespaced": False,
                    "kind": "Weather",
                    "verbs": ["get", "list"],
                    "shortNames": ["wt"],
                }
            ],
        }

    def _weather_list_response(self) -> dict:
        items = [generate_weather(name, city) for name, city in CITIES.items()]
        return WeatherList(
            apiVersion=f"{API_GROUP}/{API_VERSION}",
            kind="WeatherList",
            metadata=ListMeta(resourceVersion=str(int(time.time()))),
            items=items,
        ).to_dict()

    def _handle_weather_get(self, name: str):
        if name not in CITIES:
            self._send_json(
                {
                    "kind": "Status",
                    "apiVersion": "v1",
                    "metadata": {},
                    "status": "Failure",
                    "message": f'weathers "{name}" not found',
                    "reason": "NotFound",
                    "code": 404,
                },
                status=404,
            )
            return
        weather = generate_weather(name, CITIES[name])
        self._send_json(weather.to_dict())


# ---- Point d'entrée ----

def main():
    log.info("=== Weather API Server (Python) ===")
    log.info("Groupe API : %s/%s", API_GROUP, API_VERSION)

    server = HTTPServer(("", PORT), WeatherHandler)

    if os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(certfile=CERT_FILE, keyfile=KEY_FILE)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        log.info("Démarrage sur :%d (HTTPS)", PORT)
    else:
        log.warning(
            "Certificats TLS introuvables (%s / %s) — démarrage en HTTP sur :%d",
            CERT_FILE, KEY_FILE, PORT,
        )

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Arrêt du serveur.")
        server.server_close()


if __name__ == "__main__":
    main()
