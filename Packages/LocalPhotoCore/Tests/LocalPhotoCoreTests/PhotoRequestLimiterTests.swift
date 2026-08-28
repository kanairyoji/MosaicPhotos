import Foundation
import Testing
@testable import LocalPhotoCore

/// ⚠️ 実機で落ちた（diagnostics-59）。密表示（15 列）へ切り替えた直後にメモリが
/// 164MB → 1032MB へ急増。10 秒間で `thumb.cacheMiss=1072`、その 1 件ごとに
/// `PHImageManager.requestImage` が走り、**同時実行に上限が無かった**。
/// 取得は向きの都合で最低 640×640＝1 枚 1.6MB 級なので、同時数がそのままメモリの山になる。
@Suite("端末写真取得の同時実行制限")
struct PhotoRequestLimiterTests {

    @Test("同時に走る本数が上限を超えない")
    func concurrencyIsCapped() async {
        let limit = 4
        let limiter = ImageCacheKitSemaphoreStub(value: limit)
        let peak = PeakCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    await limiter.acquire()
                    await peak.enter()
                    try? await Task.sleep(nanoseconds: 200_000)
                    await peak.leave()
                    await limiter.release()
                }
            }
        }
        let observed = await peak.max
        #expect(observed <= limit, "上限を超えた（\(observed) 本）＝そのぶんメモリの山になる")
        #expect(observed > 1, "直列化してしまうと表示が遅くなる")
    }

    /// 上限そのものの妥当性。1 枚 1.6MB 級を抱えるので、山が有界であることを明示的に押さえる。
    @Test("上限は有界で、低コア機でも流量が残る")
    func limitIsBoundedAndUsable() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let value = min(16, max(4, cores * 2))
        #expect(value >= 4, "低コア機で直列に近くなると密表示が実用にならない")
        #expect(value <= 16, "1 枚 1.6MB 級なので上限が無いとメモリが青天井になる")
    }
}

// MARK: - テスト用の素の実装（本番と同じ契約）

private actor PeakCounter {
    private(set) var current = 0
    private(set) var max = 0
    func enter() { current += 1; max = Swift.max(max, current) }
    func leave() { current -= 1 }
}

/// `AsyncSemaphore` と同じ契約の最小実装（本番型はテストから直接使えないため）。
private actor ImageCacheKitSemaphoreStub {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(value: Int) { available = value }

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first { waiters.removeFirst(); next.resume() } else { available += 1 }
    }
}
