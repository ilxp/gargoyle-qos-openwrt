#ifndef __QOS_DBA_H__
#define __QOS_DBA_H__

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <pthread.h>
#include <errno.h>

// 定义MIN/MAX宏
#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif

#ifndef MAX
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#endif

// 常量定义
#define MAX_IFACE_LEN 16
#define MAX_CLASSES 16
#define MAX_NAME_LEN 64
#define MAX_CLASSID_LEN 16
#define DEFAULT_CONFIG_PATH "/etc/config/qos_gargoyle"

// 动态带宽分配配置
typedef struct {
    int enabled;                // 是否启用DBA
    int interval;              // 检查间隔(秒)
    int high_usage_threshold;  // 高使用率阈值(%)
    int high_usage_duration;   // 高使用持续时间(秒)
    int low_usage_threshold;   // 低使用率阈值(%)
    int low_usage_duration;    // 低使用持续时间(秒)
    float borrow_ratio;       // 借用比例
    int min_borrow_kbps;      // 最小借用带宽(kbps)
    int min_change_kbps;      // 最小调整带宽(kbps)
    int cooldown_time;        // 冷却时间(秒)
    int auto_return_enable;   // 启用自动归还
    int return_threshold;     // 归还阈值(%)
    float return_speed;       // 归还速度
} dba_config_t;

// QoS分类结构
typedef struct {
    int id;                    // 分类ID
    int enabled;             // 分类是否启用
    int adjusted;            // 是否已调整
    char name[MAX_NAME_LEN];  // 分类名称
    int config_max_kbps;    // 配置的最大带宽(kbps)
    int config_min_kbps;    // 配置的最小带宽(kbps)
    int config_percent;     // 配置的百分比
    int current_kbps;      // 当前分配的带宽(kbps)
    int used_kbps;         // 当前使用的带宽(kbps)
    float usage_rate;      // 使用率(0-1)
    float avg_usage_rate;  // 平均使用率(0-1)
    int borrowed_kbps;     // 借入的带宽(kbps)
    int lent_kbps;         // 借出的带宽(kbps)
    int priority;          // 分类优先级
    int high_usage_seconds; // 高使用持续时间
    int low_usage_seconds;  // 低使用持续时间
    int normal_usage_seconds; // 正常使用持续时间
    int peak_usage_kbps;   // 峰值使用带宽(kbps)
    int adjust_count;       // 调整次数
    int borrowed_from[MAX_CLASSES];  // 从哪些分类借入
    int lent_to[MAX_CLASSES];        // 借给哪些分类
    char classid[MAX_CLASSID_LEN];  // TC分类ID
    time_t last_adjust_time;        // 最后调整时间
    time_t last_borrow_time;        // 最后借入时间
    time_t last_lend_time;          // 最后借出时间
} qos_class_t;

// QoS DBA系统状态
typedef struct {
    dba_config_t config;           // DBA配置
    qos_class_t *upload_classes;   // 上传分类数组
    qos_class_t *download_classes; // 下载分类数组
    int upload_class_count;        // 上传分类数量
    int download_class_count;      // 下载分类数量
    int total_bandwidth_kbps;      // 总带宽(kbps)
    char wan_interface[MAX_IFACE_LEN]; // WAN接口
    int is_initialized;            // 是否已初始化
    int should_exit;              // 是否应该退出
    int verbose;                  // 详细输出
    pthread_mutex_t mutex;        // 互斥锁
    time_t last_adjust_time;      // 上次调整时间
} qos_dba_system_t;

// 全局系统变量声明
extern qos_dba_system_t g_qos_system;
extern pthread_t g_monitor_thread;
extern int g_is_running;

// 核心DBA函数声明
int qos_dba_init(const char *config_path);
int qos_dba_start(void);
int qos_dba_stop(void);
int qos_dba_reload_config(void);
int qos_dba_set_verbose(int verbose);
void qos_dba_print_status(void);
void qos_dba_cleanup(void);

