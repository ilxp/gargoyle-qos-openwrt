#include "qos_dba.h"
#include <sys/wait.h>
#include <fcntl.h>
#include <errno.h>
#include <ctype.h>

// 执行shell命令
int execute_command(const char *cmd, char *output, int output_len) {
    if (!cmd) return -1;
    
    FILE *fp = popen(cmd, "r");
    if (!fp) {
        DEBUG_LOG("执行命令失败: %s", cmd);
        return -1;
    }
    
    if (output && output_len > 0) {
        // 读取输出
        size_t bytes_read = 0;
        char buffer[128];
        
        while (fgets(buffer, sizeof(buffer), fp) != NULL) {
            int len = strlen(buffer);
            if (bytes_read + len < (size_t)output_len) {
                strcpy(output + bytes_read, buffer);
                bytes_read += len;
            } else {
                break;
            }
        }
        
        if (bytes_read > 0 && output[bytes_read-1] == '\n') {
            output[bytes_read-1] = '\0';
        }
    }
    
    int status = pclose(fp);
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    
    return -1;
}

// 解析TC速率字符串
static int parse_tc_rate_string(const char *rate_str) {
    if (!rate_str) return 0;
    
    char *endptr;
    double value = strtod(rate_str, &endptr);
    
    if (endptr == rate_str) return 0;
    
    // 跳过空格
    while (*endptr && isspace(*endptr)) endptr++;
    
    if (*endptr == '\0') {
        return (int)value;  // 假设是kbps
    }
    
    char unit = tolower(*endptr);
    
    switch (unit) {
        case 'k':  // kbit
            return (int)value;
        case 'm':  // mbit
            return (int)(value * 1000);
        case 'g':  // gbit
            return (int)(value * 1000000);
        default:
            return (int)value;
    }
}

// 获取TC分类的使用率
float get_class_usage_rate(const char *iface, const char *classid) {
    if (!iface || !classid) return 0.0f;
    
    char cmd[512];
    char output[1024] = {0};
    
    // 获取当前速率
    snprintf(cmd, sizeof(cmd), 
             "tc -s class show dev %s 2>/dev/null | "
             "grep -A 2 'class htb %s' | "
             "grep -o 'rate [0-9]\\+[kmgt]\\?bit' | "
             "head -1", iface, classid);
    
    if (execute_command(cmd, output, sizeof(output)) != 0) {
        DEBUG_LOG("获取分类 %s 速率失败", classid);
        return 0.0f;
    }
    
    // 解析速率
    int rate_kbps = 0;
    if (strlen(output) > 0) {
        char *rate_str = strchr(output, ' ');
        if (rate_str) {
            rate_str++;
            char *newline = strchr(rate_str, '\n');
            if (newline) *newline = '\0';
            rate_kbps = parse_tc_rate_string(rate_str);
        }
    }
    
    if (rate_kbps <= 0) {
        DEBUG_LOG("分类 %s 无效速率: %s", classid, output);
        return 0.0f;
    }
    
    // 获取已用带宽
    memset(output, 0, sizeof(output));
    snprintf(cmd, sizeof(cmd), 
             "tc -s -d class show dev %s 2>/dev/null | "
             "awk '/class htb %s/{getline; getline; print $2}'", 
             iface, classid);
    
    if (execute_command(cmd, output, sizeof(output)) != 0) {
        DEBUG_LOG("获取分类 %s 已用带宽失败", classid);
        return 0.0f;
    }
    
    long long bytes = 0;
    if (strlen(output) > 0) {
        bytes = atoll(output);
    }
    
    // 转换为kbps（假设最近1秒）
    int used_kbps = (int)(bytes * 8 / 1000.0);
    
    // 计算使用率
    if (rate_kbps > 0) {
        float usage = (float)used_kbps / rate_kbps;
        if (usage > 1.0f) usage = 1.0f;
        if (usage < 0.0f) usage = 0.0f;
        return usage;
    }
    
    return 0.0f;
}

