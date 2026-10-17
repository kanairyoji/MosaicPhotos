import Photos
import Testing
@testable import LocalPhotoCore

/// 端末のライブラリ全体を一覧するときの範囲（2026-10-17・動画対応）。
/// ⚠️ 動画を出すのはホームの「すべて」「端末」だけ。写真だけのストアが動画を拾わないことも縛る。
@Suite("LocalMediaScope")
struct LocalMediaScopeTests {
    private func matches(_ scope: LocalMediaScope, _ type: PHAssetMediaType) -> Bool {
        scope.predicate.evaluate(with: ["mediaType": type.rawValue])
    }

    @Test("写真だけ: 画像だけを通す")
    func photosOnly() {
        #expect(matches(.photosOnly, .image))
        #expect(!matches(.photosOnly, .video))
        #expect(!matches(.photosOnly, .audio))
        #expect(!LocalMediaScope.photosOnly.includesVideos)
    }

    @Test("写真と動画: 画像と動画を通し、音声は通さない")
    func photosAndVideos() {
        #expect(matches(.photosAndVideos, .image))
        #expect(matches(.photosAndVideos, .video))
        #expect(!matches(.photosAndVideos, .audio))
        #expect(LocalMediaScope.photosAndVideos.includesVideos)
    }

    @Test("ストアは渡された範囲を持ち、ID 指定のストアは範囲を持たない（渡された写真だけ）")
    @MainActor func storeKeepsScope() {
        #expect(LocalPhotoStore(media: .photosAndVideos).mediaScope == .photosAndVideos)
        #expect(LocalPhotoStore(media: .photosOnly).mediaScope == .photosOnly)
        #expect(LocalPhotoStore(localIdentifiers: ["x"]).mediaScope == nil)
    }
}
