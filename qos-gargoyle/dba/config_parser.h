#ifndef CONFIG_PARSER_H
#define CONFIG_PARSER_H

#include <stdint.h>

// 常量定义
#define MAX_NAME_LEN 32
#define MAX_CLASSID_LEN 16
#define MAX_BORROW_RELATIONS 5
#define MAX_UPLOAD_CLASSES 20
#define MAX_DOWNLOAD_CLASSES 20

// QoS分类结构
typedef struct qos_class {
    char name[MAX_NAME_LEN];
    char classid[MAX_CLASSID_LEN];
    int id;
    int priority;
    int config_min_kbps;  // 配置的最小带宽
    int config_max_kbps;  // 配置的最大带宽
    int current_kbps;     // 当前分配的带宽
    int used_kbps;        // 当前使用的带宽
    float usage_rate;     // 使用率
    float avg_usage_rate; // 平均使用率
    int enabled;         // 是否启用
    int adjusted;        // 是否已被调整
    int borrowed_kbps;   // 借入的带宽
    int lent_kbps;       // 借出的带宽
    int borrowed_from[MAX_BORROW_RELATIONS];  // 从哪些分类借入
    int lent_to[MAX_BORROW_RELATIONS];        // 借给哪些分类
    int peak_usage_kbps;  // 峰值使用带宽
    int adjust_count;     // 调整次数
    int last_adjust_time; // 上次调整时间
    int last_borrow_time; // 上次借入时间
    int last_lend_time;   // 上次借出时间
} qos_class_t;

// DBA配置结构
typedef struct dba_config {
    int enabled;                    // 是否启用DBA
    int interval;                   // 检查间隔(秒)
    int high_usage_threshold;       // 高使用率阈值(%)
    int high_usage_duration;        // 高使用持续时间(秒)
    int low_usage_threshold;        // 低使用率阈值(%)
    int low_usage_duration;         // 低使用持续时间(秒)
    float borrow_ratio;             // 借用比例
    int min_borrow_kbps;            // 最小借用带宽(kbps)
    int min_change_kbps;            // 最小调整带宽(kbps)
    int cooldown_time;              // 冷却时间(秒)
    int auto_return_enable;         // 是否启用自动归还
    int return_threshold;           // 归还阈值(%)
    float return_speed;             // 归还速度
} dba_config_t;

// DBA系统结构
typedef struct qos_dba_system {
    dba_config_t config;            // DBA配置
    int total_bandwidth_kbps;       // 总带宽
    int current_total_usage_kbps;   // 当前总使用带宽
    float current_total_usage_rate; // 当前总使用率
    
    qos_class_t *upload_classes;     // 上传分类数组
    qos_class_t *download_classes;   // 下载分类数组
    int upload_class_count;          // 上传分类数量
    int download_class_count;        // 下载分类数量
    
    int total_upload_classes;        // 总上传分类数
    int total_download_classes;      // 总下载分类数
    
    int borrow_count;               // 借入次数
    int lend_count;                  // 借出次数
    int total_adjustments;          // 总调整次数
    int start_time;                 // 系统启动时间
    int initializing;              // 初始化标志
    int running;                    // 运行标志
    int exiting;                    // 退出标志
} qos_dba_system_t;

// 全局系统变量
extern qos_dba_system_t g_qos_system;

// 调试日志函数
void DEBUG_LOG(const char *format, ...);
void ERROR_LOG(const char *format, ...);
void INFO_LOG(const char *format, ...);

// 配置相关函数
int load_dba_config(void);
int load_qos_classes(void);
int validate_qos_classes(void);
qos_class_t* get_qos_class(const char *classid, int is_upload);
int save_qos_config_to_uci(void);
void cleanup_qos_config(void);

// 辅助函数
int init_qos_dba_system(void);
int parse_config_file(const char *config_path);
int save_config_file(const char *config_path);
int get_total_bandwidth_from_config(void);
void print_qos_system_status(void);

#endif /* CONFIG_PARSER_H */