#!/bin/bash
# アプリのアイコンを作る。
#
# 元画像を macOS のアイコングリッド（1024 のキャンバスに 824 の角丸四角形）へ収め、
# 各サイズを書き出して `Resources/AppIcon.icns` にまとめる。
#
# 使い方:
#   ./scripts/make-icon.sh <元画像>
#
# 作り直したら `./scripts/build-app.sh` でバンドルへ入る。

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

SOURCE="${1:-}"
if [ -z "$SOURCE" ] || [ ! -f "$SOURCE" ]; then
  echo "使い方: ./scripts/make-icon.sh <元画像>" >&2
  exit 2
fi

WORK="$(mktemp -d /tmp/compass-icon.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 角丸と余白を付ける"
swift "$REPO_ROOT/scripts/make-icon.swift" "$SOURCE" "$WORK/icon.png"

echo "==> 各サイズを書き出す"
mkdir -p "$WORK/AppIcon.iconset"
# iconutil は名前で大きさを判断するので、この綴りから外れると失敗する。
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK/icon.png" \
    --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$WORK/icon.png" \
    --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done

echo "==> icns へまとめる"
mkdir -p "$REPO_ROOT/Resources"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$REPO_ROOT/Resources/AppIcon.icns"

# README で使う小さい版も一緒に作る。
mkdir -p "$REPO_ROOT/docs"
sips -z 256 256 "$WORK/icon.png" --out "$REPO_ROOT/docs/icon.png" >/dev/null

ls -lh "$REPO_ROOT/Resources/AppIcon.icns" "$REPO_ROOT/docs/icon.png" |
  awk 'NF>5 {print "    " $9 " (" $5 ")"}'
echo "==> 完了。./scripts/build-app.sh でバンドルへ入る"
