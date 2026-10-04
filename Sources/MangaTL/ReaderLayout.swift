import AppKit

/// Single centred column of pages whose heights follow each page's aspect ratio.
/// Offsets are a prefix sum, so learning one page's real aspect is an O(n) float shift
/// (microseconds for thousands of pages) and visible-rect queries are a binary search —
/// `NSCollectionViewFlowLayout` instead re-queries every item on each invalidation.
final class ReaderLayout: NSCollectionViewLayout {
    static let maxColumnWidth: CGFloat = 900
    static let spacing: CGFloat = 8
    static let defaultAspect: CGFloat = 0.7

    /// Best-known width/height of a page (nil = not known yet).
    var aspectProvider: (Int) -> CGFloat? = { _ in nil }

    private var aspects: [CGFloat] = []
    private var offsets: [CGFloat] = []   // top of each page
    private var width: CGFloat = 0

    var columnWidth: CGFloat { min(width, Self.maxColumnWidth) }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let count = collectionView.numberOfItems(inSection: 0)
        let visibleWidth = collectionView.enclosingScrollView?.contentSize.width ?? collectionView.bounds.width
        guard count != aspects.count || visibleWidth != width else { return }
        width = visibleWidth
        aspects = (0..<count).map { aspectProvider($0) ?? Self.defaultAspect }
        recomputeOffsets(from: 0)
    }

    /// Records a page's real aspect ratio. Returns how far content above `anchorY` moved, so the
    /// caller can shift the scroll position and keep what the reader is looking at still.
    @discardableResult
    func setAspect(_ aspect: CGFloat, at index: Int, anchorY: CGFloat) -> CGFloat {
        guard aspects.indices.contains(index), abs(aspects[index] - aspect) > 0.001 else { return 0 }
        let oldHeight = height(of: index)
        aspects[index] = aspect
        let delta = height(of: index) - oldHeight
        recomputeOffsets(from: index)
        invalidateLayout()
        return offsets[index] < anchorY ? delta : 0
    }

    func index(atY y: CGFloat) -> Int {
        guard !offsets.isEmpty else { return 0 }
        var lo = 0, hi = offsets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if offsets[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func top(of index: Int) -> CGFloat { offsets.indices.contains(index) ? offsets[index] : 0 }

    private func height(of index: Int) -> CGFloat { (columnWidth / aspects[index]).rounded() }

    private func recomputeOffsets(from start: Int) {
        if offsets.count != aspects.count { offsets = Array(repeating: 0, count: aspects.count) }
        var y = start == 0 ? Self.spacing : offsets[start - 1] + height(of: start - 1) + Self.spacing
        for i in start..<aspects.count {
            offsets[i] = y
            y += height(of: i) + Self.spacing
        }
    }

    private func attributes(for index: Int) -> NSCollectionViewLayoutAttributes {
        let attrs = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attrs.frame = NSRect(x: ((width - columnWidth) / 2).rounded(), y: offsets[index], width: columnWidth, height: height(of: index))
        return attrs
    }

    override var collectionViewContentSize: NSSize {
        guard let last = offsets.indices.last else { return .zero }
        return NSSize(width: width, height: offsets[last] + height(of: last) + Self.spacing)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard !offsets.isEmpty else { return [] }
        var result: [NSCollectionViewLayoutAttributes] = []
        var i = index(atY: rect.minY)
        while i < offsets.count, offsets[i] <= rect.maxY {
            result.append(attributes(for: i))
            i += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        offsets.indices.contains(indexPath.item) ? attributes(for: indexPath.item) : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != width
    }

    override func invalidateLayout() {
        // A width change (window resize) needs every height recomputed in prepare().
        if let collectionView, (collectionView.enclosingScrollView?.contentSize.width ?? 0) != width { aspects = [] }
        super.invalidateLayout()
    }
}
