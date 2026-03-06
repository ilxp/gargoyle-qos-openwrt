/*
 * qosmon - QoS Monitor for OpenWrt with epoll-based event loop
 * 修复版本 - 包含Netlink通信、TC命令、状态机、内存泄漏和信号处理的修复
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <math.h>
#include <linux/if.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/pkt_sched.h>

/* 定义 */
#define QMON_VERSION "2.0.0"
#define MAX_PING_TIME_MS 1000
#define MIN_PING_TIME_MS 1
#define PING_HISTORY_SIZE 20
#define MAX_CONFIG_FILE_SIZE 4096
#define MAX_LOG_SIZE 4096
#define MAX_DEVICE_NAME 16
#define MAX_TARGET_NAME 64
#define MAX_STATUS_FILE 256
#define MAX_DEBUG_LOG 256
#define MAX_QDISC_KIND_LEN 16
#define DEFAULT_PING_INTERVAL 200
#define DEFAULT_MAX_BANDWIDTH_KBPS 10000
#define DEFAULT_PING_LIMIT_MS 20
#define CONTROL_INTERVAL_MS 100
#define HEARTBEAT_INTERVAL_MS 30000
#define STATS_INTERVAL_MS 10000
#define REALTIME_DETECT_MS 5000

/* 枚举 */
typedef enum {
    QMON_OK = 0,
    QMON_ERR_MEMORY = -1,
    QMON_ERR_SOCKET = -2,
    QMON_ERR_SYSTEM = -3,
    QMON_ERR_CONFIG = -4,
    QMON_ERR_TIMER = -5,
    QMON_ERR_NETLINK = -6,
    QMON_ERR_TC = -7,
    QMON_ERR_PING = -8,
    QMON_ERR_BUFFER = -9,
    QMON_ERR_STATE = -10
} qosmon_error_t;

typedef enum {
    QMON_CHK = 0,
    QMON_INIT = 1,
    QMON_IDLE = 2,
    QMON_ACTIVE = 3,
    QMON_REALTIME = 4,
    QMON_EXIT = 5
} qosmon_state_t;

typedef enum {
    QDISC_HTB = 0,
    QDISC_HFSC = 1,
    QDISC_TBF = 2,
    QDISC_DRR = 3,
    QDISC_SFQ = 4,
    QDISC_CODEL = 5,
    QDISC_FQ_CODEL = 6,
    QDISC_PFIFO_FAST = 7
} qdisc_kind_t;

/* 日志级别 */
typedef enum {
    QMON_LOG_ERROR = 0,
    QMON_LOG_WARN = 1,
    QMON_LOG_INFO = 2,
    QMON_LOG_DEBUG = 3
} qosmon_log_level_t;

/* 结构体 */
typedef struct {
    int ping_interval;
    int max_bandwidth_kbps;
    int ping_limit_ms;
    int classid;
    int safe_mode;
    int verbose;
    int auto_switch_mode;
    int background_mode;
    int skip_initial;
    int min_bw_change_kbps;
    float min_bw_ratio;
    float max_bw_ratio;
    float smoothing_factor;
    float active_threshold;
    float idle_threshold;
    float safe_start_ratio;
    int use_netlink;
    int mtu;
    int buffer;
    int cbuffer;
    int quantum;
    int hfsc_m1;
    int hfsc_d;
    int hfsc_m2;
    int tbf_burst;
    int tbf_limit;
    int tbf_mtu;
    char device[MAX_DEVICE_NAME];
    char target[MAX_TARGET_NAME];
    char config_file[256];
    char status_file[MAX_STATUS_FILE];
    char debug_log[MAX_DEBUG_LOG];
} qosmon_config_t;

typedef struct {
    float times[PING_HISTORY_SIZE];
    int index;
    int count;
    float smoothed;
} ping_history_t;

typedef struct {
    int64_t start_time;
    int64_t total_time_ms;
    float avg_bandwidth_kbps;
    float packet_loss_rate;
} qosmon_stats_t;

typedef struct qosmon_context {
    qosmon_config_t config;
    int epoll_fd;
    int ping_socket;
    int timer_fd;
    int signal_pipe[2];
    int netlink_fd;
    int sigterm;
    qosmon_state_t state;
    
    struct sockaddr_storage target_addr;
    socklen_t target_addr_len;
    
    int ident;
    int sequence;
    int ntransmitted;
    int nreceived;
    
    int64_t last_ping_time_ms;
    int64_t last_tc_update_time_ms;
    int64_t last_stats_time_ms;
    int64_t last_realtime_detect_time_ms;
    int64_t last_heartbeat_ms;
    int64_t filtered_ping_time_us;
    int64_t raw_ping_time_us;
    int64_t max_ping_time_us;
    int64_t min_ping_time_us;
    
    int current_limit_bps;
    int saved_active_limit;
    int saved_realtime_limit;
    
    ping_history_t ping_history;
    qosmon_stats_t stats;
    
    char detected_qdisc[MAX_QDISC_KIND_LEN];
    qdisc_kind_t detected_qdisc_type;
    
    struct epoll_timer* timer_list;
    int timer_count;
} qosmon_context_t;

typedef struct ping_manager {
    qosmon_context_t* ctx;
    int ident;
    int sequence;
    int ntransmitted;
    int nreceived;
} ping_manager_t;

typedef struct tc_controller {
    qosmon_context_t* ctx;
    int netlink_fd;
    int seq;
    qdisc_kind_t qdisc_kind;
} tc_controller_t;

typedef struct epoll_timer {
    int fd;
    int id;
    int64_t expire_time;
    int interval;
    int repeat;
    void (*callback)(void*);
    void* data;
    struct epoll_timer* next;
} epoll_timer_t;

/* 函数原型 */
void qosmon_log(qosmon_context_t* ctx, qosmon_log_level_t level, const char* fmt, ...);
int64_t qosmon_time_ms(void);
void qosmon_config_init(qosmon_config_t* cfg);
int qosmon_config_parse(qosmon_config_t* cfg, int argc, char* argv[]);
int qosmon_config_load_file(qosmon_config_t* cfg, const char* filename);
void qosmon_config_print(const qosmon_config_t* cfg);

int epoll_init(qosmon_context_t* ctx);
int epoll_add_fd(qosmon_context_t* ctx, int fd, uint32_t events, 
                void (*handler)(void*), void* data);
int epoll_add_timer(qosmon_context_t* ctx, int64_t expire_time, int id, 
                   void (*callback)(void*), void* data, int repeat, int interval);
void epoll_handle_timers(qosmon_context_t* ctx);
int epoll_run(qosmon_context_t* ctx);
void epoll_cleanup(qosmon_context_t* ctx);

int ping_manager_init(qosmon_context_t* ctx);
int ping_manager_send(qosmon_context_t* ctx);
int ping_manager_receive(qosmon_context_t* ctx);
void ping_manager_cleanup(qosmon_context_t* ctx);

int tc_controller_init(tc_controller_t* tc, qosmon_context_t* ctx);
int tc_controller_set_bandwidth(tc_controller_t* tc, int bandwidth_bps);
void tc_controller_cleanup(tc_controller_t* tc);
char* detect_qdisc_kind(qosmon_context_t* ctx);
int detect_class_bandwidth(qosmon_context_t* ctx, int* current_bw_kbps, tc_controller_t* tc);

void state_machine_init(qosmon_context_t* ctx);
void state_machine_run(qosmon_context_t* ctx, ping_manager_t* ping_mgr, tc_controller_t* tc_mgr);
void state_machine_cleanup(qosmon_context_t* ctx);

int status_file_update(qosmon_context_t* ctx);
void qosmon_cleanup(qosmon_context_t* ctx);

/* 静态函数声明 */
static void ping_event_handler(void* data);
static void signal_event_handler(void* data);
static void timer_event_handler(void* data);
static void ping_timer_callback(void* data);
static void state_machine_timer_callback(void* data);
static void status_update_timer_callback(void* data);
static void bandwidth_adjust_timer_callback(void* data);
static void update_ping_history(qosmon_context_t* ctx, int64_t ping_time_us);
static unsigned short in_cksum(unsigned short* addr, int len);
static int tc_set_bandwidth_netlink(tc_controller_t* tc, int bandwidth_bps);
static int tc_set_bandwidth_shell(qosmon_context_t* ctx, int bandwidth_bps);
static int netlink_open(void);
static int netlink_receive_ack(tc_controller_t* tc);
static int adjust_bandwidth_by_ping(qosmon_context_t* ctx, tc_controller_t* tc_mgr);
static int calculate_realtime_bandwidth(qosmon_context_t* ctx);
static int detect_realtime_traffic(qosmon_context_t* ctx);
static float calculate_ping_jitter(qosmon_context_t* ctx);
static void update_statistics(qosmon_context_t* ctx);
static void state_machine_chk(qosmon_context_t* ctx, int64_t now, 
                              ping_manager_t* ping_mgr, tc_controller_t* tc_mgr);
static void state_machine_init_state(qosmon_context_t* ctx, int64_t now,
                                     ping_manager_t* ping_mgr, tc_controller_t* tc_mgr);
static void state_machine_idle(qosmon_context_t* ctx, int64_t now,
                               ping_manager_t* ping_mgr, tc_controller_t* tc_mgr);
static void state_machine_active(qosmon_context_t* ctx, int64_t now,
                                 ping_manager_t* ping_mgr, tc_controller_t* tc_mgr);
static void state_machine_realtime(qosmon_context_t* ctx, int64_t now,
                                   ping_manager_t* ping_mgr, tc_controller_t* tc_mgr);

/* 全局上下文指针 */
static qosmon_context_t* g_ctx = NULL;

/* 信号处理器 */
static void signal_handler(int sig) {
    if (sig == SIGTERM || sig == SIGINT) {
        if (g_ctx) {
            g_ctx->sigterm = 1;
        }
    }
}

/* 主函数 */
int main(int argc, char* argv[]) {
    qosmon_context_t ctx = {0};
    g_ctx = &ctx;
    
    qosmon_config_t config = {0};
    qosmon_config_init(&config);
    
    int ret = qosmon_config_parse(&config, argc, argv);
    if (ret != QMON_OK) {
        fprintf(stderr, "配置解析失败\n");
        return EXIT_FAILURE;
    }
    
    ctx.config = config;
    
    /* 设置信号处理器 */
    struct sigaction sa = {0};
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    
    /* 忽略SIGPIPE */
    signal(SIGPIPE, SIG_IGN);
    
    qosmon_log(&ctx, QMON_LOG_INFO, "qosmon v%s 启动\n", QMON_VERSION);
    
    /* 初始化epoll */
    ret = epoll_init(&ctx);
    if (ret != QMON_OK) {
        fprintf(stderr, "epoll初始化失败\n");
        return EXIT_FAILURE;
    }
    
    /* 初始化ping管理器 */
    ret = ping_manager_init(&ctx);
    if (ret != QMON_OK) {
        fprintf(stderr, "ping管理器初始化失败\n");
        epoll_cleanup(&ctx);
        return EXIT_FAILURE;
    }
    
    /* 添加ping socket到epoll */
    ret = epoll_add_fd(&ctx, ctx.ping_socket, EPOLLIN, ping_event_handler, &ctx);
    if (ret != QMON_OK) {
        fprintf(stderr, "添加ping socket到epoll失败\n");
        ping_manager_cleanup(&ctx);
        epoll_cleanup(&ctx);
        return EXIT_FAILURE;
    }
    
    /* 添加信号管道到epoll */
    ret = epoll_add_fd(&ctx, ctx.signal_pipe[0], EPOLLIN, signal_event_handler, &ctx);
    if (ret != QMON_OK) {
        fprintf(stderr, "添加信号管道到epoll失败\n");
        ping_manager_cleanup(&ctx);
        epoll_cleanup(&ctx);
        return EXIT_FAILURE;
    }
    
    /* 初始化TC控制器 */
    tc_controller_t* tc_mgr = (tc_controller_t*)calloc(1, sizeof(tc_controller_t));
    if (!tc_mgr) {
        fprintf(stderr, "分配TC控制器内存失败\n");
        ping_manager_cleanup(&ctx);
        epoll_cleanup(&ctx);
        return EXIT_FAILURE;
    }
    
    tc_mgr->ctx = &ctx;
    ret = tc_controller_init(tc_mgr, &ctx);
    if (ret != QMON_OK) {
        fprintf(stderr, "TC控制器初始化失败\n");
        free(tc_mgr);
        ping_manager_cleanup(&ctx);
        epoll_cleanup(&ctx);
        return EXIT_FAILURE;
    }
    
    /* 初始化状态机 */
    state_machine_init(&ctx);
    
    /* 启动定时器 */
    int64_t now = qosmon_time_ms();
    epoll_add_timer(&ctx, now + ctx.config.ping_interval, 1, ping_timer_callback, &ctx, 1, ctx.config.ping_interval);
    epoll_add_timer(&ctx, now + 10, 2, state_machine_timer_callback, &ctx, 1, 10);
    epoll_add_timer(&ctx, now + 1000, 3, status_update_timer_callback, &ctx, 1, 1000);
    epoll_add_timer(&ctx, now + CONTROL_INTERVAL_MS, 4, bandwidth_adjust_timer_callback, &ctx, 1, CONTROL_INTERVAL_MS);
    
    qosmon_log(&ctx, QMON_LOG_INFO, "启动主事件循环\n");
    
    /* 主事件循环 */
    while (!ctx.sigterm) {
        ret = epoll_run(&ctx);
        if (ret != QMON_OK && ret != EAGAIN && ret != EWOULDBLOCK) {
            qosmon_log(&ctx, QMON_LOG_ERROR, "epoll运行错误: %d\n", ret);
            break;
        }
        
        if (ctx.state == QMON_EXIT) {
            qosmon_log(&ctx, QMON_LOG_INFO, "收到退出信号\n");
            ctx.sigterm = 1;
        }
    }
    
    qosmon_log(&ctx, QMON_LOG_INFO, "清理资源\n");
    
    /* 清理 */
    tc_controller_cleanup(tc_mgr);
    free(tc_mgr);
    ping_manager_cleanup(&ctx);
    epoll_cleanup(&ctx);
    
    qosmon_log(&ctx, QMON_LOG_INFO, "qosmon退出\n");
    return EXIT_SUCCESS;
}

