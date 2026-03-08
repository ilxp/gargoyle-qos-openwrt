/* qosacc - 基于netlink的优化版QoS监控器
 * 功能：通过ping监控延迟，使用netlink动态调整ifb0根类的带宽
 * 基于Paul Bixel的原始代码优化,poll机制，完整支持HFSC\HTB\CAKE算法。
 * # 使用配置文件启动：qosacc -c /etc/qosacc.conf
 *  命令行参数覆盖配置文件：qosacc -c /etc/qosacc.conf -v -p 100 -t 1.1.1.1
 */
 
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <stdarg.h>  // 添加可变参数支持
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
#include <poll.h>  // 修复poll.h包含
#include <fcntl.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <sys/stat.h>

/* ==================== 宏定义 ==================== */
#define MAX_PACKET_SIZE 4096
#define PING_HISTORY_SIZE 10
#define MIN_PING_TIME_MS 1
#define MAX_PING_TIME_MS 5000
#define STATS_INTERVAL_MS 1000
#define CONTROL_INTERVAL_MS 1000
#define REALTIME_DETECT_MS 1000
#define HEARTBEAT_INTERVAL_MS 10000
#define POLL_TIMEOUT_MS 10  // poll 超时时间

// 修改日志宏定义，避免与系统定义冲突
#define QMON_LOG_ERROR 0
#define QMON_LOG_WARN  1
#define QMON_LOG_INFO  2
#define QMON_LOG_DEBUG 3

/* ==================== 返回码 ==================== */
typedef enum {
    QMON_OK = 0,
    QMON_ERR_MEMORY = -1,
    QMON_ERR_SOCKET = -2,
    QMON_ERR_FILE = -3,
    QMON_ERR_CONFIG = -4,
    QMON_ERR_SYSTEM = -5,
    QMON_ERR_SIGNAL = -6,
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
    QMON_CHK,
    QMON_INIT,
    QMON_IDLE,
    QMON_ACTIVE,
    QMON_REALTIME,
    QMON_EXIT
} qosacc_state_t;

/* ==================== 数据结构 ==================== */
typedef struct ping_history_s {
    int64_t times[PING_HISTORY_SIZE];
    int index;
    int count;
    float smoothed;
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
    
    // 文件
    FILE* status_file;
    FILE* debug_log_file;
    
    // 控制标志
    int sigterm;
} qosacc_context_t;

/* ==================== 帮助信息 ==================== */
const char qosacc_usage[] =
"qosacc - 基于netlink的精简版QoS监控器\n"
"版本: 基于Paul Bixel代码优化，支持poll机制与HFSC/HTB/CAKE\n\n"
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
"  -s <文件>        状态文件路径 (默认: /var/run/qosacc.status)\n"
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
// Ping管理器结构
struct ping_manager_s;
typedef struct ping_manager_s ping_manager_t;

// TC控制器结构
struct tc_controller_s;
typedef struct tc_controller_s tc_controller_t;

// Ping管理器函数
int ping_manager_init(ping_manager_t* pm, qosacc_context_t* ctx);
int ping_manager_send(ping_manager_t* pm);
int ping_manager_receive(ping_manager_t* pm);
void ping_manager_cleanup(ping_manager_t* pm);

// TC控制器函数
int tc_controller_init(tc_controller_t* tc, qosacc_context_t* ctx);
int tc_controller_set_bandwidth(tc_controller_t* tc, int bandwidth_bps);
void tc_controller_cleanup(tc_controller_t* tc);

// 配置函数
void qosacc_config_init(qosacc_config_t* cfg);
int qosacc_config_parse(qosacc_config_t* cfg, int argc, char* argv[]);
int qosacc_config_validate(qosacc_config_t* cfg, int argc, char* argv[], char* error, int error_len);

// 状态机函数
void state_machine_init(qosacc_context_t* ctx);
void state_machine_run(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc);

// 清理函数
void qosacc_cleanup(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc);

/* ==================== 辅助函数 ==================== */
int64_t qosacc_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
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
    
    va_list args;
    char buffer[1024];
    time_t now = time(NULL);
    struct tm* tm_info = localtime(&now);
    
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
        char time_str[32];
        strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S", tm_info);
        
        const char* level_str = "UNKNOWN";
        switch (level) {
            case QMON_LOG_ERROR: level_str = "ERROR"; break;
            case QMON_LOG_WARN:  level_str = "WARN"; break;
            case QMON_LOG_INFO:  level_str = "INFO"; break;
            case QMON_LOG_DEBUG: level_str = "DEBUG"; break;
        }
        
        if (ctx->config.verbose || level <= QMON_LOG_INFO) {
            fprintf(stderr, "[%s] [%s] %s", time_str, level_str, buffer);
        }
    }
    
    if (ctx->debug_log_file && (ctx->config.verbose || level <= QMON_LOG_INFO)) {
        char time_str[32];
        strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S", tm_info);
        const char* level_str = "UNKNOWN";
        switch (level) {
            case QMON_LOG_ERROR: level_str = "ERROR"; break;
            case QMON_LOG_WARN:  level_str = "WARN"; break;
            case QMON_LOG_INFO:  level_str = "INFO"; break;
            case QMON_LOG_DEBUG: level_str = "DEBUG"; break;
        }
        fprintf(ctx->debug_log_file, "[%s] [%s] %s", time_str, level_str, buffer);
        fflush(ctx->debug_log_file);
    }
}

