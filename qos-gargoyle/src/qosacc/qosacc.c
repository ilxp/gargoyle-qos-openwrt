/* qosacc - 基于netlink的QoS主动拥塞控制（TC库版，支持HFSC/HTB/CAKE，含实时类检测）
 * version=1.9.3
 * 功能：通过ping监控延迟，使用TC库直接调整根类的带宽，支持实时类检测（HFSC专用）
 * 状态文件目录：/tmp/qosacc.status
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
#include <sys/stat.h>
#include <float.h>
#include <time.h>
#include <ctype.h>
#include <stdatomic.h>
#include <sys/file.h>

/* TC库头文件（需安装iproute2开发包） */
#include "utils.h"
#include "tc_util.h"
#include "tc_common.h"

/* Linux内核TC头文件，用于CAKE常量 */
#include <linux/pkt_sched.h>
#ifndef TCA_CAKE_BASE_RATE
#define TCA_CAKE_BASE_RATE 1
#endif

/* ==================== 宏定义 ==================== */
#define QACC_LOG_ERROR 0
#define QACC_LOG_WARN  1
#define QACC_LOG_INFO  2
#define QACC_LOG_DEBUG 3
#define MAX_PACKET_SIZE 4096
#define PING_HISTORY_SIZE 10
#define MIN_PING_TIME_MS 1
#define MAX_PING_TIME_MS 5000
#define STATS_INTERVAL_MS 1000
#define CONTROL_INTERVAL_MS 1000
#define HEARTBEAT_INTERVAL_MS 10000
#define HEARTBEAT_TIMEOUT_MS 90000   //心跳超时阈值
#define POLL_TIMEOUT_MS 10
#define MIN_SLEEP_MS 1
#define CONFIG_VERSION 1
#define MIN_CONFIG_VERSION 1
#define MAX_CONFIG_VERSION 1
#define DETECT_QDISC_RETRY_COUNT 3
#define DETECT_QDISC_RETRY_DELAY_MS 100
#define STATUS_FILE_RETRY_COUNT 3
#define STATUS_FILE_RETRY_DELAY_MS 100
#define LOCK_RETRY_COUNT 3
#define LOCK_RETRY_DELAY_MS 50
#define COMPARE_EPSILON 1e-6
#define TC_OP_RETRY_COUNT 2      /* TC操作重试次数 */
#define TC_OP_RETRY_DELAY_MS 50 /* TC操作重试间隔 */
#define MAX_CLASSES 30            /* 最大类数量 */
#define ICMP_DATA_SIZE 56   // 标准 ping 数据长度（含时间戳）

#define MIN_PING_INTERVAL 100
#define MAX_PING_INTERVAL 5000
#define MIN_BANDWIDTH_KBPS 100
#define MAX_BANDWIDTH_KBPS 1000000
#define MIN_PING_LIMIT_MS 5
#define MAX_PING_LIMIT_MS 1000
#define MIN_BW_RATIO 0.01f
#define MAX_BW_RATIO_MAX 1.0f
#define SMOOTHING_FACTOR_MIN 0.0f
#define SMOOTHING_FACTOR_MAX 1.0f
#define EPSILON 1e-9
#define MIN_ADJUST_FACTOR 0.80f
#define MAX_ADJUST_FACTOR 1.20f
#define DEFAULT_BURST_TIME_MS 10 /* HTB burst时间（毫秒） */
#define MIN_BURST_BYTES 1600      /* 最小burst字节数（一个典型MTU） */
#define ACTIVE_BW_THRESHOLD 4000  /* 类活跃带宽阈值（bps） */

#define MIN(a,b) (((a)<(b))?(a):(b))
#define MAX(a,b) (((a)>(b))?(a):(b))

/* TC库兼容性宏 */
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

/* ==================== 返回码 ==================== */
typedef enum {
    QACC_OK = 0,
    QACC_ERR_MEMORY = -1,
    QACC_ERR_SOCKET = -2,
    QACC_ERR_FILE = -3,
    QACC_ERR_CONFIG = -4,
    QACC_ERR_SYSTEM = -5,
    QACC_ERR_SIGNAL = -6,
    QACC_ERR_TIMEOUT = -7,
    QACC_HELP_REQUESTED = -99
} qosacc_result_t;

/* ==================== 配置结构 ==================== */
typedef struct {
    int enabled;
    int ping_interval;          // ms
    int max_bandwidth_kbps;
    int ping_limit_ms;
    int realtime_ping_limit_ms; // 实时模式下的ping限制（0表示使用普通ping_limit_ms）
    int classid;                 // 未使用，保留
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
    int init_duration_ms;
    float adjust_rate_neg;
    float adjust_rate_pos;
    char root_classid[16];       // 如 "1:1" 或 "0x1:0x1"
    char target[64];
    char device[16];
    char config_file[256];
    char debug_log[256];
    char status_file[256];
    int check_interval;          // 单位：秒（代码内乘以1000转为毫秒）
} qosacc_config_t;

/* ==================== 状态枚举 ==================== */
typedef enum {
    QACC_CHK,
    QACC_INIT,
    QACC_IDLE,
    QACC_ACTIVE,
    QACC_REALTIME,
    QACC_EXIT
} qosacc_state_t;

/* 状态名称，用于输出到状态文件 */
static const char *state_names[] = {
    [QACC_CHK] = "CHK",
    [QACC_INIT] = "INIT",
    [QACC_IDLE] = "IDLE",
    [QACC_ACTIVE] = "ACTIVE",
    [QACC_REALTIME] = "REALTIME",
    [QACC_EXIT] = "EXIT"
};

/* ==================== 类统计结构 ==================== */
typedef struct class_stats_s {
    __u32 handle;                // 类handle
    int is_realtime;             // 是否为实时类（根据服务曲线判断）
    int active;                  // 当前是否活跃（带宽 > 阈值）
    __u64 bytes;                 // 上次读取的字节数
    int64_t bwtime;              // 上次读取的时间戳（ns）
    int64_t bw_flt;              // 滤波后的带宽（bps）
} class_stats_t;

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

/* ==================== 主上下文结构 ==================== */
typedef struct qosacc_context_s {
    qosacc_state_t state;
    qosacc_config_t config;
    
    // 网络相关
    int ping_socket;
    int ident;
    int ntransmitted;
    int nreceived;
    struct sockaddr_storage target_addr;   // 通用地址结构
    socklen_t target_addr_len;              // 地址长度
    
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
    int last_set_bps;               // 上次成功设置的带宽（避免重复设置）
    
    // TC相关
    struct rtnl_handle rth;        // TC库netlink句柄
    char detected_qdisc[16];
    __u32 root_qdisc_handle;       // 根qdisc的handle（用于CAKE修改或类操作的parent）
    __u32 root_class_handle;       // 根类的handle（备用，当前未用）
    
    // 类统计（仅用于HFSC实时检测）
    class_stats_t class_stats[MAX_CLASSES];
    int class_count;               // 实际类的数量
    int realtime_active;           // 当前活跃的实时类数量
    
    // 时间戳
    int64_t last_ping_time_ms;
    int64_t last_stats_time_ms;
    int64_t last_tc_update_time_ms;
    int64_t last_heartbeat_ms;
    int64_t last_runtime_stats_ms;
    int64_t last_class_stats_ms;
    
    // 文件
    FILE* status_file;
    FILE* debug_log_file;
    
    // 控制标志
    atomic_int sigterm;
    atomic_int reset_bw;
    
    // 运行时统计
    runtime_stats_t stats;
    
    // 原子操作计数器
    atomic_int signal_counter;
} qosacc_context_t;

/* ==================== 全局信号标志 ==================== */
static atomic_int g_sigterm_received = ATOMIC_VAR_INIT(0);
static atomic_int g_reset_bw = ATOMIC_VAR_INIT(0);

/* ==================== 帮助信息 ==================== */
const char qosacc_usage[] =
"qosacc - 基于ping延迟的动态QoS带宽调整器（TC库版，支持实时类检测）\n"
"版本: 1.9.2\n\n"
"用法:\n"
"  qosacc [ping间隔(ms)] [目标地址] [最大带宽(kbps)] [ping限制(ms)]\n"
"  qosacc [选项]\n\n"
"位置参数（传统用法）:\n"
"  ping间隔        100-5000 ms (默认: 200)\n"
"  目标地址        默认: 8.8.8.8\n"
"  最大带宽        100-1000000 kbps (默认: 10000)\n"
"  ping限制        5-1000 ms (默认: 20)\n\n"
"选项:\n"
"  -h, --help      显示此帮助信息\n"
"  -c <文件>       配置文件路径\n"
"  -d <设备>       网络设备名称 (默认: ifb0)\n"
"  -t <地址/域名>  ping目标 (默认: 8.8.8.8)\n"
"  -s <文件>       状态文件 (默认: /tmp/qosacc.status)\n"
"  -l <文件>       调试日志文件 (默认: /var/log/qosacc.log)\n"
"  -v              详细输出\n"
"  -b              后台运行\n"
"  -S              安全模式（不修改TC）\n"
"  -A              自动切换IDLE/ACTIVE\n"
"  -I              跳过初始测量\n"
"  -p <间隔>       设置ping间隔(ms)\n"
"  -m <带宽>       设置最大带宽(kbps)\n"
"  -P <限制>       设置ping限制(ms)\n\n"
"配置文件支持参数:\n"
"  adjust_rate_neg, adjust_rate_pos, init_duration_ms, root_classid, realtime_ping_limit_ms 等\n"
"  check_interval  状态检查间隔（秒，默认1）\n\n"
"信号:\n"
"  SIGTERM, SIGINT 安全退出\n"
"  SIGUSR1         重置带宽到最大值\n";

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
int tc_controller_update_class_stats(qosacc_context_t* ctx);

static int fetch_hfsc_class_info(qosacc_context_t* ctx);
static int fetch_class_cb(struct nlmsghdr *n, void *arg);

static __u32 parse_classid(const char* str);

void qosacc_config_init(qosacc_config_t* cfg);
int qosacc_config_parse(qosacc_config_t* cfg, int argc, char* argv[]);
int qosacc_config_validate(qosacc_config_t* cfg, int argc, char* argv[], char* error, int error_len);

void state_machine_init(qosacc_context_t* ctx);
void state_machine_run(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc);
void update_runtime_stats(qosacc_context_t* ctx);

void qosacc_cleanup(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc);

/* ==================== 辅助函数 ==================== */
int64_t qosacc_time_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        return (int64_t)tv.tv_sec * 1000LL + (int64_t)tv.tv_usec / 1000LL;
    }
    return (int64_t)ts.tv_sec * 1000LL + (int64_t)ts.tv_nsec / 1000000LL;
}

uint16_t icmp_checksum(void* data, int len) {
    uint16_t* p = (uint16_t*)data;
    uint32_t sum = 0;
    for (; len > 1; len -= 2) sum += *p++;
    if (len == 1) sum += *(uint8_t*)p;
    sum = (sum >> 16) + (sum & 0xFFFF);
    sum += (sum >> 16);
    return (uint16_t)~sum;
}

struct icmpv6_pseudo_header {
    struct in6_addr src;
    struct in6_addr dst;
    uint16_t length;
    uint8_t zero[3];
    uint8_t next_header;
};

uint16_t icmpv6_checksum(struct in6_addr* src, struct in6_addr* dst,
                         struct icmp6_hdr* icmp6, int len) {
    struct icmpv6_pseudo_header ph;
    memcpy(&ph.src, src, sizeof(struct in6_addr));
    memcpy(&ph.dst, dst, sizeof(struct in6_addr));
    ph.length = htons(len);
    memset(ph.zero, 0, 3);
    ph.next_header = IPPROTO_ICMPV6;
    uint32_t sum = 0;
    uint16_t* p = (uint16_t*)&ph;
    for (int i = 0; i < (int)sizeof(ph)/2; i++) sum += p[i];
    p = (uint16_t*)icmp6;
    for (int i = 0; i < len/2; i++) sum += p[i];
    if (len & 1) sum += ((uint8_t*)icmp6)[len-1] << 8;
    sum = (sum >> 16) + (sum & 0xFFFF);
    sum += (sum >> 16);
    return (uint16_t)~sum;
}

