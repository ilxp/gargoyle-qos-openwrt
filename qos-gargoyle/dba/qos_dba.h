#ifndef _QOS_DBA_H_
#define _QOS_DBA_H_

#include <stdint.h>

#define MAX_CLASSES 10
#define LOG_INFO(fmt, ...) printf("[INFO] " fmt "\n", ##__VA_ARGS__)
#define LOG_ERROR(fmt, ...) printf("[ERROR] " fmt "\n", ##__VA_ARGS__)
#define LOG_DEBUG(fmt, ...) printf("[DEBUG] " fmt "\n", ##__VA_ARGS__)

// QoS分类结构
typedef struct qos_class {
    char name[32];                  // 分类名称
    char classid[16];               // 分类ID
    int priority;                   // 优先级
    int min_kbps;                   // 最小带宽(Kbps)
    int max_kbps;                   // 最大带宽(Kbps)
    float percent_bandwidth;       // 带宽百分比
    int lent_kbps;                  // 已借出的带宽(Kbps)
    int borrowed_kbps;              // 已借入的带宽(Kbps)
} qos_class_t;

// DBA系统配置
typedef struct qos_dba_system {
    int enabled;                    // 是否启用DBA
    int interval;                   // 监控间隔(秒)
    int high_usage_threshold;       // 高使用率阈值(%)
    int high_usage_duration;        // 高使用率持续时间(秒)
    int low_usage_threshold;        // 低使用率阈值(%)
    int low_usage_duration;         // 低使用率持续时间(秒)
    float borrow_ratio;             // 借用比例(0.0-1.0)
    int min_borrow_kbps;            // 最小借用带宽(Kbps)
    int min_change_kbps;            // 最小变化带宽(Kbps)
    int cooldown_time;              // 冷却时间(秒)
    int auto_return_enable;         // 自动返还启用
    int return_threshold;           // 返还阈值(%)
    float return_speed;             // 返还速度(Kbps/秒)
    
    // QoS分类
    qos_class_t upload_classes[MAX_CLASSES];
    int upload_class_count;
    qos_class_t download_classes[MAX_CLASSES];
    int download_class_count;
    
    // 统计信息
    uint64_t total_upload_bytes;
    uint64_t total_download_bytes;
    uint64_t last_check_time;
    
    // 状态标志
    int borrowing_active;           // 是否正在借用带宽
    int cooling_down;               // 是否处于冷却期
    int cooling_until;              // 冷却结束时间
} qos_dba_system_t;

// 函数声明
int load_default_config(qos_dba_system_t *qos_system);
int load_qos_config_from_uci(qos_dba_system_t *qos_system);
int save_qos_config_to_uci(qos_dba_system_t *qos_system);
void print_qos_config(qos_dba_system_t *qos_system);

#endif // _QOS_DBA_H_