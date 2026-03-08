/*
 * qosdba.c - QoS动态带宽分配器
 * 功能：监控各QoS分类的带宽使用率，实现分类间的动态带宽借用和归还
 * 支持同时监控下载(ifb0)和上传(pppoe-wan)两个设备
 * 统一配置文件：/etc/qosdba.conf
 * 版本：1.5.0（优化版本）
 * 优化特性：
 * 1. TC状态缓存 - 减少tc命令调用频率
 * 2. 批量命令执行 - 合并多个tc class change命令
 * 3. 异步监控 - 使用epoll监控TC统计文件
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <ctype.h>
#include <time.h>
#include <math.h>
#include <stdarg.h>      // 修复1: 添加 va_start, va_end 需要的头文件
#include <sys/types.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <dirent.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/epoll.h>
#include <sys/inotify.h>

/* ==================== 宏定义 ==================== */
#define QOSDBA_VERSION "1.5.0"
#define MAX_CLASSES 32              // 最大分类数
#define MAX_BORROW_RECORDS 64       // 最大借用记录数
#define MAX_CONFIG_LINE 256         // 配置文件单行最大长度
#define MAX_QDISC_KIND_LEN 16       // 队列算法名称最大长度
#define DEFAULT_CHECK_INTERVAL 1    // 默认检查间隔(秒)
#define DEFAULT_HIGH_UTIL_THRESHOLD 85   // 默认高使用率阈值(%)
#define DEFAULT_HIGH_UTIL_DURATION 5     // 默认高使用率持续时间(秒)
#define DEFAULT_LOW_UTIL_THRESHOLD 40    // 默认低使用率阈值(%)
#define DEFAULT_LOW_UTIL_DURATION 5      // 默认低使用率持续时间(秒)
#define DEFAULT_BORROW_RATIO 0.2f        // 默认借用比例
#define DEFAULT_MIN_BORROW_KBPS 128      // 默认最小借用带宽(kbps)
#define DEFAULT_MIN_CHANGE_KBPS 128      // 默认最小调整带宽(kbps)
#define DEFAULT_COOLDOWN_TIME 8          // 默认冷却时间(秒)
#define DEFAULT_RETURN_THRESHOLD 50      // 默认归还阈值(%)
#define DEFAULT_RETURN_SPEED 0.1f        // 默认归还速度(每秒归还比例)
#define MAX_CMD_OUTPUT 4096              // 命令输出最大长度
#define MAX_DEVICES 2                   // 最大设备数（下载和上传）
#define MAX_CMD_TIMEOUT_MS 5000         // 命令执行超时时间（毫秒）

/* ==================== 返回码 ==================== */
typedef enum {
    QOSDBA_OK = 0,
    QOSDBA_ERR_MEMORY = -1,
    QOSDBA_ERR_FILE = -2,
    QOSDBA_ERR_CONFIG = -3,
    QOSDBA_ERR_SYSTEM = -4,
    QOSDBA_ERR_TC = -5,
    QOSDBA_ERR_INVALID = -6,
    QOSDBA_ERR_NETWORK = -7,
    QOSDBA_ERR_TIMEOUT = -8
} qosdba_result_t;

/* ==================== 分类带宽配置 ==================== */
typedef struct {
    int classid;                   // 分类ID
    char name[32];                 // 分类名称
    int priority;                  // 优先级(数值越小优先级越高)
    int total_bw_kbps;             // 该类的总带宽(kbps) - 新增字段
    int min_bw_kbps;               // 最小保证带宽(kbps)
    int max_bw_kbps;               // 最大允许带宽(kbps)
} class_config_t;

/* ==================== 分类状态结构 ==================== */
typedef struct {
    int classid;                   // 分类ID
    int current_bw_kbps;           // 当前带宽(kbps)
    int used_bw_kbps;              // 当前使用的带宽(kbps)
    float utilization;             // 使用率(0.0-1.0)
    
    // 借用相关
    int borrowed_bw_kbps;          // 从其他分类借用的带宽(kbps)
    int lent_bw_kbps;              // 借给其他分类的带宽(kbps)
    
    // 时间统计
    int high_util_duration;        // 高使用率持续时间(秒)
    int low_util_duration;         // 低使用率持续时间(秒)
    int cooldown_timer;            // 冷却时间计数器(秒)
    int64_t last_check_time;       // 上次检查时间(毫秒)
    
    // 统计信息
    int64_t total_bytes;           // 总字节数
    int64_t last_total_bytes;      // 上次检查时的总字节数
    int peak_used_bw_kbps;         // 峰值使用带宽(kbps)
    int avg_used_bw_kbps;          // 平均使用带宽(kbps)
} class_state_t;

/* ==================== 优先级管理策略 ==================== */
typedef struct {
    int max_borrow_from_higher_priority;  // 是否允许从高优先级借用
    int allow_same_priority_borrow;       // 是否允许同优先级借用
    int max_borrow_percentage;            // 最多可借用百分比
    int min_lender_priority_gap;          // 最小优先级差距
} priority_policy_t;

/* ==================== 借用记录结构 ==================== */
typedef struct {
    int from_classid;              // 借出分类ID
    int to_classid;                // 借入分类ID
    int borrowed_bw_kbps;          // 借用的带宽(kbps)
    int64_t start_time;            // 借用开始时间(毫秒)
    int returned;                  // 是否已归还
} borrow_record_t;

/* ==================== TC统计缓存结构 ==================== */
typedef struct {
    char tc_stats_output[8192];     // 缓存的tc统计输出
    int64_t last_query_time;        // 上次查询时间
    int valid;                      // 缓存是否有效
    int query_interval_ms;          // 查询间隔(毫秒)
} tc_cache_t;

/* ==================== 批量命令结构 ==================== */
typedef struct {
    char commands[10][512];  // 命令缓冲区
    int command_count;       // 命令数量
    int max_commands;        // 最大命令数
} batch_commands_t;

/* ==================== 异步监控上下文 ==================== */
typedef struct {
    int epoll_fd;                   // epoll文件描述符
    int inotify_fd;                 // inotify文件描述符
    int watch_fd;                   // 监控的文件描述符
    int async_enabled;              // 异步监控是否启用
    int64_t last_async_check;       // 上次异步检查时间
} async_monitor_t;

/* ==================== 设备上下文结构 ==================== */
typedef struct {
    char device[16];               // 网络设备名
    int total_bandwidth_kbps;      // 总带宽(kbps)
    char qdisc_kind[MAX_QDISC_KIND_LEN];  // 队列算法类型
    
    // 分类管理
    class_config_t configs[MAX_CLASSES];  // 分类配置
    class_state_t states[MAX_CLASSES];    // 分类状态
    borrow_record_t records[MAX_BORROW_RECORDS];  // 借用记录
    int num_classes;               // 分类数量
    int num_records;               // 借用记录数量
    
    // TC统计缓存
    tc_cache_t tc_cache;           // TC统计缓存
    
    // 异步监控
    async_monitor_t async_monitor;  // 异步监控上下文
    
    // 批量命令
    batch_commands_t batch_cmds;   // 批量命令缓冲区
    
    // 借还参数
    int high_util_threshold;       // 高使用率阈值(%)
    int high_util_duration;        // 高使用率持续时间(秒)
    int low_util_threshold;        // 低使用率阈值(%)
    int low_util_duration;         // 低使用率持续时间(秒)
    float borrow_ratio;            // 借用比例(0.0-1.0)
    int min_borrow_kbps;           // 最小借用带宽(kbps)
    int min_change_kbps;           // 最小调整带宽(kbps)
    int cooldown_time;             // 冷却时间(秒)
    int auto_return_enable;        // 是否自动归还
    int return_threshold;          // 归还阈值(%)
    float return_speed;            // 归还速度(每秒归还比例)
    
    // 优先级管理
    priority_policy_t priority_policy;
    
    // 时间戳
    int64_t last_check_time;       // 上次检查时间(毫秒)
    
    // 统计信息
    int total_borrow_events;       // 总借用事件数
    int total_return_events;       // 总归还事件数
    int64_t total_borrowed_kbps;   // 累计借用带宽(kbps)
    int64_t total_returned_kbps;   // 累计归还带宽(kbps)
    
    // 控制标志
    int enabled;                   // 此设备是否启用
} device_context_t;

/* ==================== QoS上下文结构 ==================== */
typedef struct {
    // 控制标志
    int enabled;                   // 是否启用qosdba
    int debug_mode;                // 调试模式
    int safe_mode;                 // 安全模式(不实际修改TC)
    int reload_config;             // 重新加载配置标志
    
    // 设备管理
    device_context_t devices[MAX_DEVICES];  // 设备上下文数组
    int num_devices;               // 实际启用的设备数
    
    // 全局参数
    int check_interval;            // 检查间隔(秒)
    
    // 时间戳
    int64_t start_time;            // 启动时间(毫秒)
    int64_t config_mtime;          // 配置文件修改时间
    int64_t last_check_time;       // 上次检查时间(毫秒) - 修复4: 添加此成员
    
    // 文件句柄
    FILE* status_file;             // 状态文件
    FILE* log_file;                // 日志文件
    
    // 配置文件路径
    char config_path[256];         // 配置文件路径
} qosdba_context_t;

/* ==================== 全局上下文 ==================== */
static volatile sig_atomic_t g_should_exit = 0;
static volatile sig_atomic_t g_reload_config = 0;
static qosdba_context_t* g_ctx = NULL;

/* ==================== 函数声明 ==================== */
qosdba_result_t qosdba_init(qosdba_context_t* ctx);
qosdba_result_t qosdba_run(qosdba_context_t* ctx);
qosdba_result_t qosdba_cleanup(qosdba_context_t* ctx);
qosdba_result_t qosdba_update_status(qosdba_context_t* ctx, const char* status_file);
void qosdba_set_debug(qosdba_context_t* ctx, int enable);
void qosdba_set_safe_mode(qosdba_context_t* ctx, int enable);

/* ==================== 内部函数声明 ==================== */
static qosdba_result_t load_config_file(qosdba_context_t* ctx, const char* config_file);
static qosdba_result_t discover_tc_classes(device_context_t* dev_ctx);
static qosdba_result_t init_tc_classes(device_context_t* dev_ctx, qosdba_context_t* ctx);  // 修复2: 添加ctx参数
static qosdba_result_t check_bandwidth_usage(device_context_t* dev_ctx);
static void run_borrow_logic(device_context_t* dev_ctx, qosdba_context_t* ctx);  // 修复2: 添加ctx参数
static void run_return_logic(device_context_t* dev_ctx, qosdba_context_t* ctx);  // 修复2: 添加ctx参数
static qosdba_result_t adjust_class_bandwidth(device_context_t* dev_ctx, 
                                             qosdba_context_t* ctx,  // 修复2: 添加ctx参数
                                             int classid, int new_bw_kbps);
static int find_class_by_id(device_context_t* dev_ctx, int classid);
static int find_available_class_to_borrow(device_context_t* dev_ctx, 
                                         int exclude_classid, 
                                         int borrower_priority,
                                         int needed_bw_kbps);
static void add_borrow_record(device_context_t* dev_ctx, int from_classid, 
                             int to_classid, int borrowed_bw_kbps);
static void log_message(qosdba_context_t* ctx, const char* level, 
                       const char* format, ...);
static int64_t get_current_time_ms(void);
static int execute_command_with_timeout(const char* cmd, char* output, int output_len, int timeout_ms);
static int get_file_mtime(const char* filename);
static int is_valid_device_name(const char* name);
static void trim_whitespace(char* str);
static int parse_key_value(const char* line, char* key, int key_len, char* value, int value_len);
static int validate_config_parameters(device_context_t* dev_ctx);
static int check_config_reload(qosdba_context_t* ctx, const char* config_file);  // 修复3: 添加函数声明
static qosdba_result_t reload_config(qosdba_context_t* ctx, const char* config_file);  // 修复3: 添加函数声明

