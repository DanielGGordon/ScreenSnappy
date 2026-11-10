<img src="assets/icon.svg" width="64" height="64" alt="">

# Snap

A tiny, fast screenshot tool for Windows in one AutoHotkey v2 file (`snap.ahk`), for machines where
Snagit can't be installed and the Snipping Tool is too slow.

## Use

| Key | Does |
| --- | --- |
| **PrtSc** or **Win+Shift+S** | Freezes the screen. Drag for a region, or click a window to take that window (click empty desktop for the whole screen). Esc or right-click cancels. |
| **Alt+PrtSc** | Takes the active window straight away. |

The capture opens in a small editor and is **already on the clipboard**. Every edit updates the
clipboard, so you can paste at any point.

| In the editor | Does |
| --- | --- |
| **A** / drag | Red arrow, from where you press to where you let go (the head) |
| **B** / drag | Solid black box, to hide something |
| **Ctrl+Z** | Undo |
| **Ctrl+C** | Copy again (if you've copied something else since) |
| **Ctrl+S** | Save as PNG; defaults to `Pictures\Screenshots\Snap <date time>.png`, so it's just Ctrl+S, Enter |
| **Esc** | Close |

The tray icon's menu has **Start with Windows** (adds a shortcut to your Startup folder) and **Exit**.

## Install

1. Get AutoHotkey **v2**. If you can't install software, the portable zip from
   [autohotkey.com](https://www.autohotkey.com/download/) runs without installing: unzip it and
   drag `snap.ahk` onto `AutoHotkey64.exe`.
2. Run `snap.ahk`, then choose **Start with Windows** from the tray menu.

## Testing

Tested on a Windows 11 VM: region and window capture, Alt+PrtSc, Win+Shift+S, arrow, box, undo,
clipboard contents, PNG save, and that PrtSc still reaches Snap when Windows is set to open the
Snipping Tool with it. About 60–90 ms from keypress to the overlay on the VM.
Not yet tested: multiple monitors and display scaling above 100%.

## License

Public domain ([the Unlicense](LICENSE)). Use it, change it, rebrand it, sell it; no credit needed.
