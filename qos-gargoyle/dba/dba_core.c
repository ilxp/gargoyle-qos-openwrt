#include "qos_dba.h"
#include "config_parser.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <pthread.h>
#include <syslog.h>
#include <unistd.h>

#define DEBUG_LOG(fmt, ...) syslog(LOG_DEBUG, "QoS DBA: " fmt, ##__VA_ARGS__)
#define ERROR_LOG(fmt, ...) syslog(LOG_ERR, "QoS DBA Error: " fmt, ##__VA_ARGS__)
#define INFO_LOG(fmt, ...) syslog(LOG_INFO, "QoS DBA: " fmt, ##__VA_ARGS__)

// 全局系统变量
qos_dba_system_t g_qos_system = {0};

// 计算可用借用带宽
static int calculate_available_bandwidth(qos_class_t *class_array, int class_count, int exclude_index) {
    int total_available = 0;
    
    for (int i = 0; i < class_count; i++) {
        if (i == exclude_index) continue;
        
        qos_class_t *cls = &class_array[i];
        
        // 计算可用带宽
        int available = cls->current_kbps - cls->used_kbps;
        if (available > 0) {
            // 确保不降到最小带宽以下
            int max_borrow = cls->current_kbps - cls->config_min_kbps;
            if (available > max_borrow) {
                available = max_borrow;
            }
            
            if (available > 0) {
                total_available += available;
            }
        }
    }
    
    return total_available;
}

// 获取带宽使用率
float get_class_usage_rate(const char *interface, unsigned int classid) {
    int used_kbps = 0;
    int current_kbps = 0;
    
    // 从tc中获取实际使用情况
    char cmd[256];
    FILE *fp;
    
    // 查询分类统计
    snprintf(cmd, sizeof(cmd), 
             "tc -s class show dev %s parent 1:%d 2>/dev/null | grep -E 'Sent|bytes' | head -2 | tail -1 | awk '{print $2}'", 
             interface, classid);
    
    fp = popen(cmd, "r");
    if (fp) {
        char buffer[64];
        if (fgets(buffer, sizeof(buffer), fp)) {
            used_kbps = atoi(buffer) * 8 / 1024; // bytes to kbps
        }
        pclose(fp);
    }
    
    // 获取当前带宽
    for (int i = 0; i < g_qos_system.upload_class_count; i++) {
        if (g_qos_system.upload_classes[i].classid == classid) {
            current_kbps = g_qos_system.upload_classes[i].current_kbps;
            break;
        }
    }
    
    for (int i = 0; i < g_qos_system.download_class_count; i++) {
        if (g_qos_system.download_classes[i].classid == classid) {
            current_kbps = g_qos_system.download_classes[i].current_kbps;
            break;
        }
    }
    
    if (current_kbps <= 0) {
        return 0.0f;
    }
    
    return (float)used_kbps / current_kbps;
}

// 获取使用的kbps
int get_class_used_kbps(const char *interface, unsigned int classid) {
    int used_kbps = 0;
    char cmd[256];
    FILE *fp;
    
    snprintf(cmd, sizeof(cmd), 
             "tc -s class show dev %s parent 1:%d 2>/dev/null | grep -E 'Sent|bytes' | head -2 | tail -1 | awk '{print $2}'", 
             interface, classid);
    
    fp = popen(cmd, "r");
    if (fp) {
        char buffer[64];
        if (fgets(buffer, sizeof(buffer), fp)) {
            used_kbps = atoi(buffer) * 8 / 1024; // bytes to kbps
        }
        pclose(fp);
    }
    
    return used_kbps;
}

// 调整TC分类带宽
int adjust_tc_class_bandwidth(const char *interface, unsigned int classid, int kbps) {
    char cmd[256];
    int result;
    
    // 限制最小带宽
    if (kbps < 8) kbps = 8;
    
    // 构建tc命令
    snprintf(cmd, sizeof(cmd), 
             "tc class change dev %s parent 1: classid 1:%d htb rate %dkbit ceil %dkbit burst 15k cburst 15k", 
             interface, classid, kbps, kbps);
    
    DEBUG_LOG("执行TC命令: %s", cmd);
    
    result = system(cmd);
    if (result == 0) {
        INFO_LOG("成功调整分类 1:%d 带宽为 %d kbps", classid, kbps);
        return 0;
    } else {
        ERROR_LOG("调整分类 1:%d 带宽失败: %s", classid, cmd);
        return -1;
    }
}

