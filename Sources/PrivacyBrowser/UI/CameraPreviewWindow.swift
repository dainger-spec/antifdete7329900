import AppKit
import BrowserCore
import SwiftUI

/// A separate window that shows a big live preview of the substituted camera and lets the person
/// drag a crop rectangle over the source. Opened from the editor's "Open preview" button; it
/// follows the editor's settings through a `CameraMirror` and writes the crop back through
/// `setCrop`. One window is reused.
@MainActor
final class CameraPreviewWindowController: NSWindowController {
    static let shared = CameraPreviewWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = L("editor.camera.preview.window")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(mirror: CameraMirror, setCrop: @escaping (CameraSubstitution.Crop) -> Void) {
        window?.contentView = NSHostingView(rootView: CameraPreviewWindowView(mirror: mirror, setCrop: setCrop))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct CameraPreviewWindowView: View {
    @ObservedObject var mirror: CameraMirror
    let setCrop: (CameraSubstitution.Crop) -> Void

    var body: some View {
        VStack(spacing: 12) {
            // The source with the crop rectangle, or the live preview when there is no source to crop.
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                if let source = CameraPreview.sourceImage(for: mirror.camera) {
                    GeometryReader { geometry in
                        let rect = Self.fittedRect(aspect: source.size.width / max(1, source.size.height), in: geometry.size)
                        Image(nsImage: source)
                            .resizable()
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        if mirror.camera.crop.enabled {
                            CropOverlay(crop: mirror.camera.crop, imageRect: rect, setCrop: setCrop)
                        }
                    }
                    .padding(8)
                } else {
                    CameraPreviewView(camera: mirror.camera, height: 320)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // What the page actually gets (crop, fit, mirror and the adjustments applied).
            VStack(alignment: .leading, spacing: 4) {
                Text(L("editor.camera.preview.result")).font(.caption).foregroundStyle(.secondary)
                CameraPreviewView(camera: mirror.camera, height: 120)
            }

            HStack {
                Toggle(L("editor.camera.crop.enabled"), isOn: Binding(
                    get: { mirror.camera.crop.enabled },
                    set: { var crop = mirror.camera.crop; crop.enabled = $0; setCrop(crop) }))
                    .toggleStyle(.switch)
                Spacer()
                Button(L("editor.camera.crop.reset")) { setCrop(.none) }
            }
        }
        .padding(14)
        .frame(minWidth: 420, minHeight: 460)
    }

    /// The largest rectangle of `aspect` that fits in `size`, centred.
    static func fittedRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        var width = size.width, height = size.width / aspect
        if height > size.height { height = size.height; width = size.height * aspect }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

/// The draggable crop rectangle over the source image. Normalised crop (origin top-left) maps to
/// `imageRect`; the body moves it and the four corners resize it, clamped to the image.
private struct CropOverlay: View {
    let crop: CameraSubstitution.Crop
    let imageRect: CGRect
    let setCrop: (CameraSubstitution.Crop) -> Void

    @State private var startCrop: CameraSubstitution.Crop?

    private var cropRect: CGRect {
        CGRect(x: imageRect.minX + crop.x * imageRect.width, y: imageRect.minY + crop.y * imageRect.height,
               width: crop.width * imageRect.width, height: crop.height * imageRect.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .path(in: cropRect)
                .stroke(Color.white, lineWidth: 1.5)
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
                .gesture(moveGesture)
            ForEach(Corner.allCases, id: \.self) { corner in
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .position(handlePoint(corner))
                    .gesture(resizeGesture(corner))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    private func handlePoint(_ corner: Corner) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: cropRect.minX, y: cropRect.minY)
        case .topRight: return CGPoint(x: cropRect.maxX, y: cropRect.minY)
        case .bottomLeft: return CGPoint(x: cropRect.minX, y: cropRect.maxY)
        case .bottomRight: return CGPoint(x: cropRect.maxX, y: cropRect.maxY)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let base = startCrop ?? crop
                if startCrop == nil { startCrop = crop }
                let dx = Double(value.translation.width / max(1, imageRect.width))
                let dy = Double(value.translation.height / max(1, imageRect.height))
                var next = base
                next.enabled = true
                next.x = min(max(0, base.x + dx), 1 - base.width)
                next.y = min(max(0, base.y + dy), 1 - base.height)
                setCrop(next)
            }
            .onEnded { _ in startCrop = nil }
    }

    private func resizeGesture(_ corner: Corner) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let base = startCrop ?? crop
                if startCrop == nil { startCrop = crop }
                let dx = Double(value.translation.width / max(1, imageRect.width))
                let dy = Double(value.translation.height / max(1, imageRect.height))
                var next = base
                next.enabled = true
                let minSize = 0.05
                switch corner {
                case .topLeft:
                    let nx = min(max(0, base.x + dx), base.x + base.width - minSize)
                    let ny = min(max(0, base.y + dy), base.y + base.height - minSize)
                    next.width = base.x + base.width - nx; next.height = base.y + base.height - ny
                    next.x = nx; next.y = ny
                case .topRight:
                    let ny = min(max(0, base.y + dy), base.y + base.height - minSize)
                    next.width = min(max(minSize, base.width + dx), 1 - base.x)
                    next.height = base.y + base.height - ny; next.y = ny
                case .bottomLeft:
                    let nx = min(max(0, base.x + dx), base.x + base.width - minSize)
                    next.width = base.x + base.width - nx; next.x = nx
                    next.height = min(max(minSize, base.height + dy), 1 - base.y)
                case .bottomRight:
                    next.width = min(max(minSize, base.width + dx), 1 - base.x)
                    next.height = min(max(minSize, base.height + dy), 1 - base.y)
                }
                setCrop(next)
            }
            .onEnded { _ in startCrop = nil }
    }
}
