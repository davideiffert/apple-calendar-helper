#!/bin/sh
# Runs the tests. The RRULE tests need swiftc (macOS, or Swift on Linux).
set -eu
cd "$(dirname "$0")"
python3 -m unittest discover -s tests
if command -v swiftc >/dev/null 2>&1; then
    mkdir -p build
    swiftc -parse-as-library RRule.swift tests/RRuleTests.swift -o build/rrule-tests
    build/rrule-tests
else
    echo "swiftc not found: skipped the RRULE tests"
fi
