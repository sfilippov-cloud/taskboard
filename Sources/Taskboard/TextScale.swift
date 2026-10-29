// Text size for the whole app: ⌘+ / ⌘− / ⌘0 (View menu) and the widget's right-click menu change it, and it is remembered.
// macOS has no Dynamic Type, so every view takes its size from here: `.scaled(.caption)` instead of `.font(.caption)`,
// `.scaledFrame(width:)` for fixed-size sheets, and `.textScaled()` once at the root of each window.
import Observation
import SwiftUI

extension Notification.Name {
  static let textScaleChanged = Notification.Name("textScaleChanged")
}

@MainActor
@Observable
final class TextScale {
  static let shared = TextScale()
  static let steps: [CGFloat] = [0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.6, 1.8, 2]
  private static let key = "textScale"

  private(set) var value: CGFloat = 1

  private init() {
    let saved = UserDefaults.standard.double(forKey: Self.key)
    if saved > 0 { value = min(max(CGFloat(saved), Self.steps.first!), Self.steps.last!) }
  }

  var canGrow: Bool { value < Self.steps.last! - 0.001 }
  var canShrink: Bool { value > Self.steps.first! + 0.001 }
  var isDefault: Bool { abs(value - 1) < 0.001 }

  func larger() { set(Self.steps.first { $0 > value + 0.001 } ?? value) }
  func smaller() { set(Self.steps.last { $0 < value - 0.001 } ?? value) }
  func reset() { set(1) }

  // `remember: false` is for the snapshot tool: it must not change what the user chose.
  func set(_ new: CGFloat, remember: Bool = true) {
    guard abs(new - value) > 0.001 else { return }
    value = new
    if remember { UserDefaults.standard.set(Double(new), forKey: Self.key) }
    NotificationCenter.default.post(name: .textScaleChanged, object: nil)
  }
}

extension EnvironmentValues {
  @Entry var textScale: CGFloat = 1
}

extension Font.TextStyle {
  // The point sizes macOS gives each text style at the default scale.
  var baseSize: CGFloat {
    switch self {
    case .largeTitle: 26
    case .title: 22
    case .title2: 17
    case .title3: 15
    case .headline, .body: 13
    case .callout: 12
    case .subheadline: 11
    default: 10  // footnote, caption, caption2
    }
  }
}

private struct ScaledFont: ViewModifier {
  @Environment(\.textScale) private var scale
  let style: Font.TextStyle
  let design: Font.Design?

  func body(content: Content) -> some View {
    content.font(.system(size: style.baseSize * scale, weight: style == .headline ? .semibold : nil, design: design))
  }
}

private struct ScaledFrame: ViewModifier {
  @Environment(\.textScale) private var scale
  let width: CGFloat?
  let height: CGFloat?

  func body(content: Content) -> some View {
    content.frame(width: width.map { $0 * scale }, height: height.map { $0 * scale })
  }
}

private struct TextScaled: ViewModifier {
  func body(content: Content) -> some View {
    let scale = TextScale.shared.value
    content.environment(\.textScale, scale).font(.system(size: 13 * scale)).controlSize(Self.controlSize(for: scale))
  }

  // Menus and segmented controls ignore the font; they grow in steps with the control size instead.
  private static func controlSize(for scale: CGFloat) -> ControlSize {
    switch scale {
    case ..<0.95: .small
    case ..<1.2: .regular
    case ..<1.6: .large
    default: .extraLarge
    }
  }
}

extension View {
  func scaled(_ style: Font.TextStyle, design: Font.Design? = nil) -> some View {
    modifier(ScaledFont(style: style, design: design))
  }

  func scaledFrame(width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
    modifier(ScaledFrame(width: width, height: height))
  }

  // At the root of a window: the default text size, and the scale for everything below it.
  func textScaled() -> some View { modifier(TextScaled()) }
}

// The same three commands for a right-click menu: the widget never takes focus, so ⌘+ can't reach it.
struct TextSizeMenu: View {
  var body: some View {
    let text = TextScale.shared
    Button("Bigger text") { text.larger() }.disabled(!text.canGrow)
    Button("Smaller text") { text.smaller() }.disabled(!text.canShrink)
    Button("Default text size") { text.reset() }.disabled(text.isDefault)
  }
}
