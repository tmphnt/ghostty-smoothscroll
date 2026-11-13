# ghostty-smoothscroll

Smooth, Vimium-style keyboard scrolling for [Ghostty](https://ghostty.org) on macOS: in a plain shell's scrollback and in Claude Code's transcript view.

| Key | In scroll mode |
|---|---|
| ⌘O | enter / leave scroll mode |
| hold `j` / `k` | scroll down / up, one line per screen refresh, until you let go |
| tap `j` / `k` | a few lines |
| `d` / `u` | one page down / up, eased |
| `g` / `G` | top / bottom (plain shell) |
| `q`, Esc | leave |

In a plain shell, typing anything else leaves scroll mode and types normally. In a window running Claude Code, ⌘O opens Claude Code's own transcript view, and the same keys scroll it smoothly. A ⇅ shows in the menu bar while scroll mode is on.

## Install

With Homebrew:

```sh
brew install tmphnt/tap/ghostty-smoothscroll
ghostty-smoothscroll setup
```

Or from source (needs the Xcode Command Line Tools):

```sh
git clone https://github.com/tmphnt/ghostty-smoothscroll && cd ghostty-smoothscroll
swift build -c release
install -m 755 .build/release/ghostty-smoothscroll ~/.local/bin/   # anywhere on your PATH; `install` replaces the file, a plain `cp` over a running binary gets it killed
ghostty-smoothscroll setup
```

`setup` does three things:

1. Writes `smoothscroll.conf` next to your Ghostty config, with the keybinds it needs, and adds `config-file = ?smoothscroll.conf` to your config.
2. Installs a launch agent, so it runs in the background and starts at login.
3. Starts it. macOS then asks for **Accessibility** permission (System Settings → Privacy & Security → Accessibility). Scrolling starts as soon as you allow it.

Then reload Ghostty's config with ⌘⇧,.

`ghostty-smoothscroll status` shows what's installed; `ghostty-smoothscroll uninstall` undoes all of it.

## Settings

`ghostty-smoothscroll config` creates `~/.config/ghostty-smoothscroll/config` with every setting documented. Changes apply the next time you press ⌘O.

```
scroll-speed = 60        # lines per second while j / k is held
tap-lines = 3            # lines a quick tap of j / k scrolls
page-duration = 0.4      # seconds a d / u page takes
cell-height = 17         # points per terminal row; about 1.2 × your font size
claude-chrome-rows = 8   # rows Claude Code keeps for its prompt and footer
debug = false            # log decisions to ~/Library/Logs/ghostty-smoothscroll.log
```

### Scroll speed and refresh rate

Smooth scrolling needs a steady rhythm, so `scroll-speed` snaps to a speed that divides evenly into the display's frames:

| `scroll-speed` | 60 Hz | 75 Hz | 120 Hz (ProMotion) |
|---|---|---|---|
| 30 | 1 line every 2nd frame (30/s) | every 3rd frame (25/s) | every 4th frame (30/s) |
| 60 (default) | every frame (60/s) | every frame (75/s) | every 2nd frame (60/s) |
| 120 | 2 lines every frame (120/s) | 2 per frame (150/s) | every frame (120/s) |

The frame rate is measured while scrolling, since ProMotion and variable-refresh displays don't always report their real rate. `ghostty-smoothscroll status` shows what each of your displays gets, from the rates they report.

## How it works

Ghostty has no plugin system and no smooth keyboard scrolling, and Claude Code scrolls its transcript in whole jumps. So this is a small background app that:

- watches keys with an event tap, only while Ghostty is the frontmost app;
- runs a frame clock (`CVDisplayLink`) synced to the display the Ghostty window is on;
- on every frame while a key is held, presses a key that moves the view exactly one line:
  - **plain shell:** ⌃⌥⇧⌘ + Page Down / Page Up, which `smoothscroll.conf` binds to Ghostty's `scroll_page_lines:±1`;
  - **Claude Code:** ↓ / ↑, which the transcript view scrolls a line each.

One line per frame at a steady rhythm is what looks smooth in a terminal; several lines per frame looks choppy. The hold speed is set by `scroll-speed` (see Settings) and snaps to an even rhythm on each display.

Claude Code windows are recognised by their title, which Claude Code starts with ◐, ◑ or ✳.

### Approaches that didn't work

- **AppleScript `perform action` per frame:** each Apple Event to Ghostty takes about a whole frame (median 16.7 ms, p90 38 ms), so it can't hold a steady line per frame.
- **⌃⌥⇧⌘ + arrow keys** as the scroll keys: macOS plays its alert sound on every ⌃⌥⇧⌘↓.
- **Inside Claude Code:** its scroll code moves in one step, there is no animation setting, and a Claude Code plugin can't move the transcript.

## Known limitations

- **Accessibility permission and rebuilds.** The binary is ad-hoc signed, so macOS ties the permission to that exact build. After an upgrade or rebuild you may need to allow it again (remove the old entry, then add the new one). A Developer ID signature would fix this.
- **Claude Code mode is tracked by counting ⌘O presses.** If it gets out of step, `j` / `k` jump half a page; press ⌘O twice to resync.
- **Page size is estimated** from the window height and `cell-height`.

## Testing wanted

So far tested on one Mac: macOS 27.2, Ghostty 1.4.0, a 60 Hz built-in display, US keyboard layout. Reports are welcome for:

- other refresh rates (120 Hz ProMotion, 144 Hz+), and windows moved between displays;
- other keyboard layouts (Dvorak, AZERTY, …);
- Ghostty splits and tabs;
- after sleep / wake and after a reboot.

Useful for reports: set `debug = true` and attach `~/Library/Logs/ghostty-smoothscroll.log`.

## License

MIT. See [LICENSE](LICENSE).
