/*
 * qosdba.c - QoS动态带宽分配器
 * 功能：监控各QoS分类的带宽使用率，实现分类间的动态带宽借用和归还
 * 算法：
 * 1. 每1秒监控一次各分类的带宽使用率
 * 2. 当某个分类使用率连续5秒高于90%时：
 *    a. 检查是否有其他分类使用率连续5秒低于50%
 *    b. 从低使用率分类借用其空闲带宽的20%
 *    c. 借用的带宽必须≥64kbps
 *    d. 带宽调整的最小单位是64kbps
 * 3. 调整后，该分类5秒内不再进行调整
 * 4. 当被借用带宽的分类使用率低于60%时：
 *    a. 自动开始归还借用带宽
 *    b. 每秒归还当前借用带宽的10%
 * 5. 如果被借用分类需要更多带宽，可再次借用
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <uci.h>
#include <time.h>
#include <math.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <dirent.h>
#include <signal.h>

/* ==================== 宏定义 ==================== */
#define QOSDBA_VERSION "1.0.0"
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
#define DEFAULT_MIN_BORROW_KBPS 128       // 默认最小借用带宽(kbps)
#define DEFAULT_MIN_CHANGE_KBPS 128       // 默认最小调整带宽(kbps)
#define DEFAULT_COOLDOWN_TIME 8          // 默认冷却时间(秒)
#define DEFAULT_RETURN_THRESHOLD 50      // 默认归还阈值(%)
#define DEFAULT_RETURN_SPEED 0.1f        // 默认归还速度(每秒归还比例)
#define MAX_CMD_OUTPUT 4096              // 命令输出最大长度

/* ==================== 返回码 ==================== */
typedef enum {
    QOSDBA_OK = 0,
    QOSDBA_ERR_MEMORY = -1,
    QOSDBA_ERR_FILE = -2,
    QOSDBA_ERR_CONFIG = -3,
    QOSDBA_ERR_SYSTEM = -4,
    QOSDBA_ERR_TC = -5,
    QOSDBA_ERR_INVALID = -6,
    QOSDBA_ERR_NETWORK = -7
} qosdba_result_t;

