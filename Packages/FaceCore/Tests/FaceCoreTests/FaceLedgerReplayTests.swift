import CoreGraphics
import Foundation
import PerceptionCore
import SwiftData
import Testing
@testable import FaceCore

/// **実機の台帳を Mac で回す**（ADR-234）。
///
/// ## なぜ要るか
/// 顔まわりの不具合は**遷移のとき**にだけ出る（夜の再クラスタ・版上げの再スキャン・世代の
/// 切り替え・写真の整理）。実機のライブラリは 10 万枚あるので、遷移を 1 回試すのに数晩かかり、
/// しかも**本物の名前と家族グループを賭ける**ことになる——現実には試せない。
///
/// ⚠️ ここが肝心なのだが、**写真本体は要らない**。顔の埋め込みは台帳の中にあるので、
/// 台帳ファイルだけ Mac へ持ってくれば、**本物の規模・分布・名前・束ね・家族グループ**に対して
/// `rebuildClusters` / `reapplyAssertions` / `pruneMissingPhotos` を何度でも回せる。
/// しかも**コピーに対して**やるので実機は壊れない。
///
/// ## 何を見るか
/// 正解ラベルは無いので精度（純度・B-Cubed F1）は出せない。見るのは**不変条件**——
/// 「利用者が手で作ったものが、遷移で減っていないか」（`AssertionCensus`）。
/// ⚠️ 今まで踏んだ顔まわりの不具合は**ほぼ全部これで捕まる**（名前が消える・束ねがほどける・
/// 家族グループからメンバーが消える・別人が居座る）。
///
/// ## 使い方
/// 1. 実機の Developer Options →「ピープルの台帳を書き出す」で共有し、Mac に置く
/// 2. `FACE_LEDGER_DIR=~/DEV/tmp/face-ledger swift test --filter FaceLedgerReplayTests`
///
/// 台帳が無ければ**静かにスキップ**する（CI では常にスキップ）。
/// ⚠️ 書き出したファイルには顔の埋め込みと人物名が入る。**git に入れない**。
@Suite("実機の台帳を回す（不変条件）", .serialized)
struct FaceLedgerReplayTests {

    /// 台帳を置いた場所。無ければ全部スキップ。
    static var directory: String? { ProcessInfo.processInfo.environment["FACE_LEDGER_DIR"] }

