### 说明：
- 1、2.0石像鬼qos是基于nftables的。
- 2、2.0支持cake，htb与fq_codel组合，hfsc与fq_codel组合3种算法。
- 3、优化qosmon.c代码以及主动拥塞系统。
- 4、完美支持ipv6。
- 5、HFSC+Fq_codel精于保证的延迟和带宽，适合实时应用;HTB+Fq_codel灵活的带宽分配和优先级管理，适合复杂策略;Cake开箱即用的高级解决方案，集成智能流管理。   
- 6、系统默认按照上传40M，下载100M的3大类别的配置文件，【最多支持8大类别】，要想最优的配置，得靠自己！

### 安装：
- 方法1、git clone https://github.com/ilxp/gargoyle-qos-openwrt.git  package/gargoyle-qos-openwrt
- 方法2、sed -i '$a src-git gargoyle https://github.com/ilxp/gargoyle-qos-openwrt.git;main' feeds.conf.default
- 依赖ndpi layer7 是故意去掉的，你可以装 ndpi，然后luci 上就有选项了https://github.com/fuqiang03/ndpi-netfilter

