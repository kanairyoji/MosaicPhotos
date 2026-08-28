import Foundation
import Testing
@testable import MosaicSupport

/// メイン応答性センサーの前面/背面の分類（ADR-82）。
/// 背面の停止は OS の throttle であって体感とは無関係なので、集計・即時ログから外す。
@Suite("MainThreadWatchdog", .serialized)
struct MainThreadWatchdogTests {

    /// 共有インスタンスを既知の状態にする（前回テストの残りを捨てる）。
    private func reset() {
        MainThreadWatchdog.shared.setAppActive(true)
        _ = MainThreadWatchdog.shared.flushSummary()
    }

    @Test("前面のサンプルは集計に入る（pings と max に反映）")
    func foregroundSamplesCounted() {
        reset()
        let w = MainThreadWatchdog.shared
        w.record(30)
        w.record(600)
        let summary = w.flushSummary()
        #expect(summary?.contains("pings=2") == true)
        #expect(summary?.contains("max=600") == true)
        #expect(summary?.contains("bgStalls") == false)
    }

    @Test("背面のサンプルは集計に入らず bgStalls として別枠で数える")
    func backgroundSamplesSeparated() {
        reset()
        let w = MainThreadWatchdog.shared
        w.setAppActive(false)
        w.record(28_513)          // 実機ログにあった 28.5 秒の背面停止
        w.record(30)              // しきい値未満は数えない（ノイズ）
        let summary = w.flushSummary()
        // 本体の集計（pings/max）は汚さない＝前面の実力が読める。
        #expect(summary == "main: (background) bgStalls=1")
        w.setAppActive(true)
    }

    @Test("flush で状態がリセットされる（前面・背面とも）")
    func flushResets() {
        reset()
        let w = MainThreadWatchdog.shared
        w.record(600)
        _ = w.flushSummary()
        #expect(w.flushSummary() == nil)

        w.setAppActive(false)
        w.record(600)
        _ = w.flushSummary()
        #expect(w.flushSummary() == nil)
        w.setAppActive(true)
    }

    @Test("前面と背面が混在しても、前面ぶんだけが max に出る")
    func mixedSamples() {
        reset()
        let w = MainThreadWatchdog.shared
        w.record(900)             // 前面
        w.setAppActive(false)
        w.record(20_000)          // 背面（max を汚さないこと）
        w.setAppActive(true)
        w.record(100)             // 前面
        let summary = w.flushSummary()
        #expect(summary?.contains("max=900") == true)
        #expect(summary?.contains("pings=2") == true)
        #expect(summary?.contains("bgStalls=1") == true)
    }

    // MARK: - 復帰をまたいだ ping（ADR-97）

    /// 実機 diagnostics-40〜43 の回帰: 重い処理が**一つも走っていない**復帰
    ///（`prewarm cancelled at 0/314`・`model load skipped` ×4・`infer=0ms`）で
    /// `hang main=11041ms` が記録されていた。背面で送った ping が復帰の瞬間に返ると
    /// 「返答時は前面」なので前面ハングとして数えられ、中断/throttle の待ちが体感の数字を汚す。
    @Test("背面で送って復帰後に返った ping は前面ハングに数えない")
    func pingSpanningResumeIsNotForegroundHang() {
        reset()
        let w = MainThreadWatchdog.shared
        w.setAppActive(false)
        let sentWhileBackground = DispatchTime.now().uptimeNanoseconds
        w.setAppActive(true)      // ここで復帰＝この時刻より前の ping は対象外
        w.record(11_041, startedNs: sentWhileBackground)

        let summary = w.flushSummary()
        #expect(summary?.contains("max=11041") != true, "中断待ちが前面の max を汚している")
        #expect(summary?.contains("bgStalls=1") == true, "背面側の参考値としては残すこと")
    }