/* 日志函数 */
void qosmon_log(qosmon_context_t* ctx, qosmon_log_level_t level, const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    
    const char* level_str = "UNKNOWN";
    switch (level) {
        case QMON_LOG_ERROR: level_str = "ERROR"; break;
        case QMON_LOG_WARN: level_str = "WARN"; break;
        case QMON_LOG_INFO: level_str = "INFO"; break;
        case QMON_LOG_DEBUG: level_str = "DEBUG"; break;
    }
    
    char timestamp[64];
    time_t now = time(NULL);
    struct tm* tm_info = localtime(&now);
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", tm_info);
    
    if (ctx && ctx->config.verbose >= level) {
        fprintf(stderr, "[%s] [%s] ", timestamp, level_str);
        vfprintf(stderr, fmt, args);
    } else if (!ctx && level <= QMON_LOG_INFO) {
        fprintf(stderr, "[%s] [%s] ", timestamp, level_str);
        vfprintf(stderr, fmt, args);
    }
    
    if (ctx && ctx->config.debug_log[0]) {
        FILE* f = fopen(ctx->config.debug_log, "a");
        if (f) {
            fprintf(f, "[%s] [%s] ", timestamp, level_str);
            vfprintf(f, fmt, args);
            fclose(f);
        }
    }
    
    va_end(args);
}

/* 获取当前时间（毫秒） */
int64_t qosmon_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + (int64_t)tv.tv_usec / 1000;
}

/* epoll初始化 */
int epoll_init(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    /* 创建epoll实例 */
    ctx->epoll_fd = epoll_create1(0);
    if (ctx->epoll_fd < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建epoll失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
    }
    
    /* 创建定时器 */
    ctx->timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (ctx->timer_fd < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建定时器失败: %s\n", strerror(errno));
        close(ctx->epoll_fd);
        return QMON_ERR_SYSTEM;
    }
    
    /* 初始化定时器列表 */
    ctx->timer_list = NULL;
    ctx->timer_count = 0;
    
    /* 创建信号管道 */
    if (pipe(ctx->signal_pipe) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建信号管道失败: %s\n", strerror(errno));
        close(ctx->timer_fd);
        close(ctx->epoll_fd);
        return QMON_ERR_SYSTEM;
    }
    
    /* 设置信号管道为非阻塞 */
    fcntl(ctx->signal_pipe[0], F_SETFL, O_NONBLOCK);
    fcntl(ctx->signal_pipe[1], F_SETFL, O_NONBLOCK);
    
    /* 添加定时器到epoll */
    struct epoll_event ev = {0};
    ev.events = EPOLLIN | EPOLLET;
    ev.data.ptr = NULL;
    
    if (epoll_ctl(ctx->epoll_fd, EPOLL_CTL_ADD, ctx->timer_fd, &ev) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "添加定时器到epoll失败: %s\n", strerror(errno));
        close(ctx->signal_pipe[0]);
        close(ctx->signal_pipe[1]);
        close(ctx->timer_fd);
        close(ctx->epoll_fd);
        return QMON_ERR_SYSTEM;
    }
    
    qosmon_log(ctx, QMON_LOG_INFO, "epoll初始化完成: epoll_fd=%d, timer_fd=%d\n", 
              ctx->epoll_fd, ctx->timer_fd);
    return QMON_OK;
}

/* 添加fd到epoll */
int epoll_add_fd(qosmon_context_t* ctx, int fd, uint32_t events, 
                void (*handler)(void*), void* data) {
    if (!ctx || fd < 0) return QMON_ERR_MEMORY;
    
    struct epoll_event ev = {0};
    ev.events = events | EPOLLET;
    ev.data.fd = fd;
    
    if (epoll_ctl(ctx->epoll_fd, EPOLL_CTL_ADD, fd, &ev) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "添加fd到epoll失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
    }
    
    /* 保存回调信息 */
    epoll_timer_t* timer = (epoll_timer_t*)malloc(sizeof(epoll_timer_t));
    if (!timer) {
        qosmon_log(ctx, QMON_LOG_ERROR, "分配定时器内存失败\n");
        return QMON_ERR_MEMORY;
    }
    
    memset(timer, 0, sizeof(*timer));
    timer->fd = fd;
    timer->callback = handler;
    timer->data = data;
    timer->next = ctx->timer_list;
    ctx->timer_list = timer;
    
    qosmon_log(ctx, QMON_LOG_DEBUG, "添加fd到epoll: fd=%d, events=%u\n", fd, events);
    return QMON_OK;
}

/* 添加定时器 */
int epoll_add_timer(qosmon_context_t* ctx, int64_t expire_time, int id, 
                   void (*callback)(void*), void* data, int repeat, int interval) {
    if (!ctx || expire_time <= 0) return QMON_ERR_MEMORY;
    
    epoll_timer_t* timer = (epoll_timer_t*)malloc(sizeof(epoll_timer_t));
    if (!timer) {
        qosmon_log(ctx, QMON_LOG_ERROR, "分配定时器内存失败\n");
        return QMON_ERR_MEMORY;
    }
    
    memset(timer, 0, sizeof(*timer));
    timer->fd = -1;
    timer->id = id;
    timer->expire_time = expire_time;
    timer->callback = callback;
    timer->data = data;
    timer->repeat = repeat;
    timer->interval = interval;
    
    /* 添加到链表头部 */
    timer->next = ctx->timer_list;
    ctx->timer_list = timer;
    ctx->timer_count++;
    
    qosmon_log(ctx, QMON_LOG_DEBUG, "添加定时器: id=%d, expire=%ld, interval=%d\n", 
              id, (long)expire_time, interval);
    return QMON_OK;
}

/* 处理定时器 */
void epoll_handle_timers(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    int64_t now = qosmon_time_ms();
    epoll_timer_t** prev = &ctx->timer_list;
    epoll_timer_t* current = ctx->timer_list;
    
    while (current) {
        if (current->fd == -1 && current->expire_time <= now) {
            /* 调用回调 */
            if (current->callback) {
                current->callback(current->data);
            }
            
            /* 如果需要重复，重新调度 */
            if (current->repeat) {
                current->expire_time = now + current->interval;
                prev = &current->next;
                current = current->next;
            } else {
                /* 移除定时器 */
                epoll_timer_t* to_remove = current;
                *prev = current->next;
                current = current->next;
                free(to_remove);
                ctx->timer_count--;
            }
        } else {
            prev = &current->next;
            current = current->next;
        }
    }
}

