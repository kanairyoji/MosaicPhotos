#if canImport(UIKit)
import SwiftUI
import UIKit

/// UICollectionView を土台にした写真グリッド（SwiftUI ラッパー）。
///
/// SwiftUI の `ScrollView` + `LazyVGrid` は数万件規模で programmatic スクロールが不安定
/// （`scrollTo(id:)` が未実体化の遠い項目へ飛べない）・性能も伸び悩むため、写真アプリと同じ
/// `UICollectionView` に置き換える。これにより：
/// - 右端スクラバーは `contentOffset` を直接セットするのでどんな大ジャンプも確実。
/// - セル再利用が本物で 6.7万件でも軽い。先読みは `UICollectionViewDataSourcePrefetching`。
/// - スクロールで通り過ぎるセルは `prepareForReuse` で取得をキャンセル（画像は後追い）。
///
/// 列数（ズーム段階）・日付グルーピング（月/年）・ピンチ・タップ遷移は呼び出し側（`PhotoGridView`）
/// から制御する。
struct PhotoCollectionView<Store: PhotoStore>: UIViewRepresentable {
    let store: Store
    /// 表示アイテムのスナップショット（差分検出用。変化時に updateUIView で再適用）。
    let items: [Store.Item]
    /// 1 行あたりの列数。
    let columnCount: Int
    /// 日付セクション分け。nil = セクションなし（dense）。
    let grouping: PhotoGridGrouping?
    /// ピンチ終了時のスケール（>1 拡大／<1 縮小）。
    let onPinch: (CGFloat) -> Void
    /// セルタップ時に開く item.id。
    let onSelect: (Store.Item.ID) -> Void
    /// スクラブの開始(true)/終了(false)。背景処理の一時停止に使う。
    let onScrubbingChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, onPinch: onPinch, onSelect: onSelect, onScrubbingChange: onScrubbingChange)
    }

    func makeUIView(context: Context) -> UIView {
        context.coordinator.makeContainer(columns: max(1, columnCount), grouped: grouping != nil)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(items: items, columns: max(1, columnCount), grouping: grouping)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        private let store: Store
        private let onPinch: (CGFloat) -> Void
        private let onSelect: (Store.Item.ID) -> Void
        private let onScrubbingChange: (Bool) -> Void

        private var collectionView: UICollectionView!
        private var dataSource: UICollectionViewDiffableDataSource<String, Store.Item.ID>!
        private let scrubber = ScrubberView()

        /// 現在の一覧（COW で store の配列とバッファ共有＝追加コピーは軽い）と、id→index の対応。
        /// 以前は id→Item の dict（67k 件の構造体コピー＝約10MB）だったが、index 参照に変えてメモリ削減。
        private var items: [Store.Item] = []
        private var idToIndex: [Store.Item.ID: Int] = [:]
        /// 現在適用済みの構成シグネチャ（再適用の要否判定）。
        private var appliedSignature = ""
        private var currentColumns = 0
        private var currentGrouped = false
        private var didInitialScroll = false

        private let spacing: CGFloat = 2

        init(store: Store, onPinch: @escaping (CGFloat) -> Void,
             onSelect: @escaping (Store.Item.ID) -> Void,
             onScrubbingChange: @escaping (Bool) -> Void) {
            self.store = store
            self.onPinch = onPinch
            self.onSelect = onSelect
            self.onScrubbingChange = onScrubbingChange
            super.init()
        }

        // MARK: Setup

        func makeContainer(columns: Int, grouped: Bool) -> UIView {
            currentColumns = columns
            currentGrouped = grouped

            let layout = makeLayout(columns: columns, grouped: grouped)
            let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
            cv.backgroundColor = .systemBackground
            cv.alwaysBounceVertical = true
            cv.delegate = self
            cv.prefetchDataSource = self
            collectionView = cv

            configureDataSource(cv)

            // ピンチでズーム段階を変える。
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            cv.addGestureRecognizer(pinch)

            // スクラバー（UIKit）。contentOffset を直接動かすので大ジャンプも確実。
            scrubber.onScrub = { [weak self] fraction in self?.scrollTo(fraction: fraction) }
            scrubber.onActive = { [weak self] active in self?.onScrubbingChange(active) }

            let container = UIView()
            cv.translatesAutoresizingMaskIntoConstraints = false
            scrubber.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(cv)
            container.addSubview(scrubber)
            NSLayoutConstraint.activate([
                cv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                cv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                cv.topAnchor.constraint(equalTo: container.topAnchor),
                cv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                scrubber.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrubber.topAnchor.constraint(equalTo: container.topAnchor),
                scrubber.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                scrubber.widthAnchor.constraint(equalToConstant: 44),
            ])
            return container
        }

        private func makeLayout(columns: Int, grouped: Bool) -> UICollectionViewLayout {
            let cols = max(1, columns)
            let fraction = 1.0 / CGFloat(cols)
            // item 幅を 1/cols にし、subitems:[item] でグループが cols 個で自動的に埋まる。
            // セル間の隙間は contentInsets（各辺 spacing/2）で作る（interItemSpacing だと
            // 合計幅が超過して列が折り返す古典的問題があるため使わない）。
            let item = NSCollectionLayoutItem(layoutSize: .init(
                widthDimension: .fractionalWidth(fraction),
                heightDimension: .fractionalHeight(1.0)))
            item.contentInsets = NSDirectionalEdgeInsets(
                top: spacing / 2, leading: spacing / 2, bottom: spacing / 2, trailing: spacing / 2)
            // グループ高 = コンテナ幅 × 1/cols ＝ 正方形の行。
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1.0),
                                  heightDimension: .fractionalWidth(fraction)),
                subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            if grouped {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(32)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                header.pinToVisibleBounds = true
                section.boundarySupplementaryItems = [header]
            }
            return UICollectionViewCompositionalLayout(section: section)
        }

        private func configureDataSource(_ cv: UICollectionView) {
            let cellReg = UICollectionView.CellRegistration<ThumbCell, Store.Item.ID> { [weak self] cell, _, id in
                guard let self, let index = self.idToIndex[id], index < self.items.count else { return }
                let item = self.items[index]
                let px = self.cellPixelSize()
                let store = self.store
                cell.configure { await store.thumbnail(for: item, targetSize: px) }
            }
            dataSource = UICollectionViewDiffableDataSource<String, Store.Item.ID>(collectionView: cv) {
                cv, indexPath, id in
                cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: id)
            }
            let headerReg = UICollectionView.SupplementaryRegistration<SectionHeaderView>(
                elementKind: UICollectionView.elementKindSectionHeader
            ) { [weak self] view, _, indexPath in
                guard let self else { return }
                let sections = self.dataSource.snapshot().sectionIdentifiers
                view.title = indexPath.section < sections.count ? sections[indexPath.section] : nil
            }
            dataSource.supplementaryViewProvider = { cv, _, indexPath in
                cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
            }
        }

        // MARK: Update / snapshot

        func update(items: [Store.Item], columns: Int, grouping: PhotoGridGrouping?) {
            let grouped = grouping != nil
            // レイアウト（列数/グルーピング）が変わったら作り直す。
            if columns != currentColumns || grouped != currentGrouped {
                currentColumns = columns
                currentGrouped = grouped
                collectionView.setCollectionViewLayout(makeLayout(columns: columns, grouped: grouped), animated: false)
            }
            scrubber.isHidden = items.count <= 60

            let signature = "\(items.count)|\(columns)|\(String(describing: grouping))|\(items.first.map { "\($0.id)" } ?? "")|\(items.last.map { "\($0.id)" } ?? "")"
            if signature != appliedSignature {
                appliedSignature = signature
                applySnapshot(items: items, grouping: grouping)
            } else if !didInitialScroll {
                // 構成は変わらないがレイアウトが整った可能性。末尾スクロールを再試行する。
                DispatchQueue.main.async { [weak self] in self?.scrollToBottomIfNeeded() }
            }
        }

        private func applySnapshot(items: [Store.Item], grouping: PhotoGridGrouping?) {
            // items 配列（COW・共有）と id→index を更新。dict に構造体をコピーしない。
            self.items = items
            var index: [Store.Item.ID: Int] = [:]
            index.reserveCapacity(items.count)
            for (i, item) in items.enumerated() { index[item.id] = i }
            idToIndex = index

            var snapshot = NSDiffableDataSourceSnapshot<String, Store.Item.ID>()
            if let grouping {
                let sections = photoGridSections(items: items, grouping: grouping, colCount: max(1, currentColumns))
                // diffable はセクション識別子が一意必須。日付ソート済みなら通常重複しないが、
                // 同名ラベルが非隣接で再出現してもクラッシュしないよう、出現順を保って統合する。
                var order: [String] = []
                var idsByTitle: [String: [Store.Item.ID]] = [:]
                for section in sections {
                    let ids = section.rows.flatMap { $0.entries.map { $0.item.id } }
                    if idsByTitle[section.title] == nil { order.append(section.title) }
                    idsByTitle[section.title, default: []].append(contentsOf: ids)
                }
                snapshot.appendSections(order)
                for title in order { snapshot.appendItems(idsByTitle[title] ?? [], toSection: title) }
            } else {
                let single = ""   // dense：単一セクション（ヘッダなし）
                snapshot.appendSections([single])
                snapshot.appendItems(items.map { $0.id }, toSection: single)
            }
            // 67k 件の差分計算を避けるため reloadData 適用にする（起動時の main スレッド負荷を下げる）。
            dataSource.applySnapshotUsingReloadData(snapshot) { [weak self] in
                DispatchQueue.main.async { self?.scrollToBottomIfNeeded() }
            }
        }

        /// 初回のみ、タイムライン末尾（最新）へスクロールする。
        /// ⚠️ `layoutIfNeeded()`（全 ~22,500 行のセル属性を一括計算）は起動時の大スパイクになるため使わない。
        /// `scrollToItem(.bottom)` は対象付近だけを計算するので軽い（等間隔セルはオフセットを算術計算できる）。
        func scrollToBottomIfNeeded() {
            guard !didInitialScroll, let cv = collectionView, cv.bounds.height > 0 else { return }
            let lastSection = cv.numberOfSections - 1
            guard lastSection >= 0 else { return }
            let lastItem = cv.numberOfItems(inSection: lastSection) - 1
            guard lastItem >= 0 else { return }
            didInitialScroll = true
            cv.scrollToItem(at: IndexPath(item: lastItem, section: lastSection), at: .bottom, animated: false)
        }

        // MARK: Scroll / scrubber

        private func scrollTo(fraction: CGFloat) {
            guard let cv = collectionView else { return }
            let maxY = max(0, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            cv.setContentOffset(CGPoint(x: 0, y: CGFloat(min(max(0, fraction), 1)) * maxY), animated: false)
        }

        private func cellPixelSize() -> CGSize {
            let cols = CGFloat(max(1, currentColumns))
            let width = collectionView?.bounds.width ?? UIScreen.main.bounds.width
            let side = max(1, (width - spacing * (cols - 1)) / cols)
            let scale = UIScreen.main.scale
            return CGSize(width: side * scale, height: side * scale)
        }

        // MARK: Gestures / delegate

        @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
            guard gr.state == .ended else { return }
            onPinch(gr.scale)
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: false)
            if let id = dataSource.itemIdentifier(for: indexPath) {
                onSelect(id)
            }
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let prefetch: [Store.Item] = indexPaths.compactMap { ip in
                guard let id = dataSource.itemIdentifier(for: ip),
                      let idx = idToIndex[id], idx < items.count else { return nil }
                return items[idx]
            }
            guard !prefetch.isEmpty else { return }
            store.prefetch(prefetch, targetSize: cellPixelSize())
        }

        // MARK: Scroll → 背景処理の一時停止（#3）
        // スクラブだけでなく**通常スクロール中**も背景 CLIP 埋め込みを譲り、操作を滑らかにする。

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            onScrubbingChange(true)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { onScrubbingChange(false) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            onScrubbingChange(false)
        }
    }
}

