/* qosacc - 基于netlink的优化版QoS主动拥塞控制
 * version=1.3.1 (修复版)
 * 功能：通过ping监控延迟，使用tc命令直接调整ifb0根类的带宽
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
#include <pthread.h>
#include <sys/stat.h>
#include <float.h>
#include <time.h>
#include <dlfcn.h>
#include <ctype.h>
#include <stdatomic.h>
#include <sys/file.h>

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
#define HEARTBEAT_INTERVAL_MS 10000
#define HEARTBEAT_TIMEOUT_MS 30000
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
#define COMPARE_EPSILON 1e-6          /* 浮点比较精度，原DOUBLE_EPSILON过小 */

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
#define MIN_ADJUST_FACTOR 0.80f        /* 修改：降低下限，使减少更激进（原0.95） */
#define MAX_ADJUST_FACTOR 1.20f
#define LOAD_THRESHOLD_FOR_DECREASE 0.85f

#define MIN(a,b) (((a)<(b))?(a):(b))
#define MAX(a,b) (((a)>(b))?(a):(b))

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
    QMON_HELP_REQUESTED = -99
} qosacc_result_t;

/* ==================== 配置结构 ==================== */
typedef struct {
    int enabled;
    int ping_interval;          // ms
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
    int init_duration_ms;
    float adjust_rate_neg;
    float adjust_rate_pos;
    char root_classid[16];       /* 新增：根类ID，如"1:1" */
    char target[64];
    char device[16];
    char config_file[256];
    char debug_log[256];
    char status_file[256];
    int check_interval;
} qosacc_config_t;

/* ==================== 状态枚举 ==================== */
typedef enum {
    QMON_CHK,
    QMON_INIT,
    QMON_IDLE,
    QMON_ACTIVE,
    QMON_EXIT
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
    int64_t max_ping_time_us;          /* 仅记录用，不再递减 */
    int filtered_total_load_bps;
    ping_history_t ping_history;
    
    // 带宽控制
    int current_limit_bps;
    int saved_active_limit;
    
    // TC相关
    char detected_qdisc[16];
    
    // 时间戳
    int64_t last_ping_time_ms;
    int64_t last_stats_time_ms;
    int64_t last_tc_update_time_ms;
    int64_t last_heartbeat_ms;
    int64_t last_runtime_stats_ms;
    
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

/* ==================== 队列检测结果结构 ==================== */
typedef struct {
    char qdisc_kind[16];
    int valid;
    int error_code;
} qdisc_detect_result_t;

/* ==================== 帮助信息 ==================== */
const char qosacc_usage[] =
"qosacc - 基于ping延迟的动态QoS带宽调整器\n"
"版本: 1.3.1 (修复版)\n\n"
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
"  adjust_rate_neg, adjust_rate_pos, init_duration_ms, root_classid 等\n\n"
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

int resolve_target(const char* target, struct sockaddr_in6* addr, char* error, int error_len) {
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
        memcpy(&addr->sin6_addr.s6_addr[12], &((struct sockaddr_in*)result->ai_addr)->sin_addr, 4);
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
    if (!ctx->config.verbose && level > QMON_LOG_INFO) return;
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
        if (ctx->config.verbose || level <= QMON_LOG_INFO)
            fprintf(stderr, "[%s] [%s] %s", cached_time_str, level_str, buffer);
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

/* ==================== 配置文件解析辅助（增强空格容忍） ==================== */
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
    // 提取key（允许等号前后有空格）
    const char* key_start = line;
    while (isspace(*key_start)) key_start++;
    const char* key_end = equal_sign - 1;
    while (key_end > key_start && isspace(*key_end)) key_end--;
    int key_len_to_copy = key_end - key_start + 1;
    if (key_len_to_copy >= key_len) key_len_to_copy = key_len - 1;
    strncpy(key, key_start, key_len_to_copy);
    key[key_len_to_copy] = '\0';
    
    // 提取value
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

/* ==================== 配置处理 ==================== */
void qosacc_config_init(qosacc_config_t* cfg) {
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
    cfg->init_duration_ms = 15000;
    cfg->adjust_rate_neg = 0.002f;
    cfg->adjust_rate_pos = 0.004f;
    strcpy(cfg->root_classid, "1:1");          /* 默认根类ID */
    cfg->check_interval = 1000;
    strcpy(cfg->device, "ifb0");
    strcpy(cfg->target, "8.8.8.8");
    strcpy(cfg->status_file, "/tmp/qosacc.status");
    strcpy(cfg->debug_log, "/var/log/qosacc.log");
}

static int qosacc_config_parse_file(qosacc_config_t* cfg, const char* config_file) {
    FILE* fp = fopen(config_file, "r");
    if (!fp) {
        fprintf(stderr, "错误：配置文件'%s'无法打开: %s\n", config_file, strerror(errno));
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
        if (line[0] == '#' || line[0] == ';' || line[0] == '\0') continue;
        if (line[0] == '[' && strchr(line, ']')) {
            char section[64];
            if (sscanf(line, "[%63[^]]]", section) == 1) {
                // 改进：查找等号，允许空格
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
                else if (strcmp(key, "check_interval") == 0) cfg->check_interval = atoi(value) * 1000;
                else if (strcmp(key, "config_version") == 0) {
                    int version = atoi(value);
                    if (version < MIN_CONFIG_VERSION || version > MAX_CONFIG_VERSION) {
                        fprintf(stderr, "配置版本不兼容: %d (支持 %d-%d)\n", version, MIN_CONFIG_VERSION, MAX_CONFIG_VERSION);
                        fclose(fp);
                        return QMON_ERR_CONFIG;
                    }
                }
            }
        }
    }
    fclose(fp);
    if (!cfg->enabled) fprintf(stderr, "警告：未找到设备 '%s' 的启用配置。\n", cfg->device);
    return QMON_OK;
}

int qosacc_config_parse(qosacc_config_t* cfg, int argc, char* argv[]) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "-help") == 0 || strcmp(argv[i], "--help") == 0)
            return QMON_HELP_REQUESTED;
    }
    qosacc_config_init(cfg);
    int config_file_provided = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) {
            char* config_file = argv[++i];
            strncpy(cfg->config_file, config_file, sizeof(cfg->config_file)-1);
            int ret = qosacc_config_parse_file(cfg, config_file);
            if (ret != QMON_OK) return ret;
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
    return QMON_OK;
}