/* 运行epoll循环 */
int epoll_run(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    struct epoll_event events[10];
    int nfds = epoll_wait(ctx->epoll_fd, events, 10, 100);  /* 100ms超时 */
    
    if (nfds < 0) {
        if (errno == EINTR) {
            return EAGAIN;
        }
        qosmon_log(ctx, QMON_LOG_ERROR, "epoll_wait失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
    }
    
    /* 处理事件 */
    for (int i = 0; i < nfds; i++) {
        int fd = events[i].data.fd;
        
        /* 查找对应的处理器 */
        epoll_timer_t* timer = ctx->timer_list;
        while (timer) {
            if (timer->fd == fd) {
                if (timer->callback) {
                    timer->callback(timer->data);
                }
                break;
            }
            timer = timer->next;
        }
    }
    
    /* 处理定时器 */
    epoll_handle_timers(ctx);
    
    return QMON_OK;
}

/* 清理epoll */
void epoll_cleanup(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    /* 清理定时器列表 */
    epoll_timer_t* current = ctx->timer_list;
    while (current) {
        epoll_timer_t* next = current->next;
        free(current);
        current = next;
    }
    ctx->timer_list = NULL;
    ctx->timer_count = 0;
    
    /* 关闭文件描述符 */
    if (ctx->timer_fd >= 0) {
        close(ctx->timer_fd);
        ctx->timer_fd = -1;
    }
    
    if (ctx->signal_pipe[0] >= 0) {
        close(ctx->signal_pipe[0]);
        ctx->signal_pipe[0] = -1;
    }
    
    if (ctx->signal_pipe[1] >= 0) {
        close(ctx->signal_pipe[1]);
        ctx->signal_pipe[1] = -1;
    }
    
    if (ctx->epoll_fd >= 0) {
        close(ctx->epoll_fd);
        ctx->epoll_fd = -1;
    }
    
    qosmon_log(ctx, QMON_LOG_INFO, "epoll清理完成\n");
}

/* Ping管理器初始化 */
int ping_manager_init(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    /* 创建raw socket */
    ctx->ping_socket = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
    if (ctx->ping_socket < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建ping socket失败: %s\n", strerror(errno));
        return QMON_ERR_SOCKET;
    }
    
    /* 设置socket选项 */
    int ttl = 64;
    if (setsockopt(ctx->ping_socket, IPPROTO_IP, IP_TTL, &ttl, sizeof(ttl)) < 0) {
        qosmon_log(ctx, QMON_LOG_WARN, "设置TTL失败: %s\n", strerror(errno));
    }
    
    int on = 1;
    if (setsockopt(ctx->ping_socket, SOL_SOCKET, SO_TIMESTAMP, &on, sizeof(on)) < 0) {
        qosmon_log(ctx, QMON_LOG_WARN, "设置时间戳失败: %s\n", strerror(errno));
    }
    
    /* 设置接收超时 */
    struct timeval tv = {1, 0};  /* 1秒超时 */
    if (setsockopt(ctx->ping_socket, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) {
        qosmon_log(ctx, QMON_LOG_WARN, "设置接收超时失败: %s\n", strerror(errno));
    }
    
    /* 设置非阻塞 */
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
    
    /* 初始化目标地址 */
    struct sockaddr_in* addr_in = (struct sockaddr_in*)&ctx->target_addr;
    memset(addr_in, 0, sizeof(*addr_in));
    addr_in->sin_family = AF_INET;
    
    /* 解析目标地址 */
    struct hostent* host = gethostbyname(ctx->config.target);
    if (!host) {
        qosmon_log(ctx, QMON_LOG_ERROR, "解析目标地址失败: %s\n", ctx->config.target);
        close(ctx->ping_socket);
        ctx->ping_socket = -1;
        return QMON_ERR_NETWORK;
    }
    
    memcpy(&addr_in->sin_addr, host->h_addr_list[0], host->h_length);
    ctx->target_addr_len = sizeof(*addr_in);
    
    /* 生成标识符 */
    ctx->ident = getpid() & 0xFFFF;
    ctx->sequence = 0;
    ctx->ntransmitted = 0;
    ctx->nreceived = 0;
    
    qosmon_log(ctx, QMON_LOG_INFO, "Ping管理器初始化完成，标识符: %d, 目标: %s\n", 
              ctx->ident, inet_ntoa(addr_in->sin_addr));
    return QMON_OK;
}

/* 发送Ping */
int ping_manager_send(qosmon_context_t* ctx) {
    if (!ctx || ctx->ping_socket < 0) return QMON_ERR_SOCKET;
    
    struct icmphdr icmp_hdr;
    char packet[64];
    int packet_len = sizeof(packet);
    
    /* 构建ICMP包 */
    memset(&icmp_hdr, 0, sizeof(icmp_hdr));
    icmp_hdr.type = ICMP_ECHO;
    icmp_hdr.code = 0;
    icmp_hdr.un.echo.id = htons(ctx->ident);
    icmp_hdr.un.echo.sequence = htons(ctx->sequence);
    
    /* 填充数据 */
    memset(packet, 0, sizeof(packet));
    
    /* 添加时间戳 */
    struct timeval* tv = (struct timeval*)(packet + sizeof(icmp_hdr));
    gettimeofday(tv, NULL);
    
    /* 填充剩余数据 */
    for (int i = sizeof(icmp_hdr) + sizeof(struct timeval); i < packet_len; i++) {
        packet[i] = i & 0xFF;
    }
    
    /* 复制ICMP头部 */
    memcpy(packet, &icmp_hdr, sizeof(icmp_hdr));
    
    /* 计算校验和 */
    icmp_hdr.checksum = 0;
    icmp_hdr.checksum = in_cksum((unsigned short*)packet, packet_len);
    memcpy(packet, &icmp_hdr, sizeof(icmp_hdr));
    
    /* 发送 */
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

/* 接收Ping响应 */
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
    
    /* 解析IP头部 */
    struct ip* ip_hdr = (struct ip*)packet;
    int hlen = ip_hdr->ip_hl << 2;  /* IP头部长度（字节） */
    
    if (n < hlen + ICMP_MINLEN) {
        qosmon_log(ctx, QMON_LOG_WARN, "IP头部长度错误\n");
        return 0;
    }
    
    /* 解析ICMP头部 */
    struct icmphdr* icmp_hdr = (struct icmphdr*)(packet + hlen);
    
    /* 检查是否是我们发送的echo回复 */
    if (icmp_hdr->type != ICMP_ECHOREPLY) {
        return 0;  /* 不是echo回复 */
    }
    
    uint16_t recv_id = ntohs(icmp_hdr->un.echo.id);
    if (recv_id != ctx->ident) {
        if (ctx->config.verbose) {
            qosmon_log(ctx, QMON_LOG_DEBUG, "收到非本进程的ICMP包: ID=%d (期望: %d)\n", 
                      recv_id, ctx->ident);
        }
        return 0;
    }
    
    /* 获取发送时间戳 */
    struct timeval* send_tv = (struct timeval*)(packet + hlen + sizeof(struct icmphdr));
    struct timeval recv_tv;
    gettimeofday(&recv_tv, NULL);
    
    /* 计算延迟（微秒） */
    int64_t rtt_us = (recv_tv.tv_sec - send_tv->tv_sec) * 1000000L + 
                     (recv_tv.tv_usec - send_tv->tv_usec);
    
    if (rtt_us < 0) rtt_us = 0;
    if (rtt_us > MAX_PING_TIME_MS * 1000) rtt_us = MAX_PING_TIME_MS * 1000;
    if (rtt_us < MIN_PING_TIME_MS * 1000) rtt_us = MIN_PING_TIME_MS * 1000;
    
    ctx->nreceived++;
    
    /* 更新ping历史 */
    ctx->raw_ping_time_us = rtt_us;
    update_ping_history(ctx, rtt_us);
    
    if (ctx->config.verbose) {
        qosmon_log(ctx, QMON_LOG_DEBUG, "收到ping回复 #%d, ID=%d, 序列=%d, 延迟: %.1f ms\n", 
                  ctx->nreceived, recv_id, ntohs(icmp_hdr->un.echo.sequence),
                  rtt_us / 1000.0f);
    }
    
    return 1;
}

/* 更新ping历史 */
static void update_ping_history(qosmon_context_t* ctx, int64_t ping_time_us) {
    if (!ctx) return;
    
    /* 更新历史记录 */
    ctx->ping_history.times[ctx->ping_history.index] = ping_time_us;
    ctx->ping_history.index = (ctx->ping_history.index + 1) % PING_HISTORY_SIZE;
    if (ctx->ping_history.count < PING_HISTORY_SIZE) {
        ctx->ping_history.count++;
    }
    
    /* 计算平滑延迟 */
    float alpha = 0.3f;  /* 平滑因子 */
    if (ctx->ping_history.smoothed == 0) {
        ctx->ping_history.smoothed = ping_time_us;
    } else {
        ctx->ping_history.smoothed = alpha * ping_time_us + (1 - alpha) * ctx->ping_history.smoothed;
    }
    
    ctx->filtered_ping_time_us = (int64_t)ctx->ping_history.smoothed;
    
    /* 更新最大延迟 */
    if (ping_time_us > ctx->max_ping_time_us) {
        ctx->max_ping_time_us = ping_time_us;
    }
    
    /* 更新最小延迟 */
    if (ctx->min_ping_time_us == 0 || ping_time_us < ctx->min_ping_time_us) {
        ctx->min_ping_time_us = ping_time_us;
    }
}

/* ICMP校验和计算 */
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

/* 清理Ping管理器 */
void ping_manager_cleanup(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    if (ctx->ping_socket >= 0) {
        close(ctx->ping_socket);
        ctx->ping_socket = -1;
    }
    
    qosmon_log(ctx, QMON_LOG_INFO, "Ping管理器清理完成\n");
}

/* TC控制器初始化 */
int tc_controller_init(tc_controller_t* tc, qosmon_context_t* ctx) {
    if (!tc || !ctx) return QMON_ERR_MEMORY;
    
    tc->ctx = ctx;
    tc->seq = 0;
    
    /* 检测队列算法 */
    char* qdisc_kind = detect_qdisc_kind(ctx);
    strncpy(ctx->detected_qdisc, qdisc_kind, MAX_QDISC_KIND_LEN - 1);
    ctx->detected_qdisc[MAX_QDISC_KIND_LEN - 1] = '\0';
    
    /* 映射队列类型枚举 */
    if (strcmp(qdisc_kind, "htb") == 0) {
        tc->qdisc_kind = QDISC_HTB;
    } else if (strcmp(qdisc_kind, "hfsc") == 0) {
        tc->qdisc_kind = QDISC_HFSC;
    } else if (strcmp(qdisc_kind, "tbf") == 0) {
        tc->qdisc_kind = QDISC_TBF;
    } else if (strcmp(qdisc_kind, "drr") == 0) {
        tc->qdisc_kind = QDISC_DRR;
    } else if (strcmp(qdisc_kind, "sfq") == 0) {
        tc->qdisc_kind = QDISC_SFQ;
    } else if (strcmp(qdisc_kind, "codel") == 0) {
        tc->qdisc_kind = QDISC_CODEL;
    } else if (strcmp(qdisc_kind, "fq_codel") == 0) {
        tc->qdisc_kind = QDISC_FQ_CODEL;
    } else {
        tc->qdisc_kind = QDISC_PFIFO_FAST;
    }
    
    /* 检测当前带宽 */
    int current_bw_kbps = 0;
    int ret = detect_class_bandwidth(ctx, &current_bw_kbps, tc);
    if (ret == QMON_OK && current_bw_kbps > 0) {
        ctx->current_limit_bps = current_bw_kbps * 1000;
        qosmon_log(ctx, QMON_LOG_INFO, "检测到当前带宽: %d kbps\n", current_bw_kbps);
    } else {
        ctx->current_limit_bps = ctx->config.max_bandwidth_kbps * 1000;
        qosmon_log(ctx, QMON_LOG_INFO, "使用默认带宽: %d kbps\n", ctx->config.max_bandwidth_kbps);
    }
    
    /* 打开netlink socket（如果启用） */
    if (ctx->config.use_netlink) {
        tc->netlink_fd = netlink_open();
        if (tc->netlink_fd < 0) {
            qosmon_log(ctx, QMON_LOG_WARN, "Netlink初始化失败，将使用shell命令\n");
        } else {
            qosmon_log(ctx, QMON_LOG_INFO, "Netlink初始化成功\n");
        }
    } else {
        tc->netlink_fd = -1;
        qosmon_log(ctx, QMON_LOG_INFO, "Netlink被禁用，将使用shell命令\n");
    }
    
    qosmon_log(ctx, QMON_LOG_INFO, "TC控制器初始化完成，队列算法: %s\n", qdisc_kind);
    return QMON_OK;
}

/* 修复1: Netlink通信修复 */
static int tc_set_bandwidth_netlink(tc_controller_t* tc, int bandwidth_bps) {
    if (!tc || tc->netlink_fd < 0) {
        return QMON_ERR_NETLINK;
    }
    
    char buf[4096];
    struct nlmsghdr* n = (struct nlmsghdr*)buf;
    struct tcmsg* t = NLMSG_DATA(n);
    
    memset(buf, 0, sizeof(buf));
    
    /* 设置netlink消息头 */
    n->nlmsg_len = NLMSG_LENGTH(sizeof(*t));
    n->nlmsg_type = RTM_NEWTCLASS;
    n->nlmsg_flags = NLM_F_REQUEST | NLM_F_REPLACE | NLM_F_CREATE | NLM_F_ACK;
    n->nlmsg_seq = ++tc->seq;
    n->nlmsg_pid = getpid();
    
    /* 设置TC消息 */
    t->tcm_family = AF_UNSPEC;
    t->tcm_ifindex = 0;  /* 将在后面设置 */
    t->tcm_handle = tc->ctx->config.classid;
    t->tcm_parent = 1;  /* 父类 */
    
    /* 获取接口索引 */
    struct ifreq ifr;
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        qosmon_log(tc->ctx, QMON_LOG_ERROR, "创建socket失败: %s\n", strerror(errno));
        return QMON_ERR_SOCKET;
    }
    
    strncpy(ifr.ifr_name, tc->ctx->config.device, IFNAMSIZ - 1);
    ifr.ifr_name[IFNAMSIZ - 1] = '\0';
    
    if (ioctl(sock, SIOCGIFINDEX, &ifr) < 0) {
        qosmon_log(tc->ctx, QMON_LOG_ERROR, "获取接口索引失败: %s\n", strerror(errno));
        close(sock);
        return QMON_ERR_SYSTEM;
    }
    
    t->tcm_ifindex = ifr.ifr_ifindex;
    close(sock);
    
    /* 根据队列规则类型设置参数 */
    int bandwidth_kbps = (bandwidth_bps + 500) / 1000;
    
    struct rtattr* tail = NLMSG_TAIL(n);
    switch (tc->qdisc_kind) {
        case QDISC_HTB: {
            /* HTB参数 */
            struct rtattr* opt = (struct rtattr*)tail;
            opt->rta_type = TCA_OPTIONS;
            opt->rta_len = RTA_LENGTH(sizeof(struct tc_htb_opt));
            
            struct tc_htb_opt htb_opt = {0};
            htb_opt.rate.rate = bandwidth_kbps * 1024;  /* 转换为字节 */
            htb_opt.ceil.rate = bandwidth_kbps * 1024;
            htb_opt.buffer = tc->ctx->config.buffer;
            htb_opt.cbuffer = tc->ctx->config.cbuffer;
            htb_opt.quantum = tc->ctx->config.quantum;
            
            memcpy(RTA_DATA(opt), &htb_opt, sizeof(htb_opt));
            tail = (struct rtattr*)((char*)tail + RTA_ALIGN(opt->rta_len));
            break;
        }
        case QDISC_HFSC: {
            /* HFSC参数 */
            struct rtattr* opt = (struct rtattr*)tail;
            opt->rta_type = TCA_OPTIONS;
            opt->rta_len = RTA_LENGTH(sizeof(struct tc_hfsc_qopt));
            
            struct tc_hfsc_qopt hfsc_opt = {0};
            hfsc_opt.defcls = tc->ctx->config.classid;
            hfsc_opt.rt.m1 = tc->ctx->config.hfsc_m1;
            hfsc_opt.rt.d = tc->ctx->config.hfsc_d;
            hfsc_opt.rt.m2 = bandwidth_kbps * 1024;
            hfsc_opt.ls.m1 = tc->ctx->config.hfsc_m1;
            hfsc_opt.ls.d = tc->ctx->config.hfsc_d;
            hfsc_opt.ls.m2 = bandwidth_kbps * 1024;
            
            memcpy(RTA_DATA(opt), &hfsc_opt, sizeof(hfsc_opt));
            tail = (struct rtattr*)((char*)tail + RTA_ALIGN(opt->rta_len));
            break;
        }
        case QDISC_TBF: {
            /* TBF参数 */
            struct rtattr* opt = (struct rtattr*)tail;
            opt->rta_type = TCA_OPTIONS;
            opt->rta_len = RTA_LENGTH(sizeof(struct tc_tbf_qopt));
            
            struct tc_tbf_qopt tbf_opt = {0};
            tbf_opt.rate.rate = bandwidth_kbps * 1024;
            tbf_opt.limit = tc->ctx->config.tbf_limit;
            tbf_opt.buffer = tc->ctx->config.tbf_burst;
            tbf_opt.mtu = tc->ctx->config.tbf_mtu;
            
            memcpy(RTA_DATA(opt), &tbf_opt, sizeof(tbf_opt));
            tail = (struct rtattr*)((char*)tail + RTA_ALIGN(opt->rta_len));
            break;
        }
        default:
            /* 使用默认HTB参数 */
            struct rtattr* opt = (struct rtattr*)tail;
            opt->rta_type = TCA_OPTIONS;
            opt->rta_len = RTA_LENGTH(sizeof(struct tc_htb_opt));
            
            struct tc_htb_opt htb_opt = {0};
            htb_opt.rate.rate = bandwidth_kbps * 1024;
            htb_opt.ceil.rate = bandwidth_kbps * 1024;
            htb_opt.buffer = 1600;
            htb_opt.cbuffer = 1600;
            htb_opt.quantum = 1514;
            
            memcpy(RTA_DATA(opt), &htb_opt, sizeof(htb_opt));
            tail = (struct rtattr*)((char*)tail + RTA_ALIGN(opt->rta_len));
            break;
    }
    
    /* 更新消息长度 */
    n->nlmsg_len = (void*)tail - (void*)buf;
    
    /* 发送消息 */
    struct sockaddr_nl nl_addr = {0};
    nl_addr.nl_family = AF_NETLINK;
    nl_addr.nl_pid = 0;  /* 发送到内核 */
    
    struct iovec iov = {buf, n->nlmsg_len};
    struct msghdr msg = {0};
    msg.msg_name = &nl_addr;
    msg.msg_namelen = sizeof(nl_addr);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    
    int ret = sendmsg(tc->netlink_fd, &msg, 0);
    if (ret < 0) {
        qosmon_log(tc->ctx, QMON_LOG_ERROR, "发送netlink消息失败: %s\n", strerror(errno));
        return QMON_ERR_NETLINK;
    }
    
    /* 接收ACK */
    return netlink_receive_ack(tc);
}

/* 修复2: TC命令字符串构建修复 */
static int tc_set_bandwidth_shell(qosmon_context_t* ctx, int bandwidth_bps) {
    int bandwidth_kbps = (bandwidth_bps + 500) / 1000;
    char cmd[512];
    int ret = 0;
    
    /* 构建安全的TC命令 */
    int n = 0;
    if (strcmp(ctx->detected_qdisc, "hfsc") == 0) {
        n = snprintf(cmd, sizeof(cmd), 
            "tc class change dev %s parent 1: classid 1:%x hfsc "
            "ls m1 0b d 0us m2 %dkbit "
            "ul m1 0b d 0us m2 %dkbit 2>&1",
            ctx->config.device, ctx->config.classid, 
            bandwidth_kbps, bandwidth_kbps);
    } else {
        n = snprintf(cmd, sizeof(cmd), 
            "tc class change dev %s parent 1: classid 1:%x htb "
            "rate %dkbit ceil %dkbit 2>&1",
            ctx->config.device, ctx->config.classid, 
            bandwidth_kbps, bandwidth_kbps);
    }
    
    /* 检查缓冲区是否足够 */
    if (n >= sizeof(cmd)) {
        qosmon_log(ctx, QMON_LOG_ERROR, "TC命令过长: %d > %zu\n", n, sizeof(cmd));
        return QMON_ERR_BUFFER;
    }
    
    qosmon_log(ctx, QMON_LOG_DEBUG, "执行TC命令: %s\n", cmd);
    
    /* 执行命令 */
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        qosmon_log(ctx, QMON_LOG_ERROR, "执行TC命令失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
    }
    
    char output[256];
    while (fgets(output, sizeof(output), fp) != NULL) {
        if (ctx->config.verbose) {
            qosmon_log(ctx, QMON_LOG_DEBUG, "TC输出: %s", output);
        }
    }
    
    ret = pclose(fp);
    
    if (WIFEXITED(ret)) {
        ret = WEXITSTATUS(ret);
    } else {
        ret = -1;
    }
    
    if (ret != 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "TC命令执行失败: 返回码=%d\n", ret);
        return QMON_ERR_SYSTEM;
    }
    
    return QMON_OK;
}

