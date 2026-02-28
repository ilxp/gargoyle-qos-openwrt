#include "qos_dba.h"
#include <math.h>

#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))

// 动态调整上传分类
static int adjust_upload_classes(void) {
    if (g_qos_system.upload_class_count < 2) {
        return 0;  // 需要至少2个分类才能调整
    }
    
    dba_config_t *config = &g_qos_system.config;
    qos_class_t *classes = g_qos_system.upload_classes;
    int class_count = g_qos_system.upload_class_count;
    time_t now = time(NULL);
    
    int adjustments = 0;
    
    // 1. 找出需要借用带宽的分类
    for (int i = 0; i < class_count; i++) {
        qos_class_t *need_class = &classes[i];
        
        // 检查冷却时间
        if (difftime(now, need_class->last_adjust_time) < config->cooldown_time) {
            continue;
        }
        
        // 检查是否满足借用条件
        if (need_class->high_usage_seconds >= config->high_usage_duration &&
            need_class->current_kbps < need_class->config_max_kbps &&
            need_class->usage_rate * 100 >= config->high_usage_threshold) {
            
            // 2. 找出可以借出带宽的分类
            qos_class_t *lend_class = NULL;
            
            for (int j = 0; j < class_count; j++) {
                if (i == j) continue;
                
                qos_class_t *candidate = &classes[j];
                
                // 检查是否满足借出条件
                if (candidate->low_usage_seconds >= config->low_usage_duration &&
                    candidate->current_kbps > candidate->config_min_kbps &&
                    candidate->usage_rate * 100 <= config->low_usage_threshold &&
                    candidate->priority >= need_class->priority) {  // 优先级保护
                    
                    if (!lend_class || 
                        candidate->usage_rate < lend_class->usage_rate ||
                        (candidate->usage_rate == lend_class->usage_rate && 
                         candidate->priority > lend_class->priority)) {
                        lend_class = candidate;
                    }
                }
            }
            
            if (!lend_class) {
                continue;
            }
            
            // 3. 计算借用带宽
            int need_bw = (int)((need_class->used_kbps / 0.9f) - need_class->current_kbps);
            need_bw = MAX(need_bw, config->min_change_kbps);
            
            int can_lend = (int)((lend_class->current_kbps - lend_class->used_kbps) * config->borrow_ratio);
            can_lend = MIN(can_lend, lend_class->current_kbps - lend_class->config_min_kbps);
            
            int actual_borrow = MIN(need_bw, can_lend);
            actual_borrow = MAX(actual_borrow, config->min_borrow_kbps);
            
            // 确保不超过最大值
            if (need_class->current_kbps + actual_borrow > need_class->config_max_kbps) {
                actual_borrow = need_class->config_max_kbps - need_class->current_kbps;
            }
            
            if (actual_borrow < config->min_borrow_kbps) {
                continue;
            }
            
            // 4. 执行调整
            DEBUG_LOG("上传调整: 从[%s]借%d kbps给[%s]", 
                     lend_class->name, actual_borrow, need_class->name);
            
            int new_lend_bw = lend_class->current_kbps - actual_borrow;
            int new_need_bw = need_class->current_kbps + actual_borrow;
            
            // 调整TC
            if (adjust_tc_class_bandwidth(g_qos_system.wan_interface, 
                                         lend_class->classid, new_lend_bw) == 0 &&
                adjust_tc_class_bandwidth(g_qos_system.wan_interface,
                                         need_class->classid, new_need_bw) == 0) {
                
                // 更新状态
                lend_class->current_kbps = new_lend_bw;
                need_class->current_kbps = new_need_bw;
                
                lend_class->borrowed_kbps -= actual_borrow;
                need_class->borrowed_kbps += actual_borrow;
                
                lend_class->last_adjust_time = now;
                need_class->last_adjust_time = now;
                
                lend_class->adjust_count++;
                need_class->adjust_count++;
                
                // 重置持续时间计数器
                lend_class->low_usage_seconds = 0;
                need_class->high_usage_seconds = 0;
                
                adjustments++;
            }
        }
    }
    
    return adjustments;
}

