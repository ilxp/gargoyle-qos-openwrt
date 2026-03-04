#include "qos_dba.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <syslog.h>
#include <unistd.h>

// 调试宏
#define DEBUG_LOG(fmt, ...) syslog(LOG_DEBUG, "QoS DBA: " fmt, ##__VA_ARGS__)
#define ERROR_LOG(fmt, ...) syslog(LOG_ERR, "QoS DBA Error: " fmt, ##__VA_ARGS__)
#define INFO_LOG(fmt, ...) syslog(LOG_INFO, "QoS DBA: " fmt, ##__VA_ARGS__)

// 检查冷却时间
int is_cooldown_period(qos_class_t *cls) {
    time_t now = time(NULL);
    if (difftime(now, cls->last_adjust_time) < g_qos_system.config.cooldown_time) {
        return 1;
    }
    return 0;
}

// 获取使用状态
usage_state_t get_usage_state(qos_class_t *cls) {
    if (!cls) return NORMAL_USAGE;
    
    int usage_percent = (int)(cls->usage_rate * 100);
    
    if (usage_percent >= g_qos_system.config.high_usage_threshold) {
        return HIGH_USAGE;
    } else if (usage_percent <= g_qos_system.config.low_usage_threshold) {
        return LOW_USAGE;
    } else {
        return NORMAL_USAGE;
    }
}

// 检查是否可以借用带宽
int can_borrow_bandwidth(qos_class_t *cls) {
    if (!cls) return 0;
    
    if (cls->status != HIGH_USAGE) {
        return 0;
    }
    
    if (cls->status_duration[HIGH_USAGE] < g_qos_system.config.high_usage_duration) {
        return 0;
    }
    
    if (is_cooldown_period(cls)) {
        return 0;
    }
    
    return 1;
}

// 检查是否可以借出带宽
int can_lend_bandwidth(qos_class_t *cls) {
    if (!cls) return 0;
    
    if (cls->status != LOW_USAGE) {
        return 0;
    }
    
    if (cls->status_duration[LOW_USAGE] < g_qos_system.config.low_usage_duration) {
        return 0;
    }
    
    if (is_cooldown_period(cls)) {
        return 0;
    }
    
    // 检查是否有可用带宽
    int available = cls->current_kbps - cls->used_kbps;
    int max_borrow = cls->current_kbps - cls->config_min_kbps;
    
    if (available < g_qos_system.config.min_change_kbps) {
        return 0;
    }
    
    if (available > max_borrow) {
        available = max_borrow;
    }
    
    return (available >= g_qos_system.config.min_change_kbps);
}

// 检查是否应该归还带宽
int should_return_bandwidth(qos_class_t *cls) {
    if (!cls) return 0;
    
    if (cls->borrowed_kbps <= 0) {
        return 0;
    }
    
    if (cls->status != LOW_USAGE) {
        return 0;
    }
    
    if (cls->status_duration[LOW_USAGE] < g_qos_system.config.low_usage_duration) {
        return 0;
    }
    
    if (is_cooldown_period(cls)) {
        return 0;
    }
    
    int usage_percent = (int)(cls->usage_rate * 100);
    if (usage_percent > g_qos_system.config.return_threshold) {
        return 0;
    }
    
    return 1;
}

// 借用带宽
int borrow_bandwidth(qos_class_t *borrower, qos_class_t *lender, int kbps) {
    if (!borrower || !lender || kbps <= 0) {
        return -1;
    }
    
    // 检查可以借用的最大带宽
    int available = lender->current_kbps - lender->used_kbps;
    int max_borrow = lender->current_kbps - lender->config_min_kbps;
    
    if (available > max_borrow) {
        available = max_borrow;
    }
    
    if (available < kbps) {
        kbps = available;
    }
    
    if (kbps < g_qos_system.config.min_change_kbps) {
        return -1;
    }
    
    // 调整出借者带宽
    int new_lender_bw = lender->current_kbps - kbps;
    if (apply_qos_rule(lender) != 0) {
        return -1;
    }
    
    lender->current_kbps = new_lender_bw;
    lender->borrowed_kbps -= kbps;
    
    // 调整借用者带宽
    int new_borrower_bw = borrower->current_kbps + kbps;
    if (apply_qos_rule(borrower) != 0) {
        // 回滚
        int rollback_lender_bw = lender->current_kbps + kbps;
        apply_tc_rule(g_qos_system.iface_name, lender->classid, rollback_lender_bw);
        lender->current_kbps = rollback_lender_bw;
        lender->borrowed_kbps += kbps;
        return -1;
    }
    
    borrower->current_kbps = new_borrower_bw;
    borrower->borrowed_kbps += kbps;
    
    time_t now = time(NULL);
    borrower->last_adjust_time = now;
    lender->last_adjust_time = now;
    
    INFO_LOG("带宽借用: %s 从 %s 借用 %d kbps", borrower->name, lender->name, kbps);
    return 0;
}

