#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include "qosdba.h"

static volatile int running = 1;

void signal_handler(int sig) {
    running = 0;
}

int main(int argc, char* argv[]) {
    if (argc != 4) {
        fprintf(stderr, "用法: %s <配置文件> <网络设备> <总带宽(kbps)>\n", argv[0]);
        return 1;
    }
    
    const char* config_file = argv[1];
    const char* device = argv[2];
    int total_bandwidth_kbps = atoi(argv[3]);
    
    if (total_bandwidth_kbps <= 0) {
        fprintf(stderr, "错误: 总带宽必须大于0\n");
        return 1;
    }
    
    // 设置信号处理
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // 初始化上下文
    qosdba_context_t ctx;
    qosdba_result_t ret = qosdba_init(&ctx, config_file, device, total_bandwidth_kbps);
    
    if (ret != QOSDBA_OK) {
        fprintf(stderr, "初始化失败: %d\n", ret);
        return 1;
    }
    
    // 启用调试模式
    qosdba_set_debug(&ctx, 1);
    
    printf("QoS动态带宽分配器启动成功\n");
    printf("配置文件: %s\n", config_file);
    printf("网络设备: %s\n", device);
    printf("总带宽: %d kbps\n", total_bandwidth_kbps);
    printf("分类数量: %d\n", ctx.num_classes);
    printf("按Ctrl+C退出...\n\n");
    
    // 主循环
    while (running) {
        // 运行一次检查
        ret = qosdba_run(&ctx);
        
        if (ret != QOSDBA_OK) {
            fprintf(stderr, "运行错误: %d\n", ret);
        }
        
        // 更新状态文件
        qosdba_update_status(&ctx, "/tmp/qosdba.status");
        
        // 每秒运行一次
        sleep(1);
    }
    
    // 清理资源
    qosdba_cleanup(&ctx);
    
    printf("\nQoS动态带宽分配器已退出\n");
    
    return 0;
}