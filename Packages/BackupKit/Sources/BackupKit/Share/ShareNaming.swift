import CryptoKit
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
    /// ⚠️ **大文字小文字を無視して**照合する。Dropbox の一覧は `path_lower`（すべて小文字）で
    /// 取り込むので、実際に手元に来るフォルダ名は `people-金居家` のように小文字になる
    /// （実フィードバック 9/3: 接頭辞を落としたはずが表示が変わらなかった）。
    /// 作成時に付ける名前は `People-` なので、**書いた側と読む側で見え方が違う**。
    public static func kind(fromFolderName folderName: String) -> ShareSourceKey.Kind? {
        let lower = folderName.lowercased()
        for kind in [ShareSourceKey.Kind.album, .person, .group]
        where lower.hasPrefix(prefix(for: kind).lowercased()) {
            return kind
        }
        return nil
    }

    /// フォルダ名から**表示用の名前**を作る（接頭辞を落とす）。
    ///
    /// ⚠️ `People-` / `Album-` / `Person-` は **Dropbox 上で種類を見分けるための内部の印**で、
    /// アプリの画面に出すものではない（実フィードバック: 共有アルバムが "People-◯◯" と出る）。
    /// 接頭辞が無いフォルダ（他アプリ・手作りの共有）はそのまま返す。
    public static func displayName(fromFolderName folderName: String) -> String {
        guard let kind = kind(fromFolderName: folderName) else { return folderName }
        let stripped = String(folderName.dropFirst(prefix(for: kind).count))
        // 接頭辞だけの名前（"People-"）は落とすと空になるので、元の名前を返す。
        return stripped.isEmpty ? folderName : stripped
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

    // MARK: - 共有ファイル名（中身で決まる・ADR-209）

    /// 共有フォルダに置くファイル名を**中身から決める**ための印（SHA-256 を 16 進 64 桁・全部）。
    ///
    /// ⚠️ これが差分方式の要。**同じ写真 → 必ず同じ名前**なので、
    /// - コピーは何度やり直しても同じファイルになる（冪等）＝重複が生まれない
    /// - 別の写真は別の名前になる＝衝突しない＝`autorename` が要らない
    /// - 中身が差し替われば名前が変わる＝旧名は「望ましくない」側へ回って消える
    ///
    /// 記録（どこへコピーしたか）を持たなくてよくなるのはこの性質のおかげ。
    /// 以前は宛先名をアイテムごとに採番して覚えており、その記録と実在の食い違いを
    /// 直すために採用・自己修復・墓標・残骸掃除が必要だった。
    ///
    /// ⚠️ **digest を切り詰めない**。最初は 8 桁（32 ビット）にしていたが、
    /// 1 セット 12,941 枚の実績に対して誕生日問題で**約 1.9% が衝突**する——
    /// 衝突すると片方が黙って共有されない（家族に届かない）。
    /// 桁を伸ばして確率を下げるより、**全部付けて衝突という概念を消す**方が単純で安全。
    /// 衝突しないと決まれば、衝突を解く仕組み（印を伸ばす・落ちた写真を記録する）も要らない。
    ///
    /// - Parameter contentHash: Dropbox の `content_hash`。**不明なら refKey だけで決める**
    ///   （クラウド原本は手元に hash が無い場合がある。そのときは中身の差し替えを
    ///   検知できないが、一意性と冪等性は保たれる）。
    public static func identity(refKey: String, contentHash: String?) -> String {
        let seed = "\(refKey)|\(contentHash ?? "")"
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 印と元のファイル名から、共有フォルダでのファイル名を作る。
    /// 例: `IMG_1234.jpg` ＋ 64 桁の印 → `IMG_1234--<64 桁>.jpg`
    public static func sharedFileName(sourceFileName: String, identity: String) -> String {
        let ext = (sourceFileName as NSString).pathExtension
        var stem = (sourceFileName as NSString).deletingPathExtension
        stem = String(stem.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) })
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        while stem.hasSuffix(".") { stem.removeLast() }
        // ⚠️ 長い名前は切る（Dropbox のパス長 260 文字制限）。
        // 印 64 桁＋区切り 2＋拡張子で約 70 文字使うので、幹は 80 文字までにする
        // （セットフォルダのパスが 60〜80 文字あっても収まる）。
        if stem.count > 80 { stem = String(stem.prefix(80)) }
        if stem.isEmpty { stem = "photo" }
        return ext.isEmpty ? "\(stem)\(identitySeparator)\(identity)"
                           : "\(stem)\(identitySeparator)\(identity).\(ext)"
    }

    /// 印の区切り。⚠️ 元のファイル名に現れにくい形を選ぶ（誤判定を避ける）。
    static let identitySeparator = "--"

    /// このアプリが置いた名前か。**診断とテストのための判定**
    /// （掃除の可否には使わない——セットフォルダ直下は名前に関係なく管理する・ADR-209）。
    /// ⚠️ 桁数で厳密に絞らない（印を切り詰めていた頃のファイルも自分のものと見なす）。
    public static func isShareManagedFileName(_ filename: String) -> Bool {
        let stem = (filename as NSString).deletingPathExtension
        guard let range = stem.range(of: identitySeparator, options: .backwards) else { return false }
        let tail = stem[range.upperBound...]
        guard tail.count >= 8, tail.count % 2 == 0 else { return false }
        return tail.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
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
