import AppKit

/// Browser-based Sign in with Apple for Developer ID distributions.
///
/// The fixed-domain broker returns a one-time Apple identity proof to Pocket.
/// Pocket then gives that proof to its own local bridge, which creates the
/// machine-local account session.
final class WebAppleSignInCoordinator {
    private let bridge: BridgeClient
    private var attempt: AppleWebAuthAttempt?
    private var pollWorkItem: DispatchWorkItem?
    private var completion: ((Result<AppleWebIdentity, Error>) -> Void)?
    private var consecutivePollFailures = 0
    private var finished = false

    init(bridge: BridgeClient) {
        self.bridge = bridge
    }

    func start(completion: @escaping (Result<AppleWebIdentity, Error>) -> Void) {
        guard !finished, self.completion == nil else { return }
        self.completion = completion
        bridge.startWebAppleAuth { [weak self] result in
            guard let self, !self.finished else { return }
            switch result {
            case .failure(let error):
                self.finish(.failure(error))
            case .success(let attempt):
                self.attempt = attempt
                guard NSWorkspace.shared.open(attempt.authorizationURL) else {
                    return self.finish(.failure(
                        BridgeError(message: "無法開啟 Apple 登入頁面")
                    ))
                }
                self.schedulePoll(after: attempt.pollInterval)
            }
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        pollWorkItem?.cancel()
        pollWorkItem = nil
        completion = nil
    }

    private func schedulePoll(after delay: TimeInterval) {
        guard !finished, let attempt else { return }
        guard Date() < attempt.expiresAt else {
            return finish(.failure(BridgeError(message: "Apple 登入已逾時,請重新嘗試。")))
        }
        let workItem = DispatchWorkItem { [weak self] in self?.poll() }
        pollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func poll() {
        guard !finished, let attempt else { return }
        guard Date() < attempt.expiresAt else {
            return finish(.failure(BridgeError(message: "Apple 登入已逾時,請重新嘗試。")))
        }
        bridge.pollWebAppleAuth(attempt) { [weak self] result in
            guard let self, !self.finished else { return }
            switch result {
            case .failure(let error):
                self.consecutivePollFailures += 1
                if self.consecutivePollFailures >= 3 {
                    self.finish(.failure(error))
                } else {
                    self.schedulePoll(after: attempt.pollInterval)
                }
            case .success(.pending):
                self.consecutivePollFailures = 0
                self.schedulePoll(after: attempt.pollInterval)
            case .success(.complete(let authResult)):
                self.finish(.success(authResult))
            case .success(.failed(let message)):
                self.finish(.failure(BridgeError(message: message)))
            }
        }
    }

    private func finish(_ result: Result<AppleWebIdentity, Error>) {
        guard !finished else { return }
        finished = true
        pollWorkItem?.cancel()
        pollWorkItem = nil
        let callback = completion
        completion = nil
        callback?(result)
    }
}
