#!/usr/bin/env python3
"""Build a fork-safe, model-aware dashboard from a Codex-compatible data home."""

from __future__ import annotations

import argparse
import csv
import hashlib
import html
import json
import math
import os
import pickle
import re
import sqlite3
import tempfile
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable
from uuid import UUID
from zoneinfo import ZoneInfo

try:
    import orjson as _fast_json
except ImportError:
    _fast_json = None


HOME = Path.home()
CODEX_HOME = HOME / ".codex"
QODEX_HOME = HOME / ".qodex"
SESSIONS_ROOT = CODEX_HOME / "sessions"
STATE_DB = CODEX_HOME / "state_5.sqlite"
SESSION_INDEX = CODEX_HOME / "session_index.jsonl"
AUTH_FILE = CODEX_HOME / "auth.json"
CONFIG_FILE = CODEX_HOME / "config.toml"
MODEL_ALIASES_FILE = CODEX_HOME / "token_atlas_pricing.json"
TOKENIZER_MAP_FILE = "token_atlas_tokenizers.json"
TOKENIZER_SEARCH_ROOTS = (
    HOME / ".lmstudio" / "models",
    HOME / ".cache" / "huggingface" / "hub",
    HOME / ".cache" / "modelscope" / "hub" / "models",
)

OUTPUT_HTML = HOME / "codex_token_heatmap.html"
OUTPUT_DAILY_CSV = HOME / "codex_token_usage_by_day.csv"
OUTPUT_HOURLY_CSV = HOME / "codex_token_usage_by_hour.csv"
OUTPUT_MODEL_CSV = HOME / "codex_token_usage_by_model.csv"
OUTPUT_ROUTE_CSV = HOME / "codex_token_usage_by_route.csv"
OUTPUT_SESSION_CSV = HOME / "codex_token_usage_by_session.csv"
OUTPUT_JSON = HOME / "codex_token_usage_summary.json"
OUTPUT_ARTIFACTS = (
    OUTPUT_HTML,
    OUTPUT_DAILY_CSV,
    OUTPUT_HOURLY_CSV,
    OUTPUT_MODEL_CSV,
    OUTPUT_ROUTE_CSV,
    OUTPUT_SESSION_CSV,
    OUTPUT_JSON,
)

LOCAL_TZ = ZoneInfo("Asia/Shanghai")
REPORT_SCHEMA_VERSION = 11
INCREMENTAL_CACHE_VERSION = 4
INCREMENTAL_CACHE_COMPATIBLE_VERSIONS = {1, 2, 3, INCREMENTAL_CACHE_VERSION}
CACHE_ROOT = HOME / "Library" / "Caches" / "CodexTokenAtlas"
ALL_MODELS_KEY = "all"
ACHIEVEMENT_LEVEL_NAMES = ("铜", "银", "金", "钻石")
STREAK_ACHIEVEMENT_TARGETS = (3, 7, 14)
ACTIVE_DAY_ACHIEVEMENT_TARGETS = (7, 30, 90, 365)
CONVERSATION_ACHIEVEMENT_TARGETS = (10, 30, 100, 500)
RECORD_ACHIEVEMENT_TARGETS = {
    "streak": STREAK_ACHIEVEMENT_TARGETS,
    "days": ACTIVE_DAY_ACHIEVEMENT_TARGETS,
    "sessions": CONVERSATION_ACHIEVEMENT_TARGETS,
    "models": (2, 4, 6),
    "session_models": (2, 3, 4),
    "daily_sessions": (2, 4, 8),
    "collaborative_sessions": (3, 10, 30),
    "collaborative_days": (3, 10, 30, 100),
    "total_tokens": (100_000_000, 1_000_000_000, 5_000_000_000, 25_000_000_000),
    "output_tokens": (1_000_000, 5_000_000, 20_000_000, 100_000_000),
    "reasoning_tokens": (500_000, 2_000_000, 10_000_000),
    "cached_tokens": (100_000_000, 1_000_000_000, 5_000_000_000),
}
RECORD_VOLUME_FIELDS = {
    "total_tokens": "total_tokens",
    "output_tokens": "output_tokens",
    "reasoning_tokens": "reasoning_output_tokens",
    "cached_tokens": "cached_input_tokens",
}
PEAK_VOLUME_WINDOW_SECONDS = 3600
PEAK_RATE_WINDOW_SECONDS = 60
ACTIVITY_GAP_SECONDS = 1800
UNKNOWN_MODEL = "(unknown)"
UNKNOWN_PROVIDER = "(unknown provider)"
DEFAULT_SERVICE_TIER = "default"


RAW_USAGE_FIELDS = (
    "input_tokens",
    "cached_input_tokens",
    "cache_write_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "total_tokens",
)
DERIVED_USAGE_FIELDS = (
    "uncached_input_tokens",
    "unclassified_tokens",
)
USAGE_FIELDS = RAW_USAGE_FIELDS + DERIVED_USAGE_FIELDS + ("calls",)

RELEVANT_USAGE_LINE_MARKERS = tuple(
    marker.encode("ascii")
    for event_type in (
        "turn_context",
        "thread_settings_applied",
        "task_started",
        "token_count",
        "reasoning",
    )
    for marker in (f'"type":"{event_type}"', f'"type": "{event_type}"')
) + (b"<think",)

PRICING_AS_OF = "2026-09-07"
LONG_CONTEXT_THRESHOLD = 272_000
OFFICIAL_PRICING_URL = "https://developers.openai.com/api/docs/pricing"


def decode_json(value: str | bytes) -> Any:
    if _fast_json is not None:
        return _fast_json.loads(value)
    return json.loads(value)


def relevant_usage_line(line: bytes) -> bool:
    return any(marker in line for marker in RELEVANT_USAGE_LINE_MARKERS)


def source_input_manifest(source: UsageSource) -> list[list[str | int]]:
    entries: list[list[str | int]] = []
    for path in sorted(source.sessions_root.rglob("*.jsonl")):
        try:
            stat = path.stat()
        except OSError:
            continue
        entries.append(
            [
                str(path.relative_to(source.home)),
                int(stat.st_size),
                int(stat.st_mtime_ns),
            ]
        )
    metadata_paths = [source.state_db, Path(str(source.state_db) + "-wal"), source.session_index, source.model_aliases_file]
    metadata_paths.append(source.home / TOKENIZER_MAP_FILE)
    for path in metadata_paths:
        try:
            stat = path.stat()
            size, modified = int(stat.st_size), int(stat.st_mtime_ns)
        except OSError:
            size, modified = -1, -1
        entries.append([f"@{path.name}", size, modified])
    # Credentials and unrelated preferences can change frequently. Only the
    # values consumed by the report participate in snapshot invalidation.
    entries.append(["@service_tier", source_service_tier(source)])
    entries.append(["@billing_context", json.dumps(source_billing_context(source), sort_keys=True)])
    entries.extend(auxiliary_input_manifest(source))
    return entries


