// FineTune/Services/UpdateChecker.swift
import Foundation
import AppKit
import UserNotifications
import os

/// Information about an available update.
struct UpdateInfo {
    let version: SemanticVersion
    let tagName: String
    let releaseURL: URL
    let releaseNotes: String?
    let publishedAt: Date?
}

/// Status of the update check.
enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(UpdateInfo)
    case error(String)

    static func == (lhs: UpdateStatus, rhs: UpdateStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.checking, .checking), (.upToDate, .upToDate):
            return true
        case let (.updateAvailable(lhsInfo), .updateAvailable(rhsInfo)):
            return lhsInfo.version == rhsInfo.version
        case let (.error(lhsMsg), .error(rhsMsg)):
            return lhsMsg == rhsMsg
        default:
            return false
        }
    }
}

/// Service for checking GitHub releases for updates.
@Observable
@MainActor
final class UpdateChecker {
    private(set) var status: UpdateStatus = .idle

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "UpdateChecker")
    private let releaseAPIURL = URL(string: "https://api.github.com/repos/ronitsingh10/FineTune/releases/latest")!
    private let timeout: TimeInterval = 15
    private var periodicCheckTask: Task<Void, Never>?

    /// Tracks the last version we notified about to avoid duplicate notifications.
    /// Persisted in UserDefaults so we don't re-notify after app restart.
    private var lastNotifiedVersion: SemanticVersion? {
        get {
            guard let string = UserDefaults.standard.string(forKey: "lastNotifiedUpdateVersion") else {
                return nil
            }
            return SemanticVersion(string)
        }
        set {
            UserDefaults.standard.set(newValue?.description, forKey: "lastNotifiedUpdateVersion")
        }
    }

    /// Checks for updates from GitHub releases.
    func checkForUpdates() async {
        status = .checking

        do {
            let updateInfo = try await fetchLatestRelease()

            guard let currentVersion = SemanticVersion.current else {
                logger.error("Failed to get current app version")
                status = .error("Unable to determine current version")
                return
            }

            if updateInfo.version > currentVersion {
                logger.info("Update available: \(updateInfo.version.description) (current: \(currentVersion.description))")
                status = .updateAvailable(updateInfo)
                // Only post notification if we haven't already notified about this version
                if lastNotifiedVersion != updateInfo.version {
                    lastNotifiedVersion = updateInfo.version
                    postUpdateNotification(updateInfo: updateInfo)
                }
            } else {
                logger.info("App is up to date (current: \(currentVersion.description), latest: \(updateInfo.version.description))")
                status = .upToDate
            }
        } catch {
            logger.error("Update check failed: \(error.localizedDescription)")
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet, .networkConnectionLost:
                    status = .error("No internet connection")
                case .timedOut:
                    status = .error("Request timed out")
                default:
                    status = .error("Network error")
                }
            } else {
                status = .error("Failed to check for updates")
            }
        }
    }

    /// Opens the release page in the default browser.
    func openReleasePage() {
        guard case let .updateAvailable(info) = status else { return }
        NSWorkspace.shared.open(info.releaseURL)
    }

    /// Starts periodic background update checks (hourly).
    /// The initial check is delayed to let the UI load first.
    func startPeriodicChecks(settingsManager: SettingsManager) {
        periodicCheckTask?.cancel()
        periodicCheckTask = Task { [weak self] in
            // Initial delay to let UI load
            try? await Task.sleep(for: .seconds(3))

            while !Task.isCancelled {
                if settingsManager.shouldCheckForUpdates() {
                    settingsManager.recordUpdateCheck()
                    await self?.checkForUpdates()
                }
                // Wait 1 hour before next check
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Stops periodic update checks.
    func stopPeriodicChecks() {
        periodicCheckTask?.cancel()
        periodicCheckTask = nil
    }

    // MARK: - Private

    private func postUpdateNotification(updateInfo: UpdateInfo) {
        let content = UNMutableNotificationContent()
        content.title = "FineTune Update Available"
        content.body = "Version \(updateInfo.version.description) is available. Click to download."
        content.sound = .default
        content.userInfo = ["releaseURL": updateInfo.releaseURL.absoluteString]

        let request = UNNotificationRequest(
            identifier: "update-available",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error {
                logger.error("Failed to post update notification: \(error.localizedDescription)")
            }
        }
    }

    private func fetchLatestRelease() async throws -> UpdateInfo {
        var request = URLRequest(url: releaseAPIURL)
        request.timeoutInterval = timeout
        request.setValue("FineTune-macOS-App", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("GitHub API returned status \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        guard let version = SemanticVersion(release.tag_name) else {
            throw URLError(.cannotParseResponse)
        }

        guard let releaseURL = URL(string: release.html_url) else {
            throw URLError(.badURL)
        }

        var publishedAt: Date?
        if let dateString = release.published_at {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            publishedAt = formatter.date(from: dateString)
            if publishedAt == nil {
                // Try without fractional seconds
                formatter.formatOptions = [.withInternetDateTime]
                publishedAt = formatter.date(from: dateString)
            }
        }

        return UpdateInfo(
            version: version,
            tagName: release.tag_name,
            releaseURL: releaseURL,
            releaseNotes: release.body,
            publishedAt: publishedAt
        )
    }
}

// MARK: - GitHub API Response

private struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
    let body: String?
    let published_at: String?
}

// MARK: - Notification Delegate

/// Handles notification interactions (e.g., clicking on update notification).
final class UpdateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotificationDelegate()

    private override init() {
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        if let urlString = userInfo["releaseURL"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }

        completionHandler()
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
