// config_parser.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uci.h>
#include "config_parser.h"
#include "qos_dba.h"

// 全局变量
qos_dba_system_t g_qos_system = {0};

// 日志函数实现
void DEBUG_LOG(const char *format, ...) {
    va_list args;
    va_start(args, format);
    fprintf(stderr, "DEBUG: ");
    vfprintf(stderr, format, args);
    fprintf(stderr, "\n");
    va_end(args);
}

void ERROR_LOG(const char *format, ...) {
    va_list args;
    va_start(args, format);
    fprintf(stderr, "ERROR: ");
    vfprintf(stderr, format, args);
    fprintf(stderr, "\n");
    va_end(args);
}

void INFO_LOG(const char *format, ...) {
    va_list args;
    va_start(args, format);
    fprintf(stderr, "INFO: ");
    vfprintf(stderr, format, args);
    fprintf(stderr, "\n");
    va_end(args);
}

// 全局变量
qos_dba_system_t g_qos_system = {0};

// 辅助函数：从UCI获取字符串值
static char* uci_get_string(struct uci_context *ctx, struct uci_section *s, const char *option) {
    struct uci_element *e = NULL;
    struct uci_option *o = NULL;
    
    uci_foreach_element(&s->options, e) {
        o = uci_to_option(e);
        if (strcmp(o->e.name, option) == 0) {
            return o->v.string;
        }
    }
    return NULL;
}

// 辅助函数：从UCI获取整数值
static int uci_get_int(struct uci_context *ctx, struct uci_section *s, const char *option, int default_value) {
    char *str = uci_get_string(ctx, s, option);
    if (str) {
        return atoi(str);
    }
    return default_value;
}

// 辅助函数：从UCI获取浮点数值
static float uci_get_float(struct uci_context *ctx, struct uci_section *s, const char *option, float default_value) {
    char *str = uci_get_string(ctx, s, option);
    if (str) {
        return atof(str);
    }
    return default_value;
}

// 加载DBA配置
int load_dba_config() {
    struct uci_context *ctx = uci_alloc_context();
    if (!ctx) {
        DEBUG_LOG("无法创建UCI上下文");
        return -1;
    }
    
    struct uci_package *pkg = NULL;
    if (uci_load(ctx, "qos_gargoyle", &pkg) != UCI_OK) {
        DEBUG_LOG("无法加载qos_gargoyle配置");
        uci_free_context(ctx);
        return -1;
    }
    
    // 尝试查找dba节
    struct uci_element *e = NULL;
    int dba_found = 0;
    
    uci_foreach_element(&pkg->sections, e) {
        struct uci_section *s = uci_to_section(e);
        if (strcmp(s->type, "dba") == 0) {
            dba_found = 1;
            
            // 读取DBA配置参数
            g_qos_system.enabled = uci_get_int(ctx, s, "enabled", 1);
            g_qos_system.interval = uci_get_int(ctx, s, "interval", 5);
            g_qos_system.high_usage_threshold = uci_get_int(ctx, s, "high_usage_threshold", 85);
            g_qos_system.high_usage_duration = uci_get_int(ctx, s, "high_usage_duration", 5);
            g_qos_system.low_usage_threshold = uci_get_int(ctx, s, "low_usage_threshold", 30);
            g_qos_system.low_usage_duration = uci_get_int(ctx, s, "low_usage_duration", 10);
            g_qos_system.borrow_ratio = uci_get_float(ctx, s, "borrow_ratio", 0.5);
            g_qos_system.min_borrow_kbps = uci_get_int(ctx, s, "min_borrow_kbps", 64);
            g_qos_system.min_change_kbps = uci_get_int(ctx, s, "min_change_kbps", 32);
            g_qos_system.cooldown_time = uci_get_int(ctx, s, "cooldown_time", 10);
            g_qos_system.auto_return_enable = uci_get_int(ctx, s, "auto_return_enable", 1);
            g_qos_system.return_threshold = uci_get_int(ctx, s, "return_threshold", 50);
            g_qos_system.return_speed = uci_get_float(ctx, s, "return_speed", 0.1);
            
            DEBUG_LOG("加载DBA配置成功");
            break;
        }
    }
    
    if (!dba_found) {
        DEBUG_LOG("未找到DBA配置，使用默认值");
        // 设置默认值
        g_qos_system.enabled = 1;
        g_qos_system.interval = 5;
        g_qos_system.high_usage_threshold = 85;
        g_qos_system.high_usage_duration = 5;
        g_qos_system.low_usage_threshold = 30;
        g_qos_system.low_usage_duration = 10;
        g_qos_system.borrow_ratio = 0.5;
        g_qos_system.min_borrow_kbps = 64;
        g_qos_system.min_change_kbps = 32;
        g_qos_system.cooldown_time = 10;
        g_qos_system.auto_return_enable = 1;
        g_qos_system.return_threshold = 50;
        g_qos_system.return_speed = 0.1;
    }
    
    uci_unload(ctx, pkg);
    uci_free_context(ctx);
    
    // 打印加载的配置
    DEBUG_LOG("DBA配置：");
    DEBUG_LOG("  启用: %d", g_qos_system.enabled);
    DEBUG_LOG("  检查间隔: %d秒", g_qos_system.interval);
    DEBUG_LOG("  高使用阈值: %d%%", g_qos_system.high_usage_threshold);
    DEBUG_LOG("  高使用持续时间: %d秒", g_qos_system.high_usage_duration);
    DEBUG_LOG("  低使用阈值: %d%%", g_qos_system.low_usage_threshold);
    DEBUG_LOG("  低使用持续时间: %d秒", g_qos_system.low_usage_duration);
    DEBUG_LOG("  借用比例: %.1f", g_qos_system.borrow_ratio);
    DEBUG_LOG("  最小借用: %d kbps", g_qos_system.min_borrow_kbps);
    DEBUG_LOG("  最小调整: %d kbps", g_qos_system.min_change_kbps);
    DEBUG_LOG("  冷却时间: %d秒", g_qos_system.cooldown_time);
    DEBUG_LOG("  自动归还: %d", g_qos_system.auto_return_enable);
    DEBUG_LOG("  归还阈值: %d%%", g_qos_system.return_threshold);
    DEBUG_LOG("  归还速度: %.1f", g_qos_system.return_speed);
    
    return 0;
}