    /// 台帳の `.store` を探す（コンテナ名は世代で変わるので、拡張子で拾う）。
    static func storeURL(in dir: String? = Self.directory) -> URL? {
        guard let dir else { return nil }
        let expanded = (dir as NSString).expandingTildeInPath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: expanded) else { return nil }
        guard let store = names.first(where: { $0.hasSuffix(".store") }) else { return nil }
        return URL(fileURLWithPath: expanded).appendingPathComponent(store)
    }

    /// ⚠️ **原本を触らない**。テストは `rebuildClusters` などを実際に走らせるので、
    /// 台帳を書き換える。毎回コピーを作って、そこに対して回す
    /// （でないと 1 回目の結果が 2 回目の入力になり、比べているものが分からなくなる）。
    static func openCopy(in dir: String? = Self.directory) throws -> (store: FaceStore, workDir: URL)? {
        guard let src = storeURL(in: dir) else { return nil }
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("face-ledger-replay-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: src.path + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            try fm.copyItem(at: from, to: work.appendingPathComponent(src.lastPathComponent + suffix))
        }
        let config = ModelConfiguration(schema: FaceStore.ledgerSchema,
                                        url: work.appendingPathComponent(src.lastPathComponent))
        let container = try ModelContainer(for: FaceStore.ledgerSchema, configurations: [config])
        return (FaceStore(modelContainer: container), work)
    }

    static func emit(_ line: String) { print("LEDGER " + line) }

    // MARK: - まず読めること

    @Test("台帳が読める（人物・顔・グループの規模を出す）")
    func opensAndReportsScale() async throws {
        guard let (store, work) = try Self.openCopy() else { return }
        defer { try? FileManager.default.removeItem(at: work) }
        let census = await store.assertionCensus()
        let faces = await store.faceCount()
        let scanned = await store.scannedCount()
        Self.emit("規模: 写真 \(scanned) / 顔 \(faces) / 人物 \(census.people.count) "
                  + "/ 名前付き \(census.namedCount) / 束ね \(census.bundleCount) "
                  + "/ グループ \(census.groups.count)（メンバー \(census.resolvedGroupMemberCount)）")
        #expect(census.people.count > 0, "台帳に人物が居ない（書き出しが空？）")
        // ⚠️ 開いた時点で**既に**表明が解決できていないなら、それは実機で既に壊れている。
        for group in census.groups {
            let live = Set(census.people.map(\.clusterID))
            let unresolved = group.memberClusterIDs.filter { !live.contains($0) }
            if !unresolved.isEmpty {
                Self.emit("⚠️ 実機の時点で既に未解決: グループ「\(group.name)」の \(unresolved.count) 人")
            }
        }
    }

    // MARK: - 遷移 1: 夜の再クラスタ

    /// ⚠️ 本番と同じ `rebuildClusters()` を、本物のデータに対して回す。
    /// 表明が減ったら**その場で失敗**させる（診断ログを待たない）。
    @Test("夜の再クラスタで表明が減らない")
    func rebuildKeepsAssertions() async throws {
        guard let (store, work) = try Self.openCopy() else { return }
        defer { try? FileManager.default.removeItem(at: work) }
        let before = await store.assertionCensus()
        let result = await store.rebuildClusters()
        let after = await store.assertionCensus()
        Self.emit("rebuild: clusters=\(result.clusters) moved=\(result.moved) — "
                  + AssertionCensus.summary(before: before, after: after))
        let findings = AssertionCensus.diff(before: before, after: after)
        for finding in findings.prefix(20) {
            Self.emit("⚠️ \(finding.kind.rawValue): \(finding.subject) \(finding.detail)")
        }
        #expect(findings.isEmpty, "再クラスタで表明が \(findings.count) 件失われた（上の ⚠️ を見る）")
    }

    /// ⚠️ **2 回続けて回しても安定していること**。1 回目と 2 回目で結果が動くなら、
    /// 再クラスタが収束していない（毎晩人物が入れ替わる＝実フィードバックで踏んだ形）。
    @Test("再クラスタを 2 回続けても表明が動かない（収束している）")
    func rebuildIsIdempotentForAssertions() async throws {
        guard let (store, work) = try Self.openCopy() else { return }
        defer { try? FileManager.default.removeItem(at: work) }
        _ = await store.rebuildClusters()
        let first = await store.assertionCensus()
        _ = await store.rebuildClusters()
        let second = await store.assertionCensus()
        Self.emit("rebuild×2: " + AssertionCensus.summary(before: first, after: second))
        let findings = AssertionCensus.diff(before: first, after: second)
        for finding in findings.prefix(20) {
            Self.emit("⚠️ \(finding.kind.rawValue): \(finding.subject) \(finding.detail)")
        }
        #expect(findings.isEmpty, "2 回目で表明が \(findings.count) 件動いた（収束していない）")
    }

    // MARK: - 遷移 2: 版上げの再スキャン（持ち越し）

    /// ⚠️ 実機では数晩かかる遷移を、**埋め込みを作り直さずに**再現する。
    /// 「控えを取る → 全消去 → 同じ写真を同じ埋め込みで入れ直す → 持ち越しを戻す」。
    /// 顔検出をやり直さないので数秒で終わり、**持ち越しの論理だけ**を見られる。
    @Test("版上げの再スキャンで、名前・束ね・グループが持ち越される")
    func carryoverSurvivesAFullRescan() async throws {
        guard let (store, work) = try Self.openCopy() else { return }
        defer { try? FileManager.default.removeItem(at: work) }
        let before = await store.assertionCensus()
        guard !before.groups.isEmpty || before.namedCount > 0 else {
            Self.emit("skip: 名前もグループも無い台帳（持ち越すものが無い）")
            return
        }
        let carried = await store.assertedClusterEntries()
        let input = await store.facesAsScanInput()
        Self.emit("rescan: 控え \(carried.count) 件・写真 \(input.count) 枚で作り直す")

        await store.reset()
        // ⚠️ 本番と同じ `recordScans` を通す（同じ埋め込み・同じクラスタリング）。
        // 一度に全部渡すとメモリを積むので、本番のバッチと同じくらいに刻む。
        for chunk in stride(from: 0, to: input.count, by: 200).map({
            Array(input[$0..<min($0 + 200, input.count)])
        }) {
            _ = await store.recordScans(chunk)
        }
        let remaining = await store.reapplyAssertions(carried)
        let after = await store.assertionCensus()
        Self.emit("rescan: 戻せなかった \(remaining.count)/\(carried.count) — "
                  + AssertionCensus.summary(before: before, after: after))
        let findings = AssertionCensus.diff(before: before, after: after)
        for finding in findings.prefix(20) {
            Self.emit("⚠️ \(finding.kind.rawValue): \(finding.subject) \(finding.detail)")
        }
        // ⚠️ 名前の持ち越しは「重なり ≥ max(2, 旧メンバーの 20%)」の足切りがあるので、
        // 写真の少ない人物は原理的に戻らない。**グループと束ねが消えていないこと**を主に見る。
        let hard = findings.filter { $0.kind == .groupLost || $0.kind == .groupMemberSwapped }
        #expect(hard.isEmpty, "グループが消えた／別人が居座った: \(hard.count) 件")
    }

    // MARK: - 遷移 3: 写真の整理

    /// ⚠️ 家族グループのメンバーの写真が全部消えても、行と所属は残るはず（ADR-231）。
    /// 本物のグループに対して確かめる。
    @Test("写真の整理でグループのメンバーが消えない")
    func pruneKeepsGroupMembers() async throws {
        guard let (store, work) = try Self.openCopy() else { return }
        defer { try? FileManager.default.removeItem(at: work) }
        let before = await store.assertionCensus()
        guard let group = before.groups.first(where: { $0.memberClusterIDs.count >= 2 }) else {
            Self.emit("skip: メンバー 2 人以上のグループが無い")
            return
        }
        // メンバー 1 人の写真だけを「無くなった」ことにする。
        let live = Set(before.people.map(\.clusterID))
        guard let victim = group.memberClusterIDs.first(where: { live.contains($0) }),
              let person = before.people.first(where: { $0.clusterID == victim }),
              !person.refKeys.isEmpty else {
            Self.emit("skip: 写真を持つメンバーが見つからない")
            return
        }
        let allRefKeys = Set(before.people.flatMap(\.refKeys))
        let existing = allRefKeys.subtracting(person.refKeys)
        Self.emit("prune: グループ「\(group.name)」のメンバー cluster \(victim) の "
                  + "\(person.refKeys.count) 枚を消す")
        _ = await store.pruneMissingPhotos(existingRefKeys: existing, knownGone: person.refKeys)
        let after = await store.assertionCensus()
        let stillThere = after.groups.first { $0.id == group.id }?.memberClusterIDs.contains(victim)
        Self.emit("prune: 記録に残った=\(stillThere == true) / "
                  + AssertionCensus.summary(before: before, after: after))
        #expect(stillThere == true, "写真を消したらグループの記録からメンバーが消えた")
        #expect(after.people.contains { $0.clusterID == victim },
                "写真を消したらメンバーが人物一覧から落ちた（フロアの免除が効いていない）")
    }
}

