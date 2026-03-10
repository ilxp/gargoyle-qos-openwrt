/*
 * config.c - 配置管理模块 (优化修复版)
 * 实现配置文件解析、验证、重载功能
 * 版本: 2.1.1
 * 修复: 添加对优化参数的支持
 */

#include "qosdba.h"
#include <ctype.h>
#include <sys/stat.h>

/* ==================== 配置文件解析 ==================== */

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

/* 解析CSV格式的分类配置行 */
qosdba_result_t parse_config_line(const char* line, int line_number, 
                                 int* classid, char* name, size_t name_size,
                                 int* priority, int* total_bw_kbps, 
                                 int* min_bw_kbps, int* max_bw_kbps, 
                                 int* dba_enabled) {
    if (!line || !classid || !name || !priority || !total_bw_kbps || 
        !min_bw_kbps || !max_bw_kbps || !dba_enabled) {
        return QOSDBA_ERR_PARSING;
    }
    
    char* tokens[10] = {0};
    int token_count = 0;
    
    /* 复制行以便解析 */
    char* line_copy = strdup(line);
    if (!line_copy) {
        return QOSDBA_ERR_MEMORY;
    }
    
    /* 分割CSV */
    char* token = strtok(line_copy, ",");
    while (token && token_count < 10) {
        trim_whitespace(token);
        tokens[token_count++] = token;
        token = strtok(NULL, ",");
    }
    
    if (token_count < 6 || token_count > 7) {
        free(line_copy);
        return QOSDBA_ERR_PARSING;
    }
    
    /* 解析分类ID */
    int parsed_classid = 0;
    if (sscanf(tokens[0], "0x%x", &parsed_classid) != 1) {
        free(line_copy);
        return QOSDBA_ERR_PARSING;
    }
    
    /* 解析名称 */
    strncpy(name, tokens[1], name_size - 1);
    name[name_size - 1] = '\0';
    
    /* 解析其他字段 */
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
    
    free(line_copy);
    return QOSDBA_OK;
}