/* ==================== 优化函数声明 ==================== */
static qosdba_result_t update_tc_cache(device_context_t* dev_ctx);
static int parse_class_stats_from_cache(device_context_t* dev_ctx, int classid, unsigned long long* bytes);
static void add_to_batch_commands(batch_commands_t* batch, const char* cmd);
static qosdba_result_t execute_batch_commands(batch_commands_t* batch, qosdba_context_t* ctx);  // 修复2: 改为ctx参数
static qosdba_result_t init_async_monitor(device_context_t* dev_ctx);
static int check_async_events(device_context_t* dev_ctx);

/* ==================== 辅助函数 ==================== */
int64_t get_current_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

/* 移除字符串两端的空白字符 */
static void trim_whitespace(char* str) {
    if (!str) return;
    
    char* end;
    
    // 移除开头的空白字符
    while (isspace((unsigned char)*str)) str++;
    
    // 字符串为空的情况
    if (*str == 0) return;
    
    // 移除结尾的空白字符
    end = str + strlen(str) - 1;
    while (end > str && isspace((unsigned char)*end)) end--;
    
    // 写入新的结束符
    end[1] = '\0';
}

/* 验证设备名是否安全（只允许字母、数字、短横线、点） */
static int is_valid_device_name(const char* name) {
    if (!name || *name == '\0') return 0;
    
    for (int i = 0; name[i]; i++) {
        if (!isalnum((unsigned char)name[i]) && 
            name[i] != '-' && 
            name[i] != '.' && 
            name[i] != '_') {
            return 0;
        }
    }
    return 1;
}

/* 带超时的命令执行函数 */
static int execute_command_with_timeout(const char* cmd, char* output, int output_len, int timeout_ms) {
    if (!cmd || !output || output_len <= 0) return -1;
    
    // 验证命令中是否包含潜在的危险字符
    if (strstr(cmd, ";") || strstr(cmd, "&") || strstr(cmd, "|") || 
        strstr(cmd, "$") || strstr(cmd, "`") || strstr(cmd, ">") || 
        strstr(cmd, "<") || strstr(cmd, "\n") || strstr(cmd, "\r")) {
        return -1;
    }
    
    output[0] = '\0';
    
    // 使用popen执行命令
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        return -1;
    }
    
    // 设置非阻塞读取
    int fd = fileno(fp);
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    
    int total_read = 0;
    char buffer[256];
    int64_t start_time = get_current_time_ms();
    
    while (1) {
        int64_t now = get_current_time_ms();
        if (now - start_time > timeout_ms) {
            pclose(fp);
            return -2; // 超时
        }
        
        int n = fread(buffer, 1, sizeof(buffer) - 1, fp);
        if (n > 0) {
            buffer[n] = '\0';
            if (total_read + n < output_len - 1) {
                strcpy(output + total_read, buffer);
                total_read += n;
            } else {
                // 缓冲区不足，截断
                int remaining = output_len - total_read - 1;
                if (remaining > 0) {
                    strncpy(output + total_read, buffer, remaining);
                    total_read += remaining;
                }
                break;
            }
        } else if (feof(fp)) {
            break;
        } else if (ferror(fp)) {
            if (errno != EAGAIN && errno != EWOULDBLOCK) {
                break;
            }
            usleep(10000); // 10ms
        }
    }
    
    output[total_read] = '\0';
    int ret = pclose(fp);
    
    if (WIFEXITED(ret)) {
        return WEXITSTATUS(ret);
    }
    
    return -1;
}

void log_message(qosdba_context_t* ctx, const char* level, 
                const char* format, ...) {
    if (!ctx) return;
    
    char buffer[1024];
    time_t now = time(NULL);
    struct tm* tm_info = localtime(&now);
    
    char timestamp[32];
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", tm_info);
    
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    
    if (ctx->log_file) {
        fprintf(ctx->log_file, "[%s] [%s] %s", timestamp, level, buffer);
        fflush(ctx->log_file);
    }
    
    if (ctx->debug_mode) {
        fprintf(stderr, "[%s] [%s] %s", timestamp, level, buffer);
    }
}

int get_file_mtime(const char* filename) {
    struct stat st;
    if (stat(filename, &st) == 0) {
        return st.st_mtime;
    }
    return 0;
}

/* 解析键值对，支持值中包含空格 */
static int parse_key_value(const char* line, char* key, int key_len, char* value, int value_len) {
    if (!line || !key || !value) return 0;
    
    const char* equal_sign = strchr(line, '=');
    if (!equal_sign) return 0;
    
    // 复制键
    int key_len_to_copy = equal_sign - line;
    if (key_len_to_copy >= key_len) key_len_to_copy = key_len - 1;
    strncpy(key, line, key_len_to_copy);
    key[key_len_to_copy] = '\0';
    
    // 复制值
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

/* 验证配置参数的有效性 */
static int validate_config_parameters(device_context_t* dev_ctx) {
    if (!dev_ctx) return 0;
    
    // 验证总带宽
    if (dev_ctx->total_bandwidth_kbps <= 0 || dev_ctx->total_bandwidth_kbps > 10000000) {
        log_message(NULL, "ERROR", "设备 %s 的总带宽无效: %d kbps\n", 
                   dev_ctx->device, dev_ctx->total_bandwidth_kbps);
        return 0;
    }
    
    // 验证阈值参数
    if (dev_ctx->high_util_threshold <= dev_ctx->low_util_threshold) {
        log_message(NULL, "ERROR", "设备 %s 的高使用率阈值(%d%%)必须大于低使用率阈值(%d%%)\n",
                   dev_ctx->device, dev_ctx->high_util_threshold, dev_ctx->low_util_threshold);
        return 0;
    }
    
    if (dev_ctx->high_util_threshold < 50 || dev_ctx->high_util_threshold > 100) {
        log_message(NULL, "ERROR", "设备 %s 的高使用率阈值(%d%%)超出范围(50-100)\n",
                   dev_ctx->device, dev_ctx->high_util_threshold);
        return 0;
    }
    
    if (dev_ctx->low_util_threshold < 10 || dev_ctx->low_util_threshold > 80) {
        log_message(NULL, "ERROR", "设备 %s 的低使用率阈值(%d%%)超出范围(10-80)\n",
                   dev_ctx->device, dev_ctx->low_util_threshold);
        return 0;
    }
    
    // 验证借用比例
    if (dev_ctx->borrow_ratio < 0.01f || dev_ctx->borrow_ratio > 1.0f) {
        log_message(NULL, "ERROR", "设备 %s 的借用比例(%.2f)超出范围(0.01-1.0)\n",
                   dev_ctx->device, dev_ctx->borrow_ratio);
        return 0;
    }
    
    // 验证最小调整带宽
    if (dev_ctx->min_change_kbps <= 0) {
        log_message(NULL, "ERROR", "设备 %s 的最小调整带宽(%d kbps)必须大于0\n",
                   dev_ctx->device, dev_ctx->min_change_kbps);
        return 0;
    }
    
    // 验证分类配置
    int total_class_bandwidth = 0;
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_config_t* config = &dev_ctx->configs[i];
        
        if (config->min_bw_kbps > config->max_bw_kbps) {
            log_message(NULL, "ERROR", "分类 %s 的最小带宽(%d)大于最大带宽(%d)\n",
                       config->name, config->min_bw_kbps, config->max_bw_kbps);
            return 0;
        }
        
        if (config->total_bw_kbps < config->min_bw_kbps || 
            config->total_bw_kbps > config->max_bw_kbps) {
            log_message(NULL, "ERROR", "分类 %s 的总带宽(%d)不在最小-最大范围内(%d-%d)\n",
                       config->name, config->total_bw_kbps, 
                       config->min_bw_kbps, config->max_bw_kbps);
            return 0;
        }
        
        total_class_bandwidth += config->total_bw_kbps;
    }
    
    // 检查分类总带宽是否超过设备总带宽
    if (total_class_bandwidth > dev_ctx->total_bandwidth_kbps * 1.2f) { // 允许20%的溢出
        log_message(NULL, "WARN", "设备 %s 的分类总带宽(%d kbps)超过设备总带宽(%d kbps)\n",
                   dev_ctx->device, total_class_bandwidth, dev_ctx->total_bandwidth_kbps);
    }
    
    return 1;
}

/* ==================== 信号处理函数 ==================== */
static void signal_handler(int sig) {
    switch (sig) {
        case SIGTERM:
        case SIGINT:
        case SIGQUIT:
            g_should_exit = 1;  // 使用原子变量
            break;
        case SIGHUP:
            g_reload_config = 1;  // 使用原子变量
            break;
    }
}

/* ==================== 设置信号处理器 ==================== */
static void setup_signal_handlers(void) {
    struct sigaction sa;
    sa.sa_handler = signal_handler;
    sa.sa_flags = 0;
    sigemptyset(&sa.sa_mask);
    
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGQUIT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);  // 添加SIGHUP处理器
    
    signal(SIGPIPE, SIG_IGN);
    signal(SIGALRM, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);
}

