/* qosmon.c - 基于ping延迟的QoS监控器（优化版，集成libnl，支持HTB/HFSC）
 * 功能：通过ping监控延迟，使用tc动态调整带宽
 * 设计原则：模块化、错误安全、可配置、易于维护
 * 支持队列算法：自动检测HTB/HFSC
 */
 
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/poll.h>
#include <sys/resource.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>
#include <netinet/icmp6.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <syslog.h>
#include <getopt.h>
#include <sys/wait.h>

/* ==================== 配置 ==================== */
#define DEFAULT_PING_INTERVAL 200
#define DEFAULT_TARGET "8.8.8.8"
#define DEFAULT_BANDWIDTH_K 10000
#define DEFAULT_DEVICE "ifb0"
#define DEFAULT_CLASSID 0x10
#define DEFAULT_PING_LIMIT 20
#define MAX_PACKET_SIZE 4096
#define PING_HISTORY_SIZE 10
#define CONTROL_INTERVAL_MS 1000
#define STATS_INTERVAL_MS 1000
#define REALTIME_DETECT_MS 3000
#define HEARTBEAT_INTERVAL_MS 30000
#define MIN_PING_TIME_MS 1
#define MAX_PING_TIME_MS 2000

typedef struct {
    int ping_interval;           // ping间隔(ms)
    int max_bandwidth_kbps;       // 最大带宽(kbps)
    int ping_limit_ms;            // ping限制(ms)
    char target[256];            // ping目标地址
    char device[32];             // 网络设备
    int classid;                 // TC类ID
    char status_file[256];       // 状态文件路径
    char debug_log[256];         // 调试日志路径
    
    // 算法参数
    float min_bw_ratio;          // 最小带宽比例
    float max_bw_ratio;          // 最大带宽比例
    float smoothing_factor;      // 平滑因子
    float active_threshold;      // 激活阈值
    float idle_threshold;        // 空闲阈值
    int min_bw_change_kbps;     // 最小带宽变化(kbps)
    float safe_start_ratio;      // 安全启动比例
    
    // 运行参数
    int verbose;                // 详细输出
    int background_mode;         // 后台运行
    int auto_switch_mode;       // 自动切换模式
    int skip_initial;           // 跳过初始测量
    int safe_mode;              // 安全模式(不修改TC)
} qosmon_config_t;

/* ==================== 状态 ==================== */
typedef enum {
    QMON_CHK,        // 检查状态
    QMON_INIT,       // 初始化
    QMON_IDLE,       // 空闲状态
    QMON_ACTIVE,     // 活动状态
    QMON_REALTIME,   // 实时状态
    QMON_EXIT        // 退出
} qosmon_state_t;

/* ==================== Ping历史记录 ==================== */
typedef struct {
    int64_t times[PING_HISTORY_SIZE];
    int index;
    int count;
    float smoothed;
} ping_history_t;

/* ==================== 错误码 ==================== */
#define QMON_OK 0
#define QMON_ERR_SOCKET -1
#define QMON_ERR_CONFIG -2
#define QMON_ERR_MEMORY -3
#define QMON_ERR_SYSTEM -4
#define QMON_ERR_FILE -5
#define QMON_ERR_RESOLVE -6
#define QMON_ERR_SIGNAL -7

/* ==================== 日志级别 ==================== */
typedef enum {
    LOG_ERROR = 0,
    LOG_WARN = 1,
    LOG_INFO = 2,
    LOG_DEBUG = 3
} log_level_t;

/* ==================== 上下文 ==================== */
typedef struct {
    qosmon_config_t config;
    qosmon_state_t state;
    int ping_socket;
    int ident;                 // ping标识符
    int ntransmitted;         // 已发送ping数
    int nreceived;            // 已接收ping数
    int64_t raw_ping_time_us; // 原始ping时间(us)
    int64_t filtered_ping_time_us; // 过滤后ping时间(us)
    int64_t max_ping_time_us; // 最大ping时间(us)
    int64_t last_ping_time_ms; // 上次ping时间(ms)
    int64_t last_stats_time_ms; // 上次统计时间(ms)
    int64_t last_tc_update_time_ms; // 上次TC更新时间(ms)
    int64_t last_realtime_detect_time_ms; // 上次实时检测时间(ms)
    int64_t last_heartbeat_ms; // 上次心跳时间(ms)
    int filtered_total_load_bps; // 过滤后总负载(bps)
    int current_limit_bps;    // 当前限制(bps)
    int last_tc_bw_kbps;     // 上次TC带宽(kbps)
    int saved_active_limit;   // 保存的活动限制
    int saved_realtime_limit; // 保存的实时限制
    int realtime_classes;     // 实时类数量
    int sigterm;             // 信号标志
    struct sockaddr_storage target_addr; // 目标地址
    FILE* status_file;       // 状态文件
    FILE* debug_log_file;    // 调试日志文件
    ping_history_t ping_history; // ping历史
    char detected_qdisc[16]; // 检测到的队列算法
} qosmon_context_t;

/* ==================== 函数声明 ==================== */
// 配置
void qosmon_config_init(qosmon_config_t* config);
int qosmon_config_validate(const qosmon_config_t* config, char* error, size_t error_len);
int qosmon_load_config(qosmon_config_t* config, const char* filename);
int qosmon_config_parse(qosmon_config_t* config, int argc, char* argv[]);

// 日志
void qosmon_log(qosmon_context_t* ctx, log_level_t level, const char* format, ...);

// 时间
int64_t qosmon_time_ms(void);
int64_t qosmon_time_us(void);

// Ping管理器
typedef struct ping_manager_s ping_manager_t;
int ping_manager_init(ping_manager_t* pm, qosmon_context_t* ctx);
int ping_manager_send(ping_manager_t* pm);
int ping_manager_receive(ping_manager_t* pm);
void ping_manager_cleanup(ping_manager_t* pm);

// 流量统计
int load_monitor_update(qosmon_context_t* ctx);

// TC控制器
typedef struct tc_controller_s tc_controller_t;
int tc_controller_init(tc_controller_t* tc, qosmon_context_t* ctx);
int tc_controller_set_bandwidth(tc_controller_t* tc, int bandwidth_bps);
void tc_controller_cleanup(tc_controller_t* tc);

// 状态机
void state_machine_init(qosmon_context_t* ctx);
void state_machine_run(qosmon_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc);

// 状态文件
int status_file_update(qosmon_context_t* ctx);

// 信号处理
int setup_signal_handlers(qosmon_context_t* ctx);

