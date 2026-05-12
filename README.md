# zmdr

Markdown viewer with native WebView, featuring live reload on file changes.

Inspired by [mdr](https://github.com/CleverCloud/mdr), rewritten in Zig.

## Features

- Renders Markdown with **marked.js**, **highlight.js**, and **Mermaid.js**
- Auto-detects file changes and reloads (1s polling)
- Preserves scroll position on reload via heading anchor
- Sidebar table of contents
- Search (Ctrl+F / Cmd+F)
- Dark mode (follows system theme)
- Keyboard shortcuts: `Cmd+W` close, `Cmd+O` open file

## Requirements

- Zig 0.16.0+
- macOS (WebKit) — Linux (GTK/WebKitGTK) and Windows (WebView2) should also work

## Build

```sh
git clone --recurse-submodules https://github.com/<user>/zmdr.git
cd zmdr
zig build
```

## Usage

```sh
./zig-out/bin/zmdr README.md
```

## License

MIT