// 调整上传分类
int adjust_upload_classes(void) {
    int adjustments = 0;
    time_t now = time(NULL);
    
    if (!g_qos_system.config.enable) {
        return 0;
    }
    
    for (int i = 0; i < g_qos_system.upload_class_count; i++) {
        qos_class_t *cls = &g_qos_system.upload_classes[i];
        
        // 检查冷却时间
        if (is_cooldown_period(cls)) {
            continue;
        }
        
        // 检查是否需要调整
        if (cls->status == HIGH_USAGE && 
            cls->status_duration[HIGH_USAGE] >= g_qos_system.config.high_usage_duration) {
            
            // 高使用率，需要借用带宽
            int need_bw = cls->current_kbps * (cls->usage_rate - 0.85f) / 0.15f;
            if (need_bw < g_qos_system.config.min_borrow_kbps) {
                need_bw = g_qos_system.config.min_borrow_kbps;
            }
            
            // 从低优先级分类借用
            int borrowed = 0;
            for (int j = i + 1; j < g_qos_system.upload_class_count && borrowed < need_bw; j++) {
                qos_class_t *donor = &g_qos_system.upload_classes[j];
                
                if (donor->status == LOW_USAGE && 
                    donor->status_duration[LOW_USAGE] >= g_qos_system.config.low_usage_duration &&
                    can_lend_bandwidth(donor)) {
                    
                    int can_borrow = donor->current_kbps - donor->used_kbps;
                    int max_borrow = donor->current_kbps - donor->config_min_kbps;
                    
                    if (can_borrow > max_borrow) {
                        can_borrow = max_borrow;
                    }
                    
                    int borrow_amount = (int)(can_borrow * g_qos_system.config.borrow_ratio);
                    if (borrow_amount < g_qos_system.config.min_change_kbps) {
                        continue;
                    }
                    
                    int new_donor_bw = donor->current_kbps - borrow_amount;
                    if (new_donor_bw >= donor->config_min_kbps) {
                        // 调整捐赠者带宽
                        if (borrow_bandwidth(cls, donor, borrow_amount) == 0) {
                            borrowed += borrow_amount;
                            adjustments++;
                            
                            DEBUG_LOG("上传分类 %s 从 %s 借用 %d kbps", 
                                     cls->name, donor->name, borrow_amount);
                        }
                    }
                }
            }
            
        } else if (cls->status == LOW_USAGE && 
                   cls->status_duration[LOW_USAGE] >= g_qos_system.config.low_usage_duration) {
            
            // 低使用率，但需要检查是否借用了带宽
            if (cls->borrowed_kbps > 0 && should_return_bandwidth(cls)) {
                // 尝试归还部分带宽
                int can_return = cls->borrowed_kbps;
                int return_amount = (int)(can_return * g_qos_system.config.return_speed);
                
                if (return_amount >= g_qos_system.config.min_change_kbps) {
                    if (return_bandwidth(cls, NULL, return_amount) == 0) {
                        adjustments++;
                        DEBUG_LOG("上传分类 %s 归还 %d kbps", cls->name, return_amount);
                    }
                }
            }
        }
    }
    
    return adjustments;
}

// 调整下载分类
int adjust_download_classes(void) {
    int adjustments = 0;
    time_t now = time(NULL);
    
    if (!g_qos_system.config.enable) {
        return 0;
    }
    
    for (int i = 0; i < g_qos_system.download_class_count; i++) {
        qos_class_t *cls = &g_qos_system.download_classes[i];
        
        // 检查冷却时间
        if (is_cooldown_period(cls)) {
            continue;
        }
        
        // 检查是否需要调整
        if (cls->status == HIGH_USAGE && 
            cls->status_duration[HIGH_USAGE] >= g_qos_system.config.high_usage_duration) {
            
            // 高使用率，需要借用带宽
            int need_bw = cls->current_kbps * (cls->usage_rate - 0.85f) / 0.15f;
            if (need_bw < g_qos_system.config.min_borrow_kbps) {
                need_bw = g_qos_system.config.min_borrow_kbps;
            }
            
            // 从低优先级分类借用
            int borrowed = 0;
            for (int j = i + 1; j < g_qos_system.download_class_count && borrowed < need_bw; j++) {
                qos_class_t *donor = &g_qos_system.download_classes[j];
                
                if (donor->status == LOW_USAGE && 
                    donor->status_duration[LOW_USAGE] >= g_qos_system.config.low_usage_duration &&
                    can_lend_bandwidth(donor)) {
                    
                    int can_borrow = donor->current_kbps - donor->used_kbps;
                    int max_borrow = donor->current_kbps - donor->config_min_kbps;
                    
                    if (can_borrow > max_borrow) {
                        can_borrow = max_borrow;
                    }
                    
                    int borrow_amount = (int)(can_borrow * g_qos_system.config.borrow_ratio);
                    if (borrow_amount < g_qos_system.config.min_change_kbps) {
                        continue;
                    }
                    
                    int new_donor_bw = donor->current_kbps - borrow_amount;
                    if (new_donor_bw >= donor->config_min_kbps) {
                        // 调整捐赠者带宽
                        if (borrow_bandwidth(cls, donor, borrow_amount) == 0) {
                            borrowed += borrow_amount;
                            adjustments++;
                            
                            DEBUG_LOG("下载分类 %s 从 %s 借用 %d kbps", 
                                     cls->name, donor->name, borrow_amount);
                        }
                    }
                }
            }
            
        } else if (cls->status == LOW_USAGE && 
                   cls->status_duration[LOW_USAGE] >= g_qos_system.config.low_usage_duration) {
            
            // 低使用率，但需要检查是否借用了带宽
            if (cls->borrowed_kbps > 0 && should_return_bandwidth(cls)) {
                // 尝试归还部分带宽
                int can_return = cls->borrowed_kbps;
                int return_amount = (int)(can_return * g_qos_system.config.return_speed);
                
                if (return_amount >= g_qos_system.config.min_change_kbps) {
                    if (return_bandwidth(cls, NULL, return_amount) == 0) {
                        adjustments++;
                        DEBUG_LOG("下载分类 %s 归还 %d kbps", cls->name, return_amount);
                    }
                }
            }
        }
    }
    
    return adjustments;
}

