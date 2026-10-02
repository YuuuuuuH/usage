"""Refresh regressions using isolated, synthetic data homes."""
import json
import pickle
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import codex_token_heatmap as atlas


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="atlas-refresh-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = atlas.UsageSource("test", "Test", self.root / "data")
        self.source.sessions_root.mkdir(parents=True)
        self.patchers = [patch.object(atlas, "CACHE_ROOT", self.root / "cache"),
                         patch.object(atlas, "TOKENIZER_SEARCH_ROOTS", ())]
        for patcher in self.patchers:
            patcher.start()
            self.addCleanup(patcher.stop)
        self.source.config_file.write_text('service_tier = "default"\n')
        self.source.auth_file.write_text('{"auth_mode":"chatgpt","tokens":{"access_token":"fixture-a"}}')
        self.path = self.source.sessions_root / "rollout-test.jsonl"
        self.path.write_text(atlas.synthetic_event("2024-01-01T00:00:00Z", "session_meta", {
            "id": "test", "timestamp": "2024-01-01T00:00:00Z", "model_provider": "openai"}) + "\n")
        self.append_call(1)

    def append_call(self, number, explicit_tier=None, duplicate=False):
        stamp = f"2024-01-01T00:00:{number:02d}Z"
        rows = [atlas.synthetic_event(stamp, "turn_context", {"turn_id": f"turn-{number}", "model": "gpt-5.4-mini"})]
        if explicit_tier is not None:
            rows.append(atlas.synthetic_event(stamp, "event_msg", {"type": "thread_settings_applied",
                        "thread_settings": {"service_tier": explicit_tier}}))
        usage = {"input_tokens": 90, "cached_input_tokens": 50, "output_tokens": 10, "total_tokens": 100}
        row = atlas.synthetic_event(stamp, "event_msg", {"type": "token_count", "info": {
            "total_token_usage": {k: v * number for k, v in usage.items()}, "last_token_usage": usage}})
        rows.append(row)
        if duplicate:
            rows.append(row)
        with self.path.open("a") as handle:
            handle.write("\n".join(rows) + "\n")

    def cache(self):
        report = atlas.collect_source_usage(self.source)
        atlas.save_incremental_cache(self.source, report)
        return report

    def assert_matches_full(self, incremental):
        self.assertIsNotNone(incremental)
        expected = atlas.summary_payload(atlas.collect_source_usage(self.source))
        actual = atlas.summary_payload(incremental)
        for payload in (expected, actual):
            payload.pop("generated_at")
            payload["dashboard"].pop("generated_at")
            payload["dashboard"].pop("generated_at_label")
        self.assertEqual(expected, actual)

    def test_unrelated_config_and_rotating_credentials_reuse_cache(self):
        self.cache()
        manifest = atlas.source_input_manifest(self.source)
        self.source.config_file.write_text('service_tier = "standard"\nmodel = "another-model"\n')
        self.source.auth_file.write_text('{"auth_mode":"chatgpt","tokens":{"access_token":"fixture-b"}}')
        self.assertEqual(manifest, atlas.source_input_manifest(self.source))
        self.assert_matches_full(atlas.incrementally_refresh_usage(self.source))

    def test_billing_context_updates_without_reparsing(self):
        self.cache()
        manifest = atlas.source_input_manifest(self.source)
        self.source.auth_file.write_text('{"auth_mode":"apikey","OPENAI_API_KEY":"fixture"}')
        self.assertNotEqual(manifest, atlas.source_input_manifest(self.source))
        self.assert_matches_full(atlas.incrementally_refresh_usage(self.source))

    def test_legacy_cache_migration_ignores_unrelated_runtime_files(self):
        report = self.cache()
        envelope = atlas.IncrementalCacheEnvelope(3, str(self.source.home),
            atlas._auxiliary_input_manifest(self.source, include_pricing=False, legacy=True), report)
        atlas.incremental_cache_path(self.source).write_bytes(pickle.dumps(envelope))
        self.source.config_file.write_text('service_tier = "default"\nmodel = "changed"\n')
        self.assert_matches_full(atlas.incrementally_refresh_usage(self.source))

    def test_tier_change_preserves_explicit_calls_and_deduplication(self):
        self.append_call(2, explicit_tier="default", duplicate=True)
        self.append_call(3, explicit_tier="priority")
        self.cache()
        self.source.config_file.write_text('service_tier = "priority"\n')
        report = atlas.incrementally_refresh_usage(self.source)
        self.assert_matches_full(report)
        self.assertEqual(report.totals_by_service_tier["default"]["calls"], 1)
        self.assertEqual(report.totals_by_service_tier["priority"]["calls"], 2)
        atlas.save_incremental_cache(self.source, report)
        self.append_call(4)
        self.assert_matches_full(atlas.incrementally_refresh_usage(self.source))

    def test_inferred_active_tier_updates_before_appending(self):
        self.cache()
        self.source.config_file.write_text('service_tier = "priority"\n')
        self.append_call(2)
        self.assert_matches_full(atlas.incrementally_refresh_usage(self.source))

    def test_legacy_missing_tier_provenance_requires_safe_rebuild(self):
        report = self.cache()
        report.billable_events[0].service_tier_inferred = None
        atlas.save_incremental_cache(self.source, report)
        self.source.config_file.write_text('service_tier = "priority"\n')
        self.assertIsNone(atlas.load_incremental_cache(self.source))

    def test_tier_change_that_splits_a_duplicate_requires_rebuild(self):
        self.append_call(1, explicit_tier="default")
        self.assertTrue(self.cache().tier_change_requires_rebuild)
        self.source.config_file.write_text('service_tier = "priority"\n')
        self.assertIsNone(atlas.load_incremental_cache(self.source))

    def test_tier_change_that_merges_calls_requires_rebuild(self):
        self.append_call(1, explicit_tier="priority")
        self.cache()
        self.source.config_file.write_text('service_tier = "priority"\n')
        self.assertIsNone(atlas.load_incremental_cache(self.source))

    def test_truncated_log_requires_rebuild(self):
        self.cache()
        self.path.write_text("")
        self.assertIsNone(atlas.incrementally_refresh_usage(self.source))

    def test_append_matches_full_including_records_and_prices(self):
        self.cache()
        self.append_call(2, duplicate=True)
        self.assert_matches_full(atlas.incrementally_refresh_usage(self.source))

    def test_empty_cache_can_receive_first_session(self):
        self.path.unlink()
        self.cache()
        self.append_call(1)
        self.assert_matches_full(atlas.incrementally_refresh_usage(self.source))

    def test_summary_and_html_share_one_dashboard(self):
        report = self.cache()
        with patch.object(atlas, "build_dashboard_data", wraps=atlas.build_dashboard_data) as build:
            summary = atlas.summary_payload(report)
            rendered = atlas.render_html(report, summary["dashboard"])
            self.assertIn(summary["dashboard"]["generated_at_label"], rendered)
            self.assertEqual(build.call_count, 1)
        self.assertEqual(summary["pricing"], atlas.build_pricing_data(report, list(summary["usage_by_model"])))

    def test_source_snapshots_are_isolated_atomic_and_date_checked(self):
        report = self.cache()
        manifest = atlas.source_input_manifest(self.source)
        summary = atlas.summary_payload(report, manifest)
        target = atlas.source_summary_path(self.source)
        other = atlas.UsageSource("test", "Test", self.root / "other")
        with patch.object(atlas, "OUTPUT_JSON", self.root / "summary.json"):
            atlas.write_summary_outputs(summary, self.source)
        self.assertNotEqual(target, atlas.source_summary_path(other))
        self.assertEqual(summary, atlas.cached_summary(self.source, manifest, target))
        self.assertIsNone(atlas.cached_summary(other, manifest, target))
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        summary["dashboard"]["records"]["as_of"] = "2000-01-01"
        target.write_text(json.dumps(summary))
        self.assertIsNone(atlas.cached_summary(self.source, manifest, target))

    def test_wal_updates_invalidate_snapshot(self):
        before = atlas.source_input_manifest(self.source)
        Path(str(self.source.state_db) + "-wal").write_bytes(b"fixture")
        self.assertNotEqual(before, atlas.source_input_manifest(self.source))

    def test_unchanged_rollouts_do_not_reopen_metadata(self):
        self.cache()
        with patch.object(atlas, "read_leading_session_meta", side_effect=AssertionError("reread history")):
            report = atlas.incrementally_refresh_usage(self.source)
        self.assertIsNotNone(report)
        self.append_call(2)
        with patch.object(atlas, "read_leading_session_meta", wraps=atlas.read_leading_session_meta) as read:
            report = atlas.incrementally_refresh_usage(self.source)
            self.assertEqual(read.call_count, 1)
        self.assert_matches_full(report)

    def test_records_cache_reused_until_usage_changes(self):
        report = self.cache()
        atlas.build_dashboard_data(report)
        atlas.save_incremental_cache(self.source, report)
        with patch.object(atlas, "build_usage_records", wraps=atlas.build_usage_records) as build:
            report = atlas.incrementally_refresh_usage(self.source)
            atlas.build_dashboard_data(report)
            self.assertEqual(build.call_count, 0)
            self.append_call(2)
            report = atlas.incrementally_refresh_usage(self.source)
            atlas.build_dashboard_data(report)
            self.assertEqual(build.call_count, 1)
        self.assert_matches_full(report)

    def test_records_cache_updates_titles_and_calendar_day(self):
        report = self.cache()
        atlas.build_dashboard_data(report)
        atlas.save_incremental_cache(self.source, report)
        self.source.session_index.write_text(json.dumps({"id": "test", "thread_name": "Updated title"}) + "\n")
        report = atlas.incrementally_refresh_usage(self.source)
        self.assertIsNone(report.records_cache)
        self.assert_matches_full(report)
        report.records_cache["as_of"] = "2000-01-01"
        with patch.object(atlas, "build_usage_records", wraps=atlas.build_usage_records) as build:
            atlas.build_dashboard_data(report)
            self.assertEqual(build.call_count, 1)

    def test_tier_changes_roll_internal_workers_into_parent(self):
        worker_path = self.source.sessions_root / "rollout-worker.jsonl"
        worker_path.write_text(atlas.synthetic_event("2024-01-01T00:00:01Z", "session_meta", {
            "id": "worker", "parent_thread_id": "test", "thread_source": "subagent",
            "timestamp": "2024-01-01T00:00:01Z", "model_provider": "openai"}) + "\n")
        self.path = worker_path
        self.append_call(2)
        self.cache()
        self.source.config_file.write_text('service_tier = "priority"\n')
        self.assert_matches_full(atlas.incrementally_refresh_usage(self.source))

    def test_tier_round_trip_reuses_each_cache_even_with_ambiguous_duplicates(self):
        self.append_call(1, explicit_tier="default")
        default_report = self.cache()
        self.source.config_file.write_text('service_tier = "priority"\n')
        self.assertIsNone(atlas.incrementally_refresh_usage(self.source))
        priority_report = self.cache()
        self.assertNotEqual(default_report.totals["calls"], priority_report.totals["calls"])
        self.append_call(2)
        for tier in ("default", "priority", "default"):
            self.source.config_file.write_text(f'service_tier = "{tier}"\n')
            report = atlas.incrementally_refresh_usage(self.source)
            self.assert_matches_full(report)
            atlas.save_incremental_cache(self.source, report)
        current = atlas.incremental_cache_path(self.source)
        variant = atlas.tier_cache_path(self.source, "default")
        self.assertEqual(current.stat().st_ino, variant.stat().st_ino)


if __name__ == "__main__":
    unittest.main()