/* ==================== 配置文件解析辅助函数 ==================== */
static void trim_whitespace(char* str) {
    if (!str) return;
    char* end;
    // 去除头部空格
    while (isspace((unsigned char)*str)) str++;
    if (*str == 0) return; // 全是空格
    // 去除尾部空格
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
    
    // 去除两端空格
    trim_whitespace(key);
    trim_whitespace(value);
    return 1;
}

/* ==================== 配置处理 ==================== */
void qosacc_config_init(qosacc_config_t* cfg) {
    if (!cfg) return;
    
    memset(cfg, 0, sizeof(qosacc_config_t));
	cfg->enabled = 1; // 默认启用
    cfg->ping_interval = 200;
    cfg->max_bandwidth_kbps = 10000;
    cfg->ping_limit_ms = 20;
    cfg->classid = 0x101;
    cfg->safe_mode = 0;
    cfg->verbose = 0;
    cfg->auto_switch_mode = 0;
    cfg->background_mode = 0;
    cfg->skip_initial = 0;
    cfg->min_bw_change_kbps = 10;	// 最小带宽变化阈值
    cfg->min_bw_ratio = 0.1f;	 // 最小带宽比例（最大带宽的10%）
    cfg->max_bw_ratio = 1.0f;	 // 最大带宽比例
    cfg->smoothing_factor = 0.3f;   // ping延迟平滑因子
    cfg->active_threshold = 0.7f;   // 切换到活跃状态的利用率阈值
    cfg->idle_threshold = 0.3f;    // 切换到空闲状态的利用率阈值
    cfg->safe_start_ratio = 0.5f;
	cfg->check_interval = 1000; // 默认1秒
    strcpy(cfg->device, "ifb0");
    strcpy(cfg->target, "8.8.8.8");
    strcpy(cfg->status_file, "/tmp/qosacc.status");
    strcpy(cfg->debug_log, "/var/log/qosacc.log");
}

/* ==================== [配置文件]解析函数 ==================== */
static int qosacc_config_parse_file(qosacc_config_t* cfg, const char* config_file) {
    if (!cfg || !config_file) return QMON_ERR_MEMORY;
    
    FILE* fp = fopen(config_file, "r");
    if (!fp) {
        fprintf(stderr, "无法打开配置文件: %s\n", config_file);
        return QMON_ERR_FILE;
    }
    
    char line[256];
    int in_device_section = 0;
    
    // 初始化为默认值
    qosacc_config_init(cfg);
    cfg->enabled = 0; // 默认不启用，直到在对应节中设置
    
    while (fgets(line, sizeof(line), fp)) {
        // 移除换行符
        char* newline = strchr(line, '\n');
        if (newline) *newline = '\0';
        newline = strchr(line, '\r');
        if (newline) *newline = '\0';
        
        // 跳过注释和空行
        if (line[0] == '#' || line[0] == ';' || line[0] == '\0') {
            continue;
        }
        
        // 检查节头 [device=DEVICE_NAME]
        if (line[0] == '[' && strchr(line, ']')) {
            char section[64];
            if (sscanf(line, "[%63[^]]]", section) == 1) {
                if (strncmp(section, "device=", 7) == 0) {
                    const char* device_name = section + 7;
                    if (strcmp(device_name, cfg->device) == 0) {
                        in_device_section = 1;
                        cfg->enabled = 1; // 找到对应设备的节，启用配置
                        continue;
                    } else {
                        in_device_section = 0; // 进入其他设备节，不再解析
                        continue;
                    }
                } else {
                    in_device_section = 0; // 进入其他类型的节，不再解析
                    continue;
                }
            }
        }
        
        // 如果在目标设备节内，解析键值对
        if (in_device_section) {
            char key[64], value[64];
            if (parse_key_value(line, key, sizeof(key), value, sizeof(value))) {
                // 映射键到配置结构体字段
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
                    cfg->check_interval = atoi(value) * 1000; // 转换为ms
                }
                // 注意：`device` 字段通常由节名决定，此处不解析
            }
        }
    }
    
    fclose(fp);
    
    if (!cfg->enabled) {
        fprintf(stderr, "警告：配置文件中未找到设备 '%s' 的启用配置。\n", cfg->device);
    }
    
    return QMON_OK;
}

