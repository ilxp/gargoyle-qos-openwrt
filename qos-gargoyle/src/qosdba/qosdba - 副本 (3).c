/*
 * qosdba.c - QoS动态带宽分配器
 * 功能：监控各QoS分类的带宽使用率，实现分类间的动态带宽借用和归还
 * 支持同时监控下载(ifb0)和上传(pppoe-wan)两个设备
 * 统一配置文件：/etc/qosdba.conf
 * 版本：2.0.0（DBA 2.0 - 支持HTB和HFSC）
 * 新特性：
 * 1. 完整的HTB和HFSC支持
 * 2. 自动算法检测和适配
 * 3. 完整的HFSC三个服务曲线调整
 * 4. 算法抽象层，支持扩展
 * 优化特性：
 * 1. 修复内存对齐问题
 * 2. 改进信号处理中的竞态条件
 * 3. 增强配置文件解析健壮性
 * 4. 修复浮点数比较精度问题
 * 5. 增强TC操作错误处理
 * 6. 新增配置文件验证和错误恢复
 * 7. 改进字符串操作安全性
 * 8. 增强多线程安全性
 * 修改记录：
 *   - 修复1: 内存对齐问题
 *   - 修复2: 信号处理竞态条件
 *   - 修复3: 配置文件解析
 *   - 修复4: 浮点数比较精度
 *   - 修复5: TC操作错误处理
 *   - 增强1: 配置文件验证
 *   - 增强2: 字符串操作安全
 *   - 增强3: 多线程安全
 *   - 新增1: 完整的HFSC支持
 *   - 新增2: 自动算法检测
 *   - 新增3: 算法抽象层
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
#include <float.h>
#include <stdarg.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <dirent.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/epoll.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <pthread.h>
#include <stdbool.h>

/* ==================== libnetlink (TC库) 头文件 ==================== */
#include <libnetlink.h>
#include <rtnetlink.h>
#include <linux/pkt_sched.h>
#include <linux/if_link.h>

/* ==================== 宏定义 ==================== */
#define QOSDBA_VERSION "2.0.0"
#define MAX_CLASSES 32
#define MAX_BORROW_RECORDS 64
#define MAX_CONFIG_LINE 512
#define MAX_QDISC_KIND_LEN 16
#define DEFAULT_CHECK_INTERVAL 1
#define DEFAULT_HIGH_UTIL_THRESHOLD 85
#define DEFAULT_HIGH_UTIL_DURATION 5
#define DEFAULT_LOW_UTIL_THRESHOLD 40
#define DEFAULT_LOW_UTIL_DURATION 5
#define DEFAULT_BORROW_RATIO 0.2f
#define DEFAULT_MIN_BORROW_KBPS 128
#define DEFAULT_MIN_CHANGE_KBPS 128
#define DEFAULT_COOLDOWN_TIME 8
#define DEFAULT_RETURN_THRESHOLD 50
#define DEFAULT_RETURN_SPEED 0.1f
#define MAX_CMD_OUTPUT 4096
#define MAX_DEVICES 2
#define MAX_CMD_TIMEOUT_MS 5000
#define BATCH_COMMAND_INITIAL_CAPACITY 10
#define BATCH_COMMAND_MAX_CAPACITY 50
#define CACHE_MIN_INTERVAL_MS 1000
#define CACHE_MAX_INTERVAL_MS 30000
#define MAX_RETRY_ATTEMPTS 3
#define RETRY_BASE_DELAY_MS 100
#define MAX_CROSS_CLASS_INTERACTIONS 1000
#define MAX_NETWORK_LATENCY_MS 1000
#define MAX_SYSTEM_MEMORY_USAGE_MB 100
#define MAX_CPU_USAGE_PERCENT 90
#define MAX_SYSTEM_CALLS_PER_SEC 10000
#define MAX_HEALTH_CHECK_INTERVAL_MS 30000
#define MIN_HEALTH_CHECK_INTERVAL_MS 1000
#define MAX_STRING_OPERATIONS_PER_CYCLE 100
#define MEMORY_POOL_BLOCK_SIZE 64
#define MAX_MEMORY_POOL_BLOCKS 1000
#define MAX_CONFIG_RANGE_CHECKS 100
#define MAX_ARRAY_BOUNDARY_CHECKS 1000
#define MAX_RESOURCE_COMPETITION_CHECKS 100
#define MAX_MAGIC_NUMBERS 100
#define MAX_HEALTH_CHECKS 10
#define FLOAT_EPSILON 0.000001f
#define MAX_CLASS_NAME_LENGTH 63
#define MAX_CONFIG_KEY_LENGTH 63
#define MAX_CONFIG_VALUE_LENGTH 127
#define MAX_LOG_MESSAGE_LENGTH 2047
#define MAX_TIMESTAMP_LENGTH 31
#define MAX_PATH_LENGTH 255
#define MAX_INOTIFY_BUFFER_SIZE 4096
#define MAX_EPOLL_EVENTS 10
#define MAX_ERROR_DETAIL_LENGTH 511
#define MAX_RETRY_DELAY_MS 5000
#define MIN_RETRY_DELAY_MS 10
#define MAX_SIGNAL_QUEUE_SIZE 10
#define MAX_CONFIG_VALIDATION_ERRORS 20
#define MAX_STRING_BUFFER_SIZE 4096
#define MAX_TOKEN_BUFFER_SIZE 128
#define MAX_FIELD_COUNT 20
#define MAX_LINE_VALIDATION_ATTEMPTS 3
#define MAX_CONFIG_BACKUP_COPIES 5
#define DEFAULT_CONFIG_PERMISSIONS 0644
#define MAX_FILE_DESCRIPTORS 1024
#define MAX_THREAD_NAME_LENGTH 15
#define MIN_PRIORITY_GAP 1
#define MAX_PRIORITY_GAP 10
#define MIN_BORROW_RATIO 0.01f
#define MAX_BORROW_RATIO 1.0f
#define MIN_RETURN_SPEED 0.01f
#define MAX_RETURN_SPEED 1.0f
#define DEFAULT_STRING_BUFFER_SIZE 256
#define DEFAULT_ERROR_BUFFER_SIZE 512
#define MAX_NETWORK_INTERFACE_NAME_LENGTH IFNAMSIZ
#define DEFAULT_TCPORT 0
#define MAX_TC_ERROR_MESSAGES 20
#define TC_ERROR_MESSAGE_SIZE 128
#define MAX_CONFIG_SECTION_NAME_LENGTH 127
#define MAX_DEVICE_NAME_LENGTH 15
#define MAX_CLASS_DESCRIPTION_LENGTH 127
#define MAX_CONFIG_HISTORY_ENTRIES 100
#define MAX_CONFIG_ROLLBACK_ATTEMPTS 3
#define MAX_CONFIG_SYNTAX_ERRORS 10
#define MAX_CONFIG_SEMANTIC_ERRORS 10
#define MAX_CONFIG_WARNINGS 20
#define DEFAULT_ALIGNMENT 16
#define MIN_ALIGNMENT_SIZE 4
#define MAX_ALIGNMENT_SIZE 64
#define ALIGNMENT_MASK (DEFAULT_ALIGNMENT - 1)
#define IS_ALIGNED(ptr) (((uintptr_t)(ptr) & ALIGNMENT_MASK) == 0)
#define ALIGN_UP(ptr, alignment) \
    (((uintptr_t)(ptr) + ((alignment) - 1)) & ~((uintptr_t)((alignment) - 1)))
#define ALIGN_DOWN(ptr, alignment) \
    ((uintptr_t)(ptr) & ~((uintptr_t)((alignment) - 1)))

/* ==================== 算法类型定义 ==================== */
#define ALGORITHM_UNKNOWN 0
#define ALGORITHM_HTB 1
#define ALGORITHM_HFSC 2
#define ALGORITHM_CAKE 3

/* ==================== 调试宏定义 ==================== */
#ifdef QOSDBA_DEBUG_MEMORY
#define DEBUG_MEMORY_ENABLED 1
#else
#define DEBUG_MEMORY_ENABLED 0
#endif

#ifdef QOSDBA_TEST
#define TEST_MODE_ENABLED 1
#else
#define TEST_MODE_ENABLED 0
#endif

#ifdef QOSDBA_PROFILE
#define PROFILE_ENABLED 1
#else
#define PROFILE_ENABLED 0
#endif

/* ==================== 对齐内存分配宏 ==================== */
#ifdef __GNUC__
#define ALIGNED_BUFFER(size, alignment) \
    char buffer[size] __attribute__((aligned(alignment)))
#else
#define ALIGNED_BUFFER(size, alignment) \
    union { \
        char buffer[size]; \
        max_align_t align; \
    } buffer_union; \
    char* buffer = buffer_union.buffer; \
    (void)0
#endif

/* ==================== 平台特定宏 ==================== */
#ifdef __GNUC__
#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)
#define ALWAYS_INLINE __attribute__((always_inline))
#define NOINLINE __attribute__((noinline))
#define PACKED __attribute__((packed))
#else
#define LIKELY(x) (x)
#define UNLIKELY(x) (x)
#define ALWAYS_INLINE
#define NOINLINE
#define PACKED
#endif

/* ==================== 编译器警告抑制 ==================== */
#ifdef __GNUC__
#define DIAGNOSTIC_PUSH _Pragma("GCC diagnostic push")
#define DIAGNOSTIC_POP _Pragma("GCC diagnostic pop")
#define DIAGNOSTIC_IGNORE_WCAST_ALIGN _Pragma("GCC diagnostic ignored \"-Wcast-align\"")
#define DIAGNOSTIC_IGNORE_WUNUSED_PARAMETER _Pragma("GCC diagnostic ignored \"-Wunused-parameter\"")
#define DIAGNOSTIC_IGNORE_WSIGN_COMPARE _Pragma("GCC diagnostic ignored \"-Wsign-compare\"")
#define DIAGNOSTIC_IGNORE_WIMPLICIT_FALLTHROUGH _Pragma("GCC diagnostic ignored \"-Wimplicit-fallthrough\"")
#else
#define DIAGNOSTIC_PUSH
#define DIAGNOSTIC_POP
#define DIAGNOSTIC_IGNORE_WCAST_ALIGN
#define DIAGNOSTIC_IGNORE_WUNUSED_PARAMETER
#define DIAGNOSTIC_IGNORE_WSIGN_COMPARE
#define DIAGNOSTIC_IGNORE_WIMPLICIT_FALLTHROUGH
#endif

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
    QOSDBA_ERR_TIMEOUT = -8,
    QOSDBA_ERR_PERFORMANCE = -9,
    QOSDBA_ERR_SECURITY = -10,
    QOSDBA_ERR_MAINTENANCE = -11,
    QOSDBA_ERR_ALIGNMENT = -12,
    QOSDBA_ERR_SIGNAL = -13,
    QOSDBA_ERR_PARSING = -14,
    QOSDBA_ERR_FLOAT = -15,
    QOSDBA_ERR_THREAD = -16,
    QOSDBA_ERR_SANITY = -17
} qosdba_result_t;

/* ==================== TC错误码映射 ==================== */
typedef struct {
    int tc_error;
    const char* description;
    qosdba_result_t qosdba_error;
    bool is_fatal;
} tc_error_mapping_t;

static const tc_error_mapping_t TC_ERROR_MAPPINGS[] = {
    {-ENOENT, "TC分类不存在", QOSDBA_ERR_TC, false},
    {-EINVAL, "TC参数无效", QOSDBA_ERR_TC, false},
    {-ENODEV, "网络设备不存在", QOSDBA_ERR_NETWORK, true},
    {-ENETDOWN, "网络设备已关闭", QOSDBA_ERR_NETWORK, true},
    {-EEXIST, "TC分类已存在", QOSDBA_ERR_TC, false},
    {-EOPNOTSUPP, "操作不支持", QOSDBA_ERR_TC, true},
    {-ENOMEM, "内存不足", QOSDBA_ERR_MEMORY, true},
    {-EACCES, "权限不足", QOSDBA_ERR_SYSTEM, true},
    {-EFAULT, "无效地址", QOSDBA_ERR_SYSTEM, true},
    {-EBUSY, "资源忙", QOSDBA_ERR_SYSTEM, false},
    {-EAGAIN, "资源暂时不可用", QOSDBA_ERR_SYSTEM, false},
    {-EWOULDBLOCK, "操作将被阻塞", QOSDBA_ERR_SYSTEM, false},
    {-ENOSPC, "设备空间不足", QOSDBA_ERR_SYSTEM, false},
    {-EPERM, "操作不被允许", QOSDBA_ERR_SYSTEM, true},
    {-ENOTSUP, "不支持的操作", QOSDBA_ERR_TC, true},
    {0, NULL, QOSDBA_OK, false}
};

/* ==================== 算法抽象层 ==================== */

/* 算法操作接口定义 */
typedef struct {
    const char* name;
    int algorithm_type;
    qosdba_result_t (*init_class)(device_context_t* dev_ctx, 
                                  class_config_t* config,
                                  class_state_t* state,
                                  int ifindex);
    qosdba_result_t (*adjust_bandwidth)(device_context_t* dev_ctx,
                                       int classid,
                                       int new_bw_kbps);
    qosdba_result_t (*borrow_bandwidth)(device_context_t* dev_ctx,
                                       int from_classid,
                                       int to_classid,
                                       int borrow_amount);
    qosdba_result_t (*return_bandwidth)(device_context_t* dev_ctx,
                                       int from_classid,
                                       int to_classid,
                                       int return_amount);
    int (*get_current_bandwidth)(device_context_t* dev_ctx,
                                int classid);
} qos_algorithm_ops_t;

/* 算法检测结果 */
typedef struct {
    char qdisc_kind[MAX_QDISC_KIND_LEN + 1];
    int algorithm_type;  /* 0=未知, 1=HTB, 2=HFSC, 3=CAKE */
    int detected_classes;  /* 检测到的分类数量 */
} algorithm_detection_t;

/* 信号处理结构 */
typedef struct {
    volatile sig_atomic_t signals[MAX_SIGNAL_QUEUE_SIZE];
    volatile int signal_count;
    volatile int signal_read_index;
    volatile int signal_write_index;
    pthread_mutex_t signal_mutex;
    pthread_cond_t signal_cond;
} signal_queue_t;

/* 对齐内存块结构 */
typedef struct aligned_memory_block {
    void* aligned_ptr;
    void* original_ptr;
    size_t size;
    size_t alignment;
    struct aligned_memory_block* next;
} aligned_memory_block_t;

/* 对齐内存管理器 */
typedef struct {
    aligned_memory_block_t* blocks;
    int block_count;
    pthread_mutex_t lock;
} aligned_memory_manager_t;

/* 浮点数比较容差结构 */
typedef struct {
    float epsilon;
    float min_epsilon;
    float max_epsilon;
    float relative_tolerance;
    float absolute_tolerance;
} float_tolerance_t;

/* 配置文件验证结果 */
typedef struct {
    int line_number;
    int error_code;
    char error_message[MAX_ERROR_DETAIL_LENGTH];
    char line_content[MAX_CONFIG_LINE];
} config_validation_error_t;

typedef struct {
    config_validation_error_t errors[MAX_CONFIG_VALIDATION_ERRORS];
    int error_count;
    int warning_count;
    int total_lines;
    int valid_lines;
} config_validation_result_t;

/* 解析器状态 */
typedef struct {
    char* input;
    char* current;
    char* end;
    int line_number;
    int column;
    bool in_quotes;
    bool escaped;
    char delimiter;
    char quote_char;
} parser_state_t;

/* 字符串处理上下文 */
typedef struct {
    char* buffer;
    size_t capacity;
    size_t length;
    size_t position;
    bool dynamic;
} string_buffer_t;

/* 内存池块结构 */
typedef struct memory_pool_block {
    void* data;
    size_t size;
    int used;
    struct memory_pool_block* next;
} memory_pool_block_t;

/* 内存池结构 */
typedef struct {
    memory_pool_block_t* blocks;
    int block_count;
    int max_blocks;
    size_t block_size;
    pthread_mutex_t lock;
} memory_pool_t;

/* 扩展性能监控结构 */
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
    int64_t total_network_bytes;
    int64_t total_system_calls;
    int io_errors;
    int64_t total_processing_time_ms;
    int64_t check_usage_time_ms;
    int64_t borrow_logic_time_ms;
    int64_t return_logic_time_ms;
    int64_t batch_execute_time_ms;
    int64_t cache_update_time_ms;
    int64_t retry_attempts;
    int64_t retry_success;
    int64_t retry_failures;
    int64_t string_operations;
    int64_t boundary_checks;
    int64_t cross_class_interactions;
    int64_t successful_borrows;
    int64_t failed_borrows;
    int64_t successful_returns;
    int64_t failed_returns;
    float avg_network_latency_ms;
    float max_network_latency_ms;
    int64_t network_timeouts;
    float avg_cpu_usage;
    float avg_memory_usage_mb;
    int system_calls_per_sec;
    int64_t resource_competition_checks;
    int64_t magic_number_checks;
    int64_t health_checks;
    int64_t alignment_checks;
    int64_t signal_checks;
    int64_t parsing_operations;
    int64_t float_comparisons;
    int64_t tc_error_handlings;
    int64_t htb_adjustments;
    int64_t hfsc_adjustments;
    float hfsc_latency_ms;
    int64_t hfsc_curve_updates;
} perf_stats_t;

/* 分类带宽配置 */
typedef struct {
    int classid;
    char name[MAX_CLASS_NAME_LENGTH + 1];
    int priority;
    int total_bw_kbps;
    int min_bw_kbps;
    int max_bw_kbps;
    int dba_enabled;  // 是否启用DBA动态调整
} class_config_t;

/* 分类状态结构 */
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
    int dba_enabled;  // 是否启用DBA动态调整
} class_state_t;

/* 优先级管理策略 */
typedef struct {
    int max_borrow_from_higher_priority;
    int allow_same_priority_borrow;
    int max_borrow_percentage;
    int min_lender_priority_gap;
} priority_policy_t;

/* 借用记录结构 */
typedef struct {
    int from_classid;
    int to_classid;
    int borrowed_bw_kbps;
    int64_t start_time;
    int returned;
} borrow_record_t;

/* 自适应TC统计缓存结构 */
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

/* 自适应批量命令结构 */
typedef struct {
    struct rtnl_class** classes;
    int command_count;
    int capacity;
    int max_commands;
    float avg_batch_size;
    int64_t last_adjust_time;
    int adjustment_count;
    int adaptive_enabled;
    memory_pool_t* pool;
} batch_commands_t;

/* 异步监控上下文 */
typedef struct {
    int epoll_fd;
    int inotify_fd;
    int watch_fd;
    int async_enabled;
    int64_t last_async_check;
} async_monitor_t;