/* ==================== 加载统一配置文件 ==================== */
static qosdba_result_t load_config_file(qosdba_context_t* ctx, const char* config_file) {
    if (!ctx || !config_file) return QOSDBA_ERR_MEMORY;
    
    FILE* fp = fopen(config_file, "r");
    if (!fp) {
        log_message(ctx, "ERROR", "无法打开配置文件: %s\n", config_file);
        return QOSDBA_ERR_FILE;
    }
    
    char line[MAX_CONFIG_LINE];
    int line_num = 0;
    device_context_t* current_dev = NULL;
    int device_count = 0;
    
    // 重置设备上下文
    for (int i = 0; i < MAX_DEVICES; i++) {
        memset(&ctx->devices[i], 0, sizeof(device_context_t));
    }
    ctx->num_devices = 0;
    
    // 读取配置文件
    while (fgets(line, sizeof(line), fp) && device_count < MAX_DEVICES) {
        line_num++;
        
        // 移除换行符
        char* newline = strchr(line, '\n');
        if (newline) *newline = '\0';
        
        // 移除尾部的回车符
        newline = strchr(line, '\r');
        if (newline) *newline = '\0';
        
        // 跳过注释行和空行
        if (line[0] == '#' || line[0] == '\0') {
            continue;
        }
        
        // 检查是否是节头
        if (line[0] == '[' && strchr(line, ']')) {
            char section[64];
            if (sscanf(line, "[%63[^]]]", section) == 1) {
                // 检查是否是设备节
                if (strncmp(section, "device=", 7) == 0) {
                    const char* device_name = section + 7;
                    
                    // 验证设备名
                    if (!is_valid_device_name(device_name)) {
                        log_message(ctx, "ERROR", "设备名无效: %s\n", device_name);
                        continue;
                    }
                    
                    // 查找或创建设备上下文
                    int dev_idx = -1;
                    for (int i = 0; i < device_count; i++) {
                        if (strcmp(ctx->devices[i].device, device_name) == 0) {
                            dev_idx = i;
                            break;
                        }
                    }
                    
                    if (dev_idx == -1) {
                        dev_idx = device_count;
                        device_count++;
                        ctx->num_devices = device_count;
                    }
                    
                    current_dev = &ctx->devices[dev_idx];
                    strncpy(current_dev->device, device_name, sizeof(current_dev->device)-1);
                    current_dev->device[sizeof(current_dev->device)-1] = '\0';
                    current_dev->enabled = 1;  // 默认启用
                    
                    // 初始化批量命令缓冲区
                    current_dev->batch_cmds.max_commands = 10;
                    current_dev->batch_cmds.command_count = 0;
                    
                    // 设置默认优先级策略
                    current_dev->priority_policy.max_borrow_from_higher_priority = 0;
                    current_dev->priority_policy.allow_same_priority_borrow = 0;
                    current_dev->priority_policy.max_borrow_percentage = 100;
                    current_dev->priority_policy.min_lender_priority_gap = 1;
                    
                    log_message(ctx, "DEBUG", "找到设备节: %s\n", device_name);
                } else if (strcmp(section, "download") == 0 || 
                          strcmp(section, "upload") == 0) {
                    const char* device_name = (strcmp(section, "download") == 0) ? "ifb0" : "pppoe-wan";
                    
                    int dev_idx = -1;
                    for (int i = 0; i < device_count; i++) {
                        if (strcmp(ctx->devices[i].device, device_name) == 0) {
                            dev_idx = i;
                            break;
                        }
                    }
                    
                    if (dev_idx == -1) {
                        dev_idx = device_count;
                        device_count++;
                        ctx->num_devices = device_count;
                    }
                    
                    current_dev = &ctx->devices[dev_idx];
                    strncpy(current_dev->device, device_name, sizeof(current_dev->device)-1);
                    current_dev->device[sizeof(current_dev->device)-1] = '\0';
                    current_dev->enabled = 1;
                    
                    // 初始化批量命令缓冲区
                    current_dev->batch_cmds.max_commands = 10;
                    current_dev->batch_cmds.command_count = 0;
                    
                    // 设置默认优先级策略
                    current_dev->priority_policy.max_borrow_from_higher_priority = 0;
                    current_dev->priority_policy.allow_same_priority_borrow = 0;
                    current_dev->priority_policy.max_borrow_percentage = 100;
                    current_dev->priority_policy.min_lender_priority_gap = 1;
                    
                    log_message(ctx, "DEBUG", "找到传统设备节: %s -> 设备: %s\n", 
                               section, device_name);
                } else {
                    // 其他节，重置当前设备
                    current_dev = NULL;
                }
            }
            continue;
        }
        
        // 如果当前有设备上下文，处理配置行
        if (current_dev) {
            char key[64], value[64];
            if (parse_key_value(line, key, sizeof(key), value, sizeof(value))) {
                if (strcmp(key, "enabled") == 0) {
                    current_dev->enabled = atoi(value);
                } else if (strcmp(key, "total_bandwidth_kbps") == 0) {
                    current_dev->total_bandwidth_kbps = atoi(value);
                } else if (strcmp(key, "interval") == 0) {
                    ctx->check_interval = atoi(value);
                } else if (strcmp(key, "min_change_kbps") == 0) {
                    current_dev->min_change_kbps = atoi(value);
                } else if (strcmp(key, "high_util_threshold") == 0) {
                    current_dev->high_util_threshold = atoi(value);
                } else if (strcmp(key, "high_util_duration") == 0) {
                    current_dev->high_util_duration = atoi(value);
                } else if (strcmp(key, "low_util_threshold") == 0) {
                    current_dev->low_util_threshold = atoi(value);
                } else if (strcmp(key, "low_util_duration") == 0) {
                    current_dev->low_util_duration = atoi(value);
                } else if (strcmp(key, "borrow_ratio") == 0) {
                    current_dev->borrow_ratio = atof(value);
                } else if (strcmp(key, "min_borrow_kbps") == 0) {
                    current_dev->min_borrow_kbps = atoi(value);
                } else if (strcmp(key, "cooldown_time") == 0) {
                    current_dev->cooldown_time = atoi(value);
                } else if (strcmp(key, "auto_return_enable") == 0) {
                    current_dev->auto_return_enable = atoi(value);
                } else if (strcmp(key, "return_threshold") == 0) {
                    current_dev->return_threshold = atoi(value);
                } else if (strcmp(key, "return_speed") == 0) {
                    current_dev->return_speed = atof(value);
                } else if (strcmp(key, "safe_mode") == 0) {
                    ctx->safe_mode = atoi(value);
                } else if (strcmp(key, "debug_mode") == 0) {
                    ctx->debug_mode = atoi(value);
                } else if (strcmp(key, "cache_interval") == 0) {
                    int interval = atoi(value);
                    if (interval > 0) {
                        current_dev->tc_cache.query_interval_ms = interval * 1000;
                    }
                }
            } 
            // 尝试解析为分类配置行
            else {
                int classid;
                char name[32];
                int priority, total_bw_kbps, min_bw_kbps, max_bw_kbps;
                
                int parsed = sscanf(line, "0x%x,%31[^,],%d,%d,%d,%d", 
                                   &classid, name, &priority, 
                                   &total_bw_kbps, &min_bw_kbps, &max_bw_kbps);
                
                if (parsed == 6 && current_dev->num_classes < MAX_CLASSES) {
                    class_config_t* config = &current_dev->configs[current_dev->num_classes];
                    config->classid = classid;
                    strncpy(config->name, name, sizeof(config->name) - 1);
                    config->name[sizeof(config->name)-1] = '\0';
                    config->priority = priority;
                    config->total_bw_kbps = total_bw_kbps;
                    config->min_bw_kbps = min_bw_kbps;
                    config->max_bw_kbps = max_bw_kbps;
                    
                    current_dev->num_classes++;
                    
                    log_message(ctx, "DEBUG", "加载分类: ID=0x%x, 名称=%s, 优先级=%d, "
                              "总带宽=%dkbps, 最小=%dkbps, 最大=%dkbps\n",
                              classid, name, priority, 
                              total_bw_kbps, min_bw_kbps, max_bw_kbps);
                }
            }
        }
    }
    
    fclose(fp);
    
    if (ctx->num_devices == 0) {
        log_message(ctx, "ERROR", "配置文件中没有找到有效的设备配置\n");
        return QOSDBA_ERR_CONFIG;
    }
    
    // 验证每个设备的配置参数
    for (int i = 0; i < ctx->num_devices; i++) {
        if (!validate_config_parameters(&ctx->devices[i])) {
            return QOSDBA_ERR_CONFIG;
        }
    }
    
    // 记录配置文件的修改时间
    ctx->config_mtime = get_file_mtime(config_file);
    strncpy(ctx->config_path, config_file, sizeof(ctx->config_path)-1);
    
    return QOSDBA_OK;
}

/* ==================== TC分类发现 ==================== */
static qosdba_result_t discover_tc_classes(device_context_t* dev_ctx) {
    if (!dev_ctx) return QOSDBA_ERR_MEMORY;
    
    char cmd[256];
    char output[MAX_CMD_OUTPUT];
    int discovered = 0;
    
    // 验证设备名
    if (!is_valid_device_name(dev_ctx->device)) {
        log_message(NULL, "ERROR", "设备名无效: %s\n", dev_ctx->device);
        return QOSDBA_ERR_INVALID;
    }
    
    snprintf(cmd, sizeof(cmd), "tc qdisc show dev %s 2>&1", dev_ctx->device);
    
    int ret = execute_command_with_timeout(cmd, output, sizeof(output), MAX_CMD_TIMEOUT_MS);
    if (ret != 0) {
        return QOSDBA_ERR_TC;
    }
    
    if (strstr(output, "htb") != NULL) {
        strcpy(dev_ctx->qdisc_kind, "htb");
    } else if (strstr(output, "hfsc") != NULL) {
        strcpy(dev_ctx->qdisc_kind, "hfsc");
    } else if (strstr(output, "cake") != NULL) {
        strcpy(dev_ctx->qdisc_kind, "cake");
    } else {
        strcpy(dev_ctx->qdisc_kind, "htb");
    }
    
    snprintf(cmd, sizeof(cmd), "tc -s class show dev %s 2>&1", dev_ctx->device);
    
    ret = execute_command_with_timeout(cmd, output, sizeof(output), MAX_CMD_TIMEOUT_MS);
    if (ret != 0) {
        return QOSDBA_ERR_TC;
    }
    
    char* line = strtok(output, "\n");
    while (line != NULL) {
        int major, minor;
        if (sscanf(line, "class htb %d:%d", &major, &minor) == 2 ||
            sscanf(line, "class hfsc %d:%d", &major, &minor) == 2) {
            
            int classid = (major << 16) | minor;
            
            if (classid == 0x10000) {
                line = strtok(NULL, "\n");
                continue;
            }
            
            int found = 0;
            for (int i = 0; i < dev_ctx->num_classes; i++) {
                if (dev_ctx->configs[i].classid == classid) {
                    found = 1;
                    break;
                }
            }
            
            if (!found) {
                if (dev_ctx->num_classes < MAX_CLASSES) {
                    class_config_t* config = &dev_ctx->configs[dev_ctx->num_classes];
                    config->classid = classid;
                    snprintf(config->name, sizeof(config->name), 
                            "discovered-%d:%d", major, minor);
                    config->priority = minor;
                    
                    // 为新发现的分类设置默认带宽
                    config->total_bw_kbps = dev_ctx->total_bandwidth_kbps / 10;  // 10% of total
                    config->min_bw_kbps = 64;
                    config->max_bw_kbps = dev_ctx->total_bandwidth_kbps / 5;  // 20% of total
                    
                    dev_ctx->num_classes++;
                    discovered++;
                }
            }
        }
        
        line = strtok(NULL, "\n");
    }
    
    return QOSDBA_OK;
}

/* ==================== 初始化TC分类 ==================== */
static qosdba_result_t init_tc_classes(device_context_t* dev_ctx, qosdba_context_t* ctx) {
    if (!dev_ctx || !ctx) return QOSDBA_ERR_MEMORY;
    
    char cmd[512];
    int success_count = 0;
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_config_t* config = &dev_ctx->configs[i];
        class_state_t* state = &dev_ctx->states[i];
        
        state->classid = config->classid;
        // 初始带宽设为最小和最大中间值
        state->current_bw_kbps = (config->min_bw_kbps + config->max_bw_kbps) / 2;
        state->used_bw_kbps = 0;
        state->utilization = 0.0f;
        state->borrowed_bw_kbps = 0;
        state->lent_bw_kbps = 0;
        state->high_util_duration = 0;
        state->low_util_duration = 0;
        state->cooldown_timer = 0;
        state->last_check_time = get_current_time_ms();
        state->total_bytes = 0;
        state->last_total_bytes = 0;
        state->peak_used_bw_kbps = 0;
        state->avg_used_bw_kbps = 0;
        
        int major = (config->classid >> 16) & 0xFF;
        int minor = config->classid & 0xFFFF;
        
        if (ctx->safe_mode) {  // 修复2: 改为 ctx->safe_mode
            // 安全模式，不实际执行命令
            log_message(NULL, "DEBUG", "[安全模式] 将为分类 0x%x 设置带宽: %d kbps\n", 
                       config->classid, state->current_bw_kbps);
            success_count++;
            continue;
        }
        
        if (strcmp(dev_ctx->qdisc_kind, "hfsc") == 0) {
            snprintf(cmd, sizeof(cmd),
                     "tc class add dev %s parent 1:0 classid %d:%d hfsc "
                     "ls m1 0b d 0us m2 %dkbit "
                     "ul m1 0b d 0us m2 %dkbit 2>&1 || "
                     "tc class change dev %s parent 1:0 classid %d:%d hfsc "
                     "ls m1 0b d 0us m2 %dkbit "
                     "ul m1 0b d 0us m2 %dkbit 2>&1",
                     dev_ctx->device, major, minor, 
                     state->current_bw_kbps, state->current_bw_kbps,
                     dev_ctx->device, major, minor,
                     state->current_bw_kbps, state->current_bw_kbps);
        } else if (strcmp(dev_ctx->qdisc_kind, "cake") == 0) {
            continue;
        } else {
            int burst = state->current_bw_kbps / 8;
            if (burst < 2) burst = 2;
            
            snprintf(cmd, sizeof(cmd),
                     "tc class add dev %s parent 1:0 classid %d:%d htb "
                     "rate %dkbit ceil %dkbit burst %dkbit 2>&1 || "
                     "tc class change dev %s parent 1:0 classid %d:%d htb "
                     "rate %dkbit ceil %dkbit burst %dkbit 2>&1",
                     dev_ctx->device, major, minor,
                     state->current_bw_kbps, state->current_bw_kbps, burst,
                     dev_ctx->device, major, minor,
                     state->current_bw_kbps, state->current_bw_kbps, burst);
        }
        
        char output[MAX_CMD_OUTPUT];
        int ret = execute_command_with_timeout(cmd, output, sizeof(output), MAX_CMD_TIMEOUT_MS);
        
        if (ret == 0) {
            success_count++;
        } else {
            log_message(NULL, "ERROR", "初始化分类 0x%x 失败: %s\n", 
                       config->classid, output);
        }
    }
    
    if (success_count == dev_ctx->num_classes) {
        return QOSDBA_OK;
    } else {
        return QOSDBA_ERR_TC;
    }
}