// 动态调整下载分类
static int adjust_download_classes(void) {
    if (g_qos_system.download_class_count < 2) {
        return 0;
    }
    
    dba_config_t *config = &g_qos_system.config;
    qos_class_t *classes = g_qos_system.download_classes;
    int class_count = g_qos_system.download_class_count;
    time_t now = time(NULL);
    
    int adjustments = 0;
    
    // 类似上传调整逻辑
    for (int i = 0; i < class_count; i++) {
        qos_class_t *need_class = &classes[i];
        
        if (difftime(now, need_class->last_adjust_time) < config->cooldown_time) {
            continue;
        }
        
        if (need_class->high_usage_seconds >= config->high_usage_duration &&
            need_class->current_kbps < need_class->config_max_kbps &&
            need_class->usage_rate * 100 >= config->high_usage_threshold) {
            
            qos_class_t *lend_class = NULL;
            
            for (int j = 0; j < class_count; j++) {
                if (i == j) continue;
                
                qos_class_t *candidate = &classes[j];
                
                if (candidate->low_usage_seconds >= config->low_usage_duration &&
                    candidate->current_kbps > candidate->config_min_kbps &&
                    candidate->usage_rate * 100 <= config->low_usage_threshold &&
                    candidate->priority >= need_class->priority) {
                    
                    if (!lend_class || 
                        candidate->usage_rate < lend_class->usage_rate ||
                        (candidate->usage_rate == lend_class->usage_rate && 
                         candidate->priority > lend_class->priority)) {
                        lend_class = candidate;
                    }
                }
            }
            
            if (!lend_class) {
                continue;
            }
            
            int need_bw = (int)((need_class->used_kbps / 0.9f) - need_class->current_kbps);
            need_bw = MAX(need_bw, config->min_change_kbps);
            
            int can_lend = (int)((lend_class->current_kbps - lend_class->used_kbps) * config->borrow_ratio);
            can_lend = MIN(can_lend, lend_class->current_kbps - lend_class->config_min_kbps);
            
            int actual_borrow = MIN(need_bw, can_lend);
            actual_borrow = MAX(actual_borrow, config->min_borrow_kbps);
            
            if (need_class->current_kbps + actual_borrow > need_class->config_max_kbps) {
                actual_borrow = need_class->config_max_kbps - need_class->current_kbps;
            }
            
            if (actual_borrow < config->min_borrow_kbps) {
                continue;
            }
            
            DEBUG_LOG("下载调整: 从[%s]借%d kbps给[%s]", 
                     lend_class->name, actual_borrow, need_class->name);
            
            int new_lend_bw = lend_class->current_kbps - actual_borrow;
            int new_need_bw = need_class->current_kbps + actual_borrow;
            
            if (adjust_tc_class_bandwidth(g_qos_system.wan_interface, 
                                         lend_class->classid, new_lend_bw) == 0 &&
                adjust_tc_class_bandwidth(g_qos_system.wan_interface,
                                         need_class->classid, new_need_bw) == 0) {
                
                lend_class->current_kbps = new_lend_bw;
                need_class->current_kbps = new_need_bw;
                
                lend_class->borrowed_kbps -= actual_borrow;
                need_class->borrowed_kbps += actual_borrow;
                
                lend_class->last_adjust_time = now;
                need_class->last_adjust_time = now;
                
                lend_class->adjust_count++;
                need_class->adjust_count++;
                
                lend_class->low_usage_seconds = 0;
                need_class->high_usage_seconds = 0;
                
                adjustments++;
            }
        }
    }
    
    return adjustments;
}

