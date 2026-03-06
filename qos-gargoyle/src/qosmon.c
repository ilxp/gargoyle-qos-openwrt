/* qosmon.c - 基于netlink和epoll的QoS监控器
 * 功能：通过ping监控延迟，使用netlink动态调整ifb0根类的带宽
 * 使用epoll模型，比poll更高效
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
#include <sys/epoll.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>
#include <netinet/icmp6.h>
#include <arpa/inet.h>
#include <netdb.h>
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
#define MAX_EPOLL_EVENTS 32
#define EPOLL_TIMEOUT_MS 1000  // epoll等待超时时间(ms)

// 日志级别
#define QMON_LOG_ERROR 0
#define QMON_LOG_WARN  1
#define QMON_LOG_INFO  2
#define QMON_LOG_DEBUG 3

// epoll事件标志
#define EPOLL_EV_PING (1 << 0)
#define EPOLL_EV_SIGNAL (1 << 1)
#define EPOLL_EV_TIMER (1 << 2)

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
    QMON_ERR_QDISC = -8,
    QMON_ERR_EPOLL = -9
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

/* ==================== 定时器结构 ==================== */
typedef struct {
    int64_t expire_time;        // 到期时间(毫秒)
    int id;                     // 定时器ID
    void (*callback)(void*);    // 回调函数
    void* user_data;            // 用户数据
    int repeat;                 // 是否重复
    int interval;               // 重复间隔(毫秒)
} timer_event_t;

/* ==================== epoll事件结构 ==================== */
typedef struct {
    int fd;                     // 文件描述符
    int events;                 // 事件类型
    void (*handler)(void*);     // 事件处理器
    void* data;                 // 附加数据
} epoll_event_desc_t;

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
    
    // epoll相关
    int epoll_fd;
    int signal_pipe[2];
    int timer_fd;
    timer_event_t* timers;
    int timer_count;
    int timer_capacity;
    
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
    
    // 定时任务
    int64_t next_ping_send_ms;
    int64_t next_state_machine_ms;
    int64_t next_status_update_ms;
    
    // 文件
    FILE* status_file;
    FILE* debug_log_file;
    
    // 控制标志
    int sigterm;
} qosmon_context_t;

/* ==================== 时间函数 ==================== */
static int64_t qosmon_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

/* ==================== 日志函数 ==================== */
void qosmon_log(qosmon_context_t* ctx, int level, const char* format, ...) {
    if (!ctx) return;
    
    const char* level_str = NULL;
    switch (level) {
        case QMON_LOG_ERROR: level_str = "ERROR"; break;
        case QMON_LOG_WARN:  level_str = "WARN";  break;
        case QMON_LOG_INFO:  level_str = "INFO";  break;
        case QMON_LOG_DEBUG: level_str = "DEBUG"; break;
        default: level_str = "UNKNOWN"; break;
    }
    
    va_list args;
    char timestamp[32];
    time_t now = time(NULL);
    struct tm* tm_info = localtime(&now);
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", tm_info);
    
    if (ctx->config.background_mode) {
        va_start(args, format);
        char buf[512];
        vsnprintf(buf, sizeof(buf), format, args);
        syslog(LOG_INFO, "[%s] %s", level_str, buf);
        va_end(args);
    } else {
        va_start(args, format);
        printf("[%s] ", timestamp);
        vprintf(format, args);
        va_end(args);
    }
    
    if (ctx->debug_log_file) {
        va_start(args, format);
        fprintf(ctx->debug_log_file, "[%s] [%s] ", timestamp, level_str);
        vfprintf(ctx->debug_log_file, format, args);
        fflush(ctx->debug_log_file);
        va_end(args);
    }
}

/* ==================== epoll定时器管理 ==================== */

// 创建定时器文件描述符
static int create_timer_fd(void) {
    int fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (fd < 0) {
        qosmon_log(NULL, QMON_LOG_ERROR, "创建timerfd失败: %s\n", strerror(errno));
    }
    return fd;
}

// 添加定时器
static int epoll_add_timer(qosmon_context_t* ctx, int64_t expire_time, 
                          int id, void (*callback)(void*), void* user_data,
                          int repeat, int interval) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    // 确保timers数组有足够空间
    if (ctx->timer_count >= ctx->timer_capacity) {
        int new_capacity = ctx->timer_capacity == 0 ? 16 : ctx->timer_capacity * 2;
        timer_event_t* new_timers = realloc(ctx->timers, new_capacity * sizeof(timer_event_t));
        if (!new_timers) {
            return QMON_ERR_MEMORY;
        }
        ctx->timers = new_timers;
        ctx->timer_capacity = new_capacity;
    }
    
    // 添加定时器
    timer_event_t* timer = &ctx->timers[ctx->timer_count++];
    timer->expire_time = expire_time;
    timer->id = id;
    timer->callback = callback;
    timer->user_data = user_data;
    timer->repeat = repeat;
    timer->interval = interval;
    
    // 设置timerfd
    if (ctx->timer_fd >= 0) {
        struct itimerspec its = {0};
        
        // 找到最早的定时器
        int64_t earliest = INT64_MAX;
        for (int i = 0; i < ctx->timer_count; i++) {
            if (ctx->timers[i].expire_time < earliest) {
                earliest = ctx->timers[i].expire_time;
            }
        }
        
        if (earliest != INT64_MAX) {
            int64_t now = qosmon_time_ms();
            int64_t diff = earliest - now;
            if (diff < 0) diff = 0;
            
            its.it_value.tv_sec = diff / 1000;
            its.it_value.tv_nsec = (diff % 1000) * 1000000;
            
            if (timerfd_settime(ctx->timer_fd, 0, &its, NULL) < 0) {
                qosmon_log(ctx, QMON_LOG_ERROR, "设置timerfd失败: %s\n", strerror(errno));
            }
        }
    }
    
    return QMON_OK;
}

// 删除定时器
static int epoll_remove_timer(qosmon_context_t* ctx, int id) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    for (int i = 0; i < ctx->timer_count; i++) {
        if (ctx->timers[i].id == id) {
            // 移动最后一个元素到当前位置
            if (i < ctx->timer_count - 1) {
                ctx->timers[i] = ctx->timers[ctx->timer_count - 1];
            }
            ctx->timer_count--;
            return QMON_OK;
        }
    }
    
    return QMON_ERR_SYSTEM;
}

// 处理定时器
static void epoll_handle_timers(qosmon_context_t* ctx) {
    if (!ctx || !ctx->timers || ctx->timer_count == 0) return;
    
    int64_t now = qosmon_time_ms();
    int processed = 0;
    
    // 处理到期的定时器
    for (int i = 0; i < ctx->timer_count; i++) {
        timer_event_t* timer = &ctx->timers[i];
        if (timer->expire_time <= now) {
            // 执行回调
            if (timer->callback) {
                timer->callback(timer->user_data);
            }
            
            processed++;
            
            // 如果是重复定时器，重新计算到期时间
            if (timer->repeat) {
                timer->expire_time = now + timer->interval;
            } else {
                // 删除一次性定时器
                epoll_remove_timer(ctx, timer->id);
                i--;  // 因为元素被移动了
            }
        }
    }
    
    if (processed > 0 && ctx->timer_count > 0) {
        // 重新设置timerfd
        int64_t earliest = INT64_MAX;
        for (int i = 0; i < ctx->timer_count; i++) {
            if (ctx->timers[i].expire_time < earliest) {
                earliest = ctx->timers[i].expire_time;
            }
        }
        
        if (earliest != INT64_MAX) {
            int64_t diff = earliest - now;
            if (diff < 0) diff = 0;
            
            struct itimerspec its = {0};
            its.it_value.tv_sec = diff / 1000;
            its.it_value.tv_nsec = (diff % 1000) * 1000000;
            
            if (timerfd_settime(ctx->timer_fd, 0, &its, NULL) < 0) {
                qosmon_log(ctx, QMON_LOG_ERROR, "更新timerfd失败: %s\n", strerror(errno));
            }
        }
    }
}

