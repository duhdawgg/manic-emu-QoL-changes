//
//  CollectionViewPagingLayout.swift
//  CollectionViewPagingLayout
//
//  Created by Amir Khorsandi on 12/23/19.
//  Copyright © 2019 Amir Khorsandi. All rights reserved.
//

import UIKit

public protocol CollectionViewPagingLayoutDelegate: AnyObject {
    
    /// Calls when the current page changes
    ///
    /// - Parameter layout: a reference to the layout class
    /// - Parameter currentPage: the new current page index
    func onCurrentPageChanged(layout: CollectionViewPagingLayout, currentPage: Int)
}


public extension CollectionViewPagingLayoutDelegate {
    func onCurrentPageChanged(layout: CollectionViewPagingLayout, currentPage: Int) {}
}


public class CollectionViewPagingLayout: UICollectionViewLayout {
    
    // MARK: Properties

    /// Number of visible items at the same time
    ///
    /// nil = no limit
    public var numberOfVisibleItems: Int?

    /// Constants that indicate the direction of scrolling for the layout.
    public var scrollDirection: UICollectionView.ScrollDirection = .horizontal

    /// See `ZPositionHandler` for details
    public var zPositionHandler: ZPositionHandler = .both

    /// Set `alpha` to zero when the cell is not loaded yet by collection view, enabling this prevents showing a cell before applying
    /// transforms but may cause flashing when you reload the data
    public var transparentAttributeWhenCellNotLoaded: Bool = false

    /// The animator for setting `contentOffset`
    ///
    /// See `ViewAnimator` for details
    public var defaultAnimator: ViewAnimator?

    public private(set) var isAnimating: Bool = false
    
    public weak var delegate: CollectionViewPagingLayoutDelegate?
    
    override public var collectionViewContentSize: CGSize {
        getContentSize()
    }

    /// Current page index
    ///
    /// Use `setCurrentPage` to change it
    public private(set) var currentPage: Int = 0 {
        didSet {
            delegate?.onCurrentPageChanged(layout: self, currentPage: currentPage)
        }
    }
    
    private var currentScrollOffset: CGFloat {
        let visibleRect = self.visibleRect
        if scrollDirection == .horizontal {
            let leadingInset = collectionView?.contentInset.left ?? 0
            return (visibleRect.minX + leadingInset) / max(visibleRect.width, 1)
        } else {
            let leadingInset = collectionView?.contentInset.top ?? 0
            return (visibleRect.minY + leadingInset) / max(visibleRect.height, 1)
        }
    }
    
    private var visibleRect: CGRect {
        collectionView.map { CGRect(origin: $0.contentOffset, size: $0.bounds.size) } ?? .zero
    }
    
    private var numberOfItems: Int {
        guard let numberOfSections = collectionView?.numberOfSections, numberOfSections > 0 else {
            return 0
        }
        return (0..<numberOfSections)
        .compactMap { collectionView?.numberOfItems(inSection: $0) }
        .reduce(0, +)
    }
    
    private var currentPageCache: Int?
    /// Page extent that the current `contentOffset` was built with. Bounds are already updated when a size change is reported, so this is the only record of the previous page width.
    private var lastPageSize: CGFloat = 0
    /// Set while rewriting offset for a new page size. Stops invalidation from deriving a page from the stale offset.
    private var isApplyingSizeChange = false
    private var attributesCache: [(page: Int, attributes: UICollectionViewLayoutAttributes)]?
    private var boundsObservation: NSKeyValueObservation?
    private var lastBounds: CGRect?
    private var currentViewAnimatorCancelable: ViewAnimatorCancelable?
    private var originalIsUserInteractionEnabled: Bool?
    /// Bumps on every `setCurrentPage` so a cancelled animation cannot snap offset back.
    private var pageSetGeneration: UInt64 = 0

    deinit {
        boundsObservation?.invalidate()
    }

    // MARK: Public functions
    
    public func setCurrentPage(_ page: Int,
                               animated: Bool = true,
                               animator: ViewAnimator? = nil,
                               completion: (() -> Void)? = nil) {
        safelySetCurrentPage(page, animated: animated, animator: animator, completion: completion)
    }

    public func setCurrentPage(_ page: Int,
                               animated: Bool = true,
                               completion: (() -> Void)? = nil) {
        safelySetCurrentPage(page, animated: animated, animator: defaultAnimator, completion: completion)
    }
    
