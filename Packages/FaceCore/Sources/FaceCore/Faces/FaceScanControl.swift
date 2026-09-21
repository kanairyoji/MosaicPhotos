import Foundation

/// **顔スキャンの制御だけを見せる断面**（ADR-198）。
///
/// `PeopleEngine` は public メンバーが約 50 あり、44 ファイルから参照されている。その大半は
/// 一覧の表示か編集で、**スキャンを制御する側が見る必要があるのは以下の 8 つだけ**。
/// 断面を切ると、駆動役・処理枠・ブーストが誤って編集 API（`rename` / `reassignFace` …）へ
/// 手を伸ばせなくなる。
///
/// ## なぜ型を分割しないか
/// スキャン本体は `store` / `shadowStore` / `tuning` / 版上げ移行 / 命名の持ち越し /
/// 影の世代の昇格 / 一覧の再読込など **13 個の内部に依存**している。別クラスへ出すと
/// 逆参照（`weak var engine`）を持つことになり、結合は実質減らない。**見える範囲だけを絞る。**
///
/// ⚠️ **SwiftUI のビューはこの断面を使わないこと。** `@Observable` の追従は具象型でしか効かず、
/// プロトコル越しに読むと再描画されない。ビューは `PeopleEngine` を直接受け取る。
/// この断面は「ポーリングで読む側」（駆動役・処理枠・ブースト・状況モデル）のためのもの。
@MainActor
public protocol FaceScanControl: AnyObject {

    /// 顔モデルが同梱され利用可能か（未同梱ならピープルは無効）。
    var isFaceModelAvailable: Bool { get }
    /// いまスキャンが走っているか。
    var isScanning: Bool { get }
    /// 未スキャンの残り枚数（おおよそ・**スキャン中のみ**更新。止まると 0 に戻る）。
    /// ⚠️ 完了の判定には使わないこと——「終わった」と「始められなかった」が同じ 0 になる。
    var remaining: Int { get }

    /// **スキャンしていなくても答えられる**顔の残作業（ADR-207）。
    /// 回線待ちで今回は外したクラウド分も含む。nil＝この起動でまだ測っていない。
    var faceBacklog: Int? { get }

    /// まだ測っていなければ測る（走査済みの refKey を 1 回引くので、毎回は呼ばない）。
    @discardableResult
    func measureBacklogIfUnknown(candidateRefKeys: [String]) async -> Bool

    /// 未スキャン分を背景で処理する。走行中なら何もしない。
    func startScan(candidateRefKeys: [String], allowSimulator: Bool)
    /// 進行中のスキャンを明示的に止める（前面復帰・ADR-79）。
    func stopScan()

    /// 候補から消えた写真の顔を掃除する（サムネの出ない顔が一覧に残るのを防ぐ）。戻り値＝消した数。
    @discardableResult
    func pruneMissingPhotos(candidateRefKeys: [String], knownGone: Set<String>) async -> Int
    /// 候補のうち未スキャンの枚数（台帳への実クエリ＝規模に比例する）。
    func pendingScanCount(candidateRefKeys: [String]) async -> Int
    /// スキャン済み枚数と検出顔数。
    func scanStats() async -> (scanned: Int, faces: Int)
    /// モデル更新の移行（ADR-186）の進み具合。移行中でなければ nil。
    func faceModelMigrationProgress(candidateRefKeys: [String]) async -> (scanned: Int, total: Int)?
}

extension PeopleEngine: FaceScanControl {}
