### 说明：
- 1、2.0石像鬼qos是基于nftables的。
- 2、2.0支持cake，htb，fq_codel，hfsc4种算法,默认hfsc算法。
- 3、完全重写qosmon.c脚本，优化主动拥塞系统。
- 4、完美支持ipv6。
- 5、本fq_codel算法是HTB + FQ_CoDel结合体。
- 6、系统默认按照上传40M，下载100M的3大类别的配置文件，【最多支持8大类别】，要想最优的配置，得靠自己！

### 安装：
- 方法1、git clone https://github.com/ilxp/gargoyle-qos-openwrt.git  package/gargoyle-qos-openwrt
- 方法2、sed -i '$a src-git gargoyle https://github.com/ilxp/gargoyle-qos-openwrt.git;main' feeds.conf.default
- 依赖ndpi layer7 是故意去掉的，你可以装 ndpi，然后luci 上就有选项了https://github.com/fuqiang03/ndpi-netfilter

