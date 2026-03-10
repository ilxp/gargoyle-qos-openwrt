/*
 * main.c - QoS DBA 2.1.1 主程序入口 (优化修复版)
 * 版本: 2.1.1
 * 修复: 调用优化的借还逻辑和保护机制
 */

#include "qosdba.h"
#include "config.h"
#include "tc_ops.h"
#include "bandwidth.h"
#include "monitor.h"
#include "utils.h"
#include "test.h"

#include <getopt.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/time.h>

/* 全局上下文 */
static qosdba_context_t g_ctx;
static atomic_int g_should_exit = 0;
static pthread_t g_signal_thread = 0;

/* 信号处理函数 */
static void signal_handler(int sig) {
    switch (sig) {
        case SIGTERM:
        case SIGINT:
        case SIGQUIT:
            atomic_store(&g_should_exit, 1);
            log_message(&g_ctx, "INFO", "收到退出信号 %d\n", sig);
            break;
        case SIGHUP:
            g_ctx.reload_config = 1;
            log_message(&g_ctx, "INFO", "收到SIGHUP信号，准备重新加载配置\n");
            break;
        case SIGUSR1:
            qosdba_update_status(&g_ctx, "/tmp/qosdba.status");
            log_message(&g_ctx, "INFO", "收到SIGUSR1信号，状态已保存\n");
            break;
        case SIGUSR2:
            g_ctx.debug_mode = !g_ctx.debug_mode;
            log_message(&g_ctx, "INFO", "收到SIGUSR2信号，调试模式: %s\n", 
                       g_ctx.debug_mode ? "启用" : "禁用");
            break;
        case SIGRTMIN:
            /* 动态调整参数 */
            handle_dynamic_parameter_change(&g_ctx);
            log_message(&g_ctx, "INFO", "收到SIGRTMIN信号，已动态调整参数\n");
            break;
    }
}

/* 动态参数调整处理 */
static void handle_dynamic_parameter_change(qosdba_context_t* ctx) {
    if (!ctx) return;
    
    const char* param_file = "/tmp/qosdba_params";
    FILE* fp = fopen(param_file, "r");
    if (!fp) {
        log_message(ctx, "WARN", "无法打开动态参数文件: %s\n", param_file);
        return;
    }
    
    char line[256];
    int changed_count = 0;
    
    while (fgets(line, sizeof(line), fp)) {
        char key[64], value[64];
        trim_whitespace(line);
        
        if (line[0] == '#' || line[0] == '\0') {
            continue;
        }
        
        if (parse_key_value(line, key, sizeof(key), value, sizeof(value))) {
            for (int i = 0; i < ctx->num_devices; i++) {
                device_context_t* dev = &ctx->devices[i];
                
                /* 更新设备参数 */
                if (strcmp(key, "borrow_trigger_threshold") == 0) {
                    int new_val = atoi(value);
                    if (new_val >= 70 && new_val <= 100) {
                        dev->borrow_trigger_threshold = new_val;
                        changed_count++;
                    }
                } else if (strcmp(key, "lend_trigger_threshold") == 0) {
                    int new_val = atoi(value);
                    if (new_val >= 10 && new_val <= 50) {
                        dev->lend_trigger_threshold = new_val;
                        changed_count++;
                    }
                } else if (strcmp(key, "continuous_seconds") == 0) {
                    int new_val = atoi(value);
                    if (new_val >= 3 && new_val <= 10) {
                        dev->continuous_seconds = new_val;
                        changed_count++;
                    }
                } else if (strcmp(key, "return_threshold") == 0) {
                    int new_val = atoi(value);
                    if (new_val >= 20 && new_val <= 70) {
                        dev->return_threshold = new_val;
                        changed_count++;
                    }
                } else if (strcmp(key, "enable_multi_source_borrow") == 0) {
                    int new_val = atoi(value);
                    if (new_val == 0 || new_val == 1) {
                        dev->enable_multi_source_borrow = new_val;
                        changed_count++;
                    }
                }
            }
        }
    }
    
    fclose(fp);
    
    if (changed_count > 0) {
        log_message(ctx, "INFO", "动态调整了 %d 个参数\n", changed_count);
    }
}

/* 信号处理线程 */
static void* signal_thread_func(void* arg) {
    qosdba_context_t* ctx = (qosdba_context_t*)arg;
    
    while (!atomic_load(&g_should_exit)) {
        /* 检查信号队列 */
        int sig = signal_queue_dequeue(&ctx->signal_queue);
        if (sig != 0) {
            signal_handler(sig);
        }
        usleep(10000);  /* 10ms */
    }
    
    return NULL;
}

