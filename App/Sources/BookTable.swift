import AppKit
import AudibleCore
import SwiftUI

/// The library list as a plain `NSTableView` with a fixed row height.
///
/// SwiftUI `Table` diffs the old and new rows and, for every row inserted above the top visible row, AppKit builds a
/// full hosted row view just to measure its automatic height, then tears it down
/// (`_doAutomaticRowHeightsForInsertedAndVisibleRows`, about 17 ms per row). Finished → All Books inserted 509 rows
/// and froze the window for 9 s; In Audible Only → All Books 3 s. Here a list change keeps the visible cells and
/// gives them their new books; only the rows that scroll in are created.
struct BookTable: NSViewRepresentable {
    let model: LibraryModel
    let player: Player
    let books: [Book]
    let selection: Set<Book.ID>
    let sortOrder: [BookComparator]
    let columns: TableColumnCustomization<Book>
    let fontSize: TableFontSize
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model, player: player) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = ContextMenuTableView()
        table.menuProvider = { [weak coordinator] row in coordinator?.menu(forRow: row) }
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .sequentialColumnAutoresizingStyle
        // The fix: no automatic row heights, so AppKit never measures rows that aren't on screen.
        table.usesAutomaticRowHeights = false
        // The inset style's 17 pt intercell spacing plus the old minimum widths (957 pt) overflowed the 880 pt the
        // detail column has at the 1440 pt window with the inspector open; the status column was scrolled off.
        table.intercellSpacing.width = 8
        for column in BookColumn.allCases {
            let c = NSTableColumn(identifier: .init(column.rawValue))
            c.title = column.title
            c.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            switch column {
            case .title: c.minWidth = 160; c.width = 320
            case .author: c.minWidth = 80; c.width = 160
            case .narrator: c.minWidth = 80; c.width = 140
            case .genre: c.minWidth = 80; c.width = 150
            case .length: c.width = 64; c.minWidth = 64; c.maxWidth = 64
            case .purchased: c.width = 92; c.minWidth = 92; c.maxWidth = 92
            case .released: c.width = 54; c.minWidth = 54; c.maxWidth = 54
            case .rating: c.width = 46; c.minWidth = 46; c.maxWidth = 46
            }
            table.addTableColumn(c)
        }
        let status = NSTableColumn(identifier: .init(Coordinator.statusColumn))
        status.title = ""
        status.width = 24; status.minWidth = 24; status.maxWidth = 24
        status.resizingMask = []
        table.addTableColumn(status)
        table.autoresizingMask = [.width]  // follow the clip view, so columns re-fit when the window or inspector resizes
        // Column widths and order; visibility comes from `columns`. Restoring also restores the saved sort descriptors,
        // which must not write the model mid-update: `updateNSView` pushes the model's sort order into the table instead.
        coordinator.syncing = true
        table.autosaveName = "library"
        table.autosaveTableColumns = true
        coordinator.syncing = false
        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator
        table.headerView?.menu = headerMenu
        coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.model = model
        c.player = player
        guard let table = c.table else { return }
        for column in table.tableColumns where column.identifier.rawValue != Coordinator.statusColumn {
            let hidden = columns[visibility: column.identifier.rawValue] == .hidden
            if column.isHidden != hidden { column.isHidden = hidden }
        }
        if c.fontSize != fontSize {
            c.fontSize = fontSize
            table.rowHeight = max(34, ceil(fontSize.fonts.text.boundingRectForFont.height) + 12)
            c.books = []  // every visible cell is rebuilt with the new font below
        }
        if c.sortOrder != sortOrder {
            c.sortOrder = sortOrder
            c.syncing = true
            table.sortDescriptors = sortOrder.map { NSSortDescriptor(key: $0.column.rawValue, ascending: $0.order == .forward) }
            c.syncing = false
        }
        // `==` on arrays sharing storage is O(1), so an unchanged list costs nothing here.
        if c.books != books {
            let hadRows = !c.books.isEmpty
            c.books = books
            c.rows = Dictionary(uniqueKeysWithValues: books.enumerated().map { ($1.id, $0) })
            c.selection = []
            c.syncing = true
            table.deselectAll(nil)
            c.syncing = false
            if hadRows {
                // Keep the cell views: `reloadData()` tore down and rebuilt every visible cell (about 150 ms for
                // 25 rows × 9 columns). Fix the row count, then give the existing cells their new books.
                table.noteNumberOfRowsChanged()
                table.enumerateAvailableRowViews { rowView, row in
                    guard row < books.count else { return }
                    for column in 0..<rowView.numberOfColumns {
                        if let cell = rowView.view(atColumn: column) as? BookCellView { c.configure(cell, book: books[row]) }
                    }
                }
            } else {
                table.reloadData()
            }
        }
        if c.selection != selection {
            c.selection = selection
            let indexes = IndexSet(selection.compactMap { c.rows[$0] })
            c.syncing = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            c.syncing = false
            if let first = indexes.first, !table.rows(in: table.visibleRect).contains(first) { table.scrollRowToVisible(first) }
        }
        if c.focusRequest != focusRequest {
            c.focusRequest = focusRequest
            table.window?.makeFirstResponder(table)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        static let statusColumn = "status"
        var model: LibraryModel
        var player: Player
        weak var table: NSTableView?
        var books: [Book] = []
        var rows: [Book.ID: Int] = [:]
        var selection: Set<Book.ID> = []
        var sortOrder: [BookComparator] = []
        var fontSize: TableFontSize?
        var focusRequest = 0
        /// Set while the view pushes selection or sort into the table, so the delegate doesn't push it back.
        var syncing = false

        init(model: LibraryModel, player: Player) {
            self.model = model
            self.player = player
        }

        func numberOfRows(in tableView: NSTableView) -> Int { books.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < books.count else { return nil }
            let id = tableColumn.identifier
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? BookCellView ?? BookCellView(identifier: id)
            configure(cell, book: books[row])
            return cell
        }

        fileprivate func configure(_ cell: BookCellView, book: Book) {
            let fonts = (fontSize ?? .medium).fonts
            cell.label.font = fonts.text
            switch BookColumn(rawValue: cell.identifier?.rawValue ?? "") {
            case .title:
                cell.label.string = book.title
                cell.show(cover: model.artURL(for: book))
            case .author: cell.label.string = book.author
            case .narrator: cell.label.string = book.narratedBy
            case .genre: cell.label.string = book.primaryGenre
            case .length:
                cell.label.font = fonts.digits
                cell.label.string = book.durationText
            case .purchased: cell.label.string = book.purchaseDate?.formatted(date: .abbreviated, time: .omitted) ?? "—"
            case .released: cell.label.string = book.releaseDate?.formatted(.dateTime.year()) ?? "—"
            case .rating:
                cell.label.font = fonts.digits
                cell.label.string = book.rating.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"
            case nil:
                let status = book.hasAudio ? Self.status.converted : book.hasEncrypted ? Self.status.encrypted : Self.status.cloud
                cell.imageView?.image = status.image
                cell.imageView?.contentTintColor = status.color
                cell.imageView?.toolTip = status.help
            }
        }

        private static let status = (
            converted: (image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Converted"), color: NSColor.systemGreen, help: "Converted"),
            encrypted: (image: NSImage(systemSymbolName: "lock.circle.fill", accessibilityDescription: "Downloaded, not converted"), color: NSColor.systemOrange, help: "Downloaded, not converted"),
            cloud: (image: NSImage(systemSymbolName: "icloud", accessibilityDescription: "Not downloaded"), color: NSColor.secondaryLabelColor, help: "Not downloaded"))

        /// One layer per row instead of one per cell (225 on screen): cells draw into the row's layer.
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("row")
            if let view = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableRowView { return view }
            let view = NSTableRowView()
            view.identifier = id
            view.wantsLayer = true
            view.canDrawSubviewsIntoLayer = true
            return view
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            row < books.count ? books[row].title : nil
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table else { return }
            selection = Set(table.selectedRowIndexes.compactMap { $0 < books.count ? books[$0].id : nil })
            if model.selection != selection { model.selection = selection }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !syncing else { return }
            sortOrder = tableView.sortDescriptors.compactMap { d in
                d.key.flatMap(BookColumn.init(rawValue:)).map { BookComparator($0, order: d.ascending ? .forward : .reverse) }
            }
            model.sortOrder = sortOrder.isEmpty ? BookComparator.defaultOrder : sortOrder
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            guard sender.clickedRow >= 0, sender.clickedRow < books.count else { return }
            let book = books[sender.clickedRow]
            if let url = model.audioURL(for: book) { player.play(book, url: url) }
        }

        /// Right-click: the same actions as the grid, hosted as an AppKit menu (no `@Environment`, see CLAUDE.md).
        func menu(forRow row: Int) -> NSMenu? {
            guard row >= 0, row < books.count else { return nil }
            return NSHostingMenu(rootView: BookActions(book: books[row], model: model, player: player))
        }

        // Header right-click: show or hide columns, like SwiftUI's Table header menu.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            for column in BookColumn.allCases where column != .title {
                let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = column.rawValue
                item.state = model.columnCustomization[visibility: column.rawValue] == .hidden ? .off : .on
                menu.addItem(item)
            }
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            model.columnCustomization[visibility: id] = sender.state == .on ? .hidden : .visible
        }
    }
}