// 归还带宽
int return_bandwidth(qos_class_t *returner, qos_class_t *receiver, int kbps) {
    if (!returner || kbps <= 0) {
        return -1;
    }
    
    if (returner->borrowed_kbps < kbps) {
        kbps = returner->borrowed_kbps;
    }
    
    if (kbps < g_qos_system.config.min_change_kbps) {
        return -1;
    }
    
    // 如果指定了接收者，归还给原主
    if (receiver) {
        int new_receiver_bw = receiver->current_kbps + kbps;
        if (apply_qos_rule(receiver) != 0) {
            return -1;
        }
        receiver->current_kbps = new_receiver_bw;
        receiver->borrowed_kbps += kbps;
    }
    
    // 调整归还者带宽
    int new_returner_bw = returner->current_kbps - kbps;
    if (apply_qos_rule(returner) != 0) {
        // 回滚
        if (receiver) {
            int rollback_receiver_bw = receiver->current_kbps - kbps;
            apply_tc_rule(g_qos_system.iface_name, receiver->classid, rollback_receiver_bw);
            receiver->current_kbps = rollback_receiver_bw;
            receiver->borrowed_kbps -= kbps;
        }
        return -1;
    }
    
    returner->current_kbps = new_returner_bw;
    returner->borrowed_kbps -= kbps;
    
    time_t now = time(NULL);
    returner->last_adjust_time = now;
    if (receiver) {
        receiver->last_adjust_time = now;
    }
    
    INFO_LOG("带宽归还: %s 归还 %d kbps", returner->name, kbps);
    return 0;
}

// 重置带宽
int reset_bandwidth(qos_class_t *cls) {
    if (!cls) {
        return -1;
    }
    
    if (cls->borrowed_kbps == 0) {
        return 0; // 无需重置
    }
    
    // 将带宽重置为配置值
    int target_bw = cls->config_min_kbps;
    if (cls->current_kbps != target_bw) {
        if (apply_qos_rule(cls) != 0) {
            return -1;
        }
        
        int returned = cls->borrowed_kbps;
        cls->current_kbps = target_bw;
        cls->borrowed_kbps = 0;
        
        time_t now = time(NULL);
        cls->last_adjust_time = now;
        
        INFO_LOG("带宽重置: %s 重置为 %d kbps (归还 %d kbps)", 
                cls->name, target_bw, returned);
    }
    
    return 0;
}

// 主循环
int qos_dba_loop_once(void) {
    int adjustments = 0;
    
    if (!g_qos_system.running) {
        return 0;
    }
    
    // 监控所有分类
    monitor_all_classes();
    
    // 调整上传分类
    adjustments += adjust_upload_classes();
    
    // 调整下载分类
    adjustments += adjust_download_classes();
    
    // 自动归还带宽
    adjustments += auto_return_borrowed_bandwidth();
    
    return adjustments;
}

// 打印状态
void print_dba_status(void) {
    printf("=== QoS DBA 状态 ===\n");
    printf("接口: %s\n", g_qos_system.iface_name);
    printf("运行状态: %s\n", g_qos_system.running ? "是" : "否");
    printf("总上传带宽: %d kbps\n", g_qos_system.total_upload_kbps);
    printf("总下载带宽: %d kbps\n", g_qos_system.total_download_kbps);
    printf("\n");
}

void print_qos_classes_status(void) {
    printf("=== QoS 分类状态 ===\n");
    printf("上传分类:\n");
    for (int i = 0; i < g_qos_system.upload_class_count; i++) {
        qos_class_t *cls = &g_qos_system.upload_classes[i];
        const char *status_str = "正常";
        if (cls->status == HIGH_USAGE) status_str = "高";
        else if (cls->status == LOW_USAGE) status_str = "低";
        
        printf("  %s: 当前%d/%d kbps, 已用%d kbps, 使用率%.1f%%, 状态:%s, 借用:%d kbps\n",
               cls->name, cls->current_kbps, cls->config_max_kbps, cls->used_kbps,
               cls->usage_rate * 100, status_str, cls->borrowed_kbps);
    }
    
    printf("\n下载分类:\n");
    for (int i = 0; i < g_qos_system.download_class_count; i++) {
        qos_class_t *cls = &g_qos_system.download_classes[i];
        const char *status_str = "正常";
        if (cls->status == HIGH_USAGE) status_str = "高";
        else if (cls->status == LOW_USAGE) status_str = "低";
        
        printf("  %s: 当前%d/%d kbps, 已用%d kbps, 使用率%.1f%%, 状态:%s, 借用:%d kbps\n",
               cls->name, cls->current_kbps, cls->config_max_kbps, cls->used_kbps,
               cls->usage_rate * 100, status_str, cls->borrowed_kbps);
    }
    printf("\n");
}