/* ==================== 信号处理 ==================== */

// 信号处理函数
static void signal_handler(int sig) {
    // 在主循环中处理信号
}

// 设置信号处理
static int setup_signal_handlers(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_IGN;
    sa.sa_flags = SA_RESTART;
    
    // 忽略SIGPIPE
    if (sigaction(SIGPIPE, &sa, NULL) < 0) {
        return QMON_ERR_SIGNAL;
    }
    
    // 设置SIGTERM和SIGINT处理
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sa.sa_flags = SA_RESTART;
    
    if (sigaction(SIGTERM, &sa, NULL) < 0 ||
        sigaction(SIGINT, &sa, NULL) < 0) {
        return QMON_ERR_SIGNAL;
    }
    
    return QMON_OK;
}

// 设置信号管道
static int setup_signal_pipe(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    if (pipe(ctx->signal_pipe) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建信号管道失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
    }
    
    // 设置非阻塞
    for (int i = 0; i < 2; i++) {
        int flags = fcntl(ctx->signal_pipe[i], F_GETFL, 0);
        if (flags < 0 || fcntl(ctx->signal_pipe[i], F_SETFL, flags | O_NONBLOCK) < 0) {
            close(ctx->signal_pipe[0]);
            close(ctx->signal_pipe[1]);
            return QMON_ERR_SYSTEM;
        }
    }
    
    return QMON_OK;
}

/* ==================== epoll事件管理 ==================== */

// 初始化epoll
static int epoll_init(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    // 创建epoll实例
    ctx->epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (ctx->epoll_fd < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建epoll实例失败: %s\n", strerror(errno));
        return QMON_ERR_EPOLL;
    }
    
    // 创建timerfd
    ctx->timer_fd = create_timer_fd();
    if (ctx->timer_fd < 0) {
        close(ctx->epoll_fd);
        return QMON_ERR_EPOLL;
    }
    
    // 初始化定时器数组
    ctx->timers = NULL;
    ctx->timer_count = 0;
    ctx->timer_capacity = 0;
    
    qosmon_log(ctx, QMON_LOG_DEBUG, "epoll初始化完成，fd=%d\n", ctx->epoll_fd);
    return QMON_OK;
}

// 向epoll添加文件描述符
static int epoll_add_fd(qosmon_context_t* ctx, int fd, uint32_t events, 
                       void (*handler)(void*), void* data) {
    if (!ctx || fd < 0) return QMON_ERR_MEMORY;
    
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = events;
    
    // 创建事件描述结构
    epoll_event_desc_t* desc = malloc(sizeof(epoll_event_desc_t));
    if (!desc) {
        return QMON_ERR_MEMORY;
    }
    
    desc->fd = fd;
    desc->events = events;
    desc->handler = handler;
    desc->data = data;
    ev.data.ptr = desc;
    
    if (epoll_ctl(ctx->epoll_fd, EPOLL_CTL_ADD, fd, &ev) < 0) {
        free(desc);
        qosmon_log(ctx, QMON_LOG_ERROR, "添加fd到epoll失败: %s\n", strerror(errno));
        return QMON_ERR_EPOLL;
    }
    
    qosmon_log(ctx, QMON_LOG_DEBUG, "epoll添加fd=%d，events=0x%x\n", fd, events);
    return QMON_OK;
}

// 从epoll移除文件描述符
static int epoll_remove_fd(qosmon_context_t* ctx, int fd) {
    if (!ctx || fd < 0 || ctx->epoll_fd < 0) return QMON_ERR_MEMORY;
    
    if (epoll_ctl(ctx->epoll_fd, EPOLL_CTL_DEL, fd, NULL) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "从epoll移除fd失败: %s\n", strerror(errno));
        return QMON_ERR_EPOLL;
    }
    
    qosmon_log(ctx, QMON_LOG_DEBUG, "epoll移除fd=%d\n", fd);
    return QMON_OK;
}

// 修改epoll中的文件描述符
static int epoll_modify_fd(qosmon_context_t* ctx, int fd, uint32_t events, 
                          void (*handler)(void*), void* data) {
    if (!ctx || fd < 0 || ctx->epoll_fd < 0) return QMON_ERR_MEMORY;
    
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = events;
    
    // 创建新的事件描述结构
    epoll_event_desc_t* desc = malloc(sizeof(epoll_event_desc_t));
    if (!desc) {
        return QMON_ERR_MEMORY;
    }
    
    desc->fd = fd;
    desc->events = events;
    desc->handler = handler;
    desc->data = data;
    ev.data.ptr = desc;
    
    if (epoll_ctl(ctx->epoll_fd, EPOLL_CTL_MOD, fd, &ev) < 0) {
        free(desc);
        qosmon_log(ctx, QMON_LOG_ERROR, "修改epoll fd失败: %s\n", strerror(errno));
        return QMON_ERR_EPOLL;
    }
    
    qosmon_log(ctx, QMON_LOG_DEBUG, "epoll修改fd=%d，events=0x%x\n", fd, events);
    return QMON_OK;
}

// 清理epoll资源
static void epoll_cleanup(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    if (ctx->epoll_fd >= 0) {
        close(ctx->epoll_fd);
        ctx->epoll_fd = -1;
    }
    
    if (ctx->timer_fd >= 0) {
        close(ctx->timer_fd);
        ctx->timer_fd = -1;
    }
    
    if (ctx->signal_pipe[0] >= 0) {
        close(ctx->signal_pipe[0]);
    }
    if (ctx->signal_pipe[1] >= 0) {
        close(ctx->signal_pipe[1]);
    }
    
    if (ctx->timers) {
        free(ctx->timers);
        ctx->timers = NULL;
    }
    
    ctx->timer_count = 0;
    ctx->timer_capacity = 0;
}

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
    
    n->nlmsg_seq = ++seq;
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

/* ==================== 事件处理器 ==================== */

// ping事件处理器
static void ping_event_handler(void* data) {
    qosmon_context_t* ctx = (qosmon_context_t*)data;
    if (!ctx) return;
    
    int ping_result = ping_manager_receive(ctx);
    if (ping_result > 0) {
        qosmon_log(ctx, QMON_LOG_DEBUG, "收到ping响应\n");
    } else if (ping_result < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
        qosmon_log(ctx, QMON_LOG_ERROR, "接收ping时发生错误\n");
    }
}

// 信号事件处理器
static void signal_event_handler(void* data) {
    qosmon_context_t* ctx = (qosmon_context_t*)data;
    if (!ctx) return;
    
    char buf[16];
    ssize_t n = read(ctx->signal_pipe[0], buf, sizeof(buf));
    if (n > 0) {
        qosmon_log(ctx, QMON_LOG_INFO, "收到信号，准备退出\n");
        ctx->sigterm = 1;
    }
}

