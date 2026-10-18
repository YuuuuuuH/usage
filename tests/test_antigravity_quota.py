import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("antigravity_quota", Path(__file__).resolve().parents[1] / "scripts/antigravity_quota.py")
quota = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quota)


class AntigravityQuotaTests(unittest.TestCase):
    def model(self, name="Gemini (High)", fraction=0.75):
        return {"label": name, "modelId": name, "quotaInfo": {"remainingFraction": fraction, "resetTime": "2026-10-25T15:54:26Z"}}

    def payload(self, models):
        return {"userStatus": {"email": "fixture@example.test", "name": "fixture-user", "cascadeModelConfigData": {"clientModelConfigs": models}}}

    def test_actual_fraction_units_and_private_fields(self):
        value = quota.quota_record(self.payload([self.model()]), now=1800000000)
        self.assertEqual(value["windows"][0]["used_percent"], 25)
        self.assertNotIn("fixture", json.dumps(value))
        self.assertEqual(len(value["account_key"]), 64)

    def test_unknown_quota_is_not_fabricated(self):
        models = [self.model(fraction=True), self.model(fraction=float("nan")), self.model(fraction=1.5), {"label": "unknown"}]
        self.assertEqual(quota.quota_record(self.payload(models))["windows"], [])
        model = self.model()
        model["quotaInfo"]["resetTime"] = "2026-10-25T15:54:26"
        self.assertEqual(quota.quota_record(self.payload([model]))["windows"], [])

    def test_zero_is_exhausted_and_models_remain_independent(self):
        models = [self.model("Gemini", 0), self.model("Claude", 0)]
        windows = quota.quota_record(self.payload(models))["windows"]
        self.assertEqual(len(windows), 2)
        self.assertEqual([w["used_percent"] for w in windows], [100, 100])
        self.assertEqual(len(quota.quota_record(self.payload(models + models))["windows"]), 2)

    def test_only_owned_antigravity_process_can_supply_token(self):
        rows = "501 12 /other/language_server --csrf_token fixture\n502 13 " + quota.EXECUTABLE + " --csrf_token other\n501 14 " + quota.EXECUTABLE + " --csrf_token=local-fixture --standalone"
        self.assertEqual(quota.discover_process(rows, 501), (14, "local-fixture"))
        with self.assertRaises(quota.QuotaUnavailable):
            quota.discover_process(rows, 503)

    def test_http_port_must_belong_to_validated_process(self):
        log = "listening on random port at 6000 for HTTPS\nlistening on random port at 6001 for HTTP\nlistening on random port at 6002 for HTTP"
        self.assertEqual(quota.http_port(log, "p14\nn127.0.0.1:6001\n"), 6001)
        with self.assertRaises(quota.QuotaUnavailable):
            quota.http_port(log, "n0.0.0.0:6002\nn127.0.0.1:6000\n")
