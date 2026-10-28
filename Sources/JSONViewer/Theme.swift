import SwiftUI

/// Design tokens (light, dark) from the handoff.
enum T {
    private static func c(_ light: UInt32, _ la: Double = 1, _ dark: UInt32, _ da: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (v, a) = isDark ? (dark, da) : (light, la)
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: a)
        })
    }

    static let win = c(0xFFFFFF, 1, 0x1E1E20)
    static let chrome = c(0xF3F3F5, 1, 0x2B2B2E)
    static let paneHead = c(0xFAFAFA, 1, 0x242427)
    static let drawer = c(0xFBFBFC, 1, 0x19191B)
    static let border = c(0x000000, 0.10, 0xFFFFFF, 0.09)
    static let text = c(0x1D1D1F, 1, 0xF2F2F4)
    static let text2 = c(0x6E6E73, 1, 0xA1A1A6)
    static let text3 = c(0xA1A1A6, 1, 0x6C6C71)
    static let field = c(0x000000, 0.055, 0xFFFFFF, 0.08)
    static let hover = c(0x000000, 0.06, 0xFFFFFF, 0.08)
    static let seg = c(0x000000, 0.07, 0xFFFFFF, 0.08)
    static let segOn = c(0xFFFFFF, 1, 0x5B5B60)
    static let selInactive = c(0x000000, 0.08, 0xFFFFFF, 0.10)
    static let key = c(0x7A3FB0, 1, 0xD0A8FF)
    static let string = c(0xB5381F, 1, 0xFF8F75)
    static let number = c(0x1C5FC2, 1, 0x7CB8FF)
    static let boolean = c(0xA6267A, 1, 0xF590C8)
    static let null = c(0x8A8A8E, 1, 0x8E8E93)
    static let punct = c(0x86868B, 1, 0x8E8E93)
    static let find = c(0xFFD60A, 0.25, 0xFFD60A, 0.18)
    static let findCur = c(0xFFCC00, 0.62, 0xFFCC00, 0.42)
    static let errBg = c(0xFF3B30, 0.08, 0xFF453A, 0.14)
    static let err = c(0xD70015, 1, 0xFF6961)
    static let ok = c(0x28A745, 1, 0x32D74B)
    static let accentSoft = Color.accentColor.opacity(0.16)

    static func color(_ k: TokenKind) -> Color {
        switch k { case .key: key; case .punct: punct; case .string: string; case .number: number; case .bool: boolean; case .null: null }
    }

    /// Data font size (Settings, ⌘+ / ⌘-). Read inside view bodies so changes re-render.
    static var monoSize: CGFloat { CGFloat(AppSettings.shared.fontSize) }
    static var rowHeight: CGFloat { (monoSize * 1.8).rounded() }
    static func mono(_ size: CGFloat = monoSize, _ w: Font.Weight = .regular) -> Font { .system(size: size, weight: w, design: .monospaced) }
}

/// Small text button used in pane headers (Paste · Format · Minify, Copy Path…).
struct TextButton: View {
    let title: String
    var color: Color = T.text2
    var action: () -> Void
    @State private var hover = false

    init(_ title: String, color: Color = T.text2, action: @escaping () -> Void) {
        self.title = title; self.color = color; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(hover ? T.text : color)
                .padding(.horizontal, 7).frame(height: 22)
                .background(hover ? T.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

/// Segmented control styled per the design (segOn thumb with a soft shadow).
struct Seg<V: Hashable>: View {
    let options: [(String, V)]
    @Binding var selection: V
    var height: CGFloat = 24
    var font: Font = .system(size: 12, weight: .medium)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { label, v in
                Button { selection = v } label: {
                    Text(label).font(font).foregroundStyle(T.text)
                        .padding(.horizontal, 9).frame(maxHeight: .infinity)
                        .background {
                            if selection == v {
                                RoundedRectangle(cornerRadius: 5).fill(T.segOn).shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(2).frame(height: height)
        .background(T.seg, in: RoundedRectangle(cornerRadius: 7))
    }
}
