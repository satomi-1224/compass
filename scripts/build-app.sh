#!/bin/bash
# compass.app を組み立てる。
#
# アクセシビリティ権限は**コード署名の同一性に紐づく**（requirements.md 7.1）。
# 素の実行ファイルではなく .app バンドルにして、固定の署名 ID を与える必要がある。
#
# 使い方: ./scripts/build-app.sh [debug|release]

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

CONFIGURATION="${1:-release}"
SIGNING_IDENTITY="${COMPASS_SIGNING_IDENTITY:-compass-dev}"
BUNDLE_ID="local.compass"

echo "==> ビルド ($CONFIGURATION)"
swift build -c "$CONFIGURATION"

# --show-bin-path は進捗行を混ぜて出すことがあるので最終行だけ取る。
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path | tail -1)/compass"
if [ ! -x "$BIN_PATH" ]; then
  echo "実行ファイルが見つからない: $BIN_PATH" >&2
  exit 1
fi

APP="$REPO_ROOT/build/compass.app"
echo "==> バンドル組み立て: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$REPO_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN_PATH" "$APP/Contents/MacOS/compass"

echo "==> 署名"
# **`-v` を付けない。** `-v` は「コード署名ポリシーで有効」なものだけを出すため、
# 信頼設定をしていない自己署名証明書が除外される。見落とすと黙って ad-hoc へ
# 落ちてしまい、この署名方式が防ごうとしている「リビルドで権限が外れる」を招く。
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGNING_IDENTITY\""; then
  codesign --force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
  echo "    署名 ID: ${SIGNING_IDENTITY}（権限はビルドをまたいで維持される）"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  cat <<'MSG'
    署名 ID: ad-hoc

    警告: ad-hoc 署名の designated requirement は cdhash だけなので、再ビルドすると
    アクセシビリティ権限が外れて再許可が必要になる。
    ./scripts/make-signing-cert.sh で固定の署名 ID を作ると回避できる。
MSG
fi

echo "==> 完了: $APP"
echo "    常駐起動: open $APP"
echo "    前景実行: $APP/Contents/MacOS/compass   （ログが端末に出る。終了は Ctrl-C）"
