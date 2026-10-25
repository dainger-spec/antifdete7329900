import Foundation

/// Names shared by the CLI and the app.
public enum LauncherDefaults {
    public static let vmName = "safari-profile"
    public static let baseImage = "ghcr.io/cirruslabs/macos-sonoma-base:latest"
}

/// The steps a launch walks through, in order.
public enum LaunchStage: Int, CaseIterable, Identifiable, Comparable, Sendable {
    case tart, image, vm, agent, safari, done

    public var id: Int { rawValue }

    public static func < (lhs: LaunchStage, rhs: LaunchStage) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .tart: "Проверка Tart"
        case .image: "Образ macOS"
        case .vm: "Запуск VM"
        case .agent: "Установка агента"
        case .safari: "Открытие Safari"
        case .done: "Готово"
        }
    }
}

public enum StageStatus: Equatable, Sendable {
    case pending
    /// `progress` is 0…1, or nil when only "busy" is known (spinner).
    case running(detail: String, progress: Double?)
    /// Waiting for the user (e.g. Tart is missing and needs installing).
    case attention(detail: String)
    case done(detail: String)
    case failed(detail: String)
    case cancelled

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isDone: Bool {
        if case .done = self { return true }
        return false
    }

    public var detail: String? {
        switch self {
        case .pending, .cancelled: nil
        case .running(let detail, _), .attention(let detail), .done(let detail), .failed(let detail): detail
        }
    }

    public var progress: Double? {
        if case .running(_, let progress) = self { return progress }
        return nil
    }
}

/// The status of every stage. Stages advance strictly forward: starting a stage
/// completes every earlier one that is still open.
public struct LaunchProgress: Equatable, Sendable {
    public private(set) var statuses: [LaunchStage: StageStatus]

    public init() {
        statuses = Dictionary(uniqueKeysWithValues: LaunchStage.allCases.map { ($0, .pending) })
    }

    public subscript(stage: LaunchStage) -> StageStatus { statuses[stage] ?? .pending }

    /// The stage currently running, if any.
    public var current: LaunchStage? { LaunchStage.allCases.first { self[$0].isRunning } }

    /// The latest stage that has left `pending`.
    public var furthest: LaunchStage? { LaunchStage.allCases.last { self[$0] != .pending } }

    public mutating func start(_ stage: LaunchStage, detail: String, progress: Double? = nil) {
        for earlier in LaunchStage.allCases where earlier < stage && !self[earlier].isDone {
            statuses[earlier] = .done(detail: self[earlier].detail ?? "")
        }
        statuses[stage] = .running(detail: detail, progress: progress.map(Self.clamp))
    }

    /// Updates a running stage; `progress: nil` keeps the previous value, so
    /// text-only updates don't make a determinate bar jump back to a spinner.
    public mutating func update(_ stage: LaunchStage, detail: String? = nil, progress: Double? = nil) {
        guard case .running(let oldDetail, let oldProgress) = self[stage] else { return }
        statuses[stage] = .running(detail: detail ?? oldDetail, progress: progress.map(Self.clamp) ?? oldProgress)
    }

    public mutating func finish(_ stage: LaunchStage, detail: String) {
        if !self[stage].isRunning { start(stage, detail: detail) }
        statuses[stage] = .done(detail: detail)
    }

    public mutating func attention(_ stage: LaunchStage, detail: String) {
        statuses[stage] = .attention(detail: detail)
    }

    /// Fails `stage`, or the current/furthest stage when nil.
    public mutating func fail(_ stage: LaunchStage? = nil, detail: String) {
        let target = stage ?? current ?? furthest ?? .tart
        statuses[target] = .failed(detail: detail)
    }

    public mutating func cancelOpenStages() {
        for stage in LaunchStage.allCases {
            switch self[stage] {
            case .running, .attention: statuses[stage] = .cancelled
            default: break
            }
        }
    }

    /// Overall completion 0…1: the five working stages weigh the same; a
    /// running stage contributes its own progress when it has one.
    public var fraction: Double {
        if self[.done].isDone { return 1 }
        let working = LaunchStage.allCases.filter { $0 != .done }
        let total = working.reduce(0.0) { sum, stage in
            switch self[stage] {
            case .done: sum + 1
            case .running(_, let progress?): sum + progress
            default: sum
            }
        }
        return total / Double(working.count)
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}
