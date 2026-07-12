import Foundation

/// オンデバイス AI 解析の各パスが「最後に実際に写真を処理した時刻」を記録・取得する軽量ストア。
/// ユーザー向けの「AI 解析の状況」画面で「最後に解析した時間」を出すために使う。
///
/// 記録は各タガーのバッチ確定点（実際に 1 枚以上処理したときだけ）で呼ぶ。空振り（対象ゼロで
/// 即 return）では更新しないので、「動いている／止まっている」を正しく反映する。保存は `UserDefaults`
/// に `Date`（timeIntervalSinceReferenceDate）で、キーは本 enum に集約する（設定キー一元化の規約）。
public enum AnalysisActivity {

    /// 解析のパス（種類）。`rawValue` が UserDefaults キーの一部になる。
    public enum Pass: String, CaseIterable, Sendable {
        case embeddings   // CLIP 埋め込み（意味検索の索引）
        case sceneTags    // Vision シーンタグ
        case captions     // VLM キャプション（AI による説明）
        case faces        // 顔スキャン（ピープル）
    }

    private static func key(_ pass: Pass) -> String { "analysis.lastActivity.\(pass.rawValue)" }

    /// このパスが写真を処理したことを記録する（バッチ確定時に呼ぶ）。
    public static func recordActivity(_ pass: Pass, at date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSinceReferenceDate, forKey: key(pass))
    }

    /// このパスが最後に写真を処理した時刻（未実行なら nil）。
    public static func lastActivity(_ pass: Pass) -> Date? {
        let raw = UserDefaults.standard.object(forKey: key(pass)) as? Double
        return raw.map { Date(timeIntervalSinceReferenceDate: $0) }
    }
}

/// 画像解析の進捗（各パスの完了数と分母）。`AutoAlbumEngine.analysisProgress()` が返す。
/// CLIP・シーンタグ・キャプションは同じ写真母数（取り込み済み＝`total`）を分母に進む。
public struct AnalysisProgress: Sendable {
    /// 取り込み済み写真数（＝各パスの分母）。端末＋Dropbox（includeCloud 時）。
    public var total: Int
    /// CLIP 埋め込み済み（意味検索の索引が付いた枚数）。
    public var embedded: Int
    /// Vision シーンタグ付与済みの枚数。
    public var sceneTagged: Int
    /// VLM キャプション生成済みの枚数（モデル未同梱なら常に 0）。
    public var captioned: Int

    public init(total: Int, embedded: Int, sceneTagged: Int, captioned: Int) {
        self.total = total
        self.embedded = embedded
        self.sceneTagged = sceneTagged
        self.captioned = captioned
    }
}
