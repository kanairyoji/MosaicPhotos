import XCTest

/// ドキュメント用スクリーンショットの自動撮影（scripts/capture_screenshots.sh から使う）。
///
/// 撮影対象は**フリーライセンス素材だけを入れた使い捨てシミュレータ**（MosaicShots）で、
/// 個人写真は 1 枚も含まれない。撮った画像は XCTAttachment として .xcresult に入り、
/// `xcresulttool export attachments` で取り出す（fastlane snapshot と同じ手筋・外部依存なし）。
final class ScreenshotCaptureTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        grantPhotoAccessIfAsked()
    }

    /// 初回起動の写真アクセス許可（iOS 26 では simctl privacy grant では抑止できない）。
    private func grantPhotoAccessIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["フルアクセスを許可", "Allow Full Access", "Allow Access to All Photos"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                return
            }
        }
    }

    /// 画面を撮って添付する。名前は取り出し後のファイル名になる。
    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// ラベル候補のいずれかに一致する要素をタップする（日英どちらでも拾えるように）。
    /// ⚠️ SwiftUI の行は `staticTexts` が hittable でないことがあるため、
    /// ボタン→セル→テキストの順に探し、hittable でなければ**座標タップ**へ落とす。
    @discardableResult
    private func tapFirst(_ labels: [String], timeout: TimeInterval = 5) -> Bool {
        for label in labels {
            for query in [app.buttons, app.cells, app.staticTexts, app.otherElements] {
                let element = query[label]
                guard element.waitForExistence(timeout: timeout) else { continue }
                if element.isHittable {
                    element.tap()
                } else {
                    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                }
                return true
            }
        }
        return false
    }

    /// グリッドの左上のサムネイルをタップする。
    /// ⚠️ `PhotoCollectionView` のセルは accessibility 要素として `cells` に現れず、
    /// クエリはホームのリスト行を拾ってしまう（not hittable で失敗）。撮影用途では
    /// 要素解決に凝らず**画面の相対座標**でタップする方が確実。
    private func tapFirstThumbnail() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.18)).tap()
    }

    @MainActor
    func testCaptureDocumentationScreens() throws {
        // ⚠️ 撮影順は「戻り操作が要らない順」に組む。フル画面写真から下部バーの
        // 「ホーム」へ戻る操作は UI トグルの状態に依存して不安定なので、
        // ホーム系 → 設定 → グリッド → 写真 の一方通行にする。

        // 1. ホーム（起動直後・アルバム生成前）
        capture("01-home-initial")

        // 2. アルバム生成を待つ（旅行・場所は段階起動タスクで自動生成される）。
        sleep(90)
        capture("02-home")

        // 3. 下部セクション（AI アルバム・端末アルバム・場所）
        app.swipeUp()
        sleep(2)
        capture("03-home-scrolled")
        app.swipeUp()
        sleep(2)
        capture("04-home-places")
        app.swipeDown()
        app.swipeDown()
        app.swipeDown()
        sleep(2)

        // 4. 設定（Albums & Search を含むルート）
        if tapFirst(["設定", "Settings"], timeout: 5) {
            sleep(4)
            capture("05-settings")
            // シートを閉じる（左上の戻る）。
            tapFirst(["Back", "戻る"], timeout: 3)
            sleep(2)
            app.swipeDown()   // 閉じない場合の保険（シートを引き下げる）
            sleep(2)
        }

        // 5. すべての写真（グリッド）
        if tapFirst(["すべての写真", "All Photos"], timeout: 5) {
            sleep(5)
            capture("06-grid")

            // 6. 写真 1 枚（フル画面）— ここで終わりにするので戻らない。
            tapFirstThumbnail()
            sleep(6)
            capture("07-photo")
        }
    }
}
