import UIKit

enum TimelineCellKind: Hashable {
    case videoClip
    case segment
    case transition
}

final class TimelineCellReusePool {
    private var available: [TimelineCellKind: [UIView]] = [:]

    func dequeue(kind: TimelineCellKind, factory: () -> UIView) -> UIView {
        if var pool = available[kind], !pool.isEmpty {
            let cell = pool.removeLast()
            available[kind] = pool
            return cell
        }
        return factory()
    }

    func recycle(_ cell: UIView, kind: TimelineCellKind) {
        cell.removeFromSuperview()
        cell.transform = .identity
        cell.alpha = 1
        cell.isHidden = false
        available[kind, default: []].append(cell)
    }

    func drain() {
        available.removeAll()
    }
}
