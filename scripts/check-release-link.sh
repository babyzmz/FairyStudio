#!/usr/bin/env bash
# 校验 DevFixtures（夹具引擎）只进入 Verify-Debug 构建：
#   - Release（产品配置，iOS 27.0）与 Verify-Release 的 App 链接清单与二进制中都不得出现 DevFixtures；
#   - Verify-Debug 必须包含（正向对照，证明检查方法有效）。
# 当前环境没有 iOS 27 SDK / 模拟器，Release 以 generic iOS Simulator 目的地构建（Xcode 会给出部署目标超出 SDK 范围的警告）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$ROOT/verification/logs"
mkdir -p "$LOG_DIR"
DERIVED="${FAIRY_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/FairyStudio-verify}"
LOG="$LOG_DIR/$STAMP-release-link.log"
APP_NAME="$(sed -nE 's/^FAIRY_PRODUCT_NAME = (.*)$/\1/p' Config/Brand.xcconfig)"

if [[ "${FAIRY_SKIP_GENERATE:-0}" != "1" ]]; then
  xcodegen generate >> "$LOG" 2>&1
fi

failures=0

# $1 scheme, $2 configuration, $3 期望（absent|present）
check() {
  local scheme="$1" config="$2" expect="$3"
  echo "== $scheme / $config（期望 DevFixtures $expect）" | tee -a "$LOG"
  if ! xcodebuild -project FairyStudio.xcodeproj -scheme "$scheme" -configuration "$config" \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" build >> "$LOG" 2>&1; then
    echo "FAIL：构建失败（见 $LOG）" | tee -a "$LOG"
    failures=$((failures + 1))
    return
  fi
  local products="$DERIVED/Build/Products/$config-iphonesimulator"
  local app="$products/$APP_NAME.app"
  local linklist
  linklist="$(find "$DERIVED/Build/Intermediates.noindex/FairyStudio.build/$config-iphonesimulator/FairyStudio.build" -name '*.LinkFileList' 2>/dev/null | head -1)"
  local in_linklist=0 symbols=0 ldflags=0
  if [[ -n "$linklist" ]] && grep -q "DevFixtures" "$linklist"; then in_linklist=1; fi
  # Debug 构建的代码位于 *.debug.dylib；Release 位于主可执行文件。两者都检查。
  for binary in "$app/$APP_NAME" "$app/$APP_NAME.debug.dylib"; do
    if [[ -f "$binary" ]]; then
      local count
      count="$(nm -a "$binary" 2>/dev/null | grep -c -E 'DevFixtures|FixtureEngine|FixtureRunHandle' || true)"
      symbols=$((symbols + count))
    fi
  done
  if xcodebuild -project FairyStudio.xcodeproj -target FairyStudio -configuration "$config" -showBuildSettings 2>/dev/null \
      | grep -E '^\s*OTHER_LDFLAGS = ' | grep -q "DevFixtures"; then ldflags=1; fi
  echo "linkfilelist_contains=$in_linklist other_ldflags_contains=$ldflags binary_symbols=$symbols" | tee -a "$LOG"
  local present=0
  if [[ $symbols -gt 0 || $ldflags -eq 1 || $in_linklist -eq 1 ]]; then present=1; fi
  if [[ "$expect" == "absent" && $present -eq 1 ]]; then
    echo "FAIL：$config 链接了 DevFixtures" | tee -a "$LOG"; failures=$((failures + 1))
  elif [[ "$expect" == "present" && $symbols -eq 0 ]]; then
    echo "FAIL：$config 应含 DevFixtures（正向对照失败，检查方法可能无效）" | tee -a "$LOG"; failures=$((failures + 1))
  else
    echo "OK" | tee -a "$LOG"
  fi
}

check FairyStudio Release absent
check FairyStudio-Verify Verify-Release absent
check FairyStudio Debug absent
check FairyStudio-Verify Verify-Debug present

echo "failures=$failures（日志：$LOG）" | tee -a "$LOG"
exit $failures
