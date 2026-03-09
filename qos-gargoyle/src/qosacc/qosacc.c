/* qosacc - 基于netlink的优化版QoS主动拥塞控制
 * 功能：通过ping监控延迟，使用tc库直接调整ifb0根类的带宽
 * 使用poll机制，完整支持HFSC\HTB\CAKE算法。
 * 状态文件目录：/tmp/qosacc.status
 * 1、使用配置文件启动：qosacc -c /etc/qosacc.conf
 * 2、混合使用：配置文件提供基础设置，命令行参数进行覆盖或补充：
 *  命令：qosacc -c /etc/qosacc.conf -v -p 150 -t 1.1.1.1
 * 3、传统的纯命令：
 * qosacc 200 8.8.8.8 10000 20
 * qosacc -d eth0 -t 8.8.8.8 -m 50000 -p 100 -P 30 -v -A
 * 更多使用qosacc -h
 */
 
#define _GNU_SOURCE 1
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
#include <float.h>
#include <time.h>
#include <dlfcn.h>
#include <ctype.h>

// TC库头文件
#include "utils.h"
#include "tc_util.h"
#include "tc_common.h"

/* ==================== 宏定义 ==================== */
#define QMON_LOG_ERROR 0
#define QMON_LOG_WARN  1
#define QMON_LOG_INFO  2
#define QMON_LOG_DEBUG 3
#define MAX_PACKET_SIZE 4096
#define PING_HISTORY_SIZE 10
#define MIN_PING_TIME_MS 1
#define MAX_PING_TIME_MS 5000
#define STATS_INTERVAL_MS 1000
#define CONTROL_INTERVAL_MS 1000
#define REALTIME_DETECT_MS 1000
#define HEARTBEAT_INTERVAL_MS 10000
#define HEARTBEAT_TIMEOUT_MS 30000  // 心跳超时重启机制
#define POLL_TIMEOUT_MS 10   // poll 超时时间
#define MIN_SLEEP_MS 1
#define CONFIG_VERSION 1
#define MIN_CONFIG_VERSION 1
#define MAX_CONFIG_VERSION 1
#define DETECT_QDISC_RETRY_COUNT 3
#define DETECT_QDISC_RETRY_DELAY_MS 100
#define STATUS_FILE_RETRY_COUNT 3
#define STATUS_FILE_RETRY_DELAY_MS 100

// 配置范围宏定义
#define MIN_PING_INTERVAL 50
#define MAX_PING_INTERVAL 5000
#define MIN_BANDWIDTH_KBPS 100
#define MAX_BANDWIDTH_KBPS 1000000
#define MIN_PING_LIMIT_MS 5
#define MAX_PING_LIMIT_MS 1000
#define MIN_BW_RATIO 0.01f
#define MAX_BW_RATIO_MAX 1.0f
#define MIN_BW_RATIO_MIN 0.5f
#define SMOOTHING_FACTOR_MIN 0.0f
#define SMOOTHING_FACTOR_MAX 1.0f
#define MAX_BW_RATIO_MIN 0.5f
#define MAX_BW_RATIO_MAX 1.0f
#define SAFE_START_RATIO 0.5f
#define EPSILON 1e-9   // 浮点数比较误差范围
#define FLOAT_EPSILON 0.001f
#define DOUBLE_EPSILON 1e-12

// 算法参数宏（可从配置文件调整）
#define BANDWIDTH_ADJUST_RATE_NEG 0.002f  // 负误差调整速率
#define BANDWIDTH_ADJUST_RATE_POS 0.004f  // 正误差调整速率
#define MIN_ADJUST_FACTOR 0.85f           // 最小调整因子
#define LOAD_THRESHOLD_FOR_DECREASE 0.85f // 减少带宽的负载阈值

// TC库兼容性宏
#ifndef RTNL_FAMILY_MAX
  #define dump_filter(a,b,c) rtnl_dump_filter(a,b,c,NULL,NULL)
  #define talk(a,b,c,d,e) rtnl_talk(a,b,c,NULL,NULL,NULL,NULL)
#else
  #define dump_filter(a,b,c) rtnl_dump_filter(a,b,c)
  #ifdef IFLA_STATS_RTA
    #define talk(a,b,c) rtnl_talk(a,b,c)
  #else
    #define talk(a,b,c,d,e) rtnl_talk(a,b,c,NULL,NULL)
  #endif
#endif

#define MIN(a,b) (((a)<(b))?(a):(b))

/* ==================== TC库全局变量 ==================== */
bool use_names = false;
int filter_ifindex;
struct rtnl_handle rth;

/* ==================== 返回码 ==================== */
typedef enum {
    QMON_OK = 0,
    QMON_ERR_MEMORY = -1,
    QMON_ERR_SOCKET = -2,
    QMON_ERR_FILE = -3,
    QMON_ERR_CONFIG = -4,
    QMON_ERR_SYSTEM = -5,
    QMON_ERR_SIGNAL = -6,
    QMON_ERR_TIMEOUT = -7,
    QMON_HELP_REQUESTED = -99  // 表示用户请求查看帮助
} qosacc_result_t;

/* ==================== 配置结构 ==================== */
typedef struct {
    int enabled;                // 是否启用此设备配置
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
    char target[64];            // 目标地址
    char device[16];            // 网络设备
    char config_file[256];      // 配置文件
    char debug_log[256];        // 调试日志
    char status_file[256];      // 状态文件
    int check_interval;         // 主循环检查间隔（ms）
} qosacc_config_t;

/* ==================== 状态枚举 ==================== */
typedef enum {
    QMON_CHK,      // 0: 检查状态（初始状态）
    QMON_INIT,     // 1: 初始化状态
    QMON_IDLE,     // 2: 空闲状态
    QMON_ACTIVE,   // 3: 活跃状态
    QMON_REALTIME, // 4: 实时状态
    QMON_EXIT      // 5: 退出状态
} qosacc_state_t;

/* ==================== 运行时统计结构 ==================== */
typedef struct runtime_stats_s {
    int64_t start_time_ms;
    int64_t total_ping_sent;
    int64_t total_ping_received;
    int64_t total_ping_lost;
    int64_t total_bandwidth_adjustments;
    int64_t total_errors;
    int64_t last_error_time;
    int64_t max_ping_time_recorded;
    int64_t min_ping_time_recorded;
    int64_t total_bytes_processed;
    int64_t uptime_seconds;
    int64_t total_heartbeat_checks;
    int64_t total_heartbeat_timeouts;
} runtime_stats_t;

/* ==================== 数据结构 ==================== */
typedef struct ping_history_s {
    int64_t times[PING_HISTORY_SIZE];
    int index;
    int count;
    double smoothed;
} ping_history_t;

/* ==================== 类统计结构 ==================== */
#define STATCNT 30
struct CLASS_STATS {
    int ID;
    __u64 bytes;
    u_char rtclass;
    u_char backlog;
    u_char actflg;
    long int cbw_flt;
    long int cbw_flt_rt;
    int64_t bwtime;
};

/* ==================== 主上下文结构 ==================== */
typedef struct qosacc_context_s {
    qosacc_state_t state;
    qosacc_config_t config;
    
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
    char detected_qdisc[16];
    
    // 时间戳
    int64_t last_ping_time_ms;
    int64_t last_stats_time_ms;
    int64_t last_tc_update_time_ms;
    int64_t last_realtime_detect_time_ms;
    int64_t last_heartbeat_ms;
    int64_t last_runtime_stats_ms;
    
    // 文件
    FILE* status_file;
    FILE* debug_log_file;
    
    // 控制标志
    volatile sig_atomic_t sigterm;
    volatile sig_atomic_t reset_bw;
    
    // 类统计
    struct CLASS_STATS dnstats[STATCNT];
    u_char classcnt;
    u_char errorflg;
    u_char firstflg;
    u_char DCA;
    u_char RTDCA;
    u_char pingon;
    int dbw_fil;
    int dbw_ul;
    
    // 运行时统计
    runtime_stats_t stats;
    
    // 原子操作计数器 - 改用 volatile
    volatile int signal_counter;
} qosacc_context_t;

/* ==================== 全局信号标志 ==================== */
static volatile sig_atomic_t g_sigterm_received = 0;
static volatile sig_atomic_t g_reset_bw = 0;

/* ==================== 线程安全队列检测结果结构 ==================== */
typedef struct {
    char qdisc_kind[16];
    int valid;
    int error_code;
} qdisc_detect_result_t;

/* ==================== 帮助信息 ==================== */
const char qosacc_usage[] =
"qosacc - 基于tc库的精简版QoS监控器\n"
"版本: 基于Paul Bixel代码优化，使用TC库直接操作\n\n"
"用法:\n"
"  qosacc [ping间隔(ms)] [目标地址] [最大带宽(kbps)] [ping限制(ms)]\n"
"  qosacc [选项]\n\n"
"位置参数（传统用法）:\n"
"  ping间隔        发送ICMP ping的间隔，单位毫秒 (范围: 50-5000, 默认: 200)\n"
"  目标地址        用于测量延迟的IP地址或主机名 (默认: 8.8.8.8)\n"
"  最大带宽        网络接口的物理最大带宽，单位kbps (范围: 100-1000000, 默认: 10000)\n"
"  ping限制        期望的ping延迟上限，单位毫秒，超过此值会触发限流 (范围: 5-1000, 默认: 20)\n\n"
"选项:\n"
"  -h, -help, --help\n"
"                  显示此帮助信息并退出\n"
"  -c <文件>        从指定配置文件读取参数\n"
"  -d <设备>        目标网络设备名称 (默认: ifb0)\n"
"  -t <地址/域名>  ping目标地址 (默认: 8.8.8.8)\n"
"  -s <文件>        状态文件路径 (默认: /tmp/qosacc.status)\n"
"  -l <文件>        调试日志文件路径 (默认: /var/log/qosacc.log)\n"
"  -v               启用详细输出模式\n"
"  -b               在后台（守护进程）模式运行\n"
"  -S               启用安全模式（不实际修改TC配置，仅模拟）\n"
"  -A               启用ACTIVE/IDLE状态自动切换\n"
"  -I               跳过初始链路测量\n"
"  -p <间隔>        设置ping间隔(ms)，覆盖位置参数\n"
"  -m <带宽>        设置最大带宽(kbps)，覆盖位置参数\n"
"  -P <限制>        设置ping限制(ms)，覆盖位置参数\n\n"
"示例:\n"
"  qosacc 200 8.8.8.8 10000 20\n"
"  qosacc -b -v -A -d eth0 -p 100 -t 1.1.1.1 -m 50000 -P 15\n"
"  qosacc -c /etc/qosacc.conf\n\n"
"信号处理:\n"
"  SIGTERM, SIGINT  安全终止程序，并尝试恢复TC配置\n"
"  SIGUSR1          重置链路带宽到初始值\n";

/* ==================== 前向声明 ==================== */
struct ping_manager_s;
typedef struct ping_manager_s ping_manager_t;

struct tc_controller_s;
typedef struct tc_controller_s tc_controller_t;

int ping_manager_init(ping_manager_t* pm, qosacc_context_t* ctx);
int ping_manager_send(ping_manager_t* pm);
int ping_manager_receive(ping_manager_t* pm);
void ping_manager_cleanup(ping_manager_t* pm);

int tc_controller_init(tc_controller_t* tc, qosacc_context_t* ctx);
int tc_controller_set_bandwidth(tc_controller_t* tc, int bandwidth_bps);
void tc_controller_cleanup(tc_controller_t* tc);

void qosacc_config_init(qosacc_config_t* cfg);
int qosacc_config_parse(qosacc_config_t* cfg, int argc, char* argv[]);
int qosacc_config_validate(qosacc_config_t* cfg, int argc, char* argv[], char* error, int error_len);

void state_machine_init(qosacc_context_t* ctx);
void state_machine_run(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc);
void update_runtime_stats(qosacc_context_t* ctx);

void qosacc_cleanup(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc);

char* get_tc_path(void);

/* ==================== 辅助函数 ==================== */
int64_t qosacc_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    int64_t ms = (int64_t)tv.tv_sec * 1000LL + (int64_t)tv.tv_usec / 1000LL;
    return ms;
}

