import Foundation

/// One coordinate system for the open-folder 3 × 3 grid. Drawing, click
/// hit-testing and reorder drop targets must all read from here: the previous
/// panel hit the whole cell (`contentShape` on `cellWidth × cellHeight`), so
/// clicking the label or the empty corner launched an app — exactly the bug
/// that `GridMetrics.iconIndex(at:count:)` had already fixed on the main grid.
///
/// Coordinates are "grid space": origin at the top-left of the padded
/// `LazyVGrid`, before the panel's `.offset`/`.scaleEffect` are applied.
/// `FolderOverlay` converts a `.global` drag location by subtracting the
/// grid frame it records once on appearance.
struct FolderGridMetrics: Equatable {
    static let columns = 3
    static let perPage = 9

    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var iconSize: CGFloat
    var columnSpacing: CGFloat = 12
    var rowSpacing: CGFloat = 18
    var horizontalPadding: CGFloat = 32
    var verticalPadding: CGFloat = 20
    /// Icon square's top offset inside a cell. The cell uses top alignment and
    /// an explicit spacer, so this value is exact rather than inferred from a
    /// VStack's implicit centring.
    var iconTop: CGFloat = 10
    /// Transparent padding around the artwork that still counts as "on the icon".
    var iconPadding: CGFloat = 10

    var iconBox: CGFloat { iconSize + iconPadding * 2 }

    var gridWidth: CGFloat {
        CGFloat(Self.columns) * cellWidth
            + CGFloat(Self.columns - 1) * columnSpacing
            + horizontalPadding * 2
    }

    var gridHeight: CGFloat {
        3 * cellHeight + 2 * rowSpacing + verticalPadding * 2
    }

    /// Whole cell of `slot`, in grid space.
    func cellRect(at slot: Int) -> CGRect {
        let col = slot % Self.columns
        let row = slot / Self.columns
        return CGRect(x: horizontalPadding + CGFloat(col) * (cellWidth + columnSpacing),
                      y: verticalPadding + CGFloat(row) * (cellHeight + rowSpacing),
                      width: cellWidth,
                      height: cellHeight)
    }

    /// Artwork square of `slot`, in grid space. FolderAppCell positions its
    /// icon with exactly this rect, so hit testing and drawing cannot diverge.
    func iconRect(at slot: Int) -> CGRect {
        let cell = cellRect(at: slot)
        return CGRect(x: cell.minX + (cell.width - iconBox) / 2,
                      y: cell.minY + iconTop,
                      width: iconBox,
                      height: iconBox)
    }

    /// Strict launch hit test. Only the artwork square opens an app; the label,
    /// cell corners, row/column gaps and trailing empty cells are inert.
    func iconIndex(at point: CGPoint, count: Int) -> Int? {
        let visible = min(Self.perPage, max(0, count))
        guard visible > 0 else { return nil }
        for slot in 0..<visible where iconRect(at: slot).insetBy(dx: -3, dy: -3).contains(point) {
            return slot
        }
        return nil
    }

    /// Reorder drop target. Any point maps to the cell it sits in, clamped to
    /// the number of apps actually shown on this folder page.
    func slot(at point: CGPoint, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let x = point.x - horizontalPadding
        let y = point.y - verticalPadding
        let col = min(Self.columns - 1,
                      max(0, Int(floor(x / max(1, cellWidth + columnSpacing)))))
        let row = min(2, max(0, Int(floor(y / max(1, cellHeight + rowSpacing)))))
        return min(row * Self.columns + col, count - 1)
    }

    /// Centre of the artwork in `.global` space, for probe drop points.
    func iconCenter(at slot: Int, in gridFrame: CGRect) -> CGPoint {
        let r = iconRect(at: slot)
        return CGPoint(x: gridFrame.minX + r.midX, y: gridFrame.minY + r.midY)
    }

    /// Pure preview of the reorder that `LauncherModel.reorderDraggedTile`
    /// performs on release. Keeping the arithmetic here lets the live
    /// make-way animation and the committed layout stay identical.
    static func displayIndex(index: Int, source: Int, insertion: Int) -> Int {
        if index == source { return insertion }
        if source < insertion {
            return (index > source && index <= insertion) ? index - 1 : index
        }
        if source > insertion {
            return (index >= insertion && index < source) ? index + 1 : index
        }
        return index
    }
}
