#ifndef QOS_DBA_H
#define QOS_DBA_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>

// 编译开关
#define ENABLE_DEBUG 1
#define MAX_PATH_LEN 256
#define MAX_CLASSES 10
#define MAX_CLASSID_LEN 16
#define MAX_NAME_LEN 32
#define MAX_IFACE_LEN 16

// 调试输出
#if ENABLE_DEBUG
    #define DEBUG_LOG(fmt, ...) \
        do { \
            fprintf(stderr, "[%s:%d] " fmt "\n", \
                    __func__, __LINE__, ##__VA_ARGS__); \
        } while(0)
#else
    #define DEBUG_LOG(fmt, ...) do {} while(0)
#endif

// QoS分类结构
typedef struct {
    char classid[MAX_CLASSID_LEN];    // TC classid，如"1:10"
    char name[MAX_NAME_LEN];          // 分类名称
    int direction;                   // 0=上传, 1=下载
    int config_percent;               // 配置的百分比
    int config_min_kbps;              // 配置的最小带宽(kbps)
    int config_max_kbps;              // 配置的最大带宽(kbps)
    int priority;                     // 优先级(0=最高)
    
    // 运行时状态
    int current_kbps;                // 当前分配的带宽(kbps)
    int used_kbps;                   // 实际使用的带宽(kbps)
    float usage_rate;                // 使用率 = used_kbps / current_kbps
    
    // 持续时间计数器
    int high_usage_seconds;          // 持续高使用率秒数
    int low_usage_seconds;           // 持续低使用率秒数
    int normal_usage_seconds;         // 持续正常使用率秒数
    
    // 带宽借用状态
    int borrowed_kbps;               // 借入的带宽(kbps，正数表示借入，负数表示借出)
    time_t last_adjust_time;         // 上次调整时间
    
    // 统计信息
    int peak_usage_kbps;             // 峰值使用带宽
    float avg_usage_rate;            // 平均使用率(滑动窗口)
    int adjust_count;                // 调整次数
    
} qos_class_t;

// DBA配置参数
typedef struct {
    int enabled;                     // 是否启用
    int interval;                    // 检查间隔(秒)
    
    // 调整参数
    int min_change_kbps;             // 最小调整带宽
    int high_usage_threshold;        // 高使用率阈值(%)
    int high_usage_duration;         // 高使用率持续时间(秒)
    int low_usage_threshold;         // 低使用率阈值(%)
    int low_usage_duration;          // 低使用率持续时间(秒)
    float borrow_ratio;              // 借用空闲带宽的比例
    int min_borrow_kbps;             // 最小借用带宽
    int cooldown_time;               // 冷却时间(秒)
    
    // 自动归还参数
    int auto_return_enable;          // 是否启用自动归还
    int return_threshold;            // 归还阈值(%)
    float return_speed;              // 归还速度比例
    
} dba_config_t;

// QoS系统全局状态
typedef struct {
    int total_bandwidth_kbps;        // 总带宽(kbps)
    char wan_interface[MAX_IFACE_LEN];  // WAN接口名称
    int is_initialized;              // 是否已初始化
    
    // 分类管理
    qos_class_t *upload_classes;     // 上传分类数组
    qos_class_t *download_classes;   // 下载分类数组
    int upload_class_count;          // 上传分类数量
    int download_class_count;        // 下载分类数量
    
    // DBA配置
    dba_config_t config;             // DBA配置
    
    // 运行时状态
    int should_exit;                 // 退出标志
    int verbose;                     // 详细输出标志
    
    // 互斥锁
    pthread_mutex_t mutex;
    
} qos_system_t;

// 全局系统实例
extern qos_system_t g_qos_system;

// 函数声明
int qos_dba_init(const char *config_path);
int qos_dba_start(void);
int qos_dba_stop(void);
int qos_dba_reload_config(void);
void qos_dba_print_status(void);
int qos_dba_set_verbose(int verbose);

// 工具函数
int parse_bandwidth_string(const char *str);
char *trim_whitespace(char *str);
int is_numeric_string(const char *str);
int execute_command(const char *cmd, char *output, int output_len);
float get_class_usage_rate(const char *iface, const char *classid);
int adjust_tc_class_bandwidth(const char *iface, const char *classid, int new_kbps);

#endif // QOS_DBA_H