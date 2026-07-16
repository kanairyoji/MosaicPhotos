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
