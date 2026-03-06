/* qosmon - 基于netlink的精简版QoS监控器
 * 功能：通过ping监控延迟，使用netlink动态调整ifb0根类的带宽
 * 基于Paul Bixel的原始代码优化,支持完整的HFSC/HTB/TBF/DRR参数
 */
 
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <stdarg.h>
#include <signal.h>
#include <syslog.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <sys/ioctl.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>
#include <netinet/icmp6.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>
#include <fcntl.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <sys/stat.h>
#include <linux/if_ether.h>
#include <linux/pkt_sched.h>
#include <linux/rtnetlink.h>

/* ==================== 宏定义 ==================== */
#define MAX_PACKET_SIZE 4096
#define PING_HISTORY_SIZE 10
#define MIN_PING_TIME_MS 1
#define MAX_PING_TIME_MS 5000
#define STATS_INTERVAL_MS 1000
#define CONTROL_INTERVAL_MS 1000
#define REALTIME_DETECT_MS 1000
#define HEARTBEAT_INTERVAL_MS 10000
#define MAX_QDISC_KIND_LEN 16
#define NETLINK_BUFSIZE 8192
#define MAX_ERROR_COUNT 10

// 日志级别
#define QMON_LOG_ERROR 0
#define QMON_LOG_WARN  1
#define QMON_LOG_INFO  2
#define QMON_LOG_DEBUG 3

// 队列规则类型枚举
typedef enum {
    QDISC_HTB = 0,
    QDISC_HFSC,
    QDISC_TBF,
    QDISC_DRR,
    QDISC_SFQ,
    QDISC_CODEL,
    QDISC_FQ_CODEL,
    QDISC_PFIFO_FAST,
    QDISC_UNKNOWN
} qdisc_type_t;

// 队列规则字符串名称
static const char* qdisc_names[] = {
    "htb", "hfsc", "tbf", "drr", "sfq", "codel", "fq_codel", "pfifo_fast", "unknown"
};

/* ==================== 返回码 ==================== */
typedef enum {
    QMON_OK = 0,
    QMON_ERR_MEMORY = -1,
    QMON_ERR_SOCKET = -2,
    QMON_ERR_FILE = -3,
    QMON_ERR_CONFIG = -4,
    QMON_ERR_SYSTEM = -5,
    QMON_ERR_SIGNAL = -6,
    QMON_ERR_NETLINK = -7,
    QMON_ERR_QDISC = -8
} qosmon_result_t;

/* ==================== 配置结构 ==================== */
typedef struct {
    int ping_interval;          // ping间隔(ms)
    int max_bandwidth_kbps;     // 最大带宽(kbps)
    int ping_limit_ms;          // ping限制(ms)
    int classid;                // TC类ID
    int safe_mode;              // 安全模式
    int verbose;                // 详细输出
    int auto_switch_mode;       // 自动切换模式
    int background_mode;        // 后台模式
    int skip_initial;           // 跳过初始测量
    int min_bw_change_kbps;     // 最小带宽变化(kbps)
    float min_bw_ratio;         // 最小带宽比例
    float max_bw_ratio;         // 最大带宽比例
    float smoothing_factor;     // 平滑因子
    float active_threshold;     // 激活阈值
    float idle_threshold;       // 空闲阈值
    float safe_start_ratio;     // 安全启动比例
    
    // TC队列规则特定参数
    int use_netlink;            // 使用netlink而不是shell命令
    int mtu;                    // MTU大小
    int buffer;                 // HTB缓冲区(字节)
    int cbuffer;                // HTB ceil缓冲区(字节)
    int quantum;                // HTB quantum(字节)
    
    // HFSC特定参数
    int hfsc_m1;                // HFSC m1 (字节/秒)
    int hfsc_d;                 // HFSC d (微秒)
    int hfsc_m2;                // HFSC m2 (字节/秒)
    
    // TBF特定参数
    int tbf_burst;              // TBF burst(字节)
    int tbf_limit;              // TBF limit(字节)
    int tbf_mtu;                // TBF mtu(字节)
    
    // 其他参数
    int device_mtu;             // 设备MTU
    
    char target[64];            // 目标地址
    char device[16];            // 网络设备
    char config_file[256];      // 配置文件
    char debug_log[256];        // 调试日志
    char status_file[256];      // 状态文件
} qosmon_config_t;

/* ==================== 状态枚举 ==================== */
typedef enum {
    QMON_CHK,
    QMON_INIT,
    QMON_IDLE,
    QMON_ACTIVE,
    QMON_REALTIME,
    QMON_EXIT
} qosmon_state_t;

/* ==================== Netlink消息结构 ==================== */
struct tc_qdisc_info {
    qdisc_type_t type;
    int handle;
    int parent;
    char kind[MAX_QDISC_KIND_LEN];
};

struct tc_class_info {
    qdisc_type_t qdisc_type;
    int classid;
    uint64_t rate64;
    uint64_t ceil64;
    int buffer;
    int cbuffer;
    int quantum;
    
    // HFSC特定字段
    uint64_t rsc_m1;
    uint64_t rsc_d;
    uint64_t rsc_m2;
    uint64_t fsc_m1;
    uint64_t fsc_d;
    uint64_t fsc_m2;
    uint64_t usc_m1;
    uint64_t usc_d;
    uint64_t usc_m2;
    
    // TBF特定字段
    uint64_t burst;
    uint64_t rate;
    uint64_t peakrate;
    uint32_t limit;
    uint32_t mtu;
};

/* ==================== 数据结构 ==================== */
typedef struct ping_history_s {
    int64_t times[PING_HISTORY_SIZE];
    int index;
    int count;
    float smoothed;
} ping_history_t;

