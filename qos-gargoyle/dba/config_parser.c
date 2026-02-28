#include "qos_dba.h"
#include <uci.h>
#include <string.h>
#include <stdlib.h>

// 全局QoS系统变量
extern qos_dba_system_t g_qos_system;

// 从UCI配置加载DBA设置
int load_dba_config(const char *config_path) {
    struct uci_context *ctx = uci_alloc_context();
    if (!ctx) {
        DEBUG_LOG("无法创建UCI上下文");
        return -1;
    }
    
    struct uci_package *pkg = NULL;
    int ret = 0;
    
    // 打开配置文件
    if (uci_load(ctx, "qos_gargoyle", &pkg) != 0) {
        DEBUG_LOG("无法加载UCI配置");
        uci_free_context(ctx);
        return -1;
    }
    
    // 查找DBA配置节
    struct uci_section *dba_section = uci_lookup_section(ctx, pkg, "dba");
    if (!dba_section) {
        DEBUG_LOG("未找到DBA配置节，使用默认值");
        // 使用默认值
        g_qos_system.config.enabled = 1;
        g_qos_system.config.interval = 5;
        g_qos_system.config.high_usage_threshold = 85;
        g_qos_system.config.high_usage_duration = 5;
        g_qos_system.config.low_usage_threshold = 30;
        g_qos_system.config.low_usage_duration = 10;
        g_qos_system.config.borrow_ratio = 0.5;
        g_qos_system.config.min_borrow_kbps = 64;
        g_qos_system.config.min_change_kbps = 32;
        g_qos_system.config.cooldown_time = 10;
        g_qos_system.config.auto_return_enable = 1;
        g_qos_system.config.return_threshold = 50;
        g_qos_system.config.return_speed = 0.1;
        
        uci_unload(ctx, pkg);
        uci_free_context(ctx);
        return 0;
    }
    
    // 读取配置值
    const char *enabled = uci_lookup_option_string(ctx, dba_section, "enabled");
    const char *interval = uci_lookup_option_string(ctx, dba_section, "interval");
    const char *high_usage_threshold = uci_lookup_option_string(ctx, dba_section, "high_usage_threshold");
    const char *high_usage_duration = uci_lookup_option_string(ctx, dba_section, "high_usage_duration");
    const char *low_usage_threshold = uci_lookup_option_string(ctx, dba_section, "low_usage_threshold");
    const char *low_usage_duration = uci_lookup_option_string(ctx, dba_section, "low_usage_duration");
    const char *borrow_ratio = uci_lookup_option_string(ctx, dba_section, "borrow_ratio");
    const char *min_borrow_kbps = uci_lookup_option_string(ctx, dba_section, "min_borrow_kbps");
    const char *min_change_kbps = uci_lookup_option_string(ctx, dba_section, "min_change_kbps");
    const char *cooldown_time = uci_lookup_option_string(ctx, dba_section, "cooldown_time");
    const char *auto_return_enable = uci_lookup_option_string(ctx, dba_section, "auto_return_enable");
    const char *return_threshold = uci_lookup_option_string(ctx, dba_section, "return_threshold");
    const char *return_speed = uci_lookup_option_string(ctx, dba_section, "return_speed");
    
    // 设置配置值，如果没有则使用默认值
    g_qos_system.config.enabled = enabled ? atoi(enabled) : 1;
    g_qos_system.config.interval = interval ? atoi(interval) : 5;
    g_qos_system.config.high_usage_threshold = high_usage_threshold ? atoi(high_usage_threshold) : 85;
    g_qos_system.config.high_usage_duration = high_usage_duration ? atoi(high_usage_duration) : 5;
    g_qos_system.config.low_usage_threshold = low_usage_threshold ? atoi(low_usage_threshold) : 30;
    g_qos_system.config.low_usage_duration = low_usage_duration ? atoi(low_usage_duration) : 10;
    g_qos_system.config.borrow_ratio = borrow_ratio ? atof(borrow_ratio) : 0.5;
    g_qos_system.config.min_borrow_kbps = min_borrow_kbps ? atoi(min_borrow_kbps) : 64;
    g_qos_system.config.min_change_kbps = min_change_kbps ? atoi(min_change_kbps) : 32;
    g_qos_system.config.cooldown_time = cooldown_time ? atoi(cooldown_time) : 10;
    g_qos_system.config.auto_return_enable = auto_return_enable ? atoi(auto_return_enable) : 1;
    g_qos_system.config.return_threshold = return_threshold ? atoi(return_threshold) : 50;
    g_qos_system.config.return_speed = return_speed ? atof(return_speed) : 0.1;
    
    DEBUG_LOG("加载DBA配置成功");
    DEBUG_LOG("  启用: %d", g_qos_system.config.enabled);
    DEBUG_LOG("  检查间隔: %d秒", g_qos_system.config.interval);
    DEBUG_LOG("  高使用阈值: %d%%", g_qos_system.config.high_usage_threshold);
    DEBUG_LOG("  高使用持续时间: %d秒", g_qos_system.config.high_usage_duration);
    DEBUG_LOG("  低使用阈值: %d%%", g_qos_system.config.low_usage_threshold);
    DEBUG_LOG("  低使用持续时间: %d秒", g_qos_system.config.low_usage_duration);
    DEBUG_LOG("  借用比例: %.1f", g_qos_system.config.borrow_ratio);
    DEBUG_LOG("  最小借用: %d kbps", g_qos_system.config.min_borrow_kbps);
    DEBUG_LOG("  最小调整: %d kbps", g_qos_system.config.min_change_kbps);
    DEBUG_LOG("  冷却时间: %d秒", g_qos_system.config.cooldown_time);
    DEBUG_LOG("  自动归还: %d", g_qos_system.config.auto_return_enable);
    DEBUG_LOG("  归还阈值: %d%%", g_qos_system.config.return_threshold);
    DEBUG_LOG("  归还速度: %.1f", g_qos_system.config.return_speed);
    
    uci_unload(ctx, pkg);
    uci_free_context(ctx);
    return 0;
}

