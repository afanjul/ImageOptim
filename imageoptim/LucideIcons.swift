//
//  LucideIcons.swift
//  ImageOptim
//
//  Vector Lucide icons drawn natively with crisp resolution at any scale.
//  Zero external dependencies, pixel-perfect on Retina & Liquid Glass.
//

import SwiftUI

public enum LucideIconName: String, CaseIterable, Sendable {
    case zap
    case sparkles
    case gauge
    case sliders
    case image
    case folder
    case refreshCw
    case trash2
    case checkCircle
    case alertCircle
    case arrowDown
    case plus
    case clock
    case cpu
    case shieldCheck
    case externalLink
    case layers
    case check
}

public struct LucideIcon: View {
    let name: LucideIconName
    let size: CGFloat
    let color: Color?

    public init(_ name: LucideIconName, size: CGFloat = 16, color: Color? = nil) {
        self.name = name
        self.size = size
        self.color = color
    }

    public var body: some View {
        LucideIconShape(name: name)
            .stroke(color ?? .primary, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }

    private var strokeWidth: CGFloat {
        max(1.2, size * (1.8 / 24.0))
    }
}

public struct LucideIconShape: Shape {
    let name: LucideIconName

    public func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24.0
        let ox = rect.minX + (rect.width - 24.0 * scale) / 2.0
        let oy = rect.minY + (rect.height - 24.0 * scale) / 2.0