/* ==================== TC控制器结构 ==================== */
struct tc_controller_s {
    qosmon_context_t* ctx;
    int netlink_fd;
    int seq;
    int error_count;
    qdisc_type_t detected_qdisc_type;
    struct tc_qdisc_info qdisc_info;
    struct tc_class_info class_info;
};

/* ==================== 主上下文结构 ==================== */
typedef struct qosmon_context_s {
    qosmon_state_t state;
    qosmon_config_t config;
    
    // 网络相关
    int ping_socket;
    int ident;
    int ntransmitted;
    int nreceived;
    struct sockaddr_in6 target_addr;
    
    // 统计数据
    int64_t raw_ping_time_us;
    int64_t filtered_ping_time_us;
    int64_t max_ping_time_us;
    int filtered_total_load_bps;
    ping_history_t ping_history;
    
    // 带宽控制
    int current_limit_bps;
    int saved_active_limit;
    int saved_realtime_limit;
    
    // TC相关
    int last_tc_bw_kbps;
    int realtime_classes;
    char detected_qdisc[MAX_QDISC_KIND_LEN];
    
    // 时间戳
    int64_t last_ping_time_ms;
    int64_t last_stats_time_ms;
    int64_t last_tc_update_time_ms;
    int64_t last_realtime_detect_time_ms;
    int64_t last_heartbeat_ms;
    
    // 文件
    FILE* status_file;
    FILE* debug_log_file;
    
    // 控制标志
    int sigterm;
} qosmon_context_t;

/* ==================== Netlink相关函数 ==================== */
static int netlink_open(void) {
    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (fd < 0) {
        return -1;
    }
    
    struct sockaddr_nl addr;
    memset(&addr, 0, sizeof(addr));
    addr.nl_family = AF_NETLINK;
    addr.nl_pid = getpid();
    addr.nl_groups = 0;
    
    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    
    return fd;
}

static void netlink_close(int fd) {
    if (fd >= 0) {
        close(fd);
    }
}

static int addattr_l(struct nlmsghdr* n, int maxlen, int type, const void* data, int alen) {
    int len = RTA_LENGTH(alen);
    struct rtattr* rta;
    
    if (NLMSG_ALIGN(n->nlmsg_len) + RTA_ALIGN(len) > maxlen) {
        return -1;
    }
    
    rta = (struct rtattr*)(((char*)n) + NLMSG_ALIGN(n->nlmsg_len));
    rta->rta_type = type;
    rta->rta_len = len;
    
    if (alen) {
        memcpy(RTA_DATA(rta), data, alen);
    }
    
    n->nlmsg_len = NLMSG_ALIGN(n->nlmsg_len) + RTA_ALIGN(len);
    return 0;
}

static int netlink_send_msg(int fd, struct nlmsghdr* n) {
    struct sockaddr_nl nladdr;
    memset(&nladdr, 0, sizeof(nladdr));
    nladdr.nl_family = AF_NETLINK;
    
    n->nlmsg_seq = ++tc_mgr->seq;
    n->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
    
    struct iovec iov = {
        .iov_base = n,
        .iov_len = n->nlmsg_len
    };
    
    struct msghdr msg = {
        .msg_name = &nladdr,
        .msg_namelen = sizeof(nladdr),
        .msg_iov = &iov,
        .msg_iovlen = 1
    };
    
    return sendmsg(fd, &msg, 0);
}

static int netlink_receive_ack(int fd) {
    char buf[NETLINK_BUFSIZE];
    struct nlmsghdr* hdr;
    int len;
    
    while ((len = recv(fd, buf, sizeof(buf), 0)) > 0) {
        for (hdr = (struct nlmsghdr*)buf; NLMSG_OK(hdr, len); hdr = NLMSG_NEXT(hdr, len)) {
            if (hdr->nlmsg_type == NLMSG_ERROR) {
                struct nlmsgerr* err = (struct nlmsgerr*)NLMSG_DATA(hdr);
                if (err->error != 0) {
                    return -err->error;
                }
                return 0;
            } else if (hdr->nlmsg_type == NLMSG_DONE) {
                return 0;
            }
        }
    }
    
    return -1;
}

/* ==================== TC控制器实现 ==================== */
int tc_controller_init(tc_controller_t* tc, qosmon_context_t* ctx) {
    if (!tc || !ctx) return QMON_ERR_MEMORY;
    
    tc->ctx = ctx;
    tc->seq = 0;
    tc->error_count = 0;
    tc->detected_qdisc_type = QDISC_UNKNOWN;
    memset(&tc->qdisc_info, 0, sizeof(tc->qdisc_info));
    memset(&tc->class_info, 0, sizeof(tc->class_info));
    
    // 检测队列规则类型
    char* qdisc_kind = detect_qdisc_kind(ctx);
    strncpy(ctx->detected_qdisc, qdisc_kind, sizeof(ctx->detected_qdisc) - 1);
    ctx->detected_qdisc[sizeof(ctx->detected_qdisc) - 1] = '\0';
    
    // 映射队列规则名称到类型
    for (int i = 0; i < QDISC_UNKNOWN; i++) {
        if (strcmp(qdisc_kind, qdisc_names[i]) == 0) {
            tc->detected_qdisc_type = (qdisc_type_t)i;
            break;
        }
    }
    
    // 如果检测到不支持动态调整的队列规则，默认使用HTB
    if (tc->detected_qdisc_type == QDISC_UNKNOWN || 
        tc->detected_qdisc_type == QDISC_SFQ ||
        tc->detected_qdisc_type == QDISC_CODEL ||
        tc->detected_qdisc_type == QDISC_FQ_CODEL ||
        tc->detected_qdisc_type == QDISC_PFIFO_FAST) {
        qosmon_log(ctx, QMON_LOG_WARN, 
                   "检测到不支持动态调整的队列算法: %s，将使用HTB\n", qdisc_kind);
        strcpy(ctx->detected_qdisc, "htb");
        tc->detected_qdisc_type = QDISC_HTB;
    }
    
    // 初始化netlink
    if (ctx->config.use_netlink) {
        tc->netlink_fd = netlink_open();
        if (tc->netlink_fd < 0) {
            qosmon_log(ctx, QMON_LOG_WARN, 
                       "netlink初始化失败，将使用shell命令: %s\n", strerror(errno));
            ctx->config.use_netlink = 0;
        } else {
            qosmon_log(ctx, QMON_LOG_INFO, "netlink已初始化，使用内核接口\n");
        }
    }
    
    // 查询当前类配置
    int current_bw_kbps = 0;
    if (detect_class_bandwidth(ctx, &current_bw_kbps, tc) == QMON_OK) {
        ctx->last_tc_bw_kbps = current_bw_kbps;
        qosmon_log(ctx, QMON_LOG_INFO, 
                  "检测到当前带宽: %d kbps (算法: %s)\n", 
                  current_bw_kbps, ctx->detected_qdisc);
    } else {
        qosmon_log(ctx, QMON_LOG_INFO, 
                  "使用新的带宽设置 (算法: %s)\n", ctx->detected_qdisc);
    }
    
    return QMON_OK;
}

