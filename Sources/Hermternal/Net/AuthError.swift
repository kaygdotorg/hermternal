import Foundation

enum AuthError: LocalizedError, Sendable {
    case loopbackUnavailable
    case loginTimedOut
    case malformedCallback
    case stateMismatch
    case providerRejected(String)
    case tokenExchangeFailed(status: Int, body: String)
    case ticketFailed(status: Int, body: String)
    case sessionExpired
    case notSignedIn
    case badServerURL

    var errorDescription: String? {
        switch self {
        case .loopbackUnavailable:
            "Could not open a local port for the sign-in redirect."
        case .loginTimedOut:
            "Sign-in timed out. Try again."
        case .malformedCallback:
            "The sign-in redirect was malformed."
        case .stateMismatch:
            "The sign-in response failed its CSRF check. Try again."
        case .providerRejected(let reason):
            "The identity provider rejected the sign-in: \(reason)"
        case .tokenExchangeFailed(let status, let body):
            "Token exchange failed (HTTP \(status)): \(body)"
        case .ticketFailed(let status, let body):
            "Could not mint a WebSocket ticket (HTTP \(status)): \(body)"
        case .sessionExpired:
            "The session expired. Sign in again."
        case .notSignedIn:
            "Not signed in."
        case .badServerURL:
            "That server URL is not valid."
        }
    }
}
