# Travel panel API (ubus object `travel`)

The panel page talks to the router only through the ubus object `travel`,
served by the rpcd plugin `/usr/libexec/rpcd/travel`. LuCI reaches it with
`rpc.declare({ object: 'travel', method: '<name>', params: [...] })`.
Access is granted by `/usr/share/rpcd/acl.d/luci-app-travel.json`.

Rules both sides keep:

- The panel shows **measured state from `status`**, never what it last sent.
  After any command it re-reads `status`; commands return quickly and the
  effect appears in the next status.
- Every command returns `{ "ok": true }` or `{ "ok": false, "error": "<text>" }`.
  `error` is a short sentence meant for the user, already in plain English.
- Unknown or missing fields in `status` must not break the page: treat every
  field as optional and render what is there.
- Modes are always one of: `direct`, `exitnode`, `wireguard`, `nikki`.

## `status` → object

Polled every 5 s by the page.

```json
{
  "time": 1790000000,
  "hostname": "beryl7",
  "mode": {
    "desired": "exitnode",
    "active": "direct",
    "hold": "portal",
    "exit_node": "100.64.0.11",
    "wg": "wg_office",
    "error": ""
  },
  "switch": { "region": "world", "world_mode": "exitnode", "position": "on", "on": "exitnode", "off": "direct" },
  "internet": { "online": true, "uplink": "trm_wwan", "failover": false },
  "uplinks": [
    { "name": "wan", "kind": "ethernet", "label": "Ethernet", "present": true,
      "up": false, "online": false, "metric": 10, "detail": "No cable" },
    { "name": "trm_wwan", "kind": "wifi", "label": "Wi-Fi", "present": true,
      "up": true, "online": true, "metric": 20,
      "ssid": "Hotel_Guest", "band": "5g", "channel": 44, "signal": -61, "quality": 78 },
    { "name": "tether", "kind": "phone", "label": "Phone over USB", "present": false,
      "up": false, "online": false, "metric": 30 }
  ],
  `internet.failover` (since 2026-10-08): `false`, or `{ "from", "to", "since" }` while the health check
  (`/usr/libexec/travel/health.uc`, run by the travel service) routes around an uplink that is connected but
  has no internet; `from` then reads online false with detail "No internet" and `uplink` is `to`.
  `mac` (since 2026-10-08): per uplink, `{ "wifi": { "ssid", "saved", "kind", "now" }, "ethernet": { "saved",
  "kind", "now" } }`: `saved` is the address the router is told to use (null = its own), `now` the one in use,
  `kind` original, random (made by the panel) or custom. The Wi-Fi's belongs to the network it is on.
  (`metric` is the saved order, which the panel sorts by; `live_metric` is netifd's, absent while an
  interface is down. Until 2026-10-08 `metric` was the live one, so an unplugged Ethernet fell back to 10
  and tied with the Wi-Fi in use: the panel's order never moved.)
  "portal": { "state": "detected", "host": "wifi.hotel.de",
              "url": "http://wifi.hotel.de/login", "since": 1790000000 },
  "speed": { "rx_bps": 12400000, "tx_bps": 1800000, "uplink": "trm_wwan" },
  "wifi": {
    "ssid": "Beryl7", "country": "DE",
    "country_detected": "DE", "country_source": "nearby Wi-Fi",
    "radios": [
      { "band": "2g", "channel": 6, "auto": true, "locked": false },
      { "band": "5g", "channel": 44, "auto": false, "locked": true }
    ]
  },
  "devices": [
    { "mac": "aa:bb:cc:dd:ee:ff", "name": "iPhone", "ip": "172.31.77.23",
      "band": "5g", "signal": -48, "blocked": false,
      "rx_bytes": 1200000000, "tx_bytes": 90000000 }
  ],
  "tailscale": {
    "state": "Running", "ip": "100.64.0.2", "name": "beryl7", "auth_url": "",
    "exit_nodes": [
      { "name": "home-nas", "label": "Office", "ip": "100.64.0.11",
        "online": true, "active": false }
    ]
  },
  "wireguard": [
    { "name": "wg_office", "label": "Office", "up": false,
      "endpoint": "office.example.com:51820", "handshake": 0 }
  ],
  "nikki": { "installed": true, "running": false },
  "hide_router": true
}
```

Field notes:

