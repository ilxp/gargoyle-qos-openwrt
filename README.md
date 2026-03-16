Qos_Gargoyle 算法模块 README (纯文本版)
========================================

本文档介绍 OpenWrt 下 Gargoyle QoS 系统提供的五种流量整形算法实现模块。每个模块均基于 Linux TC 和 nftables 构建，支持上传/下载双向整形，并提供丰富的可调参数。

一、模块概览
------------

模块文件             算法组合            调度器     队列管理   适用场景
cake.sh             纯 CAKE             CAKE       CAKE       简单公平、多核硬件
hfsc_cake.sh        HFSC + CAKE          HFSC       CAKE       实时业务、精准延迟控制
hfsc_fqcodel.sh     HFSC + FQ_CODEL      HFSC       FQ_CODEL   实时业务、低开销
htb_cake.sh         HTB + CAKE           HTB        CAKE       经典分级带宽保证
htb_fqcodel.sh      HTB + FQ_CODEL       HTB        FQ_CODEL   分级带宽、通用场景

所有算法均采用 fwmark 标记分类：
- 上传方向使用低 16 位掩码 0xFFFF
- 下载方向使用高 16 位掩码 0xFFFF0000
- 每个方向最多支持 16 个类别（标记位空间限制）

二、算法详述
------------

1. CAKE (纯 CAKE)
   脚本: cake.sh v5.6-mq
   特点:
     - 单队列或多队列（CAKE-MQ）自适应，自动检测设备硬件队列数。
     - 内置 DiffServ、流量隔离、ACK 过滤、ECN、overhead 补偿等高级特性。
     - 支持 bandwidth、rtt、memlimit 等参数自动调优。
     - 配置极简：只需指定总带宽即可获得良好公平性。
   适用设备:
     - 任何支持 CAKE qdisc 的 OpenWrt 设备（内核 ≥ 4.4）。
     - 尤其适合多核 CPU 或具有硬件队列的网卡。
   分类数量: 不适用类别标记，整个接口共享一个 CAKE 队列。
   依赖内核模块: sch_cake, ifb（可选）

2. HFSC + CAKE / FQ_CODEL
   脚本: hfsc_cake.sh v2.20 / hfsc_fqcodel.sh v2.10
   特点:
     - HFSC (Hierarchical Fair Service Curve) 调度器，可精确控制带宽、延迟和实时性。
     - 支持为每个类别配置 percent_bandwidth（占总带宽百分比）、per_min_bandwidth（最小保证带宽百分比）、per_max_bandwidth（上限带宽百分比）。
     - 可启用最小延迟模式 (minRTT)，为交互式流量提供极低延迟。
     - 叶子队列可选用 CAKE 或 FQ_CODEL，提供更细粒度的流队列管理。
   适用设备:
     - 需要严格保障语音、视频等实时业务的网络环境。
     - CPU 性能较好的设备（HFSC 计算开销略高于 HTB）。
   分类数量: 上传方向 ≤16 类，下载方向 ≤16 类（受 fwmark 位限制）。
   依赖内核模块: sch_hfsc, sch_cake 或 sch_fq_codel, ifb, nf_conntrack

3. HTB + CAKE / FQ_CODEL
   脚本: htb_cake.sh v2.10 / htb_fqcodel.sh v2.10
   特点:
     - HTB (Hierarchical Token Bucket) 经典调度器，实现简单高效的带宽控制。
     - 支持类别优先级（priority 0~7），高优先级类可抢占空闲带宽。
     - 支持与 HFSC 类似的带宽百分比配置，并通过 burst 参数优化突发流量。
     - 叶子队列同样可选用 CAKE 或 FQ_CODEL。
   适用设备:
     - 主流 OpenWrt 路由器，HTB 对 CPU 要求较低，性能稳定。
     - 需要多级分类、保证带宽且不希望引入过多计算开销的场景。
   分类数量: 上传方向 ≤16 类，下载方向 ≤16 类。
   依赖内核模块: sch_htb, sch_cake 或 sch_fq_codel, ifb, nf_conntrack

三、配置说明
------------

带宽单位:
  所有带宽参数支持以下格式（自动转换为 kbit）：
  - 纯数字：5000（表示 5000 kbit）
  - 数字+单位：10mbit、2M、1G（分别表示 10 Mbit、2 Mbit、1 Gbit，均转为 kbit）

