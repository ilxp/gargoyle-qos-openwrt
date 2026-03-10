/*
 * signal.c - 信号处理模块
 * 实现信号队列、信号处理线程、优雅退出
 * 版本: 2.1.1
 */

#include "qosdba.h"
#include <signal.h>
#include <unistd.h>

/* 全局信号管道 */
static int g_signal_pipe[2] = {-1, -1};
static pthread_t g_signal_thread = 0;

/* ==================== 信号队列管理 ==================== */

qosdba_result_t signal_queue_init(signal_queue_t* queue) {
    if (!queue) {
        return QOSDBA_ERR_MEMORY;
    }
    
    memset(queue, 0, sizeof(signal_queue_t));
    
    for (int i = 0; i < 10; i++) {
        queue->signals[i] = 0;
    }
    
    queue->signal_count = 0;
    queue->signal_read_index = 0;
    queue->signal_write_index = 0;
    
    if (pthread_mutex_init(&queue->signal_mutex, NULL) != 0) {
        return QOSDBA_ERR_THREAD;
    }
    
    if (pthread_cond_init(&queue->signal_cond, NULL) != 0) {
        pthread_mutex_destroy(&queue->signal_mutex);
        return QOSDBA_ERR_THREAD;
    }
    
    return QOSDBA_OK;
}

void signal_queue_cleanup(signal_queue_t* queue) {
    if (!queue) {
        return;
    }
    
    pthread_mutex_destroy(&queue->signal_mutex);
    pthread_cond_destroy(&queue->signal_cond);
}

qosdba_result_t signal_queue_enqueue(signal_queue_t* queue, int sig) {
    if (!queue) {
        return QOSDBA_ERR_MEMORY;
    }
    
    pthread_mutex_lock(&queue->signal_mutex);
    
    if (queue->signal_count >= 10) {
        pthread_mutex_unlock(&queue->signal_mutex);
        return QOSDBA_ERR_SIGNAL;
    }
    
    queue->signals[queue->signal_write_index] = sig;
    queue->signal_write_index = (queue->signal_write_index + 1) % 10;
    queue->signal_count++;
    
    pthread_cond_signal(&queue->signal_cond);
    pthread_mutex_unlock(&queue->signal_mutex);
    
    return QOSDBA_OK;
}

int signal_queue_dequeue(signal_queue_t* queue) {
    if (!queue || queue->signal_count == 0) {
        return 0;
    }
    
    pthread_mutex_lock(&queue->signal_mutex);
    
    if (queue->signal_count == 0) {
        pthread_mutex_unlock(&queue->signal_mutex);
        return 0;
    }
    
    int sig = queue->signals[queue->signal_read_index];
    queue->signal_read_index = (queue->signal_read_index + 1) % 10;
    queue->signal_count--;
    
    pthread_mutex_unlock(&queue->signal_mutex);
    return sig;
}

int signal_queue_peek(signal_queue_t* queue) {
    if (!queue || queue->signal_count == 0) {
        return 0;
    }
    
    pthread_mutex_lock(&queue->signal_mutex);
    int sig = queue->signals[queue->signal_read_index];
    pthread_mutex_unlock(&queue->signal_mutex);
    
    return sig;
}

/* ==================== 信号处理函数 ==================== */

static void signal_handler(int sig) {
    /* 写入管道通知信号处理线程 */
    if (g_signal_pipe[1] >= 0) {
        char c = (char)sig;
        write(g_signal_pipe[1], &c, 1);
    }
}

static void* signal_processing_thread(void* arg) {
    qosdba_context_t* ctx = (qosdba_context_t*)arg;
    char buffer[10];
    
    while (!atomic_load(&ctx->should_exit)) {
        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(g_signal_pipe[0], &readfds);
        
        struct timeval timeout = {1, 0};  /* 1秒超时 */
        
        int ret = select(g_signal_pipe[0] + 1, &readfds, NULL, NULL, &timeout);
        
        if (ret > 0 && FD_ISSET(g_signal_pipe[0], &readfds)) {
            ssize_t bytes = read(g_signal_pipe[0], buffer, sizeof(buffer));
            for (ssize_t i = 0; i < bytes; i++) {
                int sig = buffer[i];
                
                switch (sig) {
                    case SIGTERM:
                    case SIGINT:
                    case SIGQUIT:
                        atomic_store(&ctx->should_exit, 1);
                        log_message(ctx, "INFO", "收到退出信号 %d\n", sig);
                        break;
                    case SIGHUP:
                        ctx->reload_config = 1;
                        log_message(ctx, "INFO", "收到SIGHUP信号，准备重新加载配置\n");
                        break;
                    case SIGUSR1:
                        log_message(ctx, "INFO", "收到SIGUSR1信号，输出状态信息\n");
                        /* 状态输出逻辑在main.c中处理 */
                        break;
                    case SIGUSR2:
                        ctx->debug_mode = !ctx->debug_mode;
                        log_message(ctx, "INFO", "收到SIGUSR2信号，切换调试模式: %s\n", 
                                   ctx->debug_mode ? "启用" : "禁用");
                        break;
                }
            }
        }
    }
    
    return NULL;
}

