//
//  ShimmerModifier.swift
//  YTAudioPlayer
//
//  Shimmer loading effect for skeleton views
//

import SwiftUI

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0
    
    var animation: Animation {
        .linear(duration: 1.5)
        .repeatForever(autoreverses: false)
    }
    
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.5),
                            Color.white.opacity(0)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 2)
                    .offset(x: -geometry.size.width + (geometry.size.width * 2 * phase))
                }
                .mask(content)
            )
            .onAppear {
                withAnimation(animation) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - Skeleton Shapes
struct SkeletonRectangle: View {
    let height: CGFloat
    let cornerRadius: CGFloat
    
    init(height: CGFloat = 16, cornerRadius: CGFloat = 4) {
        self.height = height
        self.cornerRadius = cornerRadius
    }
    
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.gray.opacity(0.2))
            .frame(height: height)
            .shimmer()
    }
}

struct SkeletonCircle: View {
    let size: CGFloat
    
    init(size: CGFloat = 40) {
        self.size = size
    }
    
    var body: some View {
        Circle()
            .fill(Color.gray.opacity(0.2))
            .frame(width: size, height: size)
            .shimmer()
    }
}

struct SkeletonTrackRow: View {
    var body: some View {
        HStack(spacing: 12) {
            // Artwork skeleton
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 60, height: 60)
                .shimmer()
            
            // Text skeletons
            VStack(alignment: .leading, spacing: 8) {
                SkeletonRectangle(height: 16, cornerRadius: 4)
                    .frame(width: 180)
                
                SkeletonRectangle(height: 14, cornerRadius: 4)
                    .frame(width: 120)
            }
            
            Spacer()
            
            // Action buttons skeleton
            HStack(spacing: 16) {
                SkeletonCircle(size: 32)
                SkeletonCircle(size: 32)
            }
        }
        .padding(.vertical, 4)
    }
}
