// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import Darwin
import os

/// Opens the Uninstaller when an app lands in Trash. Opt-in because watching
/// and scanning Trash requires Full Disk Access.
///
/// Adapted from Alex Zamai's implementation in upstream PR #3879, building
/// on the original proposal in #3755.
final class TrashAppWatcher {
    static let shared = TrashAppWatcher()
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "vorssaint",
                                    category: "TrashAppWatcher")

    private let trash = UninstallerSupport.trashURL(home: FileManager.default.homeDirectoryForCurrentUser)
    private var source: DispatchSourceFileSystemObject?
    private var known = Set<String>()
    private var pendingApps: [String: URL] = [:]
    private var pendingCheck: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var retryAttempt = 0
    private var phaseObservation: AnyCancellable?

    private init() {}

    func syncWithPreferences() {
        precondition(Thread.isMainThread)
        let wanted = AppFeature.uninstaller.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.uninstallerWatchesTrash)
            && Permissions.shared.fullDiskAccess
        wanted ? start() : stop()
    }

    func stop() {
        pendingCheck?.cancel()
        pendingCheck = nil
        retryWork?.cancel()
        retryWork = nil
        retryAttempt = 0
        source?.cancel()
        source = nil
        known = []
        pendingApps = [:]
        phaseObservation?.cancel()
        phaseObservation = nil
    }

    private func start() {
        guard source == nil else { return }
        let descriptor = open(trash.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            Self.log.error("Unable to watch the user Trash (errno \(code, privacy: .public)).")
            return
        }
        known = Set(UninstallerSupport.trashedApps(in: trash).map(\.standardizedFileURL.path))
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            if source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.scheduleCheck()
            } else {
                self.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.syncWithPreferences() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
        phaseObservation = AppUninstaller.shared.$phase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleCheck() }
    }

    /// Finder writes a deleted app in a few steps; look once it settles.
    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func check() {
        guard source != nil else { return }
        pendingCheck = nil
        let current = UninstallerSupport.trashedApps(in: trash)
        let queue = UninstallerSupport.pendingTrashedApps(
            current: current, known: known, pending: pendingApps)
        known = queue.known
        pendingApps = queue.pending

        guard !pendingApps.isEmpty else {
            retryWork?.cancel()
            retryWork = nil
            retryAttempt = 0
            return
        }
        let uninstaller = AppUninstaller.shared
        guard uninstaller.phase == .empty else { return }
        var shouldRetry = false
        for (path, app) in pendingApps.sorted(by: { $0.key < $1.key }) {
            switch offerDecision(for: app, uninstaller: uninstaller) {
            case .discard:
                pendingApps.removeValue(forKey: path)
            case .retry:
                shouldRetry = true
            case .offer:
                if appDelegate()?.openUninstaller(for: app) == true {
                    pendingApps.removeValue(forKey: path)
                    return
                }
                shouldRetry = true
            }
        }
        if pendingApps.isEmpty {
            retryAttempt = 0
        } else if shouldRetry {
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard retryWork == nil, !pendingApps.isEmpty else { return }
        let delay = UninstallerSupport.retryDelay(forAttempt: retryAttempt)
        retryAttempt = min(retryAttempt + 1, 5)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWork = nil
            self.check()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private enum OfferDecision {
        case offer
        case retry
        case discard
    }

    private func offerDecision(for app: URL, uninstaller: AppUninstaller) -> OfferDecision {
        if let identity = UninstallerSupport.fileIdentity(at: app), uninstaller.isTarget(identity) {
            return .discard
        }
        let selection: UninstallerSupport.Selection
        switch UninstallerSupport.evaluate(app) {
        case let .success(value):
            selection = value
        case .failure(.unidentified):
            return .retry
        case .failure:
            return .discard
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard UninstallerSupport.trashedAppWasLastCopy(
            otherCopies: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: selection.bundleID),
            home: home, fileExists: FileManager.default.fileExists(atPath:)) else {
            return .discard
        }
        return .offer
    }
}
