#ifndef QOSDBA_H
#define QOSDBA_H

/*
 * qosdba.h - QoS DBA 2.1.1 核心头文件
 * 定义主要数据结构、常量、函数原型
 * 版本: 2.1.1
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <pthread.h>
#include <time.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>

/* ==================== libnetlink (TC库) 头文件 ==================== */

#ifdef QOSDBA_OPENWRT
    /* OpenWrt构建模式 - 使用iproute2 TC库 */
    #include <linux/pkt_sched.h>
    #include <linux/if_link.h>
    
    /* OpenWrt的TC库头文件 */
    extern "C" {
        #include "libnetlink.h"
        #include "rtnetlink.h"
    }
    
    /* 定义TC相关结构体（如果没有） */
    #ifndef HAVE_TC_STRUCTS
    struct tc_htb_glob {
        __u32 version;
        __u32 rate2quantum;
        __u32 defcls;
        __u32 debug;
    };
    
    struct tc_htb_opt {
        struct tc_ratespec rate;
        struct tc_ratespec ceil;
        __u32 buffer;
        __u32 cbuffer;
        __u32 quantum;
        __u32 level;
        __u32 prio;
    };
    #endif
    
#else
    /* 标准Linux构建模式 - 使用系统libnetlink */
    #include <libnetlink.h>
    #include <rtnetlink.h>
    #include <linux/pkt_sched.h>
    #include <linux/if_link.h>
#endif

/* ==================== 版本信息 ==================== */
#define QOSDBA_VERSION "2.1.1"
#define QOSDBA_MAJOR_VERSION 2
#define QOSDBA_MINOR_VERSION 1
#define QOSDBA_PATCH_VERSION 1

/* ==================== 全局常量 ==================== */
#define MAX_CLASSES 32
#define MAX_BORROW_RECORDS 64
#define MAX_DEVICES 2
#define MAX_CONFIG_LINE 512
#define MAX_QDISC_KIND_LEN 16
#define MAX_CLASS_NAME_LEN 63
#define MAX_DEVICE_NAME_LEN 15
#define MAX_PATH_LEN 255
#define MAX_ERROR_DETAIL_LEN 511
#define MAX_LOG_MESSAGE_LEN 2047
#define MAX_TIMESTAMP_LEN 31

/* 默认参数 */
#define DEFAULT_CHECK_INTERVAL 1
#define DEFAULT_HIGH_UTIL_THRESHOLD 85
#define DEFAULT_LOW_UTIL_THRESHOLD 40
#define DEFAULT_BORROW_RATIO 0.2f
#define DEFAULT_MIN_BORROW_KBPS 128
#define DEFAULT_MIN_CHANGE_KBPS 128
#define DEFAULT_COOLDOWN_TIME 8
#define DEFAULT_RETURN_THRESHOLD 50
#define DEFAULT_RETURN_SPEED 0.1f

/* QoS算法支持 */
#define ALGORITHM_UNKNOWN 0
#define ALGORITHM_HTB 1  /* 仅支持HTB分层令牌桶算法 */

/* 日志级别 */
#define LOG_LEVEL_DEBUG 0
#define LOG_LEVEL_INFO 1
#define LOG_LEVEL_WARN 2
#define LOG_LEVEL_ERROR 3

/* 连续时间窗口大小 */
#define WINDOW_SIZE 10
#define HISTORY_SECONDS 10

/* 紧急保护默认值 */
#define DEFAULT_STARVATION_WARNING 80
#define DEFAULT_STARVATION_CRITICAL 90
#define DEFAULT_EMERGENCY_RETURN_RATIO 0.5f
#define DEFAULT_HIGH_PRIORITY_PROTECT_LEVEL 95

