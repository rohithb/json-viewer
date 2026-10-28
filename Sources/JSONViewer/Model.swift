import AppKit
import Observation

enum Parsed {
    case empty, ok(JSON), error(JSONParseError)
    var value: JSON? { if case .ok(let v) = self { v } else { nil } }
}

enum AskState: Equatable {
    case idle, loading(String)
    case review(jq: String, expl: String, question: String)
    case ran(jq: String, expl: String)
    case failed(String)
}

enum QueryResult { case ok([JSON]), error(String) }

struct Row: Identifiable {
    let id: [PathComponent]
    let label: String
    let value: JSON
    let depth: Int
    let isIndex: Bool
    let expanded: Bool
}

struct Line: Identifiable {
    let id: Int
    let indent: Int
    let tokens: [(String, TokenKind)]
    let path: [PathComponent]?
}

enum TokenKind { case key, punct, string, number, bool, null }

extension JSON {
    var tokenKind: TokenKind {
        switch self { case .string: .string; case .number: .number; case .bool: .bool; default: .null }
    }
}

@Observable
final class Document {
    // ponytail: parses on the main thread on each edit; move off-main + lazy outline if >5 MB files matter.
    var raw: String = "" { didSet { if raw != oldValue { reparse() } } }
    private(set) var parsed: Parsed = .empty
    private(set) var byteCount = 0

    var view: ViewMode = AppSettings.shared.defaultView
    var depth: Int = AppSettings.shared.defaultDepth { didSet { overrides = [:] } }
    var overrides: [String: Bool] = [:]
    var selection: [PathComponent]? = []

    var askMode = false
    var query = "" { didSet { if query != oldValue { overrides = [:]; scheduleQuery() } } }
    var askText = ""
    var ask: AskState = .idle
    private(set) var queryResult: (query: String, result: QueryResult)?
    private var queryTask: Task<Void, Never>?
    private var askTask: Task<Void, Never>?

    var findOpen = false
    var findText = "" { didSet { findIndex = 0; if let m = matches.first { selection = m; scrollTarget = m } } }
    var findIndex = 0
    var toast = ""
    private var toastTask: Task<Void, Never>?
    /// Set to make the visible view scroll a path into view.
    var scrollTarget: [PathComponent]?
    var focusQuery = 0  // bump to focus the query field
    var focusFind = 0

    init() { reparse() }

