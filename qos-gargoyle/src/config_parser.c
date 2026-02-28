#include "qos_dba.h"
#include <ctype.h>

qos_system_t g_qos_system = {0};

// 去除字符串首尾空白字符
char *trim_whitespace(char *str) {
    if (!str) return NULL;
    
    char *end;
    
    // 去除前导空白
    while (isspace((unsigned char)*str)) str++;
    
    if (*str == 0) return str;
    
    // 去除尾部空白
    end = str + strlen(str) - 1;
    while (end > str && isspace((unsigned char)*end)) end--;
    
    end[1] = '\0';
    
    return str;
}

// 判断字符串是否为数字
int is_numeric_string(const char *str) {
    if (!str || *str == '\0') return 0;
    
    while (*str) {
        if (!isdigit((unsigned char)*str)) return 0;
        str++;
    }
    return 1;
}

// 解析带宽字符串
int parse_bandwidth_string(const char *str) {
    if (!str) return 0;
    
    char *endptr;
    long value = strtol(str, &endptr, 10);
    
    if (endptr == str) {
        // 尝试解析科学计数法
        if (strstr(str, "kbps") || strstr(str, "kbit")) {
            sscanf(str, "%ld", &value);
            return value;  // 已经是kbps
        }
        return 0;
    }
    
    if (strstr(endptr, "mbit") || strstr(endptr, "Mbit") || 
        strstr(endptr, "mbps") || strstr(endptr, "Mbps")) {
        return value * 1000;  // Mbps转kbps
    } else if (strstr(endptr, "gbit") || strstr(endptr, "Gbit") || 
               strstr(endptr, "gbps") || strstr(endptr, "Gbps")) {
        return value * 1000000;  // Gbps转kbps
    } else if (strstr(endptr, "kbit") || strstr(endptr, "Kbit") || 
               strstr(endptr, "kbps") || strstr(endptr, "Kbps")) {
        return value;  // 已经是kbps
    } else {
        // 默认为kbps
        return value;
    }
}

// 从字符串读取整数配置
static int get_int_option(const char *line, int default_val) {
    char *start = strstr(line, "'");
    if (!start) return default_val;
    
    start++;  // 跳过单引号
    char *end = strchr(start, '\'');
    if (!end) return default_val;
    
    char value_str[32] = {0};
    int len = end - start;
    if (len >= sizeof(value_str)) len = sizeof(value_str) - 1;
    strncpy(value_str, start, len);
    value_str[len] = '\0';
    
    return atoi(value_str);
}

// 从字符串读取浮点数配置
static float get_float_option(const char *line, float default_val) {
    char *start = strstr(line, "'");
    if (!start) return default_val;
    
    start++;  // 跳过单引号
    char *end = strchr(start, '\'');
    if (!end) return default_val;
    
    char value_str[32] = {0};
    int len = end - start;
    if (len >= sizeof(value_str)) len = sizeof(value_str) - 1;
    strncpy(value_str, start, len);
    value_str[len] = '\0';
    
    return atof(value_str);
}

