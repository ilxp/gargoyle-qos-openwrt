/*
 * monitor.c - 监控系统模块 (优化修复版)
 * 实现epoll异步监控、系统资源监控、健康检查
 * 版本: 2.1.1
 * 修复: 添加对优化参数的监控
 */

#include "qosdba.h"
#include <sys/epoll.h>
#include <sys/inotify.h>
#include <sys/sysinfo.h>
#include <sys/resource.h>
#include <dirent.h>
#include <unistd.h>
#include <fcntl.h>

/* ==================== 常量定义 ==================== */

#define MAX_UTILIZATION_HISTORY 300  /* 5分钟历史数据（每秒1个点） */
#define UTILIZATION_WARNING_THRESHOLD 85  /* 使用率警告阈值 */
#define UTILIZATION_CRITICAL_THRESHOLD 95 /* 使用率严重阈值 */

/* ==================== 数据结构 ==================== */

/* 使用率监控器 */
typedef struct {
    float utilization_history[MAX_UTILIZATION_HISTORY];
    int64_t history_timestamps[MAX_UTILIZATION_HISTORY];
    int history_index;
    int history_count;
    float peak_utilization_1min;
    float peak_utilization_5min;
    float avg_utilization_1min;
    float avg_utilization_5min;
    int high_util_alerts;
    int low_util_alerts;
    int64_t last_alert_time;
} utilization_monitor_t;

/* ==================== 异步监控（epoll/inotify） ==================== */

qosdba_result_t init_async_monitor(device_context_t* dev_ctx) {
    if (!dev_ctx) return QOSDBA_ERR_MEMORY;
    
    /* 创建epoll实例 */
    dev_ctx->async_monitor.epoll_fd = epoll_create1(0);
    if (dev_ctx->async_monitor.epoll_fd < 0) {
        return QOSDBA_ERR_SYSTEM;
    }
    
    /* 创建inotify实例（非阻塞模式） */
    dev_ctx->async_monitor.inotify_fd = inotify_init1(IN_NONBLOCK);
    if (dev_ctx->async_monitor.inotify_fd < 0) {
        close(dev_ctx->async_monitor.epoll_fd);
        return QOSDBA_ERR_SYSTEM;
    }
    
    dev_ctx->async_monitor.async_enabled = 1;
    dev_ctx->async_monitor.last_async_check = get_current_time_ms();
    
    /* 设置配置文件监控 */
    return setup_async_monitoring(dev_ctx);
}

