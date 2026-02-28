#include "qos_dba.h"
#include <signal.h>
#include <sys/wait.h>
#include <uci.h>

// 全局变量定义
qos_dba_system_t g_qos_system = {0};
static pthread_t g_monitor_thread = 0;
static int g_is_running = 0;

// borrow_bandwidth_for_class函数是static函数，只在qos_dba.c内部使用
static int borrow_bandwidth_for_class(qos_class_t *dst_class, int needed_kbps, int is_upload);

// 辅助函数：解析带宽字符串
static int parse_bandwidth_string(const char *str) {
    if (!str) return 0;
    
    char *endptr;
    long value = strtol(str, &endptr, 10);
    
    if (endptr == str) return 0;
    
    if (*endptr == 'k' || *endptr == 'K') {
        return (int)value;
    } else if (*endptr == 'm' || *endptr == 'M') {
        return (int)(value * 1000);
    } else if (*endptr == 'g' || *endptr == 'G') {
        return (int)(value * 1000000);
    } else {
        return (int)value;
    }
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
        g_qos_system.wan_interface[MAX_IFACE_LEN-1] = '\0';
        DEBUG_LOG("检测到WAN接口: %s", g_qos_system.wan_interface);
        return 0;
    }
    
    // 尝试常见接口
    const char *common_ifaces[] = {"eth0", "eth1", "ppp0", "wan", "br-wan", NULL};
    for (int i = 0; common_ifaces[i] != NULL; i++) {
        snprintf(cmd, sizeof(cmd), "ip link show %s 2>/dev/null | grep -q 'state UP'", common_ifaces[i]);
        if (execute_command(cmd, NULL, 0) == 0) {
            strncpy(g_qos_system.wan_interface, common_ifaces[i], MAX_IFACE_LEN-1);
            g_qos_system.wan_interface[MAX_IFACE_LEN-1] = '\0';
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
                            DEBUG_LOG("从配置获取带宽: %d kbps (%.1f Mbps)", 
                                     g_qos_system.total_bandwidth_kbps,
                                     g_qos_system.total_bandwidth_kbps / 1000.0);
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

// 打印系统状态
void qos_dba_print_status(void) {
    dba_config_t *config = &g_qos_system.config;
    
    printf("\n=================== QoS DBA 状态 ===================\n");
    printf("接口: %s, 总带宽: %d kbps (%.1f Mbps)\n", 
           g_qos_system.wan_interface,
           g_qos_system.total_bandwidth_kbps,
           g_qos_system.total_bandwidth_kbps / 1000.0);
    printf("DBA状态: %s, 检查间隔: %d秒\n",
           config->enabled ? "启用" : "禁用",
           config->interval);
    
    if (g_qos_system.upload_class_count > 0) {
        printf("\n上传分类:\n");
        printf("%-12s %-8s %-8s %-8s %-8s %-8s %-8s %-12s %-8s\n", 
               "分类", "配置%", "最小", "最大", "当前", "使用", "使用率", "状态", "借用");
        printf("--------------------------------------------------------------------------------\n");
        
        for (int i = 0; i < g_qos_system.upload_class_count; i++) {
            qos_class_t *cls = &g_qos_system.upload_classes[i];
            
            char status[32];
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
    }
    
    if (g_qos_system.download_class_count > 0) {
        printf("\n下载分类:\n");
        printf("%-12s %-8s %-8s %-8s %-8s %-8s %-8s %-12s %-8s\n", 
               "分类", "配置%", "最小", "最大", "当前", "使用", "使用率", "状态", "借用");
        printf("--------------------------------------------------------------------------------\n");
        
        for (int i = 0; i < g_qos_system.download_class_count; i++) {
            qos_class_t *cls = &g_qos_system.download_classes[i];
            
            char status[32];
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
        
        pthread_mutex_lock(&g_qos_system.mutex);
        
        // 1. 监控分类状态
        monitor_all_classes();
        
        // 2. 动态调整
        int upload_adjustments = adjust_upload_classes();
        int download_adjustments = adjust_download_classes();
        
        // 3. 自动归还
        int returned = auto_return_borrowed_bandwidth();
        
        // 4. 更新状态文件
        if (upload_adjustments > 0 || download_adjustments > 0 || returned > 0) {
            write_dba_status();
        } else {
            // 即使没有调整，也每分钟更新一次状态文件
            static time_t last_status_update = 0;
            time_t now = time(NULL);
            if (now - last_status_update >= 60) {
                write_dba_status();
                last_status_update = now;
            }
        }
        
        pthread_mutex_unlock(&g_qos_system.mutex);
        
        // 5. 休眠
        sleep(g_qos_system.config.interval);
    }
    
    DEBUG_LOG("QoS DBA监控线程退出");
    return NULL;
}

// 初始化系统
int qos_dba_init(const char *config_path) {
    if (!config_path) {
        config_path = DEFAULT_CONFIG_PATH;
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

// 调整上传分类带宽
int adjust_upload_classes(void) {
    int adjustments = 0;
    
    DEBUG_LOG("开始调整上传分类...");
    
    // 1. 找出高负载分类（需要更多带宽）
    for (int i = 0; i < g_qos_system.upload_class_count; i++) {
        qos_class_t *class = &g_qos_system.upload_classes[i];
        
        if (!class->enabled) {
            continue;
        }
        
        // 检查是否需要调整
        if (class->high_usage_seconds >= g_qos_system.config.high_usage_duration) {
            // 高负载分类，需要更多带宽
            DEBUG_LOG("上传分类 %s 高负载: 使用率=%.1f%%, 持续%d秒", 
                     class->name, class->usage_rate * 100, class->high_usage_seconds);
            
            // 计算需要的额外带宽
            int needed_kbps = 0;
            if (class->current_kbps < class->config_max_kbps) {
                // 计算目标带宽：使用率降到85%所需的带宽
                int target_kbps = (int)(class->used_kbps * 100.0 / g_qos_system.config.high_usage_threshold);
                target_kbps = MIN(target_kbps, class->config_max_kbps);
                
                needed_kbps = target_kbps - class->current_kbps;
                
                if (needed_kbps > 0) {
                    // 从低优先级低使用率分类借用带宽
                    int borrowed = borrow_bandwidth_for_class(class, needed_kbps, 1); // 1表示上传方向
                    if (borrowed > 0) {
                        // 调整TC分类带宽
                        int new_kbps = class->current_kbps + borrowed;
                        if (adjust_tc_class_bandwidth(g_qos_system.wan_interface, 
                                                       class->classid, new_kbps) == 0) {
                            class->current_kbps = new_kbps;
                            class->borrowed_kbps += borrowed;
                            class->high_usage_seconds = 0; // 重置计时器
                            adjustments++;
                            
                            DEBUG_LOG("为上传分类 %s 增加 %d kbps 带宽 (当前: %d kbps)", 
                                     class->name, borrowed, new_kbps);
                        }
                    }
                }
            }
        } else if (class->low_usage_seconds >= g_qos_system.config.low_usage_duration) {
            // 低负载分类，但只有借出逻辑在borrow_bandwidth_for_class中处理
        }
    }
    
	if (adjustments > 0) {
        DEBUG_LOG("上传分类调整完成，共调整 %d 个分类", adjustments);
        
        // 在这里调用write_dba_status
        write_dba_status();  // 添加这行
    }
	
    return adjustments;
}

// 调整下载分类带宽
int adjust_download_classes(void) {
    int adjustments = 0;
    
    DEBUG_LOG("开始调整下载分类...");
    
    for (int i = 0; i < g_qos_system.download_class_count; i++) {
        qos_class_t *class = &g_qos_system.download_classes[i];
        
        if (!class->enabled) {
            continue;
        }
        
        // 检查是否需要调整
        if (class->high_usage_seconds >= g_qos_system.config.high_usage_duration) {
            // 高负载分类，需要更多带宽
            DEBUG_LOG("下载分类 %s 高负载: 使用率=%.1f%%, 持续%d秒", 
                     class->name, class->usage_rate * 100, class->high_usage_seconds);
            
            // 计算需要的额外带宽
            int needed_kbps = 0;
            if (class->current_kbps < class->config_max_kbps) {
                // 计算目标带宽：使用率降到85%所需的带宽
                int target_kbps = (int)(class->used_kbps * 100.0 / g_qos_system.config.high_usage_threshold);
                target_kbps = MIN(target_kbps, class->config_max_kbps);
                
                needed_kbps = target_kbps - class->current_kbps;
                
                if (needed_kbps > 0) {
                    // 从低优先级低使用率分类借用带宽
                    int borrowed = borrow_bandwidth_for_class(class, needed_kbps, 0); // 0表示下载方向
                    if (borrowed > 0) {
                        // 调整TC分类带宽
                        int new_kbps = class->current_kbps + borrowed;
                        if (adjust_tc_class_bandwidth("imq0", class->classid, new_kbps) == 0) {
                            class->current_kbps = new_kbps;
                            class->borrowed_kbps += borrowed;
                            class->high_usage_seconds = 0; // 重置计时器
                            adjustments++;
                            
                            DEBUG_LOG("为下载分类 %s 增加 %d kbps 带宽 (当前: %d kbps)", 
                                     class->name, borrowed, new_kbps);
                        }
                    }
                }
            }
        }
    }
	
	if (adjustments > 0) {
        DEBUG_LOG("下载分类调整完成，共调整 %d 个分类", adjustments);
        
        // 在这里调用write_dba_status
        write_dba_status();  // 添加这行
    }
    
    return adjustments;
}

// 自动归还借用的带宽
int auto_return_borrowed_bandwidth(void) {
    int total_returned = 0;
    
    if (!g_qos_system.config.auto_return_enable) {
        return 0;
    }
    
    DEBUG_LOG("检查自动归还...");
    
    // 检查上传分类
    for (int i = 0; i < g_qos_system.upload_class_count; i++) {
        qos_class_t *class = &g_qos_system.upload_classes[i];
        
        if (class->borrowed_kbps > 0) {
            // 有借用带宽的分类
            if (class->low_usage_seconds >= g_qos_system.config.low_usage_duration) {
                // 持续低使用，归还部分带宽
                int return_kbps = (int)(class->borrowed_kbps * g_qos_system.config.return_speed);
                return_kbps = MAX(return_kbps, g_qos_system.config.min_change_kbps);
                
                if (return_kbps > 0 && class->current_kbps - return_kbps >= class->config_min_kbps) {
                    int new_kbps = class->current_kbps - return_kbps;
                    if (adjust_tc_class_bandwidth(g_qos_system.wan_interface, 
                                                   class->classid, new_kbps) == 0) {
                        class->current_kbps = new_kbps;
                        class->borrowed_kbps -= return_kbps;
                        
                        // 找到对应的借出分类并更新
                        for (int j = 0; j < g_qos_system.upload_class_count; j++) {
                            qos_class_t *src_class = &g_qos_system.upload_classes[j];
                            if (src_class->lent_kbps > 0 && src_class->lent_to == i) {
                                src_class->lent_kbps -= return_kbps;
                                break;
                            }
                        }
                        
                        total_returned += return_kbps;
                        DEBUG_LOG("上传分类 %s 归还 %d kbps 带宽", class->name, return_kbps);
                    }
                }
            }
        }
    }
    
    // 检查下载分类
    for (int i = 0; i < g_qos_system.download_class_count; i++) {
        qos_class_t *class = &g_qos_system.download_classes[i];
        
        if (class->borrowed_kbps > 0) {
            if (class->low_usage_seconds >= g_qos_system.config.low_usage_duration) {
                int return_kbps = (int)(class->borrowed_kbps * g_qos_system.config.return_speed);
                return_kbps = MAX(return_kbps, g_qos_system.config.min_change_kbps);
                
                if (return_kbps > 0 && class->current_kbps - return_kbps >= class->config_min_kbps) {
                    int new_kbps = class->current_kbps - return_kbps;
                    if (adjust_tc_class_bandwidth("imq0", class->classid, new_kbps) == 0) {
                        class->current_kbps = new_kbps;
                        class->borrowed_kbps -= return_kbps;
                        
                        for (int j = 0; j < g_qos_system.download_class_count; j++) {
                            qos_class_t *src_class = &g_qos_system.download_classes[j];
                            if (src_class->lent_kbps > 0 && src_class->lent_to == i) {
                                src_class->lent_kbps -= return_kbps;
                                break;
                            }
                        }
                        
                        total_returned += return_kbps;
                        DEBUG_LOG("下载分类 %s 归还 %d kbps 带宽", class->name, return_kbps);
                    }
                }
            }
        }
    }
	
	if (total_returned > 0) {
        DEBUG_LOG("自动归还完成，共归还 %d kbps 带宽", total_returned);
        
        // 在这里调用write_dba_status
        write_dba_status();  // 添加这行
    }
    
    return total_returned;
}

// 为分类借用带宽
static int borrow_bandwidth_for_class(qos_class_t *dst_class, int needed_kbps, int is_upload) {
    int borrowed = 0;
    qos_class_t *src_classes = is_upload ? g_qos_system.upload_classes : g_qos_system.download_classes;
    int class_count = is_upload ? g_qos_system.upload_class_count : g_qos_system.download_class_count;
    
    // 从低优先级分类借用
    for (int i = 0; i < class_count; i++) {
        if (borrowed >= needed_kbps) {
            break;
        }
        
        qos_class_t *src_class = &src_classes[i];
        
        // 检查是否可以作为借出者：
        // 1. 优先级低于目标分类
        // 2. 当前低使用
        // 3. 有可用带宽
        if (src_class != dst_class && 
            src_class->priority > dst_class->priority &&
            src_class->low_usage_seconds >= g_qos_system.config.low_usage_duration &&
            src_class->current_kbps > src_class->config_min_kbps) {
            
            // 计算可借出的带宽
            int available_kbps = src_class->current_kbps - src_class->config_min_kbps;
            int lend_kbps = (int)(available_kbps * g_qos_system.config.borrow_ratio);
            lend_kbps = MAX(lend_kbps, g_qos_system.config.min_borrow_kbps);
            
            if (lend_kbps > 0) {
                int actual_lend = MIN(lend_kbps, needed_kbps - borrowed);
                
                // 确保不会借到低于最小带宽
                if (src_class->current_kbps - actual_lend >= src_class->config_min_kbps) {
                    // 更新源分类
                    int new_src_kbps = src_class->current_kbps - actual_lend;
                    const char *iface = is_upload ? g_qos_system.wan_interface : "imq0";
                    
                    if (adjust_tc_class_bandwidth(iface, src_class->classid, new_src_kbps) == 0) {
                        src_class->current_kbps = new_src_kbps;
                        src_class->lent_kbps += actual_lend;
                        src_class->lent_to = dst_class - src_classes; // 存储目标分类索引
                        
                        borrowed += actual_lend;
                        
                        DEBUG_LOG("从分类 %s 借出 %d kbps 给 %s", 
                                 src_class->name, actual_lend, dst_class->name);
                    }
                }
            }
        }
    }
    
    return borrowed;
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
    int ret = qos_dba_init(DEFAULT_CONFIG_PATH);
    
    if (ret == 0 && upload_current_bw && download_current_bw) {
        // 恢复带宽设置
        for (int i = 0; i < g_qos_system.upload_class_count; i++) {
            if (i < g_qos_system.upload_class_count) {
                adjust_tc_class_bandwidth(g_qos_system.wan_interface,
                                         g_qos_system.upload_classes[i].classid,
                                         upload_current_bw[i]);
                g_qos_system.upload_classes[i].current_kbps = upload_current_bw[i];
            }
        }
        
        for (int i = 0; i < g_qos_system.download_class_count; i++) {
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

// 写入DBA状态到JSON文件
void write_dba_status(void) {
    const char *status_file = "/tmp/qosdba.status";
    
    FILE *fp = fopen(status_file, "w");
    if (!fp) {
        DEBUG_LOG("无法写入状态文件: %s", status_file);
        return;
    }
    
    // 写入JSON格式的状态信息
    fprintf(fp, "{\n");
    fprintf(fp, "  \"timestamp\": %ld,\n", (long)time(NULL));
    fprintf(fp, "  \"enabled\": %s,\n", g_qos_system.config.enabled ? "true" : "false");
    
    // 写入上传分类状态
    fprintf(fp, "  \"upload_classes\": {\n");
    for (int i = 0; i < g_qos_system.upload_class_count; i++) {
        qos_class_t *cls = &g_qos_system.upload_classes[i];
        fprintf(fp, "    \"%s\": {\n", cls->name);
        fprintf(fp, "      \"current\": %d,\n", cls->current_kbps);
        fprintf(fp, "      \"used\": %d,\n", cls->used_kbps);
        fprintf(fp, "      \"usage_rate\": %.2f,\n", cls->usage_rate);
        fprintf(fp, "      \"borrowed\": %d\n", cls->borrowed_kbps);
        
        if (i < g_qos_system.upload_class_count - 1) {
            fprintf(fp, "    },\n");
        } else {
            fprintf(fp, "    }\n");
        }
    }
    fprintf(fp, "  },\n");
    
    // 写入下载分类状态
    fprintf(fp, "  \"download_classes\": {\n");
    for (int i = 0; i < g_qos_system.download_class_count; i++) {
        qos_class_t *cls = &g_qos_system.download_classes[i];
        fprintf(fp, "    \"%s\": {\n", cls->name);
        fprintf(fp, "      \"current\": %d,\n", cls->current_kbps);
        fprintf(fp, "      \"used\": %d,\n", cls->used_kbps);
        fprintf(fp, "      \"usage_rate\": %.2f,\n", cls->usage_rate);
        fprintf(fp, "      \"borrowed\": %d\n", cls->borrowed_kbps);
        
        if (i < g_qos_system.download_class_count - 1) {
            fprintf(fp, "    },\n");
        } else {
            fprintf(fp, "    }\n");
        }
    }
    fprintf(fp, "  }\n");
    fprintf(fp, "}\n");
    
    fclose(fp);
    chmod(status_file, 0644);
    
    DEBUG_LOG("状态已写入: %s", status_file);
}

