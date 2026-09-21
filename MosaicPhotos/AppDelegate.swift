import BackupKit
import DropboxCore
import MosaicSupport
import UIKit

/// SwiftUI App に足した最小の UIApplicationDelegate。
///
/// 役割は 1 つ——**背景 URLSession の完了で OS に起こされたとき**に応答を受け取ること
/// （ADR-181）。`application(_:handleEventsForBackgroundURLSession:completionHandler:)` は
/// delegate にしか届かない（SwiftUI のライフサイクルには相当物が無い）。
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // ⚠️ セッションに触る前に結線する。セッションは生成した瞬間に溜まっていた応答を
        // 流し始めるので、台帳を書く相手が決まっていないと取りこぼす（spool に残って
        // 次の窓で上げ直しにはなるが、無駄）。ストアの構築は settle 側が待つ。
        BackgroundUploadSession.shared.settlerProvider = {
            await HomeStores.shared().backupEngine
        }
        // ⚠️ **自分で出し直せるようにする**（diagnostics-82）。これが無いと、Dropbox に
        // 「1 秒待て」と言われても次の投入は次の窓＝30 分後になる（投入の口がバックアップ
        // 実行中にしか無いため）。実機では 4.5 時間で 429 を 862 回受けて 1 枚も上がらなかった。
        BackgroundUploadSession.shared.tokenProvider = {
            try? await HomeStores.shared().dropboxStore.auth.freshAccessToken()
        }
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploadSession.sessionIdentifier else { completionHandler(); return }
        Diagnostics.mark("backup(bg): woken for background session events")
        let completion: @Sendable () -> Void = { Task { @MainActor in completionHandler() } }
        BackgroundUploadSession.shared.attach(completion: completion)
    }
}