static qosdba_result_t setup_async_monitoring(device_context_t* dev_ctx) {
    if (!dev_ctx || !dev_ctx->owner_ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    /* 添加inotify_fd到epoll */
    struct epoll_event ev;
    ev.events = EPOLLIN;
    ev.data.fd = dev_ctx->async_monitor.inotify_fd;
    
    if (epoll_ctl(dev_ctx->async_monitor.epoll_fd, EPOLL_CTL_ADD, 
                  dev_ctx->async_monitor.inotify_fd, &ev) < 0) {
        return QOSDBA_ERR_SYSTEM;
    }
    
    /* 添加配置文件监控 */
    if (dev_ctx->owner_ctx->config_path[0] != '\0') {
        dev_ctx->async_monitor.watch_fd = inotify_add_watch(
            dev_ctx->async_monitor.inotify_fd, 
            dev_ctx->owner_ctx->config_path, 
            IN_MODIFY | IN_DELETE_SELF | IN_MOVE_SELF);
        
        if (dev_ctx->async_monitor.watch_fd < 0) {
            log_device_message(dev_ctx, "WARN", 
                "无法添加配置文件监控: %s\n", dev_ctx->owner_ctx->config_path);
        } else {
            log_device_message(dev_ctx, "DEBUG", 
                "配置文件监控已启用: %s\n", dev_ctx->owner_ctx->config_path);
        }
    }
    
    return QOSDBA_OK;
}

int check_async_events(device_context_t* dev_ctx) {
    if (!dev_ctx || !dev_ctx->async_monitor.async_enabled) {
        return 0;
    }
    
    int64_t now = get_current_time_ms();
    if (now - dev_ctx->async_monitor.last_async_check < 1000) {
        return 0;
    }
    
    dev_ctx->async_monitor.last_async_check = now;
    
    struct epoll_event events[10];
    int nfds = epoll_wait(dev_ctx->async_monitor.epoll_fd, events, 10, 0);
    if (nfds < 0) {
        if (errno != EINTR) {
            log_device_message(dev_ctx, "ERROR", "epoll_wait失败: %s\n", strerror(errno));
        }
        return 0;
    }
    
    int event_count = 0;
    
    for (int i = 0; i < nfds; i++) {
        if (events[i].events & EPOLLIN) {
            if (events[i].data.fd == dev_ctx->async_monitor.inotify_fd) {
                char buffer[4096];
                int length = read(dev_ctx->async_monitor.inotify_fd, buffer, sizeof(buffer));
                if (length > 0) {
                    event_count++;
                    
                    int offset = 0;
                    while (offset < length) {
                        struct inotify_event* event = (struct inotify_event*)&buffer[offset];
                        
                        if (event->mask & (IN_MODIFY | IN_DELETE_SELF | IN_MOVE_SELF)) {
                            log_device_message(dev_ctx, "INFO", 
                                "检测到配置文件变化，触发重载\n");
                            if (dev_ctx->owner_ctx) {
                                dev_ctx->owner_ctx->reload_config = 1;
                            }
                        }
                        
                        offset += sizeof(struct inotify_event) + event->len;
                    }
                }
            }
        }
    }
    
    return event_count;
}

/* ==================== 配置文件监控 ==================== */
qosdba_result_t setup_async_monitoring(device_context_t* dev_ctx) {
    if (!dev_ctx || !dev_ctx->owner_ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    /* 添加配置文件监控 */
    if (dev_ctx->owner_ctx->config_path[0] != '\0') {
        dev_ctx->async_monitor.watch_fd = inotify_add_watch(
            dev_ctx->async_monitor.inotify_fd, 
            dev_ctx->owner_ctx->config_path, 
            IN_MODIFY | IN_DELETE_SELF | IN_MOVE_SELF);
        
        if (dev_ctx->async_monitor.watch_fd < 0) {
            return QOSDBA_ERR_SYSTEM;
        }
    }
    
    return QOSDBA_OK;
}

/* ==================== 连续使用率监控 ==================== */

/* 初始化连续使用率监控 */
static qosdba_result_t init_utilization_monitor(device_context_t* dev_ctx) {
    if (!dev_ctx) return QOSDBA_ERR_MEMORY;
    
    /* 分配使用率监控数组 */
    if (dev_ctx->num_classes > 0) {
        dev_ctx->util_monitors = calloc(dev_ctx->num_classes, 
                                       sizeof(utilization_monitor_t));
        if (!dev_ctx->util_monitors) {
            return QOSDBA_ERR_MEMORY;
        }
        
        /* 初始化所有监控器 */
        for (int i = 0; i < dev_ctx->num_classes; i++) {
            utilization_monitor_t* monitor = &dev_ctx->util_monitors[i];
            memset(monitor, 0, sizeof(utilization_monitor_t));
        }
    }
    
    return QOSDBA_OK;
}

/* 更新使用率监控 */
static void update_utilization_monitor(utilization_monitor_t* monitor, 
                                      float utilization, 
                                      int64_t timestamp) {
    if (!monitor) return;
    
    /* 添加到历史记录 */
    monitor->utilization_history[monitor->history_index] = utilization;
    monitor->history_timestamps[monitor->history_index] = timestamp;
    
    /* 更新索引 */
    monitor->history_index = (monitor->history_index + 1) % MAX_UTILIZATION_HISTORY;
    if (monitor->history_count < MAX_UTILIZATION_HISTORY) {
        monitor->history_count++;
    }
    
    /* 重新计算统计信息 */
    calculate_utilization_statistics(monitor, timestamp);
}

/* 计算使用率统计信息 */
static void calculate_utilization_statistics(utilization_monitor_t* monitor, 
                                            int64_t current_time) {
    if (!monitor || monitor->history_count == 0) return;
    
    float sum_1min = 0.0f;
    float sum_5min = 0.0f;
    int count_1min = 0;
    int count_5min = 0;
    float max_1min = 0.0f;
    float max_5min = 0.0f;
    
    int64_t one_minute_ago = current_time - 60000;  /* 1分钟前 */
    int64_t five_minutes_ago = current_time - 300000; /* 5分钟前 */
    
    /* 遍历历史记录 */
    for (int i = 0; i < monitor->history_count; i++) {
        int idx = (monitor->history_index - i - 1 + MAX_UTILIZATION_HISTORY) % 
                  MAX_UTILIZATION_HISTORY;
        
        int64_t sample_time = monitor->history_timestamps[idx];
        float sample_value = monitor->utilization_history[idx];
        
        /* 5分钟数据 */
        if (sample_time >= five_minutes_ago) {
            sum_5min += sample_value;
            count_5min++;
            if (sample_value > max_5min) {
                max_5min = sample_value;
            }
            
            /* 1分钟数据 */
            if (sample_time >= one_minute_ago) {
                sum_1min += sample_value;
                count_1min++;
                if (sample_value > max_1min) {
                    max_1min = sample_value;
                }
            }
        } else {
            break;  /* 样本按时间顺序存储，可以提前退出 */
        }
    }
    
    /* 更新统计 */
    if (count_1min > 0) {
        monitor->avg_utilization_1min = sum_1min / count_1min;
        monitor->peak_utilization_1min = max_1min;
    }
    
    if (count_5min > 0) {
        monitor->avg_utilization_5min = sum_5min / count_5min;
        monitor->peak_utilization_5min = max_5min;
    }
}

/* 检查连续高使用率 */
static int check_continuous_high_utilization(utilization_monitor_t* monitor, 
                                           int64_t current_time,
                                           int threshold, 
                                           int continuous_seconds) {
    if (!monitor || monitor->history_count < continuous_seconds) {
        return 0;
    }
    
    int continuous_count = 0;
    int64_t window_end = current_time;
    int64_t window_start = current_time - (continuous_seconds * 1000);
    
    /* 检查最近continuous_seconds秒内的样本 */
    for (int i = 0; i < monitor->history_count; i++) {
        int idx = (monitor->history_index - i - 1 + MAX_UTILIZATION_HISTORY) % 
                  MAX_UTILIZATION_HISTORY;
        
        int64_t sample_time = monitor->history_timestamps[idx];
        
        /* 只检查指定时间窗口内的样本 */
        if (sample_time < window_start || sample_time > window_end) {
            continue;
        }
        
        float sample_value = monitor->utilization_history[idx] * 100;  /* 转换为百分比 */
        
        if (sample_value >= threshold) {
            continuous_count++;
        } else {
            continuous_count = 0;  /* 不连续，重置计数 */
        }
    }
    
    return (continuous_count >= continuous_seconds);
}

/* 检查连续低使用率 */
static int check_continuous_low_utilization(utilization_monitor_t* monitor, 
                                          int64_t current_time,
                                          int threshold, 
                                          int continuous_seconds) {
    if (!monitor || monitor->history_count < continuous_seconds) {
        return 0;
    }
    
    int continuous_count = 0;
    int64_t window_end = current_time;
    int64_t window_start = current_time - (continuous_seconds * 1000);
    
    /* 检查最近continuous_seconds秒内的样本 */
    for (int i = 0; i < monitor->history_count; i++) {
        int idx = (monitor->history_index - i - 1 + MAX_UTILIZATION_HISTORY) % 
                  MAX_UTILIZATION_HISTORY;
        
        int64_t sample_time = monitor->history_timestamps[idx];
        
        /* 只检查指定时间窗口内的样本 */
        if (sample_time < window_start || sample_time > window_end) {
            continue;
        }
        
        float sample_value = monitor->utilization_history[idx] * 100;  /* 转换为百分比 */
        
        if (sample_value <= threshold) {
            continuous_count++;
        } else {
            continuous_count = 0;  /* 不连续，重置计数 */
        }
    }
    
    return (continuous_count >= continuous_seconds);
}

/* 连续使用率监控主函数 */
qosdba_result_t monitor_continuous_utilization(device_context_t* dev_ctx) {
    if (!dev_ctx || dev_ctx->num_classes == 0) {
        return QOSDBA_ERR_MEMORY;
    }
    
    int64_t now = get_current_time_ms();
    
    /* 初始化监控器（如果需要） */
    if (!dev_ctx->util_monitors) {
        qosdba_result_t ret = init_utilization_monitor(dev_ctx);
        if (ret != QOSDBA_OK) {
            return ret;
        }
    }
    
    /* 更新每个分类的监控数据 */
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_state_t* state = &dev_ctx->states[i];
        utilization_monitor_t* monitor = &dev_ctx->util_monitors[i];
        
        if (!state->dba_enabled) {
            continue;
        }
        
        /* 更新监控器 */
        update_utilization_monitor(monitor, state->utilization, now);
        
        /* 检查连续高使用率 */
        int continuous_high = check_continuous_high_utilization(
            monitor, now, 
            dev_ctx->borrow_trigger_threshold, 
            dev_ctx->continuous_seconds);
        
        /* 检查连续低使用率 */
        int continuous_low = check_continuous_low_utilization(
            monitor, now, 
            dev_ctx->lend_trigger_threshold, 
            dev_ctx->continuous_seconds);
        
        /* 记录状态 */
        state->continuous_high = continuous_high;
        state->continuous_low = continuous_low;
        
        /* 触发借用决策（如果满足条件） */
        if (continuous_high && state->cooldown_timer == 0) {
            state->borrow_qualified = 1;
        } else {
            state->borrow_qualified = 0;
        }
        
        /* 触发借出决策（如果满足条件） */
        if (continuous_low && state->cooldown_timer == 0) {
            state->lend_qualified = 1;
        } else {
            state->lend_qualified = 0;
        }
        
        /* 生成告警（如果使用率过高） */
        if (state->utilization * 100 >= UTILIZATION_CRITICAL_THRESHOLD) {
            if (now - monitor->last_alert_time >= 60000) {  /* 每分钟最多一次告警 */
                log_device_message(dev_ctx, "WARN", 
                    "分类 0x%x 使用率严重过高: %.1f%%\n", 
                    state->classid, state->utilization * 100);
                monitor->high_util_alerts++;
                monitor->last_alert_time = now;
            }
        } else if (state->utilization * 100 <= 5.0f) {  /* 使用率过低 */
            if (now - monitor->last_alert_time >= 60000) {
                log_device_message(dev_ctx, "INFO", 
                    "分类 0x%x 使用率过低: %.1f%%\n", 
                    state->classid, state->utilization * 100);
                monitor->low_util_alerts++;
                monitor->last_alert_time = now;
            }
        }
    }
    
    return QOSDBA_OK;
}

/* 获取分类的使用率统计 */
qosdba_result_t get_class_utilization_stats(device_context_t* dev_ctx, 
                                           int class_idx,
                                           float* avg_1min, 
                                           float* peak_1min,
                                           float* avg_5min, 
                                           float* peak_5min) {
    if (!dev_ctx || class_idx < 0 || class_idx >= dev_ctx->num_classes) {
        return QOSDBA_ERR_INVALID;
    }
    
    utilization_monitor_t* monitor = &dev_ctx->util_monitors[class_idx];
    
    if (avg_1min) *avg_1min = monitor->avg_utilization_1min;
    if (peak_1min) *peak_1min = monitor->peak_utilization_1min;
    if (avg_5min) *avg_5min = monitor->avg_utilization_5min;
    if (peak_5min) *peak_5min = monitor->peak_utilization_5min;
    
    return QOSDBA_OK;
}

/* ==================== 系统资源监控 ==================== */

qosdba_result_t check_system_resources(device_context_t* dev_ctx) {
    if (!dev_ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    int64_t now = get_current_time_ms();
    dev_ctx->system_monitor.last_check_time = now;
    
    /* 获取内存使用情况 */
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        dev_ctx->system_monitor.memory_usage_mb = usage.ru_maxrss / 1024;
        if (dev_ctx->system_monitor.memory_usage_mb > 100) {
            log_device_message(dev_ctx, "WARN", 
                "内存使用较高: %lldMB\n", dev_ctx->system_monitor.memory_usage_mb);
        }
    }
    
    /* 获取CPU使用率 */
    struct sysinfo info;
    if (sysinfo(&info) == 0) {
        long load = info.loads[0] / (1 << 16);
        dev_ctx->system_monitor.cpu_usage_percent = (float)load * 100.0f / info.procs;
        if (dev_ctx->system_monitor.cpu_usage_percent > 90.0f) {
            log_device_message(dev_ctx, "WARN", 
                "CPU使用率较高: %.1f%%\n", dev_ctx->system_monitor.cpu_usage_percent);
        }
    }
    
    /* 获取文件描述符使用情况 */
    DIR* dir = opendir("/proc/self/fd");
    if (dir) {
        int fd_count = 0;
        struct dirent* entry;
        while ((entry = readdir(dir)) != NULL) {
            if (entry->d_type == DT_LNK) {
                fd_count++;
            }
        }
        closedir(dir);
        
        dev_ctx->system_monitor.file_descriptors_used = fd_count;
        if (fd_count > 800) {
            log_device_message(dev_ctx, "WARN", 
                "文件描述符使用较多: %d\n", fd_count);
        }
    }
    
    /* 记录系统调用次数（简化版本） */
    dev_ctx->system_monitor.system_calls_per_sec++;
    
    return QOSDBA_OK;
}

/* ==================== 优化参数监控 ==================== */

/* 监控优化参数的使用情况 */
qosdba_result_t monitor_optimization_parameters(device_context_t* dev_ctx) {
    if (!dev_ctx) return QOSDBA_ERR_MEMORY;
    
    int64_t now = get_current_time_ms();
    
    /* 初始化监控统计（如果需要） */
    if (dev_ctx->num_classes > 0 && !dev_ctx->param_monitors) {
        dev_ctx->param_monitors = calloc(dev_ctx->num_classes, 
                                        sizeof(param_monitor_t));
        if (!dev_ctx->param_monitors) {
            return QOSDBA_ERR_MEMORY;
        }
    }
    
    /* 监控每个分类的优化参数 */
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_state_t* state = &dev_ctx->states[i];
        
        if (!state->dba_enabled) {
            continue;
        }
        
        /* 计算优化参数指标 */
        calculate_optimization_metrics(dev_ctx, i, now);
        
        /* 监控借用触发条件 */
        if (state->utilization * 100 >= dev_ctx->borrow_trigger_threshold) {
            dev_ctx->param_monitors[i].borrow_threshold_hits++;
        }
        
        /* 监控借出触发条件 */
        if (state->utilization * 100 <= dev_ctx->lend_trigger_threshold) {
            dev_ctx->param_monitors[i].lend_threshold_hits++;
        }
        
        /* 监控连续时间条件 */
        if (state->continuous_high_count >= dev_ctx->continuous_seconds) {
            dev_ctx->param_monitors[i].continuous_high_events++;
        }
        
        if (state->continuous_low_count >= dev_ctx->continuous_seconds) {
            dev_ctx->param_monitors[i].continuous_low_events++;
        }
    }
    
    return QOSDBA_OK;
}

