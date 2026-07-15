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