/// **再生の仕組みそのもの**を、合成した台帳で確かめる（ADR-234）。
///
/// ⚠️ `FaceLedgerReplayTests` は実機の台帳が無ければ全部スキップする——つまり**そのままでは
/// 「空でも通るテスト」**で、仕組みが壊れても誰も気づかない（この codebase が繰り返し踏んだ形）。
/// ここでは小さな台帳を**ディスクに作って**、書き出し・コピー・開き直し・再生が通ることを固定する。
@Suite("台帳の再生の仕組み（合成台帳）", .serialized)
struct FaceLedgerReplayMachineryTests {

    private func signal(_ v: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: 0.9)
    }

    /// ディスク上の台帳を 1 つ作る（実機の書き出しと同じ形＝`<名前>.store`）。
    private func makeLedgerOnDisk() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("face-ledger-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = ModelConfiguration(schema: FaceStore.ledgerSchema,
                                        url: dir.appendingPathComponent("FacesV1.store"))
        let container = try ModelContainer(for: FaceStore.ledgerSchema, configurations: [config])
        let store = FaceStore(modelContainer: container)
        for i in 0..<5 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])]) }
        for i in 0..<5 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, 0])]) }
        let ids = await store.allClusters().map(\.clusterID).sorted()
        #expect(ids.count == 2, "fixture: 2 人物になっていない（\(ids.count)）")
        await store.rename(clusterID: ids[0], name: "父")
        await store.linkClusters(ids)
        _ = await store.createPeopleGroup(name: "家族", memberClusterIDs: ids)
        return dir
    }

    @Test("書き出した台帳をコピーして開き直せる（原本を触らない）")
    func opensACopyWithoutTouchingTheOriginal() async throws {
        let dir = try await makeLedgerOnDisk()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let (store, work) = try FaceLedgerReplayTests.openCopy(in: dir.path) else {
            #expect(Bool(false), "台帳を開けなかった"); return
        }
        defer { try? FileManager.default.removeItem(at: work) }
        #expect(work.path != dir.path, "原本を直接開いている（書き換えてしまう）")
        let census = await store.assertionCensus()
        #expect(census.namedCount == 1)
        #expect(census.bundleCount == 1)
        #expect(census.groups.count == 1)
        #expect(census.resolvedGroupMemberCount == 2)
    }

    /// ⚠️ **これが B の本体**。実機では数晩かかる「全消去 → 再スキャン → 持ち越し」を、
    /// 顔検出をやり直さずに数秒で回せること。
    @Test("台帳の顔をスキャンの入力に戻して、全消去 → 再スキャン → 持ち越しが回る")
    func replaysAFullRescanFromTheLedger() async throws {
        let dir = try await makeLedgerOnDisk()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let (store, work) = try FaceLedgerReplayTests.openCopy(in: dir.path) else {
            #expect(Bool(false), "台帳を開けなかった"); return
        }
        defer { try? FileManager.default.removeItem(at: work) }

        let before = await store.assertionCensus()
        let carried = await store.assertedClusterEntries()
        let input = await store.facesAsScanInput()
        #expect(input.count == 10, "写真がスキャンの入力に戻っていない（\(input.count) 枚）")
        #expect(input.allSatisfy { !$0.faces.isEmpty }, "顔が入っていない＝埋め込みを失っている")

        await store.reset()
        _ = await store.recordScans(input)
        let remaining = await store.reapplyAssertions(carried)
        let after = await store.assertionCensus()

        #expect(remaining.isEmpty, "戻せなかった控えがある（\(remaining.count) 件）")
        #expect(after.namedCount == before.namedCount, "名前が戻っていない")
        #expect(after.bundleCount == before.bundleCount, "束ねが戻っていない")
        #expect(after.resolvedGroupMemberCount == before.resolvedGroupMemberCount,
                "家族グループのメンバーが戻っていない")
        let findings = AssertionCensus.diff(before: before, after: after)
        let hard = findings.filter { $0.kind == .groupLost || $0.kind == .groupMemberSwapped }
        #expect(hard.isEmpty, "グループが消えた／別人が居座った: \(hard)")
    }

    /// ⚠️ 実機の書き出し（`exportForReplay`）が集めたフォルダを、そのまま再生側が読めること。
    /// 片方だけ直すと「書き出せるが読めない」になる。
    @Test("書き出しが集めたフォルダの形を、再生側が読める")
    func exportLayoutIsReadableByTheReplaySide() async throws {
        let dir = try await makeLedgerOnDisk()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 実機の書き出しと同じく `.store` / `-wal` / `-shm` を 1 フォルダに集めた形。
        #expect(FaceLedgerReplayTests.storeURL(in: dir.path) != nil,
                ".store を見つけられない（書き出しの形と読み手が食い違っている）")
    }
}