        var p = Path()

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * scale, y: oy + y * scale)
        }

        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ cr: CGFloat = 0) -> Path {
            Path(roundedRect: CGRect(x: ox + x * scale, y: oy + y * scale, width: w * scale, height: h * scale), cornerRadius: cr * scale)
        }

        switch name {
        case .zap:
            p.move(to: pt(13, 2))
            p.addLine(to: pt(3, 14))
            p.addLine(to: pt(12, 14))
            p.addLine(to: pt(11, 22))
            p.addLine(to: pt(21, 10))
            p.addLine(to: pt(12, 10))
            p.closeSubpath()

        case .sparkles:
            // Main 4-point star
            p.move(to: pt(12, 3))
            p.addLine(to: pt(13.8, 8.8))
            p.addLine(to: pt(19, 10))
            p.addLine(to: pt(14.8, 13.5))
            p.addLine(to: pt(16, 19))
            p.addLine(to: pt(12, 15.5))
            p.addLine(to: pt(8, 19))
            p.addLine(to: pt(9.2, 13.5))
            p.addLine(to: pt(5, 10))
            p.addLine(to: pt(10.2, 8.8))
            p.closeSubpath()
            // Tiny star top right
            p.move(to: pt(19, 3))
            p.addLine(to: pt(19.5, 5))
            p.addLine(to: pt(21, 5.5))
            p.addLine(to: pt(19.5, 6))
            p.addLine(to: pt(19, 8))
            p.addLine(to: pt(18.5, 6))
            p.addLine(to: pt(17, 5.5))
            p.addLine(to: pt(18.5, 5))
            p.closeSubpath()

        case .gauge:
            // Gauge arc
            p.addArc(center: pt(12, 12), radius: 8.5 * scale, startAngle: .degrees(140), endAngle: .degrees(40), clockwise: false)
            // Needle
            p.move(to: pt(12, 12))
            p.addLine(to: pt(16, 8))

        case .sliders:
            // Vertical track 1
            p.move(to: pt(4, 21)); p.addLine(to: pt(4, 14))
            p.move(to: pt(4, 10)); p.addLine(to: pt(4, 3))
            p.move(to: pt(1, 14)); p.addLine(to: pt(7, 14))
            // Vertical track 2
            p.move(to: pt(12, 21)); p.addLine(to: pt(12, 12))
            p.move(to: pt(12, 8)); p.addLine(to: pt(12, 3))
            p.move(to: pt(9, 8)); p.addLine(to: pt(15, 8))
            // Vertical track 3
            p.move(to: pt(20, 21)); p.addLine(to: pt(20, 16))
            p.move(to: pt(20, 12)); p.addLine(to: pt(20, 3))
            p.move(to: pt(17, 16)); p.addLine(to: pt(23, 16))

        case .image:
            p.addPath(r(3, 3, 18, 18, 2.5))
            // Sun
            p.addEllipse(in: CGRect(x: ox + 8 * scale, y: oy + 8 * scale, width: 2.5 * scale, height: 2.5 * scale))
            // Mountain
            p.move(to: pt(21, 15))
            p.addLine(to: pt(16, 10))
            p.addLine(to: pt(6, 20))

        case .folder:
            p.move(to: pt(20, 20))
            p.addLine(to: pt(4, 20))
            p.addLine(to: pt(4, 4))
            p.addLine(to: pt(9, 4))
            p.addLine(to: pt(11, 7))
            p.addLine(to: pt(20, 7))
            p.closeSubpath()

        case .refreshCw:
            // Top circular arrow
            p.addArc(center: pt(12, 12), radius: 8 * scale, startAngle: .degrees(180), endAngle: .degrees(350), clockwise: false)
            p.move(to: pt(21, 4))
            p.addLine(to: pt(21, 8.5))
            p.addLine(to: pt(16.5, 8.5))
            // Bottom circular arrow
            p.addArc(center: pt(12, 12), radius: 8 * scale, startAngle: .degrees(0), endAngle: .degrees(170), clockwise: false)
            p.move(to: pt(3, 20))
            p.addLine(to: pt(3, 15.5))
            p.addLine(to: pt(7.5, 15.5))

        case .trash2:
            // Lid line
            p.move(to: pt(3, 6)); p.addLine(to: pt(21, 6))
            // Handle
            p.move(to: pt(8, 6)); p.addLine(to: pt(8, 4)); p.addLine(to: pt(16, 4)); p.addLine(to: pt(16, 6))
            // Bin body
            p.move(to: pt(5, 6))
            p.addLine(to: pt(6, 19))
            p.addLine(to: pt(18, 19))
            p.addLine(to: pt(19, 6))
            // Vertical slats
            p.move(to: pt(10, 10)); p.addLine(to: pt(10, 16))
            p.move(to: pt(14, 10)); p.addLine(to: pt(14, 16))

        case .checkCircle:
            p.addEllipse(in: CGRect(x: ox + 2 * scale, y: oy + 2 * scale, width: 20 * scale, height: 20 * scale))
            p.move(to: pt(8, 12))
            p.addLine(to: pt(11, 15))
            p.addLine(to: pt(16, 9))

        case .alertCircle:
            p.addEllipse(in: CGRect(x: ox + 2 * scale, y: oy + 2 * scale, width: 20 * scale, height: 20 * scale))
            p.move(to: pt(12, 8)); p.addLine(to: pt(12, 13))
            p.move(to: pt(12, 16)); p.addLine(to: pt(12, 16.5))

        case .arrowDown:
            p.move(to: pt(12, 4))
            p.addLine(to: pt(12, 20))
            p.move(to: pt(6, 14))
            p.addLine(to: pt(12, 20))
            p.addLine(to: pt(18, 14))

        case .plus:
            p.move(to: pt(12, 5)); p.addLine(to: pt(12, 19))
            p.move(to: pt(5, 12)); p.addLine(to: pt(19, 12))

        case .clock:
            p.addEllipse(in: CGRect(x: ox + 2 * scale, y: oy + 2 * scale, width: 20 * scale, height: 20 * scale))
            p.move(to: pt(12, 6)); p.addLine(to: pt(12, 12)); p.addLine(to: pt(16, 14))

        case .cpu:
            p.addPath(r(5, 5, 14, 14, 2))
            p.addPath(r(9, 9, 6, 6, 1))
            // Pins
            p.move(to: pt(9, 2)); p.addLine(to: pt(9, 5))
            p.move(to: pt(15, 2)); p.addLine(to: pt(15, 5))
            p.move(to: pt(9, 19)); p.addLine(to: pt(9, 22))
            p.move(to: pt(15, 19)); p.addLine(to: pt(15, 22))
            p.move(to: pt(2, 9)); p.addLine(to: pt(5, 9))
            p.move(to: pt(2, 15)); p.addLine(to: pt(5, 15))
            p.move(to: pt(19, 9)); p.addLine(to: pt(22, 9))
            p.move(to: pt(19, 15)); p.addLine(to: pt(22, 15))

        case .shieldCheck:
            p.move(to: pt(12, 2))
            p.addLine(to: pt(19, 5))
            p.addLine(to: pt(19, 11))
            p.addQuadCurve(to: pt(12, 22), control: pt(19, 17))
            p.addQuadCurve(to: pt(5, 11), control: pt(5, 17))
            p.addLine(to: pt(5, 5))
            p.closeSubpath()
            // Checkmark inside shield
            p.move(to: pt(9, 11.5))
            p.addLine(to: pt(11, 13.5))
            p.addLine(to: pt(15, 9))

        case .externalLink:
            p.move(to: pt(18, 13)); p.addLine(to: pt(18, 19)); p.addLine(to: pt(5, 19)); p.addLine(to: pt(5, 6)); p.addLine(to: pt(11, 6))
            p.move(to: pt(15, 3)); p.addLine(to: pt(21, 3)); p.addLine(to: pt(21, 9))
            p.move(to: pt(10, 14)); p.addLine(to: pt(21, 3))

        case .layers:
            // Top layer diamond
            p.move(to: pt(12, 2)); p.addLine(to: pt(22, 7)); p.addLine(to: pt(12, 12)); p.addLine(to: pt(2, 7)); p.closeSubpath()
            // Middle layer shelf
            p.move(to: pt(2, 12)); p.addLine(to: pt(12, 17)); p.addLine(to: pt(22, 12))
            // Bottom layer shelf
            p.move(to: pt(2, 17)); p.addLine(to: pt(12, 22)); p.addLine(to: pt(22, 17))

        case .check:
            p.move(to: pt(5, 12))
            p.addLine(to: pt(10, 17))
            p.addLine(to: pt(20, 6))
        }

        return p
    }
}
