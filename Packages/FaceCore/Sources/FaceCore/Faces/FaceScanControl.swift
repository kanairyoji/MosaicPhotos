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
    /// **スキャン中の進捗**（この実行の残り・止まると 0 に戻る）。表示用。
    /// ⚠️ **残作業ではない**。完了の判定・枠配分・停滞検出に使うと、
    /// 「終わった」と「始められなかった」が同じ 0 になる。そちらは `faceBacklog`。
    var scanProgressRemaining: Int { get }

    /// **スキャンしていなくても答えられる**顔の残作業（ADR-207）。
    /// 回線待ちで今回は外したクラウド分も含む。nil＝この起動でまだ測っていない。
    var faceBacklog: Int? { get }

    /// まだ測っていなければ測る（走査済みの refKey を 1 回引くので、毎回は呼ばない）。
    @discardableResult
    func measureBacklogIfUnknown(candidateRefKeys: [String]) async -> Bool

    /// **スキャン台帳の安い指紋**（ADR-247）: (スキャン済み, 候補から外した) の件数。
    ///
    /// ⚠️ `fetchCount` 2 回なので窓の入口で毎回読んでよい。候補の列挙（約 11 秒）を
    /// 「やることが無い」と知るためだけに払わないための材料。
    /// ⚠️⚠️ **`faceBacklog` を代わりに使ってはいけない**（ADR-237 で一度書いて気づいた罠）。
    /// あれはスキャン側しか更新しないので 0 に張り付き、新しい写真が入っても 0 のまま
    /// ——「仕事が無い」と読むと**顔スキャンが永久に走らなくなる**。
    /// こちらは DB の実数なので、版を上げて台帳を捨てれば減り、スキャンが進めば増える。
    func scanLedgerFingerprint() async -> (scanned: Int, unreadable: Int)

    /// 候補のうち**まだスキャンしていない**枚数（ADR-247）。
    /// ⚠️ 台帳を実際に引くので安くない——**列挙した回にだけ**呼ぶこと
    /// （「やることが無かった」の札を立ててよいかの、唯一の確かな根拠）。
    func pendingCount(candidateRefKeys: [String]) async -> Int

    /// 未スキャン分を背景で処理する。走行中なら何もしない。
    func startScan(candidateRefKeys: [String], allowSimulator: Bool)
    /// 進行中のスキャンを明示的に止める（前面復帰・ADR-79）。
    func stopScan()

    /// 背面で手放せる（作り直せる）キャッシュを捨てる（ADR-226 追補）。
    /// ⚠️ 走っている最中は取り上げない（実装側で守る）。
    func releaseCachesForBackground()

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
