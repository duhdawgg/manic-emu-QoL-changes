import Foundation
import os

public protocol CloudDriveObserver {
    /// Called when the status of files changes in the drive
    func cloudDriveDidChange(_ cloudDrive: CloudDrive, rootRelativePaths: [RootRelativePath])
}

public protocol CloudDriveConflictResolver {
    /// Called if you want to manually handle file conflicts. When you return, the file conflict shoud be resolved,
    /// so that NSFileVersion.isConflict is false.
    func cloudDrive(_ cloudDrive: CloudDrive, resolveConflictAt path: RootRelativePath)
}

/// Easy to use Swift wrapper around iCloud Drive.
/// By default the drive downloads nothing on its own: use `ensureDownloaded(at:)` to pull
/// the files you actually need. Set `Options.downloadsAllFilesAutomatically` to get the
/// greedy behaviour, where every file below the root is materialized as soon as it appears
/// in iCloud. Greedy mode is only appropriate for small payloads.
public final class CloudDrive: @unchecked Sendable {
    
    /// Types of storage available
    public enum Storage {
        case iCloudContainer(containerIdentifier: String?)
        case localDirectory(rootURL: URL)
    }

    /// Tuning for how the drive interacts with iCloud.
    public struct Options: Sendable {
        /// When true, every file below the root is downloaded as soon as iCloud reports it.
        /// Leave false for large payloads (media, disk images) and pull individual files
        /// with `ensureDownloaded(at:)`, otherwise the whole container lands on the device.
        public var downloadsAllFilesAutomatically: Bool

        public init(downloadsAllFilesAutomatically: Bool = false) {
            self.downloadsAllFilesAutomatically = downloadsAllFilesAutomatically
        }

        public static let `default` = Options()
    }

    /// Whether the item's bytes are on this device.
    public enum DownloadState: Sendable {
        /// Local and up to date with iCloud.
        case current
        /// Local, but iCloud holds a newer version.
        case outdated
        /// Not on this device.
        case absent
    }

    /// The options this drive was created with
    public let options: Options
    
    /// The type of storage used (eg iCloud, local)
    public let storage: Storage
            
    /// Pass in nil to get the default container. Eg. "iCloud.my.company.app"
    public var ubiquityContainerIdentifier: String? {
        if case let .iCloudContainer(id) = storage {
            return id
        } else {
            return nil
        }
    }
    
    /// The path of the directory for this drive, relative to the root of the iCloud container
    @available(*, deprecated, renamed: "relativePathToRoot")
    public var relativePathToRootInContainer: String {
        relativePathToRoot
    }
    
    /// The path of the directory for this drive, relative to the root of the drive
    public let relativePathToRoot: String
    
    /// Set this to receive notification of changes in the cloud drive. 
    public var observer: CloudDriveObserver?
    
    /// Optional conflict resolution. If not set, the most recent version wins, and others
    /// are deleted.
    public var conflictResolver: CloudDriveConflictResolver?
    
    /// If the user is signed in to iCloud, this should be true. Otherwise false.
    /// When iCloud is not used, it is always true
    public var isConnected: Bool {
        switch storage {
        case .iCloudContainer:
            return FileManager.default.ubiquityIdentityToken != nil
        case .localDirectory:
            return true
        }
    }

    private let metadataMonitor: MetadataMonitor?
    private let fileMonitor: FileMonitor
    public let rootDirectory: URL
    
    
    // MARK: Init
    