/// Selects the clicked row (unless it's already in the selection) before asking for its context menu, and fits the
/// columns to the window once it has a width (like SwiftUI's Table; later resizes follow the autoresizing style).
private final class ContextMenuTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?
    private var fitted = false

    override func layout() {
        super.layout()
        if !fitted, let width = enclosingScrollView?.contentView.bounds.width, width > 0 {
            fitted = true
            sizeToFit()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return menuProvider?(row)
    }
}

/// One cell: a label, with a 28 pt cover in the title column, or just the status symbol. Laid out by hand; no Auto Layout.
private final class BookCellView: NSTableCellView {
    var coverURL: URL?
    let label = LabelView()
    let cover = CoverView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        // Frames are set in `layout()`; keeping these views out of the window's Auto Layout engine makes adding and
        // removing rows cheap (the engine was updated for every cell added or removed).
        translatesAutoresizingMaskIntoConstraints = false
        switch identifier.rawValue {
        case BookTable.Coordinator.statusColumn:
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            image.translatesAutoresizingMaskIntoConstraints = false
            addSubview(image)
            imageView = image
        case BookColumn.title.rawValue:
            cover.translatesAutoresizingMaskIntoConstraints = false
            addSubview(cover)
            fallthrough
        default:
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { label.emphasized = backgroundStyle == .emphasized }
    }

