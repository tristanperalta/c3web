#!/usr/bin/env python3
"""
Autobahn Testsuite Results Checker

Parses the Autobahn JSON results and displays a summary.
Run after executing the Autobahn testsuite against your WebSocket server.

Usage:
    ./check_results.py                    # Summary only
    ./check_results.py --all              # Show all test results
    ./check_results.py --failed           # Show only failed tests
    ./check_results.py --category 12      # Show results for category 12 (compression)
"""

import json
import argparse
import os
from pathlib import Path

def natural_sort_key(s):
    """Sort test IDs naturally (1.1.1 < 1.1.2 < 1.1.10)"""
    import re
    return [int(c) if c.isdigit() else c for c in re.split(r'(\d+)', s)]

def load_results(report_dir):
    """Load results from index.json"""
    index_path = Path(report_dir) / "index.json"
    if not index_path.exists():
        print(f"Error: {index_path} not found")
        print("Run the Autobahn testsuite first: ./run_autobahn.sh")
        return None

    with open(index_path) as f:
        return json.load(f)

def print_summary(results, server_name):
    """Print overall summary of results"""
    behaviors = {}
    for test_id, result in results.items():
        behavior = result.get('behavior', 'UNKNOWN')
        behaviors[behavior] = behaviors.get(behavior, 0) + 1

    print(f"\n{'='*60}")
    print(f"  Autobahn Testsuite Results: {server_name}")
    print(f"{'='*60}\n")

    # Color codes for terminal
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    RESET = '\033[0m'

    total = len(results)
    ok = behaviors.get('OK', 0)
    failed = behaviors.get('FAILED', 0)
    non_strict = behaviors.get('NON-STRICT', 0)
    informational = behaviors.get('INFORMATIONAL', 0)
    unimplemented = behaviors.get('UNIMPLEMENTED', 0)

    print(f"  {GREEN}OK:             {ok:4d}{RESET}  (Passed)")
    print(f"  {YELLOW}NON-STRICT:     {non_strict:4d}{RESET}  (Passed with minor issues)")
    print(f"  {BLUE}INFORMATIONAL:  {informational:4d}{RESET}  (For information only)")
    print(f"  {BLUE}UNIMPLEMENTED:  {unimplemented:4d}{RESET}  (Feature not implemented)")
    print(f"  {RED}FAILED:         {failed:4d}{RESET}  (Failed)")
    print(f"  {'─'*30}")
    print(f"  Total:          {total:4d}")

    # Pass rate (excluding informational/unimplemented)
    testable = ok + non_strict + failed
    if testable > 0:
        pass_rate = (ok + non_strict) / testable * 100
        print(f"\n  Pass rate: {pass_rate:.1f}% ({ok + non_strict}/{testable} testable cases)")

    print()

def print_results_by_category(results, category=None, show_only=None):
    """Print results organized by category"""
    # Group by category
    categories = {}
    for test_id, result in results.items():
        cat = test_id.split('.')[0]
        if category and cat != str(category):
            continue
        if cat not in categories:
            categories[cat] = []
        categories[cat].append((test_id, result))

    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    RESET = '\033[0m'

    category_names = {
        '1': 'Framing',
        '2': 'Pings/Pongs',
        '3': 'Reserved Bits',
        '4': 'Opcodes',
        '5': 'Fragmentation',
        '6': 'UTF-8 Handling',
        '7': 'Close Handling',
        '9': 'Limits/Performance',
        '10': 'Auto-Fragmentation',
        '12': 'Compression (pmce)',
        '13': 'Compression (pmce context takeover)',
    }

    for cat in sorted(categories.keys(), key=int):
        tests = sorted(categories[cat], key=lambda x: natural_sort_key(x[0]))

        # Filter if needed
        if show_only:
            tests = [(t, r) for t, r in tests if r.get('behavior') in show_only]
            if not tests:
                continue

        cat_name = category_names.get(cat, 'Unknown')
        print(f"\n{'─'*60}")
        print(f"  Category {cat}: {cat_name}")
        print(f"{'─'*60}")

        for test_id, result in tests:
            behavior = result.get('behavior', 'UNKNOWN')

            # Color based on behavior
            if behavior == 'OK':
                color = GREEN
                symbol = '✓'
            elif behavior == 'NON-STRICT':
                color = YELLOW
                symbol = '~'
            elif behavior == 'FAILED':
                color = RED
                symbol = '✗'
            elif behavior == 'INFORMATIONAL':
                color = BLUE
                symbol = 'i'
            elif behavior == 'UNIMPLEMENTED':
                color = BLUE
                symbol = '-'
            else:
                color = RESET
                symbol = '?'

            print(f"  {color}{symbol} {test_id:12s}{RESET} {behavior}")

def print_failed_details(results, report_dir):
    """Print detailed info about failed tests"""
    failed_tests = [(t, r) for t, r in results.items() if r.get('behavior') == 'FAILED']

    if not failed_tests:
        print("\n  No failed tests! 🎉")
        return

    print(f"\n{'='*60}")
    print(f"  Failed Test Details")
    print(f"{'='*60}")

    for test_id, result in sorted(failed_tests, key=lambda x: natural_sort_key(x[0])):
        print(f"\n  Test {test_id}:")
        print(f"  {'─'*40}")

        # Try to load detailed report
        # File names use underscores, not dots
        report_name = f"c3web_websocket_server_case_{test_id.replace('.', '_')}.json"
        report_path = Path(report_dir) / report_name

        if report_path.exists():
            with open(report_path) as f:
                detail = json.load(f)

            desc = detail.get('description', 'No description')
            expectation = detail.get('expectation', 'No expectation')
            result_text = detail.get('result', 'No result')

            print(f"  Description: {desc[:80]}")
            print(f"  Expected: {expectation[:80]}")
            print(f"  Result: {result_text[:80]}")
        else:
            print(f"  (detailed report not found)")

def main():
    parser = argparse.ArgumentParser(description='Check Autobahn testsuite results')
    parser.add_argument('--all', action='store_true', help='Show all test results')
    parser.add_argument('--failed', action='store_true', help='Show only failed tests')
    parser.add_argument('--non-strict', action='store_true', help='Show failed and non-strict tests')
    parser.add_argument('--category', '-c', type=int, help='Show results for specific category (1-13)')
    parser.add_argument('--details', '-d', action='store_true', help='Show detailed info for failed tests')
    parser.add_argument('--report-dir', default=None, help='Report directory (default: auto-detect)')
    args = parser.parse_args()

    # Find report directory
    script_dir = Path(__file__).parent
    if args.report_dir:
        report_dir = Path(args.report_dir)
    else:
        report_dir = script_dir / "reports"

    # Load results
    data = load_results(report_dir)
    if not data:
        return 1

    # Find server results
    servers = list(data.keys())
    if not servers:
        print("No server results found in report")
        return 1

    server_name = servers[0]  # Usually just one server
    results = data[server_name]

    # Print summary
    print_summary(results, server_name)

    # Print detailed results if requested
    if args.all:
        print_results_by_category(results, args.category)
    elif args.failed:
        print_results_by_category(results, args.category, show_only=['FAILED'])
    elif args.non_strict:
        print_results_by_category(results, args.category, show_only=['FAILED', 'NON-STRICT'])
    elif args.category:
        print_results_by_category(results, args.category)

    # Print failed details if requested
    if args.details:
        print_failed_details(results, report_dir)

    return 0

if __name__ == '__main__':
    exit(main())
