/*
 * bandwidth.c - 带宽借用逻辑模块 (优化修复版)
 * 实现带宽监控、借用、归还算法
 * 版本: 2.1.1
 * 修复: 添加滑动窗口、多源借用、保护机制
 */

#include "qosdba.h"
#include <math.h>
#include <float.h>

/* 浮点数比较容差 */
#define FLOAT_EPSILON 0.000001f

/* 滑动窗口大小 */
#define WINDOW_SIZE 10
#define HISTORY_SECONDS 10

/* ==================== 数据结构定义 ==================== */

/* 使用率滑动窗口 */
typedef struct {
    float utilization_samples[WINDOW_SIZE];  /* 10秒历史数据 */
    int64_t sample_timestamps[WINDOW_SIZE];  /* 样本时间戳 */
    int sample_index;                        /* 当前索引 */
    int sample_count;                        /* 有效样本数 */
    float last_average_5s;                   /* 最近5秒平均值 */
    int continuous_high_count;               /* 连续高使用计数 */
    int continuous_low_count;                /* 连续低使用计数 */
} utilization_window_t;

/* 借用源评分信息 */
typedef struct {
    int lender_index;        /* 借出方索引 */
    int available_bw;        /* 可用带宽 */
    int safe_lend_amount;    /* 安全借出量 */
    float impact_score;      /* 影响评分（越低越好） */
    int priority_gap;        /* 优先级差距 */
} lender_score_t;

/* ==================== 滑动窗口管理函数 ==================== */

/* 初始化滑动窗口 */
static void init_utilization_window(utilization_window_t* window) {
    if (!window) return;
    
    memset(window, 0, sizeof(utilization_window_t));
    window->sample_index = 0;
    window->sample_count = 0;
    window->last_average_5s = 0.0f;
    window->continuous_high_count = 0;
    window->continuous_low_count = 0;
}

/* 更新滑动窗口 */
static void update_utilization_window(utilization_window_t* window, 
                                     float utilization, 
                                     int64_t timestamp) {
    if (!window) return;
    
    /* 添加新样本 */
    window->utilization_samples[window->sample_index] = utilization;
    window->sample_timestamps[window->sample_index] = timestamp;
    
    /* 更新索引 */
    window->sample_index = (window->sample_index + 1) % WINDOW_SIZE;
    
    /* 更新样本计数，但不超过窗口大小 */
    if (window->sample_count < WINDOW_SIZE) {
        window->sample_count++;
    }
}

/* 获取5秒滑动平均值 */
static float get_5s_average_utilization(utilization_window_t* window, 
                                       int64_t current_time) {
    if (!window || window->sample_count == 0) {
        return 0.0f;
    }
    
    float sum = 0.0f;
    int count = 0;
    int64_t five_seconds_ago = current_time - 5000; /* 5秒前 */
    
    /* 遍历窗口，计算最近5秒内的样本 */
    for (int i = 0; i < window->sample_count; i++) {
        int idx = (window->sample_index - i - 1 + WINDOW_SIZE) % WINDOW_SIZE;
        
        /* 检查样本是否在5秒内 */
        if (window->sample_timestamps[idx] >= five_seconds_ago) {
            sum += window->utilization_samples[idx];
            count++;
        } else {
            break;  /* 样本按时间顺序存储，可以提前退出 */
        }
    }
    
    if (count > 0) {
        window->last_average_5s = sum / count;
    }
    
    return window->last_average_5s;
}

/* 检查是否连续5秒高使用率 */
static int is_continuously_high(utilization_window_t* window, 
                               int threshold, 
                               int64_t current_time) {
    if (!window || window->sample_count < 5) {
        return 0;
    }
    
    /* 检查最近5个样本是否都超过阈值 */
    for (int i = 0; i < 5 && i < window->sample_count; i++) {
        int idx = (window->sample_index - i - 1 + WINDOW_SIZE) % WINDOW_SIZE;
        int64_t sample_time = window->sample_timestamps[idx];
        
        /* 样本必须在5秒内 */
        if (current_time - sample_time > 5000) {
            return 0;
        }
        
        /* 检查使用率 */
        if (window->utilization_samples[idx] * 100 < threshold) {
            return 0;
        }
    }
    
    return 1;
}