/* ==================== 查找分类 ==================== */
static int find_class_by_id(device_context_t* dev_ctx, int classid) {
    if (!dev_ctx) return -1;
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        if (dev_ctx->states[i].classid == classid) {
            return i;
        }
    }
    
    return -1;
}

/* ==================== 更新TC统计缓存 ==================== */
static qosdba_result_t update_tc_cache(device_context_t* dev_ctx) {
    if (!dev_ctx) return QOSDBA_ERR_MEMORY;
    
    int64_t now = get_current_time_ms();
    
    // 检查缓存是否过期（默认5秒）
    if (dev_ctx->tc_cache.valid && 
        (now - dev_ctx->tc_cache.last_query_time) < dev_ctx->tc_cache.query_interval_ms) {
        return QOSDBA_OK;  // 缓存有效
    }
    
    char cmd[256];
    char output[8192];
    
    // 批量获取所有分类的统计信息
    snprintf(cmd, sizeof(cmd), "tc -s -p -h class show dev %s 2>&1", dev_ctx->device);
    
    int ret = execute_command_with_timeout(cmd, output, sizeof(output), MAX_CMD_TIMEOUT_MS);
    if (ret == 0) {
        strncpy(dev_ctx->tc_cache.tc_stats_output, output, sizeof(dev_ctx->tc_cache.tc_stats_output)-1);
        dev_ctx->tc_cache.tc_stats_output[sizeof(dev_ctx->tc_cache.tc_stats_output)-1] = '\0';
        dev_ctx->tc_cache.last_query_time = now;
        dev_ctx->tc_cache.valid = 1;
        dev_ctx->tc_cache.query_interval_ms = 5000;  // 默认5秒更新一次
        
        log_message(NULL, "DEBUG", "TC统计缓存更新完成，设备: %s\n", dev_ctx->device);
        return QOSDBA_OK;
    } else {
        dev_ctx->tc_cache.valid = 0;
        return QOSDBA_ERR_TC;
    }
}

/* ==================== 从缓存中解析分类统计 ==================== */
static int parse_class_stats_from_cache(device_context_t* dev_ctx, int classid, unsigned long long* bytes) {
    if (!dev_ctx || !bytes || !dev_ctx->tc_cache.valid) return 0;
    
    int major = (classid >> 16) & 0xFF;
    int minor = classid & 0xFFFF;
    
    char search_pattern[32];
    snprintf(search_pattern, sizeof(search_pattern), "class %s %d:%d", 
             dev_ctx->qdisc_kind, major, minor);
    
    char* line_start = strstr(dev_ctx->tc_cache.tc_stats_output, search_pattern);
    if (!line_start) return 0;
    
    // 找到该行的开始
    char* line_end = strchr(line_start, '\n');
    if (!line_end) line_end = line_start + strlen(line_start);
    
    // 复制一行进行分析
    char line[256];
    int line_len = line_end - line_start;
    if (line_len >= sizeof(line)) line_len = sizeof(line) - 1;
    strncpy(line, line_start, line_len);
    line[line_len] = '\0';
    
    // 解析字节数
    char* bytes_ptr = strstr(line, "bytes");
    if (bytes_ptr) {
        // 向后查找数字
        for (char* p = bytes_ptr; p > line; p--) {
            if (isdigit((unsigned char)*p) && (p == line || !isdigit((unsigned char)*(p-1)))) {
                char* endptr;
                *bytes = strtoull(p, &endptr, 10);
                if (endptr != p) {
                    return 1;
                }
            }
        }
    }
    
    return 0;
}

/* ==================== 检查带宽使用率（使用缓存） ==================== */
static qosdba_result_t check_bandwidth_usage(device_context_t* dev_ctx) {
    if (!dev_ctx || dev_ctx->num_classes == 0) return QOSDBA_ERR_MEMORY;
    
    int64_t now = get_current_time_ms();
    
    // 更新TC统计缓存
    qosdba_result_t cache_ret = update_tc_cache(dev_ctx);
    if (cache_ret != QOSDBA_OK) {
        log_message(NULL, "WARN", "TC统计缓存更新失败，设备: %s\n", dev_ctx->device);
    }
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_state_t* state = &dev_ctx->states[i];
        class_config_t* config = &dev_ctx->configs[i];
        
        unsigned long long bytes = 0;
        int got_stats = 0;
        
        if (dev_ctx->tc_cache.valid) {
            // 尝试从缓存中获取统计信息
            got_stats = parse_class_stats_from_cache(dev_ctx, state->classid, &bytes);
        }
        
        if (!got_stats) {
            // 缓存失败，回退到原始方法
            int major = (state->classid >> 16) & 0xFF;
            int minor = state->classid & 0xFFFF;
            
            char cmd[256];
            char output[MAX_CMD_OUTPUT];
            
            snprintf(cmd, sizeof(cmd),
                     "tc -s class show dev %s classid %d:%d 2>&1 | "
                     "grep -E 'bytes|Sent' | head -1",
                     dev_ctx->device, major, minor);
            
            int ret = execute_command_with_timeout(cmd, output, sizeof(output), MAX_CMD_TIMEOUT_MS);
            if (ret == 0) {
                if (sscanf(output, "Sent %llu bytes", &bytes) == 1 ||
                    sscanf(output, "%*s %llu bytes", &bytes) == 1) {
                    got_stats = 1;
                }
            }
        }
        
        if (got_stats) {
            int64_t time_diff = now - state->last_check_time;
            if (time_diff > 0) {
                int64_t bytes_diff = bytes - state->last_total_bytes;
                
                if (bytes_diff < 0) {
                    bytes_diff = bytes;
                }
                
                // 修复整数溢出风险：使用64位整数
                int64_t bps = (bytes_diff * 8000LL) / time_diff;
                int new_used_bw_kbps = (int)(bps / 1000);
                
                if (new_used_bw_kbps < 0) new_used_bw_kbps = 0;
                if (new_used_bw_kbps > dev_ctx->total_bandwidth_kbps) {
                    new_used_bw_kbps = dev_ctx->total_bandwidth_kbps;
                }
                
                state->used_bw_kbps = new_used_bw_kbps;
                state->total_bytes = bytes;
                state->last_total_bytes = bytes;
                
                if (new_used_bw_kbps > state->peak_used_bw_kbps) {
                    state->peak_used_bw_kbps = new_used_bw_kbps;
                }
                
                if (state->avg_used_bw_kbps == 0) {
                    state->avg_used_bw_kbps = new_used_bw_kbps;
                } else {
                    state->avg_used_bw_kbps = (state->avg_used_bw_kbps * 9 + new_used_bw_kbps) / 10;
                }
            }
        }
        
        if (state->current_bw_kbps > 0) {
            state->utilization = (float)state->used_bw_kbps / state->current_bw_kbps;
        } else {
            state->utilization = 0.0f;
        }
        
        if (state->utilization < 0.0f) state->utilization = 0.0f;
        if (state->utilization > 2.0f) state->utilization = 2.0f;
        
        if (state->utilization * 100 > dev_ctx->high_util_threshold) {
            state->high_util_duration++;
            state->low_util_duration = 0;
        } else if (state->utilization * 100 < dev_ctx->low_util_threshold) {
            state->low_util_duration++;
            state->high_util_duration = 0;
        } else {
            state->high_util_duration = 0;
            state->low_util_duration = 0;
        }
        
        if (state->cooldown_timer > 0) {
            state->cooldown_timer--;
        }
        
        state->last_check_time = now;
    }
    
    return QOSDBA_OK;
}

/* ==================== 查找可借用分类 ==================== */
static int find_available_class_to_borrow(device_context_t* dev_ctx, 
                                         int exclude_classid, 
                                         int borrower_priority,
                                         int needed_bw_kbps) {
    if (!dev_ctx || dev_ctx->num_classes < 2) return -1;
    
    int best_class_idx = -1;
    int best_priority_diff = -1;
    int best_available_bw = 0;
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_state_t* state = &dev_ctx->states[i];
        class_config_t* config = &dev_ctx->configs[i];
        
        if (state->classid == exclude_classid) {
            continue;
        }
        
        if (config->priority <= borrower_priority) {
            continue;
        }
        
        if (state->utilization * 100 < dev_ctx->low_util_threshold &&
            state->low_util_duration >= dev_ctx->low_util_duration) {
            
            int available_bw = state->current_bw_kbps - state->used_bw_kbps;
            int max_borrow = state->current_bw_kbps - config->min_bw_kbps;
            
            if (available_bw > 0 && max_borrow > 0) {
                int actual_available = (available_bw < max_borrow) ? 
                                      available_bw : max_borrow;
                
                if (actual_available >= dev_ctx->min_borrow_kbps) {
                    int priority_diff = config->priority - borrower_priority;
                    
                    if (priority_diff > best_priority_diff) {
                        best_class_idx = i;
                        best_priority_diff = priority_diff;
                        best_available_bw = actual_available;
                    }
                }
            }
        }
    }
    
    return best_class_idx;
}

/* ==================== 添加借用记录 ==================== */
static void add_borrow_record(device_context_t* dev_ctx, int from_classid, 
                             int to_classid, int borrowed_bw_kbps) {
    if (!dev_ctx || dev_ctx->num_records >= MAX_BORROW_RECORDS) return;
    
    borrow_record_t* record = &dev_ctx->records[dev_ctx->num_records++];
    record->from_classid = from_classid;
    record->to_classid = to_classid;
    record->borrowed_bw_kbps = borrowed_bw_kbps;
    record->start_time = get_current_time_ms();
    record->returned = 0;
    
    dev_ctx->total_borrow_events++;
    dev_ctx->total_borrowed_kbps += borrowed_bw_kbps;
}

/* ==================== 添加到批量命令 ==================== */
static void add_to_batch_commands(batch_commands_t* batch, const char* cmd) {
    if (!batch || !cmd || batch->command_count >= batch->max_commands) {
        return;
    }
    
    strncpy(batch->commands[batch->command_count], cmd, sizeof(batch->commands[0])-1);
    batch->commands[batch->command_count][sizeof(batch->commands[0])-1] = '\0';
    batch->command_count++;
}

/* ==================== 执行批量命令 ==================== */
static qosdba_result_t execute_batch_commands(batch_commands_t* batch, qosdba_context_t* ctx) {
    if (!batch || !ctx || batch->command_count == 0) return QOSDBA_OK;
    
    if (ctx->safe_mode) {  // 修复2: 改为 ctx->safe_mode
        // 安全模式，只记录不执行
        for (int i = 0; i < batch->command_count; i++) {
            log_message(NULL, "DEBUG", "[安全模式] 批量命令 %d: %s\n", i+1, batch->commands[i]);
        }
        batch->command_count = 0;
        return QOSDBA_OK;
    }
    
    // 构建批量命令
    char batch_cmd[2048] = "";
    int pos = 0;
    
    for (int i = 0; i < batch->command_count; i++) {
        int remaining = sizeof(batch_cmd) - pos;
        int cmd_len = snprintf(batch_cmd + pos, remaining, "%s; ", batch->commands[i]);
        if (cmd_len >= remaining || cmd_len < 0) {
            // 缓冲区不足，执行当前已构建的命令
            if (pos > 0) {
                batch_cmd[pos-1] = '\0';  // 移除最后一个分号
                char output[MAX_CMD_OUTPUT];
                int ret = execute_command_with_timeout(batch_cmd, output, sizeof(output), MAX_CMD_TIMEOUT_MS);
                if (ret != 0) {
                    log_message(NULL, "ERROR", "批量命令执行失败: %s\n", output);
                }
            }
            pos = 0;
        } else {
            pos += cmd_len;
        }
    }
    
    // 执行剩余的命令
    if (pos > 0) {
        batch_cmd[pos-2] = '\0';  // 移除最后一个分号和空格
        char output[MAX_CMD_OUTPUT];
        int ret = execute_command_with_timeout(batch_cmd, output, sizeof(output), MAX_CMD_TIMEOUT_MS);
        if (ret != 0) {
            log_message(NULL, "ERROR", "批量命令执行失败: %s\n", output);
        }
    }
    
    batch->command_count = 0;
    return QOSDBA_OK;
}

