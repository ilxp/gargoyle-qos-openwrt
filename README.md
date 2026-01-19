### 说明：
- 1、23.05分支的石像鬼qos是基于IFB的，不是IMQ的。适用于openwrt21.02、22.03以及23.05分支源码。
- 2、imq分支，适合lean的lede和immortalwrt的1806分支，就是不含kmod-imq的但是luci是18的。
- 3、只用于防火墙firewall3，不适用4.
- 4、在immortalwrt-1806上运行最完美，无bug。21.02以及22.03和23.05分支上运行有个小bug，就是负载没有显示数据，是个瑕疵，但不影响使用。

### 安装：
- 方法1、git clone -b 23.05 https://github.com/ilxp/gargoyle-qos-openwrt.git  package/gargoyle-qos-openwrt
- 方法2、sed -i '$a src-git gargoyle https://github.com/ilxp/gargoyle-qos-openwrt.git;23.05' feeds.conf.default
- iptables补丁：将path/iptables目录下的608-add-gargoyle-netfilter-match-modules.patch放入package/network/utils/iptables/patches目录
- 内核补丁：将path/iptables目录下608-add-kernel-gargoyle-netfilter-match-modules.patch放入target/linux/generic/pending-xx.xx目录
- ndpi layer7 是故意去掉的，你可以装 ndpi，然后 luci 上就有选项了https://github.com/fuqiang03/ndpi-netfilter