int resolve_target(const char* target, struct sockaddr_storage* addr, socklen_t* addr_len, char* error, int error_len) {
    struct addrinfo hints, *result = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_RAW;
    hints.ai_flags = AI_ADDRCONFIG;
    int ret = getaddrinfo(target, NULL, &hints, &result);
    if (ret != 0) {
        snprintf(error, error_len, "无法解析地址 %s: %s", target, gai_strerror(ret));
        return QACC_ERR_SYSTEM;
    }
    if (result->ai_family == AF_INET) {
        struct sockaddr_in* sin = (struct sockaddr_in*)result->ai_addr;
        memcpy(addr, sin, sizeof(struct sockaddr_in));
        *addr_len = sizeof(struct sockaddr_in);
    } else if (result->ai_family == AF_INET6) {
        struct sockaddr_in6* sin6 = (struct sockaddr_in6*)result->ai_addr;
        memcpy(addr, sin6, sizeof(struct sockaddr_in6));
        *addr_len = sizeof(struct sockaddr_in6);
    } else {
        snprintf(error, error_len, "不支持的地址族: %d", result->ai_family);
        freeaddrinfo(result);
        return QACC_ERR_SYSTEM;
    }
    freeaddrinfo(result);
    return QACC_OK;
}

/* ==================== 日志系统 ==================== */
void qosacc_log(qosacc_context_t* ctx, int level, const char* format, ...) {
    if (!ctx) return;
    if (!ctx->config.verbose && level > QACC_LOG_INFO) return;
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
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    if (ctx->config.background_mode) {
        int syslog_level = LOG_INFO;
        switch (level) {
            case QACC_LOG_ERROR: syslog_level = LOG_ERR; break;
            case QACC_LOG_WARN:  syslog_level = LOG_WARNING; break;
            case QACC_LOG_INFO:  syslog_level = LOG_INFO; break;
            case QACC_LOG_DEBUG: syslog_level = LOG_DEBUG; break;
        }
        syslog(syslog_level, "%s", buffer);
    } else {
        const char* level_str = "UNKNOWN";
        switch (level) {
            case QACC_LOG_ERROR: level_str = "ERROR"; break;
            case QACC_LOG_WARN:  level_str = "WARN"; break;
            case QACC_LOG_INFO:  level_str = "INFO"; break;
            case QACC_LOG_DEBUG: level_str = "DEBUG"; break;
        }
        if (ctx->config.verbose || level <= QACC_LOG_INFO)
            fprintf(stderr, "[%s] [%s] %s", cached_time_str, level_str, buffer);
    }
    if (ctx->debug_log_file && (ctx->config.verbose || level <= QACC_LOG_INFO)) {
        const char* level_str = "UNKNOWN";
        switch (level) {
            case QACC_LOG_ERROR: level_str = "ERROR"; break;
            case QACC_LOG_WARN:  level_str = "WARN"; break;
            case QACC_LOG_INFO:  level_str = "INFO"; break;
            case QACC_LOG_DEBUG: level_str = "DEBUG"; break;
        }
        fprintf(ctx->debug_log_file, "[%s] [%s] %s", cached_time_str, level_str, buffer);
        fflush(ctx->debug_log_file);
    }
}

/* ==================== 配置文件解析辅助 ==================== */
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
    const char* key_start = line;
    while (isspace(*key_start)) key_start++;
    const char* key_end = equal_sign - 1;
    while (key_end > key_start && isspace(*key_end)) key_end--;
    int key_len_to_copy = key_end - key_start + 1;
    if (key_len_to_copy >= key_len) key_len_to_copy = key_len - 1;
    strncpy(key, key_start, key_len_to_copy);
    key[key_len_to_copy] = '\0';
    const char* value_start = equal_sign + 1;
    while (isspace(*value_start)) value_start++;
    const char* value_end = value_start + strlen(value_start) - 1;
    while (value_end > value_start && isspace(*value_end)) value_end--;
    int value_len_to_copy = value_end - value_start + 1;
    if (value_len_to_copy >= value_len) value_len_to_copy = value_len - 1;
    strncpy(value, value_start, value_len_to_copy);
    value[value_len_to_copy] = '\0';
    return 1;
}

void qosacc_config_init(qosacc_config_t* cfg) {
    memset(cfg, 0, sizeof(qosacc_config_t));
    cfg->enabled = 1;
    cfg->ping_interval = 200;
    cfg->max_bandwidth_kbps = 10000;
    cfg->ping_limit_ms = 20;
    cfg->realtime_ping_limit_ms = 0;
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
    cfg->init_duration_ms = 15000;
    cfg->adjust_rate_neg = 0.002f;
    cfg->adjust_rate_pos = 0.004f;
    strcpy(cfg->root_classid, "1:1");
    cfg->check_interval = 1;      // 默认1秒
    strcpy(cfg->device, "ifb0");
    strcpy(cfg->target, "8.8.8.8");
    strcpy(cfg->status_file, "/tmp/qosacc.status");
    strcpy(cfg->debug_log, "/var/log/qosacc.log");
}

static int qosacc_config_parse_file(qosacc_config_t* cfg, const char* config_file) {
    FILE* fp = fopen(config_file, "r");
    if (!fp) {
        fprintf(stderr, "错误：配置文件'%s'无法打开: %s\n", config_file, strerror(errno));
        return QACC_ERR_FILE;
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
        if (line[0] == '#' || line[0] == ';' || line[0] == '\0') continue;
        if (line[0] == '[' && strchr(line, ']')) {
            char section[64];
            if (sscanf(line, "[%63[^]]]", section) == 1) {
                char* eq = strchr(section, '=');
                if (eq) {
                    char sec_key[64], sec_val[64];
                    strncpy(sec_key, section, eq - section);
                    sec_key[eq - section] = '\0';
                    strcpy(sec_val, eq + 1);
                    trim_whitespace(sec_key);
                    trim_whitespace(sec_val);
                    if (strcmp(sec_key, "device") == 0) {
                        if (strcmp(sec_val, cfg->device) == 0) {
                            in_device_section = 1;
                            cfg->enabled = 1;
                        } else {
                            in_device_section = 0;
                        }
                        continue;
                    } else {
                        in_device_section = 0;
                        continue;
                    }
                } else {
                    in_device_section = 0;
                    continue;
                }
            } else {
                in_device_section = 0;
                continue;
            }
        }
        if (in_device_section) {
            char key[64], value[64];
            if (parse_key_value(line, key, sizeof(key), value, sizeof(value))) {
                if (strcmp(key, "enabled") == 0) cfg->enabled = atoi(value);
                else if (strcmp(key, "target") == 0) strncpy(cfg->target, value, sizeof(cfg->target)-1);
                else if (strcmp(key, "ping_interval") == 0) cfg->ping_interval = atoi(value);
                else if (strcmp(key, "max_bandwidth_kbps") == 0) cfg->max_bandwidth_kbps = atoi(value);
                else if (strcmp(key, "ping_limit_ms") == 0) cfg->ping_limit_ms = atoi(value);
                else if (strcmp(key, "realtime_ping_limit_ms") == 0) cfg->realtime_ping_limit_ms = atoi(value);
                else if (strcmp(key, "safe_mode") == 0) cfg->safe_mode = atoi(value);
                else if (strcmp(key, "verbose") == 0) cfg->verbose = atoi(value);
                else if (strcmp(key, "auto_switch_mode") == 0) cfg->auto_switch_mode = atoi(value);
                else if (strcmp(key, "background_mode") == 0) cfg->background_mode = atoi(value);
                else if (strcmp(key, "skip_initial") == 0) cfg->skip_initial = atoi(value);
                else if (strcmp(key, "min_bw_change_kbps") == 0) cfg->min_bw_change_kbps = atoi(value);
                else if (strcmp(key, "min_bw_ratio") == 0) cfg->min_bw_ratio = atof(value);
                else if (strcmp(key, "max_bw_ratio") == 0) cfg->max_bw_ratio = atof(value);
                else if (strcmp(key, "smoothing_factor") == 0) cfg->smoothing_factor = atof(value);
                else if (strcmp(key, "active_threshold") == 0) cfg->active_threshold = atof(value);
                else if (strcmp(key, "idle_threshold") == 0) cfg->idle_threshold = atof(value);
                else if (strcmp(key, "safe_start_ratio") == 0) cfg->safe_start_ratio = atof(value);
                else if (strcmp(key, "init_duration_ms") == 0) cfg->init_duration_ms = atoi(value);
                else if (strcmp(key, "adjust_rate_neg") == 0) cfg->adjust_rate_neg = atof(value);
                else if (strcmp(key, "adjust_rate_pos") == 0) cfg->adjust_rate_pos = atof(value);
                else if (strcmp(key, "root_classid") == 0) strncpy(cfg->root_classid, value, sizeof(cfg->root_classid)-1);
                else if (strcmp(key, "debug_log") == 0) strncpy(cfg->debug_log, value, sizeof(cfg->debug_log)-1);
                else if (strcmp(key, "status_file") == 0) strncpy(cfg->status_file, value, sizeof(cfg->status_file)-1);
                else if (strcmp(key, "check_interval") == 0) cfg->check_interval = atoi(value);  // 单位秒
                else if (strcmp(key, "config_version") == 0) {
                    int version = atoi(value);
                    if (version < MIN_CONFIG_VERSION || version > MAX_CONFIG_VERSION) {
                        fprintf(stderr, "配置版本不兼容: %d (支持 %d-%d)\n", version, MIN_CONFIG_VERSION, MAX_CONFIG_VERSION);
                        fclose(fp);
                        return QACC_ERR_CONFIG;
                    }
                }
            }
        }
    }
    fclose(fp);
    if (!cfg->enabled) fprintf(stderr, "警告：未找到设备 '%s' 的启用配置。\n", cfg->device);
    return QACC_OK;
}

int qosacc_config_parse(qosacc_config_t* cfg, int argc, char* argv[]) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "-help") == 0 || strcmp(argv[i], "--help") == 0)
            return QACC_HELP_REQUESTED;
    }
    qosacc_config_init(cfg);
    int config_file_provided = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) {
            char* config_file = argv[++i];
            strncpy(cfg->config_file, config_file, sizeof(cfg->config_file)-1);
            int ret = qosacc_config_parse_file(cfg, config_file);
            if (ret != QACC_OK) return ret;
            config_file_provided = 1;
            break;
        }
    }
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0) { i++; continue; }
        else if (strcmp(argv[i], "-d") == 0 && i + 1 < argc) strncpy(cfg->device, argv[++i], sizeof(cfg->device)-1);
        else if (strcmp(argv[i], "-t") == 0 && i + 1 < argc) strncpy(cfg->target, argv[++i], sizeof(cfg->target)-1);
        else if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) strncpy(cfg->status_file, argv[++i], sizeof(cfg->status_file)-1);
        else if (strcmp(argv[i], "-l") == 0 && i + 1 < argc) strncpy(cfg->debug_log, argv[++i], sizeof(cfg->debug_log)-1);
        else if (strcmp(argv[i], "-v") == 0) cfg->verbose = 1;
        else if (strcmp(argv[i], "-b") == 0) cfg->background_mode = 1;
        else if (strcmp(argv[i], "-S") == 0) cfg->safe_mode = 1;
        else if (strcmp(argv[i], "-A") == 0) cfg->auto_switch_mode = 1;
        else if (strcmp(argv[i], "-I") == 0) cfg->skip_initial = 1;
        else if (strcmp(argv[i], "-p") == 0 && i + 1 < argc) cfg->ping_interval = atoi(argv[++i]);
        else if (strcmp(argv[i], "-m") == 0 && i + 1 < argc) cfg->max_bandwidth_kbps = atoi(argv[++i]);
        else if (strcmp(argv[i], "-P") == 0 && i + 1 < argc) cfg->ping_limit_ms = atoi(argv[++i]);
        else if (i == 1 && argc >= 4 && !config_file_provided) {
            cfg->ping_interval = atoi(argv[1]);
            if (argc >= 2) strncpy(cfg->target, argv[2], sizeof(cfg->target)-1);
            if (argc >= 3) cfg->max_bandwidth_kbps = atoi(argv[3]);
            if (argc >= 4) cfg->ping_limit_ms = atoi(argv[4]);
            i += 3;
        }
    }
    // 将 check_interval 从秒转为毫秒，用于后续超时计算
    cfg->check_interval *= 1000;
    return QACC_OK;
}