int qosacc_config_validate(qosacc_config_t* cfg, int argc, char* argv[], char* error, int error_len) {
    if (argc == 1) { snprintf(error, error_len, "未提供任何参数"); return QMON_ERR_CONFIG; }
    if (!cfg->enabled) { snprintf(error, error_len, "设备 '%s' 未启用", cfg->device); return QMON_ERR_CONFIG; }
    if (cfg->ping_interval < MIN_PING_INTERVAL || cfg->ping_interval > MAX_PING_INTERVAL) {
        snprintf(error, error_len, "ping间隔 %d 超出范围 [%d,%d]", cfg->ping_interval, MIN_PING_INTERVAL, MAX_PING_INTERVAL);
        return QMON_ERR_CONFIG;
    }
    if (cfg->max_bandwidth_kbps < MIN_BANDWIDTH_KBPS || cfg->max_bandwidth_kbps > MAX_BANDWIDTH_KBPS) {
        snprintf(error, error_len, "最大带宽 %d 超出范围 [%d,%d] kbps", cfg->max_bandwidth_kbps, MIN_BANDWIDTH_KBPS, MAX_BANDWIDTH_KBPS);
        return QMON_ERR_CONFIG;
    }
    if (cfg->ping_limit_ms < MIN_PING_LIMIT_MS || cfg->ping_limit_ms > MAX_PING_LIMIT_MS) {
        snprintf(error, error_len, "ping限制 %d 超出范围 [%d,%d] ms", cfg->ping_limit_ms, MIN_PING_LIMIT_MS, MAX_PING_LIMIT_MS);
        return QMON_ERR_CONFIG;
    }
    if (strlen(cfg->target) == 0) { snprintf(error, error_len, "目标地址不能为空"); return QMON_ERR_CONFIG; }
    if (strlen(cfg->device) == 0) { snprintf(error, error_len, "设备名不能为空"); return QMON_ERR_CONFIG; }
    if (cfg->min_bw_ratio < MIN_BW_RATIO || cfg->min_bw_ratio > MAX_BW_RATIO_MAX) {
        snprintf(error, error_len, "最小带宽比例 %.2f 超出范围 [%.2f,%.2f]", cfg->min_bw_ratio, MIN_BW_RATIO, MAX_BW_RATIO_MAX);
        return QMON_ERR_CONFIG;
    }
    if (cfg->max_bw_ratio < MIN_BW_RATIO || cfg->max_bw_ratio > MAX_BW_RATIO_MAX) {
        snprintf(error, error_len, "最大带宽比例 %.2f 超出范围 [%.2f,%.2f]", cfg->max_bw_ratio, MIN_BW_RATIO, MAX_BW_RATIO_MAX);
        return QMON_ERR_CONFIG;
    }
    if (cfg->smoothing_factor < SMOOTHING_FACTOR_MIN - EPSILON || cfg->smoothing_factor > SMOOTHING_FACTOR_MAX + EPSILON) {
        snprintf(error, error_len, "平滑因子 %.2f 超出范围 [%.1f,%.1f]", cfg->smoothing_factor, SMOOTHING_FACTOR_MIN, SMOOTHING_FACTOR_MAX);
        return QMON_ERR_CONFIG;
    }
    // 检查最小带宽绝对值是否低于 MIN_BANDWIDTH_KBPS
    float min_bw_kbps = cfg->max_bandwidth_kbps * cfg->min_bw_ratio;
    if (min_bw_kbps < MIN_BANDWIDTH_KBPS - EPSILON) {
        snprintf(error, error_len, "最小带宽 %.1f kbps 低于允许的最小值 %d kbps，请调整 min_bw_ratio", min_bw_kbps, MIN_BANDWIDTH_KBPS);
        return QMON_ERR_CONFIG;
    }
    return QMON_OK;
}

/* ==================== Ping管理器 ==================== */
struct ping_manager_s {
    qosacc_context_t* ctx;
    char packet[MAX_PACKET_SIZE];
};

int ping_manager_init(ping_manager_t* pm, qosacc_context_t* ctx) {
    pm->ctx = ctx;
    int af = ctx->target_addr.sin6_family;
    int protocol = (af == AF_INET6) ? IPPROTO_ICMPV6 : IPPROTO_ICMP;
    ctx->ping_socket = socket(af, SOCK_RAW, protocol);
    if (ctx->ping_socket < 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "创建ping套接字失败: %s\n", strerror(errno));
        return QMON_ERR_SOCKET;
    }
    int ttl = 64;
    setsockopt(ctx->ping_socket, IPPROTO_IP, IP_TTL, &ttl, sizeof(ttl));
    int timeout = 2000;
    setsockopt(ctx->ping_socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    int flags = fcntl(ctx->ping_socket, F_GETFL, 0);
    if (flags >= 0) fcntl(ctx->ping_socket, F_SETFL, flags | O_NONBLOCK);
    return QMON_OK;
}

int ping_manager_send(ping_manager_t* pm) {
    qosacc_context_t* ctx = pm->ctx;
    if (ctx->ping_socket < 0) return QMON_ERR_SOCKET;
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
        for (int i = 8; i < cc; i++) pm->packet[8 + sizeof(struct icmp6_hdr) + i] = i;
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
        for (int i = 8; i < cc; i++) pm->packet[8 + sizeof(struct timeval) + i] = i;
        icp->icmp_cksum = icmp_checksum(icp, cc);
    }
    ctx->ntransmitted++;
    int ret = sendto(ctx->ping_socket, pm->packet, cc, 0, (struct sockaddr*)&ctx->target_addr, sizeof(ctx->target_addr));
    if (ret < 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "发送ping失败: %s\n", strerror(errno));
        return QMON_ERR_SOCKET;
    }
    ctx->last_ping_time_ms = qosacc_time_ms();
    qosacc_log(ctx, QMON_LOG_DEBUG, "发送ping seq=%d\n", ctx->ntransmitted);
    return QMON_OK;
}

