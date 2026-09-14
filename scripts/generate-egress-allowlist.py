#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path

POLICY_FILE = Path("policies/egress-allowlist.yaml")
OUTPUT_FILE = Path("environment/customer-egress/generated/allowlist.txt")

ENTRY_START = re.compile(r"^\s*-\s+fqdn:\s*(\S+)\s*$")
FIELD = re.compile(r"^\s{4}(port|component|reason|breakage|phase):\s*(.*?)\s*$")


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_policy() -> list[dict[str, str]]:
    if not POLICY_FILE.is_file():
        fail(f"policy file not found: {POLICY_FILE}")

    entries: list[dict[str, str]] = []
    current: dict[str, str] | None = None

    for line_number, raw in enumerate(
        POLICY_FILE.read_text(encoding="utf-8").splitlines(),
        start=1,
    ):
        line = raw.strip()

        if not line or line.startswith("#"):
            continue

        match = ENTRY_START.match(raw)
        if match:
            if current is not None:
                entries.append(current)

            current = {"fqdn": match.group(1)}
            continue

        match = FIELD.match(raw)
        if match:
            if current is None:
                fail(f"field before entry at line {line_number}")

            key, value = match.groups()
            current[key] = value.strip().strip('"')
            continue

    if current is not None:
        entries.append(current)

    if not entries:
        return []

    for index, entry in enumerate(entries, start=1):
        for field in ("fqdn", "port", "component", "reason", "breakage", "phase"):
            if field not in entry:
                fail(f"entry {index} is missing '{field}'")

        fqdn = entry["fqdn"].rstrip(".").lower()

        try:
            port = int(entry["port"])
        except ValueError:
            fail(f"entry {index} has invalid port: {entry['port']}")

        if not (1 <= port <= 65535):
            fail(f"entry {index} has invalid port: {port}")

        entry["fqdn"] = fqdn
        entry["port"] = str(port)

    return entries


def main() -> None:
    entries = parse_policy()

    output_entries: list[str] = []
    seen: set[tuple[str, int]] = set()

    for entry in entries:
        fqdn = entry["fqdn"]
        port = int(entry["port"])
        key = (fqdn, port)

        if key in seen:
            fail(f"duplicate allowlist entry: {fqdn}:{port}")

        seen.add(key)

        print(
            f"POLICY_ENTRY fqdn={fqdn} port={port} "
            f"component={entry['component']} phase={entry['phase']}"
        )

        output_entries.append(f"{fqdn}:{port}")

    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)

    OUTPUT_FILE.write_text(
        "\n".join(output_entries) + ("\n" if output_entries else ""),
        encoding="utf-8",
    )

    print(f"GENERATED_ALLOWLIST_ENTRIES={len(output_entries)}")
    print(f"OUTPUT={OUTPUT_FILE}")


if __name__ == "__main__":
    main()
