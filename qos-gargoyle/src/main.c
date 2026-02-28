#include "qos_dba.h"
#include <signal.h>

static volatile int g_running = 1;

// 信号处理
static void signal_handler(int sig) {
    DEBUG_LOG("收到信号 %d, 准备退出", sig);
    g_running = 0;
    qos_dba_stop();
}

// 打印使用说明
static void print_usage(const char *program_name) {
    printf("用法: %s [选项]\n", program_name);
    printf("选项:\n");
    printf("  -c <文件>    配置文件路径 (默认: /etc/config/qos_gargoyle)\n");
    printf("  -v           详细输出模式\n");
    printf("  -s           打印状态\n");
    printf("  -r           重新加载配置\n");
    printf("  -h           显示此帮助信息\n");
    printf("\n示例:\n");
    printf("  %s -c /etc/config/qos_gargoyle -v\n", program_name);
    printf("  %s -s\n", program_name);
    printf("  %s -r\n", program_name);
}

int main(int argc, char *argv[]) {
    const char *config_path = "/etc/config/qos_gargoyle";
    int verbose = 0;
    int show_status = 0;
    int reload_config = 0;
    
    // 解析命令行参数
    int opt;
    while ((opt = getopt(argc, argv, "c:vsrh")) != -1) {
        switch (opt) {
            case 'c':
                config_path = optarg;
                break;
            case 'v':
                verbose = 1;
                break;
            case 's':
                show_status = 1;
                break;
            case 'r':
                reload_config = 1;
                break;
            case 'h':
            default:
                print_usage(argv[0]);
                return 0;
        }
    }
    
    // 设置信号处理
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGQUIT, signal_handler);
    
    printf("QoS动态带宽调整系统 v1.0\n");
    printf("配置文件: %s\n", config_path);
    
    // 初始化
    if (qos_dba_init(config_path) != 0) {
        fprintf(stderr, "初始化失败\n");
        return 1;
    }
    
    // 设置详细输出
    if (verbose) {
        qos_dba_set_verbose(1);
    }
    
    // 如果只显示状态
    if (show_status) {
        qos_dba_print_status();
        return 0;
    }
    
    // 如果重新加载配置
    if (reload_config) {
        if (qos_dba_reload_config() == 0) {
            printf("配置重新加载成功\n");
        } else {
            fprintf(stderr, "重新加载配置失败\n");
        }
        qos_dba_print_status();
        return 0;
    }
    
    // 启动DBA
    if (qos_dba_start() != 0) {
        fprintf(stderr, "启动失败\n");
        return 1;
    }
    
    printf("QoS DBA已启动，按Ctrl+C退出\n");
    
    // 主循环
    while (g_running) {
        sleep(1);
    }
    
    printf("\n正在清理资源...\n");
    
    // 停止DBA
    qos_dba_stop();
    
    // 清理
    if (g_qos_system.upload_classes) {
        free(g_qos_system.upload_classes);
    }
    if (g_qos_system.download_classes) {
        free(g_qos_system.download_classes);
    }
    
    pthread_mutex_destroy(&g_qos_system.mutex);
    
    printf("退出完成\n");
    return 0;
}