int ping_manager_receive(ping_manager_t* pm) {
    qosacc_context_t* ctx = pm->ctx;
    char buf[MAX_PACKET_SIZE];
    struct sockaddr_storage from;
    socklen_t fromlen = sizeof(from);
    int cc = recvfrom(ctx->ping_socket, buf, sizeof(buf), 0, (struct sockaddr*)&from, &fromlen);
    if (cc < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK)
            qosacc_log(ctx, QMON_LOG_ERROR, "接收ping失败: %s\n", strerror(errno));
        return (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : QMON_ERR_SOCKET;
    }
    struct ip* ip = NULL;
    struct icmp* icp = NULL;
    struct icmp6_hdr* icp6 = NULL;
    struct timeval tv, *tp = NULL;
    int hlen, triptime = 0;
    uint16_t seq = 0;
    gettimeofday(&tv, NULL);
    if (from.ss_family == AF_INET6) {
        if (cc < (int)sizeof(struct icmp6_hdr)) return 0;
        icp6 = (struct icmp6_hdr*)buf;
        if (icp6->icmp6_type != ICMP6_ECHO_REPLY) return 0;
        if (ntohs(icp6->icmp6_id) != ctx->ident) return 0;
        if (icp6->icmp6_cksum != 0) {
            struct sockaddr_in6* from_v6 = (struct sockaddr_in6*)&from;
            struct in6_addr src = from_v6->sin6_addr;
            struct in6_addr dst = ctx->target_addr.sin6_addr;
            uint16_t saved = icp6->icmp6_cksum;
            icp6->icmp6_cksum = 0;
            uint16_t calc = icmpv6_checksum(&src, &dst, icp6, cc);
            if (saved != calc) {
                qosacc_log(ctx, QMON_LOG_WARN, "ICMPv6校验和不匹配，丢弃包\n");
                return 0;
            }
        }
        seq = ntohs(icp6->icmp6_seq);
        if (cc >= 8 + (int)sizeof(struct timeval))
            tp = (struct timeval*)&icp6->icmp6_dataun.icmp6_un_data32[1];
    } else {
        ip = (struct ip*)buf;
        hlen = ip->ip_hl << 2;
        if (cc < hlen + 8) return 0;
        icp = (struct icmp*)(buf + hlen);
        if (icp->icmp_type != ICMP_ECHOREPLY) return 0;
        if (icp->icmp_id != ctx->ident) return 0;
        uint16_t saved = icp->icmp_cksum;
        icp->icmp_cksum = 0;
        uint16_t calc = icmp_checksum(icp, cc - hlen);
        if (saved != calc) {
            qosacc_log(ctx, QMON_LOG_WARN, "ICMP校验和不匹配，丢弃包\n");
            return 0;
        }
        seq = icp->icmp_seq;
        if (cc >= hlen + 8 + (int)sizeof(struct timeval))
            tp = (struct timeval*)&icp->icmp_data[0];
    }
    if (seq != ctx->ntransmitted) return 0;
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
    ping_history_t* hist = &ctx->ping_history;
    if (hist->count < PING_HISTORY_SIZE)
        hist->times[hist->index] = ctx->raw_ping_time_us;
    else
        hist->times[hist->index] = ctx->raw_ping_time_us;
    hist->index = (hist->index + 1) % PING_HISTORY_SIZE;
    if (hist->count < PING_HISTORY_SIZE) hist->count++;
    if (hist->count == 1)
        hist->smoothed = ctx->raw_ping_time_us;
    else
        hist->smoothed = hist->smoothed * (1.0 - ctx->config.smoothing_factor) + ctx->raw_ping_time_us * ctx->config.smoothing_factor;
    ctx->filtered_ping_time_us = (int64_t)hist->smoothed;
    qosacc_log(ctx, QMON_LOG_DEBUG, "收到ping seq=%d, 时间=%dms, 平滑=%ldms\n", seq, triptime, ctx->filtered_ping_time_us / 1000);
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
        qosacc_log(ctx, QMON_LOG_ERROR, "无法打开 /proc/net/dev: %s\n", strerror(errno));
        return QMON_ERR_FILE;
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
        qosacc_log(ctx, QMON_LOG_ERROR, "接口 %s 未找到\n", ctx->config.device);
        return QMON_ERR_SYSTEM;
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
            qosacc_log(ctx, QMON_LOG_DEBUG, "流量: 原始=%d bps, 平滑=%d bps\n", bps, ctx->filtered_total_load_bps);
        }
    }
    last_rx_bytes = rx_bytes;
    last_read_time = now;
    return QMON_OK;
}

/* ==================== TC控制器（使用tc命令） ==================== */
struct tc_controller_s {
    qosacc_context_t* ctx;
};

/* 获取tc可执行文件路径 */
char* get_tc_path(void) {
    static char tc_path[256] = {0};
    if (tc_path[0] != '\0') return tc_path;
    const char* possible_paths[] = { "/sbin/tc", "/usr/sbin/tc", "/usr/local/sbin/tc", "/bin/tc", "/usr/bin/tc" };
    for (int i = 0; i < sizeof(possible_paths)/sizeof(possible_paths[0]); i++) {
        if (access(possible_paths[i], X_OK) == 0) {
            strncpy(tc_path, possible_paths[i], sizeof(tc_path)-1);
            return tc_path;
        }
    }
    FILE* fp = popen("which tc 2>/dev/null", "r");
    if (fp) {
        if (fgets(tc_path, sizeof(tc_path), fp)) {
            char* nl = strchr(tc_path, '\n');
            if (nl) *nl = '\0';
        }
        pclose(fp);
    }
    if (tc_path[0] == '\0') strcpy(tc_path, "tc");
    return tc_path;
}