/* 计算优化指标 */
static void calculate_optimization_metrics(device_context_t* dev_ctx, 
                                          int class_idx, 
                                          int64_t now) {
    if (!dev_ctx || class_idx < 0) return;
    
    /* 计算借用效率 */
    class_state_t* state = &dev_ctx->states[class_idx];
    param_monitor_t* monitor = &dev_ctx->param_monitors[class_idx];
    
    /* 借用成功率统计 */
    if (monitor->borrow_attempts > 0) {
        monitor->borrow_success_rate = 
            (float)monitor->borrow_successes * 100 / monitor->borrow_attempts;
    }
    
    /* 归还成功率统计 */
    if (monitor->return_attempts > 0) {
        monitor->return_success_rate = 
            (float)monitor->return_successes * 100 / monitor->return_attempts;
    }
    
    /* 平均借用量统计 */
    if (monitor->borrow_successes > 0) {
        monitor->avg_borrow_amount = 
            (float)monitor->total_borrowed_kbps / monitor->borrow_successes;
    }
    
    /* 平均借用时间 */
    if (monitor->borrow_successes > 0 && monitor->total_borrow_duration > 0) {
        monitor->avg_borrow_duration = 
            monitor->total_borrow_duration / monitor->borrow_successes;
    }
    
    /* 记录最后更新时间 */
    monitor->last_update_time = now;
}