uint16_t icmp_checksum(void* data, int len) {
    uint16_t* p = (uint16_t*)data;
    uint32_t sum = 0;
    
    for (; len > 1; len -= 2) {
        sum += *p++;
    }
    
    if (len == 1) {
        sum += *(uint8_t*)p;
    }
    
    sum = (sum >> 16) + (sum & 0xFFFF);
    sum += (sum >> 16);
    
    return (uint16_t)~sum;
}

int resolve_target(const char* target, struct sockaddr_in6* addr, char* error, int error_len) {
    if (!target || !addr || !error) return QMON_ERR_MEMORY;
    
    struct addrinfo hints, *result = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_RAW;
    hints.ai_flags = AI_ADDRCONFIG;
    
    int ret = getaddrinfo(target, NULL, &hints, &result);
    if (ret != 0) {
        snprintf(error, error_len, "无法解析地址 %s: %s", target, gai_strerror(ret));
        return QMON_ERR_SYSTEM;
    }
    
    if (result->ai_family == AF_INET) {
        memset(addr, 0, sizeof(struct sockaddr_in6));
        addr->sin6_family = AF_INET6;
        addr->sin6_addr.s6_addr[10] = 0xFF;
        addr->sin6_addr.s6_addr[11] = 0xFF;
        memcpy(&addr->sin6_addr.s6_addr[12], 
               &((struct sockaddr_in*)result->ai_addr)->sin_addr, 4);
    } else if (result->ai_family == AF_INET6) {
        memcpy(addr, result->ai_addr, sizeof(struct sockaddr_in6));
    } else {
        snprintf(error, error_len, "不支持的地址族: %d", result->ai_family);
        freeaddrinfo(result);
        return QMON_ERR_SYSTEM;
    }
    
    freeaddrinfo(result);
    return QMON_OK;
}

/* ==================== 日志系统 ==================== */
void qosacc_log(qosacc_context_t* ctx, int level, const char* format, ...) {
    if (!ctx) return;
    
    if (!ctx->config.verbose && level > QMON_LOG_INFO) {
        return;
    }
    
    /* 修改：使用普通的静态变量代替原子操作 */
    static int64_t last_log_time = 0;
    static char cached_time_str[32] = {0};
    int64_t now_ms = qosacc_time_ms();
    
    va_list args;
    char buffer[1024];
    
    if (now_ms - last_log_time > 100 || last_log_time == 0) {
        time_t now = time(NULL);
        struct tm* tm_info = localtime(&now);
        strftime(cached_time_str, sizeof(cached_time_str), "%Y-%m-%d %H:%M:%S", tm_info);
        last_log_time = now_ms;
    }
    
    va_start(args, format);
    int n = vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    
    if (n < 0 || n >= (int)sizeof(buffer)) {
        buffer[sizeof(buffer)-1] = '\0';
    }
    
    if (ctx->config.background_mode) {
        int syslog_level = LOG_INFO;
        switch (level) {
            case QMON_LOG_ERROR: syslog_level = LOG_ERR; break;
            case QMON_LOG_WARN:  syslog_level = LOG_WARNING; break;
            case QMON_LOG_INFO:  syslog_level = LOG_INFO; break;
            case QMON_LOG_DEBUG: syslog_level = LOG_DEBUG; break;
        }
        syslog(syslog_level, "%s", buffer);
    } else {
        const char* level_str = "UNKNOWN";
        switch (level) {
            case QMON_LOG_ERROR: level_str = "ERROR"; break;
            case QMON_LOG_WARN:  level_str = "WARN"; break;
            case QMON_LOG_INFO:  level_str = "INFO"; break;
            case QMON_LOG_DEBUG: level_str = "DEBUG"; break;
        }
        
        if (ctx->config.verbose || level <= QMON_LOG_INFO) {
            fprintf(stderr, "[%s] [%s] %s", cached_time_str, level_str, buffer);
        }
    }
    
    if (ctx->debug_log_file && (ctx->config.verbose || level <= QMON_LOG_INFO)) {
        const char* level_str = "UNKNOWN";
        switch (level) {
            case QMON_LOG_ERROR: level_str = "ERROR"; break;
            case QMON_LOG_WARN:  level_str = "WARN"; break;
            case QMON_LOG_INFO:  level_str = "INFO"; break;
            case QMON_LOG_DEBUG: level_str = "DEBUG"; break;
        }
        fprintf(ctx->debug_log_file, "[%s] [%s] %s", cached_time_str, level_str, buffer);
        fflush(ctx->debug_log_file);
    }
}

/* ==================== 配置文件解析辅助函数 ==================== */
static void trim_whitespace(char* str) {
    if (!str) return;
    char* end;
    while (isspace((unsigned char)*str)) str++;
    if (*str == 0) return;
    end = str + strlen(str) - 1;
    while (end > str && isspace((unsigned char)*end)) end--;
    end[1] = '\0';
}

static int parse_key_value(const char* line, char* key, int key_len, char* value, int value_len) {
    const char* equal_sign = strchr(line, '=');
    if (!equal_sign) return 0;
    
    int key_len_to_copy = equal_sign - line;
    if (key_len_to_copy >= key_len) key_len_to_copy = key_len - 1;
    strncpy(key, line, key_len_to_copy);
    key[key_len_to_copy] = '\0';
    
    const char* value_start = equal_sign + 1;
    int value_len_to_copy = strlen(value_start);
    if (value_len_to_copy >= value_len) value_len_to_copy = value_len - 1;
    strncpy(value, value_start, value_len_to_copy);
    value[value_len_to_copy] = '\0';
    
    trim_whitespace(key);
    trim_whitespace(value);
    return 1;
}

/* ==================== 配置处理 ==================== */
void qosacc_config_init(qosacc_config_t* cfg) {
    if (!cfg) return;
    
    memset(cfg, 0, sizeof(qosacc_config_t));
    cfg->enabled = 1;
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
    cfg->check_interval = 1000;
    strcpy(cfg->device, "ifb0");
    strcpy(cfg->target, "8.8.8.8");
    strcpy(cfg->status_file, "/tmp/qosacc.status");
    strcpy(cfg->debug_log, "/var/log/qosacc.log");
}

static int qosacc_config_parse_file(qosacc_config_t* cfg, const char* config_file) {
    if (!cfg || !config_file) return QMON_ERR_MEMORY;
    
    FILE* fp = fopen(config_file, "r");
    if (!fp) {
        fprintf(stderr, "错误：指定的配置文件'%s'无法打开: %s\n", config_file, strerror(errno));
        return QMON_ERR_FILE;
    }
    
    char line[256];
    int in_device_section = 0;
    
    qosacc_config_init(cfg);
    cfg->enabled = 0;
    
    while (fgets(line, sizeof(line), fp)) {
        char* newline = strchr(line, '\n');
        if (newline) *newline = '\0';
        newline = strchr(line, '\r');
        if (newline) *newline = '\0';
        
        if (line[0] == '#' || line[0] == ';' || line[0] == '\0') {
            continue;
        }
        
        if (line[0] == '[' && strchr(line, ']')) {
            char section[64];
            if (sscanf(line, "[%63[^]]]", section) == 1) {
                if (strncmp(section, "device=", 7) == 0) {
                    const char* device_name = section + 7;
                    if (strcmp(device_name, cfg->device) == 0) {
                        in_device_section = 1;
                        cfg->enabled = 1;
                        continue;
                    } else {
                        in_device_section = 0;
                        continue;
                    }
                } else {
                    in_device_section = 0;
                    continue;
                }
            }
        }
        
        if (in_device_section) {
            char key[64], value[64];
            if (parse_key_value(line, key, sizeof(key), value, sizeof(value))) {
                if (strcmp(key, "enabled") == 0) {
                    cfg->enabled = atoi(value);
                } else if (strcmp(key, "target") == 0) {
                    strncpy(cfg->target, value, sizeof(cfg->target)-1);
                } else if (strcmp(key, "ping_interval") == 0) {
                    cfg->ping_interval = atoi(value);
                } else if (strcmp(key, "max_bandwidth_kbps") == 0) {
                    cfg->max_bandwidth_kbps = atoi(value);
                } else if (strcmp(key, "ping_limit_ms") == 0) {
                    cfg->ping_limit_ms = atoi(value);
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
                } else if (strcmp(key, "debug_log") == 0) {
                    strncpy(cfg->debug_log, value, sizeof(cfg->debug_log)-1);
                } else if (strcmp(key, "status_file") == 0) {
                    strncpy(cfg->status_file, value, sizeof(cfg->status_file)-1);
                } else if (strcmp(key, "check_interval") == 0) {
                    cfg->check_interval = atoi(value) * 1000;
                } else if (strcmp(key, "config_version") == 0) {
                    int version = atoi(value);
                    if (version < MIN_CONFIG_VERSION || version > MAX_CONFIG_VERSION) {
                        fprintf(stderr, "配置版本不兼容: %d (支持: %d-%d)\n", 
                                version, MIN_CONFIG_VERSION, MAX_CONFIG_VERSION);
                        fclose(fp);
                        return QMON_ERR_CONFIG;
                    }
                }
            }
        }
    }
    
    fclose(fp);
    
    if (!cfg->enabled) {
        fprintf(stderr, "警告：配置文件中未找到设备 '%s' 的启用配置。\n", cfg->device);
    }
    
    return QMON_OK;
}

int qosacc_config_parse(qosacc_config_t* cfg, int argc, char* argv[]) {
    if (!cfg) return QMON_ERR_MEMORY;
    
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || 
            strcmp(argv[i], "-help") == 0 || 
            strcmp(argv[i], "--help") == 0) {
            return QMON_HELP_REQUESTED;
        }
    }
    
    qosacc_config_init(cfg);
    
    int config_file_provided = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) {
            char* config_file = argv[++i];
            strncpy(cfg->config_file, config_file, sizeof(cfg->config_file) - 1);
            int ret = qosacc_config_parse_file(cfg, config_file);
            if (ret != QMON_OK) {
                fprintf(stderr, "错误：配置文件解析失败。\n");
                return ret;
            }
            config_file_provided = 1;
            break;
        }
    }
    
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0) {
            i++;
            continue;
        } else if (strcmp(argv[i], "-d") == 0 && i + 1 < argc) {
            strncpy(cfg->device, argv[++i], sizeof(cfg->device) - 1);
            if (config_file_provided && strlen(cfg->config_file) > 0) {
                qosacc_config_parse_file(cfg, cfg->config_file);
            }
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
        } else if (strcmp(argv[i], "-p") == 0 && i + 1 < argc) {
            cfg->ping_interval = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-m") == 0 && i + 1 < argc) {
            cfg->max_bandwidth_kbps = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-P") == 0 && i + 1 < argc) {
            cfg->ping_limit_ms = atoi(argv[++i]);
        } else if (i == 1 && argc >= 4) {
            cfg->ping_interval = atoi(argv[1]);
            if (argc >= 2) strncpy(cfg->target, argv[2], sizeof(cfg->target) - 1);
            if (argc >= 3) cfg->max_bandwidth_kbps = atoi(argv[3]);
            if (argc >= 4) cfg->ping_limit_ms = atoi(argv[4]);
            i += 3;
        }
    }
    
    return QMON_OK;
}

