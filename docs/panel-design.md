# Travel panel design (agreed with Corey, 2026-09-29)

Phone first: it is used from a phone in a hotel room, on a plane, on a campus. It must also look right
on a laptop (centre the column, max width about 560 px).

## Visual language

- Flat. White cards on a light grey page; no gradients, no shadows.
- Card: 12 px radius, 0.5 px hairline border, padding 12–14 px, 12 px gap.
- Pills for state: green (ok / in use / on), amber (attention: login needed,
  down, blocked), grey (idle / standby / no cable).
- Two font weights only (400, 500). Sentence case everywhere. No emoji.
- Dark mode is required: follow `prefers-color-scheme`, and LuCI's own
  `html[data-darkmode="true"]` if present.
- Scope every rule under `.travel-panel` so no LuCI theme is affected and no
  theme breaks the panel. Define colours as CSS variables on `.travel-panel`.
- Icons: small inline SVGs (no icon fonts, no external requests; the router
  may have no internet while this page is open).

Suggested tokens (light / dark):

| Token | Light | Dark |
|---|---|---|
| page | #F5F4F0 | #1C1C1B |
| card | #FFFFFF | #262624 |
| border | rgba(0,0,0,.12) | rgba(255,255,255,.12) |
| text | #1F1E1D | #F0EFEA |
| text-2 | #5F5E5A | #B4B2A9 |
| accent | #185FA5 | #85B7EB |
| accent-bg | #E6F1FB | #0C447C |
| ok-bg / ok-text | #EAF3DE / #27500A | #27500A / #C0DD97 |
| warn-bg / warn-text | #FAEEDA / #633806 | #633806 / #FAC775 |
| idle-bg / idle-text | #F1EFE8 / #5F5E5A | #333331 / #B4B2A9 |
| danger-text | #A32D2D | #F09595 |

## Page order (top to bottom)

1. **Header**: hostname ("Beryl 7"), one status pill (e.g. "Online via Taipei
   office", amber "Paused: log in first" while `mode.hold == "portal"`,
   "Offline" when no uplink is online). Under it one grey line saying where
   traffic exits, derived from the active mode.
2. **Live speed strip**: Down / Up in Mbps for the active uplink, plus a
   sparkline of the last ~40 samples kept in page memory.
3. **Wi-Fi login** card (hotels, planes, universities all do this): pill "Not needed" (green) or "Login needed" (amber). Never say "hotel" in the UI.
   Text line explains. Button "Open login page" opens `portal.url` (or
   `http://neverssl.com/` when unknown) in a new tab.
4. **Where your traffic exits**: a 2×2 segmented control Direct / Tailscale
   exit / UniFi VPN / nikki (China). Under it, depending on the choice: exit
   node picker (from `tailscale.exit_nodes`, label or name, offline ones
   greyed), or WireGuard profile picker (from `wireguard`). Then one line:
   "Switch: up = …, down = …" with a pill showing the current position, and a
   small "Change" that lets the user pick the mode for each position.
   Show `mode.error` in amber text when present.
5. **Internet source**: one row per uplink (icon, label, detail, pill "In use" /
   "Standby" / "Down" / "No cable"). Button "Choose Wi-Fi" opens the Wi-Fi
   chooser. A small "Order" control lets the user move rows up/down
   (`uplink_order`).
6. **Devices**: one row per device (name, band + signal word + today's usage),
   "Block"/"Unblock" button. Tapping a row opens a small sheet: rename, block,
   "Use this device's MAC for the Wi-Fi login" (calls `mac` with `action:"set"`,
   `target:"wifi"`).
7. **Your Wi-Fi**: name, "Change name or password", a channel row per band
   (read-only "Locked: 44 — follows the Wi-Fi you're connected to" when `locked`), and
   "Country rules" select (show detected country and source as grey text).
8. **More**: rows that expand in place:
   - MAC address the network sees (random / original / enter manually).
   - Tailscale: state, this router's tailnet IP, "Log in" (opens `auth_url`)
     or "Log out".
   - UniFi VPN profiles: list with delete; "Add profile" takes a label and the
     `.conf` text, either pasted or loaded from a file picker.
   - "All OpenWrt settings" link to `L.url('admin/status/overview')`.

## Wi-Fi chooser (sheet or modal)

- Title "Choose Wi-Fi", a refresh button, grey line with the country rules.
- List from `wifi_scan` (strongest first): signal icon by quality, SSID, a
  lock icon unless open, a grey note "Saved" for saved ones.
- Buttons: "QR code" (it takes a photo, so not "Scan"), "Hidden network".
- Join form: SSID (read-only unless hidden), password (enterprise networks
  also get a username field), inline validation ("Enter the password first."),
  "Join". After success: "Saved. The router reconnects to it next time by itself."
- Saved networks list with "Forget".
- **QR code**: `<input type="file" accept="image/*" capture="environment">`,
  draw the photo to a canvas (downscale to ≤1024 px), decode with the bundled
  `jsQR` (`L.resource('travel/jsQR.js')`, global `jsQR`). Parse the standard
  Wi-Fi payload `WIFI:T:<WPA|WEP|nopass|SAE>;S:<ssid>;P:<password>;H:<true|false>;;`
  with `\` escapes for `\;`, `\,`, `\:`, `\\`. Pre-fill the join form; if the
  SSID was not in the scan, treat it as hidden. Explain failures plainly
  ("Couldn't find a QR code in that photo. Try again closer.").
  Live camera is not used: browsers only allow it on https pages.

## Copy

Plain, short, sentence case, no "please", no exclamation marks, no "successfully".
Errors say what happened, then what to do.