/* ==================== [配置]解析函数 ==================== */
int qosacc_config_parse(qosacc_config_t* cfg, int argc, char* argv[]) {
    if (!cfg) return QMON_ERR_MEMORY;
    
    // 检查是否为帮助请求
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || 
            strcmp(argv[i], "-help") == 0 || 
            strcmp(argv[i], "--help") == 0) {
            return QMON_HELP_REQUESTED; // 特殊返回码
        }
    }
    
    // 设置默认值
    qosacc_config_init(cfg);
    
    // 第一遍：检查是否有 -c 参数，并优先解析配置文件
    int config_file_provided = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) {
            char* config_file = argv[++i];
            strncpy(cfg->config_file, config_file, sizeof(cfg->config_file) - 1);
            int ret = qosacc_config_parse_file(cfg, config_file);
            if (ret != QMON_OK) {
                return ret; // 配置文件解析失败
            }
            config_file_provided = 1;
            break; // 假设只有一个 -c 参数
        }
    }
    
    // 第二遍：解析命令行参数（覆盖配置文件设置）
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0) {
            i++; // 跳过已处理的配置文件路径
            continue;
        } else if (strcmp(argv[i], "-d") == 0 && i + 1 < argc) {
            strncpy(cfg->device, argv[++i], sizeof(cfg->device) - 1);
            // 如果提供了 -d 但之前加载过配置文件，需要重新检查设备节
            if (config_file_provided && strlen(cfg->config_file) > 0) {
                // 重新解析配置文件，以匹配新的设备名
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
        } else if (i == 1 && argc >= 4) { // 位置参数
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

/* ==================== 配置验证函数 ==================== */
int qosacc_config_validate(qosacc_config_t* cfg, int argc, char* argv[], char* error, int error_len) {
    // 检查是否只有程序名（没有参数）
    if (argc == 1) {
        snprintf(error, error_len, "未提供任何参数");
        return QMON_ERR_CONFIG;
    }
	
	if (!cfg || !error) return QMON_ERR_MEMORY;

    if (cfg->ping_interval < 50 || cfg->ping_interval > 5000) {
        snprintf(error, error_len, "ping间隔必须在50-5000ms之间");
        return QMON_ERR_CONFIG;
    }
    
    if (cfg->max_bandwidth_kbps < 100 || cfg->max_bandwidth_kbps > 1000000) {
        snprintf(error, error_len, "最大带宽必须在100-1000000kbps之间");
        return QMON_ERR_CONFIG;
    }
    
    if (cfg->ping_limit_ms < 5 || cfg->ping_limit_ms > 1000) {
        snprintf(error, error_len, "ping限制必须在5-1000ms之间");
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
    
    if (cfg->min_bw_ratio < 0.01f || cfg->min_bw_ratio > 0.5f) {
        snprintf(error, error_len, "最小带宽比例必须在0.01-0.5之间");
        return QMON_ERR_CONFIG;
    }
    
    if (cfg->max_bw_ratio < 0.5f || cfg->max_bw_ratio > 1.0f) {
        snprintf(error, error_len, "最大带宽比例必须在0.5-1.0之间");
        return QMON_ERR_CONFIG;
    }
    
    if (cfg->smoothing_factor <= 0.0f || cfg->smoothing_factor >= 1.0f) {
        snprintf(error, error_len, "平滑因子必须在0.0-1.0之间");
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
        triptime = (tv.tv_sec - tp->tv_sec) * 1000 + 
                   (tv.tv_usec - tp->tv_usec) / 1000;
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
        hist->smoothed = hist->smoothed * (1.0f - ctx->config.smoothing_factor) +
                          ctx->raw_ping_time_us * ctx->config.smoothing_factor;
    }
    
    ctx->filtered_ping_time_us = (int)hist->smoothed;
    
    qosacc_log(ctx, QMON_LOG_DEBUG, "收到ping回复: seq=%d, 时间=%dms, 平滑=%dms\n",
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

/* ==================== TC控制器实现（修复为调整总带宽） ==================== */
struct tc_controller_s {
    qosacc_context_t* ctx;
};

// 改进的队列检测函数
char* detect_qdisc_kind(qosacc_context_t* ctx) {
    static char qdisc_kind[16] = "htb";
    char cmd[256];
    char line[512];
    
    snprintf(cmd, sizeof(cmd), "tc -s qdisc show dev %s 2>&1", ctx->config.device);
    qosacc_log(ctx, QMON_LOG_DEBUG, "执行检测命令: %s\n", cmd);
    
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        qosacc_log(ctx, QMON_LOG_ERROR, "无法执行tc命令检测队列算法: %s\n", strerror(errno));
        return qdisc_kind;
    }
    
    int htb_found = 0, hfsc_found = 0, cake_found = 0;
    char* root_line = NULL;
    
    while (fgets(line, sizeof(line), fp)) {
        char* newline = strchr(line, '\n');
        if (newline) *newline = '\0';
        
        if (strlen(line) == 0) continue;
        
        qosacc_log(ctx, QMON_LOG_DEBUG, "TC输出: %s\n", line);
        
        // 检查根队列
        if (strstr(line, "root") != NULL) {
            if (strstr(line, "htb") != NULL) {
                htb_found = 1;
                strcpy(qdisc_kind, "htb");
                root_line = line;
                break;
            } else if (strstr(line, "hfsc") != NULL) {
                hfsc_found = 1;
                strcpy(qdisc_kind, "hfsc");
                root_line = line;
                break;
            } else if (strstr(line, "cake") != NULL) {
                cake_found = 1;
                strcpy(qdisc_kind, "cake");
                root_line = line;
                break;
            }
        }
        // 检查ingress队列
        else if (strstr(line, "ingress") != NULL) {
            if (strstr(line, "cake") != NULL) {
                cake_found = 1;
                strcpy(qdisc_kind, "cake");
                root_line = line;
                break;
            }
        }
    }
    
    pclose(fp);
    
    if (!htb_found && !hfsc_found && !cake_found) {
        qosacc_log(ctx, QMON_LOG_INFO, "未检测到现有队列，将使用HTB队列\n");
    } else {
        qosacc_log(ctx, QMON_LOG_INFO, "检测到队列算法: %s\n", qdisc_kind);
        if (root_line) {
            qosacc_log(ctx, QMON_LOG_DEBUG, "根队列信息: %s\n", root_line);
        }
    }
    
    return qdisc_kind;
}

// 获取根类ID
int get_root_classid(qosacc_context_t* ctx, int* root_classid) {
    if (!ctx || !root_classid) return QMON_ERR_MEMORY;
    
    char cmd[256];
    char line[512];
    int found = 0;
    
    // 默认根类ID
    *root_classid = 0x10001;  // 1:1
    
    // 尝试查找根类
    snprintf(cmd, sizeof(cmd), "tc -s class show dev %s 2>&1", ctx->config.device);
    
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        return QMON_ERR_SYSTEM;
    }
    
    while (fgets(line, sizeof(line), fp)) {
        // 查找根类（父类为root或1:0）
        if (strstr(line, "parent root") != NULL || 
            strstr(line, "parent 1:0") != NULL ||
            (strstr(line, "parent") == NULL && strstr(line, "class") != NULL)) {
            
            // 解析类ID
            int major, minor;
            if (sscanf(line, "class htb 1:%x", &minor) == 1) {
                *root_classid = 0x10000 | minor;
                found = 1;
                break;
            } else if (sscanf(line, "class hfsc 1:%x", &minor) == 1) {
                *root_classid = 0x10000 | minor;
                found = 1;
                break;
            }
        }
    }
    
    pclose(fp);
    
    if (found) {
        qosacc_log(ctx, QMON_LOG_DEBUG, "检测到根类ID: 1:%x\n", *root_classid & 0xFFFF);
    } else {
        qosacc_log(ctx, QMON_LOG_INFO, "使用默认根类ID: 1:1\n");
    }
    
    return QMON_OK;
}

// 获取CAKE参数
int get_cake_parameters(qosacc_context_t* ctx, char* cake_params, int params_len) {
    if (!ctx || !cake_params || params_len <= 0) return QMON_ERR_MEMORY;
    
    char cmd[256];
    char line[512];
    
    snprintf(cmd, sizeof(cmd), "tc qdisc show dev %s 2>&1", ctx->config.device);
    qosacc_log(ctx, QMON_LOG_DEBUG, "获取CAKE参数命令: %s\n", cmd);
    
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        return QMON_ERR_SYSTEM;
    }
    
    cake_params[0] = '\0';
    
    while (fgets(line, sizeof(line), fp)) {
        if (strstr(line, "cake") != NULL) {
            // 找到cake行，提取参数
            char* cake_start = strstr(line, "cake");
            if (cake_start) {
                cake_start += 4; // 跳过"cake"
                while (*cake_start == ' ') cake_start++;
                
                // 复制参数直到行尾
                char* end = strchr(cake_start, '\n');
                if (end) *end = '\0';
                
                strncpy(cake_params, cake_start, params_len - 1);
                cake_params[params_len - 1] = '\0';
                
                qosacc_log(ctx, QMON_LOG_DEBUG, "提取到的CAKE参数: %s\n", cake_params);
                break;
            }
        }
    }
    
    pclose(fp);
    
    if (strlen(cake_params) == 0) {
        // 如果没有找到现有参数，使用一些合理的默认值
        strcpy(cake_params, "besteffort dual-dsthost nat wash ingress rtt 100ms no-ack-filter split-gso");
        qosacc_log(ctx, QMON_LOG_INFO, "使用默认CAKE参数: %s\n", cake_params);
    }
    
    return QMON_OK;
}

// 改进的带宽设置函数，调整为总带宽
int tc_set_bandwidth(qosacc_context_t* ctx, int bandwidth_bps) {
    if (!ctx) return QMON_ERR_MEMORY;
    
    int bandwidth_kbps = (bandwidth_bps + 500) / 1000;
    
    // 确保带宽在合理范围内
    if (bandwidth_kbps < 1) bandwidth_kbps = 1;
    int max_bandwidth_kbps = ctx->config.max_bandwidth_kbps;
    if (bandwidth_kbps > max_bandwidth_kbps) {
        bandwidth_kbps = max_bandwidth_kbps;
    }
    
    // 检查带宽变化是否足够大
    if (ctx->last_tc_bw_kbps != 0) {
        int diff = bandwidth_kbps - ctx->last_tc_bw_kbps;
        if (diff < 0) diff = -diff;
        if (diff < ctx->config.min_bw_change_kbps) {
            qosacc_log(ctx, QMON_LOG_DEBUG, "跳过TC更新: 变化太小(%d -> %d kbps, 阈值=%d)\n",
                      ctx->last_tc_bw_kbps, bandwidth_kbps, ctx->config.min_bw_change_kbps);
            return QMON_OK;
        }
    }
    
    // 检测队列类型（如果需要）
    if (strlen(ctx->detected_qdisc) == 0) {
        char* qdisc_kind = detect_qdisc_kind(ctx);
        strncpy(ctx->detected_qdisc, qdisc_kind, sizeof(ctx->detected_qdisc) - 1);
        ctx->detected_qdisc[sizeof(ctx->detected_qdisc) - 1] = '\0';
    }
    
    char cmd[512];
    int ret = 0;
    char output_buf[512] = {0};
    
    if (strcmp(ctx->detected_qdisc, "hfsc") == 0) {
        // 获取根类ID
        int root_classid = 0;
        if (get_root_classid(ctx, &root_classid) != QMON_OK) {
            root_classid = 0x10001;  // 默认1:1
        }
        
        int major = (root_classid >> 16) & 0xFF;
        int minor = root_classid & 0xFFFF;
        
        // HFSC根类带宽设置
        int rt_bandwidth = bandwidth_kbps * 7 / 10;
        if (rt_bandwidth < 1) rt_bandwidth = 1;
        
        int burst_kbit = bandwidth_kbps / 8;
        if (burst_kbit < 2) burst_kbit = 2;
        
        // 使用"tc class change"调整根类带宽
        snprintf(cmd, sizeof(cmd), 
                 "tc class change dev %s parent %d:%x classid %d:%x hfsc "
                 "rt m1 %dkbit d 100ms m2 %dkbit "
                 "ls m1 0b d 0us m2 %dkbit "
                 "ul m1 0b d 0us m2 %dkbit 2>&1",
                 ctx->config.device, major, 0,  // 父类为1:0
                 major, minor,                  // 类ID
                 rt_bandwidth, rt_bandwidth,
                 bandwidth_kbps,
                 bandwidth_kbps);
    } 
    else if (strcmp(ctx->detected_qdisc, "cake") == 0) {
        // CAKE根队列带宽设置
        char cake_params[256] = {0};
        if (get_cake_parameters(ctx, cake_params, sizeof(cake_params)) != QMON_OK) {
            strcpy(cake_params, "besteffort dual-dsthost nat wash no-ack-filter split-gso");
        }
        
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
        
        // 检查是否是ingress队列
        char* is_ingress = strstr(cake_params, "ingress");
        
        if (is_ingress != NULL) {
            snprintf(cmd, sizeof(cmd), 
                     "tc qdisc change dev %s ingress cake bandwidth %s %s 2>&1",
                     ctx->config.device, bandwidth_str, cake_params);
        } else {
            snprintf(cmd, sizeof(cmd), 
                     "tc qdisc change dev %s root cake bandwidth %s %s 2>&1",
                     ctx->config.device, bandwidth_str, cake_params);
        }
    }
    else {
        // HTB根类带宽设置（默认）
        int root_classid = 0;
        if (get_root_classid(ctx, &root_classid) != QMON_OK) {
            root_classid = 0x10001;  // 默认1:1
        }
        
        int major = (root_classid >> 16) & 0xFF;
        int minor = root_classid & 0xFFFF;
        
        int burst_kbit = bandwidth_kbps / 8;
        if (burst_kbit < 2) burst_kbit = 2;
        
        int cburst_kbit = burst_kbit * 2;
        if (cburst_kbit < 4) cburst_kbit = 4;
        
        // 使用"tc class change"调整根类带宽
        // 注意：这里使用ceil=rate，表示不允许借用额外带宽
        snprintf(cmd, sizeof(cmd), 
                 "tc class change dev %s parent %d:%x classid %d:%x htb "
                 "rate %dkbit ceil %dkbit burst %dkbit cburst %dkbit 2>&1",
                 ctx->config.device, major, 0,  // 父类为1:0
                 major, minor,                  // 类ID
                 bandwidth_kbps, bandwidth_kbps, burst_kbit, cburst_kbit);
    }
    
    qosacc_log(ctx, QMON_LOG_INFO, "执行TC命令: %s\n", cmd);
    
    FILE* fp = popen(cmd, "r");
    if (fp) {
        char output[256];
        int output_len = 0;
        while (fgets(output, sizeof(output), fp)) {
            char* newline = strchr(output, '\n');
            if (newline) *newline = '\0';
            if (strlen(output) > 0) {
                strncpy(output_buf + output_len, output, sizeof(output_buf) - output_len - 1);
                output_len += strlen(output);
                if (output_len < sizeof(output_buf) - 1) {
                    output_buf[output_len++] = ';';
                }
                qosacc_log(ctx, QMON_LOG_DEBUG, "TC输出: %s\n", output);
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
        qosacc_log(ctx, QMON_LOG_ERROR, "TC命令执行失败: 返回码=%d, 输出=%s\n", 
                  ret, output_buf);
        
        // 如果失败，尝试回退到简单命令
        if (strcmp(ctx->detected_qdisc, "hfsc") == 0) {
            int root_classid = 0;
            if (get_root_classid(ctx, &root_classid) != QMON_OK) {
                root_classid = 0x10001;
            }
            
            int major = (root_classid >> 16) & 0xFF;
            int minor = root_classid & 0xFFFF;
            
            snprintf(cmd, sizeof(cmd), 
                     "tc class change dev %s parent %d:%x classid %d:%x hfsc ls m1 0b d 0us m2 %dkbit 2>&1",
                     ctx->config.device, major, 0, major, minor, bandwidth_kbps);
        } 
        else if (strcmp(ctx->detected_qdisc, "cake") == 0) {
            char bandwidth_str[32];
            if (bandwidth_kbps >= 1000) {
                double bandwidth_mbps = bandwidth_kbps / 1000.0;
                snprintf(bandwidth_str, sizeof(bandwidth_str), "%.2fMbit", bandwidth_mbps);
            } else {
                snprintf(bandwidth_str, sizeof(bandwidth_str), "%dKbit", bandwidth_kbps);
            }
            
            snprintf(cmd, sizeof(cmd), 
                     "tc qdisc change dev %s root cake bandwidth %s 2>&1",
                     ctx->config.device, bandwidth_str);
        }
        else {
            int root_classid = 0;
            if (get_root_classid(ctx, &root_classid) != QMON_OK) {
                root_classid = 0x10001;
            }
            
            int major = (root_classid >> 16) & 0xFF;
            int minor = root_classid & 0xFFFF;
            
            snprintf(cmd, sizeof(cmd), 
                     "tc class change dev %s parent %d:%x classid %d:%x htb rate %dkbit 2>&1",
                     ctx->config.device, major, 0, major, minor, bandwidth_kbps);
        }
        
        qosacc_log(ctx, QMON_LOG_INFO, "尝试简化命令: %s\n", cmd);
        
        fp = popen(cmd, "r");
        if (fp) {
            while (fgets(output_buf, sizeof(output_buf), fp)) {
                // 忽略输出
            }
            ret = pclose(fp);
            if (WIFEXITED(ret)) {
                ret = WEXITSTATUS(ret);
            }
        }
        
        if (ret != 0) {
            qosacc_log(ctx, QMON_LOG_ERROR, "简化TC命令也失败: 返回码=%d\n", ret);
            return QMON_ERR_SYSTEM;
        }
    }
    
    ctx->last_tc_bw_kbps = bandwidth_kbps;
    qosacc_log(ctx, QMON_LOG_INFO, "总带宽设置成功: %d kbps (算法: %s)\n", 
              bandwidth_kbps, ctx->detected_qdisc);
    
    return QMON_OK;
}

int tc_set_bandwidth_direct(qosacc_context_t* ctx, int bandwidth_bps) {
    if (!ctx) return QMON_ERR_MEMORY;
    return tc_set_bandwidth(ctx, bandwidth_bps);
}

// 改进的带宽检测，检测总带宽
int detect_total_bandwidth(qosacc_context_t* ctx, int* current_bw_kbps) {
    if (!ctx || !current_bw_kbps) return QMON_ERR_MEMORY;
    
    char cmd[256];
    char line[512];
    int found = 0;
    *current_bw_kbps = 0;
    
    if (strcmp(ctx->detected_qdisc, "cake") == 0) {
        // CAKE的带宽在qdisc中
        snprintf(cmd, sizeof(cmd), 
                 "tc -s qdisc show dev %s 2>&1", ctx->config.device);
        
        FILE* fp = popen(cmd, "r");
        if (!fp) {
            return QMON_ERR_SYSTEM;
        }
        
        while (fgets(line, sizeof(line), fp)) {
            if (strstr(line, "cake") != NULL) {
                char* bw_pos = strstr(line, "bandwidth");
                if (bw_pos) {
                    double bandwidth = 0;
                    char unit[8] = {0};
                    
                    if (sscanf(bw_pos, "bandwidth %lf%3s", &bandwidth, unit) == 2) {
                        if (strncmp(unit, "Gbit", 4) == 0) {
                            *current_bw_kbps = (int)(bandwidth * 1000000);
                        } else if (strncmp(unit, "Mbit", 4) == 0) {
                            *current_bw_kbps = (int)(bandwidth * 1000);
                        } else if (strncmp(unit, "Kbit", 4) == 0) {
                            *current_bw_kbps = (int)bandwidth;
                        } else if (strncmp(unit, "bit", 3) == 0) {
                            *current_bw_kbps = (int)(bandwidth / 1000);
                        }
                        
                        if (*current_bw_kbps > 0) {
                            found = 1;
                        }
                    }
                }
                break;
            }
        }
        
        pclose(fp);
    } else {
        // HTB/HFSC的带宽在根类中
        int root_classid = 0;
        if (get_root_classid(ctx, &root_classid) != QMON_OK) {
            root_classid = 0x10001;  // 默认1:1
        }
        
        int major = (root_classid >> 16) & 0xFF;
        int minor = root_classid & 0xFFFF;
        
        snprintf(cmd, sizeof(cmd), 
                 "tc -s -d class show dev %s 2>&1", ctx->config.device);
        
        FILE* fp = popen(cmd, "r");
        if (!fp) {
            return QMON_ERR_SYSTEM;
        }
        
        char target_class[32];
        snprintf(target_class, sizeof(target_class), "%d:%x", major, minor);
        
        while (fgets(line, sizeof(line), fp)) {
            if (strstr(line, target_class) != NULL) {
                // 尝试解析HTB参数
                char* rate_pos = strstr(line, "rate");
                if (rate_pos) {
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
                }
                
                // 尝试解析HFSC参数
                char* ls_pos = strstr(line, "ls m2");
                char* ul_pos = strstr(line, "ul m2");
                
                if (ls_pos) {
                    int rate_mbit, rate_kbit;
                    if (sscanf(ls_pos, "ls m2 %dMbit", &rate_mbit) == 1) {
                        *current_bw_kbps = rate_mbit * 1000;
                        found = 1;
                        break;
                    } else if (sscanf(ls_pos, "ls m2 %dkbit", &rate_kbit) == 1) {
                        *current_bw_kbps = rate_kbit;
                        found = 1;
                        break;
                    }
                } else if (ul_pos) {
                    int rate_mbit, rate_kbit;
                    if (sscanf(ul_pos, "ul m2 %dMbit", &rate_mbit) == 1) {
                        *current_bw_kbps = rate_mbit * 1000;
                        found = 1;
                        break;
                    } else if (sscanf(ul_pos, "ul m2 %dkbit", &rate_kbit) == 1) {
                        *current_bw_kbps = rate_kbit;
                        found = 1;
                        break;
                    }
                }
            }
        }
        
        pclose(fp);
    }
    
    if (found) {
        qosacc_log(ctx, QMON_LOG_DEBUG, "检测到当前总带宽: %d kbps\n", *current_bw_kbps);
    } else {
        qosacc_log(ctx, QMON_LOG_DEBUG, "未检测到总带宽信息\n");
    }
    
    return found ? QMON_OK : QMON_ERR_SYSTEM;
}

int tc_controller_init(tc_controller_t* tc, qosacc_context_t* ctx) {
    if (!tc || !ctx) return QMON_ERR_MEMORY;
    
    tc->ctx = ctx;
    
    char* qdisc_kind = detect_qdisc_kind(ctx);
    strncpy(ctx->detected_qdisc, qdisc_kind, sizeof(ctx->detected_qdisc) - 1);
    ctx->detected_qdisc[sizeof(ctx->detected_qdisc) - 1] = '\0';
    
    int current_bw_kbps = 0;
    if (detect_total_bandwidth(ctx, &current_bw_kbps) == QMON_OK) {
        ctx->last_tc_bw_kbps = current_bw_kbps;
        qosacc_log(ctx, QMON_LOG_INFO, "检测到当前总带宽: %d kbps (算法: %s)\n", 
                  current_bw_kbps, ctx->detected_qdisc);
    } else {
        qosacc_log(ctx, QMON_LOG_INFO, "使用新的带宽设置 (算法: %s)\n", ctx->detected_qdisc);
    }
    
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
    
    qosacc_log(ctx, QMON_LOG_INFO, "TC控制器清理完成\n");
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
    
    memset(&ctx->ping_history, 0, sizeof(ping_history_t));
    memset(ctx->detected_qdisc, 0, sizeof(ctx->detected_qdisc));
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
    
    float utilization = (float)ctx->filtered_total_load_bps / max_bps;
    
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
                  utilization * 100.0f);
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
    
    float utilization = (float)ctx->filtered_total_load_bps / max_bps;
    
    if (utilization < ctx->config.idle_threshold) {
        ctx->state = QMON_IDLE;
        qosacc_log(ctx, QMON_LOG_INFO, "切换到IDLE状态: 利用率=%.1f%%\n", 
                  utilization * 100.0f);
        return;
    }
    
    int current_plimit_us = ctx->config.ping_limit_ms * 1000;
    if (current_plimit_us <= 0) {
        current_plimit_us = 10000;
    }
    
    float error = ctx->filtered_ping_time_us - current_plimit_us;
    float error_ratio = error / (float)current_plimit_us;
    
    float adjust_factor = 1.0f;
    if (error_ratio < 0) {
        if (ctx->filtered_total_load_bps < ctx->current_limit_bps * 0.85f) {
            return;
        }
        adjust_factor = 1.0f - 0.002f * error_ratio;
    } else {
        adjust_factor = 1.0f - 0.004f * (error_ratio + 0.1f);
        if (adjust_factor < 0.85f) adjust_factor = 0.85f;
    }
    
    int old_limit = ctx->current_limit_bps;
    int new_limit = (int)(ctx->current_limit_bps * adjust_factor);
    
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
        qosacc_log(ctx, QMON_LOG_DEBUG, "心跳检测: 系统运行正常\n");
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 状态: %d\n", ctx->state);
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 当前带宽: %d kbps\n", ctx->current_limit_bps / 1000);
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 当前ping: %ld ms\n", ctx->filtered_ping_time_us / 1000);
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 最大ping: %ld ms\n", ctx->max_ping_time_us / 1000);
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 已发送ping: %d\n", ctx->ntransmitted);
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 已接收ping: %d\n", ctx->nreceived);
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 流量负载: %d kbps\n", ctx->filtered_total_load_bps / 1000);
        qosacc_log(ctx, QMON_LOG_DEBUG, "  - 检测队列算法: %s\n", ctx->detected_qdisc);
        
        last_heartbeat = now;
    }
}

void state_machine_run(qosacc_context_t* ctx, ping_manager_t* pm, tc_controller_t* tc) {
    if (!ctx || !pm || !tc) return;
    
    int64_t now = qosacc_time_ms();
    
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
    
    heart_beat_check(ctx);
    
    switch (ctx->state) {
        case QMON_CHK:
            state_machine_check(ctx, pm, tc);  // 添加 tc 参数
            break;
        case QMON_INIT:
            state_machine_init_state(ctx, tc);  // 添加 tc 参数
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
    
    if (!ctx->status_file) {
        ctx->status_file = fopen(ctx->config.status_file, "w");
        if (!ctx->status_file) {
            qosacc_log(ctx, QMON_LOG_ERROR, "无法打开状态文件: %s\n", strerror(errno));
            return QMON_ERR_FILE;
        }
    }
    
    // 使用%ld格式化int64_t
    fprintf(ctx->status_file, "状态: %d\n", ctx->state);
    fprintf(ctx->status_file, "当前带宽: %d kbps\n", ctx->current_limit_bps / 1000);
    fprintf(ctx->status_file, "当前ping: %ld ms\n", ctx->filtered_ping_time_us / 1000);
    fprintf(ctx->status_file, "最大ping: %ld ms\n", ctx->max_ping_time_us / 1000);
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
    // 空函数，通过全局变量控制退出
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
    qosacc_log(&context, QMON_LOG_INFO, "TC类ID: 0x%x\n", context.config.classid);
    qosacc_log(&context, QMON_LOG_INFO, "安全模式: %s\n", context.config.safe_mode ? "是" : "否");
    qosacc_log(&context, QMON_LOG_INFO, "自动切换: %s\n", context.config.auto_switch_mode ? "是" : "否");
    qosacc_log(&context, QMON_LOG_INFO, "详细输出: %s\n", context.config.verbose ? "启用" : "禁用");
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
        if (next_ping > 0 && next_ping < min_timeout) min_timeout = next_ping;
        if (next_stats > 0 && next_stats < min_timeout) min_timeout = next_stats;
        if (next_tc_update > 0 && next_tc_update < min_timeout) min_timeout = next_tc_update;
        if (next_realtime_detect > 0 && next_realtime_detect < min_timeout) min_timeout = next_realtime_detect;
        if (next_heartbeat > 0 && next_heartbeat < min_timeout) min_timeout = next_heartbeat;
        
        if (min_timeout <= 0) {
            min_timeout = 1;  // 至少等待1ms
        } else if (min_timeout > POLL_TIMEOUT_MS) {
            min_timeout = POLL_TIMEOUT_MS;
        }
        
        int poll_ret = poll(fds, 1, min_timeout);
        
        int64_t poll_end = qosacc_time_ms();
        int poll_elapsed = poll_end - now;
        
        if (poll_ret < 0) {
            if (errno == EINTR) {
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
    
    qosacc_log(&context, QMON_LOG_INFO, "QoS监控器已退出\n");
    
    if (context.config.background_mode) {
        closelog();
    }
    
    return ret;
}