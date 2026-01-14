### 说明：
- 1、imq分支，适合iptables-mod-imq，就是含kmod-imq的。
- 3、只用于防火墙firewall3，不适用4.
- 4、在immortalwrt-1806上运行最完美，无bug。
### 安装：
- 方法1、git clone -b imq https://github.com/ilxp/gargoyle-qos-openwrt.git  package/gargoyle-qos-openwrt
- 方法2、sed -i '$a src-git gargoyle https://github.com/ilxp/gargoyle-qos-openwrt.git;imq' feeds.conf.default
- iptables补丁：将path/iptables目录下的608-add-gargoyle-netfilter-match-modules.patch与611-add-imq-support.patch放入package/network/utils/iptables/patches目录
- 内核补丁：将path/iptables目录下601-add-kernel-imq-support.patch与608-add-kernel-gargoyle-netfilter-match-modules.patch放入target/linux/generic/pending-xx.xx目录
- ndpi layer7 是故意去掉的，你可以装 ndpi，然后 luci 上就有选项了https://github.com/fuqiang03/ndpi-netfilter
