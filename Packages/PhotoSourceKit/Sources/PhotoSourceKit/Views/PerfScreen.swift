#if canImport(UIKit)
import SwiftUI
import MosaicSupport

/// 画面遷移の所要を計測する SwiftUI ヘルパ。`PerfTrace`（MosaicSupport）の seam を SwiftUI から使う。
///
/// 使い方:
///  - 遷移**元**（タップ時など）で `PerfTrace.beginScreen("open.photo")` を呼ぶ。
///  - 遷移**先**の View に `.perfScreenEnd("open.photo")` を付けると、onAppear で所要 ms をログする。
///
/// `PerfTrace` 無効時は onAppear のクロージャが即 return するだけなので常設してよい。
public extension View {
    /// 遷移先の onAppear で `PerfTrace.endScreen(name)` を呼び、遷移の所要を計測する。
    func perfScreenEnd(_ name: String) -> some View {
        onAppear { PerfTrace.endScreen(name) }
    }
}
#endif
