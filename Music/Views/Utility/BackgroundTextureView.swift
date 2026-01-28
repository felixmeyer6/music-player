import SwiftUI

enum ScreenType {
    case library
    case albums
    case albumDetail
    case artists
    case artistDetail
    case genres
    case genreDetail
    case playlists
    case playlistDetail
    case allSongs
    case player
    case miniPlayer
}

struct ScreenSpecificBackgroundView: View {
    let screen: ScreenType

    var body: some View {
        // Pure black background for all screens
        Color.black
            .ignoresSafeArea(.all)
    }
}