/* TC控制器设置带宽 */
int tc_controller_set_bandwidth(tc_controller_t* tc, int bandwidth_bps) {
    if (!tc || !tc->ctx) return QMON_ERR_MEMORY;
    
    /* 边界检查 */
    int max_bps = tc->ctx->config.max_bandwidth_kbps * 1000;
    int min_bps = (int)(max_bps * tc->ctx->config.min_bw_ratio);
    
    if (bandwidth_bps > max_bps) {
        bandwidth_bps = max_bps;
        qosmon_log(tc->ctx, QMON_LOG_WARN, "带宽超过最大值，限制为: %d bps\n", max_bps);
    }
    
    if (bandwidth_bps < min_bps) {
        bandwidth_bps = min_bps;
        qosmon_log(tc->ctx, QMON_LOG_WARN, "带宽低于最小值，限制为: %d bps\n", min_bps);
    }
    
    /* 检查变化是否达到最小阈值 */
    int min_change_bps = tc->ctx->config.min_bw_change_kbps * 1000;
    int diff = abs(bandwidth_bps - tc->ctx->current_limit_bps);
    if (diff < min_change_bps) {
        qosmon_log(tc->ctx, QMON_LOG_DEBUG, "带宽变化太小(%d bps < %d bps)，跳过\n", 
                  diff, min_change_bps);
        return QMON_OK;
    }
    
    /* 选择设置方法 */
    int ret = QMON_OK;
    if (tc->netlink_fd >= 0 && tc->ctx->config.use_netlink) {
        ret = tc_set_bandwidth_netlink(tc, bandwidth_bps);
        if (ret != QMON_OK) {
            qosmon_log(tc->ctx, QMON_LOG_WARN, "Netlink设置失败，尝试shell方法\n");
            ret = tc_set_bandwidth_shell(tc->ctx, bandwidth_bps);
        }
    } else {
        ret = tc_set_bandwidth_shell(tc->ctx, bandwidth_bps);
    }
    
    if (ret == QMON_OK) {
        tc->ctx->current_limit_bps = bandwidth_bps;
        qosmon_log(tc->ctx, QMON_LOG_INFO, "带宽设置成功: %d kbps (%.2f Mbps)\n", 
                  bandwidth_bps / 1000, bandwidth_bps / 1000000.0f);
    } else {
        qosmon_log(tc->ctx, QMON_LOG_ERROR, "带宽设置失败: %d\n", ret);
    }
    
    return ret;
}

/* 修复3: 状态机逻辑修复 */
static void state_machine_chk(qosmon_context_t* ctx, int64_t now,
                              ping_manager_t* ping_mgr, tc_controller_t* tc_mgr) {
    if (!ctx || !ping_mgr || !tc_mgr) {
        return;
    }
    
    /* 检查网络接口 */
    struct ifreq ifr;
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建socket失败: %s\n", strerror(errno));
        ctx->state = QMON_EXIT;
        return;
    }
    
    strncpy(ifr.ifr_name, ctx->config.device, IFNAMSIZ - 1);
    ifr.ifr_name[IFNAMSIZ - 1] = '\0';
    
    if (ioctl(sock, SIOCGIFFLAGS, &ifr) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "网络接口 %s 不存在或不可用: %s\n", 
                  ctx->config.device, strerror(errno));
        close(sock);
        ctx->state = QMON_EXIT;
        return;
    }
    
    if (!(ifr.ifr_flags & IFF_UP)) {
        qosmon_log(ctx, QMON_LOG_WARN, "网络接口 %s 未启动\n", ctx->config.device);
    }
    
    /* 检查路由 */
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "ip route get %s 2>&1", ctx->config.target);
    FILE* fp = popen(cmd, "r");
    if (fp) {
        char line[256];
        int route_found = 0;
        while (fgets(line, sizeof(line), fp)) {
            if (strstr(line, ctx->config.target) && strstr(line, "via")) {
                route_found = 1;
                break;
            }
        }
        pclose(fp);
        
        if (!route_found) {
            qosmon_log(ctx, QMON_LOG_WARN, "到 %s 的路由未找到\n", ctx->config.target);
        }
    }
    
    close(sock);
    
    /* 初始化TC */
    int ret = tc_controller_init(tc_mgr, ctx);
    if (ret != QMON_OK) {
        qosmon_log(ctx, QMON_LOG_WARN, "TC控制器初始化失败，但继续运行\n");
    }
    
    ctx->state = QMON_INIT;
    qosmon_log(ctx, QMON_LOG_INFO, "CHK完成，切换到INIT状态\n");
}

static void state_machine_init(qosmon_context_t* ctx, int64_t now,
                              ping_manager_t* ping_mgr, tc_controller_t* tc_mgr) {
    if (!ctx || !ping_mgr || !tc_mgr) {
        return;
    }
    
    /* 检查是否跳过初始化 */
    if (ctx->config.skip_initial) {
        ctx->state = QMON_IDLE;
        qosmon_log(ctx, QMON_LOG_INFO, "跳过初始化，切换到IDLE状态\n");
        return;
    }
    
    /* 保存当前带宽限制 */
    int saved_bandwidth_bps = ctx->current_limit_bps;
    
    /* 应用安全启动带宽 */
    int safe_bandwidth_bps = (int)(ctx->config.max_bandwidth_kbps * 1000 * 
                                 ctx->config.safe_start_ratio);
    
    if (tc_controller_set_bandwidth(tc_mgr, safe_bandwidth_bps) == QMON_OK) {
        qosmon_log(ctx, QMON_LOG_INFO, "应用安全启动带宽: %d kbps (%.1f%%)\n", 
                  safe_bandwidth_bps / 1000, 
                  ctx->config.safe_start_ratio * 100.0f);
        
        /* 等待一段时间让网络稳定 */
        usleep(2000000);  /* 2秒 */
        
        /* 恢复到之前设置的带宽 */
        tc_controller_set_bandwidth(tc_mgr, saved_bandwidth_bps);
    } else {
        qosmon_log(ctx, QMON_LOG_ERROR, "安全启动带宽设置失败\n");
    }
    
    ctx->state = QMON_IDLE;
    qosmon_log(ctx, QMON_LOG_INFO, "INIT完成，切换到IDLE状态\n");
}

static void state_machine_idle(qosmon_context_t* ctx, int64_t now,
                               ping_manager_t* ping_mgr, tc_controller_t* tc_mgr) {
    if (!ctx || !ping_mgr || !tc_mgr) {
        return;
    }
    
    /* 检查延迟是否超过阈值 */
    float current_ping_ms = ctx->filtered_ping_time_us / 1000.0f;
    float active_threshold = ctx->config.active_threshold * ctx->config.ping_limit_ms;
    
    if (current_ping_ms > active_threshold) {
        ctx->state = QMON_ACTIVE;
        qosmon_log(ctx, QMON_LOG_INFO, 
                   "网络延迟过高，切换到ACTIVE状态 (延迟: %.1f ms > %.1f ms)\n",
                   current_ping_ms, active_threshold);
        return;
    }
    
    /* 检查实时流量 */
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
    
    /* 空闲状态下，可以执行一些维护任务 */
    if (now - ctx->last_stats_time_ms >= STATS_INTERVAL_MS) {
        update_statistics(ctx);
        ctx->last_stats_time_ms = now;
    }
    
    /* 发送心跳包 */
    if (now - ctx->last_heartbeat_ms >= HEARTBEAT_INTERVAL_MS) {
        qosmon_log(ctx, QMON_LOG_DEBUG, "IDLE状态运行正常 (延迟: %.1f ms)\n", current_ping_ms);
        ctx->last_heartbeat_ms = now;
    }
}

static void state_machine_active(qosmon_context_t* ctx, int64_t now,
                                 ping_manager_t* ping_mgr, tc_controller_t* tc_mgr) {
    if (!ctx || !ping_mgr || !tc_mgr) {
        return;
    }
    
    /* 检查是否需要切换到空闲状态 */
    float current_ping_ms = ctx->filtered_ping_time_us / 1000.0f;
    float idle_threshold = ctx->config.idle_threshold * ctx->config.ping_limit_ms;
    
    if (current_ping_ms < idle_threshold) {
        ctx->state = QMON_IDLE;
        qosmon_log(ctx, QMON_LOG_INFO, 
                   "网络恢复空闲，切换到IDLE状态 (延迟: %.1f ms < %.1f ms)\n",
                   current_ping_ms, idle_threshold);
        return;
    }
    
    /* 检查是否需要切换到实时状态 */
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
    
    /* 根据延迟调整带宽 */
    if (now - ctx->last_tc_update_time_ms >= CONTROL_INTERVAL_MS) {
        adjust_bandwidth_by_ping(ctx, tc_mgr);
        ctx->last_tc_update_time_ms = now;
    }
}

static void state_machine_realtime(qosmon_context_t* ctx, int64_t now,
                                   ping_manager_t* ping_mgr, tc_controller_t* tc_mgr) {
    if (!ctx || !ping_mgr || !tc_mgr) {
        return;
    }
    
    /* 计算实时流量所需的带宽 */
    int realtime_bandwidth_bps = calculate_realtime_bandwidth(ctx);
    
    /* 保存当前限制（如果需要的话） */
    if (ctx->saved_realtime_limit == 0) {
        ctx->saved_realtime_limit = ctx->current_limit_bps;
    }
    
    /* 设置带宽 */
    if (realtime_bandwidth_bps > 0 && 
        realtime_bandwidth_bps != ctx->current_limit_bps) {
        if (tc_controller_set_bandwidth(tc_mgr, realtime_bandwidth_bps) == QMON_OK) {
            qosmon_log(ctx, QMON_LOG_INFO, 
                      "设置实时带宽: %d kbps (之前: %d kbps)\n",
                      realtime_bandwidth_bps / 1000,
                      ctx->current_limit_bps / 1000);
        }
    }
    
    /* 检查是否应该退出实时模式 */
    if (!detect_realtime_traffic(ctx)) {
        /* 恢复到之前保存的限制 */
        if (ctx->saved_realtime_limit > 0 && 
            ctx->saved_realtime_limit != ctx->current_limit_bps) {
            tc_controller_set_bandwidth(tc_mgr, ctx->saved_realtime_limit);
        }
        ctx->saved_realtime_limit = 0;
        ctx->state = QMON_ACTIVE;
        qosmon_log(ctx, QMON_LOG_INFO, "实时流量结束，切换到ACTIVE状态\n");
    }
}

