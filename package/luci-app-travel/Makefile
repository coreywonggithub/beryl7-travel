# Travel panel for the GL.iNet Beryl 7: a phone-first front page for trips,
# on top of travelmate, Tailscale, WireGuard and nikki. Everything it drives
# stays standard OpenWrt; see docs/panel-api.md for the page <-> router contract.

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Travel panel (hotel Wi-Fi, exit nodes, UniFi VPN, mode switch)
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-iwinfo +ucode +ucode-mod-fs +ucode-mod-uci \
	+ucode-mod-ubus +jsonfilter +iw +travelmate +luci-app-travelmate +tailscale \
	+wireguard-tools +luci-proto-wireguard +nlbwmon
LUCI_PKGARCH:=all

PKG_LICENSE:=GPL-2.0-only Apache-2.0
PKG_MAINTAINER:=Corey Wong <coreymails@gmail.com>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
