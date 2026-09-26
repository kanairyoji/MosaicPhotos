import Foundation
import MosaicSupport

/// 表示タグの概念埋め込み（314 語 × 512 次元）をディスクに置く。
///
/// ## なぜ要るか（実機ログ diagnostics-96）
/// この表は**メモリ上にしか無かった**ので、**起動するたびに 314 語を作り直して**いた。
/// 作り直しには CLIP テキスト塔が必要で、実機で **13 秒・+260MB**（178MB → 438MB）。
/// しかも 314 語と同梱モデルはどちらも固定なので、**答えは毎回まったく同じ**。
/// diagnostics-65/66 の「569MB まで伸び、直後に `cancelPrewarm` で捨てられていた＝完全な無駄」
/// は、当時ゲートで症状を抑えたが、**毎回作り直す構造**はそのまま残っていた。
/// 実機の窓のピーク 617MB は、その塔が顔モデル（+85MB）と重なった姿。
///
/// 628KB を置くだけで、起動ごとの 13 秒と 260MB が消える。おまけに**起動直後からタグが出る**
/// （いまは表ができるまで CLIP ラベルを飛ばして Vision タグだけになる）。
///
/// ## いつ捨てるか（ここが本質）
/// ⚠️ **人が版を採番するのに頼らない。** 表を決める入力を鍵に織り込み、どれかが変われば
/// 自動で古い表を無視する。採番を忘れると「古いモデルのベクトルで比較して静かに変なタグが
/// 出る」——気づけない種類の壊れ方になるため、忘れられる仕組みにしない。
///
/// 鍵に入れているもの（＝これらが変われば作り直す）:
/// 1. **モデルの素性**（`mobileclip_config.json` の `model` / `pretrained` / `embedDim` /
///    `contextLength`）。モデルを差し替えれば同じ語でもベクトルは別物。
/// 2. **プロンプト文字列そのもの**（`"a photo of <語>"` を全語ぶん連結してハッシュ）。
///    これ 1 つで「語の追加・削除・修正」「語順の変更」「テンプレートの変更」すべてを拾う。
///    ⚠️ 語リストだけを鍵にすると、テンプレートを変えたときに取りこぼす。
/// 3. **トークナイザの語彙ファイルの大きさ**（`bpe_simple_vocab_16e6.txt`）。語彙が変わると
///    トークン ID が変わる＝ベクトルが変わる。⚠️ 中身のハッシュではなく**サイズ**にしている
///    ——毎起動で数MBを読むのは、避けたい 13 秒を別のコストに置き換えるだけ。現実の差し替えは
///    1 と同時に起きるので、サイズは安い保険として足す位置づけ。
/// 4. **ファイル形式の版**（`formatVersion`）。並びや型を変えたときに古いファイルを読まないため。
///
/// 加えて**読むときに大きさを検査**する（`語数 × 次元 × 4`）。これが完全性の検査にもなる
/// ——途中で欠けた表は大きさが合わないので読まれない（下記）。
///
/// ## 置き場所
/// `.applicationSupportDirectory`。⚠️ Caches ではない——OS に消されると、消したことに
/// 気づかないまま**また 13 秒と 260MB を払う**（それを無くすのがこの仕組みの目的）。
/// 628KB なので置いておく害は無い。消えても壊れはしない（作り直すだけ）。
struct ConceptEmbeddingCache {

    /// ファイル形式の版。並び・型（Float32・語順）を変えたら上げる。
    private static let formatVersion = 2

    /// ⚠️ **Float16 にしない。** 表示タグは「最上位との差が `margin`（0.04）以内」を採るので、
    /// 丸めの誤差が境界のタグを入れ替え得る。628KB と 314KB の差は取るに足らないので、
    /// **挙動を変えない**方を選ぶ（`PhotoEmbedding` が Float16 なのは 6.7 万行あるからで、
    /// 314 行のここに同じ理屈は要らない）。
    private static let bytesPerValue = 4

    private static let log = LogChannel(subsystem: "com.mosaicphotos.MobileCLIPKit",
                                        label: "ConceptCache")

    // MARK: - 鍵

    /// 表を決める入力から鍵を作る。**モデルを識別できないときは nil**＝キャッシュを使わない。
    ///
    /// ⚠️ ここはモデルを**ロードしない**（起動のたびに走るので安くなければ意味が無い）。
    /// ⚠️ 鍵の式そのものは `MosaicSupport.ConceptTableFingerprint`（純ロジック）に置いてある
    /// ——「何が変われば捨てるか」がこの仕組みの心臓部なので、macOS で回るテストで
    /// 1 条件ずつ固定したい（`ConceptTableFingerprintTests`）。ここは**入力を集めるだけ**。
    static func fingerprint(prompts: [String]) -> String? {
        ConceptTableFingerprint.make(formatVersion: formatVersion,
                                     modelIdentity: MobileCLIPConfig.bundled?.identity,
                                     prompts: prompts,
                                     tokenizerSize: vocabByteCount)
    }

    /// BPE 語彙ファイルのバイト数（読み込まない・属性だけ）。
    private static let vocabByteCount: Int? = {
        guard let url = Bundle.main.url(forResource: "bpe_simple_vocab_16e6", withExtension: "txt"),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return size
    }()

    // MARK: - 場所