int qosacc_config_validate(qosacc_config_t* cfg, int argc, char* argv[], char* error, int error_len) {
    if (argc == 1) { snprintf(error, error_len, "未提供任何参数"); return QACC_ERR_CONFIG; }
    if (!cfg->enabled) { snprintf(error, error_len, "设备 '%s' 未启用", cfg->device); return QACC_ERR_CONFIG; }
    if (cfg->ping_interval < MIN_PING_INTERVAL || cfg->ping_interval > MAX_PING_INTERVAL) {
        snprintf(error, error_len, "ping间隔 %d 超出范围 [%d,%d]", cfg->ping_interval, MIN_PING_INTERVAL, MAX_PING_INTERVAL);
        return QACC_ERR_CONFIG;
    }
    if (cfg->max_bandwidth_kbps < MIN_BANDWIDTH_KBPS || cfg->max_bandwidth_kbps > MAX_BANDWIDTH_KBPS) {
        snprintf(error, error_len, "最大带宽 %d 超出范围 [%d,%d] kbps", cfg->max_bandwidth_kbps, MIN_BANDWIDTH_KBPS, MAX_BANDWIDTH_KBPS);
        return QACC_ERR_CONFIG;
    }
    if (cfg->ping_limit_ms < MIN_PING_LIMIT_MS || cfg->ping_limit_ms > MAX_PING_LIMIT_MS) {
        snprintf(error, error_len, "ping限制 %d 超出范围 [%d,%d] ms", cfg->ping_limit_ms, MIN_PING_LIMIT_MS, MAX_PING_LIMIT_MS);
        return QACC_ERR_CONFIG;
    }
    if (cfg->realtime_ping_limit_ms != 0 && (cfg->realtime_ping_limit_ms < MIN_PING_LIMIT_MS || cfg->realtime_ping_limit_ms > MAX_PING_LIMIT_MS)) {
        snprintf(error, error_len, "实时ping限制 %d 超出范围 [%d,%d] ms", cfg->realtime_ping_limit_ms, MIN_PING_LIMIT_MS, MAX_PING_LIMIT_MS);
        return QACC_ERR_CONFIG;
    }
    if (strlen(cfg->target) == 0) { snprintf(error, error_len, "目标地址不能为空"); return QACC_ERR_CONFIG; }
    if (strlen(cfg->device) == 0) { snprintf(error, error_len, "设备名不能为空"); return QACC_ERR_CONFIG; }
    if (cfg->min_bw_ratio < MIN_BW_RATIO || cfg->min_bw_ratio > MAX_BW_RATIO_MAX) {
        snprintf(error, error_len, "最小带宽比例 %.2f 超出范围 [%.2f,%.2f]", cfg->min_bw_ratio, MIN_BW_RATIO, MAX_BW_RATIO_MAX);
        return QACC_ERR_CONFIG;
    }
    if (cfg->max_bw_ratio < MIN_BW_RATIO || cfg->max_bw_ratio > MAX_BW_RATIO_MAX) {
        snprintf(error, error_len, "最大带宽比例 %.2f 超出范围 [%.2f,%.2f]", cfg->max_bw_ratio, MIN_BW_RATIO, MAX_BW_RATIO_MAX);
        return QACC_ERR_CONFIG;
    }
    if (cfg->smoothing_factor < SMOOTHING_FACTOR_MIN - EPSILON || cfg->smoothing_factor > SMOOTHING_FACTOR_MAX + EPSILON) {
        snprintf(error, error_len, "平滑因子 %.2f 超出范围 [%.1f,%.1f]", cfg->smoothing_factor, SMOOTHING_FACTOR_MIN, SMOOTHING_FACTOR_MAX);
        return QACC_ERR_CONFIG;
    }
    float min_bw_kbps = cfg->max_bandwidth_kbps * cfg->min_bw_ratio;
    if (min_bw_kbps < MIN_BANDWIDTH_KBPS - EPSILON) {
        snprintf(error, error_len, "最小带宽 %.1f kbps 低于允许的最小值 %d kbps，请调整 min_bw_ratio", min_bw_kbps, MIN_BANDWIDTH_KBPS);
        return QACC_ERR_CONFIG;
    }
    // 检查 root_classid 格式有效性
    if (parse_classid(cfg->root_classid) == 0) {
        snprintf(error, error_len, "无效的根类ID格式: %s (应为类似 1:1 或 0x1:0x1)", cfg->root_classid);
        return QACC_ERR_CONFIG;
    }
    return QACC_OK;
}

/* ==================== Ping管理器 ==================== */
struct ping_manager_s {
    qosacc_context_t* ctx;
    char packet[MAX_PACKET_SIZE];
};

int ping_manager_init(ping_manager_t* pm, qosacc_context_t* ctx) {
    pm->ctx = ctx;
    int af = ctx->target_addr.ss_family;
    int protocol;
    if (af == AF_INET)
        protocol = IPPROTO_ICMP;
    else if (af == AF_INET6)
        protocol = IPPROTO_ICMPV6;
    else {
        qosacc_log(ctx, QACC_LOG_ERROR, "未知地址族 %d\n", af);
        return QACC_ERR_SOCKET;
    }

    ctx->ping_socket = socket(af, SOCK_RAW, protocol);
    if (ctx->ping_socket < 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "创建ping套接字失败: %s\n", strerror(errno));
        ctx->ping_socket = -1;
        return QACC_ERR_SOCKET;
    }

    int ttl = 64;
    setsockopt(ctx->ping_socket, IPPROTO_IP, IP_TTL, &ttl, sizeof(ttl));
    int timeout = 2000;
    setsockopt(ctx->ping_socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    int flags = fcntl(ctx->ping_socket, F_GETFL, 0);
    if (flags >= 0) fcntl(ctx->ping_socket, F_SETFL, flags | O_NONBLOCK);
    
    // 增加接收缓冲区大小
    int bufsize = 256 * 1024;
    setsockopt(ctx->ping_socket, SOL_SOCKET, SO_RCVBUF, &bufsize, sizeof(bufsize));
    
    // 绑定套接字到指定设备
    if (setsockopt(ctx->ping_socket, SOL_SOCKET, SO_BINDTODEVICE,
                   ctx->config.device, strlen(ctx->config.device)) < 0) {
        qosacc_log(ctx, QACC_LOG_WARN, "绑定设备失败: %s\n", strerror(errno));
    } else {
        qosacc_log(ctx, QACC_LOG_INFO, "成功绑定套接字到设备 %s\n", ctx->config.device);
    }

    // 对于IPv6，设置内核自动填充校验和
    if (af == AF_INET6) {
        int offset = 2; // ICMPv6校验和字段在头部偏移2字节
        if (setsockopt(ctx->ping_socket, IPPROTO_IPV6, IPV6_CHECKSUM, &offset, sizeof(offset)) < 0) {
            qosacc_log(ctx, QACC_LOG_WARN, "设置IPV6_CHECKSUM失败: %s\n", strerror(errno));
        }
    }
    return QACC_OK;
}

int ping_manager_send(ping_manager_t* pm) {
    qosacc_context_t* ctx = pm->ctx;
    if (ctx->ping_socket < 0) return QACC_ERR_SOCKET;

    // 清零缓冲区前64字节（ICMP头 + 数据）
    memset(pm->packet, 0, 64);

    int cc = 0;
    if (ctx->target_addr.ss_family == AF_INET6) {
        struct icmp6_hdr* icp6 = (struct icmp6_hdr*)pm->packet;
        icp6->icmp6_type = ICMP6_ECHO_REQUEST;
        icp6->icmp6_code = 0;
        icp6->icmp6_id = htons(ctx->ident);
        icp6->icmp6_seq = htons(ctx->ntransmitted);

        // 数据部分：时间戳 + 填充
        struct timeval* tv = (struct timeval*)(pm->packet + sizeof(struct icmp6_hdr));
        gettimeofday(tv, NULL);
        char *data = (char*)tv;
        for (int i = sizeof(struct timeval); i < ICMP_DATA_SIZE; i++) {
            data[i] = i & 0xFF;
        }

        cc = sizeof(struct icmp6_hdr) + ICMP_DATA_SIZE;  // 总长度 64
        icp6->icmp6_cksum = 0;  // 内核自动填充
    } else {
        struct icmp* icp = (struct icmp*)pm->packet;
        icp->icmp_type = ICMP_ECHO;
        icp->icmp_code = 0;
        icp->icmp_id = htons(ctx->ident);
        icp->icmp_seq = htons(ctx->ntransmitted);

        // 数据部分：时间戳 + 填充
        struct timeval* tv = (struct timeval*)icp->icmp_data;
        gettimeofday(tv, NULL);
        char *data = (char*)icp->icmp_data;
        for (int i = sizeof(struct timeval); i < ICMP_DATA_SIZE; i++) {
            data[i] = i & 0xFF;  // 填充剩余字节
        }

        cc = 8 + ICMP_DATA_SIZE;  // ICMP头8字节 + 数据56字节 = 64
        icp->icmp_cksum = icmp_checksum(icp, cc);
    }

    ctx->ntransmitted++;
    int ret = sendto(ctx->ping_socket, pm->packet, cc, 0,
                     (struct sockaddr*)&ctx->target_addr, ctx->target_addr_len);
    if (ret < 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "发送ping失败: %s (errno=%d)\n", strerror(errno), errno);
        return QACC_ERR_SOCKET;
    }
    ctx->last_ping_time_ms = qosacc_time_ms();
    qosacc_log(ctx, QACC_LOG_INFO, "成功发送ping seq=%d, ident=%d, 长度=%d\n",
               ctx->ntransmitted-1, ctx->ident, cc);
    return QACC_OK;
}