/* ==================== 调整分类带宽 ==================== */
static qosdba_result_t adjust_class_bandwidth(device_context_t* dev_ctx, 
                                             qosdba_context_t* ctx,
                                             int classid, int new_bw_kbps) {
    if (!dev_ctx || !ctx) return QOSDBA_ERR_MEMORY;
    
    int idx = find_class_by_id(dev_ctx, classid);
    if (idx < 0) {
        return QOSDBA_ERR_INVALID;
    }
    
    class_state_t* state = &dev_ctx->states[idx];
    class_config_t* config = &dev_ctx->configs[idx];
    
    if (new_bw_kbps < config->min_bw_kbps) {
        new_bw_kbps = config->min_bw_kbps;
    }
    
    if (new_bw_kbps > config->max_bw_kbps) {
        new_bw_kbps = config->max_bw_kbps;
    }
    
    int change = new_bw_kbps - state->current_bw_kbps;
    if (change < 0) change = -change;
    
    if (change < dev_ctx->min_change_kbps) {
        return QOSDBA_OK;
    }
    
    int major = (classid >> 16) & 0xFF;
    int minor = classid & 0xFFFF;
    
    char cmd[512];
    
    if (ctx->safe_mode) {  // 修复2: 改为 ctx->safe_mode
        // 安全模式，不实际执行命令
        log_message(NULL, "DEBUG", "[安全模式] 调整分类 0x%x 带宽: %d -> %d kbps\n", 
                   classid, state->current_bw_kbps, new_bw_kbps);
        state->current_bw_kbps = new_bw_kbps;
        return QOSDBA_OK;
    }
    
    if (strcmp(dev_ctx->qdisc_kind, "hfsc") == 0) {
        snprintf(cmd, sizeof(cmd),
                 "tc class change dev %s parent 1:0 classid %d:%d hfsc "
                 "ls m1 0b d 0us m2 %dkbit "
                 "ul m1 0b d 0us m2 %dkbit 2>&1",
                 dev_ctx->device, major, minor, new_bw_kbps, new_bw_kbps);
    } else {
        int burst = new_bw_kbps / 8;
        if (burst < 2) burst = 2;
        
        snprintf(cmd, sizeof(cmd),
                 "tc class change dev %s parent 1:0 classid %d:%d htb "
                 "rate %dkbit ceil %dkbit burst %dkbit 2>&1",
                 dev_ctx->device, major, minor, new_bw_kbps, new_bw_kbps, burst);
    }
    
    // 添加到批量命令缓冲区
    add_to_batch_commands(&dev_ctx->batch_cmds, cmd);
    
    // 更新状态
    state->current_bw_kbps = new_bw_kbps;
    
    return QOSDBA_OK;
}

/* ==================== 运行借用逻辑 ==================== */
static void run_borrow_logic(device_context_t* dev_ctx, qosdba_context_t* ctx) {
    if (!dev_ctx || !ctx || dev_ctx->num_classes < 2) return;
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_state_t* class_a = &dev_ctx->states[i];
        class_config_t* config_a = &dev_ctx->configs[i];
        
        if (class_a->utilization * 100 > dev_ctx->high_util_threshold &&
            class_a->high_util_duration >= dev_ctx->high_util_duration &&
            class_a->cooldown_timer == 0) {
            
            int needed_bw_kbps = 0;
            if (class_a->utilization > 1.0f) {
                needed_bw_kbps = (int)(class_a->current_bw_kbps * 
                                      (class_a->utilization - 1.0f));
            }
            
            // 修复：确保借用量至少为最小借用量
            if (needed_bw_kbps < dev_ctx->min_borrow_kbps) {
                needed_bw_kbps = dev_ctx->min_borrow_kbps;
            }
            
            int lend_idx = find_available_class_to_borrow(dev_ctx, 
                                                        class_a->classid, 
                                                        config_a->priority,
                                                        needed_bw_kbps);
            
            if (lend_idx >= 0) {
                class_state_t* class_b = &dev_ctx->states[lend_idx];
                class_config_t* config_b = &dev_ctx->configs[lend_idx];
                
                int available_bw = class_b->current_bw_kbps - class_b->used_bw_kbps;
                int max_borrow = class_b->current_bw_kbps - config_b->min_bw_kbps;
                
                if (available_bw > 0 && max_borrow > 0) {
                    int borrow_amount = (int)(available_bw * dev_ctx->borrow_ratio);
                    
                    if (borrow_amount > max_borrow) {
                        borrow_amount = max_borrow;
                    }
                    
                    // 修复：确保借用量不小于最小借用量
                    if (borrow_amount < dev_ctx->min_borrow_kbps) {
                        borrow_amount = dev_ctx->min_borrow_kbps;
                    }
                    
                    if (borrow_amount >= dev_ctx->min_borrow_kbps) {
                        // 调整为最小调整量的整数倍
                        borrow_amount = (borrow_amount / dev_ctx->min_change_kbps) * 
                                      dev_ctx->min_change_kbps;
                        if (borrow_amount < dev_ctx->min_change_kbps) {
                            borrow_amount = dev_ctx->min_change_kbps;
                        }
                        
                        int new_bw_a = class_a->current_bw_kbps + borrow_amount;
                        if (new_bw_a > config_a->max_bw_kbps) {
                            borrow_amount = config_a->max_bw_kbps - 
                                          class_a->current_bw_kbps;
                        }
                        
                        if (borrow_amount >= dev_ctx->min_borrow_kbps) {
                            int old_bw_a = class_a->current_bw_kbps;
                            int old_bw_b = class_b->current_bw_kbps;
                            
                            // 构建调整命令
                            int major_a = (class_a->classid >> 16) & 0xFF;
                            int minor_a = class_a->classid & 0xFFFF;
                            int major_b = (class_b->classid >> 16) & 0xFF;
                            int minor_b = class_b->classid & 0xFFFF;
                            
                            char cmd[512];
                            
                            if (strcmp(dev_ctx->qdisc_kind, "hfsc") == 0) {
                                snprintf(cmd, sizeof(cmd),
                                         "tc class change dev %s parent 1:0 classid %d:%d hfsc "
                                         "ls m1 0b d 0us m2 %dkbit ul m1 0b d 0us m2 %dkbit",
                                         dev_ctx->device, major_a, minor_a, 
                                         old_bw_a + borrow_amount, old_bw_a + borrow_amount);
                                add_to_batch_commands(&dev_ctx->batch_cmds, cmd);
                                
                                snprintf(cmd, sizeof(cmd),
                                         "tc class change dev %s parent 1:0 classid %d:%d hfsc "
                                         "ls m1 0b d 0us m2 %dkbit ul m1 0b d 0us m2 %dkbit",
                                         dev_ctx->device, major_b, minor_b,
                                         old_bw_b - borrow_amount, old_bw_b - borrow_amount);
                                add_to_batch_commands(&dev_ctx->batch_cmds, cmd);
                            } else {
                                int burst_a = (old_bw_a + borrow_amount) / 8;
                                if (burst_a < 2) burst_a = 2;
                                int burst_b = (old_bw_b - borrow_amount) / 8;
                                if (burst_b < 2) burst_b = 2;
                                
                                snprintf(cmd, sizeof(cmd),
                                         "tc class change dev %s parent 1:0 classid %d:%d htb "
                                         "rate %dkbit ceil %dkbit burst %dkbit",
                                         dev_ctx->device, major_a, minor_a,
                                         old_bw_a + borrow_amount, old_bw_a + borrow_amount, burst_a);
                                add_to_batch_commands(&dev_ctx->batch_cmds, cmd);
                                
                                snprintf(cmd, sizeof(cmd),
                                         "tc class change dev %s parent 1:0 classid %d:%d htb "
                                         "rate %dkbit ceil %dkbit burst %dkbit",
                                         dev_ctx->device, major_b, minor_b,
                                         old_bw_b - borrow_amount, old_bw_b - borrow_amount, burst_b);
                                add_to_batch_commands(&dev_ctx->batch_cmds, cmd);
                            }
                            
                            // 更新状态
                            class_a->current_bw_kbps = old_bw_a + borrow_amount;
                            class_b->current_bw_kbps = old_bw_b - borrow_amount;
                            
                            class_a->borrowed_bw_kbps += borrow_amount;
                            class_b->lent_bw_kbps += borrow_amount;
                            
                            class_a->cooldown_timer = dev_ctx->cooldown_time;
                            
                            add_borrow_record(dev_ctx, class_b->classid, 
                                            class_a->classid, borrow_amount);
                            
                            log_message(NULL, "INFO", "分类 %s 从 %s 借用 %d kbps 带宽\n",
                                       config_a->name, config_b->name, borrow_amount);
                            
                            // 如果批量命令已满，执行一次
                            if (dev_ctx->batch_cmds.command_count >= dev_ctx->batch_cmds.max_commands) {
                                execute_batch_commands(&dev_ctx->batch_cmds, ctx);
                            }
                            
                            break;
                        }
                    }
                }
            }
        }
    }
    
    // 执行剩余的批量命令
    if (dev_ctx->batch_cmds.command_count > 0) {
        execute_batch_commands(&dev_ctx->batch_cmds, ctx);
    }
}