    private func reparse() {
        byteCount = raw.utf8.count
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parsed = .empty }
        else {
            do { parsed = .ok(try JSONParser.parse(raw)) } catch let e as JSONParseError { parsed = .error(e) } catch {}
        }
        selection = []
        overrides = [:]
        scheduleQuery()
    }

    // MARK: Query

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var queryActive: Bool { parsed.value != nil && !trimmedQuery.isEmpty && trimmedQuery != "." }

    private func scheduleQuery() {
        queryTask?.cancel()
        guard queryActive else { queryResult = nil; return }
        let q = trimmedQuery, input = raw
        queryTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let r: QueryResult
            do { r = .ok(try await JQ.run(q, input: input)) }
            catch let e as JQ.Failure { r = .error(e.message) }
            catch { return } // cancelled
            guard !Task.isCancelled else { return }
            queryResult = (q, r)
        }
    }

    /// Result of the current query, if it has finished and succeeded.
    var outputs: [JSON]? {
        guard queryActive, let qr = queryResult, qr.query == trimmedQuery, case .ok(let o) = qr.result else { return nil }
        return o
    }

    var queryError: String? {
        guard queryActive, let qr = queryResult, qr.query == trimmedQuery, case .error(let e) = qr.result else { return nil }
        return e
    }

    var showingResult: Bool { outputs != nil }
    var source: String { showingResult ? "res" : "doc" }
    var multi: Bool { (outputs?.count ?? 1) != 1 }

    /// The value shown in the formatted pane.
    var displayed: JSON? {
        if let o = outputs { return o.isEmpty ? nil : (o.count == 1 ? o[0] : .array(o)) }
        return parsed.value
    }

    var rootLabel: String { showingResult ? (multi ? "results" : "result") : "root" }

    var selectedPath: [PathComponent] {
        guard let s = selection, let d = displayed, d.value(at: s) != nil else { return [] }
        return s
    }

    // MARK: Tree

    func isExpanded(_ path: [PathComponent], depth d: Int, ancestors: Set<[PathComponent]>) -> Bool {
        if let o = overrides[source + jqPath(path)] { return o }
        if ancestors.contains(path) { return true }
        return d < depth
    }

    func setExpanded(_ path: [PathComponent], _ v: Bool) { overrides[source + jqPath(path)] = v }

    var rows: [Row] {
        guard let root = displayed else { return [] }
        let anc = findAncestors
        var out: [Row] = []
        func walk(_ v: JSON, _ label: String, _ path: [PathComponent], _ d: Int, _ isIdx: Bool) {
            let exp = v.isContainer && isExpanded(path, depth: d, ancestors: anc)
            out.append(Row(id: path, label: label, value: v, depth: d, isIndex: isIdx, expanded: exp))
            guard exp else { return }
            for (c, x) in v.children {
                if case .index = c { walk(x, c.label, path + [c], d + 1, true) } else { walk(x, c.label, path + [c], d + 1, false) }
            }
        }
        walk(root, rootLabel, [], 0, false)
        return out
    }

    // MARK: Text

    var lines: [Line] {
        guard let root = displayed else { return [] }
        var out: [Line] = []
        func emit(_ indent: Int, _ toks: [(String, TokenKind)], _ path: [PathComponent]?) {
            out.append(Line(id: out.count, indent: indent, tokens: toks, path: path))
        }
        func walk(_ v: JSON, _ indent: Int, _ path: [PathComponent], _ pre: [(String, TokenKind)], _ comma: Bool) {
            let cm: [(String, TokenKind)] = comma ? [(",", .punct)] : []
            switch v {
            case .object, .array:
                let isArr: Bool = if case .array = v { true } else { false }
                let (o, c) = isArr ? ("[", "]") : ("{", "}")
                let kids = v.children
                if kids.isEmpty { emit(indent, pre + [(o + c, .punct)] + cm, path); return }
                emit(indent, pre + [(o, .punct)], path)
                for (n, (k, x)) in kids.enumerated() {
                    let kp: [(String, TokenKind)] = if case .key(let s) = k { [(JSON.quote(s), .key), (": ", .punct)] } else { [] }
                    walk(x, indent + 1, path + [k], kp, n < kids.count - 1)
                }
                emit(indent, [(c, .punct)] + cm, nil)
            default:
                emit(indent, pre + [(v.primitiveText, v.tokenKind)] + cm, path)
            }
        }
        walk(root, 0, [], [], false)
        return out
    }

    // MARK: Find

    // ponytail: recomputed several times per render; memoise on (displayed, findText) if big docs feel slow.
    var matches: [[PathComponent]] {
        guard findOpen, !findText.isEmpty, let root = displayed else { return [] }
        let t = findText.lowercased()
        var out: [[PathComponent]] = []
        func walk(_ v: JSON, _ key: PathComponent?, _ path: [PathComponent]) {
            guard out.count <= 2000 else { return }
            if !path.isEmpty {
                let km = if case .key(let k)? = key { k.lowercased().contains(t) } else { false }
                let vm = !v.isContainer && v.primitiveText.lowercased().contains(t)
                if km || vm { out.append(path) }
            }
            for (c, x) in v.children { walk(x, c, path + [c]) }
        }
        walk(root, nil, [])
        return out
    }

    private var findAncestors: Set<[PathComponent]> {
        var s = Set<[PathComponent]>()
        for m in matches { for i in 0..<m.count { s.insert(Array(m.prefix(i))) } }
        return s
    }

    var currentMatch: [PathComponent]? {
        let m = matches
        return m.isEmpty ? nil : m[findIndex % m.count]
    }

    func stepFind(_ dir: Int) {
        let m = matches
        guard !m.isEmpty else { return }
        findIndex = ((findIndex + dir) % m.count + m.count) % m.count
        select(m[findIndex])
    }

    // MARK: Actions

    func select(_ path: [PathComponent]) { selection = path; scrollTarget = path }

    func replaceInput(_ text: String) {
        raw = text
        query = ""; askText = ""; ask = .idle
    }

    func pasteFromClipboard() {
        guard let t = NSPasteboard.general.string(forType: .string), !t.isEmpty else { showToast("Clipboard is empty"); return }
        replaceInput(t)
        showToast(parsed.value != nil ? "Pasted and formatted" : "Pasted — JSON is invalid")
    }

    func format() { if let v = parsed.value { raw = v.pretty } else { showToast("Fix the JSON first") } }
    func minify() { if let v = parsed.value { raw = v.compact } else { showToast("Fix the JSON first") } }

    func copy(_ text: String, _ label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(label)
    }

    func copyPath() { copy(jqPath(selectedPath), "Copied path") }
    /// Strings raw, everything else as 2-space pretty JSON.
    var selectedValueText: String? {
        guard let v = displayed?.value(at: selectedPath) else { return nil }
        if case .string(let s) = v { return s }
        return v.pretty
    }

    func copyValue() { if let t = selectedValueText { copy(t, "Copied value") } }

    func filterHere() {
        askMode = false; ask = .idle
        query = jqPath(selectedPath)
        selection = []
    }

    func clearQuery() { query = ""; askText = ""; ask = .idle; selection = [] }

    func showToast(_ m: String) {
        toast = m
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { toast = "" }
        }
    }

    // MARK: Ask

    func askAI(_ text: String? = nil) {
        let q = (text ?? askText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard let value = parsed.value else { showToast("Fix the JSON first"); return }
        let settings = AppSettings.shared
        guard settings.hasKey(settings.askProvider) else { showToast("Add an API key in Settings"); return }
        askMode = true; askText = q
        let name = settings.providers[settings.askProvider]?.name ?? "AI"
        ask = .loading("Translating “\(q)” to jq with \(name)…")
        askTask?.cancel()
        askTask = Task { @MainActor in
            do {
                let r = try await settings.askJQ(question: q, schema: schemaSummary(value))
                guard !Task.isCancelled else { return }
                ask = .review(jq: r.jq, expl: r.explanation, question: q)
            } catch {
                guard !Task.isCancelled else { return }
                ask = .failed(error.localizedDescription)
            }
        }
    }

    func runAsk() {
        guard case .review(let jq, let expl, _) = ask else { return }
        query = jq
        ask = .ran(jq: jq, expl: expl)
        selection = []
        scrollTarget = []
    }

    func editAskAsJQ() {
        let jq: String? = switch ask { case .review(let j, _, _), .ran(let j, _): j; default: nil }
        guard let jq else { return }
        query = jq; ask = .idle; askMode = false
        focusQuery += 1
    }

    func onEnterInQuery() {
        guard askMode else { return }
        if case .review(_, _, let q) = ask, q == askText.trimmingCharacters(in: .whitespacesAndNewlines) { runAsk() } else { askAI() }
    }

    var suggestions: [String] {
        if case .object(let o)? = parsed.value, o.contains(where: { $0.0 == "orders" }) {
            return ["Orders still pending", "Total value of shipped orders", "Customers outside the US", "Top 3 most expensive orders"]
        }
        return ["List every key", "Find strings containing error", "Count items"]
    }
}