/* 设备上下文结构 */
typedef struct {
    char device[MAX_DEVICE_NAME_LENGTH + 1];
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
    int64_t last_check_time;
    int total_borrow_events;
    int total_return_events;
    int64_t total_borrowed_kbps;
    int64_t total_returned_kbps;
    perf_stats_t perf_stats;
    int enabled;
    struct qosdba_context_t* owner_ctx;
} device_context_t;

/* QoS上下文结构 */
typedef struct {
    int enabled;
    int debug_mode;
    int safe_mode;
    int reload_config;
    device_context_t devices[MAX_DEVICES];
    int num_devices;
    int check_interval;
    int64_t start_time;
    int64_t config_mtime;
    int64_t last_check_time;
    FILE* status_file;
    FILE* log_file;
    char config_path[MAX_PATH_LENGTH + 1];
    struct rtnl_handle shared_rth;
    int shared_rth_refcount;
    pthread_mutex_t rth_mutex;
    pthread_spinlock_t ctx_lock;
    atomic_int should_exit;
    atomic_int reload_requested;
#ifdef DEBUG_MEMORY_ENABLED
    int64_t total_memory_allocated;
    int nl_handles_allocated;
    int class_objects_allocated;
    int cache_objects_allocated;
#endif
    device_context_t* new_devices;
    int new_num_devices;
    signal_queue_t signal_queue;
    aligned_memory_manager_t aligned_memory;
    float_tolerance_t float_tolerance;
    config_validation_result_t config_validation;
    parser_state_t parser_state;
} qosdba_context_t;

/* 默认参数配置 */
typedef struct {
    int check_interval;
    int high_util_threshold;
    int low_util_threshold;
    float borrow_ratio;
    int min_borrow_kbps;
    int cooldown_time;
    int return_threshold;
    float return_speed;
} default_params_t;

static const default_params_t DEFAULT_PARAMS = {
    .check_interval = DEFAULT_CHECK_INTERVAL,
    .high_util_threshold = DEFAULT_HIGH_UTIL_THRESHOLD,
    .low_util_threshold = DEFAULT_LOW_UTIL_THRESHOLD,
    .borrow_ratio = DEFAULT_BORROW_RATIO,
    .min_borrow_kbps = DEFAULT_MIN_BORROW_KBPS,
    .cooldown_time = DEFAULT_COOLDOWN_TIME,
    .return_threshold = DEFAULT_RETURN_THRESHOLD,
    .return_speed = DEFAULT_RETURN_SPEED
};

/* 全局上下文 */
static atomic_int g_should_exit = 0;
static atomic_int g_reload_config = 0;
static pthread_spinlock_t g_ctx_lock;
static qosdba_context_t* g_ctx = NULL;

/* ==================== 函数声明 ==================== */
qosdba_result_t qosdba_init(qosdba_context_t* ctx);
qosdba_result_t qosdba_run(qosdba_context_t* ctx);
qosdba_result_t qosdba_cleanup(qosdba_context_t* ctx);
qosdba_result_t qosdba_update_status(qosdba_context_t* ctx, const char* status_file);
void qosdba_set_debug(qosdba_context_t* ctx, int enable);
void qosdba_set_safe_mode(qosdba_context_t* ctx, int enable);
qosdba_result_t qosdba_health_check(qosdba_context_t* ctx);

/* ==================== 算法检测函数 ==================== */
static int detect_algorithm(device_context_t* dev_ctx, algorithm_detection_t* detection);
static const qos_algorithm_ops_t* get_algorithm_ops(const char* qdisc_kind);
static const qos_algorithm_ops_t* get_algorithm_ops_by_type(int algorithm_type);

/* ==================== HFSC算法实现函数 ==================== */
static qosdba_result_t init_hfsc_class(device_context_t* dev_ctx,
                                     class_config_t* config,
                                     class_state_t* state,
                                     int ifindex);
static qosdba_result_t adjust_hfsc_bandwidth(device_context_t* dev_ctx,
                                           int classid,
                                           int new_bw_kbps);
static qosdba_result_t borrow_hfsc_bandwidth(device_context_t* dev_ctx,
                                           int from_classid,
                                           int to_classid,
                                           int borrow_amount);
static qosdba_result_t return_hfsc_bandwidth(device_context_t* dev_ctx,
                                           int from_classid,
                                           int to_classid,
                                           int return_amount);
static int get_hfsc_current_bandwidth(device_context_t* dev_ctx, int classid);
static void update_hfsc_perf_stats(device_context_t* dev_ctx, int classid, 
                                  int64_t operation_time, qosdba_result_t result);

/* ==================== HTB算法实现函数 ==================== */
static qosdba_result_t init_htb_class(device_context_t* dev_ctx,
                                    class_config_t* config,
                                    class_state_t* state,
                                    int ifindex);
static qosdba_result_t adjust_htb_bandwidth(device_context_t* dev_ctx,
                                          int classid,
                                          int new_bw_kbps);
static qosdba_result_t borrow_htb_bandwidth(device_context_t* dev_ctx,
                                          int from_classid,
                                          int to_classid,
                                          int borrow_amount);
static qosdba_result_t return_htb_bandwidth(device_context_t* dev_ctx,
                                          int from_classid,
                                          int to_classid,
                                          int return_amount);
static int get_htb_current_bandwidth(device_context_t* dev_ctx, int classid);

/* ==================== 算法操作表 ==================== */
static const qos_algorithm_ops_t htb_ops = {
    .name = "htb",
    .algorithm_type = ALGORITHM_HTB,
    .init_class = init_htb_class,
    .adjust_bandwidth = adjust_htb_bandwidth,
    .borrow_bandwidth = borrow_htb_bandwidth,
    .return_bandwidth = return_htb_bandwidth,
    .get_current_bandwidth = get_htb_current_bandwidth
};

static const qos_algorithm_ops_t hfsc_ops = {
    .name = "hfsc",
    .algorithm_type = ALGORITHM_HFSC,
    .init_class = init_hfsc_class,
    .adjust_bandwidth = adjust_hfsc_bandwidth,
    .borrow_bandwidth = borrow_hfsc_bandwidth,
    .return_bandwidth = return_hfsc_bandwidth,
    .get_current_bandwidth = get_hfsc_current_bandwidth
};

/* CAKE算法操作（占位符） */
static const qos_algorithm_ops_t cake_ops = {
    .name = "cake",
    .algorithm_type = ALGORITHM_CAKE,
    .init_class = NULL,
    .adjust_bandwidth = NULL,
    .borrow_bandwidth = NULL,
    .return_bandwidth = NULL,
    .get_current_bandwidth = NULL
};

