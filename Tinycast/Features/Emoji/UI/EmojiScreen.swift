import SwiftUI

/// The emoji and symbol picker: a sectioned grid whose ↑/↓ move by visual row, not by index.
struct EmojiScreen: PaletteScreen {
    let index: EmojiIndex
    let frequent: FrequentEmojiStore
    let pinned: PinnedEmojiStore
    let core: AppCore
    let vm: PaletteState
    let tone: EmojiSkinTone
    let defaultColumns: EmojiGridColumns
    let openActions: () -> Void
    let scrollToFollow: () -> Void

    private var columns: EmojiGridColumns {
        vm.emojiGridColumnsOverride ?? defaultColumns
    }

    private var sections: [EmojiGridSection] {
        EmojiGrid.sections(
            query: vm.query, index: index, frequent: frequent, pinned: pinned,
            filter: vm.emojiCategoryFilter)
    }

    /// Flat grid order across sections — what the selection indexes.
    var rows: [EmojiEntry] { sections.flatMap(\.entries) }

    var primaryActionTitle: String { vm.pasteTarget?.pasteTitle ?? "Paste" }

    private func entry(at selection: Int) -> EmojiEntry? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let entry = entry(at: selection) else { return nil }
        let pinnedIndex = pinned.index(of: entry.glyph)
        return EmojiActionsMenu.content(
            entry: entry, core: core, target: vm.pasteTarget,
            pinnedIndex: pinnedIndex, pinnedCount: pinned.glyphs.count,
            columns: columns, defaultColumns: defaultColumns,
            togglePinned: { togglePinned(entry) },
            movePinned: { movePinned(entry, by: $0) },
            setColumns: setColumns)
    }

    func activate(at selection: Int) {
        guard let entry = entry(at: selection) else { return }
        core.emojiCoordinator.pasteEmoji(entry)
    }

    func secondary(at selection: Int) -> Bool {
        guard let entry = entry(at: selection) else { return false }
        core.emojiCoordinator.copyEmoji(entry)
        return true
    }

    /// ⌥↵ — the palette stays up, so a run of emoji goes over without re-summoning it.
    func pasteKeepingWindowOpen(at selection: Int) -> Bool {
        guard let entry = entry(at: selection) else { return false }
        core.emojiCoordinator.pasteEmojiKeepingWindowOpen(entry)
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        switch shortcut {
        case .actualSize:
            setColumns(defaultColumns)
            return true
        case .zoomIn:
            if let value = columns.offset(by: -1) { setColumns(value) }
            return true
        case .zoomOut:
            if let value = columns.offset(by: 1) { setColumns(value) }
            return true
        default:
            break
        }
        guard let entry = entry(at: selection) else { return false }
        switch shortcut {
        case .pin:
            togglePinned(entry)
            return true
        case .movePinnedUp:
            _ = movePinned(entry, by: -1)
            return true
        case .movePinnedDown:
            _ = movePinned(entry, by: 1)
            return true
        default:
            return false
        }
    }

    /// One visual row vertically, spilling into the neighbour by column; one cell horizontally.
    func move(_ delta: Int, axis: PaletteAxis, from selection: Int) -> Int? {
        let sections = sections
        let count = sections.reduce(0) { $0 + $1.entries.count }
        guard count > 0 else { return selection }
        switch axis {
        case .vertical:
            let geometry = EmojiGridGeometry(
                counts: sections.map(\.entries.count), columns: columns.rawValue)
            return delta > 0 ? geometry.down(from: selection) : geometry.up(from: selection)
        case .horizontal:
            return min(max(selection + delta, 0), count - 1)
        }
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        let sections = sections
        if !index.isLoaded {
            EmptyResults(text: "Loading emoji…")
        } else if sections.isEmpty {
            EmptyResults(text: "No emoji found")
        } else {
            EmojiGridView(
                sections: sections,
                selection: selection,
                tone: tone,
                columns: columns,
                scroll: scroll,
                onSelect: { vm.selection = $0 },
                onActivate: { activate(at: vm.selection) },
                onActions: { flat in
                    vm.selection = flat
                    openActions()
                }
            )
        }
    }

    private func togglePinned(_ entry: EmojiEntry) {
        let pinnedIndex = pinned.index(of: entry.glyph)
        let selectedPinnedOccurrence = selectedPinnedOccurrence(of: entry, pinnedIndex: pinnedIndex)
        pinned.toggle(entry.glyph)
        guard let pinnedIndex else {
            // All Categories gains one leading pin; keep the same non-pinned occurrence selected.
            if vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                vm.emojiCategoryFilter == .all
            {
                vm.selection += 1
            }
            return
        }
        guard selectedPinnedOccurrence else {
            // Removing a leading pin shifts the same catalog occurrence back one flat position.
            if vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                vm.emojiCategoryFilter == .all
            {
                vm.selection = max(vm.selection - 1, 0)
                scrollToFollow()
            } else if vm.emojiCategoryFilter == .pinned {
                vm.selection = min(vm.selection, max(rows.count - 1, 0))
                scrollToFollow()
            }
            return
        }
        vm.selection = EmojiGridGeometry.selectionAfterRemovingPin(
            at: pinnedIndex, remainingCount: pinned.glyphs.count)
        scrollToFollow()
    }

    /// Pinned is the leading section in these two views; search results are never pin positions.
    private func selectedPinnedOccurrence(of entry: EmojiEntry, pinnedIndex: Int?) -> Bool {
        guard vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            vm.emojiCategoryFilter == .all || vm.emojiCategoryFilter == .pinned,
            let pinnedIndex, vm.selection == pinnedIndex
        else { return false }
        return pinned.glyphs[pinnedIndex] == entry.glyph
    }

    @discardableResult
    private func movePinned(_ entry: EmojiEntry, by delta: Int) -> Bool {
        guard pinned.move(entry.glyph, by: delta) else { return false }
        follow(entry)
        return true
    }

    private func follow(_ entry: EmojiEntry) {
        let updated = rows
        vm.selection = updated.firstIndex(of: entry) ?? min(vm.selection, max(updated.count - 1, 0))
        scrollToFollow()
    }

    private func setColumns(_ value: EmojiGridColumns) {
        vm.emojiGridColumnsOverride = value == defaultColumns ? nil : value
        scrollToFollow()
    }
}

