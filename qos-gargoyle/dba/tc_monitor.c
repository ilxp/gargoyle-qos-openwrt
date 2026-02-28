#include "qos_dba.h"
#include <sys/wait.h>

// 执行shell命令
int execute_command(const char *cmd, char *output, int output_len) {
    if (!cmd) return -1;
    
    FILE *fp = popen(cmd, "r");
    if (!fp) {
        DEBUG_LOG("执行命令失败: %s", cmd);
        return -1;
    }
    
    if (output && output_len > 0) {
        int total_read = 0;
        char buffer[256];
        
        while (fgets(buffer, sizeof(buffer), fp) != NULL) {
            int len = strlen(buffer);
            if (total_read + len < output_len) {
                strcpy(output + total_read, buffer);
                total_read += len;
            } else {
                break;
            }
        }
        output[total_read] = '\0';
    } else {
        // 无输出
        char buffer[1024];
        while (fgets(buffer, sizeof(buffer), fp) != NULL) {
            // 丢弃输出
        }
    }
    
    int status = pclose(fp);
    return WEXITSTATUS(status);
}

// 获取分类使用率
float get_class_usage_rate(const char *iface, const char *classid) {
    char cmd[256];
    char output[1024] = {0};
    
    // 获取当前速率
    snprintf(cmd, sizeof(cmd), 
             "tc -s class show dev %s 2>/dev/null | "
             "grep -A 2 'class htb %s' | "
             "grep -o 'rate [0-9]\\+[kmgt]\\?bit' | "
             "head -1", iface, classid);
    
    if (execute_command(cmd, output, sizeof(output)) != 0) {
        return 0.0f;
    }
    
    // 解析速率
    int rate_kbps = 0;
    if (strlen(output) > 0) {
        char *rate_str = output + 5;  // 跳过"rate "
        char *unit = strpbrk(rate_str, "kmgtKMGT");
        
        if (unit) {
            *unit = '\0';
            int value = atoi(rate_str);
            
            switch (*unit) {
                case 'k': case 'K':
                    rate_kbps = value;
                    break;
                case 'm': case 'M':
                    rate_kbps = value * 1000;
                    break;
                case 'g': case 'G':
                    rate_kbps = value * 1000000;
                    break;
                default:
                    rate_kbps = value;
                    break;
            }
        } else {
            rate_kbps = atoi(rate_str);
        }
    }
    
    if (rate_kbps <= 0) {
        return 0.0f;
    }
    
    // 获取已用带宽
    memset(output, 0, sizeof(output));
    snprintf(cmd, sizeof(cmd), 
             "tc -s class show dev %s 2>/dev/null | "
             "grep -A 2 'class htb %s' | "
             "grep 'Sent' | "
             "awk '{print $2}' | tail -1", iface, classid);
    
    if (execute_command(cmd, output, sizeof(output)) != 0) {
        return 0.0f;
    }
    
    long bytes = 0;
    if (strlen(output) > 0) {
        bytes = atol(output);
    }
    
    // 转换为kbps（假设最近1秒）
    int used_kbps = (int)(bytes * 8 / 1000.0);
    
    // 计算使用率
    if (rate_kbps > 0) {
        return (float)used_kbps / rate_kbps;
    }
    
    return 0.0f;
}

// 获取分类使用带宽(kbps)
int get_class_used_kbps(const char *iface, const char *classid) {
    char cmd[256];
    char output[1024] = {0};
    
    snprintf(cmd, sizeof(cmd), 
             "tc -s -d class show dev %s 2>/dev/null | "
             "awk '/class htb %s/{getline; getline; print $2}'", 
             iface, classid);
    
    if (execute_command(cmd, output, sizeof(output)) != 0) {
        return 0;
    }
    
    if (strlen(output) > 0) {
        long bytes = atol(output);
        // 转换为kbps
        return (int)(bytes * 8 / 1000.0);
    }
    
    return 0;
}

