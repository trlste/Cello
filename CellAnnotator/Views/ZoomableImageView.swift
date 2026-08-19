import SwiftUI
import UIKit

struct ZoomableImageView: UIViewRepresentable {
    let document: TIFFDocument
    let store: AnnotationStore
    let displaySettings: [ChannelDisplaySettings]
    let displayRevision: Int
    let selectedZ: Int
    let selectedTime: Int
    let annotationDisplayRevision: Int
    let annotationFocusRevision: Int
    let measurementCalibration: PixelCalibration?
    let freehandSmoothing: Double
    @Binding var renderStatus: TileRenderStatus

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 0.1
        scrollView.maximumZoomScale = 20
        scrollView.delegate = context.coordinator
        scrollView.bouncesZoom = true

        scrollView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]

        context.coordinator.currentDocumentID = document.id
        buildContent(in: scrollView, context: context)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.renderStatus = $renderStatus
        // Watch the close-polygon request counter.
            if store.closePolygonRequest != context.coordinator.lastHandledCloseRequest {
                context.coordinator.lastHandledCloseRequest = store.closePolygonRequest
                print("calling closePolygon, overlay is nil?", context.coordinator.overlay == nil)
                context.coordinator.overlay?.closePolygon()
            }
        // Rebuild only when a different TIFF document is opened.
        if context.coordinator.currentDocumentID != document.id {
            context.coordinator.currentDocumentID = document.id
            buildContent(in: scrollView, context: context)
        }
        context.coordinator.displaySettings = displaySettings
        context.coordinator.displayRevision = displayRevision
        context.coordinator.selectedZ = selectedZ
        context.coordinator.selectedTime = selectedTime
        context.coordinator.overlay?.updateMeasurementCalibration(measurementCalibration)
        context.coordinator.overlay?.updateFreehandSmoothing(freehandSmoothing)
        context.coordinator.updateVisibleTiles(in: scrollView)
        context.coordinator.overlay?.refresh(zoomScale: scrollView.zoomScale)

        if annotationFocusRevision != context.coordinator.lastHandledAnnotationFocusRevision {
            context.coordinator.lastHandledAnnotationFocusRevision = annotationFocusRevision
            if let annotationID = store.requestedAnnotationFocusID,
               let annotation = store.annotations.first(where: { $0.id == annotationID }) {
                let documentID = document.id
                DispatchQueue.main.async {
                    guard context.coordinator.currentDocumentID == documentID else { return }
                    context.coordinator.focus(on: annotation, in: scrollView)
                }
            }
        }
    }

    /// Builds (or rebuilds) the zoomed content: container + image + overlay.
    private func buildContent(in scrollView: UIScrollView, context: Context) {
        // Tear down any existing content first.
        print("buildContent called")
        context.coordinator.tiledImageView?.onRenderStatusChange = nil
        context.coordinator.container?.removeFromSuperview()
        context.coordinator.publishRenderStatus(.idle, for: document.id)

        let container = UIView(frame: CGRect(origin: .zero, size: document.pixelSize))
        container.clipsToBounds = true

        let tiledImageView = TiledImageView(document: document)
        tiledImageView.frame = container.bounds
        tiledImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let documentID = document.id
        tiledImageView.onRenderStatusChange = { [weak coordinator = context.coordinator] status in
            coordinator?.publishRenderStatus(status, for: documentID)
        }
        container.addSubview(tiledImageView)

        let overlay = AnnotationOverlayView(
            store: store,
            imagePixelSize: document.pixelSize,
            measurementCalibration: measurementCalibration,
            freehandSmoothing: freehandSmoothing
        )
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.layer.zPosition = 1
        container.addSubview(overlay)
        container.bringSubviewToFront(overlay)

        scrollView.addSubview(container)
        scrollView.contentSize = container.bounds.size

        context.coordinator.container = container
        context.coordinator.tiledImageView = tiledImageView
        context.coordinator.overlay = overlay
        context.coordinator.displaySettings = displaySettings
        context.coordinator.displayRevision = displayRevision
        context.coordinator.selectedZ = selectedZ
        context.coordinator.selectedTime = selectedTime

        // Reset zoom to fit the new image, then center.
        DispatchQueue.main.async {
            guard context.coordinator.currentDocumentID == documentID else { return }
            guard document.pixelSize.width > 0, document.pixelSize.height > 0 else { return }
            let scaleW = scrollView.bounds.width / document.pixelSize.width
            let scaleH = scrollView.bounds.height / document.pixelSize.height
            let fitScale = min(scaleW, scaleH)
            scrollView.minimumZoomScale = min(fitScale, 0.1)
            scrollView.zoomScale = fitScale
            context.coordinator.centerContent(scrollView)
            context.coordinator.updateVisibleTiles(in: scrollView)
            context.coordinator.overlay?.refresh(zoomScale: fitScale)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(renderStatus: $renderStatus)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var container: UIView?
        weak var tiledImageView: TiledImageView?
        weak var overlay: AnnotationOverlayView?
        var currentDocumentID: UUID?
        var lastHandledCloseRequest = 0
        var lastHandledAnnotationFocusRevision = 0
        var displaySettings: [ChannelDisplaySettings] = []
        var displayRevision = 0
        var selectedZ = 0
        var selectedTime = 0
        var renderStatus: Binding<TileRenderStatus>

        init(renderStatus: Binding<TileRenderStatus>) {
            self.renderStatus = renderStatus
        }

        func publishRenderStatus(_ status: TileRenderStatus, for documentID: UUID? = nil) {
            let binding = renderStatus
            DispatchQueue.main.async { [weak self] in
                if let documentID,
                   self?.currentDocumentID != documentID {
                    return
                }
                if binding.wrappedValue != status {
                    binding.wrappedValue = status
                }
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(scrollView)
            overlay?.updateZoomScale(scrollView.zoomScale)
            updateVisibleTiles(in: scrollView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateVisibleTiles(in: scrollView)
        }

        func updateVisibleTiles(in scrollView: UIScrollView) {
            guard let container, let tiledImageView else { return }
            let visible = scrollView.convert(scrollView.bounds, to: container)
                .intersection(container.bounds)
            tiledImageView.updateVisibleRegion(
                visible,
                zoomScale: scrollView.zoomScale,
                screenScale: scrollView.window?.screen.scale ?? UIScreen.main.scale,
                settings: displaySettings,
                displayRevision: displayRevision,
                z: selectedZ,
                time: selectedTime
            )
        }

        func focus(on annotation: Annotation, in scrollView: UIScrollView) {
            guard let minX = annotation.points.map(\.x).min(),
                  let maxX = annotation.points.map(\.x).max(),
                  let minY = annotation.points.map(\.y).min(),
                  let maxY = annotation.points.map(\.y).max() else { return }
            let bounds = CGRect(
                x: minX,
                y: minY,
                width: maxX - minX,
                height: maxY - minY
            )

            // Keep substantially more context around the selected annotation. At the
            // target zoom, the annotation occupies roughly one-eighth of the viewport
            // instead of the previous one-third.
            let paddedWidth = max(bounds.width * 8, 1)
            let paddedHeight = max(bounds.height * 8, 1)
            let idealScale = min(
                scrollView.bounds.width / paddedWidth,
                scrollView.bounds.height / paddedHeight
            )
            let targetScale = min(
                scrollView.maximumZoomScale,
                max(scrollView.zoomScale, idealScale)
            )
            guard targetScale.isFinite, targetScale > 0 else { return }

            let visibleSize = CGSize(
                width: scrollView.bounds.width / targetScale,
                height: scrollView.bounds.height / targetScale
            )
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let contentSize = container?.bounds.size ?? .zero
            let maxOriginX = max(0, contentSize.width - visibleSize.width)
            let maxOriginY = max(0, contentSize.height - visibleSize.height)
            let origin = CGPoint(
                x: min(max(center.x - visibleSize.width / 2, 0), maxOriginX),
                y: min(max(center.y - visibleSize.height / 2, 0), maxOriginY)
            )
            scrollView.zoom(
                to: CGRect(origin: origin, size: visibleSize),
                animated: true
            )
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
