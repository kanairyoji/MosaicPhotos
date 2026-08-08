import Foundation
import Testing
@testable import DropboxCore

/// バックアップメタデータの「不在記録」（ADR-82）。
/// 存在しないメタデータを毎起動探しに行かないための仕組み。無効化を誤ると
/// 「初回バックアップ後もバッジが出ない」になるため、その経路を固定する。
@Suite("BackupMetadataAbsence")
struct BackupMetadataAbsenceTests {

    /// テスト専用の UserDefaults（グローバル設定を汚さない）。
    private func makeDefaults() -> (UserDefaults, String)? {
        let suite = "BackupMetadataAbsenceTests.\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: suite) else { return nil }
        return (d, suite)
    }

    @Test("記録が無ければ問い合わせる（isAbsent は false）")
    func absentByDefaultIsFalse() {
        guard let (d, suite) = makeDefaults() else { Issue.record("defaults 作成失敗"); return }
        defer { d.removePersistentDomain(forName: suite) }
        #expect(!BackupMetadataAbsence.isAbsent(path: "/x/.mosaic/metadata.json", defaults: d))
    }

    @Test("markAbsent した直後は問い合わせを省く")
    func markAbsentSuppresses() {
        guard let (d, suite) = makeDefaults() else { Issue.record("defaults 作成失敗"); return }
        defer { d.removePersistentDomain(forName: suite) }
        let path = "/x/.mosaic/metadata.json"
        BackupMetadataAbsence.markAbsent(path: path, defaults: d)
        #expect(BackupMetadataAbsence.isAbsent(path: path, defaults: d))
    }

    @Test("TTL を過ぎた記録は無効（また問い合わせる）")
    func expiredAbsenceIsIgnored() {
        guard let (d, suite) = makeDefaults() else { Issue.record("defaults 作成失敗"); return }
        defer { d.removePersistentDomain(forName: suite) }
        let path = "/x/.mosaic/catalog.json"
        // TTL より 1 秒古い時刻を直接書き込む。
        d.set(Date().addingTimeInterval(-BackupMetadataAbsence.ttl - 1),
              forKey: BackupMetadataAbsence.keyPrefix + path.lowercased())
        #expect(!BackupMetadataAbsence.isAbsent(path: path, defaults: d))
    }

    @Test("markPresent で記録が消える（見つかったら次回も確認する）")
    func markPresentClears() {
        guard let (d, suite) = makeDefaults() else { Issue.record("defaults 作成失敗"); return }
        defer { d.removePersistentDomain(forName: suite) }
        let path = "/x/.mosaic/metadata.json"
        BackupMetadataAbsence.markAbsent(path: path, defaults: d)
        BackupMetadataAbsence.markPresent(path: path, defaults: d)
        #expect(!BackupMetadataAbsence.isAbsent(path: path, defaults: d))
    }

    /// 回帰: これが効かないと、初回バックアップ後も最大 TTL(24h) のあいだ
    /// 「バックアップ済み」バッジが出ない。
    @Test("invalidateAll は全パスの記録を消す（バックアップ書き込み直後の経路）")
    func invalidateAllClearsEverything() {
        guard let (d, suite) = makeDefaults() else { Issue.record("defaults 作成失敗"); return }
        defer { d.removePersistentDomain(forName: suite) }
        let paths = ["/a/.mosaic/metadata.json", "/a/.mosaic/catalog.json", "/b/.mosaic/metadata.json"]
        for p in paths { BackupMetadataAbsence.markAbsent(path: p, defaults: d) }
        d.set("keep-me", forKey: "unrelated.key")

        BackupMetadataAbsence.invalidateAll(defaults: d)

        for p in paths { #expect(!BackupMetadataAbsence.isAbsent(path: p, defaults: d)) }
        #expect(d.string(forKey: "unrelated.key") == "keep-me")   // 無関係なキーは触らない
    }

    @Test("パスの大小文字は区別しない（Dropbox のパスは case-insensitive）")
    func pathIsCaseInsensitive() {
        guard let (d, suite) = makeDefaults() else { Issue.record("defaults 作成失敗"); return }
        defer { d.removePersistentDomain(forName: suite) }
        BackupMetadataAbsence.markAbsent(path: "/A/.mosaic/Metadata.json", defaults: d)
        #expect(BackupMetadataAbsence.isAbsent(path: "/a/.mosaic/metadata.json", defaults: d))
    }
}
