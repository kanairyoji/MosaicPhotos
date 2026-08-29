import Dispatch

/// `@ModelActor`（SwiftData ストア）を**専用のシリアルキュー**に載せるための executor。
///
/// ⚠️ なぜ要るか（実機 diagnostics-64/65）: SwiftData の既定 executor
/// （`DefaultSerialModelExecutor`）は **ジョブを「呼び出したスレッド」でそのまま走らせる**。
/// つまり MainActor から `await store.foo()` と書くと、その fetch は**メインスレッドで実行される**
/// ——`await` があるので一見オフメインに見えるのに、実際にはメインが塞がる。実測は
/// `AutoAlbumStore.allEnrichedPhotosLite()`（86k 件）で **10.9 秒の前面ハング**、
/// `FaceStore.reviewItems`（レビュー候補）で **5.9 秒**。どちらもハング中のメインスレッドの
/// 呼び出しスタックに、そのままストアのメソッドが写っていた。
///
/// 「**init したスレッドに束縛される**」という以前の理解は誤りだった。生成スレッドは関係なく、
/// **呼び出し元のスレッド**で走る（`ModelActorExecutorTests` で両方を検証している）。
/// したがって `Task.detached { Store() }` で生成しても、MainActor から呼べばメインで走る。
///
/// 対処: `unownedExecutor` を専用のシリアルキューに差し替える。actor の直列性（＝ModelContext を
/// 同時に触らない）はキューが保証するので、SwiftData の要件は満たしたまま呼び出し元から切り離せる。
///
/// QoS は**あえて指定しない**（`.unspecified`）。キューに固定 QoS を付けると、そのキューに入る
/// 仕事が一律その優先度になり、UI 起点の読み出しまで utility に落ちる。未指定なら
/// enqueue した側の優先度を引き継ぐので、前面の読みは高く・夜間バッチは低く走る。
public enum ModelStoreExecutor {

    /// ストア専用のシリアルキューを作る。`unownedExecutor` から返して使う。
    public static func serialQueue(label: String) -> DispatchSerialQueue {
        DispatchSerialQueue(label: label)
    }
}