/* 设置信号处理 */
static qosdba_result_t setup_signals(qosdba_context_t* ctx) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_IGN;
    sa.sa_flags = SA_RESTART;
    
    /* 忽略不需要的信号 */
    sigaction(SIGPIPE, &sa, NULL);
    sigaction(SIGALRM, &sa, NULL);
    sigaction(SIGCHLD, &sa, NULL);
    
    /* 初始化信号队列 */
    qosdba_result_t ret = signal_queue_init(&ctx->signal_queue);
    if (ret != QOSDBA_OK) {
        return ret;
    }
    
    /* 设置需要处理的信号 */
    sa.sa_handler = signal_handler;
    
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGQUIT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGUSR1, &sa, NULL);
    sigaction(SIGUSR2, &sa, NULL);
    sigaction(SIGRTMIN, &sa, NULL);
    
    /* 创建信号处理线程 */
    if (pthread_create(&g_signal_thread, NULL, signal_thread_func, ctx) != 0) {
        return QOSDBA_ERR_THREAD;
    }
    
    pthread_setname_np(g_signal_thread, "qosdba-signal");
    
    return QOSDBA_OK;
}

/* 设备主循环处理 */
static qosdba_result_t process_device_cycle(device_context_t* dev, 
                                           qosdba_context_t* ctx) {
    if (!dev || !ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    int64_t start_time = get_current_time_ms();
    qosdba_result_t overall_result = QOSDBA_OK;
    
    /* 1. 检查带宽使用率（更新滑动窗口） */
    qosdba_result_t ret = check_bandwidth_usage(dev);
    if (ret != QOSDBA_OK) {
        log_device_message(dev, "WARN", "检查带宽使用率失败\n");
        overall_result = ret;
    }
    
    /* 2. 保护机制：防饿死监控 */
    monitor_starvation_risk(dev, ctx);
    
    /* 3. 保护机制：高优先级性能保护 */
    protect_high_priority_classes(dev, ctx);
    
    /* 4. 执行优化版借用逻辑 */
    if (!dev->emergency_stop) {
        ret = run_borrow_logic_optimized(dev, ctx);
        if (ret != QOSDBA_OK && ret != QOSDBA_PARTIAL_SUCCESS) {
            dev->perf_stats.failed_decisions++;
        }
    } else {
        log_device_message(dev, "WARN", "设备处于紧急停止状态，跳过借用决策\n");
    }
    
    /* 5. 执行归还逻辑 */
    if (dev->auto_return_enable) {
        run_return_logic(dev, ctx);
    }
    
    /* 6. 执行批量TC命令 */
    if (dev->batch_cmds.command_count > 0) {
        ret = execute_batch_commands(&dev->batch_cmds, dev, ctx);
        if (ret != QOSDBA_OK) {
            dev->perf_stats.failed_batch_commands++;
        }
    }
    
    /* 7. 检查异步事件 */
    if (dev->async_monitor.async_enabled) {
        check_async_events(dev);
    }
    
    /* 更新性能统计 */
    int64_t cycle_time = get_current_time_ms() - start_time;
    dev->perf_stats.total_cycles++;
    dev->perf_stats.total_cycle_time_ms += cycle_time;
    
    if (cycle_time > dev->perf_stats.max_cycle_time_ms) {
        dev->perf_stats.max_cycle_time_ms = cycle_time;
    }
    
    /* 记录慢循环 */
    if (cycle_time > 100) {  /* 超过100ms */
        log_device_message(dev, "WARN", "处理周期耗时较长: %lldms\n", cycle_time);
    }
    
    return overall_result;
}

/* 主循环 */
static qosdba_result_t main_loop(qosdba_context_t* ctx) {
    int64_t last_check_time = get_current_time_ms();
    int64_t last_status_save = last_check_time;
    int64_t last_debug_output = last_check_time;
    
    while (!atomic_load(&g_should_exit)) {
        int64_t current_time = get_current_time_ms();
        
        /* 检查配置重载 */
        if (ctx->reload_config || 
            (current_time - last_check_time >= ctx->check_interval * 1000)) {
            
            ctx->reload_config = 0;
            last_check_time = current_time;
            
            /* 对每个设备执行带宽管理 */
            for (int i = 0; i < ctx->num_devices; i++) {
                device_context_t* dev = &ctx->devices[i];
                if (!dev->enabled) continue;
                
                process_device_cycle(dev, ctx);
            }
            
            /* 保存状态文件（每分钟） */
            if (current_time - last_status_save >= 60000) {
                qosdba_update_status(ctx, "/tmp/qosdba.status");
                last_status_save = current_time;
            }
            
            /* 调试输出（每5分钟） */
            if (ctx->debug_mode && 
                current_time - last_debug_output >= 300000) {
                print_debug_info(ctx);
                last_debug_output = current_time;
            }
        }
        
        /* 短暂休眠，避免CPU占用过高 */
        usleep(10000);  /* 10ms */
    }
    
    return QOSDBA_OK;
}

/* 打印调试信息 */
static void print_debug_info(qosdba_context_t* ctx) {
    if (!ctx || !ctx->debug_mode) return;
    
    log_message(ctx, "DEBUG", "===== 系统调试信息 =====\n");
    log_message(ctx, "DEBUG", "设备数量: %d\n", ctx->num_devices);
    log_message(ctx, "DEBUG", "检查间隔: %d秒\n", ctx->check_interval);
    log_message(ctx, "DEBUG", "调试模式: %s\n", ctx->debug_mode ? "开启" : "关闭");
    log_message(ctx, "DEBUG", "安全模式: %s\n", ctx->safe_mode ? "开启" : "关闭");
    
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev = &ctx->devices[i];
        
        log_message(ctx, "DEBUG", "\n设备: %s\n", dev->device);
        log_message(ctx, "DEBUG", "  总带宽: %d kbps\n", dev->total_bandwidth_kbps);
        log_message(ctx, "DEBUG", "  分类数: %d\n", dev->num_classes);
        log_message(ctx, "DEBUG", "  借用阈值: %d%%\n", dev->borrow_trigger_threshold);
        log_message(ctx, "DEBUG", "  借出阈值: %d%%\n", dev->lend_trigger_threshold);
        log_message(ctx, "DEBUG", "  连续时间: %d秒\n", dev->continuous_seconds);
        log_message(ctx, "DEBUG", "  紧急停止: %s\n", dev->emergency_stop ? "是" : "否");
        
        /* 性能统计 */
        log_message(ctx, "DEBUG", "  性能统计:\n");
        log_message(ctx, "DEBUG", "    总处理周期: %lld\n", dev->perf_stats.total_cycles);
        log_message(ctx, "DEBUG", "    成功借用: %lld\n", dev->perf_stats.successful_borrows);
        log_message(ctx, "DEBUG", "    失败借用: %lld\n", dev->perf_stats.failed_borrows);
        log_message(ctx, "DEBUG", "    成功归还: %lld\n", dev->perf_stats.successful_returns);
        log_message(ctx, "DEBUG", "    紧急归还: %lld\n", dev->perf_stats.emergency_returns);
        log_message(ctx, "DEBUG", "    失败决策: %lld\n", dev->perf_stats.failed_decisions);
        log_message(ctx, "DEBUG", "    平均周期时间: %.2fms\n", 
                   dev->perf_stats.total_cycles > 0 ? 
                   (float)dev->perf_stats.total_cycle_time_ms / dev->perf_stats.total_cycles : 0);
    }
    
    log_message(ctx, "DEBUG", "=======================\n");
}

