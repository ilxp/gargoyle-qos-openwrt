#include "qos_dba.h"
#include <signal.h>

static pthread_t g_monitor_thread = 0;
static int g_is_running = 0;

// 打印系统状态
void qos_dba_print_status(void) {
    pthread_mutex_lock(&g_qos_system.mutex);
    
    dba_config_t *config = &g_qos_system.config;
    
    printf("\n=================== QoS DBA 状态 ===================\n");
    printf("接口: %s, 总带宽: %d kbps (%.1f Mbps)\n", 
           g_qos_system.wan_interface,
           g_qos_system.total_bandwidth_kbps,
           g_qos_system.total_bandwidth_kbps / 1000.0);
    printf("DBA状态: %s, 检查间隔: %d秒\n",
           config->enabled ? "启用" : "禁用",
           config->interval);
    
    printf("\n上传分类:\n");
    printf("%-12s %-8s %-8s %-8s %-8s %-8s %-8s %-12s %-8s\n", 
           "分类", "配置%", "最小", "最大", "当前", "使用", "使用率", "状态", "借用");
    printf("--------------------------------------------------------------------------------\n");
    
    for (int i = 0; i < g_qos_system.upload_class_count; i++) {
        qos_class_t *cls = &g_qos_system.upload_classes[i];
        
        char status[16];
        if (cls->high_usage_seconds > 0) {
            snprintf(status, sizeof(status), "高负荷(%ds)", cls->high_usage_seconds);
        } else if (cls->low_usage_seconds > 0) {
            snprintf(status, sizeof(status), "低负荷(%ds)", cls->low_usage_seconds);
        } else {
            snprintf(status, sizeof(status), "正常(%ds)", cls->normal_usage_seconds);
        }
        
        char borrowed[16];
        if (cls->borrowed_kbps > 0) {
            snprintf(borrowed, sizeof(borrowed), "+%d", cls->borrowed_kbps);
        } else if (cls->borrowed_kbps < 0) {
            snprintf(borrowed, sizeof(borrowed), "%d", cls->borrowed_kbps);
        } else {
            snprintf(borrowed, sizeof(borrowed), "0");
        }
        
        printf("%-12s %-8d %-8d %-8d %-8d %-8d %-7.1f%% %-12s %-8s\n",
               cls->name,
               cls->config_percent,
               cls->config_min_kbps,
               cls->config_max_kbps,
               cls->current_kbps,
               cls->used_kbps,
               cls->usage_rate * 100,
               status,
               borrowed);
    }
    
    printf("\n下载分类:\n");
    printf("%-12s %-8s %-8s %-8s %-8s %-8s %-8s %-12s %-8s\n", 
           "分类", "配置%", "最小", "最大", "当前", "使用", "使用率", "状态", "借用");
    printf("--------------------------------------------------------------------------------\n");
    
    for (int i = 0; i < g_qos_system.download_class_count; i++) {
        qos_class_t *cls = &g_qos_system.download_classes[i];
        
        char status[16];
        if (cls->high_usage_seconds > 0) {
            snprintf(status, sizeof(status), "高负荷(%ds)", cls->high_usage_seconds);
        } else if (cls->low_usage_seconds > 0) {
            snprintf(status, sizeof(status), "低负荷(%ds)", cls->low_usage_seconds);
        } else {
            snprintf(status, sizeof(status), "正常(%ds)", cls->normal_usage_seconds);
        }
        
        char borrowed[16];
        if (cls->borrowed_kbps > 0) {
            snprintf(borrowed, sizeof(borrowed), "+%d", cls->borrowed_kbps);
        } else if (cls->borrowed_kbps < 0) {
            snprintf(borrowed, sizeof(borrowed), "%d", cls->borrowed_kbps);
        } else {
            snprintf(borrowed, sizeof(borrowed), "0");
        }
        
        printf("%-12s %-8d %-8d %-8d %-8d %-8d %-7.1f%% %-12s %-8s\n",
               cls->name,
               cls->config_percent,
               cls->config_min_kbps,
               cls->config_max_kbps,
               cls->current_kbps,
               cls->used_kbps,
               cls->usage_rate * 100,
               status,
               borrowed);
    }
    
    printf("\n调整参数:\n");
    printf("  高使用阈值=%d%%, 持续时间=%ds\n", config->high_usage_threshold, config->high_usage_duration);
    printf("  低使用阈值=%d%%, 持续时间=%ds\n", config->low_usage_threshold, config->low_usage_duration);
    printf("  借用比例=%.1f, 最小借用=%dkbps\n", config->borrow_ratio, config->min_borrow_kbps);
    printf("  冷却时间=%ds, 自动归还=%s\n", config->cooldown_time, config->auto_return_enable ? "是" : "否");
    
    if (config->auto_return_enable) {
        printf("  归还阈值=%d%%, 归还速度=%.1f\n", config->return_threshold, config->return_speed);
    }
    
    printf("====================================================\n");
    
    pthread_mutex_unlock(&g_qos_system.mutex);
}

