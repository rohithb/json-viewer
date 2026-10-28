import SwiftUI

struct FormattedPane: View {
    @Environment(Document.self) private var doc

    var body: some View {
        @Bindable var doc = doc
        VStack(spacing: 0) {
            header
            Divider()
            if doc.findOpen { FindBar(); Divider() }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(T.win)
    }

    private var header: some View {
        @Bindable var doc = doc
        return HStack(spacing: 8) {
            Text(doc.showingResult ? "Result" : "Formatted").font(.system(size: 12, weight: .semibold))
            if doc.showingResult {
                Text(doc.trimmedQuery).font(T.mono(11)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.tail)
                TextButton("Clear filter") { doc.clearQuery() }.fixedSize()
            }
            Text(meta).font(.system(size: 11.5)).foregroundStyle(T.text3).fixedSize()
            Spacer()
            Text("Expand to").font(.system(size: 11.5)).foregroundStyle(T.text2).fixedSize()
            Seg(options: [("1", 1), ("2", 2), ("3", 3), ("All", 99)], selection: $doc.depth,
                height: 20, font: .system(size: 11, weight: .medium))
                .help("⌘1 / ⌘2 / ⌘3 / ⌘4")
                .fixedSize()
            Button { doc.findOpen.toggle(); if doc.findOpen { doc.focusFind += 1 } } label: {
                Label("Find", systemImage: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(T.text2)
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(doc.findOpen ? T.seg : .clear, in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain).help("Find (⌘F)").fixedSize()
        }
        .padding(.horizontal, 12).frame(height: 34).background(T.paneHead)
    }

    private var meta: String {
        if let o = doc.outputs { return plural(o.count, "result", "results") }
        switch doc.parsed.value {
        case .object(let o)?: return plural(o.count, "key", "keys")
        case .array(let a)?: return plural(a.count, "item", "items")
        default: return ""
        }
    }

    @ViewBuilder private var content: some View {
        switch doc.parsed {
        case .empty:
            EmptyState(title: "Paste JSON to get started",
                       detail: Text("Press ⌘V anywhere in the window — it's formatted instantly.")) {
                Button("Load Sample") { doc.raw = sampleJSON }
            }
        case .error(let e):
            EmptyState(title: "This JSON can't be formatted",
                       detail: Text(e.message).font(T.mono()).foregroundStyle(T.err) + Text("\nLine \(e.line), column \(e.column)")) {}
        case .ok:
            if doc.showingResult && doc.displayed == nil {
                EmptyState(title: "No results", detail: Text("The filter ran but produced no output.")) {}
            } else if doc.view == .tree {
                TreeView()
            } else {
                TextJSONView()
            }
        }
    }
}

struct EmptyState<Actions: View>: View {
    let title: String
    let detail: Text
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(T.text)
            detail.font(.system(size: 12.5)).foregroundStyle(T.text2).multilineTextAlignment(.center)
            actions.padding(.top, 6)
        }.padding(32)
    }
}

// MARK: - Find bar

struct FindBar: View {
    @Environment(Document.self) private var doc
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var doc = doc
        let m = doc.matches
        HStack(spacing: 8) {
            TextField("Find keys and values", text: $doc.findText)
                .textFieldStyle(.roundedBorder).frame(width: 280)
                .focused($focused)
                .onSubmit { doc.stepFind(NSEvent.modifierFlags.contains(.shift) ? -1 : 1); focused = true }
                .onExitCommand { doc.findOpen = false }
            Text(doc.findText.isEmpty ? "" : m.isEmpty ? "No matches" : "\(doc.findIndex % m.count + 1) of \(m.count)")
                .font(.system(size: 11.5)).foregroundStyle(T.text2)
            Button { doc.stepFind(-1) } label: { Image(systemName: "chevron.left") }.disabled(m.isEmpty)
            Button { doc.stepFind(1) } label: { Image(systemName: "chevron.right") }.disabled(m.isEmpty)
            Spacer()
            Button("Done") { doc.findOpen = false }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).frame(height: 38).background(T.chrome)
        .onAppear { focused = true }
        .onChange(of: doc.focusFind) { _, _ in focused = true }
    }
}

// MARK: - Tree

struct TreeView: View {
    @Environment(Document.self) private var doc
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var doc = doc
        let rows = doc.rows
        let hits = Set(doc.matches)
        let cur = doc.currentMatch
        ScrollViewReader { proxy in
            List(rows, selection: $doc.selection) { r in
                TreeRow(row: r)
                    .listRowInsets(EdgeInsets(top: 0, leading: 6 + CGFloat(r.depth) * 16, bottom: 0, trailing: 6))
                    .listRowBackground(cur == r.id ? T.findCur : hits.contains(r.id) ? T.find : Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, T.rowHeight)
            .focused($focused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .return, .space, .home, .end]) { press in
                handleKey(press.key, rows) ? .handled : .ignored
            }
            .onCopyCommand {
                guard let t = doc.selectedValueText else { return [] }
                doc.showToast("Copied value")
                return [NSItemProvider(object: t as NSString)]
            }
            .onChange(of: doc.scrollTarget) { _, t in
                guard let t else { return }
                proxy.scrollTo(t)
                doc.scrollTarget = nil
            }
        }
    }

    private func handleKey(_ key: KeyEquivalent, _ rows: [Row]) -> Bool {
        guard !rows.isEmpty else { return false }
        let i = rows.firstIndex { $0.id == doc.selectedPath } ?? 0
        let r = rows[i]
        switch key {
        case .rightArrow:
            if r.value.isContainer && !r.expanded { doc.setExpanded(r.id, true) }
            else if r.expanded, i + 1 < rows.count { doc.select(rows[i + 1].id) }
        case .leftArrow:
            if r.expanded { doc.setExpanded(r.id, false) } else if !r.id.isEmpty { doc.select(Array(r.id.dropLast())) }
        case .return, .space:
            if r.value.isContainer { doc.setExpanded(r.id, !r.expanded) }
        case .home: doc.select(rows[0].id)
        case .end: doc.select(rows[rows.count - 1].id)
        default: return false
        }
        return true
    }
}

