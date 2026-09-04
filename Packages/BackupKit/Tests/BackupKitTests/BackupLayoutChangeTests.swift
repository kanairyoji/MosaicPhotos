import Foundation
import Testing
@testable import BackupKit
import DropboxCore

/// 配置の版が変わったときの台帳リセット（ADR-175）。
///
/// ⚠️ 既存データは**移行しない**（ユーザー判断）。旧配置の実体は Dropbox に残し、
/// 台帳を捨てて新配置 `Backup/` へ上げ直す。ただし**オフロード台帳は消さない**——
/// オフロード済みの写真は端末に無く、旧パスのクラウド代替が唯一の実体だから。
@Suite("配置の版とリセット", .serialized)
@MainActor
struct BackupLayoutChangeTests {

    private func freshDefaults() {
        UserDefaults.standard.removeObject(forKey: BackupSettingsKeys.layoutVersion)
    }

    @Test("版が未記録（旧インストール）なら 1 回だけリセットして版を記録する")
    func resetsOnceForOldInstall() async {
        freshDefaults()
        let engine = BackupEngine(auth: DropboxAuthService(appKey: "k", redirectURI: "app://cb"))

        #expect(await engine.resetForLayoutChangeIfNeeded(), "旧インストールなのにリセットしていない")
        #expect(UserDefaults.standard.integer(forKey: BackupSettingsKeys.layoutVersion)
                == BackupLayout.currentVersion, "版が記録されていない")
        // 2 回目は何もしない（起動のたびに台帳を捨てない）。
        #expect(await engine.resetForLayoutChangeIfNeeded() == false, "毎回リセットしている")
        freshDefaults()
    }

    @Test("バックアップ実行中はリセットしない（次回に回す）")
    func doesNotResetWhileBusy() async {
        freshDefaults()
        let engine = BackupEngine(auth: DropboxAuthService(appKey: "k", redirectURI: "app://cb"))
        engine.setReconcilingForTesting(true)
        #expect(await engine.resetForLayoutChangeIfNeeded() == false, "実行中に台帳を消している")
        #expect(UserDefaults.standard.object(forKey: BackupSettingsKeys.layoutVersion) == nil,
                "リセットしていないのに版だけ進めた（次回もリセットされなくなる）")
        engine.setReconcilingForTesting(false)
        freshDefaults()
    }

    @Test("現行の版なら何もしない")
    func noopWhenCurrent() async {
        UserDefaults.standard.set(BackupLayout.currentVersion, forKey: BackupSettingsKeys.layoutVersion)
        let engine = BackupEngine(auth: DropboxAuthService(appKey: "k", redirectURI: "app://cb"))
        #expect(await engine.resetForLayoutChangeIfNeeded() == false)
        freshDefaults()
    }
}

/// 夜間（自動）の実行では「1 回あたりの上限」を外す（ADR-180）。
///
/// ⚠️ 既定の 10 枚を夜間にも当てると、5 分の窓に 10 枚しか上がらず、6 万枚の上げ直しは
/// 何年も終わらない。夜間には**窓の期限**という別の上限があるので、枚数の上限は要らない。
@Suite("夜間の上限", .serialized)
@MainActor
struct NightlyUploadLimitTests {

    @Test("手動は設定の上限、夜間は無制限（0）")
    func nightlyRunHasNoPerRunLimit() {
        UserDefaults.standard.set(10, forKey: BackupSettingsKeys.uploadLimit)
        defer { UserDefaults.standard.removeObject(forKey: BackupSettingsKeys.uploadLimit) }
        let engine = BackupEngine(auth: DropboxAuthService(appKey: "k", redirectURI: "app://cb"))
        #expect(engine.effectiveUploadLimit == 10, "手動の上限が効いていない")
        engine.setNightlyRunForTesting(true)
        #expect(engine.effectiveUploadLimit == 0, "夜間なのに 1 回あたりの上限が残っている")
        engine.setNightlyRunForTesting(false)
        #expect(engine.effectiveUploadLimit == 10, "夜間の印が下りていない")
    }
}
