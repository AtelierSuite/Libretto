import Foundation

/// Changes to a table's structure and text, as the table panel makes them.
public enum TableEditing: Sendable {
    public static func setText(_ text: String, row: Int, cell: Int, in table: inout Table) {
        guard table.rows.indices.contains(row), table.rows[row].cells.indices.contains(cell) else { return }
        let existing = table.rows[row].cells[cell].blocks.flatMap(\.paragraphs)
        let lines = text.components(separatedBy: "\n")
        // Each line keeps the paragraph it replaces, so its style survives.
        table.rows[row].cells[cell].blocks = lines.enumerated().map { index, line in
            var paragraph = existing.indices.contains(index) ? existing[index] : (existing.last ?? Paragraph())
            if !existing.indices.contains(index) { paragraph = paragraph.splitCopy() }
            let format = paragraph.inlines.first { if case .text = $0.content { return true } else { return false } }?
                .format ?? RunFormat()
            paragraph.inlines = line.isEmpty ? [] : [Inline(.text(line), format: format)]
            return .paragraph(paragraph)
        }
    }

    public static func addRow(to table: inout Table) {
        let columns = max(1, table.columnCount)
        table.rows.append(TableRow(cells: (0..<columns).map { _ in TableCell(blocks: [.paragraph(Paragraph())]) }))
    }

    public static func addColumn(to table: inout Table) {
        // The new column takes a share of the width the others had.
        let total = table.gridColumns.reduce(0, +)
        let count = table.gridColumns.count + 1
        if total > 0 {
            table.gridColumns = table.gridColumns.map { $0 * (count - 1) / count } + [total / count]
        } else {
            table.gridColumns.append(1440)
        }
        for index in table.rows.indices {
            table.rows[index].cells.append(TableCell(blocks: [.paragraph(Paragraph())]))
        }
        clearCellWidths(&table)
        table.preservedPropertiesXML = table.preservedPropertiesXML.map(dropFixedLayout)
    }

    public static func removeLastRow(from table: inout Table) {
        guard table.rows.count > 1 else { return }
        table.rows.removeLast()
    }

    public static func removeLastColumn(from table: inout Table) {
        guard table.columnCount > 1 else { return }
        let removed = table.gridColumns.popLast() ?? 0
        if !table.gridColumns.isEmpty {
            table.gridColumns[table.gridColumns.count - 1] += removed
        }
        for index in table.rows.indices {
            guard var last = table.rows[index].cells.popLast() else { continue }
            if last.gridSpan > 1 {
                last.gridSpan -= 1
                table.rows[index].cells.append(last)
            }
        }
        clearCellWidths(&table)
    }

    /// Cell widths written for the old columns would fight the new grid.
    private static func clearCellWidths(_ table: inout Table) {
        for row in table.rows.indices {
            for cell in table.rows[row].cells.indices {
                table.rows[row].cells[cell].preservedPropertiesXML = table.rows[row].cells[cell].preservedPropertiesXML
                    .flatMap { xml in DOCXPatcher.editing(xml) { tcPr in tcPr.children(named: "tcW").forEach(tcPr.removeChild) } }
            }
        }
    }

    private static func dropFixedLayout(_ xml: String) -> String {
        DOCXPatcher.editing(xml) { tblPr in tblPr.children(named: "tblLayout").forEach(tblPr.removeChild) } ?? xml
    }
}
