# Third-party code bundled in the image

| File | Source | Version | Licence | Verified |
|---|---|---|---|---|
| `package/luci-app-travel/htdocs/luci-static/resources/travel/jsQR.js` | npm `jsqr` (dist/jsQR.js) | 1.4.0 | Apache-2.0 | npm integrity `sha512-dxLob7q65Xg2DvstYkRpkYtmKm2sPJ9oFhrhmudT1dZvNFFTlroai3AWSpLey/w5vMcLBXRgOJsbXpdN9HzU/A==` matched on download, 2026-09-29 |
| `patches/mt76/900-*.patch` | plcharriere/openwrt `beryl7`, patch 107 (ports MediaTek's rate-report approach) | 2026-09-26 | ISC (mt76) | reviewed; applies cleanly to mt76 39c960c3 |
| `patches/mt76/901-*.patch` | plcharriere/openwrt `beryl7`, patch 110 (MediaTek, Michael-CY Lee) | 2026-03-11 | ISC | applies cleanly |
| `patches/mt76/902-*.patch` | plcharriere/openwrt `beryl7`, patch 114 | 2026-09-28 | ISC | one-line change |
| `patches/mt76/903-*.patch` | openwrt/mt76 upstream 41b98d773fdd (Felix Fietkau) | 2026-07-22 | ISC | cherry-pick, applies cleanly |

Changes to other packages' installed files (two in travelmate, one in OpenWrt's wifi scripts) are made
at first boot, not in the build, and an upgrade of those packages removes them: they are registered,
with their upstream status and when to drop them, in `docs/hand-patches.md`.