int tc_controller_set_bandwidth(tc_controller_t* tc, int bandwidth_bps) {
    if (!tc || !tc->ctx) return QMON_ERR_MEMORY;
    
    qosmon_context_t* ctx = tc->ctx;
    
    if (ctx->config.safe_mode) {
        qosmon_log(ctx, QMON_LOG_INFO, 
                  "安全模式: 跳过带宽设置(%d kbps)\n", 
                  bandwidth_bps / 1000);
        return QMON_OK;
    }
    
    int bandwidth_kbps = (bandwidth_bps + 500) / 1000;
    
    // 检查是否需要进行TC更新
    if (ctx->last_tc_bw_kbps != 0) {
        int diff = bandwidth_kbps - ctx->last_tc_bw_kbps;
        if (diff < 0) diff = -diff;
        if (diff < ctx->config.min_bw_change_kbps) {
            qosmon_log(ctx, QMON_LOG_DEBUG, 
                      "跳过TC更新: 变化太小(%d -> %d kbps)\n",
                      ctx->last_tc_bw_kbps, bandwidth_kbps);
            return QMON_OK;
        }
    }
    
    int ret = QMON_OK;
    
    if (ctx->config.use_netlink && tc->netlink_fd >= 0) {
        ret = tc_set_bandwidth_netlink(tc, bandwidth_bps);
        if (ret != QMON_OK) {
            tc->error_count++;
            if (tc->error_count > MAX_ERROR_COUNT) {
                qosmon_log(ctx, QMON_LOG_ERROR, 
                          "netlink错误过多，切换到shell命令\n");
                ctx->config.use_netlink = 0;
                netlink_close(tc->netlink_fd);
                tc->netlink_fd = -1;
            }
        } else {
            tc->error_count = 0;
        }
    }
    
    // 如果netlink失败或未启用，使用shell命令
    if (!ctx->config.use_netlink || ret != QMON_OK) {
        ret = tc_set_bandwidth_shell(ctx, bandwidth_bps);
    }
    
    if (ret == QMON_OK) {
        ctx->last_tc_bw_kbps = bandwidth_kbps;
    }
    
    return ret;
}

static int tc_set_bandwidth_netlink(tc_controller_t* tc, int bandwidth_bps) {
    qosmon_context_t* ctx = tc->ctx;
    int bandwidth_kbps = (bandwidth_bps + 500) / 1000;
    
    char buf[4096];
    struct nlmsghdr* n = (struct nlmsghdr*)buf;
    struct tcmsg* t = NLMSG_DATA(n);
    struct rtattr* opt = NULL;
    
    memset(buf, 0, sizeof(buf));
    
    n->nlmsg_len = NLMSG_LENGTH(sizeof(*t));
    n->nlmsg_type = RTM_NEWTCLASS;
    n->nlmsg_flags = NLM_F_REQUEST | NLM_F_REPLACE | NLM_F_CREATE | NLM_F_ACK;
    n->nlmsg_seq = ++tc->seq;
    
    t->tcm_family = AF_UNSPEC;
    t->tcm_ifindex = 0;  // 将在后面设置
    t->tcm_handle = htonl(ctx->config.classid);
    t->tcm_parent = htonl(1);  // 父类1:
    t->tcm_info = 0;
    
    // 获取接口索引
    struct ifreq ifr;
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        return QMON_ERR_SOCKET;
    }
    
    strncpy(ifr.ifr_name, ctx->config.device, IFNAMSIZ - 1);
    if (ioctl(sock, SIOCGIFINDEX, &ifr) < 0) {
        close(sock);
        return QMON_ERR_SYSTEM;
    }
    close(sock);
    
    t->tcm_ifindex = ifr.ifr_ifindex;
    
    // 根据队列规则类型设置参数
    switch (tc->detected_qdisc_type) {
        case QDISC_HTB:
            ret = tc_set_bandwidth_htb_netlink(tc, bandwidth_bps, n, buf, sizeof(buf));
            break;
        case QDISC_HFSC:
            ret = tc_set_bandwidth_hfsc_netlink(tc, bandwidth_bps, n, buf, sizeof(buf));
            break;
        case QDISC_TBF:
            ret = tc_set_bandwidth_tbf_netlink(tc, bandwidth_bps, n, buf, sizeof(buf));
            break;
        default:
            qosmon_log(ctx, QMON_LOG_WARN, 
                      "不支持的队列规则类型: %s，使用shell命令\n",
                      qdisc_names[tc->detected_qdisc_type]);
            return QMON_ERR_QDISC;
    }
    
    if (ret != QMON_OK) {
        return ret;
    }
    
    // 发送netlink消息
    if (netlink_send_msg(tc->netlink_fd, n) < 0) {
        return QMON_ERR_NETLINK;
    }
    
    // 接收ACK
    if (netlink_receive_ack(tc->netlink_fd) != 0) {
        return QMON_ERR_NETLINK;
    }
    
    qosmon_log(ctx, QMON_LOG_DEBUG, 
              "Netlink设置带宽成功: %d kbps (类型: %s)\n",
              bandwidth_kbps, qdisc_names[tc->detected_qdisc_type]);
    
    return QMON_OK;
}