/* 状态机主函数 */
void state_machine_run(qosmon_context_t* ctx, ping_manager_t* ping_mgr, tc_controller_t* tc_mgr) {
    if (!ctx) return;
    
    int64_t now = qosmon_time_ms();
    
    switch (ctx->state) {
        case QMON_CHK:
            state_machine_chk(ctx, now, ping_mgr, tc_mgr);
            break;
        case QMON_INIT:
            state_machine_init(ctx, now, ping_mgr, tc_mgr);
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
            qosmon_log(ctx, QMON_LOG_INFO, "退出状态机\n");
            break;
        default:
            qosmon_log(ctx, QMON_LOG_ERROR, "未知状态: %d\n", ctx->state);
            ctx->state = QMON_EXIT;
            break;
    }
}

/* 根据ping延迟调整带宽 */
static int adjust_bandwidth_by_ping(qosmon_context_t* ctx, tc_controller_t* tc_mgr) {
    if (!ctx || !tc_mgr) return QMON_ERR_MEMORY;
    
    float current_ping_ms = ctx->filtered_ping_time_us / 1000.0f;
    float target_ping_ms = ctx->config.ping_limit_ms;
    float max_bw_kbps = ctx->config.max_bandwidth_kbps;
    
    /* 计算延迟比率 */
    float ping_ratio = current_ping_ms / target_ping_ms;
    
    /* 根据延迟调整带宽 */
    int new_bandwidth_bps = ctx->current_limit_bps;
    
    if (ping_ratio > 1.5f) {
        /* 延迟严重超标，大幅降低带宽 */
        new_bandwidth_bps = (int)(ctx->current_limit_bps * 0.5f);
    } else if (ping_ratio > 1.2f) {
        /* 延迟超标，适当降低带宽 */
        new_bandwidth_bps = (int)(ctx->current_limit_bps * 0.8f);
    } else if (ping_ratio > 1.0f) {
        /* 延迟略高，小幅降低带宽 */
        new_bandwidth_bps = (int)(ctx->current_limit_bps * 0.9f);
    } else if (ping_ratio < 0.8f) {
        /* 延迟较低，可以尝试增加带宽 */
        new_bandwidth_bps = (int)(ctx->current_limit_bps * 1.1f);
        
        /* 但不超过最大带宽 */
        if (new_bandwidth_bps > max_bw_kbps * 1000) {
            new_bandwidth_bps = max_bw_kbps * 1000;
        }
    } else {
        /* 延迟在目标范围内，保持当前带宽 */
        return QMON_OK;
    }
    
    /* 确保带宽在最小和最大限制之间 */
    int min_bps = (int)(max_bw_kbps * 1000 * ctx->config.min_bw_ratio);
    int max_bps = max_bw_kbps * 1000;
    
    if (new_bandwidth_bps < min_bps) new_bandwidth_bps = min_bps;
    if (new_bandwidth_bps > max_bps) new_bandwidth_bps = max_bps;
    
    /* 应用新带宽 */
    int ret = tc_controller_set_bandwidth(tc_mgr, new_bandwidth_bps);
    if (ret != QMON_OK) {
        qosmon_log(ctx, QMON_LOG_ERROR, "调整带宽失败: %d\n", ret);
        return ret;
    }
    
    qosmon_log(ctx, QMON_LOG_INFO, 
               "根据延迟调整带宽: 延迟=%.1fms, 目标=%.1fms, 新带宽=%dkbps\n",
               current_ping_ms, target_ping_ms, new_bandwidth_bps / 1000);
    
    return QMON_OK;
}

/* 计算实时流量带宽 */
static int calculate_realtime_bandwidth(qosmon_context_t* ctx) {
    if (!ctx) return 0;
    
    /* 这里可以根据需要实现实时流量检测逻辑 */
    /* 例如，可以通过检测特定端口的流量来确定 */
    
    /* 简单实现：使用最大带宽的一定比例 */
    float realtime_ratio = 0.8f;  /* 实时流量占80% */
    int realtime_bw = (int)(ctx->config.max_bandwidth_kbps * 1000 * realtime_ratio);
    
    /* 确保不低于最小带宽 */
    int min_bw = (int)(ctx->config.max_bandwidth_kbps * 1000 * ctx->config.min_bw_ratio);
    if (realtime_bw < min_bw) {
        realtime_bw = min_bw;
    }
    
    return realtime_bw;
}

/* 检测实时流量 */
static int detect_realtime_traffic(qosmon_context_t* ctx) {
    if (!ctx) return 0;
    
    /* 这里可以添加实时流量检测逻辑 */
    /* 例如，通过检测特定端口（如RTP/RTCP, WebRTC等） */
    
    /* 简单实现：检查最近ping延迟的抖动 */
    float jitter = calculate_ping_jitter(ctx);
    
    /* 如果抖动较大，可能表示有实时流量 */
    if (jitter > ctx->config.ping_limit_ms * 0.5f) {
        qosmon_log(ctx, QMON_LOG_DEBUG, "检测到可能的实时流量 (抖动: %.1fms)\n", jitter);
        return 1;
    }
    
    return 0;
}

/* 计算ping抖动 */
static float calculate_ping_jitter(qosmon_context_t* ctx) {
    if (!ctx || ctx->ping_history.count < 2) {
        return 0.0f;
    }
    
    float sum = 0.0f;
    int count = 0;
    
    for (int i = 0; i < ctx->ping_history.count - 1; i++) {
        float diff = fabsf(ctx->ping_history.times[(ctx->ping_history.index + i) % PING_HISTORY_SIZE] -
                          ctx->ping_history.times[(ctx->ping_history.index + i + 1) % PING_HISTORY_SIZE]);
        sum += diff;
        count++;
    }
    
    if (count > 0) {
        return (sum / count) / 1000.0f;  /* 转换为毫秒 */
    }
    
    return 0.0f;
}

/* 更新统计信息 */
static void update_statistics(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    int64_t now = qosmon_time_ms();
    ctx->stats.total_time_ms = now - ctx->stats.start_time;
    
    /* 计算平均带宽（这里只是示例，实际需要从接口获取） */
    ctx->stats.avg_bandwidth_kbps = ctx->current_limit_bps / 1000.0f;
    
    /* 计算丢包率 */
    if (ctx->ntransmitted > 0) {
        ctx->stats.packet_loss_rate = 1.0f - ((float)ctx->nreceived / ctx->ntransmitted);
    } else {
        ctx->stats.packet_loss_rate = 0.0f;
    }
    
    /* 更新状态文件 */
    status_file_update(ctx);
}

/* 修复4: 内存泄漏修复 */
void tc_controller_cleanup(tc_controller_t* tc) {
    if (!tc) return;
    
    /* 关闭netlink socket */
    if (tc->netlink_fd >= 0) {
        close(tc->netlink_fd);
        tc->netlink_fd = -1;
    }
    
    /* 恢复默认带宽（如果不在安全模式） */
    if (tc->ctx && !tc->ctx->config.safe_mode) {
        int default_bw = tc->ctx->config.max_bandwidth_kbps * 1000;
        tc_controller_set_bandwidth(tc, default_bw);
    }
    
    qosmon_log(tc->ctx, QMON_LOG_INFO, "TC控制器清理完成\n");
}

/* 辅助函数 */
static int netlink_open(void) {
    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (fd < 0) {
        return -1;
    }
    
    struct sockaddr_nl addr = {0};
    addr.nl_family = AF_NETLINK;
    addr.nl_pid = getpid();
    addr.nl_groups = 0;
    
    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    
    return fd;
}

static int netlink_receive_ack(tc_controller_t* tc) {
    if (!tc || tc->netlink_fd < 0) {
        return QMON_ERR_NETLINK;
    }
    
    char buf[4096];
    struct iovec iov = {buf, sizeof(buf)};
    struct msghdr msg = {0};
    struct sockaddr_nl nl_addr = {0};
    msg.msg_name = &nl_addr;
    msg.msg_namelen = sizeof(nl_addr);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    
    int ret = recvmsg(tc->netlink_fd, &msg, MSG_DONTWAIT);
    if (ret < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return QMON_OK;  /* 没有响应，但可能成功 */
        }
        qosmon_log(tc->ctx, QMON_LOG_ERROR, "接收netlink响应失败: %s\n", strerror(errno));
        return QMON_ERR_NETLINK;
    }
    
    /* 解析netlink消息 */
    struct nlmsghdr* nlh = (struct nlmsghdr*)buf;
    for (; NLMSG_OK(nlh, ret); nlh = NLMSG_NEXT(nlh, ret)) {
        if (nlh->nlmsg_type == NLMSG_ERROR) {
            struct nlmsgerr* err = (struct nlmsgerr*)NLMSG_DATA(nlh);
            if (err->error != 0) {
                qosmon_log(tc->ctx, QMON_LOG_ERROR, "Netlink错误: %s\n", strerror(-err->error));
                return QMON_ERR_NETLINK;
            }
        }
    }
    
    return QMON_OK;
}

static char* detect_qdisc_kind(qosmon_context_t* ctx) {
    if (!ctx) return "htb";
    
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "tc qdisc show dev %s 2>&1", ctx->config.device);
    
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        qosmon_log(ctx, QMON_LOG_ERROR, "执行tc命令失败\n");
        return "htb";
    }
    
    static char kind[MAX_QDISC_KIND_LEN] = "htb";
    char line[256];
    
    while (fgets(line, sizeof(line), fp)) {
        if (strstr(line, "qdisc htb")) {
            strncpy(kind, "htb", MAX_QDISC_KIND_LEN - 1);
            break;
        } else if (strstr(line, "qdisc hfsc")) {
            strncpy(kind, "hfsc", MAX_QDISC_KIND_LEN - 1);
            break;
        } else if (strstr(line, "qdisc tbf")) {
            strncpy(kind, "tbf", MAX_QDISC_KIND_LEN - 1);
            break;
        } else if (strstr(line, "qdisc drr")) {
            strncpy(kind, "drr", MAX_QDISC_KIND_LEN - 1);
            break;
        } else if (strstr(line, "qdisc sfq")) {
            strncpy(kind, "sfq", MAX_QDISC_KIND_LEN - 1);
            break;
        } else if (strstr(line, "qdisc codel")) {
            strncpy(kind, "codel", MAX_QDISC_KIND_LEN - 1);
            break;
        } else if (strstr(line, "qdisc fq_codel")) {
            strncpy(kind, "fq_codel", MAX_QDISC_KIND_LEN - 1);
            break;
        }
    }
    
    pclose(fp);
    qosmon_log(ctx, QMON_LOG_INFO, "检测到队列算法: %s\n", kind);
    return kind;
}

static int detect_class_bandwidth(qosmon_context_t* ctx, int* current_bw_kbps, tc_controller_t* tc) {
    if (!ctx || !current_bw_kbps) return QMON_ERR_MEMORY;
    
    char cmd[512];
    snprintf(cmd, sizeof(cmd), 
             "tc class show dev %s classid 1:%x 2>&1", 
             ctx->config.device, ctx->config.classid);
    
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        return QMON_ERR_SYSTEM;
    }
    
    *current_bw_kbps = 0;
    char line[256];
    
    while (fgets(line, sizeof(line), fp)) {
        /* 解析HTB */
        char* rate_pos = strstr(line, "rate");
        if (rate_pos) {
            char* rate_end = strstr(rate_pos, "kbit");
            if (rate_end) {
                *rate_end = '\0';
                char* rate_str = rate_pos + 5;  /* 跳过"rate " */
                *current_bw_kbps = atoi(rate_str);
                break;
            }
        }
        
        /* 解析HFSC */
        char* m2_pos = strstr(line, "m2");
        if (m2_pos) {
            char* m2_end = strstr(m2_pos, "kbit");
            if (m2_end) {
                *m2_end = '\0';
                char* m2_str = m2_pos + 3;  /* 跳过"m2 " */
                *current_bw_kbps = atoi(m2_str);
                break;
            }
        }
    }
    
    pclose(fp);
    return QMON_OK;
}

