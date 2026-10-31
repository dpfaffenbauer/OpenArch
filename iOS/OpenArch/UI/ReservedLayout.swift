import SwiftUI

/// What iPhone Duo reserves on its displays: the status bar's column beside
/// the page, or its band above the page, whose free part takes the page's
/// controls, and the fold while the phone is partly folded. Elsewhere, all
/// are nil and the layout is that of any iPhone or iPad.
struct ReservedLayout: Equatable {
    struct Rail: Equatable {
        let edge: HorizontalEdge
        let width: CGFloat
        /// Where the status bar's symbols end.
        let top: CGFloat
    }

    struct Band: Equatable {
        /// Up to the status bar's symbols.
        let width: CGFloat
        let height: CGFloat
    }

    /// Narrower columns are the sides of an iPhone in landscape; shorter ones
    /// have no room for the controls, and neither has the band of an iPhone,
    /// with the Dynamic Island in its middle.
    private static let railMinWidth: CGFloat = 70
    private static let railMinHeight: CGFloat = 320
    private static let bandMinWidth: CGFloat = 400

    var rail: Rail?
    var band: Band?
    /// The active fold, in the coordinates of the safe area.
    var fold: CGRect?

    init(_ proxy: GeometryProxy) {
        #if compiler(>=6.4)
        guard #available(iOS 27.1, *) else { return }
        let size = proxy.size
        let insets = proxy.safeAreaInsets
        for region in proxy.reservedRegions(kind: .occlusion) {
            let frame = region.frame
            if frame.minX >= size.width, insets.trailing >= Self.railMinWidth,
               size.height - frame.maxY >= Self.railMinHeight {
                rail = Rail(edge: .trailing, width: insets.trailing, top: frame.maxY)
            } else if frame.maxX <= 0, insets.leading >= Self.railMinWidth,
                      size.height - frame.maxY >= Self.railMinHeight {
                rail = Rail(edge: .leading, width: insets.leading, top: frame.maxY)
            } else if frame.maxY <= 0, frame.minX >= Self.bandMinWidth {
                band = Band(width: frame.minX, height: insets.top)
            }
        }
        // -testFold: as if partly folded, for looking at it without a hinge.
        let options: ReservedRegion.QueryOptions = Demo.testsFold ? .includeInactive : []
        fold = proxy.reservedRegions(kind: .division, options: options).first?.frame
        #endif
    }

    /// Whether the controls stay in their bar below the page.
    var showsBottomBar: Bool {
        rail == nil && band == nil
    }

    /// Where the page goes on beyond the safe area: under the floating bars
    /// and the status bar, to the display's edges.
    func pageEdges(sidebarShown: Bool) -> Edge.Set {
        var edges: Edge.Set = []
        switch rail?.edge {
        case .leading: if !sidebarShown { edges.insert(.leading) }
        case .trailing: edges.insert(.trailing)
        case nil: break
        }
        if band != nil { edges.insert(.top) }
        if !showsBottomBar { edges.insert(.bottom) }
        return edges
    }
}
