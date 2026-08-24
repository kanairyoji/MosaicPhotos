import Foundation
import Photos
import Testing
@testable import LocalPhotoCore

/// ⚠️ キャンセルは `requestImage` が ID を返す**前**に走り得る（AsyncStream の終了直後など）。
/// 以前は無効値のまま `cancelImageRequest` を呼んでいたため何も取り消せず、画面外になった
/// サムネイル取得が最後まで継続していた（高速スクロールで大量に残る・レビュー指摘）。
@Suite("PHImageRequestBox")
struct PHImageRequestBoxTests {

    @Test("登録より先にキャンセルされたら、登録時に「取り消せ」と返す")
    func cancelBeforeRegisterIsReportedAtRegistration() {
        let box = PHImageRequestBox()
        #expect(box.cancel() == nil, "未登録なので取り消す ID はまだ無い")
        #expect(box.register(42), "先行キャンセルを取りこぼした（取得が止まらない）")
    }

    @Test("登録後のキャンセルはその ID を返す")
    func cancelAfterRegisterReturnsID() {
        let box = PHImageRequestBox()
        #expect(box.register(7) == false)
        #expect(box.cancel() == 7)
    }

    @Test("キャンセルしていなければ登録は false")
    func registerWithoutCancel() {
        let box = PHImageRequestBox()
        #expect(box.register(3) == false)
    }

    @Test("完了は 1 回だけ通る（degraded → final の二重 resume を防ぐ）")
    func finishesOnce() {
        let box = PHImageRequestBox()
        #expect(box.finished == false)
        #expect(box.markFinished())
        #expect(box.finished)
        #expect(box.markFinished() == false)
    }

    /// 並行に register / cancel が走っても、どちらか一方は必ず「取り消す責任」を持つ。
    @Test("並行実行でも取り消しの責任が消えない")
    func concurrentRegisterAndCancel() async {
        for _ in 0..<200 {
            let box = PHImageRequestBox()
            async let registered: Bool = Task.detached { box.register(9) }.value
            async let cancelled: PHImageRequestID? = Task.detached { box.cancel() }.value
            let (didSeeCancel, idToCancel) = await (registered, cancelled)
            #expect(didSeeCancel || idToCancel == 9,
                    "どちらも取り消さない組み合わせが生まれた（要求が残る）")
        }
    }
}