/* ==================== 内部函数声明 ==================== */
static qosdba_result_t load_config_file(qosdba_context_t* ctx, const char* config_file);
static qosdba_result_t discover_tc_classes(device_context_t* dev_ctx);
static qosdba_result_t init_tc_classes(device_context_t* dev_ctx, qosdba_context_t* ctx);
static qosdba_result_t check_bandwidth_usage(device_context_t* dev_ctx);
static void run_borrow_logic(device_context_t* dev_ctx, qosdba_context_t* ctx);
static void run_return_logic(device_context_t* dev_ctx, qosdba_context_t* ctx);
static qosdba_result_t adjust_class_bandwidth(device_context_t* dev_ctx, 
                                             qosdba_context_t* ctx,
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
static void log_device_message(device_context_t* dev_ctx, const char* level,
                              const char* format, ...);
static int64_t get_current_time_ms(void);
static int get_file_mtime(const char* filename);
static int is_valid_device_name(const char* name);
static void trim_whitespace(char* str);
static int parse_key_value(const char* line, char* key, int key_len, char* value, int value_len);
static int validate_config_parameters(device_context_t* dev_ctx);
static int check_config_reload(qosdba_context_t* ctx, const char* config_file);
static qosdba_result_t reload_config(qosdba_context_t* ctx, const char* config_file);
static qosdba_result_t reload_config_atomic(qosdba_context_t* ctx, const char* config_file);

/* ==================== 优化函数声明 ==================== */
static qosdba_result_t update_tc_cache(device_context_t* dev_ctx);
static int parse_class_stats_from_cache(device_context_t* dev_ctx, int classid, uint64_t* bytes);
static void adjust_cache_interval(device_context_t* dev_ctx);
static void init_batch_commands(batch_commands_t* batch, int initial_capacity);
static void resize_batch_commands(batch_commands_t* batch, int new_capacity);
static void cleanup_batch_commands(batch_commands_t* batch);
static void adjust_batch_size(device_context_t* dev_ctx);
static void add_to_batch_commands(batch_commands_t* batch, struct rtnl_class* class);
static qosdba_result_t execute_batch_commands(batch_commands_t* batch, device_context_t* dev_ctx, qosdba_context_t* ctx);
static qosdba_result_t init_async_monitor(device_context_t* dev_ctx);
static int check_async_events(device_context_t* dev_ctx);

/* ==================== libnetlink辅助函数声明 ==================== */
static int nl_talk(struct rtnl_handle *rth, struct nlmsghdr *n);
static int qosdba_parse_class_attr(struct rtattr *tb[], int max, struct rtattr *rta, int len);
static int qosdba_parse_class_stats(struct rtnl_class *cls, uint64_t *bytes, uint64_t *packets);
static qosdba_result_t get_shared_netlink(qosdba_context_t* ctx, struct rtnl_handle** rth);
static void release_shared_netlink(qosdba_context_t* ctx);
static qosdba_result_t open_device_netlink(device_context_t* dev_ctx, qosdba_context_t* ctx);
static void close_device_netlink(device_context_t* dev_ctx, qosdba_context_t* ctx);
static int get_ifindex(device_context_t* dev_ctx);

/* ==================== 错误恢复和重试机制 ==================== */
typedef int (*nl_operation_func)(device_context_t* dev_ctx, void* arg);
static qosdba_result_t resilient_nl_operation(device_context_t* dev_ctx, 
                                              nl_operation_func func, 
                                              void* arg);
static qosdba_result_t retry_with_backoff(device_context_t* dev_ctx,
                                         nl_operation_func func,
                                         void* arg,
                                         int max_retries,
                                         int base_delay_ms);

/* ==================== 内存池管理函数 ==================== */
static memory_pool_t* create_memory_pool(size_t block_size, int max_blocks);
static void* allocate_from_pool(memory_pool_t* pool, size_t size);
static void free_pool_block(memory_pool_t* pool, void* ptr);
static void destroy_memory_pool(memory_pool_t* pool);
static void cleanup_memory_pools(device_context_t* dev_ctx);

/* ==================== 性能监控宏 ==================== */
#define NL_TIME_OPERATION_START(dev_ctx) \
    int64_t __start_time = (dev_ctx)->perf_stats.total_nl_operations > 0 ? get_current_time_ms() : 0

#define NL_TIME_OPERATION_END(dev_ctx, result) \
    do { \
        if ((dev_ctx)->perf_stats.total_nl_operations > 0) { \
            int64_t __elapsed = get_current_time_ms() - __start_time; \
            (dev_ctx)->perf_stats.total_nl_operations++; \
            (dev_ctx)->perf_stats.total_nl_time_ms += __elapsed; \
            if (__elapsed > (dev_ctx)->perf_stats.max_nl_time_ms) { \
                (dev_ctx)->perf_stats.max_nl_time_ms = __elapsed; \
            } \
            if ((result) < 0) (dev_ctx)->perf_stats.nl_errors++; \
        } \
    } while(0)

#define TIME_OPERATION_START(dev_ctx, field) \
    int64_t __start_##field = (dev_ctx)->perf_stats.field > 0 ? get_current_time_ms() : 0

#define TIME_OPERATION_END(dev_ctx, field) \
    do { \
        if ((dev_ctx)->perf_stats.field > 0) { \
            int64_t __elapsed_##field = get_current_time_ms() - __start_##field; \
            (dev_ctx)->perf_stats.field += __elapsed_##field; \
        } \
    } while(0)

#define STRING_OPERATION_START(dev_ctx) \
    do { \
        if ((dev_ctx)->perf_stats.string_operations < MAX_STRING_OPERATIONS_PER_CYCLE) { \
            (dev_ctx)->perf_stats.string_operations++; \
        } \
    } while(0)

#define BOUNDARY_CHECK_START(dev_ctx) \
    do { \
        if ((dev_ctx)->perf_stats.boundary_checks < MAX_ARRAY_BOUNDARY_CHECKS) { \
            (dev_ctx)->perf_stats.boundary_checks++; \
        } \
    } while(0)

#define RESOURCE_COMPETITION_CHECK_START(dev_ctx) \
    do { \
        if ((dev_ctx)->perf_stats.resource_competition_checks < MAX_RESOURCE_COMPETITION_CHECKS) { \
            (dev_ctx)->perf_stats.resource_competition_checks++; \
        } \
    } while(0)

#define MAGIC_NUMBER_CHECK_START(dev_ctx) \
    do { \
        if ((dev_ctx)->perf_stats.magic_number_checks < MAX_MAGIC_NUMBERS) { \
            (dev_ctx)->perf_stats.magic_number_checks++; \
        } \
    } while(0)

#define HEALTH_CHECK_START(dev_ctx) \
    do { \
        if ((dev_ctx)->perf_stats.health_checks < MAX_HEALTH_CHECKS) { \
            (dev_ctx)->perf_stats.health_checks++; \
        } \
    } while(0)

#define ALIGNMENT_CHECK_START(dev_ctx) \
    do { \
        if ((dev_ctx)->perf_stats.alignment_checks < MAX_ARRAY_BOUNDARY_CHECKS) { \
            (dev_ctx)->perf_stats.alignment_checks++; \
        } \
    } while(0)

#define SIGNAL_CHECK_START(dev_ctx) \
    do { \
        if ((dev_ctx)->perf_stats.signal_checks < MAX_HEALTH_CHECKS) { \
            (dev_ctx)->perf_stats.signal_checks++; \
        } \
    } while(0)

#define PARSING_OPERATION_START(dev_ctx) \
    do { \
        if ((dev_ctx)->perf_stats.parsing_operations < MAX_STRING_OPERATIONS_PER_CYCLE) { \
            (dev_ctx)->perf_stats.parsing_operations++; \
        } \
    } while(0)

#define FLOAT_COMPARISON_START(dev_ctx) \
    do { \
        if ((dev_ctx)->perf_stats.float_comparisons < MAX_STRING_OPERATIONS_PER_CYCLE) { \
            (dev_ctx)->perf_stats.float_comparisons++; \
        } \
    } while(0)

#define TC_ERROR_HANDLING_START(dev_ctx) \
    do { \
        if ((dev_ctx)->perf_stats.tc_error_handlings < MAX_TC_ERROR_MESSAGES) { \
            (dev_ctx)->perf_stats.tc_error_handlings++; \
        } \
    } while(0)

/* ==================== HFSC性能监控宏 ==================== */
#define HFSC_OPERATION_START(dev_ctx, classid) \
    int64_t __hfsc_start_time = get_current_time_ms()

#define HFSC_OPERATION_END(dev_ctx, classid, result) \
    do { \
        int64_t __hfsc_elapsed = get_current_time_ms() - __hfsc_start_time; \
        update_hfsc_perf_stats(dev_ctx, classid, __hfsc_elapsed, result); \
    } while(0)

/* ==================== 核心算法实现 ==================== */

/* ==================== 算法检测函数 ==================== */
static int detect_algorithm(device_context_t* dev_ctx, algorithm_detection_t* detection) {
    if (!dev_ctx || !detection) {
        return 0;
    }
    
    int ifindex = get_ifindex(dev_ctx);
    if (ifindex <= 0) {
        return 0;
    }
    
    memset(detection, 0, sizeof(algorithm_detection_t));
    detection->algorithm_type = ALGORITHM_UNKNOWN;
    
    /* 第一步：尝试获取qdisc信息 */
    struct rtnl_qdisc* qdisc = rtnl_qdisc_alloc();
    if (!qdisc) {
        return 0;
    }
    
    rtnl_tc_set_ifindex(TC_CAST(qdisc), ifindex);
    rtnl_tc_set_parent(TC_CAST(qdisc), TC_H_ROOT);
    
    int ret = rtnl_qdisc_get(&dev_ctx->rth, qdisc);
    if (ret == 0) {
        const char* kind = rtnl_tc_get_kind(TC_CAST(qdisc));
        if (kind) {
            safe_strncpy(detection->qdisc_kind, kind, sizeof(detection->qdisc_kind));
            
            /* 确定算法类型 */
            if (strcmp(kind, "htb") == 0) {
                detection->algorithm_type = ALGORITHM_HTB;
            } else if (strcmp(kind, "hfsc") == 0) {
                detection->algorithm_type = ALGORITHM_HFSC;
            } else if (strcmp(kind, "cake") == 0) {
                detection->algorithm_type = ALGORITHM_CAKE;
            } else {
                /* 尝试从分类中推断算法 */
                struct nl_cache* cache = NULL;
                if (rtnl_class_alloc_cache(&dev_ctx->rth, ifindex, &cache) >= 0) {
                    struct rtnl_class* class_obj = (struct rtnl_class*)nl_cache_get_first(cache);
                    if (class_obj) {
                        const char* class_kind = rtnl_tc_get_kind(TC_CAST(class_obj));
                        if (class_kind) {
                            if (strcmp(class_kind, "htb") == 0) {
                                detection->algorithm_type = ALGORITHM_HTB;
                                safe_strncpy(detection->qdisc_kind, "htb", sizeof(detection->qdisc_kind));
                            } else if (strcmp(class_kind, "hfsc") == 0) {
                                detection->algorithm_type = ALGORITHM_HFSC;
                                safe_strncpy(detection->qdisc_kind, "hfsc", sizeof(detection->qdisc_kind));
                            }
                        }
                        
                        /* 统计分类数量 */
                        int class_count = 0;
                        for (class_obj = (struct rtnl_class*)nl_cache_get_first(cache); 
                             class_obj; 
                             class_obj = (struct rtnl_class*)nl_cache_get_next((struct nl_object*)class_obj)) {
                            if (rtnl_tc_get_ifindex(TC_CAST(class_obj)) == ifindex) {
                                uint32_t handle = rtnl_tc_get_handle(TC_CAST(class_obj));
                                if (handle != TC_H_ROOT) {
                                    class_count++;
                                }
                            }
                        }
                        detection->detected_classes = class_count;
                    }
                    nl_cache_free(cache);
                }
            }
        }
    }
    
    rtnl_qdisc_put(qdisc);
    
    /* 第二步：如果没有检测到算法，尝试从已知的qdisc类型推断 */
    if (detection->algorithm_type == ALGORITHM_UNKNOWN) {
        /* 检查接口名称特征 */
        if (strstr(dev_ctx->device, "ifb") != NULL || 
            strstr(dev_ctx->device, "pppoe") != NULL) {
            /* 常见的家庭网关接口，默认使用HTB */
            detection->algorithm_type = ALGORITHM_HTB;
            safe_strncpy(detection->qdisc_kind, "htb", sizeof(detection->qdisc_kind));
        } else if (strstr(dev_ctx->device, "eth") != NULL ||
                   strstr(dev_ctx->device, "en") != NULL) {
            /* 以太网接口，可能使用HFSC */
            detection->algorithm_type = ALGORITHM_HFSC;
            safe_strncpy(detection->qdisc_kind, "hfsc", sizeof(detection->qdisc_kind));
        } else {
            /* 默认使用HTB */
            detection->algorithm_type = ALGORITHM_HTB;
            safe_strncpy(detection->qdisc_kind, "htb", sizeof(detection->qdisc_kind));
        }
    }
    
    /* 记录检测结果 */
    const char* algo_name = "未知";
    switch (detection->algorithm_type) {
        case ALGORITHM_HTB: algo_name = "HTB"; break;
        case ALGORITHM_HFSC: algo_name = "HFSC"; break;
        case ALGORITHM_CAKE: algo_name = "CAKE"; break;
    }
    
    log_device_message(dev_ctx, "INFO", 
                      "算法检测结果: 类型=%s, qdisc_kind=%s, 检测到分类数=%d\n",
                      algo_name, detection->qdisc_kind, detection->detected_classes);
    
    return 1;
}

static const qos_algorithm_ops_t* get_algorithm_ops(const char* qdisc_kind) {
    if (strcmp(qdisc_kind, "htb") == 0) {
        return &htb_ops;
    } else if (strcmp(qdisc_kind, "hfsc") == 0) {
        return &hfsc_ops;
    } else if (strcmp(qdisc_kind, "cake") == 0) {
        return &cake_ops;
    } else {
        /* 默认使用HTB */
        return &htb_ops;
    }
}

static const qos_algorithm_ops_t* get_algorithm_ops_by_type(int algorithm_type) {
    switch (algorithm_type) {
        case ALGORITHM_HTB: return &htb_ops;
        case ALGORITHM_HFSC: return &hfsc_ops;
        case ALGORITHM_CAKE: return &cake_ops;
        default: return &htb_ops;
    }
}

/* ==================== HFSC完整实现 ==================== */

/* HFSC带宽调整函数 */
static qosdba_result_t adjust_hfsc_bandwidth(device_context_t* dev_ctx,
                                           int classid,
                                           int new_bw_kbps) {
    if (!dev_ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    HFSC_OPERATION_START(dev_ctx, classid);
    
    int ifindex = get_ifindex(dev_ctx);
    if (ifindex <= 0) {
        return QOSDBA_ERR_NETWORK;
    }
    
    /* 获取分类对象 */
    struct rtnl_class* class_obj = rtnl_class_alloc();
    if (!class_obj) {
        return QOSDBA_ERR_MEMORY;
    }
    
    rtnl_tc_set_ifindex(TC_CAST(class_obj), ifindex);
    rtnl_tc_set_handle(TC_CAST(class_obj), classid);
    
    /* 获取当前分类信息 */
    int ret = rtnl_class_get(&dev_ctx->rth, class_obj);
    if (ret < 0) {
        rtnl_class_put(class_obj);
        return QOSDBA_ERR_TC;
    }
    
    int new_rate = new_bw_kbps * 1000 / 8;  /* 转换为字节/秒 */
    
    /* 调整HFSC的三个服务曲线 */
    struct tc_service_curve rsc, fsc, usc;
    
    /* 获取当前服务曲线 */
    int rsc_ret = rtnl_class_hfsc_get_rsc(class_obj, &rsc);
    int fsc_ret = rtnl_class_hfsc_get_fsc(class_obj, &fsc);
    int usc_ret = rtnl_class_hfsc_get_usc(class_obj, &usc);
    
    /* 设置新的服务曲线参数 */
    if (rsc_ret == 0) {
        /* 实时服务曲线 - 调整m1和m2，保持d不变 */
        rsc.m1 = new_rate;
        rsc.m2 = new_rate;
        rtnl_class_hfsc_set_rsc(class_obj, &rsc);
    }
    
    if (fsc_ret == 0) {
        /* 链接共享曲线 - 调整m2，m1通常为0，d保持固定 */
        fsc.m2 = new_rate;
        rtnl_class_hfsc_set_fsc(class_obj, &fsc);
    }
    
    if (usc_ret == 0) {
        /* 上限曲线 - 调整m1和m2，d通常为0 */
        usc.m1 = new_rate;
        usc.m2 = new_rate;
        rtnl_class_hfsc_set_usc(class_obj, &usc);
    }
    
    /* 应用变更 */
    ret = rtnl_class_change(&dev_ctx->rth, class_obj, 0);
    rtnl_class_put(class_obj);
    
    qosdba_result_t result = (ret < 0) ? QOSDBA_ERR_TC : QOSDBA_OK;
    HFSC_OPERATION_END(dev_ctx, classid, result);
    
    if (ret < 0) {
        return QOSDBA_ERR_TC;
    }
    
    return QOSDBA_OK;
}

/* HFSC初始化分类 */
static qosdba_result_t init_hfsc_class(device_context_t* dev_ctx,
                                     class_config_t* config,
                                     class_state_t* state,
                                     int ifindex) {
    if (!dev_ctx || !config || !state) {
        return QOSDBA_ERR_MEMORY;
    }
    
    struct rtnl_class* class_obj = rtnl_class_alloc();
    if (!class_obj) {
        return QOSDBA_ERR_MEMORY;
    }
    
    /* 设置基本属性 */
    rtnl_tc_set_ifindex(TC_CAST(class_obj), ifindex);
    rtnl_tc_set_parent(TC_CAST(class_obj), TC_H_ROOT);
    rtnl_tc_set_handle(TC_CAST(class_obj), config->classid);
    rtnl_tc_set_kind(TC_CAST(class_obj), "hfsc");
    
    int rate_bytes_per_sec = state->current_bw_kbps * 1000 / 8;
    
    /* 设置实时服务曲线(RSC) - 保证延迟 */
    struct tc_service_curve rsc;
    rsc.m1 = rate_bytes_per_sec;  /* 初始速率 */
    rsc.d = 10;                   /* 10ms延迟，保证实时性 */
    rsc.m2 = rate_bytes_per_sec;  /* 稳态速率 */
    
    /* 设置链接共享曲线(FSC) - 公平共享 */
    struct tc_service_curve fsc;
    fsc.m1 = 0;                   /* 初始速率为0 */
    fsc.d = 100;                  /* 100ms延迟，用于公平共享 */
    fsc.m2 = rate_bytes_per_sec;  /* 稳态速率 */
    
    /* 设置上限曲线(USC) - 最大限制 */
    struct tc_service_curve usc;
    usc.m1 = rate_bytes_per_sec;  /* 初始速率 */
    usc.d = 0;                    /* 延迟0，立即生效 */
    usc.m2 = rate_bytes_per_sec;  /* 稳态速率 */
    
    /* 应用服务曲线 */
    rtnl_class_hfsc_set_rsc(class_obj, &rsc);
    rtnl_class_hfsc_set_fsc(class_obj, &fsc);
    rtnl_class_hfsc_set_usc(class_obj, &usc);
    
    /* 添加分类 */
    int ret = rtnl_class_add(&dev_ctx->rth, class_obj, NLM_F_CREATE);
    if (ret < 0) {
        ret = rtnl_class_change(&dev_ctx->rth, class_obj, 0);
    }
    
    rtnl_class_put(class_obj);
    
    if (ret < 0) {
        return QOSDBA_ERR_TC;
    }
    
    return QOSDBA_OK;
}

/* HFSC借用带宽 */
static qosdba_result_t borrow_hfsc_bandwidth(device_context_t* dev_ctx,
                                           int from_classid,
                                           int to_classid,
                                           int borrow_amount) {
    qosdba_result_t ret;
    
    /* 获取借出方当前带宽 */
    int idx = find_class_by_id(dev_ctx, from_classid);
    if (idx < 0) {
        return QOSDBA_ERR_INVALID;
    }
    int from_current = dev_ctx->states[idx].current_bw_kbps;
    
    /* 获取借入方当前带宽 */
    idx = find_class_by_id(dev_ctx, to_classid);
    if (idx < 0) {
        return QOSDBA_ERR_INVALID;
    }
    int to_current = dev_ctx->states[idx].current_bw_kbps;
    
    /* 调整借出方带宽（减少） */
    ret = adjust_hfsc_bandwidth(dev_ctx, from_classid, from_current - borrow_amount);
    if (ret != QOSDBA_OK) {
        return ret;
    }
    
    /* 调整借入方带宽（增加） */
    ret = adjust_hfsc_bandwidth(dev_ctx, to_classid, to_current + borrow_amount);
    if (ret != QOSDBA_OK) {
        /* 如果失败，尝试恢复借出方带宽 */
        adjust_hfsc_bandwidth(dev_ctx, from_classid, from_current);
        return ret;
    }
    
    return QOSDBA_OK;
}

/* HFSC归还带宽 */
static qosdba_result_t return_hfsc_bandwidth(device_context_t* dev_ctx,
                                           int from_classid,
                                           int to_classid,
                                           int return_amount) {
    return borrow_hfsc_bandwidth(dev_ctx, to_classid, from_classid, return_amount);
}

/* HFSC获取当前带宽 */
static int get_hfsc_current_bandwidth(device_context_t* dev_ctx, int classid) {
    int ifindex = get_ifindex(dev_ctx);
    if (ifindex <= 0) {
        return 0;
    }
    
    struct rtnl_class* class_obj = rtnl_class_alloc();
    if (!class_obj) {
        return 0;
    }
    
    rtnl_tc_set_ifindex(TC_CAST(class_obj), ifindex);
    rtnl_tc_set_handle(TC_CAST(class_obj), classid);
    
    int ret = rtnl_class_get(&dev_ctx->rth, class_obj);
    if (ret < 0) {
        rtnl_class_put(class_obj);
        return 0;
    }
    
    /* 尝试从RSC获取带宽 */
    struct tc_service_curve rsc;
    int bandwidth_kbps = 0;
    
    if (rtnl_class_hfsc_get_rsc(class_obj, &rsc) == 0) {
        /* 从m1或m2获取带宽（字节/秒），转换为kbps */
        bandwidth_kbps = (int)(rsc.m1 * 8 / 1000);
    }
    
    rtnl_class_put(class_obj);
    return bandwidth_kbps;
}

/* HFSC性能监控 */
static void update_hfsc_perf_stats(device_context_t* dev_ctx, int classid, 
                                  int64_t operation_time, qosdba_result_t result) {
    if (!dev_ctx) return;
    
    dev_ctx->perf_stats.hfsc_adjustments++;
    
    /* 更新平均延迟 */
    if (dev_ctx->perf_stats.hfsc_adjustments > 0) {
        float alpha = 0.1f;  /* 指数平滑系数 */
        dev_ctx->perf_stats.hfsc_latency_ms = 
            alpha * operation_time + (1.0f - alpha) * dev_ctx->perf_stats.hfsc_latency_ms;
    }
    
    /* 记录最大延迟 */
    if (operation_time > dev_ctx->perf_stats.hfsc_latency_ms) {
        dev_ctx->perf_stats.hfsc_latency_ms = operation_time;
    }
    
    /* 曲线更新统计 */
    dev_ctx->perf_stats.hfsc_curve_updates++;
}

/* ==================== HTB算法实现 ==================== */

static qosdba_result_t init_htb_class(device_context_t* dev_ctx,
                                    class_config_t* config,
                                    class_state_t* state,
                                    int ifindex) {
    if (!dev_ctx || !config || !state) {
        return QOSDBA_ERR_MEMORY;
    }
    
    struct rtnl_class* class_obj = rtnl_class_alloc();
    if (!class_obj) {
        return QOSDBA_ERR_MEMORY;
    }
    
    rtnl_tc_set_ifindex(TC_CAST(class_obj), ifindex);
    rtnl_tc_set_parent(TC_CAST(class_obj), TC_H_ROOT);
    rtnl_tc_set_handle(TC_CAST(class_obj), config->classid);
    rtnl_tc_set_kind(TC_CAST(class_obj), "htb");
    
    struct rtnl_htb_class* htb_class = (struct rtnl_htb_class*)class_obj;
    int rate = state->current_bw_kbps;
    int ceil = state->current_bw_kbps;
    
    rate = rate * 1000 / 8;
    ceil = ceil * 1000 / 8;
    
    rtnl_htb_set_rate(htb_class, rate);
    rtnl_htb_set_ceil(htb_class, ceil);
    rtnl_htb_set_prio(htb_class, config->priority);
    
    int ret = rtnl_class_add(&dev_ctx->rth, class_obj, NLM_F_CREATE);
    if (ret < 0) {
        ret = rtnl_class_change(&dev_ctx->rth, class_obj, 0);
    }
    
    rtnl_class_put(class_obj);
    
    if (ret < 0) {
        return QOSDBA_ERR_TC;
    }
    
    return QOSDBA_OK;
}

static qosdba_result_t adjust_htb_bandwidth(device_context_t* dev_ctx,
                                          int classid,
                                          int new_bw_kbps) {
    if (!dev_ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    int ifindex = get_ifindex(dev_ctx);
    if (ifindex <= 0) {
        return QOSDBA_ERR_NETWORK;
    }
    
    struct rtnl_class* class_obj = rtnl_class_alloc();
    if (!class_obj) {
        return QOSDBA_ERR_MEMORY;
    }
    
    rtnl_tc_set_ifindex(TC_CAST(class_obj), ifindex);
    rtnl_tc_set_handle(TC_CAST(class_obj), classid);
    
    int ret = rtnl_class_get(&dev_ctx->rth, class_obj);
    if (ret < 0) {
        rtnl_class_put(class_obj);
        return QOSDBA_ERR_TC;
    }
    
    struct rtnl_htb_class* htb_class = (struct rtnl_htb_class*)class_obj;
    int rate = new_bw_kbps;
    int ceil = new_bw_kbps;
    
    rate = rate * 1000 / 8;
    ceil = ceil * 1000 / 8;
    
    rtnl_htb_set_rate(htb_class, rate);
    rtnl_htb_set_ceil(htb_class, ceil);
    
    ret = rtnl_class_change(&dev_ctx->rth, class_obj, 0);
    rtnl_class_put(class_obj);
    
    if (ret < 0) {
        return QOSDBA_ERR_TC;
    }
    
    return QOSDBA_OK;
}

static qosdba_result_t borrow_htb_bandwidth(device_context_t* dev_ctx,
                                          int from_classid,
                                          int to_classid,
                                          int borrow_amount) {
    qosdba_result_t ret;
    
    /* 获取借出方当前带宽 */
    int idx = find_class_by_id(dev_ctx, from_classid);
    if (idx < 0) {
        return QOSDBA_ERR_INVALID;
    }
    int from_current = dev_ctx->states[idx].current_bw_kbps;
    
    /* 获取借入方当前带宽 */
    idx = find_class_by_id(dev_ctx, to_classid);
    if (idx < 0) {
        return QOSDBA_ERR_INVALID;
    }
    int to_current = dev_ctx->states[idx].current_bw_kbps;
    
    /* 调整借出方带宽（减少） */
    ret = adjust_htb_bandwidth(dev_ctx, from_classid, from_current - borrow_amount);
    if (ret != QOSDBA_OK) {
        return ret;
    }
    
    /* 调整借入方带宽（增加） */
    ret = adjust_htb_bandwidth(dev_ctx, to_classid, to_current + borrow_amount);
    if (ret != QOSDBA_OK) {
        /* 如果失败，尝试恢复借出方带宽 */
        adjust_htb_bandwidth(dev_ctx, from_classid, from_current);
        return ret;
    }
    
    return QOSDBA_OK;
}

static qosdba_result_t return_htb_bandwidth(device_context_t* dev_ctx,
                                          int from_classid,
                                          int to_classid,
                                          int return_amount) {
    return borrow_htb_bandwidth(dev_ctx, to_classid, from_classid, return_amount);
}

static int get_htb_current_bandwidth(device_context_t* dev_ctx, int classid) {
    int ifindex = get_ifindex(dev_ctx);
    if (ifindex <= 0) {
        return 0;
    }
    
    struct rtnl_class* class_obj = rtnl_class_alloc();
    if (!class_obj) {
        return 0;
    }
    
    rtnl_tc_set_ifindex(TC_CAST(class_obj), ifindex);
    rtnl_tc_set_handle(TC_CAST(class_obj), classid);
    
    int ret = rtnl_class_get(&dev_ctx->rth, class_obj);
    if (ret < 0) {
        rtnl_class_put(class_obj);
        return 0;
    }
    
    struct rtnl_htb_class* htb_class = (struct rtnl_htb_class*)class_obj;
    int rate = rtnl_htb_get_rate(htb_class);
    int bandwidth_kbps = (int)(rate * 8 / 1000);
    
    rtnl_class_put(class_obj);
    return bandwidth_kbps;
}

/* ==================== 修改初始化TC分类（自动算法适配） ==================== */

static qosdba_result_t init_tc_classes(device_context_t* dev_ctx, qosdba_context_t* ctx) {
    if (!dev_ctx || !ctx) return QOSDBA_ERR_MEMORY;
    
    int success_count = 0;
    int dba_enabled_count = 0;
    int ifindex = get_ifindex(dev_ctx);
    if (ifindex <= 0) {
        log_device_message(dev_ctx, "ERROR", "无法获取设备接口索引\n");
        return QOSDBA_ERR_NETWORK;
    }
    
    /* 自动检测算法 */
    if (strlen(dev_ctx->qdisc_kind) == 0) {
        algorithm_detection_t detection;
        if (detect_algorithm(dev_ctx, &detection)) {
            safe_strncpy(dev_ctx->qdisc_kind, detection.qdisc_kind, sizeof(dev_ctx->qdisc_kind));
            log_device_message(dev_ctx, "INFO", "自动检测到算法: %s\n", dev_ctx->qdisc_kind);
        } else {
            /* 默认使用HTB */
            strcpy(dev_ctx->qdisc_kind, "htb");
            log_device_message(dev_ctx, "WARN", "算法检测失败，使用默认HTB算法\n");
        }
    }
    
    const qos_algorithm_ops_t* ops = get_algorithm_ops(dev_ctx->qdisc_kind);
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_config_t* config = &dev_ctx->configs[i];
        class_state_t* state = &dev_ctx->states[i];
        
        state->dba_enabled = config->dba_enabled;
        
        if (!state->dba_enabled) {
            log_device_message(dev_ctx, "INFO", "分类 %s (0x%x) DBA被禁用，不参与动态调整\n",
                             config->name, config->classid);
            continue;
        }
        
        dba_enabled_count++;
        
        state->classid = config->classid;
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
        
        if (ctx->safe_mode) {
            log_device_message(dev_ctx, "DEBUG", "[安全模式] 将为分类 0x%x 设置带宽: %d kbps (算法: %s)\n", 
                             config->classid, state->current_bw_kbps, ops->name);
            success_count++;
            continue;
        }
        
        if (ops->init_class) {
            qosdba_result_t ret = ops->init_class(dev_ctx, config, state, ifindex);
            if (ret == QOSDBA_OK) {
                success_count++;
                log_device_message(dev_ctx, "INFO", 
                                  "%s分类 0x%x 初始化成功: 带宽=%dkbps, 优先级=%d\n",
                                  ops->name, config->classid, state->current_bw_kbps, config->priority);
            } else {
                log_device_message(dev_ctx, "ERROR", 
                                  "%s分类 0x%x 初始化失败\n", ops->name, config->classid);
            }
        } else {
            log_device_message(dev_ctx, "ERROR", 
                              "算法 %s 不支持分类初始化\n", ops->name);
        }
    }
    
    if (dba_enabled_count < 2) {
        log_device_message(dev_ctx, "ERROR", "启用DBA的分类数量不足2个，无法运行动态调整\n");
        return QOSDBA_ERR_CONFIG;
    }
    
    if (success_count == dba_enabled_count) {
        return QOSDBA_OK;
    } else if (success_count > 0) {
        log_device_message(dev_ctx, "WARN", "部分DBA分类初始化成功: %d/%d (算法: %s)\n", 
                         success_count, dba_enabled_count, ops->name);
        return QOSDBA_OK;
    } else {
        return QOSDBA_ERR_TC;
    }
}

/* ==================== 修改调整分类带宽（自动算法适配） ==================== */

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
    
    if (ctx->safe_mode) {
        log_device_message(dev_ctx, "DEBUG", 
                          "[安全模式] 调整分类 0x%x 带宽: %d -> %d kbps (算法: %s)\n", 
                          classid, state->current_bw_kbps, new_bw_kbps, dev_ctx->qdisc_kind);
        state->current_bw_kbps = new_bw_kbps;
        return QOSDBA_OK;
    }
    
    const qos_algorithm_ops_t* ops = get_algorithm_ops(dev_ctx->qdisc_kind);
    
    if (!ops->adjust_bandwidth) {
        log_device_message(dev_ctx, "ERROR", 
                          "算法 %s 不支持带宽调整\n", ops->name);
        return QOSDBA_ERR_TC;
    }
    
    qosdba_result_t ret = ops->adjust_bandwidth(dev_ctx, classid, new_bw_kbps);
        if (ret == QOSDBA_OK) {
            state->current_bw_kbps = new_bw_kbps;
            log_device_message(dev_ctx, "INFO", 
                              "%s分类 0x%x 带宽调整: %d -> %d kbps\n",
                              ops->name, classid, state->current_bw_kbps, new_bw_kbps);
        } else {
            log_device_message(dev_ctx, "ERROR", 
                              "%s分类 0x%x 带宽调整失败: %d -> %d kbps\n",
                              ops->name, classid, state->current_bw_kbps, new_bw_kbps);
        }
        
        return ret;
    }
}

