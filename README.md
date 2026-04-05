# Markdown

Markdown is a native macOS Markdown notes app built with SwiftUI and AppKit.

It is designed for working in a folder of notes with a plain-text editor, a rendered preview, fast note switching, inline image handling, Mermaid support, and an optional in-app note assistant.

## What The App Does

- Opens a notes folder as a vault
- Shows notes and folders in a sidebar
- Lets you create, edit, save, search, and delete notes
- Renders Markdown in a native preview
- Maps note relationships in a graph view
- Renders Mermaid diagrams
- Shows image files and inline image embeds
- Includes Sparkle-based app updates for shipped builds
- Includes an optional note assistant that uses the current note as context

## Main Features

### Notes And Vaults

- Open a folder and use it as your notes vault
- Automatically restore the last opened vault on launch
- Automatically restore the last selected file in that vault
- Browse nested folders and notes in a sidebar
- Sort notes by date modified or by name
- Collapse all expanded folders from the sidebar footer
- Create new notes and folders from the app
- Delete notes from the sidebar
- Drag and drop a Markdown file onto the app to open/import it

### Editing

- Plain-text Markdown editor with syntax highlighting
- Autosave while typing
- Formatting commands for:
  - bold
  - italic
  - inline code
  - links
  - headings
  - blockquotes
  - bullet lists
  - numbered lists
  - code blocks
- If a note has no Markdown heading at the top, the app can normalize it by adding a `# Title` based on the file name
- Sidebar titles use the first heading when available
- Supports Obsidian-style `[[Wiki Links]]` for note connections

### Preview

- Toggle between source editing and rendered preview
- Native Markdown preview for normal notes
- HTML fallback preview when needed
- Mermaid diagram rendering
- Clickable links in preview
- Obsidian-style note links render as clickable internal note links in preview
- Image attachment loading relative to the current note or vault
- Direct preview for image files selected in the sidebar

### Graph View

- Switch from editor or preview into a vault graph view
- Visualizes note-to-note connections from `[[Wiki Links]]` and local markdown links
- Centers the selected note and highlights connected notes
- Click any node in the graph to open that note

### Inline Image Editing

- Optional inline image previews while editing
- Hides the raw image embed syntax until the caret moves onto that line
- Lets you click and edit around inline image previews in the source editor

### Search

- Command palette for searching notes by title, file name, or relative path

### Assistant

- Optional in-app note assistant
- Uses the current note as the primary context
- Resets chat automatically when switching notes
- Stores the API key in the app's local settings on that Mac
- Lets you choose the assistant model
- Lets you customize the floating launcher button

### Updates

- Built-in Sparkle updater for shipped builds
- `Check for Updates…` menu item in the app
- App reads the update feed from the root [appcast.xml](/Users/erlinhoxha/Developer/Markdown/appcast.xml)
- Sparkle archives are intended to be hosted in GitHub Releases, not committed into the repo
- Local installs intentionally disable Sparkle so `/Applications/Markdown.app` does not drift from the published feed

## Keyboard Shortcuts

- `Command-N`: New file
- `Shift-Command-N`: New folder
- `Command-O`: Choose folder
- `Command-S`: Save
- `Command-B`: Show or hide sidebar
- `Command-K`: Search notes
- `Shift-Command-B`: Bold
- `Command-I`: Italic
- `Command-E`: Inline code
- `Shift-Command-K`: Link

## Requirements

