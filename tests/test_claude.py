"""Claude transcript accounting, using synthetic records only."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import token_atlas as atlas


class ClaudeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve() / ".claude"
        self.project = self.home / "projects" / "example"
        self.project.mkdir(parents=True)
        self.source = atlas.usage_source_from_home(self.home)

    def record(self, mid="message-1", output=20, **changes):
        row = {"type": "assistant", "sessionId": "session-1", "timestamp": "2026-01-01T12:00:00Z",
               "message": {"role": "assistant", "id": mid, "model": "claude-test-model",
                           "content": [{"type": "text", "text": "private fixture text"}],
                           "usage": {"input_tokens": 100, "output_tokens": output,
                                     "cache_read_input_tokens": 300, "cache_creation_input_tokens": 50}}}
        row.update(changes)
        return row

    def write(self, rows, path=None):
        path = path or self.project / "session-1.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        return path

    def report(self):
        return atlas.collect_source_usage(self.source)

    def test_cache_categories_and_unknown_model(self):
        self.write([self.record()])
        report = self.report()
        self.assertEqual(report.totals["total_tokens"], 470)
        self.assertEqual(report.totals["input_tokens"], 450)
        self.assertEqual(report.totals["uncached_input_tokens"], 100)
        self.assertEqual(report.totals["cached_input_tokens"], 300)
        self.assertEqual(report.totals["cache_write_input_tokens"], 50)
        self.assertEqual(report.totals["calls"], 1)
        payload = atlas.summary_payload(report)
        self.assertEqual(payload["source_id"], "claude")
        self.assertNotIn("private fixture text", json.dumps(payload))
        self.assertEqual(report.costs_by_model["claude-test-model"]["unpriced_tokens"], 470)

    def test_content_blocks_and_partial_updates_count_once(self):
        self.write([self.record(output=1), self.record(output=20), self.record(output=20)])
        self.assertEqual(self.report().totals["total_tokens"], 470)
        self.assertEqual(self.report().totals["calls"], 1)

    def test_copied_history_and_identical_independent_calls(self):
        self.write([self.record()])
        self.write([self.record(sessionId="branch"), self.record("new-call", sessionId="branch")], self.project / "branch.jsonl")
        self.assertEqual(self.report().totals["total_tokens"], 940)
        self.assertEqual(self.report().totals["calls"], 2)

    def test_subagent_folds_into_parent(self):
        self.write([self.record()])
        self.write([self.record("worker", isSidechain=True)], self.project / "session-1/subagents/agent-a.jsonl")
        report = self.report()
        self.assertEqual(report.totals["calls"], 2)
        self.assertEqual(len(report.sessions), 1)
        self.assertEqual(report.sessions[0].total["total_tokens"], 940)
        self.assertEqual(report.internal_threads, 1)

    def test_unfinished_line_then_completed(self):
        path = self.write([self.record()])
        with path.open("a") as file:
            file.write(json.dumps(self.record("message-2")))
        self.assertEqual(self.report().totals["calls"], 1)
        with path.open("a") as file:
            file.write("\n")
        self.assertEqual(self.report().totals["calls"], 2)

    def test_invalid_or_missing_usage_not_invented(self):
        rows = [self.record() for _ in range(4)]
        rows[0]["message"].pop("usage")
        rows[1]["message"]["usage"]["input_tokens"] = -10
        rows[2]["message"]["usage"]["input_tokens"] = True
        rows[3]["message"].pop("id")
        self.write(rows)
        report = self.report()
        self.assertEqual(report.totals["calls"], 0)
        self.assertEqual(report.null_usage_events, 4)
        self.assertIn("等待本地记录", report.source_notice)

    def test_missing_timestamp_audited(self):
        self.write([self.record(timestamp="invalid")])
        report = self.report()
        self.assertEqual(report.totals["calls"], 1)
        self.assertEqual(report.missing_timestamp_events, 1)
        self.assertEqual(atlas.build_usage_records(report)["excluded_timestamp_sessions"], 1)

    def test_rewrite_and_delete_refresh_manifest(self):
        path = self.write([self.record()])
        manifest = atlas.source_input_manifest(self.source)
        self.write([self.record(output=40)])
        self.assertNotEqual(manifest, atlas.source_input_manifest(self.source))
        self.assertEqual(self.report().totals["total_tokens"], 490)
        path.unlink()
        self.assertEqual(self.report().totals["calls"], 0)

    def test_empty_source_reports_coverage(self):
        report = self.report()
        self.assertEqual(report.rollout_files, 0)
        self.assertIn("等待本地记录", atlas.summary_payload(report)["dashboard"]["source_notice"])

    def test_official_price_includes_one_hour_cache_creation(self):
        row = self.record()
        row["message"]["model"] = "claude-opus-5-5"
        row["message"]["usage"]["cache_creation"] = {"ephemeral_1h_input_tokens": 50, "ephemeral_5m_input_tokens": 0}
        self.write([row])
        report = self.report()
        cost = report.costs_by_model["claude-opus-5-5"]
        self.assertAlmostEqual(cost["estimated_cost_usd"], (100 * 4 + 300 * .2 + 50 * 8 + 20 * 20) / 1_000_000)
        self.assertEqual(cost["priced_tokens"], 470)
        self.assertEqual(report.source_notice, "")

    def test_fast_price_and_standard_equivalent(self):
        row = self.record()
        row["message"]["model"] = "claude-opus-5-5"
        row["message"]["usage"]["speed"] = "fast"
        self.write([row])
        cost = self.report().costs_by_model["claude-opus-5-5"]
        self.assertAlmostEqual(cost["estimated_cost_usd"], 2 * cost["standard_equivalent_cost_usd"])

    def test_custom_config_home_and_project_picker(self):
        custom = Path(self.temp.name).resolve() / "config"
        (custom / "projects").mkdir(parents=True)
        self.assertEqual(atlas.usage_source_from_home(custom).format, "claude")
        self.assertEqual(atlas.normalize_data_home(custom / "projects"), custom)
        self.assertFalse(self.source.read_billing_context)
        self.assertFalse(self.source.read_service_tier)

    def test_desktop_roots_exclude_plugins_and_combine_cli(self):
        user = Path(self.temp.name).resolve()
        desktop = user / "Library/Application Support/Claude"
        self.write([self.record("desktop", sessionId="desktop")], desktop / "claude-code-sessions/account/session/transcript.jsonl")
        self.write([self.record("cowork", sessionId="cowork")], desktop / "local-agent-mode-sessions/account/session/audit.jsonl")
        self.write([self.record("ignore")], desktop / "local-agent-mode-sessions/skills-plugin/sample.jsonl")
        self.write([self.record()])
        with patch.object(atlas, "HOME", user):
            source = atlas.usage_source_from_home(desktop)
            self.assertEqual(atlas.collect_source_usage(source).totals["calls"], 3)
            self.assertEqual(len(atlas.claude_log_files(source)), 3)


if __name__ == "__main__":
    unittest.main()
