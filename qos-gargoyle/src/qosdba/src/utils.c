/*
 * utils.c - 工具函数模块
 * 实现通用工具函数、时间管理、字符串处理
 * 版本: 2.1.1
 */

#include "qosdba.h"
#include <stdarg.h>
#include <sys/time.h>

/* ==================== 时间管理函数 ==================== */

int64_t get_current_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

static const char* get_current_timestamp(void) {
    static char timestamp[32];
    time_t now = time(NULL);
    struct tm* tm_info = localtime(&now);
    
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", tm_info);
    return timestamp;
}

/* 获取文件修改时间 */
int get_file_mtime(const char* filename) {
    struct stat st;
    if (stat(filename, &st) == 0) {
        return st.st_mtime;
    }
    return 0;
}

/* ==================== 字符串处理函数 ==================== */

/* 安全的字符串复制 */
char* safe_strncpy(char* dest, const char* src, size_t dest_size) {
    if (!dest || !src || dest_size == 0) {
        return NULL;
    }
    
    size_t src_len = strlen(src);
    size_t copy_len = (src_len < dest_size) ? src_len : (dest_size - 1);
    
    if (copy_len > 0) {
        memcpy(dest, src, copy_len);
    }
    dest[copy_len] = '\0';
    
    return dest;
}

/* 安全的字符串连接 */
char* safe_strncat(char* dest, const char* src, size_t dest_size) {
    if (!dest || !src || dest_size == 0) {
        return dest;
    }
    
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

/* 安全的格式化输出 */
int safe_snprintf(char* str, size_t size, const char* format, ...) {
    if (!str || !format || size == 0) {
        return -1;
    }
    
    va_list args;
    va_start(args, format);
    int result = vsnprintf(str, size, format, args);
    va_end(args);
    
    if (result < 0 || (size_t)result >= size) {
        str[size - 1] = '\0';
    }
    
    return result;
}

/* 去除字符串首尾空白字符 */
void trim_whitespace(char* str) {
    if (!str) return;
    
    char* end;
    
    /* 去除开头空白 */
    while (isspace((unsigned char)*str)) str++;
    
    if (*str == 0) return;
    
    /* 去除结尾空白 */
    end = str + strlen(str) - 1;
    while (end > str && isspace((unsigned char)*end)) end--;
    
    end[1] = '\0';
}

/* 检查设备名是否有效 */
int is_valid_device_name(const char* name) {
    if (!name || *name == '\0') return 0;
    
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

/* 解析键值对 */
int parse_key_value(const char* line, char* key, int key_len, 
                   char* value, int value_len) {
    if (!line || !key || !value) return 0;
    
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

/* ==================== 内存管理辅助函数 ==================== */

void* aligned_malloc(size_t size, size_t alignment) {
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

void aligned_free(void* ptr) {
    if (!ptr) {
        return;
    }
    
    uintptr_t aligned_addr = (uintptr_t)ptr;
    void** header = (void**)(aligned_addr - sizeof(void*));
    void* original_ptr = *header;
    
    free(original_ptr);
}

/* ==================== 浮点数比较函数 ==================== */

bool float_equal(float a, float b, float epsilon) {
    if (epsilon < 0.0f) {
        epsilon = 0.000001f;
    }
    
    return fabsf(a - b) <= epsilon;
}

bool float_less(float a, float b, float epsilon) {
    if (epsilon < 0.0f) {
        epsilon = 0.000001f;
    }
    
    return (b - a) > epsilon;
}

bool float_greater(float a, float b, float epsilon) {
    if (epsilon < 0.0f) {
        epsilon = 0.000001f;
    }
    
    return (a - b) > epsilon;
}

bool float_less_or_equal(float a, float b, float epsilon) {
    if (epsilon < 0.0f) {
        epsilon = 0.000001f;
    }
    
    return (a - b) <= epsilon;
}

bool float_greater_or_equal(float a, float b, float epsilon) {
    if (epsilon < 0.0f) {
        epsilon = 0.000001f;
    }
    
    return (b - a) <= epsilon;
}

/* ==================== 日志系统 ==================== */

void log_message(qosdba_context_t* ctx, const char* level, 
                const char* format, ...) {
    if (!ctx) {
        return;
    }
    
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

void log_device_message(device_context_t* dev_ctx, const char* level,
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

qosdba_result_t resilient_nl_operation(device_context_t* dev_ctx, 
                                      int (*func)(device_context_t*, void*), 
                                      void* arg) {
    if (!dev_ctx || !func) {
        return QOSDBA_ERR_MEMORY;
    }
    
    int attempt = 0;
    int max_retries = 3;
    int base_delay_ms = 100;
    
    while (attempt < max_retries) {
        int result = func(dev_ctx, arg);
        
        if (result == 0) {
            return QOSDBA_OK;
        }
        
        attempt++;
        dev_ctx->perf_stats.retry_attempts++;
        
        if (attempt < max_retries) {
            int delay_ms = base_delay_ms * (1 << (attempt - 1));
            if (delay_ms > 5000) {
                delay_ms = 5000;
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

qosdba_result_t retry_with_backoff(device_context_t* dev_ctx,
                                 int (*func)(device_context_t*, void*),
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
            if (delay_ms > 5000) {
                delay_ms = 5000;
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
    
    memset(&ctx->signal_queue, 0, sizeof(ctx->signal_queue));
    memset(&ctx->system_monitor, 0, sizeof(ctx->system_monitor));
    
    return QOSDBA_OK;
}

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