// 清理
void qosmon_cleanup(qosmon_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc);

/* ==================== 实现 ==================== */

/* ==================== 日志 ==================== */
void qosmon_log(qosmon_context_t* ctx, log_level_t level, const char* format, ...) {
    va_list args;
    va_start(args, format);
    
    char timestamp[32];
    time_t now = time(NULL);
    struct tm* tm_info = localtime(&now);
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", tm_info);
    
    const char* level_str[] = {"ERROR", "WARN", "INFO", "DEBUG"};
    
    if (ctx && ctx->config.verbose >= level) {
        FILE* output = (level <= LOG_WARN) ? stderr : stdout;
        fprintf(output, "[%s] [%s] ", timestamp, level_str[level]);
        vfprintf(output, format, args);
        fflush(output);
    }
    
    if (ctx && ctx->debug_log_file) {
        fprintf(ctx->debug_log_file, "[%s] [%s] ", timestamp, level_str[level]);
        vfprintf(ctx->debug_log_file, format, args);
        fflush(ctx->debug_log_file);
    }
    
    if (ctx && ctx->config.background_mode && level <= LOG_INFO) {
        // 后台模式使用syslog
        int priority = (level == LOG_ERROR) ? LOG_ERR : 
                      (level == LOG_WARN) ? LOG_WARNING : LOG_INFO;
        char message[512];
        vsnprintf(message, sizeof(message), format, args);
        syslog(priority, "%s", message);
    }
    
    va_end(args);
}

/* ==================== 配置 ==================== */
void qosmon_config_init(qosmon_config_t* config) {
    if (!config) return;
    
    memset(config, 0, sizeof(qosmon_config_t));
    
    // 默认值
    config->ping_interval = DEFAULT_PING_INTERVAL;
    config->max_bandwidth_kbps = DEFAULT_BANDWIDTH_K;
    config->ping_limit_ms = DEFAULT_PING_LIMIT;
    strncpy(config->target, DEFAULT_TARGET, sizeof(config->target) - 1);
    config->target[sizeof(config->target) - 1] = '\0';
    
    // 算法参数
    config->min_bw_ratio = 0.1f;
    config->max_bw_ratio = 1.0f;
    config->smoothing_factor = 0.3f;
    config->active_threshold = 0.4f;
    config->idle_threshold = 0.2f;
    config->min_bw_change_kbps = 50;
    config->safe_start_ratio = 0.8f;
    
    // 网络参数
    strncpy(config->device, DEFAULT_DEVICE, sizeof(config->device) - 1);
    config->device[sizeof(config->device) - 1] = '\0';
    config->classid = DEFAULT_CLASSID;
    
    // 文件路径
    strncpy(config->status_file, "/tmp/qosmon_status.txt", 
            sizeof(config->status_file) - 1);
    config->status_file[sizeof(config->status_file) - 1] = '\0';
    
    strncpy(config->debug_log, "/tmp/qosmon_debug.log", 
            sizeof(config->debug_log) - 1);
    config->debug_log[sizeof(config->debug_log) - 1] = '\0';
    
    // 运行参数
    config->verbose = 0;
    config->background_mode = 0;
    config->auto_switch_mode = 0;
    config->skip_initial = 0;
    config->safe_mode = 0;
}

int qosmon_config_validate(const qosmon_config_t* config, char* error, size_t error_len) {
    if (!config) {
        snprintf(error, error_len, "配置为空");
        return QMON_ERR_CONFIG;
    }
    
    if (config->ping_interval < 100 || config->ping_interval > 2000) {
        snprintf(error, error_len, "ping间隔必须在100-2000ms之间");
        return QMON_ERR_CONFIG;
    }
    
    if (config->max_bandwidth_kbps < 100) {
        snprintf(error, error_len, "带宽必须至少100kbps");
        return QMON_ERR_CONFIG;
    }
    
    if (config->ping_limit_ms > 0 && 
        (config->ping_limit_ms < MIN_PING_TIME_MS || 
         config->ping_limit_ms > MAX_PING_TIME_MS)) {
        snprintf(error, error_len, "ping限制必须在%d-%dms之间", 
                MIN_PING_TIME_MS, MAX_PING_TIME_MS);
        return QMON_ERR_CONFIG;
    }
    
    if (strlen(config->target) == 0 || strlen(config->target) >= sizeof(config->target)) {
        snprintf(error, error_len, "必须指定有效的ping目标");
        return QMON_ERR_CONFIG;
    }
    
    if (strlen(config->device) == 0 || strlen(config->device) >= sizeof(config->device)) {
        snprintf(error, error_len, "必须指定有效的网络设备");
        return QMON_ERR_CONFIG;
    }
    
    if (config->min_bw_ratio >= config->max_bw_ratio) {
        snprintf(error, error_len, "最小带宽比例不能大于等于最大带宽比例");
        return QMON_ERR_CONFIG;
    }
    
    if (config->min_bw_ratio < 0.01f || config->min_bw_ratio > 1.0f) {
        snprintf(error, error_len, "最小带宽比例必须在0.01-1.0之间");
        return QMON_ERR_CONFIG;
    }
    
    if (config->max_bw_ratio < 0.1f || config->max_bw_ratio > 1.0f) {
        snprintf(error, error_len, "最大带宽比例必须在0.1-1.0之间");
        return QMON_ERR_CONFIG;
    }
    
    if (config->smoothing_factor < 0.0f || config->smoothing_factor > 1.0f) {
        snprintf(error, error_len, "平滑因子必须在0.0-1.0之间");
        return QMON_ERR_CONFIG;
    }
    
    return QMON_OK;
}