static int tc_set_bandwidth_htb_netlink(tc_controller_t* tc, int bandwidth_bps, 
                                        struct nlmsghdr* n, char* buf, int buf_len) {
    qosmon_context_t* ctx = tc->ctx;
    struct tcmsg* t = NLMSG_DATA(n);
    struct rtattr* opt = NULL;
    
    // 设置HTB参数
    struct tc_htb_glob gopt = {0};
    struct tc_htb_opt opts = {0};
    uint64_t rate64 = bandwidth_bps;
    uint64_t ceil64 = bandwidth_bps;
    
    opts.rate.rate = bandwidth_bps / 8;  // 转换为字节/秒
    opts.ceil.rate = bandwidth_bps / 8;
    opts.buffer = ctx->config.buffer;
    opts.cbuffer = ctx->config.cbuffer;
    opts.quantum = ctx->config.quantum;
    
    // 添加HTB参数
    opt = (struct rtattr*)((char*)n + NLMSG_ALIGN(n->nlmsg_len));
    addattr_l(n, buf_len, TCA_OPTIONS, NULL, 0);
    
    struct rtattr* tail = (struct rtattr*)((char*)n + NLMSG_ALIGN(n->nlmsg_len) - RTA_ALIGN(sizeof(struct rtattr)));
    
    // 添加TCA_HTB_PARMS属性
    struct rtattr* rta = tail;
    rta->rta_type = TCA_HTB_PARMS;
    rta->rta_len = RTA_LENGTH(sizeof(opts));
    memcpy(RTA_DATA(rta), &opts, sizeof(opts));
    n->nlmsg_len += RTA_ALIGN(rta->rta_len);
    
    // 添加TCA_HTB_RATE64属性
    rta = (struct rtattr*)((char*)n + NLMSG_ALIGN(n->nlmsg_len) - RTA_ALIGN(sizeof(struct rtattr)));
    rta->rta_type = TCA_HTB_RATE64;
    rta->rta_len = RTA_LENGTH(sizeof(rate64));
    memcpy(RTA_DATA(rta), &rate64, sizeof(rate64));
    n->nlmsg_len += RTA_ALIGN(rta->rta_len);
    
    // 添加TCA_HTB_CEIL64属性
    rta = (struct rtattr*)((char*)n + NLMSG_ALIGN(n->nlmsg_len) - RTA_ALIGN(sizeof(struct rtattr)));
    rta->rta_type = TCA_HTB_CEIL64;
    rta->rta_len = RTA_LENGTH(sizeof(ceil64));
    memcpy(RTA_DATA(rta), &ceil64, sizeof(ceil64));
    n->nlmsg_len += RTA_ALIGN(rta->rta_len);
    
    return QMON_OK;
}

static int tc_set_bandwidth_hfsc_netlink(tc_controller_t* tc, int bandwidth_bps,
                                         struct nlmsghdr* n, char* buf, int buf_len) {
    qosmon_context_t* ctx = tc->ctx;
    struct tcmsg* t = NLMSG_DATA(n);
    struct rtattr* opt = NULL;
    
    // 设置HFSC服务曲线
    struct tc_service_curve rsc = {0}, fsc = {0}, usc = {0};
    unsigned int byte_rate = bandwidth_bps / 8;  // 转换为字节/秒
    
    // 实时服务曲线 (保证速率)
    rsc.m1 = ctx->config.hfsc_m1 ? ctx->config.hfsc_m1 : 0;
    rsc.d = ctx->config.hfsc_d ? ctx->config.hfsc_d : 0;
    rsc.m2 = byte_rate;
    
    // 链接共享服务曲线
    fsc.m1 = 0;
    fsc.d = 0;
    fsc.m2 = byte_rate;
    
    // 上限服务曲线
    usc.m1 = 0;
    usc.d = 0;
    usc.m2 = byte_rate;
    
    // 添加HFSC参数
    opt = (struct rtattr*)((char*)n + NLMSG_ALIGN(n->nlmsg_len));
    addattr_l(n, buf_len, TCA_OPTIONS, NULL, 0);
    
    // 添加实时服务曲线
    struct rtattr* rta = (struct rtattr*)((char*)n + NLMSG_ALIGN(n->nlmsg_len) - RTA_ALIGN(sizeof(struct rtattr)));
    rta->rta_type = TCA_HFSC_RSC;
    rta->rta_len = RTA_LENGTH(sizeof(rsc));
    memcpy(RTA_DATA(rta), &rsc, sizeof(rsc));
    n->nlmsg_len += RTA_ALIGN(rta->rta_len);
    
    // 添加链接共享服务曲线
    rta = (struct rtattr*)((char*)n + NLMSG_ALIGN(n->nlmsg_len) - RTA_ALIGN(sizeof(struct rtattr)));
    rta->rta_type = TCA_HFSC_FSC;
    rta->rta_len = RTA_LENGTH(sizeof(fsc));
    memcpy(RTA_DATA(rta), &fsc, sizeof(fsc));
    n->nlmsg_len += RTA_ALIGN(rta->rta_len);
    
    // 添加上限服务曲线
    rta = (struct rtattr*)((char*)n + NLMSG_ALIGN(n->nlmsg_len) - RTA_ALIGN(sizeof(struct rtattr)));
    rta->rta_type = TCA_HFSC_USC;
    rta->rta_len = RTA_LENGTH(sizeof(usc));
    memcpy(RTA_DATA(rta), &usc, sizeof(usc));
    n->nlmsg_len += RTA_ALIGN(rta->rta_len);
    
    return QMON_OK;
}

