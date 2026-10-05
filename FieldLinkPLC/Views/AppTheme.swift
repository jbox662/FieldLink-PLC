import SwiftUI
import UIKit

extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    /// Brand fill for the Overview header. Stays dark so white headline text remains readable.
    static let fieldNavy = Color(
        light: Color(red: 0.04, green: 0.12, blue: 0.20),
        dark: Color(red: 0.06, green: 0.18, blue: 0.28)
    )

    /// Primary ink for titles and labels. Navy in light mode, light in dark mode.
    static let fieldInk = Color(
        light: Color(red: 0.04, green: 0.12, blue: 0.20),
        dark: Color(red: 0.90, green: 0.94, blue: 0.97)
    )

    static let fieldTeal = Color(
        light: Color(red: 0.00, green: 0.50, blue: 0.55),
        dark: Color(red: 0.40, green: 0.84, blue: 0.88)
    )

    static let fieldOrange = Color(
        light: Color(red: 0.86, green: 0.38, blue: 0.08),
        dark: Color(red: 1.00, green: 0.66, blue: 0.32)
    )

    static let fieldSurface = Color(
        light: Color(red: 0.95, green: 0.97, blue: 0.98),
        dark: Color(red: 0.05, green: 0.08, blue: 0.11)
    )
}

extension ShapeStyle where Self == Color {
    static var fieldNavy: Color { Color.fieldNavy }
    static var fieldInk: Color { Color.fieldInk }
    static var fieldTeal: Color { Color.fieldTeal }
    static var fieldOrange: Color { Color.fieldOrange }
    static var fieldSurface: Color { Color.fieldSurface }
}

struct StatusPill: View {
    let status: GatewayStatus

    private var tint: Color {
        switch status {
        case .ready: Color(light: Color(red: 0.12, green: 0.56, blue: 0.28), dark: Color(red: 0.45, green: 0.86, blue: 0.58))
        case .connecting: .fieldOrange
        case .offline, .fault: Color(light: Color(red: 0.80, green: 0.16, blue: 0.16), dark: Color(red: 1.00, green: 0.48, blue: 0.48))
        }
    }

    var body: some View {
        Label {
            Text(status.title)
        } icon: {
            Image(systemName: status == .ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        }
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.16), in: Capsule())
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let symbol: String
    private let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
            }
                .font(.headline)
                .foregroundStyle(.fieldInk)
            content
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.fieldInk.opacity(0.14), lineWidth: 1)
        }
    }
}

extension Date {
    var fieldLinkFormatted: String {
        formatted(date: .abbreviated, time: .shortened)
    }
}
