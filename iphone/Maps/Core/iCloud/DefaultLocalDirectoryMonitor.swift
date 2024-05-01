enum DirectoryMonitorState: CaseIterable, Equatable {
  case started
  case stopped
  case paused
}

protocol DirectoryMonitor: AnyObject {
  var state: DirectoryMonitorState { get }

  func start(completion: VoidResultCompletionHandler?)
  func stop()
  func pause()
  func resume()
}

protocol LocalDirectoryMonitor: DirectoryMonitor {
  var fileManager: FileManager { get }
  var directory: URL { get }
  var delegate: LocalDirectoryMonitorDelegate? { get set }
}

protocol LocalDirectoryMonitorDelegate : AnyObject {
  func didFinishGathering(contents: LocalContents)
  func didUpdate(contents: LocalContents)
  func didReceiveLocalMonitorError(_ error: Error)
}

final class DefaultLocalDirectoryMonitor: LocalDirectoryMonitor {

  typealias Delegate = LocalDirectoryMonitorDelegate

  fileprivate enum DispatchSourceDebounceState {
    case stopped
    case started(dirSource: DispatchSourceFileSystemObject)
    case debounce(dirSource: DispatchSourceFileSystemObject, timer: Timer)
  }

  let fileManager: FileManager
  private let resourceKeys: [URLResourceKey] = [.nameKey]
  private var dispatchSource: DispatchSourceFileSystemObject?
  private var dispatchSourceDebounceState: DispatchSourceDebounceState = .stopped
  private var dispatchSourceIsSuspended = false
  private var dispatchSourceIsResumed = false
  private var didFinishGatheringIsCalled = false

  // MARK: - Public properties
  let directory: URL
  private(set) var state: DirectoryMonitorState = .stopped
  weak var delegate: Delegate?

  init(fileManager: FileManager, directory: URL) {
    self.fileManager = fileManager
    self.directory = directory
  }

  // MARK: - Public methods
  func start(completion: VoidResultCompletionHandler? = nil) {
    guard state != .started else { return }

    let nowTimer = Timer.scheduledTimer(withTimeInterval: .zero, repeats: false) { [weak self] _ in
      LOG(.debug, "LocalMonitor: Initial timer firing...")
      self?.debounceTimerDidFire()
    }

    if let dispatchSource {
      dispatchSourceDebounceState = .debounce(dirSource: dispatchSource, timer: nowTimer)
      resume()
      completion?(.success)
      return
    }

    do {
      let directorySource = try fileManager.source(for: directory)
      directorySource.setEventHandler { [weak self] in
        self?.queueDidFire()
      }
      dispatchSourceDebounceState = .debounce(dirSource: directorySource, timer: nowTimer)
      directorySource.activate()
      dispatchSource = directorySource
      state = .started
      completion?(.success)
    } catch {
      stop()
      completion?(.failure(error))
    }
  }

  func stop() {
    guard state == .started else { return }
    LOG(.debug, "LocalMonitor: Stop.")
    suspendDispatchSource()
    didFinishGatheringIsCalled = false
    dispatchSourceDebounceState = .stopped
    state = .stopped
  }

  func pause() {
    guard state == .started else { return }
    LOG(.debug, "LocalMonitor: Pause.")
    suspendDispatchSource()
    state = .paused
  }

  func resume() {
    guard state != .started else { return }
    LOG(.debug, "LocalMonitor: Resume.")
    resumeDispatchSource()
    state = .started
  }

  // MARK: - Private
  private func queueDidFire() {
    LOG(.debug, "LocalMonitor: Queue did fire.")
    let debounceTimeInterval = 0.2
    switch dispatchSourceDebounceState {
    case .started(let directorySource):
      let timer = Timer.scheduledTimer(withTimeInterval: debounceTimeInterval, repeats: false) { [weak self] _ in
        self?.debounceTimerDidFire()
      }
      dispatchSourceDebounceState = .debounce(dirSource: directorySource, timer: timer)
    case .debounce(_, let timer):
      timer.fireDate = Date(timeIntervalSinceNow: debounceTimeInterval)
      // Stay in the `.debounce` state.
    case .stopped:
      // This can happen if the read source fired and enqueued a block on the
      // main queue but, before the main queue got to service that block, someone
      // called `stop()`.  The correct response is to just do nothing.
      break
    }
  }

  private func debounceTimerDidFire() {
    LOG(.debug, "LocalMonitor: Debounce timer did fire.")
    guard state == .started else { return }
    guard case .debounce(let dirSource, let timer) = dispatchSourceDebounceState else { fatalError() }
    timer.invalidate()
    dispatchSourceDebounceState = .started(dirSource: dirSource)

    do {
      let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles])
      let contentMetadataItems = LocalContents(contents.compactMap { url in
        do {
          let metadataItem = try LocalMetadataItem(fileUrl: url)
          return metadataItem
        } catch {
          delegate?.didReceiveLocalMonitorError(error)
          return nil
        }
      })

      if !didFinishGatheringIsCalled {
        didFinishGatheringIsCalled = true
        LOG(.debug, "LocalMonitor: didFinishGathering called.")
        LOG(.debug, "LocalMonitor: contentMetadataItems count: \(contentMetadataItems.count)")
        delegate?.didFinishGathering(contents: contentMetadataItems)
      } else {
        LOG(.debug, "LocalMonitor: didUpdate called.")
        LOG(.debug, "LocalMonitor: contentMetadataItems count: \(contentMetadataItems.count)")
        delegate?.didUpdate(contents: contentMetadataItems)
      }
    } catch {
      fatalError("Error while reading directory: \(error)")
    }
  }

  private func suspendDispatchSource() {
    if !dispatchSourceIsSuspended {
      LOG(.debug, "LocalMonitor: Suspend dispatch source.")
      dispatchSource?.suspend()
      dispatchSourceIsSuspended = true
      dispatchSourceIsResumed = false
    }
  }

  private func resumeDispatchSource() {
    if !dispatchSourceIsResumed {
      LOG(.debug, "LocalMonitor: Resume dispatch source.")
      dispatchSource?.resume()
      dispatchSourceIsResumed = true
      dispatchSourceIsSuspended = false
    }
  }
}

private extension DefaultLocalDirectoryMonitor.DispatchSourceDebounceState {
  var isRunning: Bool {
    switch self {
    case .stopped: return false
    case .started: return true
    case .debounce: return true
    }
  }
}

private extension FileManager {
  func source(for directory: URL) throws -> DispatchSourceFileSystemObject {
    if !fileExists(atPath: directory.path) {
      do {
        try createDirectory(at: directory, withIntermediateDirectories: true)
      } catch {
        throw error
      }
    }
    let directoryFileDescriptor = open(directory.path, O_EVTONLY)
    guard directoryFileDescriptor >= 0 else {
      let errorCode = errno
      throw NSError(domain: POSIXError.errorDomain, code: Int(errorCode), userInfo: nil)
    }
    let dispatchSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: directoryFileDescriptor, eventMask: [.write], queue: DispatchQueue.main)
    dispatchSource.setCancelHandler {
      close(directoryFileDescriptor)
    }
    return dispatchSource
  }
}
