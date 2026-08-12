#!/bin/bash
# テストを走らせる。Xcode の無い環境向けのフラグは env.sh が組む。
#
# 使い方: ./scripts/test.sh [swift test への追加引数]

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

if [ ${#COMPASS_TEST_FLAGS[@]} -gt 0 ]; then
  swift test "${COMPASS_TEST_FLAGS[@]}" "$@"
else
  swift test "$@"
fi