// 定时器事件处理器
static void timer_event_handler(void* data) {
    qosmon_context_t* ctx = (qosmon_context_t*)data;
    if (!ctx) return;
    
    // 读取timerfd，避免后续事件
    uint64_t expirations;
    ssize_t n = read(ctx->timer_fd, &expirations, sizeof(expirations));
    if (n != sizeof(expirations)) {
        qosmon_log(ctx, QMON_LOG_WARN, "读取timerfd失败\n");
    }
    
    // 处理到期的定时器
    epoll_handle_timers(ctx);
}

// ping发送定时器回调
static void ping_timer_callback(void* data) {
    qosmon_context_t* ctx = (qosmon_context_t*)data;
    if (!ctx) return;
    
    int ret = ping_manager_send(ctx);
    if (ret != QMON_OK) {
        qosmon_log(ctx, QMON_LOG_ERROR, "发送ping失败\n");
    }
    
    // 设置下一次ping发送
    int64_t now = qosmon_time_ms();
    int64_t next_ping = now + ctx->config.ping_interval;
    epoll_add_timer(ctx, next_ping, 1, ping_timer_callback, ctx, 1, ctx->config.ping_interval);
}

// 状态机处理定时器回调
static void state_machine_timer_callback(void* data) {
    qosmon_context_t* ctx = (qosmon_context_t*)data;
    if (!ctx) return;
    
    state_machine_run(ctx, NULL, NULL);
    
    // 设置下一次状态机处理
    int64_t now = qosmon_time_ms();
    int64_t next_state = now + 10;  // 10ms后再次运行状态机
    epoll_add_timer(ctx, next_state, 2, state_machine_timer_callback, ctx, 1, 10);
}

// 状态更新定时器回调
static void status_update_timer_callback(void* data) {
    qosmon_context_t* ctx = (qosmon_context_t*)data;
    if (!ctx) return;
    
    status_file_update(ctx);
    
    // 设置下一次状态更新
    int64_t now = qosmon_time_ms();
    int64_t next_status = now + 1000;  // 1秒后更新状态
    epoll_add_timer(ctx, next_status, 3, status_update_timer_callback, ctx, 1, 1000);
}

// 带宽调整定时器回调
static void bandwidth_adjust_timer_callback(void* data) {
    qosmon_context_t* ctx = (qosmon_context_t*)data;
    if (!ctx) return;
    
    // 检查是否需要调整带宽
    int64_t now = qosmon_time_ms();
    if (now - ctx->last_tc_update_time_ms >= CONTROL_INTERVAL_MS) {
        adjust_bandwidth_by_ping(ctx, NULL);
        ctx->last_tc_update_time_ms = now;
    }
    
    // 设置下一次带宽调整
    int64_t next_adjust = now + CONTROL_INTERVAL_MS;
    epoll_add_timer(ctx, next_adjust, 4, bandwidth_adjust_timer_callback, ctx, 1, CONTROL_INTERVAL_MS);
}

/* ==================== 状态机实现 ==================== */
void state_machine_init(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    ctx->state = QMON_CHK;
    ctx->current_limit_bps = ctx->config.max_bandwidth_kbps * 1000;
    ctx->saved_active_limit = 0;
    ctx->saved_realtime_limit = 0;
    
    // 初始化ping历史
    memset(&ctx->ping_history, 0, sizeof(ctx->ping_history));
    ctx->ping_history.smoothed = ctx->config.ping_limit_ms * 1000.0f;
    
    // 初始化时间戳
    int64_t now = qosmon_time_ms();
    ctx->last_ping_time_ms = now;
    ctx->last_stats_time_ms = now;
    ctx->last_tc_update_time_ms = now;
    ctx->last_realtime_detect_time_ms = now;
    ctx->last_heartbeat_ms = now;
    
    // 初始化统计
    memset(&ctx->stats, 0, sizeof(ctx->stats));
    ctx->stats.start_time = now;
    
    qosmon_log(ctx, QMON_LOG_INFO, "状态机初始化完成\n");
}

void state_machine_run(qosmon_context_t* ctx, ping_manager_t* ping_mgr, tc_controller_t* tc_mgr) {
    if (!ctx) return;
    
    int64_t now = qosmon_time_ms();
    
    // 更新心跳
    if (now - ctx->last_heartbeat_ms >= HEARTBEAT_INTERVAL_MS) {
        ctx->last_heartbeat_ms = now;
        qosmon_log(ctx, QMON_LOG_DEBUG, "心跳检测: 状态=%d, 当前带宽=%d kbps\n", 
                  ctx->state, ctx->current_limit_bps / 1000);
    }
    
    // 根据状态执行不同逻辑
    switch (ctx->state) {
        case QMON_CHK:
            state_machine_chk(ctx, now, ping_mgr, tc_mgr);
            break;
        case QMON_INIT:
            state_machine_init_state(ctx, now, ping_mgr, tc_mgr);
            break;
        case QMON_IDLE:
            state_machine_idle(ctx, now, ping_mgr, tc_mgr);
            break;
        case QMON_ACTIVE:
            state_machine_active(ctx, now, ping_mgr, tc_mgr);
            break;
        case QMON_REALTIME:
            state_machine_realtime(ctx, now, ping_mgr, tc_mgr);
            break;
        case QMON_EXIT:
            // 退出状态
            ctx->sigterm = 1;
            break;
    }
    
    // 更新统计信息
    if (now - ctx->last_stats_time_ms >= STATS_INTERVAL_MS) {
        update_statistics(ctx);
        ctx->last_stats_time_ms = now;
    }
}

static void state_machine_chk(qosmon_context_t* ctx, int64_t now, 
                             ping_manager_t* ping_mgr, tc_controller_t* tc_mgr) {
    // 检查状态
    qosmon_log(ctx, QMON_LOG_INFO, "状态: CHK (检查)\n");
    
    // 检查网络接口
    if (!ctx->detected_qdisc[0]) {
        strcpy(ctx->detected_qdisc, "fq_codel");  // 默认值
    }
    
    // 检查目标地址
    if (!ctx->config.target[0]) {
        qosmon_log(ctx, QMON_LOG_ERROR, "未指定目标地址\n");
        ctx->state = QMON_EXIT;
        return;
    }
    
    // 检查网络设备
    if (!ctx->config.device[0]) {
        qosmon_log(ctx, QMON_LOG_ERROR, "未指定网络设备\n");
        ctx->state = QMON_EXIT;
        return;
    }
    
    ctx->state = QMON_INIT;
}

static void state_machine_init_state(qosmon_context_t* ctx, int64_t now,
                                    ping_manager_t* ping_mgr, tc_controller_t* tc_mgr) {
    qosmon_log(ctx, QMON_LOG_INFO, "状态: INIT (初始化)\n");
    
    // 保存当前带宽限制
    ctx->saved_active_limit = ctx->current_limit_bps;
    ctx->saved_realtime_limit = 0;
    
    // 计算初始带宽
    int initial_bw = (int)(ctx->config.safe_start_ratio * ctx->config.max_bandwidth_kbps * 1000);
    int min_bw = (int)(ctx->config.min_bw_ratio * ctx->config.max_bandwidth_kbps * 1000);
    int max_bw = (int)(ctx->config.max_bw_ratio * ctx->config.max_bandwidth_kbps * 1000);
    
    if (initial_bw < min_bw) {
        initial_bw = min_bw;
    }
    if (initial_bw > max_bw) {
        initial_bw = max_bw;
    }
    
    ctx->current_limit_bps = initial_bw;
    
    // 应用带宽限制
    if (tc_mgr) {
        int ret = tc_controller_set_bandwidth(tc_mgr, initial_bw);
        if (ret != QMON_OK) {
            qosmon_log(ctx, QMON_LOG_ERROR, "设置初始带宽失败\n");
        }
    }
    
    ctx->state = QMON_IDLE;
    ctx->last_tc_update_time_ms = now;
    
    qosmon_log(ctx, QMON_LOG_INFO, 
              "初始化完成: 初始带宽=%d kbps (安全模式启动)\n", 
              initial_bw / 1000);
}

