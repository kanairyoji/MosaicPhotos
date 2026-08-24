import Foundation
import Testing
@testable import DropboxCore

/// 読み込み対象フォルダ（ADR-44）の正規化純ロジック。
@Suite("DropboxSourceSettings (source folder normalization)")
struct DropboxSourceSettingsTests {

    @Test("パス正規化: 空・スラッシュ・前後空白・末尾スラッシュ")
    func pathNormalization() {
        #expect(DropboxSourceSettings.normalized("/") == "")
        #expect(DropboxSourceSettings.normalized("") == "")
        #expect(DropboxSourceSettings.normalized("  /Photos  ") == "/Photos")
        #expect(DropboxSourceSettings.normalized("Photos") == "/Photos")
        #expect(DropboxSourceSettings.normalized("/Photos/") == "/Photos")
        #expect(DropboxSourceSettings.normalized("/Photos/2024//") == "/Photos/2024")
    }

    @Test("ルート畳み込み: 全体が含まれれば 1 本に")
    func rootsCollapseToAll() {
        #expect(DropboxSourceSettings.normalizedRoots(["/", "/MosaicPhotos"]) == [""])
        #expect(DropboxSourceSettings.normalizedRoots(["", "/A"]) == [""])
    }

    @Test("ルート畳み込み: 子孫は親に畳む・大文字小文字を無視")
    func rootsDropDescendants() {
        #expect(DropboxSourceSettings.normalizedRoots(["/Photos", "/Photos/2024"]) == ["/Photos"])
        #expect(DropboxSourceSettings.normalizedRoots(["/photos", "/Photos/2024"]) == ["/photos"])
        // 兄弟は両方残る（選択フォルダ＋バックアップフォルダの通常形）
        #expect(DropboxSourceSettings.normalizedRoots(["/Family", "/MosaicPhotos"]) == ["/Family", "/MosaicPhotos"])
        // 重複（大文字小文字違い）は 1 本に
        #expect(DropboxSourceSettings.normalizedRoots(["/Photos", "/photos"]) == ["/Photos"])
    }

    @Test("前方一致の別フォルダは畳まない（/Photo と /Photos）")
    func prefixButNotAncestor() {
        #expect(DropboxSourceSettings.normalizedRoots(["/Photo", "/Photos"]).count == 2)
    }
}

// MARK: - キャッシュの持ち主（アカウント切替の検出・レビュー指摘）

/// ⚠️ 以前はメモリ上の変数で「前回のアカウント」を覚え、切断時に nil へ戻していた。
/// そのため「切断 → 別アカウントで接続」でも「再起動を挟む切替」でも切替を検出できず、
/// **旧アカウントのキャッシュを新アカウントの写真として表示**し得た。
#if canImport(UIKit)
@Suite("Dropbox cache owner (account switch)")
@MainActor
struct DropboxCacheOwnerTests {

    private let a = DropboxPhotoStore.accountFingerprint("dbid:AAA")
    private let b = DropboxPhotoStore.accountFingerprint("dbid:BBB")

    @Test("同じアカウントならキャッシュを温存する")
    func sameAccountKeepsCache() {
        #expect(DropboxPhotoStore.cacheOwnerDecision(stored: a, current: a) == .keep)
    }

    @Test("別アカウントならキャッシュを捨ててから持ち主を更新する")
    func differentAccountClearsCache() {
        #expect(DropboxPhotoStore.cacheOwnerDecision(stored: a, current: b) == .clearThenAdopt(b))
    }

    @Test("記録が無ければ持ち主として記録するだけ（初回・旧バージョンからの移行）")
    func firstRunAdopts() {
        #expect(DropboxPhotoStore.cacheOwnerDecision(stored: nil, current: a) == .adopt(a))
    }

    /// 切断（accountId なし）で記録を消すと、次の接続が「初回」に見えて切替を取りこぼす。
    @Test("未接続では持ち主の記録を変えない")
    func disconnectedKeepsOwnerRecord() {
        #expect(DropboxPhotoStore.cacheOwnerDecision(stored: a, current: nil) == .unknown)
        #expect(DropboxPhotoStore.cacheOwnerDecision(stored: nil, current: nil) == .unknown)
    }

    @Test("指紋は生の accountId を含まない（等値比較にだけ使う）")
    func fingerprintDoesNotLeakAccountId() {
        #expect(!a.contains("dbid"))
        #expect(a == DropboxPhotoStore.accountFingerprint("dbid:AAA"))
        #expect(a != b)
    }
}
#endif
