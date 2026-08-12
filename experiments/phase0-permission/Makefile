# Phase 0 検証用ビルド。
#
# 検証したい軸は「署名の付け方」。ad-hoc だとリビルドで cdhash が変わり権限が外れ、
# 固定の署名 ID なら維持される — という仮説を実測で確かめるため、どちらでも
# ビルドできるようにしてある。配置は常にコピー（パス固定）で行う。

APP_NAME  := compass-phase0
BUNDLE_ID := local.compass-phase0

BUILD_DIR ?= build
APP       := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS  := $(APP)/Contents

INSTALL_DIR ?= $(HOME)/Applications
INSTALLED   := $(INSTALL_DIR)/$(APP_NAME).app

SWIFTC      ?= swiftc
SWIFT_FLAGS ?= -O -target arm64-apple-macos14.0

# auto    : SIGN_IDENTITY があれば使い、無ければ ad-hoc に落ちる（既定）
# adhoc   : 強制的に ad-hoc 署名する（tasks.md 案B の実測用）
# identity: 強制的に SIGN_IDENTITY で署名する（無ければ失敗する）
# linker  : swiftc / ld が付けた署名のまま、バンドル署名をしない
SIGN_MODE     ?= auto
SIGN_IDENTITY ?= compass-dev

CERT_SCRIPT := ../../scripts/make-signing-cert.sh
LOG         := $(HOME)/Library/Logs/compass-phase0.log

.PHONY: app install run status log cert tcc-reset clean help

help:
	@echo 'cert       自己署名の固定証明書 $(SIGN_IDENTITY) を作る（一度だけ）'
	@echo 'app        .app をビルドする（SIGN_MODE=auto|adhoc|identity|linker）'
	@echo 'install    ~/Applications へコピー配置する（パス固定）'
	@echo 'run        配置済みの .app を起動する'
	@echo 'status     配置先の署名情報と designated requirement を表示する'
	@echo 'log        検証ログを表示する'
	@echo 'tcc-reset  付与済みのアクセシビリティ権限を取り消す（検証のやり直し用）'
	@echo 'clean      build/ を消す'

cert:
	$(CERT_SCRIPT) $(SIGN_IDENTITY)

# 毎回組み直す。mtime で判定すると、署名 ID を作った後に再署名されないといった
# 取りこぼしが起きる（実際に踏んだ）。ビルドは数秒で終わる。
app:
	rm -rf "$(APP)"
	mkdir -p "$(CONTENTS)/MacOS"
	cp Info.plist "$(CONTENTS)/Info.plist"
	$(SWIFTC) $(SWIFT_FLAGS) -o "$(CONTENTS)/MacOS/$(APP_NAME)" main.swift
	@case "$(SIGN_MODE)" in \
	  auto) \
	    if security find-identity -v -p codesigning 2>/dev/null | grep -q '"$(SIGN_IDENTITY)"'; then \
	      codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" "$(APP)"; \
	      echo "sign: $(SIGN_IDENTITY)（権限はリビルドをまたいで維持される見込み）"; \
	    else \
	      codesign --force --sign - --identifier "$(BUNDLE_ID)" "$(APP)"; \
	      echo "sign: ad-hoc（$(SIGN_IDENTITY) が無い。make cert で作れる）"; \
	    fi ;; \
	  adhoc) \
	    codesign --force --sign - --identifier "$(BUNDLE_ID)" "$(APP)"; \
	    echo "sign: ad-hoc（強制）" ;; \
	  identity) \
	    codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" "$(APP)"; \
	    echo "sign: $(SIGN_IDENTITY)（強制）" ;; \
	  linker) \
	    echo "sign: skipped（linker の署名のまま）" ;; \
	  *) \
	    echo "SIGN_MODE が不正: $(SIGN_MODE)" >&2; exit 1 ;; \
	esac
	@echo "built: $(APP)"

# パスを固定するためコピーで配置する。
# 動いているものは先に止める。バンドルを差し替えると署名の検証に失敗して落ちる。
install: app
	@pkill -f "$(INSTALLED)/Contents/MacOS/$(APP_NAME)" 2>/dev/null && sleep 1 || true
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALLED)"
	cp -R "$(APP)" "$(INSTALLED)"
	@echo "installed: $(INSTALLED)"

run:
	open "$(INSTALLED)"

status:
	@echo "--- path ---"
	@ls -ld "$(INSTALLED)" 2>/dev/null || echo "未配置: $(INSTALLED)"
	@echo "--- codesign ---"
	@codesign -dvvv "$(INSTALLED)" 2>&1 \
	  | grep -E 'Identifier=|TeamIdentifier=|Authority=|^CDHash=|Signature=' || true
	@echo "--- designated requirement ---"
	@echo "（TCC がアプリを同一と判断する条件。cdhash が出るなら内容変更で権限が外れる）"
	@codesign -d -r- "$(INSTALLED)" 2>&1 | grep '^designated' || true

log:
	@test -f "$(LOG)" && cat "$(LOG)" || echo "ログなし: $(LOG)"

# 検証をやり直すときに使う。付与済みの権限を取り消す。
tcc-reset:
	tccutil reset Accessibility $(BUNDLE_ID)

clean:
	rm -rf "$(BUILD_DIR)"
