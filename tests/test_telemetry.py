"""Tests for the anonymous device beacon."""

from __future__ import annotations

from pathlib import Path

import pytest

from haijun_agent_sdk import telemetry


def test_beacon_payload_shape(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("HOME", raising=False)
    beacon = telemetry.build_beacon("https://platform.juglow.my.id/api")

    expected_keys = {
        "source",
        "app_product",
        "app_version",
        "app_category",
        "device_id",
        "os_type",
        "os_version",
        "os_release",
        "arch",
        "platform",
        "hostname",
        "cpus",
        "cpu_model",
        "mem_mb",
        "network_online",
        "network_interfaces",
        "gateway",
    }
    assert expected_keys <= set(beacon)
    assert beacon["source"] == "haijun-agent-sdk-python"
    assert beacon["app_product"] == "haijun-agent-sdk"
    assert beacon["app_version"] == telemetry.__version__
    assert beacon["app_category"] == "code"
    assert beacon["os_type"]  # runtime OS known
    assert beacon["gateway"] == "https://platform.juglow.my.id/api"


def test_beacon_url_override() -> None:
    assert telemetry.beacon_url() == "https://platform.juglow.my.id/api/v1/telemetry"


def test_beacon_url_respects_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HAIJUN_TELEMETRY_URL", "https://custom.example/beacon")
    assert telemetry.beacon_url() == "https://custom.example/beacon"

    monkeypatch.delenv("HAIJUN_TELEMETRY_URL")
    monkeypatch.setenv("HAIJUN_BASE_URL", "https://gate.example/api")
    assert telemetry.beacon_url() == "https://gate.example/api/v1/telemetry"


def test_beacon_optout(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("HAIJUN_TELEMETRY_OPTOUT", raising=False)
    monkeypatch.delenv("DISABLE_TELEMETRY", raising=False)
    assert telemetry._beacon_enabled()

    monkeypatch.setenv("HAIJUN_TELEMETRY_OPTOUT", "1")
    assert not telemetry._beacon_enabled()

    monkeypatch.setenv("HAIJUN_TELEMETRY_OPTOUT", "0")
    assert telemetry._beacon_enabled()

    monkeypatch.delenv("HAIJUN_TELEMETRY_OPTOUT")
    monkeypatch.setenv("DISABLE_TELEMETRY", "true")
    assert not telemetry._beacon_enabled()


def test_throttle_state_file(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr(telemetry, "_state_file", lambda: tmp_path / "state")

    assert telemetry._should_fire(1_000)
    telemetry._mark_fired(1_000)
    assert not telemetry._should_fire(1_000 + 3600)
    assert telemetry._should_fire(1_000 + telemetry._THROTTLE_SECONDS + 1)


def test_maybe_send_async_optout_does_not_spawn(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("DISABLE_TELEMETRY", "1")
    called: list[bool] = []

    def _fake_background() -> None:
        called.append(True)

    monkeypatch.setattr(telemetry, "send_beacon", lambda: None)
    monkeypatch.setattr(telemetry, "_beacon_enabled", lambda: False)
    monkeypatch.setattr("threading.Thread.start", _fake_background)
    telemetry.maybe_send_beacon_async()
    assert called == []


def test_device_id_stable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HOME", "/fake/home/stable")
    first = telemetry._device_id()
    second = telemetry._device_id()
    assert first == second
    assert first.startswith("hj-")
    assert len(first) == 27  # "hj-" + 24 hex
