# Qos_Gargoyle 算法模块说明

本文档介绍 OpenWrt 下 Gargoyle QoS 系统提供的六种流量整形算法实现模块。每个模块均基于 Linux TC 和 nftables 构建，支持上传/下载双向整形，并提供丰富的可调参数。

## 一、模块概览

| 算法组合                | 调度器 | 队列管理 | 适用场景                     |
|-------------------------|--------|----------|------------------------------|
| 纯 CAKE                 | CAKE   | CAKE     | 简单公平、多核硬件           |
| 纯 CAKE + DSCP 智能分类 | CAKE   | CAKE     | 智能分类、无需手动规则       |
| HFSC + CAKE             | HFSC   | CAKE     | 实时业务、精准延迟控制       |
| HFSC + FQ_CODEL         | HFSC   | FQ_CODEL | 实时业务、低开销             |
| HTB + CAKE              | HTB    | CAKE     | 经典分级带宽保证             |
| HTB + FQ_CODEL          | HTB    | FQ_CODEL | 分级带宽、通用场景           |

所有算法均采用 fwmark 标记分类：
- 上传方向使用低 16 位掩码 `0xFFFF`
- 下载方向使用高 16 位掩码 `0xFFFF0000`
- 每个方向最多支持 16 个类别（标记位空间限制）

## 二、算法详述

### 1. CAKE (纯 CAKE)

**特点**：
- 单队列或多队列（CAKE-MQ）自适应，自动检测设备硬件队列数。
- 内置 DiffServ、流量隔离、ACK 过滤、ECN、overhead 补偿等高级特性。
- 支持 `bandwidth`、`rtt`、`memlimit` 等参数自动调优。
- 配置极简：只需指定总带宽即可获得良好公平性。

**适用设备**：
- 任何支持 CAKE qdisc 的 OpenWrt 设备（内核 ≥ 4.4）。
- 尤其适合多核 CPU 或具有硬件队列的网卡。

**分类数量**：不适用类别标记，整个接口共享一个 CAKE 队列。

**依赖内核模块**：`sch_cake`, `ifb`（可选）

### 2. CAKE + DSCP 智能分类 (`cake_dscp`)

**特点**：
- 基于纯 CAKE，但集成了 `dscpclassify` 智能分类引擎。
- 上传方向自动识别流量类型（游戏、网页、下载、语音等）并标记 DSCP。
- 下载方向通过 `act_ctinfo` 内核模块从 conntrack 中恢复 DSCP 标记，实现双向分类。
- 无需手动配置复杂的分类规则，真正“即插即用”。
- 依然保留 CAKE 的所有高级特性（多队列、ECN、overhead 补偿等）。

**适用设备**：
- 希望获得智能分类且不想手动配置规则的用户。
- 内核需支持 `act_ctinfo` 模块（OpenWrt 主线内核 ≥ 5.4 通常已包含）。
- 需额外安装 `dscpclassify` 库及其配置文件。

**分类数量**：不依赖 fwmark，完全由 DSCP 值决定，理论上支持多达 64 个 DSCP 类，但 CAKE 内部映射到有限的优先级队列。

**依赖内核模块**：`sch_cake`, `act_ctinfo`, `ifb`, `nf_conntrack`

### 3. HFSC + CAKE / FQ_CODEL

**特点**：
- HFSC (Hierarchical Fair Service Curve) 调度器，可精确控制带宽、延迟和实时性。
- 支持为每个类别配置 `percent_bandwidth`（占总带宽百分比）、`per_min_bandwidth`（最小保证带宽百分比）、`per_max_bandwidth`（上限带宽百分比）。
- 可启用最小延迟模式 (`minRTT`)，为交互式流量提供极低延迟。
- 叶子队列可选用 CAKE 或 FQ_CODEL，提供更细粒度的流队列管理。