static void state_machine_idle(qosmon_context_t* ctx, int64_t now,
                              ping_manager_t* ping_mgr, tc_controller_t* tc_mgr) {
    // 空闲状态: 网络空闲，带宽较低
    
    // 检查是否需要切换到活动状态
    float current_ping_ms = ctx->filtered_ping_time_us / 1000.0f;
    float active_threshold = ctx->config.active_threshold * ctx->config.ping_limit_ms;
    
    if (current_ping_ms > active_threshold) {
        ctx->state = QMON_ACTIVE;
        qosmon_log(ctx, QMON_LOG_INFO, 
                  "检测到网络活动，切换到ACTIVE状态 (延迟: %.1f ms > %.1f ms)\n",
                  current_ping_ms, active_threshold);
        return;
    }
    
    // 如果延迟低于阈值，可以缓慢增加带宽
    if (now - ctx->last_tc_update_time_ms >= CONTROL_INTERVAL_MS) {
        int target_bw = ctx->current_limit_bps;
        int max_bw = (int)(ctx->config.max_bw_ratio * ctx->config.max_bandwidth_kbps * 1000);
        
        if (target_bw < max_bw) {
            // 缓慢增加带宽
            int increase = max_bw / 20;  // 每次增加5%
            target_bw += increase;
            if (target_bw > max_bw) {
                target_bw = max_bw;
            }
            
            if (target_bw != ctx->current_limit_bps) {
                int old_bw = ctx->current_limit_bps;
                ctx->current_limit_bps = target_bw;
                if (tc_mgr) {
                    tc_controller_set_bandwidth(tc_mgr, target_bw);
                }
                ctx->last_tc_update_time_ms = now;
                
                qosmon_log(ctx, QMON_LOG_DEBUG, 
                          "空闲状态: 增加带宽到 %d kbps (%d -> %d)\n", 
                          target_bw / 1000, old_bw / 1000, target_bw / 1000);
            }
        }
    }
}

static void state_machine_active(qosmon_context_t* ctx, int64_t now,
                                ping_manager_t* ping_mgr, tc_controller_t* tc_mgr) {
    // 活动状态: 网络活跃，需要控制延迟
    
    // 检查是否需要切换到空闲状态
    float current_ping_ms = ctx->filtered_ping_time_us / 1000.0f;
    float idle_threshold = ctx->config.idle_threshold * ctx->config.ping_limit_ms;
    
    if (current_ping_ms < idle_threshold) {
        ctx->state = QMON_IDLE;
        qosmon_log(ctx, QMON_LOG_INFO, 
                  "网络恢复空闲，切换到IDLE状态 (延迟: %.1f ms < %.1f ms)\n",
                  current_ping_ms, idle_threshold);
        return;
    }
    
    // 检查是否需要切换到实时状态
    if (ctx->config.auto_switch_mode) {
        if (now - ctx->last_realtime_detect_time_ms >= REALTIME_DETECT_MS) {
            if (detect_realtime_traffic(ctx)) {
                ctx->state = QMON_REALTIME;
                ctx->last_realtime_detect_time_ms = now;
                qosmon_log(ctx, QMON_LOG_INFO, "检测到实时流量，切换到REALTIME状态\n");
                return;
            }
            ctx->last_realtime_detect_time_ms = now;
        }
    }
    
    // 根据延迟调整带宽
    if (now - ctx->last_tc_update_time_ms >= CONTROL_INTERVAL_MS) {
        adjust_bandwidth_by_ping(ctx, tc_mgr);
        ctx->last_tc_update_time_ms = now;
    }
}

static void state_machine_realtime(qosmon_context_t* ctx, int64_t now,
                                  ping_manager_t* ping_mgr, tc_controller_t* tc_mgr) {
    // 实时状态: 有实时流量，需要严格限制延迟
    
    // 检查是否需要退出实时状态
    if (now - ctx->last_realtime_detect_time_ms >= REALTIME_DETECT_MS) {
        if (!detect_realtime_traffic(ctx)) {
            ctx->state = QMON_ACTIVE;
            ctx->last_realtime_detect_time_ms = now;
            qosmon_log(ctx, QMON_LOG_INFO, "实时流量结束，切换回ACTIVE状态\n");
            return;
        }
        ctx->last_realtime_detect_time_ms = now;
    }
    
    // 实时模式下更积极地降低带宽
    if (now - ctx->last_tc_update_time_ms >= CONTROL_INTERVAL_MS / 2) {  // 更快响应
        int target_bw = calculate_realtime_bandwidth(ctx);
        
        if (target_bw != ctx->current_limit_bps) {
            int old_bw = ctx->current_limit_bps;
            ctx->current_limit_bps = target_bw;
            if (tc_mgr) {
                tc_controller_set_bandwidth(tc_mgr, target_bw);
            }
            ctx->last_tc_update_time_ms = now;
            
            qosmon_log(ctx, QMON_LOG_DEBUG, 
                      "实时状态: 调整带宽 %d kbps -> %d kbps (延迟: %.1f ms)\n", 
                      old_bw / 1000, target_bw / 1000,
                      ctx->filtered_ping_time_us / 1000.0f);
        }
    }
}

static int detect_realtime_traffic(qosmon_context_t* ctx) {
    if (ctx->ping_history.count < 5) {
        return 0;  // 没有足够的ping历史
    }
    
    // 计算延迟抖动
    float jitter = calculate_ping_jitter(ctx);
    float avg_ping = ctx->ping_history.smoothed;
    float ping_limit_us = ctx->config.ping_limit_ms * 1000.0f;
    
    // 高抖动可能是实时流量的迹象
    if (jitter > ping_limit_us * 0.3f) {
        return 1;
    }
    
    // 延迟持续高也可能是实时流量
    if (avg_ping > ping_limit_us * 0.8f) {
        int high_ping_count = 0;
        for (int i = 0; i < ctx->ping_history.count && i < PING_HISTORY_SIZE; i++) {
            int idx = (ctx->ping_history.index - i - 1 + PING_HISTORY_SIZE) % PING_HISTORY_SIZE;
            if (ctx->ping_history.times[idx] > ping_limit_us * 0.7f) {
                high_ping_count++;
            }
        }
        
        if (high_ping_count >= ctx->ping_history.count * 0.8) {
            return 1;
        }
    }
    
    return 0;
}