    private static var directory: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
        else { return nil }
        return base.appendingPathComponent("MosaicPhotos/ConceptEmbeddings", isDirectory: true)
    }

    private static func fileURL(_ fingerprint: String) -> URL? {
        directory?.appendingPathComponent("concepts-\(fingerprint).f32")
    }

    /// 鍵に合う表がディスクに在るか（読み込まない）。
    /// `prewarm` が「安い経路なのでゲートを待たずに進んでよいか」を決めるのに使う。
    static func hasCachedTable(prompts: [String], expectedCount: Int) -> Bool {
        guard let fp = fingerprint(prompts: prompts), let url = fileURL(fp),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return false }
        return size == expectedByteCount(count: expectedCount)
    }

    private static func expectedByteCount(count: Int) -> Int? {
        guard let dim = MobileCLIPConfig.bundled?.embedDim else { return nil }
        return count * dim * bytesPerValue
    }

    // MARK: - 読み

    /// 表を読む。鍵が合わない・大きさが合わない・読めないときは nil（＝作り直す）。
    ///
    /// ⚠️ **大きさの検査が完全性の検査でもある。** 作る側は語が 1 つでも欠けたら保存しないので、
    /// 大きさが合う＝314 語すべてが入っている。欠けた表を読んで「できている」と扱うと、
    /// その語だけ永久に付かなくなる。
    static func load(tags: [String]) -> [(tag: String, vector: [Float])]? {
        let prompts = tags.map(promptText)
        guard let fp = fingerprint(prompts: prompts), let url = fileURL(fp),
              let expected = expectedByteCount(count: tags.count),
              let dim = MobileCLIPConfig.bundled?.embedDim,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        guard data.count == expected else {
            log.error("concept cache: size mismatch (\(data.count) != \(expected)) — rebuilding")
            return nil
        }
        var out: [(tag: String, vector: [Float])] = []
        out.reserveCapacity(tags.count)
        let floats: [Float] = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        // ⚠️ 非有限が混じった表は使わない（コサインが NaN になり全タグが壊れる）。
        // 保存側でも弾いているが、ファイルが壊れた場合の保険。
        guard floats.allSatisfy({ $0.isFinite }) else {
            log.error("concept cache: non-finite value found — rebuilding")
            return nil
        }
        for (i, tag) in tags.enumerated() {
            out.append((tag: tag, vector: Array(floats[(i * dim)..<((i + 1) * dim)])))
        }
        Diagnostics.mark("labeler: concept table loaded from cache (\(tags.count) tags, "
                         + "\(data.count / 1024)KB) — CLIP text tower not needed")
        return out
    }

    // MARK: - 書き

    /// 表を保存する。**完全で有限な表だけ**を書く。
    ///
    /// ⚠️ 作る側（`buildEmbeddings`）は、ある語の埋め込みが nil でもその語を**黙って飛ばして**
    /// 表を返す（実行時はそれで動く）。その欠けた表を保存すると、以後ずっと欠けたままになる
    /// ——起動のたびに作り直していた頃は「次の起動で埋まる」可能性があったが、保存すると固定される。
    /// なので `tags` と同じ数が揃っているときだけ書く。
    static func save(_ table: [(tag: String, vector: [Float])], tags: [String]) {
        guard table.count == tags.count else {
            Diagnostics.mark("labeler: concept table incomplete (\(table.count)/\(tags.count)) "
                             + "— not caching")
            return
        }
        guard let dim = MobileCLIPConfig.bundled?.embedDim,
              table.allSatisfy({ $0.vector.count == dim && $0.vector.allSatisfy { $0.isFinite } })
        else {
            Diagnostics.mark("labeler: concept table has wrong dim or non-finite values — not caching")
            return
        }
        // ⚠️ 並びは `tags` の順そのまま（読む側は語を持たず、順序で対応づける）。
        guard table.map(\.tag) == tags else {
            Diagnostics.mark("labeler: concept table order differs from tags — not caching")
            return
        }
        guard let fp = fingerprint(prompts: tags.map(promptText)),
              let dir = directory, let url = fileURL(fp) else { return }

        var data = Data(capacity: tags.count * dim * bytesPerValue)
        for row in table {
            row.vector.withUnsafeBufferPointer { data.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            Diagnostics.mark("labeler: concept table cached (\(tags.count) tags, \(data.count / 1024)KB)")
            removeStaleFiles(keeping: url)
        } catch {
            // 書けなくても動作は変わらない（次の起動でまた作るだけ）。
            log.error("concept cache: save failed — \(error.localizedDescription)")
        }
    }

    /// 鍵が変わって使われなくなった表を片付ける（モデル差し替え・語の追加のあと）。
    private static func removeStaleFiles(keeping keep: URL) {
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                      includingPropertiesForKeys: nil)
        else { return }
        for f in files where f.lastPathComponent != keep.lastPathComponent
            && f.lastPathComponent.hasPrefix("concepts-") {
            try? FileManager.default.removeItem(at: f)
            Diagnostics.mark("labeler: removed stale concept table \(f.lastPathComponent)")
        }
    }

    // MARK: - プロンプト

    /// ⚠️ **作る側と鍵で同じ関数を使う。** ここを書き写すと、テンプレートを変えたときに
    /// 鍵だけが古いまま残り、**古いベクトルを新しいテンプレートの表として読んでしまう**。
    static func promptText(for concept: String) -> String { "a photo of \(concept)" }
}
