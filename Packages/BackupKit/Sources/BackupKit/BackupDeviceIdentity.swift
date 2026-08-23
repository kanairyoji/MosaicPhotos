import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

/// バックアップの**端末フォルダ**の identity（ADR-41）。
///
/// 家族で 1 つの Dropbox アカウントを共有する想定で、バックアップはルート直下でなく
/// `<バックアップフォルダ>/<端末フォルダ>/` に保存する。これにより
/// (1) 端末間の同名ファイル衝突を構造的に回避し、
/// (2) **`.mosaic` メタデータ（download→merge→upload 方式）の端末間競合**（後勝ちで
///     相手のエントリを消す＝本命のリスク）を排除する。
///
/// フォルダ名 = `<表示名>-<短ID>`（例 "iPhone-3F2A8C"）。
/// - **短 ID は初回に生成して Keychain に保存**する（クレデンシャルではなく識別子）。
///   UserDefaults と違い**アプリを再インストールしても残る**ため、同じ端末は常に同じ
///   フォルダへ向かう（identifierForVendor は再インストールで変わるため不採用。
///   端末名は iOS 16+ で汎用名しか取れず、ユーザー変更でフォルダが割れるため不採用）。
/// - 表示名は UIDevice.model（"iPhone"/"iPad"・汎用）。人間が Dropbox 上で見分ける補助で、
///   一意性は短 ID が担う。表示名と ID は catalog.json にも記録し、機種変更時の
///   「既存バックアップの引き継ぎ」UI の材料にする。
public enum BackupDeviceIdentity {

    private static let keychainService = "MosaicPhotos.backup"
    private static let keychainAccount = "backupDeviceID"

    // MARK: - 純ロジック（テスト対象）

    /// フォルダ名を組み立てる。表示名はサニタイズ（英数字とハイフン以外を除去・長さ制限）。
    static func folderName(displayName: String, id: String) -> String {
        var name = displayName.map { ch -> Character in
            (ch.isLetter && ch.isASCII) || ch.isNumber ? ch : "-"
        }.reduce(into: "") { out, ch in
            // 連続ハイフンを 1 つに潰す
            if ch == "-" && out.hasSuffix("-") { return }
            out.append(ch)
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if name.isEmpty { name = "device" }
        name = String(name.prefix(20))
        return "\(name)-\(id)"
    }

    /// 短 ID（UUID 先頭 6 hex・大文字）。フォルダ名の一意性を担う。
    static func generateID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
    }

    // MARK: - 公開 API

    /// この端末のバックアップフォルダ名（例 "iPhone-3F2A8C"）。ID は初回に生成して
    /// Keychain へ永続化する（以後・再インストール後も同じ名前を返す）。
    public static func currentFolderName() -> String {
        folderName(displayName: currentDisplayName(), id: currentID())
    }

    /// この端末の短 ID（Keychain 永続・初回生成）。catalog.json の deviceID にも記録する。
    ///
    /// ⚠️ **同じプロセス内では必ず同じ値を返す**こと。ID はバックアップ／共有の
    /// **フォルダ名そのもの**なので、呼ぶたびに変わると保存先が毎回変わり、ファイルが
    /// 端末フォルダの数だけ散らばる（＝どのフォルダが自分のものか分からなくなる）。
    /// Keychain が使えない環境（CI・サンドボックス・保存に失敗した端末）では
    /// 毎回新規生成になっていた——実際に CI のテストが「呼ぶたび別 ID」で落ちた。
    /// そこで (1) プロセス内メモ化、(2) Keychain が駄目なら UserDefaults へ退避、で二重に守る。
    /// （短 ID は端末の識別子でありクレデンシャルではないので UserDefaults 保存は問題ない。）
    public static func currentID() -> String {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedID, !cachedID.isEmpty { return cachedID }
        let id = resolveID(
            readKeychain: { readKeychain() },
            writeKeychain: { writeKeychain($0) },
            readFallback: { UserDefaults.standard.string(forKey: fallbackDefaultsKey) },
            writeFallback: { UserDefaults.standard.set($0, forKey: fallbackDefaultsKey) },
            generate: { generateID() })
        cachedID = id
        return id
    }

    /// ID 解決の純ロジック（保存先を引数化・テスト対象）。
    /// Keychain → 退避（UserDefaults）→ 新規生成、の順に解決し、**解決できた値は
    /// 両方へ書き戻す**。これが無いと Keychain が使えない環境で毎回新規生成になる。
    static func resolveID(readKeychain: () -> String?,
                          writeKeychain: (String) -> Void,
                          readFallback: () -> String?,
                          writeFallback: (String) -> Void,
                          generate: () -> String) -> String {
        if let stored = readKeychain(), !stored.isEmpty {
            writeFallback(stored)   // Keychain が後で使えなくなっても同じ ID を保てるように
            return stored
        }
        if let stored = readFallback(), !stored.isEmpty {
            writeKeychain(stored)   // 使えるようになっていれば書き戻す
            return stored
        }
        let id = generate()
        writeKeychain(id)
        writeFallback(id)
        return id
    }

    /// プロセス内メモ（`currentID` の安定性を担保する）。
    nonisolated(unsafe) private static var cachedID: String?
    private static let cacheLock = NSLock()
    /// Keychain が使えないときの退避先。
    private static let fallbackDefaultsKey = "backupDeviceIDFallback"

    /// 表示名（"iPhone"/"iPad"）。catalog.json の deviceName にも記録する。
    public static func currentDisplayName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "device"
        #endif
    }

    // MARK: - Keychain（識別子の保存・クレデンシャルではない）

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    private static func readKeychain() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ value: String) {
        var attrs = baseQuery
        attrs[kSecValueData as String] = Data(value.utf8)
        // 端末ロック解除後は常にアクセス可（バックアップはバックグラウンドでも走る）。
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(baseQuery as CFDictionary,
                          [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        }
    }
}