static float calculate_ping_jitter(qosmon_context_t* ctx) {
    if (ctx->ping_history.count < 2) {
        return 0.0f;
    }
    
    float sum = 0.0f;
    int count = 0;
    
    for (int i = 0; i < ctx->ping_history.count - 1 && i < PING_HISTORY_SIZE - 1; i++) {
        int idx1 = (ctx->ping_history.index - i - 1 + PING_HISTORY_SIZE) % PING_HISTORY_SIZE;
        int idx2 = (ctx->ping_history.index - i - 2 + PING_HISTORY_SIZE) % PING_HISTORY_SIZE;
        
        if (ctx->ping_history.times[idx1] > 0 && ctx->ping_history.times[idx2] > 0) {
            float diff = fabsf(ctx->ping_history.times[idx1] - ctx->ping_history.times[idx2]);
            sum += diff;
            count++;
        }
    }
    
    if (count > 0) {
        return sum / count;
    }
    
    return 0.0f;
}

static int calculate_realtime_bandwidth(qosmon_context_t* ctx) {
    float ping_ratio = (float)ctx->filtered_ping_time_us / (ctx->config.ping_limit_ms * 1000.0f);
    
    // 在实时模式下，更积极地降低带宽
    float reduction_factor = 1.0f;
    if (ping_ratio > 1.5f) {
        reduction_factor = 0.5f;  // 降低50%
    } else if (ping_ratio > 1.2f) {
        reduction_factor = 0.7f;  // 降低30%
    } else if (ping_ratio > 1.0f) {
        reduction_factor = 0.8f;  // 降低20%
    } else if (ping_ratio > 0.8f) {
        reduction_factor = 0.9f;  // 降低10%
    } else if (ping_ratio > 0.6f) {
        reduction_factor = 0.95f; // 降低5%
    } else {
        reduction_factor = 1.0f;  // 保持
    }
    
    int target_bw = (int)(ctx->current_limit_bps * reduction_factor);
    int min_bw = (int)(ctx->config.min_bw_ratio * ctx->config.max_bandwidth_kbps * 1000);
    
    if (target_bw < min_bw) {
        target_bw = min_bw;
    }
    
    return target_bw;
}

static void adjust_bandwidth_by_ping(qosmon_context_t* ctx, tc_controller_t* tc_mgr) {
    if (ctx->filtered_ping_time_us <= 0) {
        return;  // 没有有效的ping数据
    }
    
    float ping_ratio = (float)ctx->filtered_ping_time_us / (ctx->config.ping_limit_ms * 1000.0f);
    int old_bw = ctx->current_limit_bps;
    int target_bw = old_bw;
    
    if (ping_ratio > 1.0f) {
        // 延迟超过限制，降低带宽
        float overshoot = ping_ratio - 1.0f;
        float reduction = 1.0f - overshoot * ctx->config.smoothing_factor;
        
        // 限制降低幅度
        if (reduction < 0.5f) reduction = 0.5f;  // 最多降低50%
        if (reduction > 0.95f) reduction = 0.95f; // 最少降低5%
        
        target_bw = (int)(old_bw * reduction);
        
        qosmon_log(ctx, QMON_LOG_DEBUG, "延迟过高: %.1f ms (限制: %.1f ms), 降低带宽 %.0f%%\n",
                  ctx->filtered_ping_time_us / 1000.0f,
                  ctx->config.ping_limit_ms,
                  (1.0f - reduction) * 100.0f);
    } else if (ping_ratio < 0.7f) {
        // 延迟很低，可以增加带宽
        float margin = 0.7f - ping_ratio;
        float increase = 1.0f + margin * ctx->config.smoothing_factor;
        
        // 限制增加幅度
        if (increase > 1.2f) increase = 1.2f;  // 最多增加20%
        if (increase < 1.05f) increase = 1.05f; // 最少增加5%
        
        target_bw = (int)(old_bw * increase);
        
        qosmon_log(ctx, QMON_LOG_DEBUG, "延迟很低: %.1f ms (限制: %.1f ms), 增加带宽 %.0f%%\n",
                  ctx->filtered_ping_time_us / 1000.0f,
                  ctx->config.ping_limit_ms,
                  (increase - 1.0f) * 100.0f);
    } else {
        // 延迟在正常范围内，保持当前带宽
        qosmon_log(ctx, QMON_LOG_DEBUG, "延迟正常: %.1f ms (限制: %.1f ms), 保持带宽\n",
                  ctx->filtered_ping_time_us / 1000.0f,
                  ctx->config.ping_limit_ms);
        return;
    }
    
    // 确保带宽在合理范围内
    int max_bw = (int)(ctx->config.max_bw_ratio * ctx->config.max_bandwidth_kbps * 1000);
    int min_bw = (int)(ctx->config.min_bw_ratio * ctx->config.max_bandwidth_kbps * 1000);
    
    if (target_bw > max_bw) target_bw = max_bw;
    if (target_bw < min_bw) target_bw = min_bw;
    
    // 检查是否需要更新
    int diff = target_bw - old_bw;
    if (diff < 0) diff = -diff;
    
    int min_change = ctx->config.min_bw_change_kbps * 1000;
    if (diff >= min_change) {
        ctx->current_limit_bps = target_bw;
        if (tc_mgr) {
            int ret = tc_controller_set_bandwidth(tc_mgr, target_bw);
            if (ret != QMON_OK) {
                qosmon_log(ctx, QMON_LOG_ERROR, "设置带宽失败: %d -> %d kbps\n", 
                          old_bw / 1000, target_bw / 1000);
                ctx->current_limit_bps = old_bw;  // 恢复原值
            } else {
                qosmon_log(ctx, QMON_LOG_INFO, 
                          "调整带宽: %d kbps -> %d kbps (延迟: %.1f ms, 比率: %.2f)\n", 
                          old_bw / 1000, target_bw / 1000,
                          ctx->filtered_ping_time_us / 1000.0f, ping_ratio);
            }
        } else {
            qosmon_log(ctx, QMON_LOG_WARN, "TC管理器未初始化，无法设置带宽\n");
        }
    } else {
        qosmon_log(ctx, QMON_LOG_DEBUG, "带宽变化太小(%d kbps)，跳过调整\n", diff / 1000);
    }
}

static void update_statistics(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    int64_t now = qosmon_time_ms();
    int64_t elapsed = now - ctx->stats.start_time;
    
    if (elapsed <= 0) return;
    
    // 更新统计
    ctx->stats.total_time_ms = elapsed;
    
    // 计算平均带宽（如果可用）
    if (ctx->current_limit_bps > 0) {
        ctx->stats.avg_bandwidth_kbps = ctx->current_limit_bps / 1000;
    }
    
    // 计算丢包率
    if (ctx->ntransmitted > 0) {
        ctx->stats.packet_loss_rate = 1.0f - (float)ctx->nreceived / ctx->ntransmitted;
    }
    
    // 更新状态文件
    status_file_update(ctx);
    
    if (ctx->config.verbose) {
        qosmon_log(ctx, QMON_LOG_INFO, 
                  "状态统计: 状态=%d, 带宽=%d kbps, 延迟=%.1f ms, 丢包率=%.1f%%, 运行时间=%ld秒\n",
                  ctx->state, ctx->current_limit_bps / 1000,
                  ctx->filtered_ping_time_us / 1000.0f,
                  ctx->stats.packet_loss_rate * 100.0f,
                  elapsed / 1000);
    }
}