// 从UCI配置加载QoS分类
int load_qos_classes(const char *config_path) {
    struct uci_context *ctx = uci_alloc_context();
    if (!ctx) {
        DEBUG_LOG("无法创建UCI上下文");
        return -1;
    }
    
    struct uci_package *pkg = NULL;
    int ret = 0;
    
    // 打开配置文件
    if (uci_load(ctx, "qos_gargoyle", &pkg) != 0) {
        DEBUG_LOG("无法加载UCI配置");
        uci_free_context(ctx);
        return -1;
    }
    
    // 先计算分类数量
    int upload_count = 0;
    int download_count = 0;
    
    struct uci_element *e;
    uci_foreach_element(&pkg->sections, e) {
        struct uci_section *s = uci_to_section(e);
        if (strstr(s->type, "upload_class")) {
            upload_count++;
        } else if (strstr(s->type, "download_class")) {
            download_count++;
        }
    }
    
    if (upload_count == 0 && download_count == 0) {
        DEBUG_LOG("未找到QoS分类配置");
        uci_unload(ctx, pkg);
        uci_free_context(ctx);
        return -1;
    }
    
    // 分配内存
    if (upload_count > 0) {
        g_qos_system.upload_classes = malloc(upload_count * sizeof(qos_class_t));
        if (!g_qos_system.upload_classes) {
            DEBUG_LOG("分配上传分类内存失败");
            uci_unload(ctx, pkg);
            uci_free_context(ctx);
            return -1;
        }
        memset(g_qos_system.upload_classes, 0, upload_count * sizeof(qos_class_t));
    }
    
    if (download_count > 0) {
        g_qos_system.download_classes = malloc(download_count * sizeof(qos_class_t));
        if (!g_qos_system.download_classes) {
            DEBUG_LOG("分配下载分类内存失败");
            free(g_qos_system.upload_classes);
            g_qos_system.upload_classes = NULL;
            uci_unload(ctx, pkg);
            uci_free_context(ctx);
            return -1;
        }
        memset(g_qos_system.download_classes, 0, download_count * sizeof(qos_class_t));
    }
    
    // 填充分类信息
    int upload_idx = 0;
    int download_idx = 0;
    
    uci_foreach_element(&pkg->sections, e) {
        struct uci_section *s = uci_to_section(e);
        qos_class_t *cls = NULL;
        
        if (strstr(s->type, "upload_class")) {
            if (upload_idx >= upload_count) continue;
            cls = &g_qos_system.upload_classes[upload_idx];
            cls->id = upload_idx;
            upload_idx++;
        } else if (strstr(s->type, "download_class")) {
            if (download_idx >= download_count) continue;
            cls = &g_qos_system.download_classes[download_idx];
            cls->id = download_idx;
            download_idx++;
        } else {
            continue;
        }
        
        // 获取分类名称
        const char *name = uci_lookup_option_string(ctx, s, "name");
        if (name) {
            strncpy(cls->name, name, MAX_NAME_LEN - 1);
            cls->name[MAX_NAME_LEN - 1] = '\0';
        } else {
            strncpy(cls->name, s->e.name, MAX_NAME_LEN - 1);
            cls->name[MAX_NAME_LEN - 1] = '\0';
        }
        
        // 获取classid
        const char *classid = uci_lookup_option_string(ctx, s, "classid");
        if (classid) {
            strncpy(cls->classid, classid, MAX_CLASSID_LEN - 1);
            cls->classid[MAX_CLASSID_LEN - 1] = '\0';
        } else {
            // 从section名称生成
            if (strstr(s->type, "upload_class")) {
                snprintf(cls->classid, MAX_CLASSID_LEN, "1:1%02d", cls->id);
            } else {
                snprintf(cls->classid, MAX_CLASSID_LEN, "1:2%02d", cls->id);
            }
        }
        
        // 获取优先级
        const char *priority_str = uci_lookup_option_string(ctx, s, "priority");
        cls->priority = priority_str ? atoi(priority_str) : cls->id;  // 默认为ID
        
        // 获取最小带宽
        const char *min_kbps_str = uci_lookup_option_string(ctx, s, "min_kbps");
        if (min_kbps_str) {
            cls->config_min_kbps = atoi(min_kbps_str);
        } else {
            // 从百分比计算
            const char *percent_str = uci_lookup_option_string(ctx, s, "percent_bandwidth");
            int percent = percent_str ? atoi(percent_str) : 10;
            cls->config_min_kbps = (g_qos_system.total_bandwidth_kbps * percent) / 100;
        }
        
        // 获取最大带宽
        const char *max_kbps_str = uci_lookup_option_string(ctx, s, "max_kbps");
        if (max_kbps_str) {
            cls->config_max_kbps = atoi(max_kbps_str);
        } else {
            // 默认为最小带宽的2倍
            cls->config_max_kbps = cls->config_min_kbps * 2;
        }
        
        // 初始化当前带宽
        cls->current_kbps = cls->config_min_kbps;
        
        // 初始化其他字段
        cls->used_kbps = 0;
        cls->usage_rate = 0.0f;
        cls->avg_usage_rate = 0.0f;           // 修复：新增字段初始化
        cls->borrowed_kbps = 0;
        cls->lent_kbps = 0;
        cls->enabled = 1;
        cls->adjusted = 0;
        cls->peak_usage_kbps = 0;             // 修复：新增字段初始化
        cls->adjust_count = 0;                 // 修复：新增字段初始化
        cls->last_adjust_time = 0;             // 修复：新增字段初始化
        cls->last_borrow_time = 0;
        cls->last_lend_time = 0;
        
        // 初始化借入借出数组
        for (int j = 0; j < MAX_CLASSES; j++) {
            cls->borrowed_from[j] = -1;
            cls->lent_to[j] = -1;
        }
        
        DEBUG_LOG("加载分类: %s (classid: %s, 类型: %s, 带宽: %d-%dkbps, 优先级: %d)",
                  cls->name, cls->classid, 
                  strstr(s->type, "upload_class") ? "上传" : "下载",
                  cls->config_min_kbps, cls->config_max_kbps, cls->priority);
    }
    
    g_qos_system.upload_class_count = upload_idx;
    g_qos_system.download_class_count = download_idx;
    
    DEBUG_LOG("加载完成: 上传分类 %d 个, 下载分类 %d 个", 
              g_qos_system.upload_class_count, g_qos_system.download_class_count);
    
    uci_unload(ctx, pkg);
    uci_free_context(ctx);
    return 0;
}

