import UIKit

/// Keeps each page's CSS viewport fixed while fitting its backing view inside
/// the available preview. Place behind the camera, not outside the window:
/// WebKit snapshots require attached views and must not crop larger viewports.
@MainActor
final class BrowserOverlayHost: UIView {
    private var pages: [BrowserOverlayPage] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(_ pages: [BrowserOverlayPage]) {
        for page in self.pages where !pages.contains(where: { $0 === page }) {
            page.view.removeFromSuperview()
        }
        self.pages = pages
        for page in pages where page.view.superview !== self { addSubview(page.view) }
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        for page in pages {
            let width = CGFloat(page.source.contentWidth)
            let height = CGFloat(page.source.contentHeight)
            page.view.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let scale = min(bounds.width / width, bounds.height / height)
            page.view.transform = CGAffineTransform(scaleX: scale, y: scale)
            page.view.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}
