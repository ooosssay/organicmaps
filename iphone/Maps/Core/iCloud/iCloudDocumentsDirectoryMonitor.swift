protocol CloudDirectoryMonitor: DirectoryMonitor {
  var fileManager: FileManager { get }
  var delegate: CloudDirectoryMonitorDelegate? { get set }
  
  func fetchUbiquityDirectoryUrl(completion: ((Result<URL, SynchronizationError>) -> Void)?)
  func isCloudAvailable() -> Bool
}

protocol CloudDirectoryMonitorDelegate : AnyObject {
  func didFinishGathering(contents: CloudContents)
  func didUpdate(contents: CloudContents)
  func didReceiveCloudMonitorError(_ error: Error)
}

private let kUDCloudIdentityKey = "com.apple.organicmaps.UbiquityIdentityToken"
private let kDocumentsDirectoryName = "Documents"

class iCloudDocumentsDirectoryMonitor: NSObject, CloudDirectoryMonitor {

  static let sharedContainerIdentifier: String = {
    var identifier = "iCloud.app.organicmaps"
    #if DEBUG
    identifier.append(".debug")
    #endif
    return identifier
  }()

  let containerIdentifier: String
  let fileManager: FileManager
  private let fileType: FileType // TODO: Should be removed when the nested directory support will be implemented
  private(set) var metadataQuery: NSMetadataQuery?
  private(set) var ubiquitousDocumentsDirectory: URL?

  // MARK: - Public properties
  var isStarted: Bool { return metadataQuery?.isStarted ?? false }
  private(set) var isPaused: Bool = true
  weak var delegate: CloudDirectoryMonitorDelegate?

  init(fileManager: FileManager = .default, cloudContainerIdentifier: String = iCloudDocumentsDirectoryMonitor.sharedContainerIdentifier, fileType: FileType) {
    self.fileManager = fileManager
    self.containerIdentifier = cloudContainerIdentifier
    self.fileType = fileType
    super.init()

    fetchUbiquityDirectoryUrl()
    subscribeOnMetadataQueryNotifications()
    subscribeOnCloudAvailabilityNotifications()
  }

  // MARK: - Public methods
  func start(completion: VoidResultCompletionHandler? = nil) {
    guard isCloudAvailable() else {
      completion?(.failure(SynchronizationError.iCloudIsNotAvailable))
      return
    }
    fetchUbiquityDirectoryUrl { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion?(.failure(error))
      case .success:
        self.startQuery()
        completion?(.success)
      }
    }
  }

  func stop() {
    stopQuery()
  }

  func resume() {
    metadataQuery?.enableUpdates()
    isPaused = false
  }

  func pause() {
    metadataQuery?.disableUpdates()
    isPaused = true
  }

  func fetchUbiquityDirectoryUrl(completion: ((Result<URL, SynchronizationError>) -> Void)? = nil) {
    if let ubiquitousDocumentsDirectory {
      completion?(.success(ubiquitousDocumentsDirectory))
      return
    }
    DispatchQueue.global().async {
      guard let containerUrl = self.fileManager.url(forUbiquityContainerIdentifier: self.containerIdentifier) else {
        LOG(.debug, "Failed to retrieve container's URL for:\(self.containerIdentifier)")
        completion?(.failure(.containerNotFound))
        return
      }
      let documentsContainerUrl = containerUrl.appendingPathComponent(kDocumentsDirectoryName)
      if !self.fileManager.fileExists(atPath: documentsContainerUrl.path) {
        do {
          try self.fileManager.createDirectory(at: documentsContainerUrl, withIntermediateDirectories: true)
        } catch {
          completion?(.failure(.containerNotFound))
        }
      }
      self.ubiquitousDocumentsDirectory = documentsContainerUrl
      completion?(.success(documentsContainerUrl))
    }
  }
  
  func isCloudAvailable() -> Bool {
    let cloudToken = fileManager.ubiquityIdentityToken
    guard let cloudToken else {
      UserDefaults.standard.removeObject(forKey: kUDCloudIdentityKey)
      LOG(.debug, "Cloud is not available. Cloud token is nil.")
      return false
    }
    do {
      let data = try NSKeyedArchiver.archivedData(withRootObject: cloudToken, requiringSecureCoding: true)
      UserDefaults.standard.set(data, forKey: kUDCloudIdentityKey)
      return true
    } catch {
      UserDefaults.standard.removeObject(forKey: kUDCloudIdentityKey)
      LOG(.debug, "Failed to archive cloud token: \(error)")
      return false
    }
  }

  class func buildMetadataQuery(for fileType: FileType) -> NSMetadataQuery {
    let metadataQuery = NSMetadataQuery()
    metadataQuery.notificationBatchingInterval = 1
    metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
    metadataQuery.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.\(fileType.fileExtension)")
    metadataQuery.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]
    return metadataQuery
  }

  class func getContentsFromNotification(_ notification: Notification, _ onError: (Error) -> Void) -> CloudContents {
    guard let metadataQuery = notification.object as? NSMetadataQuery,
          let metadataItems = metadataQuery.results as? [NSMetadataItem] else {
      return []
    }

    let cloudMetadataItems = CloudContents(metadataItems.compactMap { item in
      do {
        return try CloudMetadataItem(metadataItem: item)
      } catch {
        onError(error)
        return nil
      }
    })
    return cloudMetadataItems
  }

  // There are no ways to retrieve the content of iCloud's .Trash directory on the macOS because it uses different file system and place trashed content in the /Users/<user_name>/.Trash which cannot be observed without access.
  // When we get a new notification and retrieve the metadata from the object the actual list of items in iOS contains both current and deleted files (which is in .Trash/ directory now) but on macOS we only have absence of the file. So there are no way to get list of deleted items on macOS on didFinishGathering state.
  // Due to didUpdate state we can get the list of deleted items on macOS from the userInfo property but cannot get their new url.
  class func getTrashContentsFromNotification(_ notification: Notification, _ onError: (Error) -> Void) -> CloudContents {
    guard let removedItems = notification.userInfo?[NSMetadataQueryUpdateRemovedItemsKey] as? [NSMetadataItem] else { return [] }
    return CloudContents(removedItems.compactMap { metadataItem in
      do {
        var item = try CloudMetadataItem(metadataItem: metadataItem)
        // on macOS deleted file will not be in the ./Trash directory, but it doesn't mean that it is not removed because it is placed in the NSMetadataQueryUpdateRemovedItems array.
        item.isRemoved = true
        return item
      } catch {
        onError(error)
        return nil
      }
    })
  }

  class func getTrashedContentsFromTrashDirectory(fileManager: FileManager, ubiquitousDocumentsDirectory: URL?, onError: (Error) -> Void) -> CloudContents {
    // There are no ways to retrieve the content of iCloud's .Trash directory on macOS.
    if #available(iOS 14.0, *), ProcessInfo.processInfo.isiOSAppOnMac {
      return []
    }
    // On iOS we can get the list of deleted items from the .Trash directory but only when iCloud is enabled.
    guard let ubiquitousDocumentsDirectory,
          let trashDirectoryUrl = try? fileManager.trashDirectoryUrl(for: ubiquitousDocumentsDirectory),
          let removedItems = try? fileManager.contentsOfDirectory(at: trashDirectoryUrl,
                                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsPackageDescendants, .skipsSubdirectoryDescendants]) else {
      return []
    }
    let removedCloudMetadataItems = CloudContents(removedItems.compactMap { url in
      do {
        var item = try CloudMetadataItem(fileUrl: url)
        item.isRemoved = true
        return item
      } catch {
        onError(error)
        return nil
      }
    })
    return removedCloudMetadataItems
  }
}

