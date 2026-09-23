#!/usr/bin/env bash
# 验证构建：xcodegen → xcodebuild build + test（FairyStudio-Verify scheme，Verify-iOS26.xcconfig）。
# 目标：iPhone 17 Pro 与 iPad Pro 11-inch (M5) 模拟器（名称经 `xcodebuild -showdestinations` 实测）。
# 结果口径：模拟器 (iOS 26.3, 验证构建)，只能记为「已实现待 iOS 27 环境复验」。见 docs/ENVIRONMENT.md。
#
# 用法：
#   scripts/build-verify.sh                 # 两台模拟器：build + 全部测试
#   FAIRY_ONLY_DEVICE=iphone scripts/build-verify.sh
#   FAIRY_TEST_FILTER="-only-testing:FairyStudioTests" scripts/build-verify.sh
#   FAIRY_SKIP_GENERATE=1 scripts/build-verify.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$ROOT/verification/logs"
mkdir -p "$LOG_DIR"
# DerivedData 不能放在 ~/Desktop 下：iCloud / 文件提供者附加的扩展属性会让 codesign 报
# "resource fork, Finder information, or similar detritus not allowed"（已实测）。
DERIVED="${FAIRY_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/FairyStudio-verify}"
RESULTS="$DERIVED/results"
mkdir -p "$RESULTS"

IPHONE="platform=iOS Simulator,name=iPhone 17 Pro"
IPAD="platform=iOS Simulator,name=iPad Pro 11-inch (M5)"
case "${FAIRY_ONLY_DEVICE:-all}" in
  iphone) DESTINATIONS=("$IPHONE") ;;
  ipad) DESTINATIONS=("$IPAD") ;;
  *) DESTINATIONS=("$IPHONE" "$IPAD") ;;
esac

SUMMARY="$LOG_DIR/$STAMP-summary.log"
echo "# build-verify $STAMP" | tee "$SUMMARY"
echo "xcode: $(xcodebuild -version | tr '\n' ' ')" | tee -a "$SUMMARY"

if [[ "${FAIRY_SKIP_GENERATE:-0}" != "1" ]]; then
  echo "== xcodegen generate" | tee -a "$SUMMARY"
  xcodegen generate 2>&1 | tail -1 | tee -a "$SUMMARY"
fi

overall=0
for destination in "${DESTINATIONS[@]}"; do
  slug="$(echo "$destination" | sed -E 's/.*name=//; s/[^A-Za-z0-9]+/-/g; s/-$//')"
  log="$LOG_DIR/$STAMP-$slug.log"
  bundle="$RESULTS/$STAMP-$slug.xcresult"
  echo "== $destination → $log" | tee -a "$SUMMARY"
  # shellcheck disable=SC2086
  xcodebuild \
    -project FairyStudio.xcodeproj \
    -scheme FairyStudio-Verify \
    -destination "$destination" \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$bundle" \
    -parallel-testing-enabled NO \
    ${FAIRY_TEST_FILTER:-} \
    build test > "$log" 2>&1
  status=$?
  echo "exit=$status" | tee -a "$SUMMARY"
  # 汇总：Swift Testing 与 XCTest 的结果行、失败行、最终结论。
  grep -E "Test run with [0-9]+ tests|^✘|Executed [0-9]+ tests?, with|Test Case .*(passed|failed)|: error:|\*\* (BUILD|TEST) (SUCCEEDED|FAILED) \*\*|^\[FAIRY-AVAILABILITY" "$log" \
    | sed -E 's/ \([0-9.]+ seconds\)//' | sort -u | tee -a "$SUMMARY"
  if [[ $status -ne 0 ]]; then overall=$status; fi
done

echo "overall_exit=$overall" | tee -a "$SUMMARY"
exit $overall
