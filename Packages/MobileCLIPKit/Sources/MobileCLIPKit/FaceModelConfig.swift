import Foundation

/// 同梱顔モデルの設定（`face_config.json`・ADR-70）。
///
/// モデルの**中身に依存する事実**（入力サイズ・整列方式・パイプライン版）はモデルと同じ
/// フォルダで生成される JSON が宣言する。Swift 側に定数で持つと、モデルだけ差し替えた・
/// アプリだけ更新した、の食い違いで壊れる（例: 旧モデルのまま v5 の全再スキャンが走る）。
/// - `alignment: "arcface5"` … 5 点相似変換で 112×112 テンプレートへ整列（ArcFace 系）
/// - `alignment` なし … 従来の両目整列（facenet 世代）
struct FaceModelConfig: Decodable, Sendable {
    var inputSize: Int
    var embedDim: Int
    var model: String
    var alignment: String?
    var pipelineVersion: Int?

    var usesArcFaceAlignment: Bool { alignment == "arcface5" }

    /// バンドルから読み込む（未同梱・旧形式は nil → facenet 既定で動く）。
    static let bundled: FaceModelConfig? = {
        guard let url = Bundle.main.url(forResource: "face_config", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FaceModelConfig.self, from: data)
    }()
}
