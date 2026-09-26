import Foundation

/// 同梱 CLIP の設定（`mobileclip_config.json`・`scripts/build_mobileclip.sh` が生成）。
///
/// 顔側の `FaceModelConfig` と**同じ方針**: モデルの中身に依存する事実は、モデルと同じ
/// フォルダで生成される JSON が宣言する。Swift 側に定数で持つと「モデルだけ差し替えた・
/// アプリだけ更新した」の食い違いで静かに壊れる。
///
/// ⚠️ ファイル名・config 名は互換のため `MobileCLIP*` 据え置き（中身は OpenCLIP・ADR-31）。
///
/// ## 何に使うか
/// いまの用途は**表示タグの概念埋め込みキャッシュの鍵**（`ConceptEmbeddingCache`）。
/// `model` / `pretrained` が変われば同じ語でもベクトルが別物になるので、これを鍵に混ぜて
/// 古い表を自動で捨てる。⚠️ ここを鍵に入れ忘れると、**モデルを差し替えたあと古いモデルの
/// ベクトルで比較して、静かに変なタグが出る**（気づけない種類の壊れ方）。
struct MobileCLIPConfig: Decodable, Sendable {
    var imageSize: Int
    var contextLength: Int
    var embedDim: Int
    /// アーキテクチャ名（例 "ViT-B-32"）。
    var model: String
    /// 学習済み重みの名前（例 "datacomp_xl_s13b_b90k"）。旧い config には無いことがある。
    var pretrained: String?

    /// バンドルから読み込む。未同梱・旧形式なら nil。
    ///
    /// ⚠️ nil のときは**キャッシュを使わない**（`ConceptEmbeddingCache` 側で判断）。
    /// モデルを識別できないまま表を保存すると、差し替えに気づけないため。
    static let bundled: MobileCLIPConfig? = {
        guard let url = Bundle.main.url(forResource: "mobileclip_config", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MobileCLIPConfig.self, from: data)
    }()

    /// モデルの素性を 1 行で表す（キャッシュの鍵に混ぜる）。
    var identity: String { "\(model)/\(pretrained ?? "-")/d\(embedDim)/c\(contextLength)" }
}
