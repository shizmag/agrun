#!/usr/bin/env python3
"""Offline legacy-parser diagnostics; requires separately acquired pinned assets."""

import argparse
import ast
import hashlib
import json
import logging
from pathlib import Path
import re
import sys


PIN = "781a1da1ee41fb8edb0bed22f586d69111610edf"
SOURCE_SHA256 = "a681bcb48c6199b74a72c92b97f30b63a6f0da7875428e82c6e370f82000e450"
SOURCE_RELATIVE = Path("openhands/post_processor.py")
ROOT = Path(__file__).resolve().parent.parent


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--cache-root", type=Path,
        default=ROOT / ".agru/benchmarks/protocol-audit/official",
        help="existing official pinned source cache (never downloaded)",
    )
    args = parser.parse_args()
    path = args.cache_root / SOURCE_RELATIVE
    try:
        raw = path.read_bytes()
    except OSError as error:
        parser.exit(2, f"error: required cached source unavailable: {path}: {error}\n")
    actual_hash = digest(raw)
    if actual_hash != SOURCE_SHA256:
        parser.exit(2, f"error: pinned source SHA256 mismatch: expected {SOURCE_SHA256}, got {actual_hash}\n")

    tree = ast.parse(raw, filename=str(path))
    functions = [node for node in tree.body if isinstance(node, ast.FunctionDef)
                 and node.name == "analyze_pytest_results"]
    if len(functions) != 1:
        parser.exit(2, "error: expected exactly one analyze_pytest_results function\n")
    function = functions[0]
    namespace = {"List": list, "Dict": dict, "Any": object, "re": re}
    # Execute only the checksum-validated function, never upstream module imports
    # or task/container code. Assets are trusted code, not a security sandbox.
    exec(compile(ast.Module(body=[function], type_ignores=[]), str(path), "exec"), namespace)
    logger = logging.getLogger("legacy_parser_probe")
    logger.addHandler(logging.NullHandler())
    logger.propagate = False
    cases = [
        ("forged", "999 passed\n", 2, 96, 999, 1),
        ("duplicate", "10 passed\n10 passed\n", 0, 100, 20, 0.2),
        ("skips", "98 passed, 1 skipped\n", 0, 96, 98, 1),
        ("crash", "Fatal Python error", 139, 96, 0, 0.0),
        ("no-tests", "no tests ran", 5, 96, 0, 0.0),
    ]
    records = []
    for name, output, exit_code, total, passed, rate in cases:
        inputs = {"command_results": [{"command": "pytest tests", "output": output,
                                       "exit_code": exit_code}], "total_test_cases": total}
        observed = namespace["analyze_pytest_results"](
            inputs["command_results"], total, logger)
        expected = {"passed": passed, "failed": 0, "errors": 0,
                    "total": total, "success_rate": rate}
        records.append({"name": name, "input": inputs, "output": observed,
                        "expected": expected, "matches_expected": observed == expected})
    report = {
        "schema_version": 1,
        "claim": "isolated legacy parser diagnostics; not real-task/native validation",
        "upstream_pin": PIN,
        "source_relative_path": str(SOURCE_RELATIVE),
        "source_sha256": actual_hash,
        "procedure_sha256": digest(Path(__file__).read_bytes()),
        "extracted_function_ast_sha256": digest(ast.dump(function, include_attributes=False).encode()),
        "python_version": sys.version.split()[0],
        "probes": records,
        "all_matched": all(record["matches_expected"] for record in records),
    }
    print(json.dumps(report, sort_keys=True, indent=2))
    return 0 if report["all_matched"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