    @Test("復帰後に送った ping は通常どおり前面ハングとして数える")
    func pingAfterResumeStillCounted() {
        reset()
        let w = MainThreadWatchdog.shared
        w.setAppActive(false)
        w.setAppActive(true)
        let sentWhileForeground = DispatchTime.now().uptimeNanoseconds
        w.record(700, startedNs: sentWhileForeground)

        let summary = w.flushSummary()
        #expect(summary?.contains("max=700") == true, "前面で完結した停止まで捨ててはいけない")
        #expect(summary?.contains("pings=1") == true)
    }
}

/// ⚠️ ハング中のスタック採取は「止まっている最中」にしか意味が無い（終わってからでは犯人が居ない）。
/// 一方でメインを一瞬 suspend するので、短い引っかかりでは採らず、長い停止では**採り直す**。
@Suite("ハング時スタック採取の判定")
struct HangStackCaptureDecisionTests {

    private let threshold: Double = 2000
    private let interval: UInt64 = 15_000_000_000   // 15 秒

    private func decide(ageMs: Double, lastCaptureNs: UInt64, nowNs: UInt64) -> Bool {
        MainThreadWatchdog.shouldCaptureStack(ageMs: ageMs, threshold: threshold,
                                              lastCaptureNs: lastCaptureNs, nowNs: nowNs,
                                              intervalNs: interval)
    }

    @Test("短い引っかかりでは採らない")
    func shortStallIsNotCaptured() {
        #expect(!decide(ageMs: 1500, lastCaptureNs: 0, nowNs: 1_000_000_000))
    }

    @Test("しきい値を超えた停止は、その場で 1 枚目を採る")
    func firstCaptureHappensImmediately() {
        #expect(decide(ageMs: 2500, lastCaptureNs: 0, nowNs: 1_000_000_000))
    }

    @Test("採った直後は採り直さない（ログを埋めない）")
    func doesNotRecaptureImmediately() {
        let now: UInt64 = 100_000_000_000
        #expect(!decide(ageMs: 6000, lastCaptureNs: now &- 3_000_000_000, nowNs: now))
    }

    /// 78 秒級の停止では「同じ場所か／別処理の数珠つなぎか」を 2 枚目以降でしか区別できない。
    @Test("停止が続けば間隔をおいて採り直す")
    func recapturesAfterInterval() {
        let now: UInt64 = 100_000_000_000
        #expect(decide(ageMs: 20000, lastCaptureNs: now &- 20_000_000_000, nowNs: now),
                "長い停止で 1 枚しか採れないと、犯人が変わったかどうか読めない")
    }

    @Test("時刻が巻き戻っても採らない（異常値で暴発させない）")
    func clockGoingBackwardsIsSafe() {
        #expect(!decide(ageMs: 9000, lastCaptureNs: 200_000_000_000, nowNs: 100_000_000_000))
    }
}

/// ⚠️ 実機 diagnostics-60 では `pread → sqlite3 → CoreData` の連なりで 16 フレームを使い切り、
/// **アプリのフレームに 1 つも届かなかった**＝誰が呼んだのかが分からなかった。
/// 深く採ったうえで「何で止まっているか」と「誰が呼んだか」だけを残す。
@Suite("ハングスタックの選別")
struct InterestingFramesTests {

    private let systemNoise = [
        " 0 libsystem_kernel.dylib pread +8",
        " 1 libsqlite3.dylib sqlite3_step +47536",
        " 2 CoreData <redacted> +124",
        " 3 CoreData <redacted> +2848",
        " 4 CoreData <redacted> +764",
        " 5 CoreData <redacted> +96",
        " 6 libswiftCore.dylib something +12",
        " 7 Foundation <redacted> +40",
    ]
    private let appFrame = " 8 MosaicPhotos.debug.dylib LocalPhotoCore.LocalAssetIndex.asset +100"

    @Test("システムの連なりに埋もれたアプリのフレームを拾う")
    func appFrameSurvivesSystemNoise() {
        let picked = MainThreadWatchdog.interestingFrames(systemNoise + [appFrame])
        #expect(picked.contains(appFrame), "誰が呼んだのかが分からないと直しようがない")
    }

