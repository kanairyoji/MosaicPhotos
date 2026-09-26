import CryptoKit
import Foundation

/// 「作り直した結果が同じになる表」を、いつ捨てるべきか決める鍵（純ロジック・テスト対象）。
///
/// ## なぜ鍵にするか（実機ログ diagnostics-96）
/// 表示タグの概念埋め込み（314 語 × 512 次元）は**メモリ上にしか無く、起動ごとに作り直して**
/// いた。作り直しには CLIP テキスト塔が必要で実機 **13 秒・+260MB**。答えは毎回同じなので
/// ディスクに置けばよいが、**置いた表をいつ捨てるか**を間違えると
/// 「古いモデルのベクトルで比較して静かに変なタグが出る」——気づけない壊れ方になる。
///
/// ⚠️ **人が版を採番するのに頼らない。** 表を決める入力を全部鍵に混ぜ、どれかが変われば
/// 鍵が変わって古いファイルが読まれなくなる。採番は忘れられるが、入力は忘れられない。
///
/// ## 鍵に入れるもの（＝これらが変われば作り直す）
/// - `formatVersion`: ファイルの並び・型。読み方を変えたら上げる。
/// - `modelIdentity`: モデルの素性（アーキテクチャ・重み・次元・文脈長）。差し替えたらベクトルは別物。
///   **nil なら鍵を作らない**＝キャッシュを使わない（識別できないまま保存すると差し替えに気づけない）。
/// - `prompts`: **モデルへ渡す文字列そのもの**を全部。これ 1 つで「語の追加・削除・修正」
///   「語順の変更」「プロンプトのテンプレート変更」を一度に拾う。
///   ⚠️ 語リストだけを混ぜると、テンプレートを変えたときに取りこぼす。
/// - `tokenizerSize`: 語彙ファイルの大きさ。語彙が変わるとトークン ID＝ベクトルが変わる。
///   ⚠️ 中身のハッシュではなく大きさにしてある——毎起動で数MBを読むのは、避けたい 13 秒を
///   別のコストに置き換えるだけ。現実の語彙差し替えはモデルと同時に起きるので安い保険の位置づけ。
public enum ConceptTableFingerprint {

    /// 鍵を作る。`modelIdentity` が nil のときは **nil**（キャッシュを使わない合図）。
    ///
    /// ⚠️ 順序に意味がある。`prompts` は区切りを挟んで連結する——挟まないと
    /// `["ab","c"]` と `["a","bc"]` が同じ鍵になり、**語の切り方を変えても気づけない**。
    public static func make(formatVersion: Int,
                            modelIdentity: String?,
                            prompts: [String],
                            tokenizerSize: Int?) -> String? {
        guard let modelIdentity else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data("v\(formatVersion)|\(modelIdentity)|".utf8))
        for p in prompts {
            hasher.update(data: Data(p.utf8))
            hasher.update(data: Data([0]))          // ← 区切り（無いと境界が曖昧になる）
        }
        hasher.update(data: Data("|vocab\(tokenizerSize ?? -1)".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            .prefix(16).description
    }
}