/* 检查是否连续5秒低使用率 */
static int is_continuously_low(utilization_window_t* window, 
                              int threshold, 
                              int64_t current_time) {
    if (!window || window->sample_count < 5) {
        return 0;
    }
    
    /* 检查最近5个样本是否都低于阈值 */
    for (int i = 0; i < 5 && i < window->sample_count; i++) {
        int idx = (window->sample_index - i - 1 + WINDOW_SIZE) % WINDOW_SIZE;
        int64_t sample_time = window->sample_timestamps[idx];
        
        /* 样本必须在5秒内 */
        if (current_time - sample_time > 5000) {
            return 0;
        }
        
        /* 检查使用率 */
        if (window->utilization_samples[idx] * 100 > threshold) {
            return 0;
        }
    }
    
    return 1;
}

/* ==================== 带宽使用率检查（优化版） ==================== */

qosdba_result_t check_bandwidth_usage(device_context_t* dev_ctx) {
    if (!dev_ctx || dev_ctx->num_classes == 0) {
        return QOSDBA_ERR_MEMORY;
    }
    
    int64_t now = get_current_time_ms();
    
    /* 初始化滑动窗口数组（如果需要） */
    if (!dev_ctx->util_windows && dev_ctx->num_classes > 0) {
        dev_ctx->util_windows = calloc(dev_ctx->num_classes, 
                                      sizeof(utilization_window_t));
        if (!dev_ctx->util_windows) {
            return QOSDBA_ERR_MEMORY;
        }
        
        for (int i = 0; i < dev_ctx->num_classes; i++) {
            init_utilization_window(&dev_ctx->util_windows[i]);
        }
    }
    
    /* 更新TC缓存 */
    qosdba_result_t cache_ret = update_tc_cache(dev_ctx);
    if (cache_ret != QOSDBA_OK) {
        log_device_message(dev_ctx, "WARN", "TC统计缓存更新失败\n");
    }
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_state_t* state = &dev_ctx->states[i];
        utilization_window_t* window = &dev_ctx->util_windows[i];
        
        if (!state->dba_enabled) {
            continue;
        }
        
        /* 获取分类统计 */
        uint64_t bytes = 0;
        int got_stats = 0;
        
        /* 尝试从缓存获取 */
        if (dev_ctx->tc_cache.valid) {
            got_stats = 1;  /* 简化版本 */
        }
        
        if (!got_stats) {
            /* 直接查询TC */
            int ifindex = get_ifindex(dev_ctx);
            if (ifindex > 0) {
                struct rtnl_class* class_obj = rtnl_class_alloc();
                if (class_obj) {
                    rtnl_tc_set_ifindex(TC_CAST(class_obj), ifindex);
                    rtnl_tc_set_handle(TC_CAST(class_obj), state->classid);
                    
                    int ret = rtnl_class_get(&dev_ctx->rth, class_obj);
                    if (ret == 0) {
                        got_stats = 1;
                    }
                    rtnl_class_put(class_obj);
                }
            }
        }
        
        if (got_stats) {
            int64_t time_diff = now - state->last_check_time;
            if (time_diff > 0) {
                /* 计算带宽使用率 */
                int64_t bytes_diff = 0;  /* 实际应从统计获取 */
                int64_t bps = (bytes_diff * 8000LL) / time_diff;
                int new_used_bw_kbps = (int)(bps / 1000);
                
                if (new_used_bw_kbps < 0) new_used_bw_kbps = 0;
                if (new_used_bw_kbps > dev_ctx->total_bandwidth_kbps) {
                    new_used_bw_kbps = dev_ctx->total_bandwidth_kbps;
                }
                
                state->used_bw_kbps = new_used_bw_kbps;
                
                if (state->current_bw_kbps > 0) {
                    state->utilization = (float)state->used_bw_kbps / state->current_bw_kbps;
                } else {
                    state->utilization = 0.0f;
                }
                
                /* 更新滑动窗口 */
                update_utilization_window(window, state->utilization, now);
                
                /* 计算5秒平均值 */
                float avg_5s = get_5s_average_utilization(window, now);
                
                /* 更新连续计数（基于5秒平均值） */
                if (avg_5s * 100 >= dev_ctx->borrow_trigger_threshold) {
                    state->continuous_high_count++;
                    state->continuous_low_count = 0;
                } else if (avg_5s * 100 <= dev_ctx->lend_trigger_threshold) {
                    state->continuous_low_count++;
                    state->continuous_high_count = 0;
                } else {
                    state->continuous_high_count = 0;
                    state->continuous_low_count = 0;
                }
                
                /* 更新冷却计时器 */
                if (state->cooldown_timer > 0) {
                    state->cooldown_timer--;
                }
                
                state->last_check_time = now;
            }
        } else {
            log_device_message(dev_ctx, "WARN", 
                              "分类 0x%x 无法获取统计信息\n", 
                              state->classid);
        }
    }
    
    return QOSDBA_OK;
}

