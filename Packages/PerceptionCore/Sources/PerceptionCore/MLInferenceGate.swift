import Foundation

/// 端末の **Neural Engine（ANE）を使う重い処理を 1 つずつに直列化**する共有ゲート。
///
/// ⚠️ 実機で判明した障害（diagnostics-19）: 顔検出（Vision `VNImageRequestHandler.perform`＝ANE）と
/// CLIP 埋め込み/モデルロード（Core ML＝ANE）が**同時に走ると ANE がデッドロックし、Vision の perform が
/// 永久に返らない**（顔スキャンが最初の 1 枚で固まり People=0 のまま）。以前は CLIP 埋め込みが Wi-Fi
/// ゲートで止まっていて顔スキャンが ANE を独占できていたため顕在化しなかった（ADR-69 で埋め込みが
/// 常時走るようになって表面化）。
///
/// 対策: 顔検出・CLIP 埋め込み・Vision タグ・VLM キャプション・各モデルロードといった **ANE 系の重い
/// 処理をこのゲートに通し、同時に 1 つだけ**実行する（推論粒度で直列化）。単体では固まらない（実績あり）
/// ので、直列化すればデッドロックしない。ロードの一時的な待ち（数十秒）はあるがトリクル処理なので許容。
///
/// 実装: `actor` の再入を利用した公平な FIFO ゲート。`run` は body 実行中ゲートを保持し、他の `run` は待つ。
public actor MLInferenceGate {
    public static let shared = MLInferenceGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()   // 次の待機者へ引き継ぐ（busy は保持したまま）
        }
    }

    /// ANE 系の重い処理を直列化して実行する。body は取得〜解放の間だけ実行され、他の呼び出しは待機する。
    public func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await acquire()
        let result = await body()
        release()
        return result
    }
}
