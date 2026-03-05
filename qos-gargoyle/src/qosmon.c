/* qosmon.c - 基于ping延迟的QoS监控器（优化版）
 * 功能：通过ping监控延迟，使用netlink动态调整带宽
 * 设计原则：模块化、错误安全、可配置、易于维护
 */

#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <syslog.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <signal.h>
#include <poll.h>
#include <netdb.h>
#include <netinet/ip_icmp.h>
#include <netinet/icmp6.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/pkt_sched.h>

/* ==================== 配置管理 ==================== */
typedef struct {
    // 网络参数
    int ping_interval;         // ms, 100-2000
    int max_bandwidth_kbps;    // kbps
    int ping_limit_ms;         // 可选的ping限制(ms)
    char target[256];          // ping目标
    char device[16];           // 网络设备名
    uint16_t classid;          // TC类ID
    
    // 算法参数
    float min_bw_ratio;        // 最小带宽比例
    float max_bw_ratio;        // 最大带宽比例
    float idle_threshold;      // IDLE状态阈值
    float active_threshold;    // ACTIVE状态阈值
    float smoothing_factor;    // 平滑因子
    int min_bw_change_kbps;    // 最小带宽变化阈值
    int safe_start_ratio;      // 安全启动比例
    
    // 运行参数
    int background_mode;       // 后台运行标志
    int auto_switch_mode;      // ACTIVE/MINRTT自动切换
    int skip_initial;          // 跳过初始测量
    int verbose;              // 详细输出
    int safe_mode;            // 安全模式（不实际修改TC）
    
    // 文件路径
    char status_file[256];     // 状态文件路径
    char debug_log[256];       // 调试日志路径
} qosmon_config_t;

/* ==================== 数据结构 ==================== */
// 状态枚举
typedef enum {
    QMON_CHK,
    QMON_INIT,
    QMON_ACTIVE,
    QMON_REALTIME,
    QMON_IDLE,
    QMON_EXIT
} qosmon_state_t;

// ping历史记录
typedef struct {
    int times[5];           // 历史ping时间(us)
    int index;              // 当前索引
    int count;              // 有效计数
    float smoothed;         // 平滑值
} ping_history_t;

// QoS监控器上下文
typedef struct {
    // 配置
    qosmon_config_t config;
    
    // 网络连接
    int ping_socket;
    int netlink_socket;
    struct sockaddr_storage target_addr;
    int ident;              // ICMP标识符
    
    // 算法状态
    qosmon_state_t state;
    int raw_ping_time_us;   // 原始ping时间(us)
    int filtered_ping_time_us; // 滤波ping时间(us)
    int max_ping_time_us;   // 最大ping时间(us)
    int current_limit_bps;  // 当前带宽限制(bps)
    int saved_active_limit; // ACTIVE模式保存值
    int saved_realtime_limit; // REALTIME模式保存值
    int filtered_total_load_bps; // 滤波总负载(bps)
    
    // 统计
    uint16_t ntransmitted;
    uint16_t nreceived;
    ping_history_t ping_history;
    int realtime_classes;   // 检测到的实时类数量
    
    // 时间控制
    int64_t last_ping_time_ms;
    int64_t last_stats_time_ms;
    int64_t last_tc_update_time_ms;
    int64_t last_realtime_detect_time_ms;
    
    // 文件句柄
    FILE* status_file;
    FILE* debug_log_file;
    long debug_log_size;
    
    // 信号标志
    volatile sig_atomic_t sigterm;
    volatile sig_atomic_t sigusr1;
    
    // 调试信息
    int last_tc_bw_kbps;
} qosmon_context_t;

/* ==================== 常量定义 ==================== */
#define DEFAULT_DEVICE        "ifb0"
#define DEFAULT_CLASSID       0x10001
#define PING_HISTORY_SIZE     5
#define MAX_PING_TIME_MS      800
#define MIN_PING_TIME_MS      5
#define STATS_INTERVAL_MS     1000
#define CONTROL_INTERVAL_MS   2000
#define REALTIME_DETECT_MS    5000
#define MAX_LOG_SIZE          (10 * 1024 * 1024)  // 10MB
#define NETLINK_BUFFER_SIZE   8192
#define MAX_PACKET_SIZE       100

/* ==================== 日志系统 ==================== */
typedef enum {
    LOG_ERROR,
    LOG_WARN,
    LOG_INFO,
    LOG_DEBUG
} log_level_t;

// 日志函数
void qosmon_log(qosmon_context_t* ctx, log_level_t level, 
                const char* format, ...) {
    if (!ctx) return;
    
    va_list args;
    va_start(args, format);
    
    const char* level_str = "UNKNOWN";
    FILE* output = stderr;
    
    switch (level) {
        case LOG_ERROR: level_str = "ERROR"; break;
        case LOG_WARN:  level_str = "WARN";  break;
        case LOG_INFO:  level_str = "INFO";  break;
        case LOG_DEBUG: level_str = "DEBUG"; break;
    }
    
    char timestamp[32];
    time_t now = time(NULL);
    struct tm* tm_info = localtime(&now);
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", tm_info);
    
    // 控制台输出
    if (ctx->config.verbose || level <= LOG_WARN) {
        fprintf(output, "[%s] [%s] ", timestamp, level_str);
        vfprintf(output, format, args);
        fflush(output);
    }
    
    // 调试日志文件
    if (ctx->debug_log_file && ctx->config.debug_log[0]) {
        if (ctx->debug_log_size > MAX_LOG_SIZE) {
            fclose(ctx->debug_log_file);
            ctx->debug_log_file = fopen(ctx->config.debug_log, "w");
            ctx->debug_log_size = 0;
        }
        
        fprintf(ctx->debug_log_file, "[%s] [%s] ", timestamp, level_str);
        vfprintf(ctx->debug_log_file, format, args);
        fflush(ctx->debug_log_file);
        
        // 计算大小
        fseek(ctx->debug_log_file, 0, SEEK_END);
        ctx->debug_log_size = ftell(ctx->debug_log_file);
    }
    
    // 系统日志（后台模式）
    if (ctx->config.background_mode && level <= LOG_INFO) {
        char syslog_msg[512];
        vsnprintf(syslog_msg, sizeof(syslog_msg), format, args);
        syslog(level == LOG_ERROR ? LOG_ERR : LOG_INFO, "%s", syslog_msg);
    }
    
    va_end(args);
}

