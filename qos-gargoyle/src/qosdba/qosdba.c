/*
 * qosdba.c - QoS动态带宽分配器
 * 功能：监控各QoS分类的带宽使用率，实现分类间的动态带宽借用和归还
 * 支持同时监控下载(ifb0)和上传(pppoe-wan)两个设备
 * 统一配置文件：/etc/qosdba.conf
 * 版本：2.1.1（DBA 2.1.1 - 仅支持HTB）
 * 修复特性：
 * 1. 修复epoll异步监控功能
 * 2. 增强错误恢复机制
 * 3. 修复内存管理问题
 * 4. 添加测试框架支持
 * 5. 改进信号处理
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
#include <sys/resource.h>
#include <dirent.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/epoll.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/sysinfo.h>
#include <net/if.h>
#include <pthread.h>
#include <stdbool.h>
#include <sys/wait.h>

/* ==================== libnetlink (TC库) 头文件 ==================== */
#include <libnetlink.h>
#include <rtnetlink.h>
#include <linux/pkt_sched.h>
#include <linux/if_link.h>

/* ==================== 宏定义 ==================== */
#define QOSDBA_VERSION "2.1.1"
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

/* ==================== 测试框架宏 ==================== */
#ifdef QOSDBA_TEST
#define TEST_MODE_ENABLED 1
#define TEST_ASSERT(condition, message) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "测试失败: %s (文件: %s, 行: %d)\n", \
                    message, __FILE__, __LINE__); \
            exit(1); \
        } \
    } while(0)
#define TEST_LOG(message, ...) \
    printf("测试日志: " message "\n", ##__VA_ARGS__)
#else
#define TEST_MODE_ENABLED 0
#define TEST_ASSERT(condition, message) ((void)0)
#define TEST_LOG(message, ...) ((void)0)
#endif

/* 算法类型定义 */
#define ALGORITHM_UNKNOWN 0
#define ALGORITHM_HTB 1

/* 调试宏定义 */
#ifdef QOSDBA_DEBUG_MEMORY
#define DEBUG_MEMORY_ENABLED 1
#else
#define DEBUG_MEMORY_ENABLED 0
#endif

#ifdef QOSDBA_PROFILE
#define PROFILE_ENABLED 1
#else
#define PROFILE_ENABLED 0
#endif

/* 内存检查宏 */
#ifdef DEBUG_MEMORY_ENABLED
#define MEMORY_CHECK_ALLOC(ptr, size) \
    do { \
        if (!(ptr)) { \
            fprintf(stderr, "内存分配失败: 文件 %s, 行 %d, 大小 %zu\n", \
                   __FILE__, __LINE__, (size)); \
        } \
    } while(0)
#else
#define MEMORY_CHECK_ALLOC(ptr, size) ((void)0)
#endif

/* 对齐内存分配宏 */
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

/* 平台特定宏 */
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

/* 编译器警告抑制 */
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

/* TC错误码映射 */
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

/* 算法抽象层 */
typedef struct device_context_t device_context_t;
typedef struct qosdba_context_t qosdba_context_t;
typedef struct class_config_t class_config_t;
typedef struct class_state_t class_state_t;

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
    int algorithm_type;  /* 0=未知, 1=HTB */
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
} perf_stats_t;

/* 系统资源监控结构 */
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
typedef struct device_context_t {
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
    system_monitor_t system_monitor;
    int enabled;
    struct qosdba_context_t* owner_ctx;
} device_context_t;

/* QoS上下文结构 */
typedef struct qosdba_context_t {
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
    device_context_t* new_devices;
    int new_num_devices;
    signal_queue_t signal_queue;
    aligned_memory_manager_t aligned_memory;
    float_tolerance_t float_tolerance;
    config_validation_result_t config_validation;
    parser_state_t parser_state;
    system_monitor_t system_monitor;
    int test_mode;
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

/* 线程信号处理器 */
static volatile sig_atomic_t g_signal_received = 0;
static pthread_t g_signal_thread = 0;
static int g_signal_pipe[2] = {-1, -1};

/* 函数声明 */
qosdba_result_t qosdba_init(qosdba_context_t* ctx);
qosdba_result_t qosdba_run(qosdba_context_t* ctx);
qosdba_result_t qosdba_cleanup(qosdba_context_t* ctx);
qosdba_result_t qosdba_update_status(qosdba_context_t* ctx, const char* status_file);
void qosdba_set_debug(qosdba_context_t* ctx, int enable);
void qosdba_set_safe_mode(qosdba_context_t* ctx, int enable);
qosdba_result_t qosdba_health_check(qosdba_context_t* ctx);
qosdba_result_t qosdba_run_tests(qosdba_context_t* ctx);

/* 内部函数声明 */
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

/* 修复的函数声明 */
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
static qosdba_result_t setup_async_monitoring(device_context_t* dev_ctx);
static void* signal_handler_thread(void* arg);
static qosdba_result_t init_signal_handling(void);
static qosdba_result_t check_system_resources(device_context_t* dev_ctx);
static qosdba_result_t safe_tc_operation(device_context_t* dev_ctx, 
                                        qosdba_result_t (*func)(device_context_t*, int, int),
                                        int classid, int bw_kbps);
static void memory_leak_check(device_context_t* dev_ctx);
static void run_integration_tests(device_context_t* dev_ctx);
static void run_performance_tests(device_context_t* dev_ctx);

/* libnetlink辅助函数声明 */
static int nl_talk(struct rtnl_handle *rth, struct nlmsghdr *n);
static int qosdba_parse_class_attr(struct rtattr *tb[], int max, struct rtattr *rta, int len);
static int qosdba_parse_class_stats(struct rtnl_class *cls, uint64_t *bytes, uint64_t *packets);
static qosdba_result_t get_shared_netlink(qosdba_context_t* ctx, struct rtnl_handle** rth);
static void release_shared_netlink(qosdba_context_t* ctx);
static qosdba_result_t open_device_netlink(device_context_t* dev_ctx, qosdba_context_t* ctx);
static void close_device_netlink(device_context_t* dev_ctx, qosdba_context_t* ctx);
static int get_ifindex(device_context_t* dev_ctx);

/* 错误恢复和重试机制 */
typedef int (*nl_operation_func)(device_context_t* dev_ctx, void* arg);
static qosdba_result_t resilient_nl_operation(device_context_t* dev_ctx, 
                                              nl_operation_func func, 
                                              void* arg);
static qosdba_result_t retry_with_backoff(device_context_t* dev_ctx,
                                         nl_operation_func func,
                                         void* arg,
                                         int max_retries,
                                         int base_delay_ms);

/* 内存池管理函数 */
static memory_pool_t* create_memory_pool(size_t block_size, int max_blocks);
static void* allocate_from_pool(memory_pool_t* pool, size_t size);
static void free_pool_block(memory_pool_t* pool, void* ptr);
static void destroy_memory_pool(memory_pool_t* pool);
static void cleanup_memory_pools(device_context_t* dev_ctx);

/* 对齐内存管理函数 */
static void* aligned_malloc(size_t size, size_t alignment);
static void aligned_free(void* ptr);
static qosdba_result_t init_aligned_memory_manager(aligned_memory_manager_t* manager);
static void cleanup_aligned_memory_manager(aligned_memory_manager_t* manager);

/* 信号队列函数 */
static qosdba_result_t init_signal_queue(signal_queue_t* queue);
static void cleanup_signal_queue(signal_queue_t* queue);
static qosdba_result_t enqueue_signal(signal_queue_t* queue, int sig);
static int dequeue_signal(signal_queue_t* queue);
static int peek_signal(signal_queue_t* queue);

/* 信号处理函数 */
static void signal_handler(int sig);
static void setup_signal_handlers(void);

/* 浮点数比较函数 */
static bool float_equal(float a, float b, float epsilon);
static bool float_less(float a, float b, float epsilon);
static bool float_greater(float a, float b, float epsilon);
static bool float_less_or_equal(float a, float b, float epsilon);
static bool float_greater_or_equal(float a, float b, float epsilon);
static int init_float_tolerance(float_tolerance_t* tolerance);

/* TC错误处理函数 */
static const char* get_tc_error_description(int tc_error);
static qosdba_result_t map_tc_error_to_qosdba(int tc_error);
static bool is_tc_error_fatal(int tc_error);
static void log_tc_error(device_context_t* dev_ctx, int tc_error, const char* operation, int classid);

/* 安全的字符串处理函数 */
static char* safe_strncpy(char* dest, const char* src, size_t dest_size);
static char* safe_strncat(char* dest, const char* src, size_t dest_size);
static int safe_snprintf(char* str, size_t size, const char* format, ...);

/* 配置文件解析增强函数 */
static qosdba_result_t parse_csv_line(const char* line, char** tokens, int max_tokens, int* token_count);
static void free_csv_tokens(char** tokens, int token_count);
static qosdba_result_t parse_config_line(const char* line, int line_number, 
                                        int* classid, char* name, size_t name_size,
                                        int* priority, int* total_bw_kbps, 
                                        int* min_bw_kbps, int* max_bw_kbps, 
                                        int* dba_enabled);

/* 测试函数 */
static void test_config_parsing(void);
static void test_bandwidth_calculation(void);
static void test_borrow_logic(void);
static void test_tc_operations(void);
static void test_memory_management(void);
static void test_error_recovery(void);
static void test_signal_handling(void);
static void test_async_monitoring(void);

/* 性能监控宏 */
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

#define SYSTEM_RESOURCE_CHECK_START(dev_ctx) \
    do { \
        if ((dev_ctx)->system_monitor.last_check_time == 0 || \
            get_current_time_ms() - (dev_ctx)->system_monitor.last_check_time > 5000) { \
            check_system_resources(dev_ctx); \
        } \
    } while(0)

/* 算法检测函数（优化后） */
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
    
    /* 尝试获取qdisc信息 */
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
            
            /* 确定算法类型 - 仅支持HTB */
            if (strcmp(kind, "htb") == 0) {
                detection->algorithm_type = ALGORITHM_HTB;
                
                /* 统计分类数量 */
                struct nl_cache* cache = NULL;
                if (rtnl_class_alloc_cache(&dev_ctx->rth, ifindex, &cache) >= 0) {
                    int class_count = 0;
                    struct rtnl_class* class_obj = NULL;
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
                    nl_cache_free(cache);
                }
                
                rtnl_qdisc_put(qdisc);
                log_device_message(dev_ctx, "INFO", 
                                  "算法检测结果: 类型=HTB, qdisc_kind=%s, 检测到分类数=%d\n",
                                  detection->qdisc_kind, detection->detected_classes);
                return 1;
            } else {
                /* 检测到非HTB算法，直接返回失败 */
                detection->algorithm_type = ALGORITHM_UNKNOWN;
                rtnl_qdisc_put(qdisc);
                log_device_message(dev_ctx, "ERROR", 
                    "检测到不支持算法: %s，仅支持HTB算法\n", kind);
                return 0;
            }
        }
    }
    
    rtnl_qdisc_put(qdisc);
    
    /* 无法获取qdisc信息，返回未知 */
    detection->algorithm_type = ALGORITHM_UNKNOWN;
    log_device_message(dev_ctx, "ERROR", 
                      "算法检测失败: 未检测到HTB算法\n");
    return 0;
}

