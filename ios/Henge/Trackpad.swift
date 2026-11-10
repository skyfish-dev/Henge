import SwiftUI
import UIKit
import GameController

/// A surface that works like a Mac's trackpad — it is one: the engine presents it on
/// the Mac's USB bus as a Magic Trackpad 2, so the Mac's own multitouch engine sees
/// the fingers: two scroll, three swipe between Spaces and to Mission Control, four
/// show the session's hidden controls.
///
/// Clicking depends on the input mode (Settings > Trackpad):
///  - Touchscreen: the surface itself clicks. A quick tap is a left click, a quick
///    two-finger tap is a right click, and touching then holding presses the button
///    down so moving drags. These go out as mouse buttons alongside the pad's fingers.
///  - Volume buttons: the surface only points and gestures; the clicks live on the
///    volume keys (VolumeClicks), so a tap here does nothing.
/// Only fingers count: a real trackpad or mouse goes through HardwareMouse. Where iOS shows its own pointer
/// over the Mac's screen, that pointer's hovers and clicks say where the Mac's pointer goes (PointerFollow).
struct Trackpad: UIViewRepresentable {
    /// Four fingers tapped together: the session shows its hidden controls.
    static let revealTap = Notification.Name("henge.trackpad.revealTap")

    /// For a surface over the Mac's screen: a point in the surface, as 0...1 of the Mac's screen, or nil off it.
    var map: ((CGPoint) -> CGPoint?)? = nil

    func makeUIView(context: Context) -> Surface {
        let surface = Surface()
        surface.map = map
        return surface
    }
    func updateUIView(_ view: Surface, context: Context) { view.map = map }

    final class Surface: UIView, UIPointerInteractionDelegate {
        /// The emulated pad's sensor, in the Magic Trackpad 2's own units.
        private static let sensorW: Int32 = 8134
        private static let sensorH: Int32 = 5206
        private static let holdTime: TimeInterval = 0.4
        private static let tapTime: TimeInterval = 0.3
        private static let tapDistance: CGFloat = 8

        private struct Finger { var touch: UITouch; var id: Int32 }

        private var fingers: [Finger] = []
        private var freeIds = Set<Int32>(1...5) /* a touch screen reports five fingers at most */
        private var started = Date()
        private var travelled: CGFloat = 0
        private var mostFingers = 0
        private var touchesLogged = 0

        /* Touchscreen-mode clicking. */
        private var holding = false
        private var holdTimer: Timer?
        private let buzz = UIImpactFeedbackGenerator(style: .medium)
        private var tapsClick: Bool { VolumeClicks.inputMode == .touchscreen }

        /* iOS's own pointer (PointerFollow). */
        var map: ((CGPoint) -> CGPoint?)?
        /// Touches made by a mouse's button rather than by fingers: they say where the Mac's pointer goes.
        private var pointerTouches: Set<UITouch> = []
        private var pointerPressed = false
        private var pointerTouchesLogged = 0, hoversLogged = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            addInteraction(UIPointerInteraction(delegate: self))
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        }

        /// Over the Mac there is only the Mac's pointer, if iPadOS hasn't locked its own away.
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

        required init?(coder: NSCoder) { fatalError("made in code") }