/* 程序入口 */
int main(int argc, char* argv[]) {
    const char* config_file = "/etc/qosdba.conf";
    const char* status_file = "/var/run/qosdba.status";
    const char* log_file = NULL;
    
    int debug_mode = 0;
    int safe_mode = 0;
    int foreground = 0;
    int test_mode = 0;
    int show_stats = 0;
    
    /* 解析命令行参数 */
    int opt;
    while ((opt = getopt(argc, argv, "c:s:l:dSfthv")) != -1) {
        switch (opt) {
            case 'c': config_file = optarg; break;
            case 's': status_file = optarg; break;
            case 'l': log_file = optarg; break;
            case 'd': debug_mode = 1; break;
            case 'S': safe_mode = 1; break;
            case 'f': foreground = 1; break;
            case 't': test_mode = 1; break;
            case 'v':
                printf("QoS DBA 2.1.1 (仅支持HTB)\n");
                printf("版本: %s\n", QOSDBA_VERSION);
                printf("编译时间: %s\n", __DATE__ " " __TIME__);
                return 0;
            case 'h':
            default:
                printf("用法: %s [选项]\n", argv[0]);
                printf("选项:\n");
                printf("  -c <文件>   配置文件路径 (默认: /etc/qosdba.conf)\n");
                printf("  -s <文件>   状态文件路径 (默认: /var/run/qosdba.status)\n");
                printf("  -l <文件>   日志文件路径 (默认: stderr)\n");
                printf("  -d          调试模式\n");
                printf("  -S          安全模式 (模拟TC操作)\n");
                printf("  -f          前台运行\n");
                printf("  -t          测试模式\n");
                printf("  -v          显示版本信息\n");
                printf("  -h          显示帮助信息\n");
                printf("\n");
                printf("QoS DBA 2.1.1 - 仅支持HTB算法的动态带宽分配器\n");
                printf("优化特性:\n");
                printf("  - 5秒连续时间检测\n");
                printf("  - 多源借用与负载均衡\n");
                printf("  - 防饿死保护机制\n");
                printf("  - 高优先级性能保护\n");
                return 0;
        }
    }
    
    /* 初始化上下文 */
    qosdba_result_t ret = qosdba_init(&g_ctx);
    if (ret != QOSDBA_OK) {
        fprintf(stderr, "初始化失败: %d\n", ret);
        return 1;
    }
    
    qosdba_set_debug(&g_ctx, debug_mode);
    qosdba_set_safe_mode(&g_ctx, safe_mode);
    
    /* 设置日志 */
    if (log_file) {
        g_ctx.log_file = fopen(log_file, "a");
        if (!g_ctx.log_file) {
            fprintf(stderr, "无法打开日志文件: %s\n", log_file);
            g_ctx.log_file = stderr;
        }
    }
    
    /* 测试模式 */
    if (test_mode) {
        ret = qosdba_run_tests(&g_ctx);
        qosdba_cleanup(&g_ctx);
        return (ret == QOSDBA_OK) ? 0 : 1;
    }
    
    /* 加载配置 */
    ret = load_config_file(&g_ctx, config_file);
    if (ret != QOSDBA_OK) {
        fprintf(stderr, "加载配置文件失败: %s\n", config_file);
        qosdba_cleanup(&g_ctx);
        return 1;
    }
    
    /* 后台运行 */
    if (!foreground) {
        pid_t pid = fork();
        if (pid < 0) {
            fprintf(stderr, "fork失败\n");
            return 1;
        } else if (pid > 0) {
            printf("QoS DBA 2.1.1 已启动，PID: %d\n", pid);
            printf("配置文件: %s\n", config_file);
            printf("设备数: %d\n", g_ctx.num_devices);
            return 0;
        }
        
        setsid();
        chdir("/");
        
        close(STDIN_FILENO);
        close(STDOUT_FILENO);
        close(STDERR_FILENO);
    } else {
        printf("QoS DBA 2.1.1 前台运行\n");
        printf("配置文件: %s\n", config_file);
        printf("设备数: %d\n", g_ctx.num_devices);
    }
    
    /* 设置信号处理 */
    ret = setup_signals(&g_ctx);
    if (ret != QOSDBA_OK) {
        log_message(&g_ctx, "ERROR", "设置信号处理失败\n");
        qosdba_cleanup(&g_ctx);
        return 1;
    }
    
    /* 运行主循环 */
    log_message(&g_ctx, "INFO", "QoS DBA 2.1.1 启动\n");
    log_message(&g_ctx, "INFO", "配置文件: %s\n", config_file);
    log_message(&g_ctx, "INFO", "检查间隔: %d秒\n", g_ctx.check_interval);
    
    /* 打印优化功能状态 */
    for (int i = 0; i < g_ctx.num_devices; i++) {
        device_context_t* dev = &g_ctx.devices[i];
        log_message(&g_ctx, "INFO", "设备: %s, 总带宽: %d kbps, 分类数: %d\n",
                   dev->device, dev->total_bandwidth_kbps, dev->num_classes);
        log_message(&g_ctx, "INFO", "  借用阈值: %d%%, 借出阈值: %d%%, 连续时间: %d秒\n",
                   dev->borrow_trigger_threshold, dev->lend_trigger_threshold,
                   dev->continuous_seconds);
        log_message(&g_ctx, "INFO", "  多源借用: %s, 最大借用源: %d\n",
                   dev->enable_multi_source_borrow ? "启用" : "禁用",
                   dev->max_borrow_sources);
    }
    
    ret = main_loop(&g_ctx);
    
    /* 等待信号线程结束 */
    if (g_signal_thread) {
        pthread_join(g_signal_thread, NULL);
    }
    
    /* 保存状态并清理 */
    qosdba_update_status(&g_ctx, status_file);
    qosdba_cleanup(&g_ctx);
    
    log_message(&g_ctx, "INFO", "QoS DBA 2.1.1 已停止\n");
    
    if (g_ctx.log_file && g_ctx.log_file != stderr) {
        fclose(g_ctx.log_file);
    }
    
    return (ret == QOSDBA_OK) ? 0 : 1;
}