import Foundation
import Testing
@testable import MosaicSupport

/// クラッシュの痕跡を残す仕組み。
///
/// ⚠️ 実機で 4 回落ちたのに、診断ログにクラッシュの行が **1 本も無かった**（8/31 朝）。
/// (1) Swift の trap は ObjC 例外ハンドラを通らない、(2) その例外ハンドラすら非同期書き込みで
/// プロセス終了に間に合っていなかった、の二重。ここは (1) の書き出しを固定する。
// ⚠️ グローバルな fd を張り替えるので**直列**に走らせる（並列だと後のテストが前の fd を閉じる）。
@Suite("クラッシュ痕跡の書き出し", .serialized)
struct CrashSignalsTests {

    @Test("シグナル名と直前の操作をログへ書く")
    func writesSignalAndBreadcrumb() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        CrashSignals.installForTesting(fileURL: url)
        CrashSignals.setBreadcrumb("people.merge 1234→5678")
        CrashSignals.writeCrashLineForTesting(SIGTRAP)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("CRASH SIGTRAP"), "どのシグナルで落ちたかが残っていない")
        #expect(text.contains("people.merge 1234→5678"), "直前の操作が残っていない")
    }

    @Test("長い操作名でもバッファを溢れさせない")
    func breadcrumbIsTruncated() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        CrashSignals.installForTesting(fileURL: url)
        CrashSignals.setBreadcrumb(String(repeating: "x", count: 4096))
        CrashSignals.writeCrashLineForTesting(SIGABRT)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("CRASH SIGABRT"))
        #expect(text.count < 1024, "固定長バッファを超えて書いている")
    }
}