    /// Pass in the type of storage (eg iCloud container), and an optional path relative to the root directory where
    /// the drive will be anchored.
    public init(storage: Storage, relativePathToRoot: String = "", options: Options = .default) async throws {
        self.storage = storage
        self.relativePathToRoot = relativePathToRoot
        self.options = options
        
        let fileManager = FileManager.default
        switch storage {
        case let .iCloudContainer(containerIdentifier):
            guard fileManager.ubiquityIdentityToken != nil else { throw Error.notSignedIntoCloud }
            guard let containerURL = fileManager.url(forUbiquityContainerIdentifier: containerIdentifier) else {
                throw Error.couldNotAccessUbiquityContainer
            }
            let url = relativePathToRoot.isEmpty ? containerURL : containerURL.appendingPathComponent(relativePathToRoot, isDirectory: true)
            self.rootDirectory = url.standardizedFileURL
            self.metadataMonitor = options.downloadsAllFilesAutomatically ? MetadataMonitor(rootDirectory: self.rootDirectory) : nil
        case let .localDirectory(rootURL):
            let url = relativePathToRoot.isEmpty ? rootURL : URL(fileURLWithPath: relativePathToRoot, isDirectory: true, relativeTo: rootURL)
            self.rootDirectory = url.standardizedFileURL
            try fileManager.createDirectory(atPath: self.rootDirectory.path, withIntermediateDirectories: true)
            self.metadataMonitor = nil
        }
        
        // Use the FileMonitor even for non-ubiquitious files
        let monitor = FileMonitor(rootDirectory: self.rootDirectory)
        self.fileMonitor = monitor
        monitor.changeHandler = { [weak self] changedPaths in
            guard let self, let observer = self.observer else { return }
            observer.cloudDriveDidChange(self, rootRelativePaths: changedPaths)
        }
        monitor.conflictHandler = { [weak self] rootRelativePath in
            guard let self, let resolver = self.conflictResolver else { return false }
            resolver.cloudDrive(self, resolveConflictAt: rootRelativePath)
            return true
        }

        try await performInitialSetup()
    }
    
    /// Pass in the container id, but also an optional root direcotry. All relative paths will then be relative to this root.
    public convenience init(ubiquityContainerIdentifier: String? = nil, relativePathToRootInContainer: String = "", options: Options = .default) async throws {
        try await self.init(storage: .iCloudContainer(containerIdentifier: ubiquityContainerIdentifier), relativePathToRoot: relativePathToRootInContainer, options: options)
    }
    
    
    // MARK: Setup

    private func performInitialSetup() async throws {
        try await setupRootDirectory()
        metadataMonitor?.startMonitoringMetadata()
        fileMonitor.startMonitoring()
    }
    
    private func setupRootDirectory() async throws {
        let coordinatedFileManager = CoordinatedFileManager(presenter: fileMonitor)
        let (exists, isDirectory) = try await coordinatedFileManager.fileExists(coordinatingAccessAt: rootDirectory)
        if exists {
            guard isDirectory else { throw Error.rootDirectoryURLIsNotDirectory }
        } else {
            try await coordinatedFileManager.createDirectory(coordinatingAccessAt: rootDirectory, withIntermediateDirectories: true)
        }
    }
    
    
    // MARK: File Operations
    
    /// Returns whether the file exists. If it is a directory, returns false
    public func fileExists(at path: RootRelativePath) async throws -> Bool {
        guard isConnected else { throw Error.queriedWhileNotConnected }
        let coordinatedFileManager = CoordinatedFileManager(presenter: fileMonitor)
        let fileURL = try path.fileURL(forRoot: rootDirectory)
        let result = try await coordinatedFileManager.fileExists(coordinatingAccessAt: fileURL)
        return result.exists && !result.isDirectory
    }
    
    /// Returns whether the directory exists
    public func directoryExists(at path: RootRelativePath) async throws -> Bool {
        guard isConnected else { throw Error.queriedWhileNotConnected }
        let coordinatedFileManager = CoordinatedFileManager(presenter: fileMonitor)
        let dirURL = try path.directoryURL(forRoot: rootDirectory)
        let result = try await coordinatedFileManager.fileExists(coordinatingAccessAt: dirURL)
        return result.exists && result.isDirectory
    }
    
    /// Creates a directory in the cloud. Always creates intermediate directories if needed.
    public func createDirectory(at path: RootRelativePath) async throws {
        guard isConnected else { throw Error.queriedWhileNotConnected }
        let coordinatedFileManager = CoordinatedFileManager(presenter: fileMonitor)
        let dirURL = try path.directoryURL(forRoot: rootDirectory)
        return try await coordinatedFileManager.createDirectory(coordinatingAccessAt: dirURL, withIntermediateDirectories: true)
    }
    
