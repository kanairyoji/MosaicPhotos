import CryptoKit
import Foundation

/// 台帳の書き出しから**読める個人情報を外す**（ADR-234 追補・純ロジック・テスト対象）。
///
/// ## 何を外せて、何を外せないか
/// ⚠️ **顔の埋め込みは外せない**。512 次元の identity ベクトルは**まさに再生が使うもの**で、
/// これが無ければクラスタリングも持ち越しも回らない。つまり書き出したファイルは、
/// 名前を外しても**生体情報のまま**である——扱いの注意は名前の有無では変わらない。
///
/// 外せるのは「再生に要らないのに読める」もの:
/// - **人物名・グループ名** → 安定した仮名。再生が名前の**文字列**を要る場所は無い
///   （`NameCarryoverMatching` は名前の値を見ず、`AssertionCensus` は「名前が在るか」だけ見る）。
/// - **写真のキー（refKey）** → 種別の接頭辞を残したハッシュ。Dropbox のキーは
///   `C-/家族/2019/沖縄旅行/IMG_1234.jpg` のような**フォルダ名を含むパス**で、
///   家族構成・行った場所・時期がそのまま読める。再生はキーを**同一性の目印**としてしか
///   使わない（重なりの突き合わせ）ので、置き換えても結果は 1 ビットも変わらない。
///
/// ## ⚠️ 塩を混ぜる
/// パスを**塩なしで**ハッシュしても隠れない——`/家族/2019/…` のような当てやすい文字列は
/// 総当たりで逆算できる。書き出しごとにランダムな塩を混ぜる。
/// 副作用として**2 回の書き出しは突き合わせられない**が、再生は 1 回の書き出しで完結するので困らない。
///
/// ## ⚠️ 「実行後に捨てる」では遅い
/// テストのあとで名前を消しても、**ファイルは既に本名を持って端末を出ている**。
/// 外すのは**書き出す時点**でなければ意味がない。
public enum FaceLedgerRedaction {

    /// 書き出しごとの塩（当てやすいパスの逆算を防ぐ）。
    public static func newSalt() -> String { UUID().uuidString }

    private static func digest(_ text: String, salt: String, length: Int) -> String {
        let hash = SHA256.hash(data: Data((salt + "\u{1F}" + text).utf8))
        return hash.map { String(format: "%02x", $0) }.joined().prefix(length).description
    }

    /// 写真のキーを置き換える。**種別の接頭辞は残す**（"L-" / "C-"）。
    ///
    /// ⚠️ 接頭辞を落としてはいけない——ローカルかクラウドかで分岐する処理（撮影日の扱い・
    /// クラウド分だけの再スキャン）があり、落とすとその分岐が動かなくなる。
    public static func redactedRefKey(_ refKey: String, salt: String) -> String {
        let prefix = refKey.count >= 2 ? String(refKey.prefix(2)) : ""
        if prefix == "L-" || prefix == "C-" {
            return prefix + digest(String(refKey.dropFirst(2)), salt: salt, length: 24)
        }
        return digest(refKey, salt: salt, length: 24)
    }

    /// 顔の ID を置き換える。`faceID` は `"<refKey>#<連番>"` なので、**refKey と同じ置き換えを
    /// 使って作り直す**（片方だけ変えるとパスが faceID 側から漏れる／参照が壊れる）。
    public static func redactedFaceID(_ faceID: String, salt: String) -> String {
        guard let hash = faceID.lastIndex(of: "#") else {
            return redactedRefKey(faceID, salt: salt)
        }
        let refKey = String(faceID[faceID.startIndex..<hash])
        let suffix = String(faceID[hash...])           // "#0" など
        return redactedRefKey(refKey, salt: salt) + suffix
    }

    /// 人物名・グループ名を安定した仮名にする（同じ名前なら同じ仮名）。
    ///
    /// ⚠️ **空文字は空文字のまま**返す。「名前が無い」を「名前が在る」に変えてしまうと、
    /// `AssertionCensus` が数える「名前付き人物」が増え、遷移の突き合わせが狂う。
    public static func pseudonym(for name: String, salt: String) -> String {
        guard !name.isEmpty else { return name }
        return "Person-" + digest(name, salt: salt, length: 8)
    }
}
