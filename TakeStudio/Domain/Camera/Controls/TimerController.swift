import Foundation

enum TimerDelay: Int, CaseIterable, Identifiable, Sendable {
    case none = 0
    case three = 3
    case five = 5
    case ten = 10

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none: return "Off"
        case .three: return "3s"
        case .five: return "5s"
        case .ten: return "10s"
        }
    }

    func next() -> TimerDelay {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return .none }
        return all[(index + 1) % all.count]
    }
}

@MainActor
final class TimerController {
    private var countdownTask: Task<Void, Never>?
    var onTick: ((Int) -> Void)?
    var onComplete: (() -> Void)?

    func start(delay: TimerDelay) {
        cancel()
        guard delay != .none else { return }

        countdownTask = Task {
            for remaining in stride(from: delay.rawValue, through: 1, by: -1) {
                onTick?(remaining)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            onComplete?()
        }
    }

    func cancel() {
        countdownTask?.cancel()
        countdownTask = nil
    }
}
