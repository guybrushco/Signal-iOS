//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import UserNotifications
import SignalMessaging
import SignalServiceKit

// The lifecycle of the NSE looks something like the following:
//  1)  App receives notification
//  2)  System creates an instance of the extension class
//      and calls `didReceive` in the background
//  3)  Extension processes messages / displays whatever
//      notifications it needs to
//  4)  Extension notifies its work is complete by calling
//      the contentHandler
//  5)  If the extension takes too long to perform its work
//      (more than 30s), it will be notified and immediately
//      terminated
//
// Note that the NSE does *not* always spawn a new process to
// handle a new notification and will also try and process notifications
// in parallel. `didReceive` could be called twice for the same process,
// but it will always be called on different threads. It may or may not be
// called on the same instance of `NotificationService` as a previous
// notification.
//
// We keep a global `environment` singleton to ensure that our app context,
// database, logging, etc. are only ever setup once per *process*
let environment = NSEEnvironment()

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var areVersionMigrationsComplete = false

    func completeSilenty(timeHasExpired: Bool = false) {
        guard let contentHandler = contentHandler else { return }
        let content = UNMutableNotificationContent()

        // We cannot perform a database read when the NSE's time
        // has expired, we must exit immediately.
        if !timeHasExpired {
            let badgeCount = databaseStorage.read { InteractionFinder.unreadCountInAllThreads(transaction: $0.unwrapGrdbRead) }
            content.badge = NSNumber(value: badgeCount)
        }

        contentHandler(content)
        self.contentHandler = nil
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler

        if let errorContent = environment.setupIfNecessary() {
            Logger.warn("Posting error notification and skipping processing.")
            contentHandler(errorContent)
            exit(0)
        }

        owsAssertDebug(FeatureFlags.notificationServiceExtension)

        Logger.info("Received notification in class: \(self), thread: \(Thread.current), pid: \(ProcessInfo.processInfo.processIdentifier)")

        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            environment.askMainAppToHandleReceipt { [weak self] mainAppHandledReceipt in
                guard !mainAppHandledReceipt else {
                    Logger.info("Received notification handled by main application.")
                    self?.completeSilenty()
                    return
                }

                Logger.info("Processing received notification.")

                self?.fetchAndProcessMessages()
            }
        }
    }

    private let nseExpirationFlag = AtomicBool(false)

    // Called just before the extension will be terminated by the system.
    override func serviceExtensionTimeWillExpire() {
        owsFailDebug("NSE expired before messages could be processed")

        guard nseExpirationFlag.tryToSetFlag() else {
            exit(0)
        }

        // We complete silently here so that nothing is presented to the user.
        // By default the OS will present whatever the raw content of the original
        // notification is to the user otherwise.
        completeSilenty(timeHasExpired: true)

        nseExpirationFlag.set(false)
    }

    func fetchAndProcessMessages() {
        AssertIsOnMainThread()

        guard !AppExpiry.shared.isExpired else {
            owsFailDebug("Not processing notifications for expired application.")
            return completeSilenty()
        }

        environment.isProcessingMessages.set(true)

        Logger.info("Beginning message fetch.")

        let fetchPromise = messageFetcherJob.run().promise
        fetchPromise.timeout(seconds: 20, description: "Message Fetch Timeout.") {
            NotificationServiceError.timeout
        }.catch { _ in
            // Do nothing, Promise.timeout() will log timeouts.
        }
        fetchPromise.then { [weak self] () -> Promise<Void> in
            Logger.info("Waiting for processing to complete.")
            guard let self = self else { return Promise.value(()) }
            let processingCompletePromise = self.messageProcessor.processingCompletePromise()
            processingCompletePromise.timeout(seconds: 20, description: "Message Processing Timeout.") {
                NotificationServiceError.timeout
            }.catch { _ in
                // Do nothing, Promise.timeout() will log timeouts.
            }
            return processingCompletePromise
        }.ensure { [weak self] in
            Logger.info("Message fetch completed.")
            environment.isProcessingMessages.set(false)
            self?.completeSilenty()
        }.catch { error in
            Logger.warn("Error: \(error)")
        }
    }

    private enum NotificationServiceError: Error {
        case timeout
    }
}