    /// Returns the contents of a directory. It doesn't recurse into subdirectories
    public func contentsOfDirectory(at path: RootRelativePath, includingPropertiesForKeys keys: [URLResourceKey]? = nil, options mask: FileManager.DirectoryEnumerationOptions = []) async throws -> [URL] {
        guard isConnected else { throw Error.queriedWhileNotConnected }
        let coordinatedFileManager = CoordinatedFileManager(presenter: fileMonitor)
        let dirURL = try path.directoryURL(forRoot: rootDirectory)
        return try await coordinatedFileManager.contentsOfDirectory(coordinatingAccessAt: dirURL, includingPropertiesForKeys: keys, options: mask)
    }
    
    /// Removes a directory at the path passed
    public func removeDirectory(at path: RootRelativePath) async throws {
        guard isConnected else { throw Error.queriedWhileNotConnected }
        let coordinatedFileManager = CoordinatedFileManager(presenter: fileMonitor)
        let dirURL = try path.directoryURL(forRoot: rootDirectory)
        let result = try await coordinatedFileManager.fileExists(coordinatingAccessAt: dirURL)
        guard result.exists, result.isDirectory else { throw Error.invalidFileType }
        return try await coordinatedFileManager.removeItem(coordinatingAccessAt: dirURL)
    }
    
    /// Removes a file at the path passed. If there is no file, or there is a directory, it gives an error
    public func removeFile(at path: RootRelativePath) async throws {
        guard isConnected else { throw Error.queriedWhileNotConnected }
        let coordinatedFileManager = CoordinatedFileManager(presenter: fileMonitor)
        let fileURL = try path.fileURL(forRoot: rootDirectory)
        let result = try await coordinatedFileManager.fileExists(coordinatingAccessAt: fileURL)
        guard result.exists, !result.isDirectory else { throw Error.invalidFileType }
        return try await coordinatedFileManager.removeItem(coordinatingAccessAt: fileURL)
    }
    
    /// Copies a file from outside the container, into the container. If there is a file already at the destination
    /// it will give an error and fail.
    public func upload(from fromURL: URL, to path: RootRelativePath) async throws {
        guard isConnected else { throw Error.queriedWhileNotConnected }
        let coordinatedFileManager = CoordinatedFileManager(presenter: fileMonitor)
        let toURL = try path.fileURL(forRoot: rootDirectory)
        try await coordinatedFileManager.copyItem(coordinatingAccessFrom: fromURL, to: toURL)
    }
    
    /// Attempts to copy a file inside the container out to a file URL not in the cloud.
    public func download(from path: RootRelativePath, toURL: URL) async throws {
        guard isConnected else { throw Error.queriedWhileNotConnected }
        let coordinatedFileManager = CoordinatedFileManager(presenter: fileMonitor)
        let fromURL = try path.fileURL(forRoot: rootDirectory)
        try await coordinatedFileManager.copyItem(coordinatingAccessFrom: fromURL, to: toURL)
    }

    /// Copies within the container.
    public func copy(from source: RootRelativePath, to destination: RootRelativePath) async throws {
        guard isConnected else { throw Error.queriedWhileNotConnected }
        let coordinatedFileManager = CoordinatedFileManager(presenter: fileMonitor)
        let sourceURL = try source.fileURL(forRoot: rootDirectory)
        let destinationURL = try destination.fileURL(forRoot: rootDirectory)
        try await coordinatedFileManager.copyItem(coordinatingAccessFrom: sourceURL, to: destinationURL)
    }
    
    /// Reads the contents of a file in the cloud, returning it as data.
    public func readFile(at path: RootRelativePath) async throws -> Data {
        guard isConnected else { throw Error.queriedWhileNotConnected }
        let coordinatedFileManager = CoordinatedFileManager(presenter: fileMonitor)
        let fileURL = try path.fileURL(forRoot: rootDirectory)
        return try await coordinatedFileManager.contentsOfFile(coordinatingAccessAt: fileURL)
    }
    
    /// Writes the contents of a file. If the file doesn't exist, it will be created. If it already exists,
    /// it will be overwritten.
    public func writeFile(with data: Data, at path: RootRelativePath) async throws {
        guard isConnected else { throw Error.queriedWhileNotConnected }
        let coordinatedFileManager = CoordinatedFileManager(presenter: fileMonitor)
        let fileURL = try path.fileURL(forRoot: rootDirectory)
        return try await coordinatedFileManager.write(data, coordinatingAccessTo: fileURL)
    }