/* ==================== 返回码枚举 ==================== */
typedef enum {
    QOSDBA_OK = 0,
    QOSDBA_ERR_MEMORY = -1,
    QOSDBA_ERR_FILE = -2,
    QOSDBA_ERR_CONFIG = -3,
    QOSDBA_ERR_SYSTEM = -4,
    QOSDBA_ERR_TC = -5,
    QOSDBA_ERR_INVALID = -6,
    QOSDBA_ERR_NETWORK = -7,
    QOSDBA_ERR_TIMEOUT = -8,
    QOSDBA_ERR_PERFORMANCE = -9,
    QOSDBA_ERR_SECURITY = -10,
    QOSDBA_ERR_MAINTENANCE = -11,
    QOSDBA_ERR_ALIGNMENT = -12,
    QOSDBA_ERR_SIGNAL = -13,
    QOSDBA_ERR_PARSING = -14,
    QOSDBA_ERR_FLOAT = -15,
    QOSDBA_ERR_THREAD = -16,
    QOSDBA_ERR_SANITY = -17,
    QOSDBA_ERR_INSUFFICIENT = -18,  /* 带宽不足 */
    QOSDBA_ERR_NO_LENDER = -19,     /* 无可用借出方 */
    QOSDBA_PARTIAL_SUCCESS = 1      /* 部分成功 */
} qosdba_result_t;

/* ==================== 数据结构 ==================== */

/* 使用率滑动窗口 */
typedef struct {
    float utilization_samples[WINDOW_SIZE];  /* 10秒历史数据 */
    int64_t sample_timestamps[WINDOW_SIZE];  /* 样本时间戳 */
    int sample_index;                        /* 当前索引 */
    int sample_count;                        /* 有效样本数 */
    float last_average_5s;                   /* 最近5秒平均值 */
    int continuous_high_count;               /* 连续高使用计数 */
    int continuous_low_count;                /* 连续低使用计数 */
} utilization_window_t;

/* 分类带宽配置 */
typedef struct {
    int classid;
    char name[MAX_CLASS_NAME_LEN + 1];
    int priority;
    int total_bw_kbps;
    int min_bw_kbps;
    int max_bw_kbps;
    int dba_enabled;
} class_config_t;

/* 分类状态 */
typedef struct {
    int classid;
    int current_bw_kbps;
    int used_bw_kbps;
    float utilization;
    int borrowed_bw_kbps;
    int lent_bw_kbps;
    int high_util_duration;
    int low_util_duration;
    int cooldown_timer;
    int64_t last_check_time;
    int64_t total_bytes;
    int64_t last_total_bytes;
    int peak_used_bw_kbps;
    int avg_used_bw_kbps;
    int dba_enabled;
    int continuous_high;      /* 是否连续高使用率 */
    int continuous_low;       /* 是否连续低使用率 */
    int borrow_qualified;     /* 是否具备借用资格 */
    int lend_qualified;       /* 是否具备借出资格 */
    int emergency_lock;       /* 紧急锁定标志 */
    int64_t emergency_lock_until;  /* 紧急锁定截止时间 */
    int daily_lent_kbps;      /* 今日已借出量 */
} class_state_t;

/* 借用记录 */
typedef struct {
    int from_classid;
    int to_classid;
    int borrowed_bw_kbps;
    int64_t start_time;
    int returned;
} borrow_record_t;

/* 优先级策略 */
typedef struct {
    int max_borrow_from_higher_priority;
    int allow_same_priority_borrow;
    int max_borrow_percentage;
    int min_lender_priority_gap;
} priority_policy_t;

/* TC缓存 */
typedef struct {
    struct rtnl_class* cached_classes[MAX_CLASSES];
    int num_cached_classes;
    int64_t last_query_time;
    int valid;
    int query_interval_ms;
    int access_count;
    int64_t last_access_time;
    float hotness_score;
    float hit_rate;
    int adaptive_enabled;
    pthread_mutex_t cache_mutex;
} tc_cache_t;

/* 批量命令 */
typedef struct {
    struct rtnl_class** classes;
    int command_count;
    int capacity;
    int max_commands;
    float avg_batch_size;
    int64_t last_adjust_time;
    int adjustment_count;
    int adaptive_enabled;
} batch_commands_t;

/* 异步监控 */
typedef struct {
    int epoll_fd;
    int inotify_fd;
    int watch_fd;
    int async_enabled;
    int64_t last_async_check;
} async_monitor_t;