/// Actions menu for a cell, shown bottom-right on right-click like `ClipboardActionsMenu`.
@MainActor
enum EmojiActionsMenu {
    static func content(
        entry: EmojiEntry, core: AppCore, target: PasteTarget?, pinnedIndex: Int?,
        pinnedCount: Int, columns: EmojiGridColumns, defaultColumns: EmojiGridColumns,
        togglePinned: @escaping () -> Void, movePinned: @escaping (Int) -> Void,
        setColumns: @escaping (EmojiGridColumns) -> Void
    )
        -> PopoverMenuContent
    {
        let noun = entry.category.itemTitle
        var items = [
            PopoverMenuItem(
                title: target?.pasteTitle ?? "Paste",
                icon: .paste(target, fallback: "doc.on.clipboard"), shortcut: "↵"
            ) {
                core.emojiCoordinator.pasteEmoji(entry)
            },
            PopoverMenuItem(
                title: "Copy to Clipboard", systemImage: "doc.on.doc", shortcut: "⌘↵"
            ) {
                core.emojiCoordinator.copyEmoji(entry)
            },
            PopoverMenuItem(
                title: "Paste and Keep Window Open",
                icon: .paste(target, fallback: "macwindow"), shortcut: "⌥↵"
            ) {
                core.emojiCoordinator.pasteEmojiKeepingWindowOpen(entry)
            }
        ]

        items.append(
            PopoverMenuItem(
                title: pinnedIndex == nil ? "Pin \(noun)" : "Unpin \(noun)",
                systemImage: pinnedIndex == nil ? "pin" : "pin.slash",
                startsSection: true, shortcut: "⌘.", action: togglePinned))
        if let pinnedIndex {
            items.append(
                PopoverMenuItem(
                    title: "Move Up in Pinned", systemImage: "arrow.up",
                    isEnabled: pinnedIndex > 0, shortcut: "⌥⌘↑"
                ) {
                    movePinned(-1)
                })
            items.append(
                PopoverMenuItem(
                    title: "Move Down in Pinned", systemImage: "arrow.down",
                    isEnabled: pinnedIndex < pinnedCount - 1, shortcut: "⌥⌘↓"
                ) {
                    movePinned(1)
                })
        }

        items.append(
            PopoverMenuItem(
                title: "Actual Size", systemImage: "magnifyingglass",
                isEnabled: columns != defaultColumns, startsSection: true, shortcut: "⌘0"
            ) {
                setColumns(defaultColumns)
            })
        items.append(
            PopoverMenuItem(
                title: "Zoom In", systemImage: "plus.magnifyingglass",
                isEnabled: columns.offset(by: -1) != nil, shortcut: "⌘+"
            ) {
                if let value = columns.offset(by: -1) { setColumns(value) }
            })
        items.append(
            PopoverMenuItem(
                title: "Zoom Out", systemImage: "minus.magnifyingglass",
                isEnabled: columns.offset(by: 1) != nil, shortcut: "⌘-"
            ) {
                if let value = columns.offset(by: 1) { setColumns(value) }
            })

        return PopoverMenuContent(header: entry.displayName, items: items)
    }
}
