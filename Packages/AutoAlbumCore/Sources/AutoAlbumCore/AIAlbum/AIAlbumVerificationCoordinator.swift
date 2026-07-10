import Foundation
import MosaicSupport

/// P2: 候補メンバーの**証拠ゲート＋LLM 審査（self-consistency）**。
/// 既存の `AlbumCandidateVerifier`（FM）を下位に使い、証拠行の組み立て・unsure の再判定・
/// 多数決の集計をここに集約する（`AIAlbumService` から分離）。
@MainActor
final class AIAlbumVerificationCoordinator {
    /// シーンタグ・キャプションのストア（証拠行の材料＝検索の一次ランキングと同一の台帳）。
    private let tagStore: TagStore?
    /// P2: LLM 審査員（FM 無し端末では nil＝審査スキップ）。
    private let verifier: AlbumCandidateVerifier?
    /// 顔スキャンの実測（refKey → 顔数）を返す seam（`AIAlbumService` 経由で Composition Root から結線）。
    var faceCountsProvider: (@Sendable () async -> [String: Int])?

    init(tagStore: TagStore?, verifier: AlbumCandidateVerifier? = makeDefaultVerifier()) {
        self.tagStore = tagStore
        self.verifier = verifier
    }

    // MARK: - 純ロジック（テスト対象）

    /// 証拠ゲート（純・テスト対象）: 除外条件つきアルバムでは、**検証可能な証拠**
    /// （シーンタグ / 顔実測 / キャプション）を 1 つも持たない写真をメンバーにしない。
    /// 「人が写っていない」と主張できない写真を弱い CLIP 対比だけで通すと漏れる（実障害）。
    /// 証拠は夜間バッチで増えるため、アルバムは索引の進行とともに自然に埋まっていく。
    nonisolated static func evidenceGated(_ members: [EnrichedPhoto],
                                          tags: [String: [String]],
                                          faceCounts: [String: Int],
                                          captions: [String: String]) -> [EnrichedPhoto] {
        members.filter { photo in
            !(tags[photo.id] ?? []).isEmpty
                || faceCounts[photo.id] != nil
                || (captions[photo.id]?.isEmpty == false)
        }
    }

    /// LLM 審査（P2）用の証拠行（純・テスト対象）。写真を見られない審査員に渡す 1 行サマリ。
    nonisolated static func evidenceLine(index: Int, photo: EnrichedPhoto,
                                         tags: [String], caption: String?, faceCount: Int?) -> String {
        var parts: [String] = ["\(index))"]
        if let date = photo.captureDate {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            parts.append(f.string(from: date))
        }
        if let place = photo.placeName, !place.isEmpty { parts.append(place) }
        if let faceCount { parts.append("faces=\(faceCount)") }
        if !tags.isEmpty { parts.append("tags: " + tags.prefix(8).joined(separator: ", ")) }
        if let caption, !caption.isEmpty { parts.append("caption: " + caption) }
        return parts.joined(separator: " | ")
    }

    // MARK: - 証拠ゲート / LLM 審査

    /// 除外条件つきアルバムの**証拠ゲート**: タグ/顔実測/キャプションを 1 つも持たない写真は
    /// メンバーにしない（「〜が写っていない」を検証できないため）。除外なしのアルバムは素通し。
    func evidenceGatedIfExcluding(_ members: [EnrichedPhoto],
                                  spec: QuerySpec) async -> [EnrichedPhoto] {
        guard !spec.allContentTerms.exclude.isEmpty, !members.isEmpty else { return members }
        let keys = members.map(\.id)
        let tags = await tagStore?.tags(forRefKeys: keys) ?? [:]
        let captions = await tagStore?.captions(forRefKeys: keys) ?? [:]
        let faces = await faceCountsProvider?() ?? [:]
        let gated = Self.evidenceGated(members, tags: tags, faceCounts: faces, captions: captions)
        if gated.count != members.count {
            Diagnostics.mark("aialbum.evidenceGate: \(members.count) → \(gated.count) (deferred until indexed)")
        }
        return gated
    }

    /// 候補（上位 60 件）の証拠行（日付・場所・顔数・タグ・キャプション）を LLM が読み、
    /// 不適合を落とす。unsure は最大 2 回再判定して**多数決**（同数は keep＝安全側）。
    /// FM 無し・候補ゼロ・証拠皆無のときは素通し。
    func verified(_ members: [EnrichedPhoto], criteria: String) async -> [EnrichedPhoto] {
        guard let verifier, verifier.isAvailable, !members.isEmpty else { return members }
        let top = Array(members.prefix(60))
        let keys = top.map(\.id)
        let tags = await tagStore?.tags(forRefKeys: keys) ?? [:]
        let captions = await tagStore?.captions(forRefKeys: keys) ?? [:]
        // 証拠（タグ/キャプション）が全く無いなら審査しても意味がない（全部 unsure になるだけ）。
        guard !tags.isEmpty || !captions.isEmpty else { return members }
        let faces = await faceCountsProvider?() ?? [:]

        func line(_ index: Int, _ photo: EnrichedPhoto) -> String {
            Self.evidenceLine(index: index, photo: photo,
                              tags: tags[photo.id] ?? [],
                              caption: captions[photo.id],
                              faceCount: faces[photo.id])
        }

        var votes: [Int: [CandidateVerdict]] = [:]
        let first = await verifier.verify(criteria: criteria,
                                          lines: top.indices.map { line($0, top[$0]) })
        for i in top.indices { votes[i] = [first[i] ?? .keep] }

        // self-consistency: unsure だけ最大 2 回再判定して票を集める。
        var unsure = first.filter { $0.value == .unsure }.map(\.key).sorted()
        var round = 0
        while !unsure.isEmpty && round < 2 {
            round += 1
            let sub = await verifier.verify(criteria: criteria,
                                            lines: unsure.enumerated().map { j, i in line(j, top[i]) })
            for (j, i) in unsure.enumerated() { votes[i]?.append(sub[j] ?? .keep) }
            unsure = unsure.filter { majorityVerdict(votes[$0] ?? []) == .unsure }
        }

        let kept = top.indices.filter { majorityVerdict(votes[$0] ?? []) != .drop }.map { top[$0] }
        if kept.count != top.count {
            Diagnostics.mark("aialbum.verify: \(top.count) → kept \(kept.count) (rounds=\(round + 1))")
        }
        return kept + members.dropFirst(top.count)
    }
}