/* 性能统计 */
typedef struct {
    int64_t total_nl_operations;
    int64_t total_nl_time_ms;
    int64_t max_nl_time_ms;
    int nl_errors;
    int64_t cache_hits;
    int64_t cache_misses;
    int64_t batch_executions;
    int64_t total_batch_commands;
    int64_t total_memory_allocated;
    int64_t peak_memory_usage;
    int64_t retry_attempts;
    int64_t retry_success;
    int64_t retry_failures;
    int64_t successful_borrows;
    int64_t failed_borrows;
    int64_t successful_returns;
    int64_t failed_returns;
    int64_t failed_decisions;
    int64_t failed_batch_commands;
    int64_t emergency_returns;
    int64_t monitor_operations;
    int64_t total_monitor_time_ms;
    int64_t total_cycles;
    int64_t total_cycle_time_ms;
    int64_t max_cycle_time_ms;
} perf_stats_t;

/* 系统监控 */
typedef struct {
    int64_t memory_usage_mb;
    float cpu_usage_percent;
    int file_descriptors_used;
    int system_calls_per_sec;
    int network_latency_ms;
    int error_count;
    int warning_count;
    int64_t last_check_time;
} system_monitor_t;

/* 参数监控统计 */
typedef struct {
    int borrow_threshold_hits;           /* 借用阈值命中次数 */
    int lend_threshold_hits;             /* 借出阈值命中次数 */
    int continuous_high_events;          /* 连续高使用率事件数 */
    int continuous_low_events;           /* 连续低使用率事件数 */
    int borrow_attempts;                 /* 借用尝试次数 */
    int borrow_successes;                /* 借用成功次数 */
    int borrow_failures;                 /* 借用失败次数 */
    int lend_attempts;                   /* 借出尝试次数 */
    int lend_successes;                  /* 借出成功次数 */
    int lend_failures;                   /* 借出失败次数 */
    int return_attempts;                 /* 归还尝试次数 */
    int return_successes;                /* 归还成功次数 */
    int return_failures;                 /* 归还失败次数 */
    int receive_return_attempts;         /* 接收归还尝试次数 */
    int receive_return_successes;        /* 接收归还成功次数 */
    int receive_return_failures;         /* 接收归还失败次数 */
    int total_borrowed_kbps;             /* 总借用带宽 */
    int total_lent_kbps;                 /* 总借出带宽 */
    int total_returned_kbps;             /* 总归还带宽 */
    int total_received_kbps;             /* 总接收带宽 */
    float borrow_success_rate;           /* 借用成功率 */
    float lend_success_rate;             /* 借出成功率 */
    float return_success_rate;           /* 归还成功率 */
    float avg_borrow_amount;             /* 平均借用量 */
    float avg_borrow_duration;           /* 平均借用时长 */
    int64_t total_borrow_duration;       /* 总借用时长 */
    int64_t last_update_time;            /* 最后更新时间 */
} param_monitor_t;

/* 借用源评分信息 */
typedef struct {
    int lender_index;        /* 借出方索引 */
    int available_bw;        /* 可用带宽 */
    int safe_lend_amount;    /* 安全借出量 */
    float impact_score;      /* 影响评分（越低越好） */
    int priority_gap;        /* 优先级差距 */
} lender_score_t;

