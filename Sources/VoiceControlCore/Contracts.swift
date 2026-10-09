import Foundation

// Local-only values. Never serialize these contracts directly into a cloud request or log.
public struct RequestToken: Hashable, Sendable {
    public let sessionID: UUID
    public let generation: UInt64
    public init(sessionID: UUID = UUID(), generation: UInt64 = 0) {
        self.sessionID = sessionID; self.generation = generation
    }
}

public struct ScreenPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct ScreenRect: Equatable, Sendable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var center: ScreenPoint { ScreenPoint(x: x + width / 2, y: y + height / 2) }
}

public struct TargetReference: Equatable, Sendable {
    public let observationID: UUID
    public let targetID: UUID
    public let applicationID: String
    public let windowID: String
    public let role: String
    public let label: String
    public let bounds: ScreenRect
    public let isEditable: Bool
    public init(observationID: UUID, targetID: UUID = UUID(), applicationID: String,
                windowID: String, role: String, label: String, bounds: ScreenRect, isEditable: Bool) {
        self.observationID = observationID; self.targetID = targetID
        self.applicationID = applicationID; self.windowID = windowID
        self.role = role; self.label = label; self.bounds = bounds; self.isEditable = isEditable
    }
}

public struct Observation: Sendable {
    public let id: UUID
    public let applicationID: String
    public let windowID: String
    public let targets: [TargetReference]
    public init(id: UUID, applicationID: String, windowID: String, targets: [TargetReference]) {
        self.id = id; self.applicationID = applicationID; self.windowID = windowID; self.targets = targets
    }
}

public enum TargetResolution: Sendable {
    case resolved(TargetReference)
    case ambiguous([TargetReference])
    case unavailable(String)
}

public struct TextSpan: Equatable, Sendable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
}

public enum BoundedAction: Equatable, Sendable {
    case activateApplication(bundleID: String)
    case focus(TargetReference)
    case movePointer(TargetReference)
    case click(TargetReference)
    case scroll(TargetReference, vertical: Int)
    case insertText(TargetReference, text: String)
    case deleteText(TargetReference, span: TextSpan, expectedText: String)
    case sendMessage(TargetReference, recipient: String, content: String)
    case spend(TargetReference, merchant: String, item: String, amount: String, currency: String, recurringTerms: String?)

    public var target: TargetReference? {
        switch self {
        case .activateApplication: nil
        case let .focus(t), let .movePointer(t), let .click(t), let .scroll(t, _),
             let .insertText(t, _), let .deleteText(t, _, _), let .sendMessage(t, _, _),
             let .spend(t, _, _, _, _, _): t
        }
    }
    public var requiresConfirmation: Bool {
        switch self { case .deleteText, .sendMessage, .spend: true; default: false }
    }
    public var isEarlyEligible: Bool {
        switch self {
        case .activateApplication, .movePointer, .scroll: true
        case let .focus(t): t.isEditable
        default: false
        }
    }
}

public struct ActionProposal: Equatable, Sendable {
    public let request: RequestToken
    public let operationID: UUID
    public let action: BoundedAction
    public let finalized: Bool
    public init(request: RequestToken, operationID: UUID = UUID(), action: BoundedAction, finalized: Bool) {
        self.request = request; self.operationID = operationID; self.action = action; self.finalized = finalized
    }
}

public enum InputEvent: Equatable, Sendable {
    case move(ScreenPoint)
    case mouseDown(ScreenPoint)
    case mouseUp(ScreenPoint)
    case unicodeDown(String)
    case unicodeUp
    case keyDown(UInt16)
    case keyUp(UInt16)
    case scroll(Int)
}

public enum Verification: String, Sendable { case verified, failed, unknown }
public enum OperationOutcome: String, Sendable { case completed, aborted, failed, unknown }

// Implementations may block during observation, but must never post input in prepare/verify.
// Non-event effects (application activation, AX focus) use perform under the same dispatch gate.
public enum PreparedStep: Equatable, Sendable {
    case event(InputEvent)
    case activateApplication(String)
    case focus(TargetReference)
}

public protocol ActionDriver: Sendable {
    func validate(_ action: BoundedAction) async -> Bool
    func prepare(_ action: BoundedAction) async throws -> [PreparedStep]
    func perform(_ step: PreparedStep) throws
    func verify(_ action: BoundedAction) async -> Verification
    func releaseHeldInputs()
}

public protocol ObservationProvider: Sendable {
    func observe() async throws -> Observation
    func resolve(_ description: String, in observation: Observation) async -> TargetResolution
    func invalidate()
}

public enum ControlError: Error, Sendable {
    case permissionDenied, staleTarget, unsupportedAction, invalidInput, dispatchFailed
}