// MARK: - Private
private extension iCloudDocumentsDirectoryMonitor {

  func subscribeOnCloudAvailabilityNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(cloudAvailabilityChanged(_:)), name: .NSUbiquityIdentityDidChange, object: nil)
  }

  // TODO: - Actually this notification was never called. If user disable the iCloud for the current app during the active state the app will be relaunched. Needs to investigate additional cases when this notification can be sent.
  @objc func cloudAvailabilityChanged(_ notification: Notification) {
    LOG(.debug, "Cloud availability changed to : \(isCloudAvailable())")
    isCloudAvailable() ? startQuery() : stopQuery()
  }

  // MARK: - MetadataQuery
  func subscribeOnMetadataQueryNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(queryDidFinishGathering(_:)), name: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(queryDidUpdate(_:)), name: NSNotification.Name.NSMetadataQueryDidUpdate, object: nil)
  }

  func startQuery() {
    metadataQuery = Self.buildMetadataQuery(for: fileType)
    guard let metadataQuery, !metadataQuery.isStarted else { return }
    metadataQuery.start()
    isPaused = false
  }

  func stopQuery() {
    metadataQuery?.stop()
    metadataQuery = nil
    isPaused = true
  }

  @objc func queryDidFinishGathering(_ notification: Notification) {
    guard isCloudAvailable() else { return }
    pause()
    let contents = Self.getContentsFromNotification(notification, metadataQueryErrorHandler)
    let trashedContents = Self.getTrashedContentsFromTrashDirectory(fileManager: fileManager,
                                                                   ubiquitousDocumentsDirectory: ubiquitousDocumentsDirectory,
                                                                   onError: metadataQueryErrorHandler)
    delegate?.didFinishGathering(contents: contents + trashedContents)
    resume()
  }

  @objc func queryDidUpdate(_ notification: Notification) {
    guard isCloudAvailable() else { return }
    pause()
    let contents = Self.getContentsFromNotification(notification, metadataQueryErrorHandler)
    let trashedContents = Self.getTrashContentsFromNotification(notification, metadataQueryErrorHandler)
    delegate?.didUpdate(contents: contents + trashedContents)
    resume()
  }

  private var metadataQueryErrorHandler: (Error) -> Void {
    { [weak self] error in
      self?.delegate?.didReceiveCloudMonitorError(error)
    }
  }
}