/* 设备上下文 */
typedef struct device_context {
    char device[MAX_DEVICE_NAME_LEN + 1];
    int total_bandwidth_kbps;
    char qdisc_kind[MAX_QDISC_KIND_LEN];
    struct rtnl_handle rth;
    
    class_config_t configs[MAX_CLASSES];
    class_state_t states[MAX_CLASSES];
    borrow_record_t records[MAX_BORROW_RECORDS];
    
    int num_classes;
    int num_records;
    tc_cache_t tc_cache;
    async_monitor_t async_monitor;
    batch_commands_t batch_cmds;
    
    /* 配置参数 */
    int high_util_threshold;
    int high_util_duration;
    int low_util_threshold;
    int low_util_duration;
    float borrow_ratio;
    int min_borrow_kbps;
    int min_change_kbps;
    int cooldown_time;
    int auto_return_enable;
    int return_threshold;
    float return_speed;
    priority_policy_t priority_policy;
    
    /* 新优化参数 */
    int borrow_trigger_threshold;      /* 借用触发阈值 */
    int lend_trigger_threshold;        /* 借出触发阈值 */
    int continuous_seconds;            /* 连续时间窗口 */
    float max_borrow_ratio;            /* 最大借用比例 */
    int min_priority_gap;              /* 最小优先级间隔 */
    float keep_for_self_ratio;         /* 为自己保留比例 */
    float max_lend_ratio;              /* 最大借出比例 */
    
    /* 多源借用参数 */
    int enable_multi_source_borrow;    /* 启用多源借用 */
    int max_borrow_sources;            /* 最多借用源数量 */
    int load_balance_mode;             /* 负载均衡模式 */
    
    /* 紧急保护参数 */
    int starvation_warning;            /* 饿死警戒线 */
    int starvation_critical;           /* 饿死紧急线 */
    float emergency_return_ratio;      /* 紧急归还比例 */
    int high_priority_protect_level;   /* 高优先级保护线 */
    
    int64_t last_check_time;
    int total_borrow_events;
    int total_return_events;
    int64_t total_borrowed_kbps;
    int64_t total_returned_kbps;
    
    perf_stats_t perf_stats;
    system_monitor_t system_monitor;
    
    /* 滑动窗口数据 */
    utilization_window_t* util_windows;  /* 使用率窗口数组 */
    
    /* 使用率监控器 */
    struct {
        float utilization_history[HISTORY_SECONDS];  /* 5分钟历史数据 */
        int64_t history_timestamps[HISTORY_SECONDS]; /* 时间戳 */
        int history_index;                           /* 当前索引 */
        int history_count;                           /* 有效样本数 */
        float peak_utilization_1min;                /* 1分钟峰值使用率 */
        float peak_utilization_5min;                /* 5分钟峰值使用率 */
        float avg_utilization_1min;                 /* 1分钟平均使用率 */
        float avg_utilization_5min;                 /* 5分钟平均使用率 */
        int high_util_alerts;                       /* 高使用率告警次数 */
        int low_util_alerts;                        /* 低使用率告警次数 */
        int64_t last_alert_time;                    /* 上次告警时间 */
    } *util_monitors;
    
    /* 参数监控器 */
    param_monitor_t* param_monitors;
    
    int enabled;
    int emergency_stop;  /* 紧急停止标志 */
    struct qosdba_context* owner_ctx;
} device_context_t;

/* 信号队列 */
typedef struct {
    volatile sig_atomic_t signals[10];
    volatile int signal_count;
    volatile int signal_read_index;
    volatile int signal_write_index;
    pthread_mutex_t signal_mutex;
    pthread_cond_t signal_cond;
} signal_queue_t;

/* 性能事件 */
typedef struct {
    int classid;
    int priority;
    float performance_level;
    int64_t timestamp;
} performance_event_t;

/* QoS上下文 */
typedef struct qosdba_context {
    int enabled;
    int debug_mode;
    int safe_mode;
    int reload_config;
    int log_level;
    
    device_context_t devices[MAX_DEVICES];
    int num_devices;
    int check_interval;
    
    int64_t start_time;
    int64_t config_mtime;
    int64_t last_check_time;
    
    char config_path[MAX_PATH_LEN + 1];
    FILE* status_file;
    FILE* log_file;
    
    struct rtnl_handle shared_rth;
    int shared_rth_refcount;
    pthread_mutex_t rth_mutex;
    pthread_spinlock_t ctx_lock;
    
    atomic_int should_exit;
    atomic_int reload_requested;
    
    device_context_t* new_devices;
    int new_num_devices;
    
    signal_queue_t signal_queue;
    system_monitor_t system_monitor;
    
    /* 性能事件记录 */
    performance_event_t perf_events[100];
    int perf_event_count;
    
    /* 参数覆盖 */
    int override_borrow_thresh;
    int override_lend_thresh;
    
    int test_mode;
} qosdba_context_t;

/* ==================== 函数声明 ==================== */

/* 初始化/清理 */
qosdba_result_t qosdba_init(qosdba_context_t* ctx);
qosdba_result_t qosdba_cleanup(qosdba_context_t* ctx);
qosdba_result_t qosdba_run(qosdba_context_t* ctx);