// 从qos_gargoyle配置文件读取DBA参数
static int load_dba_config(const char *config_path) {
    FILE *fp = fopen(config_path, "r");
    if (!fp) {
        DEBUG_LOG("无法打开配置文件: %s", config_path);
        return -1;
    }
    
    dba_config_t *config = &g_qos_system.config;
    
    // 设置默认值
    config->enabled = 0;
    config->interval = 1;
    config->min_change_kbps = 64;
    config->high_usage_threshold = 90;
    config->high_usage_duration = 5;
    config->low_usage_threshold = 50;
    config->low_usage_duration = 5;
    config->borrow_ratio = 0.2f;
    config->min_borrow_kbps = 64;
    config->cooldown_time = 5;
    config->auto_return_enable = 1;
    config->return_threshold = 60;
    config->return_speed = 0.1f;
    
    char line[512];
    int in_dba_section = 0;
    
    while (fgets(line, sizeof(line), fp)) {
        char *trimmed = trim_whitespace(line);
        
        // 跳过空行和注释
        if (trimmed[0] == '\0' || trimmed[0] == '#') {
            continue;
        }
        
        // 检测DBA配置节
        if (strstr(trimmed, "config dba 'dba") || strstr(trimmed, "config dba 'dba'")) {
            in_dba_section = 1;
            continue;
        }
        
        if (in_dba_section) {
            // 检测配置节结束
            if (strstr(trimmed, "config ") && !strstr(trimmed, "option")) {
                in_dba_section = 0;
                continue;
            }
            
            // 解析选项
            if (strstr(trimmed, "option enabled")) {
                config->enabled = get_int_option(trimmed, 0);
            } else if (strstr(trimmed, "option interval")) {
                config->interval = get_int_option(trimmed, 1);
            } else if (strstr(trimmed, "option min_change_kbps")) {
                config->min_change_kbps = get_int_option(trimmed, 64);
            } else if (strstr(trimmed, "option high_usage_threshold")) {
                config->high_usage_threshold = get_int_option(trimmed, 90);
            } else if (strstr(trimmed, "option high_usage_duration")) {
                config->high_usage_duration = get_int_option(trimmed, 5);
            } else if (strstr(trimmed, "option low_usage_threshold")) {
                config->low_usage_threshold = get_int_option(trimmed, 50);
            } else if (strstr(trimmed, "option low_usage_duration")) {
                config->low_usage_duration = get_int_option(trimmed, 5);
            } else if (strstr(trimmed, "option borrow_ratio")) {
                config->borrow_ratio = get_float_option(trimmed, 0.2f);
            } else if (strstr(trimmed, "option min_borrow_kbps")) {
                config->min_borrow_kbps = get_int_option(trimmed, 64);
            } else if (strstr(trimmed, "option cooldown_time")) {
                config->cooldown_time = get_int_option(trimmed, 5);
            } else if (strstr(trimmed, "option auto_return_enable")) {
                config->auto_return_enable = get_int_option(trimmed, 1);
            } else if (strstr(trimmed, "option return_threshold")) {
                config->return_threshold = get_int_option(trimmed, 60);
            } else if (strstr(trimmed, "option return_speed")) {
                config->return_speed = get_float_option(trimmed, 0.1f);
            }
        }
    }
    
    fclose(fp);
    
    DEBUG_LOG("DBA配置加载成功: enabled=%d, interval=%d", 
              config->enabled, config->interval);
    return 0;
}

