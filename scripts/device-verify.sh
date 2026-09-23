#!/usr/bin/env bash
# 实机验证：FairyStudio-Verify scheme（部署目标 26.2，可运行于 iOS 27.0）→ iPhone 16 Pro Max。
# xcodebuild 只接受硬件 UDID（devicectl 的 CoreDevice 标识会报 “Unable to find a device”，已实测）。
# 签名：Config/Signing.local.xcconfig 的 DEVELOPMENT_TEAM（gitignored），自动签名需要该团队的账户已登录 Xcode「设置 → 账户」。
# 本脚本不修改团队 ID、不输入任何凭据；失败时原样保留 xcodebuild 输出。
#
# 用法：
#   scripts/device-verify.sh                       # build + FairyStudioTests + FairyStudioUITests
#   FAIRY_DEVICE_ID=<硬件 UDID> scripts/device-verify.sh
#   FAIRY_TEST_FILTER="-only-testing:FairyStudioTests" scripts/device-verify.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVICE_ID="${FAIRY_DEVICE_ID:-00008140-000E2C523A52801C}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$ROOT/verification/logs"
mkdir -p "$LOG_DIR"
# DerivedData 不放在 ~/Desktop 下（iCloud 扩展属性会让 codesign 失败，见 docs/progress/M0-B.md）。
DERIVED="${FAIRY_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/FairyStudio-device}"
RESULTS="$DERIVED/results"
mkdir -p "$RESULTS"
SUMMARY="$LOG_DIR/$STAMP-device-summary.log"

echo "# device-verify $STAMP device=$DEVICE_ID" | tee "$SUMMARY"
echo "xcode: $(xcodebuild -version | tr '\n' ' ')" | tee -a "$SUMMARY"

summarize() {
  grep -E "Test run with [0-9]+ tests|^✘|Executed [0-9]+ tests?, with|Test Case .*(passed|failed)|: error:|error: |\*\* (BUILD|TEST|TEST BUILD|TEST EXECUTE) (SUCCEEDED|FAILED) \*\*|^\[FAIRY-" "$1" \
    | sed -E 's/ \([0-9.]+ seconds\)//' | sort -u | tee -a "$SUMMARY"
}

build_log="$LOG_DIR/$STAMP-device-build.log"
echo "== build → $build_log" | tee -a "$SUMMARY"
xcodebuild -project FairyStudio.xcodeproj -scheme FairyStudio-Verify -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > "$build_log" 2>&1
status=$?
echo "exit=$status" | tee -a "$SUMMARY"
summarize "$build_log"
if [[ $status -ne 0 ]]; then
  echo "构建失败，未运行测试。" | tee -a "$SUMMARY"
  exit $status
fi

test_log="$LOG_DIR/$STAMP-device-test.log"
echo "== test → $test_log" | tee -a "$SUMMARY"
# shellcheck disable=SC2086
xcodebuild -project FairyStudio.xcodeproj -scheme FairyStudio-Verify -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED" -resultBundlePath "$RESULTS/$STAMP-device.xcresult" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -parallel-testing-enabled NO \
  ${FAIRY_TEST_FILTER:-} test > "$test_log" 2>&1
status=$?
echo "exit=$status" | tee -a "$SUMMARY"
summarize "$test_log"
exit $status
