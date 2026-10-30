import SwiftUI
import UIKit

/// Observe a stationary touch without preventing the enclosing scroll view from panning.
struct PhotoTouchObserver: UIViewRepresentable {
    var enabled: Bool
    var onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let gesture = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        gesture.minimumPressDuration = 0
        gesture.cancelsTouchesInView = false
        gesture.delegate = context.coordinator
        view.addGestureRecognizer(gesture)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onChange = onChange
        view.isUserInteractionEnabled = enabled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: (Bool) -> Void
        private var start: CGPoint = .zero
        private var moved = false

        init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

        @objc func changed(_ gesture: UILongPressGestureRecognizer) {
            let point = gesture.location(in: gesture.view)
            switch gesture.state {
            case .began:
                start = point
                moved = false
                onChange(true)
            case .changed:
                if hypot(point.x - start.x, point.y - start.y) >= 10 { moved = true }
                if moved { onChange(false) }
            case .ended, .cancelled, .failed:
                onChange(false)
            default: break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
