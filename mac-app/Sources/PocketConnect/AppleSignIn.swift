import AppKit
import AuthenticationServices
import Security

// Native Sign in with Apple for AppKit/macOS.
//
// There is no SwiftUI SignInWithAppleButton here — we drive
// ASAuthorizationAppleIDProvider + ASAuthorizationController directly and present
// over the given NSWindow. Requires the com.apple.developer.applesignin
// entitlement and a Team-ID-backed provisioning profile to yield a valid
// identityToken (see README / packaging notes).

struct AppleCredential {
    let userID: String          // credential.user == apple_user_id
    let identityToken: String   // JWT (utf8 of credential.identityToken)
    let displayName: String?    // only present on the first authorization
    let email: String?          // only present on the first authorization
}

final class AppleSignInCoordinator: NSObject,
    ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    static var isAvailableForCurrentBuild: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let entitlement = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.applesignin" as CFString,
                nil
              ) as? [String]
        else {
            return false
        }
        return entitlement.contains("Default")
    }

    private let anchor: NSWindow
    private var completion: ((Result<AppleCredential, Error>) -> Void)?
    // Hold a strong ref to self while the controller is in flight.
    private static var live: AppleSignInCoordinator?

    init(presentingOver window: NSWindow) { self.anchor = window }

    func start(_ completion: @escaping (Result<AppleCredential, Error>) -> Void) {
        self.completion = completion
        AppleSignInCoordinator.live = self
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    private func finish(_ result: Result<AppleCredential, Error>) {
        completion?(result)
        completion = nil
        AppleSignInCoordinator.live = nil
    }

    // MARK: ASAuthorizationControllerDelegate
    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential else {
            return finish(.failure(BridgeError(message: "非預期的憑證型別")))
        }
        guard let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8), !token.isEmpty else {
            return finish(.failure(BridgeError(message: "Apple 未回傳 identityToken")))
        }
        let name = [cred.fullName?.givenName, cred.fullName?.familyName]
            .compactMap { $0 }.joined(separator: " ")
        finish(.success(AppleCredential(
            userID: cred.user,
            identityToken: token,
            displayName: name.isEmpty ? nil : name,
            email: cred.email)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(error))
    }

    // MARK: presentation anchor
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor
    }
}
