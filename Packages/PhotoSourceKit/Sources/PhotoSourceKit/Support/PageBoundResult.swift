import Foundation

/// 「開始時のページ」に紐づく非同期結果の受け取り可否（純ロジック・テスト対象）。
///
/// ⚠️ フル写真ビューは取得の待ち時間中も横ページ送りができる。開始時と完了時でページが
/// 変わっていることを見ないと、
/// - 共有: A で押して B へ移ったあと **A の共有シートが開く**（見ている写真と違う写真を外部へ送る）
/// - お気に入り: A の書き込み失敗が **B のハートを巻き戻す**
/// といった取り違えが起きる（レビュー指摘）。結果は必ず**開始したページ**へ適用する。
enum PageBoundResult {

    /// 完了時に UI へ反映してよいか（＝開始時のページを今も見ているか）。
    static func shouldPresent<ID: Equatable>(startedOn started: ID, current: ID) -> Bool {
        started == current
    }

    /// 楽観更新の巻き戻し先。**開始時のページ**に固定する（完了時の現在ページではない）。
    static func rollbackTarget<ID: Equatable>(startedOn started: ID) -> ID { started }
}
