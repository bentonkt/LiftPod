import Foundation

enum MotionPermissionState: String, Sendable {
    case notDetermined = "Not determined"
    case restricted = "Restricted"
    case denied = "Denied"
    case authorized = "Authorized"
    case unknown = "Unknown"
}
enum HeadphoneConnectionState: String, Sendable {
    case unknown = "Unknown"
    case waiting = "Waiting for connection"
    case connected = "Connected"
    case disconnected = "Disconnected"
}

enum MotionProviderEvent: Sendable, Equatable {
    case connected
    case disconnected
    case sample(RawMotionSample)
    case failure(String)
}

protocol MotionProviding: AnyObject, Sendable {
    var authorizationState: MotionPermissionState { get }
    var isMotionAvailable: Bool { get }
    var connectionUpdatesActive: Bool { get }
    var motionUpdatesActive: Bool { get }

    func makeEventStream() -> AsyncStream<MotionProviderEvent>
    func start()
    func stop()
}