    override func layout() {
        super.layout()
        imageView?.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: bounds.width, height: 16)
        var x: CGFloat = 2
        if cover.superview != nil {
            cover.frame = NSRect(x: x, y: (bounds.height - 28) / 2, width: 28, height: 28)
            x += 28 + 8
        }
        label.frame = NSRect(x: x, y: 0, width: max(0, bounds.width - x - 2), height: bounds.height)
    }

    /// Cached thumbnail now, else a placeholder and a decode off the main thread (dropped if the cell was reused).
    func show(cover url: URL?) {
        coverURL = url
        cover.image = url.flatMap { CoverCache.cached($0, pixels: CoverCache.thumbnailPixels) }
        guard let url, cover.image == nil else { return }
        Task { [weak self] in
            guard let image = await CoverCache.load(url, pixels: CoverCache.thumbnailPixels), let self, self.coverURL == url else { return }
            self.cover.image = image
        }
    }
}

/// The 28 pt thumbnail with rounded corners, or the placeholder, drawn directly.
private final class CoverView: NSView {
    var image: CGImage? { didSet { if image !== oldValue { needsDisplay = true } } }
    private static let placeholder = NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).addClip()
        if let image {
            // Scale to fill, like `Cover`'s `scaledToFill`.
            let scale = max(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
            let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
            NSGraphicsContext.current?.cgContext.draw(image, in: NSRect(origin: origin, size: size))
        } else {
            NSColor.quaternaryLabelColor.setFill()
            bounds.fill()
            let symbol = Self.placeholder.map { $0.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor])) ?? $0 }
            symbol?.draw(in: NSRect(x: 7, y: 7, width: 14, height: 14))
        }
    }
}

/// A single line of text drawn directly. `NSTextField` cost about 0.3 ms per cell to create, lay out, draw into its
/// own layer and free; 225 of them are on screen.
private final class LabelView: NSView {
    var string = "" { didSet { if string != oldValue { needsDisplay = true } } }
    var font = NSFont.systemFont(ofSize: NSFont.systemFontSize) { didSet { if font != oldValue { needsDisplay = true } } }
    var emphasized = false { didSet { if emphasized != oldValue { needsDisplay = true } } }

    private static let paragraph = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { string }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: Self.paragraph,
            .foregroundColor: emphasized ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
        ]
        let height = ceil(font.boundingRectForFont.height)
        let rect = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attributes)
    }
}

extension TableFontSize {
    private static let fonts = Dictionary(uniqueKeysWithValues: allCases.map { size in
        let points: CGFloat = switch size { case .small: 11; case .medium: 13; case .large: 15 }
        return (size, (text: NSFont.systemFont(ofSize: points), digits: NSFont.monospacedDigitSystemFont(ofSize: points, weight: .regular)))
    })

    var fonts: (text: NSFont, digits: NSFont) { Self.fonts[self]! }
}
