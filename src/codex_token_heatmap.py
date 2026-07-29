#!/usr/bin/env python3
"""Build a fork-safe, model-aware Codex token usage dashboard."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sqlite3
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable
from zoneinfo import ZoneInfo


HOME = Path.home()
SESSIONS_ROOT = HOME / ".codex" / "sessions"
STATE_DB = HOME / ".codex" / "state_5.sqlite"
SESSION_INDEX = HOME / ".codex" / "session_index.jsonl"
AUTH_FILE = HOME / ".codex" / "auth.json"
MODEL_ALIASES_FILE = HOME / ".codex" / "token_atlas_pricing.json"

OUTPUT_HTML = HOME / "codex_token_heatmap.html"
OUTPUT_DAILY_CSV = HOME / "codex_token_usage_by_day.csv"
OUTPUT_HOURLY_CSV = HOME / "codex_token_usage_by_hour.csv"
OUTPUT_MODEL_CSV = HOME / "codex_token_usage_by_model.csv"
OUTPUT_ROUTE_CSV = HOME / "codex_token_usage_by_route.csv"
OUTPUT_SESSION_CSV = HOME / "codex_token_usage_by_session.csv"
OUTPUT_JSON = HOME / "codex_token_usage_summary.json"

LOCAL_TZ = ZoneInfo("Asia/Shanghai")
ALL_MODELS_KEY = "all"
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

PRICING_AS_OF = "2026-07-29"
LONG_CONTEXT_THRESHOLD = 272_000
OFFICIAL_PRICING_URL = "https://developers.openai.com/api/docs/pricing"


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
    source: str = OFFICIAL_PRICING_URL,
) -> dict[str, Any]:
    return {
        "provider": provider,
        "input": input_rate,
        "cached_input": cached_input_rate,
        "cache_write_input": cache_write_input_rate,
        "output": output_rate,
        "priority_rates": priority_rates,
        "long_context": long_context,
        "long_context_threshold": long_context_threshold,
        "long_context_rates": long_context_rates,
        "source": source,
    }


PRICING_USD_PER_MTOK: dict[str, dict[str, Any]] = {
    # Current GPT families and historical standard API models.
    "gpt-5.6-sol": pricing_rate(
        5.0, 0.5, 30.0,
        cache_write_input_rate=5.0,
        priority_rates=(10.0, 1.0, 10.0, 60.0),
        long_context=True,
    ),
    "gpt-5.6-terra": pricing_rate(
        2.5, 0.25, 15.0,
        cache_write_input_rate=2.5,
        priority_rates=(5.0, 0.5, 5.0, 30.0),
        long_context=True,
    ),
    "gpt-5.6-luna": pricing_rate(
        1.0, 0.1, 6.0,
        cache_write_input_rate=1.0,
        priority_rates=(2.0, 0.2, 2.0, 12.0),
        long_context=True,
    ),
    "gpt-5.6": pricing_rate(
        5.0, 0.5, 30.0,
        cache_write_input_rate=5.0,
        priority_rates=(10.0, 1.0, 10.0, 60.0),
        long_context=True,
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
        0.435,
        0.003625,
        0.87,
        cache_write_input_rate=0.435,
        provider="DeepSeek",
        source="https://api-docs.deepseek.com/quick_start/pricing",
    ),
    "deepseek-v4-flash": pricing_rate(
        0.14,
        0.0028,
        0.28,
        cache_write_input_rate=0.14,
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
    "gemini-3.6-flash": pricing_rate(
        1.5, 0.15, 7.5,
        priority_rates=(2.7, 0.27, None, 13.5),
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


@dataclass
class SessionDescriptor:
    path: Path
    session_id: str
    parent_id: str
    root_id: str
    lineage_depth: int
    created_at: str
    model_provider: str = ""
    cli_version: str = ""
    originator: str = ""
    source: str = ""
    context_window: int = 0
    thread: ThreadInfo = field(default_factory=ThreadInfo)


@dataclass
class SessionStats:
    descriptor: SessionDescriptor
    total: Counter = field(default_factory=Counter)
    by_model: dict[str, Counter] = field(default_factory=lambda: defaultdict(Counter))
    by_provider: dict[str, Counter] = field(default_factory=lambda: defaultdict(Counter))
    by_service_tier: dict[str, Counter] = field(default_factory=lambda: defaultdict(Counter))
    by_reasoning_effort: dict[str, Counter] = field(default_factory=lambda: defaultdict(Counter))
    by_route: dict[tuple[str, str, str], Counter] = field(
        default_factory=lambda: defaultdict(Counter)
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
    missing_timestamp_events: int = 0
    fallback_provider_events: int = 0
    fallback_service_tier_events: int = 0
    first_timestamp: str | None = None
    last_timestamp: str | None = None


@dataclass
class UsageReport:
    sessions: list[SessionStats]
    pricing_catalog: dict[str, dict[str, Any]] = field(default_factory=dict)
    pricing_aliases: dict[str, str] = field(default_factory=dict)
    pricing_config_errors: list[str] = field(default_factory=list)
    totals: Counter = field(default_factory=Counter)
    totals_by_model: dict[str, Counter] = field(default_factory=lambda: defaultdict(Counter))
    totals_by_provider: dict[str, Counter] = field(default_factory=lambda: defaultdict(Counter))
    totals_by_service_tier: dict[str, Counter] = field(default_factory=lambda: defaultdict(Counter))
    totals_by_reasoning_effort: dict[str, Counter] = field(default_factory=lambda: defaultdict(Counter))
    usage_by_route: dict[tuple[str, str, str], Counter] = field(
        default_factory=lambda: defaultdict(Counter)
    )
    by_day: dict[date, Counter] = field(default_factory=lambda: defaultdict(Counter))
    by_day_model: dict[date, dict[str, Counter]] = field(
        default_factory=lambda: defaultdict(lambda: defaultdict(Counter))
    )
    by_hour: dict[datetime, Counter] = field(default_factory=lambda: defaultdict(Counter))
    by_hour_model: dict[datetime, dict[str, Counter]] = field(
        default_factory=lambda: defaultdict(lambda: defaultdict(Counter))
    )
    weekday_hour: dict[tuple[int, int], Counter] = field(
        default_factory=lambda: defaultdict(Counter)
    )
    weekday_hour_model: dict[tuple[int, int], dict[str, Counter]] = field(
        default_factory=lambda: defaultdict(lambda: defaultdict(Counter))
    )
    costs_by_model: dict[str, Counter] = field(
        default_factory=lambda: defaultdict(Counter)
    )
    costs_by_route: dict[tuple[str, str, str], Counter] = field(
        default_factory=lambda: defaultdict(Counter)
    )
    costs_by_day: dict[date, Counter] = field(default_factory=lambda: defaultdict(Counter))
    costs_by_day_model: dict[date, dict[str, Counter]] = field(
        default_factory=lambda: defaultdict(lambda: defaultdict(Counter))
    )
    costs_weekday_hour: dict[tuple[int, int], Counter] = field(
        default_factory=lambda: defaultdict(Counter)
    )
    costs_weekday_hour_model: dict[tuple[int, int], dict[str, Counter]] = field(
        default_factory=lambda: defaultdict(lambda: defaultdict(Counter))
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
    missing_timestamp_events: int = 0
    fallback_provider_events: int = 0
    fallback_service_tier_events: int = 0
    fork_sessions: int = 0
    sqlite_threads_total_tokens: int = 0


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


def clean_text(value: str | None, limit: int | None = None) -> str:
    text = " ".join((value or "").split())
    if limit is not None and len(text) > limit:
        return text[: max(0, limit - 1)].rstrip() + "…"
    return text


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
                row = json.loads(line)
            except json.JSONDecodeError:
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
    if not state_db.exists():
        return {}

    indexed_names = read_session_index_names(session_index)
    try:
        with sqlite3.connect(state_db) as conn:
            conn.row_factory = sqlite3.Row
            columns = {row[1] for row in conn.execute("pragma table_info(threads)")}
            required = {"id", "rollout_path"}
            if not required.issubset(columns):
                return {}

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
            result: dict[str, ThreadInfo] = {}
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
        return {}


def read_leading_session_meta(path: Path) -> list[dict[str, Any]]:
    metadata: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                if metadata:
                    break
                continue
            if obj.get("type") != "session_meta":
                if metadata:
                    break
                continue
            payload = obj.get("payload") or {}
            metadata.append(
                {
                    "id": str(payload.get("id") or ""),
                    "parent_id": str(payload.get("forked_from_id") or ""),
                    "timestamp": str(payload.get("timestamp") or obj.get("timestamp") or ""),
                    "model_provider": clean_text(payload.get("model_provider")),
                    "cli_version": clean_text(payload.get("cli_version")),
                    "originator": clean_text(payload.get("originator")),
                    "source": clean_text(payload.get("source") or payload.get("thread_source")),
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
) -> list[SessionDescriptor]:
    paths = sorted(sessions_root.rglob("*.jsonl"))
    leading_meta: dict[Path, list[dict[str, Any]]] = {}
    parent_map: dict[str, str] = {}

    for path in paths:
        rows = read_leading_session_meta(path)
        leading_meta[path] = rows
        for row in rows:
            if row["id"]:
                parent_map[row["id"]] = row["parent_id"]

    descriptors: list[SessionDescriptor] = []
    for path in paths:
        rows = leading_meta[path]
        first = rows[0] if rows else {}
        session_id = str(first.get("id") or session_id_from_filename(path))
        parent_id = str(first.get("parent_id") or "")
        created_at = str(first.get("timestamp") or "")
        descriptors.append(
            SessionDescriptor(
                path=path,
                session_id=session_id,
                parent_id=parent_id,
                root_id=lineage_root(session_id, parent_map),
                lineage_depth=lineage_depth(session_id, parent_map),
                created_at=created_at,
                model_provider=str(first.get("model_provider") or ""),
                cli_version=str(first.get("cli_version") or ""),
                originator=str(first.get("originator") or ""),
                source=str(first.get("source") or ""),
                context_window=safe_int(first.get("context_window")),
                thread=thread_info.get(normalized_path(path), ThreadInfo()),
            )
        )

    return sorted(
        descriptors,
        key=lambda item: (
            item.root_id,
            item.lineage_depth,
            item.created_at,
            str(item.path),
        ),
    )


def raw_usage_tuple(value: dict[str, Any] | None) -> tuple[int, ...] | None:
    if not isinstance(value, dict):
        return None
    return tuple(int(value.get(field) or 0) for field in RAW_USAGE_FIELDS)


def usage_from_values(
    value: dict[str, Any],
    stats: SessionStats,
) -> Counter:
    input_tokens = int(value.get("input_tokens") or 0)
    cached_tokens = int(value.get("cached_input_tokens") or 0)
    cache_write_tokens = int(value.get("cache_write_input_tokens") or 0)
    output_tokens = int(value.get("output_tokens") or 0)
    reasoning_tokens = int(value.get("reasoning_output_tokens") or 0)
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
    collaboration = payload.get("collaboration_mode") or {}
    settings = collaboration.get("settings") or {}
    return clean_text(settings.get("model"))


def active_effort_from_context(payload: dict[str, Any]) -> str:
    direct = clean_text(payload.get("effort") or payload.get("reasoning_effort"))
    if direct:
        return direct
    collaboration = payload.get("collaboration_mode") or {}
    settings = collaboration.get("settings") or {}
    return clean_text(settings.get("reasoning_effort"))


def normalize_service_tier(value: Any) -> str:
    normalized = clean_text(str(value or "")).lower()
    if normalized in {"", "auto", "default", "standard"}:
        return DEFAULT_SERVICE_TIER
    if normalized in {"fast", "priority"}:
        return "priority"
    return normalized


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
    try:
        rate = float(value)
    except (TypeError, ValueError):
        return None
    return rate if rate >= 0 else None


def read_model_aliases(
    path: Path = MODEL_ALIASES_FILE,
) -> tuple[dict[str, str], list[str]]:
    if not path.exists():
        return {}, []
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return {}, [f"Cannot read {path.name}: {error}"]
    if not isinstance(value, dict):
        return {}, [f"{path.name} must contain a JSON object"]

    aliases: dict[str, str] = {}
    alias_values = value.get("aliases") or {}
    if not isinstance(alias_values, dict):
        alias_values = {}
    for key, target in alias_values.items():
        if isinstance(key, str) and isinstance(target, str) and target.strip():
            aliases[key.strip().lower()] = target.strip().lower()

    errors: list[str] = []
    if value.get("models"):
        errors.append(
            "Custom rates are ignored; aliases may only target built-in official models"
        )
    for alias, target in aliases.items():
        if target not in PRICING_USD_PER_MTOK:
            errors.append(f"Alias {alias!r} targets unknown official model {target!r}")
    aliases = {
        alias: target
        for alias, target in aliases.items()
        if target in PRICING_USD_PER_MTOK
    }
    return aliases, errors


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
    catalog = catalog or PRICING_USD_PER_MTOK
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
    standard_rates, long_context = standard_rates_for_usage(pricing, usage)
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

    input_rate = selected_rates.get("input")
    cache_savings = 0.0
    if input_rate is not None:
        for token_field, rate_field in (
            ("cached_input_tokens", "cached_input"),
            ("cache_write_input_tokens", "cache_write_input"),
        ):
            category_rate = selected_rates.get(rate_field)
            if category_rate is not None:
                cache_savings += (
                    usage[token_field]
                    / 1_000_000
                    * max(0.0, float(input_rate) - float(category_rate))
                )
    result["cache_savings_usd"] = cache_savings
    result["priced_calls"] = 1 if result["priced_tokens"] else 0
    result["unpriced_calls"] = 1 if result["unpriced_tokens"] and not result["priced_tokens"] else 0
    result["long_context_calls"] = 1 if long_context else 0
    result["default_tier_calls"] = 1 if service_tier == "default" else 0
    result["priority_tier_calls"] = 1 if service_tier == "priority" else 0
    result["other_tier_calls"] = 1 if service_tier not in {"default", "priority"} else 0
    result["tier_rate_fallback_calls"] = 1 if tier_fallback else 0
    return result


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
) -> None:
    day = timestamp.date()
    hour = timestamp.replace(minute=0, second=0, microsecond=0)
    weekday_hour = (timestamp.weekday(), timestamp.hour)

    stats.total.update(usage)
    stats.by_model[model].update(usage)
    stats.by_provider[route_provider].update(usage)
    stats.by_service_tier[service_tier].update(usage)
    stats.by_reasoning_effort[reasoning_effort or "(unknown)"].update(usage)
    route = (route_provider, model, service_tier)
    stats.by_route[route].update(usage)
    report.totals.update(usage)
    report.totals_by_model[model].update(usage)
    report.totals_by_provider[route_provider].update(usage)
    report.totals_by_service_tier[service_tier].update(usage)
    report.totals_by_reasoning_effort[reasoning_effort or "(unknown)"].update(usage)
    report.usage_by_route[route].update(usage)
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
    )
    report.costs_by_model[model].update(cost)
    report.costs_by_route[route].update(cost)
    report.costs_by_day[day].update(cost)
    report.costs_by_day_model[day][model].update(cost)
    report.costs_weekday_hour[weekday_hour].update(cost)
    report.costs_weekday_hour_model[weekday_hour][model].update(cost)


def collect_usage(
    sessions_root: Path = SESSIONS_ROOT,
    thread_info: dict[str, ThreadInfo] | None = None,
) -> UsageReport:
    if thread_info is None:
        thread_info = read_thread_info()
    descriptors = discover_sessions(sessions_root, thread_info)
    model_aliases, pricing_errors = read_model_aliases()
    report = UsageReport(
        sessions=[],
        pricing_catalog=dict(PRICING_USD_PER_MTOK),
        pricing_aliases=model_aliases,
        pricing_config_errors=pricing_errors,
    )
    report.fork_sessions = sum(bool(item.parent_id) for item in descriptors)
    report.sqlite_threads_total_tokens = sum(
        item.thread.tokens_used or 0 for item in descriptors
    )

    seen: dict[tuple[Any, ...], str] = {}
    for descriptor in descriptors:
        stats = SessionStats(descriptor=descriptor)
        active_turn = ""
        active_model = ""
        active_provider = normalize_provider(descriptor.model_provider)
        active_service_tier = DEFAULT_SERVICE_TIER
        active_reasoning_effort = ""
        provider_from_event = bool(descriptor.model_provider)
        service_tier_from_event = False
        previous_cumulative = Counter()
        fallback_timestamp = parse_timestamp(
            descriptor.created_at,
            datetime.fromtimestamp(descriptor.path.stat().st_mtime, tz=LOCAL_TZ),
        )

        with descriptor.path.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue

                payload = obj.get("payload") or {}
                obj_type = obj.get("type")
                if obj_type == "event_msg" and payload.get("type") == "thread_settings_applied":
                    settings = payload.get("thread_settings") or {}
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

                stats.raw_events += 1
                report.raw_events += 1
                info = payload.get("info")
                if not isinstance(info, dict):
                    stats.null_usage_events += 1
                    report.null_usage_events += 1
                    continue
                current_usage = info.get("total_token_usage")
                if not isinstance(current_usage, dict):
                    stats.null_usage_events += 1
                    report.null_usage_events += 1
                    continue

                last_usage = info.get("last_token_usage")
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
                fingerprint = event_fingerprint(
                    descriptor.root_id,
                    active_turn,
                    route_provider,
                    model,
                    service_tier,
                    active_reasoning_effort,
                    current_usage,
                    last_usage if isinstance(last_usage, dict) else None,
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
                if provider_fallback:
                    stats.fallback_provider_events += 1
                if service_tier_fallback:
                    stats.fallback_service_tier_events += 1

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
                )

        report.fallback_delta_events += stats.fallback_delta_events
        report.fallback_model_events += stats.fallback_model_events
        report.repaired_total_events += stats.repaired_total_events
        report.cached_over_input_events += stats.cached_over_input_events
        report.cache_write_over_input_events += stats.cache_write_over_input_events
        report.reasoning_over_output_events += stats.reasoning_over_output_events
        report.missing_timestamp_events += stats.missing_timestamp_events
        report.fallback_provider_events += stats.fallback_provider_events
        report.fallback_service_tier_events += stats.fallback_service_tier_events
        report.sessions.append(stats)

    return report


def counter_dict(value: Counter | dict[str, int] | None = None) -> dict[str, int]:
    value = value or {}
    return {field: int(value.get(field, 0)) for field in USAGE_FIELDS}


def cost_dict(value: Counter | dict[str, float] | None = None) -> dict[str, float | int]:
    value = value or {}
    result: dict[str, float | int] = {}
    for field in COST_FIELDS:
        raw = value.get(field, 0)
        result[field] = round(float(raw), 6) if field.endswith("_usd") else int(raw)
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
            "long_context": bool(pricing.get("long_context")),
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
            "rates": None,
            "source": None,
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
                    "rates": selected_rates,
                    "source": source,
                    "tier_rate_fallback": tier_fallback,
                }
            )
        route_details.append(detail)

    scopes[ALL_MODELS_KEY] = cost_dict(aggregate)
    return {
        "currency": "USD",
        "as_of": PRICING_AS_OF,
        "long_context_threshold": LONG_CONTEXT_THRESHOLD,
        "scopes": scopes,
        "models": model_details,
        "routes": route_details,
        "billing_context": read_billing_context(),
        "model_aliases": {
            "path": str(MODEL_ALIASES_FILE),
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


def build_dashboard_data(report: UsageReport) -> dict[str, Any]:
    models = sorted(
        report.totals_by_model,
        key=lambda model: report.totals_by_model[model]["total_tokens"],
        reverse=True,
    )
    active_days = sorted(report.by_day)
    if not active_days:
        raise SystemExit("No token usage found.")

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
                "unique_events": stats.unique_events,
                "inherited_events": stats.inherited_events,
                "local_duplicate_events": stats.local_duplicate_events,
            }
        )

    generated_at = datetime.now(LOCAL_TZ)
    return {
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
        "daily": daily,
        "sessions": sessions,
        "audit": {
            "session_files": len(report.sessions),
            "sessions_with_usage": sum(
                stats.total["total_tokens"] > 0 for stats in report.sessions
            ),
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
            "missing_timestamp_events": report.missing_timestamp_events,
            "fallback_provider_events": report.fallback_provider_events,
            "fallback_service_tier_events": report.fallback_service_tier_events,
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
    <div class="eyebrow">Local Codex Telemetry / Asia Shanghai</div>
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
      <div class="panel-head"><div><h2>会话用量</h2><p class="panel-kicker">fork 会话仅显示分叉后新增的独占用量；继承历史不会再次计入。</p></div><div class="scale-note">TOP 30 / CURRENT FILTER</div></div>
      <div class="table-wrap"><table><thead><tr><th>Session</th><th>Models</th><th>Routing</th><th id="sessionMetric">Metric</th><th>Calls</th><th>Branch</th></tr></thead><tbody id="sessionRows"></tbody></table></div>
    </div>
  </section>

  <section class="panel">
    <div class="panel-inner">
      <div class="panel-head">
        <div><h2>官方 API 等价价值</h2><p class="panel-kicker" id="costCaption"></p></div>
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
      <p class="method">口径：每个有效 token_count 读取单次增量 last_token_usage，并关联当时最近的 provider、model、service tier 与 reasoning effort。父会话与 fork 文件中重复出现的历史事件只计第一次。total 大于 input + output 的差额保留为 Unclassified；reasoning 是 output 的子集，不重复加入 total。</p>
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
    return `${title}<br>${selected}<br>Total: ${fmt(usage.total_tokens)} · Calls: ${fmt(usage.calls)}<br>Official API value: ${usd(cost.estimated_cost_usd)}${unpriced}`;
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
        cells.push(heatButton("hourly-cell", metricValue(usage), cap, tooltipText(title, usage, costMatrix[weekday][hour]), `${title}, ${metrics[state.metric].label} ${fmt(metricValue(usage))}, official API value ${usd(costMatrix[weekday][hour].estimated_cost_usd)}`));
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
      cells.push(heatButton(`calendar-cell${outside ? " outside" : ""}`, outside ? 0 : metricValue(usage), cap, tooltipText(title, usage, cost), `${title}, ${metrics[state.metric].label} ${fmt(metricValue(usage))}, official API value ${usd(cost.estimated_cost_usd)}`));
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
      const branch = session.parent_id ? `<span class="badge fork-badge">fork +${session.lineage_depth}</span>` : `<span class="badge">root</span>`;
      const inherited = session.inherited_events ? `<span class="session-id">${fmt(session.inherited_events)} inherited skipped</span>` : "";
      return `<tr><td><span class="session-title" data-tooltip="${escapeHtml(session.path)}">${escapeHtml(session.title)}</span><span class="session-id">${escapeHtml(session.id)}</span></td><td>${models}</td><td>${providers}${tiers}</td><td>${fmt(metricValue(usage))}</td><td>${fmt(usage.calls)}</td><td>${branch}${inherited}</td></tr>`;
    }).join("") || `<tr><td colspan="6">No usage for this filter</td></tr>`;
  }

  function renderCosts() {
    const pricing = data.pricing;
    const cost = pricing.scopes[state.model] || zeroCost;
    const coverageBase = Number(cost.priced_tokens || 0) + Number(cost.unpriced_tokens || 0);
    const coverage = coverageBase ? Number(cost.priced_tokens || 0) / coverageBase : 0;
    document.getElementById("estimatedCost").textContent = usd(cost.estimated_cost_usd);
    document.getElementById("estimatedCostDetail").textContent = `${(coverage * 100).toFixed(1)}% categorized tokens priced`;
    document.getElementById("standardCost").textContent = usd(cost.standard_equivalent_cost_usd);
    document.getElementById("standardCostDetail").textContent = `${fmt(cost.default_tier_calls)} default · ${fmt(cost.long_context_calls)} long context`;
    document.getElementById("tierPremium").textContent = usd(cost.service_tier_premium_usd);
    document.getElementById("tierPremiumDetail").textContent = `${fmt(cost.priority_tier_calls)} priority / fast calls · ${fmt(cost.tier_rate_fallback_calls)} fallback`;
    document.getElementById("cacheSavings").textContent = usd(cost.cache_savings_usd);
    document.getElementById("cacheSavingsDetail").textContent = `${usd(cost.cached_input_cost_usd)} read · ${usd(cost.cache_write_input_cost_usd)} write`;
    document.getElementById("costCaption").textContent = `${modelLabel(state.model)} · 按日志路由计算官方直连文本 token 等价价值；不是中转站或订阅实际账单。`;
    document.getElementById("pricingAsOf").textContent = `OFFICIAL DIRECT RATES · ${pricing.as_of}`;

    const visibleRoutes = pricing.routes.filter(route => state.model === "all" || route.model === state.model);
    const rateCell = value => value == null ? "—" : usd(value);
    document.getElementById("costRows").innerHTML = visibleRoutes.map(detail => {
      const rates = detail.rates;
      const routeCost = detail.costs || zeroCost;
      const pricedAs = detail.pricing_model
        ? `${escapeHtml(detail.pricing_provider || "")}${detail.pricing_provider ? " / " : ""}${escapeHtml(detail.pricing_model)}`
        : `<span class="cost-warning">Not priced</span>`;
      const valueTooltip = `Input: ${usd(routeCost.uncached_input_cost_usd)} · Cache read: ${usd(routeCost.cached_input_cost_usd)} · Cache write: ${usd(routeCost.cache_write_input_cost_usd)} · Output: ${usd(routeCost.output_cost_usd)}`;
      return `<tr><td><span class="badge provider-badge">${escapeHtml(detail.route_provider)}</span></td><td>${escapeHtml(detail.model)}</td><td><span class="badge tier-badge">${escapeHtml(tierLabel(detail.service_tier))}</span></td><td>${pricedAs}</td><td data-tooltip="${escapeHtml(valueTooltip)}">${usd(routeCost.estimated_cost_usd)}</td><td>${rateCell(rates?.input)}</td><td>${rateCell(rates?.cached_input)}</td><td>${rateCell(rates?.cache_write_input)}</td><td>${rateCell(rates?.output)}</td><td>${fmt(detail.usage.calls)}</td><td>${short(routeCost.unpriced_tokens)}</td></tr>`;
    }).join("") || `<tr><td colspan="11">No usage for this filter</td></tr>`;

    const unpricedNote = cost.unpriced_tokens ? ` ${fmt(cost.unpriced_tokens)} 个无法分类或暂无官方价格的 token 未计价。` : "";
    const authMode = String(pricing.billing_context?.current_auth_mode || "unknown").toLowerCase();
    const authNote = authMode.includes("api")
      ? "当前认证为 API key；Priority/Fast 路由按官方 API Priority 价估算。"
      : authMode.includes("chatgpt")
        ? "当前认证为 ChatGPT；这里仍只显示 API 等价价值，无法从 token 日志还原订阅账单或 credits。"
        : "日志不保存可验证的历史认证方式，因此不能判定每次调用属于订阅还是 API 账单。";
    const configNote = pricing.model_aliases.aliases
      ? ` 已加载 ${pricing.model_aliases.aliases} 个官方模型别名映射。`
      : " 可用 ~/.codex/token_atlas_pricing.json 将内部模型名映射到内置官方型号；不接受中转站自定义单价。";
    const configErrorNote = pricing.model_aliases.errors.length ? ` 模型映射配置有 ${pricing.model_aliases.errors.length} 个错误。` : "";
    document.getElementById("costMethod").textContent = `${authNote} Default 使用 Standard 价；Priority/Fast 使用可用的 Priority 价，无对应价时回退 Standard 并计入审计。ChatGPT Plan Fast 对 GPT-5.6/5.5 使用 2.5x credits、GPT-5.4 使用 2x credits，但这不是 token 美元单价，日志不足以重建订阅账单。缓存读、缓存写、未缓存输入和输出分别计价；未提供独立写入价时按输入价。工具调用、缓存存储和非文本模态费用不在 Codex token 日志中，不计入。${configNote}${configErrorNote}${unpricedNote}`;
    const sourceMap = new Map();
    pricing.sources.forEach(item => {
      if (!sourceMap.has(item.url)) sourceMap.set(item.url, []);
      sourceMap.get(item.url).push(item.model);
    });
    document.getElementById("pricingSources").innerHTML = [...sourceMap].map(([url, labels]) => {
      const label = `${labels.join(" · ")} 官方价目表`;
      return /^https?:\/\//i.test(url)
        ? `<a href="${escapeHtml(url)}" target="_blank" rel="noreferrer">${escapeHtml(label)}</a>`
        : `<span>${escapeHtml(label)} · local config</span>`;
    }).join("");
  }

  function renderAudit() {
    const a = data.audit;
    const entries = [
      ["Session files", a.session_files], ["Fork sessions", a.fork_sessions], ["Raw events", a.raw_token_events],
      ["Unique calls", a.unique_model_calls], ["Fork history skipped", a.inherited_events], ["Local duplicates", a.local_duplicate_events],
      ["Null usage", a.null_usage_events], ["Delta fallbacks", a.fallback_delta_events], ["Model fallbacks", a.fallback_model_events],
      ["Provider fallbacks", a.fallback_provider_events], ["Tier fallbacks", a.fallback_service_tier_events], ["Priority calls", data.pricing.scopes.all.priority_tier_calls],
      ["Tier price fallbacks", data.pricing.scopes.all.tier_rate_fallback_calls], ["Cache writes", data.totals.all.cache_write_input_tokens], ["Pricing config errors", a.pricing_config_errors],
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
    tooltip.innerHTML = content;
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


def render_html(report: UsageReport) -> str:
    dashboard_data = build_dashboard_data(report)
    encoded = json.dumps(dashboard_data, ensure_ascii=False, separators=(",", ":"))
    encoded = encoded.replace("<", "\\u003c").replace("&", "\\u0026")
    return HTML_TEMPLATE.replace("__DATA_JSON__", encoded)


def write_daily_csv(report: UsageReport) -> None:
    with OUTPUT_DAILY_CSV.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["date", *USAGE_FIELDS])
        for day in sorted(report.by_day):
            usage = report.by_day[day]
            writer.writerow([day.isoformat(), *(usage[field] for field in USAGE_FIELDS)])


def write_hourly_csv(report: UsageReport) -> None:
    with OUTPUT_HOURLY_CSV.open("w", newline="", encoding="utf-8") as fh:
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


def write_model_csv(report: UsageReport) -> None:
    with OUTPUT_MODEL_CSV.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["model", *USAGE_FIELDS])
        for model, usage in sorted(
            report.totals_by_model.items(),
            key=lambda item: item[1]["total_tokens"],
            reverse=True,
        ):
            writer.writerow([model, *(usage[field] for field in USAGE_FIELDS)])


def write_route_csv(report: UsageReport) -> None:
    with OUTPUT_ROUTE_CSV.open("w", newline="", encoding="utf-8") as fh:
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


def write_session_csv(report: UsageReport) -> None:
    sessions = sorted(
        report.sessions,
        key=lambda item: item.total["total_tokens"],
        reverse=True,
    )
    with OUTPUT_SESSION_CSV.open("w", newline="", encoding="utf-8") as fh:
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


def summary_payload(report: UsageReport) -> dict[str, Any]:
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
        "generated_at": datetime.now(LOCAL_TZ).isoformat(),
        "timezone": LOCAL_TZ.key,
        "accounting_method": "sum unique last_token_usage events",
        "deduplication_key": "lineage_root + turn_id + cumulative_usage + last_usage + context_window",
        "sessions_root": str(SESSIONS_ROOT),
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
        "pricing": build_pricing_data(report, list(models)),
        "date_range": {
            "first": active_days[0].isoformat() if active_days else None,
            "last": active_days[-1].isoformat() if active_days else None,
            "active_days": len(active_days),
        },
        "audit": {
            "session_files": len(report.sessions),
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
            "missing_timestamp_events": report.missing_timestamp_events,
            "fallback_provider_events": report.fallback_provider_events,
            "fallback_service_tier_events": report.fallback_service_tier_events,
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


def write_outputs(report: UsageReport) -> dict[str, Any]:
    OUTPUT_HTML.write_text(render_html(report), encoding="utf-8")
    write_daily_csv(report)
    write_hourly_csv(report)
    write_model_csv(report)
    write_route_csv(report)
    write_session_csv(report)
    summary = summary_payload(report)
    OUTPUT_JSON.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return summary


def synthetic_event(
    timestamp: str,
    obj_type: str,
    payload: dict[str, Any],
) -> str:
    return json.dumps(
        {"timestamp": timestamp, "type": obj_type, "payload": payload},
        separators=(",", ":"),
    )


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir) / "sessions"
        parent_dir = root / "2026" / "01" / "01"
        child_dir = root / "2026" / "01" / "02"
        parent_dir.mkdir(parents=True)
        child_dir.mkdir(parents=True)
        parent_id = "00000000-0000-4000-8000-000000000001"
        child_id = "00000000-0000-4000-8000-000000000002"

        def meta(session_id: str, parent: str = "") -> str:
            return synthetic_event(
                "2026-01-01T00:00:00Z",
                "session_meta",
                {
                    "id": session_id,
                    "forked_from_id": parent or None,
                    "timestamp": "2026-01-01T00:00:00Z",
                    "model_provider": "OpenAI",
                    "cli_version": "0.test",
                    "originator": "codex_cli_rs",
                    "source": "cli",
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
            meta(child_id, parent_id),
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

        report = collect_usage(root, thread_info={})
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
        assert pricing_for_model("gpt-5.6-luna-2026-07-01")[0] == "gpt-5.6-luna"
        assert pricing_for_model("gpt-4o-mini-2024-07-18")[0] == "gpt-4o-mini"
        assert pricing_for_model("gpt-4o-2024-05-13")[0] == "gpt-4o-2024-05-13"
        assert pricing_for_model("gpt-3.5-turbo-0125")[0] == "gpt-3.5-turbo-0125"
        assert pricing_for_model("gpt-future") is None

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
        assert abs(priority_cost["estimated_cost_usd"] - 0.0124) < 1e-12
        assert abs(priority_cost["standard_equivalent_cost_usd"] - 0.0062) < 1e-12
        assert abs(priority_cost["cache_write_input_cost_usd"] - 0.001) < 1e-12
        assert priority_cost["priority_tier_calls"] == 1
        assert normalize_service_tier("fast") == "priority"
        assert normalize_provider("openai") == "OpenAI"

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
        gpt55_standard, _ = standard_rates_for_usage(
            pricing_for_model("gpt-5.5")[1], Counter()
        )
        gpt55_priority, _ = rates_for_service_tier(
            pricing_for_model("gpt-5.5")[1], gpt55_standard, "priority"
        )
        assert gpt55_priority["cache_write_input"] == 12.5

        deepseek_cost = estimate_usage_cost(
            "Relay", "deepseek-v4-pro", "default", priced_usage
        )
        assert abs(deepseek_cost["cache_write_input_cost_usd"] - 0.0000435) < 1e-12
        alias_file = Path(temp_dir) / "token_atlas_pricing.json"
        alias_file.write_text(
            json.dumps(
                {
                    "aliases": {
                        "Relay/internal-sol": "gpt-5.6-sol",
                        "bad": "not-an-official-model",
                    }
                }
            ),
            encoding="utf-8",
        )
        aliases, alias_errors = read_model_aliases(alias_file)
        assert aliases["relay/internal-sol"] == "gpt-5.6-sol"
        assert "bad" not in aliases
        assert len(alias_errors) == 1
        assert pricing_for_model(
            "internal-sol", "Relay", PRICING_USD_PER_MTOK, aliases
        )[0] == "gpt-5.6-sol"

        dashboard = build_dashboard_data(report)
        assert dashboard["pricing"]["hourly"]["all"][4][11]["priority_tier_calls"] == 1
        assert dashboard["pricing"]["daily"]["all"]["2026-01-02"]["unpriced_tokens"] == 30
        assert "一周 × 24 小时" in render_html(report)
        assert "官方 API 等价价值" in render_html(report)
    print("Self-test passed: fork deduplication, route attribution, cache writes, official pricing, aliases, and total-only usage.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run synthetic regression tests without reading local Codex sessions",
    )
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        return
    if not SESSIONS_ROOT.exists():
        raise SystemExit(f"Codex sessions directory not found: {SESSIONS_ROOT}")

    report = collect_usage()
    summary = write_outputs(report)
    totals = summary["totals"]

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
    print(
        "Fork/replay events skipped: "
        f"{fmt_int(report.duplicate_events)} "
        f"({fmt_int(report.inherited_events)} inherited, "
        f"{fmt_int(report.local_duplicate_events)} local duplicates)"
    )
    print(f"Models: {', '.join(summary['usage_by_model'])}")


if __name__ == "__main__":
    main()