int ping_manager_receive(ping_manager_t* pm) {
    qosacc_context_t* ctx = pm->ctx;
    char buf[MAX_PACKET_SIZE];
    struct sockaddr_storage from;
    socklen_t fromlen = sizeof(from);
    int cc = recvfrom(ctx->ping_socket, buf, sizeof(buf), 0, (struct sockaddr*)&from, &fromlen);
    if (cc < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            qosacc_log(ctx, QACC_LOG_DEBUG, "recvfrom返回EAGAIN，无数据\n");
            return 0;
        }
        qosacc_log(ctx, QACC_LOG_ERROR, "接收ping失败: %s (errno=%d)\n", strerror(errno), errno);
        return QACC_ERR_SOCKET;
    }
    qosacc_log(ctx, QACC_LOG_INFO, "接收到 %d 字节，来自 %s\n", cc,
               from.ss_family == AF_INET ? "IPv4" : "IPv6");

    struct ip* ip = NULL;
    struct icmp* icp = NULL;
    struct icmp6_hdr* icp6 = NULL;
    struct timeval tv, *tp = NULL;
    int hlen, triptime = 0;
    uint16_t seq = 0;
    gettimeofday(&tv, NULL);

    if (from.ss_family == AF_INET6) {
        if (cc < (int)sizeof(struct icmp6_hdr)) {
            qosacc_log(ctx, QACC_LOG_WARN, "IPv6包太短，丢弃\n");
            return 0;
        }
        icp6 = (struct icmp6_hdr*)buf;
        if (icp6->icmp6_type != ICMP6_ECHO_REPLY) {
            qosacc_log(ctx, QACC_LOG_DEBUG, "忽略非ECHO_REPLY IPv6包 type=%d\n", icp6->icmp6_type);
            return 0;
        }
        uint16_t rcv_id = ntohs(icp6->icmp6_id);
        if (rcv_id != ctx->ident) {
            qosacc_log(ctx, QACC_LOG_DEBUG, "忽略IPv6包：ident不匹配 (期待 %d, 收到 %d)\n", ctx->ident, rcv_id);
            return 0;
        }
        // 由于设置了 IPV6_CHECKSUM，内核已处理校验和，无需手动检查
        seq = ntohs(icp6->icmp6_seq);
        if (cc >= (int)(sizeof(struct icmp6_hdr) + sizeof(struct timeval)))
            tp = (struct timeval*)(buf + sizeof(struct icmp6_hdr));
    } else {
        ip = (struct ip*)buf;
        hlen = ip->ip_hl << 2;
        if (cc < hlen + 8) {
            qosacc_log(ctx, QACC_LOG_WARN, "IPv4包太短，丢弃\n");
            return 0;
        }
        icp = (struct icmp*)(buf + hlen);
        if (icp->icmp_type != ICMP_ECHOREPLY) {
            qosacc_log(ctx, QACC_LOG_DEBUG, "忽略非ECHOREPLY IPv4包 type=%d\n", icp->icmp_type);
            return 0;
        }

        // ========== 关键修复：转换网络字节序 ==========
        uint16_t rcv_id = ntohs(icp->icmp_id);
        if (rcv_id != ctx->ident) {
            qosacc_log(ctx, QACC_LOG_DEBUG, "忽略IPv4包：ident不匹配 (期待 %d, 收到 %d)\n", ctx->ident, rcv_id);
            return 0;
        }

        // 校验和验证（使用原始包中的校验和，计算前清零）
        uint16_t saved = icp->icmp_cksum;
        icp->icmp_cksum = 0;
        uint16_t calc = icmp_checksum(icp, cc - hlen);
        if (saved != calc) {
            // 注意：打印 seq 时也需转换
            qosacc_log(ctx, QACC_LOG_WARN, "ICMP校验和不匹配，丢弃包 (seq=%d)\n", ntohs(icp->icmp_seq));
            return 0;
        }
        // 恢复校验和（非必须，但可保持缓冲区原样）
        icp->icmp_cksum = saved;

        seq = ntohs(icp->icmp_seq);  // 转换序列号
        if (cc >= hlen + 8 + (int)sizeof(struct timeval))
            tp = (struct timeval*)&icp->icmp_data[0];
    }

    // 序号窗口检查（seq 已转为主机序）
    uint16_t expected = (uint16_t)(ctx->ntransmitted);
    uint16_t diff = (expected - seq) & 0xFFFF;
    if (diff == 0 || diff > PING_HISTORY_SIZE * 2) {
        qosacc_log(ctx, QACC_LOG_DEBUG, "忽略包：seq=%d 超出窗口 (当前发送=%d, diff=%u)\n", seq, ctx->ntransmitted, diff);
        return 0;
    }

    ctx->nreceived++;
    if (tp) {
        triptime = tv.tv_sec - tp->tv_sec;
        triptime = triptime * 1000 + (tv.tv_usec - tp->tv_usec) / 1000;
    }
    if (triptime < MIN_PING_TIME_MS) triptime = MIN_PING_TIME_MS;
    if (triptime > MAX_PING_TIME_MS) triptime = MAX_PING_TIME_MS;

    ctx->raw_ping_time_us = triptime * 1000;
    if (ctx->raw_ping_time_us > ctx->max_ping_time_us)
        ctx->max_ping_time_us = ctx->raw_ping_time_us;

    // 更新历史平滑值
    ping_history_t* hist = &ctx->ping_history;
    hist->times[hist->index] = ctx->raw_ping_time_us;
    hist->index = (hist->index + 1) % PING_HISTORY_SIZE;
    if (hist->count < PING_HISTORY_SIZE) hist->count++;

    if (hist->count == 1)
        hist->smoothed = ctx->raw_ping_time_us;
    else
        hist->smoothed = hist->smoothed * (1.0 - ctx->config.smoothing_factor) + ctx->raw_ping_time_us * ctx->config.smoothing_factor;

    ctx->filtered_ping_time_us = (int64_t)hist->smoothed;
    qosacc_log(ctx, QACC_LOG_INFO, "收到ping seq=%d, 时间=%dms, 平滑=%ldms\n", seq, triptime, ctx->filtered_ping_time_us / 1000);
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
    static unsigned long long last_rx_bytes = 0;
    static int64_t last_read_time = 0;
    char line[256];
    unsigned long long rx_bytes = 0;
    int found = 0;
    FILE* fp = fopen("/proc/net/dev", "r");
    if (!fp) {
        qosacc_log(ctx, QACC_LOG_ERROR, "无法打开 /proc/net/dev: %s\n", strerror(errno));
        return QACC_ERR_FILE;
    }
    for (int i = 0; i < 2; i++) if (!fgets(line, sizeof(line), fp)) break;
    while (fgets(line, sizeof(line), fp)) {
        char* colon = strchr(line, ':');
        if (!colon) continue;
        *colon = '\0';
        char* ifname = line;
        while (*ifname == ' ') ifname++;
        if (strcmp(ifname, ctx->config.device) == 0) {
            if (sscanf(colon + 1, "%llu", &rx_bytes) == 1) found = 1;
            break;
        }
    }
    fclose(fp);
    if (!found) {
        qosacc_log(ctx, QACC_LOG_ERROR, "接口 %s 未找到\n", ctx->config.device);
        return QACC_ERR_SYSTEM;
    }
    int64_t now = qosacc_time_ms();
    if (last_read_time > 0 && last_rx_bytes > 0 && rx_bytes >= last_rx_bytes) {
        int time_diff = (int)(now - last_read_time);
        if (time_diff > 0) {
            unsigned long long bytes_diff = rx_bytes - last_rx_bytes;
            int bps = (int)((bytes_diff * 8000) / time_diff);
            if (bps < 0) bps = 0;
            float alpha = 0.1f;
            ctx->filtered_total_load_bps += (int)((bps - ctx->filtered_total_load_bps) * alpha);
            int max_bps = ctx->config.max_bandwidth_kbps * 1000;
            if (ctx->filtered_total_load_bps < 0) ctx->filtered_total_load_bps = 0;
            else if (ctx->filtered_total_load_bps > max_bps) ctx->filtered_total_load_bps = max_bps;
            qosacc_log(ctx, QACC_LOG_DEBUG, "流量: 原始=%d bps, 平滑=%d bps\n", bps, ctx->filtered_total_load_bps);
        }
    }
    last_rx_bytes = rx_bytes;
    last_read_time = now;
    return QACC_OK;
}

/* ==================== TC控制器（使用TC库） ==================== */
struct tc_controller_s {
    qosacc_context_t* ctx;
};

static __u32 parse_classid(const char* str) {
    char *copy, *major_str, *minor_str, *endptr;
    unsigned long major, minor;

    if (!str) return 0;
    copy = strdup(str);
    if (!copy) {
        return 0; // strdup失败
    }

    major_str = copy;
    minor_str = strchr(copy, ':');
    if (!minor_str) {
        free(copy);
        return 0;
    }
    *minor_str++ = '\0';

    major = strtoul(major_str, &endptr, 0);
    if (*endptr != '\0') {
        free(copy);
        return 0;
    }
    minor = strtoul(minor_str, &endptr, 0);
    if (*endptr != '\0') {
        free(copy);
        return 0;
    }

    free(copy);
    return (major << 16) | (minor & 0xFFFF);
}

typedef struct {
    qosacc_context_t* ctx;
    char detected_qdisc[16];
    __u32 root_qdisc_handle;      // 根qdisc的handle
    __u32 root_class_handle;      // 根类的handle（若存在）
    int found_root_qdisc;
    int found_root_class;
    int parse_realtime;
    // 记录第一个遇到的 qdisc（若未找到根则回退）
    char first_qdisc[16];
    __u32 first_handle;
    int found_any;
    int target_ifindex;  // 目标设备的 ifindex
} detect_qdisc_ctx_t;

/* 队列检测回调（用于识别根队列） */
static int detect_qdisc_cb(struct nlmsghdr *n, void *arg) {
    detect_qdisc_ctx_t* dctx = (detect_qdisc_ctx_t*)arg;
    struct tcmsg *t = NLMSG_DATA(n);
    int len = n->nlmsg_len;
    struct rtattr * tb[TCA_MAX+1];

    // 过滤非目标设备的消息
    if (dctx->target_ifindex != 0 && t->tcm_ifindex != dctx->target_ifindex) {
        return 0;
    }

    if (n->nlmsg_type != RTM_NEWTCLASS && n->nlmsg_type != RTM_NEWQDISC)
        return 0;

    len -= NLMSG_LENGTH(sizeof(*t));
    if (len < 0) return -1;

    memset(tb, 0, sizeof(tb));
    parse_rtattr(tb, TCA_MAX, TCA_RTA(t), len);

    if (tb[TCA_KIND] == NULL) return 0;
    char* kind = (char*)RTA_DATA(tb[TCA_KIND]);

    qosacc_log(dctx->ctx, QACC_LOG_DEBUG, "detect_qdisc_cb: ifindex=%d, kind=%s, parent=0x%x, handle=0x%x\n",
               t->tcm_ifindex, kind, t->tcm_parent, t->tcm_handle);

    // 记录第一个遇到的 qdisc（非类）
    if (!dctx->found_any && n->nlmsg_type == RTM_NEWQDISC) {
        strcpy(dctx->first_qdisc, kind);
        dctx->first_handle = t->tcm_handle;
        dctx->found_any = 1;
    }

    int is_root = 0;
    if (n->nlmsg_type == RTM_NEWQDISC && (t->tcm_parent == TC_H_ROOT || t->tcm_parent == 0))
        is_root = 1;
    if (n->nlmsg_type == RTM_NEWTCLASS && t->tcm_parent == TC_H_ROOT)
        is_root = 1;

    if (is_root) {
        qosacc_log(dctx->ctx, QACC_LOG_DEBUG, "detect_qdisc_cb: Found root %s\n", kind);
        if (n->nlmsg_type == RTM_NEWQDISC) {
            strcpy(dctx->detected_qdisc, kind);
            dctx->root_qdisc_handle = t->tcm_handle;
            dctx->found_root_qdisc = 1;
            // 如果是 noqueue，继续遍历（期待后面有真正的队列）
            if (strcmp(kind, "noqueue") == 0) {
                return 0;
            } else {
                return -1; // 找到真正的qdisc根，停止遍历
            }
        } else { // RTM_NEWTCLASS
            dctx->root_class_handle = t->tcm_handle;
            dctx->found_root_class = 1;
            // 继续遍历，可能还有qdisc信息
        }
    }

    // 如果要求解析实时类且当前是类消息且队列为hfsc，则记录类的实时性
    if (dctx->parse_realtime && n->nlmsg_type == RTM_NEWTCLASS && strcmp(kind, "hfsc") == 0) {
        qosacc_context_t* ctx = dctx->ctx;
        if (ctx->class_count < MAX_CLASSES) {
            class_stats_t* cs = &ctx->class_stats[ctx->class_count];
            memset(cs, 0, sizeof(class_stats_t));
            cs->handle = t->tcm_handle;
            cs->bwtime = qosacc_time_ms() * 1000000LL;

            if (tb[TCA_OPTIONS]) {
                struct rtattr *tbs[TCA_HFSC_MAX + 1];
                parse_rtattr_nested(tbs, TCA_HFSC_MAX, tb[TCA_OPTIONS]);
                struct tc_service_curve *sc = NULL;
                if (tbs[TCA_HFSC_RSC] && (RTA_PAYLOAD(tbs[TCA_HFSC_RSC]) >= sizeof(*sc))) {
                    sc = RTA_DATA(tbs[TCA_HFSC_RSC]);
                    cs->is_realtime |= (sc && sc->m1 != 0);
                }
                if (tbs[TCA_HFSC_FSC] && (RTA_PAYLOAD(tbs[TCA_HFSC_FSC]) >= sizeof(*sc))) {
                    sc = RTA_DATA(tbs[TCA_HFSC_FSC]);
                    cs->is_realtime |= (sc && sc->m1 != 0);
                }
            }
            ctx->class_count++;
        }
    }

    return 0;
}

/* 专用回调：仅用于获取HFSC类信息（不提前返回） */
static int fetch_class_cb(struct nlmsghdr *n, void *arg) {
    detect_qdisc_ctx_t* dctx = (detect_qdisc_ctx_t*)arg;
    struct tcmsg *t = NLMSG_DATA(n);
    int len = n->nlmsg_len;
    struct rtattr * tb[TCA_MAX+1];

    if (n->nlmsg_type != RTM_NEWTCLASS)
        return 0;

    len -= NLMSG_LENGTH(sizeof(*t));
    if (len < 0) return -1;

    memset(tb, 0, sizeof(tb));
    parse_rtattr(tb, TCA_MAX, TCA_RTA(t), len);

    if (tb[TCA_KIND] == NULL) return 0;
    char* kind = (char*)RTA_DATA(tb[TCA_KIND]);

    // 只处理 hfsc 类
    if (strcmp(kind, "hfsc") != 0)
        return 0;

    qosacc_context_t* ctx = dctx->ctx;
    if (ctx->class_count < MAX_CLASSES) {
        class_stats_t* cs = &ctx->class_stats[ctx->class_count];
        memset(cs, 0, sizeof(class_stats_t));
        cs->handle = t->tcm_handle;
        cs->bwtime = qosacc_time_ms() * 1000000LL;

        if (tb[TCA_OPTIONS]) {
            struct rtattr *tbs[TCA_HFSC_MAX + 1];
            parse_rtattr_nested(tbs, TCA_HFSC_MAX, tb[TCA_OPTIONS]);
            struct tc_service_curve *sc = NULL;
            if (tbs[TCA_HFSC_RSC] && (RTA_PAYLOAD(tbs[TCA_HFSC_RSC]) >= sizeof(*sc))) {
                sc = RTA_DATA(tbs[TCA_HFSC_RSC]);
                cs->is_realtime |= (sc && sc->m1 != 0);
            }
            if (tbs[TCA_HFSC_FSC] && (RTA_PAYLOAD(tbs[TCA_HFSC_FSC]) >= sizeof(*sc))) {
                sc = RTA_DATA(tbs[TCA_HFSC_FSC]);
                cs->is_realtime |= (sc && sc->m1 != 0);
            }
        }
        ctx->class_count++;
    }
    return 0;
}

