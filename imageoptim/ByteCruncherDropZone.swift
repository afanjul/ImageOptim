//
//  ByteCruncherDropZone.swift
//  ImageOptim
//
//  Animated "Byte-Cruncher" mascot and drop zone with Liquid Glass styling.
//  The mascot opens its mouth and eats files when dragged over.
//

import SwiftUI
import AppKit

public struct ByteCruncherDropZone: View {
    public let isTargeted: Bool
    public let onBrowse: () -> Void

    @State private var isBlinking = false
    @State private var floatOffset: CGFloat = 0
    @State private var dashPhase: CGFloat = 0

    public init(isTargeted: Bool, onBrowse: @escaping () -> Void) {
        self.isTargeted = isTargeted
        self.onBrowse = onBrowse
    }

    public var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)

            // Mascot & suction animation
            ByteCruncherMascot(isTargeted: isTargeted, isBlinking: isBlinking)
                .frame(width: 220, height: 180)
                .allowsHitTesting(false) // Drops fall straight through to the dropDestination behind

            // Text prompts
            VStack(spacing: 6) {
                Text(isTargeted ? String(localized: "¡Suelta para devorar los bytes!", comment: "Drop zone active")
                                : String(localized: "Arrastra imágenes o carpetas aquí", comment: "Drop zone idle"))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.primary)
                    .animation(.easeInOut(duration: 0.2), value: isTargeted)

                Text(String(localized: "Compresión inteligente sin pérdida para optimizar peso y velocidad", comment: "Drop zone subtitle"))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .allowsHitTesting(false)

            // Supported format badges
            HStack(spacing: 6) {
                FormatBadge(format: "PNG")
                FormatBadge(format: "JPEG")
                FormatBadge(format: "WebP")
                FormatBadge(format: "AVIF")
                FormatBadge(format: "JXL")
                FormatBadge(format: "SVG")
                FormatBadge(format: "GIF")
            }
            .padding(.vertical, 2)
            .allowsHitTesting(false)

            // Primary action button
            Button {
                onBrowse()
            } label: {
                HStack(spacing: 6) {
                    LucideIcon(.plus, size: 14, color: .white)
                    Text(String(localized: "Examinar archivos…", comment: "Drop zone browse button"))
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 4)

            Spacer(minLength: 12)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.08))
                                 : AnyShapeStyle(.regularMaterial))
                .shadow(color: Color.black.opacity(0.05), radius: 10, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5,
                                       dash: [10, 7],
                                       dashPhase: dashPhase)
                )
        }
        .padding(16)
        .onAppear {
            startIdleAnimations()
        }
        .onChange(of: isTargeted) { _, targeted in
            if targeted {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    dashPhase = 34
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    dashPhase = 0
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func startIdleAnimations() {
        // Subtle floating movement
        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
            floatOffset = -6
        }

        // Periodic blink timer
        Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isBlinking = true
                }
                try? await Task.sleep(nanoseconds: 140_000_000)
                withAnimation(.easeInOut(duration: 0.12)) {
                    isBlinking = false
                }
            }
        }
    }
}

// MARK: - Byte-Cruncher Mascot View

private struct ByteCruncherMascot: View {
    let isTargeted: Bool
    let isBlinking: Bool

    @State private var foodOffset: CGFloat = 0
    @State private var foodRotation: Double = -12
    @State private var jawWobble: CGFloat = 0

    var body: some View {
        ZStack {
            // Suction speed waves when dragging over
            if isTargeted {
                SuctionWaves()
                    .offset(x: 15, y: -5)
            }

            // Floating file that gets eaten!
            FileToEatCard(isTargeted: isTargeted)
                .offset(x: isTargeted ? 22 : 55, y: isTargeted ? -8 : -18)
                .rotationEffect(.degrees(isTargeted ? -18 : foodRotation))
                .scaleEffect(isTargeted ? 0.78 : 0.95)
                .opacity(isTargeted ? 0.95 : 0.85)
                .animation(.spring(response: 0.45, dampingFraction: 0.65), value: isTargeted)

            // The Cruncher Body / Creature
            VStack(spacing: 0) {
                // Antenna with glowing orb
                HStack(spacing: 30) {
                    AntennaView(tilt: isTargeted ? -14 : -6, isTargeted: isTargeted)
                    AntennaView(tilt: isTargeted ? 14 : 6, isTargeted: isTargeted)
                }
                .offset(y: 4)

                // Upper Head / Jaw
                ZStack {
                    // Head shape
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(nsColor: .systemTeal).opacity(0.9),
                                    Color(nsColor: .systemBlue)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 140, height: 68)
                        .shadow(color: Color.blue.opacity(0.3), radius: 8, y: 4)

                    // Head specular highlight
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(LinearGradient(colors: [.white.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                        .frame(width: 138, height: 66)

                    // Expressive Eyes
                    HStack(spacing: 24) {
                        EyeView(isTargeted: isTargeted, isBlinking: isBlinking)
                        EyeView(isTargeted: isTargeted, isBlinking: isBlinking)
                    }
                    .offset(y: -4)

                    // Sharp white crusher teeth on upper jaw
                    HStack(spacing: 8) {
                        ForEach(0..<4) { _ in
                            UpperToothShape()
                                .fill(Color.white)
                                .frame(width: 12, height: 8)
                        }
                    }
                    .frame(width: 90, alignment: .center)
                    .offset(y: 30)
                }
                .offset(y: isTargeted ? -16 : 0)
                .rotationEffect(.degrees(isTargeted ? -8 : 0), anchor: .leading)
                .animation(.spring(response: 0.38, dampingFraction: 0.6), value: isTargeted)

                // Inside the mouth: dark compression chamber with neon glow
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .darkGray).opacity(0.85))
                        .frame(width: 110, height: isTargeted ? 32 : 12)
                        .overlay {
                            if isTargeted {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.cyan.opacity(0.6), lineWidth: 1.5)
                                    .blur(radius: 2)
                            }
                        }

                    if isTargeted {
                        Text("CRUNCH!")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundStyle(Color.cyan)
                            .tracking(1.5)
                    }
                }
                .offset(y: isTargeted ? -8 : 0)
                .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isTargeted)

