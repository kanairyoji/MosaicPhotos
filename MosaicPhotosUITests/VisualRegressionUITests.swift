import XCTest

/// Layer 4: 視覚回帰ハーネス（E2E）。主要画面へ遷移して**名前付きスクリーンショット**を添付する。
/// 手動で行っていた「遷移→撮影」を再利用可能なスイートに formalize したもの。差分は人手/CI で確認する
/// （将来 perceptual-hash でゴールデン比較すれば完全自動化できる）。
///
/// ⚠️ 実機/シミュレータの**個人写真が写り得る**ため既定ではスキップ（環境変数
/// `RUN_VISUAL_REGRESSION=1` で有効化）。添付はローカルのテスト結果に留め、外部へアップロードしない。
final class VisualRegressionUITests: XCTestCase {

    private var enabled: Bool { ProcessInfo.processInfo.environment["RUN_VISUAL_REGRESSION"] == "1" }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let att = XCTAttachment(screenshot: app.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    private func tap(_ app: XCUIApplication, _ dx: Double, _ dy: Double, wait: UInt32 = 3) {
        app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
        sleep(wait)
    }

    /// ホーム→グリッド→フル写真→人物アルバム、の主要画面を撮る。
    func testCaptureKeyScreens() throws {
        try XCTSkipUnless(enabled, "opt-in（個人写真が写り得る）: RUN_VISUAL_REGRESSION=1 で実行")
        let app = XCUIApplication()
        app.launch()
        sleep(3)
        capture(app, "01-home")

        // すべての写真（グリッド）→ フル写真
        tap(app, 0.5, 0.26, wait: 5)
        capture(app, "02-grid-all-photos")
        tap(app, 0.5, 0.5, wait: 4)
        capture(app, "03-fullscreen-photo")

        // ホームへ戻る（下部バー左端の戻る）→ 人物アルバム
        tap(app, 0.06, 0.955, wait: 2)
        let person = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Person'")).firstMatch
        var tries = 0
        while !person.exists && tries < 6 { app.swipeUp(); sleep(1); tries += 1 }
        if person.exists {
            person.tap(); sleep(5)
            capture(app, "04-person-album-grid")
        }
    }
}