/* 状态文件更新 */
int status_file_update(qosmon_context_t* ctx) {
    if (!ctx || ctx->config.status_file[0] == '\0') {
        return QMON_OK;
    }
    
    FILE* f = fopen(ctx->config.status_file, "w");
    if (!f) {
        qosmon_log(ctx, QMON_LOG_ERROR, "无法打开状态文件: %s\n", ctx->config.status_file);
        return QMON_ERR_SYSTEM;
    }
    
    fprintf(f, "{\n");
    fprintf(f, "  \"state\": %d,\n", ctx->state);
    fprintf(f, "  \"filtered_ping_ms\": %.1f,\n", ctx->filtered_ping_time_us / 1000.0f);
    fprintf(f, "  \"raw_ping_ms\": %.1f,\n", ctx->raw_ping_time_us / 1000.0f);
    fprintf(f, "  \"max_ping_ms\": %.1f,\n", ctx->max_ping_time_us / 1000.0f);
    fprintf(f, "  \"min_ping_ms\": %.1f,\n", ctx->min_ping_time_us / 1000.0f);
    fprintf(f, "  \"current_bandwidth_kbps\": %d,\n", ctx->current_limit_bps / 1000);
    fprintf(f, "  \"max_bandwidth_kbps\": %d,\n", ctx->config.max_bandwidth_kbps);
    fprintf(f, "  \"ping_limit_ms\": %d,\n", ctx->config.ping_limit_ms);
    fprintf(f, "  \"packet_loss_rate\": %.2f,\n", ctx->stats.packet_loss_rate);
    fprintf(f, "  \"avg_bandwidth_kbps\": %.1f,\n", ctx->stats.avg_bandwidth_kbps);
    fprintf(f, "  \"transmitted\": %d,\n", ctx->ntransmitted);
    fprintf(f, "  \"received\": %d,\n", ctx->nreceived);
    fprintf(f, "  \"timestamp\": %ld\n", (long)time(NULL));
    fprintf(f, "}\n");
    
    fclose(f);
    return QMON_OK;
}

/* 初始化状态机 */
void state_machine_init(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    ctx->state = QMON_CHK;
    ctx->stats.start_time = qosmon_time_ms();
    ctx->last_ping_time_ms = 0;
    ctx->last_tc_update_time_ms = 0;
    ctx->last_stats_time_ms = 0;
    ctx->last_realtime_detect_time_ms = 0;
    ctx->last_heartbeat_ms = 0;
    
    memset(&ctx->ping_history, 0, sizeof(ctx->ping_history));
    memset(&ctx->stats, 0, sizeof(ctx->stats));
    
    qosmon_log(ctx, QMON_LOG_INFO, "状态机初始化完成，初始状态: CHK\n");
}

/* 事件处理器 */
static void ping_event_handler(void* data) {
    qosmon_context_t* ctx = (qosmon_context_t*)data;
    if (!ctx) return;
    
    ping_manager_receive(ctx);
}

static void signal_event_handler(void* data) {
    qosmon_context_t* ctx = (qosmon_context_t*)data;
    if (!ctx) return;
    
    char buf[64];
    ssize_t n = read(ctx->signal_pipe[0], buf, sizeof(buf));
    if (n > 0) {
        qosmon_log(ctx, QMON_LOG_INFO, "收到信号\n");
        ctx->sigterm = 1;
    }
}

static void timer_event_handler(void* data) {
    /* 处理定时器事件 */
    qosmon_context_t* ctx = (qosmon_context_t*)data;
    if (!ctx) return;
    
    uint64_t expirations;
    ssize_t n = read(ctx->timer_fd, &expirations, sizeof(expirations));
    if (n != sizeof(expirations)) {
        qosmon_log(ctx, QMON_LOG_ERROR, "读取定时器失败\n");
    }
}

static void ping_timer_callback(void* data) {
    qosmon_context_t* ctx = (qosmon_context_t*)data;
    if (!ctx) return;
    
    ping_manager_send(ctx);
}

static void state_machine_timer_callback(void* data) {
    qosmon_context_t* ctx = (qosmon_context_t*)data;
    if (!ctx) return;
    
    /* 这里可以调用状态机更新，但状态机已经在主循环中运行 */
    /* 我们主要更新一些定期检查 */
}

static void status_update_timer_callback(void* data) {
    qosmon_context_t* ctx = (qosmon_context_t*)data;
    if (!ctx) return;
    
    status_file_update(ctx);
}

static void bandwidth_adjust_timer_callback(void* data) {
    qosmon_context_t* ctx = (qosmon_context_t*)data;
    if (!ctx) return;
    
    /* 在主循环中处理 */
}

/* 配置初始化 */
void qosmon_config_init(qosmon_config_t* cfg) {
    if (!cfg) return;
    
    memset(cfg, 0, sizeof(*cfg));
    
    /* 默认值 */
    strncpy(cfg->device, "ifb0", MAX_DEVICE_NAME - 1);
    strncpy(cfg->target, "8.8.8.8", MAX_TARGET_NAME - 1);
    cfg->ping_interval = DEFAULT_PING_INTERVAL;
    cfg->max_bandwidth_kbps = DEFAULT_MAX_BANDWIDTH_KBPS;
    cfg->ping_limit_ms = DEFAULT_PING_LIMIT_MS;
    cfg->classid = 0x101;
    cfg->safe_mode = 0;
    cfg->verbose = 0;
    cfg->auto_switch_mode = 1;
    cfg->background_mode = 0;
    cfg->skip_initial = 0;
    cfg->min_bw_change_kbps = 100;
    cfg->min_bw_ratio = 0.1f;
    cfg->max_bw_ratio = 1.0f;
    cfg->smoothing_factor = 0.3f;
    cfg->active_threshold = 0.8f;
    cfg->idle_threshold = 0.5f;
    cfg->safe_start_ratio = 0.5f;
    cfg->use_netlink = 1;
    cfg->mtu = 1500;
    cfg->buffer = 1600;
    cfg->cbuffer = 1600;
    cfg->quantum = 1514;
    cfg->hfsc_m1 = 0;
    cfg->hfsc_d = 0;
    cfg->hfsc_m2 = 10000;
    cfg->tbf_burst = 32;
    cfg->tbf_limit = 1000;
    cfg->tbf_mtu = 1500;
    
    cfg->status_file[0] = '\0';
    cfg->debug_log[0] = '\0';
    cfg->config_file[0] = '\0';
}

/* 配置解析 */
int qosmon_config_parse(qosmon_config_t* cfg, int argc, char* argv[]) {
    /* 解析命令行参数 */
    /* 这里简化处理，实际应用中需要完整的参数解析 */
    
    if (argc < 5) {
        fprintf(stderr, "用法: %s <device> <target> <ping_interval_ms> <max_bandwidth_kbps> <ping_limit_ms>\n", argv[0]);
        fprintf(stderr, "示例: %s ifb0 8.8.8.8 200 10000 20\n", argv[0]);
        fprintf(stderr, "可选参数:\n");
        fprintf(stderr, "  -c <classid>     : 类ID (十六进制, 默认: 0x101)\n");
        fprintf(stderr, "  -s              : 安全模式 (退出时恢复带宽)\n");
        fprintf(stderr, "  -v              : 详细输出\n");
        fprintf(stderr, "  -b              : 后台模式\n");
        fprintf(stderr, "  -f <config_file>: 配置文件\n");
        fprintf(stderr, "  -l <log_file>   : 日志文件\n");
        fprintf(stderr, "  -S <status_file>: 状态文件\n");
        fprintf(stderr, "  -n              : 不使用netlink (使用shell命令)\n");
        fprintf(stderr, "  -A              : 自动切换到实时模式\n");
        fprintf(stderr, "  -I              : 跳过初始带宽测试\n");
        return QMON_ERR_CONFIG;
    }
    
    /* 基本参数 */
    strncpy(cfg->device, argv[1], MAX_DEVICE_NAME - 1);
    strncpy(cfg->target, argv[2], MAX_TARGET_NAME - 1);
    cfg->ping_interval = atoi(argv[3]);
    cfg->max_bandwidth_kbps = atoi(argv[4]);
    
    if (argc > 5) {
        cfg->ping_limit_ms = atoi(argv[5]);
    }
    
    /* 可选参数 */
    for (int i = 6; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) {
            cfg->classid = (int)strtol(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "-s") == 0) {
            cfg->safe_mode = 1;
        } else if (strcmp(argv[i], "-v") == 0) {
            cfg->verbose = 1;
        } else if (strcmp(argv[i], "-b") == 0) {
            cfg->background_mode = 1;
        } else if (strcmp(argv[i], "-f") == 0 && i + 1 < argc) {
            strncpy(cfg->config_file, argv[++i], sizeof(cfg->config_file) - 1);
        } else if (strcmp(argv[i], "-l") == 0 && i + 1 < argc) {
            strncpy(cfg->debug_log, argv[++i], sizeof(cfg->debug_log) - 1);
        } else if (strcmp(argv[i], "-S") == 0 && i + 1 < argc) {
            strncpy(cfg->status_file, argv[++i], sizeof(cfg->status_file) - 1);
        } else if (strcmp(argv[i], "-n") == 0) {
            cfg->use_netlink = 0;
        } else if (strcmp(argv[i], "-A") == 0) {
            cfg->auto_switch_mode = 1;
        } else if (strcmp(argv[i], "-I") == 0) {
            cfg->skip_initial = 1;
        } else if (strcmp(argv[i], "-h") == 0) {
            return QMON_ERR_CONFIG;
        }
    }
    
    /* 加载配置文件（如果有） */
    if (cfg->config_file[0] != '\0') {
        qosmon_config_load_file(cfg, cfg->config_file);
    }
    
    return QMON_OK;
}

int qosmon_config_load_file(qosmon_config_t* cfg, const char* filename) {
    if (!cfg || !filename) return QMON_ERR_MEMORY;
    
    FILE* f = fopen(filename, "r");
    if (!f) {
        return QMON_ERR_CONFIG;
    }
    
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        /* 跳过注释和空行 */
        if (line[0] == '#' || line[0] == '\n') continue;
        
        char key[64], value[128];
        if (sscanf(line, "%63s = %127s", key, value) == 2) {
            if (strcmp(key, "device") == 0) {
                strncpy(cfg->device, value, MAX_DEVICE_NAME - 1);
            } else if (strcmp(key, "target") == 0) {
                strncpy(cfg->target, value, MAX_TARGET_NAME - 1);
            } else if (strcmp(key, "ping_interval") == 0) {
                cfg->ping_interval = atoi(value);
            } else if (strcmp(key, "max_bandwidth_kbps") == 0) {
                cfg->max_bandwidth_kbps = atoi(value);
            } else if (strcmp(key, "ping_limit_ms") == 0) {
                cfg->ping_limit_ms = atoi(value);
            } else if (strcmp(key, "classid") == 0) {
                cfg->classid = (int)strtol(value, NULL, 0);
            } else if (strcmp(key, "safe_mode") == 0) {
                cfg->safe_mode = atoi(value);
            } else if (strcmp(key, "verbose") == 0) {
                cfg->verbose = atoi(value);
            } else if (strcmp(key, "auto_switch_mode") == 0) {
                cfg->auto_switch_mode = atoi(value);
            } else if (strcmp(key, "background_mode") == 0) {
                cfg->background_mode = atoi(value);
            } else if (strcmp(key, "skip_initial") == 0) {
                cfg->skip_initial = atoi(value);
            } else if (strcmp(key, "min_bw_change_kbps") == 0) {
                cfg->min_bw_change_kbps = atoi(value);
            } else if (strcmp(key, "min_bw_ratio") == 0) {
                cfg->min_bw_ratio = atof(value);
            } else if (strcmp(key, "max_bw_ratio") == 0) {
                cfg->max_bw_ratio = atof(value);
            } else if (strcmp(key, "smoothing_factor") == 0) {
                cfg->smoothing_factor = atof(value);
            } else if (strcmp(key, "active_threshold") == 0) {
                cfg->active_threshold = atof(value);
            } else if (strcmp(key, "idle_threshold") == 0) {
                cfg->idle_threshold = atof(value);
            } else if (strcmp(key, "safe_start_ratio") == 0) {
                cfg->safe_start_ratio = atof(value);
            } else if (strcmp(key, "use_netlink") == 0) {
                cfg->use_netlink = atoi(value);
            } else if (strcmp(key, "mtu") == 0) {
                cfg->mtu = atoi(value);
            } else if (strcmp(key, "buffer") == 0) {
                cfg->buffer = atoi(value);
            } else if (strcmp(key, "cbuffer") == 0) {
                cfg->cbuffer = atoi(value);
            } else if (strcmp(key, "quantum") == 0) {
                cfg->quantum = atoi(value);
            } else if (strcmp(key, "hfsc_m1") == 0) {
                cfg->hfsc_m1 = atoi(value);
            } else if (strcmp(key, "hfsc_d") == 0) {
                cfg->hfsc_d = atoi(value);
            } else if (strcmp(key, "hfsc_m2") == 0) {
                cfg->hfsc_m2 = atoi(value);
            } else if (strcmp(key, "tbf_burst") == 0) {
                cfg->tbf_burst = atoi(value);
            } else if (strcmp(key, "tbf_limit") == 0) {
                cfg->tbf_limit = atoi(value);
            } else if (strcmp(key, "tbf_mtu") == 0) {
                cfg->tbf_mtu = atoi(value);
            } else if (strcmp(key, "status_file") == 0) {
                strncpy(cfg->status_file, value, MAX_STATUS_FILE - 1);
            } else if (strcmp(key, "debug_log") == 0) {
                strncpy(cfg->debug_log, value, MAX_DEBUG_LOG - 1);
            }
        }
    }
    
    fclose(f);
    return QMON_OK;
}