/* ==================== 配置管理 ==================== */
// 默认配置
void qosmon_config_init(qosmon_config_t* config) {
    if (!config) return;
    
    memset(config, 0, sizeof(qosmon_config_t));
    
    // 算法参数
    config->min_bw_ratio = 0.15f;
    config->max_bw_ratio = 0.95f;
    config->idle_threshold = 0.05f;
    config->active_threshold = 0.12f;
    config->smoothing_factor = 0.3f;
    config->min_bw_change_kbps = 50;
    config->safe_start_ratio = 0.8f;
    
    // 网络参数
    strncpy(config->device, DEFAULT_DEVICE, sizeof(config->device) - 1);
    config->classid = DEFAULT_CLASSID;
    
    // 文件路径
    strncpy(config->status_file, "/tmp/qosmon_status.txt", 
            sizeof(config->status_file) - 1);
    strncpy(config->debug_log, "/tmp/qosmon_debug.log", 
            sizeof(config->debug_log) - 1);
    
    // 运行参数
    config->verbose = 0;
    config->background_mode = 0;
    config->auto_switch_mode = 0;
    config->skip_initial = 0;
    config->safe_mode = 0;
}

// 配置验证
int qosmon_config_validate(const qosmon_config_t* config, char* error, size_t error_len) {
    if (!config) {
        snprintf(error, error_len, "配置为空");
        return -1;
    }
    
    if (config->ping_interval < 100 || config->ping_interval > 2000) {
        snprintf(error, error_len, "ping间隔必须在100-2000ms之间");
        return -1;
    }
    
    if (config->max_bandwidth_kbps < 100) {
        snprintf(error, error_len, "带宽必须至少100kbps");
        return -1;
    }
    
    if (config->ping_limit_ms > 0 && 
        (config->ping_limit_ms < MIN_PING_TIME_MS || 
         config->ping_limit_ms > MAX_PING_TIME_MS)) {
        snprintf(error, error_len, "ping限制必须在%d-%dms之间", 
                MIN_PING_TIME_MS, MAX_PING_TIME_MS);
        return -1;
    }
    
    if (strlen(config->target) == 0) {
        snprintf(error, error_len, "必须指定ping目标");
        return -1;
    }
    
    return 0;
}

// 解析命令行参数
int qosmon_config_parse(qosmon_config_t* config, int argc, char* argv[]) {
    int i = 1;  // 跳过程序名
    
    while (i < argc && argv[i][0] == '-') {
        char* arg = argv[i] + 1;
        
        if (strcmp(arg, "b") == 0) {
            config->background_mode = 1;
        } else if (strcmp(arg, "a") == 0) {
            config->auto_switch_mode = 1;
        } else if (strcmp(arg, "s") == 0) {
            config->skip_initial = 1;
        } else if (strcmp(arg, "v") == 0) {
            config->verbose = 1;
        } else if (strcmp(arg, "safe") == 0) {
            config->safe_mode = 1;
        } else if (i + 1 < argc) {
            if (strcmp(arg, "t") == 0) {
                // 处理-t选项
                i++;
            } else if (strcmp(arg, "l") == 0) {
                // 处理-l选项
                i++;
            } else if (strcmp(arg, "device") == 0) {
                i++;
                strncpy(config->device, argv[i], sizeof(config->device) - 1);
            } else if (strcmp(arg, "status") == 0) {
                i++;
                strncpy(config->status_file, argv[i], sizeof(config->status_file) - 1);
            } else if (strcmp(arg, "log") == 0) {
                i++;
                strncpy(config->debug_log, argv[i], sizeof(config->debug_log) - 1);
            } else {
                fprintf(stderr, "未知选项: -%s\n", arg);
                return -1;
            }
        } else {
            fprintf(stderr, "选项 -%s 缺少参数\n", arg);
            return -1;
        }
        i++;
    }
    
    // 必需参数
    if (i + 2 >= argc) {
        fprintf(stderr, "用法: %s [选项] ping间隔 ping目标 带宽 [ping限制]\n", argv[0]);
        fprintf(stderr, "选项:\n");
        fprintf(stderr, "  -b            后台运行\n");
        fprintf(stderr, "  -a            启用ACTIVE/MINRTT自动切换\n");
        fprintf(stderr, "  -s            跳过初始链路测量\n");
        fprintf(stderr, "  -v            详细模式\n");
        fprintf(stderr, "  -safe         安全模式（不修改TC）\n");
        fprintf(stderr, "  -device <ifb> 网络设备（默认ifb0）\n");
        fprintf(stderr, "  -status <文件> 状态文件路径\n");
        fprintf(stderr, "  -log <文件>   调试日志路径\n");
        return -1;
    }
    
    config->ping_interval = atoi(argv[i++]);
    strncpy(config->target, argv[i++], sizeof(config->target) - 1);
    config->max_bandwidth_kbps = atoi(argv[i++]);
    
    if (i < argc) {
        config->ping_limit_ms = atoi(argv[i++]);
    }
    
    return 0;
}

/* ==================== 时间管理 ==================== */
int64_t qosmon_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + (int64_t)tv.tv_usec / 1000;
}

int64_t qosmon_time_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000000 + (int64_t)tv.tv_usec;
}

/* ==================== 网络工具 ==================== */
// ICMP校验和
uint16_t icmp_checksum(const void* data, size_t length) {
    const uint16_t* ptr = data;
    uint32_t sum = 0;
    
    while (length > 1) {
        sum += *ptr++;
        length -= 2;
    }
    
    if (length == 1) {
        sum += *(const uint8_t*)ptr;
    }
    
    sum = (sum >> 16) + (sum & 0xffff);
    sum += (sum >> 16);
    
    return ~sum;
}

