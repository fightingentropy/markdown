# Markdown

Markdown is a native macOS Markdown editor built with SwiftUI and AppKit. It focuses on fast note-taking with a plain text editor, a live preview, Mermaid diagram rendering, keyboard-first navigation, and a lightweight vault-based file browser.

## Features

- Open a folder of Markdown notes and browse them in a sidebar
- Create notes and folders from the File menu
- Edit notes in a monospaced source editor with basic Markdown syntax highlighting
- Preview rendered Markdown, including Mermaid diagrams
- Search notes with `Command-K`
- Toggle the sidebar with `Command-B`
- Check for updates with Sparkle once an appcast feed is configured

## Project Structure

- `MarkdownEditor/`
  App source files, entitlements, and plist resources
- `project.yml`
  XcodeGen specification for the Xcode project
- `MarkdownEditor.xcodeproj`
  Generated Xcode project

## Development

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to manage the Xcode project.

Generate or refresh the project:

```bash
xcodegen
```

Build the app:

```bash
xcodebuild -project MarkdownEditor.xcodeproj -scheme MarkdownEditor -configuration Debug build
```

## Keyboard Shortcuts

- `Command-N`: New file
- `Shift-Command-N`: New folder
- `Command-O`: Choose folder
- `Command-S`: Save current file
- `Command-B`: Toggle sidebar
- `Command-K`: Open note search
- `Shift-Command-B`: Bold
- `Command-I`: Italic
- `Command-E`: Inline code
- `Shift-Command-K`: Link

## Sparkle Updates

Sparkle is integrated and the app is configured with:

- `SUFeedURL`: `https://raw.githubusercontent.com/fightingentropy/markdown/main/appcast.xml`
- `SUPublicEDKey`: configured via `project.yml`

The `Check for Updates…` menu item should now be enabled in builds generated from this repo.

### Publishing a new update

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
2. Add release notes at `releases/Markdown-<version>.md`.
3. Run the one-command release flow:

```bash
./scripts/cut_release.sh
```

That command:

- builds the Release app into `.derived`
- creates `releases/Markdown-<version>.zip`
- regenerates `releases/appcast.xml`
- syncs the root [appcast.xml](/Users/erlinhoxha/Developer/Markdown/appcast.xml) that the app actually uses

If your notes live somewhere else, you can pass them in:

```bash
./scripts/cut_release.sh --notes-file /path/to/release-notes.md
```

If you only need to regenerate the appcast from existing archives, you can still run:

```bash
./scripts/generate_appcast.sh releases
```

By default this script assumes release assets and release notes will be published under:

- `https://raw.githubusercontent.com/fightingentropy/markdown/main/releases`

If you host update archives somewhere else, pass explicit URL prefixes:

```bash
./scripts/generate_appcast.sh releases https://your-host/releases https://your-host/releases
```

The appcast the app reads lives at:

- [appcast.xml](/Users/erlinhoxha/Developer/Markdown/appcast.xml)

The Sparkle private signing key is stored in the local macOS Keychain. Do not commit exported private keys to the repository.