/* 记录借用事件 */
void record_borrow_event(device_context_t* dev_ctx, 
                         int borrower_idx, 
                         int lender_idx, 
                         int amount_kbps, 
                         int success) {
    if (!dev_ctx || borrower_idx < 0 || lender_idx < 0) return;
    
    param_monitor_t* borrower_mon = &dev_ctx->param_monitors[borrower_idx];
    param_monitor_t* lender_mon = &dev_ctx->param_monitors[lender_idx];
    
    borrower_mon->borrow_attempts++;
    lender_mon->lend_attempts++;
    
    if (success) {
        borrower_mon->borrow_successes++;
        lender_mon->lend_successes++;
        
        borrower_mon->total_borrowed_kbps += amount_kbps;
        lender_mon->total_lent_kbps += amount_kbps;
        
        int64_t now = get_current_time_ms();
        borrow_record_t* record = &dev_ctx->records[dev_ctx->num_records];
        if (dev_ctx->num_records < MAX_BORROW_RECORDS) {
            record->start_time = now;
            dev_ctx->num_records++;
        }
    } else {
        borrower_mon->borrow_failures++;
        lender_mon->lend_failures++;
    }
}

/* 记录归还事件 */
void record_return_event(device_context_t* dev_ctx, 
                         int borrower_idx, 
                         int lender_idx, 
                         int amount_kbps, 
                         int success) {
    if (!dev_ctx || borrower_idx < 0 || lender_idx < 0) return;
    
    param_monitor_t* borrower_mon = &dev_ctx->param_monitors[borrower_idx];
    param_monitor_t* lender_mon = &dev_ctx->param_monitors[lender_idx];
    
    borrower_mon->return_attempts++;
    lender_mon->receive_return_attempts++;
    
    if (success) {
        borrower_mon->return_successes++;
        lender_mon->receive_return_successes++;
        
        borrower_mon->total_returned_kbps += amount_kbps;
        lender_mon->total_received_kbps += amount_kbps;
        
        int64_t now = get_current_time_ms();
        int64_t borrow_duration = 0;
        
        /* 查找对应的借用记录 */
        for (int i = 0; i < dev_ctx->num_records; i++) {
            borrow_record_t* record = &dev_ctx->records[i];
            if (record->from_classid == dev_ctx->states[lender_idx].classid &&
                record->to_classid == dev_ctx->states[borrower_idx].classid &&
                !record->returned) {
                borrow_duration = now - record->start_time;
                break;
            }
        }
        
        borrower_mon->total_borrow_duration += borrow_duration;
    } else {
        borrower_mon->return_failures++;
        lender_mon->receive_return_failures++;
    }
}

