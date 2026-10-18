import importlib.util
import io
import json
from pathlib import Path
import shlex
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("claude_quota_bridge", Path(__file__).resolve().parents[1] / "scripts/claude_quota_bridge.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class QuotaBridgeTests(unittest.TestCase):
    def test_only_quota_counters_are_retained(self):
        record = bridge.quota_record({"cwd": "/fixture/project", "session_id": "synthetic",
            "rate_limits": {"five_hour": {"used_percentage": 23.5, "resets_at": 1800000000, "extra": "fixture"},
                            "seven_day": {"used_percentage": 42, "resets_at": 1800500000}}}, now=1799900000)
        self.assertEqual(set(record), {"observed_at", "rate_limits"})
        self.assertEqual(record["rate_limits"]["five_hour"], {"used_percentage": 23.5, "resets_at": 1800000000})
        self.assertNotIn("fixture", json.dumps(record))

    def test_absent_or_invalid_windows_remain_unknown(self):
        self.assertEqual(bridge.quota_record({})["rate_limits"], {})
        self.assertEqual(bridge.quota_record({"rate_limits": {"five_hour": {"used_percentage": True, "resets_at": 1800000000}}})["rate_limits"], {})
        self.assertEqual(bridge.quota_record({"rate_limits": {"seven_day": {"used_percentage": float("inf"), "resets_at": 1800000000}}})["rate_limits"], {})

    def test_connection_preserves_existing_command_and_restores_it(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            config = root / "claude"
            config.mkdir()
            settings = {"permissions": {"allow": ["Read"]}, "statusLine": {"type": "command", "command": "printf 'existing output'", "padding": 2}}
            path = config / "settings.json"
            path.write_text(json.dumps(settings))
            with patch.object(bridge, "CACHE_ROOT", root / "cache"):
                bridge.configure(config)
                connected = json.loads(path.read_text())
                self.assertEqual(connected["permissions"], settings["permissions"])
                self.assertEqual(connected["statusLine"]["padding"], 2)
                self.assertIn("--forward", connected["statusLine"]["command"])
                bridge.configure(config)
                bridge.configure(config, disconnect=True)
                self.assertEqual(json.loads(path.read_text()), settings)

    def test_disconnect_preserves_later_user_changes(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            config = root / "claude"
            config.mkdir()
            with patch.object(bridge, "CACHE_ROOT", root / "cache"):
                bridge.configure(config)
                path = config / "settings.json"
                later = {"statusLine": {"type": "command", "command": "printf 'new output'"}}
                path.write_text(json.dumps(later))
                with self.assertRaises(ValueError):
                    bridge.configure(config, disconnect=True)
                self.assertEqual(json.loads(path.read_text()), later)

    def test_forwarded_input_and_output_are_unchanged(self):
        with tempfile.TemporaryDirectory() as name:
            cache = Path(name)
            raw = b'{"session_id":"synthetic", "rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1800000000}}}\n'
            output = io.BytesIO()
            command = shlex.quote(sys.executable) + " -c " + shlex.quote("import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())")
            with patch.object(bridge, "CACHE_ROOT", cache), patch.object(bridge.sys, "stdout", SimpleNamespace(buffer=output)):
                bridge.receive(raw, forward=command)
            self.assertEqual(output.getvalue(), raw)
            saved = cache / "claude-quota.json"
            self.assertNotIn("session_id", saved.read_text())
            self.assertEqual(saved.stat().st_mode & 0o777, 0o600)

    def test_pre_response_payload_keeps_previous_observation(self):
        with tempfile.TemporaryDirectory() as name:
            cache = Path(name)
            saved = cache / "claude-quota.json"
            previous = bridge.quota_record({"rate_limits": {"five_hour": {"used_percentage": 12, "resets_at": 1800000000}}}, now=1799990000)
            bridge.atomic_json(saved, previous)
            with patch.object(bridge, "CACHE_ROOT", cache), patch.object(bridge.sys, "stdout", io.StringIO()):
                bridge.receive(b'{"session_id":"synthetic"}')
                self.assertEqual(json.loads(saved.read_text()), previous)
                bridge.receive(b'{"rate_limits":{}}')
                self.assertEqual(json.loads(saved.read_text())["rate_limits"], {})
