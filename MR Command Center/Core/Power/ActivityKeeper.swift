import AppKit
import IOKit
import IOKit.pwr_mgt
import Observation
import SwiftData
import os

/// "Keep this Mac awake while the app is open": every minute, tells the power manager the user
/// is active (`IOPMAssertionDeclareUserActivity`), so the display doesn't dim or sleep and the
/// idle screen lock doesn't kick in. No permission needed.
///
/// It does *not* reset the input idle time (`CGEventSource.secondsSinceLastEventType`), which is
/// what chat apps use for "Away". That would take synthetic input events, which need the
/// Accessibility permission; that was measured on 2026-10-20 and the permission is locked on the
/// user's work Mac.
///
/// Pauses while the lid is closed, the Mac is asleep, or the screen is locked, so locking still
/// means away and a locked screen isn't woken every minute. Stops when the app quits.
@Observable
final class ActivityKeeper {
    /// Saved in `AccountSettings.keepMacActive`.
    var isEnabled: Bool {
        get { settings.keepMacActive }
        set {
            settings.keepMacActive = newValue
            try? container.mainContext.save()
            newValue ? tick() : release()
        }
    }

    /// On and actually declaring activity right now (not paused).
    private(set) var isActive = false

    private let container: ModelContainer
    private var settings: AccountSettings { AccountSettings.current(in: container.mainContext) }
    private var assertionID = IOPMAssertionID(0)
    private var isAsleep = false
    private var isScreenLocked = false
    private var loop: Task<Void, Never>?
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    /// Comfortably shorter than the usual few-minute "away" thresholds.
    static let interval: Duration = .seconds(60)

    init(container: ModelContainer) {
        self.container = container
    }

    /// Starts watching sleep, wake, and screen lock, and the once-a-minute loop. Call once at launch.
    func start() {
        guard loop == nil else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(workspace, NSWorkspace.willSleepNotification) { $0.isAsleep = true; $0.release() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.isAsleep = false; $0.tick() }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.isScreenLocked = true; $0.release() }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.isScreenLocked = false; $0.tick() }

        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        release()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor @Sendable (ActivityKeeper) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    private var shouldDeclare: Bool {
        isEnabled && !isAsleep && !isScreenLocked && !Self.isLidClosed
    }

    private func tick() {
        guard shouldDeclare else {
            release()
            return
        }
        // Reusing the ID refreshes the same assertion instead of piling up new ones.
        let result = IOPMAssertionDeclareUserActivity("MR Command Center" as CFString, kIOPMUserActiveLocal, &assertionID)
        isActive = result == kIOReturnSuccess
        if !isActive {
            Log.app.error("Declaring user activity failed: \(result, privacy: .public)")
        }
    }

    private func release() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        isActive = false
    }

    /// The built-in display's lid, from the power manager. Covers "closed with an external
    /// display", when the Mac stays awake. False on desktops or if it can't be read.
    static var isLidClosed: Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        let value = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }
}