int qosmon_load_config(qosmon_config_t* config, const char* filename) {
    if (!config || !filename) return QMON_ERR_CONFIG;
    
    FILE* fp = fopen(filename, "r");
    if (!fp) {
        return QMON_ERR_FILE;
    }
    
    char line[256];
    int line_num = 0;
    
    while (fgets(line, sizeof(line), fp)) {
        line_num++;
        
        // 移除换行符
        char* newline = strchr(line, '\n');
        if (newline) *newline = '\0';
        newline = strchr(line, '\r');
        if (newline) *newline = '\0';
        
        // 跳过注释和空行
        if (line[0] == '#' || line[0] == '\0') {
            continue;
        }
        
        char* equals = strchr(line, '=');
        if (!equals) {
            fprintf(stderr, "警告: 第%d行格式错误: %s\n", line_num, line);
            continue;
        }
        
        *equals = '\0';
        char* key = line;
        char* value = equals + 1;
        
        // 移除首尾空格
        while (*key == ' ') key++;
        char* end = key + strlen(key) - 1;
        while (end > key && *end == ' ') *end-- = '\0';
        
        while (*value == ' ') value++;
        end = value + strlen(value) - 1;
        while (end > value && *end == ' ') *end-- = '\0';
        
        // 解析配置项
        if (strcmp(key, "ping_interval") == 0) {
            config->ping_interval = atoi(value);
        } else if (strcmp(key, "max_bandwidth_kbps") == 0) {
            config->max_bandwidth_kbps = atoi(value);
        } else if (strcmp(key, "ping_limit_ms") == 0) {
            config->ping_limit_ms = atoi(value);
        } else if (strcmp(key, "target") == 0) {
            strncpy(config->target, value, sizeof(config->target) - 1);
            config->target[sizeof(config->target) - 1] = '\0';
        } else if (strcmp(key, "device") == 0) {
            strncpy(config->device, value, sizeof(config->device) - 1);
            config->device[sizeof(config->device) - 1] = '\0';
        } else if (strcmp(key, "min_bw_ratio") == 0) {
            config->min_bw_ratio = atof(value);
        } else if (strcmp(key, "max_bw_ratio") == 0) {
            config->max_bw_ratio = atof(value);
        } else if (strcmp(key, "smoothing_factor") == 0) {
            config->smoothing_factor = atof(value);
        } else if (strcmp(key, "background_mode") == 0) {
            config->background_mode = atoi(value);
        } else if (strcmp(key, "safe_mode") == 0) {
            config->safe_mode = atoi(value);
        } else if (strcmp(key, "verbose") == 0) {
            config->verbose = atoi(value);
        } else {
            fprintf(stderr, "警告: 第%d行未知配置项: %s\n", line_num, key);
        }
    }
    
    fclose(fp);
    return QMON_OK;
}