/* 安全执行命令并读取输出 */
int safe_popen_and_read(qosacc_context_t* ctx, const char* cmd, char* output, int output_size) {
    output[0] = '\0';
    qosacc_log(ctx, QMON_LOG_DEBUG, "执行: %s\n", cmd);
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        qosacc_log(ctx, QMON_LOG_ERROR, "popen失败: %s\n", strerror(errno));
        return -1;
    }
    int total_read = 0;
    char buffer[256];
    while (fgets(buffer, sizeof(buffer), fp)) {
        int len = strlen(buffer);
        if (total_read + len < output_size - 1) {
            strcpy(output + total_read, buffer);
            total_read += len;
        } else {
            qosacc_log(ctx, QMON_LOG_WARN, "命令输出截断\n");
            break;
        }
    }
    output[total_read] = '\0';
    int ret = pclose(fp);
    if (WIFEXITED(ret)) {
        ret = WEXITSTATUS(ret);
    } else if (WIFSIGNALED(ret)) {
        int sig = WTERMSIG(ret);
        qosacc_log(ctx, QMON_LOG_ERROR, "命令被信号 %d (%s) 终止\n", sig, strsignal(sig));
        ret = 128 + sig;
    } else {
        qosacc_log(ctx, QMON_LOG_ERROR, "命令异常终止 (状态: %d)\n", ret);
        ret = -1;
    }
    return ret;
}

/* 检测队列类型（修复版：优先根队列，其次任意队列） */
qdisc_detect_result_t safe_detect_qdisc_kind(qosacc_context_t* ctx) {
    qdisc_detect_result_t result = {0};
    strcpy(result.qdisc_kind, "unknown");
    result.valid = 0;
    qosacc_log(ctx, QMON_LOG_INFO, "检测 %s 队列类型...\n", ctx->config.device);
    for (int attempt = 0; attempt < DETECT_QDISC_RETRY_COUNT; attempt++) {
        if (attempt > 0) usleep(DETECT_QDISC_RETRY_DELAY_MS * 1000);
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "tc qdisc show dev %s 2>&1", ctx->config.device);
        FILE* fp = popen(cmd, "r");
        if (!fp) {
            qosacc_log(ctx, QMON_LOG_ERROR, "popen失败: %s\n", strerror(errno));
            result.error_code = errno;
            continue;
        }
        char line[512];
        char root_qdisc[16] = "";
        char any_qdisc[16] = "";
        while (fgets(line, sizeof(line), fp)) {
            char* nl = strchr(line, '\n');
            if (nl) *nl = '\0';
            char low[512];
            strncpy(low, line, sizeof(low)-1);
            low[sizeof(low)-1] = '\0';
            for (int i = 0; low[i]; i++) low[i] = tolower(low[i]);
            if (strstr(low, "qdisc") != NULL) {
                int is_root = (strstr(low, "root") != NULL);
                if (strstr(low, "cake") != NULL) {
                    strcpy(any_qdisc, "cake");
                    if (is_root) strcpy(root_qdisc, "cake");
                } else if (strstr(low, "hfsc") != NULL) {
                    strcpy(any_qdisc, "hfsc");
                    if (is_root) strcpy(root_qdisc, "hfsc");
                } else if (strstr(low, "htb") != NULL) {
                    strcpy(any_qdisc, "htb");
                    if (is_root) strcpy(root_qdisc, "htb");
                } else if (strstr(low, "fq_codel") != NULL || strstr(low, "fq-codel") != NULL) {
                    strcpy(any_qdisc, "fq_codel");
                    if (is_root) strcpy(root_qdisc, "fq_codel");
                } else if (strstr(low, "pfifo_fast") != NULL || strstr(low, "pfifo") != NULL) {
                    strcpy(any_qdisc, "pfifo_fast");
                    if (is_root) strcpy(root_qdisc, "pfifo_fast");
                }
            }
        }
        pclose(fp);
        if (root_qdisc[0] != '\0') {
            strcpy(result.qdisc_kind, root_qdisc);
            result.valid = 1;
            qosacc_log(ctx, QMON_LOG_INFO, "检测到根队列: %s\n", result.qdisc_kind);
            break;
        } else if (any_qdisc[0] != '\0') {
            strcpy(result.qdisc_kind, any_qdisc);
            result.valid = 1;
            qosacc_log(ctx, QMON_LOG_INFO, "检测到队列(非根): %s\n", result.qdisc_kind);
            break;
        }
    }
    if (!result.valid) {
        // 尝试检查设备是否存在
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "ip link show %s 2>&1", ctx->config.device);
        char output[1024];
        if (safe_popen_and_read(ctx, cmd, output, sizeof(output)) == 0) {
            qosacc_log(ctx, QMON_LOG_INFO, "设备存在，使用默认队列 pfifo_fast\n");
            strcpy(result.qdisc_kind, "pfifo_fast");
            result.valid = 1;
        } else {
            qosacc_log(ctx, QMON_LOG_ERROR, "设备 %s 不存在或无法访问\n", ctx->config.device);
        }
    }
    return result;
}

/* 验证带宽值（放宽范围：1bps ~ 100Gbps） */
int validate_bandwidth(qosacc_context_t* ctx, int bandwidth_bps) {
    if (bandwidth_bps < 1) {
        qosacc_log(ctx, QMON_LOG_ERROR, "带宽过小: %d bps\n", bandwidth_bps);
        return QMON_ERR_CONFIG;
    }
    if (bandwidth_bps > 100000000000LL) {  // 100Gbps
        qosacc_log(ctx, QMON_LOG_ERROR, "带宽过大: %d bps\n", bandwidth_bps);
        return QMON_ERR_CONFIG;
    }
    return QMON_OK;
}

/* 生成CAKE命令 */
int generate_cake_command(qosacc_context_t* ctx, int bandwidth_kbps, char* cmd, int cmd_size) {
    if (bandwidth_kbps >= 1000000) {
        double gbps = bandwidth_kbps / 1000000.0;
        snprintf(cmd, cmd_size, "tc qdisc change dev %s root cake bandwidth %.2fGbit 2>&1", ctx->config.device, gbps);
    } else if (bandwidth_kbps >= 1000) {
        double mbps = bandwidth_kbps / 1000.0;
        snprintf(cmd, cmd_size, "tc qdisc change dev %s root cake bandwidth %.2fMbit 2>&1", ctx->config.device, mbps);
    } else {
        snprintf(cmd, cmd_size, "tc qdisc change dev %s root cake bandwidth %dKbit 2>&1", ctx->config.device, bandwidth_kbps);
    }
    return QMON_OK;
}

