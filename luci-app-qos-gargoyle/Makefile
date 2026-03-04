#
# Copyright (C) 2017 Xingwang Liao <kuoruan@gmail.com>
# Licensed to the public under the Apache License 2.0.
# Modified 2026 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-qos-gargoyle
PKG_VERSION:=2.0.0
PKG_RELEASE:=5

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Xingwang Liao <kuoruan@gmail.com>

LUCI_TITLE:=LuCI Support for Gargoyle QoS
LUCI_DEPENDS:=+qos-gargoyle
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/config
# shown in make menuconfig <Help>
help
	$(LUCI_TITLE)
	.
	Version: $(PKG_VERSION)-$(PKG_RELEASE)
	$(PKG_MAINTAINER)
endef

# call BuildPackage - OpenWrt buildroot signature