// 加载QoS分类
int load_qos_classes() {
    DEBUG_LOG("加载QoS分类配置...");
    
    // 首先尝试从UCI加载配置
    struct uci_context *ctx = uci_alloc_context();
    if (!ctx) {
        DEBUG_LOG("无法创建UCI上下文");
        return -1;
    }
    
    struct uci_package *pkg = NULL;
    if (uci_load(ctx, "qos_gargoyle", &pkg) != UCI_OK) {
        DEBUG_LOG("无法加载qos_gargoyle配置");
        uci_free_context(ctx);
        return -1;
    }
    
    // 统计分类数量
    int upload_count = 0;
    int download_count = 0;
    struct uci_element *e = NULL;
    
    uci_foreach_element(&pkg->sections, e) {
        struct uci_section *s = uci_to_section(e);
        if (strcmp(s->type, "upload_class") == 0) {
            upload_count++;
        } else if (strcmp(s->type, "download_class") == 0) {
            download_count++;
        }
    }
    
    DEBUG_LOG("发现上传分类: %d, 下载分类: %d", upload_count, download_count);
    
    // 分配内存
    g_qos_system.upload_classes = (qos_class_t *)calloc(upload_count, sizeof(qos_class_t));
    g_qos_system.download_classes = (qos_class_t *)calloc(download_count, sizeof(qos_class_t));
    
    if (!g_qos_system.upload_classes || !g_qos_system.download_classes) {
        DEBUG_LOG("内存分配失败");
        if (g_qos_system.upload_classes) free(g_qos_system.upload_classes);
        if (g_qos_system.download_classes) free(g_qos_system.download_classes);
        g_qos_system.upload_classes = NULL;
        g_qos_system.download_classes = NULL;
        uci_unload(ctx, pkg);
        uci_free_context(ctx);
        return -1;
    }
    
    g_qos_system.upload_class_count = 0;
    g_qos_system.download_class_count = 0;
    
    int upload_idx = 0;
    int download_idx = 0;
    
    uci_foreach_element(&pkg->sections, e) {
        struct uci_section *s = uci_to_section(e);
        qos_class_t *cls = NULL;
        int is_upload = 0;
        
        if (strcmp(s->type, "upload_class") == 0) {
            if (upload_idx >= upload_count) continue;
            cls = &g_qos_system.upload_classes[upload_idx];
            is_upload = 1;
        } else if (strcmp(s->type, "download_class") == 0) {
            if (download_idx >= download_count) continue;
            cls = &g_qos_system.download_classes[download_idx];
            is_upload = 0;
        } else {
            continue;
        }
        
        // 获取分类名称
        char *name = uci_get_string(ctx, s, "name");
        if (name && strlen(name) > 0) {
            strncpy(cls->name, name, sizeof(cls->name) - 1);
            cls->name[sizeof(cls->name) - 1] = '\0';
        } else {
            snprintf(cls->name, sizeof(cls->name), "%s_class_%d", 
                    is_upload ? "upload" : "download", 
                    is_upload ? upload_idx : download_idx);
        }
        
        // 生成classid
        if (is_upload) {
            snprintf(cls->classid, sizeof(cls->classid), "1:1%02d", upload_idx);
        } else {
            snprintf(cls->classid, sizeof(cls->classid), "1:2%02d", download_idx);
        }
        
        // 获取带宽配置
        char *percent_str = uci_get_string(ctx, s, "percent_bandwidth");
        char *min_kbps_str = uci_get_string(ctx, s, "min_bandwidth");
        char *max_kbps_str = uci_get_string(ctx, s, "max_bandwidth");
        char *priority_str = uci_get_string(ctx, s, "priority");
        
        int percent = percent_str ? atoi(percent_str) : 10;
        int min_kbps = min_kbps_str ? atoi(min_kbps_str) : 0;
        int max_kbps = max_kbps_str ? atoi(max_kbps_str) : 0;
        int priority = priority_str ? atoi(priority_str) : (is_upload ? upload_idx : download_idx);
        
        // 计算最小带宽（如果配置了百分比）
        if (min_kbps == 0 && g_qos_system.total_bandwidth_kbps > 0 && percent > 0) {
            min_kbps = (g_qos_system.total_bandwidth_kbps * percent) / 100;
        }
        
        // 计算最大带宽
        if (max_kbps <= 0) {
            max_kbps = min_kbps * 2; // 默认是min的2倍
        }
        
        // 设置带宽
        cls->min_kbps = min_kbps;
        cls->max_kbps = max_kbps;
        cls->current_kbps = min_kbps;
        cls->used_kbps = 0;
        cls->usage_rate = 0.0f;
        cls->priority = priority;
        cls->enabled = 1;
        cls->adjusted = 0;
        cls->peak_usage_kbps = 0;
        cls->adjust_count = 0;
        cls->last_adjust_time = 0;
        cls->last_borrow_time = 0;
        cls->last_lend_time = 0;
        
        // 初始化借出/借入记录
        for (int j = 0; j < MAX_BORROW_RELATIONS; j++) {
            cls->borrowed_from[j] = -1;
            cls->lent_to[j] = -1;
        }
        
        DEBUG_LOG("加载分类: %s, ID: %s, 最小: %d kbps, 最大: %d kbps, 优先级: %d",
                  cls->name, cls->classid, cls->min_kbps, cls->max_kbps, cls->priority);
        
        if (is_upload) {
            upload_idx++;
            g_qos_system.upload_class_count++;
        } else {
            download_idx++;
            g_qos_system.download_class_count++;
        }
    }
    
    uci_unload(ctx, pkg);
    uci_free_context(ctx);
    
    DEBUG_LOG("分类加载完成: 上传%d个, 下载%d个", 
              g_qos_system.upload_class_count, g_qos_system.download_class_count);
    
    return 0;
}

