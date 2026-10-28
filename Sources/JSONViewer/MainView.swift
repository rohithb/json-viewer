import SwiftUI

struct MainView: View {
    @Environment(Document.self) private var doc
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var scheme
    @Binding var inputOpen: Bool
    @AppStorage("inputWidthFraction") private var inputFraction = 0.34

    var body: some View {
        @Bindable var doc = doc
        VStack(spacing: 0) {
            if doc.askMode { AskBar(); Divider() }
            if let e = doc.queryError {
                Text(e).font(T.mono(11.5)).foregroundStyle(T.err).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6).padding(.horizontal, 16).background(T.errBg)
                Divider()
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    if inputOpen {
                        InputPane().frame(width: geo.size.width * inputFraction)
                        SplitHandle(fraction: $inputFraction, total: geo.size.width).zIndex(1)
                    }
                    FormattedPane()
                }
            }
            Divider()
            PathBar()
        }
        .background(T.win)
        .overlay(alignment: .bottom) {
            if !doc.toast.isEmpty {
                Text(doc.toast).font(.system(size: 12)).foregroundStyle(.white)
                    .padding(.vertical, 6).padding(.horizontal, 12)
                    .background(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 44).allowsHitTesting(false)
            }
        }
        .navigationTitle("Untitled")
        .navigationSubtitle(status)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { inputOpen.toggle() } label: { Label("Input", systemImage: "sidebar.left").labelStyle(.titleAndIcon) }
                    .help("Toggle input (⌘I)")
            }
            ToolbarItem(placement: .principal) { QueryField() }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("View", selection: $doc.view) {
                    Text("Tree").tag(ViewMode.tree)
                    Text("Text").tag(ViewMode.text)
                }.pickerStyle(.segmented)
                Button { settings.appearance = scheme == .dark ? .light : .dark } label: { Image(systemName: "circle.lefthalf.filled") }
                    .help("Toggle appearance")
                Button { openSettings() } label: { Image(systemName: "gearshape") }.help("Settings (⌘,)")
            }
        }
    }

    private var status: String {
        switch doc.parsed {
        case .empty: "No content"
        case .ok: "Valid JSON · \(fmtBytes(doc.byteCount))"
        case .error: "Invalid JSON"
        }
    }
}

/// 1px divider with an 8pt drag area; stores the input pane's share of the width (18–65%).
struct SplitHandle: View {
    @Binding var fraction: Double
    let total: CGFloat
    @State private var start: Double?

    var body: some View {
        Rectangle().fill(T.border).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 8).contentShape(Rectangle())
                    .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { g in
                            let s = start ?? fraction
                            start = s
                            fraction = min(max(s + g.translation.width / total, 0.18), 0.65)
                        }
                        .onEnded { _ in start = nil })
            }
    }
}

// MARK: - Query field

struct QueryField: View {
    @Environment(Document.self) private var doc
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var doc = doc
        HStack(spacing: 6) {
            Seg(options: [("jq", false), ("✦ Ask", true)], selection: Binding(
                get: { doc.askMode }, set: { doc.askMode = $0; focused = true }),
                height: 22, font: .system(size: 11, weight: .semibold))
            TextField(doc.askMode ? "Ask in plain English — e.g. orders still pending"
                                  : "Filter with jq — e.g. .orders[] | select(.total > 100)",
                      text: doc.askMode ? $doc.askText : $doc.query)
                .textFieldStyle(.plain)
                .font(doc.askMode ? .system(size: 12.5) : T.mono(12.5))
                .focused($focused)
                .onSubmit { doc.onEnterInQuery() }
                .onExitCommand { focused = false }
                .onChange(of: doc.askText) { _, _ in
                    if case .ran = doc.ask {} else if case .loading = doc.ask {} else { doc.ask = .idle }
                }
            if let s = statusText {
                Text(s.0).font(.system(size: 11.5)).foregroundStyle(s.1).fixedSize()
            }
            if !(doc.askMode ? doc.askText : doc.query).isEmpty {
                Button { doc.clearQuery() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(T.text3) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.leading, 3).padding(.trailing, 8)
        .frame(minWidth: 260, idealWidth: 560, maxWidth: 560, minHeight: 30, maxHeight: 30)
        .background(T.field, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? Color.accentColor : .clear, lineWidth: 1))
        .onChange(of: doc.focusQuery) { _, _ in
            focused = true
            DispatchQueue.main.async { focusToolbarTextField() }
        }
    }

