import Foundation

// MARK: - Grouping model

/// グループ表示の粒度。
public enum PhotoGridGrouping: Sendable {
    case month
    case year
}

/// グリッド内の 1 セル分のエントリ。`flatIndex` は全件フラットリスト上の位置で、
/// `NavigationLink(value:)` の遷移先インデックスとして使う。
public struct PhotoGridEntry<Item> {
    public let flatIndex: Int
    public let item: Item
}

/// セルを横方向に並べた 1 行（最大 `colCount` 個）。
/// `id` は行頭エントリの `flatIndex`（全件中で一意）。
public struct PhotoGridRowData<Item>: Identifiable {
    public let id: Int
    public let entries: [PhotoGridEntry<Item>]
}

/// 日付ラベルで束ねた 1 セクション。
public struct PhotoGridSection<Item>: Identifiable {
    public var id: String { title }
    public let title: String
    public let rows: [PhotoGridRowData<Item>]
}

// MARK: - Pure grouping function

/// `items` を月/年ラベルでグループ化し、各グループを `colCount` 列の行へ分割する。
///
/// View 非依存の純関数。`PhotoItem.captureDate` が `nil` のものは "Unknown" 扱い。
/// 元の並び順（呼び出し側がソート済み）を保ったまま、隣接する同一ラベルを 1 セクションに束ねる。
public func photoGridSections<Item: PhotoItem>(
    items: [Item],
    grouping: PhotoGridGrouping,
    colCount: Int
) -> [PhotoGridSection<Item>] {
    // 月＝YYYY-MM / 年＝YYYY（DisplayDate で全体統一）。
    let label: (Date) -> String = grouping == .year ? DisplayDate.year : DisplayDate.ym

    var result: [PhotoGridSection<Item>] = []
    var currentTitle: String?
    var currentEntries: [PhotoGridEntry<Item>] = []

    func flush() {
        guard let title = currentTitle, !currentEntries.isEmpty else { return }
        result.append(PhotoGridSection(title: title,
                                       rows: chunk(currentEntries, colCount: colCount)))
    }

    for (i, item) in items.enumerated() {
        let title = item.captureDate.map(label) ?? "Unknown"
        if title != currentTitle {
            flush()
            currentTitle = title
            currentEntries = []
        }
        currentEntries.append(PhotoGridEntry(flatIndex: i, item: item))
    }
    flush()
    return result
}

// オフメイン（Task.detached）で生成して main へ渡すため、Item が Sendable なら Sendable。
extension PhotoGridEntry: Sendable where Item: Sendable {}
extension PhotoGridRowData: Sendable where Item: Sendable {}
extension PhotoGridSection: Sendable where Item: Sendable {}

/// エントリ列を `colCount` ごとの行に分割する。
private func chunk<Item>(_ entries: [PhotoGridEntry<Item>], colCount: Int) -> [PhotoGridRowData<Item>] {
    let step = max(1, colCount)
    return stride(from: 0, to: entries.count, by: step).map { start in
        let end = min(start + step, entries.count)
        return PhotoGridRowData(id: entries[start].flatIndex,
                                entries: Array(entries[start..<end]))
    }
}