struct TreeRow: View {
    @Environment(Document.self) private var doc
    @Environment(\.backgroundProminence) private var prominence
    let row: Row

    var body: some View {
        let active = prominence == .increased
        let fg: Color? = active ? .white : nil
        HStack(spacing: 0) {
            Button { doc.setExpanded(row.id, !row.expanded) } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(fg ?? T.text2)
                    .rotationEffect(.degrees(row.expanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.12), value: row.expanded)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain).opacity(row.value.isContainer ? 1 : 0).disabled(!row.value.isContainer)
            Text(row.label).foregroundStyle(fg ?? (row.depth == 0 || row.isIndex ? T.text2 : T.key))
            Text(row.depth == 0 ? "  " : ": ").foregroundStyle(fg ?? T.punct)
            Text(valueText).foregroundStyle(fg ?? (row.value.isContainer ? T.text3 : T.color(row.value.tokenKind)))
                .lineLimit(1).truncationMode(.tail)
            if row.value.isContainer {
                Text(countText).font(.system(size: 11)).foregroundStyle(active ? .white.opacity(0.78) : T.text3)
                    .padding(.leading, 8).fixedSize()
            }
            Spacer(minLength: 0)
        }
        .font(T.mono())
        .frame(height: T.rowHeight)
    }

    private var valueText: String {
        switch row.value {
        case .array(let a): row.expanded ? "[" : preview(a.map { (nil, $0) }, isArray: true)
        case .object(let o): row.expanded ? "{" : preview(o.map { ($0.0, $0.1) }, isArray: false)
        default: String(row.value.primitiveText.prefix(400))
        }
    }

    private func preview(_ items: [(String?, JSON)], isArray: Bool) -> String {
        if isArray {
            guard !items.isEmpty else { return "[ ]" }
            let s = items.prefix(3).map { _, v -> String in
                switch v {
                case .array: return "[…]"
                case .object: return "{…}"
                default: let t = v.primitiveText; return t.count > 22 ? t.prefix(21) + "…" : t
                }
            }
            return "[ " + s.joined(separator: ", ") + (items.count > 3 ? ", …" : "") + " ]"
        }
        guard !items.isEmpty else { return "{ }" }
        return "{ " + items.prefix(4).map { $0.0! }.joined(separator: ", ") + (items.count > 4 ? ", …" : "") + " }"
    }

    private var countText: String {
        if case .array(let a) = row.value { return plural(a.count, "item", "items") }
        return plural(row.value.childCount, "key", "keys")
    }
}

// MARK: - Text

struct TextJSONView: View {
    @Environment(Document.self) private var doc

    var body: some View {
        let lines = doc.lines
        let sel = doc.selectedPath
        let hits = Set(doc.matches)
        let cur = doc.currentMatch
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { l in
                            HStack(spacing: 0) {
                                Text("\(l.id + 1)").foregroundStyle(T.text3)
                                    .frame(width: 40, alignment: .trailing).padding(.trailing, 12)
                                Text(attributed(l)).fixedSize()
                                    .padding(.leading, CGFloat(l.indent) * 2 * T.monoSize * 0.6)
                                Spacer(minLength: 16)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(T.mono())
                            .frame(height: T.rowHeight)
                            .background(bg(l.path, sel: sel, hits: hits, cur: cur))
                            .contentShape(Rectangle())
                            .onTapGesture { if let p = l.path { doc.selection = p } }
                            .id(l.id)
                        }
                    }
                    .padding(.vertical, 6)
                    // Fill the pane so short content isn't centred by the 2-axis ScrollView.
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                }
                .defaultScrollAnchor(.topLeading)
                .onChange(of: doc.scrollTarget) { _, t in
                    guard let t, let line = lines.first(where: { $0.path == t }) else { return }
                    proxy.scrollTo(line.id)
                    doc.scrollTarget = nil
                }
            }
        }
    }

    private func attributed(_ l: Line) -> AttributedString {
        var s = AttributedString()
        for (t, k) in l.tokens {
            var a = AttributedString(t)
            a.foregroundColor = T.color(k)
            s += a
        }
        return s
    }

    private func bg(_ p: [PathComponent]?, sel: [PathComponent], hits: Set<[PathComponent]>, cur: [PathComponent]?) -> Color {
        guard let p else { return .clear }
        if p == sel { return T.accentSoft }
        if p == cur { return T.findCur }
        return hits.contains(p) ? T.find : .clear
    }
}
