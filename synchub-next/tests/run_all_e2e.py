#!/usr/bin/env python3
"""
SyncHub-Next Master E2E Test Runner & Aggregator.
Executes all 4 test tiers, produces execution metrics, writes tests/results/summary.json,
and returns exit code 0 when all tests pass.

Usage:
    python tests/run_all_e2e.py              # Run all 4 tiers (161 tests)
    python tests/run_all_e2e.py --tier 1     # Run Tier 1: Feature Coverage (75 tests)
    python tests/run_all_e2e.py --tier 2     # Run Tier 2: Boundary & Corner Cases (75 tests)
    python tests/run_all_e2e.py --tier 3     # Run Tier 3: Pairwise Combinations (6 suites)
    python tests/run_all_e2e.py --tier 4     # Run Tier 4: Real-World Workloads (5 scenarios)
"""

import os
import sys
import time
import json
import argparse
import unittest
from datetime import datetime, timezone

# Ensure project root is in sys.path
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

SERVER_DIR = os.path.join(PROJECT_ROOT, "server", "synchub")
if SERVER_DIR not in sys.path:
    sys.path.insert(0, SERVER_DIR)


TIER_CONFIG = {
    1: {
        "name": "Tier 1: Feature Coverage",
        "dir": os.path.join(PROJECT_ROOT, "tests", "tier1_features"),
        "pattern": "test_*.py",
        "expected_tests": 75,
    },
    2: {
        "name": "Tier 2: Boundary & Corner Cases",
        "dir": os.path.join(PROJECT_ROOT, "tests", "tier2_boundaries"),
        "pattern": "test_*.py",
        "expected_tests": 75,
    },
    3: {
        "name": "Tier 3: Pairwise Combinations",
        "dir": os.path.join(PROJECT_ROOT, "tests", "tier3_combinations"),
        "pattern": "test_*.py",
        "expected_tests": 6,
    },
    4: {
        "name": "Tier 4: Real-World Workloads",
        "dir": os.path.join(PROJECT_ROOT, "tests", "tier4_real_world"),
        "pattern": "test_*.py",
        "expected_tests": 5,
    },
}


def run_tier(tier_num: int) -> dict:
    cfg = TIER_CONFIG[tier_num]
    start_time = time.time()
    loader = unittest.TestLoader()
    suite = loader.discover(start_dir=cfg["dir"], pattern=cfg["pattern"])

    stream = open(os.devnull, "w")
    runner = unittest.TextTestRunner(stream=stream, verbosity=0)
    result = runner.run(suite)
    duration = time.time() - start_time

    passed = result.testsRun - len(result.failures) - len(result.errors)
    failed = len(result.failures) + len(result.errors)

    error_details = []
    for test, err in result.failures + result.errors:
        error_details.append(f"{test.id()}: {err.strip().splitlines()[-1] if err.strip() else 'Error'}")

    return {
        "tier": tier_num,
        "name": cfg["name"],
        "tests_run": result.testsRun,
        "passed": passed,
        "failed": failed,
        "duration_seconds": round(duration, 3),
        "errors": error_details,
    }


def main():
    parser = argparse.ArgumentParser(description="SyncHub-Next Master E2E Test Runner")
    parser.add_argument("--tier", type=int, choices=[1, 2, 3, 4], help="Run a specific tier only")
    args = parser.parse_args()

    selected_tiers = [args.tier] if args.tier else [1, 2, 3, 4]

    print("=" * 80)
    print(" SyncHub-Next Automated End-to-End Test Suite")
    print(f" Execution Date: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%SZ')}")
    print(" Strict Isolation: Loopback 127.0.0.1 | Ephemeral Ports | Zero Remote Calls")
    print("=" * 80)

    overall_start = time.time()
    tier_results = []
    total_run = 0
    total_passed = 0
    total_failed = 0

    for t_num in selected_tiers:
        print(f"\n[RUNNING] {TIER_CONFIG[t_num]['name']}...")
        res = run_tier(t_num)
        tier_results.append(res)
        total_run += res["tests_run"]
        total_passed += res["passed"]
        total_failed += res["failed"]

        status_str = "PASS" if res["failed"] == 0 else "FAIL"
        print(f"[{status_str}] {res['name']}: {res['passed']}/{res['tests_run']} passed in {res['duration_seconds']}s")
        if res["failed"] > 0:
            for err in res["errors"]:
                print(f"    ! {err}")

    overall_duration = time.time() - overall_start

    # Summary Table
    print("\n" + "=" * 80)
    print(" TEST EXECUTION SUMMARY")
    print("=" * 80)
    print(f"{'Tier':<35} | {'Tests':<8} | {'Passed':<8} | {'Failed':<8} | {'Duration':<10}")
    print("-" * 80)
    for res in tier_results:
        print(f"{res['name']:<35} | {res['tests_run']:<8} | {res['passed']:<8} | {res['failed']:<8} | {res['duration_seconds']:<9}s")
    print("-" * 80)
    print(f"{'TOTAL':<35} | {total_run:<8} | {total_passed:<8} | {total_failed:<8} | {overall_duration:.3f}s")
    print("=" * 80)

    all_passed = (total_failed == 0 and total_run > 0)
    if all_passed:
        print(f"\n OVERALL RESULT: ALL {total_run} TESTS PASSED (100% SUCCESS)")
    else:
        print(f"\n OVERALL RESULT: FAILED ({total_failed} failures out of {total_run} tests)")

    # Save results to JSON
    results_dir = os.path.join(PROJECT_ROOT, "tests", "results")
    os.makedirs(results_dir, exist_ok=True)
    summary_path = os.path.join(results_dir, "summary.json")

    summary_data = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total_tests": total_run,
        "passed_tests": total_passed,
        "failed_tests": total_failed,
        "duration_seconds": round(overall_duration, 3),
        "all_passed": all_passed,
        "tiers": tier_results,
    }

    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump(summary_data, f, indent=2)
    print(f"Report written to: {summary_path}")

    sys.exit(0 if all_passed else 1)


if __name__ == "__main__":
    main()
