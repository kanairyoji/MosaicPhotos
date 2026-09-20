import Foundation
import Testing
import PerceptionCore
@testable import FaceCore

/// 表示側の写真 ID から台帳の refKey を引き当てる規則（レビュー 11 周目）。
///
/// ⚠️ クラウド写真の ID は**接頭辞の無い生パス**（`DropboxFileItem.id == path`）。
/// `"L-"` しか試さない実装だと、同じ画面で**顔の黄枠は出るのに人物名は空**になる
/// ——黄枠と長押しの「この人ではない」は `refKeyCandidates` を使っているため。
@Suite("写真 ID → refKey の候補")
@MainActor
struct PeopleEngineLookupTests {

    @Test("生の Dropbox パスからクラウドの refKey を作る")
    func rawCloudPathResolvesToCloudRefKey() {
        let candidates = PeopleEngine.refKeyCandidates(for: "/photos/2024/img.jpg")
        #expect(candidates.contains(PhotoRef.cloud("/photos/2024/img.jpg").encoded),
                "クラウドの refKey を試さない＝クラウド写真の人物名が永久に空: \(candidates)")
    }

    @Test("生の localIdentifier からローカルの refKey を作る")
    func rawLocalIDResolvesToLocalRefKey() {
        let candidates = PeopleEngine.refKeyCandidates(for: "ABC-123/L0/001")
        #expect(candidates.contains(PhotoRef.local("ABC-123/L0/001").encoded))
    }

    @Test("既に refKey ならそのまま先頭で試す")
    func encodedRefKeyIsTriedFirst() {
        let key = PhotoRef.cloud("/photos/a.jpg").encoded
        #expect(PeopleEngine.refKeyCandidates(for: key).first == key)
    }

    /// 回帰: 人物名・顔数の引き当てが、黄枠と**同じ候補**を使うこと。
    /// 片方だけ直すと「枠は出るのに名前が無い」という食い違いが戻る。
    @Test("人物名と顔数は、黄枠と同じ候補で引く")
    func nameLookupUsesTheSameCandidatesAsHighlights() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let path = "/photos/2024/img.jpg"
        let refKey = PhotoRef.cloud(path).encoded
        var v = [Float](repeating: 0, count: 8); v[0] = 1
        let signals = (0..<3).map { _ in
            DetectedFaceSignal(boundingBox: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                               embedding: ClipMath.encodeHalf(v), quality: 0.9)
        }
        // 同じ写真に 3 つは cannot-link になるので、3 枚の別写真として入れる。
        _ = await store.recordScans((0..<3).map { i in
            (PhotoRef.cloud("/photos/2024/img\(i).jpg").encoded, [signals[i]])
        })
        _ = await store.recordScans([(refKey, [signals[0]])])

        let engine = PeopleEngine(faceProvider: nil, store: store)
        let count = await engine.faceCount(forItemID: path)   // 生パスで引く
        #expect(count == 1, "生の Dropbox パスで顔数が引けない（クラウド写真の情報欄が空になる）")
    }
}
