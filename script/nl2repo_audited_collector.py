#!/usr/bin/env python3
"""Pinned pytest 8.4.1 collector. Protocol output is never read from stdout."""
import argparse
import json
import os
import sys
import tempfile
import traceback

import pytest


class Collector:
    def __init__(self, binding):
        self.document = {
            "schema": "agru.pytest-results.v1",
            "pytest_version": pytest.__version__,
            "binding": binding,
            "collected": [],
            "collection_errors": [],
            "tests": [],
            "exit_code": None,
            "finished": False,
        }
        self.tests = {}
        self.failed_collections = []

    def pytest_collection_finish(self, session):
        self.document["collected"] = [item.nodeid for item in session.items]

    def pytest_collectreport(self, report):
        if report.failed:
            self.failed_collections.append(report.nodeid)

    def pytest_exception_interact(self, node, call, report):
        if not isinstance(report, pytest.CollectReport) or not report.failed:
            return
        # ImportError from Python modules is normally wrapped by pytest's import
        # machinery. Follow the actual exception chain, never rendered longrepr.
        error = call.excinfo.value
        seen = set()
        while id(error) not in seen:
            seen.add(id(error))
            nested = error.__cause__ or error.__context__
            if nested is None:
                break
            error = nested
        frames = [
            {"path": frame.filename, "lineno": frame.lineno, "name": frame.name}
            for frame in traceback.extract_tb(error.__traceback__)
        ]
        self.document["collection_errors"].append({
            "nodeid": report.nodeid,
            "exception": {
                "type": type(error).__name__,
                "module": error.name if isinstance(error, ModuleNotFoundError) else None,
                "message": str(error),
                "frames": frames,
            },
        })

    def pytest_runtest_logreport(self, report):
        if report.nodeid not in self.tests:
            test = {"nodeid": report.nodeid, "reports": []}
            self.tests[report.nodeid] = test
            self.document["tests"].append(test)
        phase = {"when": report.when, "outcome": report.outcome}
        if hasattr(report, "wasxfail"):
            phase["wasxfail"] = str(report.wasxfail)
        self.tests[report.nodeid]["reports"].append(phase)


def write_report(path, document):
    encoded = json.dumps(document, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
    if len(encoded) > 4 * 1024 * 1024:
        raise ValueError("structured pytest report exceeds size limit")
    directory = os.path.dirname(os.path.abspath(path))
    descriptor, temporary = tempfile.mkstemp(prefix=".agru-results-", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binding", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("pytest_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if pytest.__version__ != "8.4.1":
        raise RuntimeError("collector requires pinned pytest 8.4.1")
    with open(args.binding, encoding="utf-8") as stream:
        binding = json.load(stream)
    if not isinstance(binding, dict) or not binding:
        raise ValueError("nonempty trusted binding object required")
    collector = Collector(binding)
    pytest_args = args.pytest_args
    if pytest_args[:1] == ["--"]:
        pytest_args = pytest_args[1:]
    code = int(pytest.main(pytest_args, plugins=[collector]))
    # A failed collection without actual exception metadata cannot be classified.
    recorded = [error["nodeid"] for error in collector.document["collection_errors"]]
    if sorted(recorded) != sorted(collector.failed_collections):
        raise RuntimeError("missing structured collection exception metadata")
    collector.document["exit_code"] = code
    collector.document["finished"] = True
    write_report(args.output, collector.document)
    return code


if __name__ == "__main__":
    sys.exit(main())