// 解析目标地址
int resolve_target(const char* target, struct sockaddr_storage* addr, 
                   char* error, size_t error_len) {
    if (!target || !addr) return -1;
    
    memset(addr, 0, sizeof(struct sockaddr_storage));
    
    // 尝试IPv4
    struct sockaddr_in* addr4 = (struct sockaddr_in*)addr;
    if (inet_pton(AF_INET, target, &addr4->sin_addr) == 1) {
        addr4->sin_family = AF_INET;
        return 0;
    }
    
    // 尝试IPv6
    struct sockaddr_in6* addr6 = (struct sockaddr_in6*)addr;
    if (inet_pton(AF_INET6, target, &addr6->sin6_addr) == 1) {
        addr6->sin6_family = AF_INET6;
        return 0;
    }
    
    // 通过DNS解析
    struct addrinfo hints, *result = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_RAW;
    
    int ret = getaddrinfo(target, NULL, &hints, &result);
    if (ret != 0 || !result) {
        snprintf(error, error_len, "无法解析目标: %s", gai_strerror(ret));
        return -1;
    }
    
    memcpy(addr, result->ai_addr, result->ai_addrlen);
    freeaddrinfo(result);
    
    return 0;
}

/* ==================== Ping管理器 ==================== */
typedef struct {
    qosmon_context_t* ctx;
    char packet[MAX_PACKET_SIZE];
} ping_manager_t;

int ping_manager_init(ping_manager_t* pm, qosmon_context_t* ctx) {
    if (!pm || !ctx) return -1;
    
    pm->ctx = ctx;
    memset(pm->packet, 0, sizeof(pm->packet));
    
    // 创建ping socket
    int domain = (ctx->target_addr.ss_family == AF_INET) ? AF_INET : AF_INET6;
    int protocol = (domain == AF_INET) ? IPPROTO_ICMP : IPPROTO_ICMPV6;
    
    ctx->ping_socket = socket(domain, SOCK_RAW, protocol);
    if (ctx->ping_socket < 0) {
        qosmon_log(ctx, LOG_ERROR, "创建ping socket失败: %s\n", strerror(errno));
        return -1;
    }
    
    // 设置socket选项
    int ttl = 64;
    int on = 1;
    
    if (domain == AF_INET) {
        setsockopt(ctx->ping_socket, IPPROTO_IP, IP_TTL, &ttl, sizeof(ttl));
        setsockopt(ctx->ping_socket, IPPROTO_IP, IP_RECVERR, &on, sizeof(on));
    } else {
        setsockopt(ctx->ping_socket, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &ttl, sizeof(ttl));
        setsockopt(ctx->ping_socket, IPPROTO_IPV6, IPV6_RECVERR, &on, sizeof(on));
    }
    
    // 设置非阻塞
    int flags = fcntl(ctx->ping_socket, F_GETFL, 0);
    fcntl(ctx->ping_socket, F_SETFL, flags | O_NONBLOCK);
    
    return 0;
}

int ping_manager_send(ping_manager_t* pm) {
    if (!pm || !pm->ctx) return -1;
    
    qosmon_context_t* ctx = pm->ctx;
    int cc = 56;  // 标准ping数据大小
    struct timeval* tp = (struct timeval*)&pm->packet[8];
    
    if (ctx->target_addr.ss_family == AF_INET6) {
        struct icmp6_hdr* icp = (struct icmp6_hdr*)pm->packet;
        icp->icmp6_type = ICMP6_ECHO_REQUEST;
        icp->icmp6_code = 0;
        icp->icmp6_cksum = 0;
        icp->icmp6_seq = htons(++ctx->ntransmitted);
        icp->icmp6_id = htons(ctx->ident);
        
        gettimeofday(tp, NULL);
        
        // 填充数据
        for (int i = 0; i < cc - 8; i++) {
            pm->packet[8 + sizeof(struct timeval) + i] = i;
        }
        
        // IPv6需要特殊校验和处理
        int offset = 2;
        setsockopt(ctx->ping_socket, IPPROTO_IPV6, IPV6_CHECKSUM, 
                  &offset, sizeof(offset));
    } else {
        struct icmp* icp = (struct icmp*)pm->packet;
        icp->icmp_type = ICMP_ECHO;
        icp->icmp_code = 0;
        icp->icmp_cksum = 0;
        icp->icmp_seq = ++ctx->ntransmitted;
        icp->icmp_id = ctx->ident;
        
        gettimeofday(tp, NULL);
        
        // 填充数据
        for (int i = 0; i < cc - 8; i++) {
            pm->packet[8 + sizeof(struct timeval) + i] = i;
        }
        
        icp->icmp_cksum = icmp_checksum(icp, cc);
    }
    
    int ret = sendto(ctx->ping_socket, pm->packet, cc, 0,
                     (struct sockaddr*)&ctx->target_addr, 
                     sizeof(ctx->target_addr));
    
    if (ret < 0) {
        qosmon_log(ctx, LOG_ERROR, "发送ping失败: %s\n", strerror(errno));
        return -1;
    }
    
    ctx->last_ping_time_ms = qosmon_time_ms();
    qosmon_log(ctx, LOG_DEBUG, "发送ping, seq=%d\n", ctx->ntransmitted);
    
    return 0;
}