static int tc_set_bandwidth_tbf_netlink(tc_controller_t* tc, int bandwidth_bps,
                                        struct nlmsghdr* n, char* buf, int buf_len) {
    qosmon_context_t* ctx = tc->ctx;
    struct tcmsg* t = NLMSG_DATA(n);
    
    // 设置TBF参数
    struct tc_tbf_qopt opts = {0};
    opts.rate.rate = bandwidth_bps / 8;  // 转换为字节/秒
    opts.limit = ctx->config.tbf_limit;
    opts.buffer = ctx->config.tbf_burst;
    opts.mtu = ctx->config.tbf_mtu;
    opts.peakrate.rate = bandwidth_bps / 8;  // 峰值速率
    
    // 添加TBF参数
    addattr_l(n, buf_len, TCA_OPTIONS, &opts, sizeof(opts));
    
    return QMON_OK;
}

static int tc_set_bandwidth_shell(qosmon_context_t* ctx, int bandwidth_bps) {
    int bandwidth_kbps = (bandwidth_bps + 500) / 1000;
    char cmd[512];
    int ret = 0;
    
    // 根据检测到的队列规则类型生成相应的命令
    if (strcmp(ctx->detected_qdisc, "hfsc") == 0) {
        // 增强的HFSC参数支持
        int m1 = ctx->config.hfsc_m1;
        int d = ctx->config.hfsc_d;
        
        if (m1 > 0 && d > 0) {
            // 包含m1和d参数的完整HFSC曲线
            snprintf(cmd, sizeof(cmd), 
                    "tc class change dev %s parent 1: classid 1:%x hfsc "
                    "ls m1 %db d %dus m2 %dkbit "
                    "ul m1 %db d %dus m2 %dkbit 2>&1",
                    ctx->config.device, ctx->config.classid,
                    m1, d, bandwidth_kbps,
                    m1, d, bandwidth_kbps);
        } else {
            // 简化的HFSC曲线
            snprintf(cmd, sizeof(cmd), 
                    "tc class change dev %s parent 1: classid 1:%x hfsc "
                    "ls m1 0b d 0us m2 %dkbit "
                    "ul m1 0b d 0us m2 %dkbit 2>&1",
                    ctx->config.device, ctx->config.classid, bandwidth_kbps, bandwidth_kbps);
        }
    } else if (strcmp(ctx->detected_qdisc, "tbf") == 0) {
        // TBF队列规则
        int burst = ctx->config.tbf_burst;
        int limit = ctx->config.tbf_limit;
        
        if (burst <= 0) burst = 32 * 1024;  // 默认32KB
        if (limit <= 0) limit = 300 * 1024;  // 默认300KB
        
        snprintf(cmd, sizeof(cmd), 
                "tc class change dev %s parent 1: classid 1:%x tbf "
                "rate %dkbit burst %db limit %db 2>&1",
                ctx->config.device, ctx->config.classid, bandwidth_kbps, burst, limit);
    } else if (strcmp(ctx->detected_qdisc, "drr") == 0) {
        // DRR队列规则
        int quantum = ctx->config.quantum;
        if (quantum <= 0) quantum = 1514;
        
        snprintf(cmd, sizeof(cmd), 
                "tc class change dev %s parent 1: classid 1:%x drr "
                "quantum %d 2>&1",
                ctx->config.device, ctx->config.classid, quantum);
    } else {
        // 默认HTB队列规则
        int buffer = ctx->config.buffer;
        int cbuffer = ctx->config.cbuffer;
        
        if (buffer <= 0) buffer = 1600;
        if (cbuffer <= 0) cbuffer = 1600;
        
        snprintf(cmd, sizeof(cmd), 
                "tc class change dev %s parent 1: classid 1:%x htb "
                "rate %dkbit ceil %dkbit burst %db cburst %db 2>&1",
                ctx->config.device, ctx->config.classid, bandwidth_kbps, bandwidth_kbps,
                buffer, cbuffer);
    }
    
    qosmon_log(ctx, QMON_LOG_INFO, "执行TC命令: %s\n", cmd);
    
    FILE* fp = popen(cmd, "r");
    if (fp) {
        char output[256];
        while (fgets(output, sizeof(output), fp)) {
            char* newline = strchr(output, '\n');
            if (newline) *newline = '\0';
            if (strlen(output) > 0) {
                qosmon_log(ctx, QMON_LOG_DEBUG, "TC输出: %s\n", output);
            }
        }
        ret = pclose(fp);
        
        if (WIFEXITED(ret)) {
            ret = WEXITSTATUS(ret);
        }
    } else {
        ret = -1;
    }
    
    if (ret != 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "TC命令执行失败: 返回码=%d\n", ret);
        return QMON_ERR_SYSTEM;
    }
    
    qosmon_log(ctx, QMON_LOG_INFO, 
              "带宽设置成功: %d kbps (算法: %s)\n", 
              bandwidth_kbps, ctx->detected_qdisc);
    
    return QMON_OK;
}

