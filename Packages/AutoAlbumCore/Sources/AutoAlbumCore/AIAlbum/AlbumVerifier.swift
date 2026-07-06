import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - P2: LLM 審査（エージェントの「目」）

/// 候補写真 1 件の判定。
public enum CandidateVerdict: Sendable, Equatable {
    case keep, drop, unsure
}

/// 候補写真の「証拠行」（タグ・キャプション・メタ）を読んで原文クエリとの適合を判定する審査員。
/// 写真そのものは見られないため、Vision タグ＋VLM キャプション＝疑似キャプションを目として使う。
public protocol AlbumCandidateVerifier: Sendable {
    var isAvailable: Bool { get }
    /// `lines[i]` は "i) 日付 | 場所 | faces=N | tags: … | caption: …" 形式。
    /// 返り値: 行番号 → 判定（返ってこなかった行は keep 扱い）。
    func verify(criteria: String, lines: [String]) async -> [Int: CandidateVerdict]
}

/// 既定の審査員（FM があれば LLM、無ければ nil＝審査スキップ）。
public func makeDefaultVerifier() -> AlbumCandidateVerifier? {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *), FoundationModelsVerifier.isAvailable {
        return FoundationModelsVerifier()
    }
    #endif
    return nil
}

/// self-consistency（多数決）の集計（純・テスト対象）。
/// 各ラウンドの判定を票として数え、**drop 票が keep 票より多い場合のみ** drop（同数・不明は keep＝安全側）。
public func majorityVerdict(_ votes: [CandidateVerdict]) -> CandidateVerdict {
    let drops = votes.filter { $0 == .drop }.count
    let keeps = votes.filter { $0 == .keep }.count
    if drops > keeps { return .drop }
    if keeps == 0 && drops == 0 { return .unsure }
    return .keep
}

#if canImport(FoundationModels)

@available(iOS 26.0, macOS 26.0, *)
struct FoundationModelsVerifier: AlbumCandidateVerifier {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var isAvailable: Bool { Self.isAvailable }

    @Generable
    struct GeneratedVerdicts {
        @Guide(description: "Line numbers of photos that clearly do NOT match the request. Empty if all match.")
        var drop: [Int]
        @Guide(description: "Line numbers you cannot judge from the given evidence. Empty if none.")
        var unsure: [Int]
    }

    func verify(criteria: String, lines: [String]) async -> [Int: CandidateVerdict] {
        guard !lines.isEmpty else { return [:] }
        let instructions = """
        You review photo candidates for the user's album request. Each line describes one photo \
        (date, place, detected face count, scene tags, and an optional caption). Judge ONLY from \
        the given evidence — do not guess beyond it. List the line numbers that clearly do NOT \
        match the request, and separately the ones you cannot judge. Lines you do not list are kept.
        """
        let prompt = "Request: \(criteria)\n\nPhotos:\n" + lines.joined(separator: "\n")
        // ⚠️ LLM は Task.detached で確実にオフメイン化（P0 と同じ方針）。
        let generated: GeneratedVerdicts? = await Task.detached(priority: .utility) {
            let session = LanguageModelSession(instructions: instructions)
            return try? await session.respond(to: prompt, generating: GeneratedVerdicts.self).content
        }.value
        guard let generated else { return [:] }
        var out: [Int: CandidateVerdict] = [:]
        for i in generated.drop where i >= 0 && i < lines.count { out[i] = .drop }
        for i in generated.unsure where i >= 0 && i < lines.count && out[i] == nil { out[i] = .unsure }
        return out
    }
}
#endif
