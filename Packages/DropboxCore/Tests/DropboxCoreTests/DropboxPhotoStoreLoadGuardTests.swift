#if canImport(UIKit)
import Foundation
import Testing
@testable import DropboxCore

/// `DropboxPhotoStore.shouldApplyLoad` — 途中まで進んだキャッシュ読み込みの結果を
/// `items` へ反映してよいかの判定（純ロジック）。
///
/// 背景: `loadTask?.cancel()` は `reflectCachedItems` の待機点（actor 呼び出し・`Task.detached`）を
/// 止められない。そのため切断・アカウント切替の後に旧アカウントのスナップショットが着地し、
/// 消したはずの一覧が戻り得た。世代（`loadGeneration`）とアカウントの札で代入直前に弾く。
@Suite("DropboxPhotoStore load guard")
@MainActor
struct DropboxPhotoStoreLoadGuardTests {

    private let stamp = DropboxPhotoStore.LoadStamp(generation: 3, accountId: "acct-A")

    @Test("世代・アカウントが同じでキャンセルもされていなければ反映する")
    func appliesWhenNothingChanged() {
        #expect(DropboxPhotoStore.shouldApplyLoad(
            captured: stamp, currentGeneration: 3, currentAccountId: "acct-A", isCancelled: false))
    }

    @Test("リセット後（世代が進んでいる）は反映しない")
    func dropsAfterReset() {
        // resetLoad() / clearCache() が items をクリアする前に世代を進める。
        #expect(!DropboxPhotoStore.shouldApplyLoad(
            captured: stamp, currentGeneration: 4, currentAccountId: "acct-A", isCancelled: false))
    }

    @Test("アカウントが切り替わっていれば、旧アカウントの読み込みは反映しない")
    func dropsAfterAccountSwitch() {
        // A の読み込み中に B へ切り替わった。A がいつ完了しても B の一覧を壊さない。
        #expect(!DropboxPhotoStore.shouldApplyLoad(
            captured: stamp, currentGeneration: 3, currentAccountId: "acct-B", isCancelled: false))
        // 切断（credential なし）も同様に反映しない。
        #expect(!DropboxPhotoStore.shouldApplyLoad(
            captured: stamp, currentGeneration: 3, currentAccountId: nil, isCancelled: false))
    }

    @Test("キャンセル済みタスクの結果は反映しない")
    func dropsWhenCancelled() {
        #expect(!DropboxPhotoStore.shouldApplyLoad(
            captured: stamp, currentGeneration: 3, currentAccountId: "acct-A", isCancelled: true))
    }

    @Test("世代とアカウントの両方が変わっていても反映しない")
    func dropsWhenBothChanged() {
        #expect(!DropboxPhotoStore.shouldApplyLoad(
            captured: stamp, currentGeneration: 9, currentAccountId: "acct-B", isCancelled: true))
    }
}
#endif

/// 画像（サムネ・フル画像・原本）の配達判定（ADR-174）。
///
/// ⚠️ 一覧は「代入の直前」で見れば足りるが、画像は**ダウンロード → デコード**と待ち合わせが
/// 複数あり、その間にアカウントが切り替わり得る。旧アカウントの画像を新しいキャッシュへ書くと、
/// 同じパスの写真として**別人の画像**が出る（キャッシュを消さない限り直らない）。
@Suite("画像の配達判定（アカウント切替）")
@MainActor
struct DropboxImageDeliveryGuardTests {

    private func stamp(_ generation: Int, _ account: String) -> DropboxPhotoStore.LoadStamp {
        .init(generation: generation, accountId: account)
    }

    @Test("開始時と同じアカウント・同じ世代なら配達する")
    func deliversWhenUnchanged() {
        #expect(DropboxPhotoStore.shouldDeliverImage(
            captured: stamp(3, "dbid:A"), currentGeneration: 3, currentAccountId: "dbid:A"))
    }

    @Test("ダウンロード中にアカウントが変わったら捨てる")
    func dropsOnAccountSwitch() {
        #expect(!DropboxPhotoStore.shouldDeliverImage(
            captured: stamp(3, "dbid:A"), currentGeneration: 3, currentAccountId: "dbid:B"),
                "旧アカウントの画像を新しいキャッシュへ書こうとしている")
    }

    /// キャッシュ消去・切替は世代を進める。世代が違えば、同じアカウントでも捨てる。
    @Test("世代が進んでいたら捨てる（キャッシュ消去を跨いだ）")
    func dropsOnGenerationBump() {
        #expect(!DropboxPhotoStore.shouldDeliverImage(
            captured: stamp(3, "dbid:A"), currentGeneration: 4, currentAccountId: "dbid:A"))
    }

    @Test("切断後（accountId なし）も捨てる")
    func dropsWhenDisconnected() {
        #expect(!DropboxPhotoStore.shouldDeliverImage(
            captured: stamp(3, "dbid:A"), currentGeneration: 3, currentAccountId: nil))
    }
}