// 检测WAN接口
static int detect_wan_interface(void) {
    char cmd[256];
    char output[256] = {0};
    
    // 尝试通过route命令获取默认网关接口
    snprintf(cmd, sizeof(cmd), "ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1");
    if (execute_command(cmd, output, sizeof(output)) == 0 && strlen(output) > 1) {
        output[strlen(output)-1] = '\0';  // 去掉换行符
        strncpy(g_qos_system.wan_interface, output, MAX_IFACE_LEN-1);
        DEBUG_LOG("检测到WAN接口: %s", g_qos_system.wan_interface);
        return 0;
    }
    
    // 尝试常见接口
    const char *common_ifaces[] = {"eth0", "eth1", "ppp0", "wan", "br-wan", NULL};
    for (int i = 0; common_ifaces[i] != NULL; i++) {
        snprintf(cmd, sizeof(cmd), "ip link show %s 2>/dev/null | grep -q 'state UP'", common_ifaces[i]);
        if (system(cmd) == 0) {
            strncpy(g_qos_system.wan_interface, common_ifaces[i], MAX_IFACE_LEN-1);
            DEBUG_LOG("使用接口: %s", g_qos_system.wan_interface);
            return 0;
        }
    }
    
    DEBUG_LOG("无法检测WAN接口");
    return -1;
}

// 获取总带宽
static int detect_total_bandwidth(void) {
    char cmd[256];
    char output[256] = {0};
    
    // 尝试从speedtest获取
    snprintf(cmd, sizeof(cmd), "cat /tmp/speedtest_result 2>/dev/null | grep 'Download:' | awk '{print $2}'");
    if (execute_command(cmd, output, sizeof(output)) == 0 && strlen(output) > 0) {
        float mbps = atof(output);
        if (mbps > 0) {
            g_qos_system.total_bandwidth_kbps = (int)(mbps * 1000);
            DEBUG_LOG("从speedtest获取带宽: %.1f Mbps", mbps);
            return 0;
        }
    }
    
    // 尝试从配置读取
    FILE *fp = fopen("/etc/config/qos_gargoyle", "r");
    if (fp) {
        char line[256];
        while (fgets(line, sizeof(line), fp)) {
            if (strstr(line, "option upload") || strstr(line, "option download")) {
                char *start = strstr(line, "'");
                if (start) {
                    start++;
                    char *end = strchr(start, '\'');
                    if (end) {
                        char value_str[32] = {0};
                        int len = end - start;
                        if (len >= sizeof(value_str)) len = sizeof(value_str) - 1;
                        strncpy(value_str, start, len);
                        value_str[len] = '\0';
                        
                        g_qos_system.total_bandwidth_kbps = parse_bandwidth_string(value_str);
                        if (g_qos_system.total_bandwidth_kbps > 0) {
                            DEBUG_LOG("从配置获取带宽: %d kbps", g_qos_system.total_bandwidth_kbps);
                            fclose(fp);
                            return 0;
                        }
                    }
                }
            }
        }
        fclose(fp);
    }
    
    // 默认100M
    g_qos_system.total_bandwidth_kbps = 100 * 1000;
    DEBUG_LOG("使用默认带宽: 100 Mbps");
    return 0;
}

// 主监控线程
static void *monitor_thread(void *arg) {
    DEBUG_LOG("QoS DBA监控线程启动");
    
    while (!g_qos_system.should_exit) {
        // 检查DBA是否启用
        if (!g_qos_system.config.enabled) {
            sleep(1);
            continue;
        }
        
        // 1. 监控分类状态
        monitor_all_classes();
        
        // 2. 动态调整
        int upload_adjustments = adjust_upload_classes();
        int download_adjustments = adjust_download_classes();
        
        // 3. 自动归还
        int returned = auto_return_borrowed_bandwidth();
        
        // 4. 打印状态
        if (g_qos_system.verbose || upload_adjustments > 0 || 
            download_adjustments > 0 || returned > 0) {
            qos_dba_print_status();
        }
        
        // 5. 休眠
        sleep(g_qos_system.config.interval);
    }
    
    DEBUG_LOG("QoS DBA监控线程退出");
    return NULL;
}