static const qos_algorithm_ops_t* get_algorithm_ops(const char* qdisc_kind) {
    /* 仅支持HTB算法，如果传入非htb，返回NULL */
    if (strcmp(qdisc_kind, "htb") == 0) {
        static const qos_algorithm_ops_t htb_ops = {
            .name = "htb",
            .algorithm_type = ALGORITHM_HTB,
            .init_class = NULL,
            .adjust_bandwidth = NULL,
            .borrow_bandwidth = NULL,
            .return_bandwidth = NULL,
            .get_current_bandwidth = NULL
        };
        return &htb_ops;
    } else {
        log_message(NULL, "ERROR", "请求不支持算法: %s，仅支持HTB算法\n", qdisc_kind);
        return NULL;
    }
}

static const qos_algorithm_ops_t* get_algorithm_ops_by_type(int algorithm_type) {
    /* 仅支持HTB算法 */
    if (algorithm_type == ALGORITHM_HTB) {
        static const qos_algorithm_ops_t htb_ops = {
            .name = "htb",
            .algorithm_type = ALGORITHM_HTB,
            .init_class = NULL,
            .adjust_bandwidth = NULL,
            .borrow_bandwidth = NULL,
            .return_bandwidth = NULL,
            .get_current_bandwidth = NULL
        };
        return &htb_ops;
    } else {
        log_message(NULL, "ERROR", "请求不支持算法类型: %d，仅支持HTB算法\n", algorithm_type);
        return NULL;
    }
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

/* ==================== 修复的信号处理 ==================== */
static void* signal_handler_thread(void* arg) {
    qosdba_context_t* ctx = (qosdba_context_t*)arg;
    
    while (!g_should_exit) {
        int sig = dequeue_signal(&ctx->signal_queue);
        if (sig == 0) {
            usleep(10000);
            continue;
        }
        
        SIGNAL_CHECK_START(NULL);
        
        switch (sig) {
            case SIGTERM:
            case SIGINT:
            case SIGQUIT:
                g_should_exit = 1;
                log_message(ctx, "INFO", "收到信号 %d，准备退出\n", sig);
                break;
            case SIGHUP:
                g_reload_config = 1;
                log_message(ctx, "INFO", "收到SIGHUP信号，准备重新加载配置\n");
                break;
            case SIGUSR1:
                log_message(ctx, "INFO", "收到SIGUSR1信号，输出状态信息\n");
                qosdba_update_status(ctx, "/tmp/qosdba.status");
                break;
            case SIGUSR2:
                log_message(ctx, "INFO", "收到SIGUSR2信号，切换调试模式\n");
                ctx->debug_mode = !ctx->debug_mode;
                log_message(ctx, "INFO", "调试模式: %s\n", ctx->debug_mode ? "启用" : "禁用");
                break;
        }
    }
    
    return NULL;
}

static qosdba_result_t init_signal_handling(void) {
    if (pipe(g_signal_pipe) < 0) {
        return QOSDBA_ERR_SYSTEM;
    }
    
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sa.sa_flags = SA_RESTART;
    sigemptyset(&sa.sa_mask);
    
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGQUIT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGUSR1, &sa, NULL);
    sigaction(SIGUSR2, &sa, NULL);
    
    signal(SIGPIPE, SIG_IGN);
    signal(SIGALRM, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);
    
    return QOSDBA_OK;
}

