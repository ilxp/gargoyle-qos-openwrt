### 说明：
- 1、新版的石像鬼qos是基于IFB的，不是IMQ的。适用于openwrt 21.02、22.03以及master分支源码。
- 2、luci18分支，适合lean的lede和immortalwrt-1806-k5.4分支，就是不含kmod-imq的但是luci是18的。但lede的源码无法安装。
- 3、只用于防火墙firewall3，不适用4.
- 4、在immortalwrt-1806-k5.4上运行最完美，无bug。2102以及2203和官方master分支上运行有个小bug，就是负载没有显示数据，是个瑕疵，但不影响使用。

### 安装：
- 方法1、git clone -b openwrt-2305  https://github.com/ilxp/gargoyle-qos-openwrt.git  package/gargoyle-qos-openwrt
- 方法2、sed -i '$a src-git gargoyle https://github.com/ilxp/gargoyle-qos-openwrt.git;openwrt-2305' feeds.conf.default
