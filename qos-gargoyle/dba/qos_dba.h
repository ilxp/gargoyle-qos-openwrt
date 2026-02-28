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

// 接口名最大长度
#define MAX_IFACE_LEN 16
#define MAX_CLASSES 16
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
    int enabled;             // 分类是否启用
    char name[64];          // 分类名称
    int config_max_kbps;    // 配置的最大带宽(kbps)
    int config_min_kbps;    // 配置的最小带宽(kbps)
    int config_percent;     // 配置的百分比
    int current_kbps;      // 当前分配的带宽(kbps)
    int used_kbps;         // 当前使用的带宽(kbps)
    float usage_rate;      // 使用率(0-1)
    int borrowed_kbps;     // 借入的带宽(kbps)
    int borrowed_from;     // 从哪个分类借入(-1表示未借入)
    int lent_kbps;         // 借出的带宽(kbps)
    int lent_to;           // 借给哪个分类索引(-1表示未借出)
    int priority;          // 分类优先级
    int high_usage_seconds; // 高使用持续时间
    int low_usage_seconds;  // 低使用持续时间
    int normal_usage_seconds; // 正常使用持续时间
    char classid[16];      // TC分类ID
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

// 函数声明
int qos_dba_init(const char *config_path);
int qos_dba_start(void);
int qos_dba_stop(void);
int qos_dba_reload_config(void);
int qos_dba_set_verbose(int verbose);
void qos_dba_print_status(void);
int adjust_upload_classes(void);
int adjust_download_classes(void);
int auto_return_borrowed_bandwidth(void);
int borrow_bandwidth_for_class(qos_class_t *dst_class, int needed_kbps, int is_upload);
void write_dba_status(void);

// 辅助函数声明
static int parse_bandwidth_string(const char *str);
static int detect_wan_interface(void);
static int detect_total_bandwidth(void);
static int load_dba_config(const char *config_path);
static int load_qos_classes(const char *config_path);
static int execute_command(const char *cmd, char *output, int output_len);
static int adjust_tc_class_bandwidth(const char *iface, const char *classid, int kbps);
static int monitor_all_classes(void);
static void *monitor_thread(void *arg);

// 日志宏
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

#endif // __QOS_DBA_H__