int qosacc_config_validate(qosacc_config_t* cfg, int argc, char* argv[], char* error, int error_len) {
    if (argc == 1) {
        snprintf(error, error_len, "未提供任何参数");
        return QMON_ERR_CONFIG;
    }
    
    if (!cfg || !error) return QMON_ERR_MEMORY;

    if (!cfg->enabled) {
        snprintf(error, error_len, "设备 '%s' 的配置未启用", cfg->device);
        return QMON_ERR_CONFIG;
    }

    if (cfg->ping_interval < MIN_PING_INTERVAL || cfg->ping_interval > MAX_PING_INTERVAL) {
        snprintf(error, error_len, "ping间隔必须在%d-%dms之间", 
                MIN_PING_INTERVAL, MAX_PING_INTERVAL);
        return QMON_ERR_CONFIG;
    }
    
    if (cfg->max_bandwidth_kbps < MIN_BANDWIDTH_KBPS || cfg->max_bandwidth_kbps > MAX_BANDWIDTH_KBPS) {
        snprintf(error, error_len, "最大带宽必须在%d-%dkbps之间", 
                MIN_BANDWIDTH_KBPS, MAX_BANDWIDTH_KBPS);
        return QMON_ERR_CONFIG;
    }
    
    if (cfg->ping_limit_ms < MIN_PING_LIMIT_MS || cfg->ping_limit_ms > MAX_PING_LIMIT_MS) {
        snprintf(error, error_len, "ping限制必须在%d-%dms之间", 
                MIN_PING_LIMIT_MS, MAX_PING_LIMIT_MS);
        return QMON_ERR_CONFIG;
    }
    
    if (strlen(cfg->target) == 0) {
        snprintf(error, error_len, "必须指定目标地址");
        return QMON_ERR_CONFIG;
    }
    
    if (strlen(cfg->device) == 0) {
        snprintf(error, error_len, "必须指定网络设备");
        return QMON_ERR_CONFIG;
    }
    
    if (cfg->min_bw_ratio < (MIN_BW_RATIO - EPSILON) || cfg->min_bw_ratio > (MIN_BW_RATIO_MIN + EPSILON)) {
        snprintf(error, error_len, "最小带宽比例必须在%.2f-%.2f之间", 
                MIN_BW_RATIO, MIN_BW_RATIO_MIN);
        return QMON_ERR_CONFIG;
    }
    
    if (cfg->max_bw_ratio < (MAX_BW_RATIO_MIN - EPSILON) || cfg->max_bw_ratio > (MAX_BW_RATIO_MAX + EPSILON)) {
        snprintf(error, error_len, "最大带宽比例必须在%.2f-%.2f之间", 
                MAX_BW_RATIO_MIN, MAX_BW_RATIO_MAX);
        return QMON_ERR_CONFIG;
    }
    
    if (cfg->smoothing_factor <= (SMOOTHING_FACTOR_MIN - EPSILON) || cfg->smoothing_factor >= (SMOOTHING_FACTOR_MAX + EPSILON)) {
        snprintf(error, error_len, "平滑因子必须在%.1f-%.1f之间", 
                SMOOTHING_FACTOR_MIN, SMOOTHING_FACTOR_MAX);
        return QMON_ERR_CONFIG;
    }
    
    return QMON_OK;
}

/* ==================== Ping管理器实现 ==================== */
struct ping_manager_s {
    qosacc_context_t* ctx;
    char packet[MAX_PACKET_SIZE];
};

int ping_manager_init(ping_manager_t* pm, qosacc_context_t* ctx) {
    if (!pm || !ctx) return QMON_ERR_MEMORY;
    
    pm->ctx = ctx;
    
    int af = ctx->target_addr.sin6_family;
    int socktype = SOCK_RAW;
    int protocol = (af == AF_INET6) ? IPPROTO_ICMPV6 : IPPROTO_ICMP;
    
    ctx->ping_socket = socket(af, socktype, protocol);
    if (ctx->ping_socket < 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "创建ping套接字失败: %s\n", strerror(errno));
        return QMON_ERR_SOCKET;
    }
    
    int ttl = 64;
    if (setsockopt(ctx->ping_socket, IPPROTO_IP, IP_TTL, &ttl, sizeof(ttl)) < 0) {
        qosacc_log(ctx, QMON_LOG_WARN, "设置TTL失败: %s\n", strerror(errno));
    }
    
    int timeout = 2000;
    if (setsockopt(ctx->ping_socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
        qosacc_log(ctx, QMON_LOG_WARN, "设置接收超时失败: %s\n", strerror(errno));
    }
    
    int flags = fcntl(ctx->ping_socket, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(ctx->ping_socket, F_SETFL, flags | O_NONBLOCK);
    }
    
    return QMON_OK;
}

int ping_manager_send(ping_manager_t* pm) {
    if (!pm || !pm->ctx) return QMON_ERR_MEMORY;
    
    qosacc_context_t* ctx = pm->ctx;
    
    if (ctx->ping_socket < 0) {
        return QMON_ERR_SOCKET;
    }
    
    int cc = 0;
    if (ctx->target_addr.sin6_family == AF_INET6) {
        struct icmp6_hdr* icp6 = (struct icmp6_hdr*)pm->packet;
        icp6->icmp6_type = ICMP6_ECHO_REQUEST;
        icp6->icmp6_code = 0;
        icp6->icmp6_id = htons(ctx->ident);
        icp6->icmp6_seq = htons(ctx->ntransmitted);
        
        struct timeval* tv = (struct timeval*)(pm->packet + sizeof(struct icmp6_hdr));
        gettimeofday(tv, NULL);
        
        cc = 8 + sizeof(struct timeval);
        for (int i = 8; i < cc; i++) {
            pm->packet[8 + sizeof(struct icmp6_hdr) + i] = i;
        }
        
        icp6->icmp6_cksum = 0;
    } else {
        struct icmp* icp = (struct icmp*)pm->packet;
        icp->icmp_type = ICMP_ECHO;
        icp->icmp_code = 0;
        icp->icmp_id = ctx->ident;
        icp->icmp_seq = ctx->ntransmitted;
        
        struct timeval* tv = (struct timeval*)(pm->packet + 8);
        gettimeofday(tv, NULL);
        
        cc = 8 + sizeof(struct timeval);
        for (int i = 8; i < cc; i++) {
            pm->packet[8 + sizeof(struct timeval) + i] = i;
        }
        
        icp->icmp_cksum = icmp_checksum(icp, cc);
    }
    
    ctx->ntransmitted++;
    
    int ret = sendto(ctx->ping_socket, pm->packet, cc, 0,
                     (struct sockaddr*)&ctx->target_addr, 
                     sizeof(ctx->target_addr));
    
    if (ret < 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "发送ping失败: %s\n", strerror(errno));
        return QMON_ERR_SOCKET;
    }
    
    ctx->last_ping_time_ms = qosacc_time_ms();
    qosacc_log(ctx, QMON_LOG_DEBUG, "发送ping, seq=%d\n", ctx->ntransmitted);
    
    return QMON_OK;
}

int ping_manager_receive(ping_manager_t* pm) {
    if (!pm || !pm->ctx) return QMON_ERR_MEMORY;
    
    qosacc_context_t* ctx = pm->ctx;
    char buf[MAX_PACKET_SIZE];
    struct sockaddr_storage from;
    socklen_t fromlen = sizeof(from);
    
    int cc = recvfrom(ctx->ping_socket, buf, sizeof(buf), 0,
                      (struct sockaddr*)&from, &fromlen);
    
    if (cc < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            qosacc_log(ctx, QMON_LOG_ERROR, "接收ping失败: %s\n", strerror(errno));
        }
        return QMON_ERR_SOCKET;
    }
    
    struct ip* ip = NULL;
    struct icmp* icp = NULL;
    struct icmp6_hdr* icp6 = NULL;
    struct timeval tv, *tp = NULL;
    int hlen, triptime = 0;
    uint16_t seq = 0;
    
    if (gettimeofday(&tv, NULL) != 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "获取时间失败: %s\n", strerror(errno));
        return QMON_ERR_SYSTEM;
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
    
    if (tp) {
        triptime = tv.tv_sec - tp->tv_sec;
        triptime = triptime * 1000 + (tv.tv_usec - tp->tv_usec) / 1000;
    }
    
    if (triptime < 0) {
        qosacc_log(ctx, QMON_LOG_WARN, "检测到时间回绕，重置ping计时\n");
        triptime = MIN_PING_TIME_MS;
    }
    
    if (triptime < MIN_PING_TIME_MS) triptime = MIN_PING_TIME_MS;
    if (triptime > MAX_PING_TIME_MS) triptime = MAX_PING_TIME_MS;
    
    ctx->raw_ping_time_us = triptime * 1000;
    
    if (ctx->raw_ping_time_us > ctx->max_ping_time_us) {
        ctx->max_ping_time_us = ctx->raw_ping_time_us;
    }
    
    ping_history_t* hist = &ctx->ping_history;
    if (hist->count < PING_HISTORY_SIZE) {
        hist->times[hist->index] = ctx->raw_ping_time_us;
    } else {
        hist->times[hist->index] = ctx->raw_ping_time_us;
    }
    hist->index = (hist->index + 1) % PING_HISTORY_SIZE;
    if (hist->count < PING_HISTORY_SIZE) hist->count++;
    
    if (hist->count == 1) {
        hist->smoothed = ctx->raw_ping_time_us;
    } else {
        hist->smoothed = hist->smoothed * (1.0 - ctx->config.smoothing_factor) +
                          ctx->raw_ping_time_us * ctx->config.smoothing_factor;
    }
    
    ctx->filtered_ping_time_us = (int64_t)hist->smoothed;
    
    qosacc_log(ctx, QMON_LOG_DEBUG, "收到ping回复: seq=%d, 时间=%dms, 平滑=%ldms\n",
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
int load_monitor_update(qosacc_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    static unsigned long long last_rx_bytes = 0;
    static int64_t last_read_time = 0;
    
    char line[256];
    unsigned long long rx_bytes = 0;
    int found = 0;
    
    FILE* fp = fopen("/proc/net/dev", "r");
    if (!fp) {
        qosacc_log(ctx, QMON_LOG_ERROR, "无法打开 /proc/net/dev: %s\n", strerror(errno));
        return QMON_ERR_FILE;
    }
    
    for (int i = 0; i < 2; i++) {
        if (!fgets(line, sizeof(line), fp)) {
            fclose(fp);
            return QMON_ERR_FILE;
        }
    }
    
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
        qosacc_log(ctx, QMON_LOG_ERROR, "接口 %s 未找到\n", ctx->config.device);
        return QMON_ERR_SYSTEM;
    }
    
    int64_t now = qosacc_time_ms();
    
    if (last_read_time > 0 && last_rx_bytes > 0 && rx_bytes >= last_rx_bytes) {
        int time_diff = (int)(now - last_read_time);
        if (time_diff > 0) {
            unsigned long long bytes_diff = rx_bytes - last_rx_bytes;
            int bps = (int)((bytes_diff * 8000) / time_diff);
            
            if (bps < 0) {
                qosacc_log(ctx, QMON_LOG_WARN, "流量统计溢出，重置\n");
                bps = 0;
            }
            
            float alpha = 0.1f;
            ctx->filtered_total_load_bps += (int)((bps - ctx->filtered_total_load_bps) * alpha);
            
            int max_bps = ctx->config.max_bandwidth_kbps * 1000;
            if (ctx->filtered_total_load_bps < 0) {
                ctx->filtered_total_load_bps = 0;
            } else if (ctx->filtered_total_load_bps > max_bps) {
                ctx->filtered_total_load_bps = max_bps;
            }
            
            qosacc_log(ctx, QMON_LOG_DEBUG, "流量统计: 原始=%d bps, 平滑=%d bps\n", 
                      bps, ctx->filtered_total_load_bps);
        }
    }
    
    last_rx_bytes = rx_bytes;
    last_read_time = now;
    
    return QMON_OK;
}

/* ==================== TC控制器实现（使用TC库） ==================== */
struct tc_controller_s {
    qosacc_context_t* ctx;
};

int get_root_classid(qosacc_context_t* ctx, __u32* root_classid) {
    if (!ctx || !root_classid) return QMON_ERR_MEMORY;
    
    *root_classid = 0x10001;
    
    if (get_tc_classid(root_classid, "1:1") == 0) {
        qosacc_log(ctx, QMON_LOG_DEBUG, "检测到根类ID: 1:%x\n", *root_classid & 0xFFFF);
        return QMON_OK;
    }
    
    qosacc_log(ctx, QMON_LOG_INFO, "使用默认根类ID: 1:1\n");
    return QMON_OK;
}