/* 配置管理 */
qosdba_result_t load_config_file(qosdba_context_t* ctx, const char* config_file);
qosdba_result_t reload_config(qosdba_context_t* ctx, const char* config_file);
qosdba_result_t reload_config_atomic(qosdba_context_t* ctx, const char* config_file);
qosdba_result_t qosdba_update_status(qosdba_context_t* ctx, const char* status_file);
int validate_config_parameters(device_context_t* dev_ctx);
int check_config_reload(qosdba_context_t* ctx, const char* config_file);
qosdba_result_t parse_config_line(const char* line, int line_number, 
                                 int* classid, char* name, size_t name_size,
                                 int* priority, int* total_bw_kbps, 
                                 int* min_bw_kbps, int* max_bw_kbps, 
                                 int* dba_enabled);
int parse_key_value(const char* line, char* key, int key_len, 
                   char* value, int value_len);

/* 设备管理 */
qosdba_result_t discover_tc_classes(device_context_t* dev_ctx);
qosdba_result_t init_tc_classes(device_context_t* dev_ctx, qosdba_context_t* ctx);
qosdba_result_t process_device_cycle(device_context_t* dev_ctx, qosdba_context_t* ctx);
int get_ifindex(device_context_t* dev_ctx);

/* 带宽监控 */
qosdba_result_t check_bandwidth_usage(device_context_t* dev_ctx);
void run_borrow_logic(device_context_t* dev_ctx, qosdba_context_t* ctx);
void run_return_logic(device_context_t* dev_ctx, qosdba_context_t* ctx);

/* 优化借用逻辑 */
qosdba_result_t run_borrow_logic_optimized(device_context_t* dev_ctx, 
                                          qosdba_context_t* ctx);
qosdba_result_t execute_single_borrow(device_context_t* dev_ctx,
                                     qosdba_context_t* ctx,
                                     int lender_idx,
                                     int borrower_idx,
                                     int borrow_amount);
int calculate_safe_lend_amount(class_state_t* lender, 
                              class_config_t* config,
                              device_context_t* dev_ctx);
int calculate_real_bandwidth_needed(class_state_t* borrower, 
                                   device_context_t* dev_ctx);
float calculate_lender_score(class_state_t* lender, 
                            class_config_t* config,
                            device_context_t* dev_ctx);
int find_available_lenders(device_context_t* dev_ctx, 
                          int borrower_idx,
                          int needed_bw_kbps,
                          lender_score_t* lenders, 
                          int max_lenders);
int find_class_by_id(device_context_t* dev_ctx, int classid);

/* 保护机制 */
void monitor_starvation_risk(device_context_t* dev_ctx, qosdba_context_t* ctx);
void protect_high_priority_classes(device_context_t* dev_ctx, qosdba_context_t* ctx);
void emergency_return_for_starvation(device_context_t* dev_ctx, 
                                    qosdba_context_t* ctx, 
                                    int lender_idx);
float calculate_starvation_risk(class_state_t* lender, 
                               device_context_t* dev_ctx);
void emergency_reclaim_bandwidth(device_context_t* dev_ctx,
                                qosdba_context_t* ctx,
                                int high_priority_idx);
void run_single_return(device_context_t* dev_ctx, qosdba_context_t* ctx,
                      borrow_record_t* record, 
                      int borrower_idx, int lender_idx,
                      int return_amount);

/* 连续使用率监控 */
qosdba_result_t monitor_continuous_utilization(device_context_t* dev_ctx);
void update_utilization_window(utilization_window_t* window, 
                              float utilization, 
                              int64_t timestamp);
float get_5s_average_utilization(utilization_window_t* window, 
                                int64_t current_time);
int is_continuously_high(utilization_window_t* window, 
                        int threshold, 
                        int64_t current_time);
int is_continuously_low(utilization_window_t* window, 
                       int threshold, 
                       int64_t current_time);
void init_utilization_window(utilization_window_t* window);

/* 优化参数监控 */
qosdba_result_t monitor_optimization_parameters(device_context_t* dev_ctx);
void record_borrow_event(device_context_t* dev_ctx, 
                         int borrower_idx, 
                         int lender_idx, 
                         int amount_kbps, 
                         int success);
void record_return_event(device_context_t* dev_ctx, 
                         int borrower_idx, 
                         int lender_idx, 
                         int amount_kbps, 
                         int success);
