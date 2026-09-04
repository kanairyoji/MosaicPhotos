import Foundation
import Testing
@testable import BackupKit
import DropboxCore

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

// MARK: - 端末フォルダの付け方（二重化の防止）

/// ⚠️ 端末フォルダを二重に足すと `/Root/iPhone-XXXX/Backup/iPhone-XXXX/Backup/…` になり、
/// **同じ写真が別パスへ再アップロードされる**（台帳に無いパスなので未バックアップ扱い）。
/// 一覧には旧パスと新パスの両方が並び、「古い写真が急に増えた」ように見える。
/// ADR-175: 実保存先は `<root>/<端末>/Backup`、共有は `<root>/<端末>/Share`。
@Suite("端末フォルダの付与（ADR-175 の配置）")
struct DeviceBackupRootTests {

    @Test("ルートに端末フォルダと Backup を足す")
    func appendsDeviceAndBackup() {
        #expect(BackupEngine.deviceBackupRoot(for: "/MosaicPhotos", deviceFolder: "iPhone-8D1681")
                == "/MosaicPhotos/iPhone-8D1681/Backup")
    }

    /// ⚠️ 実装直後にこれが落ちた（`…/Backup/iPhone-X/Backup` と二重になった）。
    /// 結果が設定へ書き戻る経路が 1 つでもあれば、この二重化がそのまま再アップロードになる。
    @Test("既に配下のパスを渡しても二重にしない（冪等）")
    func idempotent() {
        let once = BackupEngine.deviceBackupRoot(for: "/MosaicPhotos", deviceFolder: "iPhone-8D1681")
        #expect(BackupEngine.deviceBackupRoot(for: once, deviceFolder: "iPhone-8D1681") == once,
                "二重に足すと同じ写真が別パスへ再アップロードされる")
        // 端末フォルダまでのパスを渡しても同じ答えになる。
        #expect(BackupEngine.deviceBackupRoot(for: "/MosaicPhotos/iPhone-8D1681",
                                              deviceFolder: "iPhone-8D1681") == once)
    }

    @Test("大小が違っても二重にしない")
    func caseInsensitive() {
        #expect(BackupEngine.deviceBackupRoot(for: "/mosaicphotos/iphone-8d1681",
                                              deviceFolder: "iPhone-8D1681")
                == "/mosaicphotos/iphone-8d1681/Backup")
        // 配下のパスを渡したときは末尾の `backup` を剥がして付け直すので、大小は正規形に揃う。
        // Dropbox はパスの大小を無視するので、二重化さえしなければよい（大小一致は求めない）。
        #expect(BackupEngine.deviceBackupRoot(for: "/mosaicphotos/iphone-8d1681/backup",
                                              deviceFolder: "iPhone-8D1681").lowercased()
                == "/mosaicphotos/iphone-8d1681/backup")
    }

    @Test("末尾のスラッシュや前後の空白を正規化する")
    func normalizesInput() {
        #expect(BackupEngine.deviceBackupRoot(for: " /MosaicPhotos/ ", deviceFolder: "iPhone-1")
                == "/MosaicPhotos/iPhone-1/Backup")
    }

    @Test("端末フォルダ名が空なら何も足さない")
    func emptyDeviceFolder() {
        #expect(BackupEngine.deviceBackupRoot(for: "/MosaicPhotos", deviceFolder: "")
                == "/MosaicPhotos")
    }

    /// 似た名前のフォルダを誤って「同じ」と見なさないこと。
    @Test("途中に同名があっても末尾でなければ足す")
    func onlySuffixCounts() {
        #expect(BackupEngine.deviceBackupRoot(for: "/iPhone-1/Photos", deviceFolder: "iPhone-1")
                == "/iPhone-1/Photos/iPhone-1/Backup")
    }

    /// 共有はバックアップと**同じ端末フォルダ**の隣に置く（ADR-175 の要点）。
    @Test("共有ルートはバックアップと同じ端末フォルダの Share")
    func shareRootSitsNextToBackup() {
        let backup = BackupLayout.backupRoot(root: "/MosaicPhotos", deviceFolder: "iPhone-1")
        let share = BackupLayout.shareRoot(root: "/MosaicPhotos", deviceFolder: "iPhone-1")
        #expect(backup == "/MosaicPhotos/iPhone-1/Backup")
        #expect(share == "/MosaicPhotos/iPhone-1/Share")
        #expect((backup as NSString).deletingLastPathComponent
                == (share as NSString).deletingLastPathComponent, "端末フォルダが揃っていない")
        // Share 配下のパスを渡されても Backup と混ざらない。
        #expect(BackupLayout.backupRoot(root: share, deviceFolder: "iPhone-1") == backup)
    }
}

/// 写真本体の置き場（ADR-176）。8 万枚を 1 フォルダに置かず、撮影年月で分ける。
@Suite("写真の置き場（撮影年月）")
struct BackupPhotoFolderTests {

    private let root = "/MosaicPhotos/iPhone-1/Backup"

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: iso)!
    }

    @Test("撮影年月のフォルダへ（年 / 年-月）")
    func yearThenMonth() {
        #expect(BackupLayout.photoFolder(backupRoot: root, captureDate: date("2025-08-15T10:00:00Z"))
                == "\(root)/2025/2025-08")
        #expect(BackupLayout.photoFolder(backupRoot: root, captureDate: date("2019-01-01T00:00:00Z"))
                == "\(root)/2019/2019-01")
    }

    @Test("撮影日不明は undated")
    func undated() {
        #expect(BackupLayout.photoFolder(backupRoot: root, captureDate: nil) == "\(root)/undated")
    }

    /// ⚠️ メタデータのシャード（`.mosaic/meta/<YYYY-MM>.json`）と**同じ月**に入ること。
    /// 切り方が違うと「この月の写真とそのメタデータ」が対応しなくなる。
    @Test("メタデータのシャードと同じ月の切り方")
    func matchesShardMonth() {
        for iso in ["2025-08-31T23:59:59Z", "2025-09-01T00:00:00Z", "2020-02-29T12:00:00Z"] {
            let d = date(iso)
            let folder = BackupLayout.photoFolder(backupRoot: root, captureDate: d)
            let shard = BackupMetadataV2.shardName(for: d)
            #expect(folder.hasSuffix("/\(shard)"), "\(iso): フォルダ \(folder) とシャード \(shard) が違う")
        }
    }

    /// 端末のタイムゾーンで月が揺れると、同じ写真が別フォルダへ上がり得る。UTC 固定であること。
    @Test("月の境界は UTC で決める（端末のタイムゾーンに依らない）")
    func utcBoundary() {
        // JST では 9/1 09:00 だが UTC では 9/1 00:00 → 9 月。
        // JST では 8/31 23:30 は UTC で 8/31 14:30 → 8 月。どちらも UTC の月で決まる。
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        let jstLateAug = f.date(from: "2025-09-01T08:59:59+09:00")!   // UTC 8/31 23:59:59
        #expect(BackupLayout.photoFolder(backupRoot: root, captureDate: jstLateAug)
                .hasSuffix("/2025/2025-08"), "JST の日付で月を決めている")
    }
}