                // Lower Jaw / Chin
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(nsColor: .systemBlue),
                                    Color(nsColor: .systemIndigo)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 140, height: 50)
                        .shadow(color: Color.indigo.opacity(0.25), radius: 6, y: 3)

                    // Lower teeth
                    HStack(spacing: 8) {
                        ForEach(0..<4) { _ in
                            LowerToothShape()
                                .fill(Color.white)
                                .frame(width: 12, height: 8)
                        }
                    }
                    .frame(width: 90, alignment: .center)
                    .offset(y: -21)

                    // Smile badge indicator
                    HStack(spacing: 4) {
                        LucideIcon(.zap, size: 10, color: .yellow)
                        Text("BYTE-EATER")
                            .font(.system(size: 7.5, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.25)))
                    .offset(y: 4)
                }
                .offset(y: isTargeted ? 12 : 0)
                .rotationEffect(.degrees(isTargeted ? 6 : 0), anchor: .leading)
                .animation(.spring(response: 0.38, dampingFraction: 0.6), value: isTargeted)
            }
            .offset(x: -25)
        }
    }
}

// MARK: - Antenna

private struct AntennaView: View {
    let tilt: Double
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(isTargeted ? Color.cyan : Color.yellow)
                .frame(width: 10, height: 10)
                .shadow(color: isTargeted ? Color.cyan : Color.yellow.opacity(0.6), radius: isTargeted ? 6 : 2)
            Rectangle()
                .fill(Color(nsColor: .secondaryLabelColor))
                .frame(width: 3, height: 16)
        }
        .rotationEffect(.degrees(tilt), anchor: .bottom)
        .animation(.spring(response: 0.4, dampingFraction: 0.5), value: tilt)
    }
}

// MARK: - Eyes

private struct EyeView: View {
    let isTargeted: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            // Sclera (White of the eye)
            Capsule()
                .fill(Color.white)
                .frame(width: 22, height: isBlinking ? 2 : (isTargeted ? 26 : 22))
                .shadow(color: Color.black.opacity(0.15), radius: 2, y: 1)

            if !isBlinking {
                // Iris / Pupil
                Circle()
                    .fill(isTargeted ? Color.cyan : Color(nsColor: .textColor))
                    .frame(width: isTargeted ? 14 : 11, height: isTargeted ? 14 : 11)
                    .offset(x: isTargeted ? 3 : 1, y: 0)
                    .overlay {
                        // Specular catchlight
                        Circle()
                            .fill(Color.white)
                            .frame(width: 4, height: 4)
                            .offset(x: -2, y: -2)
                    }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isTargeted)
    }
}

// MARK: - Teeth Shapes

private struct UpperToothShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct LowerToothShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - File Card Being Eaten

private struct FileToEatCard: View {
    let isTargeted: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: 64, height: 76)
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 2, y: 4)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                }

            VStack(spacing: 4) {
                // Dog-ear corner fold
                HStack {
                    Spacer()
                    Path { p in
                        p.move(to: CGPoint(x: 12, y: 0))
                        p.addLine(to: CGPoint(x: 0, y: 12))
                        p.addLine(to: CGPoint(x: 12, y: 12))
                        p.closeSubpath()
                    }
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 12, height: 12)
                }
                .padding(.trailing, 2)
                .padding(.top, 2)

                // Mini picture thumbnail
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 28)
                    .overlay {
                        LucideIcon(.image, size: 16, color: .white)
                    }

                // File format tag
                Text("PHOTO.PNG")
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Simulated byte size
                Text("2.4 MB")
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(isTargeted ? Color.green : Color.secondary)
            }
        }
    }
}

// MARK: - Suction Waves

private struct SuctionWaves: View {
    @State private var wavePhase: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Capsule()
                    .fill(Color.accentColor.opacity(0.35 - Double(i) * 0.1))
                    .frame(width: 3, height: CGFloat(28 - i * 6))
            }
        }
    }
}
