import Foundation
import Testing
@testable import BackupKit

// MARK: - ShareNaming

@Suite("ShareNaming (フォルダ名サニタイズ)")
struct ShareNamingTests {

    @Test("禁止文字は置換され前後の空白・ドットは除かれる")
    func sanitizesForbiddenCharacters() {
        #expect(ShareNaming.sanitize("A/B:C?") == "A_B_C_")
        #expect(ShareNaming.sanitize("  Trip 2025  ") == "Trip 2025")
        #expect(ShareNaming.sanitize("..name..") == "name")
    }

    @Test("空・記号のみの名前は Shared にフォールバック")
    func fallsBackWhenEmpty() {
        #expect(ShareNaming.sanitize("") == "Shared")
        #expect(ShareNaming.sanitize("///") == "Shared" || ShareNaming.sanitize("///") == "___")
    }

    @Test("既存フォルダ名と衝突したら連番を付ける（大文字小文字は無視）")
    func resolvesCollisions() {
        #expect(ShareNaming.sanitize("Trip", existing: ["trip"]) == "Trip 2")
        #expect(ShareNaming.sanitize("Trip", existing: ["Trip", "Trip 2"]) == "Trip 3")
        #expect(ShareNaming.sanitize("Trip", existing: ["Other"]) == "Trip")
    }

    @Test("日本語名はそのまま使える")
    func keepsJapanese() {
        #expect(ShareNaming.sanitize("沖縄旅行 2025") == "沖縄旅行 2025")
    }
}

// MARK: - SharePlanning

@Suite("SharePlanning (反映計画)")
struct SharePlanningTests {

    private func item(_ refKey: String, state: ShareItemState = .pending,
                      sharedPath: String? = nil, sharedHash: String? = nil) -> ShareItemLite {
        ShareItemLite(refKey: refKey, sourcePath: nil, sharedPath: sharedPath,
                      sharedContentHash: sharedHash, state: state, addedAt: Date())
    }

    @Test("クラウド写真は原本パスから・ローカル写真はバックアップ記録からコピーする")
    func resolvesSources() {
        let plan = SharePlanning.plan(
            items: [item("C-/Photos/a.jpg"), item("L-local1")],
            backupByLocalID: ["local1": .init(dropboxPath: "/mosaicphotos/b.jpg", contentHash: "h1")])
        #expect(plan.copies.count == 2)
        #expect(plan.copies.contains(.init(refKey: "C-/Photos/a.jpg", fromPath: "/Photos/a.jpg")))
        #expect(plan.copies.contains(.init(refKey: "L-local1", fromPath: "/mosaicphotos/b.jpg")))
        #expect(plan.waitingBackup.isEmpty)
    }

    @Test("バックアップ記録が無いローカル写真は waitingBackup")
    func unbackedLocalWaits() {
        let plan = SharePlanning.plan(items: [item("L-none")], backupByLocalID: [:])
        #expect(plan.copies.isEmpty)
        #expect(plan.waitingBackup == ["L-none"])
    }

    @Test("コピー済みは再コピーしない（実在・ハッシュ一致）")
    func copiedItemsAreSkipped() {
        let plan = SharePlanning.plan(
            items: [item("L-a", state: .copied, sharedPath: "/mosaicshare/set/a.jpg", sharedHash: "h1")],
            backupByLocalID: ["a": .init(dropboxPath: "/mosaicphotos/a.jpg", contentHash: "h1")],
            remotePresentLower: ["/mosaicshare/set/a.jpg"])
        #expect(plan.copies.isEmpty)
    }

    @Test("共有側から消えたコピー済みは再コピー（自己修復）")
    func missingRemoteIsRecopied() {
        let plan = SharePlanning.plan(
            items: [item("L-a", state: .copied, sharedPath: "/mosaicshare/set/a.jpg", sharedHash: "h1")],
            backupByLocalID: ["a": .init(dropboxPath: "/mosaicphotos/a.jpg", contentHash: "h1")],
            remotePresentLower: [])
        #expect(plan.copies == [.init(refKey: "L-a", fromPath: "/mosaicphotos/a.jpg")])
    }

