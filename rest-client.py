#!/usr/bin/env python3
"""Simple REST poller for the blue/green demo endpoint."""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass
from typing import Dict, Iterable, Tuple

import requests
from requests import Response


DEFAULT_URL = "http://localhost:9001/color"


@dataclass
class PollStats:
    """Track polling totals for a single run."""

    total: int = 0
    success: int = 0
    failure: int = 0


def positive_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"Expected a number, got {value!r}") from exc
    if parsed <= 0:
        raise argparse.ArgumentTypeError("Value must be greater than 0")
    return parsed


def non_negative_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"Expected a number, got {value!r}") from exc
    if parsed < 0:
        raise argparse.ArgumentTypeError("Value must be >= 0")
    return parsed


def non_negative_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"Expected an integer, got {value!r}") from exc
    if parsed < 0:
        raise argparse.ArgumentTypeError("Value must be >= 0")
    return parsed


def header_type(header: str) -> Tuple[str, str]:
    if "=" not in header:
        raise argparse.ArgumentTypeError("Header must look like NAME=VALUE")
    name, value = header.split("=", 1)
    name = name.strip()
    if not name:
        raise argparse.ArgumentTypeError("Header name cannot be empty")
    return name, value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Continuously poll the color endpoint (or any REST URL)."
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_URL,
        help=f"Endpoint to query (default: {DEFAULT_URL}).",
    )
    parser.add_argument(
        "--interval",
        type=non_negative_float,
        default=0.5,
        metavar="SECONDS",
        help="Delay between requests. Set to 0 to run back-to-back (default: 0.5).",
    )
    parser.add_argument(
        "--timeout",
        type=positive_float,
        default=1.0,
        metavar="SECONDS",
        help="Per-request timeout in seconds (default: 1).",
    )
    parser.add_argument(
        "--count",
        type=non_negative_int,
        default=0,
        metavar="N",
        help="Stop after N requests. Leave at 0 to keep running until Ctrl+C.",
    )
    parser.add_argument(
        "--header",
        type=header_type,
        action="append",
        default=[],
        metavar="NAME=VALUE",
        help="Extra HTTP header(s) to send. Repeat for multiple headers.",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Skip TLS certificate verification (useful for local HTTPS).",
    )
    parser.add_argument(
        "--raw",
        action="store_true",
        help="Print raw text bodies instead of attempting to parse JSON.",
    )
    return parser


def format_body(response: Response, raw: bool) -> str:
    if raw:
        body = response.text.strip()
        return body or "<empty body>"
    try:
        data = response.json()
    except ValueError:
        snippet = response.text.strip()
        return snippet or "<non-JSON body>"
    if isinstance(data, (dict, list)):
        return json.dumps(data, separators=(",", ":"))
    return str(data)


def flatten_headers(items: Iterable[Tuple[str, str]]) -> Dict[str, str]:
    headers: Dict[str, str] = {}
    for name, value in items:
        headers[name] = value
    return headers


def poll(args: argparse.Namespace) -> int:
    headers = flatten_headers(args.header)
    limit = None if args.count == 0 else args.count
    stats = PollStats()
    start_time = time.perf_counter()

    with requests.Session() as session:
        verify = not args.insecure
        try:
            while limit is None or stats.total < limit:
                request_id = stats.total + 1
                stats.total += 1
                tick_start = time.perf_counter()
                try:
                    response = session.get(
                        args.url,
                        timeout=args.timeout,
                        headers=headers,
                        verify=verify,
                    )
                except requests.RequestException as exc:
                    stats.failure += 1
                    print(
                        f"[{request_id:04}] ERROR {exc.__class__.__name__}: {exc}",
                        file=sys.stderr,
                    )
                else:
                    stats.success += 1
                    latency_ms = (time.perf_counter() - tick_start) * 1000
                    body = format_body(response, raw=args.raw)
                    print(
                        f"[{request_id:04}] {response.status_code} "
                        f"{latency_ms:.1f}ms {body}"
                    )
                if limit is not None and stats.total >= limit:
                    break
                if args.interval > 0:
                    time.sleep(args.interval)
        except KeyboardInterrupt:
            print("\nInterrupted by user.")

    duration = time.perf_counter() - start_time
    print(
        f"Stopped after {stats.total} request(s) in {duration:.1f}s — "
        f"{stats.success} succeeded, {stats.failure} failed."
    )
    return 0 if stats.success else 1


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return poll(args)


if __name__ == "__main__":
    raise SystemExit(main())