/* ==================== Ping管理器实现 ==================== */
int ping_manager_init(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    // 创建raw socket
    ctx->ping_socket = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
    if (ctx->ping_socket < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建ping socket失败: %s\n", strerror(errno));
        return QMON_ERR_SOCKET;
    }
    
    // 设置socket选项
    int ttl = 64;
    if (setsockopt(ctx->ping_socket, IPPROTO_IP, IP_TTL, &ttl, sizeof(ttl)) < 0) {
        qosmon_log(ctx, QMON_LOG_WARN, "设置TTL失败: %s\n", strerror(errno));
    }
    
    int on = 1;
    if (setsockopt(ctx->ping_socket, SOL_SOCKET, SO_TIMESTAMP, &on, sizeof(on)) < 0) {
        qosmon_log(ctx, QMON_LOG_WARN, "设置时间戳失败: %s\n", strerror(errno));
    }
    
    // 设置接收超时
    struct timeval tv = {1, 0};  // 1秒超时
    if (setsockopt(ctx->ping_socket, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) {
        qosmon_log(ctx, QMON_LOG_WARN, "设置接收超时失败: %s\n", strerror(errno));
    }
    
    // 设置非阻塞
    int flags = fcntl(ctx->ping_socket, F_GETFL, 0);
    if (flags < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "获取socket标志失败: %s\n", strerror(errno));
        close(ctx->ping_socket);
        ctx->ping_socket = -1;
        return QMON_ERR_SOCKET;
    }
    
    if (fcntl(ctx->ping_socket, F_SETFL, flags | O_NONBLOCK) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "设置socket非阻塞失败: %s\n", strerror(errno));
        close(ctx->ping_socket);
        ctx->ping_socket = -1;
        return QMON_ERR_SOCKET;
    }
    
    // 初始化目标地址
    struct sockaddr_in* addr_in = (struct sockaddr_in*)&ctx->target_addr;
    memset(addr_in, 0, sizeof(*addr_in));
    addr_in->sin_family = AF_INET;
    
    // 解析目标地址
    struct hostent* host = gethostbyname(ctx->config.target);
    if (!host) {
        qosmon_log(ctx, QMON_LOG_ERROR, "解析目标地址失败: %s\n", ctx->config.target);
        close(ctx->ping_socket);
        ctx->ping_socket = -1;
        return QMON_ERR_NETWORK;
    }
    
    memcpy(&addr_in->sin_addr, host->h_addr_list[0], host->h_length);
    
    // 生成标识符
    ctx->ident = getpid() & 0xFFFF;
    ctx->sequence = 0;
    ctx->ntransmitted = 0;
    ctx->nreceived = 0;
    
    qosmon_log(ctx, QMON_LOG_INFO, "Ping管理器初始化完成，标识符: %d, 目标: %s\n", 
              ctx->ident, inet_ntoa(addr_in->sin_addr));
    return QMON_OK;
}

int ping_manager_send(qosmon_context_t* ctx) {
    if (!ctx || ctx->ping_socket < 0) return QMON_ERR_SOCKET;
    
    struct icmphdr icmp_hdr;
    char packet[64];
    int packet_len = sizeof(packet);
    
    // 构建ICMP包
    memset(&icmp_hdr, 0, sizeof(icmp_hdr));
    icmp_hdr.type = ICMP_ECHO;
    icmp_hdr.code = 0;
    icmp_hdr.un.echo.id = htons(ctx->ident);
    icmp_hdr.un.echo.sequence = htons(ctx->sequence);
    
    // 填充数据
    memset(packet, 0, sizeof(packet));
    
    // 添加时间戳
    struct timeval* tv = (struct timeval*)(packet + sizeof(icmp_hdr));
    gettimeofday(tv, NULL);
    
    // 填充剩余数据
    for (int i = sizeof(icmp_hdr) + sizeof(struct timeval); i < packet_len; i++) {
        packet[i] = i & 0xFF;
    }
    
    // 复制ICMP头部
    memcpy(packet, &icmp_hdr, sizeof(icmp_hdr));
    
    // 计算校验和
    icmp_hdr.checksum = 0;
    icmp_hdr.checksum = in_cksum((unsigned short*)packet, packet_len);
    memcpy(packet, &icmp_hdr, sizeof(icmp_hdr));
    
    // 发送
    struct sockaddr_in* addr_in = (struct sockaddr_in*)&ctx->target_addr;
    int sent = sendto(ctx->ping_socket, packet, packet_len, 0,
                     (struct sockaddr*)addr_in, sizeof(*addr_in));
    
    if (sent < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            qosmon_log(ctx, QMON_LOG_ERROR, "发送ping失败: %s\n", strerror(errno));
        }
        return QMON_ERR_SOCKET;
    }
    
    ctx->ntransmitted++;
    ctx->sequence++;
    ctx->last_ping_time_ms = qosmon_time_ms();
    
    if (ctx->config.verbose) {
        qosmon_log(ctx, QMON_LOG_DEBUG, "发送ping #%d 到 %s\n", 
                  ctx->sequence, inet_ntoa(addr_in->sin_addr));
    }
    
    return QMON_OK;
}

int ping_manager_receive(qosmon_context_t* ctx) {
    if (!ctx || ctx->ping_socket < 0) return QMON_ERR_SOCKET;
    
    char packet[256];
    struct sockaddr_in from;
    socklen_t fromlen = sizeof(from);
    
    int n = recvfrom(ctx->ping_socket, packet, sizeof(packet), 0,
                    (struct sockaddr*)&from, &fromlen);
    
    if (n < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            qosmon_log(ctx, QMON_LOG_ERROR, "接收ping失败: %s\n", strerror(errno));
        }
        return -1;
    }
    
    if (n < (int)sizeof(struct ip) + ICMP_MINLEN) {
        qosmon_log(ctx, QMON_LOG_WARN, "收到过短的ping包: %d bytes\n", n);
        return 0;
    }
    
    // 解析IP头部
    struct ip* ip_hdr = (struct ip*)packet;
    int hlen = ip_hdr->ip_hl << 2;  // IP头部长度（字节）
    
    if (n < hlen + ICMP_MINLEN) {
        qosmon_log(ctx, QMON_LOG_WARN, "IP头部长度错误\n");
        return 0;
    }
    
    // 解析ICMP头部
    struct icmphdr* icmp_hdr = (struct icmphdr*)(packet + hlen);
    
    // 检查是否是我们发送的echo回复
    if (icmp_hdr->type != ICMP_ECHOREPLY) {
        return 0;  // 不是echo回复
    }
    
    uint16_t recv_id = ntohs(icmp_hdr->un.echo.id);
    if (recv_id != ctx->ident) {
        if (ctx->config.verbose) {
            qosmon_log(ctx, QMON_LOG_DEBUG, "收到非本进程的ICMP包: ID=%d (期望: %d)\n", 
                      recv_id, ctx->ident);
        }
        return 0;
    }
    
    // 获取发送时间戳
    struct timeval* send_tv = (struct timeval*)(packet + hlen + sizeof(struct icmphdr));
    struct timeval recv_tv;
    gettimeofday(&recv_tv, NULL);
    
    // 计算延迟（微秒）
    int64_t rtt_us = (recv_tv.tv_sec - send_tv->tv_sec) * 1000000L + 
                     (recv_tv.tv_usec - send_tv->tv_usec);
    
    if (rtt_us < 0) rtt_us = 0;
    if (rtt_us > MAX_PING_TIME_MS * 1000) rtt_us = MAX_PING_TIME_MS * 1000;
    if (rtt_us < MIN_PING_TIME_MS * 1000) rtt_us = MIN_PING_TIME_MS * 1000;
    
    ctx->nreceived++;
    
    // 更新ping历史
    ctx->raw_ping_time_us = rtt_us;
    update_ping_history(ctx, rtt_us);
    
    if (ctx->config.verbose) {
        qosmon_log(ctx, QMON_LOG_DEBUG, "收到ping回复 #%d, ID=%d, 序列=%d, 延迟: %.1f ms\n", 
                  ctx->nreceived, recv_id, ntohs(icmp_hdr->un.echo.sequence),
                  rtt_us / 1000.0f);
    }
    
    return 1;
}

