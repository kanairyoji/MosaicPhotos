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