    /// @FocusState is unreliable inside toolbar items, so focus the AppKit field directly.
    private func focusToolbarTextField() {
        guard let w = NSApp.keyWindow, let frame = w.contentView?.superview else { return }
        func find(_ v: NSView) -> NSTextField? {
            if v === w.contentView { return nil } // only look in the titlebar/toolbar
            if let t = v as? NSTextField, t.isEditable { return t }
            return v.subviews.lazy.compactMap(find).first
        }
        if let t = find(frame) { w.makeFirstResponder(t) }
    }

    private var statusText: (String, Color)? {
        if let o = doc.outputs { return (plural(o.count, "result", "results"), T.text2) }
        if doc.queryError != nil { return ("Invalid filter", T.err) }
        if doc.askMode, case .review = doc.ask { return ("Press ⏎ to run", T.text2) }
        return nil
    }
}

// MARK: - Ask bar

struct AskBar: View {
    @Environment(Document.self) private var doc
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            switch doc.ask {
            case .idle:
                Text("Try").foregroundStyle(T.text2)
                ForEach(doc.suggestions, id: \.self) { s in Chip(title: s) { doc.askAI(s) } }
                Spacer()
                let cfg = settings.providers[settings.askProvider]!
                if settings.hasKey(settings.askProvider) {
                    Text("\(cfg.name) · \(cfg.model)").foregroundStyle(T.text3)
                } else {
                    Text("No API key").foregroundStyle(T.text2)
                    Button("Add Key…") { settings.settingsTab = "ai"; openSettings() }.controlSize(.small)
                }
            case .loading(let msg):
                Text("✦").foregroundStyle(Color.accentColor)
                Text(msg).foregroundStyle(T.text2).lineLimit(1)
                ProgressView().controlSize(.mini)
                Spacer()
            case .failed(let msg):
                Text("✦").foregroundStyle(Color.accentColor)
                Text(msg).foregroundStyle(T.err).lineLimit(2)
                Spacer()
                Button("Settings…") { settings.settingsTab = "ai"; openSettings() }.controlSize(.small)
            case .review(let jq, let expl, _), .ran(let jq, let expl):
                Text("✦ Generated jq").fontWeight(.semibold).foregroundStyle(Color.accentColor).fixedSize()
                Text(jq).font(T.mono(11.5)).lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(T.win, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(T.border))
                    .textSelection(.enabled)
                Text(expl).foregroundStyle(T.text2).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Button("Edit as jq") { doc.editAskAsJQ() }.controlSize(.small)
                if case .ran = doc.ask {
                    Text("Applied").foregroundStyle(T.text2)
                } else {
                    Button("Run ⏎") { doc.runAsk() }.controlSize(.small).buttonStyle(.borderedProminent)
                }
            }
        }
        .font(.system(size: 12))
        .padding(.vertical, 6).padding(.horizontal, 16).frame(minHeight: 40)
        .background(T.chrome)
    }
}

struct Chip: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(T.text)
                .padding(.horizontal, 10).frame(height: 24)
                .background(T.win, in: Capsule())
                .overlay(Capsule().stroke(hover ? Color.accentColor : T.border))
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}

// MARK: - Input pane

struct InputPane: View {
    @Environment(Document.self) private var doc

