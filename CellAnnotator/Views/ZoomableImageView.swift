import SwiftUI
import UIKit

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let store: AnnotationStore

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 0.1
        scrollView.maximumZoomScale = 20
        scrollView.delegate = context.coordinator
        scrollView.bouncesZoom = true

        scrollView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]

        buildContent(in: scrollView, context: context)
        context.coordinator.currentImage = image
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Watch the close-polygon request counter.
            if store.closePolygonRequest != context.coordinator.lastHandledCloseRequest {
                context.coordinator.lastHandledCloseRequest = store.closePolygonRequest
                print("calling closePolygon, overlay is nil?", context.coordinator.overlay == nil)
                context.coordinator.overlay?.closePolygon()
            }
        // Rebuild only when the image actually changed (new object identity).
        if context.coordinator.currentImage !== image {
            context.coordinator.currentImage = image
            buildContent(in: scrollView, context: context)
        }
        context.coordinator.overlay?.setNeedsDisplay()
    }

    /// Builds (or rebuilds) the zoomed content: container + image + overlay.
    private func buildContent(in scrollView: UIScrollView, context: Context) {
        // Tear down any existing content first.
        print("buildContent called")
        context.coordinator.container?.removeFromSuperview()

        let container = UIView(frame: CGRect(origin: .zero, size: image.size))

        let imageView = UIImageView(image: image)
        imageView.frame = container.bounds
        container.addSubview(imageView)

        let overlay = AnnotationOverlayView(store: store, imagePixelSize: image.size)
        overlay.frame = container.bounds
        container.addSubview(overlay)

        scrollView.addSubview(container)
        scrollView.contentSize = container.bounds.size

        context.coordinator.container = container
        context.coordinator.overlay = overlay

        // Reset zoom to fit the new image, then center.
        DispatchQueue.main.async {
            guard image.size.width > 0, image.size.height > 0 else { return }
            let scaleW = scrollView.bounds.width / image.size.width
            let scaleH = scrollView.bounds.height / image.size.height
            let fitScale = min(scaleW, scaleH)
            scrollView.minimumZoomScale = min(fitScale, 0.1)
            scrollView.zoomScale = fitScale
            context.coordinator.centerContent(scrollView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var container: UIView?
        weak var overlay: AnnotationOverlayView?
        var currentImage: UIImage?
        var lastHandledCloseRequest = 0

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(scrollView)
            overlay?.setNeedsDisplay()
        }

        func centerContent(_ scrollView: UIScrollView) {
            guard let content = container else { return }
            let boundsSize = scrollView.bounds.size
            let frame = content.frame
            let horizontal = max(0, (boundsSize.width - frame.width) / 2)
            let vertical = max(0, (boundsSize.height - frame.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal,
                                                   bottom: vertical, right: horizontal)
        }
    }
}