func fmtBytes(_ n: Int) -> String {
    n < 1024 ? "\(n) B" : n < 1_048_576 ? String(format: "%.1f KB", Double(n) / 1024) : String(format: "%.1f MB", Double(n) / 1_048_576)
}

func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

let sampleJSON = #"{"store":{"name":"Example Shop","currency":"USD","updatedAt":"2026-01-15T10:30:00Z","open":true},"orders":[{"id":1001,"status":"shipped","total":149.97,"customer":{"name":"Alice Johnson","email":"alice@example.com","country":"US"},"items":[{"sku":"BK-101","title":"The Pragmatic Reader","qty":1,"price":39.99},{"sku":"HD-220","title":"Wireless Headphones","qty":1,"price":109.98}],"tags":["gift","priority"],"coupon":null},{"id":1002,"status":"pending","total":24.5,"customer":{"name":"Bob Smith","email":"bob@example.com","country":"CA"},"items":[{"sku":"MG-010","title":"Coffee Mug","qty":2,"price":12.25}],"tags":[],"coupon":"WELCOME10"},{"id":1003,"status":"delivered","total":312,"customer":{"name":"Carol White","email":"carol@example.com","country":"GB"},"items":[{"sku":"KB-300","title":"Mechanical Keyboard","qty":1,"price":129},{"sku":"MS-150","title":"Ergonomic Mouse","qty":1,"price":59},{"sku":"MN-270","title":"27-inch Monitor Arm","qty":1,"price":124}],"tags":["bulk"],"coupon":null},{"id":1004,"status":"cancelled","total":18.99,"customer":{"name":"Dave Brown","email":"dave@example.com","country":"AU"},"items":[{"sku":"NB-005","title":"Dotted Notebook","qty":1,"price":18.99}],"tags":["refunded"],"coupon":null},{"id":1005,"status":"shipped","total":205.4,"customer":{"name":"Eve Davis","email":"eve@example.com","country":"DE"},"items":[{"sku":"BG-410","title":"Laptop Backpack","qty":1,"price":89.5},{"sku":"LP-600","title":"Desk Lamp","qty":2,"price":57.95}],"tags":["priority"],"coupon":"SPRING5"}]}"#