int print_class(struct nlmsghdr *n, void *arg) {
    qosacc_context_t* ctx = (qosacc_context_t*)arg;
    struct tcmsg *t = NLMSG_DATA(n);
    int len = n->nlmsg_len;
    struct rtattr * tb[TCA_MAX+1];
    int leafid;
    u_char actflg = 0;
    unsigned long long work = 0;
    struct timespec newtime;
    int64_t now_ns;

    if (n->nlmsg_type != RTM_NEWTCLASS && n->nlmsg_type != RTM_DELTCLASS) {
        return 0;
    }
    
    len -= NLMSG_LENGTH(sizeof(*t));
    if (len < 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "Wrong len %d\n", len);
        return -1;
    }

    memset(tb, 0, sizeof(tb));
    parse_rtattr(tb, TCA_MAX, TCA_RTA(t), len);
    if (clock_gettime(CLOCK_MONOTONIC, &newtime) != 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "clock_gettime失败: %s\n", strerror(errno));
        return -1;
    }

    if (tb[TCA_KIND] == NULL) {
        qosacc_log(ctx, QMON_LOG_ERROR, "print_class: NULL kind\n");
        return -1;
    }

    if (n->nlmsg_type == RTM_DELTCLASS) return 0;

    char* kind = (char*)RTA_DATA(tb[TCA_KIND]);
    if (strcmp(kind, "htb") != 0 && strcmp(kind, "hfsc") != 0) {
        return 0;
    }

    if (t->tcm_parent == TC_H_ROOT) return 0;

    if (ctx->errorflg) return 0;

    if (ctx->classcnt >= STATCNT) {
        ctx->errorflg = 1;
        return 0;
    }

    if (t->tcm_info) leafid = t->tcm_info >> 16;
    else leafid = -1;

    if ((!ctx->firstflg) && (leafid != ctx->dnstats[ctx->classcnt].ID)) {
        ctx->errorflg = 1;
        return 0;
    }

    if (ctx->firstflg) {
        ctx->dnstats[ctx->classcnt].ID = leafid;
    }

    if (tb[TCA_STATS2]) {
        struct tc_stats st;
        memset(&st, 0, sizeof(st));
        memcpy(&st, RTA_DATA(tb[TCA_STATS]), MIN(RTA_PAYLOAD(tb[TCA_STATS]), sizeof(st)));
        work = st.bytes;
        ctx->dnstats[ctx->classcnt].backlog = st.qlen;

        if (ctx->firstflg) {
            ctx->dnstats[ctx->classcnt].rtclass = 0;
            
            if (strcmp(kind, "hfsc") == 0) {
                struct tc_service_curve *sc = NULL;
                struct rtattr *tbs[TCA_HFSC_MAX + 1];
                
                parse_rtattr_nested(tbs, TCA_HFSC_MAX, tb[TCA_OPTIONS]);
                if (tbs[TCA_HFSC_RSC] && (RTA_PAYLOAD(tbs[TCA_HFSC_RSC]) >= sizeof(*sc))) {
                    sc = RTA_DATA(tbs[TCA_HFSC_RSC]);
                    ctx->dnstats[ctx->classcnt].rtclass |= (sc && sc->m1);
                }
            }
        }
    } else {
        ctx->errorflg = 1;
        return 0;
    }

    now_ns = (int64_t)newtime.tv_sec * 1000000000LL + (int64_t)newtime.tv_nsec;

    if (ctx->firstflg) {
        ctx->dnstats[ctx->classcnt].bytes = work;
    }

    if (work >= ctx->dnstats[ctx->classcnt].bytes) {
        long int bw;
        long bperiod;

        bperiod = (now_ns - ctx->dnstats[ctx->classcnt].bwtime) / 1000000LL;
        if (bperiod < ctx->config.ping_interval / 2) bperiod = ctx->config.ping_interval;
        bw = (work - ctx->dnstats[ctx->classcnt].bytes) * 8000 / bperiod;

        float BWTC = 0.1f;
        ctx->dnstats[ctx->classcnt].cbw_flt = (bw - ctx->dnstats[ctx->classcnt].cbw_flt) * BWTC + ctx->dnstats[ctx->classcnt].cbw_flt;

        if ((leafid != -1) && (ctx->dnstats[ctx->classcnt].cbw_flt > 4000)) {
            ctx->DCA++;
            actflg = 1;
            if (ctx->dnstats[ctx->classcnt].rtclass) ctx->RTDCA++;
        }

        if (leafid == -1) {
            ctx->dbw_fil = 0;
        } else {
            ctx->dbw_fil += ctx->dnstats[ctx->classcnt].cbw_flt;
        }
    }

    ctx->dnstats[ctx->classcnt].bwtime = now_ns;
    ctx->dnstats[ctx->classcnt].bytes = work;
    ctx->dnstats[ctx->classcnt].actflg = actflg;

    ctx->classcnt++;
    return 0;
}

int class_list(qosacc_context_t* ctx) {
    struct tcmsg t;
    
    ctx->RTDCA = ctx->DCA = 0;
    memset(&t, 0, sizeof(t));
    t.tcm_family = AF_UNSPEC;

    ll_init_map(&rth);

    if (ctx->config.device[0]) {
        if ((t.tcm_ifindex = ll_name_to_index(ctx->config.device)) == 0) {
            qosacc_log(ctx, QMON_LOG_ERROR, "Cannot find device \"%s\"\n", ctx->config.device);
            return 1;
        }
        filter_ifindex = t.tcm_ifindex;
    }

    if (rtnl_dump_request(&rth, RTM_GETTCLASS, &t, sizeof(t)) < 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "Cannot send dump request\n");
        return 1;
    }

    if (dump_filter(&rth, print_class, ctx) < 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "Dump terminated\n");
        return 1;
    }

    return 0;
}

int tc_class_modify(qosacc_context_t* ctx, __u32 rate) {
    if (ctx->dbw_ul == rate) return 0;
    ctx->dbw_ul = rate;

    struct {
        struct nlmsghdr n;
        struct tcmsg t;
        char buf[4096];
    } req;

    char k[16];
    __u32 handle;

    memset(&req, 0, sizeof(req));
    memset(k, 0, sizeof(k));

    req.n.nlmsg_len = NLMSG_LENGTH(sizeof(struct tcmsg));
    req.n.nlmsg_flags = NLM_F_REQUEST;
    req.n.nlmsg_type = RTM_NEWTCLASS;
    req.t.tcm_family = AF_UNSPEC;

    if (get_tc_classid(&handle, "1:1")) {
        qosacc_log(ctx, QMON_LOG_ERROR, "invalid class ID\n");
        return 1;
    }
    req.t.tcm_handle = handle;

    if (get_tc_classid(&handle, "1:0")) {
        qosacc_log(ctx, QMON_LOG_ERROR, "invalid parent ID\n");
        return 1;
    }
    req.t.tcm_parent = handle;
    
    strcpy(k, "hfsc");
    addattr_l(&req.n, sizeof(req), TCA_KIND, k, strlen(k) + 1);

    {
        struct tc_service_curve usc;
        struct rtattr *tail;

        memset(&usc, 0, sizeof(usc));
        usc.m2 = rate / 8;

        tail = NLMSG_TAIL(&req.n);
        addattr_l(&req.n, 1024, TCA_OPTIONS, NULL, 0);
        addattr_l(&req.n, 1024, TCA_HFSC_USC, &usc, sizeof(usc));
        tail->rta_len = (void *)NLMSG_TAIL(&req.n) - (void *)tail;
    }

    ll_init_map(&rth);

    if ((req.t.tcm_ifindex = ll_name_to_index(ctx->config.device)) == 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "Cannot find device %s\n", ctx->config.device);
        return 1;
    }

    if (talk(&rth, &req.n, NULL) < 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "Failed to modify TC class\n");
        return 2;
    }

    qosacc_log(ctx, QMON_LOG_INFO, "TC带宽设置成功: %d bps\n", rate);
    return 0;
}

qdisc_detect_result_t safe_detect_qdisc_kind(qosacc_context_t* ctx) {
    qdisc_detect_result_t result = {0};
    strcpy(result.qdisc_kind, "htb");
    result.valid = 1;
    
    qosacc_log(ctx, QMON_LOG_INFO, "开始检测 %s 的队列类型...\n", ctx->config.device);
    
    for (int attempt = 0; attempt < DETECT_QDISC_RETRY_COUNT; attempt++) {
        if (attempt > 0) {
            usleep(DETECT_QDISC_RETRY_DELAY_MS * 1000);
            qosacc_log(ctx, QMON_LOG_INFO, "第 %d 次重试检测队列类型...\n", attempt + 1);
        }
        
        // 使用详细输出模式获取更多信息
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "tc -d qdisc show dev %s 2>&1", ctx->config.device);
        qosacc_log(ctx, QMON_LOG_DEBUG, "执行检测命令: %s\n", cmd);
        
        FILE* fp = popen(cmd, "r");
        if (!fp) {
            qosacc_log(ctx, QMON_LOG_ERROR, "popen失败: %s\n", strerror(errno));
            result.error_code = errno;
            result.valid = 0;
            continue;
        }
        
        char line[512];
        int found_root_qdisc = 0;
        int found_any_qdisc = 0;
        int line_num = 0;
        
        while (fgets(line, sizeof(line), fp)) {
            line_num++;
            char* newline = strchr(line, '\n');
            if (newline) *newline = '\0';
            
            qosacc_log(ctx, QMON_LOG_DEBUG, "TC输出[%d]: %s\n", line_num, line);
            
            // 首先检查是否是根队列行
            if (strstr(line, "root") != NULL) {
                qosacc_log(ctx, QMON_LOG_DEBUG, "找到根队列行: %s\n", line);
                
                // 在根队列行中检测队列类型
                if (strstr(line, "hfsc") != NULL) {
                    strcpy(result.qdisc_kind, "hfsc");
                    found_root_qdisc = 1;
                    qosacc_log(ctx, QMON_LOG_DEBUG, "在根队列行检测到HFSC\n");
                    break;
                } else if (strstr(line, "htb") != NULL) {
                    strcpy(result.qdisc_kind, "htb");
                    found_root_qdisc = 1;
                    qosacc_log(ctx, QMON_LOG_DEBUG, "在根队列行检测到HTB\n");
                    break;
                } else if (strstr(line, "cake") != NULL) {
                    strcpy(result.qdisc_kind, "cake");
                    found_root_qdisc = 1;
                    qosacc_log(ctx, QMON_LOG_DEBUG, "在根队列行检测到CAKE\n");
                    break;
                } else if (strstr(line, "fq_codel") != NULL) {
                    // 这可能是子队列，不是根队列
                    qosacc_log(ctx, QMON_LOG_DEBUG, "注意: 找到fq_codel子队列，继续查找\n");
                }
            }
            
            // 如果没有在根队列行找到，但任意行中有队列类型，记录下来
            if (strstr(line, "hfsc") != NULL) {
                strcpy(result.qdisc_kind, "hfsc");
                found_any_qdisc = 1;
                qosacc_log(ctx, QMON_LOG_DEBUG, "在行%d检测到HFSC\n", line_num);
            } else if (strstr(line, "htb") != NULL) {
                strcpy(result.qdisc_kind, "htb");
                found_any_qdisc = 1;
                qosacc_log(ctx, QMON_LOG_DEBUG, "在行%d检测到HTB\n", line_num);
            } else if (strstr(line, "cake") != NULL) {
                strcpy(result.qdisc_kind, "cake");
                found_any_qdisc = 1;
                qosacc_log(ctx, QMON_LOG_DEBUG, "在行%d检测到CAKE\n", line_num);
            }
        }
        
        int ret = pclose(fp);
        if (WIFEXITED(ret)) {
            ret = WEXITSTATUS(ret);
        } else {
            ret = -1;
        }
        
        if (ret != 0) {
            qosacc_log(ctx, QMON_LOG_WARN, "tc命令返回 %d\n", ret);
            result.error_code = ret;
            result.valid = 0;
            
            // 即使命令失败，也尝试获取更多信息
            qosacc_log(ctx, QMON_LOG_INFO, "尝试使用更简单的命令检测队列...\n");
            char simple_cmd[256];
            snprintf(simple_cmd, sizeof(simple_cmd), "tc qdisc show 2>&1 | grep -A1 'dev %s'", ctx->config.device);
            
            FILE* simple_fp = popen(simple_cmd, "r");
            if (simple_fp) {
                char simple_output[512];
                while (fgets(simple_output, sizeof(simple_output), simple_fp)) {
                    qosacc_log(ctx, QMON_LOG_DEBUG, "简单检测输出: %s\n", simple_output);
                }
                pclose(simple_fp);
            }
        } else if (found_root_qdisc) {
            qosacc_log(ctx, QMON_LOG_INFO, "队列算法检测成功: %s (找到根队列, 尝试 %d)\n", 
                      result.qdisc_kind, attempt + 1);
            break;
        } else if (found_any_qdisc) {
            qosacc_log(ctx, QMON_LOG_INFO, "队列算法检测成功: %s (找到任意队列, 尝试 %d)\n", 
                      result.qdisc_kind, attempt + 1);
            break;
        } else {
            qosacc_log(ctx, QMON_LOG_WARN, "在%s的输出中未找到队列类型\n", ctx->config.device);
            result.valid = 0;
        }
    }
    
    if (!result.valid) {
        qosacc_log(ctx, QMON_LOG_ERROR, "队列算法检测失败，使用默认htb\n");
        strcpy(result.qdisc_kind, "htb");
        result.valid = 1;  // 强制有效，使用默认值
    }
    
    return result;
}

