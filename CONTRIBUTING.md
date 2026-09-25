# Contributing to Trois

Thanks for helping. Bug reports, fixes and new theme engines are all welcome.

## Where things go

- **App bugs and features**: issues and pull requests here.
- **Themes**: [trois-dev/trois-themes](https://github.com/trois-dev/trois-themes). Add, fix or report themes there.

## Reporting a bug

Open an issue with the bug template. Include your macOS version, Trois version, which mode you use (Overlay or Injection) and the app the problem shows up in. Screenshots help a lot for drawing bugs.

## Building

Requires Xcode and macOS 13 or later.

1. Open `Trois.xcodeproj` and run the `Trois` scheme for normal development.
2. To build the full app with injection support, run `./build.sh --no-deploy`. It builds `TroisLoader` and `TroisInjector` first and bundles them into the app. Without `--no-deploy` it also replaces `/Applications/Trois.app`. It signs ad hoc unless `TROIS_SIGN_IDENTITY` names a signing identity in your keychain; macOS asks for Accessibility permission again after each ad hoc build.

Overlay mode only needs the Accessibility permission. You don't need to disable SIP unless you're working on Injection mode.

## Pull requests

- Keep each PR to one change. Open an issue first for anything large so we can agree on the approach.
- Match the existing Swift style: a one-line `//` summary at the top of each file, and comments only where the intent isn't obvious.
- Don't commit `build/`, `DerivedData/` or user-specific Xcode data.
- Describe how you tested it, including which mode and which apps.

## Adding a theme engine

Themes from any engine are converted to the standard `theme.json` format, so the app doesn't need engine-specific code for buttons.

1. Write a converter that outputs button images and a `theme.json` with `engine` and `source` set.
2. If the engine has window frames, write a `frame/` folder. Reuse the Kaleidoscope 2.x layout format if it fits; otherwise give `layout.json` a new `format` value and add a renderer next to `WindowFrameK1.swift`.
3. Add a row to [Supported Engines](README.md#supported-engines), and credit the archive the themes came from in the README and in the app's Credits view (`CreditsView` in `SettingsView.swift`).

## License

By contributing you agree your code is released under the [MIT license](LICENSE).
