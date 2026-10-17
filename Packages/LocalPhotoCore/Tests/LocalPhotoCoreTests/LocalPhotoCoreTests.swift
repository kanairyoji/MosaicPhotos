import Photos
import Testing
@testable import LocalPhotoCore

@Suite("LocalPhotoStore")
struct LocalPhotoStoreTests {
    @Test("authorization status reflects PHPhotoLibrary status on init")
    @MainActor func initialAuthorizationStatus() {
        let store = LocalPhotoStore(media: .photosOnly)
        let expected = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #expect(store.authorizationStatus == expected)
    }

    @Test("assets is empty on init")
    @MainActor func initialAssetsEmpty() {
        let store = LocalPhotoStore(media: .photosOnly)
        #expect(store.assets.isEmpty)
    }
}
