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

## Getting Themes

Trois ships without themes. Get them from the catalog:

- In Trois: Settings > Get Themes, then Install.
- On the web: the gallery at https://sryo.github.io/trois-themes/. Install opens Trois, which downloads the theme and applies it.

The catalog lives in the `trois-themes` repo. Trois only installs themes listed there and checks each download against the catalog's SHA-256.

You can also drop a theme zip or folder onto Settings > Themes, or use Install Theme. Installed themes go in `~/Library/Application Support/Trois/Themes/`.

## Creating Themes

A theme is a folder of button images (BMP, PNG, JPEG, GIF or TIFF) with a `theme.json` that says which image is which button:

```json
{
  "name": "My Theme",
  "author": "Your Name",
  "version": 1,
  "buttons": {
    "close": "close_up.png",
    "closeDown": "close_down.png",
    "minimize": "min_up.png",
    "minimizeDown": "min_down.png",
    "zoom": "max_up.png",
    "zoomDown": "max_down.png",
    "restore": "restore_up.png",
    "restoreDown": "restore_down.png"
  }
}
```

Button keys: `close`, `closeDown`, `closeDisabled`, `minimize`, `minimizeDown`, `minimizeDisabled`, `zoom`, `zoomDown`, `zoomDisabled`, `restore`, `restoreDown`, `help`, `helpDown`. Restore images show on the Zoom button while a window is zoomed or full screen.

Without `theme.json`, Trois guesses from file names such as `close_up`, `close_down`, `min_up`, `max_up`, `restore_up` and `help_up` (underscores or spaces). To share a theme, add it to the catalog repo with a pull request.

## License

See [LICENSE](LICENSE) file.
