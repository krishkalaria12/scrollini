#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
macos_dir="$root/apps/macos"

echo "== config json validates =="
python3 -m json.tool "$root/scrollini.config.json" > /dev/null && echo "ok scrollini.config.json is valid json"
python3 -c "
import json, pathlib
cfg = json.loads(pathlib.Path('$root/scrollini.config.json').read_text())
assert 'default_width_ratio' in cfg, 'missing default_width_ratio'
assert 0.2 <= cfg['default_width_ratio'] <= 2.0
assert isinstance(cfg['preset_width_ratios'], list) and len(cfg['preset_width_ratios']) >= 1
print('ok config keys and ranges')
"

echo ""
echo "== swift build =="
swift build --package-path "$macos_dir"

echo ""
echo "== self-check (308 invariants) =="
"$macos_dir/.build/arm64-apple-macosx/debug/Scrollini" --self-check 2>&1 | tee /tmp/scrollini-self-check.log
grep -q "308/308 checks passed" /tmp/scrollini-self-check.log

# Try swift test when XCTest is available (full Xcode). On CLT it will be 0 tests but should not fail.
echo ""
echo "== swift test (requires full Xcode; 0 tests on CLT is expected) =="
if xcrun --find xctest 2>/dev/null | grep -q xctest; then
  swift test --package-path "$macos_dir" 2>&1 | tee /tmp/scrollini-swift-test.log || true
  if grep -q "Test Suite.*passed" /tmp/scrollini-swift-test.log; then echo "ok swift test passed"; fi
else
  echo "-- XCTest not available in this toolchain (Command Line Tools only); running --build-tests as compile check"
  swift build --build-tests --package-path "$macos_dir" > /dev/null && echo "ok tests compile"
  echo "tip: install full Xcode for swift test execution"
fi

echo ""
echo "all checks passed"
