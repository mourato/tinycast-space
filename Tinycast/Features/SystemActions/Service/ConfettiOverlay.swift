import AppKit
import CoreImage
import QuartzCore

/// tinycast-space: Raycast's Confetti — the system action, and what `raycast://confetti` fires, so an
/// extension celebrating a finished timer or task looks the same here as it does in Raycast.
///
/// Two cannons from the bottom corners, one short burst, then the pieces fall under gravity, as
/// Raycast's and Messages' do. A click-through panel per screen, above everything, closing itself.
@MainActor
enum ConfettiOverlay {
    private static var panels: [NSPanel] = []
    /// Every number below can be overridden live, without a rebuild:
    /// `defaults write com.tinycast.app confetti.velocity 2600`, then fire again.
    private static func tuned(_ key: String, _ fallback: Double) -> Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "confetti." + key) != nil else { return fallback }
        return defaults.double(forKey: "confetti." + key)
    }
    private static let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPink,
        .systemPurple
    ]

    /// Fires on the screen the pointer is on — one cannon per bottom corner.
    static func fire() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
            ?? NSScreen.main
        else { return }
        present(on: screen)
    }

    /// True for `raycast://confetti` and `tinycast://confetti`, in any capitalisation.
    static func claims(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
            ["raycast", "tinycast", "com.raycast", "raycastinternal"].contains(scheme)
        else { return false }
        let path = (url.host ?? "") + url.path
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == "confetti"
    }

    private static func present(on screen: NSScreen) {
        let panel = NSPanel(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        panel.contentView = view
        guard let root = view.layer else { return }

        let inset = tuned("cannonInset", 0)
        let cannons = [
            cannon(at: CGPoint(x: inset, y: 10), direction: .pi / 180 * tuned("cannonAngleDegrees", 90), in: root.bounds),
            cannon(at: CGPoint(x: root.bounds.width - inset, y: 10), direction: .pi - .pi / 180 * tuned("cannonAngleDegrees", 90), in: root.bounds)
        ]
        cannons.forEach(root.addSublayer)
        panel.orderFrontRegardless()
        panels.append(panel)

        Task { @MainActor in
            // A single burst: the cannons fire for a moment, then only gravity is left to watch.
            try? await Task.sleep(for: .milliseconds(Int(tuned("burstMs", 520))))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cannons.forEach { $0.birthRate = 0 }
            CATransaction.commit()
            try? await Task.sleep(for: .milliseconds(Int(tuned("tailMs", 3300))))
            panel.orderOut(nil)
            panels.removeAll { $0 === panel }
        }
    }

    private static func cannon(at position: CGPoint, direction: CGFloat, in bounds: CGRect) -> CAEmitterLayer {
        let emitter = CAEmitterLayer()
        emitter.frame = bounds
        emitter.emitterPosition = position
        emitter.emitterShape = .point
        emitter.emitterSize = .zero
        emitter.renderMode = .unordered
        emitter.beginTime = CACurrentMediaTime()
        // Air, not a vacuum: drag brakes the burst into a float, and a slow wave makes it flutter.
        // Both are undocumented Core Animation behaviours — absent, the confetti simply arcs.
        let behaviors = [
            behavior("drag") { $0.setValue(tuned("drag", 1.95), forKey: "drag") },
            behavior("wave") {
                $0.setValue(CIVector(x: tuned("waveX", 600), y: tuned("waveY", 600), z: 0), forKey: "force")
                $0.setValue(tuned("waveFrequency", 7), forKey: "frequency")
            }
        ].compactMap { $0 }
        if !behaviors.isEmpty { emitter.setValue(behaviors, forKey: "emitterBehaviors") }
        emitter.emitterCells = colors.enumerated().map { index, color in
            cell(color, flat: index.isMultiple(of: 2), direction: direction)
        }
        return emitter
    }

    /// One `CAEmitterBehavior`, built through the runtime because the class is not in the headers.
    private static func behavior(_ type: String, _ configure: (NSObject) -> Void) -> NSObject? {
        guard let klass = NSClassFromString("CAEmitterBehavior") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("behaviorWithType:")
        guard klass.responds(to: selector),
            let value = klass.perform(selector, with: type)?.takeUnretainedValue() as? NSObject
        else { return nil }
        value.setValue(type, forKey: "name")
        configure(value)
        return value
    }

    private static func cell(_ color: NSColor, flat: Bool, direction: CGFloat) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = piece(color, size: flat ? CGSize(width: 12, height: 7) : CGSize(width: 8, height: 5))
        cell.birthRate = Float(tuned("birthRate", 100))
        cell.lifetime = Float(tuned("lifetime", 4.1))
        cell.lifetimeRange = Float(tuned("lifetimeRange", 1.1))
        cell.velocity = tuned("velocity", 2800)
        cell.velocityRange = tuned("velocityRange", 2700)
        cell.emissionLongitude = direction
        cell.emissionRange = .pi / 180 * tuned("emissionRangeDegrees", 90)
        // Negative Y pulls down in layer coordinates: the arc, then the fall.
        cell.yAcceleration = -tuned("gravity", 2000)
        cell.spin = tuned("spin", 3)
        cell.spinRange = tuned("spinRange", 8)
        cell.scale = tuned("scale", 0.75)
        cell.scaleRange = tuned("scaleRange", 1.25)
        cell.alphaSpeed = Float(-tuned("fade", 0.3))
        // Undocumented, and the whole difference between paper and spinning squares: a "plane"
        // particle tumbles through three axes instead of rotating flat. Ignored if it ever goes away.
        cell.setValue("plane", forKey: "particleType")
        cell.setValue(Double.pi, forKey: "orientationRange")
        cell.setValue(Double.pi / 2, forKey: "orientationLongitude")
        cell.setValue(Double.pi / 2, forKey: "orientationLatitude")
        return cell
    }

    /// Drawn once per colour and size rather than shipped as an asset.
    private static func piece(_ color: NSColor, size: CGSize) -> CGImage? {
        let width = Int(size.width * 2), height = Int(size.height * 2)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor((color.usingColorSpace(.deviceRGB) ?? .white).cgColor)
        context.addPath(
            CGPath(
                roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()
        return context.makeImage()
    }
}