// 从qos_gargoyle配置文件读取分类定义
static int load_qos_classes(const char *config_path) {
    FILE *fp = fopen(config_path, "r");
    if (!fp) {
        DEBUG_LOG("无法打开配置文件: %s", config_path);
        return -1;
    }
    
    // 分配内存
    g_qos_system.upload_classes = calloc(MAX_CLASSES, sizeof(qos_class_t));
    g_qos_system.download_classes = calloc(MAX_CLASSES, sizeof(qos_class_t));
    
    if (!g_qos_system.upload_classes || !g_qos_system.download_classes) {
        DEBUG_LOG("内存分配失败");
        fclose(fp);
        return -1;
    }
    
    char line[512];
    qos_class_t temp_class = {0};
    int in_upload_class = 0;
    int in_download_class = 0;
    
    while (fgets(line, sizeof(line), fp)) {
        char *trimmed = trim_whitespace(line);
        
        // 跳过空行和注释
        if (trimmed[0] == '\0' || trimmed[0] == '#') {
            continue;
        }
        
        // 检测上传分类
        if (strstr(trimmed, "config upload_class")) {
            if (in_upload_class || in_download_class) {
                // 保存上一个分类
                if (in_upload_class) {
                    if (g_qos_system.upload_class_count < MAX_CLASSES) {
                        g_qos_system.upload_classes[g_qos_system.upload_class_count++] = temp_class;
                    }
                } else if (in_download_class) {
                    if (g_qos_system.download_class_count < MAX_CLASSES) {
                        g_qos_system.download_classes[g_qos_system.download_class_count++] = temp_class;
                    }
                }
            }
            
            memset(&temp_class, 0, sizeof(temp_class));
            in_upload_class = 1;
            in_download_class = 0;
            temp_class.direction = 0;  // 上传
            continue;
        }
        
        // 检测下载分类
        if (strstr(trimmed, "config download_class")) {
            if (in_upload_class || in_download_class) {
                // 保存上一个分类
                if (in_upload_class) {
                    if (g_qos_system.upload_class_count < MAX_CLASSES) {
                        g_qos_system.upload_classes[g_qos_system.upload_class_count++] = temp_class;
                    }
                } else if (in_download_class) {
                    if (g_qos_system.download_class_count < MAX_CLASSES) {
                        g_qos_system.download_classes[g_qos_system.download_class_count++] = temp_class;
                    }
                }
            }
            
            memset(&temp_class, 0, sizeof(temp_class));
            in_upload_class = 0;
            in_download_class = 1;
            temp_class.direction = 1;  // 下载
            continue;
        }
        
        // 解析分类选项
        if (in_upload_class || in_download_class) {
            if (strstr(trimmed, "option name")) {
                char *start = strstr(trimmed, "'");
                if (start) {
                    start++;
                    char *end = strchr(start, '\'');
                    if (end) {
                        int len = end - start;
                        if (len >= MAX_NAME_LEN) len = MAX_NAME_LEN - 1;
                        strncpy(temp_class.name, start, len);
                        temp_class.name[len] = '\0';
                        
                        // 设置优先级
                        if (strcmp(temp_class.name, "realtime") == 0) {
                            temp_class.priority = 0;
                        } else if (strcmp(temp_class.name, "normal") == 0) {
                            temp_class.priority = 1;
                        } else if (strcmp(temp_class.name, "bulk") == 0) {
                            temp_class.priority = 2;
                        }
                    }
                }
            } else if (strstr(trimmed, "option percent_bandwidth")) {
                temp_class.config_percent = get_int_option(trimmed, 0);
            } else if (strstr(trimmed, "option min_bandwidth")) {
                char *start = strstr(trimmed, "'");
                if (start) {
                    start++;
                    char *end = strchr(start, '\'');
                    if (end) {
                        char value_str[32] = {0};
                        int len = end - start;
                        if (len >= sizeof(value_str)) len = sizeof(value_str) - 1;
                        strncpy(value_str, start, len);
                        value_str[len] = '\0';
                        temp_class.config_min_kbps = parse_bandwidth_string(value_str);
                    }
                }
            } else if (strstr(trimmed, "option max_bandwidth")) {
                char *start = strstr(trimmed, "'");
                if (start) {
                    start++;
                    char *end = strchr(start, '\'');
                    if (end) {
                        char value_str[32] = {0};
                        int len = end - start;
                        if (len >= sizeof(value_str)) len = sizeof(value_str) - 1;
                        strncpy(value_str, start, len);
                        value_str[len] = '\0';
                        temp_class.config_max_kbps = parse_bandwidth_string(value_str);
                    }
                }
            } else if (strstr(trimmed, "option minRTT")) {
                // 优先级已根据名称设置
            }
        }
    }
    
    // 保存最后一个分类
    if (in_upload_class && g_qos_system.upload_class_count < MAX_CLASSES) {
        g_qos_system.upload_classes[g_qos_system.upload_class_count++] = temp_class;
    } else if (in_download_class && g_qos_system.download_class_count < MAX_CLASSES) {
        g_qos_system.download_classes[g_qos_system.download_class_count++] = temp_class;
    }
    
    fclose(fp);
    
    // 生成classid
    for (int i = 0; i < g_qos_system.upload_class_count; i++) {
        snprintf(g_qos_system.upload_classes[i].classid, MAX_CLASSID_LEN, 
                 "1:%d0", i+1);  // 上传: 1:10, 1:20, 1:30
        g_qos_system.upload_classes[i].current_kbps = 
            g_qos_system.total_bandwidth_kbps * 
            g_qos_system.upload_classes[i].config_percent / 100;
    }
    
    for (int i = 0; i < g_qos_system.download_class_count; i++) {
        snprintf(g_qos_system.download_classes[i].classid, MAX_CLASSID_LEN, 
                 "2:%d0", i+1);  // 下载: 2:10, 2:20, 2:30
        g_qos_system.download_classes[i].current_kbps = 
            g_qos_system.total_bandwidth_kbps * 
            g_qos_system.download_classes[i].config_percent / 100;
    }
    
    DEBUG_LOG("加载分类: 上传%d个, 下载%d个", 
              g_qos_system.upload_class_count, g_qos_system.download_class_count);
    return 0;
}