/* ==================== 修改借用逻辑（自动算法适配） ==================== */
static void run_borrow_logic(device_context_t* dev_ctx, qosdba_context_t* ctx) {
    if (!dev_ctx || !ctx || dev_ctx->num_classes < 2) return;
    
    TIME_OPERATION_START(dev_ctx, borrow_logic_time_ms);
    
    const qos_algorithm_ops_t* ops = get_algorithm_ops(dev_ctx->qdisc_kind);
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_state_t* class_a = &dev_ctx->states[i];
        class_config_t* config_a = &dev_ctx->configs[i];
        
        if (!class_a->dba_enabled) {
            continue;
        }
        
        FLOAT_COMPARISON_START(dev_ctx);
        if (class_a->utilization * 100 > dev_ctx->high_util_threshold &&
            class_a->high_util_duration >= dev_ctx->high_util_duration &&
            class_a->cooldown_timer == 0) {
            
            int needed_bw_kbps = 0;
            if (class_a->utilization > 1.0f) {
                needed_bw_kbps = (int)(class_a->current_bw_kbps * 
                                      (class_a->utilization - 1.0f));
            }
            
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
                    
                    if (borrow_amount < dev_ctx->min_borrow_kbps) {
                        borrow_amount = dev_ctx->min_borrow_kbps;
                    }
                    
                    if (borrow_amount >= dev_ctx->min_borrow_kbps) {
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
                            if (!ops->borrow_bandwidth) {
                                log_device_message(dev_ctx, "ERROR", 
                                                  "算法 %s 不支持借用逻辑\n", ops->name);
                                dev_ctx->perf_stats.failed_borrows++;
                                continue;
                            }
                            
                            /* 执行借用 */
                            qosdba_result_t ret = ops->borrow_bandwidth(dev_ctx,
                                                                       class_b->classid,
                                                                       class_a->classid,
                                                                       borrow_amount);
                            
                            if (ret == QOSDBA_OK) {
                                class_a->current_bw_kbps += borrow_amount;
                                class_b->current_bw_kbps -= borrow_amount;
                                
                                class_a->borrowed_bw_kbps += borrow_amount;
                                class_b->lent_bw_kbps += borrow_amount;
                                
                                class_a->cooldown_timer = dev_ctx->cooldown_time;
                                
                                add_borrow_record(dev_ctx, class_b->classid, 
                                                class_a->classid, borrow_amount);
                                
                                dev_ctx->perf_stats.cross_class_interactions++;
                                dev_ctx->perf_stats.successful_borrows++;
                                
                                log_device_message(dev_ctx, "INFO", 
                                                  "[%s] 分类 %s 从 %s 借用 %d kbps 带宽\n",
                                                  ops->name, config_a->name, config_b->name, borrow_amount);
                                
                                break;
                            } else {
                                dev_ctx->perf_stats.failed_borrows++;
                            }
                        }
                    }
                }
            } else {
                dev_ctx->perf_stats.failed_borrows++;
            }
        }
    }
    
    TIME_OPERATION_END(dev_ctx, borrow_logic_time_ms);
}

/* ==================== 修改归还逻辑（自动算法适配） ==================== */
static void run_return_logic(device_context_t* dev_ctx, qosdba_context_t* ctx) {
    if (!dev_ctx || !ctx || !dev_ctx->auto_return_enable) return;
    
    TIME_OPERATION_START(dev_ctx, return_logic_time_ms);
    
    const qos_algorithm_ops_t* ops = get_algorithm_ops(dev_ctx->qdisc_kind);
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_state_t* class_b = &dev_ctx->states[i];
        
        if (!class_b->dba_enabled) {
            continue;
        }
        
        FLOAT_COMPARISON_START(dev_ctx);
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
                            if (!ops->return_bandwidth) {
                                log_device_message(dev_ctx, "ERROR", 
                                                  "算法 %s 不支持归还逻辑\n", ops->name);
                                dev_ctx->perf_stats.failed_returns++;
                                continue;
                            }
                            
                            /* 执行归还 */
                            qosdba_result_t ret = ops->return_bandwidth(dev_ctx,
                                                                       class_a->classid,
                                                                       class_b->classid,
                                                                       return_amount);
                            
                            if (ret == QOSDBA_OK) {
                                class_a->current_bw_kbps -= return_amount;
                                class_b->current_bw_kbps += return_amount;
                                
                                class_a->borrowed_bw_kbps -= return_amount;
                                class_b->lent_bw_kbps -= return_amount;
                                
                                record->borrowed_bw_kbps -= return_amount;
                                
                                dev_ctx->total_return_events++;
                                dev_ctx->total_returned_kbps += return_amount;
                                
                                dev_ctx->perf_stats.cross_class_interactions++;
                                dev_ctx->perf_stats.successful_returns++;
                                
                                if (record->borrowed_bw_kbps <= 0) {
                                    record->returned = 1;
                                }
                                
                                log_device_message(dev_ctx, "INFO", 
                                                  "[%s] 分类 0x%x 归还 %d kbps 带宽给 0x%x\n",
                                                  ops->name, class_a->classid, return_amount, class_b->classid);
                                
                                break;
                            } else {
                                dev_ctx->perf_stats.failed_returns++;
                            }
                        } else {
                            dev_ctx->perf_stats.failed_returns++;
                        }
                    }
                }
            }
        }
    }
    
    TIME_OPERATION_END(dev_ctx, return_logic_time_ms);
}

/* ==================== 对齐内存管理函数 ==================== */
static void* aligned_malloc(size_t size, size_t alignment) {
    if (alignment < sizeof(void*)) {
        alignment = sizeof(void*);
    }
    
    void* original_ptr = malloc(size + alignment + sizeof(void*) + sizeof(size_t));
    if (!original_ptr) {
        return NULL;
    }
    
    uintptr_t original_addr = (uintptr_t)original_ptr;
    uintptr_t aligned_addr = (original_addr + sizeof(void*) + sizeof(size_t) + alignment - 1) & ~(alignment - 1);
    
    void** header = (void**)(aligned_addr - sizeof(void*));
    *header = original_ptr;
    
    size_t* size_ptr = (size_t*)(aligned_addr - sizeof(void*) - sizeof(size_t));
    *size_ptr = size;
    
    return (void*)aligned_addr;
}

static void aligned_free(void* ptr) {
    if (!ptr) {
        return;
    }
    
    uintptr_t aligned_addr = (uintptr_t)ptr;
    void** header = (void**)(aligned_addr - sizeof(void*));
    void* original_ptr = *header;
    
    free(original_ptr);
}

static qosdba_result_t init_aligned_memory_manager(aligned_memory_manager_t* manager) {
    if (!manager) {
        return QOSDBA_ERR_MEMORY;
    }
    
    memset(manager, 0, sizeof(aligned_memory_manager_t));
    manager->blocks = NULL;
    manager->block_count = 0;
    
    if (pthread_mutex_init(&manager->lock, NULL) != 0) {
        return QOSDBA_ERR_THREAD;
    }
    
    return QOSDBA_OK;
}

static void cleanup_aligned_memory_manager(aligned_memory_manager_t* manager) {
    if (!manager) {
        return;
    }
    
    pthread_mutex_lock(&manager->lock);
    
    aligned_memory_block_t* block = manager->blocks;
    while (block) {
        aligned_memory_block_t* next = block->next;
        if (block->original_ptr) {
            free(block->original_ptr);
        }
        free(block);
        block = next;
    }
    
    manager->blocks = NULL;
    manager->block_count = 0;
    
    pthread_mutex_unlock(&manager->lock);
    pthread_mutex_destroy(&manager->lock);
}

/* ==================== 信号队列函数 ==================== */
static qosdba_result_t init_signal_queue(signal_queue_t* queue) {
    if (!queue) {
        return QOSDBA_ERR_MEMORY;
    }
    
    memset(queue, 0, sizeof(signal_queue_t));
    
    for (int i = 0; i < MAX_SIGNAL_QUEUE_SIZE; i++) {
        queue->signals[i] = 0;
    }
    
    queue->signal_count = 0;
    queue->signal_read_index = 0;
    queue->signal_write_index = 0;
    
    if (pthread_mutex_init(&queue->signal_mutex, NULL) != 0) {
        return QOSDBA_ERR_THREAD;
    }
    
    if (pthread_cond_init(&queue->signal_cond, NULL) != 0) {
        pthread_mutex_destroy(&queue->signal_mutex);
        return QOSDBA_ERR_THREAD;
    }
    
    return QOSDBA_OK;
}

static void cleanup_signal_queue(signal_queue_t* queue) {
    if (!queue) {
        return;
    }
    
    pthread_mutex_destroy(&queue->signal_mutex);
    pthread_cond_destroy(&queue->signal_cond);
}

static qosdba_result_t enqueue_signal(signal_queue_t* queue, int sig) {
    if (!queue) {
        return QOSDBA_ERR_MEMORY;
    }
    
    pthread_mutex_lock(&queue->signal_mutex);
    
    if (queue->signal_count >= MAX_SIGNAL_QUEUE_SIZE) {
        pthread_mutex_unlock(&queue->signal_mutex);
        return QOSDBA_ERR_SIGNAL;
    }
    
    queue->signals[queue->signal_write_index] = sig;
    queue->signal_write_index = (queue->signal_write_index + 1) % MAX_SIGNAL_QUEUE_SIZE;
    queue->signal_count++;
    
    pthread_cond_signal(&queue->signal_cond);
    pthread_mutex_unlock(&queue->signal_mutex);
    
    return QOSDBA_OK;
}

static int dequeue_signal(signal_queue_t* queue) {
    if (!queue || queue->signal_count == 0) {
        return 0;
    }
    
    pthread_mutex_lock(&queue->signal_mutex);
    
    if (queue->signal_count == 0) {
        pthread_mutex_unlock(&queue->signal_mutex);
        return 0;
    }
    
    int sig = queue->signals[queue->signal_read_index];
    queue->signal_read_index = (queue->signal_read_index + 1) % MAX_SIGNAL_QUEUE_SIZE;
    queue->signal_count--;
    
    pthread_mutex_unlock(&queue->signal_mutex);
    return sig;
}

static int peek_signal(signal_queue_t* queue) {
    if (!queue || queue->signal_count == 0) {
        return 0;
    }
    
    pthread_mutex_lock(&queue->signal_mutex);
    int sig = (queue->signal_count > 0) ? queue->signals[queue->signal_read_index] : 0;
    pthread_mutex_unlock(&queue->signal_mutex);
    
    return sig;
}

/* ==================== 信号处理函数 ==================== */
static volatile sig_atomic_t g_signal_received = 0;
static volatile sig_atomic_t g_reload_signal = 0;

static void signal_handler(int sig) {
    SIGNAL_CHECK_START(NULL);
    
    switch (sig) {
        case SIGTERM:
        case SIGINT:
        case SIGQUIT:
            g_signal_received = sig;
            break;
        case SIGHUP:
            g_reload_signal = 1;
            break;
    }
}

static void setup_signal_handlers(void) {
    pthread_spin_init(&g_ctx_lock, PTHREAD_PROCESS_PRIVATE);
    
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sa.sa_flags = SA_RESTART;
    sigemptyset(&sa.sa_mask);
    
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGQUIT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    
    signal(SIGPIPE, SIG_IGN);
    signal(SIGALRM, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);
}

/* ==================== 浮点数比较函数 ==================== */
static bool float_equal(float a, float b, float epsilon) {
    FLOAT_COMPARISON_START(NULL);
    
    if (epsilon < 0.0f) {
        epsilon = FLOAT_EPSILON;
    }
    
    return fabsf(a - b) <= epsilon;
}

static bool float_less(float a, float b, float epsilon) {
    FLOAT_COMPARISON_START(NULL);
    
    if (epsilon < 0.0f) {
        epsilon = FLOAT_EPSILON;
    }
    
    return (b - a) > epsilon;
}

static bool float_greater(float a, float b, float epsilon) {
    FLOAT_COMPARISON_START(NULL);
    
    if (epsilon < 0.0f) {
        epsilon = FLOAT_EPSILON;
    }
    
    return (a - b) > epsilon;
}

static bool float_less_or_equal(float a, float b, float epsilon) {
    FLOAT_COMPARISON_START(NULL);
    
    if (epsilon < 0.0f) {
        epsilon = FLOAT_EPSILON;
    }
    
    return (a - b) <= epsilon;
}

static bool float_greater_or_equal(float a, float b, float epsilon) {
    FLOAT_COMPARISON_START(NULL);
    
    if (epsilon < 0.0f) {
        epsilon = FLOAT_EPSILON;
    }
    
    return (b - a) <= epsilon;
}

static int init_float_tolerance(float_tolerance_t* tolerance) {
    if (!tolerance) {
        return 0;
    }
    
    tolerance->epsilon = FLOAT_EPSILON;
    tolerance->min_epsilon = FLOAT_EPSILON * 0.1f;
    tolerance->max_epsilon = FLOAT_EPSILON * 10.0f;
    tolerance->relative_tolerance = 1e-6f;
    tolerance->absolute_tolerance = 1e-9f;
    
    return 1;
}

/* ==================== TC错误处理函数 ==================== */
static const char* get_tc_error_description(int tc_error) {
    TC_ERROR_HANDLING_START(NULL);
    
    for (int i = 0; TC_ERROR_MAPPINGS[i].description != NULL; i++) {
        if (TC_ERROR_MAPPINGS[i].tc_error == tc_error) {
            return TC_ERROR_MAPPINGS[i].description;
        }
    }
    
    return "未知TC错误";
}

static qosdba_result_t map_tc_error_to_qosdba(int tc_error) {
    TC_ERROR_HANDLING_START(NULL);
    
    for (int i = 0; TC_ERROR_MAPPINGS[i].description != NULL; i++) {
        if (TC_ERROR_MAPPINGS[i].tc_error == tc_error) {
            return TC_ERROR_MAPPINGS[i].qosdba_error;
        }
    }
    
    return QOSDBA_ERR_TC;
}

static bool is_tc_error_fatal(int tc_error) {
    TC_ERROR_HANDLING_START(NULL);
    
    for (int i = 0; TC_ERROR_MAPPINGS[i].description != NULL; i++) {
        if (TC_ERROR_MAPPINGS[i].tc_error == tc_error) {
            return TC_ERROR_MAPPINGS[i].is_fatal;
        }
    }
    
    return false;
}

static void log_tc_error(device_context_t* dev_ctx, int tc_error, const char* operation, int classid) {
    if (!dev_ctx) {
        return;
    }
    
    TC_ERROR_HANDLING_START(dev_ctx);
    
    const char* description = get_tc_error_description(tc_error);
    bool fatal = is_tc_error_fatal(tc_error);
    
    if (fatal) {
        log_device_message(dev_ctx, "ERROR", 
                          "TC操作失败: %s (分类 0x%x), 错误: %d, 描述: %s, 严重性: 致命\n",
                          operation, classid, -tc_error, description);
    } else {
        log_device_message(dev_ctx, "WARN", 
                          "TC操作失败: %s (分类 0x%x), 错误: %d, 描述: %s, 严重性: 可恢复\n",
                          operation, classid, -tc_error, description);
    }
}

/* ==================== 辅助函数 ==================== */
int64_t get_current_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

static void trim_whitespace(char* str) {
    if (!str) return;
    
    STRING_OPERATION_START(NULL);
    
    char* end;
    
    while (isspace((unsigned char)*str)) str++;
    
    if (*str == 0) return;
    
    end = str + strlen(str) - 1;
    while (end > str && isspace((unsigned char)*end)) end--;
    
    end[1] = '\0';
}