/* 验证配置参数 */
int validate_config_parameters(device_context_t* dev_ctx) {
    if (!dev_ctx) return 0;
    
    /* 检查总带宽 */
    if (dev_ctx->total_bandwidth_kbps <= 0 || 
        dev_ctx->total_bandwidth_kbps > 10000000) {
        log_message(NULL, "ERROR", "设备 %s 的总带宽无效: %d kbps\n", 
                   dev_ctx->device, dev_ctx->total_bandwidth_kbps);
        return 0;
    }
    
    /* 检查使用率阈值 */
    if (dev_ctx->borrow_trigger_threshold <= dev_ctx->lend_trigger_threshold) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的借用触发阈值(%d%%)必须大于借出触发阈值(%d%%)\n",
                   dev_ctx->device, dev_ctx->borrow_trigger_threshold, 
                   dev_ctx->lend_trigger_threshold);
        return 0;
    }
    
    if (dev_ctx->borrow_trigger_threshold < 70 || 
        dev_ctx->borrow_trigger_threshold > 100) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的借用触发阈值(%d%%)超出范围(70-100)\n",
                   dev_ctx->device, dev_ctx->borrow_trigger_threshold);
        return 0;
    }
    
    if (dev_ctx->lend_trigger_threshold < 10 || 
        dev_ctx->lend_trigger_threshold > 50) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的借出触发阈值(%d%%)超出范围(10-50)\n",
                   dev_ctx->device, dev_ctx->lend_trigger_threshold);
        return 0;
    }
    
    if (dev_ctx->return_threshold < 20 || 
        dev_ctx->return_threshold > 70) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的归还触发阈值(%d%%)超出范围(20-70)\n",
                   dev_ctx->device, dev_ctx->return_threshold);
        return 0;
    }
    
    /* 检查连续时间窗口 */
    if (dev_ctx->continuous_seconds < 3 || 
        dev_ctx->continuous_seconds > 10) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的连续时间窗口(%d秒)超出范围(3-10)\n",
                   dev_ctx->device, dev_ctx->continuous_seconds);
        return 0;
    }
    
    /* 检查借用比例 */
    if (dev_ctx->borrow_ratio < 0.01f || dev_ctx->borrow_ratio > 1.0f) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的借用比例(%.2f)超出范围(0.01-1.0)\n",
                   dev_ctx->device, dev_ctx->borrow_ratio);
        return 0;
    }
    
    if (dev_ctx->max_borrow_ratio < 0.1f || dev_ctx->max_borrow_ratio > 0.5f) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的最大借用比例(%.2f)超出范围(0.1-0.5)\n",
                   dev_ctx->device, dev_ctx->max_borrow_ratio);
        return 0;
    }
    
    if (dev_ctx->max_lend_ratio < 0.2f || dev_ctx->max_lend_ratio > 0.8f) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的最大借出比例(%.2f)超出范围(0.2-0.8)\n",
                   dev_ctx->device, dev_ctx->max_lend_ratio);
        return 0;
    }
    
    /* 检查最小调整带宽 */
    if (dev_ctx->min_change_kbps <= 0) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的最小调整带宽(%d kbps)必须大于0\n",
                   dev_ctx->device, dev_ctx->min_change_kbps);
        return 0;
    }
    
    /* 检查优先级间隔 */
    if (dev_ctx->min_priority_gap < 1 || dev_ctx->min_priority_gap > 5) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的最小优先级间隔(%d)超出范围(1-5)\n",
                   dev_ctx->device, dev_ctx->min_priority_gap);
        return 0;
    }
    
    /* 检查保护机制参数 */
    if (dev_ctx->keep_for_self_ratio < 1.1f || dev_ctx->keep_for_self_ratio > 2.0f) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的为自己保留比例(%.2f)超出范围(1.1-2.0)\n",
                   dev_ctx->device, dev_ctx->keep_for_self_ratio);
        return 0;
    }
    
    if (dev_ctx->starvation_warning < 50 || dev_ctx->starvation_warning > 90) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的饿死警戒线(%d%%)超出范围(50-90)\n",
                   dev_ctx->device, dev_ctx->starvation_warning);
        return 0;
    }
    
    if (dev_ctx->starvation_critical < 70 || dev_ctx->starvation_critical > 95) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的饿死紧急线(%d%%)超出范围(70-95)\n",
                   dev_ctx->device, dev_ctx->starvation_critical);
        return 0;
    }
    
    if (dev_ctx->emergency_return_ratio < 0.1f || dev_ctx->emergency_return_ratio > 1.0f) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的紧急归还比例(%.2f)超出范围(0.1-1.0)\n",
                   dev_ctx->device, dev_ctx->emergency_return_ratio);
        return 0;
    }
    
    if (dev_ctx->high_priority_protect_level < 80 || 
        dev_ctx->high_priority_protect_level > 100) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的高优先级保护线(%d%%)超出范围(80-100)\n",
                   dev_ctx->device, dev_ctx->high_priority_protect_level);
        return 0;
    }
    
    /* 检查多源借用参数 */
    if (dev_ctx->max_borrow_sources < 1 || dev_ctx->max_borrow_sources > 5) {
        log_message(NULL, "ERROR", 
                   "设备 %s 的最大借用源数量(%d)超出范围(1-5)\n",
                   dev_ctx->device, dev_ctx->max_borrow_sources);
        return 0;
    }
    
    /* 检查分类配置 */
    int total_class_bandwidth = 0;
    int used_priorities[MAX_CLASSES] = {0};
    int dba_enabled_count = 0;
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_config_t* config = &dev_ctx->configs[i];
        
        if (i >= MAX_CLASSES) {
            log_message(NULL, "ERROR", "分类数量超过最大值 %d\n", MAX_CLASSES);
            return 0;
        }
        
        /* 检查带宽范围 */
        if (config->min_bw_kbps > config->max_bw_kbps) {
            log_message(NULL, "ERROR", 
                       "分类 %s 的最小带宽(%d)大于最大带宽(%d)\n",
                       config->name, config->min_bw_kbps, config->max_bw_kbps);
            return 0;
        }
        
        if (config->total_bw_kbps < config->min_bw_kbps || 
            config->total_bw_kbps > config->max_bw_kbps) {
            log_message(NULL, "ERROR", 
                       "分类 %s 的总带宽(%d)不在最小-最大范围内(%d-%d)\n",
                       config->name, config->total_bw_kbps, 
                       config->min_bw_kbps, config->max_bw_kbps);
            return 0;
        }
        
        /* 检查优先级 */
        if (config->priority < 0 || config->priority >= MAX_CLASSES) {
            log_message(NULL, "ERROR", 
                       "分类 %s 的优先级 %d 超出范围(0-%d)\n",
                       config->name, config->priority, MAX_CLASSES-1);
            return 0;
        }
        
        if (used_priorities[config->priority]) {
            log_message(NULL, "ERROR", 
                       "优先级 %d 被多个分类使用，必须唯一\n", config->priority);
            return 0;
        }
        used_priorities[config->priority] = 1;
        
        /* 统计启用DBA的分类 */
        if (config->dba_enabled) {
            dba_enabled_count++;
        }
        
        total_class_bandwidth += config->total_bw_kbps;
    }
    
    /* 检查DBA启用分类数量 */
    if (dba_enabled_count < 2) {
        log_message(NULL, "ERROR", 
                   "设备 %s 必须至少有2个启用DBA的分类，当前启用DBA的分类数: %d\n",
                   dev_ctx->device, dba_enabled_count);
        return 0;
    }
    
    /* 检查总带宽分配 */
    if (total_class_bandwidth > dev_ctx->total_bandwidth_kbps * 1.2f) {
        log_message(NULL, "WARN", 
                   "设备 %s 的分类总带宽(%d kbps)超过设备总带宽(%d kbps)\n",
                   dev_ctx->device, total_class_bandwidth, 
                   dev_ctx->total_bandwidth_kbps);
    }
    
    return 1;
}

