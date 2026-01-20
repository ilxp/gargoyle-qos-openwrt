### 说明：
- 1、新版石像鬼qos是基于IFB的，不是IMQ的。适用于openwrt21.02以上分支源码。
- 2、ipt分支只用于防火墙firewall3的iptables，不适用firewall4。
- 3、有个小bug，就是负载没有显示数据，是个瑕疵，但不影响使用。希望有能力的朋友解决下。
- 4、最新修改来源https://github.com/ErickG233/openwrt-gargoyle-qos 感谢ErickG233辛苦的奉献！保留了负载显示和ndpi。

### 安装：
- 方法1、git clone -b ipt https://github.com/ilxp/gargoyle-qos-openwrt.git  package/gargoyle-qos-openwrt
- 方法2、sed -i '$a src-git gargoyle https://github.com/ilxp/gargoyle-qos-openwrt.git;ipt' feeds.conf.default
- iptables补丁：将path/iptables目录下的608-add-gargoyle-netfilter-match-modules.patch放入package/network/utils/iptables/patches目录
- 内核补丁：将path/iptables目录下608-add-kernel-gargoyle-netfilter-match-modules.patch放入target/linux/generic/pending-xx.xx目录
- 依赖ndpi layer7 是故意去掉的，你可以装 ndpi，然后luci 上就有选项了https://github.com/fuqiang03/ndpi-netfilter
