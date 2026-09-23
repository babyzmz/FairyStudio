#!/usr/bin/env bash
# 把 docs/ENVIRONMENT.md 中的环境核验脚本化，输出到 verification/env-<date>.log。
# 只读：不修改系统设置、不安装任何东西。签名身份只输出数量与 Team ID，不输出姓名。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p verification
LOG="verification/env-$(date +%Y-%m-%d).log"

section() {
  printf '\n## %s\n' "$1" >> "$LOG"
}

run() {
  printf '$ %s\n' "$*" >> "$LOG"
  "$@" >> "$LOG" 2>&1 || printf '(exit %s)\n' "$?" >> "$LOG"
}

: > "$LOG"
echo "# Fairy Studio 环境核验 $(date '+%Y-%m-%d %H:%M:%S %z')" >> "$LOG"

section "macOS"
run sw_vers

section "Xcode / Swift"
run xcode-select -p
run xcodebuild -version
run swift --version
run xcodebuild -showsdks

section "模拟器运行时与设备"
run xcrun simctl list runtimes
run xcrun simctl list devices available

section "已配对实机（devicectl；只输出型号、系统与状态，不输出设备名）"
devices_json="$(mktemp -t fairy-devices)"
if xcrun devicectl list devices --json-output "$devices_json" > /dev/null 2>&1; then
  python3 - "$devices_json" >> "$LOG" 2>&1 <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for device in data.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    props = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    print(f"{hardware.get('marketingName', '?')} ({hardware.get('productType', '?')}) "
          f"os={props.get('osVersionNumber', '?')} build={props.get('osBuildUpdate', '?')} "
          f"pairing={connection.get('pairingState', '?')} tunnel={connection.get('tunnelState', '?')} "
          f"ddiServicesAvailable={props.get('ddiServicesAvailable', '?')} developerMode={props.get('developerModeStatus', '?')}")
PY
else
  echo "devicectl 不可用" >> "$LOG"
fi
rm -f "$devices_json"

section "签名身份（只统计数量与 Team ID）"
identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
printf '有效身份数：%s\n' "$(printf '%s\n' "$identities" | grep -c 'Apple Development' || true)" >> "$LOG"
printf '%s\n' "$identities" | sed -nE 's/.*\(([A-Z0-9]{10})\)".*/Team \1/p' | sort -u >> "$LOG"
profiles="$HOME/Library/MobileDevice/Provisioning Profiles"
printf 'provisioning profile 数：%s\n' "$(find "$profiles" -name '*.mobileprovision' 2>/dev/null | wc -l | tr -d ' ')" >> "$LOG"

section "XcodeGen"
run which xcodegen
run xcodegen --version

section "FoundationModels（iOS Simulator SDK swiftinterface）"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
FM="$SDK/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64-apple-ios-simulator.swiftinterface"
printf 'swiftinterface: %s\n' "$FM" >> "$LOG"
if [[ -f "$FM" ]]; then
  for symbol in "final public class SystemLanguageModel" "final public class LanguageModelSession" "public enum UnavailableReason" \
                "case deviceNotEligible" "case appleIntelligenceNotEnabled" "case modelNotReady" "public enum GenerationError" \
                "case exceededContextWindowSize" "case assetsUnavailable" "case guardrailViolation" "case unsupportedGuide" \
                "case unsupportedLanguageOrLocale" "case decodingFailure" "case rateLimited" "case concurrentRequests" "case refusal" \
                "final public var isResponding" "func streamResponse(to prompt: Swift.String" "func supportsLocale" "maximumResponseTokens"; do
    printf '%-55s %s\n' "$symbol" "$(grep -c -F "$symbol" "$FM")" >> "$LOG"
  done
  printf '上下文容量 / token 计数 API（contextSize|tokenCount|contextWindow 声明）：%s\n' \
    "$(grep -c -E 'var contextSize|func tokenCount|var contextWindow' "$FM")" >> "$LOG"
else
  echo "FoundationModels swiftinterface 不存在" >> "$LOG"
fi

section "Private Cloud Compute 符号（iOS Simulator SDK 全部 swiftinterface）"
pcc_hits="$(grep -rl "PrivateCloudCompute" "$SDK/System/Library/Frameworks" --include='*.swiftinterface' 2>/dev/null | wc -l | tr -d ' ')"
printf '含 PrivateCloudCompute 的 swiftinterface 文件数：%s\n' "$pcc_hits" >> "$LOG"

section "Swift 包依赖（Package.resolved）"
run grep -A6 '"identity" : "swift-syntax"' Packages/FairyCore/Package.resolved

echo "写入 $LOG"
