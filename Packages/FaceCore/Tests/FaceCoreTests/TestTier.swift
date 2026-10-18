import Foundation

/// テストの段（`scripts/test.sh quick` / `full`）。
///
/// **データセットで精度を測るテスト**（1 本で数分・FaceCore 全体で 30 分超）は「完全」だけで走らせる。
/// 変更ごとの関門（通常）で毎回回すと、関係のない精度評価を待つ時間が件数ぶん積み上がる。
/// ⚠️ 既定（環境変数なし）は**今までどおり走る**——`swift test` を直接叩いたときに
/// 黙って評価が消えないように、外すのは `MOSAIC_TEST_TIER=quick` を明示したときだけ。
enum TestTier {
    static var isQuick: Bool { ProcessInfo.processInfo.environment["MOSAIC_TEST_TIER"] == "quick" }
}