/* ==================== 辅助函数：获取TC路径 ==================== */
char* get_tc_path(void) {
    static char tc_path[256] = {0};
    
    if (tc_path[0] != '\0') {
        return tc_path;
    }
    
    // 尝试常见的tc路径
    const char* possible_paths[] = {
        "/sbin/tc",
        "/usr/sbin/tc", 
        "/usr/local/sbin/tc",
        "/bin/tc",
        "/usr/bin/tc"
    };
    
    for (int i = 0; i < sizeof(possible_paths)/sizeof(possible_paths[0]); i++) {
        if (access(possible_paths[i], X_OK) == 0) {
            strncpy(tc_path, possible_paths[i], sizeof(tc_path)-1);
            tc_path[sizeof(tc_path)-1] = '\0';
            return tc_path;
        }
    }
    
    // 如果都没找到，尝试在PATH中查找
    FILE* fp = popen("which tc 2>/dev/null", "r");
    if (fp) {
        if (fgets(tc_path, sizeof(tc_path), fp)) {
            char* newline = strchr(tc_path, '\n');
            if (newline) *newline = '\0';
        }
        pclose(fp);
    }
    
    if (tc_path[0] == '\0') {
        strcpy(tc_path, "tc");  // 最后尝试直接调用
    }
    
    return tc_path;
}

int safe_popen_and_read(qosacc_context_t* ctx, const char* cmd, char* output, int output_size) {
    if (!ctx || !cmd || !output || output_size <= 0) {
        return -1;
    }
    
    output[0] = '\0';
    
    qosacc_log(ctx, QMON_LOG_DEBUG, "执行命令: %s\n", cmd);
    
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        qosacc_log(ctx, QMON_LOG_ERROR, "popen失败: %s\n", strerror(errno));
        return -1;
    }
    
    int total_read = 0;
    int read_success = 1;
    
    // 逐行读取，避免缓冲区溢出
    char buffer[256];
    while (fgets(buffer, sizeof(buffer), fp)) {
        int len = strlen(buffer);
        if (total_read + len < output_size - 1) {
            strcpy(output + total_read, buffer);
            total_read += len;
        } else {
            read_success = 0;
            break;
        }
    }
    
    output[total_read] = '\0';
    
    // 改进退出状态处理
    int ret = pclose(fp);
    if (WIFEXITED(ret)) {
        ret = WEXITSTATUS(ret);
        if (ret != 0) {
            qosacc_log(ctx, QMON_LOG_DEBUG, "命令退出，返回码: %d\n", ret);
        }
    } else if (WIFSIGNALED(ret)) {
        int sig = WTERMSIG(ret);
        qosacc_log(ctx, QMON_LOG_ERROR, "命令被信号 %d 终止 (%s)\n", sig, strsignal(sig));
        ret = 128 + sig;
    } else {
        qosacc_log(ctx, QMON_LOG_ERROR, "命令异常终止 (状态: %d)\n", ret);
        ret = -1;
    }
    
    if (!read_success) {
        qosacc_log(ctx, QMON_LOG_WARN, "输出缓冲区已满 (限制: %d字节)\n", output_size);
    }
    
    if (total_read > 0) {
        // 移除末尾的换行符
        char* newline = strchr(output, '\n');
        if (newline) *newline = '\0';
        
        if (strlen(output) > 0) {
            qosacc_log(ctx, QMON_LOG_DEBUG, "命令输出: %s\n", output);
        }
    }
    
    return ret;
}

int tc_set_bandwidth(qosacc_context_t* ctx, int bandwidth_bps) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    int bandwidth_kbps = (bandwidth_bps + 500) / 1000;
    
    if (bandwidth_kbps < 1) bandwidth_kbps = 1;
    int max_bandwidth_kbps = ctx->config.max_bandwidth_kbps;
    if (bandwidth_kbps > max_bandwidth_kbps) {
        bandwidth_kbps = max_bandwidth_kbps;
    }
    
    // 获取 TC 路径
    char* tc_path = get_tc_path();
    qosacc_log(ctx, QMON_LOG_INFO, "使用TC路径: %s\n", tc_path);
    
    // 检查是否需要重新检测队列类型
    if (strlen(ctx->detected_qdisc) == 0) {
        qdisc_detect_result_t result = safe_detect_qdisc_kind(ctx);
        if (result.valid) {
            strncpy(ctx->detected_qdisc, result.qdisc_kind, sizeof(ctx->detected_qdisc) - 1);
            ctx->detected_qdisc[sizeof(ctx->detected_qdisc) - 1] = '\0';
            qosacc_log(ctx, QMON_LOG_INFO, "检测到队列算法: %s\n", ctx->detected_qdisc);
        } else {
            qosacc_log(ctx, QMON_LOG_ERROR, "无法检测队列算法，使用默认htb\n");
            strcpy(ctx->detected_qdisc, "htb");
        }
    }
    
    if (ctx->last_tc_bw_kbps != 0) {
        int diff = bandwidth_kbps - ctx->last_tc_bw_kbps;
        if (diff < 0) diff = -diff;
        if (diff < ctx->config.min_bw_change_kbps) {
            qosacc_log(ctx, QMON_LOG_DEBUG, "跳过TC更新: 变化太小(%d -> %d kbps, 阈值=%d)\n",
                      ctx->last_tc_bw_kbps, bandwidth_kbps, ctx->config.min_bw_change_kbps);
            return QMON_OK;
        }
    }
    
    qosacc_log(ctx, QMON_LOG_INFO, "设置带宽: %d kbps (队列算法: %s)\n", 
              bandwidth_kbps, ctx->detected_qdisc);
    
    int ret = 0;
    char output[2048];
    
    if (strcmp(ctx->detected_qdisc, "hfsc") == 0) {
        // HFSC 命令格式
        char cmd[512];
        int cmd_len = snprintf(cmd, sizeof(cmd), 
                 "%s class change dev %s parent 1:0 classid 1:1 hfsc sc rate %dkbit ul rate %dkbit 2>&1",
                 tc_path, ctx->config.device, bandwidth_kbps, bandwidth_kbps);
        
        if (cmd_len >= (int)sizeof(cmd)) {
            qosacc_log(ctx, QMON_LOG_ERROR, "HFSC命令字符串过长\n");
            return QMON_ERR_SYSTEM;
        }
        
        qosacc_log(ctx, QMON_LOG_INFO, "执行HFSC命令: %s\n", cmd);
        
        ret = safe_popen_and_read(ctx, cmd, output, sizeof(output));
        
    } else if (strcmp(ctx->detected_qdisc, "cake") == 0) {
        char bandwidth_str[32];
        if (bandwidth_kbps >= 1000000) {
            double bandwidth_gbps = bandwidth_kbps / 1000000.0;
            snprintf(bandwidth_str, sizeof(bandwidth_str), "%.2fGbit", bandwidth_gbps);
        } else if (bandwidth_kbps >= 1000) {
            double bandwidth_mbps = bandwidth_kbps / 1000.0;
            snprintf(bandwidth_str, sizeof(bandwidth_str), "%.2fMbit", bandwidth_mbps);
        } else {
            snprintf(bandwidth_str, sizeof(bandwidth_str), "%dKbit", bandwidth_kbps);
        }
        
        char cmd[512];
        int cmd_len = snprintf(cmd, sizeof(cmd), 
                 "%s qdisc change dev %s root cake bandwidth %s 2>&1",
                 tc_path, ctx->config.device, bandwidth_str);
        
        if (cmd_len >= (int)sizeof(cmd)) {
            qosacc_log(ctx, QMON_LOG_ERROR, "CAKE命令字符串过长\n");
            return QMON_ERR_SYSTEM;
        }
        
        qosacc_log(ctx, QMON_LOG_INFO, "执行CAKE命令: %s\n", cmd);
        ret = safe_popen_and_read(ctx, cmd, output, sizeof(output));
        
    } else {
        // HTB 命令 - 修复的关键部分
        char cmd[512];
        
        // 首先检查 HTB 类 1:1 是否存在
        char check_cmd[256];
        snprintf(check_cmd, sizeof(check_cmd), "%s class show dev %s 2>&1", tc_path, ctx->config.device);
        
        char check_output[1024];
        int check_ret = safe_popen_and_read(ctx, check_cmd, check_output, sizeof(check_output));
        
        int class_exists = 0;
        if (check_ret == 0) {
            // 检查类 1:1 是否存在
            if (strstr(check_output, "1:1") != NULL) {
                class_exists = 1;
                qosacc_log(ctx, QMON_LOG_INFO, "检测到 HTB 类 1:1 已存在\n");
            } else {
                qosacc_log(ctx, QMON_LOG_WARN, "HTB 类 1:1 不存在\n");
            }
        }
        
        if (class_exists) {
            // 尝试不同的父类格式
            const char* parent_formats[] = {"1:0", "1:"};
            int success = 0;
            
            for (int i = 0; i < 2; i++) {
                int cmd_len = snprintf(cmd, sizeof(cmd), 
                         "%s class change dev %s parent %s classid 1:1 htb rate %dkbit ceil %dkbit 2>&1",
                         tc_path, ctx->config.device, parent_formats[i], bandwidth_kbps, bandwidth_kbps);
                
                if (cmd_len >= (int)sizeof(cmd)) {
                    qosacc_log(ctx, QMON_LOG_ERROR, "HTB命令字符串过长\n");
                    continue;
                }
                
                qosacc_log(ctx, QMON_LOG_INFO, "执行HTB命令(父类:%s): %s\n", parent_formats[i], cmd);
                
                ret = safe_popen_and_read(ctx, cmd, output, sizeof(output));
                
                if (ret == 0) {
                    success = 1;
                    qosacc_log(ctx, QMON_LOG_INFO, "HTB命令成功(父类:%s)\n", parent_formats[i]);
                    break;
                } else {
                    qosacc_log(ctx, QMON_LOG_WARN, "父类 %s 失败: 返回码=%d\n", parent_formats[i], ret);
                }
            }
            
            if (!success) {
                ret = -1;
            }
        } else {
            // 类不存在，需要先创建
            qosacc_log(ctx, QMON_LOG_INFO, "尝试创建 HTB 类 1:1\n");
            
            int cmd_len = snprintf(cmd, sizeof(cmd), 
                     "%s class add dev %s parent 1:0 classid 1:1 htb rate %dkbit ceil %dkbit 2>&1",
                     tc_path, ctx->config.device, bandwidth_kbps, bandwidth_kbps);
            
            if (cmd_len < (int)sizeof(cmd)) {
                qosacc_log(ctx, QMON_LOG_INFO, "执行创建HTB类命令: %s\n", cmd);
                ret = safe_popen_and_read(ctx, cmd, output, sizeof(output));
                
                if (ret != 0) {
                    qosacc_log(ctx, QMON_LOG_WARN, "创建HTB类失败，尝试使用父类1:\n");
                    
                    cmd_len = snprintf(cmd, sizeof(cmd), 
                             "%s class add dev %s parent 1: classid 1:1 htb rate %dkbit ceil %dkbit 2>&1",
                             tc_path, ctx->config.device, bandwidth_kbps, bandwidth_kbps);
                    
                    if (cmd_len < (int)sizeof(cmd)) {
                        ret = safe_popen_and_read(ctx, cmd, output, sizeof(output));
                    }
                }
            }
        }
    }
    
    if (ret != 0) {
        // 更详细的错误信息
        qosacc_log(ctx, QMON_LOG_ERROR, "TC命令执行失败: 返回码=%d\n", ret);
        qosacc_log(ctx, QMON_LOG_ERROR, "设备: %s, 带宽: %d kbps, 队列算法: %s\n", 
                  ctx->config.device, bandwidth_kbps, ctx->detected_qdisc);
        
        if (strlen(output) > 0) {
            qosacc_log(ctx, QMON_LOG_ERROR, "TC错误输出: %s\n", output);
        }
        
        // 测试 TC 命令是否可用
        char test_cmd[256];
        snprintf(test_cmd, sizeof(test_cmd), "%s -V 2>&1", tc_path);
        char test_output[512];
        int test_ret = safe_popen_and_read(ctx, test_cmd, test_output, sizeof(test_output));
        
        if (test_ret != 0) {
            qosacc_log(ctx, QMON_LOG_ERROR, "TC命令测试失败: %s\n", test_output);
        } else {
            qosacc_log(ctx, QMON_LOG_INFO, "TC命令可用: %s\n", test_output);
        }
        
        ctx->stats.total_errors++;
        ctx->stats.last_error_time = qosacc_time_ms();
        return QMON_ERR_SYSTEM;
    }
    
    ctx->last_tc_bw_kbps = bandwidth_kbps;
    ctx->stats.total_bandwidth_adjustments++;
    qosacc_log(ctx, QMON_LOG_INFO, "带宽设置成功: %d kbps (算法: %s)\n", 
              bandwidth_kbps, ctx->detected_qdisc);
    
    return QMON_OK;
}