- `mode.active` differs from `mode.desired` while `mode.hold` is set
  (`"portal"`: a Wi-Fi login page was found, so the tunnel waits) or when the
  desired mode failed (`mode.error` says why, e.g. "Tailscale is not logged in").
- `switch.region` is `china` or `world`; `switch.world_mode` is what "on" means outside China.
- `switch.position` is `"on"`, `"off"` or `"unknown"`. `on`/`off` name the mode
  each position selects.
- `portal.state`: `"none"`, `"detected"`, or `"unknown"` (not yet checked).
- `uplinks[].detail` is optional plain text for the row ("No cable",
  "Plug in and unlock your phone", "Connecting…").
- `radios[].locked` means that band follows the uplink Wi-Fi's channel because
  the uplink uses the same radio; the channel picker must be read-only then.
- `devices[].rx_bytes`/`tx_bytes` are today's totals (download / upload).
- `hide_router`: whether "Look like one device" is on (panel: a switch in More).
- `tailscale.state`: `Running`, `NeedsLogin`, `NeedsMachineAuth`, `Stopped`,
  `Starting`, `NoState`. When `auth_url` is non-empty the page offers it as a link.

## Commands

| Method | Params | Effect |
|---|---|---|
| `set_mode` | `mode`, optional `exit_node` (IP), optional `wg` (interface name) | Sets the desired mode (and its target) and applies it. |
| `set_switch_map` | `on`, `off` (modes) | What each switch position selects. |
| `wifi_scan` | `band` (`"2g"`, `"5g"` or `"all"`) | Returns `{ "ok": true, "networks": [ {ssid, bssid, band, channel, quality, security, saved} ] }`. Takes up to ~10 s. `security` is `open`, `owe`, `psk`, `sae`, `sae-mixed`, or `enterprise`. |
| `wifi_join` | `ssid`, `band`, `security`, optional `bssid`, `key`, `identity`, `password` | Saves the network as an uplink and starts connecting. Progress shows in `status.uplinks`. |
| `wifi_forget` | `ssid` | Removes a saved network. |
| `wifi_saved` | — | `{ "ok": true, "networks": [ {ssid, band, enabled} ] }` |
| `set_ap` | optional `ssid`, `key` (8–63 chars), `country` (ISO code) | Changes your own Wi-Fi. Devices reconnect afterwards. |
| `set_channel` | `band`, `channel` (`"auto"` or number) | Fails with an error when that band is locked. |
| `mac` | `target` (`"wifi"` or `"ethernet"`), `action` (`"set"`, `"random"`, `"reset"`), optional `mac` | MAC the network sees on that uplink. Returns `{ok, mac}`. Since 2026-10-08 a Wi-Fi change is also put on the station and that radio reconnects at once (travelmate alone uses it only at its next connect), and addresses made by `random` are remembered (`travel.main.mac_random`, the last 20) so status can call them random. |
| `device_block` | `mac`, `blocked` (bool) | Blocks or unblocks internet for one device. |
| `device_rename` | `mac`, `name` | Friendly name for a device. |
| `tailscale_login` | — | Starts login; returns `{ok, auth_url}` when available (may take a few seconds; the page can also pick it up from `status`). |
| `tailscale_logout` | — | Logs this router out of the tailnet. |
| `wg_import` | `label`, `conf` (text of a WireGuard `.conf`) | Creates a WireGuard profile. Returns `{ok, name}`. |
| `wg_delete` | `name` | Removes a WireGuard profile. |
| `uplink_order` | `order` (all three of `wan`, `trm_wwan`, `tether`, first = preferred) | Sets the priority of internet sources. The source carrying traffic keeps its metric and the others are numbered around it, because netifd re-applies an interface whose metric changes (address and routes off and on, dropping every connection through it); only when another connected source comes first does traffic move. A phone already plugged in is re-added with its new metric (`/usr/libexec/travel/tether-metric`). Since 2026-10-08. |
| `set_region` | `region` (`"china"` or `"world"`), optional `world_mode` (`"exitnode"` or `"wireguard"`) | The mode slider's meaning. China: on = nikki. Rest of the world: on = `world_mode`. Off is always direct. If the slider is on, the new meaning applies at once. |
| `set_hide_router` | `enabled` (bool) | "Look like one device": all traffic leaves with TTL 64 (65 through a tethered phone), so hotels and carriers can't tell a router is sharing the connection. Side effect while on: traceroute from your devices doesn't show the path. |
