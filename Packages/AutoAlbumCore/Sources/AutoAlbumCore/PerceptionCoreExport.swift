// PerceptionCore（ClipMath / PhotoRef など共通プリミティブ）を再エクスポートし、
// import AutoAlbumCore しているコンシューマ（MobileCLIPKit / アプリ）が従来どおり
// ClipMath・PhotoRef を参照できるようにする（モジュール分割の後方互換・ADR）。
@_exported import PerceptionCore

// FaceCore（顔クラスタ・ピープル）も再エクスポート（MobileCLIPKit / アプリ互換）。
@_exported import FaceCore
