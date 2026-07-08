import MosaicSupport
import UIKit

/// アプリ内の**全タッチ**を 1 箇所で捕捉して「最後の操作時刻」を更新するトラッカー。
/// AI 処理タイミング設定（`HeavyWorkTiming`）の「アプリ使用中も操作の合間に動かす」段階で、
/// 「操作の合間」を確実に判定するために使う。
///
/// 以前の方式（各ビューが個別に noteUserInteraction を呼ぶ）は検出漏れがあり
/// 「操作中なのにアイドル扱い→重い処理が走って固まる」の一因だった（ADR-25 の経緯）。
/// キーウィンドウに `cancelsTouchesInView = false` の認識器を 1 個載せることで、
/// どの画面のどんな操作（タップ・スクロール・ピンチ）でも漏れなく捕捉できる。
enum TouchActivityTracker {
    private final class Recognizer: UIGestureRecognizer {
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            BackgroundActivityMonitor.shared.noteUserInteraction()
            state = .failed   // 常に失敗扱い＝他の認識器・ビューの操作を一切妨げない
        }
    }

    /// キーウィンドウへ 1 回だけ取り付ける（RootView の onAppear/task から呼ぶ）。
    static func install() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first,
              !(window.gestureRecognizers ?? []).contains(where: { $0 is Recognizer })
        else { return }
        let recognizer = Recognizer()
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        window.addGestureRecognizer(recognizer)
    }
}