// 验证QoS分类配置
int validate_qos_classes() {
    DEBUG_LOG("验证QoS分类配置...");
    
    int total_min_kbps = 0;
    int total_max_kbps = 0;
    int error_count = 0;
    
    // 验证上传分类
    for (int i = 0; i < g_qos_system.upload_class_count; i++) {
        qos_class_t *cls = &g_qos_system.upload_classes[i];
        
        if (cls->min_kbps <= 0) {
            ERROR_LOG("上传分类 %d (%s) 的最小带宽必须大于0", i, cls->name);
            error_count++;
        }
        
        if (cls->max_kbps <= 0) {
            ERROR_LOG("上传分类 %d (%s) 的最大带宽必须大于0", i, cls->name);
            error_count++;
        }
        
        if (cls->max_kbps < cls->min_kbps) {
            ERROR_LOG("上传分类 %d (%s) 的最大带宽不能小于最小带宽", i, cls->name);
            error_count++;
        }
        
        total_min_kbps += cls->min_kbps;
        total_max_kbps += cls->max_kbps;
        
        DEBUG_LOG("上传分类[%d]: %s, 最小: %d, 最大: %d, 优先级: %d", 
                  i, cls->name, cls->min_kbps, cls->max_kbps, cls->priority);
    }
    
    // 验证下载分类
    for (int i = 0; i < g_qos_system.download_class_count; i++) {
        qos_class_t *cls = &g_qos_system.download_classes[i];
        
        if (cls->min_kbps <= 0) {
            ERROR_LOG("下载分类 %d (%s) 的最小带宽必须大于0", i, cls->name);
            error_count++;
        }
        
        if (cls->max_kbps <= 0) {
            ERROR_LOG("下载分类 %d (%s) 的最大带宽必须大于0", i, cls->name);
            error_count++;
        }
        
        if (cls->max_kbps < cls->min_kbps) {
            ERROR_LOG("下载分类 %d (%s) 的最大带宽不能小于最小带宽", i, cls->name);
            error_count++;
        }
        
        total_min_kbps += cls->min_kbps;
        total_max_kbps += cls->max_kbps;
        
        DEBUG_LOG("下载分类[%d]: %s, 最小: %d, 最大: %d, 优先级: %d", 
                  i, cls->name, cls->min_kbps, cls->max_kbps, cls->priority);
    }
    
    if (g_qos_system.total_bandwidth_kbps > 0) {
        if (total_min_kbps > g_qos_system.total_bandwidth_kbps) {
            ERROR_LOG("总最小带宽(%d)超过总带宽(%d)", total_min_kbps, g_qos_system.total_bandwidth_kbps);
            error_count++;
        }
        
        if (total_max_kbps > g_qos_system.total_bandwidth_kbps * 2) {
            DEBUG_LOG("警告: 总最大带宽(%d)超过总带宽2倍(%d)", total_max_kbps, g_qos_system.total_bandwidth_kbps * 2);
        }
    }
    
    if (error_count > 0) {
        ERROR_LOG("发现%d个配置错误", error_count);
        return -1;
    }
    
    DEBUG_LOG("分类验证通过: 总最小带宽=%d, 总最大带宽=%d", total_min_kbps, total_max_kbps);
    return 0;
}