char* detect_qdisc_kind(qosmon_context_t* ctx) {
    static char qdisc_kind[MAX_QDISC_KIND_LEN] = "htb";
    char cmd[256];
    char line[256];
    
    snprintf(cmd, sizeof(cmd), "tc qdisc show dev %s 2>/dev/null", ctx->config.device);
    qosmon_log(ctx, QMON_LOG_DEBUG, "执行检测命令: %s\n", cmd);
    
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        qosmon_log(ctx, QMON_LOG_ERROR, 
                  "无法执行tc命令检测队列算法: %s\n", strerror(errno));
        return qdisc_kind;
    }
    
    while (fgets(line, sizeof(line), fp)) {
        // 检查各种队列规则类型
        if (strstr(line, "htb") != NULL) {
            strcpy(qdisc_kind, "htb");
            break;
        } else if (strstr(line, "hfsc") != NULL) {
            strcpy(qdisc_kind, "hfsc");
            break;
        } else if (strstr(line, "tbf") != NULL) {
            strcpy(qdisc_kind, "tbf");
            break;
        } else if (strstr(line, "drr") != NULL) {
            strcpy(qdisc_kind, "drr");
            break;
        } else if (strstr(line, "sfq") != NULL) {
            strcpy(qdisc_kind, "sfq");
            break;
        } else if (strstr(line, "codel") != NULL) {
            strcpy(qdisc_kind, "codel");
            break;
        } else if (strstr(line, "fq_codel") != NULL) {
            strcpy(qdisc_kind, "fq_codel");
            break;
        } else if (strstr(line, "pfifo_fast") != NULL) {
            strcpy(qdisc_kind, "pfifo_fast");
            break;
        }
    }
    
    pclose(fp);
    qosmon_log(ctx, QMON_LOG_INFO, "检测到队列算法: %s\n", qdisc_kind);
    
    return qdisc_kind;
}

int detect_class_bandwidth(qosmon_context_t* ctx, int* current_bw_kbps, tc_controller_t* tc) {
    if (!ctx || !current_bw_kbps) return QMON_ERR_MEMORY;
    
    char cmd[256];
    char line[512];
    int found = 0;
    
    snprintf(cmd, sizeof(cmd), 
             "tc class show dev %s parent 1: classid 1:%x 2>/dev/null || "
             "tc class show dev %s parent 1:0 classid 1:%x 2>/dev/null",
             ctx->config.device, ctx->config.classid,
             ctx->config.device, ctx->config.classid);
    
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        return QMON_ERR_SYSTEM;
    }
    
    while (fgets(line, sizeof(line), fp)) {
        char* rate_pos = strstr(line, "rate");
        char* ls_pos = strstr(line, "ls");
        char* ul_pos = strstr(line, "ul");
        char* m2_pos = strstr(line, "m2");
        
        if (rate_pos) {
            // HTB或TBF格式
            int rate_mbit, rate_kbit;
            if (sscanf(rate_pos, "rate %dMbit", &rate_mbit) == 1) {
                *current_bw_kbps = rate_mbit * 1000;
                found = 1;
                break;
            } else if (sscanf(rate_pos, "rate %dkbit", &rate_kbit) == 1) {
                *current_bw_kbps = rate_kbit;
                found = 1;
                break;
            } else if (sscanf(rate_pos, "rate %dbps", current_bw_kbps) == 1) {
                *current_bw_kbps /= 1000;
                found = 1;
                break;
            }
        } else if (ls_pos || ul_pos || m2_pos) {
            // HFSC格式
            int rate_mbit, rate_kbit;
            char* start = ls_pos ? ls_pos : (ul_pos ? ul_pos : m2_pos);
            
            if (sscanf(start, "ls m1 0b d 0us m2 %dMbit", &rate_mbit) == 1 ||
                sscanf(start, "ul m1 0b d 0us m2 %dMbit", &rate_mbit) == 1 ||
                sscanf(start, "m2 %dMbit", &rate_mbit) == 1) {
                *current_bw_kbps = rate_mbit * 1000;
                found = 1;
                break;
            } else if (sscanf(start, "ls m1 0b d 0us m2 %dkbit", &rate_kbit) == 1 ||
                       sscanf(start, "ul m1 0b d 0us m2 %dkbit", &rate_kbit) == 1 ||
                       sscanf(start, "m2 %dkbit", &rate_kbit) == 1) {
                *current_bw_kbps = rate_kbit;
                found = 1;
                break;
            }
        }
    }
    
    pclose(fp);
    
    // 如果检测到HFSC，尝试提取m1和d参数
    if (found && tc && strcmp(ctx->detected_qdisc, "hfsc") == 0) {
        rewind(fp);
        while (fgets(line, sizeof(line), fp)) {
            if (strstr(line, "ls") != NULL || strstr(line, "ul") != NULL) {
                int m1, d;
                if (sscanf(line, "%*s m1 %db d %dus", &m1, &d) == 2) {
                    if (m1 > 0 && ctx->config.hfsc_m1 == 0) {
                        ctx->config.hfsc_m1 = m1;
                        qosmon_log(ctx, QMON_LOG_DEBUG, 
                                  "从现有配置中提取HFSC参数: m1=%d, d=%d\n", m1, d);
                    }
                }
            }
        }
    }
    
    return found ? QMON_OK : QMON_ERR_SYSTEM;
}

void tc_controller_cleanup(tc_controller_t* tc) {
    if (!tc || !tc->ctx) return;
    
    qosmon_context_t* ctx = tc->ctx;
    
    if (!ctx->config.safe_mode) {
        int default_bw = ctx->config.max_bandwidth_kbps * 1000;
        tc_controller_set_bandwidth(tc, default_bw);
        qosmon_log(ctx, QMON_LOG_INFO, 
                  "TC控制器清理: 恢复带宽到 %d kbps\n", 
                  ctx->config.max_bandwidth_kbps);
    }
    
    if (tc->netlink_fd >= 0) {
        netlink_close(tc->netlink_fd);
        tc->netlink_fd = -1;
    }
    
    qosmon_log(ctx, QMON_LOG_INFO, "TC控制器清理完成\n");
}