/* ==================== 配置文件加载 ==================== */

qosdba_result_t load_config_file(qosdba_context_t* ctx, const char* config_file) {
    if (!ctx || !config_file) {
        return QOSDBA_ERR_MEMORY;
    }
    
    FILE* fp = fopen(config_file, "r");
    if (!fp) {
        log_message(ctx, "ERROR", "无法打开配置文件: %s\n", config_file);
        return QOSDBA_ERR_FILE;
    }
    
    char line[MAX_CONFIG_LINE];
    int line_num = 0;
    device_context_t* current_dev = NULL;
    int device_count = 0;
    
    /* 初始化设备数组 */
    for (int i = 0; i < MAX_DEVICES; i++) {
        memset(&ctx->devices[i], 0, sizeof(device_context_t));
    }
    ctx->num_devices = 0;
    
    /* 读取配置文件 */
    while (fgets(line, sizeof(line), fp) && device_count < MAX_DEVICES) {
        line_num++;
        
        /* 去除换行符 */
        char* newline = strchr(line, '\n');
        if (newline) *newline = '\0';
        
        newline = strchr(line, '\r');
        if (newline) *newline = '\0';
        
        trim_whitespace(line);
        
        /* 跳过注释和空行 */
        if (line[0] == '#' || line[0] == '\0') {
            continue;
        }
        
        /* 解析设备节 */
        if (line[0] == '[' && strchr(line, ']')) {
            char section[128];
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
                    strncpy(current_dev->device, device_name, MAX_DEVICE_NAME_LEN);
                    current_dev->device[MAX_DEVICE_NAME_LEN] = '\0';
                    current_dev->enabled = 1;
                    current_dev->owner_ctx = ctx;
                    
                    /* 设置默认值 */
                    current_dev->borrow_trigger_threshold = 90;  /* 默认90% */
                    current_dev->lend_trigger_threshold = 30;    /* 默认30% */
                    current_dev->continuous_seconds = 5;         /* 默认5秒 */
                    current_dev->max_borrow_ratio = 0.3f;        /* 默认30% */
                    current_dev->min_priority_gap = 2;           /* 默认2级 */
                    current_dev->keep_for_self_ratio = 1.2f;     /* 默认1.2 */
                    current_dev->max_lend_ratio = 0.5f;          /* 默认50% */
                    current_dev->enable_multi_source_borrow = 1; /* 默认启用 */
                    current_dev->max_borrow_sources = 3;         /* 默认3个 */
                    current_dev->load_balance_mode = 1;          /* 默认负载均衡 */
                    current_dev->starvation_warning = 80;        /* 默认80% */
                    current_dev->starvation_critical = 90;       /* 默认90% */
                    current_dev->emergency_return_ratio = 0.5f;  /* 默认50% */
                    current_dev->high_priority_protect_level = 95; /* 默认95% */
                    
                    /* 初始化批量命令 */
                    init_batch_commands(&current_dev->batch_cmds, 10);
                    
                    /* 设置默认优先级策略 */
                    current_dev->priority_policy.max_borrow_from_higher_priority = 0;
                    current_dev->priority_policy.allow_same_priority_borrow = 0;
                    current_dev->priority_policy.max_borrow_percentage = 100;
                    current_dev->priority_policy.min_lender_priority_gap = 1;
                    
                    /* 初始化互斥锁 */
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
                    strncpy(current_dev->device, device_name, MAX_DEVICE_NAME_LEN);
                    current_dev->device[MAX_DEVICE_NAME_LEN] = '\0';
                    current_dev->enabled = 1;
                    current_dev->owner_ctx = ctx;
                    
                    /* 设置默认值 */
                    current_dev->borrow_trigger_threshold = 90;
                    current_dev->lend_trigger_threshold = 30;
                    current_dev->continuous_seconds = 5;
                    current_dev->max_borrow_ratio = 0.3f;
                    current_dev->min_priority_gap = 2;
                    current_dev->keep_for_self_ratio = 1.2f;
                    current_dev->max_lend_ratio = 0.5f;
                    current_dev->enable_multi_source_borrow = 1;
                    current_dev->max_borrow_sources = 3;
                    current_dev->load_balance_mode = 1;
                    current_dev->starvation_warning = 80;
                    current_dev->starvation_critical = 90;
                    current_dev->emergency_return_ratio = 0.5f;
                    current_dev->high_priority_protect_level = 95;
                    
                    init_batch_commands(&current_dev->batch_cmds, 10);
                    
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
            char key[64];
            char value[128];
            
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
                        current_dev->tc_cache.query_interval_ms = interval;
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
                    if (gap >= 1 && gap <= 10) {
                        current_dev->priority_policy.min_lender_priority_gap = gap;
                    }
                } else if (strcmp(key, "algorithm") == 0) {
                    /* 仅支持HTB算法 */
                    if (strcmp(value, "htb") == 0) {
                        strncpy(current_dev->qdisc_kind, value, MAX_QDISC_KIND_LEN);
                        current_dev->qdisc_kind[MAX_QDISC_KIND_LEN] = '\0';
                    } else {
                        log_message(ctx, "ERROR", "行 %d: 不支持的算法: %s，仅支持HTB算法\n", 
                                   line_num, value);
                        fclose(fp);
                        return QOSDBA_ERR_CONFIG;
                    }
                } 
                /* 以下是新增的优化参数解析 */
                else if (strcmp(key, "borrow_trigger_threshold") == 0) {
                    current_dev->borrow_trigger_threshold = atoi(value);
                } else if (strcmp(key, "lend_trigger_threshold") == 0) {
                    current_dev->lend_trigger_threshold = atoi(value);
                } else if (strcmp(key, "continuous_seconds") == 0) {
                    current_dev->continuous_seconds = atoi(value);
                } else if (strcmp(key, "max_borrow_ratio") == 0) {
                    current_dev->max_borrow_ratio = atof(value);
                } else if (strcmp(key, "min_priority_gap") == 0) {
                    current_dev->min_priority_gap = atoi(value);
                } else if (strcmp(key, "keep_for_self_ratio") == 0) {
                    current_dev->keep_for_self_ratio = atof(value);
                } else if (strcmp(key, "max_lend_ratio") == 0) {
                    current_dev->max_lend_ratio = atof(value);
                } else if (strcmp(key, "enable_multi_source_borrow") == 0) {
                    current_dev->enable_multi_source_borrow = atoi(value);
                } else if (strcmp(key, "max_borrow_sources") == 0) {
                    current_dev->max_borrow_sources = atoi(value);
                } else if (strcmp(key, "load_balance_mode") == 0) {
                    current_dev->load_balance_mode = atoi(value);
                } else if (strcmp(key, "starvation_warning") == 0) {
                    current_dev->starvation_warning = atoi(value);
                } else if (strcmp(key, "starvation_critical") == 0) {
                    current_dev->starvation_critical = atoi(value);
                } else if (strcmp(key, "emergency_return_ratio") == 0) {
                    current_dev->emergency_return_ratio = atof(value);
                } else if (strcmp(key, "high_priority_protect_level") == 0) {
                    current_dev->high_priority_protect_level = atoi(value);
                } else if (strcmp(key, "log_level") == 0) {
                    ctx->log_level = parse_log_level(value);
                } else if (strcmp(key, "log_file") == 0) {
                    strncpy(ctx->log_file, value, MAX_PATH_LEN);
                } else {
                    log_message(ctx, "WARN", "行 %d: 未知配置项: %s\n", 
                               line_num, key);
                }
            } else {
                /* 尝试解析分类配置行 */
                int classid = 0;
                char name[MAX_CLASS_NAME_LEN + 1];
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
                    strncpy(config->name, name, MAX_CLASS_NAME_LEN);
                    config->name[MAX_CLASS_NAME_LEN] = '\0';
                    config->priority = priority;
                    config->total_bw_kbps = total_bw_kbps;
                    config->min_bw_kbps = min_bw_kbps;
                    config->max_bw_kbps = max_bw_kbps;
                    config->dba_enabled = dba_enabled;
                    
                    /* 初始化分类状态 */
                    class_state_t* state = &current_dev->states[current_dev->num_classes];
                    state->classid = classid;
                    state->current_bw_kbps = total_bw_kbps;
                    state->used_bw_kbps = 0;
                    state->utilization = 0.0f;
                    state->borrowed_bw_kbps = 0;
                    state->lent_bw_kbps = 0;
                    state->high_util_duration = 0;
                    state->low_util_duration = 0;
                    state->cooldown_timer = 0;
                    state->last_check_time = 0;
                    state->total_bytes = 0;
                    state->last_total_bytes = 0;
                    state->peak_used_bw_kbps = 0;
                    state->avg_used_bw_kbps = 0;
                    state->dba_enabled = dba_enabled;
                    
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
    
    /* 验证配置参数 */
    for (int i = 0; i < ctx->num_devices; i++) {
        if (!validate_config_parameters(&ctx->devices[i])) {
            return QOSDBA_ERR_CONFIG;
        }
    }
    
    /* 保存配置信息 */
    ctx->config_mtime = get_file_mtime(config_file);
    strncpy(ctx->config_path, config_file, MAX_PATH_LEN);
    ctx->config_path[MAX_PATH_LEN] = '\0';
    
    /* 记录配置加载完成 */
    log_message(ctx, "INFO", "配置文件加载完成: %s, 设备数: %d\n", 
               config_file, ctx->num_devices);
    
    return QOSDBA_OK;
}

/* ==================== 辅助函数 ==================== */

/* 解析日志级别 */
static int parse_log_level(const char* level_str) {
    if (strcmp(level_str, "DEBUG") == 0) return LOG_LEVEL_DEBUG;
    if (strcmp(level_str, "INFO") == 0) return LOG_LEVEL_INFO;
    if (strcmp(level_str, "WARN") == 0) return LOG_LEVEL_WARN;
    if (strcmp(level_str, "ERROR") == 0) return LOG_LEVEL_ERROR;
    return LOG_LEVEL_INFO;  /* 默认 */
}

/* 获取文件修改时间 */
int get_file_mtime(const char* filename) {
    struct stat st;
    if (stat(filename, &st) == 0) {
        return st.st_mtime;
    }
    return 0;
}

/* 检查配置重载 */
int check_config_reload(qosdba_context_t* ctx, const char* config_file) {
    if (!ctx || !config_file) return 0;
    
    int current_mtime = get_file_mtime(config_file);
    if (current_mtime > ctx->config_mtime) {
        log_message(ctx, "INFO", "检测到配置文件修改，准备重新加载\n");
        return 1;
    }
    
    return 0;
}

/* 重新加载配置 */
qosdba_result_t reload_config(qosdba_context_t* ctx, const char* config_file) {
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
    
    /* 原子性重新加载 */
    pthread_spin_lock(&ctx->ctx_lock);
    
    /* 保存新设备到临时指针 */
    ctx->new_devices = malloc(sizeof(device_context_t) * MAX_DEVICES);
    if (!ctx->new_devices) {
        pthread_spin_unlock(&ctx->ctx_lock);
        return QOSDBA_ERR_MEMORY;
    }
    
    memcpy(ctx->new_devices, new_devices, sizeof(device_context_t) * MAX_DEVICES);
    ctx->new_num_devices = temp_ctx.num_devices;
    ctx->reload_config = 1;
    ctx->config_mtime = get_file_mtime(config_file);
    
    pthread_spin_unlock(&ctx->ctx_lock);
    
    log_message(ctx, "INFO", "配置文件重新加载成功\n");
    
    return QOSDBA_OK;
}

/* 原子性重新加载配置 */
qosdba_result_t reload_config_atomic(qosdba_context_t* ctx, const char* config_file) {
    if (!ctx || !config_file) return QOSDBA_ERR_MEMORY;
    
    pthread_spin_lock(&ctx->ctx_lock);
    
    /* 创建新设备数组 */
    device_context_t* new_devices = malloc(sizeof(device_context_t) * MAX_DEVICES);
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
        free(new_devices);
        pthread_spin_unlock(&ctx->ctx_lock);
        return ret;
    }
    
    /* 关闭旧的网络连接 */
    for (int i = 0; i < ctx->num_devices; i++) {
        close_device_netlink(&ctx->devices[i], ctx);
        cleanup_batch_commands(&ctx->devices[i].batch_cmds);
        pthread_mutex_destroy(&ctx->devices[i].tc_cache.cache_mutex);
    }
    
    /* 初始化新设备 */
    for (int i = 0; i < temp_ctx.num_devices; i++) {
        new_devices[i].owner_ctx = ctx;
        init_batch_commands(&new_devices[i].batch_cmds, 10);
        pthread_mutex_init(&new_devices[i].tc_cache.cache_mutex, NULL);
    }
    
    /* 替换设备数组 */
    ctx->new_devices = new_devices;
    ctx->new_num_devices = temp_ctx.num_devices;
    ctx->reload_config = 1;
    ctx->config_mtime = get_file_mtime(config_file);
    
    pthread_spin_unlock(&ctx->ctx_lock);
    
    return QOSDBA_OK;
}

