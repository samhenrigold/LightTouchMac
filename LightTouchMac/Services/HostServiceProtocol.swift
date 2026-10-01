import Foundation

nonisolated enum HostServiceFailure: Codable, Sendable {
    case device(DeviceError), tools(DeviceToolsError), posix(Int32), message(String)
    init(_ error: Error) {
        if let value = error as? DeviceError { self = .device(value) }
        else if let value = error as? DeviceToolsError { self = .tools(value) }
        else if let value = error as? POSIXError { self = .posix(value.code.rawValue) }
        else { self = .message(error.localizedDescription) }
    }
    var error: Error {
        switch self {
        case .device(let value): value
        case .tools(let value): value
        case .posix(let value): POSIXError(POSIXErrorCode(rawValue: value) ?? .EIO)
        case .message(let value): DeviceToolsError.failed(value)
        }
    }
}

nonisolated struct HostServiceRequest: Codable, Sendable {
    static let version = 1
    var version = Self.version
    let id: UUID
    let session: UUID
    let operation: HostServiceOperation
}

nonisolated struct HostServiceEvent: Codable, Sendable {
    enum Payload: Codable, Sendable {
        case result(HostServiceValue), failure(HostServiceFailure)
        case progress(HostServiceProgress)
    }
    let id: UUID
    let session: UUID
    let payload: Payload
}