/* ==================== 配置处理增强 ==================== */
void qosmon_config_init(qosmon_config_t* cfg) {
    if (!cfg) return;
    
    memset(cfg, 0, sizeof(qosmon_config_t));
    
    // 基本参数
    cfg->ping_interval = 200;
    cfg->max_bandwidth_kbps = 10000;
    cfg->ping_limit_ms = 20;
    cfg->classid = 0x101;
    cfg->safe_mode = 0;
    cfg->verbose = 0;
    cfg->auto_switch_mode = 0;
    cfg->background_mode = 0;
    cfg->skip_initial = 0;
    cfg->min_bw_change_kbps = 10;
    cfg->min_bw_ratio = 0.1f;
    cfg->max_bw_ratio = 1.0f;
    cfg->smoothing_factor = 0.3f;
    cfg->active_threshold = 0.7f;
    cfg->idle_threshold = 0.3f;
    cfg->safe_start_ratio = 0.5f;
    
    // TC相关参数
    cfg->use_netlink = 1;           // 默认启用netlink
    cfg->mtu = 1500;                // 默认MTU
    cfg->buffer = 1600;             // HTB缓冲区
    cfg->cbuffer = 1600;            // HTB ceil缓冲区
    cfg->quantum = 1514;            // HTB quantum
    
    // HFSC特定参数
    cfg->hfsc_m1 = 0;               // 实时服务曲线m1
    cfg->hfsc_d = 0;                // 实时服务曲线d
    cfg->hfsc_m2 = 0;               // 实时服务曲线m2（自动计算）
    
    // TBF特定参数
    cfg->tbf_burst = 32 * 1024;     // 32KB突发
    cfg->tbf_limit = 300 * 1024;    // 300KB限制
    cfg->tbf_mtu = 2000;            // TBF MTU
    
    // 网络设备
    strcpy(cfg->device, "ifb0");
    strcpy(cfg->target, "8.8.8.8");
    strcpy(cfg->status_file, "/var/run/qosmon.status");
    strcpy(cfg->debug_log, "/var/log/qosmon.log");
}

int qosmon_config_parse(qosmon_config_t* cfg, int argc, char* argv[]) {
    if (!cfg) return QMON_ERR_MEMORY;
    
    // 设置默认值
    qosmon_config_init(cfg);
    
    // 简单参数解析
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) {
            strncpy(cfg->config_file, argv[++i], sizeof(cfg->config_file) - 1);
        } else if (strcmp(argv[i], "-d") == 0 && i + 1 < argc) {
            strncpy(cfg->device, argv[++i], sizeof(cfg->device) - 1);
        } else if (strcmp(argv[i], "-t") == 0 && i + 1 < argc) {
            strncpy(cfg->target, argv[++i], sizeof(cfg->target) - 1);
        } else if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) {
            strncpy(cfg->status_file, argv[++i], sizeof(cfg->status_file) - 1);
        } else if (strcmp(argv[i], "-l") == 0 && i + 1 < argc) {
            strncpy(cfg->debug_log, argv[++i], sizeof(cfg->debug_log) - 1);
        } else if (strcmp(argv[i], "-v") == 0) {
            cfg->verbose = 1;
        } else if (strcmp(argv[i], "-b") == 0) {
            cfg->background_mode = 1;
        } else if (strcmp(argv[i], "-S") == 0) {
            cfg->safe_mode = 1;
        } else if (strcmp(argv[i], "-A") == 0) {
            cfg->auto_switch_mode = 1;
        } else if (strcmp(argv[i], "-I") == 0) {
            cfg->skip_initial = 1;
        } else if (strcmp(argv[i], "-N") == 0) {
            cfg->use_netlink = 0;  // 禁用netlink
        } else if (strcmp(argv[i], "-M") == 0 && i + 1 < argc) {
            cfg->mtu = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-B") == 0 && i + 1 < argc) {
            cfg->buffer = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-C") == 0 && i + 1 < argc) {
            cfg->cbuffer = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-Q") == 0 && i + 1 < argc) {
            cfg->quantum = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-H1") == 0 && i + 1 < argc) {
            cfg->hfsc_m1 = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-HD") == 0 && i + 1 < argc) {
            cfg->hfsc_d = atoi(argv[++i]);
        } else if (i == 1 && argc >= 4) {
            // 位置参数: ping_interval target max_bandwidth_kbps ping_limit_ms
            cfg->ping_interval = atoi(argv[1]);
            if (argc >= 2) strncpy(cfg->target, argv[2], sizeof(cfg->target) - 1);
            if (argc >= 3) cfg->max_bandwidth_kbps = atoi(argv[3]);
            if (argc >= 4) cfg->ping_limit_ms = atoi(argv[4]);
            i += 3; // 跳过已处理的参数
        }
    }
    
    return QMON_OK;
}

