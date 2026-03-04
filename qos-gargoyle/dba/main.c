#include "qos_dba.h"
#include <signal.h>
#include <getopt.h>
#include <string.h>

static volatile int g_running = 1;

// 信号处理
static void signal_handler(int sig) {
    DEBUG_LOG("收到信号 %d，正在关闭...", sig);
    g_running = 0;
    qos_dba_stop();
}

// 显示使用帮助
static void show_usage(const char *progname) {
    printf("用法: %s [选项]\n", progname);
    printf("选项:\n");
    printf("  -h, --help          显示此帮助信息\n");
    printf("  -v, --verbose       详细输出模式\n");
    printf("  -c, --config FILE   指定配置文件路径 (默认: /etc/config/qos_gargoyle)\n");
    printf("  -d, --daemon        以守护进程模式运行\n");
    printf("  -s, --status        显示状态后退出\n");
    printf("  -r, --reload        重新加载配置\n");
    printf("  -i, --interface IF  指定WAN接口 (默认自动检测)\n");
    printf("  -b, --bandwidth BW  指定总带宽 (如: 100M, 10M, 1G)\n");
    printf("  -o, --once          运行一次监控调整后退出\n");
    printf("\n示例:\n");
    printf("  %s -v -c /etc/config/qos_gargoyle\n", progname);
    printf("  %s -d -b 100M\n", progname);
    printf("  %s -s\n", progname);
}

// 守护进程化
static int daemonize(void) {
    pid_t pid = fork();
    
    if (pid < 0) {
        DEBUG_LOG("fork失败: %s", strerror(errno));
        return -1;
    }
    
    if (pid > 0) {
        // 父进程退出
        exit(0);
    }
    
    // 子进程继续
    if (setsid() < 0) {
        DEBUG_LOG("setsid失败: %s", strerror(errno));
        return -1;
    }
    
    signal(SIGHUP, SIG_IGN);
    
    pid = fork();
    if (pid < 0) {
        DEBUG_LOG("第二次fork失败: %s", strerror(errno));
        return -1;
    }
    
    if (pid > 0) {
        exit(0);
    }
    
    // 更改工作目录
    chdir("/");
    
    // 关闭标准文件描述符
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    
    // 重定向到/dev/null
    int fd = open("/dev/null", O_RDWR);
    if (fd != -1) {
        dup2(fd, STDIN_FILENO);
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        close(fd);
    }
    
    return 0;
}

int main(int argc, char *argv[]) {
    int opt;
    int verbose = 0;
    int daemon = 0;
    int status_only = 0;
    int reload_config = 0;
    int run_once = 0;
    const char *config_path = NULL;
    const char *interface = NULL;
    const char *bandwidth = NULL;
    
    static struct option long_options[] = {
        {"help", no_argument, 0, 'h'},
        {"verbose", no_argument, 0, 'v'},
        {"config", required_argument, 0, 'c'},
        {"daemon", no_argument, 0, 'd'},
        {"status", no_argument, 0, 's'},
        {"reload", no_argument, 0, 'r'},
        {"interface", required_argument, 0, 'i'},
        {"bandwidth", required_argument, 0, 'b'},
        {"once", no_argument, 0, 'o'},
        {0, 0, 0, 0}
    };
    
    while ((opt = getopt_long(argc, argv, "hvc:dsri:b:o", long_options, NULL)) != -1) {
        switch (opt) {
            case 'h':
                show_usage(argv[0]);
                return 0;
                
            case 'v':
                verbose = 1;
                break;
                
            case 'c':
                config_path = optarg;
                break;
                
            case 'd':
                daemon = 1;
                break;
                
            case 's':
                status_only = 1;
                break;
                
            case 'r':
                reload_config = 1;
                break;
                
            case 'i':
                interface = optarg;
                break;
                
            case 'b':
                bandwidth = optarg;
                break;
                
            case 'o':
                run_once = 1;
                break;
                
            default:
                fprintf(stderr, "未知选项\n");
                show_usage(argv[0]);
                return 1;
        }
    }
    
    // 设置信号处理
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGQUIT, signal_handler);
    
    if (reload_config) {
        // 重新加载配置模式
        if (qos_dba_init(config_path) != 0) {
            fprintf(stderr, "初始化失败\n");
            return 1;
        }
        
        if (qos_dba_reload_config() != 0) {
            fprintf(stderr, "重新加载配置失败\n");
            return 1;
        }
        
        printf("配置重新加载成功\n");
        qos_dba_print_status();
        return 0;
    }
    
    if (status_only) {
        // 状态显示模式
        if (qos_dba_init(config_path) != 0) {
            fprintf(stderr, "初始化失败\n");
            return 1;
        }
        
        qos_dba_print_status();
        return 0;
    }
    
    printf("QoS 动态带宽分配 (DBA) 系统 v1.0\n");
    printf("=====================================\n");
    
    // 初始化
    if (qos_dba_init(config_path) != 0) {
        fprintf(stderr, "初始化失败\n");
        return 1;
    }
    
    // 设置详细输出
    qos_dba_set_verbose(verbose);
    
    // 手动指定接口
    if (interface) {
        strncpy(g_qos_system.wan_interface, interface, MAX_IFACE_LEN-1);
        g_qos_system.wan_interface[MAX_IFACE_LEN-1] = '\0';
        DEBUG_LOG("手动设置WAN接口: %s", interface);
    }
    
    // 手动指定带宽
    if (bandwidth) {
        int bw = parse_bandwidth_string(bandwidth);
        if (bw > 0) {
            g_qos_system.total_bandwidth_kbps = bw;
            DEBUG_LOG("手动设置总带宽: %s (%d kbps)", bandwidth, bw);
        } else {
            fprintf(stderr, "无效的带宽值: %s\n", bandwidth);
            return 1;
        }
    }
    
    if (run_once) {
        // 单次运行模式
        printf("运行单次监控调整...\n");
        qos_dba_print_status();
        
        // 监控
        monitor_all_classes();
        
        // 调整
        int upload_adj = adjust_upload_classes();
        int download_adj = adjust_download_classes();
        int returned = auto_return_borrowed_bandwidth();
        
        printf("\n调整结果:\n");
        printf("  上传分类调整: %d 次\n", upload_adj);
        printf("  下载分类调整: %d 次\n", download_adj);
        printf("  自动归还: %d kbps\n", returned);
        
        qos_dba_print_status();
        return 0;
    }
    
    if (daemon) {
        printf("以守护进程模式启动...\n");
        if (daemonize() != 0) {
            fprintf(stderr, "守护进程化失败\n");
            return 1;
        }
    }
    
    // 启动DBA
    if (qos_dba_start() != 0) {
        fprintf(stderr, "启动DBA失败\n");
        return 1;
    }
    
    printf("QoS DBA 已启动，按 Ctrl+C 停止\n");
    
    // 主循环
    g_running = 1;
    while (g_running) {
        if (!daemon) {
            // 在非守护进程模式下，可以处理其他任务
            sleep(1);
        } else {
            // 守护进程模式，等待信号
            pause();
        }
    }
    
    // 清理
    qos_dba_stop();
    
    printf("\nQoS DBA 已停止\n");
    return 0;
}