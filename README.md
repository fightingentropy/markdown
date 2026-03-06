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

Sparkle is integrated as a Swift Package dependency and a `Check for Updates…` menu item is wired into the app menu.

The updater stays disabled until these `Info.plist` keys are configured with real values:

- `SUFeedURL`
- `SUPublicEDKey`

You can add them in `project.yml` under `targets.MarkdownEditor.info.properties` or directly in `MarkdownEditor/Info.plist` if you stop regenerating it from XcodeGen.

Example `project.yml` snippet:

```yaml
targets:
  MarkdownEditor:
    info:
      path: MarkdownEditor/Info.plist
      properties:
        SUFeedURL: https://example.com/appcast.xml
        SUPublicEDKey: YOUR_PUBLIC_ED25519_KEY
```

To make Sparkle fully functional you still need:

1. A hosted HTTPS appcast feed
2. A Sparkle EdDSA public key in the app
3. Signed release archives and appcast entries for each release

Until those are configured, the menu item remains present but disabled.