int tc_controller_init(tc_controller_t* tc, qosacc_context_t* ctx) {
    if (!tc || !ctx) return QMON_ERR_MEMORY;
    
    tc->ctx = ctx;
    
    tc_core_init();
    if (rtnl_open(&rth, 0) < 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "Cannot open rtnetlink\n");
        return QMON_ERR_SYSTEM;
    }
    
    // 初始检测队列类型
    qdisc_detect_result_t result = safe_detect_qdisc_kind(ctx);
    if (result.valid) {
        strncpy(ctx->detected_qdisc, result.qdisc_kind, sizeof(ctx->detected_qdisc) - 1);
        ctx->detected_qdisc[sizeof(ctx->detected_qdisc) - 1] = '\0';
    } else {
        qosacc_log(ctx, QMON_LOG_ERROR, "队列算法检测失败，使用默认htb\n");
        strcpy(ctx->detected_qdisc, "htb");
    }
    
    // 手动验证TC配置
    qosacc_log(ctx, QMON_LOG_INFO, "手动验证TC配置...\n");
    char cmd[256];
    char output[2048];
    
    // 验证1: 查看设备的所有队列
    snprintf(cmd, sizeof(cmd), "tc qdisc show dev %s 2>&1", ctx->config.device);
    int ret = safe_popen_and_read(ctx, cmd, output, sizeof(output));
    if (ret == 0) {
        qosacc_log(ctx, QMON_LOG_INFO, "TC队列配置: %s\n", output);
        
        // 检查是否包含hfsc
        if (strstr(output, "hfsc") != NULL) {
            qosacc_log(ctx, QMON_LOG_INFO, "✓ 设备 %s 使用HFSC队列\n", ctx->config.device);
            if (strcmp(ctx->detected_qdisc, "hfsc") != 0) {
                qosacc_log(ctx, QMON_LOG_WARN, "⚠ 检测结果(%s)与实际队列(hfsc)不匹配，强制修正\n", 
                          ctx->detected_qdisc);
                strcpy(ctx->detected_qdisc, "hfsc");
            }
        } else if (strstr(output, "htb") != NULL) {
            qosacc_log(ctx, QMON_LOG_INFO, "✓ 设备 %s 使用HTB队列\n", ctx->config.device);
        } else if (strstr(output, "cake") != NULL) {
            qosacc_log(ctx, QMON_LOG_INFO, "✓ 设备 %s 使用CAKE队列\n", ctx->config.device);
        } else {
            qosacc_log(ctx, QMON_LOG_WARN, "⚠ 设备 %s 的队列类型未知\n", ctx->config.device);
        }
    } else {
        qosacc_log(ctx, QMON_LOG_WARN, "无法获取TC配置: 返回码=%d\n", ret);
    }
    
    // 验证2: 查看类别配置
    snprintf(cmd, sizeof(cmd), "tc class show dev %s 2>&1 | head -5", ctx->config.device);
    ret = safe_popen_and_read(ctx, cmd, output, sizeof(output));
    if (ret == 0) {
        qosacc_log(ctx, QMON_LOG_INFO, "TC类别配置(前5行):\n%s\n", output);
    }
    
    qosacc_log(ctx, QMON_LOG_INFO, "TC控制器初始化完成 (最终队列算法: %s)\n", ctx->detected_qdisc);
    
    return QMON_OK;
}

int tc_controller_set_bandwidth(tc_controller_t* tc, int bandwidth_bps) {
    if (!tc || !tc->ctx) return QMON_ERR_MEMORY;
    
    qosacc_context_t* ctx = tc->ctx;
    
    if (ctx->config.safe_mode) {
        qosacc_log(ctx, QMON_LOG_INFO, "安全模式: 跳过带宽设置(%d kbps)\n", 
                  bandwidth_bps / 1000);
        return QMON_OK;
    }
    
    return tc_set_bandwidth(ctx, bandwidth_bps);
}

void tc_controller_cleanup(tc_controller_t* tc) {
    if (!tc || !tc->ctx) return;
    
    qosacc_context_t* ctx = tc->ctx;
    
    if (!ctx->config.safe_mode) {
        int default_bw = ctx->config.max_bandwidth_kbps * 1000;
        tc_set_bandwidth(ctx, default_bw);
        qosacc_log(ctx, QMON_LOG_INFO, "TC控制器清理: 恢复总带宽到 %d kbps\n", 
                  ctx->config.max_bandwidth_kbps);
    }
    
    rtnl_close(&rth);
    qosacc_log(ctx, QMON_LOG_INFO, "TC控制器清理完成\n");
}

/* ==================== 运行时统计 ==================== */
void update_runtime_stats(qosacc_context_t* ctx) {
    if (!ctx) return;
    
    int64_t now = qosacc_time_ms();
    
    ctx->stats.total_ping_sent = ctx->ntransmitted;
    ctx->stats.total_ping_received = ctx->nreceived;
    ctx->stats.total_ping_lost = ctx->ntransmitted - ctx->nreceived;
    
    if (ctx->filtered_ping_time_us > ctx->stats.max_ping_time_recorded) {
        ctx->stats.max_ping_time_recorded = ctx->filtered_ping_time_us;
    }
    
    if (ctx->stats.min_ping_time_recorded == 0 || 
        (ctx->filtered_ping_time_us < ctx->stats.min_ping_time_recorded && ctx->filtered_ping_time_us > 0)) {
        ctx->stats.min_ping_time_recorded = ctx->filtered_ping_time_us;
    }
    
    ctx->stats.uptime_seconds = (now - ctx->stats.start_time_ms) / 1000;
    
    static int64_t last_stats_update = 0;
    if (now - last_stats_update > 5000) {
        qosacc_log(ctx, QMON_LOG_INFO, "运行时统计:\n");
        qosacc_log(ctx, QMON_LOG_INFO, "  运行时间: %ld秒\n", ctx->stats.uptime_seconds);
        qosacc_log(ctx, QMON_LOG_INFO, "  发送ping: %ld\n", ctx->stats.total_ping_sent);
        qosacc_log(ctx, QMON_LOG_INFO, "  接收ping: %ld\n", ctx->stats.total_ping_received);
        qosacc_log(ctx, QMON_LOG_INFO, "  丢失ping: %ld (%.1f%%)\n", 
                   ctx->stats.total_ping_lost,
                   ctx->stats.total_ping_sent > 0 ? 
                   (ctx->stats.total_ping_lost * 100.0 / ctx->stats.total_ping_sent) : 0.0);
        qosacc_log(ctx, QMON_LOG_INFO, "  带宽调整: %ld次\n", ctx->stats.total_bandwidth_adjustments);
        qosacc_log(ctx, QMON_LOG_INFO, "  总错误数: %ld\n", ctx->stats.total_errors);
        qosacc_log(ctx, QMON_LOG_INFO, "  最大ping: %ldms\n", ctx->stats.max_ping_time_recorded / 1000);
        qosacc_log(ctx, QMON_LOG_INFO, "  最小ping: %ldms\n", ctx->stats.min_ping_time_recorded / 1000);
        qosacc_log(ctx, QMON_LOG_INFO, "  心跳检查: %ld次\n", ctx->stats.total_heartbeat_checks);
        qosacc_log(ctx, QMON_LOG_INFO, "  心跳超时: %ld次\n", ctx->stats.total_heartbeat_timeouts);
        
        last_stats_update = now;
    }
}

/* ==================== 状态机 ==================== */
void state_machine_init(qosacc_context_t* ctx) {
    if (!ctx) return;
    
    ctx->state = QMON_CHK;
    ctx->ident = getpid() & 0xFFFF;
    ctx->current_limit_bps = (int)(ctx->config.max_bandwidth_kbps * 1000 * 
                                  ctx->config.safe_start_ratio);
    ctx->saved_active_limit = ctx->current_limit_bps;
    ctx->saved_realtime_limit = ctx->current_limit_bps;
    
    int64_t now = qosacc_time_ms();
    ctx->last_ping_time_ms = now;
    ctx->last_stats_time_ms = now;
    ctx->last_tc_update_time_ms = now;
    ctx->last_realtime_detect_time_ms = now;
    ctx->last_heartbeat_ms = now;
    ctx->last_runtime_stats_ms = now;
    
    memset(&ctx->ping_history, 0, sizeof(ping_history_t));
    memset(ctx->detected_qdisc, 0, sizeof(ctx->detected_qdisc));
    
    // 初始化运行时统计
    memset(&ctx->stats, 0, sizeof(runtime_stats_t));
    ctx->stats.start_time_ms = now;
    ctx->stats.max_ping_time_recorded = 0;
    ctx->stats.min_ping_time_recorded = 0;
    
    // 初始化类统计
    memset(ctx->dnstats, 0, sizeof(ctx->dnstats));
    ctx->classcnt = 0;
    ctx->errorflg = 0;
    ctx->firstflg = 1;
    ctx->DCA = 0;
    ctx->RTDCA = 0;
    ctx->pingon = 0;
    ctx->dbw_fil = 0;
    ctx->dbw_ul = ctx->config.max_bandwidth_kbps * 1000;
    
    // 初始化原子计数器
    ctx->signal_counter = 0;
}

void state_machine_check(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc) {
    if (!ctx || !pm || !tc) return;
    
    if (ctx->nreceived >= 2) {
        if (ctx->config.ping_limit_ms > 0 && !ctx->config.auto_switch_mode) {
            ctx->current_limit_bps = 0;
            tc_controller_set_bandwidth(tc, ctx->current_limit_bps);
            ctx->state = QMON_IDLE;
        } else {
            tc_controller_set_bandwidth(tc, 10000);
            ctx->nreceived = 0;
            ctx->state = QMON_INIT;
        }
    }
}

void state_machine_init_state(qosacc_context_t* ctx, tc_controller_t* tc) {
    if (!ctx || !tc) return;
    
    static int init_count = 0;
    init_count++;
    
    int needed_pings = 15000 / ctx->config.ping_interval;
    if (needed_pings <= 0) needed_pings = 1;
    
    if (init_count > needed_pings) {
        ctx->state = QMON_IDLE;
        tc_controller_set_bandwidth(tc, ctx->current_limit_bps);
        
        if (ctx->config.auto_switch_mode) {
            ctx->config.ping_limit_ms = (int)(ctx->filtered_ping_time_us * 1.1f / 1000);
        } else {
            ctx->config.ping_limit_ms = ctx->filtered_ping_time_us * 2 / 1000;
        }
        
        if (ctx->config.ping_limit_ms < 10) ctx->config.ping_limit_ms = 10;
        if (ctx->config.ping_limit_ms > 800) ctx->config.ping_limit_ms = 800;
        
        ctx->max_ping_time_us = ctx->config.ping_limit_ms * 2 * 1000;
        init_count = 0;
        
        qosacc_log(ctx, QMON_LOG_INFO, "初始化完成: ping限制=%dms\n", 
                  ctx->config.ping_limit_ms);
    }
}

