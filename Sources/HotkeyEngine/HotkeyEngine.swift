import Carbon.HIToolbox
import CompassCore

/// トリガー + 単キーのグローバルホットキーを登録する。
///
/// **UI に依存しない**（requirements.md 2章）。押されたことを `onTrigger` で知らせる
/// だけで、何をするかは呼び出し側が決める。
///
/// Carbon の `RegisterEventHotKey` を使う。CGEvent の event tap と違って
/// **アクセシビリティ権限が要らず**、他アプリのキー入力を覗かない。登録済みの
/// 組み合わせが押されたときだけ通知が来る。
@MainActor
public final class HotkeyEngine {

    /// 登録したキーが押された。
    public var onTrigger: (@MainActor (HotkeyBinding) -> Void)?

    private struct Registration {
        var binding: HotkeyBinding
        var ref: EventHotKeyRef
    }

    /// ホットキーを識別する 4 文字コード（`cmps`）。
    ///
    /// **イベントハンドラで必ず突き合わせる。** ハンドラは
    /// `GetApplicationEventTarget()` に付くため、プロセス内の別のフレームワークが
    /// 登録したホットキーのイベントもここへ届く。
    /// nonisolated にしておく。イベントハンドラは MainActor の外で走る。
    fileprivate nonisolated static let signature: OSType = 0x636D_7073

    private let log: Log
    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    public init(log: Log = .shared) {
        self.log = log
    }

    isolated deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    /// 現在登録している数。
    public var registeredCount: Int { registrations.count }

    // MARK: - 登録

    /// 設定を適用する。**毎回すべて登録し直す。**
    ///
    /// 差分を取って部分的に付け外しすると、トリガーが変わった場合に古い登録が残る。
    /// 登録は数個なので作り直すほうが単純で確実。
    ///
    /// - Returns: 登録できなかったキーの理由。呼び出し側が通知する。
    @discardableResult
    public func apply(_ hotkeys: Hotkeys) -> [ConfigIssue] {
        unregisterAll()
        installEventHandler()

        var failures: [ConfigIssue] = []
        for binding in hotkeys.bindings {
            if let issue = register(binding, trigger: hotkeys.trigger) {
                failures.append(issue)
            }
        }

        log.debug("ホットキーを登録: \(registrations.count)/\(hotkeys.bindings.count) 件")
        return failures
    }

    public func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    private func register(_ binding: HotkeyBinding, trigger: Modifiers) -> ConfigIssue? {
        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            trigger.carbonFlags,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            let label = "\(trigger.symbols)\(binding.key.uppercased())"
            return ConfigIssue(
                file: .hotkeys,
                detail: "\(label) を登録できなかった（\(Self.describe(status))）"
            )
        }

        registrations[id] = Registration(binding: binding, ref: ref)
        return nil
    }

    private static func describe(_ status: OSStatus) -> String {
        switch status {
        case OSStatus(eventHotKeyExistsErr):
            "同じ組み合わせを他のアプリが既に使っている"
        case OSStatus(eventHotKeyInvalidErr):
            "キーの組み合わせが不正"
        default:
            "status \(status)"
        }
    }

    // MARK: - イベント

    private func installEventHandler() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // ハンドラは self より長生きしない（deinit で外す）ので unretained で渡す。
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handleHotkeyEvent,
            1,
            &eventType,
            context,
            &eventHandler
        )
        if status != noErr {
            log.error("ホットキーのイベントハンドラを登録できなかった（status \(status)）")
        }
    }

    /// Carbon のコールバックから呼ばれる。
    ///
    /// - Returns: 自分が登録したキーだったか。false ならイベントを次のハンドラへ渡す。
    fileprivate func handle(id: UInt32) -> Bool {
        guard let registration = registrations[id] else { return false }
        log.debug("ホットキー: \(registration.binding.key)")
        onTrigger?(registration.binding)
        return true
    }
}

/// Carbon に渡すコールバック。C 関数ポインタなのでキャプチャを持てない。
/// `self` は `InstallEventHandler` の userData 経由で受け取る。
///
/// **クロージャを代入したグローバル定数にはしない。** 初期化式が MainActor に
/// 触れると「nonisolated な文脈で MainActor 分離の既定値を使っている」として弾かれる。
/// 関数として書けばキャプチャを持たないまま C 関数ポインタへ渡せる。
private func handleHotkeyEvent(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    // **失敗しても `eventNotHandledErr` を返す。** それ以外の値を返すと Carbon は
    // 「処理した」と見なし、次のハンドラへ渡らずイベントを飲み込む。
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    // **自分が登録したものだけを扱う。** ハンドラは `GetApplicationEventTarget()` に
    // 付いているので、プロセス内の別のフレームワークや入力メソッドが登録した
    // ホットキーのイベントもここへ来る。id は 1 から順に振るだけなので、
    // 突き合わせないと衝突した他人のキーで自分のアクションが走る。
    guard hotKeyID.signature == HotkeyEngine.signature else {
        return OSStatus(eventNotHandledErr)
    }

    // **ポインタと構造体をクロージャへ渡さない。** non-Sendable な値を送ると
    // data race として弾かれる。`HotkeyEngine` は @MainActor なので暗黙に Sendable、
    // `id` は UInt32。どちらも先に取り出しておけば渡せる。
    let engine = Unmanaged<HotkeyEngine>.fromOpaque(context).takeUnretainedValue()
    let id = hotKeyID.id

    // Carbon のイベントディスパッチはメインスレッドで走る。
    let handled = MainActor.assumeIsolated {
        engine.handle(id: id)
    }
    // 知らない id を noErr で返すと、次のハンドラへ渡らずイベントを飲み込む。
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