/* 生成HFSC命令（使用配置的root_classid） */
int generate_hfsc_command(qosacc_context_t* ctx, int bandwidth_kbps, char* cmd, int cmd_size) {
    snprintf(cmd, cmd_size, "tc class change dev %s parent 1:0 classid %s hfsc sc rate %dkbit ul rate %dkbit 2>&1",
             ctx->config.device, ctx->config.root_classid, bandwidth_kbps, bandwidth_kbps);
    return QMON_OK;
}

/* 生成HTB命令（使用配置的root_classid） */
int generate_htb_command(qosacc_context_t* ctx, int bandwidth_kbps, char* cmd, int cmd_size) {
    snprintf(cmd, cmd_size, "tc class change dev %s parent 1:0 classid %s htb rate %dkbit ceil %dkbit 2>&1",
             ctx->config.device, ctx->config.root_classid, bandwidth_kbps, bandwidth_kbps);
    return QMON_OK;
}

/* 执行tc命令 */
int execute_tc_command(qosacc_context_t* ctx, const char* cmd) {
    char output[2048];
    int ret = safe_popen_and_read(ctx, cmd, output, sizeof(output));
    if (ret != 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "TC命令失败 (返回 %d): %s\n", ret, output);
        return QMON_ERR_SYSTEM;
    }
    return QMON_OK;
}

/* 设置带宽（核心） */
int tc_set_bandwidth(qosacc_context_t* ctx, int bandwidth_bps) {
    int bandwidth_kbps = (bandwidth_bps + 500) / 1000; // 四舍五入到kbps
    if (bandwidth_kbps < 1) bandwidth_kbps = 1;
    int max_kbps = ctx->config.max_bandwidth_kbps;
    if (bandwidth_kbps > max_kbps) bandwidth_kbps = max_kbps;
    int ret = validate_bandwidth(ctx, bandwidth_bps);
    if (ret != QMON_OK) return ret;

    if (strlen(ctx->detected_qdisc) == 0 || strcmp(ctx->detected_qdisc, "unknown") == 0) {
        qdisc_detect_result_t res = safe_detect_qdisc_kind(ctx);
        if (!res.valid) {
            qosacc_log(ctx, QMON_LOG_ERROR, "无法检测队列类型\n");
            return QMON_ERR_SYSTEM;
        }
        strncpy(ctx->detected_qdisc, res.qdisc_kind, sizeof(ctx->detected_qdisc)-1);
    }

    qosacc_log(ctx, QMON_LOG_INFO, "设置带宽: %d kbps (队列: %s, 根类ID: %s)\n",
               bandwidth_kbps, ctx->detected_qdisc, ctx->config.root_classid);

    char cmd[512];
    if (strcmp(ctx->detected_qdisc, "cake") == 0) {
        generate_cake_command(ctx, bandwidth_kbps, cmd, sizeof(cmd));
    } else if (strcmp(ctx->detected_qdisc, "hfsc") == 0) {
        generate_hfsc_command(ctx, bandwidth_kbps, cmd, sizeof(cmd));
    } else if (strcmp(ctx->detected_qdisc, "htb") == 0) {
        generate_htb_command(ctx, bandwidth_kbps, cmd, sizeof(cmd));
    } else {
        qosacc_log(ctx, QMON_LOG_ERROR, "队列 %s 不支持动态带宽调整\n", ctx->detected_qdisc);
        return QMON_ERR_SYSTEM;
    }
    return execute_tc_command(ctx, cmd);
}

int tc_controller_init(tc_controller_t* tc, qosacc_context_t* ctx) {
    tc->ctx = ctx;
    qdisc_detect_result_t res = safe_detect_qdisc_kind(ctx);
    if (!res.valid) {
        qosacc_log(ctx, QMON_LOG_ERROR, "队列检测失败，无法继续\n");
        return QMON_ERR_SYSTEM;
    }
    strncpy(ctx->detected_qdisc, res.qdisc_kind, sizeof(ctx->detected_qdisc)-1);
    if (strcmp(ctx->detected_qdisc, "fq_codel") == 0 || strcmp(ctx->detected_qdisc, "pfifo_fast") == 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "队列 %s 不支持动态带宽调整，程序退出\n", ctx->detected_qdisc);
        return QMON_ERR_CONFIG;
    }
    qosacc_log(ctx, QMON_LOG_INFO, "TC控制器初始化成功 (队列: %s, 根类ID: %s)\n",
               ctx->detected_qdisc, ctx->config.root_classid);
    return QMON_OK;
}

int tc_controller_set_bandwidth(tc_controller_t* tc, int bandwidth_bps) {
    if (!tc || !tc->ctx) return QMON_ERR_MEMORY;
    qosacc_context_t* ctx = tc->ctx;
    if (ctx->config.safe_mode) {
        qosacc_log(ctx, QMON_LOG_INFO, "安全模式: 跳过带宽设置 (%d kbps)\n", bandwidth_bps/1000);
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
        qosacc_log(ctx, QMON_LOG_INFO, "恢复带宽到 %d kbps\n", ctx->config.max_bandwidth_kbps);
    }
}

/* ==================== 运行时统计 ==================== */
void update_runtime_stats(qosacc_context_t* ctx) {
    int64_t now = qosacc_time_ms();
    ctx->stats.total_ping_sent = ctx->ntransmitted;
    ctx->stats.total_ping_received = ctx->nreceived;
    ctx->stats.total_ping_lost = ctx->ntransmitted - ctx->nreceived;
    if (ctx->filtered_ping_time_us > ctx->stats.max_ping_time_recorded)
        ctx->stats.max_ping_time_recorded = ctx->filtered_ping_time_us;
    if (ctx->stats.min_ping_time_recorded == 0 || (ctx->filtered_ping_time_us < ctx->stats.min_ping_time_recorded && ctx->filtered_ping_time_us > 0))
        ctx->stats.min_ping_time_recorded = ctx->filtered_ping_time_us;
    ctx->stats.uptime_seconds = (now - ctx->stats.start_time_ms) / 1000;
    static int64_t last = 0;
    if (now - last > 5000) {
        qosacc_log(ctx, QMON_LOG_INFO,
            "统计: 运行%ld秒, 发送%ld, 接收%ld, 丢失%ld(%.1f%%), 调整%ld次, 最大ping%ldms, 最小ping%ldms\n",
            ctx->stats.uptime_seconds,
            ctx->stats.total_ping_sent,
            ctx->stats.total_ping_received,
            ctx->stats.total_ping_lost,
            ctx->stats.total_ping_sent ? (ctx->stats.total_ping_lost * 100.0 / ctx->stats.total_ping_sent) : 0.0,
            ctx->stats.total_bandwidth_adjustments,
            ctx->stats.max_ping_time_recorded / 1000,
            ctx->stats.min_ping_time_recorded / 1000);
        last = now;
    }
}