static int is_valid_device_name(const char* name) {
    if (!name || *name == '\0') return 0;
    
    STRING_OPERATION_START(NULL);
    
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

/* ==================== 安全的字符串处理函数 ==================== */
static char* safe_strncpy(char* dest, const char* src, size_t dest_size) {
    if (!dest || !src || dest_size == 0) {
        return NULL;
    }
    
    STRING_OPERATION_START(NULL);
    
    size_t src_len = strlen(src);
    size_t copy_len = (src_len < dest_size) ? src_len : (dest_size - 1);
    
    if (copy_len > 0) {
        memcpy(dest, src, copy_len);
    }
    dest[copy_len] = '\0';
    
    return dest;
}

static char* safe_strncat(char* dest, const char* src, size_t dest_size) {
    if (!dest || !src || dest_size == 0) {
        return dest;
    }
    
    STRING_OPERATION_START(NULL);
    
    size_t dest_len = strlen(dest);
    size_t src_len = strlen(src);
    size_t available = (dest_size > dest_len) ? (dest_size - dest_len - 1) : 0;
    size_t copy_len = (src_len < available) ? src_len : available;
    
    if (copy_len > 0) {
        memcpy(dest + dest_len, src, copy_len);
        dest[dest_len + copy_len] = '\0';
    }
    
    return dest;
}

static int safe_snprintf(char* str, size_t size, const char* format, ...) {
    if (!str || !format || size == 0) {
        return -1;
    }
    
    STRING_OPERATION_START(NULL);
    
    va_list args;
    va_start(args, format);
    int result = vsnprintf(str, size, format, args);
    va_end(args);
    
    if (result < 0 || (size_t)result >= size) {
        str[size - 1] = '\0';
    }
    
    return result;
}

/* ==================== 配置文件解析增强函数 ==================== */
static qosdba_result_t parse_csv_line(const char* line, char** tokens, int max_tokens, int* token_count) {
    if (!line || !tokens || !token_count) {
        return QOSDBA_ERR_PARSING;
    }
    
    PARSING_OPERATION_START(NULL);
    
    *token_count = 0;
    
    char* line_copy = strdup(line);
    if (!line_copy) {
        return QOSDBA_ERR_MEMORY;
    }
    
    char* token = strtok(line_copy, ",");
    while (token && *token_count < max_tokens) {
        trim_whitespace(token);
        tokens[*token_count] = strdup(token);
        if (!tokens[*token_count]) {
            for (int i = 0; i < *token_count; i++) {
                free(tokens[i]);
            }
            free(line_copy);
            return QOSDBA_ERR_MEMORY;
        }
        (*token_count)++;
        token = strtok(NULL, ",");
    }
    
    free(line_copy);
    return QOSDBA_OK;
}

static void free_csv_tokens(char** tokens, int token_count) {
    if (!tokens) {
        return;
    }
    
    for (int i = 0; i < token_count; i++) {
        if (tokens[i]) {
            free(tokens[i]);
        }
    }
}

static qosdba_result_t parse_config_line(const char* line, int line_number, 
                                        int* classid, char* name, size_t name_size,
                                        int* priority, int* total_bw_kbps, 
                                        int* min_bw_kbps, int* max_bw_kbps, 
                                        int* dba_enabled) {
    if (!line || !classid || !name || !priority || !total_bw_kbps || 
        !min_bw_kbps || !max_bw_kbps || !dba_enabled) {
        return QOSDBA_ERR_PARSING;
    }
    
    PARSING_OPERATION_START(NULL);
    
    char* tokens[MAX_FIELD_COUNT] = {0};
    int token_count = 0;
    
    qosdba_result_t result = parse_csv_line(line, tokens, MAX_FIELD_COUNT, &token_count);
    if (result != QOSDBA_OK) {
        return result;
    }
    
    if (token_count < 6 || token_count > 7) {
        free_csv_tokens(tokens, token_count);
        return QOSDBA_ERR_PARSING;
    }
    
    int parsed_classid = 0;
    if (sscanf(tokens[0], "0x%x", &parsed_classid) != 1) {
        free_csv_tokens(tokens, token_count);
        return QOSDBA_ERR_PARSING;
    }
    
    safe_strncpy(name, tokens[1], name_size);
    
    int parsed_priority = atoi(tokens[2]);
    int parsed_total_bw = atoi(tokens[3]);
    int parsed_min_bw = atoi(tokens[4]);
    int parsed_max_bw = atoi(tokens[5]);
    
    int parsed_dba_enabled = 1;
    if (token_count == 7) {
        parsed_dba_enabled = atoi(tokens[6]);
    }
    
    *classid = parsed_classid;
    *priority = parsed_priority;
    *total_bw_kbps = parsed_total_bw;
    *min_bw_kbps = parsed_min_bw;
    *max_bw_kbps = parsed_max_bw;
    *dba_enabled = parsed_dba_enabled;
    
    free_csv_tokens(tokens, token_count);
    return QOSDBA_OK;
}

/* ==================== 配置验证函数 ==================== */
static int validate_config_parameters(device_context_t* dev_ctx) {
    if (!dev_ctx) return 0;
    
    MAGIC_NUMBER_CHECK_START(dev_ctx);
    
    if (dev_ctx->total_bandwidth_kbps <= 0 || dev_ctx->total_bandwidth_kbps > 10000000) {
        log_message(NULL, "ERROR", "设备 %s 的总带宽无效: %d kbps\n", 
                   dev_ctx->device, dev_ctx->total_bandwidth_kbps);
        return 0;
    }
    
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
    
    FLOAT_COMPARISON_START(dev_ctx);
    if (dev_ctx->borrow_ratio < MIN_BORROW_RATIO - FLOAT_EPSILON || 
        dev_ctx->borrow_ratio > MAX_BORROW_RATIO + FLOAT_EPSILON) {
        log_message(NULL, "ERROR", "设备 %s 的借用比例(%.2f)超出范围(%.2f-%.2f)\n",
                   dev_ctx->device, dev_ctx->borrow_ratio, 
                   MIN_BORROW_RATIO, MAX_BORROW_RATIO);
        return 0;
    }
    
    if (dev_ctx->min_change_kbps <= 0) {
        log_message(NULL, "ERROR", "设备 %s 的最小调整带宽(%d kbps)必须大于0\n",
                   dev_ctx->device, dev_ctx->min_change_kbps);
        return 0;
    }
    
    int max_possible_borrow = dev_ctx->total_bandwidth_kbps * dev_ctx->borrow_ratio;
    if (max_possible_borrow < dev_ctx->min_borrow_kbps) {
        log_message(NULL, "ERROR", 
                   "设备 %s 最大可能借用带宽(%d)小于最小借用带宽(%d)\n",
                   dev_ctx->device, max_possible_borrow, dev_ctx->min_borrow_kbps);
        return 0;
    }
    
    int total_class_bandwidth = 0;
    int used_priorities[MAX_CLASSES] = {0};
    int dba_enabled_count = 0;
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_config_t* config = &dev_ctx->configs[i];
        
        BOUNDARY_CHECK_START(dev_ctx);
        
        if (i >= MAX_CLASSES) {
            log_message(NULL, "ERROR", "分类数量超过最大值 %d\n", MAX_CLASSES);
            return 0;
        }
        
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
        
        if (config->priority < 0 || config->priority >= MAX_CLASSES) {
            log_message(NULL, "ERROR", "分类 %s 的优先级 %d 超出范围(0-%d)\n",
                       config->name, config->priority, MAX_CLASSES-1);
            return 0;
        }
        
        if (used_priorities[config->priority]) {
            log_message(NULL, "ERROR", "优先级 %d 被多个分类使用，必须唯一\n",
                       config->priority);
            return 0;
        }
        used_priorities[config->priority] = 1;
        
        if (config->dba_enabled) {
            dba_enabled_count++;
        }
        
        total_class_bandwidth += config->total_bw_kbps;
    }
    
    if (dba_enabled_count < 2) {
        log_message(NULL, "ERROR", "设备 %s 必须至少有2个启用DBA的分类，当前启用DBA的分类数: %d\n",
                   dev_ctx->device, dba_enabled_count);
        return 0;
    }
    
    if (total_class_bandwidth > dev_ctx->total_bandwidth_kbps * 1.2f) {
        log_message(NULL, "WARN", "设备 %s 的分类总带宽(%d kbps)超过设备总带宽(%d kbps)\n",
                   dev_ctx->device, total_class_bandwidth, dev_ctx->total_bandwidth_kbps);
    }
    
    return 1;
}

/* ==================== libnetlink辅助函数 ==================== */
static int nl_talk(struct rtnl_handle *rth, struct nlmsghdr *n) {
    int err;
    
    if ((err = rtnl_talk(rth, n, NULL, 0)) < 0) {
        return err;
    }
    return 0;
}

static int qosdba_parse_class_attr(struct rtattr *tb[], int max, struct rtattr *rta, int len) {
    memset(tb, 0, sizeof(struct rtattr *) * max);
    while (RTA_OK(rta, len)) {
        if (rta->rta_type < max) {
            tb[rta->rta_type] = rta;
        }
        rta = RTA_NEXT(rta, len);
    }
    if (len) {
        fprintf(stderr, "!!!Deficit %d, rta_len=%d\n", len, rta->rta_len);
    }
    return 0;
}

static int qosdba_parse_class_stats(struct rtnl_class *cls, uint64_t *bytes, uint64_t *packets) {
    struct rtnl_tc_stats *stats = rtnl_tc_get_stats(RTNL_TC(cls));
    if (!stats) {
        return -1;
    }
    if (bytes) {
        *bytes = stats->bytes;
    }
    if (packets) {
        *packets = stats->packets;
    }
    return 0;
}

static qosdba_result_t get_shared_netlink(qosdba_context_t* ctx, struct rtnl_handle** rth) {
    if (!ctx) return QOSDBA_ERR_MEMORY;
    
    pthread_mutex_lock(&ctx->rth_mutex);
    
    if (ctx->shared_rth_refcount == 0) {
        memset(&ctx->shared_rth, 0, sizeof(ctx->shared_rth));
        ctx->shared_rth.fd = -1;
        
        if (rtnl_open(&ctx->shared_rth, 0) < 0) {
            pthread_mutex_unlock(&ctx->rth_mutex);
            return QOSDBA_ERR_NETWORK;
        }
    }
    
    ctx->shared_rth_refcount++;
    *rth = &ctx->shared_rth;
    
    pthread_mutex_unlock(&ctx->rth_mutex);
    return QOSDBA_OK;
}

static void release_shared_netlink(qosdba_context_t* ctx) {
    if (!ctx) return;
    
    pthread_mutex_lock(&ctx->rth_mutex);
    
    if (ctx->shared_rth_refcount > 0) {
        ctx->shared_rth_refcount--;
        if (ctx->shared_rth_refcount == 0 && ctx->shared_rth.fd >= 0) {
            rtnl_close(&ctx->shared_rth);
            ctx->shared_rth.fd = -1;
        }
    }
    
    pthread_mutex_unlock(&ctx->rth_mutex);
}

static qosdba_result_t open_device_netlink(device_context_t* dev_ctx, qosdba_context_t* ctx) {
    if (!dev_ctx || !ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    struct rtnl_handle* shared_rth = NULL;
    qosdba_result_t ret = get_shared_netlink(ctx, &shared_rth);
    if (ret != QOSDBA_OK) {
        return ret;
    }
    
    memcpy(&dev_ctx->rth, shared_rth, sizeof(struct rtnl_handle));
    dev_ctx->owner_ctx = ctx;
    
    return QOSDBA_OK;
}

static void close_device_netlink(device_context_t* dev_ctx, qosdba_context_t* ctx) {
    if (dev_ctx && ctx) {
        dev_ctx->rth.fd = -1;
        dev_ctx->owner_ctx = NULL;
        release_shared_netlink(ctx);
    }
}

static int get_ifindex(device_context_t* dev_ctx) {
    if (!dev_ctx || dev_ctx->rth.fd < 0) {
        return 0;
    }
    
    int ifindex = 0;
    
    ifindex = rtnl_link_name2i(&dev_ctx->rth, dev_ctx->device);
    if (ifindex > 0) {
        return ifindex;
    }
    
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd >= 0) {
        struct ifreq ifr;
        memset(&ifr, 0, sizeof(ifr));
        strncpy(ifr.ifr_name, dev_ctx->device, IFNAMSIZ-1);
        if (ioctl(fd, SIOCGIFINDEX, &ifr) == 0) {
            ifindex = ifr.ifr_ifindex;
        }
        close(fd);
    }
    
    return ifindex;
}

/* ==================== 内存池管理 ==================== */
static memory_pool_t* create_memory_pool(size_t block_size, int max_blocks) {
    memory_pool_t* pool = (memory_pool_t*)aligned_malloc(sizeof(memory_pool_t), DEFAULT_ALIGNMENT);
    if (!pool) {
        return NULL;
    }
    
    memset(pool, 0, sizeof(memory_pool_t));
    
    pool->blocks = NULL;
    pool->block_count = 0;
    pool->max_blocks = max_blocks;
    pool->block_size = block_size;
    pthread_mutex_init(&pool->lock, NULL);
    
    return pool;
}

static void* allocate_from_pool(memory_pool_t* pool, size_t size) {
    if (!pool || size > pool->block_size) {
        return NULL;
    }
    
    pthread_mutex_lock(&pool->lock);
    
    memory_pool_block_t* block = pool->blocks;
    while (block) {
        if (!block->used) {
            block->used = 1;
            pthread_mutex_unlock(&pool->lock);
            return block->data;
        }
        block = block->next;
    }
    
    if (pool->block_count >= pool->max_blocks) {
        pthread_mutex_unlock(&pool->lock);
        return NULL;
    }
    
    memory_pool_block_t* new_block = (memory_pool_block_t*)aligned_malloc(sizeof(memory_pool_block_t), DEFAULT_ALIGNMENT);
    if (!new_block) {
        pthread_mutex_unlock(&pool->lock);
        return NULL;
    }
    
    new_block->data = aligned_malloc(pool->block_size, DEFAULT_ALIGNMENT);
    if (!new_block->data) {
        aligned_free(new_block);
        pthread_mutex_unlock(&pool->lock);
        return NULL;
    }
    
    new_block->size = pool->block_size;
    new_block->used = 1;
    new_block->next = pool->blocks;
    pool->blocks = new_block;
    pool->block_count++;
    
    pthread_mutex_unlock(&pool->lock);
    return new_block->data;
}

static void free_pool_block(memory_pool_t* pool, void* ptr) {
    if (!pool || !ptr) {
        return;
    }
    
    pthread_mutex_lock(&pool->lock);
    
    memory_pool_block_t* block = pool->blocks;
    while (block) {
        if (block->data == ptr) {
            block->used = 0;
            pthread_mutex_unlock(&pool->lock);
            return;
        }
        block = block->next;
    }
    
    pthread_mutex_unlock(&pool->lock);
}

static void destroy_memory_pool(memory_pool_t* pool) {
    if (!pool) {
        return;
    }
    
    pthread_mutex_lock(&pool->lock);
    
    memory_pool_block_t* block = pool->blocks;
    while (block) {
        memory_pool_block_t* next = block->next;
        if (block->data) {
            aligned_free(block->data);
        }
        aligned_free(block);
        block = next;
    }
    
    pthread_mutex_unlock(&pool->lock);
    pthread_mutex_destroy(&pool->lock);
    aligned_free(pool);
}

static void cleanup_memory_pools(device_context_t* dev_ctx) {
    if (!dev_ctx) {
        return;
    }
    
    if (dev_ctx->batch_cmds.pool) {
        destroy_memory_pool(dev_ctx->batch_cmds.pool);
        dev_ctx->batch_cmds.pool = NULL;
    }
}

/* ==================== 日志系统 ==================== */
void log_message(qosdba_context_t* ctx, const char* level, 
                const char* format, ...) {
    if (!ctx) return;
    
    char buffer[MAX_LOG_MESSAGE_LENGTH + 1];
    time_t now = time(NULL);
    struct tm* tm_info = localtime(&now);
    
    char timestamp[MAX_TIMESTAMP_LENGTH + 1];
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

static void log_device_message(device_context_t* dev_ctx, const char* level,
                              const char* format, ...) {
    if (!dev_ctx || !dev_ctx->owner_ctx) {
        char buffer[MAX_LOG_MESSAGE_LENGTH + 1];
        va_list args;
        va_start(args, format);
        vsnprintf(buffer, sizeof(buffer), format, args);
        va_end(args);
        log_message(NULL, level, buffer);
        return;
    }
    
    char new_format[MAX_LOG_MESSAGE_LENGTH + 1];
    snprintf(new_format, sizeof(new_format), "[设备:%s] %s", 
             dev_ctx->device, format);
    
    char buffer[MAX_LOG_MESSAGE_LENGTH + 1];
    time_t now = time(NULL);
    struct tm* tm_info = localtime(&now);
    
    char timestamp[MAX_TIMESTAMP_LENGTH + 1];
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", tm_info);
    
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), new_format, args);
    va_end(args);
    
    qosdba_context_t* ctx = dev_ctx->owner_ctx;
    
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

