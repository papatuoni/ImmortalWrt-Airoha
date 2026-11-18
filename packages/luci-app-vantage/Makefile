# SPDX-License-Identifier: GPL-3.0-or-later
# stage7: Vantage theme shell + dashboard, extracted from B repo files/ layer.
# Packaged as a normal ipk (not a files/ overlay) so sysupgrade keeps it and
# apk/opkg can track it. No luci.mk: custom ucode templates + rpcd backend.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-vantage
PKG_VERSION:=1.0.13
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-vantage
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=4. Themes
  TITLE:=Vantage theme and dashboard
  DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-rtnl
  PKGARCH:=all
endef

define Package/luci-app-vantage/description
  Self-contained Vantage theme shell (ucode templates, CSS, SVG icons), a
  dashboard replacing admin/dashboard, a firewall overview and the read-only
  rpcd ucode backend luci.vantage (wireless, thermal, bridge FDB, aliases).
  Registers the theme but leaves the active LuCI theme unchanged unless
  /etc/config/vantage -> default_theme is 1.
endef

define Build/Compile
endef

define Package/luci-app-vantage/install
	$(INSTALL_DIR) $(1)/
	$(CP) ./root/* $(1)/
endef

$(eval $(call BuildPackage,luci-app-vantage))