static void update_ping_history(qosmon_context_t* ctx, int64_t ping_time_us) {
    if (!ctx) return;
    
    // 更新历史记录
    ctx->ping_history.times[ctx->ping_history.index] = ping_time_us;
    ctx->ping_history.index = (ctx->ping_history.index + 1) % PING_HISTORY_SIZE;
    if (ctx->ping_history.count < PING_HISTORY_SIZE) {
        ctx->ping_history.count++;
    }
    
    // 计算平滑延迟
    float alpha = 0.3f;  // 平滑因子
    if (ctx->ping_history.smoothed == 0) {
        ctx->ping_history.smoothed = ping_time_us;
    } else {
        ctx->ping_history.smoothed = alpha * ping_time_us + (1 - alpha) * ctx->ping_history.smoothed;
    }
    
    ctx->filtered_ping_time_us = (int64_t)ctx->ping_history.smoothed;
    
    // 更新最大延迟
    if (ping_time_us > ctx->max_ping_time_us) {
        ctx->max_ping_time_us = ping_time_us;
    }
    
    // 更新最小延迟
    if (ctx->min_ping_time_us == 0 || ping_time_us < ctx->min_ping_time_us) {
        ctx->min_ping_time_us = ping_time_us;
    }
}

static unsigned short in_cksum(unsigned short* addr, int len) {
    int nleft = len;
    int sum = 0;
    unsigned short* w = addr;
    unsigned short answer = 0;
    
    while (nleft > 1) {
        sum += *w++;
        nleft -= 2;
    }
    
    if (nleft == 1) {
        *(unsigned char*)(&answer) = *(unsigned char*)w;
        sum += answer;
    }
    
    sum = (sum >> 16) + (sum & 0xFFFF);
    sum += (sum >> 16);
    answer = ~sum;
    return answer;
}

/* ==================== epoll相关函数 ==================== */
int epoll_init(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    // 创建epoll实例
    ctx->epoll_fd = epoll_create1(0);
    if (ctx->epoll_fd < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建epoll失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
    }
    
    // 创建定时器
    ctx->timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (ctx->timer_fd < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建定时器失败: %s\n", strerror(errno));
        close(ctx->epoll_fd);
        return QMON_ERR_SYSTEM;
    }
    
    // 初始化定时器列表
    ctx->timer_list = NULL;
    ctx->timer_count = 0;
    
    // 初始化信号管道
    if (pipe(ctx->signal_pipe) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建信号管道失败: %s\n", strerror(errno));
        close(ctx->timer_fd);
        close(ctx->epoll_fd);
        return QMON_ERR_SYSTEM;
    }
    
    qosmon_log(ctx, QMON_LOG_INFO, "epoll初始化完成: epoll_fd=%d, timer_fd=%d\n", 
              ctx->epoll_fd, ctx->timer_fd);
    return QMON_OK;
}