// 监控所有分类
void monitor_all_classes(void) {
    static time_t last_check = 0;
    time_t now = time(NULL);
    
    if (difftime(now, last_check) < 1.0) {
        return;
    }
    
    // 监控上传分类
    for (int i = 0; i < g_qos_system.upload_class_count; i++) {
        qos_class_t *cls = &g_qos_system.upload_classes[i];
        
        // 获取当前使用率
        cls->usage_rate = get_class_usage_rate(g_qos_system.iface_name, cls->classid);
        cls->used_kbps = get_class_used_kbps(g_qos_system.iface_name, cls->classid);
        
        // 更新状态
        usage_state_t new_state = get_usage_state(cls);
        
        if (new_state != cls->status) {
            // 状态变化，重置持续时间
            memset(cls->status_duration, 0, sizeof(cls->status_duration));
            cls->status = new_state;
        }
        
        // 增加当前状态持续时间
        cls->status_duration[cls->status]++;
        
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
        cls->usage_rate = get_class_usage_rate(g_qos_system.iface_name, cls->classid);
        cls->used_kbps = get_class_used_kbps(g_qos_system.iface_name, cls->classid);
        
        // 更新状态
        usage_state_t new_state = get_usage_state(cls);
        
        if (new_state != cls->status) {
            // 状态变化，重置持续时间
            memset(cls->status_duration, 0, sizeof(cls->status_duration));
            cls->status = new_state;
        }
        
        // 增加当前状态持续时间
        cls->status_duration[cls->status]++;
        
        // 更新峰值
        if (cls->used_kbps > cls->peak_usage_kbps) {
            cls->peak_usage_kbps = cls->used_kbps;
        }
        
        // 更新滑动平均
        cls->avg_usage_rate = (cls->avg_usage_rate * 0.9f) + (cls->usage_rate * 0.1f);
    }
    
    last_check = now;
}

// 自动归还借用带宽
int auto_return_borrowed_bandwidth(void) {
    int returned = 0;
    time_t now = time(NULL);
    
    if (!g_qos_system.config.auto_return_enable) {
        return 0;
    }
    
    // 检查上传分类
    for (int i = 0; i < g_qos_system.upload_class_count; i++) {
        qos_class_t *cls = &g_qos_system.upload_classes[i];
        
        if (cls->borrowed_kbps > 0 && 
            cls->status == LOW_USAGE &&
            cls->status_duration[LOW_USAGE] >= g_qos_system.config.low_usage_duration &&
            should_return_bandwidth(cls)) {
            
            int return_amount = (int)(cls->borrowed_kbps * g_qos_system.config.return_speed);
            if (return_amount < g_qos_system.config.min_change_kbps) {
                return_amount = cls->borrowed_kbps;
            }
            
            if (return_bandwidth(cls, NULL, return_amount) == 0) {
                returned += return_amount;
                DEBUG_LOG("上传分类 %s 自动归还 %d kbps", cls->name, return_amount);
            }
        }
    }
    
    // 检查下载分类
    for (int i = 0; i < g_qos_system.download_class_count; i++) {
        qos_class_t *cls = &g_qos_system.download_classes[i];
        
        if (cls->borrowed_kbps > 0 && 
            cls->status == LOW_USAGE &&
            cls->status_duration[LOW_USAGE] >= g_qos_system.config.low_usage_duration &&
            should_return_bandwidth(cls)) {
            
            int return_amount = (int)(cls->borrowed_kbps * g_qos_system.config.return_speed);
            if (return_amount < g_qos_system.config.min_change_kbps) {
                return_amount = cls->borrowed_kbps;
            }
            
            if (return_bandwidth(cls, NULL, return_amount) == 0) {
                returned += return_amount;
                DEBUG_LOG("下载分类 %s 自动归还 %d kbps", cls->name, return_amount);
            }
        }
    }
    
    return returned;
}