/* ==================== 健康检查 ==================== */

qosdba_result_t qosdba_health_check(qosdba_context_t* ctx) {
    if (!ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    int healthy_devices = 0;
    
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        if (!dev_ctx->enabled) {
            continue;
        }
        
        int ifindex = get_ifindex(dev_ctx);
        if (ifindex <= 0) {
            log_device_message(dev_ctx, "ERROR", "健康检查失败: 设备接口不可用\n");
            continue;
        }
        
        struct rtnl_qdisc* qdisc = rtnl_qdisc_alloc();
        if (!qdisc) {
            log_device_message(dev_ctx, "ERROR", "健康检查失败: 内存分配失败\n");
            continue;
        }
        
        rtnl_tc_set_ifindex(TC_CAST(qdisc), ifindex);
        rtnl_tc_set_parent(TC_CAST(qdisc), TC_H_ROOT);
        
        int ret = rtnl_qdisc_get(&dev_ctx->rth, qdisc);
        if (ret < 0) {
            log_device_message(dev_ctx, "ERROR", "健康检查失败: 无法获取qdisc信息\n");
            rtnl_qdisc_put(qdisc);
            continue;
        }
        
        const char* kind = rtnl_tc_get_kind(TC_CAST(qdisc));
        if (!kind || strcmp(kind, "htb") != 0) {
            log_device_message(dev_ctx, "ERROR", 
                "健康检查失败: 检测到非HTB算法: %s\n", kind ? kind : "未知");
            rtnl_qdisc_put(qdisc);
            continue;
        }
        
        rtnl_qdisc_put(qdisc);
        healthy_devices++;
        
        log_device_message(dev_ctx, "DEBUG", "健康检查通过\n");
    }
    
    if (healthy_devices == 0) {
        return QOSDBA_ERR_SANITY;
    }
    
    return QOSDBA_OK;
}

