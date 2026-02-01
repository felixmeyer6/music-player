import SwiftUI

/// Shared toolbar modifier for collection detail screens (Album, Artist, Genre, Playlist).
/// Encapsulates the filter toggle button, sort menu, and optional edit button.
struct CollectionDetailToolbar: ViewModifier {
    let hasFilterOptions: Bool
    var filterState: TrackFilterState
    @Binding var sortOption: TrackSortOption
    var sortOptions: [TrackSortOption] = TrackSortOption.allCases
    var onSortChanged: () -> Void
    var showEditButton: Bool = false
    @Binding var isEditMode: Bool
    var tracksEmpty: Bool = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        if showEditButton {
                            Button {
                                withAnimation { isEditMode.toggle() }
                            } label: {
                                Image(systemName: isEditMode ? "checkmark" : "pencil")
                            }
                            .disabled(tracksEmpty)
                        }

                        if hasFilterOptions {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    filterState.toggleFilter()
                                }
                            } label: {
                                Image(systemName: filterState.isFilterVisible ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                    .foregroundColor(.white)
                            }
                        }

                        SortMenuView(
                            selection: $sortOption,
                            options: sortOptions,
                            onSelectionChanged: onSortChanged
                        )
                    }
                }
            }
    }
}