// 解析带宽字符串
int parse_bandwidth_string(const char *str, int *kbps) {
    if (!str || !kbps) {
        return -1;
    }
    
    char *endptr = NULL;
    double value = strtod(str, &endptr);
    
    if (endptr == str) {
        return -1;  // 无效字符串
    }
    
    // 转换为kbps
    if (strstr(endptr, "G") || strstr(endptr, "g")) {
        *kbps = (int)(value * 1000000);
    } else if (strstr(endptr, "M") || strstr(endptr, "m")) {
        *kbps = (int)(value * 1000);
    } else if (strstr(endptr, "K") || strstr(endptr, "k")) {
        *kbps = (int)value;
    } else {
        *kbps = (int)value;  // 默认单位kbps
    }
    
    return 0;
}

// 验证QoS分类配置
int validate_qos_classes(qos_class_t *classes, int class_count, int total_bandwidth) {
    if (!classes || class_count == 0) {
        return 0;
    }
    
    int total_min_kbps = 0;
    int total_max_kbps = 0;
    
    DEBUG_LOG("验证QoS分类配置...");
    
    for (int i = 0; i < class_count; i++) {
        qos_class_t *cls = &classes[i];
        
        // 检查最小带宽是否有效
        if (cls->config_min_kbps <= 0) {
            DEBUG_LOG("警告: 分类 %s 的最小带宽为0或负数", cls->name);
        }
        
        // 检查最大带宽是否有效
        if (cls->config_max_kbps <= 0) {
            DEBUG_LOG("警告: 分类 %s 的最大带宽为0或负数", cls->name);
        }
        
        // 检查带宽范围
        if (cls->config_max_kbps < cls->config_min_kbps) {
            DEBUG_LOG("错误: 分类 %s 的最大带宽小于最小带宽", cls->name);
            return -1;
        }
        
        // 检查优先级是否有效
        if (cls->priority < 0) {
            DEBUG_LOG("警告: 分类 %s 的优先级为负数", cls->name);
        }
        
        // 累加带宽
        total_min_kbps += cls->config_min_kbps;
        total_max_kbps += cls->config_max_kbps;
        
        DEBUG_LOG("分类[%d]: %s, 最小: %dkbps, 最大: %dkbps, 优先级: %d",
               i, cls->name, cls->config_min_kbps, cls->config_max_kbps, cls->priority);
    }
    
    // 检查总带宽
    if (total_bandwidth > 0) {
        if (total_min_kbps > total_bandwidth) {
            DEBUG_LOG("警告: 总最小带宽(%dkbps)超过总带宽(%dkbps)", 
                   total_min_kbps, total_bandwidth);
        }
        
        if (total_max_kbps > total_bandwidth * 2) {
            DEBUG_LOG("警告: 总最大带宽(%dkbps)远超过总带宽(%dkbps)", 
                   total_max_kbps, total_bandwidth);
        }
    }
    
    DEBUG_LOG("总计: 最小带宽: %dkbps, 最大带宽: %dkbps", 
           total_min_kbps, total_max_kbps);
    
    return 0;
}

