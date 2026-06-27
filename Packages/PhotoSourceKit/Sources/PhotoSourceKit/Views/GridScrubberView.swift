#if canImport(UIKit)
import UIKit

/// 右端の縦スクラバー（UIKit）。ハンドルをドラッグするとその位置（0…1）を `onScrub` で通知する。
/// スクロール自体は呼び出し側が `contentOffset` を直接動かすため、どんな大ジャンプも確実に効く。
final class GridScrubberView: UIView {
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

    // ハンドル付近を確実に掴めるよう、右側の帯だけをヒット領域にする（左側は下のグリッドへ通す）。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        point.x >= bounds.width - (handleWidth + 12)
    }
}
#endif