int ping_manager_receive(ping_manager_t* pm) {
    if (!pm || !pm->ctx) return -1;
    
    qosmon_context_t* ctx = pm->ctx;
    char buf[MAX_PACKET_SIZE];
    struct sockaddr_storage from;
    socklen_t fromlen = sizeof(from);
    
    int cc = recvfrom(ctx->ping_socket, buf, sizeof(buf), 0,
                      (struct sockaddr*)&from, &fromlen);
    
    if (cc < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            qosmon_log(ctx, LOG_ERROR, "接收ping失败: %s\n", strerror(errno));
        }
        return -1;
    }
    
    // 验证ping响应
    struct ip* ip = NULL;
    struct icmp* icp = NULL;
    struct icmp6_hdr* icp6 = NULL;
    struct timeval tv, *tp;
    int hlen, triptime;
    uint16_t seq;
    
    gettimeofday(&tv, NULL);
    
    if (from.ss_family == AF_INET6) {
        if (cc < (int)sizeof(struct icmp6_hdr)) return 0;
        icp6 = (struct icmp6_hdr*)buf;
        
        if (icp6->icmp6_type != ICMP6_ECHO_REPLY) return 0;
        if (ntohs(icp6->icmp6_id) != ctx->ident) return 0;
        
        seq = ntohs(icp6->icmp6_seq);
        tp = (struct timeval*)&icp6->icmp6_dataun.icmp6_un_data32[1];
    } else {
        ip = (struct ip*)buf;
        hlen = ip->ip_hl << 2;
        if (cc < hlen + 8) return 0;
        icp = (struct icmp*)(buf + hlen);
        
        if (icp->icmp_type != ICMP_ECHOREPLY) return 0;
        if (icp->icmp_id != ctx->ident) return 0;
        
        seq = icp->icmp_seq;
        tp = (struct timeval*)&icp->icmp_data[0];
    }
    
    if (seq != ctx->ntransmitted) return 0;
    
    ctx->nreceived++;
    
    // 计算往返时间
    triptime = (tv.tv_sec - tp->tv_sec) * 1000 + 
               (tv.tv_usec - tp->tv_usec) / 1000;
    
    // 限制范围
    if (triptime < MIN_PING_TIME_MS) triptime = MIN_PING_TIME_MS;
    if (triptime > MAX_PING_TIME_MS) triptime = MAX_PING_TIME_MS;
    
    ctx->raw_ping_time_us = triptime * 1000;
    
    // 更新最大ping时间
    if (ctx->raw_ping_time_us > ctx->max_ping_time_us) {
        ctx->max_ping_time_us = ctx->raw_ping_time_us;
    }
    
    // 更新ping历史
    ping_history_t* hist = &ctx->ping_history;
    hist->times[hist->index] = ctx->raw_ping_time_us;
    hist->index = (hist->index + 1) % PING_HISTORY_SIZE;
    if (hist->count < PING_HISTORY_SIZE) hist->count++;
    
    // 计算平滑值
    if (hist->count == 1) {
        hist->smoothed = ctx->raw_ping_time_us;
    } else {
        hist->smoothed = hist->smoothed * (1.0f - ctx->config.smoothing_factor) +
                          ctx->raw_ping_time_us * ctx->config.smoothing_factor;
    }
    
    ctx->filtered_ping_time_us = (int)hist->smoothed;
    
    qosmon_log(ctx, LOG_DEBUG, "收到ping回复: seq=%d, 时间=%dms, 平滑=%dms\n",
               seq, triptime, ctx->filtered_ping_time_us / 1000);
    
    return 1;
}

void ping_manager_cleanup(ping_manager_t* pm) {
    if (pm && pm->ctx && pm->ctx->ping_socket >= 0) {
        close(pm->ctx->ping_socket);
        pm->ctx->ping_socket = -1;
    }
}

/* ==================== 流量统计 ==================== */
int load_monitor_update(qosmon_context_t* ctx) {
    if (!ctx) return -1;
    
    static unsigned long long last_rx_bytes = 0;
    static int64_t last_read_time = 0;
    
    char line[256];
    unsigned long long rx_bytes = 0;
    int found = 0;
    
    FILE* fp = fopen("/proc/net/dev", "r");
    if (!fp) {
        qosmon_log(ctx, LOG_ERROR, "无法打开 /proc/net/dev\n");
        return -1;
    }
    
    // 跳过标题行
    for (int i = 0; i < 2; i++) {
        if (!fgets(line, sizeof(line), fp)) {
            fclose(fp);
            return -1;
        }
    }
    
    // 查找指定接口
    while (fgets(line, sizeof(line), fp)) {
        char* colon = strchr(line, ':');
        if (!colon) continue;
        
        *colon = '\0';
        char* ifname = line;
        while (*ifname == ' ') ifname++;
        
        if (strcmp(ifname, ctx->config.device) == 0) {
            if (sscanf(colon + 1, "%llu", &rx_bytes) == 1) {
                found = 1;
            }
            break;
        }
    }
    
    fclose(fp);
    
    if (!found) {
        qosmon_log(ctx, LOG_ERROR, "接口 %s 未找到\n", ctx->config.device);
        return -1;
    }
    
    int64_t now = qosmon_time_ms();
    
    if (last_read_time > 0 && last_rx_bytes > 0 && rx_bytes >= last_rx_bytes) {
        int time_diff = (int)(now - last_read_time);
        if (time_diff > 0) {
            unsigned long long bytes_diff = rx_bytes - last_rx_bytes;
            int bps = (int)((bytes_diff * 8000) / time_diff);
            
            // 应用指数移动平均滤波
            int delta = bps - ctx->filtered_total_load_bps;
            float alpha = 0.1f;  // 时间常数约7.5秒
            ctx->filtered_total_load_bps += (int)(delta * alpha);
            
            // 限制范围
            int max_bps = ctx->config.max_bandwidth_kbps * 1000;
            if (ctx->filtered_total_load_bps < 0) {
                ctx->filtered_total_load_bps = 0;
            } else if (ctx->filtered_total_load_bps > max_bps) {
                ctx->filtered_total_load_bps = max_bps;
            }
            
            qosmon_log(ctx, LOG_DEBUG, "流量统计: 原始=%d bps, 平滑=%d bps\n", 
                      bps, ctx->filtered_total_load_bps);
        }
    }
    
    last_rx_bytes = rx_bytes;
    last_read_time = now;
    
    return 0;
}

/* ==================== TC控制器 ==================== */
typedef struct {
    qosmon_context_t* ctx;
    int netlink_seq;
} tc_controller_t;

