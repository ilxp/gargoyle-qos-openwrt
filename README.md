### 说明：
- 1、新版石像鬼qos是基于IFB的，不是IMQ的。适用于openwrt21.02以上分支源码。
- 2、nft分支只用于防火墙firewall4的nftables，不适用firewall3。
- 3、有个小bug，就是负载没有显示数据，是个瑕疵，但不影响使用。希望有能力的朋友解决下。
- 4、最新修改来源https://github.com/ErickG233/openwrt-gargoyle-qos 感谢ErickG233辛苦的奉献！保留了负载显示和ndpi。

### 安装：
- 方法1、git clone -b nft https://github.com/ilxp/gargoyle-qos-openwrt.git  package/gargoyle-qos-openwrt
- 方法2、sed -i '$a src-git gargoyle https://github.com/ilxp/gargoyle-qos-openwrt.git;nft' feeds.conf.default
- 依赖ndpi layer7 是故意去掉的，你可以装 ndpi，然后luci 上就有选项了https://github.com/fuqiang03/ndpi-netfilter