static qosacc_result_t detect_qdisc_kind_tc(qosacc_context_t* ctx, int parse_realtime) {
    struct rtnl_handle rth;
    if (rtnl_open(&rth, 0) < 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "无法打开rtnetlink\n");
        return QACC_ERR_SYSTEM;
    }

    ll_init_map(&rth);
    int ifindex = ll_name_to_index(ctx->config.device);
    if (ifindex == 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "找不到设备 %s\n", ctx->config.device);
        rtnl_close(&rth);
        return QACC_ERR_SYSTEM;
    }

    detect_qdisc_ctx_t dctx;
    memset(&dctx, 0, sizeof(dctx));
    dctx.ctx = ctx;
    dctx.parse_realtime = parse_realtime;
    dctx.target_ifindex = ifindex;

    struct tcmsg t;
    memset(&t, 0, sizeof(t));
    t.tcm_family = AF_UNSPEC;
    t.tcm_ifindex = ifindex;

    // 先查询qdisc
    if (rtnl_dump_request(&rth, RTM_GETQDISC, &t, sizeof(t)) < 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "无法发送qdisc dump请求\n");
        rtnl_close(&rth);
        return QACC_ERR_SYSTEM;
    }

    if (dump_filter(&rth, detect_qdisc_cb, &dctx) < 0 && errno != EINTR) {
        qosacc_log(ctx, QACC_LOG_DEBUG, "qdisc dump未找到根队列，尝试类dump\n");
    }

    if (dctx.found_root_qdisc) {
        strcpy(ctx->detected_qdisc, dctx.detected_qdisc);
        ctx->root_qdisc_handle = dctx.root_qdisc_handle;
        // 可能还有根类信息，继续查询类
    }

    // 如果没找到根qdisc，但找到了至少一个qdisc，则使用第一个作为根（fallback）
    if (!dctx.found_root_qdisc && dctx.found_any) {
        strcpy(ctx->detected_qdisc, dctx.first_qdisc);
        ctx->root_qdisc_handle = dctx.first_handle;
        qosacc_log(ctx, QACC_LOG_INFO, "未找到根队列，使用第一个检测到的队列: %s (handle 0x%x)\n", ctx->detected_qdisc, ctx->root_qdisc_handle);
    }

    // 重新打开rtnl句柄，查询类
    rtnl_close(&rth);
    if (rtnl_open(&rth, 0) < 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "无法重新打开rtnetlink\n");
        return QACC_ERR_SYSTEM;
    }
    memset(&t, 0, sizeof(t));
    t.tcm_family = AF_UNSPEC;
    t.tcm_ifindex = ifindex;
    if (rtnl_dump_request(&rth, RTM_GETTCLASS, &t, sizeof(t)) < 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "无法发送类dump请求\n");
        rtnl_close(&rth);
        return QACC_ERR_SYSTEM;
    }

    // 重用dctx，但不清空root_qdisc_handle
    dctx.found_root_class = 0;
    if (dump_filter(&rth, detect_qdisc_cb, &dctx) < 0 && errno != EINTR) {
        qosacc_log(ctx, QACC_LOG_DEBUG, "类dump未找到根类\n");
    }

    if (dctx.found_root_class) {
        ctx->root_class_handle = dctx.root_class_handle;
        qosacc_log(ctx, QACC_LOG_INFO, "检测到根类: handle 0x%x\n", ctx->root_class_handle);
    }

    rtnl_close(&rth);

    // 确定最终检测到的队列类型
    if (ctx->detected_qdisc[0] == '\0') {
        strcpy(ctx->detected_qdisc, "unknown");
        return QACC_ERR_SYSTEM;
    }
    return QACC_OK;
}

static int fetch_hfsc_class_info(qosacc_context_t* ctx) {
    struct rtnl_handle rth;
    if (rtnl_open(&rth, 0) < 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "无法打开rtnetlink获取HFSC类信息\n");
        return QACC_ERR_SYSTEM;
    }

    ll_init_map(&rth);
    int ifindex = ll_name_to_index(ctx->config.device);
    if (ifindex == 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "找不到设备 %s\n", ctx->config.device);
        rtnl_close(&rth);
        return QACC_ERR_SYSTEM;
    }

    struct tcmsg t;
    memset(&t, 0, sizeof(t));
    t.tcm_family = AF_UNSPEC;
    t.tcm_ifindex = ifindex;

    if (rtnl_dump_request(&rth, RTM_GETTCLASS, &t, sizeof(t)) < 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "无法发送类dump请求\n");
        rtnl_close(&rth);
        return QACC_ERR_SYSTEM;
    }

    detect_qdisc_ctx_t dctx;
    memset(&dctx, 0, sizeof(dctx));
    dctx.ctx = ctx;
    dctx.parse_realtime = 1;  // 需要解析实时类
    if (dump_filter(&rth, fetch_class_cb, &dctx) < 0 && errno != EINTR) {
        qosacc_log(ctx, QACC_LOG_WARN, "类dump解析HFSC类信息失败\n");
        rtnl_close(&rth);
        return QACC_ERR_SYSTEM;
    }
    rtnl_close(&rth);
    return QACC_OK;
}

/* 用于传递更新类统计所需数据的结构体 */
typedef struct {
    class_stats_t *tmp_stats;
    int *tmp_count;
    int64_t now_ns;
} update_class_ctx_t;

/* 类统计更新回调（独立函数） - 修复：正确提取bytes字段 */
static int update_class_cb(struct nlmsghdr *n, void *arg) {
    update_class_ctx_t *uctx = (update_class_ctx_t*)arg;
    struct tcmsg *t = NLMSG_DATA(n);
    int len = n->nlmsg_len;
    struct rtattr * tb[TCA_MAX+1];
    if (n->nlmsg_type != RTM_NEWTCLASS) return 0;
    len -= NLMSG_LENGTH(sizeof(*t));
    if (len < 0) return -1;
    memset(tb, 0, sizeof(tb));
    parse_rtattr(tb, TCA_MAX, TCA_RTA(t), len);
    if (tb[TCA_KIND] == NULL) return 0;
    char* kind = (char*)RTA_DATA(tb[TCA_KIND]);
    if (strcmp(kind, "hfsc") != 0) return 0;
    if (*(uctx->tmp_count) >= MAX_CLASSES) return 0;

    __u64 bytes = 0;
    if (tb[TCA_STATS2]) {
        // 修复：直接使用 struct tc_stats *，避免依赖未定义的 struct tc_stats2
        struct tc_stats *st = (struct tc_stats *)RTA_DATA(tb[TCA_STATS2]);
        bytes = st->bytes;
    } else if (tb[TCA_STATS]) {
        struct tc_stats *st = RTA_DATA(tb[TCA_STATS]);
        bytes = st->bytes;
    } else {
        return 0;
    }

    class_stats_t *cs = &uctx->tmp_stats[*(uctx->tmp_count)];
    cs->handle = t->tcm_handle;
    cs->bytes = bytes;
    cs->bwtime = uctx->now_ns;
    (*(uctx->tmp_count))++;
    return 0;
}

int tc_controller_update_class_stats(qosacc_context_t* ctx) {
    if (strcmp(ctx->detected_qdisc, "hfsc") != 0) {
        return QACC_OK;
    }

    struct rtnl_handle rth;
    if (rtnl_open(&rth, 0) < 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "无法打开rtnetlink更新类统计\n");
        return QACC_ERR_SYSTEM;
    }

    ll_init_map(&rth);
    int ifindex = ll_name_to_index(ctx->config.device);
    if (ifindex == 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "找不到设备 %s\n", ctx->config.device);
        rtnl_close(&rth);
        return QACC_ERR_SYSTEM;
    }

    struct tcmsg t;
    memset(&t, 0, sizeof(t));
    t.tcm_family = AF_UNSPEC;
    t.tcm_ifindex = ifindex;

    if (rtnl_dump_request(&rth, RTM_GETTCLASS, &t, sizeof(t)) < 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "无法发送类dump请求\n");
        rtnl_close(&rth);
        return QACC_ERR_SYSTEM;
    }

    class_stats_t tmp_stats[MAX_CLASSES];
    int tmp_count = 0;
    int64_t now_ns = qosacc_time_ms() * 1000000LL;

    update_class_ctx_t uctx = { .tmp_stats = tmp_stats, .tmp_count = &tmp_count, .now_ns = now_ns };

    if (dump_filter(&rth, update_class_cb, &uctx) < 0) {
        qosacc_log(ctx, QACC_LOG_WARN, "类dump失败\n");
        rtnl_close(&rth);
        return QACC_ERR_SYSTEM;
    }
    rtnl_close(&rth);

    // 如果类数量发生变化，重新获取类信息
    if (tmp_count != ctx->class_count) {
        qosacc_log(ctx, QACC_LOG_INFO, "类数量变化 %d -> %d，重新获取HFSC类信息\n", ctx->class_count, tmp_count);
        ctx->class_count = 0;
        if (fetch_hfsc_class_info(ctx) != QACC_OK) {
            qosacc_log(ctx, QACC_LOG_ERROR, "重新获取HFSC类信息失败\n");
        }
        return QACC_OK;
    }

    // 先将所有类标记为不活跃，避免残留
    for (int i = 0; i < ctx->class_count; i++) {
        ctx->class_stats[i].active = 0;
    }
    ctx->realtime_active = 0;

    // 将临时数据合并到ctx->class_stats中，并计算带宽和活跃度
    for (int i = 0; i < ctx->class_count; i++) {
        class_stats_t* cs = &ctx->class_stats[i];
        for (int j = 0; j < tmp_count; j++) {
            if (tmp_stats[j].handle == cs->handle) {
                int64_t time_diff = tmp_stats[j].bwtime - cs->bwtime;
                if (time_diff > 0) {
                    __u64 byte_diff = tmp_stats[j].bytes - cs->bytes;
                    unsigned __int128 bw128 = (unsigned __int128)byte_diff * 8000000000ULL;
                    int64_t bw = (int64_t)(bw128 / time_diff);
                    float alpha = 0.1f;
                    cs->bw_flt = (int64_t)((bw - cs->bw_flt) * alpha + cs->bw_flt);
                }
                cs->bytes = tmp_stats[j].bytes;
                cs->bwtime = tmp_stats[j].bwtime;

                cs->active = (cs->bw_flt > ACTIVE_BW_THRESHOLD) ? 1 : 0;
                if (cs->is_realtime && cs->active) {
                    ctx->realtime_active++;
                }
                break;
            }
        }
    }

    return QACC_OK;
}

