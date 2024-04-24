final class RecentlyDeletedCategoriesViewController: MWMTableViewController {

  private enum LocalizedStrings {
    static let edit = L("edit")
    static let done = L("done")
    static let delete = L("delete")
    static let deleteAll = L("delete_all")
    static let recover = L("recover")
    static let recoverAll = L("recover_all")
    static let recentlyDeleted = L("bookmarks_recently_deleted")
    static let searchInTheList = L("search_in_the_list")
  }

  private lazy var editButton = UIBarButtonItem(title: LocalizedStrings.edit, style: .done, target: self, action: #selector(editButtonDidTap))
  private lazy var recoverButton = UIBarButtonItem(title: LocalizedStrings.recover, style: .done, target: self, action: #selector(recoverButtonDidTap))
  private lazy var deleteButton = UIBarButtonItem(title: LocalizedStrings.delete, style: .done, target: self, action: #selector(deleteButtonDidTap))
  private let searchController = UISearchController(searchResultsController: nil)
  private let viewModel: RecentlyDeletedCategoriesViewModel

  init(viewModel: RecentlyDeletedCategoriesViewModel = RecentlyDeletedCategoriesViewModel()) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)

    viewModel.stateDidChange = { [weak self] state in
      self?.updateState(state)
    }
    viewModel.filteredDataSourceDidChange = { [weak self] dataSource in
      guard let self else { return }
      if dataSource.isEmpty {
        self.tableView.reloadData()
      } else {
        let indexes = IndexSet(integersIn: 0...dataSource.count - 1)
        self.tableView.update { self.tableView.reloadSections(indexes, with: .automatic) }
      }
    }
  }
  
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    setupView()
  }

  private func setupView() {
    setupNavigationBar()
    setupToolBar()
    setupSearchBar()
    setupTableView()
  }

  private func setupNavigationBar() {
    title = LocalizedStrings.recentlyDeleted
    // TODO: Show nothing to recover message and disable search bar
    guard !viewModel.filteredDataSource.isEmpty else { return }
    navigationItem.rightBarButtonItem = editButton
  }

  private func setupToolBar() {
    let flexibleSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
    toolbarItems = [flexibleSpace, recoverButton, flexibleSpace, deleteButton, flexibleSpace]
    navigationController?.isToolbarHidden = true
  }

  private func setupSearchBar() {
    searchController.searchBar.placeholder = LocalizedStrings.searchInTheList
    searchController.obscuresBackgroundDuringPresentation = false
    searchController.hidesNavigationBarDuringPresentation = alternativeSizeClass(iPhone: true, iPad: false)
    searchController.searchBar.delegate = self
    searchController.searchBar.applyTheme()
    navigationItem.searchController = searchController
    navigationItem.hidesSearchBarWhenScrolling = false
  }

  private func setupTableView() {
    tableView.allowsMultipleSelectionDuringEditing = true
    tableView.register(cell: RecentlyDeletedTableViewCell.self)
  }

  private func updateState(_ state: RecentlyDeletedCategoriesViewModel.State) {
    switch state {
    case .normal:
      tableView.setEditing(false, animated: true)
      navigationController?.setToolbarHidden(true, animated: true)
      editButton.title = LocalizedStrings.edit
      searchController.searchBar.isUserInteractionEnabled = true
    case .searching:
      tableView.setEditing(false, animated: true)
      navigationController?.setToolbarHidden(true, animated: true)
      editButton.title = LocalizedStrings.edit
      searchController.searchBar.isUserInteractionEnabled = true
    case .editingAndNothingSelected:
      tableView.setEditing(true, animated: true)
      navigationController?.setToolbarHidden(false, animated: true)
      editButton.title = LocalizedStrings.done
      recoverButton.title = LocalizedStrings.recoverAll
      deleteButton.title = LocalizedStrings.deleteAll
      searchController.searchBar.isUserInteractionEnabled = false
    case .editingAndSomeSelected:
      recoverButton.title = LocalizedStrings.recover
      deleteButton.title = LocalizedStrings.delete
      searchController.searchBar.isUserInteractionEnabled = false
    }
  }

  // MARK: - Actions
  @objc private func editButtonDidTap() {
    tableView.setEditing(!tableView.isEditing, animated: true)
    tableView.isEditing ? viewModel.startSelecting() : viewModel.cancelSelecting()
  }

  @objc private func recoverButtonDidTap() {
    viewModel.recoverSelectedCategories()
  }

  @objc private func deleteButtonDidTap() {
    viewModel.deleteSelectedCategories()
  }

  // MARK: - UITableViewDataSource & UITableViewDelegate
  override func numberOfSections(in tableView: UITableView) -> Int {
    viewModel.filteredDataSource.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    viewModel.filteredDataSource[section].title
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    viewModel.filteredDataSource[section].categories.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(cell: RecentlyDeletedTableViewCell.self, indexPath: indexPath)
    let category = viewModel.filteredDataSource[indexPath.section].categories[indexPath.row]
    cell.configureWith(category)
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard tableView.isEditing else {
      tableView.deselectRow(at: indexPath, animated: true)
      return
    }
    viewModel.selectCategory(at: indexPath)
  }

  override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
    guard tableView.isEditing else { return }
    guard let selectedIndexPaths = tableView.indexPathsForSelectedRows, !selectedIndexPaths.isEmpty else {
      viewModel.deselectAllCategories()
      return
    }
    viewModel.deselectCategory(at: indexPath)
  }

  override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    let deleteAction = UIContextualAction(style: .destructive, title: LocalizedStrings.delete) { [weak self] (_, _, completion) in
      self?.viewModel.deleteCategory(at: indexPath)
      completion(true)
    }
    let recoverAction = UIContextualAction(style: .normal, title: LocalizedStrings.recover) { [weak self] (_, _, completion) in
      self?.viewModel.recoverCategory(at: indexPath)
      completion(true)
    }
    return UISwipeActionsConfiguration(actions: [deleteAction, recoverAction])
  }
}

// MARK: - UISearchBarDelegate
extension RecentlyDeletedCategoriesViewController: UISearchBarDelegate {
  func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
    searchBar.setShowsCancelButton(true, animated: true)
    viewModel.startSearching()
  }

  func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
    searchBar.setShowsCancelButton(false, animated: true)
  }

  func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
    searchBar.text = nil
    searchBar.resignFirstResponder()
    viewModel.cancelSearching()
  }

  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    guard !searchText.isEmpty else {
      viewModel.cancelSearching()
      return
    }
    viewModel.search(searchText)
  }
}