/* ==================== 查找分类函数 ==================== */

int find_class_by_id(device_context_t* dev_ctx, int classid) {
    if (!dev_ctx) return -1;
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        if (dev_ctx->states[i].classid == classid) {
            return i;
        }
    }
    return -1;
}

/* 计算借出方评分（用于负载均衡） */
static float calculate_lender_score(class_state_t* lender, 
                                   class_config_t* config,
                                   device_context_t* dev_ctx) {
    float score = 0.0f;
    
    /* 1. 使用率因子（30%权重）：越低越好 */
    score += (1.0f - lender->utilization) * 0.3f;
    
    /* 2. 历史借用因子（20%权重）：借用越少越好 */
    float historical_ratio = 0;
    if (lender->current_bw_kbps > 0) {
        historical_ratio = (float)lender->lent_bw_kbps / lender->current_bw_kbps;
    }
    score += (1.0f - min(historical_ratio, 1.0f)) * 0.2f;
    
    /* 3. 带宽占比因子（20%权重）：占总带宽比例小的优先 */
    float bandwidth_ratio = (float)lender->current_bw_kbps / 
                          dev_ctx->total_bandwidth_kbps;
    score += (1.0f - bandwidth_ratio) * 0.2f;
    
    /* 4. 可用带宽因子（20%权重）：可用越多越好 */
    int available_bw = lender->current_bw_kbps - lender->used_bw_kbps;
    float available_ratio = 0;
    if (lender->current_bw_kbps > 0) {
        available_ratio = (float)available_bw / lender->current_bw_kbps;
    }
    score += available_ratio * 0.2f;
    
    /* 5. 冷却因子（10%权重）：不在冷却期的优先 */
    score += (lender->cooldown_timer == 0) ? 0.1f : 0.0f;
    
    return score;
}

/* 查找可借用的分类（多源版本） */
int find_available_lenders(device_context_t* dev_ctx, 
                          int borrower_idx,
                          int needed_bw_kbps,
                          lender_score_t* lenders, 
                          int max_lenders) {
    if (!dev_ctx || !lenders || max_lenders <= 0) {
        return 0;
    }
    
    class_state_t* borrower = &dev_ctx->states[borrower_idx];
    class_config_t* borrower_config = &dev_ctx->configs[borrower_idx];
    int found_count = 0;
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        if (i == borrower_idx) continue;
        
        class_state_t* lender = &dev_ctx->states[i];
        class_config_t* config = &dev_ctx->configs[i];
        
        /* 基本条件检查 */
        if (!lender->dba_enabled) continue;
        if (lender->cooldown_timer > 0) continue;
        
        /* 检查使用率：必须连续低使用率 */
        if (!is_continuously_low(&dev_ctx->util_windows[i], 
                                dev_ctx->lend_trigger_threshold, 
                                get_current_time_ms())) {
            continue;
        }
        
        /* 优先级检查：只能从低优先级（数值更大）借用 */
        int priority_gap = config->priority - borrower_config->priority;
        if (priority_gap <= 0) {
            continue;  /* 优先级相等或更高，不能借用 */
        }
        
        /* 检查最小优先级间隔 */
        if (priority_gap < dev_ctx->min_priority_gap) {
            continue;
        }
        
        /* 计算可借出带宽 */
        int safe_lend = calculate_safe_lend_amount(lender, config, dev_ctx);
        if (safe_lend < dev_ctx->min_borrow_kbps) {
            continue;
        }
        
        /* 添加到候选列表 */
        lenders[found_count].lender_index = i;
        lenders[found_count].available_bw = lender->current_bw_kbps - 
                                           lender->used_bw_kbps;
        lenders[found_count].safe_lend_amount = safe_lend;
        lenders[found_count].priority_gap = priority_gap;
        lenders[found_count].impact_score = calculate_lender_score(lender, config, dev_ctx);
        
        found_count++;
        if (found_count >= max_lenders) break;
    }
    
    return found_count;
}

/* 比较函数：用于排序借出方（按评分从高到低） */
static int compare_lenders_by_score(const void* a, const void* b) {
    const lender_score_t* la = (const lender_score_t*)a;
    const lender_score_t* lb = (const lender_score_t*)b;
    
    /* 评分高的在前面 */
    if (la->impact_score > lb->impact_score) return -1;
    if (la->impact_score < lb->impact_score) return 1;
    return 0;
}

