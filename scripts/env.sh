#!/bin/bash
# 共通ビルド環境。各スクリプトから source して使う。
#
# このマシンには Xcode が入っておらず Command Line Tools のみのため、SPM は
# Testing.framework とその依存 lib_TestingInterop.dylib を自動では見つけられない。
# 探索パスと rpath を明示的に渡す必要がある。
#
#   Testing.framework       : $DEV_FRAMEWORKS
#   lib_TestingInterop.dylib: $DEV_LIB
#
# Xcode を入れると Testing.framework の位置が変わって COMPASS_TEST_FLAGS が空になるが、
# その場合は SPM が自力で解決できるので素の `swift test` で動く。

set -eo pipefail
set -u

if ! DEV_ROOT="$(xcode-select -p 2>/dev/null)"; then
  echo "xcode-select -p に失敗した。Command Line Tools が入っているか確認する。" >&2
  exit 1
fi

DEV_FRAMEWORKS="$DEV_ROOT/Library/Developer/Frameworks"
DEV_LIB="$DEV_ROOT/Library/Developer/usr/lib"

# macOS の /bin/bash は 3.2 で、set -u のもとでは空配列の "${arr[@]}" 展開が
# unbound variable エラーになる。要素数で分岐すること（${#arr[@]} は 3.2 でも安全）。
COMPASS_TEST_FLAGS=()
if [ -d "$DEV_FRAMEWORKS/Testing.framework" ]; then
  COMPASS_TEST_FLAGS=(
    --disable-xctest
    -Xswiftc -F -Xswiftc "$DEV_FRAMEWORKS"
    -Xlinker -F -Xlinker "$DEV_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$DEV_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$DEV_LIB"
  )
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