    @Test("元のハッシュが変わったコピー済みは再コピー（ドリフト）")
    func driftedHashIsRecopied() {
        let plan = SharePlanning.plan(
            items: [item("L-a", state: .copied, sharedPath: "/mosaicshare/set/a.jpg", sharedHash: "old")],
            backupByLocalID: ["a": .init(dropboxPath: "/mosaicphotos/a.jpg", contentHash: "new")],
            remotePresentLower: ["/mosaicshare/set/a.jpg"])
        #expect(plan.copies == [.init(refKey: "L-a", fromPath: "/mosaicphotos/a.jpg")])
    }

    @Test("未照合（remote 一覧なし）ではコピー済みの実在チェックをしない")
    func noRemoteListingSkipsPresenceCheck() {
        let plan = SharePlanning.plan(
            items: [item("L-a", state: .copied, sharedPath: "/mosaicshare/set/a.jpg", sharedHash: "h1")],
            backupByLocalID: ["a": .init(dropboxPath: "/mosaicphotos/a.jpg", contentHash: "h1")],
            remotePresentLower: nil)
        #expect(plan.copies.isEmpty)
    }

    @Test("コピー先はセットフォルダ＋元ファイル名")
    func destinationPathLayout() {
        #expect(SharePlanning.destinationPath(shareRoot: "/MosaicShare", folderName: "Trip",
                                              fromPath: "/MosaicPhotos/IMG_1.jpg")
                == "/MosaicShare/Trip/IMG_1.jpg")
    }
}

// MARK: - ShareSidecar

@Suite("ShareSidecar (解析サイドカーの検証)")
struct ShareSidecarTests {

    private var validHash: String { String(repeating: "ab", count: 32) }
    private var validEmbedding: String {
        Data(repeating: 0x11, count: ShareSidecar.embeddingByteCount).base64EncodedString()
    }

    private func file(entries: [String: ShareSidecar.Entry]) -> ShareSidecar.File {
        ShareSidecar.File(versions: .init(tag: 3, perception: 8, face: 4), entries: entries)
    }

    @Test("エンコード→デコードで内容が保たれる（決定的エンコード）")
    func roundTrip() {
        let original = file(entries: [validHash: .init(tags: ["beach", "sunset"], human: 2,
                                                       clip: validEmbedding)])
        let data = ShareSidecar.encode(original)
        #expect(data != nil)
        let decoded = ShareSidecar.decodeValidated(data!)
        #expect(decoded == original)
        // 同じ内容は同じバイト列（チェックサム比較の前提）。
        #expect(ShareSidecar.encode(original) == data)
    }

    @Test("不正な content_hash キーのエントリは捨てられる")
    func invalidHashKeyDropped() {
        let bad = file(entries: ["not-a-hash": .init(tags: ["x"]),
                                 validHash: .init(tags: ["ok"])])
        let decoded = ShareSidecar.decodeValidated(ShareSidecar.encode(bad)!)
        #expect(decoded?.entries.count == 1)
        #expect(decoded?.entries[validHash]?.tags == ["ok"])
    }

    @Test("次元不正・非有限の埋め込みは捨てられる")
    func invalidEmbeddingsDropped() {
        let short = Data(repeating: 1, count: 10).base64EncodedString()
        // Float16 の NaN（0x7FFF）だけを敷き詰めたベクトル。
        var nanData = Data()
        for _ in 0..<(ShareSidecar.embeddingByteCount / 2) {
            nanData.append(contentsOf: [0xFF, 0x7F])
        }
        let entry = ShareSidecar.Entry(tags: ["keep"], clip: short,
                                       faces: [.init(x: 0.1, y: 0.1, w: 0.2, h: 0.2,
                                                     e: nanData.base64EncodedString(), q: 0.9)])
        let decoded = ShareSidecar.decodeValidated(ShareSidecar.encode(file(entries: [validHash: entry]))!)
        let cleaned = decoded?.entries[validHash]
        #expect(cleaned?.tags == ["keep"])
        #expect(cleaned?.clip == nil, "次元不正の CLIP が残った")
        #expect(cleaned?.faces == nil, "NaN 埋め込みの顔が残った")
    }

    @Test("全セクションが落ちたエントリは丸ごと消える")
    func fullyInvalidEntryDropped() {
        let entry = ShareSidecar.Entry(clip: "!!!not-base64!!!")
        let decoded = ShareSidecar.decodeValidated(ShareSidecar.encode(file(entries: [validHash: entry]))!)
        #expect(decoded?.entries.isEmpty == true)
    }

