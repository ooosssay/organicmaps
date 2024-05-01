import XCTest
@testable import Organic_Maps__Debug_

final class DefaultLocalDirectoryMonitorTests: XCTestCase {

  let fileManager = FileManager.default
  let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  var directoryMonitor: DefaultLocalDirectoryMonitor!
  var mockDelegate: LocalDirectoryMonitorDelegateMock!

  override func setUp() {
    super.setUp()
    // Setup with a temporary directory and a mock delegate
    directoryMonitor = DefaultLocalDirectoryMonitor(fileManager: fileManager, directory: tempDirectory)
    mockDelegate = LocalDirectoryMonitorDelegateMock()
    directoryMonitor.delegate = mockDelegate
  }

  override func tearDown() {
    directoryMonitor.stop()
    mockDelegate = nil
    try? fileManager.removeItem(at: tempDirectory)
    super.tearDown()
  }

  func testInitialization() {
    XCTAssertEqual(directoryMonitor.directory, tempDirectory, "Monitor initialized with incorrect directory.")
    XCTAssertTrue(directoryMonitor.state == .stopped, "Monitor should be stopped initially.")
  }

  func testStartMonitoring() {
    let startExpectation = expectation(description: "Start monitoring")
    directoryMonitor.start { result in
      switch result {
      case .success:
        XCTAssertTrue(self.directoryMonitor.state == .started, "Monitor should be started.")
      case .failure(let error):
        XCTFail("Monitoring failed to start with error: \(error)")
      }
      startExpectation.fulfill()
    }
    wait(for: [startExpectation], timeout: 5.0)
  }

  func testStopMonitoring() {
    directoryMonitor.start()
    directoryMonitor.stop()
    XCTAssertTrue(directoryMonitor.state == .stopped, "Monitor should be stopped.")
  }

  func testPauseAndResumeMonitoring() {
    directoryMonitor.start()
    directoryMonitor.pause()
    XCTAssertTrue(directoryMonitor.state == .paused, "Monitor should be paused.")

    directoryMonitor.resume()
    XCTAssertTrue(directoryMonitor.state == .started, "Monitor should be started.")
  }

  func testDelegateDidFinishGathering() {
    mockDelegate.didFinishGatheringExpectation = expectation(description: "didFinishGathering called")
    directoryMonitor.start()
    wait(for: [mockDelegate.didFinishGatheringExpectation!], timeout: 5.0)
  }

  func testDelegateDidReceiveError() {
    mockDelegate.didReceiveErrorExpectation = expectation(description: "didReceiveLocalMonitorError called")

    let error = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: nil)
    directoryMonitor.delegate?.didReceiveLocalMonitorError(error)

    wait(for: [mockDelegate.didReceiveErrorExpectation!], timeout: 1.0)
  }

  func testContentUpdateDetection() {
    let startExpectation = expectation(description: "Start monitoring")
    let didFinishGatheringExpectation = expectation(description: "didFinishGathering called")
    let didUpdateExpectation = expectation(description: "didUpdate called")

    mockDelegate.didFinishGatheringExpectation = didFinishGatheringExpectation
    mockDelegate.didUpdateExpectation = didUpdateExpectation

    directoryMonitor.start { result in
      if case .success = result {
        XCTAssertTrue(self.directoryMonitor.state == .started, "Monitor should be started.")
      }
      startExpectation.fulfill()
    }

    wait(for: [startExpectation], timeout: 5)

    let fileURL = tempDirectory.appendingPathComponent("test.kml")
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      self.fileManager.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)
    }

    wait(for: [didFinishGatheringExpectation, didUpdateExpectation], timeout: 20)
  }
}