// MARK: - Cell

private final class ThumbCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.clipsToBounds = true
        contentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// サムネイルをロードする。`prepareForReuse` でキャンセルされるため、高速スクロールで
    /// 通り過ぎるセルは取得が走らない（出現直後に少し待ってから取得＝R1 相当）。
    func configure(loader: @escaping () async -> UIImage?) {
        loadTask?.cancel()
        imageView.image = nil
        loadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            if Task.isCancelled { return }
            let image = await loader()
            if Task.isCancelled { return }
            imageView.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
    }
}

// MARK: - Section header

private final class SectionHeaderView: UICollectionReusableView {
    var title: String? {
        didSet { label.text = title }
    }
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - UIKit scrubber

/// 右端の縦スクラバー（UIKit）。ハンドルをドラッグするとその位置（0…1）を `onScrub` で通知する。
/// スクロール自体は `contentOffset` 直接制御のため、どんな大ジャンプも確実。
private final class ScrubberView: UIView {
    var onScrub: ((CGFloat) -> Void)?
    var onActive: ((Bool) -> Void)?

    private let handle = UIView()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.up.chevron.down"))
    private let handleHeight: CGFloat = 50
    private let handleWidth: CGFloat = 34
    private var fraction: CGFloat = 1   // 末尾（最新）start

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        handle.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.92)
        handle.layer.cornerRadius = handleHeight / 2
        handle.layer.borderWidth = 0.5
        handle.layer.borderColor = UIColor.separator.cgColor
        handle.layer.shadowColor = UIColor.black.cgColor
        handle.layer.shadowOpacity = 0.15
        handle.layer.shadowRadius = 2
        handle.layer.shadowOffset = .init(width: 0, height: 1)
        addSubview(handle)

        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.translatesAutoresizingMaskIntoConstraints = false
        handle.addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.centerXAnchor.constraint(equalTo: handle.centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: handle.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 16),
            chevron.heightAnchor.constraint(equalToConstant: 16),
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        addGestureRecognizer(pan)
        // ハンドル外のタップでも掴めるよう、ビュー全体をヒット対象にする。
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutHandle()
    }

    private func layoutHandle() {
        let usable = max(1, bounds.height - handleHeight)
        let y = min(max(0, fraction), 1) * usable
        handle.frame = CGRect(x: bounds.width - handleWidth - 2, y: y, width: handleWidth, height: handleHeight)
    }

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        let usable = max(1, bounds.height - handleHeight)
        let y = gr.location(in: self).y - handleHeight / 2
        fraction = min(max(0, y / usable), 1)
        layoutHandle()
        onScrub?(fraction)
        switch gr.state {
        case .began:
            onActive?(true)
            animateHandle(active: true)
        case .ended, .cancelled, .failed:
            onActive?(false)
            animateHandle(active: false)
        default:
            break
        }
    }

    private func animateHandle(active: Bool) {
        UIView.animate(withDuration: 0.12) {
            self.handle.transform = active ? CGAffineTransform(scaleX: 1.1, y: 1.1) : .identity
            self.handle.layer.shadowOpacity = active ? 0.3 : 0.15
        }
    }

    // ハンドル付近を確実に掴めるように、右側の帯だけをヒット領域にする（左側は下のグリッドへ通す）。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        point.x >= bounds.width - (handleWidth + 12)
    }
}
#endif
