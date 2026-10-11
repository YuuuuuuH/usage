"""Achievement boundaries, chronological evidence, and catalog upgrades."""
import sys
import unittest
from collections import Counter
from datetime import date, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import token_atlas as atlas


class AchievementTests(unittest.TestCase):
    def setUp(self):
        self.session = atlas.SessionStats(atlas.SessionDescriptor(
            Path("synthetic/session"), "session", "", "session", "session", 0, "",
            thread=atlas.ThreadInfo(title="Session")))
        self.report = atlas.UsageReport(sessions=[self.session])

    def add(self, stamp, model="gpt-x", tier="default", output=10, total=100, session=None):
        atlas.add_usage(self.report, session or self.session, "test", model, tier, "", stamp,
                        Counter(total_tokens=total, output_tokens=output, calls=1))

    def badges(self, today):
        return {badge["id"]: badge for badge in atlas.build_usage_records(self.report, today)["achievements"]}

    def test_thirty_day_streak_survives_a_later_break(self):
        start = datetime(2026, 1, 1, 12, tzinfo=atlas.LOCAL_TZ)
        for offset in range(29):
            self.add(start + timedelta(days=offset))
        badge = self.badges(date(2026, 1, 29))["streak"]
        self.assertEqual(badge["value"], 29)
        self.assertTrue(badge["levels"][3]["hidden"])
        self.assertIsNone(badge["levels"][3]["unlocked_on"])
        self.add(start + timedelta(days=29))
        self.add(start + timedelta(days=32))
        badge = self.badges(date(2026, 2, 2))["streak"]
        self.assertEqual((badge["value"], badge["current_value"]), (30, 1))
        self.assertEqual(badge["levels"][3]["unlocked_on"], "2026-01-30")

    def test_weekends_and_months_count_distinct_local_dates(self):
        # Friday UTC becomes Saturday in the report timezone.
        for stamp in ("2026-01-02T16:01:00+00:00", "2026-01-03T08:00:00+00:00",
                      "2026-01-04T08:00:00+00:00", "2026-02-01T08:00:00+00:00"):
            self.add(datetime.fromisoformat(stamp))
        badges = self.badges(date(2026, 2, 1))
        self.assertEqual(badges["weekend_days"]["value"], 3)
        self.assertEqual(badges["weekend_days"]["levels"][0]["unlocked_on"], "2026-01-03")
        self.assertEqual(badges["active_months"]["value"], 2)
        self.assertEqual(badges["active_months"]["levels"][0]["unlocked_on"], "2026-02-01")

    def test_daily_model_variety_merges_tiers_and_normalizes_names(self):
        start = datetime(2026, 1, 3, 12, tzinfo=atlas.LOCAL_TZ)
        for model, tier in ((" GPT-X ", "default"), ("gpt-x", "priority"),
                            ("ANTHROPIC.Claude-Y", "default"), ("claude-y", "priority"),
                            ("codex-auto-review", "default"), ("(unknown)", "default")):
            self.add(start, model=model, tier=tier)
        self.add(start + timedelta(days=1), model="different-model")
        badge = self.badges(date(2026, 1, 4))["daily_models"]
        self.assertEqual(badge["value"], 2)
        self.assertEqual(badge["levels"][0]["unlocked_on"], "2026-01-03")
        self.assertIsNone(badge["levels"][1]["unlocked_on"])

    def test_continuous_activity_splits_after_thirty_minutes_idle(self):
        start = datetime(2026, 1, 3, 12, tzinfo=atlas.LOCAL_TZ)
        for minute in (0, 15, 30, 61, 76):
            self.add(start + timedelta(minutes=minute))
        badge = self.badges(start.date())["marathon_minutes"]
        self.assertEqual(badge["value"], 30)
        self.assertEqual([level["unlocked_on"] for level in badge["levels"]],
                         ["2026-01-03", None, None, None])
        for minute in (106, 136, 166, 181):
            self.add(start + timedelta(minutes=minute))
        badge = self.badges(start.date())["marathon_minutes"]
        self.assertEqual(badge["value"], 120)
        self.assertEqual(badge["levels"][1]["unlocked_on"], "2026-01-03")
        self.assertIsNone(badge["levels"][2]["unlocked_on"])
        self.assertIsNone(badge["levels"][3]["unlocked_on"])

    def test_marathon_thresholds_include_the_hidden_full_day(self):
        start = datetime(2026, 1, 3, 0, tzinfo=atlas.LOCAL_TZ)
        for minute in (0, 9, 10, *range(30, 1440, 30), 1439, 1440):
            self.add(start + timedelta(minutes=minute))
            if minute in (9, 10, 60, 480, 1439, 1440):
                badge = self.badges((start + timedelta(minutes=minute)).date())["marathon_minutes"]
                self.assertEqual([level["target"] for level in badge["levels"]], [10, 60, 480, 1440])
                self.assertEqual(sum(level["unlocked_on"] is not None for level in badge["levels"]),
                                 sum(minute >= target for target in (10, 60, 480, 1440)))
                self.assertTrue(badge["levels"][3]["hidden"])
        self.assertEqual(badge["levels"][3]["unlocked_on"], "2026-01-04")

    def test_daily_output_uses_a_daily_peak(self):
        start = datetime(2026, 1, 3, 12, tzinfo=atlas.LOCAL_TZ)
        self.add(start, output=60_000, total=70_000)
        self.add(start + timedelta(minutes=10), output=40_000, total=50_000)
        self.add(start + timedelta(days=1), output=90_000, total=100_000)
        badge = self.badges(date(2026, 1, 4))["daily_output_tokens"]
        self.assertEqual(badge["value"], 100_000)
        self.assertEqual(badge["levels"][0]["unlocked_on"], "2026-01-03")
        self.assertIsNone(badge["levels"][1]["unlocked_on"])

    def test_temporal_badges_require_eligible_events(self):
        start = datetime(2026, 1, 3, 12, tzinfo=atlas.LOCAL_TZ)
        self.session.missing_timestamp_events = 1
        self.add(start, output=1_000_000, total=1_000_000)
        self.add(start + timedelta(minutes=30))
        future = atlas.SessionStats(atlas.SessionDescriptor(
            Path("synthetic/future"), "future", "", "future", "future", 0, ""))
        self.report.sessions.append(future)
        self.add(start + timedelta(days=35), output=1_000_000, total=1_000_000, session=future)
        badges = self.badges(start.date())
        for key in ("weekend_days", "active_months", "daily_models", "marathon_minutes", "daily_output_tokens"):
            self.assertEqual(badges[key]["value"], 0, key)
            self.assertTrue(all(level["unlocked_on"] is None for level in badges[key]["levels"]), key)
        self.assertGreater(badges["first_million"]["value"], 1_000_000)
        self.assertIsNone(badges["first_million"]["levels"][0]["unlocked_on"])

    def test_million_boundary_and_extended_token_stages(self):
        start = datetime(2026, 1, 3, 12, tzinfo=atlas.LOCAL_TZ)
        self.add(start, total=999_999)
        self.assertIsNone(self.badges(start.date())["first_million"]["levels"][0]["unlocked_on"])
        self.add(start + timedelta(minutes=1), total=1)
        self.assertEqual(self.badges(start.date())["first_million"]["levels"][0]["unlocked_on"], "2026-01-03")
        journey = self.badges(start.date())["total_tokens"]
        self.assertEqual([level["target"] for level in journey["levels"]],
                         [100_000_000, 1_000_000_000, 5_000_000_000, 25_000_000_000,
                          50_000_000_000, 100_000_000_000])
        self.assertEqual([level["title"] for level in journey["levels"]],
                         ["亿点灵感", "十亿俱乐部", "灵感星河", "钻石宇宙", "星耀远航", "千亿传说"])
        self.assertEqual([level["hidden"] for level in journey["levels"]], [False] * 3 + [True] * 3)

    def test_catalog_change_rebuilds_records_from_existing_report(self):
        start = datetime.now(atlas.LOCAL_TZ)
        self.add(start)
        self.report.records_cache = {"as_of": start.date().isoformat(), "catalog_revision": 1,
                                     "achievements": []}
        records = atlas.cached_usage_records(self.report)
        self.assertEqual(len(records["achievements"]), 19)
        self.assertEqual(records["catalog_revision"], atlas.ACHIEVEMENT_CATALOG_REVISION)
        self.assertIs(atlas.cached_usage_records(self.report), records)


if __name__ == "__main__":
    unittest.main()
