import Foundation
import Testing
@testable import BackupKit

/// 端末フォルダ名の決定ロジック（ADR-41・純関数部分）。
/// Keychain 永続化はロジックが薄いため対象外（フォルダ名の組み立てだけを固定する）。
@Suite("BackupDeviceIdentity (folder naming)")
struct BackupDeviceIdentityTests {

    @Test("表示名＋短IDでフォルダ名を組み立てる")
    func basic() {
        #expect(BackupDeviceIdentity.folderName(displayName: "iPhone", id: "3F2A8C") == "iPhone-3F2A8C")
        #expect(BackupDeviceIdentity.folderName(displayName: "iPad", id: "AB12CD") == "iPad-AB12CD")
    }

    @Test("非英数字はサニタイズされる（スペース・記号・日本語・絵文字）")
    func sanitization() {
        #expect(BackupDeviceIdentity.folderName(displayName: "Taro's iPhone", id: "AA11BB") == "Taro-s-iPhone-AA11BB")
        #expect(BackupDeviceIdentity.folderName(displayName: "太郎のiPhone 📱", id: "AA11BB") == "iPhone-AA11BB")
        // 全部消えたらフォールバック名
        #expect(BackupDeviceIdentity.folderName(displayName: "📱🎉", id: "AA11BB") == "device-AA11BB")
        #expect(BackupDeviceIdentity.folderName(displayName: "", id: "AA11BB") == "device-AA11BB")
    }

    @Test("連続する区切りは 1 つに潰し、前後の区切りは落とす")
    func collapseDashes() {
        #expect(BackupDeviceIdentity.folderName(displayName: "--My  Phone--", id: "AA11BB") == "My-Phone-AA11BB")
    }

    @Test("長い表示名は 20 文字に制限される")
    func lengthLimit() {
        let long = String(repeating: "a", count: 50)
        let name = BackupDeviceIdentity.folderName(displayName: long, id: "AA11BB")
        #expect(name == String(repeating: "a", count: 20) + "-AA11BB")
    }

    @Test("generateID は 6 文字の hex")
    func idShape() {
        let id = BackupDeviceIdentity.generateID()
        #expect(id.count == 6)
        #expect(id.allSatisfy { $0.isHexDigit })
    }
}

/// ⚠️ 実障害（CI が赤くなった）: Keychain が使えない環境では `currentID()` が
/// **呼ぶたびに新しい ID** を返していた。ID はバックアップ／共有のフォルダ名そのものなので、
/// 保存先が毎回変わり、ファイルが端末フォルダの数だけ散らばる。
@Suite("端末 ID の安定性（Keychain が使えない環境）")
struct BackupDeviceIDStabilityTests {

    /// Keychain が読めも書けもしない環境（CI・サンドボックス）を模す。
    private final class FallbackBox { var value: String? }

    @Test("Keychain が使えなくても 2 回目以降は同じ ID を返す")
    func idIsStableWithoutKeychain() {
        let box = FallbackBox()
        var generated = 0
        func resolve() -> String {
            BackupDeviceIdentity.resolveID(
                readKeychain: { nil },                  // 読めない
                writeKeychain: { _ in },                // 書けない（失敗を握り潰す本番と同じ）
                readFallback: { box.value },
                writeFallback: { box.value = $0 },
                generate: { generated += 1; return "ID\(generated)" })
        }
        let first = resolve()
        let second = resolve()
        #expect(first == second, "呼ぶたびに ID が変わる（保存先が毎回変わる）: \(first) / \(second)")
        #expect(generated == 1, "退避が効かず毎回生成している")
    }

    @Test("Keychain に値があればそれを使い、退避にも控える")
    func keychainValueWins() {
        let box = FallbackBox()
        var written: String?
        let id = BackupDeviceIdentity.resolveID(
            readKeychain: { "KEEP" }, writeKeychain: { written = $0 },
            readFallback: { box.value }, writeFallback: { box.value = $0 },
            generate: { "NEW" })
        #expect(id == "KEEP")
        #expect(box.value == "KEEP", "Keychain が後で使えなくなると ID を失う")
        #expect(written == nil, "不要な書き戻しをしている")
    }

    @Test("Keychain が復活したら退避の値を書き戻す")
    func fallbackIsRestoredToKeychain() {
        let box = FallbackBox()
        box.value = "OLD"
        var written: String?
        let id = BackupDeviceIdentity.resolveID(
            readKeychain: { nil }, writeKeychain: { written = $0 },
            readFallback: { box.value }, writeFallback: { box.value = $0 },
            generate: { "NEW" })
        #expect(id == "OLD", "退避があるのに新規生成した")
        #expect(written == "OLD", "Keychain へ書き戻していない")
    }

    /// 実装（メモ化）側の確認。Keychain の有無に関わらず、同一プロセスでは一定であること。
    @Test("同じプロセス内で端末フォルダ名は変わらない")
    func folderNameIsStableInProcess() {
        #expect(BackupDeviceIdentity.currentFolderName()
            == BackupDeviceIdentity.currentFolderName())
    }
}
