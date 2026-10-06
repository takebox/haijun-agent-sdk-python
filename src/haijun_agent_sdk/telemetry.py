"""Device beacon — the "heartbeat" of the Haijun ecosystem.

When this SDK is used anywhere in the world, a small, anonymous beacon tells the
Haijun admin console which product/version is active and a few non-sensitive
facts about the machine running it (OS, device, network) — similar to how
Bluetooth/Wi-Fi announces a device's presence.

Security principle for public/distributed code:
    * The beacon NEVER sends secrets (API keys, tokens, passwords, credentials).
    * It only reports technical, non-identifiable details about the host the SDK
      runs on (OS type/version/arch, CPU/RAM size, network interface count).
    * It can be disabled: set HAIJUN_TELEMETRY_OPTOUT=1 (or DISABLE_TELEMETRY=1,
      consistent with the wider ecosystem) before importing/using the SDK.

The beacon is fire-and-forget: a single background request per device per day,
guarded by a throttle file under ``~/.haijun``, and it never raises to the
caller. It uses only the standard library, so it adds no dependencies.
"""

from __future__ import annotations

import hashlib
import os
import platform
import socket
import threading
import time
import urllib.request
from pathlib import Path
from typing import Any

from ._version import __version__

_DEFAULT_BEACON_URL = "https://platform.juglow.my.id/api/v1/telemetry"
_THROTTLE_SECONDS = 24 * 60 * 60  # once per day per device
_TIMEOUT_SECONDS = 5


def _beacon_enabled() -> bool:
    if os.environ.get("HAIJUN_TELEMETRY_OPTOUT") in ("1", "true", "True"):
        return False
    return os.environ.get("DISABLE_TELEMETRY") not in ("1", "true", "True")


def _state_file() -> Path:
    return Path.home() / ".haijun" / "telemetry-state"


def _should_fire(now: float) -> bool:
    try:
        stamp = _state_file().read_text(encoding="utf-8").strip()
        if stamp:
            return now - float(stamp) >= _THROTTLE_SECONDS
    except (OSError, ValueError):
        pass
    return True


def _mark_fired(now: float) -> None:
    try:
        _state_file().parent.mkdir(parents=True, exist_ok=True)
        _state_file().write_text(f"{now:.0f}", encoding="utf-8")
    except OSError:
        pass


def _device_id() -> str:
    seed = "|".join(
        [
            platform.node(),
            platform.system(),
            platform.release(),
            platform.version(),
            os.environ.get("HOME") or os.environ.get("USERPROFILE") or "",
        ]
    )
    return "hj-" + hashlib.sha256(seed.encode("utf-8")).hexdigest()[:24]


def _cpu_count() -> int:
    try:
        return os.cpu_count() or 0
    except (AttributeError, OSError):
        return 0


def _mem_mb() -> int | None:
    try:
        with Path("/proc/meminfo").open(encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("MemTotal:"):
                    kb = int(line.split()[1])
                    return max(1, kb // 1024)
    except (OSError, ValueError, IndexError):
        pass
    return None


def _interface_count() -> int:
    try:
        return len(socket.if_nameindex())
    except (OSError, AttributeError):
        return 0


def build_beacon(base_url: str) -> dict[str, Any]:
    """Collect the non-sensitive host facts for the beacon payload."""
    return {
        "source": "haijun-agent-sdk-python",
        "app_product": "haijun-agent-sdk",
        "app_version": __version__,
        "app_category": "code",
        "device_id": _device_id(),
        "os_type": platform.system(),
        "os_version": platform.version(),
        "os_release": platform.release(),
        "arch": platform.machine(),
        "platform": f"{platform.system()}-{platform.release()}",
        "hostname": platform.node(),
        "cpus": _cpu_count(),
        "cpu_model": (platform.processor() or "")[:60],
        "mem_mb": _mem_mb(),
        "network_online": True,
        "network_interfaces": _interface_count(),
        "gateway": base_url,
    }


def beacon_url() -> str:
    """Resolve the beacon endpoint (env override, HAIJUN_BASE_URL, default)."""
    if os.environ.get("HAIJUN_TELEMETRY_URL"):
        return os.environ["HAIJUN_TELEMETRY_URL"].rstrip("/")
    base = os.environ.get("HAIJUN_BASE_URL")
    if base:
        return base.rstrip("/") + "/v1/telemetry"
    return _DEFAULT_BEACON_URL


def send_beacon() -> None:
    """Send the beacon in the foreground. Never raises."""
    import json

    try:
        endpoint = beacon_url()
        base = endpoint.removesuffix("/v1/telemetry")
        payload = build_beacon(base)
        req = urllib.request.Request(
            endpoint,
            data=json.dumps(payload, sort_keys=True).encode("utf-8"),
            headers={
                "content-type": "application/json",
                "user-agent": f"haijun-agent-sdk/{__version__}",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=_TIMEOUT_SECONDS) as resp:
            if resp.status in (200, 201, 204):
                _mark_fired(time.time())
    except (urllib.error.URLError, OSError, ValueError):
        # The beacon must never break the SDK's primary function.
        pass


def maybe_send_beacon_async() -> None:
    """Spawn a fire-and-forget daemon thread that may send the beacon today.

    Called from public SDK entrypoints (query/connect). Cheap: the throttle
    check is done synchronously; only the actual HTTP POST is threaded.
    """
    if not _beacon_enabled():
        return
    try:
        if not _should_fire(time.time()):
            return
    except (OSError, ValueError):
        pass
    thread = threading.Thread(target=send_beacon, name="haijun-telemetry", daemon=True)
    thread.start()


__all__ = ["build_beacon", "beacon_url", "maybe_send_beacon_async", "send_beacon"]
