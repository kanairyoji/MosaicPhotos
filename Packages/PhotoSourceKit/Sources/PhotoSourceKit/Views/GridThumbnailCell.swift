#if canImport(UIKit)
import UIKit

/// `PhotoCollectionView` のサムネイルセル。`UIImageView` を1枚持ち、`configure(loader:)` で
/// 非同期にサムネイルを読み込む。`prepareForReuse` でロードをキャンセルするため、高速スクロールで
/// 通り過ぎるセルは取得が走らない（出現直後に少し待ってから取得＝画像は後追い）。
final class GridThumbnailCell: UICollectionViewCell {
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
#endif