    @Test("先頭は残す（何で止まっているか）")
    func topFramesAreKept() {
        let picked = MainThreadWatchdog.interestingFrames(systemNoise + [appFrame],
                                                          topSystemFrames: 4)
        #expect(Array(picked.prefix(4)) == Array(systemNoise.prefix(4)))
    }

    /// 中間のシステムフレームは落とす（先頭でも末尾でもない位置＝読み手の役に立たない）。
    @Test("中間のシステムフレームは落とす")
    func middleSystemFramesAreDropped() {
        // 先頭 4 と末尾 6 のどちらにも入らない位置に置く（両端は意図的に残すため）。
        let middle = (4..<40).map { " \($0) CoreData <redacted> +\($0)" }
        let stack = Array(systemNoise.prefix(4)) + middle
            + (40..<46).map { " \($0) libswiftCore.dylib tail +\($0)" }

        let picked = MainThreadWatchdog.interestingFrames(stack, topSystemFrames: 4)
        #expect(!picked.contains(" 20 CoreData <redacted> +20"))
        #expect(picked.count < stack.count, "全部出したら選別の意味がない")
    }

    /// アプリのフレームも出し過ぎない（上限＋末尾のぶんに収まる）。
    @Test("アプリのフレームも出し過ぎない")
    func appFramesAreCapped() {
        let many = (0..<50).map { " \($0) MosaicPhotos.debug.dylib f\($0) +1" }
        let picked = MainThreadWatchdog.interestingFrames(many, topSystemFrames: 2,
                                                          maxAppFrames: 5, tailFrames: 6)
        #expect(picked.count <= 2 + 5 + 6, "50 フレーム全部を出している（\(picked.count) 行）")
        #expect(picked.count >= 2 + 5)
    }

    @Test("空でも壊れない")
    func emptyIsSafe() {
        #expect(MainThreadWatchdog.interestingFrames([]).isEmpty)
    }

    /// ⚠️ 2 度目の失敗（実機 diagnostics-62）。除外リストに `SwiftData` を入れ忘れており、
    /// アプリ枠 14 個を SwiftData のフレームが食い尽くして**呼び出し元に 1 つも届かなかった**。
    /// 除外リストは「知っている名前しか弾けない」ので、それだけに頼らない。
    @Test("永続化のフレームで枠を食い尽くさない")
    func swiftDataFramesDoNotStarveAppFrames() {
        let stack = [" 0 libsystem_platform.dylib _platform_memmove +180",
                     " 1 libsqlite3.dylib sqlite3_rekey +117032"]
            + (2..<50).map { " \($0) SwiftData <redacted> +\($0 * 100)" }
            + [" 50 MosaicPhotos.debug.dylib FaceCore.PeopleEngine.loadPeople +100"]

        let picked = MainThreadWatchdog.interestingFrames(stack)
        #expect(picked.contains(" 50 MosaicPhotos.debug.dylib FaceCore.PeopleEngine.loadPeople +100"),
                "呼び出し元に届いていない＝誰が呼んだか分からない")
    }

    /// 除外リストに無いイメージ名でも、**末尾**は必ず残す（呼び出し元はスタックの底にいる）。
    @Test("知らないイメージ名で埋まっても末尾は残す")
    func tailIsAlwaysKept() {
        let stack = (0..<60).map { " \($0) UnknownFramework <redacted> +\($0)" }
            + [" 60 MosaicPhotos.debug.dylib caller +1"]
        let picked = MainThreadWatchdog.interestingFrames(stack, maxAppFrames: 3)
        #expect(picked.contains(" 60 MosaicPhotos.debug.dylib caller +1"),
                "除外リストの漏れで診断が止まらないようにする")
    }

    @Test("末尾を足しても重複しない")
    func tailDoesNotDuplicate() {
        let stack = [" 0 libsystem_kernel.dylib pread +8", " 1 MosaicPhotos.debug.dylib f +1"]
        let picked = MainThreadWatchdog.interestingFrames(stack)
        #expect(picked.count == Set(picked).count)
    }
}
