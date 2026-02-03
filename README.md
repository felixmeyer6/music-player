# Music 🎵

Music is a high-quality music player supporting iCloud and local storage based on [Cosmos](https://github.com/clquwu/Cosmos-Music-Player), an open source music player by [@clquwu](https://github.com/clquwu). This project has way less features than the original project because I didn't need all of them and wanted to keep the project light. If you're looking for more, the original repo is definetly more complete!

## Features ✨

### 🎧 Audio Playback
- **Audio Format Support**: MP3, WAV, AAC, M4A
- **Graphic Equalizer**: GraphicEQ support with ability to save and switch configs

### 📚 Music Library Management
- **Dual Storage Support**: Choose between iCloud Drive or local storage
- **Smart Library Indexing**: Automatic detection and indexing of music files
- **Metadata Extraction**: Reads artist, album, title, genre and rating metadata

## Technical Architecture 🏗️
- **AppCoordinator**: Main app coordinator managing all services and initialization
- **PlayerEngine**: Advanced audio playback engine with background support and EQ
- **DatabaseManager**: SQLite/GRDB-based local database with migrations
- **StateManager**: iCloud state synchronization and local persistence
- **LibraryIndexer**: Automatic music file discovery and indexing

## Usage Guide 📱
### Adding Music
#### iCloud Drive
1. Open Files app on your iOS device
2. Navigate to "iCloud Drive" → "Music"
3. Add your music files to this folder

#### Local Storage
1. Open Files app on your iOS device
2. Navigate to "On My iPhone" → "Music"
3. Add your music files to this folder

### Using the Graphic Equalizer
1. **Access EQ**: Tap the equalizer icon in the now playing screen
2. **Enter GraphicEQ Text**: Input your GraphicEQ settings in text format
3. **Apply Settings**: Save your custom GraphicEQ configuration
4. **Multiple Configurations**: Create and switch between different GraphicEQ settings
5. **Toggle On/Off**: Enable or disable the equalizer without losing your settings

### Creating Playlists
1. Tap the "+" button in the Playlists section
2. Enter a playlist name
3. Add tracks from your library
4. Playlists sync automatically across devices

### Language Settings
Supported languages:
- English
- French

## License 📄
This project is licensed under GNU - see the LICENSE file for details.
