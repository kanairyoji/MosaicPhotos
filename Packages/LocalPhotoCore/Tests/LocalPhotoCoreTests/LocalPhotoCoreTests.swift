import Photos
import Testing
@testable import LocalPhotoCore

@Suite("LocalPhotoStore")
struct LocalPhotoStoreTests {
    @Test("authorization status reflects PHPhotoLibrary status on init")
    @MainActor func initialAuthorizationStatus() {
        let store = LocalPhotoStore()
        let expected = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #expect(store.authorizationStatus == expected)
    }

    @Test("assets is empty on init")
    @MainActor func initialAssetsEmpty() {
        let store = LocalPhotoStore()
        #expect(store.assets.isEmpty)
    }
}
