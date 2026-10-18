#!/usr/bin/env python3
"""Read quota counters from the running Antigravity app's loopback service."""
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time
from datetime import datetime

APP = Path("/Applications/Antigravity.app")
EXECUTABLE = str(APP / "Contents/Resources/bin/language_server")


class QuotaUnavailable(Exception):
    pass


def discover_process(output, uid):
    for line in output.splitlines():
        pieces = line.strip().split(None, 2)
        if len(pieces) != 3 or pieces[0] != str(uid):
            continue
        command = pieces[2]
        if not command.startswith(EXECUTABLE + " "):
            continue
        token = re.search(r"(?:^|\s)--csrf_token(?:=|\s+)([^\s]+)", command)
        if token and pieces[1].isdigit():
            return int(pieces[1]), token.group(1)
    raise QuotaUnavailable("打开 Antigravity 后自动读取")


def http_port(log, listeners):
    ports = re.findall(r"listening on \w+ port at (\d+) for HTTP(?!S)", log)
    owned = set(re.findall(r"^n127\.0\.0\.1:(\d+)$", listeners, re.MULTILINE))
    for value in reversed(ports):
        if value in owned and 0 < int(value) < 65536:
            return int(value)
    raise QuotaUnavailable("Antigravity 本地服务尚未就绪")


def quota_record(payload, now=None):
    status = payload.get("userStatus") if isinstance(payload, dict) else None
    if not isinstance(status, dict):
        raise QuotaUnavailable("请先在 Antigravity 中登录")
    data = status.get("cascadeModelConfigData")
    configs = data.get("clientModelConfigs", []) if isinstance(data, dict) else []
    windows, seen = [], set()
    for model in configs if isinstance(configs, list) else []:
        if not isinstance(model, dict):
            continue
        quota = model.get("quotaInfo")
        if not isinstance(quota, dict):
            continue
        fraction, reset = quota.get("remainingFraction"), quota.get("resetTime")
        if isinstance(fraction, bool) or not isinstance(fraction, (int, float)) or not math.isfinite(fraction) or not 0 <= fraction <= 1:
            continue
        try:
            date = datetime.fromisoformat(reset.replace("Z", "+00:00"))
            if date.tzinfo is None:
                continue
            timestamp = date.timestamp()
            if not 0 < timestamp < 253402300799:
                continue
        except (ValueError, TypeError, AttributeError, OverflowError):
            continue
        label = model.get("label")
        alias = model.get("modelOrAlias")
        identifier = model.get("modelId") or (alias.get("model") if isinstance(alias, dict) else None) or label
        if not isinstance(label, str) or not isinstance(identifier, str) or not label or not identifier or len(identifier) > 160 or identifier in seen:
            continue
        seen.add(identifier)
        windows.append({"id": identifier[:160], "label": label[:120], "used_percent": (1 - fraction) * 100, "resets_at": timestamp})
        if len(windows) >= 100:
            break
    account = status.get("email")
    return {"observed_at": time.time() if now is None else now,
            "account_key": hashlib.sha256(account.encode()).hexdigest() if isinstance(account, str) and account else None,
            "windows": windows}


def read_quota():
    rows = subprocess.run(["/bin/ps", "-U", str(os.getuid()), "-o", "uid=,pid=,command="], capture_output=True, text=True, timeout=3, check=True).stdout
    pid, token = discover_process(rows, os.getuid())
    listeners = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"], capture_output=True, text=True, timeout=3, check=True).stdout
    log_path = Path.home() / "Library/Logs/Antigravity/language_server.log"
    with log_path.open("rb") as handle:
        handle.seek(max(0, log_path.stat().st_size - 262144))
        log = handle.read(262144).decode("utf-8", errors="replace")
    port = http_port(log, listeners)
    with (APP / "Contents/Info.plist").open("rb") as handle:
        version = plistlib.load(handle).get("CFBundleShortVersionString", "unknown")
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=8)
    try:
        body = json.dumps({"metadata": {"ideName": "antigravity", "extensionName": "antigravity", "extensionVersion": version}})
        connection.request("POST", "/exa.language_server_pb.LanguageServerService/GetUserStatus", body=body,
                           headers={"Content-Type": "application/json", "Connect-Protocol-Version": "1", "X-Codeium-Csrf-Token": token})
        response = connection.getresponse()
        if response.status != 200:
            raise QuotaUnavailable("Antigravity 额度暂不可用")
        raw = response.read(2097153)
        if len(raw) > 2097152:
            raise QuotaUnavailable("Antigravity 额度响应过大")
        return quota_record(json.loads(raw))
    finally:
        connection.close()


if __name__ == "__main__":
    try:
        result = read_quota()
    except QuotaUnavailable as error:
        result = {"error": str(error)}
    except Exception:
        result = {"error": "Antigravity 额度暂不可用"}
    json.dump(result, sys.stdout, ensure_ascii=False)
    print()
