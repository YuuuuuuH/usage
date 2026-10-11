"""Combined accounting keeps totals, costs, chronology, and identities intact."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import token_atlas as atlas
from collections import Counter


class AllSourcesTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        for name, value in {"HOME": self.root, "CODEX_HOME": self.root / ".codex",
                            "QODEX_HOME": self.root / ".qodex", "CACHE_ROOT": self.root / "cache",
                            "TOKENIZER_SEARCH_ROOTS": ()}.items():
            patcher = patch.object(atlas, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        sessions = self.root / ".codex/sessions"
        sessions.mkdir(parents=True)
        usage = {"input_tokens": 90, "cached_input_tokens": 50, "output_tokens": 10, "total_tokens": 100}
        rows = [atlas.synthetic_event("2024-01-01T00:00:00Z", "session_meta", {"id": "shared", "model_provider": "openai"}),
                atlas.synthetic_event("2024-01-01T00:00:01Z", "turn_context", {"turn_id": "turn", "model": "gpt-5.4-mini"}),
                atlas.synthetic_event("2024-01-01T00:00:02Z", "event_msg", {"type": "token_count", "info": {"total_token_usage": usage, "last_token_usage": usage}})]
        (sessions / "a.jsonl").write_text("\n".join(rows) + "\n")
        self.claude = self.root / ".claude/projects/example/a.jsonl"
        self.claude.parent.mkdir(parents=True)
        self.row = {"type": "assistant", "sessionId": "shared", "timestamp": "2024-01-01T00:00:03Z",
                    "message": {"id": "message", "role": "assistant", "model": "claude-opus-5-5",
                                "usage": {"input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 300,
                                          "cache_creation_input_tokens": 50}}}
        self.claude.write_text(json.dumps(self.row) + "\n")
        self.source = atlas.usage_source_from_home(self.root)

    def test_all_views_and_costs_equal_sum_of_sources(self):
        children = [atlas.collect_source_usage(s) for s in atlas.available_usage_sources()]
        combined = atlas.collect_source_usage(self.source)
        self.assertEqual(combined.totals["total_tokens"], 570)
        self.assertEqual(combined.totals["calls"], 2)
        self.assertEqual(sum(s.total["total_tokens"] for s in combined.sessions), 570)
        self.assertEqual(sum(v["total_tokens"] for v in combined.by_day.values()), 570)
        self.assertEqual(sum(v["total_tokens"] for v in combined.totals_by_model.values()), 570)
        self.assertEqual({s.descriptor.session_id for s in combined.sessions}, {"codex:shared", "claude:shared"})
        self.assertAlmostEqual(sum(c["estimated_cost_usd"] for c in combined.costs_by_model.values()),
                               sum(c["estimated_cost_usd"] for child in children for c in child.costs_by_model.values()))
        payload = atlas.summary_payload(combined)
        self.assertEqual(payload["source_id"], "all")
        self.assertEqual(set(payload["source_totals"]), {"codex", "claude"})
        owners = atlas.logical_owner_ids(s.descriptor for s in combined.file_states.values())
        self.assertIsNotNone(atlas.record_event_provenance(combined, owners))

    def test_refresh_keeps_independent_cache_and_updated_claude_snapshot(self):
        atlas.collect_source_usage(self.source)
        manifest = atlas.source_input_manifest(self.source)
        self.row["message"]["usage"]["output_tokens"] = 40
        with self.claude.open("a") as f:
            f.write(json.dumps(self.row) + "\n")
        self.assertNotEqual(manifest, atlas.source_input_manifest(self.source))
        combined = atlas.collect_source_usage(self.source)
        self.assertEqual(combined.totals["total_tokens"], 590)
        self.assertEqual(combined.totals["calls"], 2)
        codex = atlas.incrementally_refresh_usage(atlas.available_usage_sources()[0])
        self.assertEqual(codex.sessions[0].descriptor.session_id, "shared")

    def test_sol_priority_and_historical_repricing(self):
        source = atlas.available_usage_sources()[0]
        path = source.sessions_root / "a.jsonl"
        path.write_text(path.read_text().replace("gpt-5.4-mini", "gpt-6.1-sol"))
        source.model_aliases_file.write_text(json.dumps({"models": {"gpt-6.1-sol": {
            "input": 2, "cached_input": .1, "cache_write_input": 2.5, "output": 4}}}))
        report = atlas.collect_source_usage(source)
        usage = report.billable_events[0].usage
        default = atlas.estimate_usage_cost("OpenAI", "gpt-6.1-sol", "default", usage)
        priority = atlas.estimate_usage_cost("OpenAI", "gpt-6.1-sol", "priority", usage)
        self.assertAlmostEqual(default["estimated_cost_usd"], (40 * 2 + 50 * .1 + 10 * 10) / 1e6)
        self.assertAlmostEqual(priority["estimated_cost_usd"], 2 * default["estimated_cost_usd"])
        self.assertEqual(priority["tier_rate_fallback_calls"], 0)
        self.assertNotIn("gpt-6.1-sol", report.custom_pricing_models)
        old_price = dict(atlas.PRICING_USD_PER_MTOK["gpt-6.1-sol"])
        old_price["output"] = 4
        old_price["priority_rates"] = None
        report.pricing_catalog["gpt-6.1-sol"] = old_price
        report.pricing_revision = "old-price"
        atlas.reprice_usage_report(report)
        atlas.save_incremental_cache(source, report)
        with patch.object(atlas, "collect_usage", side_effect=AssertionError("history reread")):
            refreshed = atlas.incrementally_refresh_usage(source)
        self.assertAlmostEqual(refreshed.costs_by_model["gpt-6.1-sol"]["estimated_cost_usd"], default["estimated_cost_usd"])
        rates, long_context = atlas.standard_rates_for_usage(atlas.PRICING_USD_PER_MTOK["gpt-6.1-sol"],
                                                             Counter(input_tokens=atlas.LONG_CONTEXT_THRESHOLD + 1))
        fast, fallback = atlas.rates_for_service_tier(atlas.PRICING_USD_PER_MTOK["gpt-6.1-sol"], rates, "priority")
        self.assertTrue(long_context)
        self.assertEqual(fast["output"], 30)
        self.assertFalse(fallback)


if __name__ == "__main__":
    unittest.main()