/* ==================== 运行归还逻辑 ==================== */
static void run_return_logic(device_context_t* dev_ctx, qosdba_context_t* ctx) {
    if (!dev_ctx || !ctx || !dev_ctx->auto_return_enable) return;
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_state_t* class_b = &dev_ctx->states[i];
        
        if (class_b->lent_bw_kbps > 0 && 
            class_b->utilization * 100 < dev_ctx->return_threshold) {
            
            for (int j = 0; j < dev_ctx->num_records; j++) {
                borrow_record_t* record = &dev_ctx->records[j];
                
                if (!record->returned && 
                    record->from_classid == class_b->classid &&
                    record->borrowed_bw_kbps > 0) {
                    
                    int borrow_idx = find_class_by_id(dev_ctx, record->to_classid);
                    if (borrow_idx >= 0) {
                        class_state_t* class_a = &dev_ctx->states[borrow_idx];
                        
                        int return_amount = (int)(class_b->lent_bw_kbps * 
                                                dev_ctx->return_speed);
                        
                        if (return_amount < dev_ctx->min_change_kbps) {
                            return_amount = dev_ctx->min_change_kbps;
                        }
                        
                        if (return_amount > class_b->lent_bw_kbps) {
                            return_amount = class_b->lent_bw_kbps;
                        }
                        
                        if (return_amount > class_a->borrowed_bw_kbps) {
                            return_amount = class_a->borrowed_bw_kbps;
                        }
                        
                        if (return_amount > record->borrowed_bw_kbps) {
                            return_amount = record->borrowed_bw_kbps;
                        }
                        
                        if (return_amount >= dev_ctx->min_change_kbps) {
                            int old_bw_a = class_a->current_bw_kbps;
                            int old_bw_b = class_b->current_bw_kbps;
                            
                            // 构建调整命令
                            int major_a = (class_a->classid >> 16) & 0xFF;
                            int minor_a = class_a->classid & 0xFFFF;
                            int major_b = (class_b->classid >> 16) & 0xFF;
                            int minor_b = class_b->classid & 0xFFFF;
                            
                            char cmd[512];
                            
                            if (strcmp(dev_ctx->qdisc_kind, "hfsc") == 0) {
                                snprintf(cmd, sizeof(cmd),
                                         "tc class change dev %s parent 1:0 classid %d:%d hfsc "
                                         "ls m1 0b d 0us m2 %dkbit ul m1 0b d 0us m2 %dkbit",
                                         dev_ctx->device, major_a, minor_a,
                                         old_bw_a - return_amount, old_bw_a - return_amount);
                                add_to_batch_commands(&dev_ctx->batch_cmds, cmd);
                                
                                snprintf(cmd, sizeof(cmd),
                                         "tc class change dev %s parent 1:0 classid %d:%d hfsc "
                                         "ls m1 0b d 0us m2 %dkbit ul m1 0b d 0us m2 %dkbit",
                                         dev_ctx->device, major_b, minor_b,
                                         old_bw_b + return_amount, old_bw_b + return_amount);
                                add_to_batch_commands(&dev_ctx->batch_cmds, cmd);
                            } else {
                                int burst_a = (old_bw_a - return_amount) / 8;
                                if (burst_a < 2) burst_a = 2;
                                int burst_b = (old_bw_b + return_amount) / 8;
                                if (burst_b < 2) burst_b = 2;
                                
                                snprintf(cmd, sizeof(cmd),
                                         "tc class change dev %s parent 1:0 classid %d:%d htb "
                                         "rate %dkbit ceil %dkbit burst %dkbit",
                                         dev_ctx->device, major_a, minor_a,
                                         old_bw_a - return_amount, old_bw_a - return_amount, burst_a);
                                add_to_batch_commands(&dev_ctx->batch_cmds, cmd);
                                
                                snprintf(cmd, sizeof(cmd),
                                         "tc class change dev %s parent 1:0 classid %d:%d htb "
                                         "rate %dkbit ceil %dkbit burst %dkbit",
                                         dev_ctx->device, major_b, minor_b,
                                         old_bw_b + return_amount, old_bw_b + return_amount, burst_b);
                                add_to_batch_commands(&dev_ctx->batch_cmds, cmd);
                            }
                            
                            // 更新状态
                            class_a->current_bw_kbps = old_bw_a - return_amount;
                            class_b->current_bw_kbps = old_bw_b + return_amount;
                            
                            class_a->borrowed_bw_kbps -= return_amount;
                            class_b->lent_bw_kbps -= return_amount;
                            
                            record->borrowed_bw_kbps -= return_amount;
                            
                            dev_ctx->total_return_events++;
                            dev_ctx->total_returned_kbps += return_amount;
                            
                            if (record->borrowed_bw_kbps <= 0) {
                                record->returned = 1;
                            }
                            
                            log_message(NULL, "INFO", "分类 0x%x 归还 %d kbps 带宽给 0x%x\n",
                                       class_a->classid, return_amount, class_b->classid);
                            
                            // 如果批量命令已满，执行一次
                            if (dev_ctx->batch_cmds.command_count >= dev_ctx->batch_cmds.max_commands) {
                                execute_batch_commands(&dev_ctx->batch_cmds, ctx);
                            }
                            
                            break;
                        }
                    }
                }
            }
        }
    }
    
    // 执行剩余的批量命令
    if (dev_ctx->batch_cmds.command_count > 0) {
        execute_batch_commands(&dev_ctx->batch_cmds, ctx);
    }
}

/* ==================== 初始化异步监控 ==================== */
static qosdba_result_t init_async_monitor(device_context_t* dev_ctx) {
    if (!dev_ctx) return QOSDBA_ERR_MEMORY;
    
    // 创建epoll实例
    dev_ctx->async_monitor.epoll_fd = epoll_create1(0);
    if (dev_ctx->async_monitor.epoll_fd < 0) {
        log_message(NULL, "ERROR", "创建epoll失败: %s\n", strerror(errno));
        return QOSDBA_ERR_SYSTEM;
    }
    
    // 创建inotify实例
    dev_ctx->async_monitor.inotify_fd = inotify_init1(IN_NONBLOCK);
    if (dev_ctx->async_monitor.inotify_fd < 0) {
        log_message(NULL, "WARN", "创建inotify失败，回退到轮询模式: %s\n", strerror(errno));
        dev_ctx->async_monitor.async_enabled = 0;
        return QOSDBA_OK;
    }
    
    // 尝试监控TC统计文件
    char stat_path[256];
    snprintf(stat_path, sizeof(stat_path), "/sys/class/net/%s/statistics/tx_bytes", dev_ctx->device);
    
    dev_ctx->async_monitor.watch_fd = inotify_add_watch(dev_ctx->async_monitor.inotify_fd, 
                                                       stat_path, IN_MODIFY);
    
    if (dev_ctx->async_monitor.watch_fd < 0) {
        // 如果监控失败，可能是文件不存在或不支持，回退到轮询
        log_message(NULL, "DEBUG", "无法监控 %s，回退到轮询模式\n", stat_path);
        dev_ctx->async_monitor.async_enabled = 0;
        close(dev_ctx->async_monitor.inotify_fd);
        dev_ctx->async_monitor.inotify_fd = -1;
        return QOSDBA_OK;
    }
    
    // 添加inotify到epoll监控
    struct epoll_event ev;
    ev.events = EPOLLIN;
    ev.data.fd = dev_ctx->async_monitor.inotify_fd;
    
    if (epoll_ctl(dev_ctx->async_monitor.epoll_fd, EPOLL_CTL_ADD, 
                 dev_ctx->async_monitor.inotify_fd, &ev) < 0) {
        log_message(NULL, "WARN", "epoll_ctl添加inotify失败: %s\n", strerror(errno));
        dev_ctx->async_monitor.async_enabled = 0;
        close(dev_ctx->async_monitor.inotify_fd);
        dev_ctx->async_monitor.inotify_fd = -1;
        return QOSDBA_OK;
    }
    
    dev_ctx->async_monitor.async_enabled = 1;
    dev_ctx->async_monitor.last_async_check = get_current_time_ms();
    
    log_message(NULL, "INFO", "异步监控已启用，设备: %s\n", dev_ctx->device);
    return QOSDBA_OK;
}

/* ==================== 异步检查事件 ==================== */
static int check_async_events(device_context_t* dev_ctx) {
    if (!dev_ctx || !dev_ctx->async_monitor.async_enabled) {
        return 0;
    }
    
    struct epoll_event events[10];
    int nfds = epoll_wait(dev_ctx->async_monitor.epoll_fd, events, 10, 0);
    
    if (nfds < 0) {
        if (errno != EINTR) {
            log_message(NULL, "ERROR", "epoll_wait失败: %s\n", strerror(errno));
        }
        return 0;
    }
    
    int need_check = 0;
    
    for (int i = 0; i < nfds; i++) {
        if (events[i].data.fd == dev_ctx->async_monitor.inotify_fd) {
            char buf[4096] __attribute__ ((aligned(__alignof__(struct inotify_event))));
            const struct inotify_event *event;
            
            ssize_t len = read(dev_ctx->async_monitor.inotify_fd, buf, sizeof(buf));
            if (len <= 0) {
                continue;
            }
            
            // 处理inotify事件
            for (char* ptr = buf; ptr < buf + len; 
                 ptr += sizeof(struct inotify_event) + event->len) {
                event = (const struct inotify_event*)ptr;
                
                if (event->mask & IN_MODIFY) {
                    need_check = 1;
                    break;
                }
            }
        }
    }
    
    if (need_check) {
        int64_t now = get_current_time_ms();
        // 避免过于频繁的检查，至少间隔100ms
        if (now - dev_ctx->async_monitor.last_async_check > 100) {
            dev_ctx->async_monitor.last_async_check = now;
            return 1;
        }
    }
    
    return 0;
}

/* ==================== 检查配置是否需要重新加载 ==================== */
static int check_config_reload(qosdba_context_t* ctx, const char* config_file) {
    if (!ctx || !config_file) return 0;
    
    int current_mtime = get_file_mtime(config_file);
    if (current_mtime > ctx->config_mtime) {
        ctx->config_mtime = current_mtime;
        return 1;
    }
    
    return 0;
}

/* ==================== 重新加载配置 ==================== */
static qosdba_result_t reload_config(qosdba_context_t* ctx, const char* config_file) {
    if (!ctx || !config_file) return QOSDBA_ERR_MEMORY;
    
    log_message(ctx, "INFO", "重新加载配置文件: %s\n", config_file);
    
    // 深拷贝旧的设备状态
    device_context_t old_devices[MAX_DEVICES];
    for (int i = 0; i < ctx->num_devices; i++) {
        memcpy(&old_devices[i], &ctx->devices[i], sizeof(device_context_t));
    }
    
    // 保存旧的分类状态
    class_state_t old_states[MAX_DEVICES][MAX_CLASSES];
    int old_num_classes[MAX_DEVICES];
    
    for (int i = 0; i < ctx->num_devices; i++) {
        old_num_classes[i] = ctx->devices[i].num_classes;
        for (int j = 0; j < ctx->devices[i].num_classes; j++) {
            old_states[i][j] = ctx->devices[i].states[j];
        }
    }
    
    // 重新加载配置
    qosdba_result_t ret = load_config_file(ctx, config_file);
    if (ret != QOSDBA_OK) {
        log_message(ctx, "ERROR", "重新加载配置失败，保留原有配置\n");
        return ret;
    }
    
    // 重新初始化设备
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        if (!dev_ctx->enabled) continue;
        
        // 尝试恢复分类状态
        for (int j = 0; j < dev_ctx->num_classes; j++) {
            // 查找对应的旧状态
            for (int k = 0; k < old_num_classes[i]; k++) {
                if (old_states[i][k].classid == dev_ctx->configs[j].classid) {
                    // 恢复状态
                    dev_ctx->states[j] = old_states[i][k];
                    break;
                }
            }
        }
        
        // 重新初始化TC分类
        if (init_tc_classes(dev_ctx, ctx) != QOSDBA_OK) {
            log_message(ctx, "ERROR", "设备 %s 的TC分类重新初始化失败\n", dev_ctx->device);
        }
        
        dev_ctx->last_check_time = get_current_time_ms();
    }
    
    log_message(ctx, "INFO", "配置文件重新加载完成\n");
    return QOSDBA_OK;
}