static int parse_key_value(const char* line, char* key, int key_len, char* value, int value_len) {
    if (!line || !key || !value) return 0;
    
    const char* equal_sign = strchr(line, '=');
    if (!equal_sign) return 0;
    
    int key_len_to_copy = equal_sign - line;
    if (key_len_to_copy >= key_len) key_len_to_copy = key_len - 1;
    strncpy(key, line, key_len_to_copy);
    key[key_len_to_copy] = '\0';
    
    const char* value_start = equal_sign + 1;
    int value_len_to_copy = strlen(value_start);
    if (value_len_to_copy >= value_len) value_len_to_copy = value_len - 1;
    strncpy(value, value_start, value_len_to_copy);
    value[value_len_to_copy] = '\0';
    
    trim_whitespace(key);
    trim_whitespace(value);
    
    return 1;
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
    
    for (int i = 0; i < MAX_DEVICES; i++) {
        memset(&ctx->devices[i], 0, sizeof(device_context_t));
    }
    ctx->num_devices = 0;
    
    while (fgets(line, sizeof(line), fp) && device_count < MAX_DEVICES) {
        line_num++;
        
        char* newline = strchr(line, '\n');
        if (newline) *newline = '\0';
        
        newline = strchr(line, '\r');
        if (newline) *newline = '\0';
        
        trim_whitespace(line);
        
        if (line[0] == '#' || line[0] == '\0') {
            continue;
        }
        
        if (line[0] == '[' && strchr(line, ']')) {
            char section[MAX_CONFIG_SECTION_NAME_LENGTH + 1];
            if (sscanf(line, "[%127[^]]]", section) == 1) {
                if (strncmp(section, "device=", 7) == 0) {
                    const char* device_name = section + 7;
                    
                    if (!is_valid_device_name(device_name)) {
                        log_message(ctx, "ERROR", "行 %d: 设备名无效: %s\n", 
                                   line_num, device_name);
                        continue;
                    }
                    
                    int dev_idx = -1;
                    for (int i = 0; i < device_count; i++) {
                        if (strcmp(ctx->devices[i].device, device_name) == 0) {
                            dev_idx = i;
                            break;
                        }
                    }
                    
                    if (dev_idx == -1) {
                        if (device_count >= MAX_DEVICES) {
                            log_message(ctx, "ERROR", "行 %d: 设备数量超过最大值 %d\n", 
                                       line_num, MAX_DEVICES);
                            continue;
                        }
                        dev_idx = device_count;
                        device_count++;
                        ctx->num_devices = device_count;
                    }
                    
                    current_dev = &ctx->devices[dev_idx];
                    safe_strncpy(current_dev->device, device_name, sizeof(current_dev->device));
                    current_dev->enabled = 1;
                    current_dev->owner_ctx = ctx;
                    
                    init_batch_commands(&current_dev->batch_cmds, BATCH_COMMAND_INITIAL_CAPACITY);
                    
                    current_dev->priority_policy.max_borrow_from_higher_priority = 0;
                    current_dev->priority_policy.allow_same_priority_borrow = 0;
                    current_dev->priority_policy.max_borrow_percentage = 100;
                    current_dev->priority_policy.min_lender_priority_gap = 1;
                    
                    pthread_mutex_init(&current_dev->tc_cache.cache_mutex, NULL);
                    
                    log_message(ctx, "DEBUG", "行 %d: 找到设备节: %s\n", line_num, device_name);
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
                        if (device_count >= MAX_DEVICES) {
                            log_message(ctx, "ERROR", "行 %d: 设备数量超过最大值 %d\n", 
                                       line_num, MAX_DEVICES);
                            continue;
                        }
                        dev_idx = device_count;
                        device_count++;
                        ctx->num_devices = device_count;
                    }
                    
                    current_dev = &ctx->devices[dev_idx];
                    safe_strncpy(current_dev->device, device_name, sizeof(current_dev->device));
                    current_dev->enabled = 1;
                    current_dev->owner_ctx = ctx;
                    
                    init_batch_commands(&current_dev->batch_cmds, BATCH_COMMAND_INITIAL_CAPACITY);
                    
                    current_dev->priority_policy.max_borrow_from_higher_priority = 0;
                    current_dev->priority_policy.allow_same_priority_borrow = 0;
                    current_dev->priority_policy.max_borrow_percentage = 100;
                    current_dev->priority_policy.min_lender_priority_gap = 1;
                    
                    pthread_mutex_init(&current_dev->tc_cache.cache_mutex, NULL);
                    
                    log_message(ctx, "DEBUG", "行 %d: 找到传统设备节: %s -> 设备: %s\n", 
                               line_num, section, device_name);
                } else {
                    current_dev = NULL;
                }
            }
            continue;
        }
        
        if (current_dev) {
            char key[MAX_CONFIG_KEY_LENGTH + 1];
            char value[MAX_CONFIG_VALUE_LENGTH + 1];
            
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
                } else if (strcmp(key, "adaptive_cache") == 0) {
                    current_dev->tc_cache.adaptive_enabled = atoi(value);
                } else if (strcmp(key, "adaptive_batch") == 0) {
                    current_dev->batch_cmds.adaptive_enabled = atoi(value);
                } else if (strcmp(key, "max_borrow_from_higher_priority") == 0) {
                    current_dev->priority_policy.max_borrow_from_higher_priority = atoi(value);
                } else if (strcmp(key, "allow_same_priority_borrow") == 0) {
                    current_dev->priority_policy.allow_same_priority_borrow = atoi(value);
                } else if (strcmp(key, "max_borrow_percentage") == 0) {
                    int percentage = atoi(value);
                    if (percentage >= 0 && percentage <= 100) {
                        current_dev->priority_policy.max_borrow_percentage = percentage;
                    }
                } else if (strcmp(key, "min_lender_priority_gap") == 0) {
                    int gap = atoi(value);
                    if (gap >= MIN_PRIORITY_GAP && gap <= MAX_PRIORITY_GAP) {
                        current_dev->priority_policy.min_lender_priority_gap = gap;
                    }
                } else if (strcmp(key, "algorithm") == 0) {
                    if (strcmp(value, "htb") == 0 || 
                        strcmp(value, "hfsc") == 0 || 
                        strcmp(value, "cake") == 0) {
                        safe_strncpy(current_dev->qdisc_kind, value, sizeof(current_dev->qdisc_kind));
                    } else {
                        log_message(ctx, "WARN", "行 %d: 不支持的算法: %s，使用默认算法\n", 
                                   line_num, value);
                    }
                } else if (strcmp(key, "hfsc_rsc_delay") == 0) {
                    /* HFSC RSC延迟参数，可在HFSC实现中使用 */
                } else if (strcmp(key, "hfsc_fsc_delay") == 0) {
                    /* HFSC FSC延迟参数，可在HFSC实现中使用 */
                } else if (strcmp(key, "hfsc_usc_delay") == 0) {
                    /* HFSC USC延迟参数，可在HFSC实现中使用 */
                }
            } 
            else {
                int classid = 0;
                char name[MAX_CLASS_NAME_LENGTH + 1];
                int priority = 0, total_bw_kbps = 0, min_bw_kbps = 0, max_bw_kbps = 0, dba_enabled = 1;
                
                qosdba_result_t parse_result = parse_config_line(line, line_num, 
                                                                 &classid, name, sizeof(name),
                                                                 &priority, &total_bw_kbps, 
                                                                 &min_bw_kbps, &max_bw_kbps, 
                                                                 &dba_enabled);
                
                if (parse_result == QOSDBA_OK) {
                    if (current_dev->num_classes >= MAX_CLASSES) {
                        log_message(ctx, "ERROR", "行 %d: 分类数量超过最大值 %d\n", 
                                   line_num, MAX_CLASSES);
                        continue;
                    }
                    
                    class_config_t* config = &current_dev->configs[current_dev->num_classes];
                    config->classid = classid;
                    safe_strncpy(config->name, name, sizeof(config->name));
                    config->priority = priority;
                    config->total_bw_kbps = total_bw_kbps;
                    config->min_bw_kbps = min_bw_kbps;
                    config->max_bw_kbps = max_bw_kbps;
                    config->dba_enabled = dba_enabled;
                    
                    current_dev->num_classes++;
                    
                    log_message(ctx, "DEBUG", "行 %d: 加载分类: ID=0x%x, 名称=%s, 优先级=%d, "
                              "总带宽=%dkbps, 最小=%dkbps, 最大=%dkbps, DBA=%s\n",
                              line_num, classid, name, priority, 
                              total_bw_kbps, min_bw_kbps, max_bw_kbps,
                              dba_enabled ? "启用" : "禁用");
                } else if (parse_result == QOSDBA_ERR_PARSING) {
                    log_message(ctx, "WARN", "行 %d: 无法解析分类配置行: %s\n", 
                               line_num, line);
                }
            }
        }
    }
    
    fclose(fp);
    
    if (ctx->num_devices == 0) {
        log_message(ctx, "ERROR", "配置文件中没有找到有效的设备配置\n");
        return QOSDBA_ERR_CONFIG;
    }
    
    for (int i = 0; i < ctx->num_devices; i++) {
        if (!validate_config_parameters(&ctx->devices[i])) {
            return QOSDBA_ERR_CONFIG;
        }
    }
    
    ctx->config_mtime = get_file_mtime(config_file);
    safe_strncpy(ctx->config_path, config_file, sizeof(ctx->config_path));
    
    return QOSDBA_OK;
}

/* ==================== TC分类发现 ==================== */
static qosdba_result_t discover_tc_classes(device_context_t* dev_ctx) {
    if (!dev_ctx) return QOSDBA_ERR_MEMORY;
    
    int discovered = 0;
    
    if (!is_valid_device_name(dev_ctx->device)) {
        log_device_message(dev_ctx, "ERROR", "设备名无效\n");
        return QOSDBA_ERR_INVALID;
    }
    
    int ifindex = get_ifindex(dev_ctx);
    if (ifindex <= 0) {
        log_device_message(dev_ctx, "ERROR", "无法获取设备接口索引\n");
        return QOSDBA_ERR_NETWORK;
    }
    
    struct rtnl_qdisc* qdisc = rtnl_qdisc_alloc();
    if (!qdisc) {
        return QOSDBA_ERR_MEMORY;
    }
    rtnl_tc_set_ifindex(TC_CAST(qdisc), ifindex);
    rtnl_tc_set_parent(TC_CAST(qdisc), TC_H_ROOT);
    
    NL_TIME_OPERATION_START(dev_ctx);
    int ret = rtnl_qdisc_get(&dev_ctx->rth, qdisc);
    NL_TIME_OPERATION_END(dev_ctx, ret);
    
    if (ret == 0) {
        const char* kind = rtnl_tc_get_kind(TC_CAST(qdisc));
        if (kind) {
            safe_strncpy(dev_ctx->qdisc_kind, kind, sizeof(dev_ctx->qdisc_kind));
        } else {
            strcpy(dev_ctx->qdisc_kind, "htb");
        }
    } else {
        strcpy(dev_ctx->qdisc_kind, "htb");
    }
    rtnl_qdisc_put(qdisc);
    
    struct nl_cache* cache = NULL;
    
    NL_TIME_OPERATION_START(dev_ctx);
    ret = rtnl_class_alloc_cache(&dev_ctx->rth, ifindex, &cache);
    NL_TIME_OPERATION_END(dev_ctx, ret);
    
    if (ret < 0) {
        log_device_message(dev_ctx, "DEBUG", "无法获取TC分类缓存，可能无分类\n");
        return QOSDBA_OK;
    }
    
    struct rtnl_class* class_obj = NULL;
    for (class_obj = (struct rtnl_class*)nl_cache_get_first(cache); 
         class_obj; 
         class_obj = (struct rtnl_class*)nl_cache_get_next((struct nl_object*)class_obj)) {
        
        if (rtnl_tc_get_ifindex(TC_CAST(class_obj)) != ifindex) {
            continue;
        }
        
        uint32_t handle = rtnl_tc_get_handle(TC_CAST(class_obj));
        if (handle == TC_H_ROOT) {
            continue;
        }
        
        int classid = handle;
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
                int major = TC_H_MAJ(handle) >> 16;
                int minor = TC_H_MIN(handle);
                snprintf(config->name, sizeof(config->name), 
                        "discovered-%d:%d", major, minor);
                config->priority = minor;
                config->total_bw_kbps = dev_ctx->total_bandwidth_kbps / 10;
                config->min_bw_kbps = 64;
                config->max_bw_kbps = dev_ctx->total_bandwidth_kbps / 5;
                config->dba_enabled = 1;
                
                dev_ctx->num_classes++;
                discovered++;
            }
        }
    }
    
    nl_cache_free(cache);
    
    if (discovered > 0) {
        log_device_message(dev_ctx, "INFO", "发现 %d 个新分类\n", discovered);
    }
    
    return QOSDBA_OK;
}

/* ==================== 更新TC统计缓存 ==================== */
static qosdba_result_t update_tc_cache(device_context_t* dev_ctx) {
    if (!dev_ctx) return QOSDBA_ERR_MEMORY;
    
    RESOURCE_COMPETITION_CHECK_START(dev_ctx);
    pthread_mutex_lock(&dev_ctx->tc_cache.cache_mutex);
    
    TIME_OPERATION_START(dev_ctx, cache_update_time_ms);
    
    int64_t now = get_current_time_ms();
    
    if (dev_ctx->tc_cache.valid && 
        (now - dev_ctx->tc_cache.last_query_time) < dev_ctx->tc_cache.query_interval_ms) {
        dev_ctx->perf_stats.cache_hits++;
        dev_ctx->tc_cache.access_count++;
        dev_ctx->tc_cache.last_access_time = now;
        TIME_OPERATION_END(dev_ctx, cache_update_time_ms);
        pthread_mutex_unlock(&dev_ctx->tc_cache.cache_mutex);
        return QOSDBA_OK;
    }
    
    int ifindex = get_ifindex(dev_ctx);
    if (ifindex <= 0) {
        TIME_OPERATION_END(dev_ctx, cache_update_time_ms);
        pthread_mutex_unlock(&dev_ctx->tc_cache.cache_mutex);
        return QOSDBA_ERR_NETWORK;
    }
    
    for (int i = 0; i < dev_ctx->tc_cache.num_cached_classes; i++) {
        if (dev_ctx->tc_cache.cached_classes[i]) {
            rtnl_class_put(dev_ctx->tc_cache.cached_classes[i]);
        }
    }
    dev_ctx->tc_cache.num_cached_classes = 0;
    
    struct nl_cache* cache = NULL;
    
    NL_TIME_OPERATION_START(dev_ctx);
    int ret = rtnl_class_alloc_cache(&dev_ctx->rth, ifindex, &cache);
    NL_TIME_OPERATION_END(dev_ctx, ret);
    
    if (ret < 0) {
        dev_ctx->tc_cache.valid = 0;
        dev_ctx->perf_stats.cache_misses++;
        TIME_OPERATION_END(dev_ctx, cache_update_time_ms);
        pthread_mutex_unlock(&dev_ctx->tc_cache.cache_mutex);
        return QOSDBA_ERR_TC;
    }
    
    struct rtnl_class* class_obj = NULL;
    for (class_obj = (struct rtnl_class*)nl_cache_get_first(cache); 
         class_obj && dev_ctx->tc_cache.num_cached_classes < MAX_CLASSES; 
         class_obj = (struct rtnl_class*)nl_cache_get_next((struct nl_object*)class_obj)) {
        
        if (rtnl_tc_get_ifindex(TC_CAST(class_obj)) != ifindex) {
            continue;
        }
        
        dev_ctx->tc_cache.cached_classes[dev_ctx->tc_cache.num_cached_classes] = 
            rtnl_class_clone(class_obj);
        if (dev_ctx->tc_cache.cached_classes[dev_ctx->tc_cache.num_cached_classes]) {
            dev_ctx->tc_cache.num_cached_classes++;
        }
    }
    
    nl_cache_free(cache);
    
    dev_ctx->tc_cache.last_query_time = now;
    dev_ctx->tc_cache.last_access_time = now;
    dev_ctx->tc_cache.access_count++;
    dev_ctx->tc_cache.valid = 1;
    
    if (dev_ctx->perf_stats.cache_hits + dev_ctx->perf_stats.cache_misses > 0) {
        dev_ctx->tc_cache.hit_rate = (float)dev_ctx->perf_stats.cache_hits * 100 / 
                                    (dev_ctx->perf_stats.cache_hits + dev_ctx->perf_stats.cache_misses);
    }
    
    if (dev_ctx->tc_cache.adaptive_enabled) {
        adjust_cache_interval(dev_ctx);
    }
    
    log_device_message(dev_ctx, "DEBUG", "TC统计缓存更新完成，缓存分类数: %d, 命中率: %.1f%%, 查询间隔: %dms\n", 
                      dev_ctx->tc_cache.num_cached_classes, dev_ctx->tc_cache.hit_rate,
                      dev_ctx->tc_cache.query_interval_ms);
    
    TIME_OPERATION_END(dev_ctx, cache_update_time_ms);
    pthread_mutex_unlock(&dev_ctx->tc_cache.cache_mutex);
    return QOSDBA_OK;
}

/* ==================== 自适应调整缓存间隔 ==================== */
static void adjust_cache_interval(device_context_t* dev_ctx) {
    if (!dev_ctx || !dev_ctx->tc_cache.adaptive_enabled) {
        return;
    }
    
    if (dev_ctx->perf_stats.cache_hits + dev_ctx->perf_stats.cache_misses < 100) {
        return;
    }
    
    float hit_rate = dev_ctx->tc_cache.hit_rate;
    
    FLOAT_COMPARISON_START(dev_ctx);
    if (hit_rate > 80.0f) {
        int new_interval = dev_ctx->tc_cache.query_interval_ms + 1000;
        if (new_interval > CACHE_MAX_INTERVAL_MS) {
            new_interval = CACHE_MAX_INTERVAL_MS;
        }
        dev_ctx->tc_cache.query_interval_ms = new_interval;
        log_device_message(dev_ctx, "DEBUG", "缓存命中率高(%.1f%%), 延长查询间隔到 %dms\n", 
                          hit_rate, new_interval);
    } else if (hit_rate < 50.0f) {
        int new_interval = dev_ctx->tc_cache.query_interval_ms - 1000;
        if (new_interval < CACHE_MIN_INTERVAL_MS) {
            new_interval = CACHE_MIN_INTERVAL_MS;
        }
        dev_ctx->tc_cache.query_interval_ms = new_interval;
        log_device_message(dev_ctx, "DEBUG", "缓存命中率低(%.1f%%), 缩短查询间隔到 %dms\n", 
                          hit_rate, new_interval);
    }
}

/* ==================== 从缓存中解析分类统计 ==================== */
static int parse_class_stats_from_cache(device_context_t* dev_ctx, int classid, uint64_t* bytes) {
    if (!dev_ctx || !bytes || !dev_ctx->tc_cache.valid) {
        if (dev_ctx) dev_ctx->perf_stats.cache_misses++;
        return 0;
    }
    
    RESOURCE_COMPETITION_CHECK_START(dev_ctx);
    pthread_mutex_lock(&dev_ctx->tc_cache.cache_mutex);
    
    dev_ctx->tc_cache.access_count++;
    dev_ctx->tc_cache.last_access_time = get_current_time_ms();
    
    for (int i = 0; i < dev_ctx->tc_cache.num_cached_classes; i++) {
        struct rtnl_class* class_obj = dev_ctx->tc_cache.cached_classes[i];
        if (!class_obj) continue;
        
        uint32_t handle = rtnl_tc_get_handle(TC_CAST(class_obj));
        if (handle == classid) {
            if (qosdba_parse_class_stats(class_obj, bytes, NULL) == 0) {
                dev_ctx->perf_stats.cache_hits++;
                pthread_mutex_unlock(&dev_ctx->tc_cache.cache_mutex);
                return 1;
            }
        }
    }
    
    dev_ctx->perf_stats.cache_misses++;
    pthread_mutex_unlock(&dev_ctx->tc_cache.cache_mutex);
    return 0;
}

