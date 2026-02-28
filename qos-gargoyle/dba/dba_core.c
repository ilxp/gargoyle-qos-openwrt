#include "qos_dba.h"
#include <math.h>
#include <time.h>
#include <stdlib.h>

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

// 调整上传分类
int adjust_upload_classes(void) {
    int adjustments = 0;
    time_t now = time(NULL);
    
    for (int i = 0; i < g_qos_system.upload_class_count; i++) {
        qos_class_t *cls = &g_qos_system.upload_classes[i];
        
        // 检查冷却时间
        if (difftime(now, cls->last_adjust_time) < g_qos_system.config.cooldown_time) {
            continue;
        }
        
        // 检查是否需要调整
        if (cls->high_usage_seconds >= g_qos_system.config.high_usage_duration) {
            // 高使用率，需要借用带宽
            int need_bw = cls->current_kbps * (cls->usage_rate - 0.85f) / 0.15f;
            if (need_bw < g_qos_system.config.min_borrow_kbps) {
                need_bw = g_qos_system.config.min_borrow_kbps;
            }
            
            // 从低优先级分类借用
            int borrowed = 0;
            for (int j = i + 1; j < g_qos_system.upload_class_count && borrowed < need_bw; j++) {
                qos_class_t *donor = &g_qos_system.upload_classes[j];
                
                if (donor->usage_rate * 100 <= g_qos_system.config.low_usage_threshold &&
                    donor->low_usage_seconds >= g_qos_system.config.low_usage_duration) {
                    
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
                        if (adjust_tc_class_bandwidth(g_qos_system.wan_interface, 
                                                     donor->classid, new_donor_bw) == 0) {
                            donor->current_kbps = new_donor_bw;
                            donor->borrowed_kbps -= borrow_amount;
                            borrowed += borrow_amount;
                            
                            int new_cls_bw = cls->current_kbps + borrow_amount;
                            if (new_cls_bw <= cls->config_max_kbps) {
                                if (adjust_tc_class_bandwidth(g_qos_system.wan_interface,
                                                             cls->classid, new_cls_bw) == 0) {
                                    cls->current_kbps = new_cls_bw;
                                    cls->borrowed_kbps += borrow_amount;
                                    cls->last_adjust_time = now;
                                    adjustments++;
                                    
                                    DEBUG_LOG("上传分类 %s 从 %s 借用 %d kbps", 
                                             cls->name, donor->name, borrow_amount);
                                }
                            }
                        }
                    }
                }
            }
            
        } else if (cls->low_usage_seconds >= g_qos_system.config.low_usage_duration) {
            // 低使用率，但需要检查是否借用了带宽
            if (cls->borrowed_kbps > 0) {
                // 尝试归还部分带宽
                int can_return = cls->borrowed_kbps;
                int return_amount = (int)(can_return * g_qos_system.config.return_speed);
                
                if (return_amount >= g_qos_system.config.min_change_kbps) {
                    int new_cls_bw = cls->current_kbps - return_amount;
                    if (new_cls_bw >= cls->config_min_kbps) {
                        if (adjust_tc_class_bandwidth(g_qos_system.wan_interface,
                                                     cls->classid, new_cls_bw) == 0) {
                            cls->current_kbps = new_cls_bw;
                            cls->borrowed_kbps -= return_amount;
                            cls->last_adjust_time = now;
                            adjustments++;
                            
                            DEBUG_LOG("上传分类 %s 归还 %d kbps", cls->name, return_amount);
                        }
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
    
    for (int i = 0; i < g_qos_system.download_class_count; i++) {
        qos_class_t *cls = &g_qos_system.download_classes[i];
        
        // 检查冷却时间
        if (difftime(now, cls->last_adjust_time) < g_qos_system.config.cooldown_time) {
            continue;
        }
        
        // 检查是否需要调整
        if (cls->high_usage_seconds >= g_qos_system.config.high_usage_duration) {
            // 高使用率，需要借用带宽
            int need_bw = cls->current_kbps * (cls->usage_rate - 0.85f) / 0.15f;
            if (need_bw < g_qos_system.config.min_borrow_kbps) {
                need_bw = g_qos_system.config.min_borrow_kbps;
            }
            
            // 从低优先级分类借用
            int borrowed = 0;
            for (int j = i + 1; j < g_qos_system.download_class_count && borrowed < need_bw; j++) {
                qos_class_t *donor = &g_qos_system.download_classes[j];
                
                if (donor->usage_rate * 100 <= g_qos_system.config.low_usage_threshold &&
                    donor->low_usage_seconds >= g_qos_system.config.low_usage_duration) {
                    
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
                        if (adjust_tc_class_bandwidth(g_qos_system.wan_interface, 
                                                     donor->classid, new_donor_bw) == 0) {
                            donor->current_kbps = new_donor_bw;
                            donor->borrowed_kbps -= borrow_amount;
                            borrowed += borrow_amount;
                            
                            int new_cls_bw = cls->current_kbps + borrow_amount;
                            if (new_cls_bw <= cls->config_max_kbps) {
                                if (adjust_tc_class_bandwidth(g_qos_system.wan_interface,
                                                             cls->classid, new_cls_bw) == 0) {
                                    cls->current_kbps = new_cls_bw;
                                    cls->borrowed_kbps += borrow_amount;
                                    cls->last_adjust_time = now;
                                    adjustments++;
                                    
                                    DEBUG_LOG("下载分类 %s 从 %s 借用 %d kbps", 
                                             cls->name, donor->name, borrow_amount);
                                }
                            }
                        }
                    }
                }
            }
            
        } else if (cls->low_usage_seconds >= g_qos_system.config.low_usage_duration) {
            // 低使用率，但需要检查是否借用了带宽
            if (cls->borrowed_kbps > 0) {
                // 尝试归还部分带宽
                int can_return = cls->borrowed_kbps;
                int return_amount = (int)(can_return * g_qos_system.config.return_speed);
                
                if (return_amount >= g_qos_system.config.min_change_kbps) {
                    int new_cls_bw = cls->current_kbps - return_amount;
                    if (new_cls_bw >= cls->config_min_kbps) {
                        if (adjust_tc_class_bandwidth(g_qos_system.wan_interface,
                                                     cls->classid, new_cls_bw) == 0) {
                            cls->current_kbps = new_cls_bw;
                            cls->borrowed_kbps -= return_amount;
                            cls->last_adjust_time = now;
                            adjustments++;
                            
                            DEBUG_LOG("下载分类 %s 归还 %d kbps", cls->name, return_amount);
                        }
                    }
                }
            }
        }
    }
    
    return adjustments;
}

// 监控所有分类
void monitor_all_classes(void) {
    time_t now = time(NULL);
    static time_t last_check = 0;
    
    if (difftime(now, last_check) < 1.0) {
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
            cls->usage_rate * 100 <= g_qos_system.config.return_threshold &&
            cls->low_usage_seconds >= g_qos_system.config.low_usage_duration &&
            difftime(now, cls->last_adjust_time) >= g_qos_system.config.cooldown_time) {
            
            int return_amount = (int)(cls->borrowed_kbps * g_qos_system.config.return_speed);
            if (return_amount < g_qos_system.config.min_change_kbps) {
                return_amount = cls->borrowed_kbps;
            }
            
            int new_bw = cls->current_kbps - return_amount;
            if (new_bw >= cls->config_min_kbps) {
                if (adjust_tc_class_bandwidth(g_qos_system.wan_interface, 
                                             cls->classid, new_bw) == 0) {
                    cls->current_kbps = new_bw;
                    cls->borrowed_kbps -= return_amount;
                    cls->last_adjust_time = now;
                    returned += return_amount;
                    
                    DEBUG_LOG("上传分类 %s 自动归还 %d kbps", cls->name, return_amount);
                }
            }
        }
    }
    
    // 检查下载分类
    for (int i = 0; i < g_qos_system.download_class_count; i++) {
        qos_class_t *cls = &g_qos_system.download_classes[i];
        
        if (cls->borrowed_kbps > 0 && 
            cls->usage_rate * 100 <= g_qos_system.config.return_threshold &&
            cls->low_usage_seconds >= g_qos_system.config.low_usage_duration &&
            difftime(now, cls->last_adjust_time) >= g_qos_system.config.cooldown_time) {
            
            int return_amount = (int)(cls->borrowed_kbps * g_qos_system.config.return_speed);
            if (return_amount < g_qos_system.config.min_change_kbps) {
                return_amount = cls->borrowed_kbps;
            }
            
            int new_bw = cls->current_kbps - return_amount;
            if (new_bw >= cls->config_min_kbps) {
                if (adjust_tc_class_bandwidth(g_qos_system.wan_interface, 
                                             cls->classid, new_bw) == 0) {
                    cls->current_kbps = new_bw;
                    cls->borrowed_kbps -= return_amount;
                    cls->last_adjust_time = now;
                    returned += return_amount;
                    
                    DEBUG_LOG("下载分类 %s 自动归还 %d kbps", cls->name, return_amount);
                }
            }
        }
    }
    
    return returned;
}