- macOS 15 or newer
- Xcode 16 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [GitHub CLI](https://cli.github.com/) for publishing updates with the release script

## Project Structure

- [MarkdownEditor](/Users/erlinhoxha/Developer/Markdown/MarkdownEditor): app source code
- [MarkdownEditorTests](/Users/erlinhoxha/Developer/Markdown/MarkdownEditorTests): unit tests
- [project.yml](/Users/erlinhoxha/Developer/Markdown/project.yml): XcodeGen project definition
- [scripts](/Users/erlinhoxha/Developer/Markdown/scripts): helper scripts, including release tooling
- [releases](/Users/erlinhoxha/Developer/Markdown/releases): tracked release notes
- [appcast.xml](/Users/erlinhoxha/Developer/Markdown/appcast.xml): Sparkle feed used by the app

## Run Locally

### Preferred Local Install

Use the local install script if you want the app in `/Applications` with stable local signing and Sparkle disabled:

```bash
./scripts/install_local_app.sh
```

That script will:

- create a local `Markdown` code-signing identity if needed
- generate the Xcode project
- build a local app
- install a clean `/Applications/Markdown.app`
- launch it
- blank the Sparkle feed and public key for that local build

### Manual Builds

### 1. Generate The Xcode Project

```bash
xcodegen
```

### 2. Build The App

Debug build:

```bash
xcodebuild -project MarkdownEditor.xcodeproj -scheme MarkdownEditor -configuration Debug build
```

Release build:

```bash
xcodebuild -project MarkdownEditor.xcodeproj -scheme MarkdownEditor -configuration Release build
```

### 3. Launch The Built App

The built app bundle is usually here:

```bash
~/Library/Developer/Xcode/DerivedData/MarkdownEditor-*/Build/Products/Debug/Markdown.app
```

or for Release:

```bash
~/Library/Developer/Xcode/DerivedData/MarkdownEditor-*/Build/Products/Release/Markdown.app
```

## How To Use The App

### Open Your Notes

1. Launch the app.
2. Click `Open Folder…` or press `Command-O`.
3. Choose the folder that contains your notes.

### Create A Note

1. Press `Command-N`.
2. Start typing.
3. The note autosaves while you work.

### Create A Folder

1. Press `Shift-Command-N`.

### Search Notes

1. Press `Command-K`.
2. Start typing the note name or path.
3. Press Return to open the top result.

### Preview A Note

1. Open a note.
2. Click the eye button in the toolbar to switch to preview.

### Ask The Assistant

1. Open Settings.
2. Add or load your OpenAI API key.
3. Choose a model.
4. Open a note.
5. Use the floating assistant button to ask questions about that note.

### Check For Updates

1. Open the app menu.
2. Click `Check for Updates…`.

Local installs created by `./scripts/install_local_app.sh` intentionally omit this updater entry.

## Sparkle Update Flow

For users, updates come from the root [appcast.xml](/Users/erlinhoxha/Developer/Markdown/appcast.xml).

For developers, the important rule is:

- the app checks the root `appcast.xml`
- release notes live in `releases/`
- heavy Sparkle archives live in GitHub Releases
- the release script keeps the root appcast in sync with those GitHub Release assets
- local `/Applications` installs should not participate in Sparkle updates

## Very Simple Release Flow

If you want to publish a new app update, do this:

### 1. Bump The Version

Edit [project.yml](/Users/erlinhoxha/Developer/Markdown/project.yml):

- update `MARKETING_VERSION`
- update `CURRENT_PROJECT_VERSION`

### 2. Add Release Notes

Create this file:

```bash
releases/Markdown-<version>.md
```

Example:

```bash
releases/Markdown-1.0.3.md
```

### 3. Run The Release Script

```bash
SPARKLE_PRIVATE_KEY=... ./scripts/cut_release.sh
```

That command will:

- generate the Xcode project
- build the Release app
- create a local archive cache in `.release-assets/`
- upload `Markdown-<version>.zip` and any new delta files to the matching GitHub Release
- generate a local appcast from that archive cache
- sync the root [appcast.xml](/Users/erlinhoxha/Developer/Markdown/appcast.xml) that Sparkle actually reads

If your notes file is somewhere else, run:

```bash
SPARKLE_PRIVATE_KEY=... ./scripts/cut_release.sh --notes-file /path/to/release-notes.md
```

If you only want to build locally and inspect the generated appcast without publishing an update:

```bash
SPARKLE_PRIVATE_KEY=... ./scripts/cut_release.sh --skip-github-release
```

That local-only mode leaves the root [appcast.xml](/Users/erlinhoxha/Developer/Markdown/appcast.xml) unchanged.

### 4. Commit And Push

```bash
git add project.yml releases/*.md appcast.xml
git commit -m "Release <version>"
git push origin main
```

Once `main` contains the new release notes and updated appcast, Sparkle can offer the update. The heavy archive files stay out of Git and live in GitHub Releases.

## Release Files Produced

After a release, you should expect:

- `releases/Markdown-<version>.md`
- root [appcast.xml](/Users/erlinhoxha/Developer/Markdown/appcast.xml)
- local `.release-assets/Markdown-<version>.zip`
- GitHub Release assets for that version

## If You Only Need To Regenerate The Appcast

```bash
./scripts/generate_appcast.sh /path/to/local/archive-cache
```

If the archive URLs or notes URLs are hosted somewhere else:

```bash
./scripts/generate_appcast.sh /path/to/local/archive-cache https://your-host/releases https://your-host/releases
```

## Notes On Keys And Signing

- Local builds intentionally leave Sparkle feed settings blank in [project.yml](/Users/erlinhoxha/Developer/Markdown/project.yml)
- `./scripts/cut_release.sh` injects `SPARKLE_FEED_URL` and derives `SPARKLE_PUBLIC_ED_KEY` from `SPARKLE_PRIVATE_KEY` at release time
- If you need a non-default feed URL, set `SPARKLE_FEED_URL` when invoking the release script
- Do not commit private keys to the repo
- Use the same `SPARKLE_PRIVATE_KEY` for future releases if you want existing users to keep receiving Sparkle updates without a manual reinstall
- Local `/Applications/Markdown.app` installs should be signed with the local `Markdown` identity, not ad-hoc
- Assistant API keys are stored in the app's local settings, not in note files

## Current Update Feed

Release builds should inject:

- [appcast.xml](/Users/erlinhoxha/Developer/Markdown/appcast.xml)
- feed URL: `https://raw.githubusercontent.com/fightingentropy/markdown/main/appcast.xml`