/* ==================== 性能统计 ==================== */

void update_perf_stats(device_context_t* dev_ctx, const char* operation, 
                      int64_t start_time, int64_t end_time, int success) {
    if (!dev_ctx) return;
    
    int64_t execution_time = end_time - start_time;
    
    if (strcmp(operation, "nl_operation") == 0) {
        dev_ctx->perf_stats.total_nl_operations++;
        dev_ctx->perf_stats.total_nl_time_ms += execution_time;
        if (execution_time > dev_ctx->perf_stats.max_nl_time_ms) {
            dev_ctx->perf_stats.max_nl_time_ms = execution_time;
        }
        if (!success) {
            dev_ctx->perf_stats.nl_errors++;
        }
    } else if (strcmp(operation, "borrow") == 0) {
        if (success) {
            dev_ctx->perf_stats.successful_borrows++;
        } else {
            dev_ctx->perf_stats.failed_borrows++;
        }
    } else if (strcmp(operation, "return") == 0) {
        if (success) {
            dev_ctx->perf_stats.successful_returns++;
        } else {
            dev_ctx->perf_stats.failed_returns++;
        }
    } else if (strcmp(operation, "retry") == 0) {
        dev_ctx->perf_stats.retry_attempts++;
        if (success) {
            dev_ctx->perf_stats.retry_success++;
        } else {
            dev_ctx->perf_stats.retry_failures++;
        }
    } else if (strcmp(operation, "cache") == 0) {
        if (success) {
            dev_ctx->perf_stats.cache_hits++;
        } else {
            dev_ctx->perf_stats.cache_misses++;
        }
    } else if (strcmp(operation, "batch") == 0) {
        dev_ctx->perf_stats.batch_executions++;
    } else if (strcmp(operation, "monitor") == 0) {
        dev_ctx->perf_stats.monitor_operations++;
        dev_ctx->perf_stats.total_monitor_time_ms += execution_time;
    }
}