int epoll_add_fd(qosmon_context_t* ctx, int fd, uint32_t events, 
                 epoll_event_handler_t handler, void* data) {
    if (!ctx || fd < 0) return QMON_ERR_PARAM;
    
    // 创建事件描述结构
    epoll_event_desc_t* desc = (epoll_event_desc_t*)malloc(sizeof(epoll_event_desc_t));
    if (!desc) {
        return QMON_ERR_MEMORY;
    }
    
    desc->fd = fd;
    desc->handler = handler;
    desc->data = data;
    
    // 设置epoll事件
    struct epoll_event ev;
    ev.events = events;
    ev.data.ptr = desc;
    
    if (epoll_ctl(ctx->epoll_fd, EPOLL_CTL_ADD, fd, &ev) < 0) {
        free(desc);
        qosmon_log(ctx, QMON_LOG_ERROR, "添加文件描述符到epoll失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
    }
    
    qosmon_log(ctx, QMON_LOG_DEBUG, "添加文件描述符到epoll: fd=%d, events=0x%x\n", fd, events);
    return QMON_OK;
}

int epoll_add_timer(qosmon_context_t* ctx, int64_t expiry_time, int id,
                    timer_callback_t callback, void* data, int repeat, int interval) {
    if (!ctx || !callback) return QMON_ERR_PARAM;
    
    // 查找是否已存在相同ID的定时器
    epoll_timer_t* timer = ctx->timer_list;
    while (timer) {
        if (timer->id == id) {
            // 更新现有定时器
            timer->expiry_time = expiry_time;
            timer->callback = callback;
            timer->data = data;
            timer->repeat = repeat;
            timer->interval = interval;
            return update_timerfd(ctx);
        }
        timer = timer->next;
    }
    
    // 创建新的定时器
    epoll_timer_t* new_timer = (epoll_timer_t*)malloc(sizeof(epoll_timer_t));
    if (!new_timer) {
        return QMON_ERR_MEMORY;
    }
    
    new_timer->id = id;
    new_timer->expiry_time = expiry_time;
    new_timer->callback = callback;
    new_timer->data = data;
    new_timer->repeat = repeat;
    new_timer->interval = interval;
    new_timer->next = ctx->timer_list;
    
    ctx->timer_list = new_timer;
    ctx->timer_count++;
    
    qosmon_log(ctx, QMON_LOG_DEBUG, "添加定时器: id=%d, 到期时间=%ld, 重复=%d, 间隔=%d\n", 
              id, expiry_time, repeat, interval);
    
    return update_timerfd(ctx);
}

static int update_timerfd(qosmon_context_t* ctx) {
    if (!ctx || ctx->timer_fd < 0) return QMON_ERR_SYSTEM;
    
    if (ctx->timer_count == 0) {
        // 禁用定时器
        struct itimerspec its = {{0, 0}, {0, 0}};
        timerfd_settime(ctx->timer_fd, 0, &its, NULL);
        return QMON_OK;
    }
    
    // 找到最近的定时器
    int64_t min_expiry = INT64_MAX;
    epoll_timer_t* timer = ctx->timer_list;
    while (timer) {
        if (timer->expiry_time < min_expiry) {
            min_expiry = timer->expiry_time;
        }
        timer = timer->next;
    }
    
    int64_t now = qosmon_time_ms();
    int64_t delta_ms = min_expiry - now;
    if (delta_ms < 0) delta_ms = 0;
    
    struct itimerspec its;
    its.it_value.tv_sec = delta_ms / 1000;
    its.it_value.tv_nsec = (delta_ms % 1000) * 1000000;
    its.it_interval.tv_sec = 0;
    its.it_interval.tv_nsec = 0;  // 一次性定时器，我们会重新设置
    
    if (timerfd_settime(ctx->timer_fd, 0, &its, NULL) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "设置定时器时间失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
    }
    
    return QMON_OK;
}

static int epoll_handle_timers(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    int64_t now = qosmon_time_ms();
    int processed = 0;
    
    // 处理到期的定时器
    epoll_timer_t** pprev = &ctx->timer_list;
    epoll_timer_t* timer = ctx->timer_list;
    
    while (timer) {
        if (timer->expiry_time <= now) {
            // 执行回调
            if (timer->callback) {
                timer->callback(timer->data);
            }
            
            processed++;
            
            if (timer->repeat) {
                // 重置定时器
                timer->expiry_time = now + timer->interval;
                
                // 移动到下一个定时器
                pprev = &timer->next;
                timer = timer->next;
            } else {
                // 删除一次性定时器
                epoll_timer_t* to_free = timer;
                *pprev = timer->next;
                timer = timer->next;
                free(to_free);
                ctx->timer_count--;
            }
        } else {
            // 未到期，继续
            pprev = &timer->next;
            timer = timer->next;
        }
    }
    
    if (processed > 0) {
        // 更新timerfd
        update_timerfd(ctx);
    }
    
    return processed;
}

static int setup_signal_handlers(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    struct sigaction sa;
    
    // 忽略SIGPIPE
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_IGN;
    sigaction(SIGPIPE, &sa, NULL);
    
    // 处理SIGTERM和SIGINT
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = [](int sig) {
        qosmon_context_t* ctx = &g_ctx;  // 需要全局上下文
        if (ctx && ctx->signal_pipe[1] >= 0) {
            char sig_num = sig;
            write(ctx->signal_pipe[1], &sig_num, 1);
        }
    };
    sa.sa_flags = SA_RESTART;
    
    if (sigaction(SIGTERM, &sa, NULL) < 0 ||
        sigaction(SIGINT, &sa, NULL) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "设置信号处理器失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
    }
    
    return QMON_OK;
}

static int setup_signal_pipe(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    // 设置信号管道为非阻塞
    int flags = fcntl(ctx->signal_pipe[0], F_GETFL, 0);
    if (flags < 0 || fcntl(ctx->signal_pipe[0], F_SETFL, flags | O_NONBLOCK) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "设置信号管道非阻塞失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
    }
    
    flags = fcntl(ctx->signal_pipe[1], F_GETFL, 0);
    if (flags < 0 || fcntl(ctx->signal_pipe[1], F_SETFL, flags | O_NONBLOCK) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "设置信号管道非阻塞失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
    }
    
    return QMON_OK;
}

void epoll_cleanup(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    if (ctx->epoll_fd >= 0) {
        close(ctx->epoll_fd);
        ctx->epoll_fd = -1;
    }
    
    if (ctx->timer_fd >= 0) {
        close(ctx->timer_fd);
        ctx->timer_fd = -1;
    }
    
    if (ctx->signal_pipe[0] >= 0) {
        close(ctx->signal_pipe[0]);
        close(ctx->signal_pipe[1]);
        ctx->signal_pipe[0] = -1;
        ctx->signal_pipe[1] = -1;
    }
    
    // 清理定时器列表
    epoll_timer_t* timer = ctx->timer_list;
    while (timer) {
        epoll_timer_t* next = timer->next;
        free(timer);
        timer = next;
    }
    ctx->timer_list = NULL;
    ctx->timer_count = 0;
}

/* ==================== 网络工具函数 ==================== */
static int resolve_target(const char* target, struct sockaddr_in* addr, 
                         char* error, int error_len) {
    if (!target || !addr || !error) return QMON_ERR_MEMORY;
    
    struct hostent* host = gethostbyname(target);
    if (!host) {
        snprintf(error, error_len, "解析目标地址失败: %s", hstrerror(h_errno));
        return QMON_ERR_NETWORK;
    }
    
    memset(addr, 0, sizeof(*addr));
    addr->sin_family = AF_INET;
    memcpy(&addr->sin_addr, host->h_addr_list[0], host->h_length);
    
    return QMON_OK;
}

/* ==================== 状态文件更新 ==================== */
static int status_file_update(qosmon_context_t* ctx) {
    if (!ctx || !ctx->config.status_file[0]) {
        return QMON_OK;
    }
    
    FILE* fp = fopen(ctx->config.status_file, "w");
    if (!fp) {
        qosmon_log(ctx, QMON_LOG_ERROR, "无法打开状态文件: %s\n", strerror(errno));
        return QMON_ERR_FILE;
    }
    
    fprintf(fp, "state=%d\n", ctx->state);
    fprintf(fp, "current_limit_bps=%d\n", ctx->current_limit_bps);
    fprintf(fp, "filtered_ping_time_us=%ld\n", ctx->filtered_ping_time_us);
    fprintf(fp, "raw_ping_time_us=%ld\n", ctx->raw_ping_time_us);
    fprintf(fp, "min_ping_time_us=%ld\n", ctx->min_ping_time_us);
    fprintf(fp, "max_ping_time_us=%ld\n", ctx->max_ping_time_us);
    fprintf(fp, "ntransmitted=%d\n", ctx->ntransmitted);
    fprintf(fp, "nreceived=%d\n", ctx->nreceived);
    fprintf(fp, "packet_loss_rate=%.4f\n", ctx->stats.packet_loss_rate);
    fprintf(fp, "total_time_ms=%ld\n", ctx->stats.total_time_ms);
    fprintf(fp, "avg_bandwidth_kbps=%d\n", ctx->stats.avg_bandwidth_kbps);
    fprintf(fp, "detected_qdisc=%s\n", ctx->detected_qdisc);
    fprintf(fp, "target=%s\n", ctx->config.target);
    fprintf(fp, "device=%s\n", ctx->config.device);
    fprintf(fp, "ping_interval=%d\n", ctx->config.ping_interval);
    fprintf(fp, "ping_limit_ms=%d\n", ctx->config.ping_limit_ms);
    fprintf(fp, "max_bandwidth_kbps=%d\n", ctx->config.max_bandwidth_kbps);
    fprintf(fp, "min_bw_ratio=%.2f\n", ctx->config.min_bw_ratio);
    fprintf(fp, "max_bw_ratio=%.2f\n", ctx->config.max_bw_ratio);
    fprintf(fp, "smoothing_factor=%.2f\n", ctx->config.smoothing_factor);
    fprintf(fp, "safe_mode=%d\n", ctx->config.safe_mode);
    fprintf(fp, "auto_switch_mode=%d\n", ctx->config.auto_switch_mode);
    
    fclose(fp);
    
    if (ctx->config.verbose) {
        qosmon_log(ctx, QMON_LOG_DEBUG, "状态文件已更新: %s\n", ctx->config.status_file);
    }
    
    return QMON_OK;
}

/* ==================== 清理函数 ==================== */
void qosmon_cleanup(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    qosmon_log(ctx, QMON_LOG_INFO, "开始清理...\n");
    
    // 清理epoll
    epoll_cleanup(ctx);
    
    // 清理Ping socket
    if (ctx->ping_socket >= 0) {
        close(ctx->ping_socket);
        ctx->ping_socket = -1;
    }
    
    // 关闭文件
    if (ctx->debug_log_file) {
        fclose(ctx->debug_log_file);
        ctx->debug_log_file = NULL;
    }
    
    // 删除状态文件
    if (ctx->config.status_file[0]) {
        unlink(ctx->config.status_file);
    }
    
    qosmon_log(ctx, QMON_LOG_INFO, "清理完成\n");
}