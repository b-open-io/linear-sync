#!/usr/bin/env python3
"""Generate or check the committed Linear Sync Codex custom-agent adapter."""

from __future__ import annotations

import argparse
import difflib
from pathlib import Path

from lib import AGENT_FILE, MANIFEST_FILE, atomic_write, build, json_text, plugin_root


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--plugin-root", type=Path)
    args = parser.parse_args()
    root = args.plugin_root.resolve() if args.plugin_root else plugin_root(Path(__file__))
    output = root / "codex" / "agents"
    adapter, manifest = build(root)
    expected = {AGENT_FILE: adapter, MANIFEST_FILE: json_text(manifest)}
    if args.check:
        problems: list[str] = []
        for name, expected_text in expected.items():
            path = output / name
            actual = path.read_text(encoding="utf-8") if path.is_file() else ""
            if actual != expected_text:
                problems.append(name)
                print("".join(difflib.unified_diff(actual.splitlines(True), expected_text.splitlines(True), fromfile=str(path), tofile=f"generated/{name}")))
        extras = sorted(path.name for path in output.glob("*.toml") if path.name != AGENT_FILE) if output.is_dir() else []
        problems.extend(extras)
        if problems:
            print("Codex agent adapters are stale: " + ", ".join(problems))
            return 1
        print(f"Codex agent adapters are current: {AGENT_FILE}")
        return 0
    for name, expected_text in expected.items():
        atomic_write(output / name, expected_text)
    print(f"Generated {AGENT_FILE} and {MANIFEST_FILE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
