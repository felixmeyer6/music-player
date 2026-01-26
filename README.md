# Music 🎵

---

Music is a high-quality music player supporting iCloud and local storage based on Cosmos, an open source music player by [@clquwu](https://github.com/clquwu).

## Features ✨

### 🎧 Audio Playback
- **High-Quality Lossless Support**: Native support for lossless FLAC and WAV audio files, plus MP3
- **Graphic Equalizer**: Text-based GraphicEQ support for precise audio customization
- **Custom EQ Settings**: Configure and save different GraphicEQ settings
- **Advanced Audio Engine**: Built with AVFoundation for optimal audio quality

### 📚 Music Library Management
- **Dual Storage Support**: Choose between iCloud Drive (syncs across devices) or local storage (device only)
- **iCloud Drive Integration**: Automatic sync of music files across devices when using iCloud storage
- **Local File Support**: Full support for music files stored locally in app's Documents folder
- **Smart Library Indexing**: Automatic detection and indexing of music files from both storage locations
- **Metadata Extraction**: Reads artist, album, title, and other metadata from FLAC, MP3, and WAV files
- **Offline First**: Works completely offline with local files, no internet required

### 🌍 Internationalization
- **Multi-Language Support**: English and French translations
- **Localized Interface**: Complete UI translation system
- **Cultural Adaptation**: Proper pluralization and date formatting
- **Easy Extension**: Modular system for adding new languages

### ☁️ Storage Options
- **iCloud Drive**: Automatic synchronization of music, favorites, and playlists across devices
- **Local Storage**: Store music directly on device with no iCloud required
- **Flexible Choice**: Mix and match - use both storage types simultaneously
- **Offline Mode**: Full functionality without internet connection (especially with local files)
- **Smart Fallbacks**: Graceful handling of connectivity issues
- **Authentication Management**: Robust iCloud authentication when using cloud features

## Technical Architecture 🏗️

### Core Components

#### Services Layer
- **AppCoordinator**: Main app coordinator managing all services and initialization
- **PlayerEngine**: Advanced audio playback engine with background support and GraphicEQ processing
- **DatabaseManager**: SQLite/GRDB-based local database with migrations
- **StateManager**: iCloud state synchronization and local persistence
- **LibraryIndexer**: Automatic music file discovery and indexing

#### Data Management
- **CloudDownloadManager**: Handles iCloud Drive file operations
- **FileCleanupManager**: Manages cleanup of iCloud files deleted from iCloud Drive
- **ArtworkManager**: Extracts and caches album artwork from both storage types

### Database Schema

```sql
-- Artists table
CREATE TABLE artist (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL COLLATE NOCASE
);

-- Albums table  
CREATE TABLE album (
    id INTEGER PRIMARY KEY,
    artist_id INTEGER REFERENCES artist(id) ON DELETE CASCADE,
    title TEXT NOT NULL COLLATE NOCASE,
    year INTEGER,
    album_artist TEXT COLLATE NOCASE
);

-- Tracks table
CREATE TABLE track (
    id INTEGER PRIMARY KEY,
    stable_id TEXT NOT NULL UNIQUE,
    album_id INTEGER REFERENCES album(id) ON DELETE SET NULL,
    artist_id INTEGER REFERENCES artist(id) ON DELETE SET NULL,
    title TEXT NOT NULL COLLATE NOCASE,
    track_no INTEGER,
    disc_no INTEGER,
    duration_ms INTEGER,
    sample_rate INTEGER,
    bit_depth INTEGER,
    channels INTEGER,
    path TEXT NOT NULL,
    file_size INTEGER,
    replaygain_track_gain REAL,
    replaygain_album_gain REAL,
    replaygain_track_peak REAL,
    replaygain_album_peak REAL,
    has_embedded_art INTEGER DEFAULT 0
);

-- Favorites table
CREATE TABLE favorite (
    track_stable_id TEXT PRIMARY KEY
);

-- Playlists table
CREATE TABLE playlist (
    id INTEGER PRIMARY KEY,
    slug TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    last_played_at INTEGER DEFAULT 0
);

-- Playlist items table
CREATE TABLE playlist_item (
    playlist_id INTEGER REFERENCES playlist(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    track_stable_id TEXT NOT NULL,
    PRIMARY KEY (playlist_id, position)
);
```

## Setup Instructions 🚀

### Prerequisites
- **Xcode**: Latest stable version (Xcode 15+ recommended)
- **Swift**: 6+
- **iOS Deployment Target**: iOS 18.5+
- **Git**: For version control
- **Valid Apple Developer Account**: Required for iCloud capabilities
- **Device**: Physical iOS device (required for iCloud functionality testing)

### Installation Steps

1. **Clone the Repository**
   ```bash
   git clone <repository-url>
   cd music-player
   ```

2. **Configure iCloud**
   - Ensure your Apple Developer Account has iCloud capabilities
   - The app uses container: `iCloud.dev.neofx.music-player`
   - Update the bundle identifier in project settings if needed

3. **Build and Run**
   - Open `Music.xcodeproj` in Xcode
   - Select your development team
   - Build and run on device (required for iCloud functionality)

### First Launch Setup

1. **iCloud Sign-in** (Optional): Sign into iCloud only if you want cross-device sync
2. **Add Music**: Choose your preferred storage method:
   - **iCloud Drive**: Place music files in "iCloud Drive → Music" folder
   - **Local Storage**: Place music files in "On My iPhone → Music" folder
3. **Library Sync**: The app will automatically detect and index your music from both locations
4. **Enjoy**: Start creating playlists and exploring your music!

## Usage Guide 📱

### Adding Music

You have two storage options:

#### Option 1: iCloud Drive (Syncs Across Devices)
1. Open Files app on your iOS device
2. Navigate to "iCloud Drive" → "Music"
3. Add your FLAC, MP3, or WAV music files to this folder
4. Files will sync to all your devices signed into the same iCloud account

#### Option 2: Local Storage (This Device Only)
1. Open Files app on your iOS device
2. Navigate to "On My iPhone" → "Music"
3. Add your FLAC, MP3, or WAV music files to this folder
4. Files remain on this device only (no iCloud required)

**Mixed Storage**: You can use both methods simultaneously - the app will find and index music from both locations!

### Using the Graphic Equalizer
1. **Access EQ**: Tap the equalizer icon in the now playing screen
2. **Enter GraphicEQ Text**: Input your GraphicEQ settings in text format
3. **Apply Settings**: Save your custom GraphicEQ configuration
4. **Multiple Configurations**: Create and switch between different GraphicEQ settings
5. **Toggle On/Off**: Enable or disable the equalizer without losing your settings

GraphicEQ format allows you to define frequency-specific gain adjustments for precise audio control.

### Creating Playlists
1. Tap the "+" button in the Playlists section
2. Enter a playlist name
3. Add songs from your library
4. Playlists sync automatically across devices

### Language Settings
The app automatically uses your device's language setting. Currently supported:
- English (en)
- French (fr)

## Dependencies 📦

### Swift Packages
- **GRDB**: SQLite database management
- **Foundation**: Core system framework
- **AVFoundation**: Audio playback engine with audio processing
- **SwiftUI**: Modern UI framework
- **Combine**: Reactive programming

## Troubleshooting 🔧

### Common Issues

**Music not appearing:**
- For iCloud files: Check iCloud Drive is enabled and signed in
- For local files: Ensure files are in the local "Music" folder
- Verify files are FLAC, MP3, or WAV format
- Try manual sync from the app
- Check both iCloud Drive and "On My iPhone" locations

**Equalizer not working:**
- Ensure the equalizer is enabled (toggle on)
- Check that audio output is not externally limited (headphone safety, volume limits)
- Try resetting to a preset before applying custom settings
- Restart playback if changes don't apply immediately

**Playlist sync issues:**
- Ensure iCloud Drive has sufficient storage
- Check device is connected to internet
- Try signing out and back into iCloud

## License 📄

This project is licensed under GNU - see the LICENSE file for details.