void state_machine_idle(qosacc_context_t* ctx) {
    if (!ctx) return;
    
    int max_bps = ctx->config.max_bandwidth_kbps * 1000;
    if (max_bps == 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "最大带宽为0\n");
        return;
    }
    
    double utilization = (double)ctx->filtered_total_load_bps / (double)max_bps;
    
    if (utilization > ctx->config.active_threshold) {
        if (ctx->realtime_classes == 0 && ctx->config.auto_switch_mode) {
            ctx->state = QMON_ACTIVE;
            ctx->current_limit_bps = ctx->saved_active_limit;
        } else {
            ctx->state = QMON_REALTIME;
            ctx->current_limit_bps = ctx->saved_realtime_limit;
        }
        
        qosacc_log(ctx, QMON_LOG_INFO, "切换到%s状态: 利用率=%.1f%%\n",
                  (ctx->state == QMON_ACTIVE) ? "ACTIVE" : "REALTIME",
                  utilization * 100.0);
    }
}

void state_machine_active(qosacc_context_t* ctx) {
    if (!ctx) return;
    
    if (ctx->state == QMON_REALTIME) {
        ctx->saved_realtime_limit = ctx->current_limit_bps;
    } else {
        ctx->saved_active_limit = ctx->current_limit_bps;
    }
    
    int max_bps = ctx->config.max_bandwidth_kbps * 1000;
    if (max_bps == 0) {
        return;
    }
    
    double utilization = (double)ctx->filtered_total_load_bps / (double)max_bps;
    
    // 使用双精度浮点数提高精度
    if (utilization < ctx->config.idle_threshold - DOUBLE_EPSILON) {
        ctx->state = QMON_IDLE;
        qosacc_log(ctx, QMON_LOG_INFO, "切换到IDLE状态: 利用率=%.1f%%\n", 
                  utilization * 100.0);
        return;
    }
    
    int current_plimit_us = ctx->config.ping_limit_ms * 1000;
    if (current_plimit_us <= 0) {
        current_plimit_us = 10000;
    }
    
    // 使用双精度浮点数计算
    double error = (double)ctx->filtered_ping_time_us - (double)current_plimit_us;
    double error_ratio = error / (double)current_plimit_us;
    
    double adjust_factor = 1.0;
    if (error_ratio < 0.0) {
        if (ctx->filtered_total_load_bps < ctx->current_limit_bps * LOAD_THRESHOLD_FOR_DECREASE) {
            return;
        }
        adjust_factor = 1.0 - BANDWIDTH_ADJUST_RATE_NEG * error_ratio;
    } else {
        adjust_factor = 1.0 - BANDWIDTH_ADJUST_RATE_POS * (error_ratio + 0.1);
        if (adjust_factor < MIN_ADJUST_FACTOR) adjust_factor = MIN_ADJUST_FACTOR;
    }
    
    int old_limit = ctx->current_limit_bps;
    int new_limit = (int)(ctx->current_limit_bps * adjust_factor + 0.5);
    
    int min_bw = (int)(ctx->config.max_bandwidth_kbps * 1000 * ctx->config.min_bw_ratio);
    int max_bw = (int)(ctx->config.max_bandwidth_kbps * 1000 * ctx->config.max_bw_ratio);
    
    if (new_limit > max_bw) new_limit = max_bw;
    else if (new_limit < min_bw) new_limit = min_bw;
    
    int change = new_limit - old_limit;
    if (change < 0) change = -change;
    if (change > ctx->config.min_bw_change_kbps * 1000) {
        ctx->current_limit_bps = new_limit;
        qosacc_log(ctx, QMON_LOG_INFO, "带宽调整: %d -> %d kbps (误差比例=%.3f)\n",
                  old_limit / 1000, new_limit / 1000, error_ratio);
    }
    
    if (ctx->max_ping_time_us > current_plimit_us) {
        ctx->max_ping_time_us -= 100;
    }
}

void heart_beat_check(qosacc_context_t* ctx) {
    if (!ctx) return;
    
    static int64_t last_heartbeat = 0;
    int64_t now = qosacc_time_ms();
    
    if (now - last_heartbeat > HEARTBEAT_INTERVAL_MS) {
        ctx->stats.total_heartbeat_checks++;
        
        qosacc_log(ctx, QMON_LOG_DEBUG, "心跳检测: 系统运行正常\n");
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 状态: %d\n", ctx->state);
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 当前带宽: %d kbps\n", ctx->current_limit_bps / 1000);
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 当前ping: %ld ms\n", ctx->filtered_ping_time_us / 1000);
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 最大ping: %ld ms\n", ctx->max_ping_time_us / 1000);
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 已发送ping: %d\n", ctx->ntransmitted);
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 已接收ping: %d\n", ctx->nreceived);
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 流量负载: %d kbps\n", ctx->filtered_total_load_bps / 1000);
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 当前队列算法: %s\n", ctx->detected_qdisc);
        
        last_heartbeat = now;
    }
}

void state_machine_run(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc) {
    if (!ctx || !pm || !tc) return;
    
    int64_t now = qosacc_time_ms();
    
    // 心跳超时重启机制
    if (now - ctx->last_heartbeat_ms > HEARTBEAT_TIMEOUT_MS) {
        qosacc_log(ctx, QMON_LOG_ERROR, "心跳超时，系统可能无响应，触发重启逻辑\n");
        qosacc_log(ctx, QMON_LOG_ERROR, "尝试重置状态机...\n");
        
        // 重置状态机
        ctx->state = QMON_CHK;
        ctx->last_heartbeat_ms = now;
        ctx->stats.total_errors++;
        ctx->stats.total_heartbeat_timeouts++;
        ctx->stats.last_error_time = now;
        
        // 尝试重新初始化网络连接
        if (ctx->ping_socket >= 0) {
            close(ctx->ping_socket);
            ctx->ping_socket = -1;
        }
        
        if (ping_manager_init(pm, ctx) != QMON_OK) {
            qosacc_log(ctx, QMON_LOG_ERROR, "网络重新初始化失败\n");
        } else {
            qosacc_log(ctx, QMON_LOG_INFO, "网络重新初始化成功\n");
        }
    }
    
    if (ctx->reset_bw) {
        qosacc_log(ctx, QMON_LOG_INFO, "收到重置带宽信号，重置到默认值\n");
        int default_bw = ctx->config.max_bandwidth_kbps * 1000;
        tc_controller_set_bandwidth(tc, default_bw);
        ctx->reset_bw = 0;
    }
    
    if (ctx->state != QMON_EXIT) {
        int time_since_last_ping = now - ctx->last_ping_time_ms;
        if (time_since_last_ping >= ctx->config.ping_interval) {
            ping_manager_send(pm);
        }
    }
    
    if (now - ctx->last_stats_time_ms > STATS_INTERVAL_MS) {
        load_monitor_update(ctx);
        ctx->last_stats_time_ms = now;
    }
    
    if (now - ctx->last_tc_update_time_ms > CONTROL_INTERVAL_MS) {
        int ret = tc_controller_set_bandwidth(tc, ctx->current_limit_bps);
        if (ret == QMON_OK) {
            ctx->last_tc_update_time_ms = now;
        } else {
            qosacc_log(ctx, QMON_LOG_WARN, "带宽设置失败，将在下次重试\n");
        }
    }
    
    if (ctx->config.auto_switch_mode && 
        now - ctx->last_realtime_detect_time_ms > REALTIME_DETECT_MS) {
        ctx->realtime_classes = 0;
        ctx->last_realtime_detect_time_ms = now;
    }
    
    if (now - ctx->last_runtime_stats_ms > 5000) {
        update_runtime_stats(ctx);
        ctx->last_runtime_stats_ms = now;
    }
    
    heart_beat_check(ctx);
    
    switch (ctx->state) {
        case QMON_CHK:
            state_machine_check(ctx, pm, tc);
            break;
        case QMON_INIT:
            state_machine_init_state(ctx, tc);
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
int status_file_update(qosacc_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    static int64_t last_update = 0;
    int64_t now = qosacc_time_ms();
    
    if (now - last_update < 5000) {
        return QMON_OK;
    }
    
    char temp_file[512];
    snprintf(temp_file, sizeof(temp_file), "%s.tmp", ctx->config.status_file);
    
    FILE* temp_fp = fopen(temp_file, "w");
    if (!temp_fp) {
        qosacc_log(ctx, QMON_LOG_ERROR, "无法打开临时状态文件: %s\n", strerror(errno));
        return QMON_ERR_FILE;
    }
    
    // 原子写入状态文件
    fprintf(temp_fp, "状态: %d\n", ctx->state);
    fprintf(temp_fp, "当前带宽: %d kbps\n", ctx->current_limit_bps / 1000);
    fprintf(temp_fp, "当前ping: %ld ms\n", ctx->filtered_ping_time_us / 1000);
    fprintf(temp_fp, "最大ping: %ld ms\n", ctx->max_ping_time_us / 1000);
    fprintf(temp_fp, "流量负载: %d kbps\n", ctx->filtered_total_load_bps / 1000);
    fprintf(temp_fp, "已发送ping: %d\n", ctx->ntransmitted);
    fprintf(temp_fp, "已接收ping: %d\n", ctx->nreceived);
    fprintf(temp_fp, "队列算法: %s\n", ctx->detected_qdisc);
    fprintf(temp_fp, "运行时间: %ld秒\n", ctx->stats.uptime_seconds);
    fprintf(temp_fp, "总带宽调整: %ld次\n", ctx->stats.total_bandwidth_adjustments);
    fprintf(temp_fp, "总错误数: %ld\n", ctx->stats.total_errors);
    fprintf(temp_fp, "心跳检查: %ld次\n", ctx->stats.total_heartbeat_checks);
    fprintf(temp_fp, "心跳超时: %ld次\n", ctx->stats.total_heartbeat_timeouts);
    fprintf(temp_fp, "最后更新: %ld\n", (long)now);
    
    fflush(temp_fp);
    fclose(temp_fp);
    
    // 原子重命名，添加重试机制
    int retry_count = 0;
    while (rename(temp_file, ctx->config.status_file) != 0) {
        if (retry_count++ >= STATUS_FILE_RETRY_COUNT) {
            qosacc_log(ctx, QMON_LOG_ERROR, "无法重命名状态文件: %s\n", strerror(errno));
            remove(temp_file);
            return QMON_ERR_FILE;
        }
        usleep(STATUS_FILE_RETRY_DELAY_MS * 1000);
    }
    
    last_update = now;
    return QMON_OK;
}

/* ==================== 信号处理 ==================== */
void signal_handler(int sig) {
    if (sig == SIGUSR1) {
        g_reset_bw = 1;
    } else {
        g_sigterm_received = 1;
    }
}

int setup_signal_handlers(qosacc_context_t* ctx) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    
    if (sigaction(SIGTERM, &sa, NULL) < 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "设置SIGTERM处理失败: %s\n", strerror(errno));
        return QMON_ERR_SIGNAL;
    }
    
    if (sigaction(SIGINT, &sa, NULL) < 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "设置SIGINT处理失败: %s\n", strerror(errno));
        return QMON_ERR_SIGNAL;
    }
    
    if (sigaction(SIGUSR1, &sa, NULL) < 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "设置SIGUSR1处理失败: %s\n", strerror(errno));
        return QMON_ERR_SIGNAL;
    }
    
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);
    
    return QMON_OK;
}