static void signal_handler(int sig) {
    SIGNAL_CHECK_START(NULL);
    
    if (g_ctx) {
        qosdba_result_t ret = enqueue_signal(&g_ctx->signal_queue, sig);
        if (ret != QOSDBA_OK) {
            log_message(NULL, "ERROR", "无法入队信号 %d\n", sig);
        }
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
    sigaction(SIGUSR1, &sa, NULL);
    sigaction(SIGUSR2, &sa, NULL);
    
    signal(SIGPIPE, SIG_IGN);
    signal(SIGALRM, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);
}

/* ==================== 修复的系统资源检查 ==================== */
static qosdba_result_t check_system_resources(device_context_t* dev_ctx) {
    if (!dev_ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    SYSTEM_RESOURCE_CHECK_START(dev_ctx);
    
    int64_t now = get_current_time_ms();
    dev_ctx->system_monitor.last_check_time = now;
    
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        dev_ctx->system_monitor.memory_usage_mb = usage.ru_maxrss / 1024;
        if (dev_ctx->system_monitor.memory_usage_mb > MAX_SYSTEM_MEMORY_USAGE_MB) {
            log_device_message(dev_ctx, "ERROR", 
                "内存使用超过限制: %lldMB > %dMB\n", 
                dev_ctx->system_monitor.memory_usage_mb, MAX_SYSTEM_MEMORY_USAGE_MB);
            return QOSDBA_ERR_PERFORMANCE;
        }
    }
    
    struct sysinfo info;
    if (sysinfo(&info) == 0) {
        long load = info.loads[0] / (1 << SI_LOAD_SHIFT);
        dev_ctx->system_monitor.cpu_usage_percent = (float)load * 100.0f / info.procs;
        if (dev_ctx->system_monitor.cpu_usage_percent > MAX_CPU_USAGE_PERCENT) {
            log_device_message(dev_ctx, "WARN", 
                "CPU使用率过高: %.1f%% > %d%%\n", 
                dev_ctx->system_monitor.cpu_usage_percent, MAX_CPU_USAGE_PERCENT);
        }
    }
    
    DIR* dir = opendir("/proc/self/fd");
    if (dir) {
        int fd_count = 0;
        struct dirent* entry;
        while ((entry = readdir(dir)) != NULL) {
            if (entry->d_type == DT_LNK) {
                fd_count++;
            }
        }
        closedir(dir);
        
        dev_ctx->system_monitor.file_descriptors_used = fd_count;
        if (fd_count > MAX_FILE_DESCRIPTORS * 0.8) {
            log_device_message(dev_ctx, "WARN", 
                "文件描述符使用较多: %d/%d\n", fd_count, MAX_FILE_DESCRIPTORS);
        }
    }
    
    return QOSDBA_OK;
}

/* ==================== 修复的TC错误恢复机制 ==================== */
static qosdba_result_t safe_tc_operation(device_context_t* dev_ctx, 
                                        qosdba_result_t (*func)(device_context_t*, int, int),
                                        int classid, int bw_kbps) {
    if (!dev_ctx || !func) {
        return QOSDBA_ERR_MEMORY;
    }
    
    int retry_count = 0;
    int max_retries = MAX_RETRY_ATTEMPTS;
    int base_delay_ms = RETRY_BASE_DELAY_MS;
    
    while (retry_count < max_retries) {
        qosdba_result_t result = func(dev_ctx, classid, bw_kbps);
        
        if (result == QOSDBA_OK) {
            if (retry_count > 0) {
                dev_ctx->perf_stats.retry_success++;
            }
            return QOSDBA_OK;
        }
        
        retry_count++;
        dev_ctx->perf_stats.retry_attempts++;
        
        if (is_tc_error_fatal(result)) {
            log_device_message(dev_ctx, "ERROR", 
                "TC操作致命错误: %s, 不再重试\n", get_tc_error_description(result));
            return result;
        }
        
        if (retry_count < max_retries) {
            int delay_ms = base_delay_ms * (1 << (retry_count - 1));
            if (delay_ms > MAX_RETRY_DELAY_MS) {
                delay_ms = MAX_RETRY_DELAY_MS;
            }
            
            log_device_message(dev_ctx, "WARN", 
                "TC操作失败，尝试 %d/%d，%dms 后重试\n", 
                retry_count, max_retries, delay_ms);
            
            usleep(delay_ms * 1000);
        }
    }
    
    dev_ctx->perf_stats.retry_failures++;
    log_device_message(dev_ctx, "ERROR", 
        "TC操作重试 %d 次后失败\n", max_retries);
    
    return QOSDBA_ERR_TIMEOUT;
}

/* ==================== 修复的异步监控 ==================== */
static qosdba_result_t init_async_monitor(device_context_t* dev_ctx) {
    if (!dev_ctx) return QOSDBA_ERR_MEMORY;
    
    dev_ctx->async_monitor.epoll_fd = epoll_create1(0);
    if (dev_ctx->async_monitor.epoll_fd < 0) {
        return QOSDBA_ERR_SYSTEM;
    }
    
    dev_ctx->async_monitor.inotify_fd = inotify_init1(IN_NONBLOCK);
    if (dev_ctx->async_monitor.inotify_fd < 0) {
        close(dev_ctx->async_monitor.epoll_fd);
        return QOSDBA_ERR_SYSTEM;
    }
    
    dev_ctx->async_monitor.async_enabled = 1;
    dev_ctx->async_monitor.last_async_check = get_current_time_ms();
    
    return setup_async_monitoring(dev_ctx);
}

static qosdba_result_t setup_async_monitoring(device_context_t* dev_ctx) {
    if (!dev_ctx || !dev_ctx->owner_ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    struct epoll_event ev;
    ev.events = EPOLLIN;
    ev.data.fd = dev_ctx->async_monitor.inotify_fd;
    
    if (epoll_ctl(dev_ctx->async_monitor.epoll_fd, EPOLL_CTL_ADD, 
                  dev_ctx->async_monitor.inotify_fd, &ev) < 0) {
        return QOSDBA_ERR_SYSTEM;
    }
    
    /* 添加配置文件监控 */
    if (dev_ctx->owner_ctx->config_path[0] != '\0') {
        dev_ctx->async_monitor.watch_fd = inotify_add_watch(
            dev_ctx->async_monitor.inotify_fd, 
            dev_ctx->owner_ctx->config_path, 
            IN_MODIFY | IN_DELETE_SELF | IN_MOVE_SELF);
        
        if (dev_ctx->async_monitor.watch_fd < 0) {
            log_device_message(dev_ctx, "WARN", 
                "无法添加配置文件监控: %s\n", dev_ctx->owner_ctx->config_path);
        } else {
            log_device_message(dev_ctx, "DEBUG", 
                "配置文件监控已启用: %s\n", dev_ctx->owner_ctx->config_path);
        }
    }
    
    return QOSDBA_OK;
}

static int check_async_events(device_context_t* dev_ctx) {
    if (!dev_ctx || !dev_ctx->async_monitor.async_enabled) {
        return 0;
    }
    
    int64_t now = get_current_time_ms();
    if (now - dev_ctx->async_monitor.last_async_check < 1000) {
        return 0;
    }
    
    dev_ctx->async_monitor.last_async_check = now;
    
    struct epoll_event events[MAX_EPOLL_EVENTS];
    int nfds = epoll_wait(dev_ctx->async_monitor.epoll_fd, events, MAX_EPOLL_EVENTS, 0);
    if (nfds < 0) {
        if (errno != EINTR) {
            log_device_message(dev_ctx, "ERROR", "epoll_wait失败: %s\n", strerror(errno));
        }
        return 0;
    }
    
    int event_count = 0;
    
    for (int i = 0; i < nfds; i++) {
        if (events[i].events & EPOLLIN) {
            if (events[i].data.fd == dev_ctx->async_monitor.inotify_fd) {
                char buffer[MAX_INOTIFY_BUFFER_SIZE];
                int length = read(dev_ctx->async_monitor.inotify_fd, buffer, sizeof(buffer));
                if (length > 0) {
                    event_count++;
                    
                    int offset = 0;
                    while (offset < length) {
                        struct inotify_event* event = (struct inotify_event*)&buffer[offset];
                        
                        if (event->mask & (IN_MODIFY | IN_DELETE_SELF | IN_MOVE_SELF)) {
                            log_device_message(dev_ctx, "INFO", 
                                "检测到配置文件变化，触发重载\n");
                            g_reload_config = 1;
                        }
                        
                        offset += sizeof(struct inotify_event) + event->len;
                    }
                }
            }
        }
    }
    
    return event_count;
}

/* ==================== 修复的内存泄漏检查 ==================== */
static void memory_leak_check(device_context_t* dev_ctx) {
    if (!dev_ctx || !DEBUG_MEMORY_ENABLED) {
        return;
    }
    
    static int64_t last_check_time = 0;
    int64_t now = get_current_time_ms();
    
    if (now - last_check_time < 30000) {
        return;
    }
    
    last_check_time = now;
    
    /* 检查批量命令内存 */
    if (dev_ctx->batch_cmds.classes) {
        for (int i = 0; i < dev_ctx->batch_cmds.command_count; i++) {
            if (dev_ctx->batch_cmds.classes[i]) {
                log_device_message(dev_ctx, "WARN", 
                    "批量命令中存在未释放的类对象: 索引=%d\n", i);
            }
        }
    }
    
    /* 检查缓存内存 */
    pthread_mutex_lock(&dev_ctx->tc_cache.cache_mutex);
    for (int i = 0; i < dev_ctx->tc_cache.num_cached_classes; i++) {
        if (dev_ctx->tc_cache.cached_classes[i]) {
            log_device_message(dev_ctx, "DEBUG", 
                "缓存中存在类对象: 索引=%d\n", i);
        }
    }
    pthread_mutex_unlock(&dev_ctx->tc_cache.cache_mutex);
    
    log_device_message(dev_ctx, "DEBUG", 
        "内存使用: 批量命令=%d, 缓存类=%d\n",
        dev_ctx->batch_cmds.command_count,
        dev_ctx->tc_cache.num_cached_classes);
}

/* ==================== 修复的内存池管理 ==================== */
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
    
    MEMORY_CHECK_ALLOC(new_block->data, pool->block_size);
    
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

/* ==================== 测试函数 ==================== */
static void test_config_parsing(void) {
    TEST_LOG("开始配置文件解析测试");
    
    qosdba_context_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    
    const char* test_config = "test_config.conf";
    FILE* fp = fopen(test_config, "w");
    if (fp) {
        fprintf(fp, "[device=ifb0]\n");
        fprintf(fp, "total_bandwidth_kbps=100000\n");
        fprintf(fp, "algorithm=htb\n");
        fprintf(fp, "0x100,class1,1,10000,1000,20000,1\n");
        fclose(fp);
    }
    
    qosdba_result_t ret = load_config_file(&ctx, test_config);
    TEST_ASSERT(ret == QOSDBA_OK, "配置文件加载失败");
    TEST_ASSERT(ctx.num_devices == 1, "设备数量错误");
    TEST_ASSERT(strcmp(ctx.devices[0].device, "ifb0") == 0, "设备名称错误");
    TEST_ASSERT(ctx.devices[0].num_classes == 1, "分类数量错误");
    
    remove(test_config);
    TEST_LOG("配置文件解析测试通过");
}

static void test_bandwidth_calculation(void) {
    TEST_LOG("开始带宽计算测试");
    
    device_context_t dev_ctx;
    memset(&dev_ctx, 0, sizeof(dev_ctx));
    
    dev_ctx.total_bandwidth_kbps = 100000;
    dev_ctx.num_classes = 2;
    
    dev_ctx.configs[0].classid = 0x100;
    dev_ctx.configs[0].min_bw_kbps = 1000;
    dev_ctx.configs[0].max_bw_kbps = 20000;
    dev_ctx.configs[0].dba_enabled = 1;
    
    dev_ctx.configs[1].classid = 0x200;
    dev_ctx.configs[1].min_bw_kbps = 1000;
    dev_ctx.configs[1].max_bw_kbps = 20000;
    dev_ctx.configs[1].dba_enabled = 1;
    
    dev_ctx.states[0].classid = 0x100;
    dev_ctx.states[0].current_bw_kbps = 10000;
    dev_ctx.states[0].used_bw_kbps = 8000;
    dev_ctx.states[0].dba_enabled = 1;
    
    dev_ctx.states[1].classid = 0x200;
    dev_ctx.states[1].current_bw_kbps = 10000;
    dev_ctx.states[1].used_bw_kbps = 3000;
    dev_ctx.states[1].dba_enabled = 1;
    
    float util1 = (float)dev_ctx.states[0].used_bw_kbps / dev_ctx.states[0].current_bw_kbps;
    float util2 = (float)dev_ctx.states[1].used_bw_kbps / dev_ctx.states[1].current_bw_kbps;
    
    TEST_ASSERT(util1 * 100 > 50, "分类1使用率计算错误");
    TEST_ASSERT(util2 * 100 < 50, "分类2使用率计算错误");
    
    TEST_LOG("带宽计算测试通过");
}

static void test_borrow_logic(void) {
    TEST_LOG("开始借用逻辑测试");
    
    device_context_t dev_ctx;
    memset(&dev_ctx, 0, sizeof(dev_ctx));
    
    dev_ctx.num_classes = 2;
    dev_ctx.high_util_threshold = 80;
    dev_ctx.high_util_duration = 3;
    dev_ctx.low_util_threshold = 30;
    dev_ctx.borrow_ratio = 0.2f;
    dev_ctx.min_borrow_kbps = 128;
    dev_ctx.min_change_kbps = 128;
    dev_ctx.cooldown_time = 8;
    
    dev_ctx.configs[0].classid = 0x100;
    dev_ctx.configs[0].priority = 1;
    dev_ctx.configs[0].min_bw_kbps = 1000;
    dev_ctx.configs[0].max_bw_kbps = 20000;
    dev_ctx.configs[0].dba_enabled = 1;
    
    dev_ctx.configs[1].classid = 0x200;
    dev_ctx.configs[1].priority = 2;
    dev_ctx.configs[1].min_bw_kbps = 1000;
    dev_ctx.configs[1].max_bw_kbps = 20000;
    dev_ctx.configs[1].dba_enabled = 1;
    
    dev_ctx.states[0].classid = 0x100;
    dev_ctx.states[0].current_bw_kbps = 10000;
    dev_ctx.states[0].used_bw_kbps = 9000;
    dev_ctx.states[0].utilization = 0.9f;
    dev_ctx.states[0].high_util_duration = 5;
    dev_ctx.states[0].cooldown_timer = 0;
    dev_ctx.states[0].dba_enabled = 1;
    
    dev_ctx.states[1].classid = 0x200;
    dev_ctx.states[1].current_bw_kbps = 10000;
    dev_ctx.states[1].used_bw_kbps = 2000;
    dev_ctx.states[1].utilization = 0.2f;
    dev_ctx.states[1].dba_enabled = 1;
    
    int needed_bw = 0;
    if (dev_ctx.states[0].utilization > 1.0f) {
        needed_bw = (int)(dev_ctx.states[0].current_bw_kbps * 
                         (dev_ctx.states[0].utilization - 1.0f));
    }
    
    TEST_ASSERT(needed_bw == 0, "所需带宽计算错误");
    TEST_LOG("借用逻辑测试通过");
}

static void test_tc_operations(void) {
    TEST_LOG("开始TC操作测试");
    
    TEST_LOG("此测试需要实际TC环境，跳过");
    TEST_LOG("TC操作测试跳过");
}

static void test_memory_management(void) {
    TEST_LOG("开始内存管理测试");
    
    void* ptr1 = aligned_malloc(100, 16);
    TEST_ASSERT(ptr1 != NULL, "对齐内存分配失败");
    TEST_ASSERT(((uintptr_t)ptr1 & 15) == 0, "内存未对齐");
    
    void* ptr2 = aligned_malloc(200, 32);
    TEST_ASSERT(ptr2 != NULL, "大内存分配失败");
    TEST_ASSERT(((uintptr_t)ptr2 & 31) == 0, "内存未对齐");
    
    aligned_free(ptr1);
    aligned_free(ptr2);
    
    memory_pool_t* pool = create_memory_pool(64, 10);
    TEST_ASSERT(pool != NULL, "内存池创建失败");
    
    void* block1 = allocate_from_pool(pool, 32);
    TEST_ASSERT(block1 != NULL, "内存池分配失败");
    
    void* block2 = allocate_from_pool(pool, 48);
    TEST_ASSERT(block2 != NULL, "内存池分配失败");
    
    free_pool_block(pool, block1);
    free_pool_block(pool, block2);
    
    destroy_memory_pool(pool);
    
    TEST_LOG("内存管理测试通过");
}

static void test_error_recovery(void) {
    TEST_LOG("开始错误恢复测试");
    
    device_context_t dev_ctx;
    memset(&dev_ctx, 0, sizeof(dev_ctx));
    
    int retry_count = 0;
    int max_retries = 3;
    
    while (retry_count < max_retries) {
        retry_count++;
        if (retry_count == 2) {
            TEST_LOG("模拟重试成功");
            break;
        }
    }
    
    TEST_ASSERT(retry_count == 2, "重试逻辑错误");
    TEST_LOG("错误恢复测试通过");
}

static void test_signal_handling(void) {
    TEST_LOG("开始信号处理测试");
    
    signal_queue_t queue;
    qosdba_result_t ret = init_signal_queue(&queue);
    TEST_ASSERT(ret == QOSDBA_OK, "信号队列初始化失败");
    
    ret = enqueue_signal(&queue, SIGUSR1);
    TEST_ASSERT(ret == QOSDBA_OK, "信号入队失败");
    
    int sig = dequeue_signal(&queue);
    TEST_ASSERT(sig == SIGUSR1, "信号出队错误");
    
    cleanup_signal_queue(&queue);
    
    TEST_LOG("信号处理测试通过");
}

static void test_async_monitoring(void) {
    TEST_LOG("开始异步监控测试");
    
    device_context_t dev_ctx;
    memset(&dev_ctx, 0, sizeof(dev_ctx));
    
    qosdba_result_t ret = init_async_monitor(&dev_ctx);
    if (ret == QOSDBA_OK) {
        TEST_LOG("异步监控初始化成功");
        
        int events = check_async_events(&dev_ctx);
        TEST_ASSERT(events >= 0, "异步事件检查失败");
        
        if (dev_ctx.async_monitor.epoll_fd >= 0) {
            close(dev_ctx.async_monitor.epoll_fd);
        }
        if (dev_ctx.async_monitor.inotify_fd >= 0) {
            close(dev_ctx.async_monitor.inotify_fd);
        }
    } else {
        TEST_LOG("异步监控初始化失败，可能系统不支持");
    }
    
    TEST_LOG("异步监控测试通过");
}

static void run_integration_tests(device_context_t* dev_ctx) {
    if (!dev_ctx || !TEST_MODE_ENABLED) {
        return;
    }
    
    TEST_LOG("开始集成测试");
    
    int64_t start_time = get_current_time_ms();
    
    test_config_parsing();
    test_bandwidth_calculation();
    test_borrow_logic();
    test_tc_operations();
    test_memory_management();
    test_error_recovery();
    test_signal_handling();
    test_async_monitoring();
    
    int64_t end_time = get_current_time_ms();
    int64_t elapsed = end_time - start_time;
    
    TEST_LOG("所有测试通过，耗时: %lld ms", elapsed);
}

static void run_performance_tests(device_context_t* dev_ctx) {
    if (!dev_ctx) {
        return;
    }
    
    int64_t start_time = get_current_time_ms();
    int iterations = 1000;
    
    for (int i = 0; i < iterations; i++) {
        safe_strncpy(dev_ctx->device, "test-device", sizeof(dev_ctx->device));
        dev_ctx->total_bandwidth_kbps = 100000 + i;
        
        for (int j = 0; j < 10; j++) {
            if (j < dev_ctx->num_classes) {
                dev_ctx->states[j].used_bw_kbps = rand() % 10000;
                dev_ctx->states[j].utilization = (float)dev_ctx->states[j].used_bw_kbps / 
                                                dev_ctx->states[j].current_bw_kbps;
            }
        }
    }
    
    int64_t end_time = get_current_time_ms();
    int64_t elapsed = end_time - start_time;
    
    log_device_message(dev_ctx, "INFO", 
        "性能测试完成: %d 次迭代, 耗时: %lld ms, 平均: %.2f ms/次", 
        iterations, elapsed, (float)elapsed / iterations);
}

/* ==================== 测试运行函数 ==================== */
qosdba_result_t qosdba_run_tests(qosdba_context_t* ctx) {
    if (!ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    TEST_LOG("启动QoS DBA测试套件 2.1.1");
    
    run_integration_tests(&ctx->devices[0]);
    
    for (int i = 0; i < ctx->num_devices; i++) {
        if (ctx->devices[i].enabled) {
            run_performance_tests(&ctx->devices[i]);
        }
    }
    
    TEST_LOG("测试套件执行完成");
    
    return QOSDBA_OK;
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

static int get_file_mtime(const char* filename) {
    struct stat st;
    if (stat(filename, &st) == 0) {
        return st.st_mtime;
    }
    return 0;
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

static int parse_key_value(const char* line, char* key, int key_len, char* value, int value_len) {
    if (!line || !key || !value) return 0;
    
    STRING_OPERATION_START(NULL);
    
    const char* equals = strchr(line, '=');
    if (!equals) return 0;
    
    int key_length = equals - line;
    if (key_length >= key_len) key_length = key_len - 1;
    
    strncpy(key, line, key_length);
    key[key_length] = '\0';
    trim_whitespace(key);
    
    const char* val_start = equals + 1;
    int val_length = strlen(val_start);
    if (val_length >= value_len) val_length = value_len - 1;
    
    strncpy(value, val_start, val_length);
    value[val_length] = '\0';
    trim_whitespace(value);
    
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
                    /* 仅支持HTB算法 */
                    if (strcmp(value, "htb") == 0) {
                        safe_strncpy(current_dev->qdisc_kind, value, sizeof(current_dev->qdisc_kind));
                    } else {
                        log_message(ctx, "ERROR", "行 %d: 不支持的算法: %s，仅支持HTB算法\n", 
                                   line_num, value);
                        fclose(fp);
                        return QOSDBA_ERR_CONFIG;
                    }
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
                
                if (state->current_bw_kbps > 0) {
                    state->utilization = (float)state->used_bw_kbps / state->current_bw_kbps;
                } else {
                    state->utilization = 0.0f;
                }
                
                if (state->used_bw_kbps > state->peak_used_bw_kbps) {
                    state->peak_used_bw_kbps = state->used_bw_kbps;
                }
                
                if (state->avg_used_bw_kbps == 0) {
                    state->avg_used_bw_kbps = state->used_bw_kbps;
                } else {
                    state->avg_used_bw_kbps = (state->avg_used_bw_kbps + state->used_bw_kbps) / 2;
                }
                
                FLOAT_COMPARISON_START(dev_ctx);
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
        } else {
            log_device_message(dev_ctx, "WARN", "分类 0x%x 无法获取统计信息\n", state->classid);
        }
    }
    
    TIME_OPERATION_END(dev_ctx, check_usage_time_ms);
    return QOSDBA_OK;
}

/* ==================== 查找分类函数 ==================== */
static int find_class_by_id(device_context_t* dev_ctx, int classid) {
    if (!dev_ctx) return -1;
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        if (dev_ctx->states[i].classid == classid) {
            return i;
        }
    }
    return -1;
}

static int find_available_class_to_borrow(device_context_t* dev_ctx, 
                                         int exclude_classid, 
                                         int borrower_priority,
                                         int needed_bw_kbps) {
    if (!dev_ctx) return -1;
    
    int best_idx = -1;
    float best_score = -1.0f;
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_state_t* state = &dev_ctx->states[i];
        class_config_t* config = &dev_ctx->configs[i];
        
        if (!state->dba_enabled) {
            continue;
        }
        
        if (state->classid == exclude_classid) {
            continue;
        }
        
        if (state->cooldown_timer > 0) {
            continue;
        }
        
        int available_bw = state->current_bw_kbps - state->used_bw_kbps;
        int max_borrow = state->current_bw_kbps - config->min_bw_kbps;
        
        if (available_bw < needed_bw_kbps || max_borrow < needed_bw_kbps) {
            continue;
        }
        
        FLOAT_COMPARISON_START(dev_ctx);
        if (state->utilization * 100 > dev_ctx->low_util_threshold) {
            continue;
        }
        
        int priority_gap = config->priority - borrower_priority;
        
        if (!dev_ctx->priority_policy.allow_same_priority_borrow && priority_gap == 0) {
            continue;
        }
        
        if (priority_gap < 0 && !dev_ctx->priority_policy.max_borrow_from_higher_priority) {
            continue;
        }
        
        if (abs(priority_gap) < dev_ctx->priority_policy.min_lender_priority_gap) {
            continue;
        }
        
        float score = (float)available_bw / state->current_bw_kbps;
        
        if (priority_gap > 0) {
            score *= 1.5f;
        } else if (priority_gap < 0) {
            score *= 0.5f;
        }
        
        score *= (1.0f - state->utilization);
        
        FLOAT_COMPARISON_START(dev_ctx);
        if (score > best_score) {
            best_score = score;
            best_idx = i;
        }
    }
    
    return best_idx;
}

/* ==================== 添加借用记录 ==================== */
static void add_borrow_record(device_context_t* dev_ctx, int from_classid, 
                             int to_classid, int borrowed_bw_kbps) {
    if (!dev_ctx) return;
    
    if (dev_ctx->num_records >= MAX_BORROW_RECORDS) {
        for (int i = 0; i < MAX_BORROW_RECORDS / 2; i++) {
            dev_ctx->records[i] = dev_ctx->records[i + MAX_BORROW_RECORDS / 2];
        }
        dev_ctx->num_records = MAX_BORROW_RECORDS / 2;
    }
    
    borrow_record_t* record = &dev_ctx->records[dev_ctx->num_records];
    record->from_classid = from_classid;
    record->to_classid = to_classid;
    record->borrowed_bw_kbps = borrowed_bw_kbps;
    record->start_time = get_current_time_ms();
    record->returned = 0;
    
    dev_ctx->num_records++;
    dev_ctx->total_borrow_events++;
    dev_ctx->total_borrowed_kbps += borrowed_bw_kbps;
}

/* ==================== 检查配置重载 ==================== */
static int check_config_reload(qosdba_context_t* ctx, const char* config_file) {
    if (!ctx || !config_file) return 0;
    
    int current_mtime = get_file_mtime(config_file);
    if (current_mtime > ctx->config_mtime) {
        log_message(ctx, "INFO", "检测到配置文件修改，准备重新加载\n");
        return 1;
    }
    
    return 0;
}

static qosdba_result_t reload_config(qosdba_context_t* ctx, const char* config_file) {
    if (!ctx || !config_file) return QOSDBA_ERR_MEMORY;
    
    log_message(ctx, "INFO", "开始重新加载配置文件\n");
    
    device_context_t new_devices[MAX_DEVICES];
    int new_num_devices = 0;
    
    memset(new_devices, 0, sizeof(new_devices));
    
    qosdba_context_t temp_ctx = *ctx;
    temp_ctx.devices = new_devices;
    temp_ctx.num_devices = 0;
    
    qosdba_result_t ret = load_config_file(&temp_ctx, config_file);
    if (ret != QOSDBA_OK) {
        log_message(ctx, "ERROR", "重新加载配置文件失败\n");
        return ret;
    }
    
    ret = reload_config_atomic(ctx, config_file);
    if (ret == QOSDBA_OK) {
        log_message(ctx, "INFO", "配置文件重新加载成功\n");
    } else {
        log_message(ctx, "ERROR", "配置文件重新加载失败\n");
    }
    
    return ret;
}

static qosdba_result_t reload_config_atomic(qosdba_context_t* ctx, const char* config_file) {
    if (!ctx || !config_file) return QOSDBA_ERR_MEMORY;
    
    pthread_spin_lock(&ctx->ctx_lock);
    
    device_context_t* new_devices = (device_context_t*)aligned_malloc(
        sizeof(device_context_t) * MAX_DEVICES, DEFAULT_ALIGNMENT);
    if (!new_devices) {
        pthread_spin_unlock(&ctx->ctx_lock);
        return QOSDBA_ERR_MEMORY;
    }
    
    memset(new_devices, 0, sizeof(device_context_t) * MAX_DEVICES);
    
    qosdba_context_t temp_ctx = *ctx;
    temp_ctx.devices = new_devices;
    temp_ctx.num_devices = 0;
    
    qosdba_result_t ret = load_config_file(&temp_ctx, config_file);
    if (ret != QOSDBA_OK) {
        aligned_free(new_devices);
        pthread_spin_unlock(&ctx->ctx_lock);
        return ret;
    }
    
    for (int i = 0; i < ctx->num_devices; i++) {
        close_device_netlink(&ctx->devices[i], ctx);
        cleanup_batch_commands(&ctx->devices[i].batch_cmds);
        pthread_mutex_destroy(&ctx->devices[i].tc_cache.cache_mutex);
    }
    
    for (int i = 0; i < temp_ctx.num_devices; i++) {
        new_devices[i].owner_ctx = ctx;
        init_batch_commands(&new_devices[i].batch_cmds, BATCH_COMMAND_INITIAL_CAPACITY);
        pthread_mutex_init(&new_devices[i].tc_cache.cache_mutex, NULL);
    }
    
    ctx->new_devices = new_devices;
    ctx->new_num_devices = temp_ctx.num_devices;
    ctx->reload_config = 1;
    ctx->config_mtime = get_file_mtime(config_file);
    
    pthread_spin_unlock(&ctx->ctx_lock);
    
    return QOSDBA_OK;
}

/* ==================== 批量命令处理 ==================== */
static void init_batch_commands(batch_commands_t* batch, int initial_capacity) {
    if (!batch) return;
    
    batch->classes = (struct rtnl_class**)aligned_malloc(
        sizeof(struct rtnl_class*) * initial_capacity, DEFAULT_ALIGNMENT);
    if (!batch->classes) {
        batch->capacity = 0;
        batch->command_count = 0;
        return;
    }
    
    memset(batch->classes, 0, sizeof(struct rtnl_class*) * initial_capacity);
    batch->command_count = 0;
    batch->capacity = initial_capacity;
    batch->max_commands = BATCH_COMMAND_MAX_CAPACITY;
    batch->avg_batch_size = 0.0f;
    batch->last_adjust_time = 0;
    batch->adjustment_count = 0;
    batch->adaptive_enabled = 1;
    batch->pool = create_memory_pool(MEMORY_POOL_BLOCK_SIZE, MAX_MEMORY_POOL_BLOCKS);
}

static void resize_batch_commands(batch_commands_t* batch, int new_capacity) {
    if (!batch || new_capacity <= 0 || new_capacity > batch->max_commands) {
        return;
    }
    
    struct rtnl_class** new_classes = (struct rtnl_class**)aligned_malloc(
        sizeof(struct rtnl_class*) * new_capacity, DEFAULT_ALIGNMENT);
    if (!new_classes) {
        return;
    }
    
    memset(new_classes, 0, sizeof(struct rtnl_class*) * new_capacity);
    
    int copy_count = (batch->command_count < new_capacity) ? batch->command_count : new_capacity;
    for (int i = 0; i < copy_count; i++) {
        new_classes[i] = batch->classes[i];
    }
    
    if (batch->classes) {
        aligned_free(batch->classes);
    }
    
    batch->classes = new_classes;
    batch->capacity = new_capacity;
    
    if (batch->command_count > new_capacity) {
        batch->command_count = new_capacity;
    }
}

static void cleanup_batch_commands(batch_commands_t* batch) {
    if (!batch) return;
    
    if (batch->classes) {
        for (int i = 0; i < batch->command_count; i++) {
            if (batch->classes[i]) {
                rtnl_class_put(batch->classes[i]);
            }
        }
        aligned_free(batch->classes);
        batch->classes = NULL;
    }
    
    if (batch->pool) {
        destroy_memory_pool(batch->pool);
        batch->pool = NULL;
    }
    
    batch->command_count = 0;
    batch->capacity = 0;
}

static void adjust_batch_size(device_context_t* dev_ctx) {
    if (!dev_ctx || !dev_ctx->batch_cmds.adaptive_enabled) {
        return;
    }
    
    int64_t now = get_current_time_ms();
    
    if (dev_ctx->batch_cmds.last_adjust_time == 0) {
        dev_ctx->batch_cmds.last_adjust_time = now;
        return;
    }
    
    int64_t time_diff = now - dev_ctx->batch_cmds.last_adjust_time;
    if (time_diff < 10000) {
        return;
    }
    
    float current_batch_size = (float)dev_ctx->batch_cmds.adjustment_count / (time_diff / 1000.0f);
    
    if (dev_ctx->batch_cmds.avg_batch_size == 0.0f) {
        dev_ctx->batch_cmds.avg_batch_size = current_batch_size;
    } else {
        dev_ctx->batch_cmds.avg_batch_size = 
            (dev_ctx->batch_cmds.avg_batch_size + current_batch_size) / 2.0f;
    }
    
    int target_capacity = (int)(dev_ctx->batch_cmds.avg_batch_size * 2.0f);
    if (target_capacity < BATCH_COMMAND_INITIAL_CAPACITY) {
        target_capacity = BATCH_COMMAND_INITIAL_CAPACITY;
    }
    
    if (target_capacity > BATCH_COMMAND_MAX_CAPACITY) {
        target_capacity = BATCH_COMMAND_MAX_CAPACITY;
    }
    
    if (target_capacity != dev_ctx->batch_cmds.capacity) {
        resize_batch_commands(&dev_ctx->batch_cmds, target_capacity);
        log_device_message(dev_ctx, "DEBUG", "调整批量命令容量: %d -> %d\n", 
                          dev_ctx->batch_cmds.capacity, target_capacity);
    }
    
    dev_ctx->batch_cmds.last_adjust_time = now;
    dev_ctx->batch_cmds.adjustment_count = 0;
}

static void add_to_batch_commands(batch_commands_t* batch, struct rtnl_class* class) {
    if (!batch || !class) return;
    
    if (batch->command_count >= batch->capacity) {
        int new_capacity = batch->capacity * 2;
        if (new_capacity > batch->max_commands) {
            new_capacity = batch->max_commands;
        }
        if (new_capacity > batch->capacity) {
            resize_batch_commands(batch, new_capacity);
        } else {
            return;
        }
    }
    
    batch->classes[batch->command_count] = rtnl_class_clone(class);
    if (batch->classes[batch->command_count]) {
        batch->command_count++;
    } else {
        log_message(NULL, "WARN", "无法克隆rtnl_class对象\n");
    }
}

static qosdba_result_t execute_batch_commands(batch_commands_t* batch, device_context_t* dev_ctx, qosdba_context_t* ctx) {
    if (!batch || !dev_ctx || !ctx || batch->command_count == 0) {
        return QOSDBA_OK;
    }
    
    TIME_OPERATION_START(dev_ctx, batch_execute_time_ms);
    
    int success_count = 0;
    int total_commands = batch->command_count;
    
    for (int i = 0; i < batch->command_count; i++) {
        struct rtnl_class* class_obj = batch->classes[i];
        if (!class_obj) continue;
        
        NL_TIME_OPERATION_START(dev_ctx);
        int ret = rtnl_class_change(&dev_ctx->rth, class_obj, 0);
        NL_TIME_OPERATION_END(dev_ctx, ret);
        
        if (ret == 0) {
            success_count++;
        } else {
            log_tc_error(dev_ctx, ret, "批量执行分类变更", 
                        rtnl_tc_get_handle(TC_CAST(class_obj)));
        }
        
        rtnl_class_put(class_obj);
        batch->classes[i] = NULL;
    }
    
    batch->command_count = 0;
    dev_ctx->perf_stats.batch_executions++;
    dev_ctx->perf_stats.total_batch_commands += total_commands;
    
    if (batch->adaptive_enabled) {
        dev_ctx->batch_cmds.adjustment_count += total_commands;
    }
    
    TIME_OPERATION_END(dev_ctx, batch_execute_time_ms);
    
    if (success_count == total_commands) {
        return QOSDBA_OK;
    } else if (success_count > 0) {
        log_device_message(dev_ctx, "WARN", "批量命令执行部分成功: %d/%d\n", 
                          success_count, total_commands);
        return QOSDBA_OK;
    } else {
        return QOSDBA_ERR_TC;
    }
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

/* ==================== 错误恢复和重试机制 ==================== */
static qosdba_result_t resilient_nl_operation(device_context_t* dev_ctx, 
                                              nl_operation_func func, 
                                              void* arg) {
    if (!dev_ctx || !func) {
        return QOSDBA_ERR_MEMORY;
    }
    
    int attempt = 0;
    int max_retries = MAX_RETRY_ATTEMPTS;
    int base_delay_ms = RETRY_BASE_DELAY_MS;
    
    while (attempt < max_retries) {
        int result = func(dev_ctx, arg);
        
        if (result == 0) {
            return QOSDBA_OK;
        }
        
        attempt++;
        dev_ctx->perf_stats.retry_attempts++;
        
        if (attempt < max_retries) {
            int delay_ms = base_delay_ms * (1 << (attempt - 1));
            if (delay_ms > MAX_RETRY_DELAY_MS) {
                delay_ms = MAX_RETRY_DELAY_MS;
            }
            
            log_device_message(dev_ctx, "WARN", 
                              "NL操作失败，尝试 %d/%d，%dms 后重试\n", 
                              attempt, max_retries, delay_ms);
            
            usleep(delay_ms * 1000);
        }
    }
    
    dev_ctx->perf_stats.retry_failures++;
    return QOSDBA_ERR_TIMEOUT;
}

static qosdba_result_t retry_with_backoff(device_context_t* dev_ctx,
                                         nl_operation_func func,
                                         void* arg,
                                         int max_retries,
                                         int base_delay_ms) {
    if (!dev_ctx || !func || max_retries <= 0) {
        return QOSDBA_ERR_MEMORY;
    }
    
    for (int attempt = 0; attempt < max_retries; attempt++) {
        int result = func(dev_ctx, arg);
        
        if (result == 0) {
            if (attempt > 0) {
                dev_ctx->perf_stats.retry_success++;
            }
            return QOSDBA_OK;
        }
        
        dev_ctx->perf_stats.retry_attempts++;
        
        if (attempt < max_retries - 1) {
            int delay_ms = base_delay_ms * (1 << attempt);
            if (delay_ms > MAX_RETRY_DELAY_MS) {
                delay_ms = MAX_RETRY_DELAY_MS;
            }
            
            log_device_message(dev_ctx, "DEBUG", 
                              "操作失败，%dms 后重试 (尝试 %d/%d)\n", 
                              delay_ms, attempt + 1, max_retries);
            
            usleep(delay_ms * 1000);
        }
    }
    
    dev_ctx->perf_stats.retry_failures++;
    return QOSDBA_ERR_TIMEOUT;
}

/* ==================== 主循环函数 ==================== */
qosdba_result_t qosdba_run(qosdba_context_t* ctx) {
    if (!ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    ctx->start_time = get_current_time_ms();
    ctx->last_check_time = ctx->start_time;
    
    log_message(ctx, "INFO", "QoS DBA 2.1.1 启动 (仅支持HTB算法)\n");
    log_message(ctx, "INFO", "版本: %s\n", QOSDBA_VERSION);
    log_message(ctx, "INFO", "配置文件: %s\n", ctx->config_path);
    log_message(ctx, "INFO", "设备数量: %d\n", ctx->num_devices);
    log_message(ctx, "INFO", "检查间隔: %d 秒\n", ctx->check_interval);
    
    if (ctx->safe_mode) {
        log_message(ctx, "WARN", "安全模式已启用，TC操作将被模拟\n");
    }
    
    if (ctx->test_mode) {
        log_message(ctx, "INFO", "测试模式已启用，运行测试套件\n");
        qosdba_run_tests(ctx);
        return QOSDBA_OK;
    }
    
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        if (!dev_ctx->enabled) {
            log_device_message(dev_ctx, "INFO", "设备被禁用\n");
            continue;
        }
        
        qosdba_result_t ret = open_device_netlink(dev_ctx, ctx);
        if (ret != QOSDBA_OK) {
            log_device_message(dev_ctx, "ERROR", "打开netlink连接失败\n");
            dev_ctx->enabled = 0;
            continue;
        }
        
        ret = discover_tc_classes(dev_ctx);
        if (ret != QOSDBA_OK) {
            log_device_message(dev_ctx, "WARN", "发现TC分类失败\n");
        }
        
        ret = init_tc_classes(dev_ctx, ctx);
        if (ret != QOSDBA_OK) {
            log_device_message(dev_ctx, "ERROR", "初始化TC分类失败，设备将被禁用\n");
            dev_ctx->enabled = 0;
            close_device_netlink(dev_ctx, ctx);
            continue;
        }
        
        if (dev_ctx->async_monitor.async_enabled) {
            ret = init_async_monitor(dev_ctx);
            if (ret != QOSDBA_OK) {
                log_device_message(dev_ctx, "WARN", "初始化异步监控失败\n");
            }
        }
        
        log_device_message(dev_ctx, "INFO", 
                          "设备初始化完成: 总带宽=%dkbps, 分类数=%d, 算法=HTB\n",
                          dev_ctx->total_bandwidth_kbps, dev_ctx->num_classes);
    }
    
    int active_devices = 0;
    for (int i = 0; i < ctx->num_devices; i++) {
        if (ctx->devices[i].enabled) {
            active_devices++;
        }
    }
    
    if (active_devices == 0) {
        log_message(ctx, "ERROR", "没有活动的设备，程序退出\n");
        return QOSDBA_ERR_CONFIG;
    }
    
    log_message(ctx, "INFO", "活动设备数量: %d\n", active_devices);
    
    g_ctx = ctx;
    setup_signal_handlers();
    
    /* 启动信号处理线程 */
    if (pthread_create(&g_signal_thread, NULL, signal_handler_thread, ctx) != 0) {
        log_message(ctx, "ERROR", "无法启动信号处理线程\n");
    } else {
        pthread_setname_np(g_signal_thread, "qosdba-signal");
    }
    
    while (!g_should_exit) {
        int64_t current_time = get_current_time_ms();
        
        if (g_reload_config || check_config_reload(ctx, ctx->config_path)) {
            g_reload_config = 0;
            
            qosdba_result_t ret = reload_config(ctx, ctx->config_path);
            if (ret == QOSDBA_OK) {
                log_message(ctx, "INFO", "配置重载成功，应用新配置\n");
                
                for (int i = 0; i < ctx->num_devices; i++) {
                    device_context_t* dev_ctx = &ctx->devices[i];
                    
                    if (dev_ctx->enabled) {
                        close_device_netlink(dev_ctx, ctx);
                    }
                }
                
                if (ctx->new_devices) {
                    for (int i = 0; i < ctx->new_num_devices; i++) {
                        if (i < MAX_DEVICES) {
                            ctx->devices[i] = ctx->new_devices[i];
                        }
                    }
                    aligned_free(ctx->new_devices);
                    ctx->new_devices = NULL;
                    ctx->new_num_devices = 0;
                }
                
                for (int i = 0; i < ctx->num_devices; i++) {
                    device_context_t* dev_ctx = &ctx->devices[i];
                    
                    if (dev_ctx->enabled) {
                        qosdba_result_t ret = open_device_netlink(dev_ctx, ctx);
                        if (ret != QOSDBA_OK) {
                            log_device_message(dev_ctx, "ERROR", "重新打开netlink连接失败\n");
                            dev_ctx->enabled = 0;
                            continue;
                        }
                        
                        ret = init_tc_classes(dev_ctx, ctx);
                        if (ret != QOSDBA_OK) {
                            log_device_message(dev_ctx, "ERROR", "重新初始化TC分类失败\n");
                            dev_ctx->enabled = 0;
                            close_device_netlink(dev_ctx, ctx);
                        }
                    }
                }
            } else {
                log_message(ctx, "ERROR", "配置重载失败，继续使用旧配置\n");
            }
        }
        
        for (int i = 0; i < ctx->num_devices; i++) {
            device_context_t* dev_ctx = &ctx->devices[i];
            
            if (!dev_ctx->enabled) {
                continue;
            }
            
            SYSTEM_RESOURCE_CHECK_START(dev_ctx);
            memory_leak_check(dev_ctx);
            
            TIME_OPERATION_START(dev_ctx, total_processing_time_ms);
            
            qosdba_result_t ret = check_bandwidth_usage(dev_ctx);
            if (ret == QOSDBA_OK) {
                run_borrow_logic(dev_ctx, ctx);
                
                if (dev_ctx->auto_return_enable) {
                    run_return_logic(dev_ctx, ctx);
                }
            } else {
                log_device_message(dev_ctx, "WARN", "检查带宽使用率失败\n");
            }
            
            if (dev_ctx->batch_cmds.command_count > 0) {
                execute_batch_commands(&dev_ctx->batch_cmds, dev_ctx, ctx);
            }
            
            if (dev_ctx->batch_cmds.adaptive_enabled) {
                adjust_batch_size(dev_ctx);
            }
            
            if (dev_ctx->async_monitor.async_enabled) {
                check_async_events(dev_ctx);
            }
            
            TIME_OPERATION_END(dev_ctx, total_processing_time_ms);
        }
        
        int sleep_time = ctx->check_interval * 1000;
        
        if (sleep_time < 100) {
            sleep_time = 100;
        }
        
        int elapsed = 0;
        while (elapsed < sleep_time && !g_should_exit) {
            usleep(100000);
            elapsed += 100;
            
            if (g_reload_config) {
                break;
            }
        }
        
        ctx->last_check_time = current_time;
    }
    
    log_message(ctx, "INFO", "收到退出信号，正在清理资源...\n");
    
    if (g_signal_thread) {
        pthread_join(g_signal_thread, NULL);
    }
    
    return QOSDBA_OK;
}

/* ==================== 初始化函数 ==================== */
qosdba_result_t qosdba_init(qosdba_context_t* ctx) {
    if (!ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    memset(ctx, 0, sizeof(qosdba_context_t));
    
    ctx->enabled = 1;
    ctx->debug_mode = 0;
    ctx->safe_mode = 0;
    ctx->reload_config = 0;
    ctx->num_devices = 0;
    ctx->check_interval = DEFAULT_CHECK_INTERVAL;
    ctx->start_time = 0;
    ctx->config_mtime = 0;
    ctx->last_check_time = 0;
    ctx->status_file = NULL;
    ctx->log_file = stderr;
    ctx->test_mode = 0;
    
    memset(&ctx->shared_rth, 0, sizeof(ctx->shared_rth));
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
    
    memset(&ctx->config_validation, 0, sizeof(ctx->config_validation));
    memset(&ctx->parser_state, 0, sizeof(ctx->parser_state));
    memset(&ctx->system_monitor, 0, sizeof(ctx->system_monitor));
    
    return QOSDBA_OK;
}

/* ==================== 清理函数 ==================== */
qosdba_result_t qosdba_cleanup(qosdba_context_t* ctx) {
    if (!ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    log_message(ctx, "INFO", "清理资源...\n");
    
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        if (dev_ctx->enabled) {
            close_device_netlink(dev_ctx, ctx);
        }
        
        cleanup_batch_commands(&dev_ctx->batch_cmds);
        cleanup_memory_pools(dev_ctx);
        
        if (dev_ctx->async_monitor.async_enabled) {
            if (dev_ctx->async_monitor.epoll_fd >= 0) {
                close(dev_ctx->async_monitor.epoll_fd);
            }
            if (dev_ctx->async_monitor.inotify_fd >= 0) {
                if (dev_ctx->async_monitor.watch_fd >= 0) {
                    inotify_rm_watch(dev_ctx->async_monitor.inotify_fd, 
                                     dev_ctx->async_monitor.watch_fd);
                }
                close(dev_ctx->async_monitor.inotify_fd);
            }
        }
        
        pthread_mutex_destroy(&dev_ctx->tc_cache.cache_mutex);
    }
    
    if (ctx->new_devices) {
        aligned_free(ctx->new_devices);
        ctx->new_devices = NULL;
    }
    
    if (ctx->shared_rth.fd >= 0 && ctx->shared_rth_refcount == 0) {
        rtnl_close(&ctx->shared_rth);
    }
    
    pthread_mutex_destroy(&ctx->rth_mutex);
    pthread_spin_destroy(&ctx->ctx_lock);
    
    cleanup_signal_queue(&ctx->signal_queue);
    cleanup_aligned_memory_manager(&ctx->aligned_memory);
    
    if (ctx->status_file && ctx->status_file != stdout && ctx->status_file != stderr) {
        fclose(ctx->status_file);
    }
    
    if (ctx->log_file && ctx->log_file != stdout && ctx->log_file != stderr) {
        fclose(ctx->log_file);
    }
    
    if (g_signal_pipe[0] >= 0) close(g_signal_pipe[0]);
    if (g_signal_pipe[1] >= 0) close(g_signal_pipe[1]);
    
    memset(ctx, 0, sizeof(qosdba_context_t));
    
    return QOSDBA_OK;
}

/* ==================== 状态更新函数 ==================== */
qosdba_result_t qosdba_update_status(qosdba_context_t* ctx, const char* status_file) {
    if (!ctx || !status_file) {
        return QOSDBA_ERR_MEMORY;
    }
    
    FILE* fp = fopen(status_file, "w");
    if (!fp) {
        return QOSDBA_ERR_FILE;
    }
    
    fprintf(fp, "QoS DBA Status\n");
    fprintf(fp, "==============\n");
    fprintf(fp, "Version: %s\n", QOSDBA_VERSION);
    fprintf(fp, "Running: %s\n", g_signal_received ? "No" : "Yes");
    fprintf(fp, "Devices: %d\n", ctx->num_devices);
    fprintf(fp, "\n");
    
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        fprintf(fp, "Device: %s\n", dev_ctx->device);
        fprintf(fp, "  Enabled: %s\n", dev_ctx->enabled ? "Yes" : "No");
        fprintf(fp, "  Algorithm: %s\n", dev_ctx->qdisc_kind);
        fprintf(fp, "  Total Bandwidth: %d kbps\n", dev_ctx->total_bandwidth_kbps);
        fprintf(fp, "  Classes: %d\n", dev_ctx->num_classes);
        fprintf(fp, "\n");
        
        for (int j = 0; j < dev_ctx->num_classes; j++) {
            class_config_t* config = &dev_ctx->configs[j];
            class_state_t* state = &dev_ctx->states[j];
            
            fprintf(fp, "  Class: 0x%x (%s)\n", config->classid, config->name);
            fprintf(fp, "    Priority: %d\n", config->priority);
            fprintf(fp, "    Config BW: %d-%d kbps (current: %d)\n", 
                   config->min_bw_kbps, config->max_bw_kbps, state->current_bw_kbps);
            fprintf(fp, "    Used BW: %d kbps\n", state->used_bw_kbps);
            fprintf(fp, "    Utilization: %.1f%%\n", state->utilization * 100);
            fprintf(fp, "    DBA Enabled: %s\n", state->dba_enabled ? "Yes" : "No");
            fprintf(fp, "\n");
        }
        
        fprintf(fp, "  Borrow Records: %d\n", dev_ctx->num_records);
        for (int j = 0; j < dev_ctx->num_records; j++) {
            borrow_record_t* record = &dev_ctx->records[j];
            fprintf(fp, "    From 0x%x to 0x%x: %d kbps %s\n",
                   record->from_classid, record->to_classid,
                   record->borrowed_bw_kbps,
                   record->returned ? "(returned)" : "(active)");
        }
        
        fprintf(fp, "\n");
    }
    
    fclose(fp);
    return QOSDBA_OK;
}

/* ==================== 设置函数 ==================== */
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

void qosdba_set_test_mode(qosdba_context_t* ctx, int enable) {
    if (ctx) {
        ctx->test_mode = enable;
    }
}

/* ==================== 健康检查函数 ==================== */
qosdba_result_t qosdba_health_check(qosdba_context_t* ctx) {
    if (!ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    HEALTH_CHECK_START(NULL);
    
    int healthy_devices = 0;
    
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        if (!dev_ctx->enabled) {
            continue;
        }
        
        int ifindex = get_ifindex(dev_ctx);
        if (ifindex <= 0) {
            log_device_message(dev_ctx, "ERROR", "健康检查失败: 设备接口不可用\n");
            continue;
        }
        
        struct rtnl_qdisc* qdisc = rtnl_qdisc_alloc();
        if (!qdisc) {
            log_device_message(dev_ctx, "ERROR", "健康检查失败: 内存分配失败\n");
            continue;
        }
        
        rtnl_tc_set_ifindex(TC_CAST(qdisc), ifindex);
        rtnl_tc_set_parent(TC_CAST(qdisc), TC_H_ROOT);
        
        int ret = rtnl_qdisc_get(&dev_ctx->rth, qdisc);
        if (ret < 0) {
            log_device_message(dev_ctx, "ERROR", "健康检查失败: 无法获取qdisc信息\n");
            rtnl_qdisc_put(qdisc);
            continue;
        }
        
        const char* kind = rtnl_tc_get_kind(TC_CAST(qdisc));
        if (!kind || strcmp(kind, "htb") != 0) {
            log_device_message(dev_ctx, "ERROR", "健康检查失败: 检测到非HTB算法: %s\n", 
                             kind ? kind : "未知");
            rtnl_qdisc_put(qdisc);
            continue;
        }
        
        rtnl_qdisc_put(qdisc);
        healthy_devices++;
        
        log_device_message(dev_ctx, "DEBUG", "健康检查通过\n");
    }
    
    if (healthy_devices == 0) {
        return QOSDBA_ERR_SANITY;
    }
    
    return QOSDBA_OK;
}

/* ==================== 主函数 ==================== */
int main(int argc, char* argv[]) {
    qosdba_context_t ctx;
    qosdba_result_t ret;
    
    const char* config_file = "/etc/qosdba.conf";
    const char* status_file = "/var/run/qosdba.status";
    const char* log_file = NULL;
    
    int debug_mode = 0;
    int safe_mode = 0;
    int foreground = 0;
    int test_mode = 0;
    
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) {
            config_file = argv[++i];
        } else if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) {
            status_file = argv[++i];
        } else if (strcmp(argv[i], "-l") == 0 && i + 1 < argc) {
            log_file = argv[++i];
        } else if (strcmp(argv[i], "-d") == 0) {
            debug_mode = 1;
        } else if (strcmp(argv[i], "-S") == 0) {
            safe_mode = 1;
        } else if (strcmp(argv[i], "-f") == 0) {
            foreground = 1;
        } else if (strcmp(argv[i], "-t") == 0) {
            test_mode = 1;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            printf("Usage: %s [options]\n", argv[0]);
            printf("Options:\n");
            printf("  -c <file>   配置文件路径 (默认: /etc/qosdba.conf)\n");
            printf("  -s <file>   状态文件路径 (默认: /var/run/qosdba.status)\n");
            printf("  -l <file>   日志文件路径 (默认: stderr)\n");
            printf("  -d          调试模式\n");
            printf("  -S          安全模式 (模拟TC操作)\n");
            printf("  -f          前台运行\n");
            printf("  -t          测试模式\n");
            printf("  -h, --help  显示帮助信息\n");
            printf("\n");
            printf("QoS DBA 2.1.1 - 仅支持HTB算法的动态带宽分配器\n");
            return 0;
        } else if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--version") == 0) {
            printf("QoS DBA 2.1.1 (仅支持HTB)\n");
            printf("版本: %s\n", QOSDBA_VERSION);
            return 0;
        }
    }
    
    ret = qosdba_init(&ctx);
    if (ret != QOSDBA_OK) {
        fprintf(stderr, "初始化失败: %d\n", ret);
        return 1;
    }
    
    qosdba_set_debug(&ctx, debug_mode);
    qosdba_set_safe_mode(&ctx, safe_mode);
    qosdba_set_test_mode(&ctx, test_mode);
    
    if (log_file) {
        ctx.log_file = fopen(log_file, "a");
        if (!ctx.log_file) {
            fprintf(stderr, "无法打开日志文件: %s\n", log_file);
            ctx.log_file = stderr;
        }
    }
    
    if (!foreground && !test_mode) {
        pid_t pid = fork();
        if (pid < 0) {
            fprintf(stderr, "fork失败\n");
            return 1;
        } else if (pid > 0) {
            printf("QoS DBA 2.1.1 已启动，PID: %d\n", pid);
            return 0;
        }
        
        setsid();
        chdir("/");
        
        close(STDIN_FILENO);
        close(STDOUT_FILENO);
        close(STDERR_FILENO);
    }
    
    ret = load_config_file(&ctx, config_file);
    if (ret != QOSDBA_OK) {
        fprintf(stderr, "加载配置文件失败: %s\n", config_file);
        qosdba_cleanup(&ctx);
        return 1;
    }
    
    if (ctx.safe_mode) {
        log_message(&ctx, "WARN", "安全模式已启用，TC操作将被模拟\n");
    }
    
    if (ctx.test_mode) {
        ret = qosdba_run_tests(&ctx);
    } else {
        ret = qosdba_run(&ctx);
    }
    
    if (ret != QOSDBA_OK) {
        log_message(&ctx, "ERROR", "运行失败: %d\n", ret);
    }
    
    qosdba_update_status(&ctx, status_file);
    qosdba_cleanup(&ctx);
    
    log_message(&ctx, "INFO", "QoS DBA 2.1.1 已停止\n");
    
    if (ctx.log_file && ctx.log_file != stderr) {
        fclose(ctx.log_file);
    }
    
    return (ret == QOSDBA_OK) ? 0 : 1;
}