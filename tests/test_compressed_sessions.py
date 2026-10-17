"""Compressed cold history must survive refreshes and lossless compression."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import token_atlas as atlas


@unittest.skipUnless(atlas._zstd is not None or atlas.zstd_executable(), "Zstandard decoder unavailable")
class CompressedSessionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="atlas-compressed-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.source = atlas.UsageSource("test", "Test", self.root / "data")
        self.source.sessions_root.mkdir(parents=True)
        self.source.config_file.write_text('service_tier = "default"\n')
        for patcher in (patch.object(atlas, "CACHE_ROOT", self.root / "cache"),
                        patch.object(atlas, "TOKENIZER_SEARCH_ROOTS", ())):
            patcher.start()
            self.addCleanup(patcher.stop)

    def rows(self, identifier, day, tokens=100, parent=""):
        stamp = day + "T12:00:00Z"
        metadata = {"id": identifier, "timestamp": stamp, "model_provider": "openai"}
        if parent:
            metadata["forked_from_id"] = parent
        usage = {"input_tokens": tokens, "cached_input_tokens": tokens // 2,
                 "output_tokens": 10, "total_tokens": tokens + 10}
        return [
            atlas.synthetic_event(stamp, "session_meta", metadata),
            atlas.synthetic_event(stamp, "turn_context", {"turn_id": identifier, "model": "gpt-5.6-sol"}),
            atlas.synthetic_event(stamp, "event_msg", {"type": "token_count", "info": {
                "last_token_usage": usage, "total_token_usage": usage, "model_context_window": 512000}}),
        ]

    def write(self, name, rows):
        target = self.source.sessions_root / (name + ".jsonl")
        target.write_text("\n".join(rows) + "\n")
        return target

    def compress(self, path, *, keep=False):
        data = path.read_bytes()
        encoded = (atlas._zstd.compress(data) if atlas._zstd is not None else
                   subprocess.run([atlas.zstd_executable(), "-q", "-c"], input=data,
                                  stdout=subprocess.PIPE, check=True).stdout)
        target = path.with_suffix(".jsonl.zst")
        target.write_bytes(encoded)
        if not keep:
            path.unlink()
        return target

    def cache(self):
        report = atlas.collect_source_usage(self.source)
        atlas.save_incremental_cache(self.source, report)
        return report

    def comparable(self, report):
        value = atlas.summary_payload(report)
        value.pop("generated_at")
        value["dashboard"].pop("generated_at")
        value["dashboard"].pop("generated_at_label")
        return value

    def assert_matches_full(self, report):
        self.assertIsNotNone(report)
        self.assertEqual(self.comparable(report), self.comparable(atlas.collect_source_usage(self.source)))

    def test_compressed_history_restores_early_dates_and_fork_deduplication(self):
        parent_rows = self.rows("parent", "2026-06-08")
        parent = self.write("early", parent_rows)
        child_rows = self.rows("child", "2026-08-05", 200, parent="parent")
        child = self.write("late", [child_rows[0], *parent_rows[1:], *child_rows[1:]])
        expected = self.cache()
        self.compress(parent)
        actual = atlas.collect_source_usage(self.source)
        self.assertEqual(actual.totals, expected.totals)
        self.assertEqual(actual.totals["calls"], 2)
        self.assertEqual(actual.inherited_events, 1)
        self.assertEqual(atlas.summary_payload(actual)["date_range"]["first"], "2026-06-08")
        self.assertTrue(child.exists())

    def test_unchanged_cold_files_are_never_opened_while_live_log_grows(self):
        cold = self.compress(self.write("cold", self.rows("cold", "2026-06-08")))
        live = self.write("live", self.rows("live", "2026-08-05"))
        self.cache()
        later = self.rows("next", "2026-08-06", 200)
        with live.open("a") as handle:
            handle.write("\n".join(later[1:]) + "\n")
        original = atlas.open_session_log
        def open_live_only(path, **kwargs):
            self.assertNotEqual(path, cold, "unchanged compressed history was reopened")
            return original(path, **kwargs)
        with patch.object(atlas, "open_session_log", side_effect=open_live_only):
            report = atlas.incrementally_refresh_usage(self.source)
        self.assertEqual(report.totals["calls"], 3)
        self.assert_matches_full(report)

    def test_lossless_conversion_reuses_cached_events_and_other_cold_files(self):
        cold = self.compress(self.write("cold", self.rows("cold", "2026-06-08")))
        live = self.write("live", self.rows("live", "2026-08-05"))
        self.cache()
        converted = self.compress(live)
        original = atlas.open_session_log
        def open_converted_only(path, **kwargs):
            self.assertNotEqual(path, cold, "conversion rescanned unrelated cold history")
            return original(path, **kwargs)
        with patch.object(atlas, "open_session_log", side_effect=open_converted_only), \
             patch.object(atlas, "add_usage", side_effect=AssertionError("cached calls were reparsed")):
            report = atlas.incrementally_refresh_usage(self.source)
        self.assertIn(str(converted), report.file_states)
        self.assertNotIn(str(live), report.file_states)
        self.assert_matches_full(report)
        atlas.save_incremental_cache(self.source, report)
        with patch.object(atlas, "open_session_log", side_effect=AssertionError("cold file reopened")):
            self.assertIsNotNone(atlas.incrementally_refresh_usage(self.source))

    def test_new_compressed_file_is_added_incrementally(self):
        self.write("live", self.rows("live", "2026-08-05"))
        before = atlas.source_input_manifest(self.source)
        self.cache()
        compressed = self.compress(self.write("early", self.rows("early", "2026-06-08")))
        self.assertNotEqual(before, atlas.source_input_manifest(self.source))
        report = atlas.incrementally_refresh_usage(self.source)
        self.assertIn(str(compressed), report.file_states)
        self.assert_matches_full(report)

    def test_both_formats_of_same_log_count_once(self):
        plain = self.write("same", self.rows("same", "2026-06-08"))
        self.compress(plain, keep=True)
        self.assertEqual(atlas.session_log_files(self.source.sessions_root), [plain])
        report = self.cache()
        self.assertEqual(report.rollout_files, 1)
        self.assertEqual(report.totals["calls"], 1)

    def test_rewritten_compressed_prefix_rebuilds(self):
        plain = self.write("same", self.rows("same", "2026-06-08"))
        self.compress(plain)
        self.cache()
        self.compress(self.write("same", self.rows("same", "2026-06-08", 10000)))
        self.assertIsNone(atlas.incrementally_refresh_usage(self.source))

    def test_appended_compressed_stream_parses_only_new_calls(self):
        rows = self.rows("same", "2026-06-08")
        plain = self.write("same", rows)
        self.compress(plain)
        self.cache()
        self.compress(self.write("same", [*rows, *self.rows("later", "2026-08-05", 200)[1:]]))
        with patch.object(atlas, "add_usage", wraps=atlas.add_usage) as add:
            report = atlas.incrementally_refresh_usage(self.source)
            self.assertEqual(add.call_count, 1)
        self.assertEqual(report.totals["calls"], 2)
        self.assert_matches_full(report)

    def test_older_cache_without_digest_rebuilds_on_conversion(self):
        plain = self.write("same", self.rows("same", "2026-06-08"))
        report = self.cache()
        del report.file_states[str(plain)].content_digest
        atlas.save_incremental_cache(self.source, report)
        self.compress(plain)
        self.assertIsNone(atlas.incrementally_refresh_usage(self.source))

    @unittest.skipUnless(atlas.zstd_executable(), "zstd executable unavailable")
    def test_cli_fallback_supports_metadata_and_incremental_offsets(self):
        live = self.write("same", self.rows("same", "2026-06-08"))
        self.cache()
        with live.open("a") as handle:
            handle.write("\n".join(self.rows("later", "2026-08-05", 200)[1:]) + "\n")
        self.compress(live)
        with patch.object(atlas, "_zstd", None):
            report = atlas.incrementally_refresh_usage(self.source)
            self.assertEqual(report.totals["calls"], 2)
            self.assert_matches_full(report)

    def test_unreadable_compressed_logs_fail_instead_of_losing_history(self):
        target = self.source.sessions_root / "broken.jsonl.zst"
        target.write_bytes(b"not a Zstandard stream")
        with self.assertRaises(OSError):
            atlas.collect_source_usage(self.source)
        with patch.object(atlas, "_zstd", None), patch.object(atlas, "zstd_executable", return_value=None):
            with self.assertRaisesRegex(OSError, "Python 3.14"):
                atlas.collect_source_usage(self.source)
