import Foundation

public extension Array where Element: PhotoItem {
    /// `captureDate` の昇順（古い順＝新しいものが末尾）に**その場で**並べる。
    /// `nil` は先頭（最も古い扱い）。グリッドは `defaultScrollAnchor(.bottom)` なので、
    /// これで「下が新しい写真」になる。
    ///
    /// ⚠️ **結果を別配列で返す版は置かない**（レビュー 8 周目）。12 万件の一覧では戻り値と
    /// 元配列が並べ替えの間だけ同時に立ち、約 21MB のピークになる。戻り値版を残しておくと、
    /// 次に書く人がそちらを選んでしまう——**選べないようにするのが確実**。
    /// 元配列を保ちたい場面が出たら、そのときに `sorted(by:)` を直接書けばよい。
    mutating func sortByCaptureDateAscending() {
        sort(by: PhotoItemSorting.isBeforeByCaptureDate)
    }
}

/// 並べ替えの比較そのもの（純ロジック・テスト対象）。
///
/// ⚠️ 書き写さないこと。`nil` の扱いを片方だけ直すと、同じ一覧が経路によって違う順で
/// 並び、指紋が毎回変わって再構築が止まらなくなる。
public enum PhotoItemSorting {
    /// 昇順（古い順）。`nil` は先頭（最も古い扱い）。
    ///
    /// ⚠️ `(nil, nil)` は **false**（同順）。`true` にすると `a<b` と `b<a` が同時に成立し、
    /// strict weak ordering が壊れて `sort` の挙動が未定義になる。
    public static func isBeforeByCaptureDate<Element: PhotoItem>(_ lhs: Element,
                                                                _ rhs: Element) -> Bool {
        switch (lhs.captureDate, rhs.captureDate) {
        case let (a?, b?): return a < b   // 古い順
        case (nil, nil):   return false
        case (nil, _):     return true    // nil は先頭（最古扱い）
        case (_, nil):     return false
        }
    }
}