static int modify_class_bandwidth(qosacc_context_t* ctx, __u32 rate_bps) {
    struct {
        struct nlmsghdr n;
        struct tcmsg t;
        char buf[4096];
    } req;

    int retries = TC_OP_RETRY_COUNT;
    int last_ret = 0;

    while (retries-- > 0) {
        // 如果收到退出信号，立即返回失败
        if (atomic_load(&ctx->sigterm)) {
            qosacc_log(ctx, QACC_LOG_INFO, "退出信号，中止TC操作\n");
            return QACC_ERR_SYSTEM;
        }

        memset(&req, 0, sizeof(req));
        req.n.nlmsg_len = NLMSG_LENGTH(sizeof(struct tcmsg));
        req.n.nlmsg_flags = NLM_F_REQUEST | NLM_F_REPLACE;
        req.n.nlmsg_type = RTM_NEWTCLASS;
        req.t.tcm_family = AF_UNSPEC;

        __u32 handle = parse_classid(ctx->config.root_classid);
        if (handle == 0) {
            qosacc_log(ctx, QACC_LOG_ERROR, "无效的根类ID: %s\n", ctx->config.root_classid);
            return QACC_ERR_CONFIG;
        }
        req.t.tcm_handle = handle;
        req.t.tcm_parent = ctx->root_qdisc_handle ? ctx->root_qdisc_handle : TC_H_ROOT;

        ll_init_map(&ctx->rth);
        req.t.tcm_ifindex = ll_name_to_index(ctx->config.device);
        if (req.t.tcm_ifindex == 0) {
            qosacc_log(ctx, QACC_LOG_ERROR, "找不到设备 %s\n", ctx->config.device);
            return QACC_ERR_SYSTEM;
        }

        if (strcmp(ctx->detected_qdisc, "hfsc") == 0) {
            addattr_l(&req.n, sizeof(req), TCA_KIND, "hfsc", strlen("hfsc")+1);
            struct rtattr *tail = NLMSG_TAIL(&req.n);
            addattr_l(&req.n, sizeof(req), TCA_OPTIONS, NULL, 0);
            struct tc_service_curve sc;
            memset(&sc, 0, sizeof(sc));
            sc.m2 = rate_bps / 8;
#ifdef TCA_HFSC_SC
            addattr_l(&req.n, sizeof(req), TCA_HFSC_SC, &sc, sizeof(sc));
            addattr_l(&req.n, sizeof(req), TCA_HFSC_UL, &sc, sizeof(sc));
#else
            addattr_l(&req.n, sizeof(req), TCA_HFSC_USC, &sc, sizeof(sc));
#endif
            tail->rta_len = (void*)NLMSG_TAIL(&req.n) - (void*)tail;
        } else if (strcmp(ctx->detected_qdisc, "htb") == 0) {
            addattr_l(&req.n, sizeof(req), TCA_KIND, "htb", strlen("htb")+1);
            struct rtattr *tail = NLMSG_TAIL(&req.n);
            addattr_l(&req.n, sizeof(req), TCA_OPTIONS, NULL, 0);
            struct tc_htb_opt opt;
            memset(&opt, 0, sizeof(opt));
            __u32 rate_bytes = rate_bps / 8;
            __u32 burst_bytes = rate_bytes * DEFAULT_BURST_TIME_MS / 1000;
            if (burst_bytes < MIN_BURST_BYTES) burst_bytes = MIN_BURST_BYTES;
            opt.rate.rate = rate_bytes;
            opt.ceil.rate = rate_bytes;
            opt.buffer = burst_bytes;
            opt.cbuffer = burst_bytes;
            addattr_l(&req.n, sizeof(req), TCA_HTB_PARMS, &opt, sizeof(opt));
            tail->rta_len = (void*)NLMSG_TAIL(&req.n) - (void*)tail;
        } else {
            qosacc_log(ctx, QACC_LOG_ERROR, "不支持的类类型: %s\n", ctx->detected_qdisc);
            return QACC_ERR_SYSTEM;
        }

        int ret = talk(&ctx->rth, &req.n, NULL);
        if (ret == 0) {
            qosacc_log(ctx, QACC_LOG_INFO, "TC类带宽设置成功: %d bps\n", rate_bps);
            return QACC_OK;
        }

        last_ret = ret;
        qosacc_log(ctx, QACC_LOG_WARN, "修改TC类失败 (ret=%d), 剩余重试次数 %d\n", last_ret, retries);
        if (retries > 0) usleep(TC_OP_RETRY_DELAY_MS * 1000);
    }

    qosacc_log(ctx, QACC_LOG_ERROR, "修改TC类失败，已重试 %d 次，最后返回 %d\n", TC_OP_RETRY_COUNT, last_ret);
    return QACC_ERR_SYSTEM;
}

static int modify_qdisc_bandwidth(qosacc_context_t* ctx, __u32 rate_bps) {
    struct {
        struct nlmsghdr n;
        struct tcmsg t;
        char buf[4096];
    } req;

    int retries = TC_OP_RETRY_COUNT;
    int last_ret = 0;

    while (retries-- > 0) {
        if (atomic_load(&ctx->sigterm)) {
            qosacc_log(ctx, QACC_LOG_INFO, "退出信号，中止TC操作\n");
            return QACC_ERR_SYSTEM;
        }

        memset(&req, 0, sizeof(req));
        req.n.nlmsg_len = NLMSG_LENGTH(sizeof(struct tcmsg));
        req.n.nlmsg_flags = NLM_F_REQUEST | NLM_F_REPLACE;
        req.n.nlmsg_type = RTM_NEWQDISC;
        req.t.tcm_family = AF_UNSPEC;

        if (ctx->root_qdisc_handle != 0) {
            req.t.tcm_handle = ctx->root_qdisc_handle;
        } else {
            req.t.tcm_handle = TC_H_MAKE(1, 0);
        }
        req.t.tcm_parent = TC_H_ROOT;

        ll_init_map(&ctx->rth);
        req.t.tcm_ifindex = ll_name_to_index(ctx->config.device);
        if (req.t.tcm_ifindex == 0) {
            qosacc_log(ctx, QACC_LOG_ERROR, "找不到设备 %s\n", ctx->config.device);
            return QACC_ERR_SYSTEM;
        }

        addattr_l(&req.n, sizeof(req), TCA_KIND, "cake", strlen("cake")+1);
        struct rtattr *tail = NLMSG_TAIL(&req.n);
        addattr_l(&req.n, sizeof(req), TCA_OPTIONS, NULL, 0);
        __u32 rate_bytes = rate_bps / 8;
        addattr_l(&req.n, sizeof(req), TCA_CAKE_BASE_RATE, &rate_bytes, sizeof(rate_bytes));
        tail->rta_len = (void*)NLMSG_TAIL(&req.n) - (void*)tail;

        int ret = talk(&ctx->rth, &req.n, NULL);
        if (ret == 0) {
            qosacc_log(ctx, QACC_LOG_INFO, "CAKE带宽设置成功: %d bps\n", rate_bps);
            return QACC_OK;
        }

        last_ret = ret;
        qosacc_log(ctx, QACC_LOG_WARN, "修改CAKE qdisc失败 (ret=%d), 剩余重试次数 %d\n", last_ret, retries);
        if (retries > 0) usleep(TC_OP_RETRY_DELAY_MS * 1000);
    }

    qosacc_log(ctx, QACC_LOG_ERROR, "修改CAKE qdisc失败，已重试 %d 次，最后返回 %d\n", TC_OP_RETRY_COUNT, last_ret);
    return QACC_ERR_SYSTEM;
}

int tc_controller_init(tc_controller_t* tc, qosacc_context_t* ctx) {
    tc->ctx = ctx;
    if (rtnl_open(&ctx->rth, 0) < 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "无法打开rtnetlink\n");
        return QACC_ERR_SYSTEM;
    }

    int parse_realtime = 1;
    if (detect_qdisc_kind_tc(ctx, parse_realtime) != QACC_OK) {
        qosacc_log(ctx, QACC_LOG_ERROR, "队列检测失败，无法继续\n");
        rtnl_close(&ctx->rth);
        tc->ctx = NULL;
        return QACC_ERR_SYSTEM;
    }

    // 检查队列是否支持动态带宽调整（包括 noqueue）
    if (strcmp(ctx->detected_qdisc, "fq_codel") == 0 || 
        strcmp(ctx->detected_qdisc, "pfifo_fast") == 0 ||
        strcmp(ctx->detected_qdisc, "noqueue") == 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "队列 %s 不支持动态带宽调整，程序退出\n", ctx->detected_qdisc);
        rtnl_close(&ctx->rth);
        tc->ctx = NULL;
        return QACC_ERR_CONFIG;
    }

    // 如果是HFSC，获取实时类信息
    if (strcmp(ctx->detected_qdisc, "hfsc") == 0) {
        ctx->class_count = 0;
        if (fetch_hfsc_class_info(ctx) != QACC_OK) {
            qosacc_log(ctx, QACC_LOG_ERROR, "无法获取HFSC类信息，实时类检测将失效\n");
        } else {
            qosacc_log(ctx, QACC_LOG_INFO, "成功获取 %d 个HFSC类\n", ctx->class_count);
        }
    }

    ctx->realtime_active = 0;
    ctx->last_class_stats_ms = qosacc_time_ms();
    ctx->last_set_bps = 0;  // 初始化为0，确保第一次设置生效

    qosacc_log(ctx, QACC_LOG_INFO, "TC控制器初始化成功 (队列: %s, 根qdisc handle: 0x%x, 类数量: %d)\n",
               ctx->detected_qdisc, ctx->root_qdisc_handle, ctx->class_count);
    return QACC_OK;
}

int tc_controller_set_bandwidth(tc_controller_t* tc, int bandwidth_bps) {
    if (!tc || !tc->ctx) return QACC_ERR_MEMORY;
    qosacc_context_t* ctx = tc->ctx;
    if (ctx->config.safe_mode) {
        qosacc_log(ctx, QACC_LOG_INFO, "安全模式: 跳过带宽设置 (%d kbps)\n", bandwidth_bps/1000);
        return QACC_OK;
    }
    if (bandwidth_bps < 1) bandwidth_bps = 1;

    // 避免重复设置相同带宽
    if (bandwidth_bps == ctx->last_set_bps) {
        return QACC_OK;
    }

    int ret;
    if (strcmp(ctx->detected_qdisc, "cake") == 0) {
        ret = modify_qdisc_bandwidth(ctx, bandwidth_bps);
    } else if (strcmp(ctx->detected_qdisc, "hfsc") == 0 || strcmp(ctx->detected_qdisc, "htb") == 0) {
        ret = modify_class_bandwidth(ctx, bandwidth_bps);
    } else {
        qosacc_log(ctx, QACC_LOG_ERROR, "不支持的队列类型: %s\n", ctx->detected_qdisc);
        return QACC_ERR_SYSTEM;
    }

    if (ret == QACC_OK) {
        ctx->last_set_bps = bandwidth_bps;
    }
    return ret;
}

void tc_controller_cleanup(tc_controller_t* tc) {
    if (!tc || !tc->ctx) return;
    qosacc_context_t* ctx = tc->ctx;
    if (!ctx->config.safe_mode) {
        int default_bw = ctx->config.max_bandwidth_kbps * 1000;
        if (strcmp(ctx->detected_qdisc, "cake") == 0)
            modify_qdisc_bandwidth(ctx, default_bw);
        else
            modify_class_bandwidth(ctx, default_bw);
        qosacc_log(ctx, QACC_LOG_INFO, "恢复带宽到 %d kbps\n", ctx->config.max_bandwidth_kbps);
    }
    rtnl_close(&ctx->rth);
}

/* ==================== 运行时统计 ==================== */
void update_runtime_stats(qosacc_context_t* ctx) {
    int64_t now = qosacc_time_ms();
    ctx->stats.total_ping_sent = ctx->ntransmitted;
    ctx->stats.total_ping_received = ctx->nreceived;
    // 防止 nreceived 意外大于 ntransmitted
    if (ctx->ntransmitted >= ctx->nreceived)
        ctx->stats.total_ping_lost = ctx->ntransmitted - ctx->nreceived;
    else
        ctx->stats.total_ping_lost = 0;
    if (ctx->filtered_ping_time_us > ctx->stats.max_ping_time_recorded)
        ctx->stats.max_ping_time_recorded = ctx->filtered_ping_time_us;
    if (ctx->stats.min_ping_time_recorded == 0 || (ctx->filtered_ping_time_us < ctx->stats.min_ping_time_recorded && ctx->filtered_ping_time_us > 0))
        ctx->stats.min_ping_time_recorded = ctx->filtered_ping_time_us;
    ctx->stats.uptime_seconds = (now - ctx->stats.start_time_ms) / 1000;
    static int64_t last = 0;
    if (now - last > 5000) {
        qosacc_log(ctx, QACC_LOG_INFO,
            "统计: 运行%ld秒, 发送%ld, 接收%ld, 丢失%ld(%.1f%%), 调整%ld次, 最大ping%ldms, 最小ping%ldms, 实时类活跃: %d\n",
            ctx->stats.uptime_seconds,
            ctx->stats.total_ping_sent,
            ctx->stats.total_ping_received,
            ctx->stats.total_ping_lost,
            ctx->stats.total_ping_sent ? (ctx->stats.total_ping_lost * 100.0 / ctx->stats.total_ping_sent) : 0.0,
            ctx->stats.total_bandwidth_adjustments,
            ctx->stats.max_ping_time_recorded / 1000,
            ctx->stats.min_ping_time_recorded / 1000,
            ctx->realtime_active);
        last = now;
    }
}