// 自动归还借用带宽
static int auto_return_borrowed_bandwidth(void) {
    dba_config_t *config = &g_qos_system.config;
    if (!config->auto_return_enable) {
        return 0;
    }
    
    time_t now = time(NULL);
    int total_returned = 0;
    
    // 处理上传分类
    for (int i = 0; i < g_qos_system.upload_class_count; i++) {
        qos_class_t *cls = &g_qos_system.upload_classes[i];
        
        if (cls->borrowed_kbps <= 0) {
            continue;
        }
        
        if (difftime(now, cls->last_adjust_time) < config->cooldown_time) {
            continue;
        }
        
        if (cls->usage_rate * 100 <= config->return_threshold &&
            cls->normal_usage_seconds >= 10) {
            
            int return_bw = (int)(cls->borrowed_kbps * config->return_speed);
            return_bw = MAX(return_bw, config->min_borrow_kbps);
            
            if (return_bw < config->min_borrow_kbps) {
                return_bw = cls->borrowed_kbps;
            }
            
            for (int j = 0; j < g_qos_system.upload_class_count; j++) {
                qos_class_t *lender = &g_qos_system.upload_classes[j];
                
                if (lender->borrowed_kbps < 0 &&
                    lender->current_kbps < lender->config_max_kbps) {
                    
                    int actual_return = MIN(return_bw, lender->config_max_kbps - lender->current_kbps);
                    actual_return = MIN(actual_return, cls->borrowed_kbps);
                    
                    if (actual_return >= config->min_borrow_kbps) {
                        int new_cls_bw = cls->current_kbps - actual_return;
                        int new_lender_bw = lender->current_kbps + actual_return;
                        
                        if (adjust_tc_class_bandwidth(g_qos_system.wan_interface,
                                                     cls->classid, new_cls_bw) == 0 &&
                            adjust_tc_class_bandwidth(g_qos_system.wan_interface,
                                                     lender->classid, new_lender_bw) == 0) {
                            
                            cls->current_kbps = new_cls_bw;
                            lender->current_kbps = new_lender_bw;
                            
                            cls->borrowed_kbps -= actual_return;
                            lender->borrowed_kbps += actual_return;
                            
                            cls->last_adjust_time = now;
                            lender->last_adjust_time = now;
                            
                            total_returned += actual_return;
                            
                            DEBUG_LOG("上传归还: 从[%s]归还%d kbps给[%s]", 
                                     cls->name, actual_return, lender->name);
                            
                            if (cls->borrowed_kbps <= 0) {
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
    
    // 处理下载分类（类似逻辑）
    for (int i = 0; i < g_qos_system.download_class_count; i++) {
        qos_class_t *cls = &g_qos_system.download_classes[i];
        
        if (cls->borrowed_kbps <= 0) {
            continue;
        }
        
        if (difftime(now, cls->last_adjust_time) < config->cooldown_time) {
            continue;
        }
        
        if (cls->usage_rate * 100 <= config->return_threshold &&
            cls->normal_usage_seconds >= 10) {
            
            int return_bw = (int)(cls->borrowed_kbps * config->return_speed);
            return_bw = MAX(return_bw, config->min_borrow_kbps);
            
            if (return_bw < config->min_borrow_kbps) {
                return_bw = cls->borrowed_kbps;
            }
            
            for (int j = 0; j < g_qos_system.download_class_count; j++) {
                qos_class_t *lender = &g_qos_system.download_classes[j];
                
                if (lender->borrowed_kbps < 0 &&
                    lender->current_kbps < lender->config_max_kbps) {
                    
                    int actual_return = MIN(return_bw, lender->config_max_kbps - lender->current_kbps);
                    actual_return = MIN(actual_return, cls->borrowed_kbps);
                    
                    if (actual_return >= config->min_borrow_kbps) {
                        int new_cls_bw = cls->current_kbps - actual_return;
                        int new_lender_bw = lender->current_kbps + actual_return;
                        
                        if (adjust_tc_class_bandwidth(g_qos_system.wan_interface,
                                                     cls->classid, new_cls_bw) == 0 &&
                            adjust_tc_class_bandwidth(g_qos_system.wan_interface,
                                                     lender->classid, new_lender_bw) == 0) {
                            
                            cls->current_kbps = new_cls_bw;
                            lender->current_kbps = new_lender_bw;
                            
                            cls->borrowed_kbps -= actual_return;
                            lender->borrowed_kbps += actual_return;
                            
                            cls->last_adjust_time = now;
                            lender->last_adjust_time = now;
                            
                            total_returned += actual_return;
                            
                            DEBUG_LOG("下载归还: 从[%s]归还%d kbps给[%s]", 
                                     cls->name, actual_return, lender->name);
                            
                            if (cls->borrowed_kbps <= 0) {
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
    
    return total_returned;
}