/* ==================== 主函数 ==================== */
int main(int argc, char* argv[]) {
    int ret = EXIT_FAILURE;
    qosmon_context_t context = {0};
    ping_manager_t ping_mgr = {0};
    tc_controller_t tc_mgr = {0};
    
    qosmon_config_init(&context.config);
    
    int config_result = qosmon_config_parse(&context.config, argc, argv);
    if (config_result != QMON_OK) {
        fprintf(stderr, "配置解析失败\n");
        return EXIT_FAILURE;
    }
    
    char config_error[256] = {0};
    if (qosmon_config_validate(&context.config, config_error, sizeof(config_error)) != QMON_OK) {
        fprintf(stderr, "配置验证失败: %s\n", config_error);
        return EXIT_FAILURE;
    }
    
    if (context.config.background_mode) {
        if (daemon(0, 0) < 0) {
            perror("后台运行失败");
            return EXIT_FAILURE;
        }
        openlog("qosmon", LOG_PID, LOG_USER);
    }
    
    if (strlen(context.config.debug_log) > 0) {
        context.debug_log_file = fopen(context.config.debug_log, "a");
        if (!context.debug_log_file) {
            qosmon_log(&context, QMON_LOG_WARN, 
                      "无法打开调试日志文件: %s\n", context.config.debug_log);
        } else {
            qosmon_log(&context, QMON_LOG_INFO, 
                      "调试日志已启用: %s\n", context.config.debug_log);
        }
    }
    
    // 显示TC配置信息
    qosmon_log(&context, QMON_LOG_INFO, "TC配置参数:\n");
    qosmon_log(&context, QMON_LOG_INFO, "  - 使用netlink: %s\n", 
              context.config.use_netlink ? "是" : "否");
    qosmon_log(&context, QMON_LOG_INFO, "  - MTU: %d\n", context.config.mtu);
    qosmon_log(&context, QMON_LOG_INFO, "  - HTB buffer: %d\n", context.config.buffer);
    qosmon_log(&context, QMON_LOG_INFO, "  - HTB cbuffer: %d\n", context.config.cbuffer);
    qosmon_log(&context, QMON_LOG_INFO, "  - Quantum: %d\n", context.config.quantum);
    
    if (context.config.hfsc_m1 > 0) {
        qosmon_log(&context, QMON_LOG_INFO, "  - HFSC m1: %d\n", context.config.hfsc_m1);
        qosmon_log(&context, QMON_LOG_INFO, "  - HFSC d: %d\n", context.config.hfsc_d);
    }
    
    // 初始化
    if (setup_signal_handlers(&context) != QMON_OK) {
        qosmon_log(&context, QMON_LOG_ERROR, "信号处理设置失败\n");
        goto cleanup;
    }
    
    state_machine_init(&context);
    
    char resolve_error[256];
    if (resolve_target(context.config.target, &context.target_addr, 
                       resolve_error, sizeof(resolve_error)) != QMON_OK) {
        qosmon_log(&context, QMON_LOG_ERROR, 
                  "目标地址解析失败: %s\n", resolve_error);
        goto cleanup;
    }
    
    if (ping_manager_init(&ping_mgr, &context) != QMON_OK) {
        qosmon_log(&context, QMON_LOG_ERROR, "ping管理器初始化失败\n");
        goto cleanup;
    }
    
    if (tc_controller_init(&tc_mgr, &context) != QMON_OK) {
        qosmon_log(&context, QMON_LOG_ERROR, "TC控制器初始化失败\n");
        goto cleanup;
    }
    
    if (setpriority(PRIO_PROCESS, 0, -10) < 0) {
        qosmon_log(&context, QMON_LOG_WARN, 
                  "无法设置进程优先级: %s\n", strerror(errno));
    }
    
    qosmon_log(&context, QMON_LOG_INFO, "========================================\n");
    qosmon_log(&context, QMON_LOG_INFO, "QoS监控器启动 (增强版)\n");
    qosmon_log(&context, QMON_LOG_INFO, "目标地址: %s\n", context.config.target);
    qosmon_log(&context, QMON_LOG_INFO, "网络接口: %s\n", context.config.device);
    qosmon_log(&context, QMON_LOG_INFO, "最大带宽: %d kbps\n", context.config.max_bandwidth_kbps);
    qosmon_log(&context, QMON_LOG_INFO, "ping间隔: %d ms\n", context.config.ping_interval);
    qosmon_log(&context, QMON_LOG_INFO, "ping限制: %d ms\n", context.config.ping_limit_ms);
    qosmon_log(&context, QMON_LOG_INFO, "TC类ID: 0x%x\n", context.config.classid);
    qosmon_log(&context, QMON_LOG_INFO, "队列算法: %s\n", context.detected_qdisc);
    qosmon_log(&context, QMON_LOG_INFO, "========================================\n");
    
    qosmon_log(&context, QMON_LOG_INFO, "开始监控循环...\n");
    
    context.state = QMON_CHK;
    context.last_heartbeat_ms = qosmon_time_ms();
    
    if (!context.config.skip_initial) {
        for (int i = 0; i < 5; i++) {
            ping_manager_send(&ping_mgr);
            usleep(context.config.ping_interval * 1000);
        }
    }
    
    while (!context.sigterm) {
        int64_t start_time = qosmon_time_ms();
        
        int ping_result = ping_manager_receive(&ping_mgr);
        if (ping_result > 0) {
            // ping received successfully
        } else if (ping_result < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            qosmon_log(&context, QMON_LOG_ERROR, "接收ping时发生错误\n");
        }
        
        state_machine_run(&context, &ping_mgr, &tc_mgr);
        
        status_file_update(&context);
        
        int64_t elapsed = qosmon_time_ms() - start_time;
        int sleep_time = 10;
        if (elapsed < sleep_time) {
            usleep((sleep_time - elapsed) * 1000);
        } else if (elapsed > 50) {
            qosmon_log(&context, QMON_LOG_DEBUG, "循环处理时间过长: %ld ms\n", elapsed);
        }
        
        if (context.sigterm) {
            qosmon_log(&context, QMON_LOG_INFO, "收到退出信号\n");
            break;
        }
    }
    
    ret = EXIT_SUCCESS;
    
cleanup:
    qosmon_cleanup(&context, &ping_mgr, &tc_mgr);
    
    qosmon_log(&context, QMON_LOG_INFO, "QoS监控器已退出\n");
    
    if (context.config.background_mode) {
        closelog();
    }
    
    return ret;
}