/* ==================== 检查带宽使用率 ==================== */
static qosdba_result_t check_bandwidth_usage(device_context_t* dev_ctx) {
    if (!dev_ctx || dev_ctx->num_classes == 0) return QOSDBA_ERR_MEMORY;
    
    TIME_OPERATION_START(dev_ctx, check_usage_time_ms);
    int64_t now = get_current_time_ms();
    
    qosdba_result_t cache_ret = update_tc_cache(dev_ctx);
    if (cache_ret != QOSDBA_OK) {
        log_device_message(dev_ctx, "WARN", "TC统计缓存更新失败\n");
    }
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_state_t* state = &dev_ctx->states[i];
        
        if (!state->dba_enabled) {
            continue;
        }
        
        class_config_t* config = &dev_ctx->configs[i];
        
        uint64_t bytes = 0;
        int got_stats = 0;
        
        if (dev_ctx->tc_cache.valid) {
            got_stats = parse_class_stats_from_cache(dev_ctx, state->classid, &bytes);
        }
        
        if (!got_stats) {
            int ifindex = get_ifindex(dev_ctx);
            if (ifindex > 0) {
                struct rtnl_class* class_obj = rtnl_class_alloc();
                if (class_obj) {
                    rtnl_tc_set_ifindex(TC_CAST(class_obj), ifindex);
                    rtnl_tc_set_handle(TC_CAST(class_obj), state->classid);
                    
                    NL_TIME_OPERATION_START(dev_ctx);
                    int ret = rtnl_class_get(&dev_ctx->rth, class_obj);
                    NL_TIME_OPERATION_END(dev_ctx, ret);
                    
                    if (ret == 0) {
                        uint64_t tmp_bytes = 0;
                        if (qosdba_parse_class_stats(class_obj, &tmp_bytes, NULL) == 0) {
                            bytes = tmp_bytes;
                            got_stats = 1;
                        }
                    } else if (ret < 0) {
                        log_tc_error(dev_ctx, ret, "获取分类统计", state->classid);
                    }
                    rtnl_class_put(class_obj);
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
        
        FLOAT_COMPARISON_START(dev_ctx);
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
    
    TIME_OPERATION_END(dev_ctx, check_usage_time_ms);
    return QOSDBA_OK;
}

/* ==================== 查找分类 ==================== */
static int find_class_by_id(device_context_t* dev_ctx, int classid) {
    if (!dev_ctx || dev_ctx->num_classes <= 0 || 
        dev_ctx->num_classes > MAX_CLASSES) {
        return -1;
    }
    
    BOUNDARY_CHECK_START(dev_ctx);
    
    for (int i = 0; i < dev_ctx->num_classes && i < MAX_CLASSES; i++) {
        if (dev_ctx->states[i].classid == classid) {
            return i;
        }
    }
    
    return -1;
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
        
        if (!state->dba_enabled) {
            continue;
        }
        
        if (!dev_ctx->priority_policy.allow_same_priority_borrow && 
            config->priority == borrower_priority) {
            continue;
        }
        
        if (config->priority <= borrower_priority) {
            continue;
        }
        
        if (dev_ctx->priority_policy.max_borrow_from_higher_priority &&
            (config->priority - borrower_priority) > dev_ctx->priority_policy.min_lender_priority_gap) {
            continue;
        }
        
        FLOAT_COMPARISON_START(dev_ctx);
        if (state->utilization * 100 < dev_ctx->low_util_threshold &&
            state->low_util_duration >= dev_ctx->low_util_duration) {
            
            int available_bw = state->current_bw_kbps - state->used_bw_kbps;
            int max_borrow = state->current_bw_kbps - config->min_bw_kbps;
            
            if (dev_ctx->priority_policy.max_borrow_percentage < 100) {
                int max_allowed_borrow = state->current_bw_kbps * 
                                       dev_ctx->priority_policy.max_borrow_percentage / 100;
                if (max_borrow > max_allowed_borrow) {
                    max_borrow = max_allowed_borrow;
                }
            }
            
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
    
    dev_ctx->perf_stats.cross_class_interactions++;
    
    log_device_message(dev_ctx, "INFO", "添加借用记录: 从 0x%x 借给 0x%x: %d kbps\n",
                      from_classid, to_classid, borrowed_bw_kbps);
}

/* ==================== 初始化批量命令 ==================== */
static void init_batch_commands(batch_commands_t* batch, int initial_capacity) {
    if (!batch) return;
    
    batch->classes = (struct rtnl_class**)aligned_malloc(initial_capacity * sizeof(struct rtnl_class*), DEFAULT_ALIGNMENT);
    batch->capacity = initial_capacity;
    batch->max_commands = initial_capacity;
    batch->command_count = 0;
    batch->avg_batch_size = 0.0f;
    batch->last_adjust_time = 0;
    batch->adjustment_count = 0;
    batch->adaptive_enabled = 1;
    
    batch->pool = create_memory_pool(MEMORY_POOL_BLOCK_SIZE, MAX_MEMORY_POOL_BLOCKS);
}

/* ==================== 调整批量命令容量 ==================== */
static void resize_batch_commands(batch_commands_t* batch, int new_capacity) {
    if (!batch || new_capacity <= batch->capacity) return;
    
    if (new_capacity > BATCH_COMMAND_MAX_CAPACITY) {
        new_capacity = BATCH_COMMAND_MAX_CAPACITY;
    }
    
    struct rtnl_class** new_classes = (struct rtnl_class**)aligned_realloc(
        batch->classes, new_capacity * sizeof(struct rtnl_class*), DEFAULT_ALIGNMENT);
    if (new_classes) {
        batch->classes = new_classes;
        batch->capacity = new_capacity;
        batch->max_commands = new_capacity;
        batch->adjustment_count++;
    }
}

/* ==================== 清理批量命令 ==================== */
static void cleanup_batch_commands(batch_commands_t* batch) {
    if (!batch) return;
    
    for (int i = 0; i < batch->command_count; i++) {
        if (batch->classes[i]) {
            rtnl_class_put(batch->classes[i]);
        }
    }
    batch->command_count = 0;
    
    if (batch->classes) {
        aligned_free(batch->classes);
        batch->classes = NULL;
    }
    batch->capacity = 0;
    batch->max_commands = 0;
    batch->avg_batch_size = 0.0f;
    batch->last_adjust_time = 0;
    batch->adjustment_count = 0;
    
    cleanup_memory_pools(NULL);
}

/* ==================== 自适应调整批量大小 ==================== */
static void adjust_batch_size(device_context_t* dev_ctx) {
    if (!dev_ctx || !dev_ctx->batch_cmds.adaptive_enabled) {
        return;
    }
    
    batch_commands_t* batch = &dev_ctx->batch_cmds;
    
    if (dev_ctx->perf_stats.batch_executions < 10) {
        return;
    }
    
    FLOAT_COMPARISON_START(dev_ctx);
    float avg_batch_size = (float)dev_ctx->perf_stats.total_batch_commands / 
                          dev_ctx->perf_stats.batch_executions;
    
    batch->avg_batch_size = avg_batch_size;
    
    int64_t now = get_current_time_ms();
    if (batch->last_adjust_time > 0 && (now - batch->last_adjust_time) < 30000) {
        return;
    }
    
    if (avg_batch_size > batch->capacity * 0.8f) {
        int new_capacity = batch->capacity * 2;
        if (new_capacity > BATCH_COMMAND_MAX_CAPACITY) {
            new_capacity = BATCH_COMMAND_MAX_CAPACITY;
        }
        resize_batch_commands(batch, new_capacity);
        batch->last_adjust_time = now;
        log_device_message(dev_ctx, "DEBUG", "批量大小自适应: 平均 %.1f, 扩容到 %d\n", 
                          avg_batch_size, new_capacity);
    }
    else if (avg_batch_size < batch->capacity * 0.3f && 
             batch->capacity > BATCH_COMMAND_INITIAL_CAPACITY) {
        int new_capacity = batch->capacity / 2;
        if (new_capacity < BATCH_COMMAND_INITIAL_CAPACITY) {
            new_capacity = BATCH_COMMAND_INITIAL_CAPACITY;
        }
        resize_batch_commands(batch, new_capacity);
        batch->last_adjust_time = now;
        log_device_message(dev_ctx, "DEBUG", "批量大小自适应: 平均 %.1f, 缩容到 %d\n", 
                          avg_batch_size, new_capacity);
    }
}

/* ==================== 添加到批量命令 ==================== */
static void add_to_batch_commands(batch_commands_t* batch, struct rtnl_class* class_obj) {
    if (!batch || !class_obj) {
        if (class_obj) {
            rtnl_class_put(class_obj);
        }
        return;
    }
    
    if (batch->command_count >= batch->capacity) {
        int new_capacity = batch->capacity * 2;
        if (new_capacity > BATCH_COMMAND_MAX_CAPACITY) {
            new_capacity = BATCH_COMMAND_MAX_CAPACITY;
        }
        
        if (new_capacity > batch->capacity) {
            resize_batch_commands(batch, new_capacity);
        }
    }
    
    if (batch->command_count >= batch->capacity) {
        rtnl_class_put(class_obj);
        return;
    }
    
    batch->classes[batch->command_count] = class_obj;
    batch->command_count++;
}

/* ==================== 执行批量命令 ==================== */
static qosdba_result_t execute_batch_commands(batch_commands_t* batch, device_context_t* dev_ctx, qosdba_context_t* ctx) {
    if (!batch || !dev_ctx || !ctx || batch->command_count == 0) {
        return QOSDBA_OK;
    }
    
    TIME_OPERATION_START(dev_ctx, batch_execute_time_ms);
    
    dev_ctx->perf_stats.batch_executions++;
    dev_ctx->perf_stats.total_batch_commands += batch->command_count;
    
    if (ctx->safe_mode) {
        for (int i = 0; i < batch->command_count; i++) {
            uint32_t handle = rtnl_tc_get_handle(TC_CAST(batch->classes[i]));
            log_device_message(dev_ctx, "DEBUG", "[安全模式] 批量命令 %d: 修改分类 0x%x\n", i+1, handle);
            rtnl_class_put(batch->classes[i]);
        }
        batch->command_count = 0;
        TIME_OPERATION_END(dev_ctx, batch_execute_time_ms);
        return QOSDBA_OK;
    }
    
    int success_count = 0;
    int fail_count = 0;
    
    for (int i = 0; i < batch->command_count; i++) {
        NL_TIME_OPERATION_START(dev_ctx);
        int ret = rtnl_class_change(&dev_ctx->rth, batch->classes[i], 0);
        NL_TIME_OPERATION_END(dev_ctx, ret);
        
        if (ret < 0) {
            uint32_t handle = rtnl_tc_get_handle(TC_CAST(batch->classes[i]));
            log_tc_error(dev_ctx, ret, "批量命令执行", handle);
            
            TC_ERROR_HANDLING_START(dev_ctx);
            if (is_tc_error_fatal(ret)) {
                log_device_message(dev_ctx, "ERROR", "致命错误，停止执行剩余批量命令\n");
                for (int j = i; j < batch->command_count; j++) {
                    rtnl_class_put(batch->classes[j]);
                }
                batch->command_count = 0;
                TIME_OPERATION_END(dev_ctx, batch_execute_time_ms);
                return map_tc_error_to_qosdba(ret);
            }
            fail_count++;
        } else {
            success_count++;
        }
        
        rtnl_class_put(batch->classes[i]);
    }
    
    batch->command_count = 0;
    
    if (fail_count > 0) {
        log_device_message(dev_ctx, "WARN", "批量命令执行结果: 成功 %d, 失败 %d\n", success_count, fail_count);
    }
    
    if (dev_ctx->batch_cmds.adaptive_enabled) {
        adjust_batch_size(dev_ctx);
    }
    
    TIME_OPERATION_END(dev_ctx, batch_execute_time_ms);
    return (fail_count > 0) ? QOSDBA_ERR_TC : QOSDBA_OK;
}

/* ==================== 带重试的网络链路操作 ==================== */
static int nl_get_class_operation(device_context_t* dev_ctx, void* arg) {
    struct rtnl_class* class_obj = (struct rtnl_class*)arg;
    return rtnl_class_get(&dev_ctx->rth, class_obj);
}

static int nl_change_class_operation(device_context_t* dev_ctx, void* arg) {
    struct rtnl_class* class_obj = (struct rtnl_class*)arg;
    return rtnl_class_change(&dev_ctx->rth, class_obj, 0);
}

static int nl_add_class_operation(device_context_t* dev_ctx, void* arg) {
    struct rtnl_class* class_obj = (struct rtnl_class*)arg;
    return rtnl_class_add(&dev_ctx->rth, class_obj, NLM_F_CREATE);
}

/* ==================== 重试机制 ==================== */
static qosdba_result_t retry_with_backoff(device_context_t* dev_ctx,
                                         nl_operation_func func,
                                         void* arg,
                                         int max_retries,
                                         int base_delay_ms) {
    int retry_delay_ms = base_delay_ms;
    
    for (int i = 0; i < max_retries; i++) {
        dev_ctx->perf_stats.retry_attempts++;
        
        NL_TIME_OPERATION_START(dev_ctx);
        int ret = func(dev_ctx, arg);
        NL_TIME_OPERATION_END(dev_ctx, ret);
        
        if (ret >= 0) {
            if (i > 0) {
                dev_ctx->perf_stats.retry_success++;
                log_device_message(dev_ctx, "INFO", "重试成功 (第 %d 次重试)\n", i);
            }
            return QOSDBA_OK;
        }
        
        if (ret == -ENETDOWN || ret == -ENODEV) {
            log_device_message(dev_ctx, "WARN", "网络连接问题，尝试重新连接 (尝试 %d/%d)\n", 
                             i+1, max_retries);
            
            close_device_netlink(dev_ctx, dev_ctx->owner_ctx);
            usleep(retry_delay_ms * 1000);
            
            if (open_device_netlink(dev_ctx, dev_ctx->owner_ctx) != QOSDBA_OK) {
                retry_delay_ms *= 2;
                if (retry_delay_ms > MAX_RETRY_DELAY_MS) {
                    retry_delay_ms = MAX_RETRY_DELAY_MS;
                }
                continue;
            }
        } else if (ret == -EAGAIN || ret == -EWOULDBLOCK) {
            log_device_message(dev_ctx, "DEBUG", "资源暂时不可用，%dms后重试 (尝试 %d/%d)\n", 
                             retry_delay_ms, i+1, max_retries);
            usleep(retry_delay_ms * 1000);
            retry_delay_ms *= 2;
            if (retry_delay_ms > MAX_RETRY_DELAY_MS) {
                retry_delay_ms = MAX_RETRY_DELAY_MS;
            }
        } else if (is_tc_error_fatal(ret)) {
            log_device_message(dev_ctx, "ERROR", "致命错误，不重试: %s\n", 
                             get_tc_error_description(ret));
            dev_ctx->perf_stats.retry_failures++;
            break;
        } else {
            log_device_message(dev_ctx, "ERROR", "操作失败，错误码: %d, 描述: %s, 不重试\n", 
                             -ret, get_tc_error_description(ret));
            dev_ctx->perf_stats.retry_failures++;
            break;
        }
    }
    
    return QOSDBA_ERR_TC;
}

/* ==================== 增强的网络链路操作 ==================== */
static qosdba_result_t resilient_nl_operation(device_context_t* dev_ctx, 
                                              nl_operation_func func, 
                                              void* arg) {
    return retry_with_backoff(dev_ctx, func, arg, MAX_RETRY_ATTEMPTS, RETRY_BASE_DELAY_MS);
}

/* ==================== 配置检查重新加载 ==================== */
static int check_config_reload(qosdba_context_t* ctx, const char* config_file) {
    int mtime = get_file_mtime(config_file);
    if (mtime > ctx->config_mtime) {
        log_message(ctx, "INFO", "配置文件已修改，触发重载\n");
        return 1;
    }
    return 0;
}

static qosdba_result_t reload_config(qosdba_context_t* ctx, const char* config_file) {
    qosdba_result_t ret = reload_config_atomic(ctx, config_file);
    if (ret == QOSDBA_OK) {
        log_message(ctx, "INFO", "配置文件重载成功\n");
    } else {
        log_message(ctx, "ERROR", "配置文件重载失败: %d\n", ret);
    }
    return ret;
}

static qosdba_result_t reload_config_atomic(qosdba_context_t* ctx, const char* config_file) {
    device_context_t new_devices[MAX_DEVICES];
    int new_num_devices = 0;
    
    memset(new_devices, 0, sizeof(new_devices));
    
    qosdba_context_t tmp_ctx = *ctx;
    tmp_ctx.devices = new_devices;
    tmp_ctx.num_devices = 0;
    
    qosdba_result_t ret = load_config_file(&tmp_ctx, config_file);
    if (ret != QOSDBA_OK) {
        return ret;
    }
    
    new_num_devices = tmp_ctx.num_devices;
    
    for (int i = 0; i < ctx->num_devices; i++) {
        cleanup_batch_commands(&ctx->devices[i].batch_cmds);
        close_device_netlink(&ctx->devices[i], ctx);
    }
    
    memcpy(ctx->devices, new_devices, sizeof(device_context_t) * new_num_devices);
    ctx->num_devices = new_num_devices;
    
    for (int i = 0; i < ctx->num_devices; i++) {
        if (ctx->devices[i].enabled) {
            open_device_netlink(&ctx->devices[i], ctx);
        }
    }
    
    ctx->config_mtime = get_file_mtime(config_file);
    
    return QOSDBA_OK;
}

/* ==================== 异步监控初始化 ==================== */
static qosdba_result_t init_async_monitor(device_context_t* dev_ctx) {
    if (!dev_ctx) return QOSDBA_ERR_MEMORY;
    
    dev_ctx->async_monitor.epoll_fd = epoll_create1(0);
    if (dev_ctx->async_monitor.epoll_fd < 0) {
        log_device_message(dev_ctx, "ERROR", "创建epoll失败: %s\n", strerror(errno));
        return QOSDBA_ERR_SYSTEM;
    }
    
    dev_ctx->async_monitor.inotify_fd = inotify_init1(IN_NONBLOCK);
    if (dev_ctx->async_monitor.inotify_fd < 0) {
        log_device_message(dev_ctx, "WARN", "创建inotify失败，回退到轮询模式: %s\n", strerror(errno));
        dev_ctx->async_monitor.async_enabled = 0;
        return QOSDBA_OK;
    }
    
    char stat_path[MAX_PATH_LENGTH + 1];
    snprintf(stat_path, sizeof(stat_path), "/sys/class/net/%s/statistics/tx_bytes", dev_ctx->device);
    
    dev_ctx->async_monitor.watch_fd = inotify_add_watch(dev_ctx->async_monitor.inotify_fd, 
                                                       stat_path, IN_MODIFY);
    if (dev_ctx->async_monitor.watch_fd < 0) {
        log_device_message(dev_ctx, "WARN", "添加inotify监视失败: %s\n", strerror(errno));
        dev_ctx->async_monitor.async_enabled = 0;
        return QOSDBA_OK;
    }
    
    struct epoll_event ev;
    ev.events = EPOLLIN;
    ev.data.fd = dev_ctx->async_monitor.inotify_fd;
    
    if (epoll_ctl(dev_ctx->async_monitor.epoll_fd, EPOLL_CTL_ADD, 
                  dev_ctx->async_monitor.inotify_fd, &ev) < 0) {
        log_device_message(dev_ctx, "WARN", "添加inotify到epoll失败: %s\n", strerror(errno));
        dev_ctx->async_monitor.async_enabled = 0;
        return QOSDBA_OK;
    }
    
    dev_ctx->async_monitor.async_enabled = 1;
    dev_ctx->async_monitor.last_async_check = 0;
    
    log_device_message(dev_ctx, "DEBUG", "异步监控初始化完成\n");
    
    return QOSDBA_OK;
}

/* ==================== 检查异步事件 ==================== */
static int check_async_events(device_context_t* dev_ctx) {
    if (!dev_ctx || !dev_ctx->async_monitor.async_enabled) {
        return 0;
    }
    
    struct epoll_event events[MAX_EPOLL_EVENTS];
    int nfds = epoll_wait(dev_ctx->async_monitor.epoll_fd, events, 
                         MAX_EPOLL_EVENTS, 0);
    
    if (nfds < 0) {
        if (errno != EINTR) {
            log_device_message(dev_ctx, "ERROR", "epoll_wait失败: %s\n", strerror(errno));
        }
        return 0;
    }
    
    for (int i = 0; i < nfds; i++) {
        if (events[i].data.fd == dev_ctx->async_monitor.inotify_fd) {
            char buffer[MAX_INOTIFY_BUFFER_SIZE];
            int len = read(dev_ctx->async_monitor.inotify_fd, buffer, sizeof(buffer));
            if (len > 0) {
                dev_ctx->async_monitor.last_async_check = get_current_time_ms();
                return 1;
            }
        }
    }
    
    return 0;
}

/* ==================== 状态更新函数 ==================== */
qosdba_result_t qosdba_update_status(qosdba_context_t* ctx, const char* status_file) {
    if (!ctx) return QOSDBA_ERR_MEMORY;
    
    if (!status_file) {
        ctx->status_file = NULL;
        return QOSDBA_OK;
    }
    
    FILE* file = fopen(status_file, "w");
    if (!file) {
        return QOSDBA_ERR_FILE;
    }
    
    ctx->status_file = file;
    
    fprintf(ctx->status_file, "=== QoS动态带宽分配器状态 (DBA 2.0) ===\n");
    fprintf(ctx->status_file, "版本: %s\n", QOSDBA_VERSION);
    fprintf(ctx->status_file, "运行时间: %ld 秒\n", (get_current_time_ms() - ctx->start_time) / 1000);
    fprintf(ctx->status_file, "配置文件: %s\n", ctx->config_path);
    fprintf(ctx->status_file, "检查间隔: %d 秒\n", ctx->check_interval);
    fprintf(ctx->status_file, "安全模式: %s\n", ctx->safe_mode ? "启用" : "禁用");
    fprintf(ctx->status_file, "调试模式: %s\n", ctx->debug_mode ? "启用" : "禁用");
    fprintf(ctx->status_file, "\n");
    
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        if (!dev_ctx->enabled) continue;
        
        const qos_algorithm_ops_t* ops = get_algorithm_ops(dev_ctx->qdisc_kind);
        
        fprintf(ctx->status_file, "=== 设备 %s 状态 ===\n", dev_ctx->device);
        fprintf(ctx->status_file, "算法: %s\n", ops->name);
        fprintf(ctx->status_file, "qdisc_kind: %s\n", dev_ctx->qdisc_kind);
        fprintf(ctx->status_file, "总带宽: %d kbps\n", dev_ctx->total_bandwidth_kbps);
        fprintf(ctx->status_file, "高使用率阈值: %d%%\n", dev_ctx->high_util_threshold);
        fprintf(ctx->status_file, "低使用率阈值: %d%%\n", dev_ctx->low_util_threshold);
        fprintf(ctx->status_file, "借用比例: %.2f\n", dev_ctx->borrow_ratio);
        fprintf(ctx->status_file, "自动归还: %s\n", dev_ctx->auto_return_enable ? "启用" : "禁用");
        fprintf(ctx->status_file, "借用事件: %d\n", dev_ctx->total_borrow_events);
        fprintf(ctx->status_file, "归还事件: %d\n", dev_ctx->total_return_events);
        fprintf(ctx->status_file, "总借用带宽: %ld kbps\n", dev_ctx->total_borrowed_kbps);
        fprintf(ctx->status_file, "总归还带宽: %ld kbps\n", dev_ctx->total_returned_kbps);
        
        /* 添加算法特定信息 */
        if (strcmp(ops->name, "hfsc") == 0) {
            fprintf(ctx->status_file, "HFSC特性: 支持实时服务曲线(RSC), 链接共享曲线(FSC), 上限曲线(USC)\n");
        } else if (strcmp(ops->name, "htb") == 0) {
            fprintf(ctx->status_file, "HTB特性: 层次令牌桶, 支持优先级和借用\n");
        }
        
        fprintf(ctx->status_file, "\n分类状态:\n");
        fprintf(ctx->status_file, "%-10s %-20s %-8s %-8s %-8s %-8s %-8s %-8s\n",
               "ID", "名称", "当前(kbps)", "使用(kbps)", "利用率", "借用", "借出", "DBA");
        
        for (int j = 0; j < dev_ctx->num_classes; j++) {
            class_state_t* state = &dev_ctx->states[j];
            class_config_t* config = &dev_ctx->configs[j];
            
            if (!state->dba_enabled) {
                fprintf(ctx->status_file, "0x%08x %-20s %-8d %-8d %-7.1f%% 不参与DBA\n",
                       config->classid, config->name, 
                       state->current_bw_kbps, state->used_bw_kbps,
                       state->utilization * 100);
            } else {
                fprintf(ctx->status_file, "0x%08x %-20s %-8d %-8d %-7.1f%% %-8d %-8d %s\n",
                       config->classid, config->name, 
                       state->current_bw_kbps, state->used_bw_kbps,
                       state->utilization * 100,
                       state->borrowed_bw_kbps, state->lent_bw_kbps,
                       "启用");
            }
        }
        
        fprintf(ctx->status_file, "\n性能统计:\n");
        fprintf(ctx->status_file, "NL操作: %ld 次, 平均延迟: %.2f ms\n", 
                dev_ctx->perf_stats.total_nl_operations,
                dev_ctx->perf_stats.total_nl_operations > 0 ? 
                (float)dev_ctx->perf_stats.total_nl_time_ms / dev_ctx->perf_stats.total_nl_operations : 0.0f);
        fprintf(ctx->status_file, "缓存命中率: %.1f%%\n", dev_ctx->tc_cache.hit_rate);
        fprintf(ctx->status_file, "批量执行: %ld 次, 平均批量大小: %.1f\n", 
                dev_ctx->perf_stats.batch_executions,
                dev_ctx->batch_cmds.avg_batch_size);
        fprintf(ctx->status_file, "成功借用: %ld 次, 失败借用: %ld 次\n", 
                dev_ctx->perf_stats.successful_borrows,
                dev_ctx->perf_stats.failed_borrows);
        fprintf(ctx->status_file, "成功归还: %ld 次, 失败归还: %ld 次\n", 
                dev_ctx->perf_stats.successful_returns,
                dev_ctx->perf_stats.failed_returns);
        
        if (strcmp(ops->name, "hfsc") == 0) {
            fprintf(ctx->status_file, "HFSC调整: %ld 次, 平均延迟: %.2f ms\n", 
                    dev_ctx->perf_stats.hfsc_adjustments,
                    dev_ctx->perf_stats.hfsc_latency_ms);
        }
        
        fprintf(ctx->status_file, "\n");
    }
    
    fprintf(ctx->status_file, "=== 全局统计 ===\n");
    fprintf(ctx->status_file, "总NL操作: %ld 次\n", 
            ctx->num_devices > 0 ? ctx->devices[0].perf_stats.total_nl_operations : 0);
    
    fflush(ctx->status_file);
    
    return QOSDBA_OK;
}

/* ==================== 健康检查 ==================== */
qosdba_result_t qosdba_health_check(qosdba_context_t* ctx) {
    if (!ctx) return QOSDBA_ERR_MEMORY;
    
    HEALTH_CHECK_START(NULL);
    
    int healthy = 1;
    
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        if (!dev_ctx->enabled) continue;
        
        int ifindex = get_ifindex(dev_ctx);
        if (ifindex <= 0) {
            log_device_message(dev_ctx, "ERROR", "健康检查失败: 设备不可用\n");
            healthy = 0;
            continue;
        }
        
        int64_t now = get_current_time_ms();
        if ((now - dev_ctx->tc_cache.last_query_time) > 30000) {
            log_device_message(dev_ctx, "WARN", "健康检查: TC缓存长时间未更新\n");
        }
        
        if (dev_ctx->perf_stats.nl_errors > 100) {
            log_device_message(dev_ctx, "WARN", "健康检查: NL错误过多 (%d)\n", 
                              dev_ctx->perf_stats.nl_errors);
        }
    }
    
    if (healthy) {
        return QOSDBA_OK;
    } else {
        return QOSDBA_ERR_HEALTH;
    }
}

/* ==================== 主初始化函数 ==================== */
qosdba_result_t qosdba_init(qosdba_context_t* ctx) {
    if (!ctx) return QOSDBA_ERR_MEMORY;
    
    memset(ctx, 0, sizeof(qosdba_context_t));
    
    ctx->enabled = 1;
    ctx->debug_mode = 0;
    ctx->safe_mode = 0;
    ctx->reload_config = 0;
    ctx->num_devices = 0;
    ctx->check_interval = DEFAULT_CHECK_INTERVAL;
    ctx->start_time = get_current_time_ms();
    ctx->config_mtime = 0;
    ctx->last_check_time = 0;
    ctx->status_file = NULL;
    ctx->log_file = NULL;
    ctx->shared_rth.fd = -1;
    ctx->shared_rth_refcount = 0;
    
    pthread_mutex_init(&ctx->rth_mutex, NULL);
    pthread_spin_init(&ctx->ctx_lock, PTHREAD_PROCESS_PRIVATE);
    
    atomic_init(&ctx->should_exit, 0);
    atomic_init(&ctx->reload_requested, 0);
    
    ctx->new_devices = NULL;
    ctx->new_num_devices = 0;
    
    init_signal_queue(&ctx->signal_queue);
    init_aligned_memory_manager(&ctx->aligned_memory);
    init_float_tolerance(&ctx->float_tolerance);
    
    setup_signal_handlers();
    
    return QOSDBA_OK;
}

/* ==================== 设置调试模式 ==================== */
void qosdba_set_debug(qosdba_context_t* ctx, int enable) {
    if (ctx) {
        ctx->debug_mode = enable;
    }
}

/* ==================== 设置安全模式 ==================== */
void qosdba_set_safe_mode(qosdba_context_t* ctx, int enable) {
    if (ctx) {
        ctx->safe_mode = enable;
    }
}

/* ==================== 主运行循环 ==================== */
qosdba_result_t qosdba_run(qosdba_context_t* ctx) {
    if (!ctx || !ctx->enabled) {
        return QOSDBA_ERR_MEMORY;
    }
    
    log_message(ctx, "INFO", "QoS动态带宽分配器 (DBA 2.0) 启动\n");
    log_message(ctx, "INFO", "版本: %s\n", QOSDBA_VERSION);
    
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        if (!dev_ctx->enabled) continue;
        
        log_device_message(dev_ctx, "INFO", "初始化设备\n");
        
        qosdba_result_t ret = open_device_netlink(dev_ctx, ctx);
        if (ret != QOSDBA_OK) {
            log_device_message(dev_ctx, "ERROR", "打开网络链接失败\n");
            dev_ctx->enabled = 0;
            continue;
        }
        
        if (strlen(dev_ctx->qdisc_kind) == 0) {
            algorithm_detection_t detection;
            if (detect_algorithm(dev_ctx, &detection)) {
                safe_strncpy(dev_ctx->qdisc_kind, detection.qdisc_kind, sizeof(dev_ctx->qdisc_kind));
                log_device_message(dev_ctx, "INFO", "检测到算法: %s\n", dev_ctx->qdisc_kind);
            } else {
                strcpy(dev_ctx->qdisc_kind, "htb");
                log_device_message(dev_ctx, "WARN", "算法检测失败，使用默认HTB算法\n");
            }
        }
        
        const qos_algorithm_ops_t* ops = get_algorithm_ops(dev_ctx->qdisc_kind);
        log_device_message(dev_ctx, "INFO", "使用算法: %s\n", ops->name);
        
        discover_tc_classes(dev_ctx);
        
        ret = init_tc_classes(dev_ctx, ctx);
        if (ret != QOSDBA_OK) {
            log_device_message(dev_ctx, "ERROR", "TC分类初始化失败\n");
            dev_ctx->enabled = 0;
            continue;
        }
        
        init_async_monitor(dev_ctx);
    }
    
    ctx->last_check_time = get_current_time_ms();
    
    while (!atomic_load(&ctx->should_exit)) {
        int64_t now = get_current_time_ms();
        
        if (atomic_load(&ctx->reload_requested)) {
            atomic_store(&ctx->reload_requested, 0);
            reload_config(ctx, ctx->config_path);
        }
        
        if (check_config_reload(ctx, ctx->config_path)) {
            reload_config(ctx, ctx->config_path);
        }
        
        int sig = dequeue_signal(&ctx->signal_queue);
        if (sig == SIGHUP) {
            log_message(ctx, "INFO", "接收到SIGHUP信号，重新加载配置\n");
            reload_config(ctx, ctx->config_path);
        } else if (sig == SIGTERM || sig == SIGINT || sig == SIGQUIT) {
            log_message(ctx, "INFO", "接收到终止信号，准备退出\n");
            break;
        }
        
        for (int i = 0; i < ctx->num_devices; i++) {
            device_context_t* dev_ctx = &ctx->devices[i];
            
            if (!dev_ctx->enabled) continue;
            
            if (dev_ctx->async_monitor.async_enabled) {
                if (check_async_events(dev_ctx)) {
                    check_bandwidth_usage(dev_ctx);
                    run_borrow_logic(dev_ctx, ctx);
                    run_return_logic(dev_ctx, ctx);
                }
            } else if ((now - ctx->last_check_time) >= ctx->check_interval * 1000) {
                check_bandwidth_usage(dev_ctx);
                run_borrow_logic(dev_ctx, ctx);
                run_return_logic(dev_ctx, ctx);
            }
            
            if (dev_ctx->batch_cmds.command_count > 0) {
                execute_batch_commands(&dev_ctx->batch_cmds, dev_ctx, ctx);
            }
        }
        
        if ((now - ctx->last_check_time) >= ctx->check_interval * 1000) {
            ctx->last_check_time = now;
        }
        
        qosdba_update_status(ctx, "/tmp/qosdba_status.txt");
        
        qosdba_health_check(ctx);
        
        usleep(100000);
    }
    
    return QOSDBA_OK;
}

/* ==================== 清理函数 ==================== */
qosdba_result_t qosdba_cleanup(qosdba_context_t* ctx) {
    if (!ctx) return QOSDBA_ERR_MEMORY;
    
    log_message(ctx, "INFO", "清理资源\n");
    
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        if (dev_ctx->enabled) {
            cleanup_batch_commands(&dev_ctx->batch_cmds);
            close_device_netlink(dev_ctx, ctx);
            
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
        }
    }
    
    release_shared_netlink(ctx);
    
    if (ctx->status_file) {
        fclose(ctx->status_file);
        ctx->status_file = NULL;
    }
    
    if (ctx->log_file) {
        fclose(ctx->log_file);
        ctx->log_file = NULL;
    }
    
    cleanup_signal_queue(&ctx->signal_queue);
    cleanup_aligned_memory_manager(&ctx->aligned_memory);
    
    pthread_mutex_destroy(&ctx->rth_mutex);
    pthread_spin_destroy(&ctx->ctx_lock);
    
    log_message(ctx, "INFO", "QoS动态带宽分配器已停止\n");
    
    return QOSDBA_OK;
}

