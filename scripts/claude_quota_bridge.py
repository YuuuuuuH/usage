#!/usr/bin/env python3
"""Forward Claude's status line and cache its official quota counters locally."""
import argparse
import json
import math
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

CACHE_ROOT = Path.home() / "Library/Caches/CodexTokenAtlas"


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=path.name + "-", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False)
            handle.write("\n")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def quota_record(payload, now=None):
    limits = payload.get("rate_limits") if isinstance(payload, dict) else None
    clean = {}
    if isinstance(limits, dict):
        for name in ("five_hour", "seven_day"):
            row = limits.get(name)
            if not isinstance(row, dict):
                continue
            percent, reset = row.get("used_percentage"), row.get("resets_at")
            if any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value)
                   for value in (percent, reset)):
                continue
            if percent < 0 or not 0 < reset < 253402300799:
                continue
            clean[name] = {"used_percentage": min(100, percent), "resets_at": reset}
    return {"observed_at": time.time() if now is None else now, "rate_limits": clean}


def configure(config_dir, disconnect=False):
    config_dir = config_dir.expanduser().resolve()
    settings_path = (config_dir / "settings.json").resolve()
    settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
    if not isinstance(settings, dict):
        raise ValueError("Claude 设置需要使用 JSON 对象格式。")
    backup_path = CACHE_ROOT / "claude-statusline-connection.json"
    previous = settings.get("statusLine")
    if disconnect:
        saved = json.loads(backup_path.read_text())
        if not isinstance(previous, dict) or previous.get("command") != saved["installed_command"]:
            raise ValueError("Claude 状态栏已经变更，请在 Claude 设置中调整。")
        if saved["original_present"]:
            settings["statusLine"] = saved["original"]
        else:
            settings.pop("statusLine", None)
        atomic_json(settings_path, settings)
        return
    if previous is not None and (not isinstance(previous, dict) or previous.get("type") != "command" or not isinstance(previous.get("command"), str)):
        raise ValueError("当前 Claude 状态栏格式无法自动连接。")
    script = str(Path(__file__).resolve())
    if isinstance(previous, dict) and script in previous.get("command", ""):
        return
    command = [sys.executable, script, "--config-dir", str(config_dir)]
    if isinstance(previous, dict):
        command.extend(["--forward", previous["command"]])
    installed = " ".join(shlex.quote(value) for value in command)
    atomic_json(backup_path, {"original_present": "statusLine" in settings, "original": previous, "installed_command": installed})
    settings["statusLine"] = dict(previous or {}, type="command", command=installed)
    atomic_json(settings_path, settings)


def receive(raw, forward=None):
    record = None
    try:
        payload = json.loads(raw)
        if isinstance(payload, dict) and isinstance(payload.get("rate_limits"), dict):
            record = quota_record(payload)
            atomic_json(CACHE_ROOT / "claude-quota.json", record)
    except (OSError, ValueError, TypeError):
        pass
    if forward:
        try:
            result = subprocess.run(forward, shell=True, input=raw, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, timeout=5)
            sys.stdout.buffer.write(result.stdout)
        except (OSError, subprocess.TimeoutExpired):
            pass
    else:
        parts = []
        for key, label in (("five_hour", "5h"), ("seven_day", "本周")):
            row = (record or {}).get("rate_limits", {}).get(key)
            if row:
                parts.append(f"{label} 余 {max(0, 100 - row['used_percentage']):.0f}%")
        print("Claude" + (" · " + " · ".join(parts) if parts else ""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connect", action="store_true")
    parser.add_argument("--disconnect", action="store_true")
    parser.add_argument("--config-dir", type=Path, default=Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))))
    parser.add_argument("--forward")
    args = parser.parse_args()
    if args.connect or args.disconnect:
        try:
            configure(args.config_dir, disconnect=args.disconnect)
        except (OSError, ValueError, KeyError):
            raise SystemExit("Claude 状态栏连接失败，请检查 settings.json；现有设置已保留。")
        print("Claude 额度已连接，下次模型响应后会更新。" if args.connect else "Claude 原有状态栏已恢复。")
    else:
        receive(sys.stdin.buffer.read(1024 * 1024), forward=args.forward)


if __name__ == "__main__":
    main()