/* 比较函数：用于排序借出方（按优先级差距从小到大） */
static int compare_lenders_by_priority(const void* a, const void* b) {
    const lender_score_t* la = (const lender_score_t*)a;
    const lender_score_t* lb = (const lender_score_t*)b;
    
    /* 优先级差距小的在前面 */
    if (la->priority_gap < lb->priority_gap) return -1;
    if (la->priority_gap > lb->priority_gap) return 1;
    return 0;
}

/* ==================== 计算安全借出量 ==================== */

/* 计算安全可借出带宽 */
static int calculate_safe_lend_amount(class_state_t* lender, 
                                     class_config_t* config,
                                     device_context_t* dev_ctx) {
    int current_bw = lender->current_bw_kbps;
    int used_bw = lender->used_bw_kbps;
    int min_bw = config->min_bw_kbps;
    
    /* 1. 绝对不能低于配置的最小带宽 */
    int absolute_min = min_bw;
    
    /* 2. 为自己保留足够的带宽 */
    int keep_for_self = (int)(used_bw * dev_ctx->keep_for_self_ratio);
    int usage_based_min = max(absolute_min, keep_for_self);
    
    /* 3. 计算可借出带宽 */
    int lendable = current_bw - usage_based_min;
    
    /* 4. 应用最大借出比例限制 */
    int max_by_ratio = (int)(current_bw * dev_ctx->max_lend_ratio);
    lendable = min(lendable, max_by_ratio);
    
    /* 5. 确保不为负 */
    lendable = max(0, lendable);
    
    /* 6. 考虑已借出的带宽 */
    int available_after_lent = lendable - lender->lent_bw_kbps;
    
    return max(0, available_after_lent);
}

/* 计算真实带宽需求 */
static int calculate_real_bandwidth_needed(class_state_t* borrower, 
                                          device_context_t* dev_ctx) {
    /* 目标：将使用率降至85% */
    float target_util = 0.85f;
    
    if (borrower->current_bw_kbps > 0 && borrower->utilization > target_util) {
        /* 计算达到目标使用率所需的带宽 */
        int required_bw = (int)(borrower->used_bw_kbps / target_util);
        int needed = max(0, required_bw - borrower->current_bw_kbps);
        
        /* 应用最大借用比例限制 */
        int max_by_ratio = (int)(borrower->current_bw_kbps * 
                                dev_ctx->max_borrow_ratio);
        needed = min(needed, max_by_ratio);
        
        return needed;
    }
    
    return 0;
}

/* ==================== 优化借用逻辑 ==================== */

