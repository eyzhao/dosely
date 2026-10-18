import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

/// "Linen & sage" — warm paper neutrals, a calm sage accent, honey for due, clay for missed, lavender for PRN.
enum Theme {
    static let canvas       = Color.dynamic(0xF5F2EC, 0x111615)
    static let surface      = Color.dynamic(0xFFFEFB, 0x1A2120)
    static let surfaceSunk  = Color.dynamic(0xECE8E0, 0x1E2625)
    static let ink          = Color.dynamic(0x27312F, 0xE6EBE8)
    static let inkSecondary = Color.dynamic(0x6B7471, 0x97A39F)
    static let inkTertiary  = Color.dynamic(0xA6ACA8, 0x5E6A66)
    static let hairline     = Color.dynamic(0xE4DFD6, 0x263030)
    static let outline      = Color.dynamic(0xCFCAC0, 0x3A4644)

    static let sage         = Color.dynamic(0x5B8A74, 0x7FB29A)
    static let sageSoft     = Color.dynamic(0xDDE9E2, 0x203229)
    static let honey        = Color.dynamic(0xD39B3E, 0xE2B562)
    static let honeySoft    = Color.dynamic(0xF7EAD2, 0x362D1E)
    static let clay         = Color.dynamic(0xC7775B, 0xDA9478)
    static let claySoft     = Color.dynamic(0xF4E1D8, 0x372621)
    static let lavender     = Color.dynamic(0x8679AE, 0xAFA3D6)
    static let lavenderSoft = Color.dynamic(0xE9E5F3, 0x2A2638)
}

/// Grid metrics shared by header, names and cells so everything lines up.
enum MAR {
    static let nameWidth: CGFloat = 124
    static let rowHeight: CGFloat = 60
    static let columnWidth: CGFloat = 56
    static let dayPadding: CGFloat = 8
    static let minDayWidth: CGFloat = 84
    static let headerHeight: CGFloat = 52
    static let cell: CGFloat = 30
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6) }
}

/// Small wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > bounds.width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = Theme.inkSecondary
    var fill: Color = Theme.surfaceSunk

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(fill, in: Capsule())
    }
}