类别配置 (UCI):
  通过 /etc/config/qos_gargoyle 配置上传/下载类别。每个类别为一个配置节，例如：

  config upload_class 'voip'
      option name 'VoIP'
      option percent_bandwidth '20'        # 占上传总带宽的 20%
      option per_min_bandwidth '50'         # 保证带宽为类别总带宽的 50%
      option per_max_bandwidth '100'        # 上限带宽为类别总带宽的 100%
      option minRTT '1'                      # 启用最小延迟模式
      option priority '0'                     # 优先级 (仅 HTB)

规则配置（在 rule.sh 中处理）：

  config rule 'rule1'
      option class 'voip'                    # 关联的类别名
      option proto 'tcp'                      # 协议: tcp/udp/tcp_udp/icmp 等
      option dstport '5060'                    # 目标端口（上传方向）
      option srcport ''                         # 源端口（下载方向）
      option connbytes_kb '100-500'            # 连接字节数范围 (KB)
      option state 'new,established'           # 连接状态
      option family 'inet'                      # inet/ip6
      option enabled '1'

四、调试与日志
--------------

查看运行状态:
  所有模块均支持 status 命令，可显示当前队列、分类规则、连接标记等信息：
    /usr/lib/qos_gargoyle/cake.sh status
    /usr/lib/qos_gargoyle/hfsc_cake.sh status
    /usr/lib/qos_gargoyle/htb_fqcodel.sh status

  输出示例：
    ===== HTB-CAKE QoS 状态报告 (v2.10) =====
    时间: 14:30:22
    WAN接口: eth0.2
    IFB设备: 已启动且运行中 (ifb0)
    ...
    上传方向cake队列:
      parent 1:2  Sent 123456 bytes 1234 pkt (dropped 0, overlimits 0)
        maxpacket 0 ecn_mark 0 memory_used 0

系统日志:
  所有模块使用 logger 记录关键信息到系统日志：
    logread | grep qos_gargoyle

  错误信息通常以 ❌ 或 ERROR 标记，例如：
    [14:30:15] qos_gargoyle CAKE错误: 无法在 eth0 上创建入口队列

调试模式:
  在脚本开头设置 DEBUG=1 可输出更详细的调试信息（需手动修改脚本或通过 UCI 传递）。

常见错误排查:
  错误信息                                  可能原因                    解决方法
  tc 命令未找到                             缺少 iproute2 包             opkg update && opkg install iproute2 tc
  无法加载内核模块 sch_cake                  内核不支持 CAKE              编译内核时加入 CAKE 支持，或更换算法
  类数量超过16个                             标记空间不足                 减少上传或下载类别数量
  IPv6入口重定向失败                         内核缺少 connmark 或 flower 支持 检查内核配置，确保 CONFIG_NETFILTER_XT_MATCH_CONNMARK 等启用
  带宽转换无效                               带宽格式错误                 使用正确格式，如 10mbit、5000

五、常见问题与限制
------------------

1. 分类数量上限
   上传和下载方向各自最多 16 个类别。如需更多类别，需修改 fwmark 掩码（但不建议，可能导致标记冲突）。

2. IFB 设备管理
   下载方向依赖 IFB 设备进行入口整形。停止 QoS 时，IFB 设备默认保留（DELETE_IFB_ON_STOP=0），可避免重复创建；如需彻底删除，请在 UCI 中设置 delete_ifb_on_stop=1。

3. 内核模块依赖
   使用前请确认内核已加载相应模块：lsmod | grep -E "sch_(cake|hfsc|htb|fq_codel)"。如缺失，尝试 modprobe <模块名>。

4. nftables 兼容性
   规则生成需要 nftables 支持 ct state、ct bytes 等表达式。旧版内核可能缺少某些功能，请使用 OpenWrt 主线内核（≥4.14）。

5. 优先级 0
   HTB 允许优先级 0（最高），但需注意避免与系统默认队列冲突。

6. 连接状态过滤
   state 选项支持 new、established、related、untracked、invalid，多个状态用逗号分隔。invalid 状态需内核支持。

六、版本信息
------------

- CAKE 模块: v5.6-mq
- HFSC+CAKE: v2.20
- HFSC+FQ_CODEL: v2.10
- HTB+CAKE: v2.10
- HTB+FQ_CODEL: v2.10
- rule.sh: v1.8.1

--- 结束 ---