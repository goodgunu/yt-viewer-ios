#!/usr/bin/env python3
"""EasyList 形式のテキストを WebKit Content Blocker JSON に変換する。

対応するのはよく使う記法に限る。コメント、要素非表示、
``||domain^`` のネットワーク規則、``@@`` 例外、``$script`` などの
リソース種別、``third-party``、``domain=``。
``$csp`` や手続き的な化粧フィルタは捨て、件数を標準エラーに出す。

WebKit はリストのどこか 1 件でも不正だとコンパイル全体を失敗させる。
変換後は ``--check`` で形を確認してからアプリへ入れる。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


RESOURCE_TYPES = {
    "script": "script",
    "image": "image",
    "stylesheet": "style-sheet",
    "css": "style-sheet",
    "xmlhttprequest": "raw",
    "xhr": "raw",
    "media": "media",
    "font": "font",
    "ping": "ping",
    "websocket": "raw",
    "other": "raw",
    "object": "raw",
    "subdocument": "document",
    "document": "document",
    "popup": "popup",
}

KNOWN_OPTIONS = {
    "third-party",
    "3p",
    "~third-party",
    "1p",
    "match-case",
    "important",
    "all",
    "first-party",
}

COSMETIC_SEPARATORS = ("#@#", "#?#", "#$#", "##")

UNSAFE_SELECTOR_MARKERS = (
    ":-abp",
    ":has-text",
    ":has(",
    ":xpath",
    ":matches-css",
    ":matches-attr",
    ":matches-path",
    ":style(",
    ":remove(",
    ":upward(",
    ":min-text-length",
    ":watch-attr",
    ":others(",
    ":is(",
    ":where(",
)

BROAD_BLOCK_FILTERS = {".*", ".+", "^.*", "^https?://.*", "https?://.*"}
TOO_BROAD_SELECTORS = {"*", "body", "html", "body, html"}


class Stats:
    def __init__(self) -> None:
        self.read = 0
        self.comments = 0
        self.unsupported = 0
        self.cosmetic_exceptions = 0
        self.blocks = 0
        self.exceptions = 0

    def summary(self) -> str:
        emitted = self.blocks + self.exceptions
        skipped = self.comments + self.unsupported + self.cosmetic_exceptions
        return (
            f"読み込み: {self.read}\n"
            f"出力: {emitted}（ブロック {self.blocks} / 例外 {self.exceptions}）\n"
            f"スキップ: {skipped}\n"
            f"  コメント: {self.comments}\n"
            f"  未対応: {self.unsupported}\n"
            f"  装飾の例外: {self.cosmetic_exceptions}"
        )


def translate_body(pattern: str) -> str | None:
    parts: list[str] = []
    literal: list[str] = []

    def flush() -> None:
        if literal:
            parts.append(re.escape("".join(literal)))
            literal.clear()

    index = 0
    while index < len(pattern):
        char = pattern[index]
        if char == "\\" and index + 1 < len(pattern):
            literal.append(pattern[index + 1])
            index += 2
            continue
        if char == "*":
            flush()
            parts.append(".*")
        elif char == "^":
            flush()
            parts.append(r"(?:[^\w.%_-]|$)")
        else:
            literal.append(char)
        index += 1
    flush()
    return "".join(parts)


def pattern_to_regex(pattern: str, *, raw: bool = False) -> str | None:
    if not pattern or len(pattern) > 1024:
        return None
    if raw:
        if "(?" in pattern:
            return None
        regex = pattern
    else:
        domain_anchor = False
        start_anchor = False
        end_anchor = False
        if pattern.startswith("||"):
            domain_anchor = True
            pattern = pattern[2:]
        elif pattern.startswith("|"):
            start_anchor = True
            pattern = pattern[1:]
        if pattern.endswith("|"):
            end_anchor = True
            pattern = pattern[:-1]
        if not pattern:
            return None
        body = translate_body(pattern)
        if not body:
            return None
        if domain_anchor:
            regex = r"^https?://([^/]*\.)?" + body
        elif start_anchor:
            regex = "^" + body
        else:
            regex = body
        if end_anchor:
            regex += "$"
    if not regex or len(regex) > 2048 or regex in BROAD_BLOCK_FILTERS:
        return None
    try:
        re.compile(regex)
    except re.error:
        return None
    return regex


def split_cosmetic(line: str) -> tuple[str, str, str] | None:
    index = 0
    while index < len(line):
        if line[index] == "\\" and index + 1 < len(line):
            index += 2
            continue
        for separator in COSMETIC_SEPARATORS:
            if line.startswith(separator, index):
                return line[:index], separator, line[index + len(separator) :]
        index += 1
    return None


def split_network_options(line: str) -> tuple[str, str]:
    """`$` 以降がオプションならそこで分ける。URL 中の裸の `$` はそのまま残す。"""
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char != "$":
            continue
        options = line[index + 1 :]
        if options == "" or options[0].isalpha() or options[0] == "~":
            return line[:index], options
    return line, ""


def parse_domain_tokens(text: str) -> tuple[list[str], list[str]] | None:
    include: list[str] = []
    exclude: list[str] = []
    if not text:
        return include, exclude
    for raw in text.split("|"):
        token = raw.strip().lower()
        if not token:
            continue
        negated = token.startswith("~")
        if negated:
            token = token[1:]
        if not token or not re.fullmatch(r"\*?[a-z0-9.-]+", token):
            return None
        if token.startswith("*") and not token.startswith("*."):
            # "*youtube.com" は WebKit のサブドメイン記法として残す。
            pass
        (exclude if negated else include).append(token)
    return include, exclude


def parse_cosmetic_domains(text: str) -> tuple[list[str], list[str]] | None:
    include: list[str] = []
    exclude: list[str] = []
    if not text:
        return include, exclude
    for raw in text.split(","):
        token = raw.strip().lower()
        if not token:
            continue
        negated = token.startswith("~")
        if negated:
            token = token[1:]
        if not re.fullmatch(r"\*?[a-z0-9.-]+", token):
            return None
        (exclude if negated else include).append(token)
    return include, exclude


def selector_is_safe(selector: str) -> bool:
    stripped = selector.strip()
    if not stripped or len(stripped) > 4000:
        return False
    if stripped in TOO_BROAD_SELECTORS:
        return False
    if any(marker in stripped for marker in UNSAFE_SELECTOR_MARKERS):
        return False
    if any(char in stripped for char in "{}\\"):
        return False
    if stripped.count("(") != stripped.count(")"):
        return False
    return True


def apply_domain_fields(trigger: dict, include: list[str], exclude: list[str]) -> None:
    if include:
        trigger["if-domain"] = include
    if exclude:
        trigger["unless-domain"] = exclude


def parse_options(options: str) -> dict | None:
    trigger: dict = {}
    resources: list[str] = []
    saw_third = False
    saw_first = False
    if not options:
        return trigger
    for raw in options.split(","):
        token = raw.strip()
        if not token:
            continue
        lower = token.lower()
        if lower in {"important", "all", "first-party"}:
            continue
        if lower in {"third-party", "3p"}:
            saw_third = True
            continue
        if lower in {"~third-party", "1p"}:
            saw_first = True
            continue
        if lower == "match-case":
            trigger["url-filter-is-case-sensitive"] = True
            continue
        if lower.startswith("domain="):
            parsed = parse_domain_tokens(token.split("=", 1)[1])
            if parsed is None:
                return None
            include, exclude = parsed
            apply_domain_fields(trigger, include, exclude)
            continue
        if lower in RESOURCE_TYPES:
            mapped = RESOURCE_TYPES[lower]
            if mapped not in resources:
                resources.append(mapped)
            continue
        if lower in KNOWN_OPTIONS:
            continue
        return None
    if saw_third and saw_first:
        return None
    if saw_third:
        trigger["load-type"] = ["third-party"]
    elif saw_first:
        trigger["load-type"] = ["first-party"]
    if resources:
        trigger["resource-type"] = resources
    return trigger


def is_raw_regex(pattern: str) -> bool:
    return len(pattern) >= 2 and pattern.startswith("/") and pattern.endswith("/") and pattern.rfind("/") > 0


def make_network_rule(pattern: str, options: str, exception: bool) -> dict | None:
    raw = False
    if is_raw_regex(pattern):
        raw = True
        pattern = pattern[1:-1]
    regex = pattern_to_regex(pattern, raw=raw)
    if regex is None:
        return None
    if not exception and regex in BROAD_BLOCK_FILTERS:
        return None
    extra = parse_options(options)
    if extra is None:
        return None
    trigger = {"url-filter": regex}
    trigger.update(extra)
    action = {"type": "ignore-previous-rules" if exception else "block"}
    return {"trigger": trigger, "action": action}


def make_cosmetic_rule(domains: str, selector: str) -> dict | None:
    parsed = parse_cosmetic_domains(domains)
    if parsed is None:
        return None
    include, exclude = parsed
    cleaned = selector.replace(r"\#", "#").strip()
    if not selector_is_safe(cleaned):
        return None
    trigger: dict = {"url-filter": ".*"}
    apply_domain_fields(trigger, include, exclude)
    return {
        "trigger": trigger,
        "action": {"type": "css-display-none", "selector": cleaned},
    }


def parse_line(line: str, stats: Stats, allow_generic_cosmetic: bool) -> dict | None:
    stripped = line.strip()
    stats.read += 1
    if not stripped or stripped.startswith("!") or stripped.startswith("# ") or stripped.startswith("["):
        stats.comments += 1
        return None

    exception = False
    body = stripped
    if body.startswith("@@"):
        exception = True
        body = body[2:]

    cosmetic = split_cosmetic(body)
    if cosmetic is not None:
        domains, separator, selector = cosmetic
        if exception or separator != "##":
            stats.cosmetic_exceptions += 1
            return None
        rule = make_cosmetic_rule(domains, selector)
        if rule is None:
            stats.unsupported += 1
            return None
        include = rule["trigger"].get("if-domain") or []
        exclude = rule["trigger"].get("unless-domain") or []
        if not allow_generic_cosmetic and not include and not exclude:
            stats.unsupported += 1
            return None
        stats.blocks += 1
        return rule

    pattern, options = split_network_options(body)
    rule = make_network_rule(pattern, options, exception)
    if rule is None:
        stats.unsupported += 1
        return None
    if exception:
        stats.exceptions += 1
    else:
        stats.blocks += 1
    return rule


def dedupe(rules: list[dict]) -> list[dict]:
    seen: set[str] = set()
    unique: list[dict] = []
    for rule in rules:
        key = json.dumps(rule, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
        if key in seen:
            continue
        seen.add(key)
        unique.append(rule)
    return unique


def convert_lines(lines: list[str], *, allow_generic_cosmetic: bool, limit: int) -> tuple[list[dict], Stats]:
    stats = Stats()
    blocks: list[dict] = []
    exceptions: list[dict] = []
    for line in lines:
        before_blocks = stats.blocks
        before_exceptions = stats.exceptions
        rule = parse_line(line, stats, allow_generic_cosmetic)
        if rule is None:
            continue
        if stats.exceptions > before_exceptions:
            exceptions.append(rule)
        elif stats.blocks > before_blocks:
            blocks.append(rule)
    blocks = dedupe(blocks)
    exceptions = dedupe(exceptions)
    stats.blocks = len(blocks)
    stats.exceptions = len(exceptions)
    if len(exceptions) >= limit:
        return exceptions[:limit], stats
    room = max(limit - len(exceptions), 0)
    return blocks[:room] + exceptions, stats


def validate_rules(rules: object) -> None:
    if not isinstance(rules, list):
        raise ValueError("トップレベルは配列である必要があります")
    allowed_actions = {"block", "block-cookies", "css-display-none", "ignore-previous-rules", "make-https"}
    for index, rule in enumerate(rules):
        if not isinstance(rule, dict):
            raise ValueError(f"{index}: 規則がオブジェクトではありません")
        trigger = rule.get("trigger")
        action = rule.get("action")
        if not isinstance(trigger, dict) or not isinstance(action, dict):
            raise ValueError(f"{index}: trigger と action が必要です")
        url_filter = trigger.get("url-filter")
        if not isinstance(url_filter, str) or not url_filter:
            raise ValueError(f"{index}: url-filter がありません")
        try:
            re.compile(url_filter)
        except re.error as error:
            raise ValueError(f"{index}: url-filter をコンパイルできません: {error}") from error
        action_type = action.get("type")
        if action_type not in allowed_actions:
            raise ValueError(f"{index}: action.type が不正です")
        if action_type == "css-display-none":
            selector = action.get("selector")
            if not isinstance(selector, str) or not selector.strip():
                raise ValueError(f"{index}: selector がありません")
        for key in ("if-domain", "unless-domain", "resource-type", "load-type"):
            if key in trigger and not (
                isinstance(trigger[key], list) and all(isinstance(item, str) for item in trigger[key])
            ):
                raise ValueError(f"{index}: {key} は文字列の配列です")


def read_text(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    return Path(path).read_text(encoding="utf-8-sig")


def write_json(rules: list[dict], output: str | None) -> None:
    payload = json.dumps(rules, ensure_ascii=False, indent=2) + "\n"
    if output is None:
        sys.stdout.write(payload)
    else:
        Path(output).write_text(payload, encoding="utf-8")


def self_test() -> None:
    sample = """
