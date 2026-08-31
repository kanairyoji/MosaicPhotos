import Foundation
import Testing
@testable import BackupKit
import DropboxCore

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

/// ⚠️ **同名でも種類が違えば別のアルバム**（実フィードバック 8/31: ピープルアルバムと同じ名前を
/// AI アルバムに付けたら、AI アルバムまで勝手に共有された）。
/// 人物由来の共有セットは clusterID が当てにならなくなると `sourceKey` を外すので、
/// そこから先は**フォルダ名の接頭辞だけが種類を知っている**。
@Suite("共有セットの種類（フォルダ名から復元）")
struct ShareKindFromFolderTests {

    @Test("接頭辞から種類を読み取る")
    func readsKindFromPrefix() {
        #expect(ShareNaming.kind(fromFolderName: "Album-沖縄旅行") == .album)
        #expect(ShareNaming.kind(fromFolderName: "Person-太郎") == .person)
        #expect(ShareNaming.kind(fromFolderName: "People-金居家") == .group)
    }

    @Test("接頭辞の無い旧セットは種類不明のまま")
    func legacyFolderHasNoKind() {
        #expect(ShareNaming.kind(fromFolderName: "沖縄旅行") == nil)
        #expect(ShareNaming.kind(fromFolderName: "") == nil)
    }

    @Test("作成時に付けた接頭辞と読み取りが往復する")
    func roundTrips() {
        for kind in [ShareSourceKey.Kind.album, .person, .group] {
            let folder = ShareNaming.folderName("家族", kind: kind)
            #expect(ShareNaming.kind(fromFolderName: folder) == kind,
                    "作成時の接頭辞を読み戻せない（種類の判別が効かない）")
        }
    }
}

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

    /// アルバムの単位は「**写真が直接入っているフォルダ**」（階層の深さに依存しない）。
    /// 提供側は `<root>/<端末フォルダ>/<セット名>/` に置くため、決め打ちの階層数では拾えない。
    @Test("複数ルート・大文字小文字を吸収し、写真の親フォルダをアルバムにする")
    func multiRootAndCase() {
        let albums = SharedAlbumDiscovery.albums(
            itemPaths: ["/mosaicshare/iPhone-AAAA/Trip/a.jpg", "/Family2/Kids/a.jpg"],
            familyRoots: ["/MosaicShare", "/family2"])
        #expect(albums.map(\.name).sorted() == ["Kids", "Trip"])
        #expect(albums.first { $0.name == "Trip" }?.photoCount == 1)
        // 端末フォルダを挟んだ構成では、提供者が分かる。
        #expect(albums.first { $0.name == "Trip" }?.providerName == "iPhone-AAAA")
        #expect(albums.first { $0.name == "Kids" }?.providerName == nil)
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

@Suite("共有セットのライフサイクル（実ユースケース）")
@MainActor
struct ShareSetLifecycleTests {

    /// 反映を伴わない（ネットワークを触らない）エンジンを作る。
    private func makeEngine() -> (ShareSyncEngine, BackupStore) {
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        // provide を OFF にしておくと syncNow は即 return するのでネットワークを触らない。
        // ⚠️ `.standard` ではなく専用スイート——並列に走る反映テストの provide を消してしまう。
        let defaults = UserDefaults(suiteName: "share-lifecycle-\(UUID().uuidString)") ?? .standard
        defaults.set(false, forKey: ShareSettingsKeys.provideEnabled)
        let engine = ShareSyncEngine(tokenProvider: NeverTokenProvider(),
                                     storeProvider: { store },
                                     httpClient: NeverHTTPClient(), defaults: defaults)
        return (engine, store)
    }

    /// ⚠️ 実フィードバック: グループを解除して**同じ名前で作り直す**と ID が変わる。
    /// このとき別セットを作ると Dropbox 上に「名前 2」ができ、同じ写真がもう一組
    /// コピーされる（容量が倍）。既存セットを再利用して更新すること。
    @Test("同じ名前で作り直しても新しいセットを増やさず、既存セットを更新する")
    func recreatingGroupReusesExistingSet() async {
        let (engine, store) = makeEngine()
        let firstID = UUID(), secondID = UUID()

        _ = await engine.createSet(name: "Group A", refKeys: ["L-a", "L-b"],
                                   sourceKey: ShareSourceKey.group(firstID).encoded)
        #expect(await store.allShareSets().count == 1)

        // 解除 → 同名・同メンバーで作り直し（新しい UUID）。
        _ = await engine.createSet(name: "Group A", refKeys: ["L-a", "L-b"],
                                   sourceKey: ShareSourceKey.group(secondID).encoded)
        let sets = await store.allShareSets()
        #expect(sets.count == 1, "セットが増えた（Dropbox 上に重複フォルダができる）: \(sets.count)")
        #expect(sets.first?.sourceKey == ShareSourceKey.group(secondID).encoded,
                "作成元キーが新しい ID に更新されていない")
        #expect(await store.shareItems(setID: sets[0].id).count == 2)
    }

    @Test("同じ作成元をもう一度共有すると、メンバーが今の内容へ入れ替わる")
    func resharingUpdatesMembers() async {
        let (engine, store) = makeEngine()
        let groupID = UUID()
        let key = ShareSourceKey.group(groupID).encoded

        _ = await engine.createSet(name: "G", refKeys: ["L-a", "L-b"], sourceKey: key)
        // メンバーが変わった状態で再共有（b が抜けて c が入る）。
        _ = await engine.createSet(name: "G", refKeys: ["L-a", "L-c"], sourceKey: key)

        let sets = await store.allShareSets()
        #expect(sets.count == 1)
        let keys = Set(await store.shareItems(setID: sets[0].id).map(\.refKey))
        #expect(keys == ["L-a", "L-c"], "現在の内容に追従していない: \(keys)")
    }
}

/// テスト用: トークンを返さない（ネットワーク経路へ進ませない）。
private final class NeverTokenProvider: AccessTokenProvider, @unchecked Sendable {
    func freshAccessToken() async throws -> String { throw URLError(.userAuthenticationRequired) }
}

private struct NeverHTTPClient: HTTPClient, Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

@Suite("フォルダ名の種類接頭辞")
struct ShareFolderPrefixTests {

    /// Dropbox 上で何のアルバムか分かり、種類違いの同名でも衝突しない（実フィードバック）。
    @Test("種類ごとに接頭辞が付く")
    func prefixesByKind() {
        #expect(ShareNaming.folderName("木村家", kind: .group) == "People-木村家")
        #expect(ShareNaming.folderName("沖縄旅行", kind: .album) == "Album-沖縄旅行")
        #expect(ShareNaming.folderName("ハナコ", kind: .person) == "Person-ハナコ")
    }

    @Test("同名でも種類が違えばフォルダが衝突しない（連番が出ない）")
    func noCollisionAcrossKinds() {
        let group = ShareNaming.folderName("沖縄", kind: .group)
        let album = ShareNaming.folderName("沖縄", kind: .album, existing: [group])
        #expect(group == "People-沖縄")
        #expect(album == "Album-沖縄", "種類違いなのに連番が付いた: \(album)")
    }

    @Test("作成元が不明なら接頭辞なし（手動作成・旧セット）")
    func noPrefixWithoutKind() {
        #expect(ShareNaming.folderName("Trip", kind: nil) == "Trip")
    }

    @Test("使えない文字は接頭辞の後ろで置換される")
    func sanitizesAfterPrefix() {
        #expect(ShareNaming.folderName("Kids/Trip:2025", kind: .album) == "Album-Kids_Trip_2025")
    }
}