/* 清理函数 */
void qosmon_cleanup(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    /* 清理状态机 */
    state_machine_cleanup(ctx);
    
    /* 关闭所有文件描述符 */
    if (ctx->ping_socket >= 0) {
        close(ctx->ping_socket);
    }
    
    if (ctx->epoll_fd >= 0) {
        close(ctx->epoll_fd);
    }
    
    if (ctx->timer_fd >= 0) {
        close(ctx->timer_fd);
    }
    
    if (ctx->signal_pipe[0] >= 0) {
        close(ctx->signal_pipe[0]);
    }
    
    if (ctx->signal_pipe[1] >= 0) {
        close(ctx->signal_pipe[1]);
    }
}

void state_machine_cleanup(qosmon_context_t* ctx) {
    /* 这里可以添加状态机特定的清理 */
    qosmon_log(ctx, QMON_LOG_DEBUG, "状态机清理完成\n");
}

/* 主循环调用 */
int main_loop(qosmon_context_t* ctx, ping_manager_t* ping_mgr, tc_controller_t* tc_mgr) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    qosmon_log(ctx, QMON_LOG_INFO, "进入主循环\n");
    
    /* 创建epoll实例 */
    ctx->epoll_fd = epoll_create1(0);
    if (ctx->epoll_fd < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建epoll失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
    }
    
    /* 设置定时器 */
    ctx->timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
    if (ctx->timer_fd < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建定时器失败: %s\n", strerror(errno));
        close(ctx->epoll_fd);
        ctx->epoll_fd = -1;
        return QMON_ERR_SYSTEM;
    }
    
    struct itimerspec timer_spec = {0};
    timer_spec.it_interval.tv_sec = 1;  /* 每秒触发一次 */
    timer_spec.it_interval.tv_nsec = 0;
    timer_spec.it_value.tv_sec = 1;     /* 1秒后开始 */
    timer_spec.it_value.tv_nsec = 0;
    
    if (timerfd_settime(ctx->timer_fd, 0, &timer_spec, NULL) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "设置定时器失败: %s\n", strerror(errno));
        close(ctx->timer_fd);
        close(ctx->epoll_fd);
        ctx->timer_fd = -1;
        ctx->epoll_fd = -1;
        return QMON_ERR_SYSTEM;
    }
    
    /* 创建信号管道 */
    if (pipe(ctx->signal_pipe) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建信号管道失败: %s\n", strerror(errno));
        close(ctx->timer_fd);
        close(ctx->epoll_fd);
        ctx->timer_fd = -1;
        ctx->epoll_fd = -1;
        return QMON_ERR_SYSTEM;
    }
    
    /* 设置非阻塞IO */
    fcntl(ctx->signal_pipe[0], F_SETFL, O_NONBLOCK);
    fcntl(ctx->signal_pipe[1], F_SETFL, O_NONBLOCK);
    
    /* 注册信号处理 */
    struct sigaction sa = {0};
    sa.sa_handler = signal_handler;
    sa.sa_flags = SA_RESTART;
    sigemptyset(&sa.sa_mask);
    
    if (sigaction(SIGINT, &sa, NULL) < 0 ||
        sigaction(SIGTERM, &sa, NULL) < 0 ||
        sigaction(SIGQUIT, &sa, NULL) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "注册信号处理失败: %s\n", strerror(errno));
        close(ctx->signal_pipe[0]);
        close(ctx->signal_pipe[1]);
        close(ctx->timer_fd);
        close(ctx->epoll_fd);
        return QMON_ERR_SYSTEM;
    }
    
    /* 将描述符添加到epoll */
    struct epoll_event ev = {0};
    ev.events = EPOLLIN;
    
    /* 添加ping socket */
    if (ctx->ping_socket >= 0) {
        ev.data.fd = ctx->ping_socket;
        ev.data.ptr = ping_event_handler;
        if (epoll_ctl(ctx->epoll_fd, EPOLL_CTL_ADD, ctx->ping_socket, &ev) < 0) {
            qosmon_log(ctx, QMON_LOG_ERROR, "添加ping socket到epoll失败: %s\n", strerror(errno));
        }
    }
    
    /* 添加定时器 */
    ev.data.fd = ctx->timer_fd;
    ev.data.ptr = timer_event_handler;
    if (epoll_ctl(ctx->epoll_fd, EPOLL_CTL_ADD, ctx->timer_fd, &ev) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "添加定时器到epoll失败: %s\n", strerror(errno));
    }
    
    /* 添加信号管道 */
    ev.data.fd = ctx->signal_pipe[0];
    ev.data.ptr = signal_event_handler;
    if (epoll_ctl(ctx->epoll_fd, EPOLL_CTL_ADD, ctx->signal_pipe[0], &ev) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "添加信号管道到epoll失败: %s\n", strerror(errno));
    }
    
    /* 主循环 */
    qosmon_log(ctx, QMON_LOG_INFO, "开始主循环\n");
    
    int64_t last_ping_time_ms = 0;
    int64_t last_state_machine_time_ms = 0;
    int64_t last_status_update_time_ms = 0;
    int64_t last_bandwidth_adjust_time_ms = 0;
    
    while (!ctx->sigterm) {
        struct epoll_event events[MAX_EPOLL_EVENTS];
        int timeout = ctx->config.ping_interval;  /* 毫秒 */
        
        int nfds = epoll_wait(ctx->epoll_fd, events, MAX_EPOLL_EVENTS, timeout);
        
        int64_t now = qosmon_time_ms();
        
        /* 处理事件 */
        for (int i = 0; i < nfds; i++) {
            event_handler_t handler = (event_handler_t)events[i].data.ptr;
            if (handler) {
                handler((void*)ctx);
            }
        }
        
        /* 定期发送ping */
        if (now - last_ping_time_ms >= ctx->config.ping_interval) {
            ping_manager_send(ctx);
            last_ping_time_ms = now;
        }
        
        /* 运行状态机 */
        if (now - last_state_machine_time_ms >= 100) {  /* 每100毫秒运行一次 */
            state_machine_run(ctx, ping_mgr, tc_mgr);
            last_state_machine_time_ms = now;
        }
        
        /* 更新状态文件 */
        if (now - last_status_update_time_ms >= 1000) {  /* 每秒更新一次 */
            status_file_update(ctx);
            last_status_update_time_ms = now;
        }
        
        /* 检查是否需要调整带宽 */
        if (now - last_bandwidth_adjust_time_ms >= 2000) {  /* 每2秒检查一次 */
            if (ctx->state == QMON_ACTIVE) {
                adjust_bandwidth_by_ping(ctx, tc_mgr);
            }
            last_bandwidth_adjust_time_ms = now;
        }
        
        /* 检查退出条件 */
        if (ctx->state == QMON_EXIT) {
            qosmon_log(ctx, QMON_LOG_INFO, "状态机请求退出\n");
            break;
        }
    }
    
    qosmon_log(ctx, QMON_LOG_INFO, "主循环结束\n");
    
    /* 清理 */
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
        ctx->signal_pipe[0] = -1;
    }
    
    if (ctx->signal_pipe[1] >= 0) {
        close(ctx->signal_pipe[1]);
        ctx->signal_pipe[1] = -1;
    }
    
    return QMON_OK;
}

/* 信号处理函数 */
static void signal_handler(int sig) {
    /* 这个函数是信号处理程序，不能做太多事情 */
    /* 我们只是在信号管道中写入一个字节 */
    qosmon_context_t* ctx = global_ctx;  /* 全局上下文指针 */
    
    if (ctx && ctx->signal_pipe[1] >= 0) {
        char c = 1;
        if (write(ctx->signal_pipe[1], &c, 1) < 0) {
            /* 忽略写错误 */
        }
    }
}

/* 修复5: 资源管理修复 */
static qosmon_context_t* create_context(void) {
    qosmon_context_t* ctx = (qosmon_context_t*)calloc(1, sizeof(qosmon_context_t));
    if (!ctx) {
        return NULL;
    }
    
    /* 初始化所有文件描述符为-1 */
    ctx->ping_socket = -1;
    ctx->epoll_fd = -1;
    ctx->timer_fd = -1;
    ctx->signal_pipe[0] = -1;
    ctx->signal_pipe[1] = -1;
    
    /* 初始化其他成员 */
    ctx->ident = 0;
    ctx->sequence = 0;
    ctx->ntransmitted = 0;
    ctx->nreceived = 0;
    ctx->sigterm = 0;
    ctx->state = QMON_CHK;
    
    ctx->raw_ping_time_us = 0;
    ctx->filtered_ping_time_us = 0;
    ctx->max_ping_time_us = 0;
    ctx->min_ping_time_us = 0;
    
    ctx->current_limit_bps = 0;
    ctx->saved_realtime_limit = 0;
    
    ctx->last_ping_time_ms = 0;
    ctx->last_tc_update_time_ms = 0;
    ctx->last_stats_time_ms = 0;
    ctx->last_realtime_detect_time_ms = 0;
    ctx->last_heartbeat_ms = 0;
    
    memset(&ctx->target_addr, 0, sizeof(ctx->target_addr));
    ctx->target_addr_len = 0;
    
    memset(&ctx->ping_history, 0, sizeof(ctx->ping_history));
    memset(&ctx->stats, 0, sizeof(ctx->stats));
    
    memset(ctx->detected_qdisc, 0, sizeof(ctx->detected_qdisc));
    
    return ctx;
}

static void destroy_context(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    /* 关闭所有打开的资源 */
    if (ctx->ping_socket >= 0) {
        close(ctx->ping_socket);
    }
    
    if (ctx->epoll_fd >= 0) {
        close(ctx->epoll_fd);
    }
    
    if (ctx->timer_fd >= 0) {
        close(ctx->timer_fd);
    }
    
    if (ctx->signal_pipe[0] >= 0) {
        close(ctx->signal_pipe[0]);
    }
    
    if (ctx->signal_pipe[1] >= 0) {
        close(ctx->signal_pipe[1]);
    }
    
    /* 释放内存 */
    free(ctx);
}

/* 修复6: 错误处理增强 */
int handle_epoll_errors(qosmon_context_t* ctx) {
    if (!ctx || ctx->epoll_fd < 0) {
        return QMON_ERR_SOCKET;
    }
    
    /* 检查epoll错误 */
    int error = 0;
    socklen_t len = sizeof(error);
    if (getsockopt(ctx->epoll_fd, SOL_SOCKET, SO_ERROR, &error, &len) < 0) {
        error = errno;
    }
    
    if (error != 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "epoll错误: %s\n", strerror(error));
        return QMON_ERR_SOCKET;
    }
    
    /* 检查其他描述符的错误 */
    int fds[] = {ctx->ping_socket, ctx->timer_fd, ctx->signal_pipe[0]};
    const char* fd_names[] = {"ping socket", "timer", "signal pipe"};
    
    for (int i = 0; i < 3; i++) {
        if (fds[i] >= 0) {
            error = 0;
            len = sizeof(error);
            if (getsockopt(fds[i], SOL_SOCKET, SO_ERROR, &error, &len) < 0) {
                if (errno != ENOTSOCK) {
                    error = errno;
                } else {
                    error = 0;  /* 不是socket，跳过 */
                }
            }
            
            if (error != 0) {
                qosmon_log(ctx, QMON_LOG_ERROR, "%s错误: %s\n", fd_names[i], strerror(error));
                return QMON_ERR_SOCKET;
            }
        }
    }
    
    return QMON_OK;
}

/* 日志系统增强 */
void qosmon_log(qosmon_context_t* ctx, qosmon_log_level_t level, const char* format, ...) {
    if (!ctx) return;
    
    static const char* level_strings[] = {
        "DEBUG", "INFO", "WARN", "ERROR", "FATAL"
    };
    
    if (level < ctx->config.log_level) {
        return;  /* 日志级别低于配置级别，不记录 */
    }
    
    time_t now = time(NULL);
    struct tm* tm_info = localtime(&now);
    char time_str[32];
    strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S", tm_info);
    
    FILE* output = stdout;
    if (ctx->config.debug_log[0] != '\0') {
        output = fopen(ctx->config.debug_log, "a");
        if (!output) {
            output = stderr;
        }
    } else if (ctx->config.background_mode) {
        output = fopen("/dev/null", "a");
        if (!output) {
            output = stdout;
        }
    }
    
    if (ctx->config.verbose || level >= QMON_LOG_WARN) {
        fprintf(output, "[%s] [%s] ", time_str, level_strings[level]);
        
        va_list args;
        va_start(args, format);
        vfprintf(output, format, args);
        va_end(args);
        
        fflush(output);
    }
    
    if (output != stdout && output != stderr) {
        fclose(output);
    }
}