    /// Make any change to the file contents desired for the path given. Can be used for in-place updates.
    public func updateFile(at path: RootRelativePath, in block: @Sendable @escaping (URL) throws -> Void) async throws {
        guard isConnected else { throw Error.queriedWhileNotConnected }
        let coordinatedFileManager = CoordinatedFileManager(presenter: fileMonitor)
        let fileURL = try path.fileURL(forRoot: rootDirectory)
        try await coordinatedFileManager.updateFile(coordinatingAccessTo: fileURL) { url in
            try block(url)
        }
    }

    /// As updateFile, but coordinated for reading.
    public func readFile(at path: RootRelativePath, in block: @Sendable @escaping (URL) throws -> Void) async throws {
        guard isConnected else { throw Error.queriedWhileNotConnected }
        let coordinatedFileManager = CoordinatedFileManager(presenter: fileMonitor)
        let fileURL = try path.fileURL(forRoot: rootDirectory)
        try await coordinatedFileManager.readFile(coordinatingAccessTo: fileURL) { url in
            try block(url)
        }
    }


    // MARK: On-Demand Download

    /// Whether the file's bytes are on this device. Files that iCloud does not manage
    /// report `.current`, since their bytes are simply local.
    public func downloadState(at path: RootRelativePath) throws -> DownloadState {
        let fileURL = try path.fileURL(forRoot: rootDirectory)
        return try Self.probe(itemAt: fileURL).state
    }

    /// Asks the system to materialize a single file. Returns as soon as the request is filed.
    public func startDownloading(at path: RootRelativePath) throws {
        let fileURL = try path.fileURL(forRoot: rootDirectory)
        try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
    }

    /// Waits until the file's bytes are on this device, requesting the download if needed.
    ///
    /// Polls the one item's resource values instead of running a metadata query, so the cost
    /// is proportional to the single file the caller wants.
    ///
    /// - Parameters:
    ///   - path: File to materialize.
    ///   - stallTimeout: Give up once neither the download status nor the on-disk byte count
    ///     has advanced for this long. Active transfers keep resetting it, so large files are
    ///     not penalised for taking a while.
    public func ensureDownloaded(at path: RootRelativePath, stallTimeout: TimeInterval = 90) async throws {
        guard isConnected else { throw Error.queriedWhileNotConnected }
        let fileURL = try path.fileURL(forRoot: rootDirectory)

        var probe = try Self.probe(itemAt: fileURL)
        if probe.state == .current { return }

        try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)

        let pollInterval: TimeInterval = 0.5
        let rerequestInterval: TimeInterval = 15
        var lastState = probe.state
        var lastBytes = probe.bytesOnDisk
        var lastActivityAt = Date()
        var lastRequestedAt = Date()

        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))

            probe = try Self.probe(itemAt: fileURL)
            if probe.state == .current { return }
            if let error = probe.error { throw Error.foundationError(error) }

            let now = Date()
            if probe.bytesOnDisk > lastBytes || probe.state != lastState {
                lastBytes = probe.bytesOnDisk
                lastState = probe.state
                lastActivityAt = now
                continue
            }
            if now.timeIntervalSince(lastActivityAt) >= stallTimeout {
                // Bytes are here but iCloud never promoted them to current. Prefer using them
                // over failing; a later comparison pass picks up any newer version.
                if probe.state == .outdated { return }
                throw Error.downloadStalled
            }
            if now.timeIntervalSince(lastRequestedAt) >= rerequestInterval {
                lastRequestedAt = now
                try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
            }
        }
    }

    private static func probe(itemAt url: URL) throws -> (state: DownloadState, bytesOnDisk: Int, error: NSError?) {
        // URL caches resource values, so each poll needs a fresh copy.
        var probeURL = url
        probeURL.removeAllCachedResourceValues()
        let values = try probeURL.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemDownloadingErrorKey,
            .totalFileAllocatedSizeKey
        ])
        let bytes = values.totalFileAllocatedSize ?? 0
        let error = values.ubiquitousItemDownloadingError
        // No status means iCloud does not manage this item, so its bytes are simply local.
        guard let status = values.ubiquitousItemDownloadingStatus else {
            return (.current, bytes, error)
        }
        if status == .current {
            return (.current, bytes, error)
        }
        if status == .downloaded {
            return (.outdated, bytes, error)
        }
        return (.absent, bytes, error)
    }
}