qosdba_result_t setup_signal_handlers(qosdba_context_t* ctx) {
    /* 创建管道用于信号通信 */
    if (pipe(g_signal_pipe) < 0) {
        return QOSDBA_ERR_SYSTEM;
    }
    
    /* 设置管道为非阻塞 */
    fcntl(g_signal_pipe[0], F_SETFL, O_NONBLOCK);
    fcntl(g_signal_pipe[1], F_SETFL, O_NONBLOCK);
    
    /* 设置信号处理器 */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sa.sa_flags = SA_RESTART;
    sigemptyset(&sa.sa_mask);
    
    /* 注册需要处理的信号 */
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGQUIT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGUSR1, &sa, NULL);
    sigaction(SIGUSR2, &sa, NULL);
    
    /* 忽略不需要的信号 */
    signal(SIGPIPE, SIG_IGN);
    signal(SIGALRM, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);
    
    /* 启动信号处理线程 */
    if (pthread_create(&g_signal_thread, NULL, signal_processing_thread, ctx) != 0) {
        close(g_signal_pipe[0]);
        close(g_signal_pipe[1]);
        g_signal_pipe[0] = g_signal_pipe[1] = -1;
        return QOSDBA_ERR_THREAD;
    }
    
    pthread_setname_np(g_signal_thread, "qosdba-signal");
    
    return QOSDBA_OK;
}

void cleanup_signal_handlers(qosdba_context_t* ctx) {
    /* 等待信号线程结束 */
    if (g_signal_thread) {
        pthread_join(g_signal_thread, NULL);
        g_signal_thread = 0;
    }
    
    /* 关闭管道 */
    if (g_signal_pipe[0] >= 0) {
        close(g_signal_pipe[0]);
        g_signal_pipe[0] = -1;
    }
    if (g_signal_pipe[1] >= 0) {
        close(g_signal_pipe[1]);
        g_signal_pipe[1] = -1;
    }
    
    /* 清理信号队列 */
    signal_queue_cleanup(&ctx->signal_queue);
}

/* ==================== 优雅退出机制 ==================== */

qosdba_result_t qosdba_shutdown(qosdba_context_t* ctx, int graceful) {
    if (!ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    if (graceful) {
        log_message(ctx, "INFO", "开始优雅关闭...\n");
        
        /* 1. 停止接受新任务 */
        atomic_store(&ctx->should_exit, 1);
        
        /* 2. 等待处理中的任务完成（如果有） */
        usleep(100000);  /* 100ms */
        
        /* 3. 清理资源 */
        qosdba_cleanup(ctx);
        
        log_message(ctx, "INFO", "优雅关闭完成\n");
    } else {
        log_message(ctx, "INFO", "立即关闭\n");
        qosdba_cleanup(ctx);
    }
    
    return QOSDBA_OK;
}

/* ==================== 清理函数 ==================== */

qosdba_result_t qosdba_cleanup(qosdba_context_t* ctx) {
    if (!ctx) {
        return QOSDBA_ERR_MEMORY;
    }
    
    log_message(ctx, "INFO", "清理资源...\n");
    
    /* 清理信号处理 */
    cleanup_signal_handlers(ctx);
    
    /* 关闭网络连接 */
    pthread_mutex_lock(&ctx->rth_mutex);
    
    if (ctx->shared_rth.fd >= 0 && ctx->shared_rth_refcount == 0) {
        rtnl_close(&ctx->shared_rth);
        ctx->shared_rth.fd = -1;
    }
    
    pthread_mutex_unlock(&ctx->rth_mutex);
    
    /* 清理设备资源 */
    for (int i = 0; i < ctx->num_devices; i++) {
        device_context_t* dev_ctx = &ctx->devices[i];
        
        if (dev_ctx->enabled) {
            close_device_netlink(dev_ctx, ctx);
        }
        
        cleanup_batch_commands(&dev_ctx->batch_cmds);
        
        if (dev_ctx->async_monitor.async_enabled) {
            if (dev_ctx->async_monitor.epoll_fd >= 0) {
                close(dev_ctx->async_monitor.epoll_fd);
            }
            if (dev_ctx->async_monitor.inotify_fd >= 0) {
                if (dev_ctx->async_monitor.watch_fd >= 0) {
                    inotify_rm_watch(dev_ctx->async_monitor.inotify_fd, 
                                     dev_ctx->async_monitor.watch_fd);
                }
                close(dev_ctx->async_monitor.inotify_fd);
            }
        }
        
        pthread_mutex_destroy(&dev_ctx->tc_cache.cache_mutex);
    }
    
    /* 清理新设备数组（如果存在） */
    if (ctx->new_devices) {
        free(ctx->new_devices);
        ctx->new_devices = NULL;
    }
    
    /* 清理同步原语 */
    pthread_mutex_destroy(&ctx->rth_mutex);
    pthread_spin_destroy(&ctx->ctx_lock);
    
    /* 关闭文件 */
    if (ctx->status_file && ctx->status_file != stdout && ctx->status_file != stderr) {
        fclose(ctx->status_file);
    }
    
    if (ctx->log_file && ctx->log_file != stdout && ctx->log_file != stderr) {
        fclose(ctx->log_file);
    }
    
    /* 清空上下文 */
    memset(ctx, 0, sizeof(qosdba_context_t));
    
    return QOSDBA_OK;
}