/* ==================== 清理函数 ==================== */
void qosacc_cleanup(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc) {
    if (!ctx) return;
    
    qosacc_log(ctx, QMON_LOG_INFO, "开始清理资源...\n");
    
    if (!ctx->config.safe_mode) {
        int default_bw = ctx->config.max_bandwidth_kbps * 1000;
        tc_set_bandwidth(ctx, default_bw);
        qosacc_log(ctx, QMON_LOG_INFO, "重置TC带宽为默认值\n");
    }
    
    if (tc) {
        tc_controller_cleanup(tc);
    }
    
    if (pm) {
        ping_manager_cleanup(pm);
    }
    
    if (ctx->status_file) {
        fclose(ctx->status_file);
        ctx->status_file = NULL;
    }
    
    if (ctx->debug_log_file) {
        fclose(ctx->debug_log_file);
        ctx->debug_log_file = NULL;
    }
    
    if (ctx->ping_socket >= 0) {
        close(ctx->ping_socket);
        ctx->ping_socket = -1;
    }
    
    qosacc_log(ctx, QMON_LOG_INFO, "资源清理完成\n");
}

/* ==================== 主函数（使用poll） ==================== */
int main(int argc, char* argv[]) {
    int ret = EXIT_FAILURE;
    qosacc_context_t context = {0};
    ping_manager_t ping_mgr = {0};
    tc_controller_t tc_mgr = {0};
    
    // 情况1：无任何参数，直接提示帮助
    if (argc == 1) {
        fprintf(stderr, "qosacc: 错误: 未提供任何参数。\n");
        fprintf(stderr, "使用 'qosacc -h' 查看完整的用法说明。\n");
        return EXIT_FAILURE;
    }
    
    qosacc_config_init(&context.config);
    
    // 解析配置
    int config_result = qosacc_config_parse(&context.config, argc, argv);
    
    // 情况2：用户显式请求帮助
    if (config_result == QMON_HELP_REQUESTED) {
        fprintf(stderr, "%s", qosacc_usage);
        return EXIT_SUCCESS; // 帮助是正常功能，返回成功
    }
    
    // 情况3：配置解析发生其他错误
    if (config_result != QMON_OK) {
        fprintf(stderr, "错误: 配置解析失败。\n");
        return EXIT_FAILURE;
    }
    
    // 情况4：配置验证
    char config_error[256] = {0};
    int validation_result = qosacc_config_validate(&context.config, argc, argv, config_error, sizeof(config_error));
    
    if (validation_result != QMON_OK) {
        fprintf(stderr, "错误: %s\n", config_error);
        fprintf(stderr, "使用 'qosacc -h' 查看详细的参数要求与示例。\n");
        return EXIT_FAILURE;
    }
    
    // 验证通过，继续执行程序...
    
    if (context.config.background_mode) {
        if (daemon(0, 0) < 0) {
            perror("后台运行失败");
            return EXIT_FAILURE;
        }
        openlog("qosacc", LOG_PID, LOG_USER);
    }
    
    if (strlen(context.config.debug_log) > 0) {
        context.debug_log_file = fopen(context.config.debug_log, "a");
        if (!context.debug_log_file) {
            qosacc_log(&context, QMON_LOG_WARN, "无法打开调试日志文件: %s\n", context.config.debug_log);
        } else {
            qosacc_log(&context, QMON_LOG_INFO, "调试日志已启用: %s\n", context.config.debug_log);
        }
    }
    
    if (setup_signal_handlers(&context) != QMON_OK) {
        qosacc_log(&context, QMON_LOG_ERROR, "信号处理设置失败\n");
        goto cleanup;
    }
    
    state_machine_init(&context);
    
    char resolve_error[256];
    if (resolve_target(context.config.target, &context.target_addr, 
                       resolve_error, sizeof(resolve_error)) != QMON_OK) {
        qosacc_log(&context, QMON_LOG_ERROR, "目标地址解析失败: %s\n", resolve_error);
        goto cleanup;
    }
    
    if (ping_manager_init(&ping_mgr, &context) != QMON_OK) {
        qosacc_log(&context, QMON_LOG_ERROR, "ping管理器初始化失败\n");
        goto cleanup;
    }
    
    if (tc_controller_init(&tc_mgr, &context) != QMON_OK) {
        qosacc_log(&context, QMON_LOG_ERROR, "TC控制器初始化失败\n");
        goto cleanup;
    }
    
    if (setpriority(PRIO_PROCESS, 0, -10) < 0) {
        qosacc_log(&context, QMON_LOG_WARN, "无法设置进程优先级: %s\n", strerror(errno));
    }
	
	qosacc_log(&context, QMON_LOG_INFO, "========================================\n");
    qosacc_log(&context, QMON_LOG_INFO, "QoS监控器启动（使用poll机制）\n");
    qosacc_log(&context, QMON_LOG_INFO, "目标地址: %s\n", context.config.target);
    qosacc_log(&context, QMON_LOG_INFO, "网络接口: %s\n", context.config.device);
    qosacc_log(&context, QMON_LOG_INFO, "最大带宽: %d kbps\n", context.config.max_bandwidth_kbps);
    qosacc_log(&context, QMON_LOG_INFO, "ping间隔: %d ms\n", context.config.ping_interval);
    qosacc_log(&context, QMON_LOG_INFO, "ping限制: %d ms\n", context.config.ping_limit_ms);
    qosacc_log(&context, QMON_LOG_INFO, "队列算法: %s\n", context.detected_qdisc);  // 添加这行
    qosacc_log(&context, QMON_LOG_INFO, "TC类ID: 0x%x\n", context.config.classid);
    qosacc_log(&context, QMON_LOG_INFO, "安全模式: %s\n", context.config.safe_mode ? "是" : "否");
    qosacc_log(&context, QMON_LOG_INFO, "自动切换: %s\n", context.config.auto_switch_mode ? "是" : "否");
    qosacc_log(&context, QMON_LOG_INFO, "详细输出: %s\n", context.config.verbose ? "启用" : "禁用");
    qosacc_log(&context, QMON_LOG_INFO, "配置版本: %d\n", CONFIG_VERSION);
    qosacc_log(&context, QMON_LOG_INFO, "========================================\n");
    
    qosacc_log(&context, QMON_LOG_INFO, "开始监控循环（使用poll机制）...\n");
    
    context.state = QMON_CHK;
    context.last_heartbeat_ms = qosacc_time_ms();
    
    if (!context.config.skip_initial) {
        for (int i = 0; i < 5; i++) {
            ping_manager_send(&ping_mgr);
            usleep(context.config.ping_interval * 1000);
        }
    }
    
    // 使用poll进行事件驱动
    struct pollfd fds[1];
    fds[0].fd = context.ping_socket;
    fds[0].events = POLLIN;
    
    // 将全局标志同步到上下文
    context.sigterm = g_sigterm_received;
    context.reset_bw = g_reset_bw;
    
    while (!context.sigterm) {
        int64_t now = qosacc_time_ms();
        
        // 计算下一个定时任务的时间
        int next_timeout = context.config.ping_interval;
        
        // 计算下一个需要执行的任务时间
        int64_t next_ping = context.last_ping_time_ms + context.config.ping_interval - now;
        int64_t next_stats = context.last_stats_time_ms + STATS_INTERVAL_MS - now;
        int64_t next_tc_update = context.last_tc_update_time_ms + CONTROL_INTERVAL_MS - now;
        int64_t next_realtime_detect = context.last_realtime_detect_time_ms + REALTIME_DETECT_MS - now;
        int64_t next_heartbeat = context.last_heartbeat_ms + HEARTBEAT_INTERVAL_MS - now;
        int64_t next_status_update = 5000;  // 状态文件更新间隔5秒
        
        // 找到最小的正超时时间
        int min_timeout = POLL_TIMEOUT_MS;
        
        // 考虑check_interval配置
        int max_check_timeout = context.config.check_interval;
        if (max_check_timeout < min_timeout) {
            min_timeout = max_check_timeout;
        }
        
        if (next_ping > 0 && next_ping < min_timeout) min_timeout = next_ping;
        if (next_stats > 0 && next_stats < min_timeout) min_timeout = next_stats;
        if (next_tc_update > 0 && next_tc_update < min_timeout) min_timeout = next_tc_update;
        if (next_realtime_detect > 0 && next_realtime_detect < min_timeout) min_timeout = next_realtime_detect;
        if (next_heartbeat > 0 && next_heartbeat < min_timeout) min_timeout = next_heartbeat;
        
        // 优化poll循环计算，添加最小睡眠时间保护
        if (min_timeout <= 0) {
            min_timeout = MIN_SLEEP_MS;  // 至少等待最小睡眠时间
        } else if (min_timeout > POLL_TIMEOUT_MS) {
            min_timeout = POLL_TIMEOUT_MS;
        }
        
        int poll_ret = poll(fds, 1, min_timeout);
        
        int64_t poll_end = qosacc_time_ms();
        int poll_elapsed = poll_end - now;
        
        if (poll_ret < 0) {
            if (errno == EINTR) {
                // 更新信号标志
                context.sigterm = g_sigterm_received;
                context.reset_bw = g_reset_bw;
                context.signal_counter++;  // 修改：使用普通递增
                continue;  // 被信号中断，继续循环
            }
            qosacc_log(&context, QMON_LOG_ERROR, "poll失败: %s\n", strerror(errno));
            break;
        }
        
        if (poll_ret > 0) {
            if (fds[0].revents & POLLIN) {
                int ping_result = ping_manager_receive(&ping_mgr);
                if (ping_result < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                    qosacc_log(&context, QMON_LOG_ERROR, "接收ping时发生错误\n");
                }
            }
            
            if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
                qosacc_log(&context, QMON_LOG_ERROR, "socket错误，revents=0x%x\n", fds[0].revents);
                break;
            }
        }
        
        // 无论poll是否超时，都执行状态机
        state_machine_run(&context, &ping_mgr, &tc_mgr);
        
        status_file_update(&context);
        
        // 更新信号标志
        context.sigterm = g_sigterm_received;
        context.reset_bw = g_reset_bw;
        
        if (context.sigterm) {
            qosacc_log(&context, QMON_LOG_INFO, "收到退出信号\n");
            break;
        }
        
        if (poll_elapsed > 50) {
            qosacc_log(&context, QMON_LOG_DEBUG, "循环处理时间过长: %d ms\n", poll_elapsed);
        }
    }
    
    ret = EXIT_SUCCESS;
    
cleanup:
    qosacc_cleanup(&context, &ping_mgr, &tc_mgr);
    
    // 打印最终运行时统计
    int64_t uptime = (qosacc_time_ms() - context.stats.start_time_ms) / 1000;
    qosacc_log(&context, QMON_LOG_INFO, "最终运行时统计:\n");
    qosacc_log(&context, QMON_LOG_INFO, "  总运行时间: %ld秒\n", uptime);
    qosacc_log(&context, QMON_LOG_INFO, "  总发送ping: %ld\n", context.stats.total_ping_sent);
    qosacc_log(&context, QMON_LOG_INFO, "  总接收ping: %ld\n", context.stats.total_ping_received);
    qosacc_log(&context, QMON_LOG_INFO, "  总丢失ping: %ld\n", context.stats.total_ping_lost);
    qosacc_log(&context, QMON_LOG_INFO, "  总带宽调整: %ld次\n", context.stats.total_bandwidth_adjustments);
    qosacc_log(&context, QMON_LOG_INFO, "  总错误数: %ld\n", context.stats.total_errors);
    qosacc_log(&context, QMON_LOG_INFO, "  最大ping: %ldms\n", context.stats.max_ping_time_recorded / 1000);
    qosacc_log(&context, QMON_LOG_INFO, "  最小ping: %ldms\n", context.stats.min_ping_time_recorded / 1000);
    qosacc_log(&context, QMON_LOG_INFO, "  心跳检查: %ld次\n", context.stats.total_heartbeat_checks);
    qosacc_log(&context, QMON_LOG_INFO, "  心跳超时: %ld次\n", context.stats.total_heartbeat_timeouts);
    qosacc_log(&context, QMON_LOG_INFO, "  信号中断: %d次\n", context.signal_counter);
    
    qosacc_log(&context, QMON_LOG_INFO, "QoS监控器已退出\n");
    
    if (context.config.background_mode) {
        closelog();
    }
    
    return ret;
}