! comment
[Adblock Plus 2.0]
||doubleclick.net^
||notdoubleclick.net^
@@||safe.example.com^
example.com,foo.com##.banner
##.adsbox
||ads.example.com^$script,third-party
||tracker.example^$csp=script-src 'none'
@@||ads.example.com/allowed.js^
example.com#@#.keep
||ads.example.com/banner/*
"""
    rules, stats = convert_lines(
        sample.splitlines(),
        allow_generic_cosmetic=True,
        limit=50000,
    )
    validate_rules(rules)
    assert stats.comments == 3
    assert stats.cosmetic_exceptions == 1
    assert stats.unsupported == 1  # $csp
    assert rules[-1]["action"]["type"] == "ignore-previous-rules"
    assert any(rule["action"]["type"] == "block" for rule in rules)
    types = [rule["action"]["type"] for rule in rules]
    assert types.index("ignore-previous-rules") > types.index("block")

    domain_rule = next(
        rule for rule in rules if "doubleclick" in rule["trigger"]["url-filter"] and "notdoubleclick" not in rule["trigger"]["url-filter"]
    )
    regex = domain_rule["trigger"]["url-filter"]
    assert re.search(regex, "https://ad.doubleclick.net/page")
    assert re.search(regex, "https://doubleclick.net")
    assert not re.search(regex, "https://notdoubleclick.net/")
    assert not re.search(regex, "https://doubleclick.net.evil.com/")

    script_rule = next(rule for rule in rules if rule["trigger"].get("resource-type") == ["script"])
    assert script_rule["trigger"]["load-type"] == ["third-party"]

    cosmetic = next(rule for rule in rules if rule["action"]["type"] == "css-display-none" and rule["action"]["selector"] == ".banner")
    assert cosmetic["trigger"]["if-domain"] == ["example.com", "foo.com"]

    generic = next(rule for rule in rules if rule["action"].get("selector") == ".adsbox")
    assert "if-domain" not in generic["trigger"]

    without_generic, _ = convert_lines(
        sample.splitlines(),
        allow_generic_cosmetic=False,
        limit=50000,
    )
    assert all(rule["action"].get("selector") != ".adsbox" for rule in without_generic)

    limited, _ = convert_lines(sample.splitlines(), allow_generic_cosmetic=True, limit=1)
    assert len(limited) == 1
    validate_rules(limited)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="EasyList テキストを WebKit Content Blocker JSON に変換します。")
    parser.add_argument("input", nargs="?", help="入力ファイル。- で標準入力")
    parser.add_argument("-o", "--output", help="出力 JSON。省略時は標準出力")
    parser.add_argument("--limit", type=int, default=50000, help="出力する規則の上限（既定 50000）")
    parser.add_argument(
        "--no-generic-cosmetic",
        action="store_true",
        help="ドメイン指定のない要素非表示を捨てる",
    )
    parser.add_argument("--self-test", action="store_true", help="同梱の自己テストを実行して終了する")
    parser.add_argument("--check", help="既存の Content Blocker JSON を検証する")
    args = parser.parse_args(argv)

    if args.self_test:
        self_test()
        print("self-test: ok", file=sys.stderr)
        return 0

    if args.check:
        payload = json.loads(Path(args.check).read_text(encoding="utf-8"))
        validate_rules(payload)
        print(f"check: ok ({len(payload)} rules)", file=sys.stderr)
        return 0

    if not args.input:
        parser.error("入力ファイルを指定してください")

    text = read_text(args.input)
    rules, stats = convert_lines(
        text.splitlines(),
        allow_generic_cosmetic=not args.no_generic_cosmetic,
        limit=args.limit,
    )
    validate_rules(rules)
    print(stats.summary(), file=sys.stderr)
    if not rules:
        print("変換結果が空です", file=sys.stderr)
        return 1
    write_json(rules, args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
