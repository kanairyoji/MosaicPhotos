import MosaicSupport
import SwiftUI

@main
struct MosaicPhotosApp: App {
    init() {
        // 未捕捉例外・メモリ圧迫を端末上の診断ログへ記録する（実機でも原因を追えるように）。
        Diagnostics.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
