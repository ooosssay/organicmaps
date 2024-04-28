class MockRecentlyDeletedCategoriesManager: NSObject, RecentlyDeletedCategoriesManager {
  var categories = [RecentlyDeletedCategory]()

  func getRecentlyDeletedCategories() -> [URL] {
    categories.map { $0.fileURL }
  }

  func deleteRecentlyDeletedCategory(at urls: [URL]) {
    categories.removeAll { urls.contains($0.fileURL) }
  }

  func deleteAllRecentlyDeletedCategories() {
    categories.removeAll()
  }

  func recoverRecentlyDeletedCategories(at urls: [URL]) {
    categories.removeAll { urls.contains($0.fileURL) }
  }
}