// 带宽调整函数声明
int adjust_upload_classes(void);
int adjust_download_classes(void);
int auto_return_borrowed_bandwidth(void);
int borrow_bandwidth_for_class(qos_class_t *dst_class, int needed_kbps, int is_upload);
int lend_bandwidth_to_class(qos_class_t *src_class, int to_class_id, int kbps, int is_upload);
void write_dba_status(void);

// TC操作函数声明
int setup_qos_tc_rules(void);
int cleanup_qos_tc_rules(void);
int adjust_tc_class_bandwidth(const char *iface, const char *classid, int kbps);
int get_class_usage(const char *iface, const char *classid, int *kbps, float *rate);

// 配置管理函数声明
int load_dba_config(const char *config_path);
int load_qos_classes(const char *config_path);
int save_qos_config_to_uci(qos_dba_system_t *qos_system);
int parse_bandwidth_string(const char *str, int *kbps);
int validate_qos_classes(qos_class_t *classes, int class_count, int total_bandwidth);

// 监控和统计函数声明
int monitor_all_classes(void);
static void *monitor_thread(void *arg);
int collect_class_statistics(qos_class_t *classes, int class_count, int is_upload);
void print_class_statistics(qos_class_t *classes, int class_count, const char *direction);

// 工具函数声明
static int detect_wan_interface(void);
static int detect_total_bandwidth(void);
static int execute_command(const char *cmd, char *output, int output_len);
int get_interface_speed(const char *iface, int *tx_speed, int *rx_speed);
int get_interface_usage(const char *iface, int *tx_kbps, int *rx_kbps);

// 日志和调试宏
#define DEBUG_LOG(fmt, ...) \
    do { \
        if (g_qos_system.verbose) { \
            time_t now = time(NULL); \
            struct tm *tm = localtime(&now); \
            fprintf(stderr, "[%02d:%02d:%02d] " fmt "\n", \
                    tm->tm_hour, tm->tm_min, tm->tm_sec, \
                    ##__VA_ARGS__); \
        } \
    } while(0)

#define INFO_LOG(fmt, ...) \
    do { \
        time_t now = time(NULL); \
        struct tm *tm = localtime(&now); \
        fprintf(stdout, "[%02d:%02d:%02d] " fmt "\n", \
                tm->tm_hour, tm->tm_min, tm->tm_sec, \
                ##__VA_ARGS__); \
    } while(0)

#define ERROR_LOG(fmt, ...) \
    do { \
        time_t now = time(NULL); \
        struct tm *tm = localtime(&now); \
        fprintf(stderr, "[%02d:%02d:%02d] ERROR: " fmt "\n", \
                tm->tm_hour, tm->tm_min, tm->tm_sec, \
                ##__VA_ARGS__); \
    } while(0)

// 内存管理宏
#define MALLOC_CHECK(ptr) \
    do { \
        if (!(ptr)) { \
            ERROR_LOG("内存分配失败: %s:%d", __FILE__, __LINE__); \
            exit(EXIT_FAILURE); \
        } \
    } while(0)

#define FREE_IF_NOT_NULL(ptr) \
    do { \
        if (ptr) { \
            free(ptr); \
            (ptr) = NULL; \
        } \
    } while(0)

// 互斥锁操作宏
#define LOCK_MUTEX(mutex) \
    do { \
        if (pthread_mutex_lock(&(mutex)) != 0) { \
            ERROR_LOG("锁定互斥锁失败"); \
        } \
    } while(0)

#define UNLOCK_MUTEX(mutex) \
    do { \
        if (pthread_mutex_unlock(&(mutex)) != 0) { \
            ERROR_LOG("解锁互斥锁失败"); \
        } \
    } while(0)

// 带宽计算宏
#define KBPS_TO_MBPS(kbps) ((kbps) / 1000.0)
#define MBPS_TO_KBPS(mbps) ((int)((mbps) * 1000))
#define KBPS_TO_GBPS(kbps) ((kbps) / 1000000.0)
#define GBPS_TO_KBPS(gbps) ((int)((gbps) * 1000000))

#endif // __QOS_DBA_H__