qosdba_result_t run_borrow_logic_optimized(device_context_t* dev_ctx, 
                                          qosdba_context_t* ctx) {
    if (!dev_ctx || !ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    qosdba_result_t overall_result = QOSDBA_OK;
    
    /* 查找需要带宽的分类 */
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_state_t* state = &dev_ctx->states[i];
        class_config_t* config = &dev_ctx->configs[i];
        
        if (!state->dba_enabled) {
            continue;
        }
        
        /* 检查冷却期 */
        if (state->cooldown_timer > 0) {
            continue;
        }
        
        /* 检查借用条件：连续5秒高使用率 */
        if (!is_continuously_high(&dev_ctx->util_windows[i], 
                                 dev_ctx->borrow_trigger_threshold, 
                                 get_current_time_ms())) {
            continue;
        }
        
        /* 计算真实带宽需求 */
        int needed_bw = calculate_real_bandwidth_needed(state, dev_ctx);
        if (needed_bw < dev_ctx->min_borrow_kbps) {
            continue;
        }
        
        /* 检查是否已借满 */
        int max_borrowable = config->max_bw_kbps - state->current_bw_kbps;
        if (state->borrowed_bw_kbps >= max_borrowable) {
            continue;
        }
        
        /* 查找可借用的分类 */
        lender_score_t lenders[MAX_CLASSES];
        int max_sources = dev_ctx->enable_multi_source_borrow ? 
                         min(dev_ctx->max_borrow_sources, MAX_CLASSES) : 1;
        
        int found_lenders = find_available_lenders(dev_ctx, i, 
                                                  needed_bw, 
                                                  lenders, 
                                                  max_sources);
        
        if (found_lenders == 0) {
            continue;
        }
        
        /* 排序借出方 */
        if (dev_ctx->load_balance_mode) {
            /* 负载均衡模式：按评分排序（影响小的优先） */
            qsort(lenders, found_lenders, sizeof(lender_score_t), 
                  compare_lenders_by_score);
        } else {
            /* 集中模式：按优先级差距排序（差距小的优先） */
            qsort(lenders, found_lenders, sizeof(lender_score_t), 
                  compare_lenders_by_priority);
        }
        
        /* 从多个源借用 */
        int remaining_needed = needed_bw;
        int borrowed_sources = 0;
        
        for (int j = 0; j < found_lenders && remaining_needed > 0; j++) {
            int lender_idx = lenders[j].lender_index;
            class_state_t* lender = &dev_ctx->states[lender_idx];
            class_config_t* lender_config = &dev_ctx->configs[lender_idx];
            
            /* 计算单次借用量 */
            int max_single_borrow = lenders[j].safe_lend_amount;
            int actual_borrow = min(max_single_borrow, remaining_needed);
            
            /* 确保不低于最小借用单位 */
            if (actual_borrow < dev_ctx->min_borrow_kbps) {
                continue;
            }
            
            /* 应用单次借用上限 */
            int max_by_config = (int)(lender->current_bw_kbps * 
                                     dev_ctx->max_borrow_ratio);
            actual_borrow = min(actual_borrow, max_by_config);
            
            /* 执行借用 */
            qosdba_result_t ret = execute_single_borrow(dev_ctx, ctx, 
                                                       lender_idx, i, 
                                                       actual_borrow);
            
            if (ret == QOSDBA_OK) {
                /* 更新状态 */
                lender->current_bw_kbps -= actual_borrow;
                lender->lent_bw_kbps += actual_borrow;
                lender->cooldown_timer = dev_ctx->cooldown_time;
                
                state->current_bw_kbps += actual_borrow;
                state->borrowed_bw_kbps += actual_borrow;
                state->continuous_high_count = 0;
                state->cooldown_timer = dev_ctx->cooldown_time;
                
                /* 添加借用记录 */
                add_borrow_record(dev_ctx, lender->classid, 
                                 state->classid, actual_borrow);
                
                /* 更新统计 */
                dev_ctx->perf_stats.successful_borrows++;
                dev_ctx->total_borrow_events++;
                dev_ctx->total_borrowed_kbps += actual_borrow;
                
                log_device_message(dev_ctx, "INFO", 
                                  "带宽借用成功: 从 0x%x 借 %d kbps 到 0x%x (来源: %d/%d)\n",
                                  lender->classid, actual_borrow, 
                                  state->classid, j+1, found_lenders);
                
                remaining_needed -= actual_borrow;
                borrowed_sources++;
            } else {
                dev_ctx->perf_stats.failed_borrows++;
                log_device_message(dev_ctx, "WARN", 
                                  "带宽借用失败: 从 0x%x 到 0x%x\n",
                                  lender->classid, state->classid);
            }
        }
        
        if (remaining_needed > 0) {
            log_device_message(dev_ctx, "INFO", 
                              "带宽借用部分成功: 分类 0x%x 获得 %d/%d kbps\n",
                              state->classid, needed_bw - remaining_needed, 
                              needed_bw);
        }
    }
    
    return overall_result;
}

/* 执行单次借用 */
static qosdba_result_t execute_single_borrow(device_context_t* dev_ctx,
                                            qosdba_context_t* ctx,
                                            int lender_idx,
                                            int borrower_idx,
                                            int borrow_amount) {
    if (!dev_ctx || !ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    class_state_t* lender = &dev_ctx->states[lender_idx];
    class_state_t* borrower = &dev_ctx->states[borrower_idx];
    
    /* 调整带宽：减少借出方，增加借用方 */
    qosdba_result_t ret = adjust_class_bandwidth(
        dev_ctx, ctx, lender->classid, 
        lender->current_bw_kbps - borrow_amount);
    
    if (ret == QOSDBA_OK) {
        ret = adjust_class_bandwidth(
            dev_ctx, ctx, borrower->classid, 
            borrower->current_bw_kbps + borrow_amount);
    }
    
    return ret;
}

/* ==================== 保护机制函数 ==================== */

/* 防饿死监控 */
void monitor_starvation_risk(device_context_t* dev_ctx, qosdba_context_t* ctx) {
    if (!dev_ctx || !ctx) {
        return;
    }
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_state_t* state = &dev_ctx->states[i];
        
        /* 只检查有借出带宽的分类 */
        if (state->lent_bw_kbps == 0) {
            continue;
        }
        
        /* 计算饿死风险 */
        float starvation_risk = calculate_starvation_risk(state, dev_ctx);
        
        if (starvation_risk * 100 >= dev_ctx->starvation_critical) {
            /* 紧急饿死：立即归还 */
            emergency_return_for_starvation(dev_ctx, ctx, i);
            
        } else if (starvation_risk * 100 >= dev_ctx->starvation_warning) {
            /* 高风险：加速归还 */
            accelerate_return_for_lender(dev_ctx, ctx, i);
            
            /* 临时提高冷却时间，防止继续借用 */
            state->cooldown_timer = dev_ctx->cooldown_time * 2;
            
            log_device_message(dev_ctx, "WARN", 
                              "分类 0x%x 饿死风险高(%.1f%%)，加速归还\n",
                              state->classid, starvation_risk * 100);
        }
    }
}

