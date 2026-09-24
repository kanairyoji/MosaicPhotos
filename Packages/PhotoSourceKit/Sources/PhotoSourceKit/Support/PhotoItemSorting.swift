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
        sorted(by: PhotoItemSorting.isBeforeByCaptureDate)
    }

    /// 同じ並べ替えを**その場で**行う（結果用の 2 本目の配列を作らない）。
    ///
    /// ⚠️ 12 万件の一覧では `sortedByCaptureDateAscending()` の戻り値と元配列が
    /// 並べ替えの間だけ同時に立ち、約 21MB のピークになる（常駐メモリの棚卸し）。
    /// 元の配列がもう要らない場所ではこちらを使う。
    mutating func sortByCaptureDateAscending() {
        sort(by: PhotoItemSorting.isBeforeByCaptureDate)
    }
}

/// 並べ替えの比較そのもの（`sorted` 版と `sort` 版で**同じ式を使う**ため 1 か所に置く）。
///
/// ⚠️ 書き写さないこと。`nil` の扱いを片方だけ直すと、同じ一覧が経路によって違う順で
/// 並び、指紋が毎回変わって再構築が止まらなくなる。
public enum PhotoItemSorting {
    /// 昇順（古い順）。`nil` は先頭（最も古い扱い）。
    public static func isBeforeByCaptureDate<Element: PhotoItem>(_ lhs: Element,
                                                                _ rhs: Element) -> Bool {
        switch (lhs.captureDate, rhs.captureDate) {
        case let (a?, b?): return a < b   // 古い順
        case (nil, nil):   return false   // ⚠️ 同順。true にすると a<b と b<a が同時に成立する
        case (nil, _):     return true    // nil は先頭（最古扱い）
        case (_, nil):     return false
        }
    }
}