def cached_summary(
    source: UsageSource,
    manifest: list[list[str | int]],
    path: Path | None = None,
) -> dict[str, Any] | None:
    if path is None and any(not artifact.is_file() for artifact in OUTPUT_ARTIFACTS):
        return None
    try:
        payload = decode_json((path or OUTPUT_JSON).read_bytes())
    except (OSError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    if payload.get("schema_version") != REPORT_SCHEMA_VERSION:
        return None
    # A quiet data directory still needs its current streak to age on refresh.
    dashboard = payload.get("dashboard")
    records = dashboard.get("records") if isinstance(dashboard, dict) else None
    if not isinstance(records, dict) or records.get("as_of") != datetime.now(LOCAL_TZ).date().isoformat():
        return None
    if payload.get("source_id") != source.key:
        return None
    if payload.get("sessions_root") != str(source.sessions_root):
        return None
    pricing = payload.get("pricing")
    if not isinstance(pricing, dict) or pricing.get("as_of") != PRICING_AS_OF:
        return None
    if pricing.get("revision") != pricing_configuration_revision(source):
        return None
    if payload.get("input_manifest") != manifest:
        return None
    return payload


def _auxiliary_input_manifest(
    source: UsageSource,
    *,
    include_pricing: bool,
    legacy: bool = False,
) -> list[list[str | int]]:
    paths = [source.home / TOKENIZER_MAP_FILE]
    if include_pricing:
        paths.insert(0, source.model_aliases_file)
    if legacy and source.read_service_tier:
        paths.append(source.config_file)
    if legacy and source.read_billing_context:
        paths.append(source.auth_file)
    result: list[list[str | int]] = []
    for path in paths:
        try:
            stat = path.stat()
            size, modified = int(stat.st_size), int(stat.st_mtime_ns)
        except OSError:
            size, modified = -1, -1
        result.append([str(path), size, modified])
    for root in TOKENIZER_SEARCH_ROOTS:
        if not root.is_dir():
            continue
        try:
            tokenizer_paths = sorted(root.rglob("tokenizer.json"))
        except OSError:
            continue
        for path in tokenizer_paths:
            try:
                stat = path.stat()
            except OSError:
                continue
            result.append([str(path), int(stat.st_size), int(stat.st_mtime_ns)])
    return result


def auxiliary_input_manifest(source: UsageSource) -> list[list[str | int]]:
    return _auxiliary_input_manifest(source, include_pricing=False)


def legacy_auxiliary_input_manifest(source: UsageSource) -> list[list[str | int]]:
    return _auxiliary_input_manifest(source, include_pricing=True, legacy=True)


def source_service_tier(source: UsageSource) -> str:
    return read_configured_service_tier(source.config_file) if source.read_service_tier else DEFAULT_SERVICE_TIER


def source_billing_context(source: UsageSource) -> dict[str, Any]:
    return read_billing_context(source.auth_file) if source.read_billing_context else {}


def pricing_configuration_revision(source: UsageSource) -> str:
    digest = hashlib.sha256()
    digest.update(PRICING_AS_OF.encode("utf-8"))
    digest.update(b"\0cost-schema=2")
    digest.update(b"\0official=" + str(source.enable_official_pricing).encode("ascii"))
    if source.enable_official_pricing:
        digest.update(
            b"\0catalog="
            + json.dumps(
                PRICING_USD_PER_MTOK,
                ensure_ascii=True,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        )
    try:
        digest.update(b"\0config=" + source.model_aliases_file.read_bytes())
    except OSError:
        digest.update(b"\0config=(missing)")
    return digest.hexdigest()


def incremental_cache_path(source: UsageSource) -> Path:
    digest = hashlib.sha256(str(source.home).encode("utf-8")).hexdigest()[:20]
    return CACHE_ROOT / f"usage-{digest}.pickle"


def source_summary_path(source: UsageSource) -> Path:
    return incremental_cache_path(source).with_suffix(".json")


def tier_cache_path(source: UsageSource, tier: str) -> Path | None:
    if tier not in {"default", "priority"}:
        return None
    path = incremental_cache_path(source)
    return path.with_name(f"{path.stem}-{tier}{path.suffix}")


def atomic_write(path: Path, contents: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=path.name + "-", suffix=".tmp", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(contents)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def load_incremental_cache(source: UsageSource, *, tier_variant: bool = False) -> UsageReport | None:
    path = tier_cache_path(source, source_service_tier(source)) if tier_variant else incremental_cache_path(source)
    if path is None:
        return None
    try:
        stat = path.lstat()
        if path.is_symlink() or stat.st_uid != os.getuid() or stat.st_mode & 0o022:
            return None
        with path.open("rb") as handle:
            envelope = pickle.load(handle)
    except (
        OSError,
        EOFError,
        pickle.PickleError,
        AttributeError,
        ImportError,
        TypeError,
        ValueError,
    ):
        return None
    if not isinstance(envelope, IncrementalCacheEnvelope):
        return None
    if envelope.version not in INCREMENTAL_CACHE_COMPATIBLE_VERSIONS:
        return None
    if envelope.source_home != str(source.home):
        return None
    expected_auxiliary_manifest = (
        legacy_auxiliary_input_manifest(source)
        if envelope.version < 3
        else auxiliary_input_manifest(source)
    )
    # Migrate existing caches without rereading history merely because auth
    # tokens rotated or a non-accounting config preference changed.
    runtime_paths = {str(source.auth_file), str(source.config_file)}
    stored_manifest = [entry for entry in envelope.auxiliary_manifest if entry[0] not in runtime_paths]
    expected_manifest = [entry for entry in expected_auxiliary_manifest if entry[0] not in runtime_paths]
    if stored_manifest != expected_manifest:
        return None
    if not isinstance(envelope.report, UsageReport):
        return None
    envelope.report.billing_context = source_billing_context(source)
    if envelope.version == 1:
        base_catalog = PRICING_USD_PER_MTOK if source.enable_official_pricing else {}
        _, configured_custom_models, _ = read_pricing_config(
            source.model_aliases_file,
            base_catalog,
        )
        if configured_custom_models:
            return None
    if not hasattr(envelope.report, "custom_pricing_models"):
        envelope.report.custom_pricing_models = set()
    if not hasattr(envelope.report, "billable_events"):
        envelope.report.billable_events = []
    if not hasattr(envelope.report, "pricing_revision"):
        envelope.report.pricing_revision = ""
    if not hasattr(envelope.report, "inferred_tier_fingerprints"):
        envelope.report.inferred_tier_fingerprints = set()
    desired_tier = source_service_tier(source)
    tier_changed = envelope.report.configured_service_tier_fallback != desired_tier
    if tier_changed and not retier_inferred_usage(envelope.report, desired_tier):
        return None if tier_variant else load_incremental_cache(source, tier_variant=True)
    desired_pricing_revision = pricing_configuration_revision(source)
    if tier_changed or envelope.report.pricing_revision != desired_pricing_revision:
        catalog, aliases, custom_models, errors = current_pricing_configuration(source)
        # Older cache schemas did not retain the per-call timestamp/context needed
        # for exact repricing. Rebuild them once rather than silently revaluing only
        # calls appended after the upgrade.
        if envelope.report.totals["calls"] and not envelope.report.billable_events:
            return None
        envelope.report.pricing_catalog = catalog
        envelope.report.pricing_aliases = aliases
        envelope.report.custom_pricing_models = custom_models
        envelope.report.pricing_config_errors = errors
        reprice_usage_report(envelope.report)
        envelope.report.pricing_revision = desired_pricing_revision
    return envelope.report


def save_incremental_cache(source: UsageSource, report: UsageReport) -> None:
    envelope = IncrementalCacheEnvelope(
        version=INCREMENTAL_CACHE_VERSION,
        source_home=str(source.home),
        auxiliary_manifest=auxiliary_input_manifest(source),
        report=report,
    )
    CACHE_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix="usage-cache-",
        suffix=".tmp",
        dir=CACHE_ROOT,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            pickle.dump(envelope, handle, protocol=pickle.HIGHEST_PROTOCOL)
        temporary_path.chmod(0o600)
        temporary_path.replace(incremental_cache_path(source))
        variant = tier_cache_path(source, report.configured_service_tier_fallback)
        if variant is not None:
            # Atomic replacements keep prior tier snapshots intact. Hard links
            # avoid serializing or storing the current report twice.
            os.link(incremental_cache_path(source), temporary_path)
            temporary_path.replace(variant)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def pricing_rate(
    input_rate: float,
    cached_input_rate: float | None,
    output_rate: float,
    *,
    cache_write_input_rate: float | None = None,
    priority_rates: tuple[float, float | None, float | None, float] | None = None,
    provider: str = "OpenAI",
    long_context: bool = False,
    long_context_threshold: int | None = None,
    long_context_rates: tuple[float, float | None, float | None, float] | None = None,
    off_peak_rates: tuple[float, float | None, float | None, float] | None = None,
    peak_utc_weekday_windows: tuple[tuple[int, int], ...] | None = None,
    source: str = OFFICIAL_PRICING_URL,
) -> dict[str, Any]:
    return {
        "provider": provider,
        "pricing_kind": "official",
        "input": input_rate,
        "cached_input": cached_input_rate,
        "cache_write_input": cache_write_input_rate,
        "output": output_rate,
        "priority_rates": priority_rates,
        "long_context": long_context,
        "long_context_threshold": long_context_threshold,
        "long_context_rates": long_context_rates,
        "off_peak_rates": off_peak_rates,
        "peak_utc_weekday_windows": peak_utc_weekday_windows,
        "source": source,
    }


PRICING_USD_PER_MTOK: dict[str, dict[str, Any]] = {
    # Current GPT families and historical standard API models.
    "gpt-6-astra": pricing_rate(
        10.0, 1.0, 50.0,
        cache_write_input_rate=12.5,
        priority_rates=(20.0, 2.0, 25.0, 100.0),
        long_context_threshold=LONG_CONTEXT_THRESHOLD,
        long_context_rates=(20.0, 2.0, 25.0, 75.0),
        source="https://developers.openai.com/api/docs/models/gpt-6-astra",
    ),
    "gpt-5.6-sol": pricing_rate(
        4.0, 0.4, 20.0,
        cache_write_input_rate=5.0,
        priority_rates=(8.0, 0.8, 10.0, 40.0),
        long_context=True,
    ),
    "gpt-5.6-terra": pricing_rate(
        2.0, 0.2, 12.0,
        cache_write_input_rate=2.5,
        priority_rates=(4.0, 0.4, 5.0, 24.0),
        long_context=True,
    ),
    "gpt-5.6-luna": pricing_rate(
        0.2, 0.02, 1.2,
        cache_write_input_rate=0.25,
        priority_rates=(0.4, 0.04, 0.5, 2.4),
        long_context=True,
    ),
    "gpt-5.6": pricing_rate(
        4.0, 0.4, 20.0,
        cache_write_input_rate=5.0,
        priority_rates=(8.0, 0.8, 10.0, 40.0),
        long_context=True,
    ),
    "gpt-5.6-cyber": pricing_rate(
        12.5, 1.25, 75.0,
        cache_write_input_rate=15.625,
    ),
    "gpt-daybreak-blue-latest": pricing_rate(
        4.0, 0.4, 20.0,
        cache_write_input_rate=5.0,
        priority_rates=(8.0, 0.8, 10.0, 40.0),
        long_context=True,
    ),
    "gpt-daybreak-red-latest": pricing_rate(
        12.5, 1.25, 75.0,
        cache_write_input_rate=15.625,
    ),
    "chat-latest": pricing_rate(
        5.0, 0.5, 30.0,
        source="https://developers.openai.com/api/docs/models/chat-latest",
    ),
    "gpt-5.5-pro": pricing_rate(
        30.0, None, 180.0,
        long_context=True,
    ),
    "gpt-5.5": pricing_rate(
        5.0, 0.5, 30.0,
        priority_rates=(12.5, 1.25, None, 75.0),
        long_context=True,
    ),
    "gpt-5.4-pro": pricing_rate(
        30.0, None, 180.0,
        long_context=True,
    ),
    "gpt-5.4-mini": pricing_rate(
        0.75, 0.075, 4.5,
        priority_rates=(1.5, 0.15, None, 9.0),
    ),
    "gpt-5.4-nano": pricing_rate(0.2, 0.02, 1.25),
    "gpt-5.4": pricing_rate(
        2.5, 0.25, 15.0,
        priority_rates=(5.0, 0.5, None, 30.0),
        long_context=True,
    ),
    "gpt-5.3-codex": pricing_rate(
        1.75,
        0.175,
        14.0,
        priority_rates=(3.5, 0.35, None, 28.0),
        source="https://developers.openai.com/api/docs/models/gpt-5.3-codex",
    ),
    "gpt-5.3-chat-latest": pricing_rate(
        1.75,
        0.175,
        14.0,
        source="https://developers.openai.com/api/docs/models/gpt-5.3-chat-latest",
    ),
    "gpt-5.2-codex": pricing_rate(
        1.75,
        0.175,
        14.0,
        source="https://developers.openai.com/api/docs/models/gpt-5.2-codex",
    ),
    "gpt-5.2-chat-latest": pricing_rate(1.75, 0.175, 14.0),
    "gpt-5.2-pro": pricing_rate(21.0, None, 168.0),
    "gpt-5.2": pricing_rate(
        1.75, 0.175, 14.0,
        priority_rates=(3.5, 0.35, None, 28.0),
    ),
    "gpt-5.1-codex-max": pricing_rate(
        1.25,
        0.125,
        10.0,
        source="https://developers.openai.com/api/docs/models/gpt-5.1-codex-max",
    ),
    "gpt-5.1-codex-mini": pricing_rate(
        0.25,
        0.025,
        2.0,
        source="https://developers.openai.com/api/docs/models/gpt-5.1-codex-mini",
    ),
    "gpt-5.1-codex": pricing_rate(
        1.25,
        0.125,
        10.0,
        source="https://developers.openai.com/api/docs/models/gpt-5.1-codex",
    ),
    "gpt-5.1-chat-latest": pricing_rate(1.25, 0.125, 10.0),
    "gpt-5.1": pricing_rate(
        1.25, 0.125, 10.0,
        priority_rates=(2.5, 0.25, None, 20.0),
    ),
    "gpt-5-codex": pricing_rate(
        1.25,
        0.125,
        10.0,
        source="https://developers.openai.com/api/docs/models/gpt-5-codex",
    ),
    "gpt-5-chat-latest": pricing_rate(1.25, 0.125, 10.0),
    "gpt-5-mini": pricing_rate(
        0.25, 0.025, 2.0,
        priority_rates=(0.45, 0.045, None, 3.6),
    ),
    "gpt-5-nano": pricing_rate(0.05, 0.005, 0.4),
    "gpt-5-pro": pricing_rate(15.0, None, 120.0),
    "gpt-5": pricing_rate(
        1.25, 0.125, 10.0,
        priority_rates=(2.5, 0.25, None, 20.0),
    ),
    "gpt-4.5-preview": pricing_rate(
        75.0,
        37.5,
        150.0,
        source="https://developers.openai.com/api/docs/models/gpt-4.5-preview",
    ),
    "gpt-4.1-mini": pricing_rate(0.4, 0.1, 1.6, priority_rates=(0.7, 0.175, None, 2.8)),
    "gpt-4.1-nano": pricing_rate(0.1, 0.025, 0.4, priority_rates=(0.2, 0.05, None, 0.8)),
    "gpt-4.1": pricing_rate(2.0, 0.5, 8.0, priority_rates=(3.5, 0.875, None, 14.0)),
    "gpt-4o-mini": pricing_rate(0.15, 0.075, 0.6, priority_rates=(0.25, 0.125, None, 1.0)),
    "gpt-4o-2024-05-13": pricing_rate(5.0, None, 15.0),
    "gpt-4o": pricing_rate(2.5, 1.25, 10.0, priority_rates=(4.25, 2.125, None, 17.0)),
    "chatgpt-4o-latest": pricing_rate(5.0, None, 15.0),
    "gpt-4-turbo-2024-04-09": pricing_rate(10.0, None, 30.0),
    "gpt-4-turbo-preview": pricing_rate(10.0, None, 30.0),
    "gpt-4-0125-preview": pricing_rate(10.0, None, 30.0),
    "gpt-4-1106-vision-preview": pricing_rate(10.0, None, 30.0),
    "gpt-4-1106-preview": pricing_rate(10.0, None, 30.0),
    "gpt-4-turbo": pricing_rate(10.0, None, 30.0),
    "gpt-4-32k": pricing_rate(60.0, None, 120.0),
    "gpt-4-0613": pricing_rate(30.0, None, 60.0),
    "gpt-4-0314": pricing_rate(30.0, None, 60.0),
    "gpt-4": pricing_rate(30.0, None, 60.0),
    "gpt-3.5-turbo-16k-0613": pricing_rate(3.0, None, 4.0),
    "gpt-3.5-turbo-instruct": pricing_rate(1.5, None, 2.0),
    "gpt-3.5-turbo-0613": pricing_rate(1.5, None, 2.0),
    "gpt-3.5-turbo-1106": pricing_rate(1.0, None, 2.0),
    "gpt-3.5-turbo-0125": pricing_rate(0.5, None, 1.5),
    "gpt-3.5-0301": pricing_rate(1.5, None, 2.0),
    "gpt-3.5-turbo": pricing_rate(0.5, None, 1.5),
    # Reasoning/Codex names can also appear in older Codex session logs.
    "codex-mini-latest": pricing_rate(
        1.5,
        0.375,
        6.0,
        source="https://developers.openai.com/api/docs/models/codex-mini-latest",
    ),
    "o4-mini": pricing_rate(1.1, 0.275, 4.4, priority_rates=(2.0, 0.5, None, 8.0)),
    "o3-mini": pricing_rate(1.1, 0.55, 4.4),
    "o3-pro": pricing_rate(20.0, None, 80.0),
    "o3": pricing_rate(2.0, 0.5, 8.0, priority_rates=(3.5, 0.875, None, 14.0)),
    "o1-mini": pricing_rate(1.1, 0.55, 4.4),
    "o1-pro": pricing_rate(150.0, None, 600.0),
    "o1": pricing_rate(15.0, 7.5, 60.0),
    # Other providers commonly routed through OpenAI-compatible Codex endpoints.
    "deepseek-v4-pro": pricing_rate(
        1.32,
        0.044,
        3.96,
        cache_write_input_rate=1.32,
        off_peak_rates=(0.66, 0.022, 0.66, 1.98),
        peak_utc_weekday_windows=((1, 4), (6, 10)),
        provider="DeepSeek",
        source="https://api-docs.deepseek.com/quick_start/pricing",
    ),
    "deepseek-v4-flash": pricing_rate(
        0.44,
        0.014,
        1.32,
        cache_write_input_rate=0.44,
        off_peak_rates=(0.22, 0.007, 0.22, 0.66),
        peak_utc_weekday_windows=((1, 4), (6, 10)),
        provider="DeepSeek",
        source="https://api-docs.deepseek.com/quick_start/pricing",
    ),
    "deepseek-v4-flash-vision-exp": pricing_rate(
        0.44,
        0.014,
        1.32,
        cache_write_input_rate=0.44,
        off_peak_rates=(0.22, 0.007, 0.22, 0.66),
        peak_utc_weekday_windows=((1, 4), (6, 10)),
        provider="DeepSeek",
        source="https://api-docs.deepseek.com/quick_start/pricing",
    ),
    "deepseek-reasoner": pricing_rate(
        0.55,
        0.14,
        2.19,
        cache_write_input_rate=0.55,
        provider="DeepSeek",
        source="https://api-docs.deepseek.com/quick_start/pricing-details-usd",
    ),
    "deepseek-chat": pricing_rate(
        0.27,
        0.07,
        1.10,
        cache_write_input_rate=0.27,
        provider="DeepSeek",
        source="https://api-docs.deepseek.com/quick_start/pricing-details-usd",
    ),
    "gemini-3.8-flash": pricing_rate(
        0.75, 0.075, 3.75,
        priority_rates=(1.35, 0.135, None, 6.75),
        provider="Google",
        source="https://ai.google.dev/gemini-api/docs/pricing",
    ),
    "gemini-3.7-flash": pricing_rate(
        0.75, 0.075, 3.75,
        priority_rates=(1.35, 0.135, None, 6.75),
        provider="Google",
        source="https://ai.google.dev/gemini-api/docs/pricing",
    ),
    "gemini-3.6-flash": pricing_rate(
        0.75, 0.075, 3.75,
        priority_rates=(1.35, 0.135, None, 6.75),
        provider="Google",
        source="https://ai.google.dev/gemini-api/docs/pricing",
    ),
    "gemini-3.5-flash-lite": pricing_rate(
        0.3, 0.03, 2.5,
        priority_rates=(0.54, 0.05, None, 4.5),
        provider="Google",
        source="https://ai.google.dev/gemini-api/docs/pricing",
    ),
    "gemini-3.5-flash": pricing_rate(
        1.5, 0.15, 9.0,
        priority_rates=(2.7, 0.27, None, 16.2),
        provider="Google",
        source="https://ai.google.dev/gemini-api/docs/pricing",
    ),
    "gemini-3.1-pro-preview-customtools": pricing_rate(
        2.0, 0.2, 12.0,
        priority_rates=(3.6, 0.36, None, 21.6),
        provider="Google",
        long_context_threshold=200_000,
        long_context_rates=(4.0, 0.4, None, 18.0),
        source="https://ai.google.dev/gemini-api/docs/pricing",
    ),
    "gemini-3.1-pro-preview": pricing_rate(
        2.0, 0.2, 12.0,
        priority_rates=(3.6, 0.36, None, 21.6),
        provider="Google",
        long_context_threshold=200_000,
        long_context_rates=(4.0, 0.4, None, 18.0),
        source="https://ai.google.dev/gemini-api/docs/pricing",
    ),
    "gemini-3.1-flash-lite": pricing_rate(
        0.25, 0.025, 1.5,
        priority_rates=(0.45, 0.045, None, 2.7),
        provider="Google",
        source="https://ai.google.dev/gemini-api/docs/pricing",
    ),
    "gemini-3-flash-preview": pricing_rate(
        0.5, 0.05, 3.0,
        provider="Google",
        source="https://ai.google.dev/gemini-api/docs/pricing",
    ),
    "gemini-2.5-pro": pricing_rate(
        1.25, 0.125, 10.0,
        priority_rates=(2.25, 0.225, None, 18.0),
        provider="Google",
        long_context_threshold=200_000,
        long_context_rates=(2.5, 0.25, None, 15.0),
        source="https://ai.google.dev/gemini-api/docs/pricing",
    ),
    "gemini-2.5-flash-lite": pricing_rate(
        0.1, 0.01, 0.4,
        priority_rates=(0.18, 0.018, None, 0.72),
        provider="Google",
        source="https://ai.google.dev/gemini-api/docs/pricing",
    ),
    "gemini-2.5-flash": pricing_rate(
        0.3, 0.03, 2.5,
        priority_rates=(0.54, 0.054, None, 4.5),
        provider="Google",
        source="https://ai.google.dev/gemini-api/docs/pricing",
    ),
    "gemini-2.0-flash-lite": pricing_rate(
        0.075, None, 0.3,
        provider="Google",
        source="https://ai.google.dev/gemini-api/docs/pricing",
    ),
    "gemini-2.0-flash": pricing_rate(
        0.1, 0.025, 0.4,
        provider="Google",
        source="https://ai.google.dev/gemini-api/docs/pricing",
    ),
    "claude-fable-5-1": pricing_rate(
        10.0, 0.25, 50.0,
        cache_write_input_rate=12.5,
        provider="Anthropic",
        source="https://platform.claude.com/docs/en/about-claude/pricing",
    ),
    "claude-mythos-5-1": pricing_rate(
        10.0, 0.25, 50.0,
        cache_write_input_rate=12.5,
        provider="Anthropic",
        source="https://platform.claude.com/docs/en/about-claude/pricing",
    ),
    "claude-fable-5": pricing_rate(
        10.0, 1.0, 50.0,
        cache_write_input_rate=12.5,
        provider="Anthropic",
        source="https://platform.claude.com/docs/en/about-claude/pricing",
    ),
    "claude-mythos-5": pricing_rate(
        10.0, 1.0, 50.0,
        cache_write_input_rate=12.5,
        provider="Anthropic",
        source="https://platform.claude.com/docs/en/about-claude/pricing",
    ),
    "claude-opus-5": pricing_rate(
        5.0, 0.5, 25.0,
        cache_write_input_rate=6.25,
        provider="Anthropic",
        source="https://platform.claude.com/docs/en/about-claude/pricing",
    ),
    "claude-sonnet-5": pricing_rate(
        2.0, 0.2, 10.0,
        cache_write_input_rate=2.5,
        provider="Anthropic",
        source="https://platform.claude.com/docs/en/about-claude/pricing",
    ),
    "claude-opus-4-8": pricing_rate(
        5.0, 0.5, 25.0,
        cache_write_input_rate=6.25,
        provider="Anthropic",
        source="https://platform.claude.com/docs/en/about-claude/pricing",
    ),
    "claude-opus-4-7": pricing_rate(
        5.0, 0.5, 25.0,
        cache_write_input_rate=6.25,
        provider="Anthropic",
        source="https://platform.claude.com/docs/en/about-claude/pricing",
    ),
    "claude-opus-4-6": pricing_rate(
        5.0, 0.5, 25.0,
        cache_write_input_rate=6.25,
        provider="Anthropic",
        source="https://platform.claude.com/docs/en/about-claude/pricing",
    ),
    "claude-sonnet-4-6": pricing_rate(
        3.0, 0.3, 15.0,
        cache_write_input_rate=3.75,
        provider="Anthropic",
        source="https://platform.claude.com/docs/en/about-claude/pricing",
    ),
    "claude-sonnet-4-5": pricing_rate(
        3.0, 0.3, 15.0,
        cache_write_input_rate=3.75,
        provider="Anthropic",
        source="https://platform.claude.com/docs/en/about-claude/pricing",
    ),
    "claude-haiku-4-5": pricing_rate(
        1.0, 0.1, 5.0,
        cache_write_input_rate=1.25,
        provider="Anthropic",
        source="https://platform.claude.com/docs/en/about-claude/pricing",
    ),
    "grok-4.6": pricing_rate(
        2.0, 0.5, 6.0,
        provider="xAI",
        long_context_threshold=200_000,
        long_context_rates=(4.0, 1.0, None, 12.0),
        source="https://docs.x.ai/developers/pricing",
    ),
    "grok-4.5": pricing_rate(
        2.0, 0.3, 6.0,
        provider="xAI",
        long_context_threshold=200_000,
        long_context_rates=(4.0, 0.6, None, 12.0),
        source="https://docs.x.ai/developers/pricing",
    ),
    "grok-build-0.1": pricing_rate(
        1.0, 0.2, 2.0,
        provider="xAI",
        long_context_threshold=200_000,
        long_context_rates=(2.0, 0.4, None, 4.0),
        source="https://docs.x.ai/developers/pricing",
    ),
    "grok-4.3": pricing_rate(
        1.25, 0.2, 2.5,
        provider="xAI",
        long_context_threshold=200_000,
        long_context_rates=(2.5, 0.4, None, 5.0),
        source="https://docs.x.ai/developers/pricing",
    ),
    "grok-4.20-multi-agent-0309": pricing_rate(
        1.25, 0.2, 2.5,
        provider="xAI",
        long_context_threshold=200_000,
        long_context_rates=(2.5, 0.4, None, 5.0),
        source="https://docs.x.ai/developers/pricing",
    ),
    "grok-4.20-0309-reasoning": pricing_rate(
        1.25, 0.2, 2.5,
        provider="xAI",
        long_context_threshold=200_000,
        long_context_rates=(2.5, 0.4, None, 5.0),
        source="https://docs.x.ai/developers/pricing",
    ),
    "grok-4.20-0309-non-reasoning": pricing_rate(
        1.25, 0.2, 2.5,
        provider="xAI",
        long_context_threshold=200_000,
        long_context_rates=(2.5, 0.4, None, 5.0),
        source="https://docs.x.ai/developers/pricing",
    ),
}
COST_FIELDS = (
    "uncached_input_cost_usd",
    "cached_input_cost_usd",
    "cache_write_input_cost_usd",
    "output_cost_usd",
    "estimated_cost_usd",
    "standard_equivalent_cost_usd",
    "service_tier_premium_usd",
    "cache_savings_usd",
    "standard_cache_savings_usd",
    "standard_cached_input_cost_usd",
    "standard_cache_write_input_cost_usd",
    "priced_tokens",
    "unpriced_tokens",
    "priced_calls",
    "unpriced_calls",
    "long_context_calls",
    "default_tier_calls",
    "priority_tier_calls",
    "other_tier_calls",
    "tier_rate_fallback_calls",
)


@dataclass
class ThreadInfo:
    thread_id: str = ""
    title: str = ""
    title_source: str = ""
    tokens_used: int | None = None
    model: str = ""


@dataclass(frozen=True)
class UsageSource:
    key: str
    label: str
    home: Path
    read_billing_context: bool = True
    read_service_tier: bool = True
    enable_official_pricing: bool = True

    @property
    def sessions_root(self) -> Path:
        return self.home / "sessions"

    @property
    def state_db(self) -> Path:
        return self.home / "state_5.sqlite"

    @property
    def session_index(self) -> Path:
        return self.home / "session_index.jsonl"

    @property
    def auth_file(self) -> Path:
        return self.home / "auth.json"

    @property
    def config_file(self) -> Path:
        return self.home / "config.toml"

    @property
    def model_aliases_file(self) -> Path:
        return self.home / "token_atlas_pricing.json"


def usage_source_from_home(home: Path) -> UsageSource:
    home = home.expanduser().resolve(strict=False)
    is_qodex = home == QODEX_HOME.resolve(strict=False) or home.name.lower() == ".qodex"
    if is_qodex:
        # Qodex can point at a local provider. Token accounting does not require
        # reading its credential-bearing auth or provider configuration files.
        return UsageSource(
            "qodex",
            "Qodex",
            home,
            read_billing_context=False,
            read_service_tier=False,
            enable_official_pricing=False,
        )
    if home == CODEX_HOME.resolve(strict=False):
        return UsageSource("codex", "Codex", home)
    label = (
        "Codex"
        if home.name.lower() == ".codex"
        else clean_text(home.name.lstrip("."), 80) or "Custom"
    )
    key = re.sub(r"[^a-z0-9_-]+", "-", label.lower()).strip("-") or "custom"
    return UsageSource(
        key,
        label,
        home,
        read_billing_context=False,
        read_service_tier=False,
        enable_official_pricing=False,
    )


def normalize_data_home(path: Path) -> Path:
    data_home = path.expanduser().resolve(strict=False)
    if data_home.name == "sessions" and not (data_home / "sessions").is_dir():
        return data_home.parent
    return data_home


def counter_map() -> defaultdict[Any, Counter]:
    return defaultdict(Counter)


def nested_counter_map() -> defaultdict[Any, defaultdict[Any, Counter]]:
    return defaultdict(counter_map)


@dataclass
class SessionDescriptor:
    path: Path
    session_id: str
    parent_id: str
    root_id: str
    dedupe_root_id: str
    lineage_depth: int
    created_at: str
    model_provider: str = ""
    cli_version: str = ""
    originator: str = ""
    source: str = ""
    thread_source: str = ""
    physical_parent_id: str = ""
    conversation_id: str = ""
    is_internal: bool = False
    orphan_internal: bool = False
    context_window: int = 0
    thread: ThreadInfo = field(default_factory=ThreadInfo)
    leading_meta: list[dict[str, Any]] | None = field(default=None, repr=False)


@dataclass
class SessionStats:
    descriptor: SessionDescriptor
    total: Counter = field(default_factory=Counter)
    by_model: dict[str, Counter] = field(default_factory=counter_map)
    by_provider: dict[str, Counter] = field(default_factory=counter_map)
    by_service_tier: dict[str, Counter] = field(default_factory=counter_map)
    by_reasoning_effort: dict[str, Counter] = field(default_factory=counter_map)
    by_route: dict[tuple[str, str, str], Counter] = field(default_factory=counter_map)
    by_day: dict[date, Counter] = field(default_factory=counter_map)
    by_day_model: dict[date, dict[str, Counter]] = field(
        default_factory=nested_counter_map
    )
    costs_by_day: dict[date, Counter] = field(default_factory=counter_map)
    costs_by_day_model: dict[date, dict[str, Counter]] = field(
        default_factory=nested_counter_map
    )
    raw_events: int = 0
    unique_events: int = 0
    inherited_events: int = 0
    local_duplicate_events: int = 0
    null_usage_events: int = 0
    fallback_delta_events: int = 0
    fallback_model_events: int = 0
    repaired_total_events: int = 0
    cached_over_input_events: int = 0
    cache_write_over_input_events: int = 0
    reasoning_over_output_events: int = 0
    inferred_reasoning_events: int = 0
    inferred_reasoning_tokens: int = 0
    heuristic_reasoning_events: int = 0
    missing_timestamp_events: int = 0
    fallback_provider_events: int = 0
    fallback_service_tier_events: int = 0
    first_timestamp: str | None = None
    last_timestamp: str | None = None
    rollout_files: int = 1
    internal_thread_count: int = 0


@dataclass
class FileParserState:
    descriptor: SessionDescriptor
    offset: int = 0
    size: int = 0
    mtime_ns: int = 0
    logical_owner_id: str = ""
    active_turn: str = ""
    active_model: str = ""
    active_provider: str = ""
    active_service_tier: str = DEFAULT_SERVICE_TIER
    active_reasoning_effort: str = ""
    provider_from_event: bool = False
    service_tier_from_event: bool = False
    previous_cumulative: Counter = field(default_factory=Counter)
    pending_reasoning_parts: list[str] = field(default_factory=list)


@dataclass
class BillableUsageEvent:
    session_id: str
    route_provider: str
    model: str
    service_tier: str
    timestamp: datetime
    usage: Counter
    service_tier_inferred: bool | None = None


@dataclass
class UsageReport:
    sessions: list[SessionStats]
    source_key: str = "codex"
    source_label: str = "Codex"
    sessions_root: Path = SESSIONS_ROOT
    model_aliases_path: Path = MODEL_ALIASES_FILE
    billing_context: dict[str, Any] = field(default_factory=dict)
    configured_service_tier_fallback: str = DEFAULT_SERVICE_TIER
    pricing_catalog: dict[str, dict[str, Any]] = field(default_factory=dict)
    custom_pricing_models: set[str] = field(default_factory=set)
    pricing_aliases: dict[str, str] = field(default_factory=dict)
    pricing_config_errors: list[str] = field(default_factory=list)
    pricing_revision: str = ""
    billable_events: list[BillableUsageEvent] = field(default_factory=list)
    totals: Counter = field(default_factory=Counter)
    totals_by_model: dict[str, Counter] = field(default_factory=counter_map)
    totals_by_provider: dict[str, Counter] = field(default_factory=counter_map)
    totals_by_service_tier: dict[str, Counter] = field(default_factory=counter_map)
    totals_by_reasoning_effort: dict[str, Counter] = field(default_factory=counter_map)
    usage_by_route: dict[tuple[str, str, str], Counter] = field(default_factory=counter_map)
    usage_by_day_route: dict[date, dict[tuple[str, str, str], Counter]] = field(
        default_factory=nested_counter_map
    )
    by_day: dict[date, Counter] = field(default_factory=counter_map)
    by_day_model: dict[date, dict[str, Counter]] = field(
        default_factory=nested_counter_map
    )
    by_hour: dict[datetime, Counter] = field(default_factory=counter_map)
    by_hour_model: dict[datetime, dict[str, Counter]] = field(
        default_factory=nested_counter_map
    )
    weekday_hour: dict[tuple[int, int], Counter] = field(default_factory=counter_map)
    weekday_hour_model: dict[tuple[int, int], dict[str, Counter]] = field(
        default_factory=nested_counter_map
    )
    costs_by_model: dict[str, Counter] = field(default_factory=counter_map)
    costs_by_route: dict[tuple[str, str, str], Counter] = field(default_factory=counter_map)
    costs_by_day: dict[date, Counter] = field(default_factory=counter_map)
    costs_by_day_model: dict[date, dict[str, Counter]] = field(
        default_factory=nested_counter_map
    )
    costs_by_day_route: dict[date, dict[tuple[str, str, str], Counter]] = field(
        default_factory=nested_counter_map
    )
    costs_by_hour: dict[datetime, Counter] = field(default_factory=counter_map)
    costs_by_hour_model: dict[datetime, dict[str, Counter]] = field(
        default_factory=nested_counter_map
    )
    costs_weekday_hour: dict[tuple[int, int], Counter] = field(default_factory=counter_map)
    costs_weekday_hour_model: dict[tuple[int, int], dict[str, Counter]] = field(
        default_factory=nested_counter_map
    )
    raw_events: int = 0
    duplicate_events: int = 0
    inherited_events: int = 0
    local_duplicate_events: int = 0
    null_usage_events: int = 0
    fallback_delta_events: int = 0
    fallback_model_events: int = 0
    repaired_total_events: int = 0
    cached_over_input_events: int = 0
    cache_write_over_input_events: int = 0
    reasoning_over_output_events: int = 0
    inferred_reasoning_events: int = 0
    inferred_reasoning_tokens: int = 0
    heuristic_reasoning_events: int = 0
    missing_timestamp_events: int = 0
    fallback_provider_events: int = 0
    fallback_service_tier_events: int = 0
    fork_sessions: int = 0
    rollout_files: int = 0
    conversation_sessions: int = 0
    internal_threads: int = 0
    orphan_internal_threads: int = 0
    sqlite_threads_total_tokens: int = 0
    file_states: dict[str, FileParserState] = field(default_factory=dict, repr=False)
    seen_fingerprints: dict[tuple[Any, ...], str] = field(
        default_factory=dict,
        repr=False,
    )
    inferred_tier_fingerprints: set[tuple[Any, ...]] = field(default_factory=set, repr=False)
    tier_change_requires_rebuild: bool = False
    records_cache: dict[str, Any] | None = field(default=None, repr=False)


@dataclass
class IncrementalCacheEnvelope:
    version: int
    source_home: str
    auxiliary_manifest: list[list[str | int]]
    report: UsageReport


def fmt_int(value: int) -> str:
    return f"{int(value):,}"


def fmt_short(value: int) -> str:
    value = int(value)
    if value >= 1_000_000_000:
        return f"{value / 1_000_000_000:.2f}B"
    if value >= 1_000_000:
        return f"{value / 1_000_000:.1f}M"
    if value >= 1_000:
        return f"{value / 1_000:.1f}K"
    return str(value)


def clean_text(value: Any, limit: int | None = None) -> str:
    if isinstance(value, str):
        raw_text = value
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        raw_text = str(value)
    else:
        raw_text = ""
    text = " ".join(raw_text.split())
    if limit is not None and len(text) > limit:
        return text[: max(0, limit - 1)].rstrip() + "…"
    return text


def source_text(value: Any, limit: int = 200) -> str:
    direct = clean_text(value, limit)
    if direct or not isinstance(value, (dict, list)):
        return direct

    parts: list[str] = []

    def append_part(part: Any) -> None:
        text = clean_text(part)
        if text and text not in parts:
            parts.append(text)

    def visit(node: Any, depth: int = 0) -> None:
        if depth > 4:
            return
        if isinstance(node, dict):
            for key, child in node.items():
                key_text = clean_text(key)
                if isinstance(child, (dict, list)):
                    append_part(key_text)
                    visit(child, depth + 1)
                elif key_text in {"type", "kind", "name", "source", "origin"}:
                    append_part(child)
                elif depth == 0:
                    append_part(key_text)
        elif isinstance(node, list):
            for child in node:
                visit(child, depth + 1)

    visit(value)
    return clean_text(" / ".join(parts), limit)


def safe_int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool) or isinstance(value, (dict, list, tuple, set)):
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def normalized_path(value: str | Path) -> str:
    return str(Path(value).expanduser().resolve(strict=False))


def parse_timestamp(value: str | None, fallback: datetime | None = None) -> datetime:
    if value:
        try:
            normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
            parsed = datetime.fromisoformat(normalized)
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=timezone.utc)
            return parsed.astimezone(LOCAL_TZ)
        except ValueError:
            pass
    if fallback is not None:
        return fallback.astimezone(LOCAL_TZ)
    return datetime.now(LOCAL_TZ)


def read_session_index_names(path: Path = SESSION_INDEX) -> dict[str, str]:
    names: dict[str, str] = {}
    if not path.exists():
        return names
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                row = decode_json(line)
            except ValueError:
                continue
            if not isinstance(row, dict):
                continue
            thread_id = str(row.get("id") or "")
            thread_name = clean_text(row.get("thread_name"))
            if thread_id and thread_name:
                names[thread_id] = thread_name
    return names


def read_thread_info(
    state_db: Path = STATE_DB,
    session_index: Path = SESSION_INDEX,
) -> dict[str, ThreadInfo]:
    indexed_names = read_session_index_names(session_index)
    result = {
        f"id:{thread_id}": ThreadInfo(thread_id=thread_id, title=title, title_source="session_index.thread_name")
        for thread_id, title in indexed_names.items()
    }
    if not state_db.exists():
        return result
    try:
        with sqlite3.connect(state_db.resolve().as_uri() + "?mode=ro", uri=True) as conn:
            conn.row_factory = sqlite3.Row
            columns = {row[1] for row in conn.execute("pragma table_info(threads)")}
            required = {"id", "rollout_path"}
            if not required.issubset(columns):
                return result

            optional = [
                name
                for name in (
                    "title",
                    "first_user_message",
                    "preview",
                    "tokens_used",
                    "model",
                )
                if name in columns
            ]
            select_fields = ["id", "rollout_path", *optional]
            query = f"select {', '.join(select_fields)} from threads"
            for row in conn.execute(query):
                rollout_path = row["rollout_path"]
                if not rollout_path:
                    continue

                thread_id = str(row["id"] or "")
                title = indexed_names.get(thread_id, "")
                title_source = "session_index.thread_name" if title else ""
                if not title:
                    for source in ("title", "first_user_message", "preview"):
                        if source not in columns:
                            continue
                        title = clean_text(row[source])
                        if title:
                            title_source = f"threads.{source}"
                            break

                result[normalized_path(rollout_path)] = ThreadInfo(
                    thread_id=thread_id,
                    title=title,
                    title_source=title_source,
                    tokens_used=(
                        int(row["tokens_used"] or 0)
                        if "tokens_used" in columns
                        else None
                    ),
                    model=(
                        clean_text(row["model"])
                        if "model" in columns
                        else ""
                    ),
                )
            return result
    except sqlite3.Error:
        return result


def read_leading_session_meta(path: Path) -> list[dict[str, Any]]:
    metadata: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                obj = decode_json(line)
            except ValueError:
                if metadata:
                    break
                continue
            if not isinstance(obj, dict):
                if metadata:
                    break
                continue
            if obj.get("type") != "session_meta":
                if metadata:
                    break
                continue
            payload = obj.get("payload")
            if not isinstance(payload, dict):
                if metadata:
                    break
                continue
            source = payload.get("source") or payload.get("thread_source")
            thread_source = clean_text(payload.get("thread_source")).lower()
            source_parent_id = ""
            source_payload = payload.get("source")
            if isinstance(source_payload, dict):
                pending: list[Any] = [source_payload]
                while pending and not source_parent_id:
                    node = pending.pop()
                    if isinstance(node, dict):
                        source_parent_id = str(node.get("parent_thread_id") or "")
                        pending.extend(node.values())
                    elif isinstance(node, list):
                        pending.extend(node)
            top_parent_id = str(payload.get("parent_thread_id") or "")
            forked_from_id = str(payload.get("forked_from_id") or "")
            conversation_id = str(payload.get("session_id") or "")
            source_has_subagent = (
                isinstance(source_payload, dict) and "subagent" in source_payload
            )
            is_internal = bool(
                thread_source == "subagent"
                or source_has_subagent
                or top_parent_id
                or source_parent_id
            )
            physical_parent_id = (
                top_parent_id or source_parent_id or forked_from_id
            )
            if (
                is_internal
                and not physical_parent_id
                and conversation_id
                and conversation_id != str(payload.get("id") or "")
            ):
                physical_parent_id = conversation_id
            metadata.append(
                {
                    "id": str(payload.get("id") or ""),
                    "parent_id": "" if is_internal else forked_from_id,
                    "physical_parent_id": physical_parent_id,
                    "conversation_id": conversation_id,
                    "is_internal": is_internal,
                    "timestamp": str(payload.get("timestamp") or obj.get("timestamp") or ""),
                    "model_provider": clean_text(payload.get("model_provider")),
                    "cli_version": clean_text(payload.get("cli_version")),
                    "originator": clean_text(payload.get("originator")),
                    "source": source_text(source),
                    "thread_source": thread_source,
                    "context_window": safe_int(payload.get("context_window")),
                }
            )
    return metadata


def session_id_from_filename(path: Path) -> str:
    match = re.search(
        r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
        path.name,
        flags=re.IGNORECASE,
    )
    return match.group(1) if match else path.stem


def lineage_root(session_id: str, parent_map: dict[str, str]) -> str:
    current = session_id
    seen: set[str] = set()
    while current and parent_map.get(current) and current not in seen:
        seen.add(current)
        current = parent_map[current]
    return current or session_id


def lineage_depth(session_id: str, parent_map: dict[str, str]) -> int:
    current = session_id
    seen: set[str] = set()
    depth = 0
    while current and parent_map.get(current) and current not in seen:
        seen.add(current)
        current = parent_map[current]
        depth += 1
    return depth


def discover_sessions(
    sessions_root: Path,
    thread_info: dict[str, ThreadInfo],
    cached_states: dict[str, FileParserState] | None = None,
) -> list[SessionDescriptor]:
    paths = sorted(sessions_root.rglob("*.jsonl"))
    leading_meta: dict[Path, list[dict[str, Any]]] = {}
    physical_parent_map: dict[str, str] = {}
    user_parent_map: dict[str, str] = {}
    path_keys = {path: normalized_path(path) for path in paths}

    for path in paths:
        state = (cached_states or {}).get(path_keys[path])
        stat = path.stat()
        if (state is not None and state.descriptor.leading_meta is not None
            and stat.st_size == state.size and stat.st_mtime_ns == state.mtime_ns):
            rows = state.descriptor.leading_meta
        else:
            rows = read_leading_session_meta(path)
        leading_meta[path] = rows
        for row in rows:
            if row["id"]:
                physical_parent_map[row["id"]] = row["physical_parent_id"]
                if not row["is_internal"]:
                    user_parent_map[row["id"]] = row["parent_id"]

    descriptors: list[SessionDescriptor] = []
    for path in paths:
        rows = leading_meta[path]
        first = rows[0] if rows else {}
        session_id = str(first.get("id") or session_id_from_filename(path))
        parent_id = str(first.get("parent_id") or "")
        physical_parent_id = str(first.get("physical_parent_id") or parent_id)
        created_at = str(first.get("timestamp") or "")
        descriptors.append(
            SessionDescriptor(
                path=path,
                session_id=session_id,
                parent_id=parent_id,
                root_id=lineage_root(session_id, user_parent_map),
                dedupe_root_id=lineage_root(session_id, physical_parent_map),
                lineage_depth=lineage_depth(session_id, user_parent_map),
                created_at=created_at,
                model_provider=str(first.get("model_provider") or ""),
                cli_version=str(first.get("cli_version") or ""),
                originator=str(first.get("originator") or ""),
                source=str(first.get("source") or ""),
                thread_source=str(first.get("thread_source") or ""),
                physical_parent_id=physical_parent_id,
                conversation_id=str(first.get("conversation_id") or ""),
                is_internal=bool(first.get("is_internal")),
                context_window=safe_int(first.get("context_window")),
                thread=thread_info.get(path_keys[path], thread_info.get(f"id:{session_id}", ThreadInfo())),
                leading_meta=rows,
            )
        )

    return sorted(
        descriptors,
        key=lambda item: (
            item.dedupe_root_id,
            item.lineage_depth,
            item.created_at,
            str(item.path),
        ),
    )


def raw_usage_tuple(value: dict[str, Any] | None) -> tuple[int, ...] | None:
    if not isinstance(value, dict):
        return None
    return tuple(
        reasoning_tokens_from_values(value)
        if field == "reasoning_output_tokens"
        else int(value.get(field) or 0)
        for field in RAW_USAGE_FIELDS
    )


def reasoning_tokens_from_values(value: dict[str, Any]) -> int:
    direct = int(value.get("reasoning_output_tokens") or 0)
    if direct:
        return direct
    details = value.get("output_tokens_details")
    if isinstance(details, dict):
        return int(details.get("reasoning_tokens") or 0)
    return 0


def normalized_usage_values(value: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(value)
    nested_reasoning = reasoning_tokens_from_values(value)
    if nested_reasoning:
        normalized["reasoning_output_tokens"] = nested_reasoning
    return normalized


def response_reasoning_text(payload: dict[str, Any]) -> str:
    def content_text(content: Any) -> str:
        if isinstance(content, str):
            return content
        if not isinstance(content, list):
            return ""
        return "".join(
            str(part.get("text") or "")
            for part in content
            if isinstance(part, dict)
        )

    if payload.get("type") == "reasoning":
        return content_text(payload.get("content"))
    if payload.get("type") == "message" and payload.get("role") == "assistant":
        text = content_text(payload.get("content"))
        return "\n".join(
            match.group(1)
            for match in re.finditer(
                r"<think\b[^>]*>(.*?)</think\s*>",
                text,
                flags=re.IGNORECASE | re.DOTALL,
            )
        )
    return ""


def heuristic_text_tokens(text: str) -> int:
    compact = "".join(character for character in text if not character.isspace())
    if not compact:
        return 0
    ascii_characters = sum(character.isascii() for character in compact)
    non_ascii_characters = len(compact) - ascii_characters
    return max(1, non_ascii_characters + (ascii_characters + 3) // 4)


class ReasoningTokenCounter:
    def __init__(
        self,
        data_home: Path,
        search_roots: Iterable[Path] = TOKENIZER_SEARCH_ROOTS,
    ) -> None:
        self.data_home = data_home
        self.search_roots = tuple(search_roots)
        self.explicit_paths = self._read_explicit_paths()
        self.candidates: list[Path] | None = None
        self.tokenizers: dict[Path, Any | None] = {}

    @staticmethod
    def model_key(value: str) -> str:
        return re.sub(r"[^a-z0-9]+", "", value.lower())

    def _read_explicit_paths(self) -> dict[str, Path]:
        path = self.data_home / TOKENIZER_MAP_FILE
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        if isinstance(payload, dict) and isinstance(payload.get("models"), dict):
            payload = payload["models"]
        if not isinstance(payload, dict):
            return {}
        result: dict[str, Path] = {}
        for model, configured in payload.items():
            if isinstance(configured, dict):
                configured = configured.get("tokenizer")
            if not isinstance(configured, str) or not configured.strip():
                continue
            configured_path = Path(configured).expanduser()
            if not configured_path.is_absolute():
                configured_path = path.parent / configured_path
            if configured_path.is_dir():
                configured_path /= "tokenizer.json"
            result[str(model).lower()] = configured_path.resolve(strict=False)
        return result

    def _candidate_paths(self) -> list[Path]:
        if self.candidates is not None:
            return self.candidates
        candidates: set[Path] = set()
        direct = self.data_home / "tokenizer.json"
        if direct.is_file():
            candidates.add(direct)
        roots = (self.data_home / "tokenizers",) + self.search_roots
        for root in roots:
            if not root.is_dir():
                continue
            try:
                candidates.update(root.rglob("tokenizer.json"))
            except OSError:
                continue
        self.candidates = sorted(candidates)
        return self.candidates

    def _path_for_model(self, model: str) -> Path | None:
        explicit = self.explicit_paths.get(model.lower())
        if explicit and explicit.is_file():
            return explicit
        needle = self.model_key(model)
        if not needle:
            return None
        matches = [
            path
            for path in self._candidate_paths()
            if needle in self.model_key(str(path.parent))
        ]
        if not matches:
            return None
        return min(matches, key=lambda path: (len(str(path)), str(path)))

    def _load(self, path: Path) -> Any | None:
        if path in self.tokenizers:
            return self.tokenizers[path]
        tokenizer = None
        try:
            from tokenizers import Tokenizer

            tokenizer = Tokenizer.from_file(str(path))
        except (ImportError, OSError, ValueError):
            pass
        self.tokenizers[path] = tokenizer
        return tokenizer

    def count(self, model: str, text: str) -> tuple[int, str]:
        path = self._path_for_model(model)
        if path is not None:
            tokenizer = self._load(path)
            if tokenizer is not None:
                try:
                    return len(tokenizer.encode(text, add_special_tokens=False).ids), "tokenizer"
                except (TypeError, ValueError):
                    pass
        return heuristic_text_tokens(text), "heuristic"


def usage_from_values(
    value: dict[str, Any],
    stats: SessionStats,
) -> Counter:
    input_tokens = int(value.get("input_tokens") or 0)
    cached_tokens = int(value.get("cached_input_tokens") or 0)
    cache_write_tokens = int(value.get("cache_write_input_tokens") or 0)
    output_tokens = int(value.get("output_tokens") or 0)
    reasoning_tokens = reasoning_tokens_from_values(value)
    reported_total = value.get("total_tokens")
    known_total = input_tokens + output_tokens
    total_tokens = int(reported_total) if reported_total is not None else known_total
    if total_tokens < known_total:
        total_tokens = known_total
        stats.repaired_total_events += 1
    if cached_tokens > input_tokens:
        stats.cached_over_input_events += 1
    if cached_tokens + cache_write_tokens > input_tokens:
        stats.cache_write_over_input_events += 1
    if reasoning_tokens > output_tokens:
        stats.reasoning_over_output_events += 1

    return Counter(
        {
            "input_tokens": input_tokens,
            "cached_input_tokens": cached_tokens,
            "cache_write_input_tokens": cache_write_tokens,
            "uncached_input_tokens": max(
                0,
                input_tokens - cached_tokens - cache_write_tokens,
            ),
            "output_tokens": output_tokens,
            "reasoning_output_tokens": reasoning_tokens,
            "unclassified_tokens": max(0, total_tokens - known_total),
            "total_tokens": total_tokens,
            "calls": 1,
        }
    )


def fallback_delta_usage(
    current: dict[str, Any],
    previous: Counter,
    stats: SessionStats,
) -> Counter:
    current_counter = Counter(
        {field: int(current.get(field) or 0) for field in RAW_USAGE_FIELDS}
    )
    reset = current_counter["total_tokens"] < previous["total_tokens"]
    delta = {
        field: (
            current_counter[field]
            if reset
            else max(0, current_counter[field] - previous[field])
        )
        for field in RAW_USAGE_FIELDS
    }
    stats.fallback_delta_events += 1
    return usage_from_values(delta, stats)


def active_model_from_context(payload: dict[str, Any]) -> str:
    direct = clean_text(payload.get("model"))
    if direct:
        return direct
    collaboration = payload.get("collaboration_mode")
    if not isinstance(collaboration, dict):
        return ""
    settings = collaboration.get("settings")
    if not isinstance(settings, dict):
        return ""
    return clean_text(settings.get("model"))


def active_effort_from_context(payload: dict[str, Any]) -> str:
    direct = clean_text(payload.get("effort") or payload.get("reasoning_effort"))
    if direct:
        return direct
    collaboration = payload.get("collaboration_mode")
    if not isinstance(collaboration, dict):
        return ""
    settings = collaboration.get("settings")
    if not isinstance(settings, dict):
        return ""
    return clean_text(settings.get("reasoning_effort"))


def normalize_service_tier(value: Any) -> str:
    normalized = clean_text(str(value or "")).lower()
    if normalized in {"", "auto", "default", "standard"}:
        return DEFAULT_SERVICE_TIER
    if normalized in {"fast", "priority"}:
        return "priority"
    return normalized


def read_configured_service_tier(config_file: Path = CONFIG_FILE) -> str:
    if not config_file.exists():
        return DEFAULT_SERVICE_TIER

    try:
        try:
            import tomllib  # type: ignore[import-not-found]
        except ImportError:
            tomllib = None  # type: ignore[assignment]

        if tomllib is not None:
            with config_file.open("rb") as fh:
                config = tomllib.load(fh)
            return normalize_service_tier(config.get("service_tier"))

        for raw_line in config_file.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if line.startswith("["):
                break
            match = re.fullmatch(
                r"service_tier\s*=\s*(['\"])([^'\"]+)\1\s*(?:#.*)?",
                line,
            )
            if match:
                return normalize_service_tier(match.group(2))
    except (OSError, ValueError):
        pass
    return DEFAULT_SERVICE_TIER


def normalize_provider(value: Any) -> str:
    provider = clean_text(str(value or ""))
    canonical = {
        "openai": "OpenAI",
        "deepseek": "DeepSeek",
        "anthropic": "Anthropic",
        "xai": "xAI",
        "google": "Google",
    }
    return canonical.get(provider.lower(), provider or UNKNOWN_PROVIDER)


def read_billing_context(auth_file: Path = AUTH_FILE) -> dict[str, Any]:
    context = {
        "current_auth_mode": "unknown",
        "has_api_key": False,
        "historical_auth_available": False,
    }
    if not auth_file.exists():
        return context
    try:
        value = json.loads(auth_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return context
    if not isinstance(value, dict):
        return context
    context["current_auth_mode"] = clean_text(value.get("auth_mode")) or "unknown"
    context["has_api_key"] = bool(value.get("OPENAI_API_KEY"))
    return context


def optional_rate(value: Any) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    try:
        rate = float(value)
    except (TypeError, ValueError):
        return None
    return rate if math.isfinite(rate) and rate >= 0 else None


def read_pricing_config(
    path: Path = MODEL_ALIASES_FILE,
    base_catalog: dict[str, dict[str, Any]] | None = None,
) -> tuple[dict[str, str], dict[str, dict[str, Any]], list[str]]:
    if not path.exists():
        return {}, {}, []
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return {}, {}, [f"Cannot read {path.name}: {error}"]
    if not isinstance(value, dict):
        return {}, {}, [f"{path.name} must contain a JSON object"]

    base_models = dict(
        PRICING_USD_PER_MTOK if base_catalog is None else base_catalog
    )
    errors: list[str] = []
    custom_models: dict[str, dict[str, Any]] = {}
    model_values = value.get("models") or {}
    if not isinstance(model_values, dict):
        errors.append(f"{path.name} models must contain a JSON object")
        model_values = {}
    for model, configured in model_values.items():
        if not isinstance(model, str) or not model.strip():
            errors.append("Custom model IDs must be non-empty strings")
            continue
        model_id = normalized_model_id(model)
        if model_id in base_models:
            continue
        if not isinstance(configured, dict):
            errors.append(f"Custom model {model!r} must contain a JSON object")
            continue

        input_rate = optional_rate(configured.get("input"))
        output_rate = optional_rate(configured.get("output"))
        if input_rate is None or output_rate is None:
            errors.append(
                f"Custom model {model!r} requires non-negative input and output rates"
            )
            continue

        cached_input_rate = optional_rate(configured.get("cached_input"))
        cache_write_rate = optional_rate(configured.get("cache_write_input"))
        if "cached_input" in configured and cached_input_rate is None:
            errors.append(f"Custom model {model!r} has an invalid cached_input rate")
            continue
        if "cache_write_input" in configured and cache_write_rate is None:
            errors.append(
                f"Custom model {model!r} has an invalid cache_write_input rate"
            )
            continue

        provider = clean_text(configured.get("provider"), 80) or "Custom"
        custom_models[model_id] = pricing_rate(
            input_rate,
            cached_input_rate if cached_input_rate is not None else input_rate,
            output_rate,
            cache_write_input_rate=(
                cache_write_rate if cache_write_rate is not None else input_rate
            ),
            provider=provider,
            source=path.name,
        )
        custom_models[model_id]["pricing_kind"] = "custom"

    effective_catalog = dict(base_models)
    effective_catalog.update(custom_models)
    aliases: dict[str, str] = {}
    alias_values = value.get("aliases") or {}
    if not isinstance(alias_values, dict):
        errors.append(f"{path.name} aliases must contain a JSON object")
        alias_values = {}
    for key, target in alias_values.items():
        if isinstance(key, str) and isinstance(target, str) and target.strip():
            aliases[key.strip().lower()] = normalized_model_id(target)
        else:
            errors.append("Pricing aliases must map non-empty strings to model IDs")

    for alias, target in aliases.items():
        if target not in effective_catalog:
            errors.append(f"Alias {alias!r} targets unknown priced model {target!r}")
    aliases = {
        alias: target
        for alias, target in aliases.items()
        if target in effective_catalog
    }
    return aliases, custom_models, errors


def read_model_aliases(
    path: Path = MODEL_ALIASES_FILE,
) -> tuple[dict[str, str], list[str]]:
    aliases, _, errors = read_pricing_config(path, PRICING_USD_PER_MTOK)
    return aliases, errors


def current_pricing_configuration(
    source: UsageSource,
) -> tuple[dict[str, dict[str, Any]], dict[str, str], set[str], list[str]]:
    catalog = dict(PRICING_USD_PER_MTOK) if source.enable_official_pricing else {}
    aliases, custom_models, errors = read_pricing_config(
        source.model_aliases_file,
        catalog,
    )
    catalog.update(custom_models)
    return catalog, aliases, set(custom_models), errors


def normalized_model_id(model: str) -> str:
    normalized = model.strip().lower()
    if normalized.startswith("anthropic."):
        normalized = normalized[len("anthropic."):]
    return normalized


def pricing_for_model(
    model: str,
    route_provider: str = "",
    catalog: dict[str, dict[str, Any]] | None = None,
    aliases: dict[str, str] | None = None,
) -> tuple[str, dict[str, Any]] | None:
    catalog = PRICING_USD_PER_MTOK if catalog is None else catalog
    aliases = aliases or {}
    normalized = normalized_model_id(model)
    route_key = f"{route_provider.strip().lower()}/{normalized}" if route_provider else ""
    alias_target = aliases.get(route_key) or aliases.get(normalized)
    if alias_target:
        normalized = normalized_model_id(alias_target)
        route_key = ""

    for candidate in (route_key, normalized):
        if candidate and candidate in catalog:
            return candidate, catalog[candidate]
    for pricing_model in sorted(catalog, key=len, reverse=True):
        if "/" in pricing_model:
            continue
        if (
            normalized.startswith(f"{pricing_model}-20")
            or normalized.startswith(f"{pricing_model}@20")
        ):
            return pricing_model, catalog[pricing_model]
    return None


def standard_rates_for_usage(
    pricing: dict[str, Any],
    usage: Counter,
    timestamp: datetime | None = None,
) -> tuple[dict[str, float | None], bool]:
    input_rate = float(pricing["input"])
    cache_write_rate = optional_rate(pricing.get("cache_write_input"))
    rates: dict[str, float | None] = {
        "input": input_rate,
        "cached_input": optional_rate(pricing.get("cached_input")),
        # Providers without a separate write rate charge cache creation as input.
        "cache_write_input": (
            cache_write_rate if cache_write_rate is not None else input_rate
        ),
        "output": float(pricing["output"]),
    }
    off_peak_rates = pricing.get("off_peak_rates")
    peak_windows = pricing.get("peak_utc_weekday_windows")
    if timestamp is not None and off_peak_rates and peak_windows:
        aware_timestamp = (
            timestamp.replace(tzinfo=timezone.utc)
            if timestamp.tzinfo is None
            else timestamp
        )
        utc_timestamp = aware_timestamp.astimezone(timezone.utc)
        is_peak = utc_timestamp.weekday() < 5 and any(
            int(start) <= utc_timestamp.hour < int(end)
            for start, end in peak_windows
        )
        if not is_peak:
            rates = {
                "input": off_peak_rates[0],
                "cached_input": off_peak_rates[1],
                "cache_write_input": (
                    off_peak_rates[2]
                    if off_peak_rates[2] is not None
                    else off_peak_rates[0]
                ),
                "output": off_peak_rates[3],
            }
    threshold = pricing.get("long_context_threshold")
    if threshold is None and pricing.get("long_context"):
        threshold = LONG_CONTEXT_THRESHOLD
    long_context = bool(threshold and usage["input_tokens"] > int(threshold))
    if not long_context:
        return rates, False

    explicit = pricing.get("long_context_rates")
    if explicit:
        return {
            "input": explicit[0],
            "cached_input": explicit[1],
            "cache_write_input": (
                explicit[2] if explicit[2] is not None else explicit[0]
            ),
            "output": explicit[3],
        }, True

    rates["input"] = float(rates["input"] or 0) * 2.0
    if rates["cached_input"] is not None:
        rates["cached_input"] = float(rates["cached_input"] or 0) * 2.0
    if rates["cache_write_input"] is not None:
        rates["cache_write_input"] = float(rates["cache_write_input"] or 0) * 2.0
    rates["output"] = float(rates["output"] or 0) * 1.5
    return rates, True


def rates_for_service_tier(
    pricing: dict[str, Any],
    standard_rates: dict[str, float | None],
    service_tier: str,
) -> tuple[dict[str, float | None], bool]:
    if service_tier == "default":
        return dict(standard_rates), False
    if service_tier != "priority":
        return dict(standard_rates), True
    priority = pricing.get("priority_rates")
    if not priority:
        return dict(standard_rates), True

    short_input_rate = optional_rate(pricing.get("input"))
    short_cache_write_rate = optional_rate(pricing.get("cache_write_input"))
    short_rates = {
        "input": short_input_rate,
        "cached_input": optional_rate(pricing.get("cached_input")),
        "cache_write_input": (
            short_cache_write_rate
            if short_cache_write_rate is not None
            else short_input_rate
        ),
        "output": optional_rate(pricing.get("output")),
    }
    priority_rates = {
        "input": priority[0],
        "cached_input": priority[1],
        "cache_write_input": (
            priority[2] if priority[2] is not None else priority[0]
        ),
        "output": priority[3],
    }
    selected: dict[str, float | None] = {}
    for field in short_rates:
        standard_short = short_rates[field]
        priority_short = priority_rates[field]
        current_standard = standard_rates[field]
        if priority_short is None or standard_short is None or current_standard is None:
            selected[field] = None
        elif standard_short == 0:
            selected[field] = float(priority_short)
        else:
            selected[field] = (
                float(current_standard) * float(priority_short) / float(standard_short)
            )
    return selected, False


def cost_for_rates(usage: Counter, rates: dict[str, float | None]) -> Counter:
    categories = (
        ("uncached_input_tokens", "input", "uncached_input_cost_usd"),
        ("cached_input_tokens", "cached_input", "cached_input_cost_usd"),
        ("cache_write_input_tokens", "cache_write_input", "cache_write_input_cost_usd"),
        ("output_tokens", "output", "output_cost_usd"),
    )
    result = Counter()
    for token_field, rate_field, cost_field in categories:
        tokens = int(usage[token_field])
        rate = rates.get(rate_field)
        if rate is None:
            result["unpriced_tokens"] += tokens
            continue
        result[cost_field] = tokens / 1_000_000 * float(rate)
        result["priced_tokens"] += tokens
    result["unpriced_tokens"] += int(usage["unclassified_tokens"])
    result["estimated_cost_usd"] = sum(
        result[field]
        for field in (
            "uncached_input_cost_usd",
            "cached_input_cost_usd",
            "cache_write_input_cost_usd",
            "output_cost_usd",
        )
    )
    return result


def estimate_usage_cost(
    route_provider: str,
    model: str,
    service_tier: str,
    usage: Counter,
    catalog: dict[str, dict[str, Any]] | None = None,
    aliases: dict[str, str] | None = None,
    timestamp: datetime | None = None,
) -> Counter:
    pricing_match = pricing_for_model(
        model,
        route_provider,
        catalog,
        aliases,
    )
    if pricing_match is None:
        return Counter(
            {
                "unpriced_tokens": usage["total_tokens"],
                "unpriced_calls": 1,
                "priority_tier_calls": 1 if service_tier == "priority" else 0,
                "default_tier_calls": 1 if service_tier == "default" else 0,
                "other_tier_calls": 1 if service_tier not in {"default", "priority"} else 0,
            }
        )

    _, pricing = pricing_match
    standard_rates, long_context = standard_rates_for_usage(pricing, usage, timestamp)
    selected_rates, tier_fallback = rates_for_service_tier(
        pricing,
        standard_rates,
        service_tier,
    )
    result = cost_for_rates(usage, selected_rates)
    standard_cost = cost_for_rates(usage, standard_rates)
    result["standard_equivalent_cost_usd"] = standard_cost["estimated_cost_usd"]
    result["service_tier_premium_usd"] = max(
        0.0,
        result["estimated_cost_usd"] - standard_cost["estimated_cost_usd"],
    )

    for rates, field in (
        (selected_rates, "cache_savings_usd"),
        (standard_rates, "standard_cache_savings_usd"),
    ):
        input_rate = rates.get("input")
        if input_rate is not None:
            result[field] = sum(
                usage[token_field] / 1_000_000
                * max(0.0, float(input_rate) - float(rates[rate_field]))
                for token_field, rate_field in (
                    ("cached_input_tokens", "cached_input"),
                    ("cache_write_input_tokens", "cache_write_input"),
                )
                if rates.get(rate_field) is not None
            )
    result["standard_cached_input_cost_usd"] = standard_cost["cached_input_cost_usd"]
    result["standard_cache_write_input_cost_usd"] = standard_cost["cache_write_input_cost_usd"]
    result["priced_calls"] = 1 if result["priced_tokens"] else 0
    result["unpriced_calls"] = 1 if result["unpriced_tokens"] and not result["priced_tokens"] else 0
    result["long_context_calls"] = 1 if long_context else 0
    result["default_tier_calls"] = 1 if service_tier == "default" else 0
    result["priority_tier_calls"] = 1 if service_tier == "priority" else 0
    result["other_tier_calls"] = 1 if service_tier not in {"default", "priority"} else 0
    result["tier_rate_fallback_calls"] = 1 if tier_fallback else 0
    return result


def reprice_usage_report(report: UsageReport) -> None:
    for attribute in (
        "costs_by_model",
        "costs_by_route",
        "costs_by_day",
        "costs_by_day_model",
        "costs_by_day_route",
        "costs_by_hour",
        "costs_by_hour_model",
        "costs_weekday_hour",
        "costs_weekday_hour_model",
    ):
        getattr(report, attribute).clear()
    for stats in report.sessions:
        stats.costs_by_day.clear()
        stats.costs_by_day_model.clear()

    sessions_by_id = {
        stats.descriptor.session_id: stats for stats in report.sessions
    }
    logical_owner_by_id = {
        state.descriptor.session_id: state.logical_owner_id
        for state in report.file_states.values()
        if state.logical_owner_id
    }

    for event in report.billable_events:
        timestamp = event.timestamp
        day = timestamp.date()
        hour = timestamp.replace(minute=0, second=0, microsecond=0)
        weekday_hour = (timestamp.weekday(), timestamp.hour)
        route = (event.route_provider, event.model, event.service_tier)
        cost = estimate_usage_cost(
            event.route_provider,
            event.model,
            event.service_tier,
            event.usage,
            report.pricing_catalog,
            report.pricing_aliases,
            timestamp,
        )

        report.costs_by_model[event.model].update(cost)
        report.costs_by_route[route].update(cost)
        report.costs_by_day[day].update(cost)
        report.costs_by_day_model[day][event.model].update(cost)
        report.costs_by_day_route[day][route].update(cost)
        report.costs_by_hour[hour].update(cost)
        report.costs_by_hour_model[hour][event.model].update(cost)
        report.costs_weekday_hour[weekday_hour].update(cost)
        report.costs_weekday_hour_model[weekday_hour][event.model].update(cost)

        owner_id = logical_owner_by_id.get(event.session_id, event.session_id)
        stats = sessions_by_id.get(owner_id)
        if stats is not None:
            stats.costs_by_day[day].update(cost)
            stats.costs_by_day_model[day][event.model].update(cost)


def retier_inferred_usage(report: UsageReport, service_tier: str) -> bool:
    """Rebuild route aggregates from recorded calls when the fallback tier changes."""
    if report.tier_change_requires_rebuild:
        return False
    owners = {state.descriptor.session_id: state.logical_owner_id for state in report.file_states.values()}
    if record_event_provenance(report, owners) is None:
        return False
    seen: dict[tuple[Any, ...], str] = {}
    inferred: set[tuple[Any, ...]] = set()
    for event, (fingerprint, owner) in zip(report.billable_events, report.seen_fingerprints.items()):
        if event.service_tier_inferred is None:
            return False  # Legacy caches need one parse to establish attribution.
        if event.service_tier_inferred:
            fingerprint = (*fingerprint[:4], service_tier, *fingerprint[5:])
            inferred.add(fingerprint)
        if fingerprint in seen:
            return False  # A tier change can alter replay deduplication.
        seen[fingerprint] = owner

    report.seen_fingerprints = seen
    report.inferred_tier_fingerprints = inferred
    report.totals_by_service_tier.clear()
    report.usage_by_route.clear()
    report.usage_by_day_route.clear()
    sessions = {stats.descriptor.session_id: stats for stats in report.sessions}
    for stats in report.sessions:
        stats.by_service_tier.clear()
        stats.by_route.clear()
    for event in report.billable_events:
        if event.service_tier_inferred:
            event.service_tier = service_tier
        route = (event.route_provider, event.model, event.service_tier)
        report.totals_by_service_tier[event.service_tier].update(event.usage)
        report.usage_by_route[route].update(event.usage)
        report.usage_by_day_route[event.timestamp.date()][route].update(event.usage)
        stats = sessions[owners.get(event.session_id, event.session_id)]
        stats.by_service_tier[event.service_tier].update(event.usage)
        stats.by_route[route].update(event.usage)
    for state in report.file_states.values():
        if not state.service_tier_from_event:
            state.active_service_tier = service_tier
    report.configured_service_tier_fallback = service_tier
    return True


def event_fingerprint(
    root_id: str,
    turn_id: str,
    route_provider: str,
    model: str,
    service_tier: str,
    reasoning_effort: str,
    current_usage: dict[str, Any],
    last_usage: dict[str, Any] | None,
    context_window: Any,
) -> tuple[Any, ...]:
    return (
        root_id,
        turn_id or "(no-turn)",
        route_provider,
        model,
        service_tier,
        reasoning_effort,
        raw_usage_tuple(current_usage),
        raw_usage_tuple(last_usage),
        safe_int(context_window),
    )


def add_usage(
    report: UsageReport,
    stats: SessionStats,
    route_provider: str,
    model: str,
    service_tier: str,
    reasoning_effort: str,
    timestamp: datetime,
    usage: Counter,
    *,
    service_tier_inferred: bool = False,
) -> None:
    report.records_cache = None
    report.billable_events.append(BillableUsageEvent(
        session_id=stats.descriptor.session_id,
        route_provider=route_provider,
        model=model,
        service_tier=service_tier,
        timestamp=timestamp,
        usage=Counter(usage),
        service_tier_inferred=service_tier_inferred,
    ))
    day = timestamp.date()
    hour = timestamp.replace(minute=0, second=0, microsecond=0)
    weekday_hour = (timestamp.weekday(), timestamp.hour)

    stats.total.update(usage)
    stats.by_model[model].update(usage)
    stats.by_provider[route_provider].update(usage)
    stats.by_service_tier[service_tier].update(usage)
    stats.by_reasoning_effort[reasoning_effort or "(unknown)"].update(usage)
    stats.by_day[day].update(usage)
    stats.by_day_model[day][model].update(usage)
    route = (route_provider, model, service_tier)
    stats.by_route[route].update(usage)
    report.totals.update(usage)
    report.totals_by_model[model].update(usage)
    report.totals_by_provider[route_provider].update(usage)
    report.totals_by_service_tier[service_tier].update(usage)
    report.totals_by_reasoning_effort[reasoning_effort or "(unknown)"].update(usage)
    report.usage_by_route[route].update(usage)
    report.usage_by_day_route[day][route].update(usage)
    report.by_day[day].update(usage)
    report.by_day_model[day][model].update(usage)
    report.by_hour[hour].update(usage)
    report.by_hour_model[hour][model].update(usage)
    report.weekday_hour[weekday_hour].update(usage)
    report.weekday_hour_model[weekday_hour][model].update(usage)
    cost = estimate_usage_cost(
        route_provider,
        model,
        service_tier,
        usage,
        report.pricing_catalog,
        report.pricing_aliases,
        timestamp,
    )
    stats.costs_by_day[day].update(cost)
    stats.costs_by_day_model[day][model].update(cost)
    report.costs_by_model[model].update(cost)
    report.costs_by_route[route].update(cost)
    report.costs_by_day[day].update(cost)
    report.costs_by_day_model[day][model].update(cost)
    report.costs_by_day_route[day][route].update(cost)
    report.costs_by_hour[hour].update(cost)
    report.costs_by_hour_model[hour][model].update(cost)
    report.costs_weekday_hour[weekday_hour].update(cost)
    report.costs_weekday_hour_model[weekday_hour][model].update(cost)


def merge_session_stats(target: SessionStats, source: SessionStats) -> None:
    target.total.update(source.total)
    for attribute in (
        "by_model",
        "by_provider",
        "by_service_tier",
        "by_reasoning_effort",
        "by_route",
        "by_day",
        "costs_by_day",
    ):
        target_map = getattr(target, attribute)
        for key, value in getattr(source, attribute).items():
            target_map[key].update(value)
    for attribute in (
        "by_day_model",
        "costs_by_day_model",
    ):
        target_map = getattr(target, attribute)
        for outer_key, nested in getattr(source, attribute).items():
            for inner_key, value in nested.items():
                target_map[outer_key][inner_key].update(value)

    for attribute in (
        "raw_events",
        "unique_events",
        "inherited_events",
        "local_duplicate_events",
        "null_usage_events",
        "fallback_delta_events",
        "fallback_model_events",
        "repaired_total_events",
        "cached_over_input_events",
        "cache_write_over_input_events",
        "reasoning_over_output_events",
        "inferred_reasoning_events",
        "inferred_reasoning_tokens",
        "heuristic_reasoning_events",
        "missing_timestamp_events",
        "fallback_provider_events",
        "fallback_service_tier_events",
    ):
        setattr(target, attribute, getattr(target, attribute) + getattr(source, attribute))

    timestamps = [
        value
        for value in (target.first_timestamp, source.first_timestamp)
        if value
    ]
    target.first_timestamp = min(timestamps) if timestamps else None
    timestamps = [
        value
        for value in (target.last_timestamp, source.last_timestamp)
        if value
    ]
    target.last_timestamp = max(timestamps) if timestamps else None
    target.rollout_files += source.rollout_files
    target.internal_thread_count += source.internal_thread_count + 1


def logical_owner_ids(
    descriptors: Iterable[SessionDescriptor],
) -> dict[str, str]:
    descriptors = list(descriptors)
    by_id = {descriptor.session_id: descriptor for descriptor in descriptors}
    visible_ids = {
        descriptor.session_id for descriptor in descriptors if not descriptor.is_internal
    }
    # Memoize physical ancestry independently of conversation_id overrides: an
    # ancestor's override does not change a descendant's physical parent chain.
    physical_owners = {sid: sid for sid in visible_ids}
    result: dict[str, str] = {}
    for descriptor in descriptors:
        if not descriptor.is_internal:
            result[descriptor.session_id] = descriptor.session_id
            continue
        candidate = descriptor.conversation_id
        if candidate and candidate != descriptor.session_id and candidate in visible_ids:
            result[descriptor.session_id] = candidate
            continue
        current = descriptor.session_id
        visited: set[str] = set()
        while current and current not in visited and current not in physical_owners:
            visited.add(current)
            parent = by_id.get(current)
            current = parent.physical_parent_id if parent is not None else ""
        owner = physical_owners.get(current, "")
        for sid in visited:
            physical_owners[sid] = owner
        result[descriptor.session_id] = owner or descriptor.session_id
    return result


def aggregate_internal_threads(report: UsageReport) -> None:
    """Roll physical worker threads into their user-visible conversation."""
    physical_stats = list(report.sessions)
    visible_by_id = {
        stats.descriptor.session_id: stats
        for stats in physical_stats
        if not stats.descriptor.is_internal
    }
    owner_ids = logical_owner_ids(stats.descriptor for stats in physical_stats)

    logical_sessions = [
        stats for stats in physical_stats if not stats.descriptor.is_internal
    ]
    for stats in physical_stats:
        if not stats.descriptor.is_internal:
            continue
        owner = visible_by_id.get(owner_ids.get(stats.descriptor.session_id, ""))
        if owner is not None:
            merge_session_stats(owner, stats)
            continue
        stats.descriptor.orphan_internal = True
        stats.internal_thread_count = max(1, stats.internal_thread_count)
        report.orphan_internal_threads += 1
        logical_sessions.append(stats)

    report.sessions = sorted(
        logical_sessions,
        key=lambda item: (
            item.descriptor.root_id,
            item.descriptor.lineage_depth,
            item.descriptor.created_at,
            str(item.descriptor.path),
        ),
    )


def collect_usage(
    sessions_root: Path = SESSIONS_ROOT,
    thread_info: dict[str, ThreadInfo] | None = None,
    fallback_service_tier: str | None = None,
    *,
    source_key: str = "codex",
    source_label: str = "Codex",
    model_aliases_file: Path = MODEL_ALIASES_FILE,
    billing_context: dict[str, Any] | None = None,
    pricing_catalog: dict[str, dict[str, Any]] | None = None,
    reasoning_counter: ReasoningTokenCounter | None = None,
) -> UsageReport:
    if thread_info is None:
        thread_info = read_thread_info()
    descriptors = discover_sessions(sessions_root, thread_info)
    base_pricing_catalog = (
        dict(PRICING_USD_PER_MTOK)
        if pricing_catalog is None
        else dict(pricing_catalog)
    )
    model_aliases, custom_pricing, pricing_errors = read_pricing_config(
        model_aliases_file,
        base_pricing_catalog,
    )
    base_pricing_catalog.update(custom_pricing)
    configured_service_tier = normalize_service_tier(
        fallback_service_tier
        if fallback_service_tier is not None
        else read_configured_service_tier()
    )
    report = UsageReport(
        sessions=[],
        source_key=source_key,
        source_label=source_label,
        sessions_root=sessions_root,
        model_aliases_path=model_aliases_file,
        billing_context=(
            dict(billing_context)
            if billing_context is not None
            else read_billing_context()
        ),
        configured_service_tier_fallback=configured_service_tier,
        pricing_catalog=base_pricing_catalog,
        custom_pricing_models=set(custom_pricing),
        pricing_aliases=model_aliases,
        pricing_config_errors=pricing_errors,
    )
    report.rollout_files = len(descriptors)
    report.conversation_sessions = sum(not item.is_internal for item in descriptors)
    report.internal_threads = sum(item.is_internal for item in descriptors)
    report.fork_sessions = sum(
        bool(item.parent_id) for item in descriptors if not item.is_internal
    )
    report.sqlite_threads_total_tokens = sum(
        item.thread.tokens_used or 0 for item in descriptors
    )
    reasoning_counter = reasoning_counter or ReasoningTokenCounter(sessions_root.parent)

    seen: dict[tuple[Any, ...], str] = {}
    for descriptor in descriptors:
        stats = SessionStats(descriptor=descriptor)
        active_turn = ""
        active_model = ""
        active_provider = normalize_provider(descriptor.model_provider)
        active_service_tier = configured_service_tier
        active_reasoning_effort = ""
        provider_from_event = bool(descriptor.model_provider)
        service_tier_from_event = False
        previous_cumulative = Counter()
        pending_reasoning_parts: list[str] = []
        fallback_timestamp = parse_timestamp(
            descriptor.created_at,
            datetime.fromtimestamp(descriptor.path.stat().st_mtime, tz=LOCAL_TZ),
        )

        file_offset = 0
        with descriptor.path.open("rb") as fh:
            for line in fh:
                file_offset += len(line)
                if not line.endswith(b"\n"):
                    file_offset -= len(line)
                    break
                if not relevant_usage_line(line):
                    continue
                try:
                    obj = decode_json(line)
                except ValueError:
                    continue
                if not isinstance(obj, dict):
                    continue

                payload = obj.get("payload")
                if not isinstance(payload, dict):
                    continue
                obj_type = obj.get("type")
                if obj_type == "response_item":
                    reasoning_text = response_reasoning_text(payload)
                    if reasoning_text:
                        pending_reasoning_parts.append(reasoning_text)
                if obj_type == "event_msg" and payload.get("type") == "thread_settings_applied":
                    settings = payload.get("thread_settings")
                    if not isinstance(settings, dict):
                        continue
                    settings_model = clean_text(settings.get("model"))
                    if settings_model:
                        active_model = settings_model
                    settings_provider = clean_text(settings.get("model_provider_id"))
                    if settings_provider:
                        active_provider = normalize_provider(settings_provider)
                        provider_from_event = True
                    if "service_tier" in settings:
                        active_service_tier = normalize_service_tier(
                            settings.get("service_tier")
                        )
                        service_tier_from_event = True
                    settings_effort = clean_text(
                        settings.get("reasoning_effort") or settings.get("effort")
                    )
                    if settings_effort:
                        active_reasoning_effort = settings_effort
                    continue
                if obj_type == "turn_context":
                    active_turn = str(payload.get("turn_id") or active_turn)
                    context_model = active_model_from_context(payload)
                    if context_model:
                        active_model = context_model
                    context_effort = active_effort_from_context(payload)
                    if context_effort:
                        active_reasoning_effort = context_effort
                    continue
                if obj_type == "event_msg" and payload.get("type") == "task_started":
                    active_turn = str(payload.get("turn_id") or active_turn)
                    continue
                if obj_type != "event_msg" or payload.get("type") != "token_count":
                    continue

                pending_reasoning_text = "\n".join(pending_reasoning_parts)
                pending_reasoning_parts.clear()
                stats.raw_events += 1
                report.raw_events += 1
                info = payload.get("info")
                if not isinstance(info, dict):
                    stats.null_usage_events += 1
                    report.null_usage_events += 1
                    continue
                raw_current_usage = info.get("total_token_usage")
                if not isinstance(raw_current_usage, dict):
                    stats.null_usage_events += 1
                    report.null_usage_events += 1
                    continue
                current_usage = normalized_usage_values(raw_current_usage)

                raw_last_usage = info.get("last_token_usage")
                last_usage = (
                    normalized_usage_values(raw_last_usage)
                    if isinstance(raw_last_usage, dict)
                    else None
                )
                model = active_model
                if not model:
                    model = descriptor.thread.model
                    if model:
                        stats.fallback_model_events += 1
                if not model:
                    model = UNKNOWN_MODEL
                route_provider = normalize_provider(active_provider)
                provider_fallback = not provider_from_event
                service_tier = normalize_service_tier(active_service_tier)
                service_tier_fallback = not service_tier_from_event
                if isinstance(last_usage, dict):
                    output_for_call = int(last_usage.get("output_tokens") or 0)
                    reported_reasoning = reasoning_tokens_from_values(last_usage)
                else:
                    output_for_call = max(
                        0,
                        int(current_usage.get("output_tokens") or 0)
                        - previous_cumulative["output_tokens"],
                    )
                    reported_reasoning = 0
                inferred_reasoning = 0
                inference_method = ""
                if pending_reasoning_text and not reported_reasoning and output_for_call:
                    inferred_reasoning, inference_method = reasoning_counter.count(
                        model,
                        pending_reasoning_text,
                    )
                    inferred_reasoning = min(output_for_call, inferred_reasoning)
                    if isinstance(last_usage, dict):
                        last_usage["reasoning_output_tokens"] = inferred_reasoning

                current_total = int(current_usage.get("total_tokens") or 0)
                cumulative_reset = current_total < previous_cumulative["total_tokens"]
                if not reasoning_tokens_from_values(current_usage):
                    previous_reasoning = (
                        0
                        if cumulative_reset
                        else previous_cumulative["reasoning_output_tokens"]
                    )
                    call_reasoning = (
                        reasoning_tokens_from_values(last_usage)
                        if isinstance(last_usage, dict)
                        else inferred_reasoning
                    )
                    if current_total == previous_cumulative["total_tokens"]:
                        call_reasoning = 0
                    current_usage["reasoning_output_tokens"] = (
                        previous_reasoning + call_reasoning
                    )
                fingerprint = event_fingerprint(
                    descriptor.dedupe_root_id,
                    active_turn,
                    route_provider,
                    model,
                    service_tier,
                    active_reasoning_effort,
                    raw_current_usage,
                    raw_last_usage if isinstance(raw_last_usage, dict) else None,
                    info.get("model_context_window"),
                )
                owner = seen.get(fingerprint)
                current_cumulative = Counter(
                    {
                        field: int(current_usage.get(field) or 0)
                        for field in RAW_USAGE_FIELDS
                    }
                )
                if owner is not None:
                    if (fingerprint in report.inferred_tier_fingerprints) != service_tier_fallback:
                        report.tier_change_requires_rebuild = True
                    previous_cumulative = current_cumulative
                    report.duplicate_events += 1
                    if owner == descriptor.session_id:
                        stats.local_duplicate_events += 1
                        report.local_duplicate_events += 1
                    else:
                        stats.inherited_events += 1
                        report.inherited_events += 1
                    continue
                seen[fingerprint] = descriptor.session_id
                if service_tier_fallback:
                    report.inferred_tier_fingerprints.add(fingerprint)
                if provider_fallback:
                    stats.fallback_provider_events += 1
                if service_tier_fallback:
                    stats.fallback_service_tier_events += 1
                if inferred_reasoning:
                    stats.inferred_reasoning_events += 1
                    stats.inferred_reasoning_tokens += inferred_reasoning
                    if inference_method == "heuristic":
                        stats.heuristic_reasoning_events += 1

                if isinstance(last_usage, dict):
                    usage = usage_from_values(last_usage, stats)
                else:
                    usage = fallback_delta_usage(
                        current_usage,
                        previous_cumulative,
                        stats,
                    )
                previous_cumulative = current_cumulative

                timestamp_text = str(obj.get("timestamp") or "")
                if not timestamp_text:
                    stats.missing_timestamp_events += 1
                timestamp = parse_timestamp(timestamp_text, fallback_timestamp)
                stats.first_timestamp = stats.first_timestamp or timestamp.isoformat()
                stats.last_timestamp = timestamp.isoformat()
                stats.unique_events += 1
                add_usage(
                    report,
                    stats,
                    route_provider,
                    model,
                    service_tier,
                    active_reasoning_effort,
                    timestamp,
                    usage,
                    service_tier_inferred=service_tier_fallback,
                )

        report.fallback_delta_events += stats.fallback_delta_events
        report.fallback_model_events += stats.fallback_model_events
        report.repaired_total_events += stats.repaired_total_events
        report.cached_over_input_events += stats.cached_over_input_events
        report.cache_write_over_input_events += stats.cache_write_over_input_events
        report.reasoning_over_output_events += stats.reasoning_over_output_events
        report.inferred_reasoning_events += stats.inferred_reasoning_events
        report.inferred_reasoning_tokens += stats.inferred_reasoning_tokens
        report.heuristic_reasoning_events += stats.heuristic_reasoning_events
        report.missing_timestamp_events += stats.missing_timestamp_events
        report.fallback_provider_events += stats.fallback_provider_events
        report.fallback_service_tier_events += stats.fallback_service_tier_events
        report.sessions.append(stats)

        try:
            file_stat = descriptor.path.stat()
            file_size = int(file_stat.st_size)
            file_mtime_ns = int(file_stat.st_mtime_ns)
        except OSError:
            file_size = file_offset
            file_mtime_ns = 0
        report.file_states[normalized_path(descriptor.path)] = FileParserState(
            descriptor=descriptor,
            offset=file_offset,
            size=file_size,
            mtime_ns=file_mtime_ns,
            active_turn=active_turn,
            active_model=active_model,
            active_provider=active_provider,
            active_service_tier=active_service_tier,
            active_reasoning_effort=active_reasoning_effort,
            provider_from_event=provider_from_event,
            service_tier_from_event=service_tier_from_event,
            previous_cumulative=Counter(previous_cumulative),
            pending_reasoning_parts=list(pending_reasoning_parts),
        )

    owner_ids = logical_owner_ids(
        state.descriptor for state in report.file_states.values()
    )
    for state in report.file_states.values():
        state.logical_owner_id = owner_ids.get(
            state.descriptor.session_id,
            state.descriptor.session_id,
        )
    report.seen_fingerprints = dict(seen)
    aggregate_internal_threads(report)
    return report


def descriptor_cache_identity(descriptor: SessionDescriptor) -> tuple[Any, ...]:
    return (
        descriptor.session_id,
        descriptor.parent_id,
        descriptor.root_id,
        descriptor.dedupe_root_id,
        descriptor.lineage_depth,
        descriptor.created_at,
        descriptor.model_provider,
        descriptor.cli_version,
        descriptor.originator,
        descriptor.source,
        descriptor.thread_source,
        descriptor.physical_parent_id,
        descriptor.conversation_id,
        descriptor.is_internal,
        descriptor.context_window,
    )


def process_incremental_file(
    report: UsageReport,
    state: FileParserState,
    target: SessionStats,
    reasoning_counter: ReasoningTokenCounter,
) -> None:
    descriptor = state.descriptor
    fallback_timestamp = parse_timestamp(
        descriptor.created_at,
        datetime.fromtimestamp(descriptor.path.stat().st_mtime, tz=LOCAL_TZ),
    )
    audit_side_effects = (
        "fallback_delta_events",
        "repaired_total_events",
        "cached_over_input_events",
        "cache_write_over_input_events",
        "reasoning_over_output_events",
    )

    with descriptor.path.open("rb") as handle:
        handle.seek(state.offset)
        while True:
            line_start = handle.tell()
            line = handle.readline()
            if not line:
                break
            state.offset = handle.tell()
            if not line.endswith(b"\n"):
                state.offset = line_start
                break
            if not relevant_usage_line(line):
                continue
            try:
                obj = decode_json(line)
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue
            payload = obj.get("payload")
            if not isinstance(payload, dict):
                continue
            obj_type = obj.get("type")
            if obj_type == "response_item":
                reasoning_text = response_reasoning_text(payload)
                if reasoning_text:
                    state.pending_reasoning_parts.append(reasoning_text)
            if obj_type == "event_msg" and payload.get("type") == "thread_settings_applied":
                settings = payload.get("thread_settings")
                if not isinstance(settings, dict):
                    continue
                settings_model = clean_text(settings.get("model"))
                if settings_model:
                    state.active_model = settings_model
                settings_provider = clean_text(settings.get("model_provider_id"))
                if settings_provider:
                    state.active_provider = normalize_provider(settings_provider)
                    state.provider_from_event = True
                if "service_tier" in settings:
                    state.active_service_tier = normalize_service_tier(
                        settings.get("service_tier")
                    )
                    state.service_tier_from_event = True
                settings_effort = clean_text(
                    settings.get("reasoning_effort") or settings.get("effort")
                )
                if settings_effort:
                    state.active_reasoning_effort = settings_effort
                continue
            if obj_type == "turn_context":
                state.active_turn = str(payload.get("turn_id") or state.active_turn)
                context_model = active_model_from_context(payload)
                if context_model:
                    state.active_model = context_model
                context_effort = active_effort_from_context(payload)
                if context_effort:
                    state.active_reasoning_effort = context_effort
                continue
            if obj_type == "event_msg" and payload.get("type") == "task_started":
                state.active_turn = str(payload.get("turn_id") or state.active_turn)
                continue
            if obj_type != "event_msg" or payload.get("type") != "token_count":
                continue

            pending_reasoning_text = "\n".join(state.pending_reasoning_parts)
            state.pending_reasoning_parts.clear()
            target.raw_events += 1
            report.raw_events += 1
            info = payload.get("info")
            if not isinstance(info, dict):
                target.null_usage_events += 1
                report.null_usage_events += 1
                continue
            raw_current_usage = info.get("total_token_usage")
            if not isinstance(raw_current_usage, dict):
                target.null_usage_events += 1
                report.null_usage_events += 1
                continue
            current_usage = normalized_usage_values(raw_current_usage)
            raw_last_usage = info.get("last_token_usage")
            last_usage = (
                normalized_usage_values(raw_last_usage)
                if isinstance(raw_last_usage, dict)
                else None
            )

            model = state.active_model
            if not model:
                model = descriptor.thread.model
                if model:
                    target.fallback_model_events += 1
                    report.fallback_model_events += 1
            if not model:
                model = UNKNOWN_MODEL
            route_provider = normalize_provider(state.active_provider)
            provider_fallback = not state.provider_from_event
            service_tier = normalize_service_tier(state.active_service_tier)
            service_tier_fallback = not state.service_tier_from_event

            if isinstance(last_usage, dict):
                output_for_call = int(last_usage.get("output_tokens") or 0)
                reported_reasoning = reasoning_tokens_from_values(last_usage)
            else:
                output_for_call = max(
                    0,
                    int(current_usage.get("output_tokens") or 0)
                    - state.previous_cumulative["output_tokens"],
                )
                reported_reasoning = 0
            inferred_reasoning = 0
            inference_method = ""
            if pending_reasoning_text and not reported_reasoning and output_for_call:
                inferred_reasoning, inference_method = reasoning_counter.count(
                    model,
                    pending_reasoning_text,
                )
                inferred_reasoning = min(output_for_call, inferred_reasoning)
                if isinstance(last_usage, dict):
                    last_usage["reasoning_output_tokens"] = inferred_reasoning

            current_total = int(current_usage.get("total_tokens") or 0)
            cumulative_reset = current_total < state.previous_cumulative["total_tokens"]
            if not reasoning_tokens_from_values(current_usage):
                previous_reasoning = (
                    0
                    if cumulative_reset
                    else state.previous_cumulative["reasoning_output_tokens"]
                )
                call_reasoning = (
                    reasoning_tokens_from_values(last_usage)
                    if isinstance(last_usage, dict)
                    else inferred_reasoning
                )
                if current_total == state.previous_cumulative["total_tokens"]:
                    call_reasoning = 0
                current_usage["reasoning_output_tokens"] = (
                    previous_reasoning + call_reasoning
                )

            fingerprint = event_fingerprint(
                descriptor.dedupe_root_id,
                state.active_turn,
                route_provider,
                model,
                service_tier,
                state.active_reasoning_effort,
                raw_current_usage,
                raw_last_usage if isinstance(raw_last_usage, dict) else None,
                info.get("model_context_window"),
            )
            owner = report.seen_fingerprints.get(fingerprint)
            current_cumulative = Counter(
                {
                    field: int(current_usage.get(field) or 0)
                    for field in RAW_USAGE_FIELDS
                }
            )
            if owner is not None:
                if (fingerprint in report.inferred_tier_fingerprints) != service_tier_fallback:
                    report.tier_change_requires_rebuild = True
                state.previous_cumulative = current_cumulative
                report.duplicate_events += 1
                if owner == descriptor.session_id:
                    target.local_duplicate_events += 1
                    report.local_duplicate_events += 1
                else:
                    target.inherited_events += 1
                    report.inherited_events += 1
                continue
            report.seen_fingerprints[fingerprint] = descriptor.session_id
            if service_tier_fallback:
                report.inferred_tier_fingerprints.add(fingerprint)
            if provider_fallback:
                target.fallback_provider_events += 1
                report.fallback_provider_events += 1
            if service_tier_fallback:
                target.fallback_service_tier_events += 1
                report.fallback_service_tier_events += 1
            if inferred_reasoning:
                target.inferred_reasoning_events += 1
                target.inferred_reasoning_tokens += inferred_reasoning
                report.inferred_reasoning_events += 1
                report.inferred_reasoning_tokens += inferred_reasoning
                if inference_method == "heuristic":
                    target.heuristic_reasoning_events += 1
                    report.heuristic_reasoning_events += 1

            before = {attribute: getattr(target, attribute) for attribute in audit_side_effects}
            if isinstance(last_usage, dict):
                usage = usage_from_values(last_usage, target)
            else:
                usage = fallback_delta_usage(
                    current_usage,
                    state.previous_cumulative,
                    target,
                )
            for attribute in audit_side_effects:
                setattr(
                    report,
                    attribute,
                    getattr(report, attribute)
                    + getattr(target, attribute)
                    - before[attribute],
                )
            state.previous_cumulative = current_cumulative

            timestamp_text = str(obj.get("timestamp") or "")
            if not timestamp_text:
                target.missing_timestamp_events += 1
                report.missing_timestamp_events += 1
            timestamp = parse_timestamp(timestamp_text, fallback_timestamp)
            target.first_timestamp = target.first_timestamp or timestamp.isoformat()
            target.last_timestamp = timestamp.isoformat()
            target.unique_events += 1
            add_usage(
                report,
                target,
                route_provider,
                model,
                service_tier,
                state.active_reasoning_effort,
                timestamp,
                usage,
                service_tier_inferred=service_tier_fallback,
            )

    try:
        stat = descriptor.path.stat()
        state.size = int(stat.st_size)
        state.mtime_ns = int(stat.st_mtime_ns)
    except OSError:
        state.size = state.offset
        state.mtime_ns = 0


def incrementally_refresh_usage(source: UsageSource) -> UsageReport | None:
    report = load_incremental_cache(source)
    if report is None:
        return None

    thread_info = read_thread_info(source.state_db, source.session_index)
    descriptors = discover_sessions(source.sessions_root, thread_info, report.file_states)
    descriptors_by_path = {
        normalized_path(descriptor.path): descriptor for descriptor in descriptors
    }
    if not set(report.file_states).issubset(descriptors_by_path):
        return None

    owner_ids = logical_owner_ids(descriptors)
    for path_key, state in report.file_states.items():
        descriptor = descriptors_by_path[path_key]
        if descriptor_cache_identity(descriptor) != descriptor_cache_identity(state.descriptor):
            return None
        if owner_ids.get(descriptor.session_id, descriptor.session_id) != state.logical_owner_id:
            return None
        try:
            stat = descriptor.path.stat()
        except OSError:
            return None
        if stat.st_size < state.offset:
            return None
        if stat.st_size == state.size and stat.st_mtime_ns != state.mtime_ns:
            return None
        if descriptor.thread.title != state.descriptor.thread.title:
            report.records_cache = None
        state.descriptor = descriptor

    logical_by_id = {
        stats.descriptor.session_id: stats for stats in report.sessions
    }
    descriptors_by_id = {descriptor.session_id: descriptor for descriptor in descriptors}
    for stats in report.sessions:
        current = descriptors_by_id.get(stats.descriptor.session_id)
        if current is not None:
            stats.descriptor.thread = current.thread

    new_descriptors = [
        descriptor
        for descriptor in descriptors
        if normalized_path(descriptor.path) not in report.file_states
    ]
    if new_descriptors:
        report.records_cache = None
    for descriptor in new_descriptors:
        owner_id = owner_ids.get(descriptor.session_id, descriptor.session_id)
        if owner_id != descriptor.session_id:
            continue
        stats = SessionStats(descriptor=descriptor)
        if descriptor.is_internal:
            descriptor.orphan_internal = True
            stats.internal_thread_count = 1
            report.orphan_internal_threads += 1
        report.sessions.append(stats)
        logical_by_id[descriptor.session_id] = stats

    for descriptor in new_descriptors:
        owner_id = owner_ids.get(descriptor.session_id, descriptor.session_id)
        target = logical_by_id.get(owner_id)
        if target is None:
            return None
        if owner_id != descriptor.session_id:
            target.rollout_files += 1
            target.internal_thread_count += 1
        report.rollout_files += 1
        if descriptor.is_internal:
            report.internal_threads += 1
        else:
            report.conversation_sessions += 1
            if descriptor.parent_id:
                report.fork_sessions += 1
        report.file_states[normalized_path(descriptor.path)] = FileParserState(
            descriptor=descriptor,
            logical_owner_id=owner_id,
            active_provider=normalize_provider(descriptor.model_provider),
            active_service_tier=report.configured_service_tier_fallback,
            provider_from_event=bool(descriptor.model_provider),
        )

    reasoning_counter = ReasoningTokenCounter(source.home)
    for descriptor in descriptors:
        state = report.file_states[normalized_path(descriptor.path)]
        try:
            current_size = descriptor.path.stat().st_size
        except OSError:
            return None
        if current_size <= state.offset:
            continue
        target = logical_by_id.get(state.logical_owner_id)
        if target is None:
            return None
        process_incremental_file(report, state, target, reasoning_counter)

    report.sqlite_threads_total_tokens = sum(
        descriptor.thread.tokens_used or 0 for descriptor in descriptors
    )
    report.sessions.sort(
        key=lambda item: (
            item.descriptor.root_id,
            item.descriptor.lineage_depth,
            item.descriptor.created_at,
            str(item.descriptor.path),
        )
    )
    return report


def counter_dict(value: Counter | dict[str, int] | None = None) -> dict[str, int]:
    value = value or {}
    return {field: int(value.get(field, 0)) for field in USAGE_FIELDS}


def cost_dict(value: Counter | dict[str, float] | None = None) -> dict[str, float | int]:
    value = value or {}
    result: dict[str, float | int] = {}
    for field in COST_FIELDS:
        raw = value.get(field, 0)
        result[field] = round(float(raw), 9) if field.endswith("_usd") else int(raw)
    return result


def build_pricing_data(report: UsageReport, models: list[str]) -> dict[str, Any]:
    aggregate = Counter()
    scopes: dict[str, dict[str, float | int]] = {}
    model_details: dict[str, dict[str, Any]] = {}
    sources: dict[str, str] = {}

    for model in models:
        costs = report.costs_by_model[model]
        aggregate.update(costs)
        scopes[model] = cost_dict(costs)
        route_provider = next(
            (
                provider
                for provider, route_model, _ in report.usage_by_route
                if route_model == model
            ),
            "",
        )
        pricing_match = pricing_for_model(
            model,
            route_provider,
            report.pricing_catalog,
            report.pricing_aliases,
        )
        if pricing_match is None:
            model_details[model] = {
                "pricing_model": None,
                "pricing_kind": None,
                "rates": None,
                "source": None,
                "costs": cost_dict(costs),
            }
            continue
        pricing_model, pricing = pricing_match
        source = str(pricing["source"])
        model_details[model] = {
            "pricing_provider": pricing.get("provider"),
            "pricing_model": pricing_model,
            "pricing_kind": pricing.get("pricing_kind", "official"),
            "rates": {
                "input": float(pricing["input"]),
                "cached_input": (
                    float(pricing["cached_input"])
                    if pricing.get("cached_input") is not None
                    else None
                ),
                "cache_write_input": (
                    float(pricing["cache_write_input"])
                    if pricing.get("cache_write_input") is not None
                    else None
                ),
                "output": float(pricing["output"]),
            },
            "long_context": bool(
                pricing.get("long_context") or pricing.get("long_context_threshold")
            ),
            "rate_note": (
                "Peak rate shown; historical value uses the official UTC "
                "weekday peak/off-peak schedule."
                if pricing.get("off_peak_rates")
                else None
            ),
            "source": source,
            "costs": cost_dict(costs),
        }

    route_details = []
    for route, usage in sorted(
        report.usage_by_route.items(),
        key=lambda item: item[1]["total_tokens"],
        reverse=True,
    ):
        route_provider, model, service_tier = route
        costs = report.costs_by_route[route]
        pricing_match = pricing_for_model(
            model,
            route_provider,
            report.pricing_catalog,
            report.pricing_aliases,
        )
        detail: dict[str, Any] = {
            "route_provider": route_provider,
            "model": model,
            "service_tier": service_tier,
            "usage": counter_dict(usage),
            "costs": cost_dict(costs),
            "pricing_provider": None,
            "pricing_model": None,
            "pricing_kind": None,
            "rates": None,
            "rate_note": None,
            "standard_rates": None,
            "source": None,
            "daily": {
                day.isoformat(): {
                    "usage": counter_dict(report.usage_by_day_route[day][route]),
                    "costs": cost_dict(report.costs_by_day_route[day][route]),
                }
                for day in sorted(report.by_day)
            },
        }
        if pricing_match is not None:
            pricing_model, pricing = pricing_match
            source = str(pricing.get("source") or "")
            sources[str(pricing.get("provider") or "Unknown")] = source
            standard_rates, _ = standard_rates_for_usage(pricing, Counter())
            selected_rates, tier_fallback = rates_for_service_tier(
                pricing,
                standard_rates,
                service_tier,
            )
            detail.update(
                {
                    "pricing_provider": pricing.get("provider"),
                    "pricing_model": pricing_model,
                    "pricing_kind": pricing.get("pricing_kind", "official"),
                    "rates": selected_rates,
                    "standard_rates": standard_rates,
                    "rate_note": (
                        "Peak rate shown; historical value uses the official UTC "
                        "weekday peak/off-peak schedule."
                        if pricing.get("off_peak_rates")
                        else None
                    ),
                    "source": source,
                    "tier_rate_fallback": tier_fallback,
                }
            )
        route_details.append(detail)

    scopes[ALL_MODELS_KEY] = cost_dict(aggregate)
    return {
        "currency": "USD",
        "as_of": PRICING_AS_OF,
        "revision": report.pricing_revision,
        "custom_models": sorted(report.custom_pricing_models),
        "long_context_threshold": LONG_CONTEXT_THRESHOLD,
        "scopes": scopes,
        "models": model_details,
        "routes": route_details,
        "billing_context": {
            **report.billing_context,
            "configured_service_tier_fallback": report.configured_service_tier_fallback,
            "inferred_service_tier_calls": report.fallback_service_tier_events,
        },
        "model_aliases": {
            "path": str(report.model_aliases_path),
            "aliases": len(report.pricing_aliases),
            "errors": report.pricing_config_errors,
        },
        "sources": [
            {"model": model, "url": url}
            for model, url in sorted(sources.items())
            if url
        ],
    }


def iter_dates(start: date, end: date) -> Iterable[date]:
    for offset in range((end - start).days + 1):
        yield start + timedelta(days=offset)


def record_event_provenance(report: UsageReport, owners: dict[str, str]) -> list[tuple[str, str]] | None:
    """Recover physical rollout and turn IDs from the existing parser cache.

    Both parsers insert one fingerprint immediately before appending one billable
    event. Validate the entire ordered pairing before using it for timing records.
    """
    if len(report.seen_fingerprints) != len(report.billable_events):
        return None
    provenance = []
    for event, (fingerprint, physical_id) in zip(report.billable_events, report.seen_fingerprints.items()):
        if len(fingerprint) != 9 or (
            event.route_provider, event.model, event.service_tier
        ) != fingerprint[2:5] or event.session_id not in (physical_id, owners.get(physical_id)):
            return None
        provenance.append((physical_id, fingerprint[1]))
    return provenance


def peak_usage_windows(events: list[BillableUsageEvent], seconds: int) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    """Find independent total/output peaks over sorted events in (end - seconds, end]."""
    peak_total = peak_output = None
    left = total = output = 0
    for right, event in enumerate(events):
        stamp = event.timestamp.timestamp()
        while left < right and events[left].timestamp.timestamp() <= stamp - seconds:
            total -= events[left].usage["total_tokens"]
            output -= events[left].usage["output_tokens"]
            left += 1
        total += event.usage["total_tokens"]
        output += event.usage["output_tokens"]
        new_total = peak_total is None or total > peak_total["total_tokens"]
        new_output = peak_output is None or output > peak_output["output_tokens"]
        if new_total or new_output:
            window = {
                "start": (event.timestamp.astimezone(LOCAL_TZ) - timedelta(seconds=seconds)).isoformat(),
                "end": event.timestamp.astimezone(LOCAL_TZ).isoformat(),
                "window_seconds": seconds, "total_tokens": total, "output_tokens": output,
            }
            if new_total:
                peak_total = window
            if new_output:
                peak_output = window
    return peak_total, peak_output


def build_usage_records(report: UsageReport, today: date | None = None) -> dict[str, Any]:
    """Lifetime records from deduplicated events; no rollout rereads or rate sampling."""
    today = today or datetime.now(LOCAL_TZ).date()
    # Full parses retain physical IDs; incremental appends use logical owners.
    descriptors = {state.descriptor.session_id: state.descriptor for state in report.file_states.values()}
    owners = logical_owner_ids(descriptors.values())
    sessions = {s.descriptor.session_id: s for s in report.sessions}
    visible = [s for s in report.sessions if not s.descriptor.is_internal and s.total["total_tokens"] > 0]
    visible_ids = {s.descriptor.session_id for s in visible}
    # Identity follows the reported model, independent of service tiers and
    # pricing aliases. Keep all identities in footprints for accounting.
    model_usage: dict[str, Counter] = defaultdict(Counter)
    for model, usage in report.totals_by_model.items():
        model_usage[normalized_model_id(model)].update(usage)

    def known_model(model: str) -> bool:
        return model not in ("", "(unknown)", "unknown", "codex-auto-review")

    known_models = {model for model, usage in model_usage.items() if known_model(model) and usage["total_tokens"] > 0}
    models_by_session = {
        s.descriptor.session_id: {
            normalized_model_id(model) for model, usage in s.by_model.items()
            if usage["total_tokens"] > 0 and known_model(normalized_model_id(model))
        }
        for s in visible
    }
    excluded = {sid for sid, stats in sessions.items() if stats.missing_timestamp_events}
    fork_created = {}
    worker_created = {}
    for state in report.file_states.values():
        descriptor = state.descriptor
        try:
            created = datetime.fromisoformat(descriptor.created_at.replace("Z", "+00:00"))
            if created.tzinfo is not None:
                if descriptor.physical_parent_id or descriptor.parent_id:
                    fork_created[descriptor.session_id] = created.timestamp()
                if descriptor.is_internal:
                    worker_created[descriptor.session_id] = created.timestamp()
        except ValueError:
            continue
    provenance = record_event_provenance(report, owners)
    turn_times: dict[str, float | None] = {}

    def turn_timestamp(turn_id: str) -> float | None:
        if turn_id not in turn_times:
            try:
                turn = UUID(turn_id)
                turn_times[turn_id] = (turn.int >> 80) / 1000 if turn.version == 7 else None
            except (ValueError, AttributeError):
                turn_times[turn_id] = None
        return turn_times[turn_id]

    excluded_replay_events = excluded_provenance_events = 0
    eligible_events: list[tuple[BillableUsageEvent, str | None]] = []
    workers: set[str] = set()
    workers_by_session: dict[str, set[str]] = defaultdict(set)
    for index, event in enumerate(report.billable_events):
        if event.usage["total_tokens"] <= 0:
            continue
        owner = owners.get(event.session_id, event.session_id)
        worker_id = None
        if provenance is not None:
            physical_id, turn_id = provenance[index]
            descriptor = descriptors.get(physical_id)
            if descriptor is not None and descriptor.is_internal:
                created = worker_created.get(physical_id)
                turn_time = turn_timestamp(turn_id)
                # A physical rollout can contain copied parent calls, including
                # calls with preserved original timestamps. Participation needs
                # an own post-creation turn and occurrence; missing evidence is
                # insufficient. Repeated calls still count a physical ID once.
                if (created is not None and turn_time is not None and turn_time + 1 >= created
                    and event.timestamp.tzinfo is not None and event.timestamp.timestamp() >= created):
                    worker_id = physical_id
                    workers.add(worker_id)
                    if owner in visible_ids:
                        workers_by_session[owner].add(worker_id)
        # Participation snapshots include every positive confirmed own call;
        # dates and daily patterns require the additional chronology checks.
        if (owner in excluded or event.timestamp.tzinfo is None
            or event.timestamp.astimezone(LOCAL_TZ).date() > today):
            continue
        if provenance is None and report.file_states:
            excluded_provenance_events += 1
            continue
        if provenance is not None:
            physical_id, turn_id = provenance[index]
            created = fork_created.get(physical_id)
            if created is not None:
                turn_time = turn_timestamp(turn_id)
                if turn_time is None and event.timestamp.timestamp() >= created:
                    # Old copied histories can omit turn IDs entirely. Their
                    # rewritten time cannot be distinguished from new activity.
                    excluded_provenance_events += 1
                    continue
                # A pre-existing turn rewritten at/after the fork's creation is
                # inherited history with an unsuitable occurrence timestamp.
                # Preserve original pre-fork timestamps; tolerate 1 s rounding.
                if turn_time is not None and turn_time + 1 < created <= event.timestamp.timestamp():
                    excluded_replay_events += 1
                    continue
        eligible_events.append((event, worker_id))
    eligible_events.sort(key=lambda item: item[0].timestamp.timestamp())
    events = [event for event, _ in eligible_events]
    active_days = sorted({event.timestamp.astimezone(LOCAL_TZ).date() for event in events})
    longest_streak = streak = 0
    longest_start = longest_end = streak_start = previous = None
    streak_unlocks: dict[int, str] = {}
    for day in active_days:
        streak = streak + 1 if previous and day == previous + timedelta(days=1) else 1
        if streak == 1:
            streak_start = day
        if streak > longest_streak:
            longest_streak, longest_start, longest_end = streak, streak_start, day
        for goal in STREAK_ACHIEVEMENT_TARGETS:
            if streak >= goal and goal not in streak_unlocks:
                streak_unlocks[goal] = day.isoformat()
        previous = day
    current_streak = streak if previous in (today, today - timedelta(days=1)) else 0

    peak_total, peak_output = peak_usage_windows(events, PEAK_VOLUME_WINDOW_SECONDS)
    peak_rate, peak_output_rate = peak_usage_windows(events, PEAK_RATE_WINDOW_SECONDS)
    activity: dict[str, dict[str, Any]] = {}
    longest_activity = None
    for event in events:
        stamp = event.timestamp.timestamp()
        owner = owners.get(event.session_id, event.session_id)
        stats = sessions.get(owner)
        if stats is None or stats.descriptor.is_internal:
            continue
        segment = activity.get(owner)
        if segment is None or stamp - segment["last"] > ACTIVITY_GAP_SECONDS:
            segment = {"first": stamp, "last": stamp, "start": event.timestamp.isoformat(), "total_tokens": 0}
            activity[owner] = segment
        segment["last"] = stamp
        segment["total_tokens"] += event.usage["total_tokens"]
        duration = int(stamp - segment["first"])
        if duration > 0 and (longest_activity is None or duration > longest_activity["seconds"]):
            longest_activity = {
                "session_id": owner, "title": clean_text(stats.descriptor.thread.title or "(untitled)", limit=500),
                "start": segment["start"], "end": event.timestamp.isoformat(),
                "seconds": duration, "total_tokens": segment["total_tokens"],
            }

    # One chronological pass establishes the earliest confirmable attainment
    # dates, independently of cumulative counters whose timestamps may be absent.
    unlocks: dict[str, dict[int, str]] = defaultdict(dict)
    day_usage: dict[str, Counter] = defaultdict(Counter)
    day_sessions: dict[str, set[str]] = defaultdict(set)
    day_models: dict[str, set[str]] = defaultdict(set)
    model_dates: dict[str, dict[str, str]] = {}
    observed_models: set[str] = set()
    observed_sessions: set[str] = set()
    observed_session_models: dict[str, set[str]] = defaultdict(set)
    observed_workers: dict[str, set[str]] = defaultdict(set)
    collaborative_days: set[str] = set()
    observed_volumes: Counter = Counter()

    def confirm(key: str, value: int, day: str) -> None:
        for target in RECORD_ACHIEVEMENT_TARGETS[key]:
            if value >= target and target not in unlocks[key]:
                unlocks[key][target] = day

    for event, worker_id in eligible_events:
        day = event.timestamp.astimezone(LOCAL_TZ).date().isoformat()
        model = normalized_model_id(event.model)
        owner = owners.get(event.session_id, event.session_id)
        day_usage[day].update(event.usage)
        model_dates.setdefault(model, {"first_used": day})["last_used"] = day
        if known_model(model):
            day_models[day].add(model)
            observed_models.add(model)
            confirm("models", len(observed_models), day)
        if owner in visible_ids:
            day_sessions[day].add(owner)
            observed_sessions.add(owner)
            confirm("sessions", len(observed_sessions), day)
            confirm("daily_sessions", len(day_sessions[day]), day)
            if known_model(model):
                observed_session_models[owner].add(model)
                confirm("session_models", len(observed_session_models[owner]), day)
            if worker_id is not None:
                observed_workers[owner].add(worker_id)
                collaborative_days.add(day)
                confirm("collaborative_sessions", len(observed_workers), day)
                confirm("collaborative_days", len(collaborative_days), day)
        for key, field_name in RECORD_VOLUME_FIELDS.items():
            observed_volumes[key] += event.usage[field_name]
            confirm(key, observed_volumes[key], day)

    days = [
        {"date": day, "total_tokens": usage["total_tokens"], "output_tokens": usage["output_tokens"],
         "calls": usage["calls"], "sessions": len(day_sessions[day]), "models": len(day_models[day])}
        for day, usage in sorted(day_usage.items())
    ]
    # Ascending days plus max's first-wins behavior makes every tie independent
    # and deterministic, including days with different total/output peaks.
    peak_day = max(days, key=lambda item: item["total_tokens"], default=None)
    peak_output_day = max(days, key=lambda item: item["output_tokens"], default=None)
    busiest_day = max(days, key=lambda item: item["sessions"], default=None)
    most_models_id = min(
        (sid for sid, models in models_by_session.items() if models),
        key=lambda sid: (-len(models_by_session[sid]), sid), default=None,
    )
    most_models_session = None if most_models_id is None else {
        "session_id": most_models_id,
        "title": clean_text(sessions[most_models_id].descriptor.thread.title or "(untitled)", limit=500),
        "model_count": len(models_by_session[most_models_id]), "models": sorted(models_by_session[most_models_id]),
    }
    largest_team_id = min(workers_by_session, key=lambda sid: (-len(workers_by_session[sid]), sid), default=None)
    largest_team_session = None if largest_team_id is None else {
        "session_id": largest_team_id,
        "title": clean_text(sessions[largest_team_id].descriptor.thread.title or "(untitled)", limit=500),
        "worker_count": len(workers_by_session[largest_team_id]),
    }
    insights = {
        "first_active_day": active_days[0].isoformat() if active_days else None,
        "model_count": len(known_models), "collaborative_sessions": len(workers_by_session),
        "worker_count": len(workers), "peak_day": peak_day, "peak_output_day": peak_output_day,
        "busiest_day": busiest_day, "most_models_session": most_models_session,
        "collaborative_days": len(collaborative_days), "largest_team_session": largest_team_session,
        "models": [
            {"id": model, "calls": usage["calls"], "total_tokens": usage["total_tokens"],
             "output_tokens": usage["output_tokens"], "first_used": model_dates.get(model, {}).get("first_used"),
             "last_used": model_dates.get(model, {}).get("last_used")}
            for model, usage in sorted(model_usage.items(), key=lambda item: (-item[1]["calls"], item[0]))
        ],
    }
    largest = max(visible, key=lambda s: s.total["total_tokens"], default=None)
    largest_session = None if largest is None else {
        "session_id": largest.descriptor.session_id,
        "title": clean_text(largest.descriptor.thread.title or "(untitled)", limit=500),
        "total_tokens": largest.total["total_tokens"],
    }
    achievements = []
    for key, title, symbol, category, detail, rule, value, unit in (
        ("streak", "持之以恒", "flame", "habit", "最长连续使用", "按可确认时间的本地日期，记录连续有用量的最长天数。", longest_streak, "天"),
        ("days", "日积月累", "calendar", "habit", "累计活跃", "按可确认时间的本地日期，累计有用量的不同日期。", len(active_days), "天"),
        ("sessions", "对话旅程", "bubble.left.and.bubble.right", "habit", "有用量的逻辑会话", "累计有用量的用户对话，内部工作线程用量归入所属对话。", len(visible), "条"),
        ("models", "模型探索", "sparkles", "exploration", "累计使用的模型", "按报告中的已知模型标识累计，同一标识的服务档位合并计数。", len(known_models), "种"),
        ("session_models", "融会贯通", "square.stack.3d.up", "exploration", "单条对话中的最多模型", "记录单条用户对话使用过的最多已知模型，包含所属内部工作线程。", max(map(len, models_by_session.values()), default=0), "种"),
        ("daily_sessions", "多线展开", "bubble.left.and.text.bubble.right", "exploration", "单日有用量的最多对话", "按可确认时间的本地日期，记录一天内有用量的最多不同用户对话。", busiest_day["sessions"] if busiest_day else 0, "条"),
        ("collaborative_sessions", "携手同行", "person.2", "collaboration", "有内部工作线程参与的对话", "累计有时间与来源可确认的内部线程调用的用户对话；参与按线程创建后的自身调用确认。", len(workers_by_session), "条"),
        ("collaborative_days", "协作日常", "person.3", "collaboration", "累计协作活跃", "按可确认时间的本地日期，累计有内部工作线程自身调用的日期；同一天的不同线程和对话合并计为一天。", len(collaborative_days), "天"),
        ("total_tokens", "用量里程碑", "chart.bar", "volume", "累计 Token", "累计报告总用量；日期以可确认时间的事件累计首次达到门槛为准。", report.totals["total_tokens"], "Token"),
        ("output_tokens", "输出积累", "text.alignleft", "volume", "累计输出 Token", "累计报告输出用量；日期以可确认时间的事件累计首次达到门槛为准。", report.totals["output_tokens"], "Token"),
        ("reasoning_tokens", "推理足迹", "brain", "volume", "累计推理 Token", "累计报告推理用量，包含报告已计入的估算值；日期以可确认时间的事件累计为准。", report.totals["reasoning_output_tokens"], "Token"),
        ("cached_tokens", "缓存接力", "arrow.triangle.2.circlepath", "volume", "累计缓存输入 Token", "累计报告缓存输入用量；日期以可确认时间的事件累计首次达到门槛为准。", report.totals["cached_input_tokens"], "Token"),
    ):
        levels = []
        for name, goal in zip(ACHIEVEMENT_LEVEL_NAMES, RECORD_ACHIEVEMENT_TARGETS[key]):
            unlocked_on = unlocks[key].get(goal) if value >= goal else None
            if key == "streak":
                unlocked_on = streak_unlocks.get(goal)
            elif key == "days" and len(active_days) >= goal:
                unlocked_on = active_days[goal - 1].isoformat()
            levels.append({"name": name, "target": goal, "unlocked_on": unlocked_on, "hidden": name == "钻石"})
        achievements.append({"id": key, "title": title, "symbol": symbol, "detail": detail,
                             "category": category, "rule": rule,
                             "value": value, "current_value": current_streak if key == "streak" else value,
                             "unit": unit, "levels": levels})
    return {
        "as_of": today.isoformat(), "active_days": len(active_days),
        "current_streak": current_streak, "longest_streak": longest_streak,
        "longest_streak_start": longest_start.isoformat() if longest_start else None,
        "longest_streak_end": longest_end.isoformat() if longest_end else None,
        "peak_hour": peak_total, "peak_output_hour": peak_output,
        "peak_throughput": peak_rate, "peak_output_throughput": peak_output_rate,
        "longest_activity": longest_activity, "largest_session": largest_session,
        "achievements": achievements, "insights": insights, "excluded_timestamp_sessions": len(excluded),
        "excluded_replay_events": excluded_replay_events,
        "excluded_provenance_events": excluded_provenance_events,
    }


def cached_usage_records(report: UsageReport) -> dict[str, Any]:
    today = datetime.now(LOCAL_TZ).date()
    if report.records_cache is None or report.records_cache.get("as_of") != today.isoformat():
        report.records_cache = build_usage_records(report, today)
    return report.records_cache


def build_dashboard_data(report: UsageReport) -> dict[str, Any]:
    models = sorted(
        report.totals_by_model,
        key=lambda model: report.totals_by_model[model]["total_tokens"],
        reverse=True,
    )
    active_days = sorted(report.by_day)
    if not active_days:
        active_days = [datetime.now(LOCAL_TZ).date()]

    totals_by_scope = {ALL_MODELS_KEY: counter_dict(report.totals)}
    for model in models:
        totals_by_scope[model] = counter_dict(report.totals_by_model[model])

    hourly: dict[str, list[list[dict[str, int]]]] = {}
    for scope in [ALL_MODELS_KEY, *models]:
        rows: list[list[dict[str, int]]] = []
        for weekday in range(7):
            row: list[dict[str, int]] = []
            for hour in range(24):
                if scope == ALL_MODELS_KEY:
                    usage = report.weekday_hour[(weekday, hour)]
                else:
                    usage = report.weekday_hour_model[(weekday, hour)][scope]
                row.append(counter_dict(usage))
            rows.append(row)
        hourly[scope] = rows

    daily: dict[str, dict[str, dict[str, int]]] = {
        scope: {} for scope in [ALL_MODELS_KEY, *models]
    }
    for day in iter_dates(active_days[0], active_days[-1]):
        daily[ALL_MODELS_KEY][day.isoformat()] = counter_dict(report.by_day[day])
        for model in models:
            daily[model][day.isoformat()] = counter_dict(
                report.by_day_model[day][model]
            )

    timeline_hourly: dict[str, dict[str, dict[str, int]]] = {
        scope: {} for scope in [ALL_MODELS_KEY, *models]
    }
    for hour in sorted(report.by_hour):
        key = hour.strftime("%Y-%m-%dT%H")
        timeline_hourly[ALL_MODELS_KEY][key] = counter_dict(report.by_hour[hour])
        for model in models:
            usage = report.by_hour_model[hour][model]
            if usage["calls"]:
                timeline_hourly[model][key] = counter_dict(usage)

    pricing_data = build_pricing_data(report, models)
    hourly_costs: dict[str, list[list[dict[str, float | int]]]] = {}
    for scope in [ALL_MODELS_KEY, *models]:
        rows = []
        for weekday in range(7):
            row = []
            for hour in range(24):
                if scope == ALL_MODELS_KEY:
                    cost = report.costs_weekday_hour[(weekday, hour)]
                else:
                    cost = report.costs_weekday_hour_model[(weekday, hour)][scope]
                row.append(cost_dict(cost))
            rows.append(row)
        hourly_costs[scope] = rows

    daily_costs: dict[str, dict[str, dict[str, float | int]]] = {
        scope: {} for scope in [ALL_MODELS_KEY, *models]
    }
    for day in iter_dates(active_days[0], active_days[-1]):
        daily_costs[ALL_MODELS_KEY][day.isoformat()] = cost_dict(
            report.costs_by_day[day]
        )
        for model in models:
            daily_costs[model][day.isoformat()] = cost_dict(
                report.costs_by_day_model[day][model]
            )
    pricing_data["hourly"] = hourly_costs
    pricing_data["daily"] = daily_costs
    pricing_data["timeline_hourly"] = {
        scope: {
            hour.strftime("%Y-%m-%dT%H"): cost_dict(
                report.costs_by_hour[hour]
                if scope == ALL_MODELS_KEY
                else report.costs_by_hour_model[hour][scope]
            )
            for hour in sorted(report.by_hour)
            if (
                scope == ALL_MODELS_KEY
                or report.costs_by_hour_model[hour][scope]["priced_calls"]
                or report.costs_by_hour_model[hour][scope]["unpriced_calls"]
            )
        }
        for scope in [ALL_MODELS_KEY, *models]
    }

    sessions = []
    for stats in report.sessions:
        descriptor = stats.descriptor
        title = clean_text(
            descriptor.thread.title or descriptor.path.stem,
            limit=500,
        )
        sessions.append(
            {
                "id": descriptor.session_id,
                "parent_id": descriptor.parent_id,
                "root_id": descriptor.root_id,
                "lineage_depth": descriptor.lineage_depth,
                "model_provider": descriptor.model_provider,
                "cli_version": descriptor.cli_version,
                "originator": descriptor.originator,
                "source": descriptor.source,
                "thread_source": descriptor.thread_source,
                "thread_kind": "internal" if descriptor.is_internal else "user",
                "orphan_internal": descriptor.orphan_internal,
                "context_window": descriptor.context_window,
                "title": title or "(untitled)",
                "title_source": descriptor.thread.title_source,
                "path": str(descriptor.path),
                "file": descriptor.path.name,
                "first_timestamp": stats.first_timestamp,
                "last_timestamp": stats.last_timestamp,
                "totals": counter_dict(stats.total),
                "by_model": {
                    model: counter_dict(usage)
                    for model, usage in stats.by_model.items()
                },
                "by_provider": {
                    provider: counter_dict(usage)
                    for provider, usage in stats.by_provider.items()
                },
                "by_service_tier": {
                    tier: counter_dict(usage)
                    for tier, usage in stats.by_service_tier.items()
                },
                "by_reasoning_effort": {
                    effort: counter_dict(usage)
                    for effort, usage in stats.by_reasoning_effort.items()
                },
                "by_day": {
                    day.isoformat(): counter_dict(usage)
                    for day, usage in sorted(stats.by_day.items())
                },
                "by_day_model": {
                    day.isoformat(): {
                        model: counter_dict(usage)
                        for model, usage in by_model.items()
                    }
                    for day, by_model in sorted(stats.by_day_model.items())
                },
                "costs_by_day": {
                    day.isoformat(): cost_dict(cost)
                    for day, cost in sorted(stats.costs_by_day.items())
                },
                "costs_by_day_model": {
                    day.isoformat(): {
                        model: cost_dict(cost)
                        for model, cost in by_model.items()
                    }
                    for day, by_model in sorted(stats.costs_by_day_model.items())
                },
                "unique_events": stats.unique_events,
                "inherited_events": stats.inherited_events,
                "local_duplicate_events": stats.local_duplicate_events,
                "rollout_files": stats.rollout_files,
                "internal_thread_count": stats.internal_thread_count,
            }
        )

    generated_at = datetime.now(LOCAL_TZ)
    return {
        "source_id": report.source_key,
        "source_label": report.source_label,
        "generated_at": generated_at.isoformat(),
        "generated_at_label": generated_at.strftime("%Y-%m-%d %H:%M:%S %Z"),
        "timezone": LOCAL_TZ.key,
        "range": {
            "start": active_days[0].isoformat(),
            "end": active_days[-1].isoformat(),
        },
        "models": models,
        "totals": totals_by_scope,
        "pricing": pricing_data,
        "breakdowns": {
            "providers": {
                provider: counter_dict(usage)
                for provider, usage in sorted(report.totals_by_provider.items())
            },
            "service_tiers": {
                tier: counter_dict(usage)
                for tier, usage in sorted(report.totals_by_service_tier.items())
            },
            "reasoning_efforts": {
                effort: counter_dict(usage)
                for effort, usage in sorted(report.totals_by_reasoning_effort.items())
            },
        },
        "hourly": hourly,
        "timeline_hourly": timeline_hourly,
        "daily": daily,
        "sessions": sessions,
        "records": cached_usage_records(report),
        "audit": {
            "session_files": report.rollout_files,
            "sessions_with_usage": sum(
                stats.total["total_tokens"] > 0 for stats in report.sessions
            ),
            "conversation_sessions": report.conversation_sessions,
            "logical_sessions": len(report.sessions),
            "internal_threads": report.internal_threads,
            "orphan_internal_threads": report.orphan_internal_threads,
            "fork_sessions": report.fork_sessions,
            "raw_token_events": report.raw_events,
            "unique_model_calls": int(report.totals["calls"]),
            "duplicate_events": report.duplicate_events,
            "inherited_events": report.inherited_events,
            "local_duplicate_events": report.local_duplicate_events,
            "null_usage_events": report.null_usage_events,
            "fallback_delta_events": report.fallback_delta_events,
            "fallback_model_events": report.fallback_model_events,
            "repaired_total_events": report.repaired_total_events,
            "cached_over_input_events": report.cached_over_input_events,
            "cache_write_over_input_events": report.cache_write_over_input_events,
            "reasoning_over_output_events": report.reasoning_over_output_events,
            "inferred_reasoning_events": report.inferred_reasoning_events,
            "inferred_reasoning_tokens": report.inferred_reasoning_tokens,
            "heuristic_reasoning_events": report.heuristic_reasoning_events,
            "missing_timestamp_events": report.missing_timestamp_events,
            "fallback_provider_events": report.fallback_provider_events,
            "fallback_service_tier_events": report.fallback_service_tier_events,
            "configured_service_tier_fallback": report.configured_service_tier_fallback,
            "pricing_config_errors": len(report.pricing_config_errors),
            "sqlite_threads_total_tokens": report.sqlite_threads_total_tokens,
        },
    }


HTML_TEMPLATE = r"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Codex Token Atlas</title>
<style>
:root {
  color-scheme: light;
  --ink: #102a2a;
  --ink-soft: #3e5c59;
  --muted: #6d817e;
  --line: #cfdcd8;
  --line-strong: #a9bfba;
  --surface: rgba(255, 255, 255, 0.88);
  --surface-solid: #ffffff;
  --canvas: #eef5f2;
  --teal: #087968;
  --teal-deep: #044e47;
  --coral: #e86f51;
  --amber: #d89a2b;
  --zero: #e5ece9;
  --shadow: 0 18px 50px rgba(26, 73, 67, 0.09);
}
* { box-sizing: border-box; }
html { min-width: 320px; }
body {
  margin: 0;
  min-height: 100vh;
  overflow-x: hidden;
  color: var(--ink);
  font-family: "Avenir Next", Avenir, "Helvetica Neue", sans-serif;
  background:
    linear-gradient(rgba(9, 83, 72, 0.045) 1px, transparent 1px),
    linear-gradient(90deg, rgba(9, 83, 72, 0.045) 1px, transparent 1px),
    radial-gradient(circle at 85% 3%, rgba(232, 111, 81, 0.14), transparent 31%),
    var(--canvas);
  background-size: 28px 28px, 28px 28px, auto, auto;
}
button, select { font: inherit; }
.shell {
  width: min(1420px, calc(100% - 40px));
  margin: 0 auto;
  padding: 32px 0 56px;
}
.masthead {
  position: relative;
  overflow: hidden;
  padding: 30px 34px 26px;
  border: 1px solid rgba(8, 121, 104, 0.22);
  background: linear-gradient(135deg, rgba(255,255,255,.96), rgba(241,250,247,.88));
  box-shadow: var(--shadow);
}
.masthead::after {
  content: "";
  position: absolute;
  inset: auto -32px -46px auto;
  width: 230px;
  height: 120px;
  border: 18px solid rgba(8, 121, 104, 0.08);
  transform: rotate(-8deg);
}
.eyebrow {
  color: var(--teal);
  font: 700 11px/1.2 ui-monospace, SFMono-Regular, Menlo, monospace;
  letter-spacing: 0.14em;
  text-transform: uppercase;
}
.masthead-row {
  position: relative;
  z-index: 1;
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 24px;
  margin-top: 10px;
}
h1 {
  margin: 0;
  font: 700 54px/0.98 "Avenir Next", Avenir, sans-serif;
  letter-spacing: 0;
}
.subtitle {
  max-width: 720px;
  margin: 14px 0 0;
  color: var(--ink-soft);
  font-size: 15px;
}
.status-stamp {
  flex: 0 0 auto;
  padding: 11px 14px;
  border-left: 3px solid var(--coral);
  background: rgba(232, 111, 81, 0.08);
  color: #85402e;
  font: 700 12px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
}
.controls {
  position: relative;
  z-index: 1;
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  margin-top: 24px;
}
.control {
  display: flex;
  align-items: center;
  gap: 9px;
  min-height: 42px;
  padding: 6px 8px 6px 13px;
  border: 1px solid var(--line-strong);
  background: rgba(255,255,255,.9);
}
.control span {
  color: var(--muted);
  font-size: 12px;
  font-weight: 700;
}
select {
  min-width: 180px;
  border: 0;
  outline: 0;
  color: var(--ink);
  background: transparent;
  font-weight: 650;
  cursor: pointer;
}
.stats {
  display: grid;
  grid-template-columns: repeat(6, minmax(0, 1fr));
  gap: 10px;
  margin: 18px 0;
}
.stat {
  min-height: 118px;
  padding: 17px 18px;
  border-top: 3px solid var(--teal);
  background: var(--surface);
  box-shadow: 0 8px 22px rgba(26, 73, 67, 0.055);
}
.stat:nth-child(3n) { border-top-color: var(--coral); }
.stat:nth-child(4n) { border-top-color: var(--amber); }
.stat-label {
  color: var(--muted);
  font-size: 11px;
  font-weight: 750;
  text-transform: uppercase;
  letter-spacing: .06em;
}
.stat-value {
  display: block;
  margin-top: 12px;
  font: 700 clamp(21px, 2vw, 30px)/1 ui-monospace, SFMono-Regular, Menlo, monospace;
  letter-spacing: -0.04em;
}
.stat-detail {
  display: block;
  margin-top: 8px;
  color: var(--muted);
  font-size: 11px;
}
.panel {
  margin-top: 14px;
  border: 1px solid var(--line);
  background: var(--surface);
  box-shadow: 0 10px 30px rgba(26, 73, 67, 0.055);
}
.panel-inner { padding: 22px 24px 24px; }
.panel-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 18px;
  margin-bottom: 18px;
}
h2 {
  margin: 0;
  font-size: 19px;
  line-height: 1.2;
}
.panel-kicker {
  margin: 6px 0 0;
  color: var(--muted);
  font-size: 12px;
}
.scale-note {
  flex: 0 0 auto;
  color: var(--muted);
  font: 600 11px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
  text-align: right;
}
.scroll-x {
  overflow-x: auto;
  padding: 3px 2px 10px;
}
.hour-grid {
  display: grid;
  grid-template-columns: 66px repeat(24, minmax(27px, 1fr));
  gap: 5px;
  min-width: 970px;
  align-items: center;
}
.hour-label, .day-label {
  color: var(--muted);
  font: 650 10px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
  text-align: center;
}
.day-label {
  padding-right: 8px;
  color: var(--ink-soft);
  text-align: right;
  font-family: "Avenir Next", Avenir, sans-serif;
  font-size: 12px;
}
.heat-cell {
  width: 100%;
  aspect-ratio: 1;
  min-height: 27px;
  padding: 0;
  border: 1px solid rgba(8, 78, 71, 0.08);
  border-radius: 2px;
  outline: none;
  cursor: crosshair;
  transition: transform .12s ease, box-shadow .12s ease;
}
.heat-cell:hover, .heat-cell:focus-visible {
  position: relative;
  z-index: 2;
  transform: scale(1.16);
  box-shadow: 0 0 0 2px var(--surface-solid), 0 0 0 4px var(--coral);
}
.legend-row {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 10px;
  margin-top: 12px;
  color: var(--muted);
  font-size: 11px;
}
.gradient-bar {
  width: 180px;
  height: 9px;
  background: linear-gradient(90deg, #dcebe6, #84cdb8, #18927a, #034e46);
  border: 1px solid rgba(8, 78, 71, 0.12);
}
.calendar-layout { min-width: max-content; }
.month-labels {
  display: grid;
  gap: 4px;
  margin-left: 44px;
  min-height: 22px;
  color: var(--muted);
  font: 650 10px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
}
.calendar-row { display: flex; gap: 8px; }
.calendar-weekdays {
  display: grid;
  grid-template-rows: repeat(7, 18px);
  gap: 4px;
  width: 36px;
  color: var(--muted);
  font-size: 10px;
  line-height: 18px;
  text-align: right;
}
.calendar-cells {
  display: grid;
  grid-auto-flow: column;
  grid-template-rows: repeat(7, 18px);
  grid-auto-columns: 18px;
  gap: 4px;
}
.calendar-cell { min-height: 18px; border-radius: 2px; }
.split {
  display: grid;
  grid-template-columns: minmax(0, .92fr) minmax(0, 1.08fr);
  gap: 14px;
}
.table-wrap { width: 100%; max-width: 100%; overflow-x: auto; }
.panel, .panel-inner { min-width: 0; }
table {
  width: 100%;
  border-collapse: collapse;
  font-size: 12px;
}
th, td {
  padding: 10px 9px;
  border-bottom: 1px solid var(--line);
  text-align: right;
  white-space: nowrap;
}
th {
  color: var(--muted);
  font-size: 10px;
  letter-spacing: .04em;
  text-transform: uppercase;
}
th:first-child, td:first-child { text-align: left; }
tbody tr:hover { background: rgba(8, 121, 104, 0.045); }
.model-button {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  padding: 0;
  border: 0;
  color: var(--ink);
  background: transparent;
  font-weight: 700;
  cursor: pointer;
}
.model-dot {
  width: 9px;
  height: 9px;
  border-radius: 50%;
  background: var(--dot);
}
.active-row { background: rgba(232, 111, 81, 0.08); }
.share-track {
  display: inline-block;
  width: 70px;
  height: 5px;
  margin-left: 8px;
  background: var(--zero);
  vertical-align: middle;
}
.share-fill { display: block; height: 100%; background: var(--teal); }
.session-title {
  display: block;
  max-width: 520px;
  overflow: hidden;
  color: var(--ink);
  font-weight: 650;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.session-id {
  display: block;
  margin-top: 3px;
  color: var(--muted);
  font: 10px/1.2 ui-monospace, SFMono-Regular, Menlo, monospace;
}
.badge {
  display: inline-block;
  margin: 1px 3px 1px 0;
  padding: 2px 6px;
  border: 1px solid var(--line);
  color: var(--ink-soft);
  background: #f5faf8;
  font: 600 9px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
}
.fork-badge { border-color: rgba(232,111,81,.35); color: #98462f; background: #fff5f1; }
.provider-badge { border-color: rgba(8,121,104,.3); color: var(--teal-deep); }
.tier-badge { border-color: rgba(216,154,43,.42); color: #7b5712; background: #fff9eb; }
.cost-strip {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  margin-bottom: 18px;
  border: 1px solid var(--line);
  background: var(--surface-solid);
}
.cost-metric {
  min-height: 104px;
  padding: 17px 18px;
  border-left: 1px solid var(--line);
}
.cost-metric:first-child { border-left: 0; }
.cost-label {
  display: block;
  color: var(--muted);
  font-size: 10px;
  font-weight: 750;
  letter-spacing: .05em;
  text-transform: uppercase;
}
.cost-value {
  display: block;
  margin-top: 11px;
  color: var(--teal-deep);
  font: 700 25px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
}
.cost-detail {
  display: block;
  margin-top: 8px;
  color: var(--muted);
  font-size: 10px;
}
.pricing-sources {
  display: flex;
  flex-wrap: wrap;
  gap: 6px 12px;
  margin-top: 14px;
  font-size: 11px;
}
.pricing-sources a { color: var(--teal); text-underline-offset: 3px; }
.cost-warning { color: #9a4a34; font-weight: 700; }
.audit-grid {
  display: grid;
  grid-template-columns: repeat(6, minmax(0, 1fr));
  gap: 1px;
  border: 1px solid var(--line);
  background: var(--line);
}
.audit-item { min-height: 82px; padding: 14px; background: var(--surface-solid); }
.audit-item span { display: block; color: var(--muted); font-size: 10px; text-transform: uppercase; }
.audit-item strong { display: block; margin-top: 8px; font: 700 18px/1 ui-monospace, SFMono-Regular, Menlo, monospace; }
.method {
  margin: 16px 0 0;
  padding-left: 14px;
  border-left: 3px solid var(--teal);
  color: var(--ink-soft);
  font-size: 12px;
  line-height: 1.65;
  overflow-wrap: anywhere;
}
.footer {
  display: flex;
  justify-content: space-between;
  gap: 20px;
  margin-top: 18px;
  color: var(--muted);
  font: 10px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
}
.tooltip {
  white-space: pre-line;
  position: fixed;
  z-index: 99;
  max-width: 310px;
  padding: 10px 12px;
  pointer-events: none;
  opacity: 0;
  color: #f5fffc;
  background: #0d3532;
  box-shadow: 0 10px 30px rgba(0,0,0,.22);
  font-size: 11px;
  line-height: 1.5;
  transform: translateY(4px);
  transition: opacity .08s ease, transform .08s ease;
}
.tooltip.visible { opacity: 1; transform: translateY(0); }
@media (max-width: 1120px) {
  .stats { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .cost-strip { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .cost-metric:nth-child(3) { border-left: 0; border-top: 1px solid var(--line); }
  .cost-metric:nth-child(4) { border-top: 1px solid var(--line); }
  .audit-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .split { grid-template-columns: 1fr; }
}
@media (max-width: 720px) {
  .shell { width: min(100% - 20px, 1420px); padding-top: 10px; }
  .masthead { padding: 22px 20px; }
  h1 { font-size: 38px; }
  .masthead-row { align-items: flex-start; flex-direction: column; }
  .status-stamp { align-self: stretch; }
  .controls { flex-direction: column; }
  .control { justify-content: space-between; }
  select { min-width: 0; max-width: 62vw; }
  .stats { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .stat { min-height: 105px; padding: 14px; }
  .panel-inner { padding: 18px 15px; }
  .panel-head { flex-direction: column; }
  .scale-note { text-align: left; }
  .audit-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .footer { flex-direction: column; }
}
@media (max-width: 430px) {
  .stats { grid-template-columns: 1fr; }
  .cost-strip { grid-template-columns: 1fr; }
  .cost-metric, .cost-metric:nth-child(3) { border-left: 0; border-top: 1px solid var(--line); }
  .cost-metric:first-child { border-top: 0; }
  .audit-grid { grid-template-columns: 1fr 1fr; }
}
</style>
</head>
<body>
<main class="shell">
  <header class="masthead">
    <div class="eyebrow">Local __SOURCE_LABEL__ Telemetry / Asia Shanghai</div>
    <div class="masthead-row">
      <div>
        <h1>Token Atlas</h1>
        <p class="subtitle" id="subtitle"></p>
      </div>
      <div class="status-stamp">FORK SAFE<br>PROVIDER AWARE<br>TIER AWARE<br>HOURLY RESOLUTION</div>
    </div>
    <div class="controls">
      <label class="control"><span>模型</span><select id="modelSelect"></select></label>
      <label class="control"><span>指标</span><select id="metricSelect"></select></label>
    </div>
  </header>

  <section class="stats" aria-label="Usage summary">
    <article class="stat"><span class="stat-label">Total tokens</span><strong class="stat-value" id="totalValue">0</strong><small class="stat-detail" id="totalDetail"></small></article>
    <article class="stat"><span class="stat-label">Input</span><strong class="stat-value" id="inputValue">0</strong><small class="stat-detail" id="inputDetail"></small></article>
    <article class="stat"><span class="stat-label">Uncached input</span><strong class="stat-value" id="uncachedValue">0</strong><small class="stat-detail" id="uncachedDetail"></small></article>
    <article class="stat"><span class="stat-label">Output</span><strong class="stat-value" id="outputValue">0</strong><small class="stat-detail" id="outputDetail"></small></article>
    <article class="stat"><span class="stat-label">Cache ratio</span><strong class="stat-value" id="cacheValue">0%</strong><small class="stat-detail" id="cacheDetail"></small></article>
    <article class="stat"><span class="stat-label">Unique calls</span><strong class="stat-value" id="callsValue">0</strong><small class="stat-detail" id="callsDetail"></small></article>
  </section>

  <section class="panel">
    <div class="panel-inner">
      <div class="panel-head">
        <div><h2>一周 × 24 小时</h2><p class="panel-kicker" id="hourlyCaption"></p></div>
        <div class="scale-note" id="hourlyScaleNote"></div>
      </div>
      <div class="scroll-x"><div class="hour-grid" id="hourGrid" role="grid"></div></div>
      <div class="legend-row"><span>0</span><span class="gradient-bar"></span><span id="hourlyLegendMax">0</span></div>
    </div>
  </section>

  <section class="panel">
    <div class="panel-inner">
      <div class="panel-head">
        <div><h2>每日历史</h2><p class="panel-kicker">按本地日期排列；同样使用连续色阶，可随模型和指标筛选。</p></div>
        <div class="scale-note" id="calendarScaleNote"></div>
      </div>
      <div class="scroll-x">
        <div class="calendar-layout">
          <div class="month-labels" id="monthLabels"></div>
          <div class="calendar-row">
            <div class="calendar-weekdays"><span>一</span><span>二</span><span>三</span><span>四</span><span>五</span><span>六</span><span>日</span></div>
            <div class="calendar-cells" id="calendarCells"></div>
          </div>
        </div>
      </div>
      <div class="legend-row"><span>0</span><span class="gradient-bar"></span><span id="calendarLegendMax">0</span></div>
    </div>
  </section>

  <div class="split">
    <section class="panel"><div class="panel-inner"><div class="panel-head"><div><h2>模型分布</h2><p class="panel-kicker">模型取自每次调用前最近的 turn_context，不使用会话最终模型覆盖历史。</p></div></div><div class="table-wrap"><table><thead><tr><th>Model</th><th>Total</th><th>Share</th><th>Calls</th><th>Cache</th></tr></thead><tbody id="modelRows"></tbody></table></div></div></section>
    <section class="panel"><div class="panel-inner"><div class="panel-head"><div><h2>高用量日期</h2><p class="panel-kicker" id="topDaysCaption"></p></div></div><div class="table-wrap"><table><thead><tr><th>Date</th><th id="topDaysMetric">Metric</th><th>Total</th><th>Calls</th></tr></thead><tbody id="topDayRows"></tbody></table></div></div></section>
  </div>

  <section class="panel">
    <div class="panel-inner">
      <div class="panel-head"><div><h2>会话用量</h2><p class="panel-kicker">每行是一段用户可见会话；内部线程归并到所属会话，显式用户 fork 单独列出。</p></div><div class="scale-note">TOP 30 / CURRENT FILTER</div></div>
      <div class="table-wrap"><table><thead><tr><th>Session</th><th>Models</th><th>Routing</th><th id="sessionMetric">Metric</th><th>Calls</th><th>Branch</th></tr></thead><tbody id="sessionRows"></tbody></table></div>
    </div>
  </section>

  <section class="panel">
    <div class="panel-inner">
      <div class="panel-head">
        <div><h2>Token 价值估算</h2><p class="panel-kicker" id="costCaption"></p></div>
        <div class="scale-note" id="pricingAsOf"></div>
      </div>
      <div class="cost-strip">
        <div class="cost-metric"><span class="cost-label">Official equivalent</span><strong class="cost-value" id="estimatedCost">$0.00</strong><small class="cost-detail" id="estimatedCostDetail"></small></div>
        <div class="cost-metric"><span class="cost-label">Standard baseline</span><strong class="cost-value" id="standardCost">$0.00</strong><small class="cost-detail" id="standardCostDetail"></small></div>
        <div class="cost-metric"><span class="cost-label">Tier premium</span><strong class="cost-value" id="tierPremium">$0.00</strong><small class="cost-detail" id="tierPremiumDetail"></small></div>
        <div class="cost-metric"><span class="cost-label">Cache savings</span><strong class="cost-value" id="cacheSavings">$0.00</strong><small class="cost-detail" id="cacheSavingsDetail"></small></div>
      </div>
      <div class="table-wrap"><table><thead><tr><th>Route provider</th><th>Model</th><th>Tier</th><th>Priced as</th><th>Value</th><th>Input / MTok</th><th>Cache read</th><th>Cache write</th><th>Output / MTok</th><th>Calls</th><th>Unpriced</th></tr></thead><tbody id="costRows"></tbody></table></div>
      <p class="method" id="costMethod"></p>
      <div class="pricing-sources" id="pricingSources"></div>
    </div>
  </section>

  <section class="panel">
    <div class="panel-inner">
      <div class="panel-head"><div><h2>统计审计</h2><p class="panel-kicker">所有异常与去重结果都留在这里，便于核对数据口径。</p></div></div>
      <div class="audit-grid" id="auditGrid"></div>
      <p class="method">口径：每个有效 token_count 读取单次增量 last_token_usage，并关联当时最近的 provider、model、service tier 与 reasoning effort。父会话与 fork 文件中重复出现的历史事件只计第一次。total 大于 input + output 的差额保留为 Unclassified；reasoning 是 output 的子集，不重复加入 total。兼容供应商把 reasoning 计为 0 但保留明文 reasoning item 时，使用匹配的本地 tokenizer 推导，fallback 会在审计区单独标记。</p>
    </div>
  </section>

  <footer class="footer"><span id="generatedAt"></span><span>by_day.csv · by_hour.csv · by_model.csv · by_route.csv · by_session.csv · summary.json</span></footer>
</main>
<div class="tooltip" id="tooltip" role="tooltip"></div>
<script id="usageData" type="application/json">__DATA_JSON__</script>
<script>
(() => {
  "use strict";
  const data = JSON.parse(document.getElementById("usageData").textContent);
  const zeroUsage = {input_tokens:0,cached_input_tokens:0,cache_write_input_tokens:0,uncached_input_tokens:0,output_tokens:0,reasoning_output_tokens:0,unclassified_tokens:0,total_tokens:0,calls:0};
  const zeroCost = {uncached_input_cost_usd:0,cached_input_cost_usd:0,cache_write_input_cost_usd:0,output_cost_usd:0,estimated_cost_usd:0,standard_equivalent_cost_usd:0,service_tier_premium_usd:0,cache_savings_usd:0,priced_tokens:0,unpriced_tokens:0,priced_calls:0,unpriced_calls:0,long_context_calls:0,default_tier_calls:0,priority_tier_calls:0,other_tier_calls:0,tier_rate_fallback_calls:0};
  const metrics = {
    total_tokens: {label:"Total tokens", short:"Total"},
    input_tokens: {label:"Input tokens", short:"Input"},
    cached_input_tokens: {label:"Cached input", short:"Cached"},
    cache_write_input_tokens: {label:"Cache write input", short:"Cache write"},
    uncached_input_tokens: {label:"Uncached input", short:"Uncached"},
    output_tokens: {label:"Output tokens", short:"Output"},
    reasoning_output_tokens: {label:"Reasoning output", short:"Reasoning"},
    unclassified_tokens: {label:"Unclassified tokens", short:"Unclassified"},
    calls: {label:"Unique model calls", short:"Calls"}
  };
  const weekdays = ["周一","周二","周三","周四","周五","周六","周日"];
  const palette = ["#087968","#2878a8","#d67834","#ba4d3c","#6b8c2f","#b48716","#39756c","#8b6353"];
  const state = {model:"all", metric:"total_tokens"};
  const modelSelect = document.getElementById("modelSelect");
  const metricSelect = document.getElementById("metricSelect");

  const fmt = value => new Intl.NumberFormat("en-US").format(Math.round(value || 0));
  const short = value => {
    const n = Number(value || 0);
    if (n >= 1e9) return `${(n / 1e9).toFixed(2)}B`;
    if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
    if (n >= 1e3) return `${(n / 1e3).toFixed(1)}K`;
    return fmt(n);
  };
  const usd = value => new Intl.NumberFormat("en-US", {style:"currency",currency:"USD",minimumFractionDigits:2,maximumFractionDigits:Number(value || 0) < 1 ? 4 : 2}).format(Number(value || 0));
  const escapeHtml = value => String(value ?? "").replace(/[&<>'"]/g, char => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[char]));
  const usageFor = (collection, scope) => collection[scope] || zeroUsage;
  const modelLabel = model => model === "all" ? "全部模型" : model;
  const metricValue = usage => Number((usage || zeroUsage)[state.metric] || 0);
  const metricColor = model => palette[Math.max(0, data.models.indexOf(model)) % palette.length];

  function percentile(values, fraction) {
    const sorted = values.filter(v => v > 0).sort((a,b) => a-b);
    if (!sorted.length) return 0;
    const index = Math.min(sorted.length - 1, Math.max(0, Math.round((sorted.length - 1) * fraction)));
    return sorted[index];
  }
  function mix(a, b, amount) { return Math.round(a + (b - a) * amount); }
  function colorFor(value, cap) {
    if (!(value > 0) || !(cap > 0)) return "#e5ece9";
    const t = Math.pow(Math.min(value / cap, 1), 0.44);
    const stops = [[0,[220,235,230]],[.36,[126,202,181]],[.7,[24,146,122]],[1,[3,78,70]]];
    let left = stops[0], right = stops[stops.length - 1];
    for (let i = 1; i < stops.length; i++) {
      if (t <= stops[i][0]) { left = stops[i - 1]; right = stops[i]; break; }
    }
    const span = right[0] - left[0] || 1;
    const local = (t - left[0]) / span;
    const rgb = left[1].map((channel, i) => mix(channel, right[1][i], local));
    return `rgb(${rgb.join(",")})`;
  }
  function tooltipText(title, usage, cost = zeroCost) {
    const selected = `${metrics[state.metric].label}: ${fmt(metricValue(usage))}`;
    const unpriced = cost.unpriced_tokens ? ` · ${short(cost.unpriced_tokens)} unpriced` : "";
    const value = cost.priced_tokens ? usd(cost.estimated_cost_usd) : "Unpriced";
    return `${title}\n${selected}\nTotal: ${fmt(usage.total_tokens)} · Calls: ${fmt(usage.calls)}\nAPI value: ${value}${unpriced}`;
  }
  function heatButton(className, value, cap, tooltip, aria) {
    return `<button type="button" class="heat-cell ${className}" style="background:${colorFor(value, cap)}" data-tooltip="${escapeHtml(tooltip)}" aria-label="${escapeHtml(aria)}"></button>`;
  }

  function populateControls() {
    modelSelect.innerHTML = [`<option value="all">全部模型</option>`, ...data.models.map(model => `<option value="${escapeHtml(model)}">${escapeHtml(model)}</option>`)].join("");
    metricSelect.innerHTML = Object.entries(metrics).map(([key, item]) => `<option value="${key}">${item.label}</option>`).join("");
    modelSelect.value = state.model;
    metricSelect.value = state.metric;
  }

  function renderStats() {
    const usage = usageFor(data.totals, state.model);
    const overall = usageFor(data.totals, "all");
    const share = overall.total_tokens ? usage.total_tokens / overall.total_tokens : 0;
    const cacheRate = usage.input_tokens ? usage.cached_input_tokens / usage.input_tokens : 0;
    document.getElementById("totalValue").textContent = short(usage.total_tokens);
    document.getElementById("totalDetail").textContent = state.model === "all" ? fmt(usage.total_tokens) : `${(share * 100).toFixed(1)}% of all models`;
    document.getElementById("inputValue").textContent = short(usage.input_tokens);
    document.getElementById("inputDetail").textContent = fmt(usage.input_tokens);
    document.getElementById("uncachedValue").textContent = short(usage.uncached_input_tokens);
    document.getElementById("uncachedDetail").textContent = `${short(usage.cached_input_tokens)} read · ${short(usage.cache_write_input_tokens)} write`;
    document.getElementById("outputValue").textContent = short(usage.output_tokens);
    document.getElementById("outputDetail").textContent = `${short(usage.reasoning_output_tokens)} reasoning`;
    document.getElementById("cacheValue").textContent = `${(cacheRate * 100).toFixed(1)}%`;
    document.getElementById("cacheDetail").textContent = `${short(usage.cached_input_tokens)} read · ${short(usage.cache_write_input_tokens)} write`;
    document.getElementById("callsValue").textContent = short(usage.calls);
    document.getElementById("callsDetail").textContent = `${short(usage.unclassified_tokens)} unclassified`;
  }

  function renderHourly() {
    const matrix = data.hourly[state.model] || data.hourly.all;
    const costMatrix = data.pricing.hourly[state.model] || data.pricing.hourly.all;
    const values = matrix.flat().map(metricValue);
    const cap = percentile(values, .98);
    const cells = [`<div></div>`, ...Array.from({length:24}, (_, hour) => `<div class="hour-label">${String(hour).padStart(2,"0")}</div>`)];
    matrix.forEach((row, weekday) => {
      cells.push(`<div class="day-label">${weekdays[weekday]}</div>`);
      row.forEach((usage, hour) => {
        const title = `${weekdays[weekday]} ${String(hour).padStart(2,"0")}:00–${String(hour).padStart(2,"0")}:59 · ${modelLabel(state.model)}`;
        const cost = costMatrix[weekday][hour];
        const costLabel = cost.priced_tokens ? usd(cost.estimated_cost_usd) : "unpriced";
        cells.push(heatButton("hourly-cell", metricValue(usage), cap, tooltipText(title, usage, cost), `${title}, ${metrics[state.metric].label} ${fmt(metricValue(usage))}, official API value ${costLabel}`));
      });
    });
    document.getElementById("hourGrid").innerHTML = cells.join("");
    document.getElementById("hourlyCaption").textContent = `${data.range.start} 至 ${data.range.end} 的历史调用，按星期与本地小时聚合。`;
    document.getElementById("hourlyScaleNote").textContent = `CONTINUOUS POWER SCALE · P98 CAP ${short(cap)}`;
    document.getElementById("hourlyLegendMax").textContent = short(cap);
  }

  function utcDate(value) { return new Date(`${value}T00:00:00Z`); }
  function isoDate(value) { return value.toISOString().slice(0,10); }
  function addUtcDays(value, count) { const next = new Date(value); next.setUTCDate(next.getUTCDate() + count); return next; }
  function mondayIndex(value) { return (value.getUTCDay() + 6) % 7; }

  function renderCalendar() {
    const usageByDate = data.daily[state.model] || data.daily.all;
    const costsByDate = data.pricing.daily[state.model] || data.pricing.daily.all;
    const values = Object.values(usageByDate).map(metricValue);
    const cap = percentile(values, .98);
    const first = utcDate(data.range.start);
    const last = utcDate(data.range.end);
    const start = addUtcDays(first, -mondayIndex(first));
    const end = addUtcDays(last, 6 - mondayIndex(last));
    const dayCount = Math.round((end - start) / 86400000) + 1;
    const weeks = Math.ceil(dayCount / 7);
    const cells = [];
    const months = [];
    let previousMonth = -1;
    for (let offset = 0; offset < dayCount; offset++) {
      const current = addUtcDays(start, offset);
      const key = isoDate(current);
      const usage = usageByDate[key] || zeroUsage;
      const outside = current < first || current > last;
      const title = `${key} · ${modelLabel(state.model)}`;
      const cost = outside ? zeroCost : (costsByDate[key] || zeroCost);
      const costLabel = cost.priced_tokens ? usd(cost.estimated_cost_usd) : "unpriced";
      cells.push(heatButton(`calendar-cell${outside ? " outside" : ""}`, outside ? 0 : metricValue(usage), cap, tooltipText(title, usage, cost), `${title}, ${metrics[state.metric].label} ${fmt(metricValue(usage))}, official API value ${costLabel}`));
      if (offset % 7 === 0 && current.getUTCMonth() !== previousMonth) {
        months.push(`<span style="grid-column:${Math.floor(offset / 7) + 1}">${current.toLocaleString("zh-CN", {month:"short", timeZone:"UTC"})}</span>`);
        previousMonth = current.getUTCMonth();
      }
    }
    const monthLabels = document.getElementById("monthLabels");
    monthLabels.style.gridTemplateColumns = `repeat(${weeks}, 18px)`;
    monthLabels.innerHTML = months.join("");
    document.getElementById("calendarCells").innerHTML = cells.join("");
    document.getElementById("calendarScaleNote").textContent = `CONTINUOUS POWER SCALE · P98 CAP ${short(cap)}`;
    document.getElementById("calendarLegendMax").textContent = short(cap);
  }

  function renderModels() {
    const all = data.totals.all.total_tokens || 1;
    document.getElementById("modelRows").innerHTML = data.models.map((model, index) => {
      const usage = data.totals[model] || zeroUsage;
      const share = usage.total_tokens / all;
      const cache = usage.input_tokens ? usage.cached_input_tokens / usage.input_tokens : 0;
      return `<tr class="${state.model === model ? "active-row" : ""}"><td><button class="model-button" type="button" data-model="${escapeHtml(model)}"><span class="model-dot" style="--dot:${palette[index % palette.length]}"></span>${escapeHtml(model)}</button></td><td>${short(usage.total_tokens)}</td><td>${(share*100).toFixed(1)}%<span class="share-track"><span class="share-fill" style="width:${Math.max(2,share*100)}%"></span></span></td><td>${fmt(usage.calls)}</td><td>${(cache*100).toFixed(1)}%</td></tr>`;
    }).join("");
  }

  function renderTopDays() {
    const daily = data.daily[state.model] || data.daily.all;
    const rows = Object.entries(daily).map(([day, usage]) => ({day, usage, value:metricValue(usage)})).filter(item => item.value > 0).sort((a,b) => b.value-a.value).slice(0,10);
    document.getElementById("topDaysMetric").textContent = metrics[state.metric].short;
    document.getElementById("topDaysCaption").textContent = `${modelLabel(state.model)} · ${metrics[state.metric].label}`;
    document.getElementById("topDayRows").innerHTML = rows.map(item => `<tr><td>${item.day}</td><td>${fmt(item.value)}</td><td>${short(item.usage.total_tokens)}</td><td>${fmt(item.usage.calls)}</td></tr>`).join("") || `<tr><td colspan="4">No usage</td></tr>`;
  }

  function sessionUsage(session) { return state.model === "all" ? session.totals : (session.by_model[state.model] || zeroUsage); }
  function tierLabel(tier) { return tier === "priority" ? "priority / fast" : tier; }
  function renderSessions() {
    const rows = data.sessions.map(session => ({session, usage:sessionUsage(session)})).filter(item => metricValue(item.usage) > 0).sort((a,b) => metricValue(b.usage)-metricValue(a.usage)).slice(0,30);
    document.getElementById("sessionMetric").textContent = metrics[state.metric].short;
    document.getElementById("sessionRows").innerHTML = rows.map(({session,usage}) => {
      const models = Object.entries(session.by_model).sort((a,b) => b[1].total_tokens-a[1].total_tokens).map(([model]) => `<span class="badge">${escapeHtml(model)}</span>`).join("");
      const providers = Object.entries(session.by_provider || {}).sort((a,b) => b[1].total_tokens-a[1].total_tokens).map(([provider]) => `<span class="badge provider-badge">${escapeHtml(provider)}</span>`).join("");
      const tiers = Object.entries(session.by_service_tier || {}).sort((a,b) => b[1].total_tokens-a[1].total_tokens).map(([tier]) => `<span class="badge tier-badge">${escapeHtml(tierLabel(tier))}</span>`).join("");
      const branch = session.parent_id ? `<span class="badge fork-badge">user fork +${session.lineage_depth}</span>` : `<span class="badge">conversation</span>`;
      const lineage = `<span class="session-id">${fmt(session.rollout_files || 1)} files · ${fmt(session.internal_thread_count || 0)} internal</span>`;
      return `<tr><td><span class="session-title" data-tooltip="${escapeHtml(session.path)}">${escapeHtml(session.title)}</span><span class="session-id">${escapeHtml(session.id)}</span></td><td>${models}</td><td>${providers}${tiers}</td><td>${fmt(metricValue(usage))}</td><td>${fmt(usage.calls)}</td><td>${branch}${lineage}</td></tr>`;
    }).join("") || `<tr><td colspan="6">No usage for this filter</td></tr>`;
  }

  function renderCosts() {
    const pricing = data.pricing;
    const cost = pricing.scopes[state.model] || zeroCost;
    const coverageBase = Number(cost.priced_tokens || 0) + Number(cost.unpriced_tokens || 0);
    const coverage = coverageBase ? Number(cost.priced_tokens || 0) / coverageBase : 0;
    const hasTrustedPricing = Number(cost.priced_tokens || 0) > 0;
    const hasCustomPricing = pricing.routes.some(route =>
      (state.model === "all" || route.model === state.model) && route.pricing_kind === "custom"
    );
    const hasTimeVariablePricing = pricing.routes.some(route =>
      (state.model === "all" || route.model === state.model) && route.rate_note
    );
    document.getElementById("estimatedCost").textContent = hasTrustedPricing ? usd(cost.estimated_cost_usd) : "未定价";
    document.getElementById("estimatedCostDetail").textContent = `${(coverage * 100).toFixed(1)}% categorized tokens priced`;
    document.getElementById("standardCost").textContent = hasTrustedPricing ? usd(cost.standard_equivalent_cost_usd) : "未定价";
    document.getElementById("standardCostDetail").textContent = `${fmt(cost.default_tier_calls)} default · ${fmt(cost.long_context_calls)} long context`;
    document.getElementById("tierPremium").textContent = hasTrustedPricing ? usd(cost.service_tier_premium_usd) : "—";
    document.getElementById("tierPremiumDetail").textContent = `${fmt(cost.priority_tier_calls)} priority / fast calls · ${fmt(cost.tier_rate_fallback_calls)} fallback`;
    document.getElementById("cacheSavings").textContent = hasTrustedPricing ? usd(cost.cache_savings_usd) : "—";
    document.getElementById("cacheSavingsDetail").textContent = `${usd(cost.cached_input_cost_usd)} read · ${usd(cost.cache_write_input_cost_usd)} write`;
    document.getElementById("costCaption").textContent = hasTrustedPricing
      ? hasCustomPricing
        ? `${modelLabel(state.model)} · 使用当前数据目录保存的逐模型单价估算文本 token 价值。`
        : `${modelLabel(state.model)} · 按日志路由计算官方直连文本 token 等价价值；不是中转站或订阅实际账单。${hasTimeVariablePricing ? " DeepSeek V4 表中显示峰时价，历史金额按调用时间套用 UTC 工作日峰/谷价。" : ""}`
      : `${modelLabel(state.model)} · 当前数据目录尚未配置可用价格；模型、调用和 token 仍完整统计。`;
    document.getElementById("pricingAsOf").textContent = hasTrustedPricing
      ? hasCustomPricing ? "CUSTOM MODEL RATES" : `OFFICIAL DIRECT RATES · ${pricing.as_of}`
      : "UNPRICED SOURCE";

    const visibleRoutes = pricing.routes.filter(route => state.model === "all" || route.model === state.model);
    const rateCell = value => value == null ? "—" : usd(value);
    document.getElementById("costRows").innerHTML = visibleRoutes.map(detail => {
      const rates = detail.rates;
      const routeCost = detail.costs || zeroCost;
      const pricedAs = detail.pricing_model
        ? `${escapeHtml(detail.pricing_provider || "")}${detail.pricing_provider ? " / " : ""}${escapeHtml(detail.pricing_model)}`
        : `<span class="cost-warning">Not priced</span>`;
      const valueTooltip = `Input: ${usd(routeCost.uncached_input_cost_usd)} · Cache read: ${usd(routeCost.cached_input_cost_usd)} · Cache write: ${usd(routeCost.cache_write_input_cost_usd)} · Output: ${usd(routeCost.output_cost_usd)}`;
      return `<tr><td><span class="badge provider-badge">${escapeHtml(detail.route_provider)}</span></td><td>${escapeHtml(detail.model)}</td><td><span class="badge tier-badge">${escapeHtml(tierLabel(detail.service_tier))}</span></td><td>${pricedAs}</td><td data-tooltip="${escapeHtml(valueTooltip)}">${routeCost.priced_tokens ? usd(routeCost.estimated_cost_usd) : "—"}</td><td>${rateCell(rates?.input)}</td><td>${rateCell(rates?.cached_input)}</td><td>${rateCell(rates?.cache_write_input)}</td><td>${rateCell(rates?.output)}</td><td>${fmt(detail.usage.calls)}</td><td>${short(routeCost.unpriced_tokens)}</td></tr>`;
    }).join("") || `<tr><td colspan="11">No usage for this filter</td></tr>`;

    const unpricedNote = cost.unpriced_tokens ? ` ${fmt(cost.unpriced_tokens)} 个无法分类或暂无官方价格的 token 未计价。` : "";
    const authMode = String(pricing.billing_context?.current_auth_mode || "unknown").toLowerCase();
    const authNote = authMode.includes("api")
      ? "当前认证为 API key；Priority/Fast 路由按官方 API Priority 价估算。"
      : authMode.includes("chatgpt")
        ? "当前认证为 ChatGPT；这里仍只显示 API 等价价值，无法从 token 日志还原订阅账单或 credits。"
        : "日志不保存可验证的历史认证方式，因此不能判定每次调用属于订阅还是 API 账单。";
    const aliasPath = pricing.model_aliases.path || "token_atlas_pricing.json";
    const configNote = pricing.model_aliases.aliases
      ? ` 已加载 ${pricing.model_aliases.aliases} 个模型别名映射。`
      : ` 可用 ${aliasPath} 保存逐模型单价和模型别名。`;
    const customRateNote = hasCustomPricing ? ` 已加载 ${pricing.custom_models.length} 个自定义模型价格。` : "";
    const configErrorNote = pricing.model_aliases.errors.length ? ` 价格配置有 ${pricing.model_aliases.errors.length} 个错误。` : "";
    const inferredTier = pricing.billing_context?.configured_service_tier_fallback === "priority" ? "Fast/Priority" : (pricing.billing_context?.configured_service_tier_fallback || "Default");
    const inferredTierCalls = Number(pricing.billing_context?.inferred_service_tier_calls || 0);
    const inferredTierNote = inferredTierCalls ? ` 日志缺失 tier 的 ${fmt(inferredTierCalls)} 次调用按当前数据目录配置 ${inferredTier} 推断。` : "";
    document.getElementById("costMethod").textContent = hasTrustedPricing
      ? hasCustomPricing
        ? `自定义价格按 USD / 100 万 tokens 保存，并分别应用于未缓存输入、缓存读取、缓存写入和输出。${customRateNote}${configNote}${configErrorNote}${unpricedNote}`
        : `${authNote} Default 使用 Standard 价；Priority/Fast 使用可用的 Priority 价，无对应价时回退 Standard 并计入审计。${inferredTierNote} ChatGPT Plan Fast 对 GPT-5.6/5.5 使用 2.5x credits、GPT-5.4 使用 2x credits，但这不是 token 美元单价，日志不足以重建订阅账单。缓存读、缓存写、未缓存输入和输出分别计价；未提供独立写入价时按输入价。工具调用、缓存存储和非文本模态费用不在 Codex token 日志中，不计入。${configNote}${configErrorNote}${unpricedNote}`
      : `当前来源仅提供用量统计。可在应用设置中为已识别模型填写价格。${configErrorNote}${unpricedNote}`;
    const sourceMap = new Map();
    pricing.sources.forEach(item => {
      if (!sourceMap.has(item.url)) sourceMap.set(item.url, []);
      sourceMap.get(item.url).push(item.model);
    });
    document.getElementById("pricingSources").innerHTML = [...sourceMap].map(([url, labels]) => {
      const isOfficial = /^https?:\/\//i.test(url);
      const label = `${labels.join(" · ")} ${isOfficial ? "官方价目表" : "自定义价格"}`;
      return isOfficial
        ? `<a href="${escapeHtml(url)}" target="_blank" rel="noreferrer">${escapeHtml(label)}</a>`
        : `<span>${escapeHtml(label)} · local config</span>`;
    }).join("");
  }

  function renderAudit() {
    const a = data.audit;
    const entries = [
      ["Rollout files", a.session_files], ["Conversations", a.conversation_sessions], ["User forks", a.fork_sessions],
      ["Internal threads", a.internal_threads], ["Orphan internal", a.orphan_internal_threads], ["Raw events", a.raw_token_events],
      ["Unique calls", a.unique_model_calls], ["Replay skipped", a.inherited_events], ["Local duplicates", a.local_duplicate_events],
      ["Null usage", a.null_usage_events], ["Delta fallbacks", a.fallback_delta_events], ["Model fallbacks", a.fallback_model_events],
      ["Provider fallbacks", a.fallback_provider_events], ["Tier fallbacks", a.fallback_service_tier_events], ["Priority calls", data.pricing.scopes.all.priority_tier_calls],
      ["Tier price fallbacks", data.pricing.scopes.all.tier_rate_fallback_calls], ["Reasoning inferred", a.inferred_reasoning_events || 0], ["Inferred reasoning tokens", a.inferred_reasoning_tokens || 0],
      ["Heuristic reasoning", a.heuristic_reasoning_events || 0], ["Cache writes", data.totals.all.cache_write_input_tokens], ["Pricing config errors", a.pricing_config_errors],
      ["Total repairs", a.repaired_total_events], ["Missing timestamps", a.missing_timestamp_events], ["Unclassified", data.totals.all.unclassified_tokens]
    ];
    document.getElementById("auditGrid").innerHTML = entries.map(([label,value]) => `<div class="audit-item"><span>${label}</span><strong>${short(value)}</strong></div>`).join("");
  }

  function renderAll() {
    renderStats(); renderHourly(); renderCalendar(); renderModels(); renderTopDays(); renderSessions(); renderCosts();
    document.getElementById("subtitle").textContent = `${data.range.start} → ${data.range.end} · ${modelLabel(state.model)} · ${metrics[state.metric].label}`;
  }

  modelSelect.addEventListener("change", () => { state.model = modelSelect.value; renderAll(); });
  metricSelect.addEventListener("change", () => { state.metric = metricSelect.value; renderAll(); });
  document.getElementById("modelRows").addEventListener("click", event => {
    const button = event.target.closest("[data-model]");
    if (!button) return;
    state.model = button.dataset.model;
    modelSelect.value = state.model;
    renderAll();
  });

  const tooltip = document.getElementById("tooltip");
  function showTooltip(target, event) {
    const content = target?.dataset?.tooltip;
    if (!content) return;
    tooltip.textContent = content;
    tooltip.classList.add("visible");
    positionTooltip(event);
  }
  function positionTooltip(event) {
    const x = Math.min(window.innerWidth - tooltip.offsetWidth - 12, Math.max(12, (event.clientX || 20) + 14));
    const y = Math.min(window.innerHeight - tooltip.offsetHeight - 12, Math.max(12, (event.clientY || 20) + 14));
    tooltip.style.left = `${x}px`; tooltip.style.top = `${y}px`;
  }
  document.addEventListener("pointerover", event => { const target=event.target.closest("[data-tooltip]"); if(target) showTooltip(target,event); });
  document.addEventListener("pointermove", event => { if(tooltip.classList.contains("visible")) positionTooltip(event); });
  document.addEventListener("pointerout", event => { if(event.target.closest("[data-tooltip]")) tooltip.classList.remove("visible"); });
  document.addEventListener("focusin", event => { const target=event.target.closest("[data-tooltip]"); if(target) showTooltip(target,{clientX:target.getBoundingClientRect().left,clientY:target.getBoundingClientRect().bottom}); });
  document.addEventListener("focusout", () => tooltip.classList.remove("visible"));

  populateControls(); renderAudit(); renderAll();
  document.getElementById("generatedAt").textContent = `Generated ${data.generated_at_label} · ${data.timezone}`;
})();
</script>
</body>
</html>
"""


def render_html(report: UsageReport, dashboard_data: dict[str, Any] | None = None) -> str:
    if dashboard_data is None:
        dashboard_data = build_dashboard_data(report)
    encoded = json.dumps(dashboard_data, ensure_ascii=False, separators=(",", ":"))
    encoded = encoded.replace("<", "\\u003c").replace("&", "\\u0026")
    return (
        HTML_TEMPLATE
        .replace("__SOURCE_LABEL__", html.escape(report.source_label))
        .replace("__DATA_JSON__", encoded)
    )


def write_daily_csv(report: UsageReport, path: Path = OUTPUT_DAILY_CSV) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["date", *USAGE_FIELDS])
        for day in sorted(report.by_day):
            usage = report.by_day[day]
            writer.writerow([day.isoformat(), *(usage[field] for field in USAGE_FIELDS)])


def write_hourly_csv(report: UsageReport, path: Path = OUTPUT_HOURLY_CSV) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["date", "hour", "timezone", "model", *USAGE_FIELDS])
        for hour in sorted(report.by_hour_model):
            for model in sorted(report.by_hour_model[hour]):
                usage = report.by_hour_model[hour][model]
                writer.writerow(
                    [
                        hour.date().isoformat(),
                        hour.hour,
                        LOCAL_TZ.key,
                        model,
                        *(usage[field] for field in USAGE_FIELDS),
                    ]
                )


def write_model_csv(report: UsageReport, path: Path = OUTPUT_MODEL_CSV) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["model", *USAGE_FIELDS])
        for model, usage in sorted(
            report.totals_by_model.items(),
            key=lambda item: item[1]["total_tokens"],
            reverse=True,
        ):
            writer.writerow([model, *(usage[field] for field in USAGE_FIELDS)])


def write_route_csv(report: UsageReport, path: Path = OUTPUT_ROUTE_CSV) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            [
                "route_provider",
                "model",
                "service_tier",
                "pricing_provider",
                "pricing_model",
                "pricing_source",
                *USAGE_FIELDS,
                *COST_FIELDS,
            ]
        )
        for route, usage in sorted(
            report.usage_by_route.items(),
            key=lambda item: item[1]["total_tokens"],
            reverse=True,
        ):
            route_provider, model, service_tier = route
            pricing_match = pricing_for_model(
                model,
                route_provider,
                report.pricing_catalog,
                report.pricing_aliases,
            )
            pricing_model = ""
            pricing_provider = ""
            pricing_source = ""
            if pricing_match is not None:
                pricing_model, pricing = pricing_match
                pricing_provider = str(pricing.get("provider") or "")
                pricing_source = str(pricing.get("source") or "")
            costs = cost_dict(report.costs_by_route[route])
            writer.writerow(
                [
                    route_provider,
                    model,
                    service_tier,
                    pricing_provider,
                    pricing_model,
                    pricing_source,
                    *(usage[field] for field in USAGE_FIELDS),
                    *(costs[field] for field in COST_FIELDS),
                ]
            )


def write_session_csv(report: UsageReport, path: Path = OUTPUT_SESSION_CSV) -> None:
    sessions = sorted(
        report.sessions,
        key=lambda item: item.total["total_tokens"],
        reverse=True,
    )
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            [
                "rank",
                "conversation_title",
                "title_source",
                "session_id",
                "parent_session_id",
                "lineage_root_id",
                "lineage_depth",
                "rollout_files",
                "internal_threads",
                "session_file",
                "first_timestamp",
                "last_timestamp",
                "model_provider",
                "cli_version",
                "originator",
                "source",
                "models",
                "providers",
                "service_tiers",
                "reasoning_efforts",
                *USAGE_FIELDS,
                "inherited_events_skipped",
                "local_duplicate_events",
                "sqlite_threads_tokens_used",
            ]
        )
        for rank, stats in enumerate(sessions, start=1):
            descriptor = stats.descriptor
            models = "; ".join(
                f"{model}:{usage['total_tokens']}"
                for model, usage in sorted(
                    stats.by_model.items(),
                    key=lambda item: item[1]["total_tokens"],
                    reverse=True,
                )
            )
            providers = "; ".join(
                f"{provider}:{usage['total_tokens']}"
                for provider, usage in sorted(
                    stats.by_provider.items(),
                    key=lambda item: item[1]["total_tokens"],
                    reverse=True,
                )
            )
            service_tiers = "; ".join(
                f"{tier}:{usage['total_tokens']}"
                for tier, usage in sorted(
                    stats.by_service_tier.items(),
                    key=lambda item: item[1]["total_tokens"],
                    reverse=True,
                )
            )
            reasoning_efforts = "; ".join(
                f"{effort}:{usage['total_tokens']}"
                for effort, usage in sorted(
                    stats.by_reasoning_effort.items(),
                    key=lambda item: item[1]["total_tokens"],
                    reverse=True,
                )
            )
            writer.writerow(
                [
                    rank,
                    clean_text(descriptor.thread.title or descriptor.path.stem, 500),
                    descriptor.thread.title_source,
                    descriptor.session_id,
                    descriptor.parent_id,
                    descriptor.root_id,
                    descriptor.lineage_depth,
                    stats.rollout_files,
                    stats.internal_thread_count,
                    descriptor.path.name,
                    stats.first_timestamp or "",
                    stats.last_timestamp or "",
                    descriptor.model_provider,
                    descriptor.cli_version,
                    descriptor.originator,
                    descriptor.source,
                    models,
                    providers,
                    service_tiers,
                    reasoning_efforts,
                    *(stats.total[field] for field in USAGE_FIELDS),
                    stats.inherited_events,
                    stats.local_duplicate_events,
                    (
                        descriptor.thread.tokens_used
                        if descriptor.thread.tokens_used is not None
                        else ""
                    ),
                ]
            )


def summary_payload(
    report: UsageReport,
    input_manifest: list[list[str | int]] | None = None,
    dashboard: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if dashboard is None:
        dashboard = build_dashboard_data(report)
    active_days = sorted(report.by_day)
    models = {
        model: counter_dict(usage)
        for model, usage in sorted(
            report.totals_by_model.items(),
            key=lambda item: item[1]["total_tokens"],
            reverse=True,
        )
    }
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "input_manifest": input_manifest,
        "generated_at": datetime.now(LOCAL_TZ).isoformat(),
        "timezone": LOCAL_TZ.key,
        "accounting_method": (
            "sum unique last_token_usage events; roll internal threads into "
            "their user-visible conversation"
        ),
        "deduplication_key": (
            "physical_lineage_root + turn_id + route + cumulative_usage + "
            "last_usage + context_window"
        ),
        "source_id": report.source_key,
        "source_label": report.source_label,
        "sessions_root": str(report.sessions_root),
        "dashboard": dashboard,
        "totals": counter_dict(report.totals),
        "usage_by_model": models,
        "usage_by_provider": {
            provider: counter_dict(usage)
            for provider, usage in sorted(report.totals_by_provider.items())
        },
        "usage_by_service_tier": {
            tier: counter_dict(usage)
            for tier, usage in sorted(report.totals_by_service_tier.items())
        },
        "usage_by_reasoning_effort": {
            effort: counter_dict(usage)
            for effort, usage in sorted(report.totals_by_reasoning_effort.items())
        },
        "pricing": {key: value for key, value in dashboard["pricing"].items()
                    if key not in {"hourly", "daily", "timeline_hourly"}},
        "date_range": {
            "first": active_days[0].isoformat() if active_days else None,
            "last": active_days[-1].isoformat() if active_days else None,
            "active_days": len(active_days),
        },
        "audit": {
            "session_files": report.rollout_files,
            "conversation_sessions": report.conversation_sessions,
            "logical_sessions": len(report.sessions),
            "internal_threads": report.internal_threads,
            "orphan_internal_threads": report.orphan_internal_threads,
            "fork_sessions": report.fork_sessions,
            "raw_token_count_events": report.raw_events,
            "unique_model_calls": int(report.totals["calls"]),
            "duplicate_events_skipped": report.duplicate_events,
            "inherited_fork_events_skipped": report.inherited_events,
            "local_duplicate_events_skipped": report.local_duplicate_events,
            "null_usage_events": report.null_usage_events,
            "fallback_delta_events": report.fallback_delta_events,
            "fallback_model_events": report.fallback_model_events,
            "repaired_total_events": report.repaired_total_events,
            "cached_over_input_events": report.cached_over_input_events,
            "cache_write_over_input_events": report.cache_write_over_input_events,
            "reasoning_over_output_events": report.reasoning_over_output_events,
            "inferred_reasoning_events": report.inferred_reasoning_events,
            "inferred_reasoning_tokens": report.inferred_reasoning_tokens,
            "heuristic_reasoning_events": report.heuristic_reasoning_events,
            "missing_timestamp_events": report.missing_timestamp_events,
            "fallback_provider_events": report.fallback_provider_events,
            "fallback_service_tier_events": report.fallback_service_tier_events,
            "configured_service_tier_fallback": report.configured_service_tier_fallback,
            "pricing_config_errors": report.pricing_config_errors,
            "sqlite_threads_total_tokens_reference_only": report.sqlite_threads_total_tokens,
        },
        "outputs": {
            "html": str(OUTPUT_HTML),
            "daily_csv": str(OUTPUT_DAILY_CSV),
            "hourly_csv": str(OUTPUT_HOURLY_CSV),
            "model_csv": str(OUTPUT_MODEL_CSV),
            "route_csv": str(OUTPUT_ROUTE_CSV),
            "session_csv": str(OUTPUT_SESSION_CSV),
            "json": str(OUTPUT_JSON),
        },
    }


def write_outputs(
    report: UsageReport,
    input_manifest: list[list[str | int]] | None = None,
) -> dict[str, Any]:
    summary = summary_payload(report, input_manifest)
    write_export_outputs(report, summary["dashboard"])
    write_summary_outputs(summary)
    return summary


def write_summary_outputs(summary: dict[str, Any], source: UsageSource | None = None) -> None:
    encoded = json.dumps(summary, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    atomic_write(OUTPUT_JSON, encoded)
    if source is not None:
        atomic_write(source_summary_path(source), encoded)


def write_export_outputs(report: UsageReport, dashboard: dict[str, Any]) -> None:
    atomic_write(OUTPUT_HTML, render_html(report, dashboard).encode("utf-8"))
    write_daily_csv(report)
    write_hourly_csv(report)
    write_model_csv(report)
    write_route_csv(report)
    write_session_csv(report)


def synthetic_event(
    timestamp: str,
    obj_type: str,
    payload: dict[str, Any],
) -> str:
    return json.dumps(
        {"timestamp": timestamp, "type": obj_type, "payload": payload},
        separators=(",", ":"),
    )


def run_records_self_test() -> None:
    def session(sid: str) -> SessionStats:
        return SessionStats(SessionDescriptor(Path("synthetic") / sid, sid, "", sid, sid, 0, "", thread=ThreadInfo(title=sid)))

    first, second = session("first"), session("second")
    report = UsageReport(sessions=[first, second])
    start = datetime(2026, 1, 1, 12, tzinfo=LOCAL_TZ)
    for minute, tokens in ((0, 100), (10, 200), (29, 300), (30, 400), (61, 500)):
        add_usage(report, first, "test", "test", "default", "", start + timedelta(minutes=minute), Counter(total_tokens=tokens, output_tokens=10, calls=1))
    add_usage(report, second, "test", "test", "default", "", start + timedelta(minutes=29), Counter(total_tokens=100, output_tokens=90, calls=1))
    report.billable_events.reverse()
    records = build_usage_records(report, date(2026, 1, 1))
    assert records["peak_hour"]["total_tokens"] == 1500
    assert records["peak_output_hour"]["output_tokens"] == 130
    assert records["peak_throughput"]["total_tokens"] == 500
    assert records["peak_output_throughput"]["output_tokens"] == 100
    for key, seconds in (("peak_hour", 3600), ("peak_output_hour", 3600), ("peak_throughput", 60), ("peak_output_throughput", 60)):
        peak = records[key]
        assert peak["window_seconds"] == seconds
        assert (datetime.fromisoformat(peak["end"]) - datetime.fromisoformat(peak["start"])).total_seconds() == seconds
    for window_seconds in (60, 3600):
        boundary_events = [BillableUsageEvent("boundary", "test", "test", "default", start + timedelta(seconds=second * window_seconds / 60), Counter(total_tokens=tokens, output_tokens=10))
                           for second, tokens in ((0, 100), (30, 200), (59, 300), (60, 400), (121, 500))]
        peak, _ = peak_usage_windows(boundary_events, window_seconds)
        assert peak["total_tokens"] == 900  # exact lower boundary is excluded
    assert records["longest_activity"]["seconds"] == 1800  # >30 min idle splits activity
    assert records["longest_activity"]["session_id"] == "first"
    assert records["largest_session"]["total_tokens"] == 1500
    assert records["current_streak"] == records["longest_streak"] == 1
    assert build_usage_records(report, date(2026, 1, 2))["current_streak"] == 1
    assert build_usage_records(report, date(2026, 1, 3))["current_streak"] == 0
    for day in range(2, 8):
        # UTC 16:01 belongs to the following local calendar day.
        timestamp = datetime(2026, 1, day - 1, 16, 1, tzinfo=timezone.utc)
        add_usage(report, first, "test", "test", "default", "", timestamp, Counter(total_tokens=1, calls=1))
    records = build_usage_records(report, date(2026, 1, 7))
    assert records["active_days"] == records["current_streak"] == records["longest_streak"] == 7
    streak_badge = next(a for a in records["achievements"] if a["id"] == "streak")
    assert streak_badge["levels"][0]["unlocked_on"] == "2026-01-03"
    assert streak_badge["levels"][1]["unlocked_on"] == "2026-01-07"
    assert [level["target"] for level in streak_badge["levels"]] == [3, 7, 14]
    assert [level["name"] for level in streak_badge["levels"]] == ["铜", "银", "金"]
    interrupted = build_usage_records(report, date(2026, 1, 10))
    assert interrupted["current_streak"] == 0 and interrupted["longest_streak"] == 7
    interrupted_badge = next(a for a in interrupted["achievements"] if a["id"] == "streak")
    assert interrupted_badge["value"] == 7 and interrupted_badge["current_value"] == 0
    assert interrupted_badge["levels"][1]["unlocked_on"] == "2026-01-07"
    unknown_time = session("missing-time")
    unknown_time.missing_timestamp_events = 1
    report.sessions.append(unknown_time)
    add_usage(report, unknown_time, "test", "test", "default", "", start, Counter(total_tokens=100000, calls=1))
    records = build_usage_records(report, date(2026, 1, 7))
    assert records["peak_hour"]["total_tokens"] == 1500
    assert records["excluded_timestamp_sessions"] == 1
    assert records["largest_session"]["total_tokens"] == 100000
    milestone_session = session("milestones")
    milestones = UsageReport(sessions=[milestone_session])
    for offset in range(365):
        add_usage(milestones, milestone_session, "test", "test", "default", "", start + timedelta(days=offset), Counter(total_tokens=1, calls=1))
    for days, streak_levels, active_levels in ((2, 0, 0), (3, 1, 0), (6, 1, 0), (7, 2, 1), (13, 2, 1), (14, 3, 1), (29, 3, 1), (30, 3, 2), (89, 3, 2), (90, 3, 3), (364, 3, 3), (365, 3, 4)):
        milestone_records = build_usage_records(milestones, start.date() + timedelta(days=days - 1))
        for badge, expected_levels in zip(milestone_records["achievements"][:2], (streak_levels, active_levels)):
            assert sum(badge["value"] >= level["target"] for level in badge["levels"]) == expected_levels
            assert sum(level["unlocked_on"] is not None for level in badge["levels"]) == expected_levels
    for event in milestones.billable_events:
        event.timestamp = start + (event.timestamp - start) * 2
    spaced_records = build_usage_records(milestones, start.date() + timedelta(days=728))
    assert spaced_records["active_days"] == 365 and spaced_records["longest_streak"] == 1
    assert all(level["unlocked_on"] is None for level in spaced_records["achievements"][0]["levels"])
    assert all(level["unlocked_on"] is not None for level in spaced_records["achievements"][1]["levels"])
    parent, worker = session("parent"), session("worker")
    worker.descriptor.is_internal = True
    worker.descriptor.physical_parent_id = parent.descriptor.session_id
    worker.descriptor.conversation_id = parent.descriptor.session_id
    fork_time = start + timedelta(days=1)
    worker.descriptor.created_at = fork_time.isoformat()
    replay_report = UsageReport(sessions=[parent])
    replay_report.file_states = {
        "parent": FileParserState(parent.descriptor), "worker": FileParserState(worker.descriptor),
    }
    def turn_uuid(when: datetime) -> str:
        return str(UUID(int=(int(when.timestamp() * 1000) << 80) | (7 << 76) | (2 << 62)))
    old_turn, own_turn = turn_uuid(start), turn_uuid(fork_time + timedelta(seconds=10))
    for physical, turn, when, tokens in (
        ("parent", old_turn, start, 10),
        ("worker", old_turn, fork_time + timedelta(milliseconds=250), 100000),
        ("worker", old_turn, start + timedelta(seconds=60), 20),
        ("worker", own_turn, fork_time + timedelta(seconds=60), 30),
        ("worker", "(no-turn)", fork_time + timedelta(seconds=1), 40),
    ):
        usage = Counter(total_tokens=tokens, output_tokens=tokens, calls=1)
        fingerprint = event_fingerprint("parent", turn, "test", "test", "default", "", usage, usage, 0)
        replay_report.seen_fingerprints[fingerprint] = physical
        add_usage(replay_report, parent, "test", "test", "default", "", when, usage)
    replay_records = build_usage_records(replay_report, fork_time.date())
    assert replay_records["excluded_replay_events"] == 1
    assert replay_records["excluded_provenance_events"] == 1
    assert replay_records["peak_hour"]["total_tokens"] == 30
    assert replay_records["peak_throughput"]["total_tokens"] == 30
    assert replay_report.totals["total_tokens"] == 100100  # timing views do not change accounting
    replay_report.seen_fingerprints.pop(next(iter(replay_report.seen_fingerprints)))
    invalid_provenance = build_usage_records(replay_report, fork_time.date())
    assert invalid_provenance["excluded_provenance_events"] == 5
    assert invalid_provenance["peak_hour"] is None
    assert invalid_provenance["insights"]["worker_count"] == 0
    assert invalid_provenance["insights"]["first_active_day"] is None
    assert all(level["unlocked_on"] is None for badge in invalid_provenance["achievements"] for level in badge["levels"])

    # Reported identity is stable across case, whitespace, provider prefix and
    # service tiers. A pricing alias remains its own reported model identity.
    explorer = session("explorer")
    exploration = UsageReport(sessions=[explorer], pricing_aliases={"alias-x": "gpt-x"})
    for offset, model, tier in (
        (0, " GPT-X ", "default"), (0, "gpt-x", "priority"),
        (1, " ANTHROPIC.Claude-Y ", "flex"), (2, "claude-y", "default"),
        (3, "alias-x", "default"), (4, "gpt-x-fast", "default"),
        (0, "", "default"), (0, "(unknown)", "default"),
        (0, "UNKNOWN", "default"), (0, "codex-auto-review", "default"),
    ):
        add_usage(exploration, explorer, "test", model, tier, "", start + timedelta(days=offset), Counter(total_tokens=10, output_tokens=2, calls=1))
    add_usage(exploration, explorer, "test", "unused-model", "default", "", start, Counter(calls=1))
    exploration_records = build_usage_records(exploration, start.date() + timedelta(days=4))
    badges = {a["id"]: a for a in exploration_records["achievements"]}
    assert badges["models"]["value"] == badges["session_models"]["value"] == 4
    assert badges["models"]["levels"][0]["unlocked_on"] == "2026-01-02"
    assert [level["unlocked_on"] for level in badges["session_models"]["levels"]] == ["2026-01-02", "2026-01-04", "2026-01-05"]
    footprints = exploration_records["insights"]["models"]
    assert [item["id"] for item in footprints[:2]] == ["claude-y", "gpt-x"]
    footprint_by_id = {item["id"]: item for item in footprints}
    assert footprint_by_id["gpt-x"]["calls"] == 2 and footprint_by_id["gpt-x"]["total_tokens"] == 20
    assert footprint_by_id["claude-y"]["first_used"] == "2026-01-02"
    assert footprint_by_id["claude-y"]["last_used"] == "2026-01-03"
    assert footprint_by_id["unused-model"]["first_used"] is None
    assert sum(item["total_tokens"] for item in footprints) == exploration.totals["total_tokens"]
    assert exploration_records["insights"]["most_models_session"]["models"] == ["alias-x", "claude-y", "gpt-x", "gpt-x-fast"]

    # Total, output and distinct-conversation day records have separate peaks;
    # ties choose the earliest local day even when events arrive out of order.
    daily_sessions = [session(f"daily-{index}") for index in range(3)]
    missing_daily = session("daily-missing")
    missing_daily.missing_timestamp_events = 1
    daily_report = UsageReport(sessions=[*daily_sessions, missing_daily])
    for offset, index, total, output in (
        (0, 0, 1000, 2), (1, 1, 1000, 1),
        (2, 0, 50, 45), (2, 1, 50, 45), (3, 0, 50, 45), (3, 1, 50, 45),
        (4, 0, 1, 0), (4, 1, 1, 0), (4, 2, 1, 0),
        (5, 0, 1, 0), (5, 1, 1, 0), (5, 2, 1, 0), (6, 0, 100000, 100000),
    ):
        stamp = start + timedelta(days=offset)
        if offset == 4:
            stamp = datetime(2026, 1, 4, 16, 1, tzinfo=timezone.utc)
        add_usage(daily_report, daily_sessions[index], "test", f"model-{index}", "default", "", stamp, Counter(total_tokens=total, output_tokens=output, calls=1))
    add_usage(daily_report, missing_daily, "test", "model-unknown-time", "default", "", start, Counter(total_tokens=1000000, output_tokens=1000000, calls=1))
    daily_report.billable_events.reverse()
    daily_records = build_usage_records(daily_report, date(2026, 1, 6))
    daily_insights = daily_records["insights"]
    assert daily_insights["first_active_day"] == "2026-01-01"
    assert daily_insights["peak_day"]["date"] == "2026-01-01"
    assert daily_insights["peak_day"]["total_tokens"] == 1000
    assert daily_insights["peak_output_day"]["date"] == "2026-01-03"
    assert daily_insights["peak_output_day"]["output_tokens"] == 90
    assert daily_insights["busiest_day"] == {"date": "2026-01-05", "total_tokens": 3, "output_tokens": 0, "calls": 3, "sessions": 3, "models": 3}
    badges = {a["id"]: a for a in daily_records["achievements"]}
    assert badges["daily_sessions"]["value"] == 3
    assert badges["daily_sessions"]["levels"][0]["unlocked_on"] == "2026-01-03"
    assert badges["sessions"]["value"] == 4 and all(level["unlocked_on"] is None for level in badges["sessions"]["levels"])

    # Count physical participating workers once, preserve logical owners across
    # full/incremental event representations, and keep orphan usage in totals.
    team_parent, unknown_parent = session("team-parent"), session("unknown-parent")
    unknown_parent.missing_timestamp_events = 1
    team_workers = [session(f"team-worker-{index}") for index in range(5)]
    orphan = session("orphan-worker")
    for index, stats in enumerate([*team_workers, orphan]):
        stats.descriptor.is_internal = True
        stats.descriptor.created_at = fork_time.isoformat()
        if stats is not orphan:
            stats.descriptor.physical_parent_id = unknown_parent.descriptor.session_id if index == 3 else team_parent.descriptor.session_id
            stats.descriptor.conversation_id = stats.descriptor.physical_parent_id
    orphan.descriptor.orphan_internal = True
    orphan.descriptor.physical_parent_id = "unavailable-parent"
    team_report = UsageReport(sessions=[team_parent, unknown_parent, orphan])
    team_report.file_states = {
        stats.descriptor.session_id: FileParserState(stats.descriptor)
        for stats in [team_parent, unknown_parent, *team_workers, orphan]
    }
    for index, (physical, target, offset, tokens, inherited) in enumerate((
        (team_workers[0], team_parent, 2, 10, False),
        (team_workers[1], team_parent, 3, 10, False),
        (team_workers[0], team_parent, 4, 10, False),
        (team_workers[2], team_parent, 2, 1000000, True),
        (team_workers[3], unknown_parent, 2, 10, False),
        (team_workers[4], team_parent, 2, 0, False),
        (orphan, orphan, 2, 10, False),
        (team_parent, team_parent, 2, 10, False),
    )):
        stamp = start + timedelta(days=offset)
        usage = Counter(total_tokens=tokens, output_tokens=tokens, calls=1)
        turn = old_turn if inherited else turn_uuid(stamp)
        fingerprint = event_fingerprint(target.descriptor.session_id, turn, "test", f"team-model-{index}", "default", "", usage, usage, index)
        team_report.seen_fingerprints[fingerprint] = physical.descriptor.session_id
        add_usage(team_report, target, "test", f"team-model-{index}", "default", "", stamp, usage)
    team_records = build_usage_records(team_report, date(2026, 1, 5))
    team_badges = {a["id"]: a for a in team_records["achievements"]}
    assert team_records["insights"]["worker_count"] == 4
    assert team_records["insights"]["collaborative_sessions"] == team_badges["collaborative_sessions"]["value"] == 2
    assert team_badges["collaborative_sessions"]["levels"][0]["unlocked_on"] is None
    assert team_badges["collaborative_days"]["value"] == 3
    assert team_badges["collaborative_days"]["levels"][0]["unlocked_on"] == "2026-01-05"
    assert team_records["insights"]["collaborative_days"] == 3
    assert team_records["insights"]["largest_team_session"] == {"session_id": "team-parent", "title": "team-parent", "worker_count": 2}
    assert team_badges["sessions"]["value"] == 2
    assert team_records["insights"]["busiest_day"]["sessions"] == 1
    assert team_records["insights"]["most_models_session"]["model_count"] == 5
    assert team_records["excluded_replay_events"] == 1
    for event, physical in zip(team_report.billable_events, team_report.seen_fingerprints.values()):
        event.session_id = physical
    assert build_usage_records(team_report, date(2026, 1, 5)) == team_records
    # Even a same-length provenance mismatch invalidates every proposed date.
    first_fingerprint = next(iter(team_report.seen_fingerprints))
    mismatched_fingerprint = (*first_fingerprint[:3], "different-model", *first_fingerprint[4:])
    team_report.seen_fingerprints = {
        mismatched_fingerprint if fingerprint == first_fingerprint else fingerprint: physical
        for fingerprint, physical in team_report.seen_fingerprints.items()
    }
    unpaired_records = build_usage_records(team_report, date(2026, 1, 5))
    unpaired_badges = {a["id"]: a for a in unpaired_records["achievements"]}
    assert unpaired_badges["session_models"]["value"] == 5
    assert unpaired_badges["output_tokens"]["value"] >= 1_000_000
    assert all(level["unlocked_on"] is None for a in unpaired_records["achievements"] for level in a["levels"])
    assert all(model["first_used"] is None and model["last_used"] is None for model in unpaired_records["insights"]["models"])

    copied_parent, copied_worker = session("copied-parent"), session("copied-worker")
    copied_worker.descriptor.is_internal = True
    copied_worker.descriptor.physical_parent_id = copied_parent.descriptor.session_id
    copied_worker.descriptor.created_at = fork_time.isoformat()
    copied_report = UsageReport(sessions=[copied_parent], file_states={
        "copied-parent": FileParserState(copied_parent.descriptor),
        "copied-worker": FileParserState(copied_worker.descriptor),
    })
    for index, stamp in enumerate((start, fork_time + timedelta(seconds=5))):
        usage = Counter(total_tokens=10, calls=1)
        fingerprint = event_fingerprint("copied-parent", old_turn, "test", "test", "default", "", usage, usage, index)
        copied_report.seen_fingerprints[fingerprint] = "copied-worker"
        add_usage(copied_report, copied_parent, "test", "test", "default", "", stamp, usage)
    copied_records = build_usage_records(copied_report, fork_time.date())
    assert copied_records["insights"]["worker_count"] == copied_records["insights"]["collaborative_sessions"] == 0
    assert copied_records["insights"]["first_active_day"] == "2026-01-01"
    assert copied_records["peak_hour"]["total_tokens"] == 10
    assert next(a for a in copied_records["achievements"] if a["id"] == "collaborative_days")["value"] == 0
    own_usage = Counter(total_tokens=20, calls=1)
    copied_report.seen_fingerprints[event_fingerprint("copied-parent", own_turn, "test", "test", "default", "", own_usage, own_usage, 2)] = "copied-worker"
    add_usage(copied_report, copied_parent, "test", "test", "default", "", fork_time + timedelta(seconds=60), own_usage)
    own_records = build_usage_records(copied_report, fork_time.date())
    assert own_records["insights"]["worker_count"] == own_records["insights"]["collaborative_sessions"] == 1
    assert next(a for a in own_records["achievements"] if a["id"] == "collaborative_sessions")["levels"][0]["unlocked_on"] is None
    assert own_records["insights"]["collaborative_days"] == 1
    copied_worker.descriptor.created_at = ""
    assert build_usage_records(copied_report, fork_time.date())["insights"]["worker_count"] == 0
    copied_worker.descriptor.created_at = fork_time.isoformat()
    copied_report.seen_fingerprints = {
        (fingerprint[0], "(no-turn)", *fingerprint[2:]): physical
        for fingerprint, physical in copied_report.seen_fingerprints.items()
    }
    assert build_usage_records(copied_report, fork_time.date())["insights"]["worker_count"] == 0

    # Many automatic workers in one conversation/day do not advance either
    # collaboration track more than once. Reuse the same worker across dates.
    habit_parent = session("habit-parent")
    habit_report = UsageReport(sessions=[habit_parent])
    habit_report.file_states[habit_parent.descriptor.session_id] = FileParserState(habit_parent.descriptor)
    habit_workers = [session(f"habit-worker-{index}") for index in range(100)]
    for index, worker in enumerate(habit_workers):
        worker.descriptor.is_internal = True
        worker.descriptor.physical_parent_id = habit_parent.descriptor.session_id
        worker.descriptor.created_at = start.isoformat()
        habit_report.file_states[worker.descriptor.session_id] = FileParserState(worker.descriptor)
        stamp = start + timedelta(seconds=index + 1)
        usage = Counter(total_tokens=1, calls=1)
        habit_report.seen_fingerprints[event_fingerprint("habit-parent", turn_uuid(stamp), "test", "test", "default", "", usage, usage, index)] = worker.descriptor.session_id
        add_usage(habit_report, habit_parent, "test", "test", "default", "", stamp, usage)
    burst_records = build_usage_records(habit_report, start.date())
    burst_badges = {a["id"]: a for a in burst_records["achievements"]}
    assert burst_records["insights"]["largest_team_session"]["worker_count"] == 100
    assert burst_badges["collaborative_sessions"]["value"] == burst_badges["collaborative_days"]["value"] == 1
    assert all(level["unlocked_on"] is None for key in ("collaborative_sessions", "collaborative_days") for level in burst_badges[key]["levels"])
    for offset in range(1, 100):
        stamp = start + timedelta(days=offset)
        usage = Counter(total_tokens=1, calls=1)
        habit_report.seen_fingerprints[event_fingerprint("habit-parent", turn_uuid(stamp), "test", "test", "default", "", usage, usage, offset + 100)] = habit_workers[0].descriptor.session_id
        add_usage(habit_report, habit_parent, "test", "test", "default", "", stamp, usage)
    for target in RECORD_ACHIEVEMENT_TARGETS["collaborative_days"]:
        for count in (target - 1, target):
            checked = build_usage_records(habit_report, start.date() + timedelta(days=count - 1))
            badge = next(a for a in checked["achievements"] if a["id"] == "collaborative_days")
            assert badge["value"] == count
            assert sum(level["unlocked_on"] is not None for level in badge["levels"]) == sum(count >= goal for goal in RECORD_ACHIEVEMENT_TARGETS["collaborative_days"])
        assert next(level for level in badge["levels"] if level["target"] == target)["unlocked_on"] == (start.date() + timedelta(days=target - 1)).isoformat()
    assert habit_report.totals["total_tokens"] == 199

    # Conversation thresholds count logical conversations, not calls, while
    # their dates stop at the last eligible threshold crossing.
    journey = UsageReport(sessions=[])
    for count in range(1, 502):
        traveler = session(f"journey-{count}")
        journey.sessions.append(traveler)
        stamp = start + timedelta(days=count - 1)
        add_usage(journey, traveler, "test", "test", "default", "", stamp, Counter(total_tokens=1, calls=1000))
        if any(abs(count - target) <= 1 for target in CONVERSATION_ACHIEVEMENT_TARGETS):
            badge = next(a for a in build_usage_records(journey, stamp.date())["achievements"] if a["id"] == "sessions")
            assert badge["value"] == count
            for level in badge["levels"]:
                expected_date = (start.date() + timedelta(days=level["target"] - 1)).isoformat() if count >= level["target"] else None
                assert level["unlocked_on"] == expected_date

    # Memoized ancestry retains physical-chain semantics even when an ancestor
    # has its own explicit conversation override, and terminates on cycles.
    ancestry_root, override_root = session("ancestry-root"), session("override-root")
    ancestry = [ancestry_root.descriptor, override_root.descriptor]
    for index in range(1000):
        descendant = session(f"descendant-{index}").descriptor
        descendant.is_internal = True
        descendant.physical_parent_id = ancestry_root.descriptor.session_id if index == 0 else f"descendant-{index - 1}"
        if index == 0:
            descendant.conversation_id = override_root.descriptor.session_id
        ancestry.append(descendant)
    ancestry_owners = logical_owner_ids(reversed(ancestry))
    assert ancestry_owners["descendant-0"] == "override-root"
    assert ancestry_owners["descendant-999"] == "ancestry-root"
    ancestry[2].physical_parent_id = "descendant-999"
    cycle_owners = logical_owner_ids(ancestry)
    assert cycle_owners["descendant-0"] == "override-root"
    assert cycle_owners["descendant-999"] == "descendant-999"

    # Large cumulative totals with incomplete chronology unlock badges while
    # dates stay null until eligible events alone cross the exact thresholds.
    dated_volume, undated_volume = session("dated-volume"), session("undated-volume")
    undated_volume.missing_timestamp_events = 1
    volume_report = UsageReport(sessions=[dated_volume, undated_volume])
    highest_usage = Counter({field_name: RECORD_ACHIEVEMENT_TARGETS[key][-1] for key, field_name in RECORD_VOLUME_FIELDS.items()})
    highest_usage["calls"] = 1
    add_usage(volume_report, undated_volume, "test", "volume-model", "default", "", start, highest_usage)
    dated_cumulative = Counter()
    for level_index in range(len(ACHIEVEMENT_LEVEL_NAMES)):
        tier_fields = {key: field_name for key, field_name in RECORD_VOLUME_FIELDS.items() if level_index < len(RECORD_ACHIEVEMENT_TARGETS[key])}
        below_target = Counter({field_name: RECORD_ACHIEVEMENT_TARGETS[key][level_index] - 1 for key, field_name in tier_fields.items()})
        delta = Counter({field_name: below_target[field_name] - dated_cumulative[field_name] for field_name in tier_fields.values()})
        delta["calls"] = 1
        stamp = start + timedelta(days=level_index * 2 + 1)
        add_usage(volume_report, dated_volume, "test", "volume-model", "default", "", stamp, delta)
        before = {a["id"]: a for a in build_usage_records(volume_report, stamp.date())["achievements"]}
        assert all(before[key]["levels"][level_index]["unlocked_on"] is None for key in tier_fields)
        step = Counter({field_name: 1 for field_name in tier_fields.values()})
        step["calls"] = 1
        add_usage(volume_report, dated_volume, "test", "volume-model", "default", "", stamp + timedelta(days=1), step)
        dated_cumulative = below_target + step
        after = {a["id"]: a for a in build_usage_records(volume_report, stamp.date() + timedelta(days=1))["achievements"]}
        for key, field_name in tier_fields.items():
            assert after[key]["value"] == after[key]["current_value"] == volume_report.totals[field_name]
            assert after[key]["levels"][level_index]["unlocked_on"] == (stamp.date() + timedelta(days=1)).isoformat()
            assert after[key]["unit"] == "Token"

    empty = build_usage_records(UsageReport(sessions=[]), date(2026, 1, 1))
    assert empty["peak_hour"] is None and empty["peak_throughput"] is None and empty["longest_activity"] is None
    assert empty["active_days"] == empty["current_streak"] == empty["longest_streak"] == 0
    assert all(a["value"] == 0 for a in empty["achievements"])
    assert empty["insights"] == {
        "first_active_day": None, "model_count": 0, "collaborative_sessions": 0, "worker_count": 0,
        "peak_day": None, "peak_output_day": None, "busiest_day": None, "most_models_session": None, "models": [],
        "collaborative_days": 0, "largest_team_session": None,
    }
    assert [a["id"] for a in empty["achievements"]] == [
        "streak", "days", "sessions", "models", "session_models", "daily_sessions", "collaborative_sessions",
        "collaborative_days", "total_tokens", "output_tokens", "reasoning_tokens", "cached_tokens",
    ]
    assert [a["category"] for a in empty["achievements"]] == ["habit"] * 3 + ["exploration"] * 3 + ["collaboration"] * 2 + ["volume"] * 4
    assert [list(level["target"] for level in a["levels"]) for a in empty["achievements"]] == [
        [3, 7, 14], [7, 30, 90, 365], [10, 30, 100, 500], [2, 4, 6], [2, 3, 4], [2, 4, 8], [3, 10, 30], [3, 10, 30, 100],
        [100_000_000, 1_000_000_000, 5_000_000_000, 25_000_000_000], [1_000_000, 5_000_000, 20_000_000, 100_000_000],
        [500_000, 2_000_000, 10_000_000], [100_000_000, 1_000_000_000, 5_000_000_000],
    ]
    assert all(a["rule"] and [level["name"] for level in a["levels"][:3]] == ["铜", "银", "金"] for a in empty["achievements"])
    assert {a["id"] for a in empty["achievements"] if len(a["levels"]) == 4} == {"days", "sessions", "collaborative_days", "total_tokens", "output_tokens"}
    assert all(level["hidden"] == (level["name"] == "钻石") for a in empty["achievements"] for level in a["levels"])
    assert REPORT_SCHEMA_VERSION == 11 and INCREMENTAL_CACHE_VERSION == 4


def run_self_test() -> None:
    run_records_self_test()
    with tempfile.TemporaryDirectory() as temp_dir:
        empty_report = UsageReport(sessions=[], sessions_root=Path(temp_dir) / "empty")
        empty_data = build_dashboard_data(empty_report)
        assert empty_data["totals"]["all"]["total_tokens"] == 0
        assert empty_data["models"] == []
        assert empty_data["range"]["start"] == empty_data["range"]["end"]
        assert "tooltip.textContent = content" in render_html(empty_report)
        index_file = Path(temp_dir) / "session_index.jsonl"
        index_file.write_text(json.dumps({"id": "index-only", "thread_name": "Named session"}) + "\n", encoding="utf-8")
        indexed_info = read_thread_info(Path(temp_dir) / "absent.sqlite", index_file)
        assert indexed_info["id:index-only"].title == "Named session"
        assert not (Path(temp_dir) / "absent.sqlite").exists()
        root = Path(temp_dir) / "sessions"
        parent_dir = root / "2026" / "01" / "01"
        child_dir = root / "2026" / "01" / "02"
        parent_dir.mkdir(parents=True)
        child_dir.mkdir(parents=True)
        parent_id = "00000000-0000-4000-8000-000000000001"
        child_id = "00000000-0000-4000-8000-000000000002"
        user_fork_id = "00000000-0000-4000-8000-000000000003"

        def meta(
            session_id: str,
            parent: str = "",
            source: Any = "cli",
            provider: str = "OpenAI",
        ) -> str:
            return synthetic_event(
                "2026-01-01T00:00:00Z",
                "session_meta",
                {
                    "id": session_id,
                    "forked_from_id": parent or None,
                    "timestamp": "2026-01-01T00:00:00Z",
                    "model_provider": provider,
                    "cli_version": "0.test",
                    "originator": "codex_cli_rs",
                    "source": source,
                },
            )

        def context(turn: str, model: str, timestamp: str) -> str:
            return synthetic_event(
                timestamp,
                "turn_context",
                {"turn_id": turn, "model": model},
            )

        def settings(
            model: str,
            provider: str,
            service_tier: str,
            effort: str,
            timestamp: str,
        ) -> str:
            return synthetic_event(
                timestamp,
                "event_msg",
                {
                    "type": "thread_settings_applied",
                    "thread_settings": {
                        "model": model,
                        "model_provider_id": provider,
                        "service_tier": service_tier,
                        "reasoning_effort": effort,
                    },
                },
            )

        def usage_event(
            turn_total: int,
            last: dict[str, int] | None,
            timestamp: str,
        ) -> str:
            input_tokens = turn_total - 10
            info: dict[str, Any] = {
                "total_token_usage": {
                    "input_tokens": input_tokens,
                    "cached_input_tokens": 0,
                    "output_tokens": 10,
                    "reasoning_output_tokens": 0,
                    "total_tokens": turn_total,
                },
                "model_context_window": 1000,
            }
            if last is not None:
                info["last_token_usage"] = last
            return synthetic_event(
                timestamp,
                "event_msg",
                {
                    "type": "token_count",
                    "info": info,
                },
            )

        first_last = {
            "input_tokens": 90,
            "cached_input_tokens": 0,
            "output_tokens": 10,
            "reasoning_output_tokens": 0,
            "total_tokens": 100,
        }
        second_last = {
            "input_tokens": 45,
            "cached_input_tokens": 0,
            "output_tokens": 5,
            "reasoning_output_tokens": 0,
            "total_tokens": 50,
        }
        total_only_last = {
            "input_tokens": 0,
            "cached_input_tokens": 0,
            "output_tokens": 0,
            "reasoning_output_tokens": 0,
            "total_tokens": 30,
        }
        parent_lines = [
            meta(parent_id),
            context("turn-a", "gpt-a", "2026-01-01T00:00:01Z"),
            usage_event(100, first_last, "2026-01-01T00:00:02Z"),
            usage_event(100, first_last, "2026-01-01T00:00:03Z"),
            context("turn-b", "gpt-b", "2026-01-01T01:00:01Z"),
            usage_event(150, second_last, "2026-01-01T01:00:02Z"),
        ]
        child_lines = [
            meta(
                child_id,
                parent_id,
                {"subagent": {"thread_spawn": {"parent_thread_id": parent_id}}},
            ),
            meta(parent_id),
            context("turn-a", "gpt-a", "2026-01-02T00:00:01Z"),
            usage_event(100, first_last, "2026-01-02T00:00:02Z"),
            context("turn-b", "gpt-b", "2026-01-02T00:00:03Z"),
            usage_event(150, second_last, "2026-01-02T00:00:04Z"),
            settings("deepseek-v4-pro", "DeepSeek", "default", "high", "2026-01-02T02:00:00Z"),
            context("turn-c", "deepseek-v4-pro", "2026-01-02T02:00:01Z"),
            usage_event(180, total_only_last, "2026-01-02T02:00:02Z"),
            settings("gpt-5.6-sol", "OpenAI", "fast", "xhigh", "2026-01-02T03:00:00Z"),
            context("turn-d", "gpt-5.6-sol", "2026-01-02T03:00:01Z"),
            usage_event(200, None, "2026-01-02T03:00:02Z"),
        ]
        (parent_dir / f"rollout-{parent_id}.jsonl").write_text(
            "\n".join(parent_lines) + "\n",
            encoding="utf-8",
        )
        (child_dir / f"rollout-{child_id}.jsonl").write_text(
            "\n".join(child_lines) + "\n",
            encoding="utf-8",
        )
        (child_dir / f"rollout-{user_fork_id}.jsonl").write_text(
            meta(user_fork_id, parent_id) + "\n",
            encoding="utf-8",
        )

        report = collect_usage(
            root,
            thread_info={},
            fallback_service_tier=DEFAULT_SERVICE_TIER,
        )
        assert report.totals["total_tokens"] == 200
        assert report.totals["unclassified_tokens"] == 30
        assert report.totals["calls"] == 4
        assert report.totals_by_model["gpt-a"]["total_tokens"] == 100
        assert report.totals_by_model["gpt-b"]["total_tokens"] == 50
        assert report.totals_by_model["deepseek-v4-pro"]["total_tokens"] == 30
        assert report.totals_by_model["gpt-5.6-sol"]["total_tokens"] == 20
        assert report.totals_by_provider["DeepSeek"]["total_tokens"] == 30
        assert report.totals_by_service_tier["priority"]["total_tokens"] == 20
        assert report.totals_by_reasoning_effort["xhigh"]["total_tokens"] == 20
        assert report.usage_by_route[("OpenAI", "gpt-5.6-sol", "priority")]["calls"] == 1
        assert report.inherited_events == 2
        assert report.local_duplicate_events == 1
        assert report.fallback_delta_events == 1
        parent_stats = next(
            stats
            for stats in report.sessions
            if stats.descriptor.session_id == parent_id
        )
        assert len(report.sessions) == 2
        assert parent_stats.total["total_tokens"] == 200
        assert parent_stats.rollout_files == 2
        assert parent_stats.internal_thread_count == 1
        assert report.rollout_files == 3
        assert report.conversation_sessions == 2
        assert report.internal_threads == 1
        assert report.fork_sessions == 1
        assert report.orphan_internal_threads == 0
        assert next(
            stats for stats in report.sessions
            if stats.descriptor.session_id == user_fork_id
        ).descriptor.parent_id == parent_id
        assert clean_text({"unexpected": "object"}) == ""
        assert pricing_for_model("gpt-5.6-luna-2026-07-01")[0] == "gpt-5.6-luna"
        assert pricing_for_model("gpt-6-astra-2026-08-31")[0] == "gpt-6-astra"
        assert pricing_for_model("gemini-3.8-flash")[1]["input"] == 0.75
        assert pricing_for_model("claude-fable-5-1")[1]["cached_input"] == 0.25
        assert pricing_for_model("grok-4.6")[1]["output"] == 6.0
        assert pricing_for_model("gpt-4o-mini-2024-07-18")[0] == "gpt-4o-mini"
        assert pricing_for_model("gpt-4o-2024-05-13")[0] == "gpt-4o-2024-05-13"
        assert pricing_for_model("gpt-3.5-turbo-0125")[0] == "gpt-3.5-turbo-0125"
        assert pricing_for_model("gpt-future") is None
        assert pricing_for_model("gpt-5.6-sol", "qwen_local", {}) is None

        priced_usage = Counter(
            {
                "input_tokens": 1000,
                "cached_input_tokens": 400,
                "cache_write_input_tokens": 100,
                "uncached_input_tokens": 500,
                "output_tokens": 100,
                "total_tokens": 1100,
                "calls": 1,
            }
        )
        priority_cost = estimate_usage_cost(
            "OpenAI", "gpt-5.6-sol", "priority", priced_usage
        )
        assert abs(priority_cost["estimated_cost_usd"] - 0.00932) < 1e-12
        assert abs(priority_cost["standard_equivalent_cost_usd"] - 0.00466) < 1e-12
        assert abs(priority_cost["cache_write_input_cost_usd"] - 0.001) < 1e-12
        assert abs(priority_cost["standard_cache_write_input_cost_usd"] - 0.0005) < 1e-12
        assert abs(priority_cost["standard_cached_input_cost_usd"] - 0.00016) < 1e-12
        assert abs(priority_cost["cache_savings_usd"] - 2 * priority_cost["standard_cache_savings_usd"]) < 1e-12
        assert priority_cost["priority_tier_calls"] == 1
        assert normalize_service_tier("fast") == "priority"
        assert normalize_provider("openai") == "OpenAI"
        config_file = Path(temp_dir) / "config.toml"
        config_file.write_text(
            'service_tier = "fast"\n\n[projects."/tmp"]\nservice_tier = "default"\n',
            encoding="utf-8",
        )
        assert read_configured_service_tier(config_file) == "priority"
        config_file.write_text(
            '[projects."/tmp"]\nservice_tier = "fast"\n',
            encoding="utf-8",
        )
        assert read_configured_service_tier(config_file) == DEFAULT_SERVICE_TIER

        gemini_pricing = pricing_for_model("gemini-2.5-pro")[1]
        gemini_standard, gemini_long = standard_rates_for_usage(
            gemini_pricing, Counter({"input_tokens": 200_001})
        )
        gemini_priority, gemini_fallback = rates_for_service_tier(
            gemini_pricing, gemini_standard, "priority"
        )
        assert gemini_long
        assert not gemini_fallback
        assert gemini_standard["input"] == 2.5
        assert gemini_priority["input"] == 4.5
        assert gemini_priority["output"] == 27.0
        assert rates_for_service_tier(gemini_pricing, gemini_standard, "flex")[1]
        astra_pricing = pricing_for_model("gpt-6-astra")[1]
        astra_long, astra_is_long = standard_rates_for_usage(
            astra_pricing, Counter({"input_tokens": LONG_CONTEXT_THRESHOLD + 1})
        )
        astra_fast, astra_fast_fallback = rates_for_service_tier(
            astra_pricing, astra_long, "priority"
        )
        assert astra_is_long
        assert not astra_fast_fallback
        assert astra_long["input"] == 20.0
        assert astra_fast["input"] == 40.0
        assert astra_fast["output"] == 150.0
        grok_pricing = pricing_for_model("grok-4.6")[1]
        grok_long, grok_is_long = standard_rates_for_usage(
            grok_pricing, Counter({"input_tokens": 200_001})
        )
        grok_priority, grok_priority_fallback = rates_for_service_tier(
            grok_pricing, grok_long, "priority"
        )
        assert grok_is_long
        assert grok_long["input"] == 4.0
        assert grok_priority["input"] == 4.0
        assert grok_priority_fallback
        gpt55_standard, _ = standard_rates_for_usage(
            pricing_for_model("gpt-5.5")[1], Counter()
        )
        gpt55_priority, _ = rates_for_service_tier(
            pricing_for_model("gpt-5.5")[1], gpt55_standard, "priority"
        )
        assert gpt55_priority["cache_write_input"] == 12.5

        deepseek_peak_cost = estimate_usage_cost(
            "Relay",
            "deepseek-v4-pro",
            "default",
            priced_usage,
            timestamp=datetime(2026, 9, 7, 2, tzinfo=timezone.utc),
        )
        deepseek_off_peak_cost = estimate_usage_cost(
            "Relay",
            "deepseek-v4-pro",
            "default",
            priced_usage,
            timestamp=datetime(2026, 9, 6, 2, tzinfo=timezone.utc),
        )
        assert abs(
            deepseek_peak_cost["cache_write_input_cost_usd"] - 0.000132
        ) < 1e-12
        assert abs(
            deepseek_peak_cost["estimated_cost_usd"] - 0.0012056
        ) < 1e-12
        assert abs(
            deepseek_off_peak_cost["estimated_cost_usd"] - 0.0006028
        ) < 1e-12
        alias_file = Path(temp_dir) / "token_atlas_pricing.json"
        alias_file.write_text(
            json.dumps(
                {
                    "aliases": {
                        "Relay/internal-sol": "gpt-5.6-sol",
                        "bad": "not-an-official-model",
                    },
                    "models": {
                        "gpt-5.6-sol": {
                            "provider": "Custom",
                            "input": 0,
                            "output": 0,
                        },
                        "Qwen3.8-27B": {
                            "provider": "Local Qodex",
                            "input": 0.2,
                            "cached_input": 0.05,
                            "cache_write_input": 0.1,
                            "output": 0.8,
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        aliases, custom_models, alias_errors = read_pricing_config(
            alias_file,
            PRICING_USD_PER_MTOK,
        )
        assert aliases["relay/internal-sol"] == "gpt-5.6-sol"
        assert "bad" not in aliases
        assert len(alias_errors) == 1
        assert "gpt-5.6-sol" not in custom_models
        assert custom_models["qwen3.8-27b"]["pricing_kind"] == "custom"
        assert custom_models["qwen3.8-27b"]["provider"] == "Local Qodex"
        custom_catalog = dict(PRICING_USD_PER_MTOK)
        custom_catalog.update(custom_models)
        qwen_cost = estimate_usage_cost(
            "Local Qodex",
            "Qwen3.8-27B",
            "default",
            priced_usage,
            custom_catalog,
            aliases,
        )
        assert abs(qwen_cost["estimated_cost_usd"] - 0.00021) < 1e-12
        assert qwen_cost["priced_tokens"] == priced_usage["total_tokens"]
        assert pricing_for_model(
            "internal-sol", "Relay", PRICING_USD_PER_MTOK, aliases
        )[0] == "gpt-5.6-sol"

        dashboard = build_dashboard_data(report)
        assert summary_payload(report)["dashboard"]["totals"]["all"]["total_tokens"] == 200
        assert dashboard["timeline_hourly"]["all"]["2026-01-02T11"]["total_tokens"] == 20
        parent_dashboard = next(item for item in dashboard["sessions"] if item["id"] == parent_id)
        assert parent_dashboard["by_day"]["2026-01-02"]["total_tokens"] == 50
        assert parent_dashboard["costs_by_day"]["2026-01-02"]["priority_tier_calls"] == 1
        assert parent_dashboard["costs_by_day_model"]["2026-01-02"]["gpt-5.6-sol"]["standard_equivalent_cost_usd"] > 0
        assert parent_dashboard["internal_thread_count"] == 1
        assert dashboard["audit"]["conversation_sessions"] == 2
        priority_route = next(
            item
            for item in dashboard["pricing"]["routes"]
            if item["model"] == "gpt-5.6-sol" and item["service_tier"] == "priority"
        )
        assert priority_route["daily"]["2026-01-02"]["usage"]["total_tokens"] == 20
        assert priority_route["standard_rates"]["input"] == 4.0
        assert priority_route["rates"]["input"] == 8.0
        assert dashboard["pricing"]["hourly"]["all"][4][11]["priority_tier_calls"] == 1
        assert dashboard["pricing"]["timeline_hourly"]["gpt-5.6-sol"]["2026-01-02T11"]["priority_tier_calls"] == 1
        assert dashboard["pricing"]["daily"]["all"]["2026-01-02"]["unpriced_tokens"] == 30
        assert "一周 × 24 小时" in render_html(report)
        assert "Token 价值估算" in render_html(report)

        incremental_last = {
            "input_tokens": 10,
            "cached_input_tokens": 0,
            "output_tokens": 10,
            "reasoning_output_tokens": 0,
            "total_tokens": 20,
        }
        parent_path = parent_dir / f"rollout-{parent_id}.jsonl"
        with parent_path.open("a", encoding="utf-8") as handle:
            handle.write(
                "\n".join(
                    [
                        context("turn-incremental", "gpt-a", "2026-01-01T02:00:00Z"),
                        synthetic_event(
                            "2026-01-01T02:00:01Z",
                            "response_item",
                            {
                                "type": "reasoning",
                                "content": [
                                    {"type": "reasoning_text", "text": "plan"}
                                ],
                            },
                        ),
                        usage_event(170, incremental_last, "2026-01-01T02:00:02Z"),
                    ]
                )
                + "\n"
            )
        parent_state = report.file_states[normalized_path(parent_path)]
        process_incremental_file(
            report,
            parent_state,
            parent_stats,
            ReasoningTokenCounter(Path(temp_dir), search_roots=()),
        )
        assert report.totals["total_tokens"] == 220
        assert report.totals["calls"] == 5
        assert report.totals["reasoning_output_tokens"] > 0
        assert report.inferred_reasoning_events == 1
        assert parent_stats.total["total_tokens"] == 220
        fresh_report = collect_usage(
            root,
            thread_info={},
            fallback_service_tier=DEFAULT_SERVICE_TIER,
            reasoning_counter=ReasoningTokenCounter(Path(temp_dir), search_roots=()),
        )
        assert counter_dict(report.totals) == counter_dict(fresh_report.totals)
        assert {
            model: counter_dict(usage)
            for model, usage in report.totals_by_model.items()
        } == {
            model: counter_dict(usage)
            for model, usage in fresh_report.totals_by_model.items()
        }
        assert report.inferred_reasoning_events == fresh_report.inferred_reasoning_events
        assert report.inferred_reasoning_tokens == fresh_report.inferred_reasoning_tokens
        assert [counter_dict(stats.total) for stats in report.sessions] == [
            counter_dict(stats.total) for stats in fresh_report.sessions
        ]
        assert build_usage_records(report) == build_usage_records(fresh_report)

        qodex_home = Path(temp_dir) / ".qodex"
        qodex_session_dir = qodex_home / "sessions" / "2026" / "01" / "03"
        qodex_session_dir.mkdir(parents=True)
        qodex_id = "00000000-0000-4000-8000-000000000004"
        (qodex_session_dir / f"rollout-{qodex_id}.jsonl").write_text(
            "\n".join(
                [
                    meta(qodex_id, provider="qwen_local"),
                    settings(
                        "gpt-5.6-sol",
                        "qwen_local",
                        "default",
                        "ultra",
                        "2026-01-03T00:00:00Z",
                    ),
                    context(
                        "turn-qodex",
                        "gpt-5.6-sol",
                        "2026-01-03T00:00:01Z",
                    ),
                    synthetic_event(
                        "2026-01-03T00:00:01.500Z",
                        "response_item",
                        {
                            "type": "reasoning",
                            "content": [
                                {"type": "reasoning_text", "text": "check the plan"}
                            ],
                        },
                    ),
                    usage_event(100, first_last, "2026-01-03T00:00:02Z"),
                    synthetic_event(
                        "2026-01-03T00:00:02.500Z",
                        "response_item",
                        {
                            "type": "reasoning",
                            "content": [
                                {"type": "reasoning_text", "text": "check the plan"}
                            ],
                        },
                    ),
                    usage_event(100, first_last, "2026-01-03T00:00:03Z"),
                ]
            ) + "\n",
            encoding="utf-8",
        )
        qodex_source = usage_source_from_home(qodex_home)
        qodex_report = collect_source_usage(qodex_source)
        qodex_dashboard = build_dashboard_data(qodex_report)
        assert qodex_source.key == "qodex"
        assert not qodex_source.read_billing_context
        assert not qodex_source.read_service_tier
        assert not qodex_source.enable_official_pricing
        assert qodex_report.billing_context == {}
        assert qodex_report.fork_sessions == 0
        assert qodex_report.internal_threads == 0
        assert qodex_dashboard["models"] == ["gpt-5.6-sol"]
        assert qodex_dashboard["totals"]["all"]["total_tokens"] == 100
        assert 0 < qodex_dashboard["totals"]["all"]["reasoning_output_tokens"] <= 10
        assert qodex_dashboard["audit"]["inferred_reasoning_events"] == 1
        assert qodex_dashboard["audit"]["inferred_reasoning_tokens"] > 0
        assert qodex_dashboard["pricing"]["scopes"]["all"]["priced_tokens"] == 0
        assert qodex_dashboard["pricing"]["scopes"]["all"]["unpriced_tokens"] == 100

        qodex_cache_path = incremental_cache_path(qodex_source)
        CACHE_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
        legacy_qodex_report = pickle.loads(pickle.dumps(qodex_report))
        del legacy_qodex_report.custom_pricing_models
        del legacy_qodex_report.billable_events
        del legacy_qodex_report.pricing_revision
        with qodex_cache_path.open("wb") as handle:
            pickle.dump(
                IncrementalCacheEnvelope(
                    version=1,
                    source_home=str(qodex_source.home),
                    auxiliary_manifest=legacy_auxiliary_input_manifest(qodex_source),
                    report=legacy_qodex_report,
                ),
                handle,
            )
        qodex_cache_path.chmod(0o600)
        migrated_qodex_report = load_incremental_cache(qodex_source)
        assert migrated_qodex_report is None
        qodex_cache_path.unlink()

        qodex_source.model_aliases_file.write_text(
            json.dumps(
                {
                    "models": {
                        "gpt-5.6-sol": {
                            "provider": "Qodex",
                            "input": 1.0,
                            "cached_input": 0.25,
                            "cache_write_input": 1.0,
                            "output": 2.0,
                        }
                    }
                }
            ),
            encoding="utf-8",
        )
        qodex_report = collect_source_usage(qodex_source)
        qodex_dashboard = build_dashboard_data(qodex_report)
        assert qodex_report.custom_pricing_models == {"gpt-5.6-sol"}
        assert qodex_dashboard["pricing"]["custom_models"] == ["gpt-5.6-sol"]
        assert qodex_dashboard["pricing"]["scopes"]["all"]["priced_tokens"] == 100
        assert qodex_dashboard["pricing"]["scopes"]["all"]["unpriced_tokens"] == 0
        assert abs(
            qodex_dashboard["pricing"]["scopes"]["all"]["estimated_cost_usd"]
            - 0.00011
        ) < 1e-12
        assert qodex_dashboard["pricing"]["routes"][0]["pricing_kind"] == "custom"

        try:
            with qodex_cache_path.open("wb") as handle:
                pickle.dump(
                    IncrementalCacheEnvelope(
                        version=1,
                        source_home=str(qodex_source.home),
                        auxiliary_manifest=legacy_auxiliary_input_manifest(qodex_source),
                        report=qodex_report,
                    ),
                    handle,
                )
            qodex_cache_path.chmod(0o600)
            assert load_incremental_cache(qodex_source) is None
            save_incremental_cache(qodex_source, qodex_report)
            qodex_source.model_aliases_file.write_text(
                json.dumps(
                    {
                        "models": {
                            "gpt-5.6-sol": {
                                "provider": "Qodex",
                                "input": 2.0,
                                "cached_input": 0.5,
                                "cache_write_input": 2.0,
                                "output": 4.0,
                            }
                        }
                    }
                ),
                encoding="utf-8",
            )
            repriced_qodex = load_incremental_cache(qodex_source)
            assert repriced_qodex is not None
            assert repriced_qodex.totals["total_tokens"] == 100
            assert abs(
                repriced_qodex.costs_by_model["gpt-5.6-sol"][
                    "estimated_cost_usd"
                ]
                - 0.00022
            ) < 1e-12
            next_qodex_id = "00000000-0000-4000-8000-000000000005"
            next_qodex_path = qodex_session_dir / f"rollout-{next_qodex_id}.jsonl"
            next_qodex_path.write_text(
                "\n".join(
                    [
                        meta(next_qodex_id, provider="qwen_local"),
                        context(
                            "turn-qodex-next",
                            "gpt-5.6-sol",
                            "2026-01-03T01:00:01Z",
                        ),
                        usage_event(100, first_last, "2026-01-03T01:00:02Z"),
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            incremental_qodex = incrementally_refresh_usage(qodex_source)
            assert incremental_qodex is not None
            assert incremental_qodex.totals["total_tokens"] == 200
            assert incremental_qodex.totals["calls"] == 2
            assert incremental_qodex.conversation_sessions == 2
            assert len(incremental_qodex.sessions) == 2
        finally:
            qodex_cache_path.unlink(missing_ok=True)

        relocated_codex = usage_source_from_home(
            Path(temp_dir) / "archive" / ".codex"
        )
        assert relocated_codex.label == "Codex"
        assert not relocated_codex.read_billing_context
        assert not relocated_codex.read_service_tier
        assert not relocated_codex.enable_official_pricing
        assert normalize_data_home(qodex_home / "sessions") == qodex_home.resolve()
        nested_home = Path(temp_dir) / "sessions"
        (nested_home / "sessions").mkdir(parents=True)
        assert normalize_data_home(nested_home) == nested_home.resolve()
    print(
        "Self-test passed: user-fork/internal-thread semantics, model filtering, "
        "reasoning inference, route attribution, pricing isolation, and total invariants."
    )


def collect_source_usage(source: UsageSource) -> UsageReport:
    fallback_service_tier = source_service_tier(source)
    billing_context = source_billing_context(source)
    report = collect_usage(
        source.sessions_root,
        thread_info=read_thread_info(source.state_db, source.session_index),
        fallback_service_tier=fallback_service_tier,
        source_key=source.key,
        source_label=source.label,
        model_aliases_file=source.model_aliases_file,
        billing_context=billing_context,
        # Official-price comparisons are scoped to the standard Codex source;
        # compatible local sources remain token-accounting sources.
        pricing_catalog={} if not source.enable_official_pricing else None,
    )
    report.pricing_revision = pricing_configuration_revision(source)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run synthetic regression tests without reading local sessions",
    )
    parser.add_argument(
        "--data-home",
        type=Path,
        default=CODEX_HOME,
        help="Codex-compatible data home containing sessions/ (SQLite metadata is optional)",
    )
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        return
    data_home = normalize_data_home(args.data_home)
    source = usage_source_from_home(data_home)
    if not source.sessions_root.is_dir():
        raise SystemExit(
            f"Compatible sessions directory not found: {source.sessions_root}"
        )

    started = time.perf_counter()
    input_manifest = source_input_manifest(source)
    scanned = time.perf_counter()
    summary = cached_summary(source, input_manifest)
    if summary is None:
        report = incrementally_refresh_usage(source)
        if report is None:
            print("Parser cache unavailable or accounting inputs changed; rebuilding full history.", flush=True)
            report = collect_source_usage(source)
        else:
            print("Loaded the source-specific parser cache; processed appended data only.", flush=True)
        parsed = time.perf_counter()
        summary = summary_payload(report, input_manifest)
        aggregated = time.perf_counter()
        write_export_outputs(report, summary["dashboard"])
        write_summary_outputs(summary, source)
        exported = time.perf_counter()
        save_incremental_cache(source, report)
        print(f"Refresh timing: manifest={scanned-started:.3f}s parse={parsed-scanned:.3f}s "
              f"aggregate={aggregated-parsed:.3f}s export={exported-aggregated:.3f}s "
              f"cache={time.perf_counter()-exported:.3f}s", flush=True)
    else:
        print("Usage inputs unchanged; reused the existing report.")
        if not source_summary_path(source).is_file():
            write_summary_outputs(summary, source)
    print(f"Refresh completed in {time.perf_counter()-started:.3f}s", flush=True)
    totals = summary["totals"]

    print(f"Data source: {source.label} ({source.home})")
    print(f"HTML: {OUTPUT_HTML}")
    print(f"Daily CSV: {OUTPUT_DAILY_CSV}")
    print(f"Hourly CSV: {OUTPUT_HOURLY_CSV}")
    print(f"Model CSV: {OUTPUT_MODEL_CSV}")
    print(f"Route CSV: {OUTPUT_ROUTE_CSV}")
    print(f"Session CSV: {OUTPUT_SESSION_CSV}")
    print(f"JSON: {OUTPUT_JSON}")
    print()
    print(f"Total tokens: {fmt_int(totals['total_tokens'])}")
    print(f"Input tokens: {fmt_int(totals['input_tokens'])}")
    print(f"Cached input tokens: {fmt_int(totals['cached_input_tokens'])}")
    print(f"Cache write input tokens: {fmt_int(totals['cache_write_input_tokens'])}")
    print(f"Output tokens: {fmt_int(totals['output_tokens'])}")
    print(f"Reasoning output tokens: {fmt_int(totals['reasoning_output_tokens'])}")
    print(f"Unclassified tokens: {fmt_int(totals['unclassified_tokens'])}")
    print(f"Unique model calls: {fmt_int(totals['calls'])}")
    print()
    audit = summary.get("audit") or {}
    print(
        "Fork/replay events skipped: "
        f"{fmt_int(audit.get('duplicate_events_skipped', 0))} "
        f"({fmt_int(audit.get('inherited_fork_events_skipped', 0))} inherited, "
        f"{fmt_int(audit.get('local_duplicate_events_skipped', 0))} local duplicates)"
    )
    print(f"Models: {', '.join(summary['usage_by_model'])}")


if __name__ == "__main__":
    main()
