#!/bin/bash
# Prints every test atom (a Tests/*.swift entry file) the runner from build_test_runner.sh dispatches on, one per line.
# test.sh and the CircleCI suite (.circleci/test-suites.yml discover) both read this list.
cd "$(dirname "$0")/.."
{
    # Harness atoms the runner checks with `atom == …` rather than selected(…).
    printf '%s\n' Tests/EventOverviewAccessibilityTests.swift Tests/ReaderAccessibilityTests.swift \
        Tests/TensionCalibrationTests.swift
    grep -oE 'selected\("Tests/[A-Za-z0-9]+\.swift"\)' script/build_test_runner.sh | grep -oE 'Tests/[A-Za-z0-9]+\.swift'
} | sort -u
