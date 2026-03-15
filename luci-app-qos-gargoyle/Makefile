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

# 安装前的预处理
define Package/$(PKG_NAME)/preinst
#!/bin/sh
# 检查是否已安装qos-gargoyle，如果没有则警告
if [ -z "$$(opkg list-installed | grep '^qos-gargoyle')" ]; then
	echo "Warning: qos-gargoyle package is not installed. This LuCI app requires it." >&2
fi
exit 0
endef

# 安装后的配置
define Package/$(PKG_NAME)/postinst
#!/bin/sh
# 确保LuCI的缓存被清除，以便新应用显示
[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd reload 2>/dev/null || true
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart 2>/dev/null || true
# 清除LuCI缓存
rm -f /tmp/luci-indexcache 2>/dev/null || true
rm -f /tmp/luci-modulecache/* 2>/dev/null || true
exit 0
endef

# 卸载前的处理
define Package/$(PKG_NAME)/prerm
#!/bin/sh
# 停止所有相关的LuCI进程（如果有的话）
if [ -f "/www/luci-static/resources/view/qos_gargoyle.js" ]; then
	# 如果有静态资源，可以在这里执行清理
	echo "Preparing to remove LuCI app..."
fi
exit 0
endef

# 卸载后的清理
define Package/$(PKG_NAME)/postrm
#!/bin/sh
# 清理LuCI应用的所有残留文件
# 注意：这里需要清理由luci.mk自动安装的文件

find $${IPKG_INSTROOT}/usr/lib/lua/luci/i18n/ -name "qos_gargoyle.*.lmo" -delete 2>/dev/null || true
rm -f $${IPKG_INSTROOT}/usr/lib/lua/luci/controller/qos_gargoyle.lua 2>/dev/null || true
rm -f $${IPKG_INSTROOT}/usr/lib/lua/luci/model/cbi/qos_gargoyle.lua 2>/dev/null || true
rm -rf $${IPKG_INSTROOT}/usr/lib/lua/luci/view/qos_gargoyle/ 2>/dev/null || true
rm -rf $${IPKG_INSTROOT}/www/luci-static/resources/qos_gargoyle/ 2>/dev/null || true
rm -f $${IPKG_INSTROOT}/www/luci-static/resources/view/qos_gargoyle.js 2>/dev/null || true
# 清理配置文件和目录
if [ -n "$${IPKG_INSTROOT}" ]; then
	# 在构建环境中，直接删除
	rm -rf $${IPKG_INSTROOT}/etc/config/qos_gargoyle 2>/dev/null || true
else
	# 在实际系统中，询问用户是否删除配置文件
	if [ "$${1}" = "remove" ] || [ "$${1}" = "deconfigure" ]; then
		echo "Do you want to remove LuCI configuration files for qos-gargoyle? [y/N]: "
		read answer
		case "$$answer" in
			[Yy]*)
				# 删除LuCI相关的配置文件
				rm -f /etc/config/qos_gargoyle 2>/dev/null || true
				uci -q delete luci.applications.qos_gargoyle 2>/dev/null || true
				uci commit luci 2>/dev/null || true
				;;
			*)
				echo "LuCI configuration files preserved."
				;;
		esac
	fi
fi

# 清理可能遗留的空目录
find $${IPKG_INSTROOT}/usr/lib/lua/luci/ -type d -empty -delete 2>/dev/null || true
find $${IPKG_INSTROOT}/www/luci-static/resources/ -type d -empty -delete 2>/dev/null || true
find $${IPKG_INSTROOT}/usr/share/luci/menu.d/ -type f -empty -delete 2>/dev/null || true

# 重启LuCI相关服务以清除缓存
[ -n "$${IPKG_INSTROOT}" ] || {
	# 只在真实系统上重启服务
	[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd reload 2>/dev/null || true
	[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart 2>/dev/null || true
	# 清除LuCI缓存
	rm -f /tmp/luci-indexcache 2>/dev/null || true
	rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
}

exit 0
endef

# call BuildPackage - OpenWrt buildroot signature