/* 信号处理初始化 */
static int setup_signals(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    /* 设置全局上下文（用于信号处理程序） */
    global_ctx = ctx;
    
    struct sigaction sa = {0};
    sa.sa_handler = signal_handler;
    sa.sa_flags = SA_RESTART;
    sigemptyset(&sa.sa_mask);
    
    if (sigaction(SIGINT, &sa, NULL) < 0 ||
        sigaction(SIGTERM, &sa, NULL) < 0 ||
        sigaction(SIGQUIT, &sa, NULL) < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "设置信号处理失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
    }
    
    /* 忽略SIGPIPE */
    signal(SIGPIPE, SIG_IGN);
    
    return QMON_OK;
}

/* 后台模式 */
static int daemonize(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    pid_t pid = fork();
    if (pid < 0) {
        qosmon_log(ctx, QMON_LOG_ERROR, "创建守护进程失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
    }
    
    if (pid > 0) {
        /* 父进程退出 */
        exit(0);
    }
    
    /* 子进程继续 */
    setsid();
    
    /* 关闭标准文件描述符 */
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    
    /* 重新打开到/dev/null */
    open("/dev/null", O_RDONLY);
    open("/dev/null", O_WRONLY);
    open("/dev/null", O_WRONLY);
    
    /* 记录PID文件 */
    if (ctx->config.pid_file[0] != '\0') {
        FILE* pid_file = fopen(ctx->config.pid_file, "w");
        if (pid_file) {
            fprintf(pid_file, "%d\n", getpid());
            fclose(pid_file);
        }
    }
    
    return QMON_OK;
}

/* 主函数 */
int main(int argc, char* argv[]) {
    qosmon_config_t config = {0};
    qosmon_config_init(&config);
    
    /* 解析命令行参数 */
    int ret = qosmon_config_parse(&config, argc, argv);
    if (ret != QMON_OK) {
        if (ret != QMON_ERR_CONFIG) {
            fprintf(stderr, "配置解析失败: %d\n", ret);
        }
        return EXIT_FAILURE;
    }
    
    /* 验证配置 */
    if (config.max_bandwidth_kbps <= 0) {
        fprintf(stderr, "错误: 最大带宽必须大于0\n");
        return EXIT_FAILURE;
    }
    
    if (config.ping_limit_ms <= 0) {
        fprintf(stderr, "错误: ping限制必须大于0\n");
        return EXIT_FAILURE;
    }
    
    if (config.ping_interval <= 0) {
        fprintf(stderr, "错误: ping间隔必须大于0\n");
        return EXIT_FAILURE;
    }
    
    /* 创建上下文 */
    qosmon_context_t* ctx = create_context();
    if (!ctx) {
        fprintf(stderr, "创建上下文失败: 内存不足\n");
        return EXIT_FAILURE;
    }
    
    /* 复制配置 */
    memcpy(&ctx->config, &config, sizeof(config));
    
    /* 初始化日志 */
    qosmon_log(ctx, QMON_LOG_INFO, "QoSMonitor启动\n");
    qosmon_log(ctx, QMON_LOG_INFO, "设备: %s\n", ctx->config.device);
    qosmon_log(ctx, QMON_LOG_INFO, "目标: %s\n", ctx->config.target);
    qosmon_log(ctx, QMON_LOG_INFO, "最大带宽: %d kbps\n", ctx->config.max_bandwidth_kbps);
    qosmon_log(ctx, QMON_LOG_INFO, "Ping限制: %d ms\n", ctx->config.ping_limit_ms);
    qosmon_log(ctx, QMON_LOG_INFO, "Ping间隔: %d ms\n", ctx->config.ping_interval);
    
    /* 后台模式 */
    if (ctx->config.background_mode) {
        qosmon_log(ctx, QMON_LOG_INFO, "进入后台模式\n");
        if (daemonize(ctx) != QMON_OK) {
            qosmon_log(ctx, QMON_LOG_ERROR, "后台化失败\n");
            destroy_context(ctx);
            return EXIT_FAILURE;
        }
    }
    
    /* 设置信号处理 */
    if (setup_signals(ctx) != QMON_OK) {
        qosmon_log(ctx, QMON_LOG_ERROR, "信号处理设置失败\n");
        destroy_context(ctx);
        return EXIT_FAILURE;
    }
    
    /* 初始化ping管理器 */
    ping_manager_t ping_mgr = {0};
    ping_mgr.ctx = ctx;
    
    if (ping_manager_init(&ping_mgr) != QMON_OK) {
        qosmon_log(ctx, QMON_LOG_ERROR, "Ping管理器初始化失败\n");
        destroy_context(ctx);
        return EXIT_FAILURE;
    }
    
    /* 初始化TC控制器 */
    tc_controller_t tc_mgr = {0};
    
    if (tc_controller_init(&tc_mgr, ctx) != QMON_OK) {
        qosmon_log(ctx, QMON_LOG_WARN, "TC控制器初始化失败，继续以监控模式运行\n");
    }
    
    /* 初始化状态机 */
    state_machine_init(ctx);
    
    /* 运行主循环 */
    ret = main_loop(ctx, &ping_mgr, &tc_mgr);
    
    /* 清理 */
    qosmon_log(ctx, QMON_LOG_INFO, "开始清理...\n");
    
    ping_manager_cleanup(&ping_mgr);
    tc_controller_cleanup(&tc_mgr);
    
    /* 恢复原始带宽设置（如果启用安全模式） */
    if (ctx->config.safe_mode) {
        int default_bw = ctx->config.max_bandwidth_kbps * 1000;
        tc_controller_set_bandwidth(&tc_mgr, default_bw);
        qosmon_log(ctx, QMON_LOG_INFO, "恢复原始带宽: %d kbps\n", default_bw / 1000);
    }
    
    /* 删除PID文件 */
    if (ctx->config.pid_file[0] != '\0') {
        unlink(ctx->config.pid_file);
    }
    
    destroy_context(ctx);
    
    qosmon_log(NULL, QMON_LOG_INFO, "QoSMonitor退出\n");
    
    if (ret == QMON_OK) {
        return EXIT_SUCCESS;
    } else {
        return EXIT_FAILURE;
    }
}

/* 时间函数 */
int64_t qosmon_time_ms(void) {
    struct timeval tv = {0};
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

int64_t qosmon_time_us(void) {
    struct timeval tv = {0};
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000000 + tv.tv_usec;
}

/* 辅助宏定义 */
#define MAX_EPOLL_EVENTS 10
#define MAX_PING_TIME_MS 1000
#define MIN_PING_TIME_MS 1
#define PING_HISTORY_SIZE 10
#define HEARTBEAT_INTERVAL_MS 10000
#define STATS_INTERVAL_MS 5000
#define CONTROL_INTERVAL_MS 2000
#define REALTIME_DETECT_MS 1000

/* 类型定义 */
typedef enum {
    QMON_CHK = 0,       /* 检查网络状态 */
    QMON_INIT,          /* 初始化状态 */
    QMON_IDLE,          /* 空闲状态 */
    QMON_ACTIVE,        /* 活动状态（高延迟） */
    QMON_REALTIME,      /* 实时流量状态 */
    QMON_EXIT           /* 退出状态 */
} qosmon_state_t;

typedef enum {
    QDISC_HTB = 0,
    QDISC_HFSC,
    QDISC_TBF,
    QDISC_DRR,
    QDISC_SFQ,
    QDISC_CODEL,
    QDISC_FQ_CODEL,
    QDISC_PFIFO_FAST
} qdisc_kind_t;

typedef enum {
    QMON_LOG_DEBUG = 0,
    QMON_LOG_INFO,
    QMON_LOG_WARN,
    QMON_LOG_ERROR,
    QMON_LOG_FATAL
} qosmon_log_level_t;

typedef enum {
    QMON_OK = 0,
    QMON_ERR_MEMORY = -1,
    QMON_ERR_SOCKET = -2,
    QMON_ERR_SYSTEM = -3,
    QMON_ERR_CONFIG = -4,
    QMON_ERR_NETLINK = -5,
    QMON_ERR_BUFFER = -6
} qosmon_error_t;

/* 回调函数类型 */
typedef void (*event_handler_t)(void* data);

/* 全局上下文指针（用于信号处理） */
static qosmon_context_t* global_ctx = NULL;

/* 配置结构体 */
typedef struct {
    char device[MAX_DEVICE_NAME];           /* 网络设备名称 */
    char target[MAX_TARGET_NAME];           /* 目标地址 */
    int ping_interval;                      /* ping间隔（毫秒） */
    int max_bandwidth_kbps;                 /* 最大带宽（kbps） */
    int ping_limit_ms;                      /* ping限制（毫秒） */
    int classid;                            /* 类ID */
    int safe_mode;                          /* 安全模式 */
    int verbose;                            /* 详细输出 */
    int auto_switch_mode;                   /* 自动切换到实时模式 */
    int background_mode;                    /* 后台模式 */
    int skip_initial;                       /* 跳过初始化测试 */
    int min_bw_change_kbps;                 /* 最小带宽变化（kbps） */
    float min_bw_ratio;                     /* 最小带宽比例 */
    float max_bw_ratio;                     /* 最大带宽比例 */
    float smoothing_factor;                  /* 平滑因子 */
    float active_threshold;                  /* 激活阈值 */
    float idle_threshold;                    /* 空闲阈值 */
    float safe_start_ratio;                 /* 安全启动比例 */
    int use_netlink;                        /* 使用netlink */
    int mtu;                                /* MTU */
    int buffer;                             /* 缓冲区 */
    int cbuffer;                            /* 限速缓冲区 */
    int quantum;                            /* 量子值 */
    int hfsc_m1;                            /* HFSC M1 */
    int hfsc_d;                             /* HFSC D */
    int hfsc_m2;                            /* HFSC M2 */
    int tbf_burst;                          /* TBF突发值 */
    int tbf_limit;                          /* TBF限制 */
    int tbf_mtu;                            /* TBF MTU */
    char status_file[MAX_STATUS_FILE];      /* 状态文件 */
    char debug_log[MAX_DEBUG_LOG];          /* 调试日志 */
    char config_file[MAX_CONFIG_FILE];       /* 配置文件 */
    char pid_file[MAX_PID_FILE];            /* PID文件 */
    qosmon_log_level_t log_level;           /* 日志级别 */
} qosmon_config_t;

/* Ping历史结构体 */
typedef struct {
    int64_t times[PING_HISTORY_SIZE];       /* 历史ping时间 */
    int index;                              /* 当前索引 */
    int count;                              /* 历史数量 */
    float smoothed;                         /* 平滑值 */
} ping_history_t;

/* 统计结构体 */
typedef struct {
    int64_t start_time;                     /* 开始时间 */
    int64_t total_time_ms;                  /* 总运行时间 */
    float avg_bandwidth_kbps;               /* 平均带宽 */
    float packet_loss_rate;                  /* 丢包率 */
} statistics_t;

/* 主上下文结构体 */
typedef struct {
    qosmon_config_t config;                 /* 配置 */
    
    /* 网络相关 */
    int ping_socket;                        /* ping套接字 */
    struct sockaddr target_addr;            /* 目标地址 */
    socklen_t target_addr_len;              /* 地址长度 */
    uint16_t ident;                         /* ping标识符 */
    uint16_t sequence;                      /* ping序列号 */
    int ntransmitted;                       /* 发送计数 */
    int nreceived;                          /* 接收计数 */
    
    /* 状态管理 */
    qosmon_state_t state;                   /* 当前状态 */
    int sigterm;                            /* 终止信号 */
    
    /* 时间相关 */
    int64_t raw_ping_time_us;               /* 原始ping时间 */
    int64_t filtered_ping_time_us;          /* 过滤后ping时间 */
    int64_t max_ping_time_us;               /* 最大ping时间 */
    int64_t min_ping_time_us;               /* 最小ping时间 */
    
    /* 带宽管理 */
    int current_limit_bps;                  /* 当前限制（bps） */
    int saved_realtime_limit;               /* 保存的实时限制 */
    
    /* 时间戳 */
    int64_t last_ping_time_ms;              /* 上次ping时间 */
    int64_t last_tc_update_time_ms;         /* 上次TC更新时间 */
    int64_t last_stats_time_ms;             /* 上次统计时间 */
    int64_t last_realtime_detect_time_ms;   /* 上次实时检测时间 */
    int64_t last_heartbeat_ms;              /* 上次心跳时间 */
    
    /* 历史数据 */
    ping_history_t ping_history;            /* ping历史 */
    statistics_t stats;                     /* 统计信息 */
    
    /* 检测到的队列算法 */
    char detected_qdisc[MAX_QDISC_KIND_LEN]; /* 队列算法 */
    
    /* 文件描述符 */
    int epoll_fd;                           /* epoll描述符 */
    int timer_fd;                           /* 定时器描述符 */
    int signal_pipe[2];                     /* 信号管道 */
} qosmon_context_t;

/* Ping管理器结构体 */
typedef struct {
    qosmon_context_t* ctx;                  /* 上下文指针 */
} ping_manager_t;

/* TC控制器结构体 */
typedef struct {
    qosmon_context_t* ctx;                  /* 上下文指针 */
    int netlink_fd;                         /* netlink描述符 */
    int seq;                                /* 序列号 */
    qdisc_kind_t qdisc_kind;                /* 队列算法类型 */
} tc_controller_t;

/* 主程序结束 */