# SQM on the Beryl 7: design (2026-10-07)

Corey approved the approach on 2026-10-07 ("your design suggestion is amazing, let's record it and work
on it now"). This page is the design; the decision record is
`~/decisions/_inbox/DEC-2026-1007-INFRA-BERYL7-SQM-PER-NETWORK-AUTOMATIC.md` (proposed).

## Why

At the office, a full-speed upload through the Beryl raised the delay from about 10 ms to 264 ms (the mini
on the Beryl's cable) and 461 ms (the Air on its Wi-Fi) (`networkQuality`, 2026-10-07 11:53). That is
bufferbloat: a queue fills at the slowest link, here the office line, and every packet waits behind it.
A video call stutters whenever anything uploads. SQM shapes the traffic just below the line's speed, so
the queue forms in the router instead, where cake keeps it short and fair between devices.

## The travel problem

SQM must know the line's speed, and every network is different: a hotel may give 2 Mbps or 300, and the
same hotel changes with the time of day. A fixed setting is wrong almost everywhere.

## The design

- **Per network, three settings:** Off, Automatic (the default), Manual (download and upload in Mbps).
  Kept per saved network (Wi-Fi by name; the cable and the phone each have their own entry).
- **Automatic measures each new network once.** After the router joins a network and the internet is
  open (travelmate reports "net ok", so never at a login page), it runs a short speed test through that
  uplink only: several parallel downloads and uploads for about 8 s each, against the endpoint the soak
  already uses (`speed.cloudflare.com`). It sets the shaper to 90% of each measured speed and stores the
  numbers with the time.
- **It measures again** when the panel's "Measure again" is pressed, or when the stored result is older
  than 14 days. Never on its own while the uplink is the phone (USB tethering is usually metered); there
  it waits for a press.
- **When the measurement fails or makes no sense** (under 1 Mbps or over 2000), SQM stays off for that
  network and the panel says why. A shaper set too low is worse than none.
- **It follows the uplink in use:** when the cable, the Wi-Fi uplink or the phone comes up, that network's
  values are applied to that interface (egress) and to its ingress through an ifb device; the old
  interface's shaper is removed.
- **The panel:** one line in the internet source card, for example "Smooth calls: Automatic, 87 down /
  41 up (measured today 12:30)", with Measure again and a sheet for Off / Automatic / Manual.
- **Exit node and VPN:** the shaper sits on the physical uplink, below the tunnel, so it works the same in
  every mode; the tunnel's overhead is inside the 10% margin.

## How the shaping is done: our own short cake script, not sqm-scripts

Decided by Corey on 2026-10-07 ("short script running cake"); the record is
`~/decisions/_inbox/DEC-2026-1007-INFRA-BERYL7-SQM-OWN-CAKE-SCRIPT.md`.

- **Chosen: a short script of our own** (`/usr/libexec/travel/sqm`) that runs `tc` with cake: `cake
  bandwidth <up> besteffort` on the uplink and `cake bandwidth <down> besteffort ingress` on an ifb that
  mirrors its ingress. Packages: `kmod-sched-cake`, `kmod-ifb`, `kmod-sched-core` (mirred), `tc-tiny`.
  The panel already owns every setting, so we need only the shaping, and nothing else changes it behind
  the panel's back.
- **Rejected for now: sqm-scripts** (1.7.2, the standard OpenWrt package). Well tested, but it depends on
  `iptables` and `iptables-mod-ipopt`, which pull an iptables layer onto this nftables (fw4) router with
  512 MB of RAM, and it brings its own settings file that would sit beside ours. The way back, if our
  script falls short: install it and let the panel write `/etc/config/sqm`.
- **Rejected: cake's own `autorate-ingress`.** It estimates only the download side, and poorly on Wi-Fi
  uplinks whose rate swings; and it does nothing for uploads, the side that hurt at the office.

## What it needs

- **A new image (v5):** cake and ifb are kernel modules. The v4 kernel has neither (no `sch_cake` or even
  `sch_fq_codel` module on the router, 2026-10-07), and modules built later do not fit this self-built
  kernel's package hash. **Image v5 (built 2026-10-07) carries them:** `kmod-sched-core`, `kmod-sched-cake`,
  `kmod-ifb`, `tc-tiny`. The script itself is userland and follows as a package update, no reflash.
- **Built and tested before that** in the sandbox: the measurement parser, the per-network settings, the
  panel, and the `tc` commands (a stand-in `tc` records them).

## Open questions

- The 90% margin and the 14-day re-measure are first guesses; the soak's own hourly tests on v5 will show
  whether a hotel's speed swings more than that.
- Whether to also shape the router's own LAN Wi-Fi is left out: the queue that hurt was the office line's.