/* ==================== 主函数 ==================== */
int main(int argc, char* argv[]) {
    qosdba_context_t ctx;
    qosdba_result_t ret;
    
    const char* config_file = "/etc/qosdba.conf";
    int daemon_mode = 0;
    int debug_mode = 0;
    int safe_mode = 0;
    
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--config") == 0 && i + 1 < argc) {
            config_file = argv[++i];
        } else if (strcmp(argv[i], "--daemon") == 0) {
            daemon_mode = 1;
        } else if (strcmp(argv[i], "--debug") == 0) {
            debug_mode = 1;
        } else if (strcmp(argv[i], "--safe") == 0) {
            safe_mode = 1;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("QoS动态带宽分配器 (DBA 2.0)\n");
            printf("用法: %s [选项]\n", argv[0]);
            printf("选项:\n");
            printf("  --config <文件>   指定配置文件 (默认: /etc/qosdba.conf)\n");
            printf("  --daemon          以守护进程模式运行\n");
            printf("  --debug           启用调试模式\n");
            printf("  --safe            启用安全模式（不实际执行TC操作）\n");
            printf("  --help, -h        显示此帮助信息\n");
            return 0;
        } else {
            printf("未知选项: %s\n", argv[i]);
            printf("使用 --help 查看帮助信息\n");
            return 1;
        }
    }
    
    if (daemon_mode) {
        if (daemon(0, 0) < 0) {
            perror("daemon");
            return 1;
        }
    }
    
    ret = qosdba_init(&ctx);
    if (ret != QOSDBA_OK) {
        fprintf(stderr, "初始化失败: %d\n", ret);
        return 1;
    }
    
    qosdba_set_debug(&ctx, debug_mode);
    qosdba_set_safe_mode(&ctx, safe_mode);
    
    ret = load_config_file(&ctx, config_file);
    if (ret != QOSDBA_OK) {
        fprintf(stderr, "加载配置文件失败: %d\n", ret);
        qosdba_cleanup(&ctx);
        return 1;
    }
    
    FILE* log_file = fopen("/var/log/qosdba.log", "a");
    if (log_file) {
        ctx.log_file = log_file;
    }
    
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);
    signal(SIGQUIT, signal_handler);
    signal(SIGHUP, signal_handler);
    
    ret = qosdba_run(&ctx);
    if (ret != QOSDBA_OK) {
        fprintf(stderr, "运行失败: %d\n", ret);
    }
    
    qosdba_cleanup(&ctx);
    
    if (log_file) {
        fclose(log_file);
    }
    
    return (ret == QOSDBA_OK) ? 0 : 1;
}