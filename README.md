# Tintkey

A macOS menu bar app that changes your QMK/VIA keyboard's RGB color to match the app you're using, and flashes or breathes the keys when an app gets a notification.

- Per-app colors, or one locked color
- Notification alerts (flashing or breathing) from Dock badge counts
- Works over USB or a 2.4GHz dongle that passes VIA through
- Live changes only: nothing is written to the keyboard's memory, and your own lighting returns on quit

Requires macOS 13+, Apple silicon, and a keyboard running QMK with VIA enabled. Developed on a Keychron V1 Max.

## Build

```bash
swift build                 # library and probe
swift test                  # hardware-free tests
./scripts/build-app.sh      # dist/Tintkey.app and dist/Tintkey.dmg (ad-hoc signed)
```

For a signed, notarized build set `SIGN_ID` and either `NOTARY_PROFILE` or `NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER` (see the header of `scripts/build-app.sh`).

`swift run tintkey-probe` lists VIA devices and reads their lighting. `tintkey-probe --set <hue> <sat>` changes the color temporarily and restores it.

## Layout

- `Sources/TintkeyKit` HID discovery and the VIA client
- `Sources/Tintkey` the menu bar app
- `Sources/tintkey-probe` command line probe
- `docs/` the landing page