/* ==================== TC分类发现 ==================== */

qosdba_result_t discover_tc_classes(device_context_t* dev_ctx) {
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
    
    /* 获取qdisc信息 */
    struct rtnl_qdisc* qdisc = rtnl_qdisc_alloc();
    if (!qdisc) {
        return QOSDBA_ERR_MEMORY;
    }
    rtnl_tc_set_ifindex(TC_CAST(qdisc), ifindex);
    rtnl_tc_set_parent(TC_CAST(qdisc), TC_H_ROOT);
    
    int ret = rtnl_qdisc_get(&dev_ctx->rth, qdisc);
    if (ret == 0) {
        const char* kind = rtnl_tc_get_kind(TC_CAST(qdisc));
        if (kind) {
            strncpy(dev_ctx->qdisc_kind, kind, MAX_QDISC_KIND_LEN);
            dev_ctx->qdisc_kind[MAX_QDISC_KIND_LEN] = '\0';
        } else {
            strcpy(dev_ctx->qdisc_kind, "htb");
        }
    } else {
        strcpy(dev_ctx->qdisc_kind, "htb");
    }
    rtnl_qdisc_put(qdisc);
    
    /* 获取TC分类 */
    struct nl_cache* cache = NULL;
    ret = rtnl_class_alloc_cache(&dev_ctx->rth, ifindex, &cache);
    
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
        
        /* 检查是否已存在 */
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
                
                /* 初始化状态 */
                class_state_t* state = &dev_ctx->states[dev_ctx->num_classes];
                state->classid = classid;
                state->current_bw_kbps = config->total_bw_kbps;
                state->used_bw_kbps = 0;
                state->utilization = 0.0f;
                state->borrowed_bw_kbps = 0;
                state->lent_bw_kbps = 0;
                state->high_util_duration = 0;
                state->low_util_duration = 0;
                state->cooldown_timer = 0;
                state->last_check_time = 0;
                state->total_bytes = 0;
                state->last_total_bytes = 0;
                state->peak_used_bw_kbps = 0;
                state->avg_used_bw_kbps = 0;
                state->dba_enabled = 1;
                
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

/* ==================== TC分类初始化 ==================== */

qosdba_result_t init_tc_classes(device_context_t* dev_ctx, qosdba_context_t* ctx) {
    if (!dev_ctx || !ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    /* 打开网络连接 */
    qosdba_result_t ret = open_device_netlink(dev_ctx, ctx);
    if (ret != QOSDBA_OK) {
        log_device_message(dev_ctx, "ERROR", "打开网络连接失败\n");
        return ret;
    }
    
    /* 尝试发现现有TC分类 */
    ret = discover_tc_classes(dev_ctx);
    if (ret != QOSDBA_OK) {
        log_device_message(dev_ctx, "WARN", "发现TC分类失败\n");
    }
    
    /* 初始化缓存 */
    dev_ctx->tc_cache.valid = 0;
    dev_ctx->tc_cache.query_interval_ms = 1000;
    dev_ctx->tc_cache.adaptive_enabled = 1;
    
    /* 初始化性能统计 */
    memset(&dev_ctx->perf_stats, 0, sizeof(perf_stats_t));
    
    /* 初始化系统监控 */
    memset(&dev_ctx->system_monitor, 0, sizeof(system_monitor_t));
    
    /* 初始化借用记录 */
    dev_ctx->num_records = 0;
    dev_ctx->total_borrow_events = 0;
    dev_ctx->total_return_events = 0;
    dev_ctx->total_borrowed_kbps = 0;
    dev_ctx->total_returned_kbps = 0;
    
    log_device_message(dev_ctx, "INFO", 
                      "设备初始化完成: 总带宽=%dkbps, 分类数=%d, 算法=%s\n",
                      dev_ctx->total_bandwidth_kbps, dev_ctx->num_classes,
                      dev_ctx->qdisc_kind);
    
    return QOSDBA_OK;
}

/* ==================== 配置文件工具函数 ==================== */

int qosdba_save_config(qosdba_context_t* ctx, const char* config_file) {
    if (!ctx || !config_file) {
        return 0;
    }
    
    FILE* fp = fopen(config_file, "w");
    if (!fp) {
        return 0;
    }
    
    fprintf(fp, "# QoS DBA 配置文件 (优化版本)\n");
    fprintf(fp, "# 版本: %s\n", QOSDBA_VERSION);
    fprintf(fp, "# 生成时间: %s\n", get_current_timestamp());
    fprintf(fp, "\n");
    
    /* 全局设置 */
    fprintf(fp, "[global]\n");
    fprintf(fp, "debug_mode=%d\n", ctx->debug_mode);
    fprintf(fp, "safe_mode=%d\n", ctx->safe_mode);
    fprintf(fp, "interval=%d\n", ctx->check_interval);
    fprintf(fp, "\n");
    
    /* 设备配置 */
    for (int d = 0; d < ctx->num_devices; d++) {
        device_context_t* dev = &ctx->devices[d];
        
        fprintf(fp, "[device=%s]\n", dev->device);
        fprintf(fp, "enabled=%d\n", dev->enabled);
        fprintf(fp, "total_bandwidth_kbps=%d\n", dev->total_bandwidth_kbps);
        fprintf(fp, "algorithm=%s\n", dev->qdisc_kind);
        
        /* 借用触发阈值 */
        fprintf(fp, "borrow_trigger_threshold=%d\n", dev->borrow_trigger_threshold);
        fprintf(fp, "lend_trigger_threshold=%d\n", dev->lend_trigger_threshold);
        fprintf(fp, "continuous_seconds=%d\n", dev->continuous_seconds);
        fprintf(fp, "borrow_ratio=%.2f\n", dev->borrow_ratio);
        fprintf(fp, "max_borrow_ratio=%.2f\n", dev->max_borrow_ratio);
        fprintf(fp, "min_borrow_kbps=%d\n", dev->min_borrow_kbps);
        fprintf(fp, "cooldown_time=%d\n", dev->cooldown_time);
        fprintf(fp, "min_priority_gap=%d\n", dev->min_priority_gap);
        fprintf(fp, "keep_for_self_ratio=%.2f\n", dev->keep_for_self_ratio);
        fprintf(fp, "max_lend_ratio=%.2f\n", dev->max_lend_ratio);
        
        /* 多源借用参数 */
        fprintf(fp, "enable_multi_source_borrow=%d\n", dev->enable_multi_source_borrow);
        fprintf(fp, "max_borrow_sources=%d\n", dev->max_borrow_sources);
        fprintf(fp, "load_balance_mode=%d\n", dev->load_balance_mode);
        
        /* 归还参数 */
        fprintf(fp, "auto_return_enable=%d\n", dev->auto_return_enable);
        fprintf(fp, "return_threshold=%d\n", dev->return_threshold);
        fprintf(fp, "return_speed=%.2f\n", dev->return_speed);
        
        /* 保护机制参数 */
        fprintf(fp, "starvation_warning=%d\n", dev->starvation_warning);
        fprintf(fp, "starvation_critical=%d\n", dev->starvation_critical);
        fprintf(fp, "emergency_return_ratio=%.2f\n", dev->emergency_return_ratio);
        fprintf(fp, "high_priority_protect_level=%d\n", dev->high_priority_protect_level);
        
        /* 缓存参数 */
        fprintf(fp, "cache_interval=%d\n", dev->tc_cache.query_interval_ms);
        fprintf(fp, "adaptive_cache=%d\n", dev->tc_cache.adaptive_enabled);
        fprintf(fp, "adaptive_batch=%d\n", dev->batch_cmds.adaptive_enabled);
        
        fprintf(fp, "\n");
        
        /* 分类配置 */
        for (int i = 0; i < dev->num_classes; i++) {
            class_config_t* config = &dev->configs[i];
            fprintf(fp, "0x%x,%s,%d,%d,%d,%d,%d\n",
                   config->classid, config->name, config->priority,
                   config->total_bw_kbps, config->min_bw_kbps, 
                   config->max_bw_kbps, config->dba_enabled);
        }
        
        fprintf(fp, "\n");
    }
    
    fclose(fp);
    return 1;
}

/* 获取当前时间戳 */
static const char* get_current_timestamp(void) {
    static char timestamp[32];
    time_t now = time(NULL);
    struct tm* tm_info = localtime(&now);
    
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", tm_info);
    return timestamp;
}