/* ==================== 主接口函数 ==================== */
qosdba_result_t qosdba_init(qosdba_context_t* ctx) {
    if (!ctx) return QOSDBA_ERR_MEMORY;
    
    memset(ctx, 0, sizeof(qosdba_context_t));
    
    // 设置默认参数
    ctx->enabled = 1;
    ctx->debug_mode = 0;
    ctx->safe_mode = 0;
    ctx->check_interval = DEFAULT_CHECK_INTERVAL;
    ctx->start_time = get_current_time_ms();
    ctx->last_check_time = get_current_time_ms();  // 修复4: 添加初始化
    
    // 从统一配置文件加载参数
    if (load_config_file(ctx, "/etc/qosdba.conf") != QOSDBA_OK) {
        log_message(ctx, "INFO", "使用默认参数启动qosdba\n");
        
        // 设置默认设备配置
        ctx->num_devices = 2;
        
        // 下载设备（ifb0）默认配置
        device_context_t* dl_dev = &ctx->devices[0];
        dl_dev->enabled = 1;
        strcpy(dl_dev->device, "ifb0");
        dl_dev->total_bandwidth_kbps = 100000;
        dl_dev->high_util_threshold = DEFAULT_HIGH_UTIL_THRESHOLD;
        dl_dev->high_util_duration = DEFAULT_HIGH_UTIL_DURATION;
        dl_dev->low_util_threshold = DEFAULT_LOW_UTIL_THRESHOLD;
        dl_dev->low_util_duration = DEFAULT_LOW_UTIL_DURATION;
        dl_dev->borrow_ratio = DEFAULT_BORROW_RATIO;
        dl_dev->min_borrow_kbps = DEFAULT_MIN_BORROW_KBPS;
        dl_dev->min_change_kbps = DEFAULT_MIN_CHANGE_KBPS;
        dl_dev->cooldown_time = DEFAULT_COOLDOWN_TIME;
        dl_dev->auto_return_enable = 1;
        dl_dev->return_threshold = DEFAULT_RETURN_THRESHOLD;
        dl_dev->return_speed = DEFAULT_RETURN_SPEED;
        
        // 上传设备（pppoe-wan）默认配置
        device_context_t* ul_dev = &ctx->devices[1];
        ul_dev->enabled = 1;
        strcpy(ul_dev->device, "pppoe-wan");
        ul_dev->total_bandwidth_kbps = 20000;  // 上传带宽较小
        ul_dev->high_util_threshold = 85;      // 上传更敏感
        ul_dev->high_util_duration = 3;        // 更短的持续时间
        ul_dev->low_util_threshold = 40;
        ul_dev->low_util_duration = 3;
        ul_dev->borrow_ratio = 0.3;            // 更高的借用比例
        ul_dev->min_borrow_kbps = 64;          // 更小的最小借用
        ul_dev->min_change_kbps = 64;
        ul_dev->cooldown_time = 5;             // 更短的冷却时间
        ul_dev->auto_return_enable = 1;
        ul_dev->return_threshold = 50;
        ul_dev->return_speed = 0.15;           // 更快的归还速度
    }
    
    if (!ctx->enabled) {
        log_message(ctx, "INFO", "qosdba已被禁用\n");
        return QOSDBA_OK;
    }
    
    // 初始化每个设备
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        if (!dev_ctx->enabled) {
            log_message(ctx, "INFO", "设备 %s 被禁用\n", dev_ctx->device);
            continue;
        }
        
        // 初始化TC统计缓存
        dev_ctx->tc_cache.valid = 0;
        dev_ctx->tc_cache.query_interval_ms = 5000;  // 默认5秒
        
        // 初始化批量命令缓冲区
        dev_ctx->batch_cmds.max_commands = 10;
        dev_ctx->batch_cmds.command_count = 0;
        
        // 初始化异步监控
        if (init_async_monitor(dev_ctx) != QOSDBA_OK) {
            log_message(ctx, "WARN", "设备 %s 异步监控初始化失败\n", dev_ctx->device);
        }
        
        // 发现TC分类
        if (discover_tc_classes(dev_ctx) != QOSDBA_OK) {
            log_message(ctx, "WARN", "设备 %s 的TC分类发现失败\n", dev_ctx->device);
        }
        
        // 初始化TC分类
        if (init_tc_classes(dev_ctx, ctx) != QOSDBA_OK) {
            log_message(ctx, "ERROR", "设备 %s 的TC分类初始化失败\n", dev_ctx->device);
        } else {
            log_message(ctx, "INFO", 
                       "设备 %s 初始化完成: 总带宽=%dkbps, 分类数=%d, 异步监控=%s\n"
                       "  借还参数: 高阈值=%d%%, 低阈值=%d%%, 借用比例=%.1f%%, 最小借用=%dkbps\n",
                       dev_ctx->device, dev_ctx->total_bandwidth_kbps, dev_ctx->num_classes,
                       dev_ctx->async_monitor.async_enabled ? "启用" : "禁用",
                       dev_ctx->high_util_threshold, dev_ctx->low_util_threshold,
                       dev_ctx->borrow_ratio * 100.0f, dev_ctx->min_borrow_kbps);
            
            // 输出每个分类的详细信息
            for (int j = 0; j < dev_ctx->num_classes; j++) {
                class_config_t* config = &dev_ctx->configs[j];
                log_message(ctx, "INFO",
                           "    分类 %s (0x%x): 优先级=%d, 总带宽=%dkbps, 最小=%dkbps, 最大=%dkbps\n",
                           config->name, config->classid, config->priority,
                           config->total_bw_kbps, config->min_bw_kbps, config->max_bw_kbps);
            }
        }
        
        dev_ctx->last_check_time = get_current_time_ms();
    }
    
    log_message(ctx, "INFO", 
               "QoS动态带宽分配器初始化完成: 支持 %d 个设备, 检查间隔=%d秒, TC缓存=启用, 批量命令=启用\n",
               ctx->num_devices, ctx->check_interval);
    
    return QOSDBA_OK;
}

qosdba_result_t qosdba_run(qosdba_context_t* ctx) {
    if (!ctx || !ctx->enabled) return QOSDBA_ERR_MEMORY;
    
    int64_t now = get_current_time_ms();
    
    // 检查是否需要重新加载配置
    if (g_reload_config || (ctx->config_path[0] && check_config_reload(ctx, ctx->config_path))) {
        g_ctx = ctx; // 设置全局上下文指针
        reload_config(ctx, ctx->config_path);
        ctx->reload_config = 0;
        g_reload_config = 0;
    }
    
    // 检查是否需要退出
    if (g_should_exit) {
        ctx->enabled = 0;
        log_message(ctx, "INFO", "收到终止信号，准备退出\n");
        return QOSDBA_OK;
    }
    
    // 为每个设备运行监控逻辑
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        if (!dev_ctx->enabled) {
            continue;
        }
        
        int need_check = 0;
        
        // 检查定时器是否到期
        if (now - dev_ctx->last_check_time >= ctx->check_interval * 1000) {
            need_check = 1;
        }
        
        // 检查异步事件
        if (check_async_events(dev_ctx)) {
            need_check = 1;
        }
        
        if (need_check) {
            // 检查带宽使用率
            if (check_bandwidth_usage(dev_ctx) != QOSDBA_OK) {
                log_message(ctx, "ERROR", "设备 %s 带宽使用率检查失败\n", dev_ctx->device);
                continue;
            }
            
            // 运行借用逻辑
            run_borrow_logic(dev_ctx, ctx);
            
            // 运行归还逻辑
            run_return_logic(dev_ctx, ctx);
            
            dev_ctx->last_check_time = now;
        }
    }
    
    ctx->last_check_time = now;
    
    return QOSDBA_OK;
}

/* ==================== 状态更新函数 ==================== */
qosdba_result_t qosdba_update_status(qosdba_context_t* ctx, const char* status_file) {
    if (!ctx) return QOSDBA_ERR_MEMORY;
    
    if (status_file) {
        ctx->status_file = fopen(status_file, "w");
        if (!ctx->status_file) {
            return QOSDBA_ERR_FILE;
        }
    }
    
    if (!ctx->status_file) {
        return QOSDBA_OK;
    }
    
    int64_t now = get_current_time_ms();
    int64_t uptime = (now - ctx->start_time) / 1000;
    
    fprintf(ctx->status_file, "=== QoS动态带宽分配器状态 ===\n");
    fprintf(ctx->status_file, "版本: %s\n", QOSDBA_VERSION);
    fprintf(ctx->status_file, "运行时间: %ld秒\n", (long)uptime);
    fprintf(ctx->status_file, "启用设备数: %d\n", ctx->num_devices);
    fprintf(ctx->status_file, "检查间隔: %d秒\n", ctx->check_interval);
    fprintf(ctx->status_file, "调试模式: %s\n", ctx->debug_mode ? "是" : "否");
    fprintf(ctx->status_file, "安全模式: %s\n", ctx->safe_mode ? "是" : "否");
    fprintf(ctx->status_file, "配置文件: /etc/qosdba.conf\n");
    fprintf(ctx->status_file, "配置文件修改时间: %ld\n", (long)ctx->config_mtime);
    fprintf(ctx->status_file, "\n");
    
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        if (!dev_ctx->enabled) continue;
        
        fprintf(ctx->status_file, "=== 设备 %s 状态 ===\n", dev_ctx->device);
        fprintf(ctx->status_file, "总带宽: %d kbps\n", dev_ctx->total_bandwidth_kbps);
        fprintf(ctx->status_file, "队列算法: %s\n", dev_ctx->qdisc_kind);
        fprintf(ctx->status_file, "分类数量: %d\n", dev_ctx->num_classes);
        fprintf(ctx->status_file, "高使用率阈值: %d%%\n", dev_ctx->high_util_threshold);
        fprintf(ctx->status_file, "高使用率持续时间: %d秒\n", dev_ctx->high_util_duration);
        fprintf(ctx->status_file, "低使用率阈值: %d%%\n", dev_ctx->low_util_threshold);
        fprintf(ctx->status_file, "低使用率持续时间: %d秒\n", dev_ctx->low_util_duration);
        fprintf(ctx->status_file, "借用比例: %.1f%%\n", dev_ctx->borrow_ratio * 100.0f);
        fprintf(ctx->status_file, "最小借用带宽: %d kbps\n", dev_ctx->min_borrow_kbps);
        fprintf(ctx->status_file, "最小调整带宽: %d kbps\n", dev_ctx->min_change_kbps);
        fprintf(ctx->status_file, "冷却时间: %d秒\n", dev_ctx->cooldown_time);
        fprintf(ctx->status_file, "自动归还: %s\n", dev_ctx->auto_return_enable ? "是" : "否");
        fprintf(ctx->status_file, "归还阈值: %d%%\n", dev_ctx->return_threshold);
        fprintf(ctx->status_file, "归还速度: %.1f%%/秒\n", dev_ctx->return_speed * 100.0f);
        fprintf(ctx->status_file, "总借用事件: %d\n", dev_ctx->total_borrow_events);
        fprintf(ctx->status_file, "总归还事件: %d\n", dev_ctx->total_return_events);
        fprintf(ctx->status_file, "累计借用带宽: %ld kbps\n", 
                (long)dev_ctx->total_borrowed_kbps);
        fprintf(ctx->status_file, "累计归还带宽: %ld kbps\n", 
                (long)dev_ctx->total_returned_kbps);
        fprintf(ctx->status_file, "最后检查时间: %ld秒前\n", 
                (long)((now - dev_ctx->last_check_time) / 1000));
        fprintf(ctx->status_file, "TC缓存状态: %s\n", 
                dev_ctx->tc_cache.valid ? "有效" : "无效");
        fprintf(ctx->status_file, "异步监控: %s\n", 
                dev_ctx->async_monitor.async_enabled ? "启用" : "禁用");
        fprintf(ctx->status_file, "\n");
        
        fprintf(ctx->status_file, "=== 分类状态 ===\n");
        for (int j = 0; j < dev_ctx->num_classes; j++) {
            class_state_t* state = &dev_ctx->states[j];
            class_config_t* config = &dev_ctx->configs[j];
            
            fprintf(ctx->status_file, "分类 %s (0x%x):\n", 
                    config->name, state->classid);
            fprintf(ctx->status_file, "  优先级: %d\n", config->priority);
            fprintf(ctx->status_file, "  分类总带宽: %d kbps\n", config->total_bw_kbps);
            fprintf(ctx->status_file, "  带宽范围: %d-%d kbps\n", 
                    config->min_bw_kbps, config->max_bw_kbps);
            fprintf(ctx->status_file, "  当前带宽: %d kbps\n", state->current_bw_kbps);
            fprintf(ctx->status_file, "  使用带宽: %d kbps\n", state->used_bw_kbps);
            fprintf(ctx->status_file, "  使用率: %.1f%%\n", state->utilization * 100.0f);
            fprintf(ctx->status_file, "  借用状态: 借入 %d kbps, 借出 %d kbps\n",
                    state->borrowed_bw_kbps, state->lent_bw_kbps);
            fprintf(ctx->status_file, "  持续时间: 高使用率 %d秒, 低使用率 %d秒\n",
                    state->high_util_duration, state->low_util_duration);
            fprintf(ctx->status_file, "  冷却时间: %d秒\n", state->cooldown_timer);
            fprintf(ctx->status_file, "  最后检查时间: %ld秒前\n", 
                    (long)((now - state->last_check_time) / 1000));
            fprintf(ctx->status_file, "  统计信息: 峰值=%dkbps, 平均=%dkbps\n",
                    state->peak_used_bw_kbps, state->avg_used_bw_kbps);
            fprintf(ctx->status_file, "\n");
        }
        
        if (dev_ctx->num_records > 0) {
            fprintf(ctx->status_file, "=== 借用记录 ===\n");
            int active_records = 0;
            for (int j = 0; j < dev_ctx->num_records; j++) {
                borrow_record_t* record = &dev_ctx->records[j];
                if (!record->returned) {
                    int64_t age = (now - record->start_time) / 1000;
                    fprintf(ctx->status_file, "  从 0x%x 借给 0x%x: %d kbps (已借 %ld秒)\n",
                            record->from_classid, record->to_classid,
                            record->borrowed_bw_kbps, (long)age);
                    active_records++;
                }
            }
            if (active_records == 0) {
                fprintf(ctx->status_file, "  无活跃借用记录\n");
            }
        }
        
        fprintf(ctx->status_file, "\n");
    }
    
    fflush(ctx->status_file);
    
    if (status_file) {
        fclose(ctx->status_file);
        ctx->status_file = NULL;
    }
    
    return QOSDBA_OK;
}

