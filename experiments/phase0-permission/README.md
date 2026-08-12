# Phase 0: アクセシビリティ権限の検証

クリップボード履歴とスニペットのペーストは `CGEvent` でキーストロークを送るため、
アクセシビリティ権限が必須。**リビルドして入れ替えたあとも権限が保持されるか**を
実機で確かめる。ここが破綻すると配布方式かビルド方式の再検討が必要になる。

要件は [../../docs/requirements.md](../../docs/requirements.md) の 7.1、
タスクは [../../docs/tasks.md](../../docs/tasks.md) の Phase 0 を参照。

## 検証アプリの仕組み

`Cmd+V` を**自分自身のテキストフィールドへ**送り、マーカー文字列が届いたかで判定する。
他アプリへの副作用なしに HID レベルの送出を試せる。送出経路（`cghidEventTap`）は
システム全体を通るため、権限がなければ届かない。

実行するたび `~/Library/Logs/compass-phase0.log` に**追記**する。
リビルド前後を並べて比較できることが検証の value そのものなので、消さない。

記録する項目:

| 項目 | 何を見るためのものか |
|---|---|
| `executable` / `executable.resolved` | シンボリックリンク配置のとき realpath が nix store を指すか |
| `executable.inode` | 入れ替えで実体が変わったか |
| `signing.cdhash` | リビルドでハッシュが変わったか |
| `signing.designated` | **TCC が「同じアプリ」と判断する条件式**（下記） |
| `ax.trusted` | TCC の権限が生きているか |
| `paste.result` | 実際にキーストロークが届いたか |

## 着手前に判明していること

同一マシンで動いている [comet](https://github.com/satomi-1224/comet)（自作の
タイリングウィンドウマネージャ）が同じ問題を通過済みで、結論が出ている。

### 1. designated requirement が署名方式で変わる

TCC はアプリの同一性を designated requirement で判断する。実測:

```
ad-hoc 署名   designated => cdhash H"08e26d983666ae1e5ca57e3c0a169101c436e188"
固定証明書    designated => identifier "local.comet"
                            and certificate leaf = H"768eb2562c02ce0a3e5d626d656a71e41cba7827"
```

ad-hoc 署名は **cdhash だけ**で、identifier すら含まれない。バイナリが 1 バイト
変われば別アプリになる。固定証明書なら identifier と証明書の組で決まり、
どちらもリビルドで変わらないため同一と見なされる。

### 2. 自己署名で足りる。Apple Developer アカウントは要らない

comet は `TeamIdentifier=not set` の自己署名証明書で権限を維持している。
requirements.md 7.1 の案C は「安定した Team ID で署名する（Apple Developer
アカウントが必要）」としているが、**アカウントは不要**。

### 3. nix store に本体を置く方式は二重に成立しない

- nixpkgs の Swift は 5.10（実測）。Swift 6 を要求するコードは store の中で組めない
- store のパスは更新のたびに変わるため、そこから起動すると権限が毎回外れる

comet は本体を `~/Applications/` に置き、flake は**設定・自動起動・ログの置き場所**
だけを受け持つ形にしている。

## 検証手順

### 手順1: 固定証明書で権限が維持されることを確かめる（本命）

```bash
cd experiments/phase0-permission

# 1. 自己署名の固定証明書を作る（一度だけ。キーチェーンのパスワード入力あり）
make cert

# 2. ビルドして ~/Applications へコピー配置する
make install
make status          # designated requirement に certificate leaf が出ることを確認

# 3. 起動して権限を付与する
make run
#    → 「権限なし」と出て許可を求められる
#    → システム設定で compass-phase0 を許可し、アプリを終了して再度 make run
#    → PASS を確認する

# 4. コードを変えてリビルド・再配置する（main.swift に空行を足すだけでよい）
make install
make status          # cdhash が変わり、designated requirement は変わらないことを確認

# 5. 権限を再付与せずに起動する
make run
#    → PASS が出れば成功。これが Phase 0 の完了条件
```

初回の `codesign` でキーチェーンのアクセス許可ダイアログが出る。
**「常に許可」を選ぶ**。「許可」だとビルドのたびに聞かれる。

### 手順2: ad-hoc では権限が外れることを確かめる（対照。省略可）

designated requirement が cdhash だけであることは既に確認済みなので、
論理的には結論が出ている。記録として残す場合のみ実施する。

```bash
make tcc-reset                      # 手順1で付与した権限を取り消す
make install SIGN_MODE=adhoc
make run                            # 権限を付与して PASS を確認
make install SIGN_MODE=adhoc        # 再ビルド（cdhash が変わる）
make run                            # 権限が外れて「権限なし」になるはず
```

検証後は手順1の状態へ戻す（`make tcc-reset` → `make install` → 権限を再付与）。

## 結果

**固定証明書で権限は保持される。**（2026-08-13 実測、macOS 26.5.2 / arm64、Swift 6.3.2）

`make log` に全履歴が残っている。要点:

| 署名 | 操作 | `cdhash` | `inode` | `ax.trusted` | `paste` |
|---|---|---|---|---|---|
| `compass-dev` | 初回配置 → 権限を付与 | `db3add7c` | 8294379 | true | FAIL |
| `compass-dev` | リビルドして再配置 | `b0bfa767` | 8294828 | **true** | FAIL |
| `compass-dev` | Edit メニューを足して再配置 | `ea8df101` | 8294947 | **true** | **PASS** |

- cdhash は 3 回すべて変わり、実行ファイルの実体（inode）も入れ替わっている
- それでも `ax.trusted` は**一度も再付与せず** true のまま
- designated requirement は 3 回とも
  `identifier "local.compass-phase0" and certificate leaf = H"270b26e5…"` で不変

### 途中の FAIL は権限ではなくメニュー未実装が原因だった

**AppKit はキー等価物をメインメニューで解決する。** `NSApp.mainMenu` に Edit メニューが
無いと、`Cmd+V` の keyDown はビューまで届くのに `paste:` へ変換されず**何も起きない**。

診断がこれを示していた:

```
secure.input      false        secure input ではない
app.active        true         アプリはアクティブ
first.responder   NSTextView   フォーカスは正しい
keydown.observed  true    ←    送出した Cmd+V は届いている
paste.result      got empty    なのにペーストされない
```

`LSUIElement = true` でメニューバーを出さない compass 本体でも、`NSApp.mainMenu`
の設定自体は必要になる。requirements.md 7.4 に反映済み。

## 判定

- [x] 手順1 の step 5 で、権限を再付与せずに PASS が出た
- [x] 結論を requirements.md 7.1 に反映した
- [x] 配布方式を requirements.md 5.1 に確定した

手順2（ad-hoc の対照実験）は未実施。designated requirement が cdhash だけであることを
確認済みで結論が変わらないため、TCC のエントリを汚さずに済ませた。