qosdba_result_t get_class_utilization_stats(device_context_t* dev_ctx, 
                                           int class_idx,
                                           float* avg_1min, 
                                           float* peak_1min,
                                           float* avg_5min, 
                                           float* peak_5min);

/* TC操作 */
qosdba_result_t adjust_class_bandwidth(device_context_t* dev_ctx, 
                                      qosdba_context_t* ctx,
                                      int classid, int new_bw_kbps);
qosdba_result_t open_device_netlink(device_context_t* dev_ctx, qosdba_context_t* ctx);
void close_device_netlink(device_context_t* dev_ctx, qosdba_context_t* ctx);

/* 批量命令 */
void init_batch_commands(batch_commands_t* batch, int initial_capacity);
void cleanup_batch_commands(batch_commands_t* batch);
qosdba_result_t execute_batch_commands(batch_commands_t* batch, 
                                      device_context_t* dev_ctx, 
                                      qosdba_context_t* ctx);

/* 缓存管理 */
qosdba_result_t update_tc_cache(device_context_t* dev_ctx);
void adjust_cache_interval(device_context_t* dev_ctx);

/* 异步监控 */
qosdba_result_t init_async_monitor(device_context_t* dev_ctx);
int check_async_events(device_context_t* dev_ctx);
qosdba_result_t setup_async_monitoring(device_context_t* dev_ctx);

/* 系统资源监控 */
qosdba_result_t check_system_resources(device_context_t* dev_ctx);
void update_perf_stats(device_context_t* dev_ctx, const char* operation, 
                      int64_t start_time, int64_t end_time, int success);
void print_perf_stats(device_context_t* dev_ctx, FILE* out);

/* 信号处理 */
qosdba_result_t signal_queue_init(signal_queue_t* queue);
void signal_queue_cleanup(signal_queue_t* queue);
qosdba_result_t signal_queue_enqueue(signal_queue_t* queue, int sig);
int signal_queue_dequeue(signal_queue_t* queue);
qosdba_result_t setup_signals(qosdba_context_t* ctx);
void* signal_thread_func(void* arg);
void handle_dynamic_parameter_change(qosdba_context_t* ctx);

/* 日志系统 */
void log_message(qosdba_context_t* ctx, const char* level, 
                const char* format, ...);
void log_device_message(device_context_t* dev_ctx, const char* level,
                       const char* format, ...);
int parse_log_level(const char* level_str);

/* 工具函数 */
int64_t get_current_time_ms(void);
int get_file_mtime(const char* filename);
int is_valid_device_name(const char* name);
void trim_whitespace(char* str);
const char* get_current_timestamp(void);
int min(int a, int b);
int max(int a, int b);
float minf(float a, float b);
float maxf(float a, float b);

/* 设置函数 */
void qosdba_set_debug(qosdba_context_t* ctx, int enable);
void qosdba_set_safe_mode(qosdba_context_t* ctx, int enable);
void qosdba_set_test_mode(qosdba_context_t* ctx, int enable);

/* 健康检查 */
qosdba_result_t qosdba_health_check(qosdba_context_t* ctx);

/* 借用记录管理 */
void add_borrow_record(device_context_t* dev_ctx, int from_classid, 
                      int to_classid, int borrowed_bw_kbps);

/* 测试 */
qosdba_result_t qosdba_run_tests(qosdba_context_t* ctx);
void test_optimized_borrow_logic(void);
void test_cleanup(qosdba_context_t* ctx);
void generate_test_report(qosdba_context_t* ctx, const char* report_file);

/* TC专用操作 */
qosdba_result_t adjust_class_bandwidth_openwrt(device_context_t* dev_ctx, 
                                              qosdba_context_t* ctx,
                                              int classid, int new_bw_kbps);
qosdba_result_t get_tc_stats_openwrt(const char* device, int classid, 
                                    uint64_t* bytes, uint64_t* packets);

/* 批量命令适配器 */
void init_batch_commands_openwrt(batch_commands_t* batch, int initial_capacity);
void cleanup_batch_commands_openwrt(batch_commands_t* batch);
qosdba_result_t execute_batch_commands_openwrt(batch_commands_t* batch, 
                                              device_context_t* dev_ctx, 
                                              qosdba_context_t* ctx);

#endif /* QOSDBA_H */