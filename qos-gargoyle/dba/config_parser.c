#include "qos_dba.h"
#include <uci.h>
#include <string.h>
#include <stdlib.h>

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
            upload_idx++;
        } else if (strstr(s->type, "download_class")) {
            if (download_idx >= download_count) continue;
            cls = &g_qos_system.download_classes[download_idx];
            download_idx++;
        } else {
            continue;
        }
        
        // 获取分类名称
        const char *name = uci_lookup_option_string(ctx, s, "name");
        if (name) {
            strncpy(cls->name, name, MAX_NAME_LEN-1);
            cls->name[MAX_NAME_LEN-1] = '\0';
        } else {
            strncpy(cls->name, s->e.name, MAX_NAME_LEN-1);
            cls->name[MAX_NAME_LEN-1] = '\0';
        }
        
        // 获取classid
        const char *classid = uci_lookup_option_string(ctx, s, "classid");
        if (classid) {
            strncpy(cls->classid, classid, MAX_CLASSID_LEN-1);
            cls->classid[MAX_CLASSID_LEN-1] = '\0';
        } else {
            // 从section名称生成
            if (strstr(s->type, "upload_class")) {
                snprintf(cls->classid, MAX_CLASSID_LEN, "1:1%02d", upload_idx);
            } else {
                snprintf(cls->classid, MAX_CLASSID_LEN, "1:2%02d", download_idx);
            }
        }
        
        // 获取百分比
        const char *percent = uci_lookup_option_string(ctx, s, "percent");
        cls->config_percent = percent ? atoi(percent) : 10;
        
        // 计算带宽
        int bandwidth_kbps = 0;
        if (strstr(s->type, "upload_class")) {
            bandwidth_kbps = (g_qos_system.total_bandwidth_kbps * cls->config_percent) / 100;
        } else {
            bandwidth_kbps = (g_qos_system.total_bandwidth_kbps * cls->config_percent) / 100;
        }
        
        // 设置最小/最大/当前带宽
        cls->config_min_kbps = (int)(bandwidth_kbps * 0.1);  // 最小为配置的10%
        cls->config_max_kbps = (int)(bandwidth_kbps * 2.0);  // 最大为配置的200%
        cls->current_kbps = bandwidth_kbps;
        
        // 获取优先级
        const char *priority = uci_lookup_option_string(ctx, s, "priority");
        cls->priority = priority ? atoi(priority) : upload_idx;  // 默认为索引
        
        // 初始化其他字段
        cls->used_kbps = 0;
        cls->usage_rate = 0.0f;
        cls->avg_usage_rate = 0.0f;
        cls->high_usage_seconds = 0;
        cls->low_usage_seconds = 0;
        cls->normal_usage_seconds = 0;
        cls->peak_usage_kbps = 0;
        cls->borrowed_kbps = 0;
        cls->adjust_count = 0;
        cls->last_adjust_time = 0;
        
        DEBUG_LOG("加载分类: %s (classid: %s, 类型: %s, 带宽: %dkbps, 优先级: %d)",
                  cls->name, cls->classid, 
                  strstr(s->type, "upload_class") ? "上传" : "下载",
                  bandwidth_kbps, cls->priority);
    }
    
    g_qos_system.upload_class_count = upload_idx;
    g_qos_system.download_class_count = download_idx;
    
    DEBUG_LOG("加载完成: 上传分类 %d 个, 下载分类 %d 个", 
              g_qos_system.upload_class_count, g_qos_system.download_class_count);
    
    uci_unload(ctx, pkg);
    uci_free_context(ctx);
    return 0;
}