/* ==================== 状态机 ==================== */
void state_machine_init(qosacc_context_t* ctx) {
    ctx->state = QMON_CHK;
    ctx->ident = getpid() & 0xFFFF;
    ctx->current_limit_bps = (int)(ctx->config.max_bandwidth_kbps * 1000 * ctx->config.safe_start_ratio);
    ctx->saved_active_limit = ctx->current_limit_bps;
    int64_t now = qosacc_time_ms();
    ctx->last_ping_time_ms = now;
    ctx->last_stats_time_ms = now;
    ctx->last_tc_update_time_ms = now;
    ctx->last_heartbeat_ms = now;
    ctx->last_runtime_stats_ms = now;
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
    static int init_count = 0;
    init_count++;
    int needed_pings = ctx->config.init_duration_ms / ctx->config.ping_interval;
    if (needed_pings <= 0) needed_pings = 1;
    if (init_count > needed_pings) {
        ctx->state = QMON_IDLE;
        tc_controller_set_bandwidth(tc, ctx->current_limit_bps);
        if (ctx->config.auto_switch_mode)
            ctx->config.ping_limit_ms = (int)(ctx->filtered_ping_time_us * 1.1f / 1000);
        else
            ctx->config.ping_limit_ms = ctx->filtered_ping_time_us * 2 / 1000;
        if (ctx->config.ping_limit_ms < 10) ctx->config.ping_limit_ms = 10;
        if (ctx->config.ping_limit_ms > 800) ctx->config.ping_limit_ms = 800;
        ctx->max_ping_time_us = ctx->config.ping_limit_ms * 2 * 1000;
        init_count = 0;
        qosacc_log(ctx, QMON_LOG_INFO, "初始化完成, ping限制=%dms\n", ctx->config.ping_limit_ms);
    }
}

void state_machine_idle(qosacc_context_t* ctx) {
    int max_bps = ctx->config.max_bandwidth_kbps * 1000;
    if (max_bps == 0) return;
    double util = (double)ctx->filtered_total_load_bps / (double)max_bps;
    if (util > ctx->config.active_threshold) {
        ctx->state = QMON_ACTIVE;
        ctx->current_limit_bps = ctx->saved_active_limit;
        qosacc_log(ctx, QMON_LOG_INFO, "进入ACTIVE状态, 利用率=%.1f%%\n", util * 100.0);
    }
}

void state_machine_active(qosacc_context_t* ctx) {
    ctx->saved_active_limit = ctx->current_limit_bps;
    int max_bps = ctx->config.max_bandwidth_kbps * 1000;
    if (max_bps == 0) return;
    double util = (double)ctx->filtered_total_load_bps / (double)max_bps;
    if (util < ctx->config.idle_threshold - COMPARE_EPSILON) {  /* 使用新精度 */
        ctx->state = QMON_IDLE;
        qosacc_log(ctx, QMON_LOG_INFO, "进入IDLE状态, 利用率=%.1f%%\n", util * 100.0);
        return;
    }
    int target_us = ctx->config.ping_limit_ms * 1000;
    if (target_us <= 0) target_us = 10000;
    double error = (double)ctx->filtered_ping_time_us - (double)target_us;
    double error_ratio = error / target_us;
    double adjust = 1.0;
    if (error < 0) {  // 延迟低于目标，增加带宽
        adjust = 1.0 + ctx->config.adjust_rate_neg * (-error_ratio);
        if (adjust > MAX_ADJUST_FACTOR) adjust = MAX_ADJUST_FACTOR;
    } else {          // 延迟高于目标，减少带宽
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
        qosacc_log(ctx, QMON_LOG_INFO, "带宽调整: %d -> %d kbps (误差=%.3f)\n",
                   old_limit/1000, new_limit/1000, error_ratio);
    }
    /* 移除无意义的 ctx->max_ping_time_us 递减 */
}

void heart_beat_check(qosacc_context_t* ctx) {
    static int64_t last = 0;
    int64_t now = qosacc_time_ms();
    if (now - last > HEARTBEAT_INTERVAL_MS) {
        ctx->stats.total_heartbeat_checks++;
        qosacc_log(ctx, QMON_LOG_DEBUG,
            "心跳: 状态=%d, 带宽=%d kbps, ping=%ld ms, 负载=%d kbps, 队列=%s\n",
            ctx->state, ctx->current_limit_bps/1000, ctx->filtered_ping_time_us/1000,
            ctx->filtered_total_load_bps/1000, ctx->detected_qdisc);
        last = now;
    }
}