        @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
            guard hover.state == .began || hover.state == .changed, let map, let p = map(hover.location(in: self)) else { return }
            if hoversLogged < 3 {
                hoversLogged += 1
                HengeLog.log("input", "hover from iOS's pointer; following: \(PointerFollow.shared.active)")
            }
            PointerFollow.shared.hovered(p)
        }

        /// A mouse's touch, rather than a finger's. iPadOS marks it as one. On iPhone a mouse works through
        /// AssistiveTouch, whose clicks come as ordinary touches: with a mouse connected, a touch over the Mac
        /// is taken to be its click.
        private func isPointer(_ touch: UITouch) -> Bool {
            guard PointerFollow.shared.active, map != nil else { return false }
            if touch.type == .indirectPointer { return true }
            return !Device.isPad && (GCMouse.current != nil || PointerFollow.mode == .on)
        }

        /// Takes the touches that are a mouse's out of `touches` and handles them; returns the fingers.
        private func pointerPhase(_ touches: Set<UITouch>, began: Bool = false, ended: Bool = false) -> Set<UITouch> {
            if began, pointerTouchesLogged < 6, let t = touches.first {
                pointerTouchesLogged += 1
                HengeLog.log("input", "touch type \(t.type.rawValue), mouse connected \(GCMouse.current != nil), following \(PointerFollow.shared.active)")
            }
            var rest = Set<UITouch>()
            for touch in touches {
                if began {
                    guard isPointer(touch) else {
                        // With the pointer locked, GameController has a mouse's clicks (HardwareMouse).
                        if touch.type != .indirectPointer { rest.insert(touch) }
                        continue
                    }
                    guard let map, let p = map(touch.location(in: self)) else { continue } // off the Mac's screen
                    pointerTouches.insert(touch)
                    PointerFollow.shared.aim(p)
                    // A mouse whose buttons GameController reports clicks by itself (HardwareMouse).
                    PointerFollow.shared.afterArriving { [weak self] in
                        guard let self, !HardwareMouse.shared.buttonsSeen, !self.pointerPressed else { return }
                        self.pointerPressed = true
                        henge_vm_mouse_button(0, 1)
                    }
                } else if pointerTouches.contains(touch) {
                    if let map, let p = map(touch.location(in: self)) { PointerFollow.shared.aim(p) }
                    guard ended else { continue }
                    pointerTouches.remove(touch)
                    guard pointerTouches.isEmpty else { continue }
                    PointerFollow.shared.afterArriving { [weak self] in
                        guard let self, self.pointerPressed else { return }
                        self.pointerPressed = false
                        henge_vm_mouse_button(0, 0)
                        StickyKeys.shared.releaseAll()
                    }
                } else {
                    rest.insert(touch)
                }
            }
            return rest
        }

        /// Where the finger is on the pad's sensor, in its units.
        private func sensor(_ t: UITouch) -> (Int32, Int32) {
            let p = t.location(in: self)
            // One scale for both axes. The view and the pad's sensor are different
            // shapes, so stretching the view to fill the sensor would make a finger
            // move the pointer further on one axis than the other. Map the view to a
            // centred part of the sensor at a single scale instead.
            let w = max(Double(bounds.width), 1), h = max(Double(bounds.height), 1)
            let scale = min(Double(Self.sensorW) / w, Double(Self.sensorH) / h)
            let x = (Double(p.x) - w / 2) * scale + Double(Self.sensorW) / 2
            let y = (Double(p.y) - h / 2) * scale + Double(Self.sensorH) / 2
            return (Int32(min(max(x, 0), Double(Self.sensorW))),
                    Int32(min(max(y, 0), Double(Self.sensorH))))
        }

        /* A touch sample's own clock, in ms. The guest derives finger speed from the
           timestamp deltas, so reports must carry the sample time, not the moment we
           process the event -- otherwise a burst of samples reads as one enormous flick
           and scroll inertia goes wild on release. */
        private static func ms(_ t: TimeInterval) -> UInt32 { UInt32(truncatingIfNeeded: Int(t * 1000)) }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = pointerPhase(touches, began: true)
            guard !touches.isEmpty else { return }
            if fingers.isEmpty {
                started = Date()
                travelled = 0
                mostFingers = 0
                if tapsClick { buzz.prepare() }
            }
            for t in touches {
                guard let id = freeIds.min() else { break }
                freeIds.remove(id)
                fingers.append(Finger(touch: t, id: id))
                let (x, y) = sensor(t)
                henge_vm_touch(id, 0, x, y, Self.ms(t.timestamp))
                if touchesLogged < 12 {
                    touchesLogged += 1
                    HengeLog.log("input", "trackpad: finger \(id) down at \(x),\(y)")
                }
            }
            mostFingers = max(mostFingers, fingers.count)
            guard tapsClick else { return }
            if fingers.count >= 2 {
                cancelHold()
                if holding { /* a drag becomes a multi-finger gesture */
                    holding = false
                    henge_vm_mouse_button(0, 0)
                }
            } else {
                armHold()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            let touches = pointerPhase(touches)
            var moved = false
            let ts = Self.ms(event?.timestamp ?? touches.first?.timestamp ?? 0)
            for t in touches where t.type != .indirectPointer {
                guard let i = fingers.firstIndex(where: { $0.touch == t }) else { continue }
                let now = t.location(in: self), before = t.previousLocation(in: self)
                travelled += abs(now.x - before.x) + abs(now.y - before.y)
                let (x, y) = sensor(t)
                henge_vm_touch(fingers[i].id, 1, x, y, ts)
                moved = true
            }
            /* Moving means pointing or a gesture, not a tap or a press-to-drag. */
            if tapsClick && travelled >= Self.tapDistance && !holding { cancelHold() }
            /* One frame with every finger that moved, so the guest sees a gesture's
               fingers move together rather than one at a time. */
            if moved { henge_vm_touch_frame(ts) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

        private func lift(_ touches: Set<UITouch>) {
            let touches = pointerPhase(touches, ended: true)
            var lifted: [Int32] = []
            fingers.removeAll { finger in
                guard touches.contains(finger.touch), finger.touch.type != .indirectPointer else { return false }
                freeIds.insert(finger.id)
                lifted.append(finger.id)
                return true
            }
            guard !lifted.isEmpty else { return }
            let ts = Self.ms(touches.map(\.timestamp).max() ?? 0)
            for id in lifted { henge_vm_touch(id, 2, 0, 0, ts) }
            guard fingers.isEmpty else { return } /* fingers still down: the gesture goes on */
            /* The whole gesture is over. */
            if tapsClick {
                cancelHold()
                let quick = Date().timeIntervalSince(started) < Self.tapTime
                let still = travelled < Self.tapDistance
                if holding {
                    holding = false
                    henge_vm_mouse_button(0, 0) /* let go of the drag */
                } else if quick && still {
                    if mostFingers == 1 { click(0) }      /* a tap is a left click */
                    else if mostFingers == 2 { click(1) } /* a two-finger tap is a right click */
                }
            }
            if mostFingers >= 4, travelled < Self.tapDistance * 3, Date().timeIntervalSince(started) < Self.tapTime * 2 {
                NotificationCenter.default.post(name: Trackpad.revealTap, object: nil)
            }
            StickyKeys.shared.releaseAll()
        }

        /// A brief press of a mouse button: down then up.
        private func click(_ button: Int32) {
            henge_vm_mouse_button(button, 1)
            henge_vm_mouse_button(button, 0)
            buzz.impactOccurred()
        }

        /// A finger that stays put presses the left button down, so moving it drags.
        private func armHold() {
            cancelHold()
            let timer = Timer(timeInterval: Self.holdTime, repeats: false) { [weak self] _ in
                guard let self, self.fingers.count == 1, self.travelled < Self.tapDistance else { return }
                self.holding = true
                henge_vm_mouse_button(0, 1)
                self.buzz.impactOccurred()
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
        }

        private func cancelHold() {
            holdTimer?.invalidate()
            holdTimer = nil
        }
    }
}

/// One mouse button you can hold: down when touched, up when let go.
struct MouseButton: View {
    let title: String
    let button: Int32
    @State private var down = false

    var body: some View {
        Text(title)
            .font(.system(size: 15))
            .foregroundStyle(down ? Desk.text : Desk.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(down ? Desk.raised : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        henge_vm_mouse_button(button, 1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        down = false
                        henge_vm_mouse_button(button, 0)
                        StickyKeys.shared.releaseAll()
                    }
            )
            .accessibilityLabel(title)
    }
}