// 调整TC分类带宽
int adjust_tc_class_bandwidth(const char *iface, const char *classid, int new_kbps) {
    char cmd[512];
    
    // 尝试用tc class change命令
    snprintf(cmd, sizeof(cmd), 
             "tc class change dev %s parent 1: classid %s htb rate %dkbit ceil %dkbit 2>/dev/null", 
             iface, classid, new_kbps, new_kbps);
    
    int ret = system(cmd);
    
    if (ret != 0) {
        // 如果失败，尝试replace
        DEBUG_LOG("tc class change失败，尝试replace");
        snprintf(cmd, sizeof(cmd), 
                 "tc class replace dev %s parent 1: classid %s htb rate %dkbit ceil %dkbit 2>/dev/null", 
                 iface, classid, new_kbps, new_kbps);
        ret = system(cmd);
    }
    
    if (ret == 0) {
        DEBUG_LOG("调整TC分类 %s 带宽为 %d kbps 成功", classid, new_kbps);
    } else {
        DEBUG_LOG("调整TC分类 %s 带宽为 %d kbps 失败", classid, new_kbps);
    }
    
    return ret;
}

// 监控所有分类
static void monitor_all_classes(void) {
    pthread_mutex_lock(&g_qos_system.mutex);
    
    time_t now = time(NULL);
    static time_t last_check = 0;
    
    if (difftime(now, last_check) < 1.0) {
        pthread_mutex_unlock(&g_qos_system.mutex);
        return;
    }
    
    // 监控上传分类
    for (int i = 0; i < g_qos_system.upload_class_count; i++) {
        qos_class_t *cls = &g_qos_system.upload_classes[i];
        
        // 获取当前使用率
        cls->usage_rate = get_class_usage_rate(g_qos_system.wan_interface, cls->classid);
        cls->used_kbps = get_class_used_kbps(g_qos_system.wan_interface, cls->classid);
        
        // 更新状态持续时间
        if (cls->usage_rate * 100 >= g_qos_system.config.high_usage_threshold) {
            cls->high_usage_seconds++;
            cls->low_usage_seconds = 0;
            cls->normal_usage_seconds = 0;
        } else if (cls->usage_rate * 100 <= g_qos_system.config.low_usage_threshold) {
            cls->low_usage_seconds++;
            cls->high_usage_seconds = 0;
            cls->normal_usage_seconds = 0;
        } else {
            cls->normal_usage_seconds++;
            cls->high_usage_seconds = 0;
            cls->low_usage_seconds = 0;
        }
        
        // 更新峰值
        if (cls->used_kbps > cls->peak_usage_kbps) {
            cls->peak_usage_kbps = cls->used_kbps;
        }
        
        // 更新滑动平均
        cls->avg_usage_rate = (cls->avg_usage_rate * 0.9f) + (cls->usage_rate * 0.1f);
    }
    
    // 监控下载分类
    for (int i = 0; i < g_qos_system.download_class_count; i++) {
        qos_class_t *cls = &g_qos_system.download_classes[i];
        
        // 获取当前使用率
        cls->usage_rate = get_class_usage_rate(g_qos_system.wan_interface, cls->classid);
        cls->used_kbps = get_class_used_kbps(g_qos_system.wan_interface, cls->classid);
        
        // 更新状态持续时间
        if (cls->usage_rate * 100 >= g_qos_system.config.high_usage_threshold) {
            cls->high_usage_seconds++;
            cls->low_usage_seconds = 0;
            cls->normal_usage_seconds = 0;
        } else if (cls->usage_rate * 100 <= g_qos_system.config.low_usage_threshold) {
            cls->low_usage_seconds++;
            cls->high_usage_seconds = 0;
            cls->normal_usage_seconds = 0;
        } else {
            cls->normal_usage_seconds++;
            cls->high_usage_seconds = 0;
            cls->low_usage_seconds = 0;
        }
        
        // 更新峰值
        if (cls->used_kbps > cls->peak_usage_kbps) {
            cls->peak_usage_kbps = cls->used_kbps;
        }
        
        // 更新滑动平均
        cls->avg_usage_rate = (cls->avg_usage_rate * 0.9f) + (cls->usage_rate * 0.1f);
    }
    
    last_check = now;
    pthread_mutex_unlock(&g_qos_system.mutex);
}