/* ==================== 状态机 ==================== */
void state_machine_init(qosacc_context_t* ctx) {
    ctx->state = QACC_CHK;
    ctx->ident = getpid() & 0xFFFF;
    ctx->current_limit_bps = (int)(ctx->config.max_bandwidth_kbps * 1000 * ctx->config.safe_start_ratio);
    ctx->saved_active_limit = ctx->current_limit_bps;
    ctx->saved_realtime_limit = ctx->current_limit_bps;
    int64_t now = qosacc_time_ms();
    ctx->last_ping_time_ms = now;
    ctx->last_stats_time_ms = now;
    ctx->last_tc_update_time_ms = now;
    ctx->last_heartbeat_ms = now;
    ctx->last_runtime_stats_ms = now;
    ctx->last_class_stats_ms = now;
    memset(&ctx->ping_history, 0, sizeof(ping_history_t));
    memset(ctx->detected_qdisc, 0, sizeof(ctx->detected_qdisc));
    memset(&ctx->stats, 0, sizeof(runtime_stats_t));
    ctx->stats.start_time_ms = now;
    atomic_store(&ctx->signal_counter, 0);
    atomic_store(&ctx->sigterm, 0);
    atomic_store(&ctx->reset_bw, 0);
}

void state_machine_check(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc) {
    if (ctx->nreceived >= 2) {
        if (ctx->config.ping_limit_ms > 0 && !ctx->config.auto_switch_mode) {
            // 进入IDLE，但不改变当前带宽
            ctx->state = QACC_IDLE;
        } else {
            // 使用当前限制带宽作为初始值，而不是硬编码10000bps
            tc_controller_set_bandwidth(tc, ctx->current_limit_bps);
            ctx->nreceived = 0;
            ctx->state = QACC_INIT;
        }
    }
}

void state_machine_init_state(qosacc_context_t* ctx, tc_controller_t* tc) {
    static int init_count = 0;
    init_count++;
    int needed_pings = ctx->config.init_duration_ms / ctx->config.ping_interval;
    if (needed_pings <= 0) needed_pings = 1;
    if (init_count > needed_pings) {
        ctx->state = QACC_IDLE;
        tc_controller_set_bandwidth(tc, ctx->current_limit_bps);
        if (ctx->config.auto_switch_mode)
            ctx->config.ping_limit_ms = (int)(ctx->filtered_ping_time_us * 1.1f / 1000);
        else
            ctx->config.ping_limit_ms = ctx->filtered_ping_time_us * 2 / 1000;
        if (ctx->config.ping_limit_ms < 10) ctx->config.ping_limit_ms = 10;
        if (ctx->config.ping_limit_ms > 800) ctx->config.ping_limit_ms = 800;
        ctx->max_ping_time_us = ctx->config.ping_limit_ms * 2 * 1000;
        init_count = 0;
        qosacc_log(ctx, QACC_LOG_INFO, "初始化完成, ping限制=%dms\n", ctx->config.ping_limit_ms);
    }
}

void state_machine_idle(qosacc_context_t* ctx) {
    int max_bps = ctx->config.max_bandwidth_kbps * 1000;
    if (max_bps == 0) return;
    double util = (double)ctx->filtered_total_load_bps / (double)max_bps;
    if (util > ctx->config.active_threshold) {
        if (ctx->realtime_active > 0) {
            ctx->state = QACC_REALTIME;
            if (ctx->saved_realtime_limit == (int)(ctx->config.max_bandwidth_kbps * 1000 * ctx->config.safe_start_ratio)) {
                ctx->saved_realtime_limit = ctx->current_limit_bps;
            }
            ctx->current_limit_bps = ctx->saved_realtime_limit;
        } else {
            ctx->state = QACC_ACTIVE;
            if (ctx->saved_active_limit == (int)(ctx->config.max_bandwidth_kbps * 1000 * ctx->config.safe_start_ratio)) {
                ctx->saved_active_limit = ctx->current_limit_bps;
            }
            ctx->current_limit_bps = ctx->saved_active_limit;
        }
        qosacc_log(ctx, QACC_LOG_INFO, "进入%s状态, 利用率=%.1f%%, 实时类活跃=%d\n",
                   (ctx->state == QACC_ACTIVE) ? "ACTIVE" : "REALTIME",
                   util * 100.0, ctx->realtime_active);
    }
}

void state_machine_active_common(qosacc_context_t* ctx) {
    if (ctx->state == QACC_ACTIVE) {
        ctx->saved_active_limit = ctx->current_limit_bps;
    } else {
        ctx->saved_realtime_limit = ctx->current_limit_bps;
    }

    int max_bps = ctx->config.max_bandwidth_kbps * 1000;
    if (max_bps == 0) return;

    double util = (double)ctx->filtered_total_load_bps / (double)max_bps;
    if (util < ctx->config.idle_threshold - COMPARE_EPSILON) {
        ctx->state = QACC_IDLE;
        qosacc_log(ctx, QACC_LOG_INFO, "进入IDLE状态, 利用率=%.1f%%\n", util * 100.0);
        return;
    }

    if (ctx->state == QACC_ACTIVE && ctx->realtime_active > 0) {
        ctx->saved_active_limit = ctx->current_limit_bps;
        ctx->state = QACC_REALTIME;
        if (ctx->saved_realtime_limit == (int)(ctx->config.max_bandwidth_kbps * 1000 * ctx->config.safe_start_ratio)) {
            ctx->saved_realtime_limit = ctx->current_limit_bps;
        }
        ctx->current_limit_bps = ctx->saved_realtime_limit;
        qosacc_log(ctx, QACC_LOG_INFO, "检测到实时类，切换到REALTIME模式\n");
    } else if (ctx->state == QACC_REALTIME && ctx->realtime_active == 0) {
        ctx->saved_realtime_limit = ctx->current_limit_bps;
        ctx->state = QACC_ACTIVE;
        if (ctx->saved_active_limit == (int)(ctx->config.max_bandwidth_kbps * 1000 * ctx->config.safe_start_ratio)) {
            ctx->saved_active_limit = ctx->current_limit_bps;
        }
        ctx->current_limit_bps = ctx->saved_active_limit;
        qosacc_log(ctx, QACC_LOG_INFO, "实时类消失，切换回ACTIVE模式\n");
    }

    int target_us;
    if (ctx->state == QACC_REALTIME && ctx->config.realtime_ping_limit_ms > 0) {
        target_us = ctx->config.realtime_ping_limit_ms * 1000;
    } else {
        target_us = ctx->config.ping_limit_ms * 1000;
    }
    if (target_us <= 0) target_us = 10000;

    double error = (double)ctx->filtered_ping_time_us - (double)target_us;
    double error_ratio = error / target_us;
    double adjust = 1.0;
    if (error < 0) {
        adjust = 1.0 + ctx->config.adjust_rate_neg * (-error_ratio);
        if (adjust > MAX_ADJUST_FACTOR) adjust = MAX_ADJUST_FACTOR;
    } else {
        adjust = 1.0 - ctx->config.adjust_rate_pos * error_ratio;
        if (adjust < MIN_ADJUST_FACTOR) adjust = MIN_ADJUST_FACTOR;
    }
    int old_limit = ctx->current_limit_bps;
    int new_limit = (int)(old_limit * adjust + 0.5);
    int min_bw = (int)(ctx->config.max_bandwidth_kbps * 1000 * ctx->config.min_bw_ratio);
    int max_bw = (int)(ctx->config.max_bandwidth_kbps * 1000 * ctx->config.max_bw_ratio);
    new_limit = MAX(min_bw, MIN(new_limit, max_bw));
    if (abs(new_limit - old_limit) >= ctx->config.min_bw_change_kbps * 1000) {
        ctx->current_limit_bps = new_limit;
        ctx->stats.total_bandwidth_adjustments++;
        qosacc_log(ctx, QACC_LOG_INFO, "带宽调整: %d -> %d kbps (误差=%.3f, 模式=%s)\n",
                   old_limit/1000, new_limit/1000, error_ratio,
                   (ctx->state == QACC_ACTIVE) ? "ACTIVE" : "REALTIME");
    }
}

void state_machine_active(qosacc_context_t* ctx) {
    state_machine_active_common(ctx);
}

void state_machine_realtime(qosacc_context_t* ctx) {
    state_machine_active_common(ctx);
}

void heart_beat_check(qosacc_context_t* ctx) {
    static int64_t last = 0;
    int64_t now = qosacc_time_ms();
    if (now - last > HEARTBEAT_INTERVAL_MS) {
        ctx->stats.total_heartbeat_checks++;
        qosacc_log(ctx, QACC_LOG_DEBUG,
            "心跳: 状态=%d, 带宽=%d kbps, ping=%ld ms, 负载=%d kbps, 队列=%s, 实时类活跃=%d\n",
            ctx->state, ctx->current_limit_bps/1000, ctx->filtered_ping_time_us/1000,
            ctx->filtered_total_load_bps/1000, ctx->detected_qdisc, ctx->realtime_active);
        last = now;
        ctx->last_heartbeat_ms = now;   // 更新心跳时间戳，避免超时误报
    }
}

void state_machine_run(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc) {
    int64_t now = qosacc_time_ms();
    if (now - ctx->last_heartbeat_ms > HEARTBEAT_TIMEOUT_MS) {
        qosacc_log(ctx, QACC_LOG_ERROR, "心跳超时，重置状态机\n");
        ctx->state = QACC_CHK;
        ctx->last_heartbeat_ms = now;
        ctx->stats.total_errors++;
        ctx->stats.total_heartbeat_timeouts++;
        ctx->stats.last_error_time = now;
        if (ctx->ping_socket >= 0) {
            close(ctx->ping_socket);
            ctx->ping_socket = -1;
        }
        if (ping_manager_init(pm, ctx) != QACC_OK) {
            qosacc_log(ctx, QACC_LOG_ERROR, "网络重初始化失败，继续运行但可能无法接收ping\n");
            // 保持 ping_socket 为 -1，后续发送会失败，但不会崩溃
        } else {
            qosacc_log(ctx, QACC_LOG_INFO, "网络重初始化成功\n");
        }
    }
    if (atomic_load(&ctx->reset_bw)) {
        qosacc_log(ctx, QACC_LOG_INFO, "收到重置信号，恢复带宽到最大值\n");
        int default_bw = ctx->config.max_bandwidth_kbps * 1000;
        tc_controller_set_bandwidth(tc, default_bw);
        atomic_store(&ctx->reset_bw, 0);
    }
    if (ctx->state != QACC_EXIT) {
        if (now - ctx->last_ping_time_ms >= ctx->config.ping_interval)
            ping_manager_send(pm);
    }
    if (now - ctx->last_stats_time_ms > STATS_INTERVAL_MS) {
        load_monitor_update(ctx);
        ctx->last_stats_time_ms = now;
    }
    if (now - ctx->last_class_stats_ms > CONTROL_INTERVAL_MS) {
        tc_controller_update_class_stats(ctx);
        ctx->last_class_stats_ms = now;
    }
    if (now - ctx->last_tc_update_time_ms > CONTROL_INTERVAL_MS) {
        if (tc_controller_set_bandwidth(tc, ctx->current_limit_bps) == QACC_OK)
            ctx->last_tc_update_time_ms = now;
        else
            qosacc_log(ctx, QACC_LOG_WARN, "带宽设置失败，稍后重试\n");
    }
    if (now - ctx->last_runtime_stats_ms > 5000) {
        update_runtime_stats(ctx);
        ctx->last_runtime_stats_ms = now;
    }
    heart_beat_check(ctx);
    switch (ctx->state) {
        case QACC_CHK:    state_machine_check(ctx, pm, tc); break;
        case QACC_INIT:   state_machine_init_state(ctx, tc); break;
        case QACC_IDLE:   state_machine_idle(ctx); break;
        case QACC_ACTIVE: state_machine_active(ctx); break;
        case QACC_REALTIME: state_machine_realtime(ctx); break;
        default: break;
    }
}

