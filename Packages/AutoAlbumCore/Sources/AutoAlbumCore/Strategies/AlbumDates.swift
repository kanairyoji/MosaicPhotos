import Foundation
import MosaicSupport

/// メンバー写真の撮影日から「意味のある」開始/終了日を求める純ロジック（旅行・フォルダ・AI 共用）。
/// カメラ既定値の 1980 等（1990 未満）や欠落は `CaptureDate.meaningful` で除外し、偽の日付が
/// アルバム期間に混じらないようにする（表示側は `.distantPast` を「日時不明」に寄せる）。
/// `dates.min()/max() ?? .distantPast` を各戦略に散在させないための集約点。
public enum AlbumDates {
    /// 意味のある日付だけを昇順で返す。
    public static func meaningfulSorted(_ dates: [Date?]) -> [Date] {
        dates.compactMap { CaptureDate.meaningful($0) }.sorted()
    }

    /// 開始/終了日。有効な撮影日が無ければ両方 `.distantPast`。
    public static func range(_ dates: [Date?]) -> (start: Date, end: Date) {
        let sorted = meaningfulSorted(dates)
        return (sorted.first ?? .distantPast, sorted.last ?? .distantPast)
    }
}
