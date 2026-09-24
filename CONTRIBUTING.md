# Contributing to Trois

Thanks for helping. Bug reports, fixes and new theme engines are all welcome.

## Where things go

- **App bugs and features**: issues and pull requests here.
- **Themes**: [trois-dev/trois-themes](https://github.com/trois-dev/trois-themes). Add, fix or report themes there.

## Reporting a bug

Open an issue with the bug template. Include your macOS version, Trois version, which mode you use (Overlay or Injection) and the app the problem shows up in. Screenshots help a lot for drawing bugs.

## Building

Requires Xcode and macOS 13 or later.

1. Open `Eppie.xcodeproj` and run the `Eppie` scheme for normal development.
2. To build the full app with injection support, run `./build.sh`. It builds `TroisLoader` and `TroisInjector` first and bundles them into the app.

Overlay mode only needs the Accessibility permission. You don't need to disable SIP unless you're working on Injection mode.

## Pull requests

- Keep each PR to one change. Open an issue first for anything large so we can agree on the approach.
- Match the existing Swift style: a one-line `//` summary at the top of each file, and comments only where the intent isn't obvious.
- Don't commit `build/`, `DerivedData/` or user-specific Xcode data.
- Describe how you tested it, including which mode and which apps.

## Adding a theme engine

See [Adding an Engine](README.md#adding-an-engine) in the README. Converters should output the standard `theme.json` format so the app doesn't need engine-specific code for buttons.

## License

By contributing you agree your code is released under the [MIT license](LICENSE).