void state_machine_run(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc) {
    int64_t now = qosacc_time_ms();
    // 心跳超时重启
    if (now - ctx->last_heartbeat_ms > HEARTBEAT_TIMEOUT_MS) {
        qosacc_log(ctx, QMON_LOG_ERROR, "心跳超时，重置状态机\n");
        ctx->state = QMON_CHK;
        ctx->last_heartbeat_ms = now;
        ctx->stats.total_errors++;
        ctx->stats.total_heartbeat_timeouts++;
        ctx->stats.last_error_time = now;
        if (ctx->ping_socket >= 0) {
            close(ctx->ping_socket);
            ctx->ping_socket = -1;
        }
        if (ping_manager_init(pm, ctx) != QMON_OK)
            qosacc_log(ctx, QMON_LOG_ERROR, "网络重初始化失败\n");
        else
            qosacc_log(ctx, QMON_LOG_INFO, "网络重初始化成功\n");
    }
    if (atomic_load(&ctx->reset_bw)) {
        qosacc_log(ctx, QMON_LOG_INFO, "收到重置信号，恢复带宽到最大值\n");
        int default_bw = ctx->config.max_bandwidth_kbps * 1000;
        tc_controller_set_bandwidth(tc, default_bw);
        atomic_store(&ctx->reset_bw, 0);
    }
    if (ctx->state != QMON_EXIT) {
        if (now - ctx->last_ping_time_ms >= ctx->config.ping_interval)
            ping_manager_send(pm);
    }
    if (now - ctx->last_stats_time_ms > STATS_INTERVAL_MS) {
        load_monitor_update(ctx);
        ctx->last_stats_time_ms = now;
    }
    if (now - ctx->last_tc_update_time_ms > CONTROL_INTERVAL_MS) {
        if (tc_controller_set_bandwidth(tc, ctx->current_limit_bps) == QMON_OK)
            ctx->last_tc_update_time_ms = now;
        else
            qosacc_log(ctx, QMON_LOG_WARN, "带宽设置失败，稍后重试\n");
    }
    if (now - ctx->last_runtime_stats_ms > 5000) {
        update_runtime_stats(ctx);
        ctx->last_runtime_stats_ms = now;
    }
    heart_beat_check(ctx);
    switch (ctx->state) {
        case QMON_CHK:    state_machine_check(ctx, pm, tc); break;
        case QMON_INIT:   state_machine_init_state(ctx, tc); break;
        case QMON_IDLE:   state_machine_idle(ctx); break;
        case QMON_ACTIVE: state_machine_active(ctx); break;
        default: break;
    }
}

/* ==================== 状态文件更新 ==================== */
int status_file_update(qosacc_context_t* ctx) {
    static int64_t last = 0;
    int64_t now = qosacc_time_ms();
    if (now - last < 5000) return QMON_OK;
    char temp[512];
    snprintf(temp, sizeof(temp), "%s.tmp", ctx->config.status_file);
    int fd = open(temp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        qosacc_log(ctx, QMON_LOG_ERROR, "无法创建临时状态文件: %s\n", strerror(errno));
        return QMON_ERR_FILE;
    }
    // 使用fcntl加锁，带重试
    struct flock lock = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 0 };
    int locked = 0;
    for (int i = 0; i < LOCK_RETRY_COUNT; i++) {
        if (fcntl(fd, F_SETLK, &lock) == 0) { locked = 1; break; }
        usleep(LOCK_RETRY_DELAY_MS * 1000);
    }
    if (!locked) {
        qosacc_log(ctx, QMON_LOG_ERROR, "无法锁定状态文件 (重试%d次)\n", LOCK_RETRY_COUNT);
        close(fd);
        return QMON_ERR_FILE;
    }
    FILE* fp = fdopen(fd, "w");
    if (!fp) {
        qosacc_log(ctx, QMON_LOG_ERROR, "fdopen失败: %s\n", strerror(errno));
        lock.l_type = F_UNLCK;
        fcntl(fd, F_SETLK, &lock);
        close(fd);
        return QMON_ERR_FILE;
    }
    fprintf(fp, "状态: %d\n", ctx->state);
    fprintf(fp, "当前带宽: %d kbps\n", ctx->current_limit_bps / 1000);
    fprintf(fp, "当前ping: %ld ms\n", ctx->filtered_ping_time_us / 1000);
    fprintf(fp, "最大ping: %ld ms\n", ctx->max_ping_time_us / 1000);
    fprintf(fp, "流量负载: %d kbps\n", ctx->filtered_total_load_bps / 1000);
    fprintf(fp, "已发送ping: %d\n", ctx->ntransmitted);
    fprintf(fp, "已接收ping: %d\n", ctx->nreceived);
    fprintf(fp, "队列算法: %s\n", ctx->detected_qdisc);
    fprintf(fp, "运行时间: %ld秒\n", ctx->stats.uptime_seconds);
    fprintf(fp, "总带宽调整: %ld次\n", ctx->stats.total_bandwidth_adjustments);
    fprintf(fp, "总错误数: %ld\n", ctx->stats.total_errors);
    fprintf(fp, "心跳检查: %ld次\n", ctx->stats.total_heartbeat_checks);
    fprintf(fp, "心跳超时: %ld次\n", ctx->stats.total_heartbeat_timeouts);
    time_t t = (time_t)(now / 1000);
    struct tm* tm_info = localtime(&t);
    char time_buf[26];
    strftime(time_buf, sizeof(time_buf), "%Y-%m-%d %H:%M:%S", tm_info);
    fprintf(fp, "最后更新: %s.%03ld\n", time_buf, (long)(now % 1000));
    fflush(fp);
    lock.l_type = F_UNLCK;
    fcntl(fd, F_SETLK, &lock);
    fclose(fp);
    // 原子重命名
    for (int i = 0; i < STATUS_FILE_RETRY_COUNT; i++) {
        if (rename(temp, ctx->config.status_file) == 0) break;
        usleep(STATUS_FILE_RETRY_DELAY_MS * 1000);
        if (i == STATUS_FILE_RETRY_COUNT - 1) {
            qosacc_log(ctx, QMON_LOG_ERROR, "重命名状态文件失败: %s\n", strerror(errno));
            unlink(temp);
            return QMON_ERR_FILE;
        }
    }
    last = now;
    return QMON_OK;
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
        qosacc_log(ctx, QMON_LOG_ERROR, "信号处理设置失败\n");
        return QMON_ERR_SIGNAL;
    }
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);
    return QMON_OK;
}

/* ==================== 清理 ==================== */
void qosacc_cleanup(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc) {
    qosacc_log(ctx, QMON_LOG_INFO, "清理资源...\n");
    if (!ctx->config.safe_mode) {
        int default_bw = ctx->config.max_bandwidth_kbps * 1000;
        tc_set_bandwidth(ctx, default_bw);
    }
    if (tc) tc_controller_cleanup(tc);
    if (pm) ping_manager_cleanup(pm);
    if (ctx->status_file) fclose(ctx->status_file);
    if (ctx->debug_log_file) fclose(ctx->debug_log_file);
    if (ctx->ping_socket >= 0) close(ctx->ping_socket);
}

