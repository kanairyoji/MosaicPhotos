import Foundation

/// **モデル世代の台帳**（ADR-186）——同梱している学習済みモデルの「いまの版」を 1 箇所で宣言する。
///
/// ## モデル更新の方針（後から読む人へ）
/// モデルファイルは今後も更新される。そのとき **DB を丸ごと作り直さない**ために、索引は次の 3 通りで持つ:
///
/// | 索引 | 版の持ち方 | 更新のしかた |
/// |---|---|---|
/// | シーンタグ | 行ごと（`PhotoTagRecord.version`） | 旧版の行を少しずつ付け直す（従来どおり） |
/// | CLIP 埋め込み | **行ごと**（`PhotoEmbedding.modelID`） | 新しい写真から順に上書き。未移行の行は検索で自分の空間（旧テキストタワーが同梱されていれば）で当たる |
/// | 顔 | **コンテナごと**（影の世代 `Faces-<modelID>`） | 旧コンテナで表示を続けながら新コンテナを育て、網羅が閾値に達したら名前を移して切り替え |
///
/// 行に版を付けるのは「写真ごとに独立した索引」（埋め込み・タグ）。顔はクラスタという全体構造を
/// 持つので、行の版ではなくコンテナを分ける。どちらも**既存データを消さない**（optional 列の追加だけ・
/// コンテナ名の採番はしない・台帳は開く前に控えを取る＝`StoreSnapshot`）。
///
/// ## 更新の手順
/// 1. 新しいモデルファイルを同梱し、ID を変える（CLIP はここの `clip`・顔は face_config.json の `model`）。
/// 2. CLIP: 旧テキストタワーも 1 リリースだけ同梱するなら `retainedClipTextTowers` に旧 ID を足す
///    （検索が途切れない）。次のリリースで外す。
/// 3. 顔: 何もしない。`PeopleEngine` が ID の違いを見て影の世代を育て、切り替える。
public enum ModelGeneration {

    /// CLIP 画像／テキストタワーの ID。**変えると**埋め込みの再計算が新しい写真から順に始まる。
    /// `PhotoEmbedding.modelID` が nil の行は、この列を足す前に作られた＝`legacyClip` とみなす。
    public static let clip = "openclip-vitb32-datacomp-int8-v1"
    /// `modelID` 列を導入する前の埋め込みが作られたモデル（現行と同じ）。
    public static let legacyClip = clip
    /// 旧 CLIP のうち、テキストタワーをまだ同梱している ID（未移行の行を旧空間で検索できる）。
    /// いまは無し。モデル更新の 1 リリース目に旧 ID を入れ、2 リリース目で外す。
    /// ⚠️ ここに ID を入れるだけでは足りない: 検索側がクエリを空間ごとに埋め込み、行の `modelID` に
    /// 合う方で採点する必要がある（`AutoAlbumStore.enrichmentVectorPageWithModel` → `AIAlbumSearcher`）。
    /// 最初のモデル更新のときに実装する（それまでは現行モデルの行だけが検索対象）。
    public static let retainedClipTextTowers: [String] = []

    /// ある行の埋め込みが「いまの空間」か。
    public static func isCurrentClip(_ modelID: String?) -> Bool { (modelID ?? legacyClip) == clip }
    /// ある行の埋め込みを検索に使えるか（現行か、テキストタワーが残っている旧版）。
    public static func isSearchableClip(_ modelID: String?) -> Bool {
        let id = modelID ?? legacyClip
        return id == clip || retainedClipTextTowers.contains(id)
    }

    /// 顔の identity モデルの ID は**同梱モデル側（face_config.json の `model`）が宣言**する
    /// （`FacePerceptionProvider.modelID`・ADR-70 と同じ理由＝モデルとアプリの食い違いを防ぐ）。
    /// ID が `legacyFace` と違えば `Faces-<id>` の影の世代が育ち始める（`PeopleEngine`）。
    /// 既存データのコンテナ名 "FacesV1" が指すモデル。**ここは変えない**（変えると既存の人物が別世代扱いになる）。
    public static let legacyFace = "auraface-v1-r100"
}