// 保存QoS配置到UCI
int save_qos_config_to_uci(qos_dba_system_t *qos_system) {
    if (!qos_system) {
        return -1;
    }
    
    struct uci_context *ctx = uci_alloc_context();
    if (!ctx) {
        DEBUG_LOG("无法创建UCI上下文");
        return -1;
    }
    
    struct uci_package *pkg = NULL;
    
    // 打开配置文件
    if (uci_load(ctx, "qos_gargoyle", &pkg) != 0) {
        DEBUG_LOG("无法加载UCI配置");
        uci_free_context(ctx);
        return -1;
    }
    
    int ret = 0;
    
    // 保存DBA配置
    struct uci_section *dba_section = uci_lookup_section(ctx, pkg, "dba");
    if (!dba_section) {
        // 创建新的DBA节
        dba_section = uci_add_section(ctx, pkg, "dba");
        if (!dba_section) {
            DEBUG_LOG("无法创建DBA配置节");
            uci_unload(ctx, pkg);
            uci_free_context(ctx);
            return -1;
        }
    }
    
    // 设置DBA配置值
    char value[32];
    
    snprintf(value, sizeof(value), "%d", qos_system->config.enabled);
    uci_set(ctx, &pkg, "dba", "enabled", value);
    
    snprintf(value, sizeof(value), "%d", qos_system->config.interval);
    uci_set(ctx, &pkg, "dba", "interval", value);
    
    snprintf(value, sizeof(value), "%d", qos_system->config.high_usage_threshold);
    uci_set(ctx, &pkg, "dba", "high_usage_threshold", value);
    
    snprintf(value, sizeof(value), "%d", qos_system->config.high_usage_duration);
    uci_set(ctx, &pkg, "dba", "high_usage_duration", value);
    
    snprintf(value, sizeof(value), "%d", qos_system->config.low_usage_threshold);
    uci_set(ctx, &pkg, "dba", "low_usage_threshold", value);
    
    snprintf(value, sizeof(value), "%d", qos_system->config.low_usage_duration);
    uci_set(ctx, &pkg, "dba", "low_usage_duration", value);
    
    snprintf(value, sizeof(value), "%.2f", qos_system->config.borrow_ratio);
    uci_set(ctx, &pkg, "dba", "borrow_ratio", value);
    
    snprintf(value, sizeof(value), "%d", qos_system->config.min_borrow_kbps);
    uci_set(ctx, &pkg, "dba", "min_borrow_kbps", value);
    
    snprintf(value, sizeof(value), "%d", qos_system->config.min_change_kbps);
    uci_set(ctx, &pkg, "dba", "min_change_kbps", value);
    
    snprintf(value, sizeof(value), "%d", qos_system->config.cooldown_time);
    uci_set(ctx, &pkg, "dba", "cooldown_time", value);
    
    snprintf(value, sizeof(value), "%d", qos_system->config.auto_return_enable);
    uci_set(ctx, &pkg, "dba", "auto_return_enable", value);
    
    snprintf(value, sizeof(value), "%d", qos_system->config.return_threshold);
    uci_set(ctx, &pkg, "dba", "return_threshold", value);
    
    snprintf(value, sizeof(value), "%.2f", qos_system->config.return_speed);
    uci_set(ctx, &pkg, "dba", "return_speed", value);
    
    // 保存分类配置
    for (int i = 0; i < qos_system->upload_class_count; i++) {
        qos_class_t *cls = &qos_system->upload_classes[i];
        char section_name[32];
        snprintf(section_name, sizeof(section_name), "upload_class_%d", i);
        
        // 查找或创建分类节
        struct uci_section *class_section = uci_lookup_section(ctx, pkg, section_name);
        if (!class_section) {
            class_section = uci_add_section(ctx, pkg, "upload_class");
            if (!class_section) {
                DEBUG_LOG("无法创建上传分类节: %s", section_name);
                continue;
            }
        }
        
        // 设置分类参数
        uci_set(ctx, &pkg, section_name, "name", cls->name);
        uci_set(ctx, &pkg, section_name, "classid", cls->classid);
        
        snprintf(value, sizeof(value), "%d", cls->priority);
        uci_set(ctx, &pkg, section_name, "priority", value);
        
        snprintf(value, sizeof(value), "%d", cls->config_min_kbps);
        uci_set(ctx, &pkg, section_name, "min_kbps", value);
        
        snprintf(value, sizeof(value), "%d", cls->config_max_kbps);
        uci_set(ctx, &pkg, section_name, "max_kbps", value);
        
        // 计算百分比
        int percent = (cls->current_kbps * 100) / qos_system->total_bandwidth_kbps;
        snprintf(value, sizeof(value), "%d", percent);
        uci_set(ctx, &pkg, section_name, "percent_bandwidth", value);
    }
    
    for (int i = 0; i < qos_system->download_class_count; i++) {
        qos_class_t *cls = &qos_system->download_classes[i];
        char section_name[32];
        snprintf(section_name, sizeof(section_name), "download_class_%d", i);
        
        // 查找或创建分类节
        struct uci_section *class_section = uci_lookup_section(ctx, pkg, section_name);
        if (!class_section) {
            class_section = uci_add_section(ctx, pkg, "download_class");
            if (!class_section) {
                DEBUG_LOG("无法创建下载分类节: %s", section_name);
                continue;
            }
        }
        
        // 设置分类参数
        uci_set(ctx, &pkg, section_name, "name", cls->name);
        uci_set(ctx, &pkg, section_name, "classid", cls->classid);
        
        snprintf(value, sizeof(value), "%d", cls->priority);
        uci_set(ctx, &pkg, section_name, "priority", value);
        
        snprintf(value, sizeof(value), "%d", cls->config_min_kbps);
        uci_set(ctx, &pkg, section_name, "min_kbps", value);
        
        snprintf(value, sizeof(value), "%d", cls->config_max_kbps);
        uci_set(ctx, &pkg, section_name, "max_kbps", value);
        
        // 计算百分比
        int percent = (cls->current_kbps * 100) / qos_system->total_bandwidth_kbps;
        snprintf(value, sizeof(value), "%d", percent);
        uci_set(ctx, &pkg, section_name, "percent_bandwidth", value);
    }
    
    // 提交更改
    if (uci_commit(ctx, &pkg, false) != 0) {
        DEBUG_LOG("保存配置失败");
        ret = -1;
    } else {
        DEBUG_LOG("配置已保存到UCI");
    }
    
    uci_unload(ctx, pkg);
    uci_free_context(ctx);
    return ret;
}