//
//  ViewExtensions.swift
//  YTAudioPlayer
//
//  View modifiers and extensions for design system
//

import SwiftUI

// MARK: - Shadow Modifier
struct ShadowModifier: ViewModifier {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
    
    func body(content: Content) -> some View {
        content
            .shadow(color: color, radius: radius, x: x, y: y)
    }
}

extension View {
    func appShadow(color: Color = Theme.shadow, radius: CGFloat = 4, x: CGFloat = 0, y: CGFloat = 2) -> some View {
        modifier(ShadowModifier(color: color, radius: radius, x: x, y: y))
    }
}

// MARK: - Card Modifier
struct CardModifier: ViewModifier {
    let backgroundColor: Color
    let cornerRadius: CGFloat
    let shadowColor: Color
    let shadowRadius: CGFloat
    let hasShadow: Bool
    
    func body(content: Content) -> some View {
        content
            .background(backgroundColor)
            .cornerRadius(cornerRadius)
            .shadow(color: hasShadow ? shadowColor : .clear, radius: shadowRadius, x: 0, y: 2)
    }
}

extension View {
    func card(
        background: Color = Theme.background,
        cornerRadius: CGFloat = CornerRadius.md,
        shadow: Bool = true
    ) -> some View {
        modifier(CardModifier(
            backgroundColor: background,
            cornerRadius: cornerRadius,
            shadowColor: Theme.shadow,
            shadowRadius: 4,
            hasShadow: shadow
        ))
    }
}

// MARK: - ApplyIf Helper
extension View {
    @ViewBuilder
    func applyIf<Content: View, T>(
        _ value: T?,
        @ViewBuilder transform: (Self, T) -> Content
    ) -> some View {
        if let value = value {
            transform(self, value)
        } else {
            self
        }
    }
}

// MARK: - Pressable Button Style
struct PressableButtonStyle: ButtonStyle {
    let scale: CGFloat
    let opacity: CGFloat
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .opacity(configuration.isPressed ? opacity : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle {
        PressableButtonStyle(scale: 0.95, opacity: 0.8)
    }
    
    static func pressable(scale: CGFloat = 0.95, opacity: CGFloat = 0.8) -> PressableButtonStyle {
        PressableButtonStyle(scale: scale, opacity: opacity)
    }
}

// MARK: - Circular Button Style
struct CircularButtonStyle: ButtonStyle {
    let backgroundColor: Color
    let foregroundColor: Color
    let size: CGFloat
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == CircularButtonStyle {
    static func circular(
        background: Color = Theme.primary,
        foreground: Color = .white,
        size: CGFloat = 44
    ) -> CircularButtonStyle {
        CircularButtonStyle(
            backgroundColor: background,
            foregroundColor: foreground,
            size: size
        )
    }
}

// MARK: - Marquee Text
struct MarqueeText: View {
    let text: String
    let font: Font
    let width: CGFloat
    
    @State private var animate = false
    
    var body: some View {
        GeometryReader { geometry in
            let textWidth = text.widthOfString(usingFont: font)
            
            if textWidth > width {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                }
                .disabled(true)
            } else {
                Text(text)
                    .font(font)
                    .lineLimit(1)
            }
        }
        .frame(width: width)
    }
}

// MARK: - String Width Helper
extension String {
    func widthOfString(usingFont font: Font) -> CGFloat {
        let uiFont: UIFont
        switch font {
        case .largeTitle:
            uiFont = .systemFont(ofSize: 34, weight: .bold)
        case .title:
            uiFont = .systemFont(ofSize: 28, weight: .bold)
        case .title2:
            uiFont = .systemFont(ofSize: 22, weight: .bold)
        case .title3:
            uiFont = .systemFont(ofSize: 20, weight: .semibold)
        case .headline:
            uiFont = .systemFont(ofSize: 17, weight: .semibold)
        case .subheadline:
            uiFont = .systemFont(ofSize: 15)
        case .body:
            uiFont = .systemFont(ofSize: 17)
        case .callout:
            uiFont = .systemFont(ofSize: 16)
        case .footnote:
            uiFont = .systemFont(ofSize: 13)
        case .caption:
            uiFont = .systemFont(ofSize: 12)
        case .caption2:
            uiFont = .systemFont(ofSize: 11)
        default:
            uiFont = .systemFont(ofSize: 17)
        }
        
        let attributes: [NSAttributedString.Key: Any] = [.font: uiFont]
        return self.size(withAttributes: attributes).width
    }
}

// MARK: - Blur Background
struct BlurBackground: ViewModifier {
    let style: UIBlurEffect.Style
    
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
    }
}

extension View {
    func blurBackground(style: UIBlurEffect.Style = .systemMaterial) -> some View {
        modifier(BlurBackground(style: style))
    }
}