// 获取分类使用带宽(kbps)
int get_class_used_kbps(const char *iface, const char *classid) {
    if (!iface || !classid) return 0;
    
    char cmd[512];
    char output[1024] = {0};
    
    snprintf(cmd, sizeof(cmd), 
             "tc -s -d class show dev %s 2>/dev/null | "
             "awk '/class htb %s/{getline; getline; print $2}'", 
             iface, classid);
    
    if (execute_command(cmd, output, sizeof(output)) != 0) {
        return 0;
    }
    
    if (strlen(output) > 0) {
        long long bytes = atoll(output);
        // 转换为kbps
        return (int)(bytes * 8 / 1000.0);
    }
    
    return 0;
}

// 调整TC分类带宽
int adjust_tc_class_bandwidth(const char *iface, const char *classid, int new_kbps) {
    if (!iface || !classid || new_kbps <= 0) {
        DEBUG_LOG("无效参数: iface=%s, classid=%s, kbps=%d", 
                 iface ? iface : "NULL", 
                 classid ? classid : "NULL", 
                 new_kbps);
        return -1;
    }
    
    char cmd[512];
    
    // 检查分类是否存在
    snprintf(cmd, sizeof(cmd), 
             "tc class show dev %s 2>/dev/null | grep -q 'class htb %s'", 
             iface, classid);
    
    if (execute_command(cmd, NULL, 0) != 0) {
        DEBUG_LOG("分类 %s 不存在于接口 %s", classid, iface);
        return -1;
    }
    
    // 获取当前TC配置
    snprintf(cmd, sizeof(cmd), 
             "tc class show dev %s 2>/dev/null | grep 'class htb %s' | head -1", 
             iface, classid);
    
    char output[1024] = {0};
    if (execute_command(cmd, output, sizeof(output)) != 0) {
        DEBUG_LOG("无法获取分类 %s 的TC配置", classid);
        return -1;
    }
    
    if (strlen(output) == 0) {
        DEBUG_LOG("分类 %s 不存在", classid);
        return -1;
    }
    
    // 从当前配置中提取参数
    char *burst = "15k";
    char *cburst = "15k";
    char *prio = "0";
    
    char *token = strtok(output, " ");
    while (token) {
        if (strcmp(token, "burst") == 0) {
            token = strtok(NULL, " ");
            if (token) burst = token;
        } else if (strcmp(token, "cburst") == 0) {
            token = strtok(NULL, " ");
            if (token) cburst = token;
        } else if (strcmp(token, "prio") == 0) {
            token = strtok(NULL, " ");
            if (token) prio = token;
        }
        token = strtok(NULL, " ");
    }
    
    // 构建tc命令
    snprintf(cmd, sizeof(cmd), 
             "tc class change dev %s parent 1: classid %s htb "
             "rate %dkbit ceil %dkbit burst %s cburst %s prio %s 2>&1", 
             iface, classid, new_kbps, new_kbps, burst, cburst, prio);
    
    char result[1024] = {0};
    int ret = execute_command(cmd, result, sizeof(result));
    
    if (ret != 0) {
        DEBUG_LOG("tc class change失败: %s", result);
        
        // 尝试replace
        snprintf(cmd, sizeof(cmd), 
                 "tc class replace dev %s parent 1: classid %s htb "
                 "rate %dkbit ceil %dkbit burst %s cburst %s prio %s 2>&1", 
                 iface, classid, new_kbps, new_kbps, burst, cburst, prio);
        
        ret = execute_command(cmd, result, sizeof(result));
    }
    
    if (ret == 0) {
        DEBUG_LOG("调整TC分类 %s 带宽为 %d kbps 成功", classid, new_kbps);
    } else {
        DEBUG_LOG("调整TC分类 %s 带宽为 %d kbps 失败: %s", classid, new_kbps, result);
    }
    
    return ret;
}