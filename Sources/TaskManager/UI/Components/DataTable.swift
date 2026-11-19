import SwiftUI

/// One column of a custom table. `width == nil` means "take the remaining space".
struct TableColumnDef: Identifiable, Equatable {
    var id: String
    var title: String
    var width: CGFloat?
    var minWidth: CGFloat = 50
    var trailing = false
    /// Big value shown above the title, e.g. "24%" for CPU.
    var headerValue: String?
    /// 0...1, tints the header when the resource is busy.
    var headerHeat: Double = 0
    var sortable = true
}

/// Column widths per table, persisted so resizes survive relaunches.
final class ColumnWidths: ObservableObject {
    @Published private var widths: [String: CGFloat]
    private let key: String

    init(table: String) {
        key = "columnWidths." + table
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        widths = stored.mapValues { CGFloat($0) }
    }

    func width(_ column: TableColumnDef) -> CGFloat? {
        guard let base = column.width else { return nil }
        return max(column.minWidth, widths[column.id] ?? base)
    }

    func set(_ column: TableColumnDef, _ value: CGFloat) {
        widths[column.id] = max(column.minWidth, min(600, value))
    }

    func persist() {
        UserDefaults.standard.set(widths.mapValues { Double($0) }, forKey: key)
    }

    func reset() {
        widths = [:]
        persist()
    }
}

struct TableHeader<Menu: View>: View {
    var columns: [TableColumnDef]
    @Binding var sort: SortDescriptor
    @ObservedObject var widths: ColumnWidths
    var leadingInset: CGFloat = 0
    var tall = false
    @ViewBuilder var menu: () -> Menu

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset)
            ForEach(columns) { column in
                HeaderCell(column: column, sort: $sort, widths: widths, tall: tall)
            }
        }
        .frame(height: tall ? 50 : 32)
        .background(Theme.content)
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
        .contextMenu { menu() }
    }
}

private struct HeaderCell: View {
    var column: TableColumnDef
    @Binding var sort: SortDescriptor
    @ObservedObject var widths: ColumnWidths
    var tall: Bool

    @State private var hovering = false
    @State private var dragStart: CGFloat?

    var body: some View {
        let width = widths.width(column)
        let sorted = sort.column == column.id
        Button {
            guard column.sortable else { return }
            if sorted {
                sort.ascending.toggle()
            } else {
                // Like Windows: text sorts A→Z first, resources show the biggest first.
                sort = SortDescriptor(column: column.id, ascending: !column.trailing)
            }
        } label: {
            VStack(alignment: column.trailing ? .trailing : .leading, spacing: 0) {
                if tall {
                    Text(column.headerValue ?? " ")
                        .font(.system(size: 15, weight: .regular).monospacedDigit())
                        .foregroundStyle(Theme.text)
                }
                HStack(spacing: 3) {
                    if column.trailing, sorted { sortGlyph }
                    Text(column.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                    if !column.trailing, sorted { sortGlyph }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: column.trailing ? .bottomTrailing : .bottomLeading)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .background(headerFill)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .overlay(alignment: .trailing) {
            if column.width != nil { resizeHandle }
        }
    }

    private var headerFill: Color {
        if column.headerHeat > 0.6 { return Theme.heat(column.headerHeat) }
        return hovering ? Theme.hover : .clear
    }

    private var sortGlyph: some View {
        Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Theme.secondaryText)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStart == nil { dragStart = widths.width(column) ?? column.width ?? 80 }
                        // Trailing columns grow to the left, like Windows.
                        let delta = column.trailing ? -value.translation.width : value.translation.width
                        widths.set(column, (dragStart ?? 80) + delta)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        widths.persist()
                    }
            )
            .offset(x: column.trailing ? 0 : 3)
            .frame(maxWidth: .infinity, alignment: column.trailing ? .leading : .trailing)
    }
}

/// Places a cell at the column's width with the right alignment and padding.
struct Cell<Content: View>: View {
    var column: TableColumnDef
    @ObservedObject var widths: ColumnWidths
    var heat: Double = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        let width = widths.width(column)
        content()
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: column.trailing ? .trailing : .leading)
            .background(heat > 0 ? Theme.heat(heat) : Color.clear)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }
}

/// Hover/selection background shared by all table rows.
struct TableRowBackground: ViewModifier {
    var selected: Bool
    var height: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .frame(height: height)
            .background(selected ? Theme.selection : (hovering ? Theme.hover : Color.clear))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 14)
                        .padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension View {
    func tableRow(selected: Bool, height: CGFloat = Theme.rowHeight) -> some View {
        modifier(TableRowBackground(selected: selected, height: height))
    }
}
