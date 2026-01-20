include $(TOPDIR)/rules.mk

PKG_NAME:=gargoyle-firewall-util
PKG_VERSION:=$(GARGOYLE_VERSION)
ifeq ($(GARGOYLE_VERSION),)
     PKG_VERSION:=1.0.0
endif
PKG_RELEASE:=1

PKG_BUILD_DIR := $(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/gargoyle-firewall-util
	SECTION:=net
	CATEGORY:=Network
	TITLE:=A couple of shell script routines for firewall initialization
	DEPENDS:=+iptables +ip6tables +libericstools +iptables-mod-filter +iptables-mod-ipopt +iptables-mod-conntrack-extra +iptables-mod-nat-extra +iptables-mod-extra +iptables-mod-iprange +iptables-mod-ipopt +kmod-tun +kmod-nf-nathelper +kmod-nf-nathelper-extra +ipset +kmod-ipt-ipset
	MAINTAINER:=Eric Bishop <eric@gargoyle-router.com>
endef

define Package/gargoyle-firewall-util/description
	A couple of shell script routines for firewall initialization
endef

define Build/Prepare
	echo PACKAGE BUILD DIR = $(PACKAGE_BUILD_DIR)
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Configure
endef


define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) \
		$(TARGET_CONFIGURE_OPTS) \
		STAGING_DIR="$(STAGING_DIR)" \
		CFLAGS="$(TARGET_CFLAGS) -I $(STAGING_DIR)/usr/include" \
		LDFLAGS="$(TARGET_LDFLAGS) -L $(STAGING_DIR)/usr/lib" 
endef



# define Package/gargoyle-firewall-util/postinst
# 	included=$$(cat $${IPKG_INSTROOT}/etc/config/firewall | grep 'gargoyle_firewall_additions.include'  )
# 	if [ -z "$$included" ] ; then printf "config include\n\toption type script\n\toption path /usr/lib/gargoyle_firewall_util/gargoyle_firewall_additions.include\n\toption family any\n\toption reload 1\n\n" >> $${IPKG_INSTROOT}/etc/config/firewall ; fi
# endef

# 初始化安装路径
# 不需要的多余东西
# $(INSTALL_DIR) $(1)/etc/ppp/ip-up.d/
# $(INSTALL_BIN) $(CURDIR)/files/modemaccess.pppoe $(1)/etc/ppp/ip-up.d/modemaccess.sh
# $(INSTALL_DIR) $(1)/etc/init.d/
# $(INSTALL_BIN) $(CURDIR)/files/set_kernel_timezone.init $(1)/etc/init.d/set_kernel_timezone
define Package/gargoyle-firewall-util/install
	$(INSTALL_DIR) $(1)/usr/bin/
	
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/delete_chain_from_table $(1)/usr/bin/delete_chain_from_table
	
endef


$(eval $(call BuildPackage,gargoyle-firewall-util))