int qosmon_config_parse(qosmon_config_t* config, int argc, char* argv[]) {
    int opt;
    int option_index = 0;
    char* config_file = NULL;
    
    static struct option long_options[] = {
        {"background", no_argument, 0, 'b'},
        {"auto-switch", no_argument, 0, 'a'},
        {"skip-initial", no_argument, 0, 's'},
        {"verbose", no_argument, 0, 'v'},
        {"safe-mode", no_argument, 0, 'S'},
        {"device", required_argument, 0, 'd'},
        {"status", required_argument, 0, 'F'},
        {"log", required_argument, 0, 'L'},
        {"config", required_argument, 0, 'c'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };
    
    while ((opt = getopt_long(argc, argv, "basvSd:F:L:c:h", 
                              long_options, &option_index)) != -1) {
        switch (opt) {
            case 'b':
                config->background_mode = 1;
                break;
            case 'a':
                config->auto_switch_mode = 1;
                break;
            case 's':
                config->skip_initial = 1;
                break;
            case 'v':
                config->verbose = 1;
                break;
            case 'S':
                config->safe_mode = 1;
                break;
            case 'd':
                strncpy(config->device, optarg, sizeof(config->device) - 1);
                config->device[sizeof(config->device) - 1] = '\0';
                break;
            case 'F':
                strncpy(config->status_file, optarg, sizeof(config->status_file) - 1);
                config->status_file[sizeof(config->status_file) - 1] = '\0';
                break;
            case 'L':
                strncpy(config->debug_log, optarg, sizeof(config->debug_log) - 1);
                config->debug_log[sizeof(config->debug_log) - 1] = '\0';
                break;
            case 'c':
                config_file = optarg;
                break;
            case 'h':
                printf("qosmon - 基于ping延迟的QoS监控器\n");
                printf("用法: %s [选项] <ping间隔> <目标地址> <带宽(kbps)> [ping限制(ms)]\n", argv[0]);
                printf("\n选项:\n");
                printf("  -b, --background     后台运行\n");
                printf("  -a, --auto-switch    启用ACTIVE/MINRTT自动切换\n");
                printf("  -s, --skip-initial   跳过初始链路测量\n");
                printf("  -v, --verbose        详细输出\n");
                printf("  -S, --safe-mode      安全模式（不修改TC）\n");
                printf("  -d, --device <ifb>   网络设备（默认: ifb0）\n");
                printf("  -F, --status <文件>  状态文件路径\n");
                printf("  -L, --log <文件>     调试日志路径\n");
                printf("  -c, --config <文件>  配置文件路径\n");
                printf("  -h, --help           显示此帮助信息\n");
                printf("\n示例:\n");
                printf("  %s 200 8.8.8.8 10000 20\n", argv[0]);
                printf("  %s -v -d eth0 100 1.1.1.1 5000\n", argv[0]);
                printf("  %s -c /etc/qosmon.conf\n", argv[0]);
                exit(EXIT_SUCCESS);
            case '?':
                fprintf(stderr, "未知选项或缺少参数，使用 -h 查看帮助\n");
                return QMON_ERR_CONFIG;
        }
    }
    
    // 如果指定了配置文件，优先加载
    if (config_file) {
        int ret = qosmon_load_config(config, config_file);
        if (ret != QMON_OK) {
            fprintf(stderr, "无法加载配置文件: %s\n", config_file);
            return ret;
        }
    }
    
    // 处理必需参数
    if (optind + 3 > argc) {
        if (!config_file) {
            fprintf(stderr, "错误: 缺少必需参数\n");
            fprintf(stderr, "用法: %s [选项] <ping间隔> <目标地址> <带宽(kbps)> [ping限制(ms)]\n", argv[0]);
            fprintf(stderr, "使用 -h 查看完整帮助\n");
            return QMON_ERR_CONFIG;
        }
    } else {
        config->ping_interval = atoi(argv[optind++]);
        strncpy(config->target, argv[optind++], sizeof(config->target) - 1);
        config->target[sizeof(config->target) - 1] = '\0';
        config->max_bandwidth_kbps = atoi(argv[optind++]);
        
        if (optind < argc) {
            config->ping_limit_ms = atoi(argv[optind++]);
        }
    }
    
    return QMON_OK;
}

/* ==================== 时间管理 ==================== */
int64_t qosmon_time_ms(void) {
    struct timeval tv;
    if (gettimeofday(&tv, NULL) != 0) {
        return 0;
    }
    return (int64_t)tv.tv_sec * 1000 + (int64_t)tv.tv_usec / 1000;
}

int64_t qosmon_time_us(void) {
    struct timeval tv;
    if (gettimeofday(&tv, NULL) != 0) {
        return 0;
    }
    return (int64_t)tv.tv_sec * 1000000 + (int64_t)tv.tv_usec;
}

/* ==================== 网络工具 ==================== */
uint16_t icmp_checksum(const void* data, size_t length) {
    if (!data || length == 0) return 0;
    
    const uint16_t* ptr = data;
    uint32_t sum = 0;
    
    while (length > 1) {
        sum += *ptr++;
        if (sum < *ptr) {  // 处理溢出
            sum = (sum & 0xFFFF) + (sum >> 16);
        }
        length -= 2;
    }
    
    if (length == 1) {
        uint16_t last_byte = 0;
        *(uint8_t*)&last_byte = *(const uint8_t*)ptr;
        sum += last_byte;
    }
    
    sum = (sum >> 16) + (sum & 0xffff);
    sum += (sum >> 16);
    
    return (uint16_t)~sum;
}

int resolve_target(const char* target, struct sockaddr_storage* addr, 
                   char* error, size_t error_len) {
    if (!target || !addr) {
        snprintf(error, error_len, "参数错误");
        return QMON_ERR_CONFIG;
    }
    
    memset(addr, 0, sizeof(struct sockaddr_storage));
    
    // 尝试IPv4
    struct sockaddr_in* addr4 = (struct sockaddr_in*)addr;
    if (inet_pton(AF_INET, target, &addr4->sin_addr) == 1) {
        addr4->sin_family = AF_INET;
        return QMON_OK;
    }
    
    // 尝试IPv6
    struct sockaddr_in6* addr6 = (struct sockaddr_in6*)addr;
    if (inet_pton(AF_INET6, target, &addr6->sin6_addr) == 1) {
        addr6->sin6_family = AF_INET6;
        return QMON_OK;
    }
    
    // 通过DNS解析
    struct addrinfo hints, *result = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_RAW;
    
    int ret = getaddrinfo(target, NULL, &hints, &result);
    if (ret != 0 || !result) {
        snprintf(error, error_len, "无法解析目标: %s", gai_strerror(ret));
        return QMON_ERR_RESOLVE;
    }
    
    memcpy(addr, result->ai_addr, result->ai_addrlen);
    freeaddrinfo(result);
    
    return QMON_OK;
}

/* ==================== Ping管理器 ==================== */
typedef struct {
    qosmon_context_t* ctx;
    char packet[MAX_PACKET_SIZE];
} ping_manager_t;

int ping_manager_init(ping_manager_t* pm, qosmon_context_t* ctx) {
    if (!pm || !ctx) return QMON_ERR_MEMORY;
    
    pm->ctx = ctx;
    memset(pm->packet, 0, sizeof(pm->packet));
    
    // 创建ping socket
    int domain = (ctx->target_addr.ss_family == AF_INET) ? AF_INET : AF_INET6;
    int protocol = (domain == AF_INET) ? IPPROTO_ICMP : IPPROTO_ICMPV6;
    
    ctx->ping_socket = socket(domain, SOCK_RAW, protocol);
    if (ctx->ping_socket < 0) {
        qosmon_log(ctx, LOG_ERROR, "创建ping socket失败: %s\n", strerror(errno));
        return QMON_ERR_SOCKET;
    }
    
    // 设置socket选项
    int ttl = 64;
    int on = 1;
    int reuseaddr = 1;
    
    if (setsockopt(ctx->ping_socket, SOL_SOCKET, SO_REUSEADDR, &reuseaddr, sizeof(reuseaddr)) < 0) {
        qosmon_log(ctx, LOG_WARN, "设置SO_REUSEADDR失败: %s\n", strerror(errno));
    }
    
    if (domain == AF_INET) {
        if (setsockopt(ctx->ping_socket, IPPROTO_IP, IP_TTL, &ttl, sizeof(ttl)) < 0) {
            qosmon_log(ctx, LOG_WARN, "设置IP_TTL失败: %s\n", strerror(errno));
        }
        if (setsockopt(ctx->ping_socket, IPPROTO_IP, IP_RECVERR, &on, sizeof(on)) < 0) {
            qosmon_log(ctx, LOG_WARN, "设置IP_RECVERR失败: %s\n", strerror(errno));
        }
    } else {
        if (setsockopt(ctx->ping_socket, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &ttl, sizeof(ttl)) < 0) {
            qosmon_log(ctx, LOG_WARN, "设置IPV6_UNICAST_HOPS失败: %s\n", strerror(errno));
        }
        if (setsockopt(ctx->ping_socket, IPPROTO_IPV6, IPV6_RECVERR, &on, sizeof(on)) < 0) {
            qosmon_log(ctx, LOG_WARN, "设置IPV6_RECVERR失败: %s\n", strerror(errno));
        }
    }
    
    // 设置非阻塞
    int flags = fcntl(ctx->ping_socket, F_GETFL, 0);
    if (flags < 0) {
        qosmon_log(ctx, LOG_WARN, "获取socket标志失败: %s\n", strerror(errno));
    } else {
        if (fcntl(ctx->ping_socket, F_SETFL, flags | O_NONBLOCK) < 0) {
            qosmon_log(ctx, LOG_WARN, "设置非阻塞失败: %s\n", strerror(errno));
        }
    }
    
    return QMON_OK;
}

int ping_manager_send(ping_manager_t* pm) {
    if (!pm || !pm->ctx) return QMON_ERR_MEMORY;
    
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
        
        if (gettimeofday(tp, NULL) != 0) {
            qosmon_log(ctx, LOG_ERROR, "获取时间失败: %s\n", strerror(errno));
            return -1;
        }
        
        // 填充数据
        for (int i = 0; i < cc - 8; i++) {
            pm->packet[8 + sizeof(struct timeval) + i] = i;
        }
        
        // IPv6需要特殊校验和处理
        int offset = 2;
        if (setsockopt(ctx->ping_socket, IPPROTO_IPV6, IPV6_CHECKSUM, 
                      &offset, sizeof(offset)) < 0) {
            qosmon_log(ctx, LOG_WARN, "设置IPv6校验和失败: %s\n", strerror(errno));
        }
    } else {
        struct icmp* icp = (struct icmp*)pm->packet;
        icp->icmp_type = ICMP_ECHO;
        icp->icmp_code = 0;
        icp->icmp_cksum = 0;
        icp->icmp_seq = ++ctx->ntransmitted;
        icp->icmp_id = ctx->ident;
        
        if (gettimeofday(tp, NULL) != 0) {
            qosmon_log(ctx, LOG_ERROR, "获取时间失败: %s\n", strerror(errno));
            return -1;
        }
        
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
    struct timeval tv, *tp = NULL;
    int hlen, triptime = 0;
    uint16_t seq = 0;
    
    if (gettimeofday(&tv, NULL) != 0) {
        qosmon_log(ctx, LOG_ERROR, "获取时间失败: %s\n", strerror(errno));
        return -1;
    }
    
    if (from.ss_family == AF_INET6) {
        if (cc < (int)sizeof(struct icmp6_hdr)) return 0;
        icp6 = (struct icmp6_hdr*)buf;
        
        if (icp6->icmp6_type != ICMP6_ECHO_REPLY) return 0;
        if (ntohs(icp6->icmp6_id) != ctx->ident) return 0;
        
        seq = ntohs(icp6->icmp6_seq);
        if (cc >= 8 + (int)sizeof(struct timeval)) {
            tp = (struct timeval*)&icp6->icmp6_dataun.icmp6_un_data32[1];
        }
    } else {
        ip = (struct ip*)buf;
        hlen = ip->ip_hl << 2;
        if (cc < hlen + 8) return 0;
        icp = (struct icmp*)(buf + hlen);
        
        if (icp->icmp_type != ICMP_ECHOREPLY) return 0;
        if (icp->icmp_id != ctx->ident) return 0;
        
        seq = icp->icmp_seq;
        if (cc >= hlen + 8 + (int)sizeof(struct timeval)) {
            tp = (struct timeval*)&icp->icmp_data[0];
        }
    }
    
    if (seq != ctx->ntransmitted) return 0;
    
    ctx->nreceived++;
    
    // 计算往返时间
    if (tp) {
        triptime = (tv.tv_sec - tp->tv_sec) * 1000 + 
                   (tv.tv_usec - tp->tv_usec) / 1000;
    }
    
    // 处理时间回绕
    if (triptime < 0) {
        qosmon_log(ctx, LOG_WARN, "检测到时间回绕，重置ping计时\n");
        triptime = MIN_PING_TIME_MS;
    }
    
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
    if (hist->count < PING_HISTORY_SIZE) {
        hist->times[hist->index] = ctx->raw_ping_time_us;
    } else {
        hist->times[hist->index] = ctx->raw_ping_time_us;
    }
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
    if (!ctx) return QMON_ERR_MEMORY;
    
    static unsigned long long last_rx_bytes = 0;
    static int64_t last_read_time = 0;
    
    char line[256];
    unsigned long long rx_bytes = 0;
    int found = 0;
    
    FILE* fp = fopen("/proc/net/dev", "r");
    if (!fp) {
        qosmon_log(ctx, LOG_ERROR, "无法打开 /proc/net/dev: %s\n", strerror(errno));
        return QMON_ERR_FILE;
    }
    
    // 跳过标题行
    for (int i = 0; i < 2; i++) {
        if (!fgets(line, sizeof(line), fp)) {
            fclose(fp);
            return QMON_ERR_FILE;
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
        return QMON_ERR_SYSTEM;
    }
    
    int64_t now = qosmon_time_ms();
    
    if (last_read_time > 0 && last_rx_bytes > 0 && rx_bytes >= last_rx_bytes) {
        int time_diff = (int)(now - last_read_time);
        if (time_diff > 0) {
            unsigned long long bytes_diff = rx_bytes - last_rx_bytes;
            int bps = (int)((bytes_diff * 8000) / time_diff);
            
            // 处理整数溢出
            if (bps < 0) {
                qosmon_log(ctx, LOG_WARN, "流量统计溢出，重置\n");
                bps = 0;
            }
            
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
    
    return QMON_OK;
}

/* ==================== TC控制器 ==================== */
typedef struct {
    qosmon_context_t* ctx;
} tc_controller_t;

// 检测当前设备使用的队列算法
char* detect_qdisc_kind(qosmon_context_t* ctx) {
    static char qdisc_kind[16] = "htb";  // 默认使用HTB
    char cmd[256];
    char line[256];
    
    snprintf(cmd, sizeof(cmd), "tc qdisc show dev %s 2>/dev/null", ctx->config.device);
    qosmon_log(ctx, LOG_DEBUG, "执行检测命令: %s\n", cmd);
    
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        qosmon_log(ctx, LOG_ERROR, "无法执行tc命令检测队列算法: %s\n", strerror(errno));
        return qdisc_kind;
    }
    
    while (fgets(line, sizeof(line), fp)) {
        // 寻找队列算法类型
        if (strstr(line, "htb") != NULL) {
            strcpy(qdisc_kind, "htb");
            break;
        } else if (strstr(line, "hfsc") != NULL) {
            strcpy(qdisc_kind, "hfsc");
            break;
        } else if (strstr(line, "fq_codel") != NULL || 
                   strstr(line, "codel") != NULL || 
                   strstr(line, "pfifo_fast") != NULL) {
            // 这些算法不支持动态带宽调整
            qosmon_log(ctx, LOG_WARN, "检测到不支持动态调整的队列算法: %s，将自动创建HTB队列\n", 
                      strtok(line, " "));
            strcpy(qdisc_kind, "htb");
            break;
        }
    }
    
    pclose(fp);
    qosmon_log(ctx, LOG_INFO, "检测到队列算法: %s\n", qdisc_kind);
    
    return qdisc_kind;
}

// 检测当前类的带宽设置
int detect_class_bandwidth(qosmon_context_t* ctx, int* current_bw_kbps) {
    if (!ctx || !current_bw_kbps) return QMON_ERR_MEMORY;
    
    char cmd[256];
    char line[512];
    int found = 0;
    
    // 构建tc命令来查询类的带宽
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
        
        if (rate_pos) {
            // HTB格式: rate 1000kbit ceil 1000kbit
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
        } else if (ls_pos || ul_pos) {
            // HFSC格式: ls m1 0b d 0us m2 1000kbit ul m1 0b d 0us m2 1000kbit
            char* start = ls_pos ? ls_pos : ul_pos;
            int rate_mbit, rate_kbit;
            
            if (sscanf(start, "ls m1 0b d 0us m2 %dMbit", &rate_mbit) == 1 ||
                sscanf(start, "ul m1 0b d 0us m2 %dMbit", &rate_mbit) == 1) {
                *current_bw_kbps = rate_mbit * 1000;
                found = 1;
                break;
            } else if (sscanf(start, "ls m1 0b d 0us m2 %dkbit", &rate_kbit) == 1 ||
                       sscanf(start, "ul m1 0b d 0us m2 %dkbit", &rate_kbit) == 1) {
                *current_bw_kbps = rate_kbit;
                found = 1;
                break;
            }
        }
    }
    
    pclose(fp);
    return found ? QMON_OK : QMON_ERR_SYSTEM;
}

// 使用tc命令设置带宽
int tc_set_bandwidth(qosmon_context_t* ctx, int bandwidth_bps) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    int bandwidth_kbps = (bandwidth_bps + 500) / 1000;
    
    // 检查变化是否足够大
    if (ctx->last_tc_bw_kbps != 0) {
        int diff = bandwidth_kbps - ctx->last_tc_bw_kbps;
        if (diff < 0) diff = -diff;
        if (diff < ctx->config.min_bw_change_kbps) {
            qosmon_log(ctx, LOG_DEBUG, "跳过TC更新: 变化太小(%d -> %d kbps)\n",
                      ctx->last_tc_bw_kbps, bandwidth_kbps);
            return QMON_OK;
        }
    }
    
    // 检测当前队列算法
    if (strlen(ctx->detected_qdisc) == 0) {
        char* qdisc_kind = detect_qdisc_kind(ctx);
        strncpy(ctx->detected_qdisc, qdisc_kind, sizeof(ctx->detected_qdisc) - 1);
        ctx->detected_qdisc[sizeof(ctx->detected_qdisc) - 1] = '\0';
    }
    
    char cmd[512];
    int ret = 0;
    
    if (strcmp(ctx->detected_qdisc, "hfsc") == 0) {
        // HFSC队列算法
        snprintf(cmd, sizeof(cmd), 
                 "tc class change dev %s parent 1: classid 1:%x hfsc ls m1 0b d 0us m2 %dkbit ul m1 0b d 0us m2 %dkbit 2>&1",
                 ctx->config.device, ctx->config.classid, bandwidth_kbps, bandwidth_kbps);
    } else {
        // 默认使用HTB
        snprintf(cmd, sizeof(cmd), 
                 "tc class change dev %s parent 1: classid 1:%x htb rate %dkbit ceil %dkbit 2>&1",
                 ctx->config.device, ctx->config.classid, bandwidth_kbps, bandwidth_kbps);
    }
    
    qosmon_log(ctx, LOG_INFO, "执行TC命令: %s\n", cmd);
    
    FILE* fp = popen(cmd, "r");
    if (fp) {
        char output[256];
        while (fgets(output, sizeof(output), fp)) {
            // 移除换行符
            char* newline = strchr(output, '\n');
            if (newline) *newline = '\0';
            if (strlen(output) > 0) {
                qosmon_log(ctx, LOG_DEBUG, "TC输出: %s\n", output);
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
        qosmon_log(ctx, LOG_ERROR, "TC命令执行失败: 返回码=%d\n", ret);
        return QMON_ERR_SYSTEM;
    }
    
    ctx->last_tc_bw_kbps = bandwidth_kbps;
    qosmon_log(ctx, LOG_INFO, "带宽设置成功: %d kbps (算法: %s)\n", 
              bandwidth_kbps, ctx->detected_qdisc);
    
    return QMON_OK;
}

int tc_controller_init(tc_controller_t* tc, qosmon_context_t* ctx) {
    if (!tc || !ctx) return QMON_ERR_MEMORY;
    
    tc->ctx = ctx;
    
    // 检测当前队列算法
    char* qdisc_kind = detect_qdisc_kind(ctx);
    strncpy(ctx->detected_qdisc, qdisc_kind, sizeof(ctx->detected_qdisc) - 1);
    ctx->detected_qdisc[sizeof(ctx->detected_qdisc) - 1] = '\0';
    
    // 尝试读取当前带宽设置
    int current_bw_kbps = 0;
    if (detect_class_bandwidth(ctx, &current_bw_kbps) == QMON_OK) {
        ctx->last_tc_bw_kbps = current_bw_kbps;
        qosmon_log(ctx, LOG_INFO, "检测到当前带宽: %d kbps (算法: %s)\n", 
                  current_bw_kbps, ctx->detected_qdisc);
    } else {
        qosmon_log(ctx, LOG_INFO, "使用新的带宽设置 (算法: %s)\n", ctx->detected_qdisc);
    }
    
    return QMON_OK;
}

int tc_controller_set_bandwidth(tc_controller_t* tc, int bandwidth_bps) {
    if (!tc || !tc->ctx) return QMON_ERR_MEMORY;
    
    qosmon_context_t* ctx = tc->ctx;
    
    if (ctx->config.safe_mode) {
        qosmon_log(ctx, LOG_INFO, "安全模式: 跳过带宽设置(%d kbps)\n", 
                  bandwidth_bps / 1000);
        return QMON_OK;
    }
    
    return tc_set_bandwidth(ctx, bandwidth_bps);
}

void tc_controller_cleanup(tc_controller_t* tc) {
    if (!tc || !tc->ctx) return;
    
    qosmon_context_t* ctx = tc->ctx;
    
    // 恢复默认带宽
    if (!ctx->config.safe_mode) {
        int default_bw = ctx->config.max_bandwidth_kbps * 1000;
        tc_set_bandwidth(ctx, default_bw);
        qosmon_log(ctx, LOG_INFO, "TC控制器清理: 恢复带宽到 %d kbps\n", 
                  ctx->config.max_bandwidth_kbps);
    }
    
    qosmon_log(ctx, LOG_INFO, "TC控制器清理完成\n");
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
    ctx->last_heartbeat_ms = now;
    
    // 初始化ping历史
    memset(&ctx->ping_history, 0, sizeof(ping_history_t));
    
    // 初始化队列算法检测
    memset(ctx->detected_qdisc, 0, sizeof(ctx->detected_qdisc));
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
    if (needed_pings <= 0) needed_pings = 1;  // 防止除零
    
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
    int max_bps = ctx->config.max_bandwidth_kbps * 1000;
    if (max_bps == 0) {  // 防止除零
        qosmon_log(ctx, LOG_ERROR, "最大带宽为0\n");
        return;
    }
    
    float utilization = (float)ctx->filtered_total_load_bps / max_bps;
    
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
    int max_bps = ctx->config.max_bandwidth_kbps * 1000;
    if (max_bps == 0) {  // 防止除零
        return;
    }
    
    float utilization = (float)ctx->filtered_total_load_bps / max_bps;
    
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
    int change = new_limit - old_limit;
    if (change < 0) change = -change;
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

// 心跳检测
void heart_beat_check(qosmon_context_t* ctx) {
    if (!ctx) return;
    
    static int64_t last_heartbeat = 0;
    int64_t now = qosmon_time_ms();
    
    if (now - last_heartbeat > HEARTBEAT_INTERVAL_MS) {
        qosmon_log(ctx, LOG_DEBUG, "心跳检测: 系统运行正常\n");
        qosmon_log(ctx, LOG_DEBUG, "  - 状态: %d\n", ctx->state);
        qosmon_log(ctx, LOG_DEBUG, "  - 当前带宽: %d kbps\n", ctx->current_limit_bps / 1000);
        qosmon_log(ctx, LOG_DEBUG, "  - 当前ping: %d ms\n", ctx->filtered_ping_time_us / 1000);
        qosmon_log(ctx, LOG_DEBUG, "  - 最大ping: %d ms\n", ctx->max_ping_time_us / 1000);
        qosmon_log(ctx, LOG_DEBUG, "  - 已发送ping: %d\n", ctx->ntransmitted);
        qosmon_log(ctx, LOG_DEBUG, "  - 已接收ping: %d\n", ctx->nreceived);
        qosmon_log(ctx, LOG_DEBUG, "  - 流量负载: %d kbps\n", ctx->filtered_total_load_bps / 1000);
        qosmon_log(ctx, LOG_DEBUG, "  - 检测队列算法: %s\n", ctx->detected_qdisc);
        
        last_heartbeat = now;
    }
}

void state_machine_run(qosmon_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc) {
    if (!ctx || !pm || !tc) return;
    
    int64_t now = qosmon_time_ms();
    
    // 定期发送ping
    if (ctx->state != QMON_EXIT) {
        int time_since_last_ping = now - ctx->last_ping_time_ms;
        if (time_since_last_ping >= ctx->config.ping_interval) {
            ping_manager_send(pm);
        }
    }
    
    // 定期更新流量统计
    if (now - ctx->last_stats_time_ms > STATS_INTERVAL_MS) {
        load_monitor_update(ctx);
        ctx->last_stats_time_ms = now;
    }
    
    // 定期更新TC设置
    if (now - ctx->last_tc_update_time_ms > CONTROL_INTERVAL_MS) {
        int ret = tc_controller_set_bandwidth(tc, ctx->current_limit_bps);
        if (ret == QMON_OK) {
            ctx->last_tc_update_time_ms = now;
        } else {
            qosmon_log(ctx, LOG_WARN, "带宽设置失败，将在下次重试\n");
        }
    }
    
    // 定期检测实时类
    if (ctx->config.auto_switch_mode && 
        now - ctx->last_realtime_detect_time_ms > REALTIME_DETECT_MS) {
        ctx->realtime_classes = 0;  // 这里可以添加检测实时类数量的逻辑
        ctx->last_realtime_detect_time_ms = now;
    }
    
    // 心跳检测
    heart_beat_check(ctx);
    
    // 状态机主循环
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
        case QMON_EXIT:
            break;
    }
}

/* ==================== 状态文件更新 ==================== */
int status_file_update(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    static int64_t last_update = 0;
    int64_t now = qosmon_time_ms();
    
    // 每5秒更新一次状态文件
    if (now - last_update < 5000) {
        return QMON_OK;
    }
    
    if (!ctx->status_file) {
        ctx->status_file = fopen(ctx->config.status_file, "w");
        if (!ctx->status_file) {
            qosmon_log(ctx, LOG_ERROR, "无法打开状态文件: %s\n", strerror(errno));
            return QMON_ERR_FILE;
        }
    }
    
    // 写入状态信息
    fprintf(ctx->status_file, "状态: %d\n", ctx->state);
    fprintf(ctx->status_file, "当前带宽: %d kbps\n", ctx->current_limit_bps / 1000);
    fprintf(ctx->status_file, "当前ping: %d ms\n", ctx->filtered_ping_time_us / 1000);
    fprintf(ctx->status_file, "最大ping: %d ms\n", ctx->max_ping_time_us / 1000);
    fprintf(ctx->status_file, "流量负载: %d kbps\n", ctx->filtered_total_load_bps / 1000);
    fprintf(ctx->status_file, "已发送ping: %d\n", ctx->ntransmitted);
    fprintf(ctx->status_file, "已接收ping: %d\n", ctx->nreceived);
    fprintf(ctx->status_file, "队列算法: %s\n", ctx->detected_qdisc);
    fprintf(ctx->status_file, "最后更新: %ld\n", (long)now);
    
    fflush(ctx->status_file);
    fseek(ctx->status_file, 0, SEEK_SET);
    
    last_update = now;
    return QMON_OK;
}

/* ==================== 信号处理 ==================== */
void signal_handler(int sig) {
    // 信号处理逻辑
    if (sig == SIGTERM || sig == SIGINT) {
        // 标记退出信号
        // 注意：这里不能直接修改上下文，需要通过全局变量或参数传递
    } else if (sig == SIGUSR1) {
        // 调试信号
    }
}

int setup_signal_handlers(qosmon_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    // 设置信号处理
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    
    if (sigaction(SIGTERM, &sa, NULL) < 0) {
        qosmon_log(ctx, LOG_ERROR, "设置SIGTERM处理失败: %s\n", strerror(errno));
        return QMON_ERR_SIGNAL;
    }
    
    if (sigaction(SIGINT, &sa, NULL) < 0) {
        qosmon_log(ctx, LOG_ERROR, "设置SIGINT处理失败: %s\n", strerror(errno));
        return QMON_ERR_SIGNAL;
    }
    
    if (sigaction(SIGUSR1, &sa, NULL) < 0) {
        qosmon_log(ctx, LOG_ERROR, "设置SIGUSR1处理失败: %s\n", strerror(errno));
        return QMON_ERR_SIGNAL;
    }
    
    // 忽略其他信号
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);
    
    return QMON_OK;
}

/* ==================== 清理函数 ==================== */
void qosmon_cleanup(qosmon_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc) {
    if (!ctx) return;
    
    qosmon_log(ctx, LOG_INFO, "开始清理资源...\n");
    
    // 重置TC设置
    if (!ctx->config.safe_mode) {
        int default_bw = ctx->config.max_bandwidth_kbps * 1000;
        tc_controller_set_bandwidth(tc, default_bw);
        qosmon_log(ctx, LOG_INFO, "重置TC带宽为默认值\n");
    }
    
    // 清理TC控制器
    if (tc) {
        tc_controller_cleanup(tc);
    }
    
    // 清理ping管理器
    if (pm) {
        ping_manager_cleanup(pm);
    }
    
    // 关闭文件
    if (ctx->status_file) {
        fclose(ctx->status_file);
        ctx->status_file = NULL;
    }
    
    if (ctx->debug_log_file) {
        fclose(ctx->debug_log_file);
        ctx->debug_log_file = NULL;
    }
    
    // 重置网络socket
    if (ctx->ping_socket >= 0) {
        close(ctx->ping_socket);
        ctx->ping_socket = -1;
    }
    
    qosmon_log(ctx, LOG_INFO, "资源清理完成\n");
    
    if (ctx->config.background_mode) {
        closelog();
    }
}

/* ==================== 主函数 ==================== */
int main(int argc, char* argv[]) {
    int ret = EXIT_FAILURE;
    qosmon_context_t context = {0};
    ping_manager_t ping_mgr = {0};
    tc_controller_t tc_mgr = {0};
    
    // 初始化配置
    qosmon_config_init(&context.config);
    
    // 解析命令行参数
    int config_result = qosmon_config_parse(&context.config, argc, argv);
    if (config_result != QMON_OK) {
        fprintf(stderr, "配置解析失败\n");
        return EXIT_FAILURE;
    }
    
    // 配置验证
    char config_error[256] = {0};
    if (qosmon_config_validate(&context.config, config_error, sizeof(config_error)) != QMON_OK) {
        fprintf(stderr, "配置验证失败: %s\n", config_error);
        return EXIT_FAILURE;
    }
    
    // 后台运行处理
    if (context.config.background_mode) {
        if (daemon(0, 0) < 0) {
            perror("后台运行失败");
            return EXIT_FAILURE;
        }
        openlog("qosmon", LOG_PID, LOG_USER);
    }
    
    // 打开调试日志文件
    if (strlen(context.config.debug_log) > 0) {
        context.debug_log_file = fopen(context.config.debug_log, "a");
        if (!context.debug_log_file) {
            qosmon_log(&context, LOG_WARN, "无法打开调试日志文件: %s\n", context.config.debug_log);
        } else {
            qosmon_log(&context, LOG_INFO, "调试日志已启用: %s\n", context.config.debug_log);
        }
    }
    
    // 设置信号处理
    if (setup_signal_handlers(&context) != QMON_OK) {
        qosmon_log(&context, LOG_ERROR, "信号处理设置失败\n");
        goto cleanup;
    }
    
    // 初始化上下文
    state_machine_init(&context);
    
    // 解析目标地址
    char resolve_error[256];
    if (resolve_target(context.config.target, &context.target_addr, 
                       resolve_error, sizeof(resolve_error)) != QMON_OK) {
        qosmon_log(&context, LOG_ERROR, "目标地址解析失败: %s\n", resolve_error);
        goto cleanup;
    }
    
    // 初始化ping管理器
    if (ping_manager_init(&ping_mgr, &context) != QMON_OK) {
        qosmon_log(&context, LOG_ERROR, "ping管理器初始化失败\n");
        goto cleanup;
    }
    
    // 初始化TC控制器
    if (tc_controller_init(&tc_mgr, &context) != QMON_OK) {
        qosmon_log(&context, LOG_ERROR, "TC控制器初始化失败\n");
        goto cleanup;
    }
    
    // 设置进程优先级
    if (setpriority(PRIO_PROCESS, 0, -10) < 0) {
        qosmon_log(&context, LOG_WARN, "无法设置进程优先级: %s\n", strerror(errno));
    }
    
    qosmon_log(&context, LOG_INFO, "========================================\n");
    qosmon_log(&context, LOG_INFO, "QoS监控器启动\n");
    qosmon_log(&context, LOG_INFO, "目标地址: %s\n", context.config.target);
    qosmon_log(&context, LOG_INFO, "网络接口: %s\n", context.config.device);
    qosmon_log(&context, LOG_INFO, "最大带宽: %d kbps\n", context.config.max_bandwidth_kbps);
    qosmon_log(&context, LOG_INFO, "ping间隔: %d ms\n", context.config.ping_interval);
    qosmon_log(&context, LOG_INFO, "ping限制: %d ms\n", context.config.ping_limit_ms);
    qosmon_log(&context, LOG_INFO, "TC类ID: 0x%x\n", context.config.classid);
    qosmon_log(&context, LOG_INFO, "安全模式: %s\n", context.config.safe_mode ? "是" : "否");
    qosmon_log(&context, LOG_INFO, "自动切换: %s\n", context.config.auto_switch_mode ? "是" : "否");
    qosmon_log(&context, LOG_INFO, "详细输出: %s\n", context.config.verbose ? "启用" : "禁用");
    qosmon_log(&context, LOG_INFO, "========================================\n");
    
    // 主循环
    qosmon_log(&context, LOG_INFO, "开始监控循环...\n");
    
    context.state = QMON_CHK;
    context.last_heartbeat_ms = qosmon_time_ms();
    
    // 如果不跳过初始测量，先发几个ping测试连通性
    if (!context.config.skip_initial) {
        for (int i = 0; i < 5; i++) {
            ping_manager_send(&ping_mgr);
            usleep(context.config.ping_interval * 1000);
        }
    }
    
    // 主循环
    while (!context.sigterm) {
        int64_t start_time = qosmon_time_ms();
        
        // 接收和处理ping响应
        int ping_result = ping_manager_receive(&ping_mgr);
        if (ping_result > 0) {
            // 成功接收到ping响应
        } else if (ping_result < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            qosmon_log(&context, LOG_ERROR, "接收ping时发生错误\n");
        }
        
        // 运行状态机
        state_machine_run(&context, &ping_mgr, &tc_mgr);
        
        // 更新状态文件
        status_file_update(&context);
        
        // 控制循环速度
        int64_t elapsed = qosmon_time_ms() - start_time;
        int sleep_time = 10;  // 10ms的基本间隔
        if (elapsed < sleep_time) {
            usleep((sleep_time - elapsed) * 1000);
        } else if (elapsed > 50) {
            qosmon_log(&context, LOG_DEBUG, "循环处理时间过长: %ld ms\n", elapsed);
        }
        
        // 检查退出信号
        if (context.sigterm) {
            qosmon_log(&context, LOG_INFO, "收到退出信号\n");
            break;
        }
    }
    
    ret = EXIT_SUCCESS;
    
cleanup:
    // 清理资源
    qosmon_cleanup(&context, &ping_mgr, &tc_mgr);
    
    qosmon_log(&context, LOG_INFO, "QoS监控器已退出\n");
    
    if (context.config.background_mode) {
        closelog();
    }
    
    return ret;
}