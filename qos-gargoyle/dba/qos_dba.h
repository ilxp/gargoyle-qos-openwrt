#ifndef QOS_DBA_H
#define QOS_DBA_H

#include "config_parser.h"
#include <stdint.h>
#include <time.h>

// 带宽调整操作类型
typedef enum {
    BORROW_BANDWIDTH = 0,    // 借入带宽
    RETURN_BANDWIDTH,         // 归还带宽
    RESET_BANDWIDTH,          // 重置带宽
    ADJUST_BANDWIDTH          // 调整带宽
} adjust_operation_t;

// 带宽使用状态
typedef enum {
    LOW_USAGE = 0,           // 低使用率
    NORMAL_USAGE,            // 正常使用率
    HIGH_USAGE,              // 高使用率
    OVERLOAD_USAGE           // 过载使用率
} usage_state_t;

// QoS分类结构体
typedef struct qos_class {
    char name[64];
    unsigned int classid;
    int config_min_kbps;
    int config_max_kbps;
    int current_kbps;
    int used_kbps;
    float usage_rate;
    float avg_usage_rate;
    int borrowed_kbps;
    int status;                      // 当前状态: LOW_USAGE, NORMAL_USAGE, HIGH_USAGE
    int status_duration[4];         // 各状态持续时间，对应usage_state_t枚举
    int peak_usage_kbps;
    time_t last_adjust_time;
} qos_class_t;

// DBA配置结构体
typedef struct dba_config {
    int enable;                     // 是否启用DBA
    int cooldown_time;              // 冷却时间（秒）
    int high_usage_threshold;      // 高使用率阈值（百分比）
    int low_usage_threshold;       // 低使用率阈值（百分比）
    int high_usage_duration;        // 高使用率持续时间（秒）
    int low_usage_duration;         // 低使用率持续时间（秒）
    int min_borrow_kbps;           // 最小借用带宽（kbps）
    int min_change_kbps;           // 最小变化带宽（kbps）
    float borrow_ratio;            // 借用比例
    float return_speed;            // 归还速度比例
    int return_threshold;          // 归还阈值
    int auto_return_enable;        // 是否启用自动归还
} dba_config_t;

// DBA系统结构体
typedef struct qos_dba_system {
    char iface_name[16];           // 接口名称
    dba_config_t config;
    qos_class_t *upload_classes;
    qos_class_t *download_classes;
    int upload_class_count;
    int download_class_count;
    int total_upload_kbps;         // 总上传带宽
    int total_download_kbps;       // 总下载带宽
    int running;                   // 是否正在运行
    pthread_t monitor_thread;      // 监控线程
} qos_dba_system_t;

// 全局变量声明
extern qos_dba_system_t g_qos_system;

// DBA算法相关函数声明

// 初始化DBA系统
int qos_dba_init(void);
int qos_dba_deinit(void);

// 主运行函数
int qos_dba_run(void);
void qos_dba_stop(void);
int qos_dba_loop_once(void);

// 带宽调整函数
int qos_dba_adjust_bandwidth(void);
int borrow_bandwidth(qos_class_t *borrower, qos_class_t *lender, int kbps);
int return_bandwidth(qos_class_t *returner, qos_class_t *receiver, int kbps);
int reset_bandwidth(qos_class_t *cls);

// 状态检查和判断函数
int check_bandwidth_usage(void);
usage_state_t get_usage_state(qos_class_t *cls);
int can_borrow_bandwidth(qos_class_t *cls);
int can_lend_bandwidth(qos_class_t *cls);
int should_return_bandwidth(qos_class_t *cls);

// 统计和监控函数
int update_bandwidth_usage(const char *classid, int is_upload, int used_kbps);
int get_class_bandwidth_stats(const char *classid, int is_upload, 
                              int *min_bw, int *max_bw, int *cur_bw, int *used_bw);
int calculate_usage_rates(void);
int update_peak_usage(void);

// 系统配置函数
void qos_dba_set_total_bandwidth(int upload_kbps, int download_kbps);
int qos_dba_enable(int enable);
int qos_dba_set_config(const dba_config_t *config);

// 工具函数
int apply_tc_rule(const char *classid, int kbps);
int apply_qos_rule(qos_class_t *cls);
int get_current_time(void);
int is_cooldown_period(qos_class_t *cls);
void print_dba_status(void);
void print_qos_classes_status(void);

// 获取和设置函数
qos_dba_system_t* get_qos_dba_system(void);
dba_config_t* get_dba_config(void);
qos_class_t* get_class_by_name(const char *name, int is_upload);
qos_class_t* get_class_by_id(int id, int is_upload);
int get_total_available_bandwidth(int is_upload);
int get_total_used_bandwidth(int is_upload);
float get_total_usage_rate(int is_upload);

// 新的函数声明（修复编译错误）
int adjust_tc_class_bandwidth(const char *interface, unsigned int classid, int kbps);
float get_class_usage_rate(const char *interface, unsigned int classid);
int get_class_used_kbps(const char *interface, unsigned int classid);

// 修复4：添加调整函数声明
int adjust_upload_classes(void);
int adjust_download_classes(void);
void monitor_all_classes(void);
int auto_return_borrowed_bandwidth(void);

#endif /* QOS_DBA_H */