/* ==================== 资源清理函数 ==================== */
qosdba_result_t qosdba_cleanup(qosdba_context_t* ctx) {
    if (!ctx) return QOSDBA_ERR_MEMORY;
    
    log_message(ctx, "INFO", "开始清理资源...\n");
    
    // 清理每个设备
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        if (!dev_ctx->enabled) continue;
        
        // 清理异步监控资源
        if (dev_ctx->async_monitor.async_enabled) {
            if (dev_ctx->async_monitor.watch_fd >= 0) {
                inotify_rm_watch(dev_ctx->async_monitor.inotify_fd, 
                                dev_ctx->async_monitor.watch_fd);
            }
            if (dev_ctx->async_monitor.inotify_fd >= 0) {
                close(dev_ctx->async_monitor.inotify_fd);
            }
            if (dev_ctx->async_monitor.epoll_fd >= 0) {
                close(dev_ctx->async_monitor.epoll_fd);
            }
        }
        
        // 将所有分类带宽恢复到中间值（最小和最大中间）
        for (int j = 0; j < dev_ctx->num_classes; j++) {
            class_state_t* state = &dev_ctx->states[j];
            class_config_t* config = &dev_ctx->configs[j];
            
            int target_bw = (config->min_bw_kbps + config->max_bw_kbps) / 2;
            if (state->current_bw_kbps != target_bw) {
                // 使用批量命令执行最后一次调整
                adjust_class_bandwidth(dev_ctx, ctx, state->classid, target_bw);
            }
        }
        
        // 执行最后一次批量命令
        if (dev_ctx->batch_cmds.command_count > 0) {
            execute_batch_commands(&dev_ctx->batch_cmds, ctx);
        }
    }
    
    // 关闭文件
    if (ctx->status_file) {
        fclose(ctx->status_file);
        ctx->status_file = NULL;
    }
    
    if (ctx->log_file && ctx->log_file != stderr) {
        fclose(ctx->log_file);
        ctx->log_file = NULL;
    }
    
    log_message(ctx, "INFO", "资源清理完成\n");
    
    return QOSDBA_OK;
}

/* ==================== 调试模式设置函数 ==================== */
void qosdba_set_debug(qosdba_context_t* ctx, int enable) {
    if (ctx) {
        ctx->debug_mode = enable;
    }
}

/* ==================== 安全模式设置函数 ==================== */
void qosdba_set_safe_mode(qosdba_context_t* ctx, int enable) {
    if (ctx) {
        ctx->safe_mode = enable;
    }
}

/* ==================== 命令行接口 ==================== */
#include <getopt.h>

typedef struct {
    char config_file[256];         // 配置文件路径
    char status_file[256];         // 状态文件路径
    char log_file[256];            // 日志文件路径
    int daemon_mode;               // 后台守护进程模式
    int debug_mode;                // 调试模式
    int safe_mode;                 // 安全模式
    int run_once;                  // 只运行一次检查
} qosdba_options_t;

static void print_help(const char* progname) {
    printf("QoS动态带宽分配器 v%s (统一配置文件版本)\n", QOSDBA_VERSION);
    printf("用法: %s [选项]\n", progname);
    printf("\n");
    printf("选项:\n");
    printf("  -c, --config <文件>   配置文件路径 (默认: /etc/qosdba.conf)\n");
    printf("  -s, --status <文件>   状态文件路径 (默认: /tmp/qosdba.status)\n");
    printf("  -l, --log <文件>      日志文件路径 (默认: /var/log/qosdba.log)\n");
    printf("  -D, --daemon          后台守护进程模式\n");
    printf("  -v, --verbose         详细输出模式\n");
    printf("  -S, --safe            安全模式(不实际修改TC配置)\n");
    printf("  -o, --once            只运行一次检查，然后退出\n");
    printf("  -h, --help            显示此帮助信息\n");
    printf("\n");
    printf("说明:\n");
    printf("  本程序从统一配置文件读取参数，支持同时监控多个设备\n");
    printf("  配置文件格式: /etc/qosdba.conf\n");
    printf("  支持SIGHUP信号重新加载配置\n");
    printf("\n");
    printf("示例:\n");
    printf("  %s -c /etc/qosdba.conf -D\n", progname);
    printf("  %s --verbose --once\n", progname);
}

static int parse_options(int argc, char* argv[], qosdba_options_t* opts) {
    if (!opts) return -1;
    
    // 设置默认值
    memset(opts, 0, sizeof(qosdba_options_t));
    strcpy(opts->config_file, "/etc/qosdba.conf");
    strcpy(opts->status_file, "/tmp/qosdba.status");
    strcpy(opts->log_file, "/var/log/qosdba.log");
    opts->daemon_mode = 0;
    opts->debug_mode = 0;
    opts->safe_mode = 0;
    opts->run_once = 0;
    
    // 长选项定义
    static struct option long_options[] = {
        {"config", required_argument, 0, 'c'},
        {"status", required_argument, 0, 's'},
        {"log", required_argument, 0, 'l'},
        {"daemon", no_argument, 0, 'D'},
        {"verbose", no_argument, 0, 'v'},
        {"safe", no_argument, 0, 'S'},
        {"once", no_argument, 0, 'o'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };
    
    int opt;
    int option_index = 0;
    
    while ((opt = getopt_long(argc, argv, "c:s:l:DvSoh", 
                             long_options, &option_index)) != -1) {
        switch (opt) {
            case 'c':
                strncpy(opts->config_file, optarg, sizeof(opts->config_file) - 1);
                break;
            case 's':
                strncpy(opts->status_file, optarg, sizeof(opts->status_file) - 1);
                break;
            case 'l':
                strncpy(opts->log_file, optarg, sizeof(opts->log_file) - 1);
                break;
            case 'D':
                opts->daemon_mode = 1;
                break;
            case 'v':
                opts->debug_mode = 1;
                break;
            case 'S':
                opts->safe_mode = 1;
                break;
            case 'o':
                opts->run_once = 1;
                break;
            case 'h':
                print_help(argv[0]);
                exit(EXIT_SUCCESS);
            default:
                print_help(argv[0]);
                exit(EXIT_FAILURE);
        }
    }
    
    return 0;
}

/* ==================== 后台模式 ==================== */
static int daemonize(void) {
    pid_t pid = fork();
    if (pid < 0) {
        return -1;
    } else if (pid > 0) {
        exit(EXIT_SUCCESS);
    }
    
    if (setsid() < 0) {
        return -1;
    }
    
    pid = fork();
    if (pid < 0) {
        return -1;
    } else if (pid > 0) {
        exit(EXIT_SUCCESS);
    }
    
    umask(0);
    chdir("/");
    
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    
    int null_fd = open("/dev/null", O_RDWR);
    if (null_fd >= 0) {
        dup2(null_fd, STDIN_FILENO);
        dup2(null_fd, STDOUT_FILENO);
        dup2(null_fd, STDERR_FILENO);
        close(null_fd);
    }
    
    return 0;
}

/* ==================== PID文件管理 ==================== */
static int create_pid_file(const char* pid_file) {
    if (!pid_file || strlen(pid_file) == 0) {
        return 0;
    }
    
    FILE* fp = fopen(pid_file, "w");
    if (!fp) {
        return -1;
    }
    
    fprintf(fp, "%d\n", getpid());
    fclose(fp);
    return 0;
}

static void remove_pid_file(const char* pid_file) {
    if (pid_file && strlen(pid_file) > 0) {
        unlink(pid_file);
    }
}

/* ==================== 主函数 ==================== */
int main(int argc, char* argv[]) {
    qosdba_options_t opts;
    qosdba_context_t ctx;
    int ret = EXIT_SUCCESS;
    
    // 解析命令行参数
    if (parse_options(argc, argv, &opts) != 0) {
        return EXIT_FAILURE;
    }
    
    // 设置全局上下文指针
    g_ctx = &ctx;
    
    // 后台模式
    if (opts.daemon_mode) {
        if (daemonize() < 0) {
            perror("后台模式失败");
            return EXIT_FAILURE;
        }
    }
    
    // 设置信号处理
    setup_signal_handlers();
    
    // 创建PID文件
    if (create_pid_file("/var/run/qosdba.pid") < 0) {
        fprintf(stderr, "警告: 无法创建PID文件\n");
    }
    
    // 打开日志文件
    ctx.log_file = fopen(opts.log_file, "a");
    if (!ctx.log_file) {
        ctx.log_file = stderr;
        fprintf(stderr, "警告: 无法打开日志文件: %s，将使用标准错误输出\n", opts.log_file);
    }
    
    // 初始化qosdba
    log_message(&ctx, "INFO", "启动QoS动态带宽分配器 v%s (统一配置文件版本)\n", QOSDBA_VERSION);
    log_message(&ctx, "INFO", "配置文件: %s\n", opts.config_file);
    log_message(&ctx, "INFO", "日志文件: %s\n", opts.log_file);
    log_message(&ctx, "INFO", "状态文件: %s\n", opts.status_file);
    log_message(&ctx, "INFO", "模式: %s%s\n", 
               opts.safe_mode ? "安全模式" : "正常模式",
               opts.debug_mode ? " (调试)" : "");
    
    // 设置模式
    qosdba_set_debug(&ctx, opts.debug_mode);
    qosdba_set_safe_mode(&ctx, opts.safe_mode);
    
    // 初始化
    qosdba_result_t init_ret = qosdba_init(&ctx);
    if (init_ret != QOSDBA_OK) {
        log_message(&ctx, "ERROR", "初始化失败: %d\n", init_ret);
        if (ctx.log_file && ctx.log_file != stderr) {
            fclose(ctx.log_file);
        }
        remove_pid_file("/var/run/qosdba.pid");
        return EXIT_FAILURE;
    }
    
    // 检查是否启用
    if (!ctx.enabled) {
        log_message(&ctx, "INFO", "qosdba已被禁用，退出\n");
        if (ctx.log_file && ctx.log_file != stderr) {
            fclose(ctx.log_file);
        }
        remove_pid_file("/var/run/qosdba.pid");
        return EXIT_SUCCESS;
    }
    
    // 主循环
    while (ctx.enabled) {
        qosdba_result_t run_ret = qosdba_run(&ctx);
        
        if (run_ret != QOSDBA_OK) {
            log_message(&ctx, "ERROR", "运行错误: %d\n", run_ret);
        }
        
        // 更新状态文件
        qosdba_update_status(&ctx, opts.status_file);
        
        // 如果是一次性运行，则退出
        if (opts.run_once) {
            break;
        }
        
        // 每秒运行一次
        sleep(1);
    }
    
    // 清理
    log_message(&ctx, "INFO", "收到终止信号，开始清理资源...\n");
    qosdba_cleanup(&ctx);
    
    // 移除PID文件
    remove_pid_file("/var/run/qosdba.pid");
    
    // 关闭日志文件
    if (ctx.log_file && ctx.log_file != stderr) {
        fclose(ctx.log_file);
    }
    
    log_message(&ctx, "INFO", "QoS动态带宽分配器已退出\n");
    
    return ret;
}