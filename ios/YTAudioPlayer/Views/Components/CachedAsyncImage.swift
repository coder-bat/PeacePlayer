//
//  CachedAsyncImage.swift
//  YTAudioPlayer
//
//  Cached image view using ImageCache with content/placeholder closures
//

import SwiftUI
import Combine

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let contentBuilder: (Image) -> Content
    let placeholderBuilder: () -> Placeholder

    @State private var image: UIImage?
    @State private var isLoaded = false
    @State private var cancellable: AnyCancellable?

    init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.contentBuilder = content
        self.placeholderBuilder = placeholder
    }

    var body: some View {
        ZStack {
            if let image = image {
                contentBuilder(Image(uiImage: image))
                    .opacity(isLoaded ? 1 : 0)
                    .onAppear {
                        withAnimation(.easeIn(duration: 0.2)) {
                            isLoaded = true
                        }
                    }
            } else {
                placeholderBuilder()
            }
        }
        .onAppear {
            loadImage()
        }
        .onChange(of: url) { _, _ in
            cancellable?.cancel()
            image = nil
            isLoaded = false
            loadImage()
        }
        .onDisappear {
            cancellable?.cancel()
        }
    }

    private func loadImage() {
        // No URL means there is nothing to load. Returning without
        // touching `image` matters: this runs from `onAppear`, and
        // writing @State from there during a graph update leaves a
        // state box that SwiftUI can release twice when the view is
        // torn down (observed as a SIGBUS inside the image loader).
        guard let url = url else { return }

        cancellable = ImageCache.shared.image(for: url)
            .receive(on: DispatchQueue.main)
            .sink { loadedImage in
                if let loadedImage = loadedImage {
                    self.image = loadedImage
                }
            }
    }
}

// MARK: - Backward-Compatible Convenience Init

/// Default content that matches the original CachedAsyncImage behavior
struct CachedImageDefaultContent: View {
    let image: Image
    var body: some View {
        image.resizable().aspectRatio(contentMode: .fill)
    }
}

extension CachedAsyncImage where Content == CachedImageDefaultContent {
    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.init(url: url, content: { CachedImageDefaultContent(image: $0) }, placeholder: placeholder)
    }
}
