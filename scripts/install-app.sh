#!/bin/bash
# compass.app を常用の場所へ入れる。
#
# **`build/compass.app` は常用に向かない。** build-app.sh が毎回消して作り直すため、
# launchd が指す先が一瞬消える。固定の場所（`~/Applications/compass.app`）へ置いて
# そこから起動する。
#
# 使い方:
#   ./scripts/install-app.sh [debug|release]
#
# やること:
#   1. アプリバンドルを組み立てる
#   2. ~/Applications/compass.app へ入れ替える（動いていれば止めてから）
#   3. launchd の登録があれば読み直させる

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

CONFIGURATION="${1:-release}"
DESTINATION="$HOME/Applications/compass.app"
# home-manager の launchd.agents が付けるラベル。
LABEL="org.nix-community.home.compass"
AGENT="gui/$(id -u)/$LABEL"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

"$REPO_ROOT/scripts/build-app.sh" "$CONFIGURATION" || exit 1

echo "==> 入れ替え: ${DESTINATION}"
# 動いているものは止める。バンドルを差し替えると署名の検証に失敗して落ちる。
#
# **`bootout` したら必ず `bootstrap` で戻す。** 戻さないと launchd の登録が消えた
# ままになり、以後 `kickstart` が「サービスが無い」で失敗する。
#
# **plist が無いなら bootout してはいけない。** 戻す手段が無くなり、登録を消した
# だけで終わる。plist があるときに限って外す。
CAN_RESTORE=0
if [ -f "$PLIST" ]; then
  CAN_RESTORE=1
fi

if [ "$CAN_RESTORE" = "1" ] && launchctl print "$AGENT" >/dev/null 2>&1; then
  echo "    launchd の登録を一旦外す"
  launchctl bootout "$AGENT" 2>/dev/null || true
  sleep 2
fi
if pgrep -f "$DESTINATION/Contents/MacOS/compass" >/dev/null; then
  echo "    動いている compass を止める"
  pkill -INT -f "$DESTINATION/Contents/MacOS/compass" || true
  sleep 2
fi

# **先に隣へ置いてから差し替える。** 消してからコピーすると、途中で失敗した時に
# アプリが 1 つも残らない（登録も外れているので復帰の手がかりが無くなる）。
mkdir -p "$HOME/Applications"
STAGING="$DESTINATION.new"
rm -rf "$STAGING"
cp -R "$REPO_ROOT/build/compass.app" "$STAGING"
rm -rf "$DESTINATION"
mv "$STAGING" "$DESTINATION"

# 外した登録を戻す。登録できない環境（Nix を使っていない場合）は open で上げる。
if [ "$CAN_RESTORE" = "1" ]; then
  echo "==> launchd へ登録して起動する"
  launchctl bootout "$AGENT" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
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
