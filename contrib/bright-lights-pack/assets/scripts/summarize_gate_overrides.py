#!/usr/bin/env python3
"""Summarize bright-lights gate-override audit log.

Reads the JSONL audit log produced by
prompts/convergence/gate.sh's visual-check fail branch and prints a
plain-text frequency table: counts by failure_field and counts by rig.
stdlib only.

Exit codes:
  0  success (including empty / missing log — prints "no records")
  2  malformed JSON on a line that was actually read
"""
import argparse
import json
import os
import sys
from collections import Counter


DEFAULT_LOG = os.path.expanduser("~/bright-lights/gate_overrides.log")


def load_records(path):
    records = []
    with open(path, "r", encoding="utf-8") as f:
        for lineno, line in enumerate(f, start=1):
            line = line.rstrip("\n")
            if not line.strip():
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(
                    f"error: malformed JSON on line {lineno} of {path}: {e}",
                    file=sys.stderr,
                )
                sys.exit(2)
    return records


def format_table(title, counter):
    if not counter:
        return f"{title}: (empty)\n"
    key_header = title
    key_width = max(len(key_header), max(len(str(k)) for k in counter.keys()))
    lines = []
    lines.append(f"{key_header.ljust(key_width)}  count")
    lines.append(f"{'-' * key_width}  -----")
    # Sort: most frequent first, then lexicographic.
    for key, count in sorted(counter.items(), key=lambda kv: (-kv[1], str(kv[0]))):
        lines.append(f"{str(key).ljust(key_width)}  {count}")
    return "\n".join(lines) + "\n"


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--log",
        default=DEFAULT_LOG,
        help=f"path to JSONL audit log (default: {DEFAULT_LOG})",
    )
    args = p.parse_args()

    if not os.path.exists(args.log):
        print(f"no records: {args.log} does not exist")
        return

    records = load_records(args.log)
    if not records:
        print(f"no records in {args.log}")
        return

    total = len(records)
    failure_counts = Counter(r.get("failure_field", "") for r in records)
    rig_counts = Counter(r.get("rig", "") for r in records)

    print(f"Gate-override audit log: {args.log}")
    print(f"Total records: {total}")
    print()
    print("Counts by failure_field:")
    print(format_table("failure_field", failure_counts))
    print("Counts by rig:")
    print(format_table("rig", rig_counts))


if __name__ == "__main__":
    main()
