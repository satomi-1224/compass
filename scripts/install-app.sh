#!/bin/bash
# compass.app を常用の場所へ入れる。
#
# **`build/compass.app` は常用に向かない。** build-app.sh が毎回消して作り直すため、
# launchd が指す先が一瞬消える。固定の場所（`~/Applications/compass.app`）へ置いて
# そこから起動する。
#
# 使い方:
#   ./scripts/install-app.sh [debug|release]
#   COMPASS_APP=/path/to/compass.app ./scripts/install-app.sh
#
# やること:
#   1. アプリバンドルを組み立てる
#   2. 置き場所へ入れ替える（動いていれば止めてから）
#   3. launchd の登録があれば読み直させる

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

CONFIGURATION="${1:-release}"
# home-manager の `programs.compass.app` を既定から変えているなら、同じ場所を指すよう
# `COMPASS_APP` を渡す。ずれると launchd が居ない実行ファイルを起動し続ける。
DESTINATION="${COMPASS_APP:-$HOME/Applications/compass.app}"
LABEL="org.nix-community.home.compass"
AGENT="gui/$(id -u)/$LABEL"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

"$REPO_ROOT/scripts/build-app.sh" "$CONFIGURATION" || exit 1

echo "==> 入れ替え: ${DESTINATION}"

# **plist が無いなら bootout してはいけない。** 戻す手段が無くなり、登録を消した
# だけで終わる。plist があるときに限って外す。
CAN_RESTORE=0
if [ -f "$PLIST" ]; then
  CAN_RESTORE=1
fi

if [ "$CAN_RESTORE" = "1" ] && launchctl print "$AGENT" >/dev/null 2>&1; then
  echo "    launchd の登録を一旦外す"
  launchctl bootout "$AGENT" || echo "    bootout が失敗した" >&2
  sleep 2

  # **外せていないなら差し替えない。** `KeepAlive = true` で動き続けている
  # ところへバンドルを差し替えると、署名の検証に失敗して落ちる。
  if launchctl print "$AGENT" >/dev/null 2>&1; then
    cat >&2 <<MSG
エラー: launchd の登録を外せなかった。動いているまま差し替えると落ちるので中断する。
       手で外してから再実行する:
         launchctl bootout $AGENT
MSG
    exit 1
  fi
fi

if pgrep -f "$DESTINATION/Contents/MacOS/compass" >/dev/null; then
  echo "    動いている compass を止める"
  pkill -INT -f "$DESTINATION/Contents/MacOS/compass" || true
  sleep 2
fi

# **消す前に置く。** `rm` のあとに `mv` が失敗すると、アプリが 1 つも残らない
# （登録も外れているので復帰の手がかりが無くなる）。
mkdir -p "$(dirname "$DESTINATION")"
STAGING="$DESTINATION.new"
BACKUP="$DESTINATION.old"
rm -rf "$STAGING" "$BACKUP"

if ! cp -R "$REPO_ROOT/build/compass.app" "$STAGING"; then
  rm -rf "$STAGING"
  echo "コピーに失敗した。元のアプリはそのまま残っている。" >&2
  exit 1
fi

if [ -e "$DESTINATION" ]; then
  mv "$DESTINATION" "$BACKUP"
fi
if ! mv "$STAGING" "$DESTINATION"; then
  echo "差し替えに失敗した。元のアプリへ戻す。" >&2
  if [ -e "$BACKUP" ]; then
    mv "$BACKUP" "$DESTINATION"
  fi
  rm -rf "$STAGING"
  exit 1
fi
rm -rf "$BACKUP"

# 外した登録を戻す。登録できない環境（Nix を使っていない場合）は open で上げる。
if [ "$CAN_RESTORE" = "1" ]; then
  echo "==> launchd へ登録して起動する"
  # **bootout の直後に bootstrap してはいけない。** bootout は完全に外れる前に
  # 返るため「Operation already in progress」で落ちる。間を置き、それでも
  # 失敗したら直接起動へ逃がす（`set -e` で黙って止まると、何も動いていない
  # 状態で終わってしまう）。
  launchctl bootout "$AGENT" 2>/dev/null || true
  sleep 2
  if ! launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
    echo "    launchd への登録に失敗した。直接起動する" >&2
    open "$DESTINATION"
  fi
else
  echo "==> launchd の登録が無いので直接起動する"
  open "$DESTINATION"
fi

sleep 3
if pgrep -f "$DESTINATION/Contents/MacOS/compass" >/dev/null; then
  echo "==> 完了。${DESTINATION} で稼働中"
else
  echo "==> 起動を確認できなかった。ログ: ~/Library/Logs/compass.log" >&2
  exit 1
fi
