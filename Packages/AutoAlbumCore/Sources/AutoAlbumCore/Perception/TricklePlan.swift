import Foundation

/// 背景トリクル（シーンタグ → CLIP 埋め込み）で**何を・どの順で・どこまでやるか**の判断
/// （純ロジック・テスト対象・ADR-198）。
///
/// ## なぜ出したか
/// 以前は `scheduleBackgroundFill()` が 117 行の単一 Task クロージャで、二重起動の抑止・世代ガード・
/// ゲート待ち・ラベラのウォーム・候補の準備・P1/P2 の順序と上限を**全部ひとつのクロージャ**に
/// 抱えていた。`AutoAlbumEngine`（巨大な依存を持つ `@MainActor @Observable`）のメソッドの中なので、
/// どの判断も単独で呼べず、**テストは 2 本しか無かった**（テスト/kLOC 7.1 で全体最低）。
///
/// ここで固定したいのは、**コメントにしか書かれていなかった不変条件**:
/// - P1（シーンタグ）には**必ず有限の上限**がある。無いとタグが窓を独占し、CLIP 埋め込みが
///   **永久に飢餓**する（ADR-85。実機 diag-28〜33 でタグは 33,662→24,505 と進む一方、
///   未埋め込みは 43,611→43,626 とまったく減らず、`embed: batch` が数週間 1 度も出ていなかった）。
/// - 回線が許されないときは**候補を端末内写真だけに絞る**（クラウドのタグ付けはサムネ DL を伴う）。
///   ローカルは通信不要なので常に進む。
/// - ラベラのウォームは**ゲートが開いているときだけ**起こす（ADR-80。以前はゲート判定の外に
///   あったため、起動直後でも CLIP テキストタワーのロード＝新規インストール直後は実測 23 秒と
///   約300語の encode が走り、起動を重くしていた）。
/// - 手順は**必ず埋め込みで終わる**（VLM キャプションのインターリーブは ADR-108 で廃止）。
public enum TricklePlan {

    /// 判断に要る状態（すべて呼び出し側が測って渡す）。
    public struct Inputs: Equatable, Sendable {
        /// 回線ポリシーを満たしているか（ブーストは免除される＝ゲートの表が答える）。
        public var networkAllowed: Bool
        /// 表示ラベラがあり、まだ温まっていないか。
        public var labelerNeedsWarming: Bool
        /// 入口の時点でゲートが開いているか（ウォームを起こしてよいか）。
        public var gateOpen: Bool

        public init(networkAllowed: Bool = true,
                    labelerNeedsWarming: Bool = false,
                    gateOpen: Bool = true) {
            self.networkAllowed = networkAllowed
            self.labelerNeedsWarming = labelerNeedsWarming
            self.gateOpen = gateOpen
        }
    }

    /// トリクルの 1 手。
    public enum Step: Equatable, Sendable {
        /// 表示ラベラの概念埋め込み（約300語）を別タスクで温める（fire-and-forget）。
        case warmLabeler
        /// Vision シーンタグ。`maxBatches` は 1 回の実行あたりの上限（ADR-85）。
        case tagScenes(maxBatches: Int, localOnly: Bool)
        /// CLIP 埋め込み。進捗しなくなるまで回す。
        case embed

        public var label: String {
            switch self {
            case .warmLabeler:                   return "warmLabeler"
            case .tagScenes(let n, let localOnly): return "tags(\(n)\(localOnly ? ",local" : ""))"
            case .embed:                          return "embed"
            }
        }
    }

    /// 1 回の実行でシーンタグに割り当てるバッチ数の上限（ADR-85）。
    /// 8 枚/バッチなので 40 バッチ ≒ 320 枚。これを超えたら打ち切って埋め込みへ順番を回す。
    /// 次の実行で続きから進むので総量は変わらず、「どれも少しずつ進む」状態になる。
    public static let tagBatchesPerRun = 40

    public static func steps(_ i: Inputs) -> [Step] {
        var out: [Step] = []
        // ウォームは「ついで」なので、ゲートが開いているときだけ。閉じていても実害はない
        // （未ウォームなら insight は CLIP ラベルを飛ばして Vision タグだけで即返す）。
        if i.gateOpen, i.labelerNeedsWarming { out.append(.warmLabeler) }
        // P1: タグは検索の一次ランキングなので埋め込みより先に揃える価値が高い。
        out.append(.tagScenes(maxBatches: tagBatchesPerRun, localOnly: !i.networkAllowed))
        // P2: 窓の残りは全部埋め込みに使う。
        out.append(.embed)
        return out
    }
}
