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

    private func plan(items: [ShareItemLite],
                      backup: [String: SharePlanning.BackupRef] = [:],
                      remote: [SharePlanning.RemoteFile]? = nil) -> SharePlanning.Plan {
        SharePlanning.plan(items: items, backupByLocalID: backup,
                           shareRoot: "/MosaicShare", folderName: "Trip", remoteFiles: remote)
    }

    @Test("クラウド写真は原本パスから・ローカル写真はバックアップ記録からコピーする")
    func resolvesSources() {
        let result = plan(
            items: [item("C-/Photos/a.jpg"), item("L-local1")],
            backup: ["local1": .init(dropboxPath: "/mosaicphotos/b.jpg", contentHash: "h1")],
            remote: [])
        #expect(result.copies.count == 2)
        #expect(result.copies.contains(.init(refKey: "C-/Photos/a.jpg", fromPath: "/Photos/a.jpg",
                                             toPath: "/MosaicShare/Trip/a.jpg")))
        #expect(result.copies.contains(.init(refKey: "L-local1", fromPath: "/mosaicphotos/b.jpg",
                                             toPath: "/MosaicShare/Trip/b.jpg")))
        #expect(result.waitingBackup.isEmpty)
    }

    @Test("バックアップ記録が無いローカル写真は waitingBackup")
    func unbackedLocalWaits() {
        let result = plan(items: [item("L-none")])
        #expect(result.copies.isEmpty)
        #expect(result.waitingBackup == ["L-none"])
    }

    @Test("同名ソースには衝突しない宛先を決定的に割り当てる（autorename 不使用）")
    func assignsUniqueDestinations() {
        let result = plan(
            items: [item("C-/A/IMG.jpg"), item("C-/B/IMG.jpg"), item("C-/C/IMG.jpg")],
            remote: [])
        #expect(result.copies.map(\.toPath) ==
                ["/MosaicShare/Trip/IMG.jpg", "/MosaicShare/Trip/IMG 2.jpg", "/MosaicShare/Trip/IMG 3.jpg"])
    }

    @Test("宛先が既に実在するなら採用（コピーしない）＝タイムアウト後のリトライが冪等")
    func adoptsExistingDestination() {
        let result = plan(
            items: [item("L-a", state: .failed)],
            backup: ["a": .init(dropboxPath: "/mosaicphotos/a.jpg", contentHash: "h1")],
            remote: [.init(pathLower: "/mosaicshare/trip/a.jpg", contentHash: "h1")])
        #expect(result.copies.isEmpty, "実在する宛先へ再コピーした（重複の温床）")
        #expect(result.adoptions == [.init(refKey: "L-a",
                                           sharedPathLower: "/mosaicshare/trip/a.jpg",
                                           contentHash: "h1")])
    }

    @Test("宛先実在でも中身が違えば採用せず別名コピー")
    func differentContentGetsAlternateName() {
        let result = plan(
            items: [item("L-a", state: .pending)],
            backup: ["a": .init(dropboxPath: "/mosaicphotos/a.jpg", contentHash: "NEW")],
            remote: [.init(pathLower: "/mosaicshare/trip/a.jpg", contentHash: "OLD")])
        #expect(result.adoptions.isEmpty)
        #expect(result.copies == [.init(refKey: "L-a", fromPath: "/mosaicphotos/a.jpg",
                                        toPath: "/MosaicShare/Trip/a 2.jpg")])
    }

    @Test("コピー済みは再コピーしない（実在・ハッシュ一致）")
    func copiedItemsAreSkipped() {
        let result = plan(
            items: [item("L-a", state: .copied, sharedPath: "/mosaicshare/trip/a.jpg", sharedHash: "h1")],
            backup: ["a": .init(dropboxPath: "/mosaicphotos/a.jpg", contentHash: "h1")],
            remote: [.init(pathLower: "/mosaicshare/trip/a.jpg", contentHash: "h1")])
        #expect(result.copies.isEmpty)
        #expect(result.adoptions.isEmpty)
    }

    @Test("共有側から消えたコピー済みは再コピー（自己修復）")
    func missingRemoteIsRecopied() {
        let result = plan(
            items: [item("L-a", state: .copied, sharedPath: "/mosaicshare/trip/a.jpg", sharedHash: "h1")],
            backup: ["a": .init(dropboxPath: "/mosaicphotos/a.jpg", contentHash: "h1")],
            remote: [])
        #expect(result.copies.count == 1)
    }

    @Test("未照合（remote 一覧なし）ではコピー済みの実在チェックをしない")
    func noRemoteListingSkipsPresenceCheck() {
        let result = plan(
            items: [item("L-a", state: .copied, sharedPath: "/mosaicshare/trip/a.jpg", sharedHash: "h1")],
            backup: ["a": .init(dropboxPath: "/mosaicphotos/a.jpg", contentHash: "h1")],
            remote: nil)
        #expect(result.copies.isEmpty)
    }

    @Test("autorename 暴走の残骸（name (N).ext・記録に属さず元名が実在）だけ掃除対象になる")
    func duplicateCleanupTargets() {
        let result = plan(
            items: [item("L-a", state: .copied, sharedPath: "/mosaicshare/trip/img.jpg", sharedHash: "h1")],
            backup: ["a": .init(dropboxPath: "/mosaicphotos/img.jpg", contentHash: "h1")],
            remote: [
                .init(pathLower: "/mosaicshare/trip/img.jpg", contentHash: "h1"),
                .init(pathLower: "/mosaicshare/trip/img (1).jpg", contentHash: "h1"),
                .init(pathLower: "/mosaicshare/trip/img (12).jpg", contentHash: "h1"),
                .init(pathLower: "/mosaicshare/trip/other (1).jpg", contentHash: "hx"),  // 元名なし → 残す
                .init(pathLower: "/mosaicshare/trip/party (2024).jpg", contentHash: "hy"),  // 数字だが元名なし → 残す
            ])
        #expect(result.duplicatesToDelete ==
                ["/mosaicshare/trip/img (1).jpg", "/mosaicshare/trip/img (12).jpg"])
    }

    @Test("記録に属する (N) 形式のファイルは掃除しない")
    func ownedAutorenameFilesAreKept() {
        let result = plan(
            items: [item("L-a", state: .copied, sharedPath: "/mosaicshare/trip/img (1).jpg", sharedHash: "h1")],
            backup: ["a": .init(dropboxPath: "/mosaicphotos/img.jpg", contentHash: "h1")],
            remote: [
                .init(pathLower: "/mosaicshare/trip/img.jpg", contentHash: "h2"),
                .init(pathLower: "/mosaicshare/trip/img (1).jpg", contentHash: "h1"),
            ])
        #expect(result.duplicatesToDelete.isEmpty)
    }

    /// ⚠️ 検証: 元のファイル名自体が "name (1).ext" の**別写真**が、たまたま同じフォルダに
    /// "name.ext" があるだけで「重複」と誤判定されないか（コピー記録がまだ無い状態）。
    /// ⚠️ 重複大量生成の再発防止（レビュー指摘）。バックアップ照合で記録が消えると
    /// アイテムは `waitingBackup` へ戻るが **sharedPath は残る**。このとき自分の既存コピー名を
    /// 再利用できないと、セット全体が " 2" 付きで複製される（過去 2 回の暴走と同種）。
    @Test("sharedPath を保持したまま再コピーに回っても、同じ宛先を再利用する")
    func reusesOwnDestinationOnRecopy() {
        for state in [ShareItemState.waitingBackup, .failed, .pending] {
            let result = plan(
                items: [item("L-a", state: state, sharedPath: "/mosaicshare/trip/a.jpg")],
                backup: ["a": .init(dropboxPath: "/mosaicphotos/a.jpg", contentHash: "h1")],
                remote: [])   // 共有側には無い＝コピーが必要
            #expect(result.copies.map(\.toPath) == ["/mosaicshare/trip/a.jpg"],
                    "\(state) で自分のコピー先を再利用せず複製した: \(result.copies.map(\.toPath))")
        }
    }

    /// 「今回の計画が使う予定のパス」は掃除しない（採用直後に消す経路の防止）。
    @Test("同じ回に採用したファイルを掃除対象にしない")
    func doesNotDeleteWhatItJustAdopted() {
        let result = plan(
            items: [item("C-/src/img.jpg"), item("C-/src/img (1).jpg")],
            remote: [
                .init(pathLower: "/mosaicshare/trip/img.jpg", contentHash: "hSAME"),
                .init(pathLower: "/mosaicshare/trip/img (1).jpg", contentHash: "hSAME"),
            ])
        let adopted = Set(result.adoptions.map(\.sharedPathLower))
        for path in result.duplicatesToDelete {
            #expect(!adopted.contains(path), "採用したファイルを削除しようとしている: \(path)")
        }
    }

    @Test("元名が (N) 形式の別写真は掃除対象にしない（中身が違えば残す）")
    func doesNotDeleteDistinctPhotoNamedLikeDuplicate() {
        let result = plan(
            items: [item("C-/src/img.jpg", state: .copied,
                         sharedPath: "/mosaicshare/trip/img.jpg", sharedHash: "hA"),
                    // まだコピー記録が無い（pending）別写真。元ファイル名が "img (1).jpg"。
                    item("C-/src/img (1).jpg", state: .pending)],
            remote: [
                .init(pathLower: "/mosaicshare/trip/img.jpg", contentHash: "hA"),
                // 中身は hB＝img.jpg とは別写真。
                .init(pathLower: "/mosaicshare/trip/img (1).jpg", contentHash: "hB"),
            ])
        #expect(!result.duplicatesToDelete.contains("/mosaicshare/trip/img (1).jpg"),
                "中身の違う別写真を重複として削除しようとしている")
    }

    /// 削除は不可逆なので、フォルダ名の異常は**必ず nil**（呼び出し側が中断する）。
    @Test("不正なフォルダ名は setFolderPath が拒否する（共有ルート全消しの防止）")
    func setFolderPathRejectsUnsafeNames() {
        #expect(SharePlanning.setFolderPath(shareRoot: "/MosaicShare", folderName: "Trip")
                == "/MosaicShare/Trip")
        // 末尾スラッシュのルートも正規化される。
        #expect(SharePlanning.setFolderPath(shareRoot: "/MosaicShare/", folderName: "Trip")
                == "/MosaicShare/Trip")
        // 危険な名前はすべて拒否。
        for bad in ["", "   ", "..", ".", "a/b", "a\\b"] {
            #expect(SharePlanning.setFolderPath(shareRoot: "/MosaicShare", folderName: bad) == nil,
                    "危険なフォルダ名を通した: \(bad)")
        }
        // ルート側が壊れている場合も拒否（ルート直下を消しに行かない）。
        #expect(SharePlanning.setFolderPath(shareRoot: "", folderName: "Trip") == nil)
        #expect(SharePlanning.setFolderPath(shareRoot: "/", folderName: "Trip") == nil)
    }

    @Test("autorenameBase の解析")
    func autorenameBaseParsing() {
        #expect(SharePlanning.autorenameBase(of: "/s/t/img (3).jpg") == "/s/t/img.jpg")
        #expect(SharePlanning.autorenameBase(of: "/s/t/img.jpg") == nil)
        #expect(SharePlanning.autorenameBase(of: "/s/t/(1).jpg") == nil)
        #expect(SharePlanning.autorenameBase(of: "/s/t/img (a).jpg") == nil)
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

// MARK: - SharedAlbumDiscovery

@Suite("SharedAlbumDiscovery (受信アルバムの発見)")
struct SharedAlbumDiscoveryTests {

    @Test("家族フォルダ直下のサブフォルダ単位にグルーピングされる")
    func groupsBySubfolder() {
        let albums = SharedAlbumDiscovery.albums(
            itemPaths: ["/MosaicShare/Trip/a.jpg", "/MosaicShare/Trip/b.jpg",
                        "/MosaicShare/Kids/c.jpg", "/Other/x.jpg"],
            familyRoots: ["/mosaicshare"])
        #expect(albums.map(\.name) == ["Kids", "Trip"])
        #expect(albums.first { $0.name == "Trip" }?.photoCount == 2)
        #expect(albums.first { $0.name == "Trip" }?.folderPath == "/MosaicShare/Trip")
        #expect(albums.first { $0.name == "Trip" }?.coverPath == "/MosaicShare/Trip/a.jpg")
    }

    @Test("ルート直下の写真はフォルダ自身のアルバムになる（セットを直接共有された構成）")
    func rootItselfAsAlbum() {
        let albums = SharedAlbumDiscovery.albums(
            itemPaths: ["/SharedSet/a.jpg", "/SharedSet/b.jpg"],
            familyRoots: ["/SharedSet"])
        #expect(albums.count == 1)
        #expect(albums.first?.name == "SharedSet")
        #expect(albums.first?.photoCount == 2)
    }

    @Test("複数ルート・大文字小文字の違いを吸収し、深い階層もセット単位に畳む")
    func multiRootAndCase() {
        let albums = SharedAlbumDiscovery.albums(
            itemPaths: ["/mosaicshare/Trip/sub/deep.jpg", "/Family2/Kids/a.jpg"],
            familyRoots: ["/MosaicShare", "/family2"])
        #expect(albums.map(\.name).sorted() == ["Kids", "Trip"])
        #expect(albums.first { $0.name == "Trip" }?.photoCount == 1)
    }

    @Test("ルート未設定・該当なしは空")
    func emptyCases() {
        #expect(SharedAlbumDiscovery.albums(itemPaths: ["/a.jpg"], familyRoots: []).isEmpty)
        #expect(SharedAlbumDiscovery.albums(itemPaths: [], familyRoots: ["/x"]).isEmpty)
    }
}

// MARK: - ShareSourceKey

@Suite("ShareSourceKey (作成元キーの符号化)")
struct ShareSourceKeyTests {

    @Test("符号化 → 復号で往復する")
    func roundTrip() {
        let uuid = UUID()
        let cases: [ShareSourceKey] = [.album("trip-2025"), .person(42), .group(uuid)]
        for key in cases {
            #expect(ShareSourceKey(key.encoded) == key, "往復しない: \(key.encoded)")
        }
    }

    @Test("不正な文字列は nil（旧セットの sourceKey=nil と区別できる）")
    func rejectsInvalid() {
        for raw in ["", "unknown-1", "person-abc", "pgroup-not-a-uuid", "album-"] {
            #expect(ShareSourceKey(raw) == nil, "不正な値を通した: \(raw)")
        }
    }

    @Test("接頭辞が他と衝突しない")
    func prefixesAreDistinct() {
        #expect(ShareSourceKey.album("x").encoded.hasPrefix("album-"))
        #expect(ShareSourceKey.person(1).encoded.hasPrefix("person-"))
        #expect(ShareSourceKey.group(UUID()).encoded.hasPrefix("pgroup-"))
    }
}

@Suite("ShareSidecar 日付検証（外部入力）")
struct ShareSidecarDateTests {

    private var hash: String { String(repeating: "cd", count: 32) }
    private var embedding: String {
        Data(repeating: 0x11, count: ShareSidecar.embeddingByteCount).base64EncodedString()
    }

    /// NaN/巨大値の撮影日をそのまま Date にすると、人物の時期分割で日付ソートの
    /// strict weak ordering が壊れる。範囲外は「日付なし」に落とす。
    ///
    /// ⚠️ NaN は JSON で表現できない（エンコード時点で弾かれる）ので、JSON を経由せず
    /// `validate` を直接叩いて検証する。巨大値は JSON で表現できるため実際に届き得る。
    @Test("非有限・非現実的な撮影日は nil に落とす（顔自体は残す）")
    func dropsImplausibleCaptureDates() {
        func face(_ d: Double?) -> ShareSidecar.Face {
            .init(x: 0.1, y: 0.1, w: 0.2, h: 0.2, e: embedding, q: 0.9, s: nil, d: d)
        }
        let entry = ShareSidecar.Entry(faces: [face(.nan), face(1e300), face(-1e300),
                                               face(1_750_000_000)])
        let cleaned = ShareSidecar.validate(entry)
        let faces = cleaned?.faces
        #expect(faces?.count == 4, "顔そのものは残すべき")
        #expect(faces?.prefix(3).allSatisfy { $0.d == nil } == true, "不正な日付が残った")
        #expect(faces?.last?.d == 1_750_000_000, "正常な日付まで落とした")
    }

    /// 巨大値は JSON 経由でも実際に届く（NaN と違ってエンコードできる）。
    @Test("JSON 経由でも範囲外の撮影日は落ちる")
    func dropsImplausibleDatesThroughJSON() {
        let entry = ShareSidecar.Entry(faces: [
            .init(x: 0.1, y: 0.1, w: 0.2, h: 0.2, e: embedding, q: 0.9, s: nil, d: 1e300)])
        let file = ShareSidecar.File(versions: .init(tag: 3, perception: 8, face: 4),
                                     entries: [hash: entry])
        guard let data = ShareSidecar.encode(file) else {
            Issue.record("エンコードできなかった"); return
        }
        let decoded = ShareSidecar.decodeValidated(data)
        #expect(decoded?.entries[hash]?.faces?.first?.d == nil)
    }
}