// 获取指定分类
qos_class_t* get_qos_class(const char *classid, int is_upload) {
    if (!classid) return NULL;
    
    if (is_upload) {
        for (int i = 0; i < g_qos_system.upload_class_count; i++) {
            if (strcmp(g_qos_system.upload_classes[i].classid, classid) == 0) {
                return &g_qos_system.upload_classes[i];
            }
        }
    } else {
        for (int i = 0; i < g_qos_system.download_class_count; i++) {
            if (strcmp(g_qos_system.download_classes[i].classid, classid) == 0) {
                return &g_qos_system.download_classes[i];
            }
        }
    }
    
    return NULL;
}

// 保存配置到UCI
int save_qos_config_to_uci() {
    if (!g_qos_system.ctx) {
        ERROR_LOG("无效的参数");
        return -1;
    }
    
    INFO_LOG("保存配置到UCI（功能暂时简化）");
    
    // 这里应该实现保存配置到UCI的逻辑
    // 由于UCI库的复杂性，这里暂时简化
    
    return 0;
}

// 清理资源
void cleanup_qos_config() {
    if (g_qos_system.upload_classes) {
        free(g_qos_system.upload_classes);
        g_qos_system.upload_classes = NULL;
    }
    
    if (g_qos_system.download_classes) {
        free(g_qos_system.download_classes);
        g_qos_system.download_classes = NULL;
    }
    
    g_qos_system.upload_class_count = 0;
    g_qos_system.download_class_count = 0;
    
    DEBUG_LOG("配置资源已清理");
}