#!/bin/bash
# 開発用の自己署名コード署名証明書 "compass-dev" を作る。一度だけ実行すればよい。
#
# なぜ必要か:
#   アクセシビリティ権限はコード署名の同一性に紐づく。ad-hoc 署名（codesign -s -）は
#   ビルドのたびに cdhash が変わるため、再ビルドすると権限が外れて再許可を求められる。
#   固定の署名 ID で署名し続ければ、designated requirement が
#   「identifier + 証明書」で決まるため、内容が変わっても権限は維持される。
#
#   Apple Developer アカウントは要らない。TeamIdentifier が not set の自己署名でも
#   権限は維持される（同一マシンの comet で実証済み）。
#
# 注意:
#   キーチェーンへの登録と信頼設定でパスワード入力を求められる。
#   GUI で行う場合は「キーチェーンアクセス > 証明書アシスタント > 証明書を作成」で
#   名前 compass-dev / 証明書のタイプ「コード署名」/ 自己署名ルート を選んでも同じ。
#
# 既に別プロジェクトの開発用証明書（comet-dev など）を持っているなら、
# それを SIGN_IDENTITY に渡して使い回してもよい。designated requirement は
# identifier と証明書の組で決まるため、別アプリと混ざることはない。

set -euo pipefail

IDENTITY="${1:-compass-dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "署名 ID \"$IDENTITY\" は既に存在する。何もしない。"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 鍵と証明書を生成"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$IDENTITY" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  2>/dev/null

# **空パスワードの p12 にしてはいけない。** macOS の openssl は LibreSSL で、
# 空パスワードで作った p12 は Apple の `security import` が MAC を検証できず
# 「MAC verification failed during PKCS12 import (wrong password?)」で失敗する。
# 使い捨ての乱数を使う。
# **`tr </dev/urandom | head` は使わない。** head が先に終わると tr が SIGPIPE で
# 落ち、`set -o pipefail` によってスクリプトが黙って終了する。
P12_PASSWORD="$(openssl rand -hex 16)"
openssl pkcs12 -export -out "$WORK/$IDENTITY.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout "pass:$P12_PASSWORD"

echo "==> キーチェーンに登録"
security import "$WORK/$IDENTITY.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security

# 署名するだけなら信頼設定は要らない（`codesign -s` は鍵があれば通る）。
# 付けておくと `codesign -v` での検証も通るが、**管理者パスワードの入力が必要**。
# 失敗しても署名はできるので、ここで止めない。
echo "==> 信頼設定（管理者パスワードを求められる。省略しても署名はできる）"
if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null
then
  echo "    信頼設定は省略した（署名には影響しない）"
fi

echo
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  cat <<MSG
完了。以降のビルドはこの ID で署名する。

次の2点に注意:

1. 初回の codesign でキーチェーンのアクセス許可ダイアログが出る。
   「常に許可」を選ぶこと。「許可」を選ぶとビルドのたびに聞かれる。

2. 署名 ID が変わるため、既に付与済みのアクセシビリティ権限は一度リセットする:
       tccutil reset Accessibility local.compass
       tccutil reset Accessibility local.compass-phase0
MSG
else
  echo "署名 ID を作成できなかった。キーチェーンアクセスの GUI から作成すること。" >&2
  exit 1
fi
