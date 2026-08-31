import Foundation

/// 共有セットのフォルダ名サニタイズ（純ロジック・テスト対象）。
/// Dropbox のパス制約（`/ \ : ? * " < > |` 不可・前後空白/ドット不可）に合わせ、
/// ユーザー入力のセット名を安全なフォルダ名へ変換する。
public enum ShareNaming {

    /// Dropbox で使えない・トラブルの元になる文字。
    private static let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|")

    /// 種類ごとのフォルダ名接頭辞。Dropbox 上で**何のアルバムか一目で分かる**ようにし、
    /// 併せて「AI アルバムとピープルグループに同じ名前」でもフォルダが衝突しないようにする
    /// （同じ種類の中では同名を作れないので、連番はもう出ない・実フィードバック）。
    public static func prefix(for kind: ShareSourceKey.Kind) -> String {
        switch kind {
        case .album:  return "Album-"
        case .person: return "Person-"
        case .group:  return "People-"
        }
    }

    /// フォルダ名から種類を読み取る（接頭辞なし＝旧セットは nil）。
    ///
    /// ⚠️ **`sourceKey` が無いセットの種類は、フォルダ名だけが知っている。**
    /// 人物由来のセットは clusterID が当てにならなくなった時点で `sourceKey` を外す
    /// （`detachPersonSources`）ため、その後は「種類不明」になり、名前だけの照合に落ちる。
    /// すると **AI アルバムに同じ名前を付けただけで、人物の共有に結び付いてしまう**
    /// （実フィードバック 8/31: 同名の AI アルバムが勝手に共有された）。
    /// フォルダ名の接頭辞は作成時と移行時に付くので、ここから種類を復元する。
    public static func kind(fromFolderName folderName: String) -> ShareSourceKey.Kind? {
        for kind in [ShareSourceKey.Kind.album, .person, .group]
        where folderName.hasPrefix(prefix(for: kind)) {
            return kind
        }
        return nil
    }

    /// 種類つきのフォルダ名（例: `People-木村家` / `Album-沖縄旅行`）。
    /// 作成元が分からない場合（手動作成・旧セット）は接頭辞なし。
    public static func folderName(_ name: String, kind: ShareSourceKey.Kind?,
                                  existing: [String] = []) -> String {
        let base = sanitize(name)
        let prefixed = kind.map { prefix(for: $0) + base } ?? base
        // 接頭辞込みで衝突する場合だけ連番（通常は種類＋同名禁止で発生しない）。
        return sanitize(prefixed, existing: existing)
    }

    /// 既存セットの**接頭辞なしフォルダ名**を、種類つきの名前へ移行する（純ロジック）。
    ///
    /// 接頭辞は作成時にしか付かないので、この機能より前に作った共有セットは
    /// `沖縄旅行` のままになる。作り直しを強いるとクラウド上の写真をコピーし直すことに
    /// なるため、**フォルダ名の変更（サーバーサイド move）で移行する**。
    ///
    /// - Returns: 移行後のフォルダ名。移行不要（すでに接頭辞つき・種類不明・名前が空）は nil。
    public static func migratedFolderName(current: String, name: String,
                                          kind: ShareSourceKey.Kind?,
                                          existing: [String]) -> String? {
        guard let kind else { return nil }
        let currentTrimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentTrimmed.isEmpty else { return nil }
        // すでに何らかの種類接頭辞が付いていれば触らない（ユーザーが手で付けた場合も含む）。
        let known = [ShareSourceKey.Kind.album, .person, .group].map { prefix(for: $0).lowercased() }
        guard !known.contains(where: { currentTrimmed.lowercased().hasPrefix($0) }) else { return nil }
        // 自分自身は衝突候補から外す（自分と衝突して連番が付くのを防ぐ）。
        let others = existing.filter { $0.lowercased() != currentTrimmed.lowercased() }
        let proposed = folderName(name, kind: kind, existing: others)
        return proposed == currentTrimmed ? nil : proposed
    }

    /// セット名 → フォルダ名。空になった場合は "Shared" にフォールバック。
    /// `existing`（小文字比較）と衝突したら " 2", " 3", … を付ける。
    public static func sanitize(_ name: String, existing: [String] = []) -> String {
        var cleaned = String(name.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix(".") { cleaned.removeLast() }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 80 { cleaned = String(cleaned.prefix(80)) }
        if cleaned.isEmpty { cleaned = "Shared" }

        let lowerExisting = Set(existing.map { $0.lowercased() })
        guard lowerExisting.contains(cleaned.lowercased()) else { return cleaned }
        for n in 2...999 {
            let candidate = "\(cleaned) \(n)"
            if !lowerExisting.contains(candidate.lowercased()) { return candidate }
        }
        return "\(cleaned) \(UUID().uuidString.prefix(8))"
    }
}