**适用设备**：
- 需要严格保障语音、视频等实时业务的网络环境。
- CPU 性能较好的设备（HFSC 计算开销略高于 HTB）。

**分类数量**：上传方向 ≤16 类，下载方向 ≤16 类（受 fwmark 位限制）。

**依赖内核模块**：`sch_hfsc`, `sch_cake` 或 `sch_fq_codel`, `ifb`, `nf_conntrack`

### 4. HTB + CAKE / FQ_CODEL

**特点**：
- HTB (Hierarchical Token Bucket) 经典调度器，实现简单高效的带宽控制。
- 支持类别优先级（`priority` 0~7），高优先级类可抢占空闲带宽。
- 支持与 HFSC 类似的带宽百分比配置，并通过 `burst` 参数优化突发流量。
- 叶子队列同样可选用 CAKE 或 FQ_CODEL。

**适用设备**：
- 主流 OpenWrt 路由器，HTB 对 CPU 要求较低，性能稳定。
- 需要多级分类、保证带宽且不希望引入过多计算开销的场景。

**分类数量**：上传方向 ≤16 类，下载方向 ≤16 类。

**依赖内核模块**：`sch_htb`, `sch_cake` 或 `sch_fq_codel`, `ifb`, `nf_conntrack`

## 三、规则格式说明

### 端口格式
`srcport` 和 `dstport` 支持以下格式：
- 单个端口：`80`
- 逗号分隔列表：`80,443,8080`
- 范围：`1000-2000`
- 混合：`80,443,8000-9000`

### 连接字节数格式
`connbytes_kb` 支持三种格式：
- 单个数值（表示 ≥ 该值）：`500`（匹配连接字节数 ≥ 500KB 的流量）
- 范围：`100-500`（匹配 100KB ≤ 字节数 ≤ 500KB）
- 操作符：`>=100`、`<=500`、`>100`、`<500`、`=100`、`!=100`  
  **注意**：操作符和数值之间不能有空格。

### 连接状态
`state` 选项的值必须是以下关键字之一或多个（逗号分隔）：
- `new`：新连接
- `established`：已建立的连接
- `related`：相关联的连接（如 FTP 数据连接）
- `untracked`：未跟踪的连接（如由 raw 表 bypass 的流量）
- `invalid`：无效的连接（通常因状态机错误产生）

## 四、日志查看

所有模块使用 `logger` 记录关键信息到系统日志，可通过以下命令查看：
logread | grep qos_gargoyle
错误信息通常以 ❌ 或 ERROR 标记，例如：
[14:30:15] qos_gargoyle CAKE错误: 无法在 eth0 上创建入口队列

## 五、常见问题与限制
**分类数量上限**
- 基于 fwmark 的算法（HFSC/HTB）上传和下载方向各自最多 16 个类别。如需更多类别，需修改 fwmark 掩码（但不建议，可能导致标记冲突）。
CAKE + DSCP 算法不受此限。

**IFB 设备管理**
- 下载方向依赖 IFB 设备进行入口整形。停止 QoS 时，IFB 设备默认保留（DELETE_IFB_ON_STOP=0），可避免重复创建；如需彻底删除，请在 UCI 中设置 delete_ifb_on_stop=1。

**内核模块依赖**
- 使用前请确认内核已加载相应模块：lsmod | grep -E "sch_(cake|hfsc|htb|fq_codel|act_ctinfo)"。如缺失，尝试 modprobe <模块名>。

**nftables 兼容性**
- 规则生成需要 nftables 支持 ct state、ct bytes 等表达式。旧版内核可能缺少某些功能，请使用 OpenWrt 主线内核（≥4.14）。

**优先级范围**
- HFSC 支持优先级 0-255，HTB 只支持 0-7，配置时需注意避免与系统默认队列冲突。

**连接状态过滤**
- state 选项支持 new、established、related、untracked、invalid，多个状态用逗号分隔。invalid 状态需内核支持。

--- 结束 ---
