include $(TOPDIR)/rules.mk

PKG_NAME:=qos-gargoyle
PKG_VERSION:=$(GARGOYLE_VERSION)
ifeq ($(GARGOYLE_VERSION),)
     PKG_VERSION:=2.0.0
endif
PKG_RELEASE:=1

PKG_BUILD_DIR := $(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/kernel.mk

# 测试能不能跑了
# 使用nftables作为依赖
define Package/qos-gargoyle
	SECTION:=net
	CATEGORY:=Network
	TITLE:=A set of QoS scripts designed for use with Gargoyle Web Interface
	DEPENDS:=+tc-full +ip +bc +kmod-ifb +kmod-sched +kmod-sched-connmark +kmod-sched-prio +nftables \
							+kmod-nf-conntrack +kmod-nf-conntrack6 +kmod-nf-nat +kmod-nf-nat6 +kmod-nf-nathelper +kmod-nf-nathelper-extra
	MAINTAINER:=Eric Bishop <eric@gargoyle-router.com>
endef

define Package/qos-gargoyle/description
	A set of QoS scripts designed for use with Gargoyle Web Interface
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	#$(CP) ./src/qosacc/* $(PKG_BUILD_DIR)/
	$(CP) ./src/qosdba/* $(PKG_BUILD_DIR)/
endef


define Build/Configure
endef

define Build/Compile
	-$(MAKE) -C $(PKG_BUILD_DIR) clean
	$(MAKE) -C $(PKG_BUILD_DIR) \
		$(TARGET_CONFIGURE_OPTS) \
		CFLAGS="$(TARGET_CFLAGS) -I $(STAGING_DIR)/usr/include" \
		LDFLAGS="$(TARGET_LDFLAGS) -L $(STAGING_DIR)/usr/lib" \
		BUILD_DIR="$(KERNEL_BUILD_DIR)" \
		all
endef

# 安装前的预处理
define Package/qos-gargoyle/preinst
#!/bin/sh
# 检查服务是否在运行，停止它
if [ -f "$$
{IPKG_INSTROOT}/etc/init.d/qos_gargoyle" ]; then
	$${IPKG_INSTROOT}/etc/init.d/qos_gargoyle stop 2>/dev/null || true
	$${IPKG_INSTROOT}/etc/init.d/qos_gargoyle disable 2>/dev/null || true
fi
exit 0
endef

# 安装后的配置
define Package/qos-gargoyle/postinst
#!/bin/sh
# 添加防火墙规则包含
if [ -z "$$(grep 'gargoyle_firewall.include' $${IPKG_INSTROOT}/etc/config/firewall 2>/dev/null)" ]; then
	echo "config include 'qos_gargoyle'" >> $${IPKG_INSTROOT}/etc/config/firewall
	echo "	option type script" >> $${IPKG_INSTROOT}/etc/config/firewall
	echo "	option path /usr/share/qos_gargoyle/gargoyle_firewall.include" >> $${IPKG_INSTROOT}/etc/config/firewall
	echo "	option family any" >> $${IPKG_INSTROOT}/etc/config/firewall
	echo "	option reload 1" >> $${IPKG_INSTROOT}/etc/config/firewall
fi
# 启用服务
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/qos_gargoyle enable
	/etc/init.d/ifb0 enable
}
exit 0
endef

# 卸载前的处理
define Package/qos-gargoyle/prerm
#!/bin/sh
# 停止服务
if [ -f "$${IPKG_INSTROOT}/etc/init.d/qos_gargoyle" ]; then
	$$
{IPKG_INSTROOT}/etc/init.d/qos_gargoyle stop 2>/dev/null || true
	$${IPKG_INSTROOT}/etc/init.d/qos_gargoyle disable 2>/dev/null || true
fi
if [ -f "$$
{IPKG_INSTROOT}/etc/init.d/ifb0" ]; then
	$${IPKG_INSTROOT}/etc/init.d/ifb0 disable 2>/dev/null || true
fi
exit 0
endef

# 卸载后的清理
define Package/qos-gargoyle/postrm
#!/bin/sh
# 从防火墙配置中删除qos_gargoyle的include规则
if [ -f "$${IPKG_INSTROOT}/etc/config/firewall" ]; then
	sed -i '/config include.*qos_gargoyle/,/^[[:space:]]*$/d' "$${IPKG_INSTROOT}/etc/config/firewall" 2>/dev/null || true
fi
# 清理残留的空目录
[ -n "$${IPKG_INSTROOT}" ] || {
	# 只在真实系统上删除配置文件（询问用户）
	if [ "$${1}" = "remove" ]; then
		echo "Do you want to remove the configuration files? [y/N]: "
		read answer
		case "$$answer" in
			[Yy]*)
				rm -rf /etc/config/qos_gargoyle 2>/dev/null || true
				rm -rf /etc/qos_gargoyle/ 2>/dev/null || true
				;;
			*)
				echo "Configuration files preserved."
				;;
		esac
	fi
	# 删除空目录
	rmdir /usr/lib/qos_gargoyle/ 2>/dev/null || true
	rmdir /usr/share/qos_gargoyle/ 2>/dev/null || true
	rmdir /etc/qos_gargoyle/ 2>/dev/null || true
}
exit 0
endef

define Package/qos-gargoyle/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/qos_gargoyle/
	$(INSTALL_DIR) $(1)/usr/lib/qos_gargoyle/
	$(INSTALL_DIR) $(1)/usr/share/qos_gargoyle/
	
	$(INSTALL_BIN) $(CURDIR)/files/ifb0.init $(1)/etc/init.d/ifb0
	$(INSTALL_BIN) $(CURDIR)/files/qos_gargoyle.init $(1)/etc/init.d/qos_gargoyle
	$(INSTALL_BIN) $(CURDIR)/files/qos_gargoyle.hotplug $(1)/etc/hotplug.d/iface/99-qos_gargoyle
	$(INSTALL_CONF) $(CURDIR)/files/qos_gargoyle.conf $(1)/etc/config/qos_gargoyle
	$(INSTALL_BIN) $(CURDIR)/files/usr/lib/qos_gargoyle/rule.sh $(1)/usr/lib/qos_gargoyle/rule.sh
	$(INSTALL_BIN) $(CURDIR)/files/usr/lib/qos_gargoyle/hfsc_fqcodel.sh $(1)/usr/lib/qos_gargoyle/hfsc_fqcodel.sh
	$(INSTALL_BIN) $(CURDIR)/files/usr/lib/qos_gargoyle/htb_fqcodel.sh $(1)/usr/lib/qos_gargoyle/htb_fqcodel.sh
	$(INSTALL_BIN) $(CURDIR)/files/usr/lib/qos_gargoyle/cake.sh $(1)/usr/lib/qos_gargoyle/cake.sh
	$(INSTALL_BIN) $(CURDIR)/files/usr/lib/qos_gargoyle/acc_conf.sh $(1)/usr/lib/qos_gargoyle/acc_conf.sh
	$(INSTALL_BIN) $(CURDIR)/files/usr/lib/qos_gargoyle/dba_conf.sh $(1)/usr/lib/qos_gargoyle/dba_conf.sh
	$(INSTALL_BIN) $(CURDIR)/files/gargoyle_firewall.include $(1)/usr/share/qos_gargoyle/gargoyle_firewall.include

	$(INSTALL_DIR) $(1)/usr/sbin
	#$(INSTALL_BIN) $(PKG_BUILD_DIR)/qosacc $(1)/usr/sbin/qosacc
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/qosdba $(1)/usr/sbin/qosdba
endef

$(eval $(call BuildPackage,qos-gargoyle))
