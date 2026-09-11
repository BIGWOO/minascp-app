import SwiftUI
import AppKit

extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self { case .light: return .light; case .dark: return .dark; case .system: return nil }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
}

enum GlassAppearance {
    // The percentage controls backdrop exposure, never the alpha of text or controls.
    static func backgroundOpacity(transparency: Double, reduceTransparency: Bool, increaseContrast: Bool) -> Double {
        guard !reduceTransparency else { return 1 }
        let exposure = Preferences.normalizedTransparency(transparency) / 100
        return max(increaseContrast ? 0.8 : 0.15, 1 - 0.85 * exposure)
    }
}

/// The bridge only owns the window's backdrop. SwiftUI and BrowserModel own state.
private struct WindowBackdrop: NSViewRepresentable {
    let transparency: Double
    let reduceTransparency: Bool
    let increaseContrast: Bool

    func makeNSView(context: Context) -> WindowBackdropView { WindowBackdropView() }
    func updateNSView(_ view: WindowBackdropView, context: Context) {
        view.coverOpacity = GlassAppearance.backgroundOpacity(transparency: transparency, reduceTransparency: reduceTransparency, increaseContrast: increaseContrast)
        view.refreshMaterial()
    }
}

private final class WindowBackdropView: NSView {
    private let material = NSVisualEffectView()
    private let cover = NSView()
    var coverOpacity = 1.0

    init() {
        super.init(frame: .zero)
        material.material = .underWindowBackground
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        for child in [material, cover] {
            child.frame = bounds
            child.autoresizingMask = [.width, .height]
            addSubview(child)
        }
        cover.wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = false
        window?.backgroundColor = .clear
        // Standalone AppKit windows keep their native title-bar material;
        // only a full-size content view can supply a backdrop underneath it.
        window?.titlebarAppearsTransparent = window?.styleMask.contains(.fullSizeContentView) == true
        refreshMaterial()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshMaterial()
    }
    func refreshMaterial() {
        material.isHidden = coverOpacity >= 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cover.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(coverOpacity).cgColor
        }
    }
}

private struct MinaWindowAppearance: ViewModifier {
    @ObservedObject var model: BrowserModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .modifier(ClearWindowBackground())
            .background {
                WindowBackdrop(transparency: model.preferences.glassTransparency, reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased)
                    .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
            }
            .preferredColorScheme(model.preferences.appearanceMode.colorScheme)
    }
}

/// Let the AppKit backdrop draw through SwiftUI's window container.
private struct ClearWindowBackground: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.containerBackground(.clear, for: .window) }
        else { content }
    }
}

private struct GlassControlSurface: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

private struct GlassPrimaryButton: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency { content.buttonStyle(.glassProminent) }
        else { content.buttonStyle(.borderedProminent) }
    }
}

extension View {
    func minaWindowAppearance(model: BrowserModel) -> some View { modifier(MinaWindowAppearance(model: model)) }
    func minaControlSurface(cornerRadius: CGFloat = 12) -> some View { modifier(GlassControlSurface(cornerRadius: cornerRadius)) }
    func minaPrimaryButton() -> some View { modifier(GlassPrimaryButton()) }
}

enum PaneFocusTarget { case path, filter }
struct PaneFocusRequest {
    let tabID: UUID
    let side: PanelSide
    let target: PaneFocusTarget
}
extension Notification.Name {
    static let minaPaneFocus = Notification.Name("MinaSCP.PaneFocus")
}

struct AppearancePreferencesView: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Section {
            Picker("外觀", selection: Binding(get: { model.preferences.appearanceMode }, set: { model.updateAppearance(mode: $0) })) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("外觀模式")
            preview.padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("背景透明度")
                    Spacer()
                    Text("\(Int(model.preferences.glassTransparency))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { model.preferences.glassTransparency }, set: { model.updateAppearance(transparency: $0) }), in: 0...100, step: 1)
                    .labelsHidden()
                    .accessibilityLabel("背景透明度").accessibilityValue("\(Int(model.preferences.glassTransparency))%")
                    .disabled(reduceTransparency)
                HStack { Text("不透明"); Spacer(); Text("較通透") }.font(.caption).foregroundStyle(.secondary)
                if reduceTransparency {
                    Label("macOS 已開啟「減少透明度」，目前使用實色背景；原本的透明度設定仍會保留。", systemImage: "accessibility")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("調整背景透出程度，文字與圖示保持清晰。原生右鍵選單的材質由 macOS 決定。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if contrast == .increased { Text("已配合系統增加對比，降低背景干擾。").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 8)
            Button("恢復外觀預設值") { model.resetAppearance() }
        } header: { Text("外觀與玻璃效果") }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary)
                Text("即時預覽").font(.caption.weight(.medium))
                Spacer()
                Image(systemName: "arrow.up.arrow.down").foregroundStyle(.blue)
            }
            HStack(spacing: 20) {
                previewPane("本機", icon: "laptopcomputer", selected: false)
                Divider()
                previewPane("遠端", icon: "server.rack", selected: true)
            }.frame(height: 100)
        }.padding(18)
            .background {
                ZStack {
                    // Sample colors make the slider's effect visible even when
                    // the real window is backed by a plain desktop or document.
                    LinearGradient(colors: [.blue.opacity(0.3), .mint.opacity(0.2), .purple.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Color(nsColor: .windowBackgroundColor).opacity(GlassAppearance.backgroundOpacity(
                        transparency: model.preferences.glassTransparency,
                        reduceTransparency: reduceTransparency,
                        increaseContrast: contrast == .increased
                    ))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.1)))
    }
    private func previewPane(_ title: String, icon: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            Label("Documents", systemImage: "folder.fill").foregroundStyle(.secondary)
            Label("README.md", systemImage: "doc.text")
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                .background(selected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }
}
