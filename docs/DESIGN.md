# Tintkey landing site: design notes

Static HTML/CSS/vanilla JS. Open `index.html` or run `python3 -m http.server` from this folder.

## The one thing to change after publishing
`DOWNLOAD_URL` at the top of `script.js` (default `https://github.com/akabdalla9124/tintkey/releases/latest/download/Tintkey.dmg`). Replace `akabdalla9124` with the real GitHub account. `index.html` repeats the same URL as the no-JS fallback `href` on the three `data-dmg` links (nav, hero, download section); replace `akabdalla9124` there too (search the whole folder for `akabdalla9124`). The script logs a console warning while `akabdalla9124` is still present.

Also update `og:image` / `twitter:image` to an absolute URL (`https://<your-domain>/assets/og-card.png`) once the domain is known; social crawlers ignore relative paths.

## Swapping the name
`const BRAND` in `script.js` rewrites every `[data-brand]` element and the page title. `index.html` keeps "Tintkey" as the no-JS fallback, so a search-and-replace there is also needed for a full rename. The name is a placeholder (footer says so).

## What the product really does (the copy must match this)
Verified against `Sources/Tintkey` and `research/features.md`:
- Base behavior: ONE color for the whole keyboard via VIA. Per-key colors are the exception (v0.2.0): the "Keys..." editor per app, only on Keychron firmware with Per Key RGB (V1 Max 81-key layout today). The app detects support and stays whole-board otherwise; every key shows a color (a key can't be switched off); nothing is saved to the keyboard.
- Modes: per-app colors, locked color, or leave the keyboard's own lighting alone.
- Meeting mode (off by default): chosen color (red by default) while any app uses the camera and/or microphone; camera and mic are separate; no permission; dictation/Siri count as mic. Beats Focus.
- Focus mode (off by default): a color per macOS Focus (Work, Do Not Disturb, Sleep...). Reading Focus needs optional Full Disk Access; otherwise Shortcuts call `tintkey://focus?on=1&mode=Work` and `tintkey://focus?on=0`.
- Updates: Sparkle, "Check for Updates..." plus an automatic-check switch, signed. v0.1.0 has no updater (manual update once).
- Alerts: ONLY apps added on the Notifications tab alert; each has its own color and Flashing/Breathing style (or defaults), a Notify switch, a Test button, plus a global blink count. Detected by reading Dock badge counts through the Accessibility API; needs the Accessibility permission; banners without a badge are not detected; alerts for the frontmost app are skipped. `tintkey://alert?app=Name&style=breathe` also triggers one.
- Never sends VIA's save command, so nothing is written to the keyboard's flash; the keyboard's own color returns on quit. Open at login option. It has a settings window plus the menu bar item.
- More keyboards (beta, NEW): any keyboard the free open-source OpenRGB app supports is controlled through OpenRGB's local SDK server (127.0.0.1:6742); the user starts Settings > SDK Server > Start Server and the board shows in General > Keyboard as "<name> (via OpenRGB)". Works: whole-board color, notification flash/breathe (breathing emulated by scaling the color), Meeting and Focus colors. Does NOT work yet: per-key colors. Not tested on every keyboard. Never claim a brand unless it is on OpenRGB's list; the Glorious GMMK PRO is NOT supported by OpenRGB. Only allowed line about a native driver: "Native support for more keyboards (starting with Glorious) is in progress". OpenRGB is a separate GPL app Tintkey does not bundle; Tintkey never flashes firmware.
- Several keyboards: all found boards are listed, one is controlled at a time, "Flash it" blinks one to identify it, choice remembered by USB port.
- USB works. 2.4GHz works only if the dongle passes VIA raw HID through. Bluetooth is not supported.
- Build facts (from `dist/`): version 0.2.0, 2,224,085 bytes (2.1 MB, `dist/Tintkey-0.2.0.dmg`), `lipo -info` says arm64 only (Apple silicon, NOT Intel), minimum macOS 13.0. Signed with Developer ID, notarization in progress; page says "Notarized by Apple". Update the version, size and chip lines (hero `.fine`, `.specs`, hero-meta, og card, and the 0.1.0 mention in the updates FAQ) if a new build changes them.

## Direction
Swiss Industrial Print from the brutalist skill (the `industrial-brutalist-ui` skill was not installed; `brutalist-skill` was used). Paper `#ECEBE6`, ink `#0E0E0E`, hazard red as the only accent, Archivo at extended width weight 900 for headlines, IBM Plex Mono for data, zero border-radius, 2px rules, hard-offset button shadows, hazard stripe, faint grain. The page is colorless so the keyboard is the only thing that glows.

A dark system scheme is supported by swapping tokens (paper and ink invert, red text lightens to `#FF5A5A`). The demo console is dark in both schemes.

## Color tokens and contrast (WCAG AA, computed)
| Pair | Ratio |
|---|---|
| ink on paper (light) | 16.2 |
| red text `#B30E0E` on paper / paper-2 (light) | 5.9 / 5.3 |
| white on red fill `#C81010` (buttons, download, nav) | 5.9 |
| red-on-ink `#FF5A5A` on ink panel (light) | 6.3 |
| light ink on `#121212` (dark) | 15.7 |
| red text `#FF5A5A` on paper / paper-2 (dark) | 6.1 / 5.6 |
| `#B30E0E` on light panel (dark scheme "how" numerals) | 5.9 |
| console labels `#B4B4AE` on `#0B0B0B` | 9.5 |
| key legend on lit key (auto black/white by luminance), worst case | 5.4 |

Fixed from the first version: red `#E61919` as text on paper was 3.9:1 (fail), white on `#E61919` 4.65 (marginal), red mono labels on paper 3.9, `#9A9A94`/66% opacity labels, 85%-opacity white on red. Re-checked in a browser at 1440/1024/768/375 in light and dark with a script that walks every text node (0 failures).

Other readability rules: body 16-17px, mono labels 12-13px minimum, line length capped at 52-70ch, line-height 1.5+, tap targets 44px+ (48px on the picker), visible `:focus-visible` outlines (red on paper, white on the console and red sections), state is never color alone (readout text names the app, hex value and "Alert: flashing/breathing").

## The keyboard demo
75% layout generated in JS (decorative `span`s, not focusable). The picker has 8 choices: six apps, Final Cut (per-key profile: J K L amber on a teal board, `keys` on the app object, other keys use the app color) and Meeting (whole board red, menu bar state "Meeting mode on"). Picker columns: 8 desktop, 4 at 980px, 2 at 700px. App picker, connection toggle and alert-style toggle are radiogroups with roving tabindex and arrow/Home/End keys. A visually hidden `role="status"` region announces changes. "Send test alert" paints every key (as the real app does, an alert hides the key map) then restores per-key colors; it flashes the whole board (3 pulses) or breathes its brightness; under `prefers-reduced-motion` it is a single static hold and the auto-cycle and sweep are skipped. Real key presses are matched by `event.code` and cleared on blur.

## Keyboards section (`#keyboards`)
Reuses the `.notify` section, `.steps` three-cell grid and `.notify-note` (no new CSS): lede, 3 steps (install OpenRGB, start SDK server, pick it in Tintkey), bold "Beta." note. Nav gets a "Keyboards" link, hero-meta an "OpenRGB beta" item, the connect note links to it. New FAQ entries: Razer/Corsair/Glorious/other, firmware flashing, two keyboards. The feature grid stays at eight cards (4-column grid, no orphans); the headline count is unchanged. Links in body copy inherit ink color (underlined by `p a`), so contrast is the ink-on-paper-2 ratio (about 14.6 light), no new pairs.

## Assets
`assets/icon-1024.png` and `assets/menubar-icon@2x.png` are copies of the files in the repo-level `assets/`. Generated: `favicon.ico`, `assets/favicon-16/32.png`, `apple-touch-icon.png` (180), `icon-192.png`, `icon-512.png`, and `assets/og-card.png` (1200x630, made with PIL from the icon plus site colors; replace with a designed card whenever one exists, keeping the filename).

## Release checklist
1. Build and notarize the app: `dist/Tintkey.dmg` must be signed (Developer ID), notarized and stapled (`xcrun stapler validate dist/Tintkey.dmg`; `spctl -a -t open --context context:primary-signature -v dist/Tintkey.dmg`).
2. Create the GitHub repo (for example `tintkey`, public so release downloads work without login). Push the source if wanted; the site and the release can live in the same repo.
3. Create a release tagged `v0.2.0` (see `scripts/release.sh`), upload `Tintkey.dmg` as a release asset. The asset name must be exactly `Tintkey.dmg` so `/releases/latest/download/Tintkey.dmg` resolves. Mark it as the latest release.
4. Replace `akabdalla9124` in `site/script.js` (`DOWNLOAD_URL`) and the three `data-dmg` hrefs in `site/index.html`. If the repo name is not `tintkey`, change that segment too. Confirm the link downloads in a private window.
5. Check the facts on the page against the build you uploaded: version, size (`ls -l Tintkey.dmg`), `lipo -info` (arm64 only unless you ship a universal build, then change "Apple silicon only" to "Apple silicon and Intel" in hero-meta, hero `.fine`, `.specs` and the og card), minimum macOS.
6. Deploy `site/` as a static site:
   - Cloudflare Pages: create a project from the repo (or direct upload), build command empty, output directory `site`. Add a custom domain if wanted.
   - GitHub Pages: Settings, Pages, deploy from branch, folder `/site` is not offered for non-root folders, so either publish through a GitHub Action that uploads `site/` or copy `site/` to a `gh-pages` branch root.
7. Set the absolute `og:image` / `twitter:image` URLs to the deployed domain and re-test the share preview.
8. Final pass: open the deployed page in light and dark, with the keyboard only (Tab through the page), and click Download.