/* ==================== 主函数 ==================== */
int main(int argc, char* argv[]) {
    int ret = EXIT_FAILURE;
    qosacc_context_t context = {0};
    ping_manager_t ping_mgr = {0};
    tc_controller_t tc_mgr = {0};

    if (argc == 1) {
        fprintf(stderr, "qosacc: 未提供参数，使用 -h 查看帮助\n");
        return EXIT_FAILURE;
    }

    qosacc_config_init(&context.config);
    int config_result = qosacc_config_parse(&context.config, argc, argv);
    if (config_result == QMON_HELP_REQUESTED) {
        fprintf(stderr, "%s", qosacc_usage);
        return EXIT_SUCCESS;
    }
    if (config_result != QMON_OK) {
        fprintf(stderr, "配置解析失败\n");
        return EXIT_FAILURE;
    }

    char err[256];
    if (qosacc_config_validate(&context.config, argc, argv, err, sizeof(err)) != QMON_OK) {
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
            qosacc_log(&context, QMON_LOG_WARN, "无法打开调试日志 %s\n", context.config.debug_log);
    }

    if (setup_signal_handlers(&context) != QMON_OK) goto cleanup;

    state_machine_init(&context);

    if (resolve_target(context.config.target, &context.target_addr, err, sizeof(err)) != QMON_OK) {
        qosacc_log(&context, QMON_LOG_ERROR, "解析目标失败: %s\n", err);
        goto cleanup;
    }

    if (ping_manager_init(&ping_mgr, &context) != QMON_OK) goto cleanup;
    if (tc_controller_init(&tc_mgr, &context) != QMON_OK) goto cleanup;

    if (setpriority(PRIO_PROCESS, 0, -10) < 0)
        qosacc_log(&context, QMON_LOG_WARN, "无法设置进程优先级\n");

    qosacc_log(&context, QMON_LOG_INFO,
        "======== qosacc 启动 ========\n"
        "目标: %s\n设备: %s\n最大带宽: %d kbps\nping间隔: %d ms\nping限制: %d ms\n队列: %s\n根类ID: %s\n安全模式: %s\n自动切换: %s\n",
        context.config.target, context.config.device,
        context.config.max_bandwidth_kbps,
        context.config.ping_interval,
        context.config.ping_limit_ms,
        context.detected_qdisc,
        context.config.root_classid,
        context.config.safe_mode ? "是" : "否",
        context.config.auto_switch_mode ? "是" : "否");

    context.state = QMON_CHK;
    context.last_heartbeat_ms = qosacc_time_ms();

    if (!context.config.skip_initial) {
        for (int i = 0; i < 5; i++) {
            ping_manager_send(&ping_mgr);
            usleep(context.config.ping_interval * 1000);
        }
    }

    struct pollfd fds[1];
    fds[0].fd = context.ping_socket;
    fds[0].events = POLLIN;

    atomic_store(&context.sigterm, atomic_load(&g_sigterm_received));
    atomic_store(&context.reset_bw, atomic_load(&g_reset_bw));

    while (!atomic_load(&context.sigterm)) {
        int64_t now = qosacc_time_ms();
        int64_t next_ping = context.last_ping_time_ms + context.config.ping_interval - now;
        int64_t next_stats = context.last_stats_time_ms + STATS_INTERVAL_MS - now;
        int64_t next_tc = context.last_tc_update_time_ms + CONTROL_INTERVAL_MS - now;
        int64_t next_heartbeat = context.last_heartbeat_ms + HEARTBEAT_INTERVAL_MS - now;
        int timeout = POLL_TIMEOUT_MS;
        if (next_ping > 0 && next_ping < timeout) timeout = next_ping;
        if (next_stats > 0 && next_stats < timeout) timeout = next_stats;
        if (next_tc > 0 && next_tc < timeout) timeout = next_tc;
        if (next_heartbeat > 0 && next_heartbeat < timeout) timeout = next_heartbeat;
        if (timeout <= 0) timeout = MIN_SLEEP_MS;
        if (timeout > context.config.check_interval) timeout = context.config.check_interval;

        int poll_ret = poll(fds, 1, timeout);
        int64_t poll_end = qosacc_time_ms();

        if (poll_ret < 0) {
            if (errno == EINTR) {
                atomic_store(&context.sigterm, atomic_load(&g_sigterm_received));
                atomic_store(&context.reset_bw, atomic_load(&g_reset_bw));
                atomic_fetch_add(&context.signal_counter, 1);
                continue;
            }
            qosacc_log(&context, QMON_LOG_ERROR, "poll失败: %s\n", strerror(errno));
            break;
        }

        if (poll_ret > 0 && (fds[0].revents & POLLIN)) {
            ping_manager_receive(&ping_mgr);
        }
        if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
            qosacc_log(&context, QMON_LOG_ERROR, "socket错误, revents=0x%x\n", fds[0].revents);
            break;
        }

        state_machine_run(&context, &ping_mgr, &tc_mgr);
        status_file_update(&context);

        atomic_store(&context.sigterm, atomic_load(&g_sigterm_received));
        atomic_store(&context.reset_bw, atomic_load(&g_reset_bw));
        if (atomic_load(&context.sigterm)) break;

        if (poll_end - now > 50)
            qosacc_log(&context, QMON_LOG_DEBUG, "循环耗时 %d ms\n", (int)(poll_end - now));
    }

    ret = EXIT_SUCCESS;

cleanup:
    qosacc_cleanup(&context, &ping_mgr, &tc_mgr);
    int64_t uptime = (qosacc_time_ms() - context.stats.start_time_ms) / 1000;
    qosacc_log(&context, QMON_LOG_INFO,
        "最终统计: 运行%ld秒, 发送%ld, 接收%ld, 丢失%ld, 调整%ld次, 最大ping%ldms, 最小ping%ldms\n",
        uptime,
        context.stats.total_ping_sent,
        context.stats.total_ping_received,
        context.stats.total_ping_lost,
        context.stats.total_bandwidth_adjustments,
        context.stats.max_ping_time_recorded / 1000,
        context.stats.min_ping_time_recorded / 1000);
    qosacc_log(&context, QMON_LOG_INFO, "qosacc 退出\n");

    if (context.config.background_mode) closelog();
    return ret;
}