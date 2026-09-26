#!/bin/zsh
# macOS 27 下 ~/Desktop 内的文件带 com.apple.provenance 扩展属性，codesign 会报
# "resource fork, Finder information, or similar detritus not allowed"，导致 swift test 失败。
# 因此 SwiftPM 的构建目录统一放到 Desktop 之外；按仓库路径区分，避免多个 worktree 互相干扰。
# 用法：scripts/spm.sh test [--filter X] / scripts/spm.sh build ...
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="$(echo "$ROOT" | shasum | cut -c1-12)"
SCRATCH="$HOME/Library/Caches/FairyStudio/spm-$KEY"
cd "$ROOT/Packages/FairyCore"
exec swift "$@" --scratch-path "$SCRATCH"
