import Foundation

public extension Array where Element: PhotoItem {
    /// `captureDate` の降順（新しい順）に並べる。`captureDate` が nil の要素は末尾へ。
    func sortedByCaptureDateDescending() -> [Element] {
        sorted {
            switch ($0.captureDate, $1.captureDate) {
            case let (a?, b?): return a > b   // 新しい順
            case (nil, _):     return false   // nil は後ろ
            case (_, nil):     return true
            }
        }
    }

    /// `captureDate` の昇順（古い順＝新しいものが末尾）に並べる。`nil` は先頭（最も古い扱い）。
    /// グリッドは `defaultScrollAnchor(.bottom)` なので、これで「下が新しい写真」になる。
    func sortedByCaptureDateAscending() -> [Element] {
        sorted {
            switch ($0.captureDate, $1.captureDate) {
            case let (a?, b?): return a < b   // 古い順
            case (nil, _):     return true    // nil は先頭（最古扱い）
            case (_, nil):     return false
            }
        }
    }
}
