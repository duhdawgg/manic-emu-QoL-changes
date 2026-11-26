//
//  MetadataMonitor.swift
//  
//
//  Created by Drew McCormack on 10/06/2022.
//

import Foundation
import os

/// Monitors changes to the metadata, to trigger downloads of new files or updates.
///
/// This is opt-in via `CloudDrive.Options.downloadsAllFilesAutomatically`, because it
/// materializes every file below the root onto the device. Apps holding large payloads
/// should leave it off and pull individual files with `CloudDrive.ensureDownloaded(at:)`.
final class MetadataMonitor: @unchecked Sendable {
 
    let rootDirectory: URL
    let fileManager: FileManager = .init()

    /// Query callbacks read ubiquitous attributes, which can block on the iCloud
    /// daemon, so they must stay off the main run loop.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "SwiftCloudDrive.MetadataMonitor"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    private var metadataQuery: NSMetadataQuery?
    
    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: metadataQuery)
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: metadataQuery)
        
        nonisolated(unsafe) let query = metadataQuery
        Task { @MainActor in
            guard let query else { return }
            query.disableUpdates()
            query.stop()
        }
    }
    
    func startMonitoringMetadata() {
        // Predicate that queries which files are in the cloud, not local, and need to begin downloading
        let predicate: NSPredicate = NSPredicate(format: "%K = %@ AND %K = FALSE AND %K BEGINSWITH %@", NSMetadataUbiquitousItemDownloadingStatusKey, NSMetadataUbiquitousItemDownloadingStatusNotDownloaded, NSMetadataUbiquitousItemIsDownloadingKey, NSMetadataItemPathKey, rootDirectory.path)
        
        let query = NSMetadataQuery()
        query.notificationBatchingInterval = 3.0
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope, NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = predicate
        query.operationQueue = queue
        metadataQuery = query

        NotificationCenter.default.addObserver(self, selector: #selector(handleGatheringNotification(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(handleUpdateNotification(_:)), name: .NSMetadataQueryDidUpdate, object: query)

        nonisolated(unsafe) let queryToStart = query
        Task { @MainActor in
            queryToStart.start()
        }
    }

    /// The initial gather is the only point where the whole result set is new to us.
    @objc private func handleGatheringNotification(_ notif: Notification) {
        guard let metadataQuery else { return }
        metadataQuery.disableUpdates()
        let items = (metadataQuery.results as? [NSMetadataItem]) ?? []
        metadataQuery.enableUpdates()
        startDownloads(for: items)
    }

    /// Only act on items the query reports as added or changed. Re-walking the whole
    /// result set on every update re-requests downloads for the same files indefinitely,
    /// which floods the iCloud daemon.
    @objc private func handleUpdateNotification(_ notif: Notification) {
        guard let userInfo = notif.userInfo else { return }
        var items: [NSMetadataItem] = []
        for key in [NSMetadataQueryUpdateAddedItemsKey, NSMetadataQueryUpdateChangedItemsKey] {
            if let changed = userInfo[key] as? [NSMetadataItem] {
                items.append(contentsOf: changed)
            }
        }
        startDownloads(for: items)
    }

    private func startDownloads(for items: [NSMetadataItem]) {
        guard !items.isEmpty else { return }
        for item in items {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            do {
                try fileManager.startDownloadingUbiquitousItem(at: url)
            } catch {
                os_log("Failed to start downloading file")
            }
        }
    }
    
}
