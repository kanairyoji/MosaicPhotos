import Foundation

/// AI アルバムの検索文から、ピープル（顔クラスタ）の**名前付き人物**を決定的に接地する純ロジック。
///
/// 人物アルバム名はフルネーム（例「木村太郎」「木村花子」）で入ることが多い。一方クエリは
/// 名だけ（「太郎」）や複数人物（「太郎と花子」）で来る。姓名の**部分指定**と**複数人物**に対応するため、
/// 各フルネームの「前方（姓）・後方（名）の部分文字列（長さ2以上）＋全体」を作り、クエリ原文に
/// それが現れるフルネームを拾う。中間だけの部分文字列は作らない（「木村太郎」で「村太」に当てない＝
/// 誤爆を抑える）。照合は `QueryEvaluator` の people 部分一致と整合（フルネームを条件に載せる）。
///
/// LLM に頼らず動くので**作成時の即時プレビューでも人物名アルバムがヒットする**。夜間の LLM 解釈は
/// あだ名・ローマ字ゆれ等をさらに拾う補強として併用する。
enum PersonNameGrounder {

    /// 検索文 `criteria` が参照している名前付き人物の**フルネーム**を返す（カタログ `names` に接地）。
    /// 一致は大文字小文字を無視。`names` は名前付きクラスタの表示名（"Person N" は渡さない前提）。
    ///
    /// 2 パスで照合する。第 1 パスで**フルネーム完全一致**を先に拾い、その部分をクエリから消費する。
    /// これをしないと「木村太郎」というフルネーム入力が、部分照合の姓片「木村」で木村花子ら
    /// **同姓の家族全員に接地してしまう**（実障害）。完全一致した箇所はそれ以上分解しない。
    /// 長い名前から先に照合する（「木村太」と「木村太郎」が両方いるとき後者を優先）。
    static func groundedNames(in criteria: String, names: [String]) -> [String] {
        guard !names.isEmpty else { return [] }
        var q = criteria.lowercased()
        guard !q.isEmpty else { return [] }
        var matched: [String] = []
        // 第 1 パス: フルネーム完全一致（長い順）。一致箇所をクエリから消費する。
        for name in names.sorted(by: { $0.count > $1.count }) {
            let lower = name.lowercased()
            guard lower.count >= 2, q.contains(lower), !matched.contains(name) else { continue }
            matched.append(name)
            while let range = q.range(of: lower) {
                q.replaceSubrange(range, with: " ")
            }
        }
        // 第 2 パス: 残りのクエリに対して姓（前方）・名（後方）の部分照合。
        for name in names {
            let lower = name.lowercased()
            guard lower.count >= 2, !matched.contains(name) else { continue }
            if nameParts(lower).contains(where: { q.contains($0) }) {
                matched.append(name)
            }
        }
        return matched
    }

    /// 接地した人物名が原文中で占める部分を空白へ置換して返す。視覚語抽出（例「花子」→ 花＝flower）が
    /// 人名の文字を誤って被写体語として拾わないよう、レキシコン適用前に人名部分を落とすのに使う。
    static func strippingNames(from criteria: String, matched names: [String]) -> String {
        guard !names.isEmpty else { return criteria }
        var out = criteria
        // 長い部分から消す（「花子」を先に消してから「花」が残らないように）。
        for name in names {
            let parts = nameParts(name.lowercased()).sorted { $0.count > $1.count }
            for part in parts where part.count >= 2 {
                // 大文字小文字を無視して該当箇所を空白化。
                while let range = out.range(of: part, options: .caseInsensitive) {
                    out.replaceSubrange(range, with: " ")
                }
            }
        }
        return out
    }

    /// フルネームの照合部分：全体＋前方部分（姓）＋後方部分（名）。長さ 2 以上のみ。中間片は作らない。
    static func nameParts(_ name: String) -> [String] {
        let chars = Array(name)
        let n = chars.count
        guard n >= 2 else { return [name] }
        var parts: [String] = [name]
        // 長さ 2 以上・全体未満の前方（姓）と後方（名）。
        if n > 2 {
            for len in 2..<n {
                parts.append(String(chars.prefix(len)))   // 姓（前方）
                parts.append(String(chars.suffix(len)))   // 名（後方）
            }
        }
        return parts
    }
}
