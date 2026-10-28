import SwiftUI

@main
struct JSONViewerApp: App {
    private let doc = Document()
    private let settings = AppSettings.shared
    @AppStorage("inputOpen") private var inputOpen = true

    init() {
        if CommandLine.arguments.contains("--selftest") { selfTest(); exit(0) }
        // ⌘V outside a text field replaces the input.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [doc, settings] e in
            // ⌘= is the unshifted ⌘+ key on most layouts.
            // Compare only ⌘⇧⌥⌃: keys can also carry numericPad/function flags.
            let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
            if mods == .command, e.charactersIgnoringModifiers == "=" {
                settings.changeFontSize(by: 1)
                return nil
            }
            guard mods == .command,
                  e.charactersIgnoringModifiers == "v",
                  !(e.window?.firstResponder is NSText) else { return e }
            doc.pasteFromClipboard()
            return nil
        }
    }

    var body: some Scene {
        Window("JSON Viewer", id: "main") {
            MainView(inputOpen: $inputOpen)
                .environment(doc)
                .environment(settings)
                .frame(minWidth: 720, minHeight: 560)
                .onAppear { applyAppearance(settings.appearance) }
                .onChange(of: settings.appearance) { _, a in applyAppearance(a) }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Toggle Input") { inputOpen.toggle() }.keyboardShortcut("i")
                Button("Tree") { doc.view = .tree }
                Button("Text") { doc.view = .text }
                Divider()
                Button("Expand to 1") { doc.depth = 1 }.keyboardShortcut("1")
                Button("Expand to 2") { doc.depth = 2 }.keyboardShortcut("2")
                Button("Expand to 3") { doc.depth = 3 }.keyboardShortcut("3")
                Button("Expand All") { doc.depth = 99 }.keyboardShortcut("4")
                Divider()
                Button("Increase Font Size") { settings.changeFontSize(by: 1) }.keyboardShortcut("+")
                    .disabled(settings.fontSize >= AppSettings.fontSizes.upperBound)
                Button("Decrease Font Size") { settings.changeFontSize(by: -1) }.keyboardShortcut("-")
                    .disabled(settings.fontSize <= AppSettings.fontSizes.lowerBound)
                Divider()
            }
            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find…") { doc.findOpen = true; doc.focusFind += 1 }.keyboardShortcut("f")
                Button("Find Next") { doc.stepFind(1) }.keyboardShortcut("g").disabled(!doc.findOpen)
                Button("Find Previous") { doc.stepFind(-1) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!doc.findOpen)
                Divider()
                Button("Filter with jq") { doc.askMode = false; doc.focusQuery += 1 }.keyboardShortcut("l")
                Button("Ask in Plain English") { doc.askMode = true; doc.focusQuery += 1 }.keyboardShortcut("k")
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}

func applyAppearance(_ a: Appearance) {
    NSApp.appearance = switch a {
    case .auto: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
}

/// Run with `--selftest`: parser round-trip and error position checks.
func selfTest() {
    let v = try! JSONParser.parse(sampleJSON)
    precondition(v.compact == sampleJSON, "compact round-trip")
    precondition(try! JSONParser.parse(v.pretty) == v, "pretty round-trip")
    precondition(v.value(at: [.key("orders"), .index(0), .key("customer"), .key("name")]) == .string("Alice Johnson"))
    precondition(jqPath([.key("orders"), .index(0), .key("first name")]) == #".orders[0]["first name"]"#)
    precondition(try! JSONParser.parse(#"{"a":1e3,"b":"\u00e9\ud83d\ude00\n"}"#).compact == #"{"a":1e3,"b":"é😀\n"}"#)
    do { _ = try JSONParser.parse("{\n  \"a\": 1,\n  \"b\": }"); preconditionFailure("should fail") }
    catch let e as JSONParseError { precondition(e.line == 3 && e.column == 8, "got \(e)") } catch {}
    precondition(JQ.binary?.hasSuffix("Contents/Resources/jq") == true, "using \(JQ.binary ?? "no jq"), not the embedded one")
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let ids = try! await JQ.run(".orders[] | select(.coupon == null) | .customer.name", input: sampleJSON)
        precondition(ids == [.string("Alice Johnson"), .string("Carol White"), .string("Dave Brown")], "jq got \(ids)")
        do { _ = try await JQ.run(".orders[", input: sampleJSON); preconditionFailure("jq should fail") }
        catch let e as JQ.Failure { precondition(e.message.hasPrefix("syntax error"), e.message) }
        done.signal()
    }
    done.wait()
    print("selftest ok")
}