    public func goToNextPage(animated: Bool = true,
                             animator: ViewAnimator? = nil,
                             completion: (() -> Void)? = nil) {
        setCurrentPage(currentPage + 1, animated: animated, animator: animator, completion: completion)
    }
    
    public func goToPreviousPage(animated: Bool = true,
                                 animator: ViewAnimator? = nil,
                                 completion: (() -> Void)? = nil) {
        setCurrentPage(currentPage - 1, animated: animated, animator: animator, completion: completion)
    }

    /// Calls `invalidateLayout` wrapped in `performBatchUpdates`
    /// - Parameter invalidateOffset: change offset and revert it immediately
    /// this fixes the zIndex issue more: https://stackoverflow.com/questions/12659301/uicollectionview-setlayoutanimated-not-preserving-zindex
    public func invalidateLayoutInBatchUpdate(invalidateOffset: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            // Rotation / view teardown can destroy the data source after this work is scheduled.
            // performBatchUpdates with empty updates then crashes with NSInternalInconsistencyException
            // when item counts change (e.g. 1 → 0) because dataSource became nil.
            guard let self,
                  let collectionView = self.collectionView,
                  collectionView.dataSource != nil,
                  collectionView.window != nil,
                  !collectionView.isHidden else { return }

            if invalidateOffset, !self.isAnimating {
                let original = collectionView.contentOffset
                collectionView.contentOffset = .init(x: original.x + 1, y: original.y + 1)
                collectionView.contentOffset = original
            }

            collectionView.performBatchUpdates({ [weak self] in
                self?.invalidateLayout()
            })
        }
    }
    
    
    // MARK: UICollectionViewLayout
    
    override public func prepare() {
        super.prepare()
        if lastPageSize <= 0.5 {
            let extent = currentPageExtent()
            if extent > 0.5 {
                lastPageSize = extent
            }
        }
    }

    override public func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        let newPageSize = pageExtent(of: newBounds.size)
        // Bounds already equal `newBounds` here, so comparing with `visibleRect` never caches the page.
        if lastPageSize > 0.5, newPageSize > 0.5, abs(newPageSize - lastPageSize) > 0.5 {
            currentPageCache = currentPage
        }
        return true
    }

    override public func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let currentScrollOffset = self.currentScrollOffset
        let numberOfItems = self.numberOfItems
        let attributesCount = numberOfVisibleItems ?? numberOfItems
        let visibleRangeMid = attributesCount / 2
        let currentPageIndex = Int(round(currentScrollOffset))
        var initialStartIndex = currentPageIndex - visibleRangeMid
        var initialEndIndex = currentPageIndex + visibleRangeMid
        if attributesCount % 2 != 0 {
            if currentPageIndex < visibleRangeMid {
                initialStartIndex -= 1
            } else {
                initialEndIndex += 1
            }
        }
        let startIndexOutOfBounds = max(0, -initialStartIndex)
        let endIndexOutOfBounds = max(0, initialEndIndex - numberOfItems)
        let startIndex = max(0, initialStartIndex - endIndexOutOfBounds)
        let endIndex = min(numberOfItems, initialEndIndex + startIndexOutOfBounds)
        
        var attributesArray: [(page: Int, attributes: UICollectionViewLayoutAttributes)] = []
        var section = 0
        var numberOfItemsInSection = collectionView?.numberOfItems(inSection: section) ?? 0
        var numberOfItemsInPrevSections = 0
        for index in startIndex..<endIndex {
            var item = index - numberOfItemsInPrevSections
            while item >= numberOfItemsInSection {
                numberOfItemsInPrevSections += numberOfItemsInSection
                section += 1
                numberOfItemsInSection = collectionView?.numberOfItems(inSection: section) ?? 0
                item = index - numberOfItemsInPrevSections
            }
            
            let cellAttributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: item, section: section))
            let pageIndex = CGFloat(index)
            let progress = pageIndex - currentScrollOffset
            var zIndex = Int(-abs(round(progress)))
            
            let cell = collectionView?.cellForItem(at: cellAttributes.indexPath)
            
            if let cell = cell as? TransformableView {
                cell.transform(progress: progress)
                zIndex = cell.zPosition(progress: progress)
            }
            
            if cell == nil || cell is TransformableView {
                cellAttributes.frame = visibleRect
                if cell == nil, transparentAttributeWhenCellNotLoaded {
                    cellAttributes.alpha = 0
                }
            } else {
                cellAttributes.frame = CGRect(origin: CGPoint(x: pageIndex * visibleRect.width, y: 0),
                                              size: visibleRect.size)
            }

            // In some cases attribute.zIndex doesn't work so this is the work-around
            if let cell = cell, [ZPositionHandler.both, .cellLayer].contains(zPositionHandler) {
                cell.layer.zPosition = CGFloat(zIndex)
            }

            if [ZPositionHandler.both, .layoutAttribute].contains(zPositionHandler) {
                cellAttributes.zIndex = zIndex
            }
            attributesArray.append((page: Int(pageIndex), attributes: cellAttributes))
        }
        attributesCache = attributesArray
        addBoundsObserverIfNeeded()
        return attributesArray.map(\.attributes)
    }
    
    override public func invalidateLayout() {
        super.invalidateLayout()
        guard !isApplyingSizeChange else { return }
        if let page = currentPageCache {
            let extent = currentPageExtent()
            if extent > 0.5, numberOfItems > 0, abs(extent - lastPageSize) > 0.5 {
                currentPageCache = nil
                isApplyingSizeChange = true
                setCurrentPage(page, animated: false)
                isApplyingSizeChange = false
                lastPageSize = currentPageExtent()
                return
            }
            // Size or items are not ready. Keep the cached page for the next invalidation.
            if extent <= 0.5 || numberOfItems == 0 {
                return
            }
            currentPageCache = nil
        }
        updateCurrentPageIfNeeded()
    }
    
    
    // MARK: Private functions
    
    private func pageExtent(of size: CGSize) -> CGFloat {
        scrollDirection == .horizontal ? size.width : size.height
    }

    private func currentPageExtent() -> CGFloat {
        guard let collectionView else { return 0 }
        return pageExtent(of: collectionView.bounds.size)
    }

    private func updateCurrentPageIfNeeded() {
        guard !isApplyingSizeChange, let collectionView else { return }
        let boundsPageSize = currentPageExtent()
        // Offset is still in the previous page size. Deriving a page from the new width jumps forward when the view shrinks.
        if lastPageSize > 0.5, boundsPageSize > 0.5, abs(boundsPageSize - lastPageSize) > 0.5 {
            return
        }
        var currentPage: Int = 0
        let contentOffset = collectionView.contentOffset
        let pageSize = scrollDirection == .horizontal ? collectionView.frame.width : collectionView.frame.height
        let offset = scrollDirection == .horizontal ?
            (contentOffset.x + collectionView.contentInset.left) :
            (contentOffset.y + collectionView.contentInset.top)
        if pageSize > 0 {
            currentPage = Int(round(offset / pageSize))
        }
        if boundsPageSize > 0.5 {
            lastPageSize = boundsPageSize
        }
        if currentPage != self.currentPage, !isAnimating {
            self.currentPage = currentPage
        }
    }
    
    private func getContentSize() -> CGSize {
        var safeAreaLeftRight: CGFloat = 0
        var safeAreaTopBottom: CGFloat = 0
        if #available(iOS 11, *) {
            safeAreaLeftRight = (collectionView?.safeAreaInsets.left ?? 0) + (collectionView?.safeAreaInsets.right ?? 0)
            safeAreaTopBottom = (collectionView?.safeAreaInsets.top ?? 0) + (collectionView?.safeAreaInsets.bottom ?? 0)
        }
        if scrollDirection == .horizontal {
            return CGSize(width: CGFloat(numberOfItems) * visibleRect.width, height: visibleRect.height - safeAreaTopBottom)
        } else {
             return CGSize(width: visibleRect.width - safeAreaLeftRight, height: CGFloat(numberOfItems) * visibleRect.height)
        }
    }
    
    private func safelySetCurrentPage(_ page: Int, animated: Bool, animator: ViewAnimator?, completion: (() -> Void)? = nil) {
        pageSetGeneration += 1
        let generation = pageSetGeneration
        let wasAnimating = isAnimating
        cancelCurrentPageAnimation()

        let pageSize = scrollDirection == .horizontal ? visibleRect.width : visibleRect.height
        let contentSize = scrollDirection == .horizontal ? collectionViewContentSize.width : collectionViewContentSize.height
        let leadingInset = scrollDirection == .horizontal ?
            (collectionView?.contentInset.left ?? 0) :
            (collectionView?.contentInset.top ?? 0)
        let minPossibleOffset = -leadingInset
        let maxPossibleOffset = contentSize - pageSize - leadingInset
        var offset = Double(pageSize) * Double(page) - Double(leadingInset)
        offset = max(Double(minPossibleOffset), offset)
        offset = min(offset, Double(maxPossibleOffset))
        let contentOffset: CGPoint = scrollDirection == .horizontal ? CGPoint(x: offset, y: 0) : CGPoint(x: 0, y: offset)

        // Match currentPage to the clamped offset so callers can chain pages while an animation is in flight.
        var targetPage = page
        if pageSize > 0 {
            let actual = (scrollDirection == .horizontal ? contentOffset.x : contentOffset.y) + leadingInset
            targetPage = Int(round(actual / pageSize))
        }

        let alreadyAtTarget = collectionView.map { isOffset($0.contentOffset, closeTo: contentOffset) } ?? true
        // Mark animating before assigning currentPage: onCurrentPageChanged may invalidate layout,
        // and updateCurrentPageIfNeeded must not snap currentPage back to the old offset.
        if animated, !alreadyAtTarget {
            isAnimating = true
        }
        if currentPage != targetPage {
            currentPage = targetPage
        }
        if alreadyAtTarget {
            completion?()
            return
        }

        if animated {
            // UIKit `setContentOffset(animated:)` cannot be retargeted; a second call is often ignored
            // and the exact-offset KVO never fires, leaving isAnimating stuck and currentPage stale.
            let pageAnimator: ViewAnimator
            if let animator {
                pageAnimator = animator
            } else if wasAnimating {
                // Keep velocity when chaining pages (key-repeat) instead of restarting ease-in.
                pageAnimator = DefaultViewAnimator(0.18, curve: .linear)
            } else {
                pageAnimator = DefaultViewAnimator(0.25, curve: .easeInOut)
            }
            setContentOffset(with: pageAnimator, offset: contentOffset, generation: generation, completion: completion)
        } else {
            collectionView?.setContentOffset(contentOffset, animated: false)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.pageSetGeneration else { return }
                self.invalidateLayoutInBatchUpdate()
                self.collectionView?.setContentOffset(contentOffset, animated: false)
                completion?()
            }
        }
    }

    private func cancelCurrentPageAnimation() {
        currentViewAnimatorCancelable?.cancel()
        currentViewAnimatorCancelable = nil
        if isAnimating {
            isAnimating = false
            if let isEnabled = originalIsUserInteractionEnabled {
                collectionView?.isUserInteractionEnabled = isEnabled
            }
            originalIsUserInteractionEnabled = nil
        }
    }

    private func isOffset(_ lhs: CGPoint, closeTo rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 0.5 && abs(lhs.y - rhs.y) < 0.5
    }

    private func setContentOffset(with animator: ViewAnimator, offset: CGPoint, generation: UInt64, completion: (() -> Void)? = nil) {
        guard let start = collectionView?.contentOffset else { return }
        let x = offset.x - start.x
        let y = offset.y - start.y
        originalIsUserInteractionEnabled = collectionView?.isUserInteractionEnabled ?? true
        collectionView?.isUserInteractionEnabled = false
        currentViewAnimatorCancelable = animator.animate { [weak self] progress, finished in
            guard let self, generation == self.pageSetGeneration, let collectionView = self.collectionView else { return }
            collectionView.contentOffset = CGPoint(x: start.x + x * CGFloat(progress),
                                                   y: start.y + y * CGFloat(progress))
            if finished {
                self.currentViewAnimatorCancelable = nil
                self.isAnimating = false
                collectionView.isUserInteractionEnabled = self.originalIsUserInteractionEnabled ?? true
                self.originalIsUserInteractionEnabled = nil
                collectionView.delegate?.scrollViewDidEndScrollingAnimation?(collectionView)
                self.invalidateLayoutInBatchUpdate()
                completion?()
            }
        }
    }
}


extension CollectionViewPagingLayout {
    private func addBoundsObserverIfNeeded() {
        guard boundsObservation == nil else { return }
        boundsObservation = collectionView?.observe(\.bounds, options: [.old, .new, .initial, .prior]) { [weak self] collectionView, _ in
            guard collectionView.bounds.size != self?.lastBounds?.size else { return }
            self?.lastBounds = collectionView.bounds
            self?.invalidateLayoutInBatchUpdate(invalidateOffset: true)
        }
    }
}