/* 计算饿死风险 */
static float calculate_starvation_risk(class_state_t* lender, 
                                      device_context_t* dev_ctx) {
    if (!lender) return 0.0f;
    
    /* 风险因子1: 当前使用率 */
    float usage_factor = lender->utilization;
    
    /* 风险因子2: 被借出比例 */
    float lent_ratio = 0;
    if (lender->current_bw_kbps > 0) {
        lent_ratio = (float)lender->lent_bw_kbps / lender->current_bw_kbps;
    }
    
    /* 风险因子3: 可用带宽缓冲 */
    int available_bw = lender->current_bw_kbps - lender->used_bw_kbps;
    float buffer_factor = 0;
    if (lender->current_bw_kbps > 0) {
        buffer_factor = 1.0f - (float)available_bw / lender->current_bw_kbps;
    }
    
    /* 综合风险 */
    float risk = (usage_factor * 0.4f) + (lent_ratio * 0.4f) + (buffer_factor * 0.2f);
    
    return min(1.0f, risk);
}

/* 紧急归还机制 */
void emergency_return_for_starvation(device_context_t* dev_ctx, 
                                    qosdba_context_t* ctx, 
                                    int lender_idx) {
    if (!dev_ctx || !ctx || lender_idx < 0 || 
        lender_idx >= dev_ctx->num_classes) {
        return;
    }
    
    class_state_t* lender = &dev_ctx->states[lender_idx];
    
    /* 查找该借出方的所有借用记录 */
    for (int i = 0; i < dev_ctx->num_records; i++) {
        borrow_record_t* record = &dev_ctx->records[i];
        
        if (record->returned || 
            record->from_classid != lender->classid) {
            continue;
        }
        
        /* 计算紧急归还量 */
        int return_amount = (int)(record->borrowed_bw_kbps * 
                                 dev_ctx->emergency_return_ratio);
        
        if (return_amount < dev_ctx->min_change_kbps) {
            return_amount = dev_ctx->min_change_kbps;
        }
        
        if (return_amount > record->borrowed_bw_kbps) {
            return_amount = record->borrowed_bw_kbps;
        }
        
        /* 查找借用方 */
        int borrower_idx = find_class_by_id(dev_ctx, record->to_classid);
        if (borrower_idx < 0) continue;
        
        class_state_t* borrower = &dev_ctx->states[borrower_idx];
        
        /* 执行紧急归还 */
        qosdba_result_t ret = adjust_class_bandwidth(
            dev_ctx, ctx, borrower->classid, 
            borrower->current_bw_kbps - return_amount);
        
        if (ret == QOSDBA_OK) {
            ret = adjust_class_bandwidth(
                dev_ctx, ctx, lender->classid, 
                lender->current_bw_kbps + return_amount);
        }
        
        if (ret == QOSDBA_OK) {
            /* 更新状态 */
            borrower->current_bw_kbps -= return_amount;
            borrower->borrowed_bw_kbps -= return_amount;
            
            lender->current_bw_kbps += return_amount;
            lender->lent_bw_kbps -= return_amount;
            
            record->borrowed_bw_kbps -= return_amount;
            
            if (record->borrowed_bw_kbps <= 0) {
                record->returned = 1;
            }
            
            /* 记录紧急归还事件 */
            dev_ctx->perf_stats.emergency_returns++;
            
            log_device_message(dev_ctx, "ERROR", 
                              "紧急归还: 从 0x%x 归还 %d kbps 到 0x%x (饿死保护)\n",
                              borrower->classid, return_amount, 
                              lender->classid);
        }
    }
    
    /* 锁定借出方，防止继续被借用 */
    lender->cooldown_timer = dev_ctx->cooldown_time * 5;  /* 5倍冷却时间 */
    lender->emergency_lock = 1;
    lender->emergency_lock_until = get_current_time_ms() + 30000;  /* 锁定30秒 */
}

