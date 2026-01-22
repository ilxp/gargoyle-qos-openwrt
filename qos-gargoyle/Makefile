include $(TOPDIR)/rules.mk

PKG_NAME:=qos-gargoyle
PKG_VERSION:=$(GARGOYLE_VERSION)
ifeq ($(GARGOYLE_VERSION),)
     PKG_VERSION:=1.0.0
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
	DEPENDS:=+tc-full +ip +kmod-ifb +kmod-sched +kmod-sched-connmark +kmod-sched-prio +nftables \
							+kmod-nf-conntrack +kmod-nf-conntrack6 +kmod-nf-nat +kmod-nf-nat6 +kmod-nf-nathelper +kmod-nf-nathelper-extra
	MAINTAINER:=Eric Bishop <eric@gargoyle-router.com>
endef

define Package/qos-gargoyle/description
	A set of QoS scripts designed for use with Gargoyle Web Interface
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
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

# 重启防火墙时, 添加qos规则
define Package/gargoyle-firewall-util/postinst
	included=$$(cat $${IPKG_INSTROOT}/etc/config/firewall | grep 'gargoyle_firewall.include'  )
	if [ -z "$$included" ] ; then printf "config include 'qos_gargoyle'\n\toption type script\n\toption path /usr/share/qos_gargoyle/gargoyle_firewall.include\n\toption family any\n\toption reload 1\n\n" >> $${IPKG_INSTROOT}/etc/config/firewall ; fi
endef

define Package/qos-gargoyle/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/qos_gargoyle/
	$(INSTALL_DIR) $(1)/usr/share/qos_gargoyle/
	
	$(INSTALL_BIN) $(CURDIR)/files/qos_gargoyle.init $(1)/etc/init.d/qos_gargoyle
	$(INSTALL_BIN) $(CURDIR)/files/qos_gargoyle.hotplug $(1)/etc/hotplug.d/iface/23-qos_gargoyle
	$(INSTALL_CONF) $(CURDIR)/files/qos_gargoyle.conf $(1)/etc/config/qos_gargoyle
	$(INSTALL_BIN) $(CURDIR)/files/gargoyle_firewall.include $(1)/usr/share/qos_gargoyle/gargoyle_firewall.include

	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/qosmon $(1)/usr/sbin/qosmon
endef

define Package/qos-gargoyle/prerm
	$${IPKG_INSTROOT}/etc/init.d/qos_gargoyle stop 2>/dev/null
	$${IPKG_INSTROOT}/etc/init.d/qos_gargoyle disable 2>/dev/null
	ls >/dev/null 2>&1
endef

$(eval $(call BuildPackage,qos-gargoyle))
