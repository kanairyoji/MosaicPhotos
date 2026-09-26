import CoreGraphics
import Foundation
import PerceptionCore
import SwiftData
import Testing
@testable import FaceCore

/// 台帳の書き出しから**読める個人情報を外す**（ADR-234 追補）。
///
/// ⚠️ この仕組みの目的を取り違えないこと: **顔の埋め込みは外せない**（再生が使うもの）。
/// 外すのは「再生に要らないのに読める」ぶん＝人物名と写真のパスだけ。
/// つまり書き出したファイルは名前の有無に関わらず**生体情報**で、扱いの注意は変わらない。
@Suite("台帳の書き出しから個人情報を外す")
struct FaceLedgerRedactionTests {

    // MARK: - 置き換えの規則（純）

    @Test("写真のキーは、種別の接頭辞を残して置き換える")
    func keepsTheSourcePrefix() {
        let salt = "s"
        let local = FaceLedgerRedaction.redactedRefKey("L-ABC123/L0/001", salt: salt)
        let cloud = FaceLedgerRedaction.redactedRefKey("C-/家族/2019/沖縄旅行/IMG_1234.jpg", salt: salt)
        #expect(local.hasPrefix("L-"), "\(local)")
        #expect(cloud.hasPrefix("C-"), "\(cloud)")
        // ⚠️ 接頭辞を落とすと、ローカル/クラウドで分岐する処理が動かなくなる。
        #expect(!local.contains("ABC123"), "元のキーが残っている: \(local)")
        #expect(!cloud.contains("家族") && !cloud.contains("沖縄") && !cloud.contains("IMG_1234"),
                "フォルダ名が残っている: \(cloud)")
    }

    @Test("同じキーは同じ値になる（重なりの突き合わせが効く）")
    func isStableForTheSameKey() {
        let salt = "s"
        #expect(FaceLedgerRedaction.redactedRefKey("L-a", salt: salt)
                == FaceLedgerRedaction.redactedRefKey("L-a", salt: salt))
        #expect(FaceLedgerRedaction.redactedRefKey("L-a", salt: salt)
                != FaceLedgerRedaction.redactedRefKey("L-b", salt: salt))
    }

    /// ⚠️ 塩が無いと、`/家族/2019/…` のような**当てやすいパスは総当たりで逆算できる**。
    @Test("塩が違えば値も違う（当てやすいパスの逆算を防ぐ）")
    func saltChangesTheResult() {
        #expect(FaceLedgerRedaction.redactedRefKey("C-/家族/x.jpg", salt: "a")
                != FaceLedgerRedaction.redactedRefKey("C-/家族/x.jpg", salt: "b"))
    }

    /// `faceID` は `"<refKey>#<連番>"`。⚠️ 片方だけ置き換えるとパスが faceID 側から漏れ、
    /// `coverFaceID` の参照も壊れる。
    @Test("顔の ID は、写真のキーと同じ置き換えで作り直す（連番は残す）")
    func faceIDUsesTheSameMapping() {
        let salt = "s"
        let key = "C-/家族/2019/IMG_1.jpg"
        let redactedKey = FaceLedgerRedaction.redactedRefKey(key, salt: salt)
        let redactedFace = FaceLedgerRedaction.redactedFaceID(key + "#2", salt: salt)
        #expect(redactedFace == redactedKey + "#2", "\(redactedFace)")
        #expect(!redactedFace.contains("家族"), "パスが faceID 側から漏れている: \(redactedFace)")
    }

    @Test("名前は安定した仮名になる（同じ名前なら同じ仮名）")
    func pseudonymsAreStable() {
        let salt = "s"
        let a = FaceLedgerRedaction.pseudonym(for: "太郎", salt: salt)
        #expect(a == FaceLedgerRedaction.pseudonym(for: "太郎", salt: salt))
        #expect(a != FaceLedgerRedaction.pseudonym(for: "花子", salt: salt))
        #expect(!a.contains("太郎"), "\(a)")
    }

    /// ⚠️ 空文字を仮名にすると「名前が無い」が「名前が在る」に変わり、
    /// `AssertionCensus` の数える「名前付き人物」が増えて突き合わせが狂う。
    @Test("名前が空なら空のまま（名前の有無を変えない）")
    func doesNotInventNames() {
        #expect(FaceLedgerRedaction.pseudonym(for: "", salt: "s").isEmpty)
    }

    // MARK: - 書き出し全体（ディスク）

    private func signal(_ v: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: 0.9)
    }

    /// 本名とクラウドのパスを持つ台帳をディスクに作る。
    private func makeLedger() async throws -> (dir: URL, store: FaceStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = ModelConfiguration(schema: FaceStore.ledgerSchema,
                                        url: dir.appendingPathComponent("FacesV1.store"))
        let container = try ModelContainer(for: FaceStore.ledgerSchema, configurations: [config])
        let store = FaceStore(modelContainer: container)
        for i in 0..<5 {
            await store.recordScan(refKey: "C-/家族/2019/沖縄旅行/IMG_\(i).jpg",
                                   faces: [signal([1, 0, 0])])
        }
        for i in 0..<5 {
            await store.recordScan(refKey: "L-LOCALID\(i)/L0/001", faces: [signal([0, 1, 0])])
        }
        let ids = await store.allClusters().map(\.clusterID).sorted()
        #expect(ids.count == 2, "fixture: 2 人物になっていない")
        await store.rename(clusterID: ids[0], name: "山田太郎")
        await store.setCover(clusterID: ids[0],
                             faceID: "C-/家族/2019/沖縄旅行/IMG_0.jpg#0")
        await store.linkClusters(ids)
        _ = await store.createPeopleGroup(name: "山田家", memberClusterIDs: ids)
        return (dir, store)
    }

    /// ⚠️ **これが肝心**。書き出したファイルを**バイト列として**調べて、本名とパスが
    /// 1 つも残っていないことを確かめる。SwiftData 越しに見るだけでは、
    /// 別の列や索引に残っていても気づけない。
    @Test("書き出したファイルのどこにも本名とフォルダ名が残らない")
    func exportedBytesContainNoNamesOrPaths() async throws {
        let (dir, _) = try await makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("FacesV1.store")
        #expect(FaceLedgerBackup.redactLedger(at: storeURL), "外す処理が失敗した")

        // ⚠️ `-wal` も含めて全部見る（本体だけ見ると WAL に残った分を見落とす）。
        var haystack = Data()
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            if let data = try? Data(contentsOf: url) { haystack.append(data) }
        }
        for secret in ["山田太郎", "山田家", "沖縄旅行", "家族", "LOCALID0"] {
            #expect(haystack.range(of: Data(secret.utf8)) == nil,
                    "書き出したファイルに「\(secret)」が残っている")
        }
        #expect(!haystack.isEmpty, "ファイルが空（fixture が壊れている）")
    }

    /// ⚠️ 外した結果が**再生に使える**こと。外して壊れるなら意味が無い。
    @Test("外したあとでも、再生（再クラスタ・持ち越し）がそのまま回る")
    func redactedLedgerStillReplays() async throws {
        let (dir, original) = try await makeLedger()
        defer { try? FileManager.default.removeItem(at: dir) }
        let censusBefore = await original.assertionCensus()
        #expect(censusBefore.namedCount == 1)
        #expect(censusBefore.bundleCount == 1)
        #expect(censusBefore.groups.count == 1)

        let storeURL = dir.appendingPathComponent("FacesV1.store")
        #expect(FaceLedgerBackup.redactLedger(at: storeURL))

        guard let (store, work) = try FaceLedgerReplayTests.openCopy(in: dir.path) else {
            #expect(Bool(false), "外した台帳を開けなかった"); return
        }
        defer { try? FileManager.default.removeItem(at: work) }
        let after = await store.assertionCensus()
        // ⚠️ **数が変わっていないこと**。名前が仮名になっても「名前付きが 1 人」は保たれる。
        #expect(after.namedCount == censusBefore.namedCount, "名前の有無が変わった")
        #expect(after.bundleCount == censusBefore.bundleCount, "束ねが失われた")
        #expect(after.groups.count == censusBefore.groups.count)
        #expect(after.resolvedGroupMemberCount == censusBefore.resolvedGroupMemberCount,
                "家族グループのメンバーが解決できなくなった（キーの置き換えで参照が壊れた）")
        #expect(after.coverCount == censusBefore.coverCount,
                "代表写真の参照が壊れた（coverFaceID を同じ置き換えで直していない）")

        // 再クラスタと持ち越しが回ること。
        _ = await store.rebuildClusters()
        let carried = await store.assertedClusterEntries()
        let input = await store.facesAsScanInput()
        await store.reset()
        _ = await store.recordScans(input)
        let remaining = await store.reapplyAssertions(carried)
        #expect(remaining.isEmpty, "外した台帳では持ち越しが戻らない（\(remaining.count) 件）")
        let replayed = await store.assertionCensus()
        #expect(replayed.namedCount == censusBefore.namedCount)
        #expect(replayed.resolvedGroupMemberCount == censusBefore.resolvedGroupMemberCount)
    }
}
