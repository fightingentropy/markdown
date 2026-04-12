import AppKit
import SwiftUI

struct ImagePreview: View {
    private static let imageCache = NSCache<NSURL, NSImage>()

    let url: URL
    @State private var zoomScale: CGFloat = 1
    @State private var isShowingControls = false
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var image: NSImage?
    @State private var isLoadingImage = false

    var body: some View {
        Group {
            if let image {
                imageView(image)
            } else if isLoadingImage {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.18))
            } else {
                ContentUnavailableView(
                    "Image Unavailable",
                    systemImage: "photo",
                    description: Text("This image couldn't be loaded.")
                )
            }
        }
        .task(id: url) {
            await loadImage()
        }
        .onDisappear {
            controlsHideTask?.cancel()
        }
    }

    private var minimumZoomScale: CGFloat { 0.25 }
    private var maximumZoomScale: CGFloat { 4 }

    private func clampedZoom(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumZoomScale), maximumZoomScale)
    }

    private func revealControls() {
        controlsHideTask?.cancel()
        isShowingControls = true
        scheduleControlsHide(after: .seconds(2))
    }

    private func scheduleControlsHide(after duration: Duration) {
        controlsHideTask?.cancel()
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            isShowingControls = false
        }
    }

    private func imageView(_ image: NSImage) -> some View {
        ZoomableImageScrollView(image: image, zoomScale: $zoomScale)
            .padding(24)
            .overlay(alignment: .topTrailing) {
                zoomControls
                    .padding(16)
                    .opacity(isShowingControls ? 1 : 0)
                    .offset(y: isShowingControls ? 0 : -6)
                    .animation(.easeInOut(duration: 0.18), value: isShowingControls)
                    .allowsHitTesting(isShowingControls)
            }
            .onHover { isHovering in
                if isHovering {
                    revealControls()
                } else {
                    scheduleControlsHide(after: .milliseconds(900))
                }
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    revealControls()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.18))
    }

    @MainActor
    private func loadImage() async {
        let cacheKey = url as NSURL
        if let cachedImage = Self.imageCache.object(forKey: cacheKey) {
            image = cachedImage
            isLoadingImage = false
            return
        }

        image = nil
        isLoadingImage = true
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard !Task.isCancelled else { return }

        let loadedImage = data.flatMap(NSImage.init(data:))
        if let loadedImage {
            Self.imageCache.setObject(loadedImage, forKey: cacheKey)
        }

        image = loadedImage
        isLoadingImage = false
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button {
                revealControls()
                zoomScale = clampedZoom(zoomScale - 0.2)
            } label: {
                Image(systemName: "minus")
            }
            .help("Zoom Out")
            .disabled(zoomScale <= minimumZoomScale)

            Text("\(Int(zoomScale * 100))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)

            Button {
                revealControls()
                zoomScale = clampedZoom(zoomScale + 0.2)
            } label: {
                Image(systemName: "plus")
            }
            .help("Zoom In")
            .disabled(zoomScale >= maximumZoomScale)

            Button("Reset") {
                revealControls()
                zoomScale = 1
            }
            .font(.caption)
            .help("Reset Zoom")
            .disabled(abs(zoomScale - 1) < 0.01)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }
}

// MARK: - Zoomable Image Scroll View

struct ZoomableImageScrollView: NSViewRepresentable {
    let image: NSImage
    @Binding var zoomScale: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 4
        scrollView.magnification = 1

        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)

        let documentView = FlippedDocumentView(frame: CGRect(origin: .zero, size: image.size))
        documentView.addSubview(imageView)
        scrollView.documentView = documentView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleLiveMagnify(_:)),
            name: NSScrollView.willStartLiveMagnifyNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleEndMagnify(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let documentView = scrollView.documentView,
              let imageView = documentView.subviews.first as? NSImageView else {
            return
        }

        if imageView.image != image {
            imageView.image = image
        }

        if imageView.frame.size != image.size {
            imageView.frame = CGRect(origin: .zero, size: image.size)
        }

        if documentView.frame.size != image.size {
            documentView.frame = CGRect(origin: .zero, size: image.size)
        }

        let imageSize = image.size
        if context.coordinator.lastImageSize != imageSize {
            context.coordinator.lastImageSize = imageSize
            context.coordinator.didApplyInitialZoom = false
        }

        if !context.coordinator.didApplyInitialZoom {
            let visibleSize = scrollView.contentView.bounds.size
            if visibleSize.width > 0, visibleSize.height > 0 {
                let fittedScale = fittedZoomScale(for: imageSize, in: visibleSize)
                context.coordinator.didApplyInitialZoom = true
                if abs(zoomScale - fittedScale) > 0.001 {
                    zoomScale = fittedScale
                }
                scrollView.setMagnification(
                    fittedScale,
                    centeredAt: CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY)
                )
                return
            }
        }

        if abs(scrollView.magnification - zoomScale) > 0.001 {
            scrollView.setMagnification(zoomScale, centeredAt: CGPoint(x: documentView.bounds.midX, y: documentView.bounds.midY))
        }
    }

    private func fittedZoomScale(for imageSize: CGSize, in visibleSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let widthScale = visibleSize.width / imageSize.width
        let heightScale = visibleSize.height / imageSize.height
        return min(max(min(widthScale, heightScale), 0.25), 1)
    }

    @MainActor
    final class Coordinator: NSObject {
        @Binding private var zoomScale: CGFloat
        var didApplyInitialZoom = false
        var lastImageSize = CGSize.zero

        init(zoomScale: Binding<CGFloat>) {
            _zoomScale = zoomScale
        }

        @objc
        func handleEndMagnify(_ notification: Notification) {
            updateZoomScale(from: notification.object)
        }

        @objc
        func handleLiveMagnify(_ notification: Notification) {
            updateZoomScale(from: notification.object)
        }

        private func updateZoomScale(from object: Any?) {
            guard let scrollView = object as? NSScrollView else { return }
            let currentScale = scrollView.magnification
            if abs(zoomScale - currentScale) > 0.001 {
                zoomScale = currentScale
            }
        }
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)

        guard let documentSize = documentView?.frame.size else {
            return constrained
        }

        if documentSize.width < proposedBounds.width {
            constrained.origin.x = -(proposedBounds.width - documentSize.width) / 2
        }

        if documentSize.height < proposedBounds.height {
            constrained.origin.y = -(proposedBounds.height - documentSize.height) / 2
        }

        return constrained
    }
}