    var body: some View {
        @Bindable var doc = doc
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Input").font(.system(size: 12, weight: .semibold))
                Circle().fill(validColor).frame(width: 7, height: 7)
                Spacer()
                TextButton("Paste") { doc.pasteFromClipboard() }.help("Paste from clipboard")
                TextButton("Format") { doc.format() }.help("Pretty-print the input")
                TextButton("Minify") { doc.minify() }.help("Minify the input")
            }
            .padding(.horizontal, 12).frame(height: 34).background(T.paneHead)
            Divider()
            Text("\(validWord) · \(fmtBytes(doc.byteCount))").font(.system(size: 11)).foregroundStyle(T.text2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).padding(.horizontal, 14)
            Divider()
            RawEditor(text: $doc.raw, fontSize: T.monoSize)
                .overlay(alignment: .topLeading) {
                    if doc.raw.isEmpty {
                        Text("Paste JSON here…").font(T.mono()).foregroundStyle(T.text3)
                            .padding(.vertical, 12).padding(.horizontal, 19).allowsHitTesting(false)
                    }
                }
            if case .error(let e) = doc.parsed {
                Text("Line \(e.line), column \(e.column) — \(e.message)").font(.system(size: 11.5)).foregroundStyle(T.err)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7).padding(.horizontal, 14).background(T.errBg)
            }
        }
        .background(T.drawer)
    }

    private var validColor: Color {
        switch doc.parsed { case .empty: T.text3; case .ok: T.ok; case .error: T.err }
    }
    private var validWord: String {
        switch doc.parsed { case .empty: "Empty"; case .ok: "Valid"; case .error: "Invalid" }
    }
}

/// NSTextView with smart quotes/dashes off — TextEditor would corrupt JSON.
struct RawEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.textContainerInset = NSSize(width: 9, height: 12)
        for flag in [\NSTextView.isAutomaticQuoteSubstitutionEnabled, \.isAutomaticDashSubstitutionEnabled,
                     \.isAutomaticTextReplacementEnabled, \.isAutomaticSpellingCorrectionEnabled,
                     \.isContinuousSpellCheckingEnabled, \.isGrammarCheckingEnabled] {
            tv[keyPath: flag] = false
        }
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.25
        tv.defaultParagraphStyle = para
        tv.typingAttributes[.paragraphStyle] = para
        tv.drawsBackground = false
        sv.drawsBackground = false
        tv.string = text
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let tv = sv.documentView as! NSTextView
        if tv.string != text { tv.string = text }
        if tv.font?.pointSize != fontSize { tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RawEditor
        init(_ p: RawEditor) { parent = p }
        func textDidChange(_ n: Notification) { parent.text = (n.object as! NSTextView).string }
    }
}

// MARK: - Path bar

struct PathBar: View {
    @Environment(Document.self) private var doc

    var body: some View {
        let path = doc.selectedPath
        HStack(spacing: 4) {
            if doc.displayed != nil {
                let crumbs = [(doc.rootLabel, [PathComponent]())] + path.indices.map { (path[$0].label, Array(path[...$0])) }
                ForEach(crumbs.indices, id: \.self) { i in
                    if i > 0 { Text("›").foregroundStyle(T.text3) }
                    let last = i == crumbs.count - 1
                    Button(crumbs[i].0) { doc.select(crumbs[i].1) }.buttonStyle(.plain)
                        .foregroundStyle(last ? T.text : T.text2).fontWeight(last ? .semibold : .regular)
                }
                Spacer(minLength: 12)
                Text(jqPath(path)).font(T.mono(11)).foregroundStyle(T.text2).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 320, alignment: .trailing)
                TextButton("Copy Path") { doc.copyPath() }
                TextButton("Copy Value") { doc.copyValue() }
                if !doc.showingResult && !path.isEmpty {
                    TextButton("Filter Here", color: .accentColor) { doc.filterHere() }
                }
            } else {
                Spacer()
            }
        }
        .font(.system(size: 11.5)).lineLimit(1)
        .padding(.horizontal, 12).frame(height: 28).background(T.chrome)
    }
}