// 初始化系统
int qos_dba_init(const char *config_path) {
    if (!config_path) {
        config_path = "/etc/config/qos_gargoyle";
    }
    
    // 初始化互斥锁
    if (pthread_mutex_init(&g_qos_system.mutex, NULL) != 0) {
        DEBUG_LOG("初始化互斥锁失败");
        return -1;
    }
    
    // 默认值
    g_qos_system.should_exit = 0;
    g_qos_system.verbose = 0;
    
    // 检测WAN接口
    if (detect_wan_interface() != 0) {
        DEBUG_LOG("初始化失败: 无法检测WAN接口");
        return -1;
    }
    
    // 获取总带宽
    if (detect_total_bandwidth() != 0) {
        DEBUG_LOG("初始化失败: 无法获取总带宽");
        return -1;
    }
    
    // 加载配置
    if (load_dba_config(config_path) != 0) {
        DEBUG_LOG("加载DBA配置失败");
        return -1;
    }
    
    if (load_qos_classes(config_path) != 0) {
        DEBUG_LOG("加载QoS分类失败");
        return -1;
    }
    
    g_qos_system.is_initialized = 1;
    
    printf("QoS DBA系统初始化完成\n");
    printf("  WAN接口: %s\n", g_qos_system.wan_interface);
    printf("  总带宽: %d kbps (%.1f Mbps)\n", 
           g_qos_system.total_bandwidth_kbps,
           g_qos_system.total_bandwidth_kbps / 1000.0);
    printf("  上传分类: %d个\n", g_qos_system.upload_class_count);
    printf("  下载分类: %d个\n", g_qos_system.download_class_count);
    printf("  DBA状态: %s\n", g_qos_system.config.enabled ? "启用" : "禁用");
    
    return 0;
}

// 启动DBA
int qos_dba_start(void) {
    if (!g_qos_system.is_initialized) {
        DEBUG_LOG("DBA未初始化");
        return -1;
    }
    
    if (g_is_running) {
        DEBUG_LOG("DBA已在运行");
        return 0;
    }
    
    g_qos_system.should_exit = 0;
    
    if (pthread_create(&g_monitor_thread, NULL, monitor_thread, NULL) != 0) {
        DEBUG_LOG("创建监控线程失败");
        return -1;
    }
    
    g_is_running = 1;
    DEBUG_LOG("DBA已启动");
    return 0;
}

// 停止DBA
int qos_dba_stop(void) {
    if (!g_is_running) {
        return 0;
    }
    
    g_qos_system.should_exit = 1;
    
    if (g_monitor_thread) {
        pthread_join(g_monitor_thread, NULL);
        g_monitor_thread = 0;
    }
    
    g_is_running = 0;
    DEBUG_LOG("DBA已停止");
    return 0;
}

// 重新加载配置
int qos_dba_reload_config(void) {
    pthread_mutex_lock(&g_qos_system.mutex);
    
    // 保存当前分类状态
    int *upload_current_bw = NULL;
    int *download_current_bw = NULL;
    
    if (g_qos_system.upload_class_count > 0) {
        upload_current_bw = malloc(g_qos_system.upload_class_count * sizeof(int));
        for (int i = 0; i < g_qos_system.upload_class_count; i++) {
            upload_current_bw[i] = g_qos_system.upload_classes[i].current_kbps;
        }
    }
    
    if (g_qos_system.download_class_count > 0) {
        download_current_bw = malloc(g_qos_system.download_class_count * sizeof(int));
        for (int i = 0; i < g_qos_system.download_class_count; i++) {
            download_current_bw[i] = g_qos_system.download_classes[i].current_kbps;
        }
    }
    
    // 释放旧分类
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
    
    // 重新加载配置
    int ret = qos_dba_init("/etc/config/qos_gargoyle");
    
    if (ret == 0) {
        // 恢复带宽设置
        for (int i = 0; i < g_qos_system.upload_class_count && i < MAX_CLASSES; i++) {
            if (i < g_qos_system.upload_class_count) {
                adjust_tc_class_bandwidth(g_qos_system.wan_interface,
                                        g_qos_system.upload_classes[i].classid,
                                        upload_current_bw[i]);
                g_qos_system.upload_classes[i].current_kbps = upload_current_bw[i];
            }
        }
        
        for (int i = 0; i < g_qos_system.download_class_count && i < MAX_CLASSES; i++) {
            if (i < g_qos_system.download_class_count) {
                adjust_tc_class_bandwidth(g_qos_system.wan_interface,
                                        g_qos_system.download_classes[i].classid,
                                        download_current_bw[i]);
                g_qos_system.download_classes[i].current_kbps = download_current_bw[i];
            }
        }
    }
    
    if (upload_current_bw) free(upload_current_bw);
    if (download_current_bw) free(download_current_bw);
    
    pthread_mutex_unlock(&g_qos_system.mutex);
    
    return ret;
}

// 设置详细输出
int qos_dba_set_verbose(int verbose) {
    g_qos_system.verbose = verbose ? 1 : 0;
    return 0;
}