void print_perf_stats(device_context_t* dev_ctx, FILE* out) {
    if (!dev_ctx || !out) return;
    
    fprintf(out, "\n性能统计 (设备: %s):\n", dev_ctx->device);
    fprintf(out, "========================================\n");
    
    /* NL操作统计 */
    if (dev_ctx->perf_stats.total_nl_operations > 0) {
        float avg_nl_time = (float)dev_ctx->perf_stats.total_nl_time_ms / 
                           dev_ctx->perf_stats.total_nl_operations;
        fprintf(out, "NL操作: 总数=%lld, 成功=%lld, 错误=%lld\n",
                dev_ctx->perf_stats.total_nl_operations,
                dev_ctx->perf_stats.total_nl_operations - dev_ctx->perf_stats.nl_errors,
                dev_ctx->perf_stats.nl_errors);
        fprintf(out, "NL时间: 总耗时=%lldms, 平均=%.2fms, 最大=%lldms\n",
                dev_ctx->perf_stats.total_nl_time_ms,
                avg_nl_time,
                dev_ctx->perf_stats.max_nl_time_ms);
    }
    
    /* 缓存统计 */
    int64_t total_cache_access = dev_ctx->perf_stats.cache_hits + 
                                dev_ctx->perf_stats.cache_misses;
    if (total_cache_access > 0) {
        float hit_rate = (float)dev_ctx->perf_stats.cache_hits * 100 / total_cache_access;
        fprintf(out, "缓存: 命中=%lld, 未命中=%lld, 命中率=%.1f%%\n",
                dev_ctx->perf_stats.cache_hits,
                dev_ctx->perf_stats.cache_misses,
                hit_rate);
    }
    
    /* 批量操作统计 */
    if (dev_ctx->perf_stats.batch_executions > 0) {
        fprintf(out, "批量执行: 次数=%lld, 命令总数=%lld\n",
                dev_ctx->perf_stats.batch_executions,
                dev_ctx->perf_stats.total_batch_commands);
    }
    
    /* 借用统计 */
    fprintf(out, "带宽借用: 成功=%lld, 失败=%lld\n",
            dev_ctx->perf_stats.successful_borrows,
            dev_ctx->perf_stats.failed_borrows);
    fprintf(out, "带宽归还: 成功=%lld, 失败=%lld\n",
            dev_ctx->perf_stats.successful_returns,
            dev_ctx->perf_stats.failed_returns);
    
    /* 重试统计 */
    if (dev_ctx->perf_stats.retry_attempts > 0) {
        float retry_success_rate = (float)dev_ctx->perf_stats.retry_success * 100 / 
                                   dev_ctx->perf_stats.retry_attempts;
        fprintf(out, "重试: 尝试=%lld, 成功=%lld, 成功率=%.1f%%\n",
                dev_ctx->perf_stats.retry_attempts,
                dev_ctx->perf_stats.retry_success,
                retry_success_rate);
    }
    
    /* 监控统计 */
    if (dev_ctx->perf_stats.monitor_operations > 0) {
        float avg_monitor_time = (float)dev_ctx->perf_stats.total_monitor_time_ms / 
                                dev_ctx->perf_stats.monitor_operations;
        fprintf(out, "监控操作: 次数=%lld, 平均时间=%.2fms\n",
                dev_ctx->perf_stats.monitor_operations,
                avg_monitor_time);
    }
    
    /* 系统资源 */
    fprintf(out, "系统资源: 内存=%lldMB, CPU=%.1f%%, 文件描述符=%d\n",
            dev_ctx->system_monitor.memory_usage_mb,
            dev_ctx->system_monitor.cpu_usage_percent,
            dev_ctx->system_monitor.file_descriptors_used);
    
    /* 借用事件统计 */
    fprintf(out, "借用事件: 总数=%d, 总借用带宽=%lldkbps, 总归还带宽=%lldkbps\n",
            dev_ctx->total_borrow_events,
            dev_ctx->total_borrowed_kbps,
            dev_ctx->total_returned_kbps);
    
    fprintf(out, "========================================\n");
}

/* ==================== 状态输出 ==================== */