/* ==================== 分类带宽配置 ==================== */
typedef struct {
    int classid;                   // 分类ID，如0x100, 0x200等
    char name[32];                 // 分类名称
    float min_percent;             // 最小带宽百分比(0.0-1.0)
    float max_percent;             // 最大带宽百分比(0.0-1.0)
    float init_percent;            // 初始带宽百分比(0.0-1.0)
    int priority;                  // 优先级(数值越小优先级越高)
    int min_bw_kbps;               // 最小保证带宽(kbps，通过计算得到)
    int max_bw_kbps;               // 最大允许带宽(kbps，通过计算得到)
    int init_bw_kbps;              // 初始带宽(kbps，通过计算得到)
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

/* ==================== QoS上下文结构 ==================== */
typedef struct {
    // 控制标志
    int enabled;                   // 是否启用qosdba
    int debug_mode;                // 调试模式
    int safe_mode;                 // 安全模式(不实际修改TC)
    
    // 网络设备信息
    char device[16];               // 网络设备名
    int total_bandwidth_kbps;      // 总带宽(kbps)
    char qdisc_kind[MAX_QDISC_KIND_LEN];  // 队列算法类型
    
    // 分类管理
    class_config_t configs[MAX_CLASSES];  // 分类配置
    class_state_t states[MAX_CLASSES];    // 分类状态
    borrow_record_t records[MAX_BORROW_RECORDS];  // 借用记录
    int num_classes;               // 分类数量
    int num_records;               // 借用记录数量
    
    // 优先级管理
    priority_policy_t priority_policy;
    
    // 借还参数
    int check_interval;            // 检查间隔(秒)
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
    
    // 时间戳
    int64_t last_check_time;       // 上次检查时间(毫秒)
    int64_t start_time;            // 启动时间(毫秒)
    
    // 文件句柄
    FILE* status_file;             // 状态文件
    FILE* log_file;                // 日志文件
    
    // 统计信息
    int total_borrow_events;       // 总借用事件数
    int total_return_events;       // 总归还事件数
    int64_t total_borrowed_kbps;   // 累计借用带宽(kbps)
    int64_t total_returned_kbps;   // 累计归还带宽(kbps)
} qosdba_context_t;

/* ==================== 函数声明 ==================== */
qosdba_result_t qosdba_init(qosdba_context_t* ctx, const char* config_file, 
                           const char* device, int total_bandwidth_kbps);
qosdba_result_t qosdba_run(qosdba_context_t* ctx);
qosdba_result_t qosdba_cleanup(qosdba_context_t* ctx);
qosdba_result_t qosdba_update_status(qosdba_context_t* ctx, const char* status_file);
void qosdba_set_debug(qosdba_context_t* ctx, int enable);
void qosdba_set_safe_mode(qosdba_context_t* ctx, int enable);

/* ==================== 内部函数声明 ==================== */
static qosdba_result_t load_config(qosdba_context_t* ctx, const char* config_file);
static qosdba_result_t discover_tc_classes(qosdba_context_t* ctx);
static qosdba_result_t calculate_bandwidth_limits(qosdba_context_t* ctx);
static qosdba_result_t init_tc_classes(qosdba_context_t* ctx);
static qosdba_result_t check_bandwidth_usage(qosdba_context_t* ctx);
static void run_borrow_logic(qosdba_context_t* ctx);
static void run_return_logic(qosdba_context_t* ctx);
static qosdba_result_t adjust_class_bandwidth(qosdba_context_t* ctx, 
                                             int classid, int new_bw_kbps);
static int find_class_by_id(qosdba_context_t* ctx, int classid);
static int find_available_class_to_borrow(qosdba_context_t* ctx, 
                                         int exclude_classid, 
                                         int borrower_priority,
                                         int needed_bw_kbps);
static void add_borrow_record(qosdba_context_t* ctx, int from_classid, 
                             int to_classid, int borrowed_bw_kbps);
static void log_message(qosdba_context_t* ctx, const char* level, 
                       const char* format, ...);
static int64_t get_current_time_ms(void);
static int execute_command(const char* cmd, char* output, int output_len);

/* ==================== 辅助函数 ==================== */
int64_t get_current_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

int execute_command(const char* cmd, char* output, int output_len) {
    if (!cmd || !output || output_len <= 0) return -1;
    
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        return -1;
    }
    
    int total_read = 0;
    char buffer[256];
    
    while (fgets(buffer, sizeof(buffer), fp) != NULL && 
           total_read < output_len - 1) {
        int len = strlen(buffer);
        if (total_read + len < output_len) {
            strcpy(output + total_read, buffer);
            total_read += len;
        } else {
            break;
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

/* ==================== 读取 qosdba 配置的函数 ==================== */
static int load_qosdba_config(qosdba_context_t *ctx) {
    struct uci_context *uci_ctx = NULL;
    struct uci_package *pkg = NULL;
    struct uci_element *e = NULL;
    int ret = -1;
    
    uci_ctx = uci_alloc_context();
    if (!uci_ctx) {
        return -1;
    }
    
    // 加载 qos-gargoyle 配置
    if (uci_load(uci_ctx, "qos_gargoyle", &pkg) != UCI_OK) {
        uci_free_context(uci_ctx);
        return -1;
    }
    
    // 遍历所有配置节
    uci_foreach_element(&pkg->sections, e) {
        struct uci_section *s = uci_to_section(e);
        
        // 查找名为 "qosdba" 的配置节
        if (strcmp(s->type, "qosdba") == 0) {
            const char *value = NULL;
            
            // 读取 enabled 选项
            value = uci_lookup_option_string(uci_ctx, s, "enabled");
            if (value) ctx->enabled = atoi(value);
            
            // 读取 device 选项
            value = uci_lookup_option_string(uci_ctx, s, "device");
            if (value) strncpy(ctx->device, value, sizeof(ctx->device)-1);
            
            // 读取 total_bandwidth_kbps 选项
            value = uci_lookup_option_string(uci_ctx, s, "total_bandwidth_kbps");
            if (value) ctx->total_bandwidth_kbps = atoi(value);
            
            // 读取 interval 选项
            value = uci_lookup_option_string(uci_ctx, s, "interval");
            if (value) ctx->check_interval = atoi(value);
            
            // 读取 min_change_kbps 选项
            value = uci_lookup_option_string(uci_ctx, s, "min_change_kbps");
            if (value) ctx->min_change_kbps = atoi(value);
            
            // 读取高使用率参数
            value = uci_lookup_option_string(uci_ctx, s, "high_util_threshold");
            if (value) ctx->high_util_threshold = atoi(value);
            
            value = uci_lookup_option_string(uci_ctx, s, "high_util_duration");
            if (value) ctx->high_util_duration = atoi(value);
            
            // 读取低使用率参数
            value = uci_lookup_option_string(uci_ctx, s, "low_util_threshold");
            if (value) ctx->low_util_threshold = atoi(value);
            
            value = uci_lookup_option_string(uci_ctx, s, "low_util_duration");
            if (value) ctx->low_util_duration = atoi(value);
            
            // 读取借用参数
            value = uci_lookup_option_string(uci_ctx, s, "borrow_ratio");
            if (value) ctx->borrow_ratio = atof(value);
            
            value = uci_lookup_option_string(uci_ctx, s, "min_borrow_kbps");
            if (value) ctx->min_borrow_kbps = atoi(value);
            
            value = uci_lookup_option_string(uci_ctx, s, "cooldown_time");
            if (value) ctx->cooldown_time = atoi(value);
            
            // 读取归还参数
            value = uci_lookup_option_string(uci_ctx, s, "auto_return_enable");
            if (value) ctx->auto_return_enable = atoi(value);
            
            value = uci_lookup_option_string(uci_ctx, s, "return_threshold");
            if (value) ctx->return_threshold = atoi(value);
            
            value = uci_lookup_option_string(uci_ctx, s, "return_speed");
            if (value) ctx->return_speed = atof(value);
            
            // 读取模式参数
            value = uci_lookup_option_string(uci_ctx, s, "safe_mode");
            if (value) ctx->safe_mode = atoi(value);
            
            value = uci_lookup_option_string(uci_ctx, s, "debug_mode");
            if (value) ctx->debug_mode = atoi(value);
            
            ret = 0;  // 成功读取
            break;
        }
    }
    
    uci_unload(uci_ctx, pkg);
    uci_free_context(uci_ctx);
    
    return ret;
}

/* ==================== 配置加载 ==================== */
qosdba_result_t load_config(qosdba_context_t* ctx, const char* config_file) {
    if (!ctx || !config_file) return QOSDBA_ERR_MEMORY;
    
    FILE* fp = fopen(config_file, "r");
    if (!fp) {
        log_message(ctx, "ERROR", "无法打开配置文件: %s\n", config_file);
        return QOSDBA_ERR_FILE;
    }
    
    char line[MAX_CONFIG_LINE];
    int line_num = 0;
    int class_count = 0;
    
    // 读取全局参数
    while (fgets(line, sizeof(line), fp) && class_count < MAX_CLASSES) {
        line_num++;
        
        // 跳过注释行和空行
        if (line[0] == '#' || line[0] == '\n') {
            continue;
        }
        
        // 移除换行符
        char* newline = strchr(line, '\n');
        if (newline) *newline = '\0';
        
        // 解析分类配置行
        // 格式: classid,name,min_percent,max_percent,init_percent,priority
        int classid;
        char name[32];
        float min_percent, max_percent, init_percent;
        int priority;
        
        int parsed = sscanf(line, "0x%x,%31[^,],%f,%f,%f,%d", 
                           &classid, name, &min_percent, &max_percent, 
                           &init_percent, &priority);
        
        if (parsed == 6) {
            class_config_t* config = &ctx->configs[class_count];
            config->classid = classid;
            strncpy(config->name, name, sizeof(config->name) - 1);
            config->min_percent = min_percent / 100.0f;  // 转换为小数
            config->max_percent = max_percent / 100.0f;
            config->init_percent = init_percent / 100.0f;
            config->priority = priority;
            
            class_count++;
            
            log_message(ctx, "INFO", "加载分类配置: ID=0x%x, 名称=%s, "
                      "最小=%.1f%%, 最大=%.1f%%, 初始=%.1f%%, 优先级=%d\n",
                      classid, name, min_percent, max_percent, 
                      init_percent, priority);
        } else {
            log_message(ctx, "WARN", "配置文件第%d行格式错误: %s\n", 
                       line_num, line);
        }
    }
    
    fclose(fp);
    
    if (class_count == 0) {
        log_message(ctx, "ERROR", "配置文件中没有有效的分类配置\n");
        return QOSDBA_ERR_CONFIG;
    }
    
    ctx->num_classes = class_count;
    
    // 计算实际带宽值
    return calculate_bandwidth_limits(ctx);
}

qosdba_result_t calculate_bandwidth_limits(qosdba_context_t* ctx) {
    if (!ctx || ctx->num_classes == 0) return QOSDBA_ERR_MEMORY;
    
    int total_assigned = 0;
    
    for (int i = 0; i < ctx->num_classes; i++) {
        class_config_t* config = &ctx->configs[i];
        
        // 计算实际带宽值
        config->min_bw_kbps = (int)(ctx->total_bandwidth_kbps * config->min_percent);
        config->max_bw_kbps = (int)(ctx->total_bandwidth_kbps * config->max_percent);
        config->init_bw_kbps = (int)(ctx->total_bandwidth_kbps * config->init_percent);
        
        // 验证带宽范围
        if (config->min_bw_kbps <= 0) {
            config->min_bw_kbps = 64;  // 最小64kbps
        }
        
        if (config->max_bw_kbps > ctx->total_bandwidth_kbps) {
            config->max_bw_kbps = ctx->total_bandwidth_kbps;
        }
        
        if (config->init_bw_kbps < config->min_bw_kbps) {
            config->init_bw_kbps = config->min_bw_kbps;
        }
        
        if (config->init_bw_kbps > config->max_bw_kbps) {
            config->init_bw_kbps = config->max_bw_kbps;
        }
        
        total_assigned += config->init_bw_kbps;
        
        log_message(ctx, "DEBUG", "分类 0x%x: 最小=%dkbps, 最大=%dkbps, 初始=%dkbps\n",
                   config->classid, config->min_bw_kbps, 
                   config->max_bw_kbps, config->init_bw_kbps);
    }
    
    // 验证总分配带宽不超过总带宽
    if (total_assigned > ctx->total_bandwidth_kbps) {
        log_message(ctx, "WARN", "总分配带宽(%dkbps)超过总带宽(%dkbps)，将进行比例缩减\n",
                   total_assigned, ctx->total_bandwidth_kbps);
        
        // 按比例缩减
        float scale = (float)ctx->total_bandwidth_kbps / total_assigned;
        for (int i = 0; i < ctx->num_classes; i++) {
            class_config_t* config = &ctx->configs[i];
            config->init_bw_kbps = (int)(config->init_bw_kbps * scale);
            if (config->init_bw_kbps < config->min_bw_kbps) {
                config->init_bw_kbps = config->min_bw_kbps;
            }
        }
    }
    
    return QOSDBA_OK;
}

/* ==================== TC分类发现 ==================== */
qosdba_result_t discover_tc_classes(qosdba_context_t* ctx) {
    if (!ctx) return QOSDBA_ERR_MEMORY;
    
    char cmd[256];
    char output[MAX_CMD_OUTPUT];
    int discovered = 0;
    
    // 检测队列算法类型
    snprintf(cmd, sizeof(cmd), "tc qdisc show dev %s 2>&1", ctx->device);
    
    int ret = execute_command(cmd, output, sizeof(output));
    if (ret != 0) {
        log_message(ctx, "ERROR", "无法获取队列算法信息: %s\n", output);
        return QOSDBA_ERR_TC;
    }
    
    // 解析队列算法类型
    if (strstr(output, "htb") != NULL) {
        strcpy(ctx->qdisc_kind, "htb");
    } else if (strstr(output, "hfsc") != NULL) {
        strcpy(ctx->qdisc_kind, "hfsc");
    } else if (strstr(output, "cake") != NULL) {
        strcpy(ctx->qdisc_kind, "cake");
    } else {
        strcpy(ctx->qdisc_kind, "htb");  // 默认使用HTB
        log_message(ctx, "INFO", "使用默认队列算法: HTB\n");
    }
    
    // 发现现有分类
    snprintf(cmd, sizeof(cmd), "tc -s class show dev %s 2>&1", ctx->device);
    
    ret = execute_command(cmd, output, sizeof(output));
    if (ret != 0) {
        log_message(ctx, "ERROR", "无法获取TC分类信息: %s\n", output);
        return QOSDBA_ERR_TC;
    }
    
    // 解析输出，查找分类
    char* line = strtok(output, "\n");
    while (line != NULL) {
        int major, minor;
        if (sscanf(line, "class htb %d:%d", &major, &minor) == 2 ||
            sscanf(line, "class hfsc %d:%d", &major, &minor) == 2) {
            
            int classid = (major << 16) | minor;
            
            // 跳过根分类
            if (classid == 0x10000) {
                line = strtok(NULL, "\n");
                continue;
            }
            
            // 检查是否在配置中
            int found = 0;
            for (int i = 0; i < ctx->num_classes; i++) {
                if (ctx->configs[i].classid == classid) {
                    found = 1;
                    break;
                }
            }
            
            if (!found) {
                // 添加新发现的分类
                if (ctx->num_classes < MAX_CLASSES) {
                    class_config_t* config = &ctx->configs[ctx->num_classes];
                    config->classid = classid;
                    snprintf(config->name, sizeof(config->name), 
                            "discovered-%d:%d", major, minor);
                    config->min_percent = 0.01f;  // 默认1%
                    config->max_percent = 0.1f;   // 默认10%
                    config->init_percent = 0.05f; // 默认5%
                    config->priority = minor;
                    
                    // 计算实际带宽
                    config->min_bw_kbps = (int)(ctx->total_bandwidth_kbps * config->min_percent);
                    config->max_bw_kbps = (int)(ctx->total_bandwidth_kbps * config->max_percent);
                    config->init_bw_kbps = (int)(ctx->total_bandwidth_kbps * config->init_percent);
                    
                    ctx->num_classes++;
                    discovered++;
                    
                    log_message(ctx, "INFO", "发现新分类: ID=0x%x (%d:%d)\n", 
                              classid, major, minor);
                }
            }
        }
        
        line = strtok(NULL, "\n");
    }
    
    if (discovered > 0) {
        log_message(ctx, "INFO", "发现 %d 个新分类\n", discovered);
    }
    
    return QOSDBA_OK;
}

/* ==================== 初始化TC分类 ==================== */
qosdba_result_t init_tc_classes(qosdba_context_t* ctx) {
    if (!ctx) return QOSDBA_ERR_MEMORY;
    
    char cmd[512];
    int success_count = 0;
    
    for (int i = 0; i < ctx->num_classes; i++) {
        class_config_t* config = &ctx->configs[i];
        class_state_t* state = &ctx->states[i];
        
        // 初始化状态
        state->classid = config->classid;
        state->current_bw_kbps = config->init_bw_kbps;
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
        
        if (ctx->safe_mode) {
            log_message(ctx, "INFO", "安全模式: 跳过分类 0x%x 初始化\n", 
                      config->classid);
            success_count++;
            continue;
        }
        
        // 创建或修改TC分类
        int major = (config->classid >> 16) & 0xFF;
        int minor = config->classid & 0xFFFF;
        
        if (strcmp(ctx->qdisc_kind, "hfsc") == 0) {
            // HFSC分类
            snprintf(cmd, sizeof(cmd),
                     "tc class add dev %s parent 1:0 classid %d:%d hfsc "
                     "ls m1 0b d 0us m2 %dkbit "
                     "ul m1 0b d 0us m2 %dkbit 2>&1 || "
                     "tc class change dev %s parent 1:0 classid %d:%d hfsc "
                     "ls m1 0b d 0us m2 %dkbit "
                     "ul m1 0b d 0us m2 %dkbit 2>&1",
                     ctx->device, major, minor, 
                     config->init_bw_kbps, config->init_bw_kbps,
                     ctx->device, major, minor,
                     config->init_bw_kbps, config->init_bw_kbps);
        } else if (strcmp(ctx->qdisc_kind, "cake") == 0) {
            // CAKE队列，不支持分类
            log_message(ctx, "WARN", "CAKE队列不支持分类，跳过分类 0x%x\n", 
                      config->classid);
            continue;
        } else {
            // 默认HTB分类
            int burst = config->init_bw_kbps / 8;
            if (burst < 2) burst = 2;
            
            snprintf(cmd, sizeof(cmd),
                     "tc class add dev %s parent 1:0 classid %d:%d htb "
                     "rate %dkbit ceil %dkbit burst %dkbit 2>&1 || "
                     "tc class change dev %s parent 1:0 classid %d:%d htb "
                     "rate %dkbit ceil %dkbit burst %dkbit 2>&1",
                     ctx->device, major, minor,
                     config->init_bw_kbps, config->init_bw_kbps, burst,
                     ctx->device, major, minor,
                     config->init_bw_kbps, config->init_bw_kbps, burst);
        }
        
        char output[MAX_CMD_OUTPUT];
        int ret = execute_command(cmd, output, sizeof(output));
        
        if (ret == 0) {
            success_count++;
            log_message(ctx, "INFO", "初始化分类 0x%x: %dkbps\n", 
                      config->classid, config->init_bw_kbps);
        } else {
            log_message(ctx, "ERROR", "初始化分类 0x%x 失败: %s\n", 
                      config->classid, output);
        }
    }
    
    if (success_count == ctx->num_classes) {
        log_message(ctx, "INFO", "成功初始化 %d 个分类\n", success_count);
        return QOSDBA_OK;
    } else {
        log_message(ctx, "ERROR", "只成功初始化 %d/%d 个分类\n", 
                   success_count, ctx->num_classes);
        return QOSDBA_ERR_TC;
    }
}

/* ==================== 查找分类 ==================== */
int find_class_by_id(qosdba_context_t* ctx, int classid) {
    if (!ctx) return -1;
    
    for (int i = 0; i < ctx->num_classes; i++) {
        if (ctx->states[i].classid == classid) {
            return i;
        }
    }
    
    return -1;
}

/* ==================== 检查带宽使用率 ==================== */
qosdba_result_t check_bandwidth_usage(qosdba_context_t* ctx) {
    if (!ctx || ctx->num_classes == 0) return QOSDBA_ERR_MEMORY;
    
    int64_t now = get_current_time_ms();
    
    for (int i = 0; i < ctx->num_classes; i++) {
        class_state_t* state = &ctx->states[i];
        class_config_t* config = &ctx->configs[i];
        
        int major = (state->classid >> 16) & 0xFF;
        int minor = state->classid & 0xFFFF;
        
        // 获取分类统计信息
        char cmd[256];
        char output[MAX_CMD_OUTPUT];
        
        snprintf(cmd, sizeof(cmd),
                 "tc -s class show dev %s classid %d:%d 2>&1 | "
                 "grep -E 'bytes|Sent' | head -1",
                 ctx->device, major, minor);
        
        int ret = execute_command(cmd, output, sizeof(output));
        if (ret == 0) {
            unsigned long long bytes = 0;
            if (sscanf(output, "Sent %llu bytes", &bytes) == 1 ||
                sscanf(output, "%*s %llu bytes", &bytes) == 1) {
                
                int64_t time_diff = now - state->last_check_time;
                if (time_diff > 0) {
                    // 计算当前使用带宽
                    int64_t bytes_diff = bytes - state->last_total_bytes;
                    
                    // 处理计数器回绕
                    if (bytes_diff < 0) {
                        bytes_diff = bytes;
                    }
                    
                    // 计算bps: bytes * 8 * 1000 / time_ms
                    int bps = (int)((bytes_diff * 8000) / time_diff);
                    int new_used_bw_kbps = bps / 1000;
                    
                    if (new_used_bw_kbps < 0) new_used_bw_kbps = 0;
                    if (new_used_bw_kbps > ctx->total_bandwidth_kbps) {
                        new_used_bw_kbps = ctx->total_bandwidth_kbps;
                    }
                    
                    // 更新使用带宽
                    state->used_bw_kbps = new_used_bw_kbps;
                    state->total_bytes = bytes;
                    state->last_total_bytes = bytes;
                    
                    // 更新峰值
                    if (new_used_bw_kbps > state->peak_used_bw_kbps) {
                        state->peak_used_bw_kbps = new_used_bw_kbps;
                    }
                    
                    // 更新平均值（指数移动平均）
                    if (state->avg_used_bw_kbps == 0) {
                        state->avg_used_bw_kbps = new_used_bw_kbps;
                    } else {
                        state->avg_used_bw_kbps = (state->avg_used_bw_kbps * 9 + new_used_bw_kbps) / 10;
                    }
                }
            }
        }
        
        // 计算使用率
        if (state->current_bw_kbps > 0) {
            state->utilization = (float)state->used_bw_kbps / state->current_bw_kbps;
        } else {
            state->utilization = 0.0f;
        }
        
        // 限制使用率在合理范围
        if (state->utilization < 0.0f) state->utilization = 0.0f;
        if (state->utilization > 2.0f) state->utilization = 2.0f;  // 允许超过100%
        
        // 更新高/低使用率持续时间
        if (state->utilization * 100 > ctx->high_util_threshold) {
            state->high_util_duration++;
            state->low_util_duration = 0;
        } else if (state->utilization * 100 < ctx->low_util_threshold) {
            state->low_util_duration++;
            state->high_util_duration = 0;
        } else {
            state->high_util_duration = 0;
            state->low_util_duration = 0;
        }
        
        // 更新冷却时间
        if (state->cooldown_timer > 0) {
            state->cooldown_timer--;
        }
        
        state->last_check_time = now;
        
        if (ctx->debug_mode) {
            log_message(ctx, "DEBUG", 
                       "分类 0x%x: 当前=%dkbps, 使用=%dkbps, 使用率=%.1f%%, "
                       "高持续=%d, 低持续=%d, 冷却=%d\n",
                       state->classid,
                       state->current_bw_kbps,
                       state->used_bw_kbps,
                       state->utilization * 100.0f,
                       state->high_util_duration,
                       state->low_util_duration,
                       state->cooldown_timer);
        }
    }
    
    return QOSDBA_OK;
}

/* ==================== 查找可借用分类 ==================== */
int find_available_class_to_borrow(qosdba_context_t* ctx, 
                                         int exclude_classid, 
                                         int borrower_priority,
                                         int needed_bw_kbps) {
    if (!ctx || ctx->num_classes < 2) return -1;
    
    int best_class_idx = -1;
    int best_priority_diff = -1;
    int best_available_bw = 0;
    
    for (int i = 0; i < ctx->num_classes; i++) {
        class_state_t* state = &ctx->states[i];
        class_config_t* config = &ctx->configs[i];
        
        // 排除自身
        if (state->classid == exclude_classid) {
            continue;
        }
        
        // 规则1：只能从优先级更低的分类借用
        if (config->priority <= borrower_priority) {
            continue;  // 跳过优先级相同或更高的分类
        }
        
        // 规则2：必须满足低使用率条件
        if (state->utilization * 100 < ctx->low_util_threshold &&
            state->low_util_duration >= ctx->low_util_duration) {
            
            // 计算可借用带宽
            int available_bw = state->current_bw_kbps - state->used_bw_kbps;
            int max_borrow = state->current_bw_kbps - config->min_bw_kbps;
            
            if (available_bw > 0 && max_borrow > 0) {
                int actual_available = (available_bw < max_borrow) ? 
                                      available_bw : max_borrow;
                
                if (actual_available >= ctx->min_borrow_kbps) {
                    int priority_diff = config->priority - borrower_priority;
                    
                    // 规则3：优先从最低优先级的分类借用
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
void add_borrow_record(qosdba_context_t* ctx, int from_classid, 
                      int to_classid, int borrowed_bw_kbps) {
    if (!ctx || ctx->num_records >= MAX_BORROW_RECORDS) return;
    
    borrow_record_t* record = &ctx->records[ctx->num_records++];
    record->from_classid = from_classid;
    record->to_classid = to_classid;
    record->borrowed_bw_kbps = borrowed_bw_kbps;
    record->start_time = get_current_time_ms();
    record->returned = 0;
    
    ctx->total_borrow_events++;
    ctx->total_borrowed_kbps += borrowed_bw_kbps;
}

/* ==================== 调整分类带宽 ==================== */
qosdba_result_t adjust_class_bandwidth(qosdba_context_t* ctx, 
                                      int classid, int new_bw_kbps) {
    if (!ctx) return QOSDBA_ERR_MEMORY;
    
    int idx = find_class_by_id(ctx, classid);
    if (idx < 0) {
        log_message(ctx, "ERROR", "未找到分类 0x%x\n", classid);
        return QOSDBA_ERR_INVALID;
    }
    
    class_state_t* state = &ctx->states[idx];
    class_config_t* config = &ctx->configs[idx];
    
    // 验证新带宽范围
    if (new_bw_kbps < config->min_bw_kbps) {
        new_bw_kbps = config->min_bw_kbps;
    }
    
    if (new_bw_kbps > config->max_bw_kbps) {
        new_bw_kbps = config->max_bw_kbps;
    }
    
    // 检查变化是否足够大
    int change = new_bw_kbps - state->current_bw_kbps;
    if (change < 0) change = -change;
    
    if (change < ctx->min_change_kbps) {
        log_message(ctx, "DEBUG", "分类 0x%x 带宽变化太小(%dkbps)，跳过\n", 
                   classid, change);
        return QOSDBA_OK;
    }
    
    if (ctx->safe_mode) {
        log_message(ctx, "INFO", "安全模式: 分类 0x%x 带宽 %d -> %d kbps\n", 
                   classid, state->current_bw_kbps, new_bw_kbps);
        state->current_bw_kbps = new_bw_kbps;
        return QOSDBA_OK;
    }
    
    // 执行TC命令调整带宽
    int major = (classid >> 16) & 0xFF;
    int minor = classid & 0xFFFF;
    
    char cmd[512];
    char output[MAX_CMD_OUTPUT];
    
    if (strcmp(ctx->qdisc_kind, "hfsc") == 0) {
        snprintf(cmd, sizeof(cmd),
                 "tc class change dev %s parent 1:0 classid %d:%d hfsc "
                 "ls m1 0b d 0us m2 %dkbit "
                 "ul m1 0b d 0us m2 %dkbit 2>&1",
                 ctx->device, major, minor, new_bw_kbps, new_bw_kbps);
    } else {
        // 默认HTB
        int burst = new_bw_kbps / 8;
        if (burst < 2) burst = 2;
        
        snprintf(cmd, sizeof(cmd),
                 "tc class change dev %s parent 1:0 classid %d:%d htb "
                 "rate %dkbit ceil %dkbit burst %dkbit 2>&1",
                 ctx->device, major, minor, new_bw_kbps, new_bw_kbps, burst);
    }
    
    int ret = execute_command(cmd, output, sizeof(output));
    
    if (ret == 0) {
        int old_bw = state->current_bw_kbps;
        state->current_bw_kbps = new_bw_kbps;
        
        log_message(ctx, "INFO", "调整分类 0x%x 带宽: %d -> %d kbps\n", 
                   classid, old_bw, new_bw_kbps);
        return QOSDBA_OK;
    } else {
        log_message(ctx, "ERROR", "调整分类 0x%x 带宽失败: %s\n", 
                   classid, output);
        return QOSDBA_ERR_TC;
    }
}

/* ==================== 运行借用逻辑 ==================== */
void run_borrow_logic(qosdba_context_t* ctx) {
    if (!ctx || ctx->num_classes < 2) return;
    
    // 寻找高使用率分类
    for (int i = 0; i < ctx->num_classes; i++) {
        class_state_t* class_a = &ctx->states[i];
        class_config_t* config_a = &ctx->configs[i];
        
        // 检查条件：使用率 > 高使用率阈值 且 持续时间 >= 高使用率持续时间
        if (class_a->utilization * 100 > ctx->high_util_threshold &&
            class_a->high_util_duration >= ctx->high_util_duration &&
            class_a->cooldown_timer == 0) {
            
            log_message(ctx, "INFO", 
                       "分类 0x%x 需要借用带宽: 使用率=%.1f%%, 持续=%d秒\n",
                       class_a->classid,
                       class_a->utilization * 100.0f,
                       class_a->high_util_duration);
            
            // 计算需要的带宽
            int needed_bw_kbps = 0;
            if (class_a->utilization > 1.0f) {
                needed_bw_kbps = (int)(class_a->current_bw_kbps * 
                                      (class_a->utilization - 1.0f));
            }
            if (needed_bw_kbps < ctx->min_borrow_kbps) {
                needed_bw_kbps = ctx->min_borrow_kbps;
            }
            
            // 查找可借用分类
            int lend_idx = find_available_class_to_borrow(ctx, 
                                                        class_a->classid, 
                                                        config_a->priority,  // 传入优先级
                                                        needed_bw_kbps);
            
            if (lend_idx >= 0) {
                class_state_t* class_b = &ctx->states[lend_idx];
                class_config_t* config_b = &ctx->configs[lend_idx];
                
                // 计算可借用带宽
                int available_bw = class_b->current_bw_kbps - class_b->used_bw_kbps;
                int max_borrow = class_b->current_bw_kbps - config_b->min_bw_kbps;
                
                if (available_bw > 0 && max_borrow > 0) {
                    int borrow_amount = (int)(available_bw * ctx->borrow_ratio);
                    
                    // 确保不超过最大可借用
                    if (borrow_amount > max_borrow) {
                        borrow_amount = max_borrow;
                    }
                    
                    // 确保满足最小借用阈值
                    if (borrow_amount >= ctx->min_borrow_kbps) {
                        // 对齐到最小调整单位
                        borrow_amount = (borrow_amount / ctx->min_change_kbps) * 
                                        ctx->min_change_kbps;
                        if (borrow_amount < ctx->min_change_kbps) {
                            borrow_amount = ctx->min_change_kbps;
                        }
                        
                        // 确保不超过借入分类的最大限制
                        int new_bw_a = class_a->current_bw_kbps + borrow_amount;
                        if (new_bw_a > config_a->max_bw_kbps) {
                            borrow_amount = config_a->max_bw_kbps - 
                                          class_a->current_bw_kbps;
                        }
                        
                        if (borrow_amount >= ctx->min_borrow_kbps) {
                            // 执行借用
                            int old_bw_a = class_a->current_bw_kbps;
                            int old_bw_b = class_b->current_bw_kbps;
                            
                            // 调整带宽
                            adjust_class_bandwidth(ctx, class_a->classid, 
                                                 old_bw_a + borrow_amount);
                            adjust_class_bandwidth(ctx, class_b->classid, 
                                                 old_bw_b - borrow_amount);
                            
                            // 更新状态
                            class_a->borrowed_bw_kbps += borrow_amount;
                            class_b->lent_bw_kbps += borrow_amount;
                            
                            // 设置冷却时间
                            class_a->cooldown_timer = ctx->cooldown_time;
                            
                            // 添加借用记录
                            add_borrow_record(ctx, class_b->classid, 
                                            class_a->classid, borrow_amount);
                            
                            log_message(ctx, "INFO",
                                       "带宽借用成功: 从分类 0x%x 借用 %dkbps 到分类 0x%x\n"
                                       "  (%d->%d kbps, %d->%d kbps)\n",
                                       class_b->classid, borrow_amount, class_a->classid,
                                       old_bw_b, class_b->current_bw_kbps,
                                       old_bw_a, class_a->current_bw_kbps);
                            
                            // 一次只从一个分类借用
                            break;
                        }
                    }
                }
            } else {
                log_message(ctx, "DEBUG", "未找到可借用带宽的分类\n");
            }
        }
    }
}

/* ==================== 运行归还逻辑 ==================== */
void run_return_logic(qosdba_context_t* ctx) {
    if (!ctx) return;
    
    // 如果没有启用自动归还，直接返回
    if (!ctx->auto_return_enable) {
        return;
    }
    
    // 检查借出带宽的分类是否需要归还
    for (int i = 0; i < ctx->num_classes; i++) {
        class_state_t* class_b = &ctx->states[i];
        
        // 如果借出了带宽且使用率低于归还阈值
        if (class_b->lent_bw_kbps > 0 && 
            class_b->utilization * 100 < ctx->return_threshold) {
            
            // 查找借用关系
            for (int j = 0; j < ctx->num_records; j++) {
                borrow_record_t* record = &ctx->records[j];
                
                if (!record->returned && 
                    record->from_classid == class_b->classid &&
                    record->borrowed_bw_kbps > 0) {
                    
                    // 找到借入分类
                    int borrow_idx = find_class_by_id(ctx, record->to_classid);
                    if (borrow_idx >= 0) {
                        class_state_t* class_a = &ctx->states[borrow_idx];
                        
                        // 每秒归还借出带宽的10%
                        int return_amount = (int)(class_b->lent_bw_kbps * 
                                                ctx->return_speed);
                        
                        // 确保最小调整单位
                        if (return_amount < ctx->min_change_kbps) {
                            return_amount = ctx->min_change_kbps;
                        }
                        
                        // 不能超过借出的总量
                        if (return_amount > class_b->lent_bw_kbps) {
                            return_amount = class_b->lent_bw_kbps;
                        }
                        
                        // 不能超过借入分类的借用总量
                        if (return_amount > class_a->borrowed_bw_kbps) {
                            return_amount = class_a->borrowed_bw_kbps;
                        }
                        
                        // 不能超过记录的借用总量
                        if (return_amount > record->borrowed_bw_kbps) {
                            return_amount = record->borrowed_bw_kbps;
                        }
                        
                        if (return_amount >= ctx->min_change_kbps) {
                            int old_bw_a = class_a->current_bw_kbps;
                            int old_bw_b = class_b->current_bw_kbps;
                            
                            // 调整带宽
                            adjust_class_bandwidth(ctx, class_a->classid, 
                                                 old_bw_a - return_amount);
                            adjust_class_bandwidth(ctx, class_b->classid, 
                                                 old_bw_b + return_amount);
                            
                            // 更新状态
                            class_a->borrowed_bw_kbps -= return_amount;
                            class_b->lent_bw_kbps -= return_amount;
                            
                            record->borrowed_bw_kbps -= return_amount;
                            
                            ctx->total_return_events++;
                            ctx->total_returned_kbps += return_amount;
                            
                            // 如果完全归还，标记记录
                            if (record->borrowed_bw_kbps <= 0) {
                                record->returned = 1;
                            }
                            
                            log_message(ctx, "INFO",
                                       "带宽归还成功: 从分类 0x%x 归还 %dkbps 到分类 0x%x\n"
                                       "  (%d->%d kbps, %d->%d kbps, 剩余借用=%dkbps)\n",
                                       class_a->classid, return_amount, class_b->classid,
                                       old_bw_a, class_a->current_bw_kbps,
                                       old_bw_b, class_b->current_bw_kbps,
                                       class_a->borrowed_bw_kbps);
                            
                            break;
                        }
                    }
                }
            }
        }
    }
}

/* ==================== 主接口函数 ==================== */
qosdba_result_t qosdba_init(qosdba_context_t* ctx, const char* config_file, 
                           const char* device, int total_bandwidth_kbps) {
    if (!ctx || !config_file || !device) {
        return QOSDBA_ERR_MEMORY;
    }
    
    memset(ctx, 0, sizeof(qosdba_context_t));
    
    // 设置默认参数
    ctx->enabled = 1;  // 默认启用
    ctx->debug_mode = 0;
    ctx->safe_mode = 0;
    
    strncpy(ctx->device, device, sizeof(ctx->device) - 1);
    ctx->total_bandwidth_kbps = total_bandwidth_kbps;
    ctx->start_time = get_current_time_ms();
    
    // 设置默认参数
    ctx->check_interval = DEFAULT_CHECK_INTERVAL;
    ctx->high_util_threshold = DEFAULT_HIGH_UTIL_THRESHOLD;
    ctx->high_util_duration = DEFAULT_HIGH_UTIL_DURATION;
    ctx->low_util_threshold = DEFAULT_LOW_UTIL_THRESHOLD;
    ctx->low_util_duration = DEFAULT_LOW_UTIL_DURATION;
    ctx->borrow_ratio = DEFAULT_BORROW_RATIO;
    ctx->min_borrow_kbps = DEFAULT_MIN_BORROW_KBPS;
    ctx->min_change_kbps = DEFAULT_MIN_CHANGE_KBPS;
    ctx->cooldown_time = DEFAULT_COOLDOWN_TIME;
    ctx->auto_return_enable = 1;  // 默认启用自动归还
    ctx->return_threshold = DEFAULT_RETURN_THRESHOLD;
    ctx->return_speed = DEFAULT_RETURN_SPEED;
    
    // 设置默认优先级策略
    ctx->priority_policy.max_borrow_from_higher_priority = 0;  // 不允许从高优先级借用
    ctx->priority_policy.allow_same_priority_borrow = 0;       // 不允许同优先级借用
    ctx->priority_policy.max_borrow_percentage = 100;          // 最多可借用100%
    ctx->priority_policy.min_lender_priority_gap = 1;          // 最小优先级差距为1
    
    // 首先尝试从UCI配置读取qosdba参数
    int uci_loaded = 0;
    if (load_qosdba_config(ctx) == 0) {
        uci_loaded = 1;
        log_message(ctx, "INFO", "成功从UCI配置加载qosdba参数\n");
        
        // 如果UCI配置中禁用了qosdba，直接返回
        if (!ctx->enabled) {
            log_message(ctx, "INFO", "qosdba在UCI配置中已被禁用\n");
            return QOSDBA_OK;
        }
    } else {
        log_message(ctx, "INFO", "使用默认参数启动qosdba\n");
    }
    
    // 加载分类配置文件
    qosdba_result_t ret = load_config(ctx, config_file);
    if (ret != QOSDBA_OK) {
        return ret;
    }
    
    // 发现现有TC分类
    ret = discover_tc_classes(ctx);
    if (ret != QOSDBA_OK) {
        log_message(ctx, "WARN", "TC分类发现失败\n");
    }
    
    // 初始化TC分类
    ret = init_tc_classes(ctx);
    if (ret != QOSDBA_OK) {
        return ret;
    }
    
    ctx->last_check_time = get_current_time_ms();
    
    log_message(ctx, "INFO", 
               "QoS动态带宽分配器初始化完成: 设备=%s, 总带宽=%dkbps, 分类数=%d\n"
               "检查间隔=%d秒, 高使用率阈值=%d%%, 低使用率阈值=%d%%, 自动归还=%s\n",
               ctx->device, ctx->total_bandwidth_kbps, ctx->num_classes,
               ctx->check_interval, ctx->high_util_threshold, ctx->low_util_threshold,
               ctx->auto_return_enable ? "启用" : "禁用");
    
    return QOSDBA_OK;
}

qosdba_result_t qosdba_run(qosdba_context_t* ctx) {
    if (!ctx) return QOSDBA_ERR_MEMORY;
    
    // 检查是否启用
    if (!ctx->enabled) {
        return QOSDBA_OK;
    }
    
    int64_t now = get_current_time_ms();
    
    // 检查是否到达检查间隔
    if (now - ctx->last_check_time < ctx->check_interval * 1000) {
        return QOSDBA_OK;
    }
    
    ctx->last_check_time = now;
    
    // 检查带宽使用率
    qosdba_result_t ret = check_bandwidth_usage(ctx);
    if (ret != QOSDBA_OK) {
        return ret;
    }
    
    // 运行借用逻辑
    run_borrow_logic(ctx);
    
    // 运行归还逻辑
    run_return_logic(ctx);
    
    return QOSDBA_OK;
}

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
    fprintf(ctx->status_file, "设备: %s\n", ctx->device);
    fprintf(ctx->status_file, "总带宽: %d kbps\n", ctx->total_bandwidth_kbps);
    fprintf(ctx->status_file, "队列算法: %s\n", ctx->qdisc_kind);
    fprintf(ctx->status_file, "运行时间: %ld秒\n", (long)uptime);
    fprintf(ctx->status_file, "分类数量: %d\n", ctx->num_classes);
    fprintf(ctx->status_file, "检查间隔: %d秒\n", ctx->check_interval);
    fprintf(ctx->status_file, "总借用事件: %d\n", ctx->total_borrow_events);
    fprintf(ctx->status_file, "总归还事件: %d\n", ctx->total_return_events);
    fprintf(ctx->status_file, "累计借用带宽: %ld kbps\n", 
            (long)ctx->total_borrowed_kbps);
    fprintf(ctx->status_file, "累计归还带宽: %ld kbps\n", 
            (long)ctx->total_returned_kbps);
    fprintf(ctx->status_file, "\n");
    
    fprintf(ctx->status_file, "=== 分类状态 ===\n");
    for (int i = 0; i < ctx->num_classes; i++) {
        class_state_t* state = &ctx->states[i];
        class_config_t* config = &ctx->configs[i];
        
        fprintf(ctx->status_file, "分类 %s (0x%x):\n", 
                config->name, state->classid);
        fprintf(ctx->status_file, "  优先级: %d\n", config->priority);
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
        fprintf(ctx->status_file, "  统计信息: 峰值=%dkbps, 平均=%dkbps\n",
                state->peak_used_bw_kbps, state->avg_used_bw_kbps);
        fprintf(ctx->status_file, "\n");
    }
    
    if (ctx->num_records > 0) {
        fprintf(ctx->status_file, "=== 借用记录 ===\n");
        int active_records = 0;
        for (int i = 0; i < ctx->num_records; i++) {
            borrow_record_t* record = &ctx->records[i];
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
    
    fprintf(ctx->status_file, "=== 参数配置 ===\n");
    fprintf(ctx->status_file, "启用状态: %s\n", ctx->enabled ? "是" : "否");
    fprintf(ctx->status_file, "检查间隔: %d秒\n", ctx->check_interval);
    fprintf(ctx->status_file, "高使用率阈值: %d%%\n", ctx->high_util_threshold);
    fprintf(ctx->status_file, "高使用率持续时间: %d秒\n", ctx->high_util_duration);
    fprintf(ctx->status_file, "低使用率阈值: %d%%\n", ctx->low_util_threshold);
    fprintf(ctx->status_file, "低使用率持续时间: %d秒\n", ctx->low_util_duration);
    fprintf(ctx->status_file, "借用比例: %.1f%%\n", ctx->borrow_ratio * 100.0f);
    fprintf(ctx->status_file, "最小借用带宽: %d kbps\n", ctx->min_borrow_kbps);
    fprintf(ctx->status_file, "最小调整带宽: %d kbps\n", ctx->min_change_kbps);
    fprintf(ctx->status_file, "冷却时间: %d秒\n", ctx->cooldown_time);
    fprintf(ctx->status_file, "自动归还: %s\n", ctx->auto_return_enable ? "启用" : "禁用");
    fprintf(ctx->status_file, "归还阈值: %d%%\n", ctx->return_threshold);
    fprintf(ctx->status_file, "归还速度: %.1f%%/秒\n", ctx->return_speed * 100.0f);
    fprintf(ctx->status_file, "安全模式: %s\n", ctx->safe_mode ? "是" : "否");
    fprintf(ctx->status_file, "调试模式: %s\n", ctx->debug_mode ? "是" : "否");
    
    fprintf(ctx->status_file, "\n=== 优先级策略 ===\n");
    fprintf(ctx->status_file, "允许从高优先级借用: %s\n", 
            ctx->priority_policy.max_borrow_from_higher_priority ? "是" : "否");
    fprintf(ctx->status_file, "允许同优先级借用: %s\n", 
            ctx->priority_policy.allow_same_priority_borrow ? "是" : "否");
    fprintf(ctx->status_file, "最大借用百分比: %d%%\n", 
            ctx->priority_policy.max_borrow_percentage);
    fprintf(ctx->status_file, "最小优先级差距: %d\n", 
            ctx->priority_policy.min_lender_priority_gap);
    
    fflush(ctx->status_file);
    
    if (status_file) {
        fclose(ctx->status_file);
        ctx->status_file = NULL;
    }
    
    return QOSDBA_OK;
}

qosdba_result_t qosdba_cleanup(qosdba_context_t* ctx) {
    if (!ctx) return QOSDBA_ERR_MEMORY;
    
    log_message(ctx, "INFO", "开始清理资源...\n");
    
    // 将所有分类带宽恢复到初始值
    for (int i = 0; i < ctx->num_classes; i++) {
        class_state_t* state = &ctx->states[i];
        class_config_t* config = &ctx->configs[i];
        
        if (state->current_bw_kbps != config->init_bw_kbps) {
            adjust_class_bandwidth(ctx, state->classid, config->init_bw_kbps);
            
            log_message(ctx, "INFO", 
                       "恢复分类 0x%x 带宽: %d -> %d kbps\n",
                       state->classid,
                       state->current_bw_kbps,
                       config->init_bw_kbps);
        }
    }
    
    // 关闭文件
    if (ctx->status_file) {
        fclose(ctx->status_file);
        ctx->status_file = NULL;
    }
    
    if (ctx->log_file) {
        fclose(ctx->log_file);
        ctx->log_file = NULL;
    }
    
    log_message(ctx, "INFO", "资源清理完成\n");
    
    return QOSDBA_OK;
}

void qosdba_set_debug(qosdba_context_t* ctx, int enable) {
    if (ctx) {
        ctx->debug_mode = enable;
    }
}

void qosdba_set_safe_mode(qosdba_context_t* ctx, int enable) {
    if (ctx) {
        ctx->safe_mode = enable;
    }
}