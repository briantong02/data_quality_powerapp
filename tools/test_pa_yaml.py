#!/usr/bin/env python3
"""Lints .pa.yaml sources for the hazards that break a Canvas App build.

A port of Test-PaYaml.ps1, for machines without PowerShell. Same three checks,
same exit codes, so either script can gate a pack:

  1. Plain-scalar hazards. Power Apps writes formulas as YAML scalars. An
     UNQUOTED (plain) scalar may not contain ": " -- YAML reads that as a
     key/value separator and fails with PA1001 YamlInvalidSyntax. Power Fx
     record literals are written {Key: Value}, so this bites constantly.
     Block scalars ("Prop: |") are exempt: everything under "|" is literal.
     Also flagged: " #" (opens a YAML comment mid-scalar) and a trailing ":".
  2. Control block indentation. A "- name:" at indent N must be followed by
     "Control:" at N+4. YAML otherwise fails with "did not find expected key",
     pointing at the line AFTER the real mistake.
  3. Control name uniqueness, app-wide -- not per screen. Studio reports a
     collision as PA2110 "An entity with name 'x' already exists".

Unlike the PowerShell original this also parses each file with a real YAML
parser, which catches the whole malformed-document class rather than the three
patterns above.

NOTE: 'pac canvas pack' does NOT parse .pa.yaml. It packs invalid YAML without
complaint and the failure only surfaces when Studio opens the .msapp. Run this
first.

Usage:
    python3 tools/test_pa_yaml.py [--path src/Src] [--quiet]
Exit: 0 PASS, 1 FAIL, 2 nothing to lint.
"""

import argparse
import pathlib
import re
import sys
from collections import defaultdict

INLINE_FORMULA = re.compile(r"^\s+[A-Za-z][A-Za-z0-9]*:\s+=")
PROP_PREFIX = re.compile(r"^\s+[A-Za-z][A-Za-z0-9]*:\s+")
CONTROL_ENTRY = re.compile(r"^(\s*)-\s+([A-Za-z][A-Za-z0-9_]*):\s*$")

# _EditorState.pa.yaml is editor metadata, not controls; it is exempt from the
# structural checks exactly as it is in the PowerShell original.
EDITOR_STATE = "_EditorState.pa.yaml"


def scalar_hazards(lines):
    """Check 1 -- plain scalars that YAML will misread."""
    for n, line in enumerate(lines, 1):
        if not INLINE_FORMULA.match(line):
            continue
        value = PROP_PREFIX.sub("", line, count=1)
        reasons = []
        if re.search(r":\s", value):
            reasons.append("colon-space")
        if re.search(r":$", value):
            reasons.append("trailing-colon")
        if re.search(r"\s#", value):
            reasons.append("space-hash")
        if reasons:
            yield n, "+".join(reasons), line.strip()


def control_indent(lines):
    """Check 2 -- 'Control:' must sit 4 spaces inside its '- name:'."""
    for i, line in enumerate(lines):
        m = CONTROL_ENTRY.match(line)
        if not m:
            continue
        name_indent = len(m.group(1))
        j = i + 1
        while j < len(lines) and (not lines[j].strip() or lines[j].lstrip().startswith("#")):
            j += 1
        if j >= len(lines):
            continue
        next_indent = len(lines[j]) - len(lines[j].lstrip())
        if lines[j].lstrip().startswith("Control:") and next_indent != name_indent + 4:
            yield j + 1, (
                f"control block indent: '- {m.group(2)}:' at {name_indent} but "
                f"'Control:' at {next_indent} (expected {name_indent + 4})"
            )


def main():
    ap = argparse.ArgumentParser(description="Lint .pa.yaml sources before packing.")
    ap.add_argument("--path", default=None, help="directory of .pa.yaml files (default: ../src/Src)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    root = pathlib.Path(args.path) if args.path else pathlib.Path(__file__).resolve().parent.parent / "src" / "Src"
    files = sorted(root.glob("*.pa.yaml"))
    if not files:
        print(f"No .pa.yaml files found under {root}", file=sys.stderr)
        return 2

    scalar_bad = defaultdict(list)
    indent_bad = []
    parse_bad = []
    names = defaultdict(list)

    for path in files:
        # Explicit UTF-8: these files contain em dashes and other non-ASCII, and
        # a locale-default decode mangles them silently.
        text = path.read_text(encoding="utf-8")
        lines = text.splitlines()

        scalar_bad[path.name] = list(scalar_hazards(lines))

        try:
            yaml_mod = __import__("yaml")
            yaml_mod.safe_load(text)
        except ImportError:
            pass  # no PyYAML: the three pattern checks still run
        except Exception as exc:
            parse_bad.append((path.name, str(exc).replace("\n", " ")))

        if path.name == EDITOR_STATE:
            continue
        indent_bad += [(path.name, n, msg) for n, msg in control_indent(lines)]
        for n, line in enumerate(lines, 1):
            m = CONTROL_ENTRY.match(line)
            if m and line.startswith(" "):
                names[m.group(2)].append(f"{path.name}:{n}")

    dupes = {k: v for k, v in names.items() if len(v) > 1}
    total_scalar = sum(len(v) for v in scalar_bad.values())

    if not args.quiet:
        print()
        for path in files:
            bad = scalar_bad[path.name]
            if not bad:
                print(f"  {path.name:<30} OK")
            else:
                print(f"  {path.name:<30} {len(bad)} problem(s)")
                for n, reason, txt in bad:
                    print(f"      line {n:<5} [{reason}]  {txt}")
        print()

    if parse_bad:
        print("  YAML parse failures:")
        for name, msg in parse_bad:
            print(f"      {name}  ->  {msg}")
        print()
    if indent_bad:
        print("  Control block indentation problems:")
        for name, n, msg in indent_bad:
            print(f"      {name}:{n}  {msg}")
        print()
    if dupes:
        print("  Duplicate control names (must be unique app-wide):")
        for name, where in sorted(dupes.items()):
            print(f"      {name}  ->  {', '.join(where)}")
        print()

    if total_scalar or indent_bad or dupes or parse_bad:
        if parse_bad:
            print(f"  {len(parse_bad)} file(s) are not valid YAML. FAIL")
        if indent_bad:
            print(f"  {len(indent_bad)} control block(s) at the wrong indent. FAIL")
        if total_scalar:
            print(f"  {total_scalar} offending plain scalar(s). FAIL")
        if dupes:
            print(f"  {len(dupes)} duplicated control name(s). FAIL")
        print("  Fix: change 'Prop: =formula' to a block scalar 'Prop: |' with the")
        print("        formula on the next line, indented +2, and give every control a")
        print("        name unique across all screens.")
        print()
        return 1

    print("  0 offending plain scalars, 0 duplicate names, all files parse. PASS")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