qosdba_result_t qosdba_update_status(qosdba_context_t* ctx, const char* status_file) {
    if (!ctx || !status_file) {
        return QOSDBA_ERR_MEMORY;
    }
    
    FILE* fp = fopen(status_file, "w");
    if (!fp) {
        return QOSDBA_ERR_FILE;
    }
    
    fprintf(fp, "QoS DBA Status Report\n");
    fprintf(fp, "======================\n");
    fprintf(fp, "Version: %s\n", QOSDBA_VERSION);
    fprintf(fp, "Running: %s\n", atomic_load(&ctx->should_exit) ? "No" : "Yes");
    fprintf(fp, "Devices: %d\n", ctx->num_devices);
    fprintf(fp, "Check Interval: %d seconds\n", ctx->check_interval);
    fprintf(fp, "Safe Mode: %s\n", ctx->safe_mode ? "Yes" : "No");
    fprintf(fp, "Debug Mode: %s\n", ctx->debug_mode ? "Yes" : "No");
    fprintf(fp, "Config File: %s\n", ctx->config_path);
    fprintf(fp, "\n");
    
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        fprintf(fp, "Device: %s\n", dev_ctx->device);
        fprintf(fp, "  Enabled: %s\n", dev_ctx->enabled ? "Yes" : "No");
        fprintf(fp, "  Algorithm: %s\n", dev_ctx->qdisc_kind);
        fprintf(fp, "  Total Bandwidth: %d kbps\n", dev_ctx->total_bandwidth_kbps);
        fprintf(fp, "  Classes: %d\n", dev_ctx->num_classes);
        fprintf(fp, "\n");
        
        /* 优化参数配置 */
        fprintf(fp, "  Optimization Parameters:\n");
        fprintf(fp, "    Borrow Trigger: %d%%\n", dev_ctx->borrow_trigger_threshold);
        fprintf(fp, "    Lend Trigger: %d%%\n", dev_ctx->lend_trigger_threshold);
        fprintf(fp, "    Continuous Seconds: %d\n", dev_ctx->continuous_seconds);
        fprintf(fp, "    Max Borrow Sources: %d\n", dev_ctx->max_borrow_sources);
        fprintf(fp, "    Load Balance Mode: %s\n", 
               dev_ctx->load_balance_mode ? "Distributed" : "Centralized");
        fprintf(fp, "    Starvation Warning: %d%%\n", dev_ctx->starvation_warning);
        fprintf(fp, "    Starvation Critical: %d%%\n", dev_ctx->starvation_critical);
        fprintf(fp, "\n");
        
        for (int j = 0; j < dev_ctx->num_classes; j++) {
            class_config_t* config = &dev_ctx->configs[j];
            class_state_t* state = &dev_ctx->states[j];
            
            fprintf(fp, "  Class: 0x%x (%s)\n", config->classid, config->name);
            fprintf(fp, "    Priority: %d\n", config->priority);
            fprintf(fp, "    Config BW: %d-%d kbps\n", 
                   config->min_bw_kbps, config->max_bw_kbps);
            fprintf(fp, "    Current BW: %d kbps\n", state->current_bw_kbps);
            fprintf(fp, "    Used BW: %d kbps\n", state->used_bw_kbps);
            fprintf(fp, "    Utilization: %.1f%%\n", state->utilization * 100);
            fprintf(fp, "    DBA Enabled: %s\n", state->dba_enabled ? "Yes" : "No");
            fprintf(fp, "    Borrowed: %d kbps\n", state->borrowed_bw_kbps);
            fprintf(fp, "    Lent: %d kbps\n", state->lent_bw_kbps);
            fprintf(fp, "    Cooldown Timer: %d\n", state->cooldown_timer);
            fprintf(fp, "    Continuous High: %s\n", 
                   state->continuous_high ? "Yes" : "No");
            fprintf(fp, "    Continuous Low: %s\n", 
                   state->continuous_low ? "Yes" : "No");
            fprintf(fp, "\n");
        }
        
        fprintf(fp, "  Borrow Records: %d\n", dev_ctx->num_records);
        for (int j = 0; j < dev_ctx->num_records; j++) {
            borrow_record_t* record = &dev_ctx->records[j];
            fprintf(fp, "    From 0x%x to 0x%x: %d kbps %s\n",
                   record->from_classid, record->to_classid,
                   record->borrowed_bw_kbps,
                   record->returned ? "(returned)" : "(active)");
        }
        
        fprintf(fp, "\n");
        
        /* 输出性能统计 */
        print_perf_stats(dev_ctx, fp);
    }
    
    fclose(fp);
    return QOSDBA_OK;
}