int tc_controller_init(tc_controller_t* tc, qosmon_context_t* ctx) {
    if (!tc || !ctx) return -1;
    
    tc->ctx = ctx;
    tc->netlink_seq = 1;
    
    // 创建netlink socket
    ctx->netlink_socket = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (ctx->netlink_socket < 0) {
        qosmon_log(ctx, LOG_ERROR, "创建netlink socket失败: %s\n", strerror(errno));
        return -1;
    }
    
    // 绑定socket
    struct sockaddr_nl addr = {0};
    addr.nl_family = AF_NETLINK;
    addr.nl_pid = getpid();
    
    if (bind(ctx->netlink_socket, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        qosmon_log(ctx, LOG_ERROR, "绑定netlink socket失败: %s\n", strerror(errno));
        close(ctx->netlink_socket);
        ctx->netlink_socket = -1;
        return -1;
    }
    
    return 0;
}

int tc_controller_set_bandwidth(tc_controller_t* tc, int bandwidth_bps) {
    if (!tc || !tc->ctx) return -1;
    
    qosmon_context_t* ctx = tc->ctx;
    
    if (ctx->config.safe_mode) {
        qosmon_log(ctx, LOG_INFO, "安全模式: 跳过带宽设置(%d kbps)\n", 
                  bandwidth_bps / 1000);
        return 0;
    }
    
    int bandwidth_kbps = (bandwidth_bps + 500) / 1000;
    
    // 检查变化是否足够大
    if (abs(bandwidth_kbps - ctx->last_tc_bw_kbps) < ctx->config.min_bw_change_kbps &&
        ctx->last_tc_bw_kbps != 0) {
        qosmon_log(ctx, LOG_DEBUG, "跳过TC更新: 变化太小(%d -> %d kbps)\n",
                  ctx->last_tc_bw_kbps, bandwidth_kbps);
        return 0;
    }
    
    qosmon_log(ctx, LOG_INFO, "设置带宽: %d kbps\n", bandwidth_kbps);
    
    // 获取接口索引
    int ifindex = if_nametoindex(ctx->config.device);
    if (ifindex == 0) {
        qosmon_log(ctx, LOG_ERROR, "获取接口索引失败: %s\n", strerror(errno));
        return -1;
    }
    
    // 构造netlink消息
    char buf[4096];
    struct nlmsghdr* nlh = (struct nlmsghdr*)buf;
    struct tcmsg* tcm = NLMSG_DATA(nlh);
    struct rtattr* opts;
    
    memset(buf, 0, sizeof(buf));
    
    // 填充消息头
    nlh->nlmsg_len = NLMSG_LENGTH(sizeof(struct tcmsg));
    nlh->nlmsg_type = RTM_NEWTCLASS;
    nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_REPLACE;
    nlh->nlmsg_seq = tc->netlink_seq++;
    nlh->nlmsg_pid = getpid();
    
    // 填充TC消息
    memset(tcm, 0, sizeof(struct tcmsg));
    tcm->tcm_family = AF_UNSPEC;
    tcm->tcm_ifindex = ifindex;
    tcm->tcm_handle = TC_H_MAKE(1, 1);
    tcm->tcm_parent = TC_H_MAKE(1, 0);
    
    // 添加TC种类属性
    struct rtattr* kind_attr = (struct rtattr*)((char*)nlh + NLMSG_ALIGN(nlh->nlmsg_len));
    kind_attr->rta_type = TCA_KIND;
    kind_attr->rta_len = RTA_LENGTH(4);
    strcpy(RTA_DATA(kind_attr), "htb");
    nlh->nlmsg_len = NLMSG_ALIGN(nlh->nlmsg_len) + RTA_ALIGN(kind_attr->rta_len);
    
    // 添加选项
    opts = (struct rtattr*)((char*)nlh + NLMSG_ALIGN(nlh->nlmsg_len));
    opts->rta_type = TCA_OPTIONS;
    opts->rta_len = RTA_LENGTH(0);
    nlh->nlmsg_len = NLMSG_ALIGN(nlh->nlmsg_len) + RTA_ALIGN(opts->rta_len);
    
    // 添加HTB参数
    struct tc_htb_opt htb_opt = {0};
    htb_opt.rate.rate = bandwidth_bps;
    htb_opt.ceil.rate = bandwidth_bps;
    htb_opt.buffer = 1600;
    htb_opt.cbuffer = 1600;
    htb_opt.quantum = 0x600;
    
    struct rtattr* htb_attr = (struct rtattr*)((char*)nlh + NLMSG_ALIGN(nlh->nlmsg_len));
    htb_attr->rta_type = TCA_HTB_PARMS;
    htb_attr->rta_len = RTA_LENGTH(sizeof(struct tc_htb_opt));
    memcpy(RTA_DATA(htb_attr), &htb_opt, sizeof(struct tc_htb_opt));
    nlh->nlmsg_len = NLMSG_ALIGN(nlh->nlmsg_len) + RTA_ALIGN(htb_attr->rta_len);
    
    // 完成选项
    opts->rta_len = (char*)NLMSG_TAIL(nlh) - (char*)opts;
    
    // 发送消息
    struct sockaddr_nl nladdr = {0};
    struct iovec iov = {buf, nlh->nlmsg_len};
    struct msghdr msg = {0};
    
    nladdr.nl_family = AF_NETLINK;
    msg.msg_name = &nladdr;
    msg.msg_namelen = sizeof(nladdr);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    
    int ret = sendmsg(ctx->netlink_socket, &msg, 0);
    if (ret < 0) {
        qosmon_log(ctx, LOG_ERROR, "发送netlink消息失败: %s\n", strerror(errno));
        return -1;
    }
    
    // 接收响应
    char reply[1024];
    iov.iov_base = reply;
    iov.iov_len = sizeof(reply);
    
    struct timeval tv = {1, 0};  // 1秒超时
    setsockopt(ctx->netlink_socket, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    
    ret = recvmsg(ctx->netlink_socket, &msg, 0);
    if (ret < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            qosmon_log(ctx, LOG_WARN, "接收netlink响应超时\n");
        } else {
            qosmon_log(ctx, LOG_ERROR, "接收netlink响应失败: %s\n", strerror(errno));
        }
        return -1;
    }
    
    // 解析响应
    struct nlmsghdr* reply_nlh = (struct nlmsghdr*)reply;
    if (reply_nlh->nlmsg_type == NLMSG_ERROR) {
        struct nlmsgerr* err = (struct nlmsgerr*)NLMSG_DATA(reply_nlh);
        if (err->error != 0) {
            qosmon_log(ctx, LOG_ERROR, "netlink错误: %s\n", strerror(-err->error));
            return -1;
        }
    }
    
    ctx->last_tc_bw_kbps = bandwidth_kbps;
    qosmon_log(ctx, LOG_INFO, "带宽设置成功: %d kbps\n", bandwidth_kbps);
    
    return 0;
}

void tc_controller_cleanup(tc_controller_t* tc) {
    if (tc && tc->ctx && tc->ctx->netlink_socket >= 0) {
        close(tc->ctx->netlink_socket);
        tc->ctx->netlink_socket = -1;
    }
}

/* ==================== 状态机 ==================== */
void state_machine_init(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    ctx->state = QMON_CHK;
    ctx->ident = getpid() & 0xFFFF;
    ctx->current_limit_bps = (int)(ctx->config.max_bandwidth_kbps * 1000 * 
                                  ctx->config.safe_start_ratio);
    ctx->saved_active_limit = ctx->current_limit_bps;
    ctx->saved_realtime_limit = ctx->current_limit_bps;
    
    // 初始化时间戳
    int64_t now = qosmon_time_ms();
    ctx->last_ping_time_ms = now;
    ctx->last_stats_time_ms = now;
    ctx->last_tc_update_time_ms = now;
    ctx->last_realtime_detect_time_ms = now;
    
    // 初始化ping历史
    memset(&ctx->ping_history, 0, sizeof(ping_history_t));
}

void state_machine_check(qosmon_context_t* ctx, ping_manager_t* pm) {
    if (!ctx || !pm) return;
    
    // 等待至少2个ping响应
    if (ctx->nreceived >= 2) {
        if (ctx->config.ping_limit_ms > 0 && !ctx->config.auto_switch_mode) {
            // 用户指定了ping限制但没有启用自动切换
            ctx->current_limit_bps = 0;  // 强制TC更新
            tc_controller_set_bandwidth(NULL, ctx->current_limit_bps);
            ctx->state = QMON_IDLE;
        } else {
            // 开始初始化测量
            tc_controller_set_bandwidth(NULL, 10000);  // 10kbps
            ctx->nreceived = 0;
            ctx->state = QMON_INIT;
        }
    }
}

void state_machine_init_state(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    static int init_count = 0;
    init_count++;
    
    // 测量15秒
    int needed_pings = 15000 / ctx->config.ping_interval;
    if (init_count > needed_pings) {
        // 完成测量
        ctx->state = QMON_IDLE;
        tc_controller_set_bandwidth(NULL, ctx->current_limit_bps);
        
        // 计算ping限制
        if (ctx->config.auto_switch_mode) {
            ctx->config.ping_limit_ms = (int)(ctx->filtered_ping_time_us * 1.1f / 1000);
        } else {
            ctx->config.ping_limit_ms = ctx->filtered_ping_time_us * 2 / 1000;
        }
        
        // 合理性检查
        if (ctx->config.ping_limit_ms < 10) ctx->config.ping_limit_ms = 10;
        if (ctx->config.ping_limit_ms > 800) ctx->config.ping_limit_ms = 800;
        
        ctx->max_ping_time_us = ctx->config.ping_limit_ms * 2 * 1000;
        init_count = 0;
        
        qosmon_log(ctx, LOG_INFO, "初始化完成: ping限制=%dms\n", 
                  ctx->config.ping_limit_ms);
    }
}

void state_machine_idle(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    // 检查是否应该激活
    float utilization = (float)ctx->filtered_total_load_bps / 
                        (ctx->config.max_bandwidth_kbps * 1000);
    
    if (utilization > ctx->config.active_threshold) {
        // 利用率超过阈值时激活
        if (ctx->realtime_classes == 0 && ctx->config.auto_switch_mode) {
            ctx->state = QMON_ACTIVE;
            ctx->current_limit_bps = ctx->saved_active_limit;
        } else {
            ctx->state = QMON_REALTIME;
            ctx->current_limit_bps = ctx->saved_realtime_limit;
        }
        
        qosmon_log(ctx, LOG_INFO, "切换到%s状态: 利用率=%.1f%%\n",
                  (ctx->state == QMON_ACTIVE) ? "ACTIVE" : "REALTIME",
                  utilization * 100.0f);
    }
}

void state_machine_active(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    // 保存当前限制
    if (ctx->state == QMON_REALTIME) {
        ctx->saved_realtime_limit = ctx->current_limit_bps;
    } else {
        ctx->saved_active_limit = ctx->current_limit_bps;
    }
    
    // 检查低利用率
    float utilization = (float)ctx->filtered_total_load_bps / 
                        (ctx->config.max_bandwidth_kbps * 1000);
    
    if (utilization < ctx->config.idle_threshold) {
        ctx->state = QMON_IDLE;
        qosmon_log(ctx, LOG_INFO, "切换到IDLE状态: 利用率=%.1f%%\n", 
                  utilization * 100.0f);
        return;
    }
    
    // 计算ping误差
    int current_plimit_us = ctx->config.ping_limit_ms * 1000;
    if (current_plimit_us <= 0) {
        current_plimit_us = 10000;  // 默认10ms
    }
    
    float error = ctx->filtered_ping_time_us - current_plimit_us;
    float error_ratio = error / (float)current_plimit_us;
    
    // 计算带宽调整因子
    float adjust_factor = 1.0f;
    if (error_ratio < 0) {
        // ping时间低于限制，可以增加带宽
        if (ctx->filtered_total_load_bps < ctx->current_limit_bps * 0.85f) {
            return;  // 当前利用率不足85%，不增加带宽
        }
        adjust_factor = 1.0f - 0.002f * error_ratio;  // 缓慢增加
    } else {
        // ping时间超过限制，减少带宽
        adjust_factor = 1.0f - 0.004f * (error_ratio + 0.1f);  // 快速减少
        if (adjust_factor < 0.85f) adjust_factor = 0.85f;  // 单次最多减少15%
    }
    
    // 应用调整
    int old_limit = ctx->current_limit_bps;
    int new_limit = (int)(ctx->current_limit_bps * adjust_factor);
    
    // 带宽限幅
    int min_bw = (int)(ctx->config.max_bandwidth_kbps * 1000 * ctx->config.min_bw_ratio);
    int max_bw = (int)(ctx->config.max_bandwidth_kbps * 1000 * ctx->config.max_bw_ratio);
    
    if (new_limit > max_bw) new_limit = max_bw;
    else if (new_limit < min_bw) new_limit = min_bw;
    
    // 避免频繁调整
    int change = abs(new_limit - old_limit);
    if (change > ctx->config.min_bw_change_kbps * 1000) {
        ctx->current_limit_bps = new_limit;
        qosmon_log(ctx, LOG_INFO, "带宽调整: %d -> %d kbps (误差比例=%.3f)\n",
                  old_limit / 1000, new_limit / 1000, error_ratio);
    }
    
    // 更新最大ping时间
    if (ctx->max_ping_time_us > current_plimit_us) {
        ctx->max_ping_time_us -= 100;  // 缓慢下降
    }
}

void state_machine_run(qosmon_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc) {
    if (!ctx || !pm || !tc) return;
    
    int64_t now = qosmon_time_ms();
    
    // 定期发送ping
    if (now - ctx->last_ping_time_ms >= ctx->config.ping_interval) {
        ping_manager_send(pm);
    }
    
    // 定期更新统计
    if (now - ctx->last_stats_time_ms >= STATS_INTERVAL_MS) {
        load_monitor_update(ctx);
        ctx->last_stats_time_ms = now;
    }
    
    // 运行状态机
    switch (ctx->state) {
        case QMON_CHK:
            state_machine_check(ctx, pm);
            break;
        case QMON_INIT:
            state_machine_init_state(ctx);
            break;
        case QMON_IDLE:
            state_machine_idle(ctx);
            break;
        case QMON_ACTIVE:
        case QMON_REALTIME:
            state_machine_active(ctx);
            break;
        default:
            break;
    }
    
    // 定期更新TC带宽
    if (now - ctx->last_tc_update_time_ms >= CONTROL_INTERVAL_MS) {
        static int last_bw = 0;
        int change = abs(ctx->current_limit_bps - last_bw);
        
        if (change > ctx->config.min_bw_change_kbps * 1000 || last_bw == 0) {
            tc_controller_set_bandwidth(tc, ctx->current_limit_bps);
            last_bw = ctx->current_limit_bps;
        }
        
        ctx->last_tc_update_time_ms = now;
    }
}

/* ==================== 状态文件 ==================== */
int status_file_init(qosmon_context_t* ctx) {
    if (!ctx) return -1;
    
    ctx->status_file = fopen(ctx->config.status_file, "w");
    if (!ctx->status_file) {
        qosmon_log(ctx, LOG_ERROR, "无法打开状态文件: %s\n", strerror(errno));
        return -1;
    }
    
    return 0;
}

void status_file_update(qosmon_context_t* ctx) {
    if (!ctx || !ctx->status_file) return;
    
    ftruncate(fileno(ctx->status_file), 0);
    rewind(ctx->status_file);
    
    const char* state_names[] = {"CHECK", "INIT", "ACTIVE", "REALTIME", "IDLE", "EXIT"};
    const char* state_name = (ctx->state < 6) ? state_names[ctx->state] : "UNKNOWN";
    
    fprintf(ctx->status_file, "状态: %s\n", state_name);
    fprintf(ctx->status_file, "目标: %s\n", ctx->config.target);
    fprintf(ctx->status_file, "设备: %s\n", ctx->config.device);
    fprintf(ctx->status_file, "安全模式: %s\n", ctx->config.safe_mode ? "ON" : "OFF");
    fprintf(ctx->status_file, "当前带宽: %d kbps\n", ctx->current_limit_bps / 1000);
    fprintf(ctx->status_file, "最大带宽: %d kbps\n", ctx->config.max_bandwidth_kbps);
    fprintf(ctx->status_file, "当前负载: %d kbps\n", ctx->filtered_total_load_bps / 1000);
    fprintf(ctx->status_file, "利用率: %.1f%%\n", 
            (float)ctx->filtered_total_load_bps / (ctx->config.max_bandwidth_kbps * 1000) * 100.0f);
    
    if (ctx->raw_ping_time_us > 0) {
        fprintf(ctx->status_file, "Ping: %d ms\n", ctx->raw_ping_time_us / 1000);
        fprintf(ctx->status_file, "平滑Ping: %d ms\n", ctx->filtered_ping_time_us / 1000);
    } else {
        fprintf(ctx->status_file, "Ping: 关闭\n");
    }
    
    fprintf(ctx->status_file, "Ping限制: %d ms\n", ctx->config.ping_limit_ms);
    fprintf(ctx->status_file, "实时类数量: %d\n", ctx->realtime_classes);
    fprintf(ctx->status_file, "最后更新: %s", ctime(&(time_t){time(NULL)}));
    
    fflush(ctx->status_file);
}

void status_file_cleanup(qosmon_context_t* ctx) {
    if (ctx && ctx->status_file) {
        fclose(ctx->status_file);
        ctx->status_file = NULL;
    }
}

/* ==================== 信号处理 ==================== */
static volatile sig_atomic_t g_signal_terminate = 0;
static volatile sig_atomic_t g_signal_reset = 0;

void signal_handler(int sig) {
    switch (sig) {
        case SIGTERM:
        case SIGINT:
            g_signal_terminate = 1;
            break;
        case SIGUSR1:
            g_signal_reset = 1;
            break;
    }
}

int signal_setup(void) {
    struct sigaction sa = {0};
    
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    
    if (sigaction(SIGTERM, &sa, NULL) < 0 ||
        sigaction(SIGINT, &sa, NULL) < 0 ||
        sigaction(SIGUSR1, &sa, NULL) < 0) {
        perror("设置信号处理器失败");
        return -1;
    }
    
    signal(SIGPIPE, SIG_IGN);
    
    return 0;
}

/* ==================== 主程序 ==================== */
void qosmon_cleanup(qosmon_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc) {
    qosmon_log(ctx, LOG_INFO, "清理资源...\n");
    
    // 恢复原始带宽
    if (ctx && !ctx->config.safe_mode) {
        qosmon_log(ctx, LOG_INFO, "恢复带宽到最大值\n");
        tc_controller_set_bandwidth(tc, ctx->config.max_bandwidth_kbps * 1000);
    }
    
    // 更新状态文件
    if (ctx) {
        ctx->state = QMON_EXIT;
        status_file_update(ctx);
    }
    
    // 清理资源
    ping_manager_cleanup(pm);
    tc_controller_cleanup(tc);
    status_file_cleanup(ctx);
    
    if (ctx && ctx->debug_log_file) {
        fclose(ctx->debug_log_file);
        ctx->debug_log_file = NULL;
    }
    
    if (ctx && ctx->config.background_mode) {
        syslog(LOG_INFO, "qosmon终止");
        closelog();
    }
}

int main(int argc, char* argv[]) {
    qosmon_config_t config;
    qosmon_context_t context = {0};
    ping_manager_t ping_mgr = {0};
    tc_controller_t tc_mgr = {0};
    
    int ret = EXIT_FAILURE;
    
    // 初始化配置
    qosmon_config_init(&config);
    
    // 解析命令行
    if (qosmon_config_parse(&config, argc, argv) != 0) {
        return EXIT_FAILURE;
    }
    
    // 验证配置
    char error_msg[256];
    if (qosmon_config_validate(&config, error_msg, sizeof(error_msg)) != 0) {
        fprintf(stderr, "配置错误: %s\n", error_msg);
        return EXIT_FAILURE;
    }
    
    // 初始化上下文
    context.config = config;
    context.ident = getpid() & 0xFFFF;
    
    // 设置信号处理器
    if (signal_setup() != 0) {
        return EXIT_FAILURE;
    }
    
    // 解析目标地址
    if (resolve_target(context.config.target, &context.target_addr, 
                      error_msg, sizeof(error_msg)) != 0) {
        fprintf(stderr, "%s\n", error_msg);
        return EXIT_FAILURE;
    }
    
    // 后台模式设置
    if (context.config.background_mode) {
        if (daemon(0, 0) < 0) {
            perror("daemon失败");
            return EXIT_FAILURE;
        }
        openlog("qosmon", LOG_PID, LOG_DAEMON);
    }
    
    // 初始化组件
    if (ping_manager_init(&ping_mgr, &context) != 0) {
        goto cleanup;
    }
    
    if (tc_controller_init(&tc_mgr, &context) != 0) {
        goto cleanup;
    }
    
    if (status_file_init(&context) != 0) {
        goto cleanup;
    }
    
    // 打开调试日志
    if (context.config.debug_log[0]) {
        context.debug_log_file = fopen(context.config.debug_log, "a");
        if (context.debug_log_file) {
            fseek(context.debug_log_file, 0, SEEK_END);
            context.debug_log_size = ftell(context.debug_log_file);
        }
    }
    
    // 初始化状态机
    state_machine_init(&context);
    
    // 主循环
    qosmon_log(&context, LOG_INFO, "qosmon启动: 目标=%s, 带宽=%dkbps, 间隔=%dms\n",
              context.config.target, context.config.max_bandwidth_kbps, 
              context.config.ping_interval);
    
    struct pollfd fds[2];
    fds[0].fd = context.ping_socket;
    fds[0].events = POLLIN;
    fds[1].fd = context.netlink_socket;
    fds[1].events = POLLIN;
    
    while (!g_signal_terminate) {
        // 处理重置信号
        if (g_signal_reset) {
            context.current_limit_bps = (int)(context.config.max_bandwidth_kbps * 1000 * 0.9f);
            tc_controller_set_bandwidth(&tc_mgr, context.current_limit_bps);
            g_signal_reset = 0;
            qosmon_log(&context, LOG_INFO, "收到重置信号，带宽重置为%d kbps\n",
                      context.current_limit_bps / 1000);
        }
        
        // 计算poll超时
        int timeout = context.config.ping_interval;
        if (context.ntransmitted > 0) {  // 有在发送ping
            int64_t time_since_ping = qosmon_time_ms() - context.last_ping_time_ms;
            if (time_since_ping < context.config.ping_interval) {
                timeout = context.config.ping_interval - time_since_ping;
            }
        }
        
        int poll_result = poll(fds, 2, timeout);
        if (poll_result < 0) {
            if (errno == EINTR) continue;
            qosmon_log(&context, LOG_ERROR, "poll失败: %s\n", strerror(errno));
            break;
        }
        
        if (poll_result > 0) {
            if (fds[0].revents & POLLIN) {
                ping_manager_receive(&ping_mgr);
            }
            if (fds[1].revents & POLLIN) {
                // 处理netlink消息
                char buf[1024];
                int len = recv(context.netlink_socket, buf, sizeof(buf), 0);
                if (len > 0) {
                    qosmon_log(&context, LOG_DEBUG, "收到netlink消息，长度=%d\n", len);
                }
            }
        }
        
        // 运行控制算法
        state_machine_run(&context, &ping_mgr, &tc_mgr);
        
        // 更新状态文件
        status_file_update(&context);
    }
    
    ret = EXIT_SUCCESS;
    
cleanup:
    qosmon_cleanup(&context, &ping_mgr, &tc_mgr);
    
    return ret;
}
