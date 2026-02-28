#ifndef QOS_DBA_H
#define QOS_DBA_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

// 调试日志
#ifdef DEBUG
#define DEBUG_LOG(fmt, ...) printf("[DBA] " fmt "\n", ##__VA_ARGS__)
#else
#define DEBUG_LOG(fmt, ...)
#endif

// 配置常量
#define MAX_CLASSES 10
#define MAX_CLASSID_LEN 16
#define MAX_NAME_LEN 32
#define MAX_IFACE_LEN 16
#define DEFAULT_CONFIG_PATH "/etc/config/qos_gargoyle"

// 结构定义
typedef struct {
    char classid[MAX_CLASSID_LEN];      // TC classid
    char name[MAX_NAME_LEN];            // 分类名称
    int priority;                       // 优先级 (0=最高)
    
    int config_percent;                 // 配置的带宽百分比
    int config_min_kbps;               // 最小带宽 (kbps)
    int config_max_kbps;               // 最大带宽 (kbps)
    int current_kbps;                  // 当前分配的带宽
    
    int used_kbps;                     // 当前使用的带宽
    float usage_rate;                  // 使用率 (0-1)
    float avg_usage_rate;              // 平均使用率
    
    int high_usage_seconds;            // 高使用持续时间
    int low_usage_seconds;             // 低使用持续时间
    int normal_usage_seconds;          // 正常使用持续时间
    
    int peak_usage_kbps;               // 峰值使用带宽
    int borrowed_kbps;                 // 借用的带宽（正数表示借用，负数表示借出）
    int adjust_count;                  // 调整次数
    
    time_t last_adjust_time;           // 上次调整时间
} qos_class_t;

typedef struct {
    int enabled;                       // DBA是否启用
    int interval;                      // 检查间隔（秒）
    int high_usage_threshold;          // 高使用阈值（%）
    int high_usage_duration;           // 高使用持续时间（秒）
    int low_usage_threshold;           // 低使用阈值（%）
    int low_usage_duration;            // 低使用持续时间（秒）
    float borrow_ratio;                // 借用比例 (0-1)
    int min_borrow_kbps;               // 最小借用带宽
    int min_change_kbps;               // 最小调整带宽
    int cooldown_time;                 // 冷却时间（秒）
    
    int auto_return_enable;           // 自动归还开关
    int return_threshold;              // 归还阈值（%）
    float return_speed;                // 归还速度
} dba_config_t;

typedef struct {
    dba_config_t config;               // DBA配置
    qos_class_t *upload_classes;       // 上传分类
    qos_class_t *download_classes;     // 下载分类
    int upload_class_count;            // 上传分类数
    int download_class_count;          // 下载分类数
    
    char wan_interface[MAX_IFACE_LEN]; // WAN接口名称
    int total_bandwidth_kbps;          // 总带宽 (kbps)
    
    int is_initialized;                // 是否已初始化
    int should_exit;                   // 是否应该退出
    int verbose;                       // 详细输出
    
    pthread_mutex_t mutex;             // 互斥锁
} qos_dba_system_t;

// 全局系统实例
extern qos_dba_system_t g_qos_system;

// 函数声明
int qos_dba_init(const char *config_path);
int qos_dba_start(void);
int qos_dba_stop(void);
int qos_dba_reload_config(void);
int qos_dba_set_verbose(int verbose);
void qos_dba_print_status(void);

// 配置文件解析函数
int load_dba_config(const char *config_path);
int load_qos_classes(const char *config_path);

// 监控和调整函数
void monitor_all_classes(void);
int adjust_upload_classes(void);
int adjust_download_classes(void);
int auto_return_borrowed_bandwidth(void);

// TC工具函数
int execute_command(const char *cmd, char *output, int output_len);
float get_class_usage_rate(const char *iface, const char *classid);
int get_class_used_kbps(const char *iface, const char *classid);
int adjust_tc_class_bandwidth(const char *iface, const char *classid, int new_kbps);

#endif