/* 加速归还 */
static void accelerate_return_for_lender(device_context_t* dev_ctx,
                                        qosdba_context_t* ctx,
                                        int lender_idx) {
    if (!dev_ctx || !ctx) return;
    
    /* 查找该借出方的所有借用记录 */
    for (int i = 0; i < dev_ctx->num_records; i++) {
        borrow_record_t* record = &dev_ctx->records[i];
        
        if (record->returned) continue;
        
        int borrower_idx = find_class_by_id(dev_ctx, record->to_classid);
        if (borrower_idx < 0) continue;
        
        class_state_t* borrower = &dev_ctx->states[borrower_idx];
        
        /* 检查借用方是否稳定低使用 */
        if (borrower->utilization * 100 < dev_ctx->return_threshold) {
            /* 加速归还：使用更大的归还比例 */
            int return_amount = (int)(record->borrowed_bw_kbps * 0.3f);  /* 30% */
            
            if (return_amount < dev_ctx->min_change_kbps) {
                return_amount = dev_ctx->min_change_kbps;
            }
            
            if (return_amount > record->borrowed_bw_kbps) {
                return_amount = record->borrowed_bw_kbps;
            }
            
            /* 执行归还 */
            run_single_return(dev_ctx, ctx, record, borrower_idx, lender_idx, 
                             return_amount);
        }
    }
}

/* 高优先级性能保护 */
void protect_high_priority_classes(device_context_t* dev_ctx, qosdba_context_t* ctx) {
    if (!dev_ctx || !ctx) {
        return;
    }
    
    for (int i = 0; i < dev_ctx->num_classes; i++) {
        class_config_t* config = &dev_ctx->configs[i];
        
        /* 只监控高优先级分类（优先级1-3） */
        if (config->priority > 3) {
            continue;
        }
        
        class_state_t* state = &dev_ctx->states[i];
        
        /* 检查性能下降指标 */
        if (state->utilization * 100 >= dev_ctx->high_priority_protect_level) {
            /* 高优先级分类性能下降，触发紧急回收 */
            emergency_reclaim_bandwidth(dev_ctx, ctx, i);
            
            log_device_message(dev_ctx, "WARN", 
                              "高优先级分类 0x%x 性能下降(%.1f%%)，触发带宽回收\n",
                              state->classid, state->utilization * 100);
        }
    }
}

/* 紧急带宽回收 */
static void emergency_reclaim_bandwidth(device_context_t* dev_ctx,
                                       qosdba_context_t* ctx,
                                       int high_priority_idx) {
    if (!dev_ctx || !ctx) return;
    
    class_state_t* hp_state = &dev_ctx->states[high_priority_idx];
    
    /* 查找该分类的所有借用记录 */
    for (int i = 0; i < dev_ctx->num_records; i++) {
        borrow_record_t* record = &dev_ctx->records[i];
        
        if (record->returned || 
            record->to_classid != hp_state->classid) {
            continue;
        }
        
        /* 计算回收量 */
        int reclaim_amount = (int)(record->borrowed_bw_kbps * 0.5f);  /* 回收50% */
        
        if (reclaim_amount < dev_ctx->min_change_kbps) {
            reclaim_amount = dev_ctx->min_change_kbps;
        }
        
        if (reclaim_amount > record->borrowed_bw_kbps) {
            reclaim_amount = record->borrowed_bw_kbps;
        }
        
        /* 查找借出方 */
        int lender_idx = find_class_by_id(dev_ctx, record->from_classid);
        if (lender_idx < 0) continue;
        
        class_state_t* lender = &dev_ctx->states[lender_idx];
        
        /* 执行回收（反向借用） */
        qosdba_result_t ret = adjust_class_bandwidth(
            dev_ctx, ctx, lender->classid, 
            lender->current_bw_kbps + reclaim_amount);
        
        if (ret == QOSDBA_OK) {
            ret = adjust_class_bandwidth(
                dev_ctx, ctx, hp_state->classid, 
                hp_state->current_bw_kbps - reclaim_amount);
        }
        
        if (ret == QOSDBA_OK) {
            /* 更新状态 */
            lender->current_bw_kbps += reclaim_amount;
            lender->lent_bw_kbps -= reclaim_amount;
            
            hp_state->current_bw_kbps -= reclaim_amount;
            hp_state->borrowed_bw_kbps -= reclaim_amount;
            
            record->borrowed_bw_kbps -= reclaim_amount;
            
            if (record->borrowed_bw_kbps <= 0) {
                record->returned = 1;
            }
            
            log_device_message(dev_ctx, "INFO", 
                              "带宽回收: 从 0x%x 回收 %d kbps 到 0x%x (高优先级保护)\n",
                              hp_state->classid, reclaim_amount, 
                              lender->classid);
        }
    }
}

