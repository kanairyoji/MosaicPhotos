import Testing

/// **`UserDefaults.standard` の `backupDestination` / `shareProvideEnabled` を書き換えるテスト**の親。
///
/// 本番の読み口（`BackupScope.current(.standard)`・`BackupEngine.runnerShareMemberLocalIdentifiers`）が
/// `.standard` を読むので、通しのテストはその間だけ設定を差し替える。⚠️ swift-testing は
/// **スイートどうしを並列に**走らせるので、子のスイートにそれぞれ `.serialized` を付けても
/// 互いの差し替えが混ざる（実際に踏んだ: 解析を止める変異で、解析と無関係な
/// 「共有セットが無ければ何も上げない」まで落ちた）。この 2 つのキーを触るスイートは
/// **必ずこの下に置く**。
@Suite("standard の設定を書き換えるテスト（直列）", .serialized)
enum StandardSettingsSuite {}