    @Test("フォーマット版が違うファイルは拒否する")
    func rejectsUnknownFormatVersion() {
        var bad = file(entries: [validHash: .init(tags: ["x"])])
        bad.formatVersion = 999
        #expect(ShareSidecar.decodeValidated(ShareSidecar.encode(bad)!) == nil)
    }

    @Test("タグ・OCR は上限で刈り込まれる")
    func capsAreEnforced() {
        let manyTags = (0..<200).map { "tag\($0)" }
        let longOcr = String(repeating: "x", count: 10_000)
        let entry = ShareSidecar.Entry(tags: manyTags, ocr: longOcr)
        let decoded = ShareSidecar.decodeValidated(ShareSidecar.encode(file(entries: [validHash: entry]))!)
        let cleaned = decoded?.entries[validHash]
        #expect(cleaned?.tags?.count == ShareSidecar.maxTagsPerEntry)
        #expect(cleaned?.ocr?.count == ShareSidecar.maxOcrLength)
    }
}

// MARK: - ShareImportPlanning

@Suite("ShareImportPlanning (受信側の突合)")
struct ShareImportPlanningTests {

    private var hashA: String { String(repeating: "aa", count: 32) }
    private var hashB: String { String(repeating: "bb", count: 32) }
    private var embedding: String {
        Data(repeating: 0x11, count: ShareSidecar.embeddingByteCount).base64EncodedString()
    }

    private func sidecar(versions: ShareSidecar.Versions = .init(tag: 3, perception: 8, face: 4))
        -> ShareSidecar.File {
        ShareSidecar.File(versions: versions, entries: [
            hashA: .init(tags: ["beach"], clip: embedding,
                         faces: [.init(x: 0.1, y: 0.1, w: 0.2, h: 0.2, e: embedding, q: 0.9)]),
            hashB: .init(tags: ["cat"]),
        ])
    }

    private var receiver: ShareImportPlanning.ReceiverVersions {
        .init(tag: 3, perception: 8, face: 4)
    }

    @Test("content_hash で受信側 refKey に突合される")
    func matchesByHash() {
        let batch = ShareImportPlanning.plan(
            sidecar: sidecar(),
            localItems: [.init(refKey: "C-/mosaicshare/trip/a.jpg", contentHash: hashA)],
            versions: receiver)
        #expect(batch.tags.map(\.refKey) == ["C-/mosaicshare/trip/a.jpg"])
        #expect(batch.embeddings.count == 1)
        #expect(batch.faces.count == 1)
    }

    @Test("同じ写真が複数セットにあれば全 refKey に展開する")
    func expandsToAllRefKeys() {
        let batch = ShareImportPlanning.plan(
            sidecar: sidecar(),
            localItems: [.init(refKey: "C-/a/x.jpg", contentHash: hashA),
                         .init(refKey: "C-/b/x.jpg", contentHash: hashA)],
            versions: receiver)
        #expect(batch.tags.count == 2)
        #expect(batch.embeddings.count == 2)
    }

    @Test("版が一致しないセクションは取り込まない")
    func versionGating() {
        let batch = ShareImportPlanning.plan(
            sidecar: sidecar(versions: .init(tag: 2, perception: 7, face: 4)),
            localItems: [.init(refKey: "C-/a.jpg", contentHash: hashA)],
            versions: receiver)
        #expect(batch.tags.isEmpty, "タグ版不一致なのに取り込まれた")
        #expect(batch.embeddings.isEmpty, "CLIP 版不一致なのに取り込まれた")
        #expect(batch.faces.count == 1, "顔版は一致しているのに落ちた")
    }

    @Test("受信側に無い写真のエントリは無視される")
    func unmatchedEntriesIgnored() {
        let batch = ShareImportPlanning.plan(
            sidecar: sidecar(),
            localItems: [.init(refKey: "C-/c.jpg", contentHash: String(repeating: "cc", count: 32))],
            versions: receiver)
        #expect(batch.tags.isEmpty)
        #expect(batch.embeddings.isEmpty)
        #expect(batch.faces.isEmpty)
    }
}
