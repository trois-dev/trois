# Trois

A macOS menu bar app that replaces window traffic light buttons (close, minimize, zoom) with custom themed images.

An homage to EppieDesktop by Jeff Epstein. Compatible with EppieDesktop themes. Not affiliated with the original author.

## Modes

| Mode | Requirements | Description |
|------|--------------|-------------|
| **Overlay** | Accessibility permission | Default mode. Uses overlay windows. |
| **Injection** | SIP disabled | Hooks into apps directly. Seamless. |

## Enabling Injection Mode

Injection mode requires disabling library validation. This is the same approach used by [MacForge](https://github.com/MacEnhance/MacForge).

### Step 1: Disable Library Validation

Open Terminal and run:
```bash
sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true
```

### Step 2: Partially Disable SIP

1. **Enter Recovery Mode**
   - Apple Silicon: Hold power button until "Loading startup options" → Options → Continue
   - Intel: Hold ⌘+R during boot

2. **Open Terminal** (Utilities → Terminal) and run:
   ```bash
   csrutil enable --without debug --without fs
   ```

3. **Reboot**. Trois will detect injection mode automatically.

### Re-enabling Security

To restore default security settings:
1. Boot to Recovery Mode
2. Run `csrutil enable`
3. Reboot
4. Run `sudo defaults delete /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation`

## Creating Themes

A theme is a folder containing button images. Place themes in:
- `~/Library/Application Support/Trois/Themes/`

### Image Naming

Trois looks for these image files (PNG, BMP, JPEG, TIFF):

| Button | Normal | Hover | Pressed | Disabled |
|--------|--------|-------|---------|----------|
| Close | `close.png` | `close_hover.png` | `close_pressed.png` | `close_disabled.png` |
| Minimize | `minimize.png` | `minimize_hover.png` | `minimize_pressed.png` | `minimize_disabled.png` |
| Zoom | `maximize.png` | `maximize_hover.png` | `maximize_pressed.png` | `maximize_disabled.png` |
| Restore | `restore_up.png` | - | `restore_down.png` | - |

**Note:** Restore images are shown on the Zoom button when a window is maximized/fullscreen. If no restore images are provided, the maximize images are used.

Alternative naming patterns are also supported (e.g., `closebox.bmp`, `close_up.png`, `cls.bmp`).

- Theme authors: kepplah, Spyder, Nikkie, KMR, VisualGroup, GooeyGoo, Joel Engdahl, Djoole, N-I-C, Tara, Crash, Weez, VoX, and others

## License

See [LICENSE](LICENSE) file.