/* ==================== 优化归还逻辑 ==================== */

void run_return_logic(device_context_t* dev_ctx, qosdba_context_t* ctx) {
    if (!dev_ctx || !ctx || !dev_ctx->auto_return_enable) {
        return;
    }
    
    /* 检查借用记录，查找可以归还的带宽 */
    for (int i = 0; i < dev_ctx->num_records; i++) {
        borrow_record_t* record = &dev_ctx->records[i];
        
        if (record->returned) {
            continue;
        }
        
        /* 查找借用方和出借方 */
        int borrower_idx = find_class_by_id(dev_ctx, record->to_classid);
        int lender_idx = find_class_by_id(dev_ctx, record->from_classid);
        
        if (borrower_idx < 0 || lender_idx < 0) {
            continue;
        }
        
        class_state_t* borrower = &dev_ctx->states[borrower_idx];
        class_state_t* lender = &dev_ctx->states[lender_idx];
        
        /* 检查借用方是否稳定低使用 */
        if (borrower->utilization * 100 < dev_ctx->return_threshold &&
            is_continuously_low(&dev_ctx->util_windows[borrower_idx], 
                              dev_ctx->return_threshold, 
                              get_current_time_ms())) {
            
            /* 计算渐进式归还带宽 */
            int return_amount = (int)(record->borrowed_bw_kbps * 
                                     dev_ctx->return_speed);
            
            if (return_amount < dev_ctx->min_change_kbps) {
                return_amount = dev_ctx->min_change_kbps;
            }
            
            if (return_amount > record->borrowed_bw_kbps) {
                return_amount = record->borrowed_bw_kbps;
            }
            
            /* 执行单次归还 */
            run_single_return(dev_ctx, ctx, record, borrower_idx, lender_idx, 
                             return_amount);
        }
    }
}

/* 执行单次归还 */
static void run_single_return(device_context_t* dev_ctx, qosdba_context_t* ctx,
                             borrow_record_t* record, 
                             int borrower_idx, int lender_idx,
                             int return_amount) {
    if (!dev_ctx || !ctx || !record) return;
    
    class_state_t* borrower = &dev_ctx->states[borrower_idx];
    class_state_t* lender = &dev_ctx->states[lender_idx];
    
    /* 调整带宽 */
    qosdba_result_t ret = adjust_class_bandwidth(
        dev_ctx, ctx, borrower->classid, 
        borrower->current_bw_kbps - return_amount);
    
    if (ret == QOSDBA_OK) {
        ret = adjust_class_bandwidth(
            dev_ctx, ctx, lender->classid, 
            lender->current_bw_kbps + return_amount);
    }
    
    if (ret == QOSDBA_OK) {
        /* 更新状态 */
        borrower->current_bw_kbps -= return_amount;
        borrower->borrowed_bw_kbps -= return_amount;
        
        lender->current_bw_kbps += return_amount;
        lender->lent_bw_kbps -= return_amount;
        
        record->borrowed_bw_kbps -= return_amount;
        
        if (record->borrowed_bw_kbps <= 0) {
            record->returned = 1;
        }
        
        dev_ctx->perf_stats.successful_returns++;
        dev_ctx->total_return_events++;
        dev_ctx->total_returned_kbps += return_amount;
        
        log_device_message(dev_ctx, "INFO", 
                          "带宽归还成功: 从 0x%x 归还 %d kbps 到 0x%x (剩余: %d)\n",
                          borrower->classid, return_amount, 
                          lender->classid, record->borrowed_bw_kbps);
    } else {
        dev_ctx->perf_stats.failed_returns++;
    }
}

/* ==================== 借用记录管理 ==================== */

void add_borrow_record(device_context_t* dev_ctx, int from_classid, 
                      int to_classid, int borrowed_bw_kbps) {
    if (!dev_ctx) return;
    
    if (dev_ctx->num_records >= MAX_BORROW_RECORDS) {
        /* 移除一半旧的记录 */
        for (int i = 0; i < MAX_BORROW_RECORDS / 2; i++) {
            dev_ctx->records[i] = dev_ctx->records[i + MAX_BORROW_RECORDS / 2];
        }
        dev_ctx->num_records = MAX_BORROW_RECORDS / 2;
    }
    
    borrow_record_t* record = &dev_ctx->records[dev_ctx->num_records];
    record->from_classid = from_classid;
    record->to_classid = to_classid;
    record->borrowed_bw_kbps = borrowed_bw_kbps;
    record->start_time = get_current_time_ms();
    record->returned = 0;
    
    dev_ctx->num_records++;
}