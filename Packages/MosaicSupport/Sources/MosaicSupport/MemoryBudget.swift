import Foundation
#if canImport(os)
import os
#endif

/// 端末のメモリ予算から、画像キャッシュ等の**ベース上限**を算出する。
///
/// 固定値だと低 RAM 機で jetsam（メモリ超過で OS にkillされる）、高 RAM 機で取りこぼし
///（ディスク再デコード増）になる。そこで起動時の予算からベースを決め、圧迫時の**動的縮小**は
/// `MemoryPressureMonitor` / `MemoryImageCache` 側に任せる二段構え（ベース＝ここ／反応＝あちら）。
///
/// 予算の入力は **`os_proc_available_memory()`**（iOS 13+・「このプロセスが kill されるまでに
/// 使える実バイト」）。`physicalMemory` より正直で、OS や他アプリの使用ぶんを差し引いた値。
/// 取得不可/他プラットフォームは `physicalMemory` の一定割合をフォールバックにする。
/// 値は時々で変動するので**起動時に1回読んでベースに使う**想定（毎回は読まない）。
public enum MemoryBudget {
    /// テスト用に予算を固定注入する（nil なら実測）。決定的なテストのための seam。
    public static var override: UInt64?

    /// アプリが使えるメモリ予算（概算バイト）。
    public static func availableBytes() -> UInt64 {
        if let override { return override }
        #if os(iOS)
        let avail = os_proc_available_memory()
        if avail > 0 { return UInt64(avail) }
        #endif
        // フォールバック: 物理メモリの一部（OS/他アプリ分を引いて控えめに）。
        return UInt64(Double(ProcessInfo.processInfo.physicalMemory) * 0.25)
    }

    /// サムネのメモリ層（`NSCache`）コスト上限（バイト）を予算から算出する。
    /// サムネは 128px≈64KB と軽いので割合は小さめ、上下限でクランプして暴走を防ぐ（純関数・テスト対象）。
    public static func thumbnailCostLimit(budget: UInt64) -> Int {
        let target = Double(budget) * 0.05            // 予算の約5%
        let floor = Double(60 * 1_048_576)            // 60MB（保持下限＝取りこぼし防止）
        let ceiling = Double(192 * 1_048_576)         // 192MB（攻めすぎ防止）
        return Int(min(max(target, floor), ceiling))
    }
}