/* ==================== 状态文件更新 ==================== */
int status_file_update(qosacc_context_t* ctx) {
    static int64_t last = 0;
    int64_t now = qosacc_time_ms();
    if (now - last < 5000) return QACC_OK;
    char temp[512];
    snprintf(temp, sizeof(temp), "%s.tmp", ctx->config.status_file);
    int fd = open(temp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "无法创建临时状态文件: %s\n", strerror(errno));
        return QACC_ERR_FILE;
    }
    struct flock lock = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 0 };
    int locked = 0;
    for (int i = 0; i < LOCK_RETRY_COUNT; i++) {
        if (fcntl(fd, F_SETLK, &lock) == 0) { locked = 1; break; }
        usleep(LOCK_RETRY_DELAY_MS * 1000);
    }
    if (!locked) {
        qosacc_log(ctx, QACC_LOG_ERROR, "无法锁定状态文件 (重试%d次)\n", LOCK_RETRY_COUNT);
        close(fd);
        return QACC_ERR_FILE;
    }
    FILE* fp = fdopen(fd, "w");
    if (!fp) {
        qosacc_log(ctx, QACC_LOG_ERROR, "fdopen失败: %s\n", strerror(errno));
        lock.l_type = F_UNLCK;
        fcntl(fd, F_SETLK, &lock);
        close(fd);
        return QACC_ERR_FILE;
    }
    // 输出状态名称字符串，而非数字
    fprintf(fp, "状态: %s\n", state_names[ctx->state]);
    fprintf(fp, "当前带宽: %d kbps\n", ctx->current_limit_bps / 1000);
    fprintf(fp, "当前ping: %ld ms\n", ctx->filtered_ping_time_us / 1000);
    fprintf(fp, "最大ping: %ld ms\n", ctx->max_ping_time_us / 1000);
    fprintf(fp, "流量负载: %d kbps\n", ctx->filtered_total_load_bps / 1000);
    fprintf(fp, "已发送ping: %d\n", ctx->ntransmitted);
    fprintf(fp, "已接收ping: %d\n", ctx->nreceived);
    fprintf(fp, "队列算法: %s\n", ctx->detected_qdisc);
    fprintf(fp, "实时类活跃: %d\n", ctx->realtime_active);
    fprintf(fp, "运行时间: %ld秒\n", ctx->stats.uptime_seconds);
    fprintf(fp, "总带宽调整: %ld次\n", ctx->stats.total_bandwidth_adjustments);
    fprintf(fp, "总错误数: %ld\n", ctx->stats.total_errors);
    fprintf(fp, "心跳检查: %ld次\n", ctx->stats.total_heartbeat_checks);
    fprintf(fp, "心跳超时: %ld次\n", ctx->stats.total_heartbeat_timeouts);
    // 使用系统时间（带毫秒）
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm* tm_info = localtime(&ts.tv_sec);
    char time_buf[26];
    strftime(time_buf, sizeof(time_buf), "%Y-%m-%d %H:%M:%S", tm_info);
    fprintf(fp, "最后更新: %s.%03ld\n", time_buf, ts.tv_nsec / 1000000);
    fflush(fp);
    lock.l_type = F_UNLCK;
    fcntl(fd, F_SETLK, &lock);
    fclose(fp);
    
    for (int i = 0; i < STATUS_FILE_RETRY_COUNT; i++) {
        if (rename(temp, ctx->config.status_file) == 0) break;
        usleep(STATUS_FILE_RETRY_DELAY_MS * 1000);
        if (i == STATUS_FILE_RETRY_COUNT - 1) {
            qosacc_log(ctx, QACC_LOG_ERROR, "重命名状态文件失败: %s\n", strerror(errno));
            unlink(temp);
            return QACC_ERR_FILE;
        }
    }
    last = now;
    return QACC_OK;
}

/* ==================== 信号处理 ==================== */
void signal_handler(int sig) {
    if (sig == SIGUSR1)
        atomic_store(&g_reset_bw, 1);
    else
        atomic_store(&g_sigterm_received, 1);
}

int setup_signal_handlers(qosacc_context_t* ctx) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sigaddset(&sa.sa_mask, SIGTERM);
    sigaddset(&sa.sa_mask, SIGINT);
    sigaddset(&sa.sa_mask, SIGUSR1);
    if (sigaction(SIGTERM, &sa, NULL) < 0 ||
        sigaction(SIGINT, &sa, NULL) < 0 ||
        sigaction(SIGUSR1, &sa, NULL) < 0) {
        qosacc_log(ctx, QACC_LOG_ERROR, "信号处理设置失败\n");
        return QACC_ERR_SIGNAL;
    }
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);
    return QACC_OK;
}

void qosacc_cleanup(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc) {
    qosacc_log(ctx, QACC_LOG_INFO, "清理资源...\n");
    if (!ctx->config.safe_mode) {
        int default_bw = ctx->config.max_bandwidth_kbps * 1000;
        tc_controller_set_bandwidth(tc, default_bw);
    }
    if (tc) tc_controller_cleanup(tc);
    if (pm) ping_manager_cleanup(pm);
    
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
}

/* ==================== 主函数 ==================== */
int main(int argc, char* argv[]) {
    int ret = EXIT_FAILURE;
    qosacc_context_t context = {0};
    ping_manager_t ping_mgr = {0};
    tc_controller_t tc_mgr = {0};

    // 初始化 ping_socket 为 -1，避免误关闭
    context.ping_socket = -1;

    if (argc == 1) {
        fprintf(stderr, "qosacc: 未提供参数，使用 -h 查看帮助\n");
        return EXIT_FAILURE;
    }

    qosacc_config_init(&context.config);
    int config_result = qosacc_config_parse(&context.config, argc, argv);
    if (config_result == QACC_HELP_REQUESTED) {
        fprintf(stderr, "%s", qosacc_usage);
        return EXIT_SUCCESS;
    }
    if (config_result != QACC_OK) {
        fprintf(stderr, "配置解析失败\n");
        return EXIT_FAILURE;
    }

    char err[256];
    if (qosacc_config_validate(&context.config, argc, argv, err, sizeof(err)) != QACC_OK) {
        fprintf(stderr, "错误: %s\n", err);
        return EXIT_FAILURE;
    }

    if (context.config.background_mode) {
        if (daemon(0, 0) < 0) { perror("daemon"); return EXIT_FAILURE; }
        openlog("qosacc", LOG_PID, LOG_USER);
    }

    if (strlen(context.config.debug_log) > 0) {
        context.debug_log_file = fopen(context.config.debug_log, "a");
        if (!context.debug_log_file)
            qosacc_log(&context, QACC_LOG_WARN, "无法打开调试日志 %s\n", context.config.debug_log);
    }

    if (setup_signal_handlers(&context) != QACC_OK) goto cleanup;

    state_machine_init(&context);

    if (resolve_target(context.config.target, &context.target_addr, &context.target_addr_len, err, sizeof(err)) != QACC_OK) {
        qosacc_log(&context, QACC_LOG_ERROR, "解析目标失败: %s\n", err);
        goto cleanup;
    }
    qosacc_log(&context, QACC_LOG_INFO, "目标地址解析为 %s\n",
               context.target_addr.ss_family == AF_INET ? "IPv4" : "IPv6");

    if (ping_manager_init(&ping_mgr, &context) != QACC_OK) goto cleanup;
    if (tc_controller_init(&tc_mgr, &context) != QACC_OK) goto cleanup;

    if (setpriority(PRIO_PROCESS, 0, -10) < 0)
        qosacc_log(&context, QACC_LOG_WARN, "无法设置进程优先级\n");

    qosacc_log(&context, QACC_LOG_INFO,
        "======== qosacc 启动 ========\n"
        "目标: %s\n设备: %s\n最大带宽: %d kbps\nping间隔: %d ms\nping限制: %d ms\n实时ping限制: %d ms\n队列: %s\n根qdisc handle: 0x%x\n安全模式: %s\n自动切换: %s\n",
        context.config.target, context.config.device,
        context.config.max_bandwidth_kbps,
        context.config.ping_interval,
        context.config.ping_limit_ms,
        context.config.realtime_ping_limit_ms,
        context.detected_qdisc,
        context.root_qdisc_handle,
        context.config.safe_mode ? "是" : "否",
        context.config.auto_switch_mode ? "是" : "否");

    context.state = QACC_CHK;
    context.last_heartbeat_ms = qosacc_time_ms();

    if (!context.config.skip_initial) {
        for (int i = 0; i < 5; i++) {
            ping_manager_send(&ping_mgr);
            usleep(context.config.ping_interval * 1000);
        }
    }

    struct pollfd fds[1];
    int poll_ret;

    atomic_store(&context.sigterm, atomic_load(&g_sigterm_received));
    atomic_store(&context.reset_bw, atomic_load(&g_reset_bw));

    while (!atomic_load(&context.sigterm)) {
        int64_t now = qosacc_time_ms();
        int64_t next_ping = context.last_ping_time_ms + context.config.ping_interval - now;
        int64_t next_stats = context.last_stats_time_ms + STATS_INTERVAL_MS - now;
        int64_t next_tc = context.last_tc_update_time_ms + CONTROL_INTERVAL_MS - now;
        int64_t next_heartbeat = context.last_heartbeat_ms + HEARTBEAT_INTERVAL_MS - now;
        int64_t next_class_stats = context.last_class_stats_ms + CONTROL_INTERVAL_MS - now;
        int timeout = POLL_TIMEOUT_MS;
        if (next_ping > 0 && next_ping < timeout) timeout = next_ping;
        if (next_stats > 0 && next_stats < timeout) timeout = next_stats;
        if (next_tc > 0 && next_tc < timeout) timeout = next_tc;
        if (next_heartbeat > 0 && next_heartbeat < timeout) timeout = next_heartbeat;
        if (next_class_stats > 0 && next_class_stats < timeout) timeout = next_class_stats;
        if (timeout <= 0) timeout = MIN_SLEEP_MS;
        if (timeout > context.config.check_interval) timeout = context.config.check_interval;

        // 如果 ping_socket 无效，则跳过 poll，直接睡眠
        if (context.ping_socket >= 0) {
            fds[0].fd = context.ping_socket;
            fds[0].events = POLLIN;
            poll_ret = poll(fds, 1, timeout);
            qosacc_log(&context, QACC_LOG_DEBUG, "poll返回: %d, revents=0x%x\n", poll_ret, fds[0].revents);
        } else {
            usleep(timeout * 1000);
            poll_ret = 0;
            fds[0].revents = 0;
        }
        int64_t poll_end = qosacc_time_ms();

        if (poll_ret < 0) {
            if (errno == EINTR) {
                atomic_store(&context.sigterm, atomic_load(&g_sigterm_received));
                atomic_store(&context.reset_bw, atomic_load(&g_reset_bw));
                atomic_fetch_add(&context.signal_counter, 1);
                continue;
            }
            qosacc_log(&context, QACC_LOG_ERROR, "poll失败: %s\n", strerror(errno));
            break;
        }

        if (poll_ret > 0 && (fds[0].revents & POLLIN)) {
            ping_manager_receive(&ping_mgr);
        }
        if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
            qosacc_log(&context, QACC_LOG_ERROR, "socket错误, revents=0x%x\n", fds[0].revents);
            break;
        }

        state_machine_run(&context, &ping_mgr, &tc_mgr);
        status_file_update(&context);

        atomic_store(&context.sigterm, atomic_load(&g_sigterm_received));
        atomic_store(&context.reset_bw, atomic_load(&g_reset_bw));
        if (atomic_load(&context.sigterm)) break;

        if (poll_end - now > 50)
            qosacc_log(&context, QACC_LOG_DEBUG, "循环耗时 %d ms\n", (int)(poll_end - now));
    }

    ret = EXIT_SUCCESS;

cleanup:
    qosacc_cleanup(&context, &ping_mgr, &tc_mgr);
    int64_t uptime = (qosacc_time_ms() - context.stats.start_time_ms) / 1000;
    qosacc_log(&context, QACC_LOG_INFO,
        "最终统计: 运行%ld秒, 发送%ld, 接收%ld, 丢失%ld, 调整%ld次, 最大ping%ldms, 最小ping%ldms\n",
        uptime,
        context.stats.total_ping_sent,
        context.stats.total_ping_received,
        context.stats.total_ping_lost,
        context.stats.total_bandwidth_adjustments,
        context.stats.max_ping_time_recorded / 1000,
        context.stats.min_ping_time_recorded / 1000);
    qosacc_log(&context, QACC_LOG_INFO, "qosacc 退出\n");

    if (context.config.background_mode) closelog();
    return ret;
}