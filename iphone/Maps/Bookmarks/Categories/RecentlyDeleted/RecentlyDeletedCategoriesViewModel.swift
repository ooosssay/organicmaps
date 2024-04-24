struct RecentlyDeletedCategory: Equatable {
  let fileName: String
  let fileURL: URL
  let deletionDate: TimeInterval
}

final class RecentlyDeletedCategoriesViewModel {

  enum Section: CaseIterable {
    struct Model: Equatable {
      let title: String
      var categories: [RecentlyDeletedCategory]
    }

    case onDevice
    case iCloud
  }

  enum State {
    case normal
    case searching
    case editingAndNothingSelected
    case editingAndSomeSelected
  }

  private var bookmarksManager: any RecentlyDeletedCategoriesManager
  private(set) var selectedIndexPaths: [IndexPath] = []
  private var dataSource: [Section.Model] = [] {
    didSet {
      filteredDataSource = dataSource
    }
  }
  private(set) var filteredDataSource: [Section.Model] = [] {
    didSet {
      guard oldValue != filteredDataSource else { return }
      filteredDataSourceDidChange?(filteredDataSource)
    }
  }
  private(set) var state: State = .normal
  var stateDidChange: ((State) -> Void)?
  var filteredDataSourceDidChange: (([Section.Model]) -> Void)?

  init(bookmarksManager: RecentlyDeletedCategoriesManager = BookmarksManager.shared()) {
    self.bookmarksManager = bookmarksManager
    fetchRecentlyDeletedCategories()
  }

  func fetchRecentlyDeletedCategories() {
    dataSource.removeAll()
    Section.allCases.forEach {
      let content = getContentForSection($0)
      guard !content.categories.isEmpty else { return }
      dataSource.append(content)
    }
    filteredDataSource = dataSource
  }

  private func getContentForSection(_ section: Section) -> Section.Model {
    let categories: [RecentlyDeletedCategory]
    switch section {
    case .onDevice:
      let recentlyDeletedCategoryURLs = bookmarksManager.getRecentlyDeletedCategories()
      categories = recentlyDeletedCategoryURLs.map { fileUrl in
        let fileName = fileUrl.lastPathComponent
        // TODO: remove this code with cpp
        let deletionDate = (try! fileUrl.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date()).timeIntervalSince1970
        return RecentlyDeletedCategory(fileName: fileName, fileURL: fileUrl, deletionDate: deletionDate)
      }
    case .iCloud:
      categories = []
    }
    return Section.Model(title: section.title, categories: categories)
  }

  private func updateSelectionAtIndexPath(_ indexPath: IndexPath, isSelected: Bool) {
    if isSelected {
      updateState(to: .editingAndSomeSelected)
    } else {
      let allDeselected = dataSource.allSatisfy { $0.categories.isEmpty }
      updateState(to: allDeselected ? .editingAndNothingSelected : .editingAndSomeSelected)
    }
  }

  private func removeCategories(at indexPaths: [IndexPath], completion: ([URL]) -> Void) {
    guard !indexPaths.isEmpty else {
      completion(dataSource.flatMap { $0.categories.map { $0.fileURL } })
      dataSource.removeAll()
      return
    }

    var fileToRemoveURLs = [URL]()
    var updatedDataSource = dataSource
    indexPaths.forEach { [weak self] indexPath in
      guard let self, indexPath.section < self.filteredDataSource.count, indexPath.row < self.filteredDataSource[indexPath.section].categories.count else { return }
      let fileToRemoveURL = self.filteredDataSource[indexPath.section].categories[indexPath.row].fileURL
      updatedDataSource[indexPath.section].categories.removeAll { $0.fileURL == fileToRemoveURL }
      fileToRemoveURLs.append(fileToRemoveURL)
    }
    dataSource = updatedDataSource
    updateState(to: selectedIndexPaths.isEmpty ? .normal : .editingAndSomeSelected)
    completion(fileToRemoveURLs)
  }

  private func removeSelectedCategories(completion: ([URL]) -> Void) {
    let removeAll = selectedIndexPaths.isEmpty || selectedIndexPaths.count == dataSource.flatMap({ $0.categories }).count
    removeCategories(at: removeAll ? [] : selectedIndexPaths, completion: completion)
    selectedIndexPaths.removeAll()
    updateState(to: .normal)
  }

  private func updateState(to newState: State) {
    if state != newState {
      state = newState
      stateDidChange?(state)
    }
  }
}

extension RecentlyDeletedCategoriesViewModel {
  func deleteCategory(at indexPath: IndexPath) {
    removeCategories(at: [indexPath]) { bookmarksManager.deleteRecentlyDeletedCategory(at: $0) }
  }

  func deleteSelectedCategories() {
    removeSelectedCategories { bookmarksManager.deleteRecentlyDeletedCategory(at: $0) }
  }

  func recoverCategory(at indexPath: IndexPath) {
    removeCategories(at: [indexPath]) { bookmarksManager.recoverRecentlyDeletedCategories(at: $0) }
  }

  func recoverSelectedCategories() {
    removeSelectedCategories { bookmarksManager.recoverRecentlyDeletedCategories(at: $0) }
  }

  func selectCategory(at indexPath: IndexPath) {
    selectedIndexPaths.append(indexPath)
    updateState(to: .editingAndSomeSelected)
  }

  func deselectCategory(at indexPath: IndexPath) {
    selectedIndexPaths.removeAll { $0 == indexPath }
    if selectedIndexPaths.isEmpty {
      updateState(to: .editingAndNothingSelected)
    }
  }

  func selectAllCategories() {
    selectedIndexPaths = dataSource.enumerated().flatMap { sectionIndex, section in
      section.categories.indices.map { IndexPath(row: $0, section: sectionIndex) }
    }
    updateState(to: .editingAndSomeSelected)
  }

  func deselectAllCategories() {
    selectedIndexPaths.removeAll()
    updateState(to: .editingAndNothingSelected)
  }

  func startSearching() {
    updateState(to: .searching)
  }

  func cancelSearching() {
    selectedIndexPaths.removeAll()
    filteredDataSource = dataSource
    updateState(to: .normal)
  }

  func startSelecting() {
    updateState(to: .editingAndNothingSelected)
  }

  func cancelSelecting() {
    selectedIndexPaths.removeAll()
    updateState(to: .normal)
  }

  func search(_ searchText: String) {
    updateState(to: .searching)
    guard !searchText.isEmpty else {
      filteredDataSource = dataSource
      return
    }
    let filteredCategories = dataSource.map { section in
      let filteredCategories = section.categories.filter { $0.fileName.localizedCaseInsensitiveContains(searchText) }
      return Section.Model(title: section.title, categories: filteredCategories)
    }
    filteredDataSource = filteredCategories.filter { !$0.categories.isEmpty }
  }
}

// TODO: localize
private extension RecentlyDeletedCategoriesViewModel.Section {
  var title: String {
    switch self {
    case .onDevice:
      return L("on_device")
    case .iCloud:
      return L("iCloud")
    }
  }
}
