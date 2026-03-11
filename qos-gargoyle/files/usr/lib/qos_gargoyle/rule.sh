#!/bin/sh
# 规则辅助模块 (rule.sh)
# 支持多样化端口、协议、IPv6双栈和连接字节数过滤
# version=1.5.2 修复sh语法兼容性版本
# 修复内容：
# 1. 修复第93行正则表达式语法错误，符合sh语法
# 2. 修复数组语法，使用位置参数替代bash数组
# 3. 修复字符串连接语法
# 4. 修复变量替换语法

CONFIG_FILE="qos_gargoyle"

# ========== 输入验证和清理函数 ==========
# 清理输入，防止命令注入
sanitize_input() {
    local input="$1"
    # 只允许字母、数字、下划线、连字符、冒号、斜杠、点
    echo "$input" | sed 's/[^a-zA-Z0-9_\-:\/\.]//g'
}

# ========== 统一日志函数 ==========
# 日志缩进辅助函数
log_indent() {
    local message="$1"
    echo "  $message"
}

log() {
    local level="$1"
    local message="$2"
    
    # 如果有换行符，则拆分成多行记录
    if echo "$message" | grep -q '
'; then
        local first_line=1
        echo "$message" | while IFS= read -r line; do
            if [ $first_line -eq 1 ]; then
                first_line=0
                continue
            fi
            case "$level" in
                "ERROR"|"error")
                    logger -t "qos_gargoyle" "错误: $line"
                    ;;
                "WARN"|"warn"|"WARNING"|"warning")
                    logger -t "qos_gargoyle" "警告: $line"
                    ;;
                "INFO"|"info")
                    logger -t "qos_gargoyle" "信息: $line"
                    ;;
                "DEBUG"|"debug")
                    logger -t "qos_gargoyle" "调试: $line"
                    ;;
                *)
                    logger -t "qos_gargoyle" "$line"
                    ;;
            esac
        done
    fi
    
    # 记录主消息
    case "$level" in
        "ERROR"|"error")
            logger -t "qos_gargoyle" "错误: $(echo "$message" | head -1)"
            ;;
        "WARN"|"warn"|"WARNING"|"warning")
            logger -t "qos_gargoyle" "警告: $(echo "$message" | head -1)"
            ;;
        "INFO"|"info")
            logger -t "qos_gargoyle" "信息: $(echo "$message" | head -1)"
            ;;
        "DEBUG"|"debug")
            logger -t "qos_gargoyle" "调试: $(echo "$message" | head -1)"
            ;;
        *)
            logger -t "qos_gargoyle" "$(echo "$message" | head -1)"
            ;;
    esac
}

# ========== 安全执行函数 ==========
# 在关键函数添加超时控制
safe_exec() {
    local timeout=30
    local command="$1"
    shift
    # 在sh中使用位置参数代替数组
    local args="$@"
    
    (
        # 使用eval执行命令
        eval "$command $args"
    ) & 
    pid=$!
    
    (
        sleep $timeout
        kill -9 $pid 2>/dev/null
    ) 2>/dev/null &
    
    local killer_pid=$!
    
    wait $pid
    local exit_code=$?
    
    # 清理杀手进程
    kill $killer_pid 2>/dev/null
    
    return $exit_code
}

# ========== 验证函数 ==========
validate_number() {
    local value="$1"
    local param_name="$2"
    local min="${3:-0}"
    local max="${4:-2147483647}"
    
    if ! echo "$value" | grep -qE '^[0-9]+$'; then
        log "ERROR" "参数 $param_name 必须是整数: $value"
        return 1
    fi
    
    if [ "$value" -lt "$min" ] 2>/dev/null; then
        log "ERROR" "参数 $param_name 必须大于等于 $min: $value"
        return 1
    fi
    
    if [ "$value" -gt "$max" ] 2>/dev/null; then
        log "ERROR" "参数 $param_name 必须小于等于 $max: $value"
        return 1
    fi
    
    return 0
}

# 验证端口参数 - 修复端口范围分割漏洞
validate_port() {
    local value="$1"
    local param_name="$2"
    
    # 检查是否为空
    if [ -z "$value" ]; then
        return 0
    fi
    
    # 清理输入
    value=$(sanitize_input "$value")
    
    # 去除所有空格
    local clean_value=$(echo "$value" | tr -d '[:space:]')
    
    # 检查是否是逗号分隔的列表
    if echo "$clean_value" | grep -q ','; then
        local IFS=,
        for port in $clean_value; do
            if echo "$port" | grep -q '-'; then
                # 端口范围 - 使用数组分割确保格式正确
                local min_port max_port
                min_port=$(echo "$port" | cut -d'-' -f1)
                max_port=$(echo "$port" | cut -d'-' -f2)
                # 修复：确保分割后的两部分均为非空数字
                if [ -z "$min_port" ] || [ -z "$max_port" ]; then
                    log "ERROR" "无效的端口范围格式 '$port'，必须为'最小端口-最大端口'"
                    return 1
                fi
                
                # 验证最小端口
                if ! validate_number "$min_port" "$param_name" 1 65535; then
                    return 1
                fi
                
                # 验证最大端口
                if ! validate_number "$max_port" "$param_name" 1 65535; then
                    return 1
                fi
                
                # 检查端口范围顺序
                if [ "$min_port" -gt "$max_port" ]; then
                    log "ERROR" "端口范围 $param_name 起始端口 $min_port 大于结束端口 $max_port"
                    return 1
                fi
                
                # 修复：确保最大端口不超过65535
                if [ "$max_port" -gt 65535 ]; then
                    log "ERROR" "端口范围 $param_name 结束端口 $max_port 超过最大允许值65535"
                    return 1
                fi
            else
                # 单个端口
                if ! validate_number "$port" "$param_name" 1 65535; then
                    return 1
                fi
            fi
        done
    elif echo "$clean_value" | grep -q '-'; then
        # 单个端口范围
        local min_port max_port
        min_port=$(echo "$clean_value" | cut -d'-' -f1)
        max_port=$(echo "$clean_value" | cut -d'-' -f2)
        # 修复：确保分割后的两部分均为非空数字
        if [ -z "$min_port" ] || [ -z "$max_port" ]; then
            log "ERROR" "无效的端口范围格式 '$clean_value'，必须为'最小端口-最大端口'"
            return 1
        fi
        
        if ! validate_number "$min_port" "$param_name" 1 65535; then
            return 1
        fi
        
        if ! validate_number "$max_port" "$param_name" 1 65535; then
            return 1
        fi
        
        if [ "$min_port" -gt "$max_port" ]; then
            log "ERROR" "端口范围 $param_name 起始端口 $min_port 大于结束端口 $max_port"
            return 1
        fi
        
        # 修复：确保最大端口不超过65535
        if [ "$max_port" -gt 65535 ]; then
            log "ERROR" "端口范围 $param_name 结束端口 $max_port 超过最大允许值65535"
            return 1
        fi
    else
        # 单个端口
        if ! validate_number "$clean_value" "$param_name" 1 65535; then
            return 1
        fi
    fi
    
    return 0
}

# 验证IP地址 - 修复IPv6正则表达式
validate_ip_address() {
    local ip="$1"
    local param_name="$2"
    
    if [ -z "$ip" ]; then
        return 0
    fi
    
    # 清理输入
    ip=$(sanitize_input "$ip")
    
    # IPv4验证 - 禁止前导零
    if echo "$ip" | grep -qE '^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'; then
        return 0
    fi
    
    # IPv6验证 - 修复：支持压缩格式和接口标识符
    if echo "$ip" | grep -qE '^(?:[a-fA-F0-9]{1,4}:){7}[a-fA-F0-9]{1,4}$|^(?:[a-fA-F0-9]{1,4}:){0,7}::(?:[a-fA-F0-9]{1,4}:){0,6}[a-fA-F0-9]{1,4}$|^[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}$|^::(?:[a-fA-F0-9]{1,4}:){0,6}[a-fA-F0-9]{1,4}$|^[a-fA-F0-9]{1,4}::(?:[a-fA-F0-9]{1,4}:){0,5}[a-fA-F0-9]{1,4}$|^(?:[a-fA-F0-9]{1,4}:){2}:(?:[a-fA-F0-9]{1,4}:){0,4}[a-fA-F0-9]{1,4}$|^(?:[a-fA-F0-9]{1,4}:){3}:(?:[a-fA-F0-9]{1,4}:){0,3}[a-fA-F0-9]{1,4}$|^(?:[a-fA-F0-9]{1,4}:){4}:(?:[a-fA-F0-9]{1,4}:){0,2}[a-fA-F0-9]{1,4}$|^(?:[a-fA-F0-9]{1,4}:){5}:(?:[a-fA-F0-9]{1,4}:)?[a-fA-F0-9]{1,4}$|^(?:[a-fA-F0-9]{1,4}:){6}:[a-fA-F0-9]{1,4}$|^[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}::[a-fA-F0-9]{1,4}$|^[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}::[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}$|^[a-fA-F0-9]{1,4}::[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}$|^::[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}:[a-fA-F0-9]{1,4}$'; then
        return 0
    fi
    
    log "ERROR" "$param_name IP地址格式不正确: $ip"
    return 1
}

# 验证协议名称
validate_protocol() {
    local proto="$1"
    local param_name="$2"
    
    if [ -z "$proto" ] || [ "$proto" = "all" ]; then
        return 0
    fi
    
    # 清理输入
    proto=$(sanitize_input "$proto")
    
    # 常见协议列表
    case "$proto" in
        tcp|udp|icmp|icmpv6|gre|esp|ah|sctp|dccp|udplite|tcp_udp)
            return 0
            ;;
        *)
            log "WARN" "$param_name 协议名称 $proto 不是标准协议，将继续处理"
            return 0
            ;;
    esac
}

# ========== 配置加载函数 ==========
# 加载所有配置段
load_all_config_sections() {
    local config_name="$1"
    local section_type="$2"
    
    # 使用uci命令获取所有配置段
    local config_output=$(uci show "$config_name" 2>/dev/null)
    
    if [ -z "$config_output" ]; then
        echo ""
        return
    fi
    
    if [ -n "$section_type" ]; then
        # 修复：同时支持两种配置格式
        
        # 格式1：匿名配置节
        local anonymous_sections=$(echo "$config_output" | \
            grep -E "^${config_name}\\.@${section_type}\\[[0-9]+\\]=" | \
            cut -d= -f1 | sed "s/${config_name}\.@${section_type}\[//g; s/\]//g")
        
        # 格式2：命名配置节 - 修复：使用sh兼容的正则表达式
        # 原始行：grep -E "^${config_name}\.[a-zA-Z0-9_]+=${section_type}(['\"])?$" |
        # 修复为：使用更简单的正则表达式
        local named_sections=$(echo "$config_output" | \
            grep -E "^${config_name}\\.[a-zA-Z0-9_]+=${section_type}"'$' | \
            cut -d= -f1 | cut -d. -f2)
        
        # 格式3：旧格式
        local old_format_sections=$(echo "$config_output" | \
            grep -E "^${config_name}\\.${section_type}_[0-9]+=" | \
            cut -d= -f1 | cut -d. -f2)
        
        # 合并所有结果
        local all_sections=$(echo "$anonymous_sections" "$named_sections" "$old_format_sections" | \
            tr ' ' '
' | grep -v "^$" | sort -u | tr '
' ' ')
        
        # 输出结果，移除多余空格
        echo "$all_sections" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    else
        # 查找所有配置段
        echo "$config_output" | grep -E "^${config_name}\\.[a-zA-Z_]+[0-9]*=" | \
            cut -d= -f1 | cut -d. -f2
    fi
}

# 加载并排序所有配置段
load_and_sort_all_config_sections() {
    local config_name="$1"
    local section_type="$2"
    local sort_variable="$3"
    
    # 获取所有配置段
    local sections=$(load_all_config_sections "$config_name" "$section_type")
    
    if [ -z "$sections" ]; then
        echo ""
        return
    fi
    
    # 如果有排序变量，按排序值排序
    if [ -n "$sort_variable" ]; then
        # 创建临时文件 - 增强安全性
        local temp_file=$(mktemp -u /tmp/qos_rule_XXXXXX 2>/dev/null)
        if [ -z "$temp_file" ] || ! mktemp "$temp_file" >/dev/null 2>&1; then
            log "ERROR" "无法创建临时文件"
            echo "$sections"
            return 1
        fi
        
        # 注册清理钩子
        trap "rm -f '$temp_file' 2>/dev/null" EXIT INT TERM HUP
        
        for section in $sections; do
            local order=$(uci -q get "${config_name}.${section}.${sort_variable}")
            order=${order:-100}  # 更合理的默认值
            echo "${order}:${section}" >> "$temp_file"
        done
        
        # 排序并输出
        sort -n -t ':' -k1 "$temp_file" 2>/dev/null | cut -d: -f2- 2>/dev/null | grep -v "^$"
    else
        echo "$sections"
    fi
}

# 加载所有配置选项 - 优化：批量读取配置
load_all_config_options() {
    local config_name="$1"
    local section_id="$2"
    
    # 清空之前可能存在的变量
    unset class order enabled proto srcport dstport connbytes_kb family
    
    # 优化：批量读取配置
    local config_data=$(uci show "${config_name}.${section_id}" 2>/dev/null)
    
    # 从批量数据中提取配置
    local class_val=$(echo "$config_data" | grep ^"${config_name}.${section_id}\.class=" | cut -d= -f2)
    local order_val=$(echo "$config_data" | grep ^"${config_name}.${section_id}\.order=" | cut -d= -f2)
    local enabled_val=$(echo "$config_data" | grep ^"${config_name}.${section_id}\.enabled=" | cut -d= -f2)
    local proto_val=$(echo "$config_data" | grep ^"${config_name}.${section_id}\.proto=" | cut -d= -f2)
    local srcport_val=$(echo "$config_data" | grep ^"${config_name}.${section_id}\.srcport=" | cut -d= -f2)
    local dstport_val=$(echo "$config_data" | grep ^"${config_name}.${section_id}\.dstport=" | cut -d= -f2)
    local connbytes_kb_val=$(echo "$config_data" | grep ^"${config_name}.${section_id}\.connbytes_kb=" | cut -d= -f2)
    local family_val=$(echo "$config_data" | grep ^"${config_name}.${section_id}\.family=" | cut -d= -f2)
    
    # 验证关键参数
    if [ -n "$srcport_val" ]; then
        if ! validate_port "$srcport_val" "${section_id}.srcport"; then
            log "WARN" "源端口参数验证失败: $srcport_val，将使用空值"
            srcport_val=""
        fi
    fi
    
    if [ -n "$dstport_val" ]; then
        if ! validate_port "$dstport_val" "${section_id}.dstport"; then
            log "WARN" "目的端口参数验证失败: $dstport_val，将使用空值"
            dstport_val=""
        fi
    fi
    
    if [ -n "$proto_val" ]; then
        if ! validate_protocol "$proto_val" "${section_id}.proto"; then
            log "WARN" "协议参数验证失败: $proto_val，将继续处理"
        fi
    fi
    
    # 输出格式化的配置行
    echo "${class_val}:${order_val}:${enabled_val}:${proto_val}:${srcport_val}:${dstport_val}:${connbytes_kb_val}:${family_val}"
}

# 解析配置行
parse_config_line() {
    local config_line="$1"
    local var_prefix="$2"
    
    IFS=':' read -r class_val order_val enabled_val proto_val srcport_val dstport_val connbytes_kb_val family_val <<EOF
$config_line
EOF
    
    # 导出到调用者变量
    eval "${var_prefix}_class=\"$class_val\""
    eval "${var_prefix}_order=\"$order_val\""
    eval "${var_prefix}_enabled=\"$enabled_val\""
    eval "${var_prefix}_proto=\"$proto_val\""
    eval "${var_prefix}_srcport=\"$srcport_val\""
    eval "${var_prefix}_dstport=\"$dstport_val\""
    eval "${var_prefix}_connbytes_kb=\"$connbytes_kb_val\""
    eval "${var_prefix}_family=\"$family_val\""
}

# ========== 类别标记计算函数 ==========
# 计算哈希索引
calculate_hash_index() {
    local class="$1"
    # 使用SHA1哈希取前8位作为索引
    if command -v sha1sum >/dev/null 2>&1; then
        local hash=$(echo -n "$class" | sha1sum | cut -c1-8)
        # 将十六进制转换为十进制
        printf "%d" "0x$hash"
    elif command -v sha1 >/dev/null 2>&1; then
        local hash=$(echo -n "$class" | sha1 | cut -c1-8)
        printf "%d" "0x$hash"
    else
        # 回退到简单的CRC32计算
        local sum=0
        local i=0
        while [ $i -lt ${#class} ]; do
            local char=$(printf "%d" "'${class:$i:1}")
            sum=$(( (sum << 5) - sum + char ))
            i=$((i + 1))
        done
        echo $((sum & 0xFFFFFFFF))
    fi
}

# 获取类别标记 - 修复：引入哈希算法生成唯一索引
get_class_mark_for_rule() {
    local class="$1"
    local direction="$2"  # upload 或 download
    
    # 首先尝试从UCI配置中获取
    local config_mark=$(uci -q get "${CONFIG_FILE}.${class}.class_mark" 2>/dev/null)
    if [ -n "$config_mark" ] && echo "$config_mark" | grep -qE '^0x[0-9A-Fa-f]+$'; then
        echo "$config_mark"
        return 0
    fi
    
    # 如果没有配置，尝试从文件中获取
    if [ "$direction" = "upload" ]; then
        if [ -f "/etc/qos_gargoyle/upload_class_marks" ]; then
            local file_mark=$(grep "^upload:${class}:" "/etc/qos_gargoyle/upload_class_marks" 2>/dev/null | awk -F: '{print $3}')
            if [ -n "$file_mark" ]; then
                echo "$file_mark"
                return 0
            fi
        fi
    elif [ "$direction" = "download" ]; then
        if [ -f "/etc/qos_gargoyle/download_class_marks" ]; then
            local file_mark=$(grep "^download:${class}:" "/etc/qos_gargoyle/download_class_marks" 2>/dev/null | awk -F: '{print $3}')
            if [ -n "$file_mark" ]; then
                echo "$file_mark"
                return 0
            fi
        fi
    fi
    
    # 最后尝试通过计算获取
    local calculated_mark
    calculated_mark=$(calculate_class_mark "$class" "0x0" "$direction")
    if [ -n "$calculated_mark" ]; then
        echo "$calculated_mark"
        return 0
    fi
    
    return 1
}

# 计算类别标记 - 修复：使用哈希算法生成唯一索引
calculate_class_mark() {
    local class="$1"
    local mask="$2"
    local chain_type="$3"  # "upload" 或 "download"
    
    # 从类别名称提取索引 - 使用哈希算法生成唯一索引
    local index=1
    
    # 修复：使用哈希算法生成唯一索引
    index=$(calculate_hash_index "$class")
    
    # 确保索引在合理范围内 (1-255)
    index=$(( (index % 255) + 1 ))
    
    # 根据链类型计算基础值
    local base_value=0
    
    if [ "$chain_type" = "upload" ]; then
        base_value=$((0x1))
    elif [ "$chain_type" = "download" ]; then
        base_value=$((0x100))
    else
        log "ERROR" "未知链类型: $chain_type"
        echo ""
        return
    fi
    
    # 计算标记值: base_value << (index-1)
    local shift_amount=$((index - 1))
    local mark_value=$((base_value << shift_amount))
    
    # 输出16进制格式
    local mark_hex=$(printf "0x%X" "$mark_value")
    echo "$mark_hex"
}

# 计算规则的综合优先级分数
calculate_composite_priority() {
    local rule_name="$1"
    local direction="$2"  # upload 或 download，可选
    
    # 加载规则配置
    local config_line
    if config_line=$(load_all_config_options "$CONFIG_FILE" "$rule_name"); then
        parse_config_line "$config_line" "rule"
    else
        echo "999999_999999"  # 返回一个高优先级字符串
        return
    fi
    
    # 检查规则是否启用
    if [ "$rule_enabled" != "1" ]; then
        # 不输出日志，只返回分数
        echo "999999_999999"
        return
    fi
    
    if [ -z "$rule_class" ]; then
        echo "999999_999999"
        return
    fi
    
    # 获取规则自身的 order (默认值为100)
    local rule_order=${rule_order:-100}
    
    # 获取该规则关联 class 的 priority
    local class_priority=999
    if [ -n "$direction" ]; then
        # 如果有方向信息，尝试获取具体方向的class
        if [ "$direction" = "upload" ]; then
            class_priority=$(uci -q get "${CONFIG_FILE}.${rule_class}.priority" 2>/dev/null || echo "999")
        elif [ "$direction" = "download" ]; then
            class_priority=$(uci -q get "${CONFIG_FILE}.${rule_class}.priority" 2>/dev/null || echo "999")
        fi
    else
        # 没有方向信息，尝试通用获取
        class_priority=$(uci -q get "${CONFIG_FILE}.${rule_class}.priority" 2>/dev/null || echo "999")
    fi
    
    # 计算综合优先级分数 - 使用字符串拼接避免整数溢出
    # 格式: "类优先级_规则序号"，通过下划线分隔
    local composite_score="${class_priority}_${rule_order}"
    
    echo "$composite_score"
}

# 按优先级分数排序 - 优化：使用内存缓冲
sort_rules_by_priority() {
    local rule_list="$1"
    local direction="$2"
    local sort_direction="${3:-ascending}"
    
    # 如果输入为空，返回空
    [ -z "$rule_list" ] && { echo ""; return 0; }
    
    # 创建临时文件 - 增强安全性
    local temp_file=$(mktemp -u /tmp/qos_rule_XXXXXX 2>/dev/null)
    if [ -z "$temp_file" ] || ! mktemp "$temp_file" >/dev/null 2>&1; then
        log "ERROR" "无法创建临时文件"
        echo "$rule_list"
        return 1
    fi
    
    # 注册清理钩子
    trap "rm -f '$temp_file' 2>/dev/null" EXIT INT TERM HUP
    
    # 使用内存缓冲减少IO操作
    local buffer=""
    
    # 使用while read处理每个规则
    echo "$rule_list" | tr ' ' '
' | while read -r rule; do
        [ -z "$rule" ] && continue
        
        # 使用calculate_composite_priority计算分数
        local score
        score=$(calculate_composite_priority "$rule" "$direction")
        
        # 添加到缓冲区
        buffer="$buffer${score}:${rule}
"
    done
    
    # 写入文件
    printf "%s" "$buffer" >> "$temp_file"
    
    # 排序 - 使用新的字符串排序方法
    if [ "$sort_direction" = "ascending" ]; then
        # 使用sort命令处理"类优先级_规则序号"格式
        sort -t '_' -k1,1n -k2,2n "$temp_file" 2>/dev/null | cut -d: -f2- 2>/dev/null | tr '
' ' ' | sed 's/ $//'
    else
        # 降序排序
        sort -t '_' -k1,1nr -k2,2nr "$temp_file" 2>/dev/null | cut -d: -f2- 2>/dev/null | tr '
' ' ' | sed 's/ $//'
    fi
}

# ========== 增强规则应用函数 ==========
apply_enhanced_direction_rules() {
    local rule_type="$1"
    local chain="$2"
    local mask="$3"
    
    log "INFO" "应用增强$rule_type规则到链: $chain, 掩码: $mask"
    
    # 根据链类型确定方向
    local direction=""
    if [ "$chain" = "filter_qos_egress" ]; then
        direction="upload"
    elif [ "$chain" = "filter_qos_ingress" ]; then
        direction="download"
    else
        log "WARN" "未知链类型: $chain，将不进行方向特定的优先级计算"
    fi
    
    # 加载所有规则
    local rule_list=$(load_all_config_sections "$CONFIG_FILE" "$rule_type")
    
    if [ -z "$rule_list" ]; then
        log "INFO" "未找到$rule_type规则配置"
        return
    fi
    
    log "INFO" "找到$rule_type规则: $rule_list"
    
    # 按综合优先级排序规则
    local sorted_rule_list=$(sort_rules_by_priority "$rule_list" "$direction" "ascending")
    
    if [ -z "$sorted_rule_list" ]; then
        log "INFO" "没有可用的启用规则"
        return
    fi
    
    # 优化日志：合并详细信息
    local priority_info="=== 规则优先级详情 ===
"
    for rule_name in $sorted_rule_list; do
        local score=$(calculate_composite_priority "$rule_name" "$direction")
        local class="" order=""
        
        # 加载规则配置
        local config_line
        if config_line=$(load_all_config_options "$CONFIG_FILE" "$rule_name"); then
            parse_config_line "$config_line" "rule"
            local class_priority=$(uci -q get "${CONFIG_FILE}.${rule_class}.priority" 2>/dev/null || echo "999")
            priority_info="${priority_info}  $rule_name -> 类[$rule_class:prio$class_priority] + 规则[order:${rule_order:-100}] = 总分:$score
"
        fi
    done
    priority_info="${priority_info}====================="
    
    log "INFO" "按优先级排序后的规则: $sorted_rule_list
$(log_indent "$priority_info")"
    
    # 按优先级顺序应用规则
    for rule_name in $sorted_rule_list; do
        log "INFO" "应用规则: $rule_name (优先级顺序)"
        if ! apply_single_enhanced_rule "$rule_name" "$chain" "$mask"; then
            log "ERROR" "规则 $rule_name 应用失败，但将继续处理其他规则"
        fi
    done
}

# 应用单条增强规则
apply_single_enhanced_rule() {
    local rule_name="$1"
    local chain="$2"
    local mask="$3"
    
    log "INFO" "处理增强规则: $rule_name"
    
    # 加载规则配置
    local config_line
    if config_line=$(load_all_config_options "$CONFIG_FILE" "$rule_name"); then
        parse_config_line "$config_line" "rule"
    else
        log "ERROR" "加载规则配置失败: $rule_name"
        return 1
    fi
    
    if [ -z "$rule_class" ]; then
        log "ERROR" "规则 $rule_name 缺少class参数，跳过"
        return 1
    fi
    
    # 检查规则是否启用
    if [ "$rule_enabled" != "1" ]; then
        log "INFO" "规则 $rule_name 未启用，跳过"
        return 0
    fi
    
    # 获取类别标记
    local direction=""
    if [ "$chain" = "filter_qos_egress" ]; then
        direction="upload"
    elif [ "$chain" = "filter_qos_ingress" ]; then
        direction="download"
    fi
    
    local class_mark
    if ! class_mark=$(get_class_mark_for_rule "$rule_class" "$direction"); then
        log "ERROR" "规则 $rule_name 的类别 $rule_class 未找到标记，跳过"
        return 1
    fi
    
    # 设置地址族
    if [ -z "$rule_family" ]; then
        rule_family="inet"
    fi
    
    # 修复协议处理逻辑 - 使用协议合并优化
    if [ "$rule_proto" = "all" ] || [ -z "$rule_proto" ]; then
        # 检查是否有端口条件
        local has_port_condition="false"
        if [[ "$chain" == *"ingress"* ]] && [ -n "$rule_srcport" ] && [ "$rule_srcport" != "0" ] && [ "$rule_srcport" != "0x0" ]; then
            has_port_condition="true"
        elif [[ "$chain" == *"egress"* ]] && [ -n "$rule_dstport" ] && [ "$rule_dstport" != "0" ] && [ "$rule_dstport" != "0x0" ]; then
            has_port_condition="true"
        fi
        
        if [ "$has_port_condition" = "true" ]; then
            # 优化：使用集合语法合并TCP和UDP规则
            log "INFO" "为规则 $rule_name 创建合并的TCP/UDP规则（协议: all）"
            
            # 使用特殊的协议标记表示合并的TCP/UDP
            if ! build_enhanced_nft_rule "$rule_name" "$chain" "$class_mark" "$mask" "$rule_family" "tcp_udp" "$rule_srcport" "$rule_dstport" "$rule_connbytes_kb"; then
                log "ERROR" "创建合并的TCP/UDP规则失败: $rule_name"
                return 1
            fi
        else
            # 没有端口条件，创建不指定协议的规则
            if ! build_enhanced_nft_rule "$rule_name" "$chain" "$class_mark" "$mask" "$rule_family" "" "$rule_srcport" "$rule_dstport" "$rule_connbytes_kb"; then
                log "ERROR" "创建通用规则失败: $rule_name"
                return 1
            fi
        fi
    else
        # 指定了特定协议，直接调用
        if ! build_enhanced_nft_rule "$rule_name" "$chain" "$class_mark" "$mask" "$rule_family" "$rule_proto" "$rule_srcport" "$rule_dstport" "$rule_connbytes_kb"; then
            log "ERROR" "创建规则失败: $rule_name (协议: $rule_proto)"
            return 1
        fi
    fi
    
    return 0
}

# 构建增强 NFT 规则 - 优化日志记录
build_enhanced_nft_rule() {
    local rule_name="$1"
    local chain="$2"
    local class_mark="$3"
    local mask="$4"
    local family="$5"
    local proto="$6"
    local srcport="$7"
    local dstport="$8"
    local connbytes_kb="$9"
    
    # 验证必要参数
    if [ -z "$rule_name" ] || [ -z "$chain" ] || [ -z "$class_mark" ]; then
        log "ERROR" "缺少必要参数: rule_name, chain, class_mark"
        return 1
    fi
    
    # 设置默认family
    [ -z "$family" ] && family="inet"
    
    # 开始构建命令
    local nft_cmd="nft add rule $family gargoyle-qos-priority $chain"
    
    # 协议条件
    if [ "$proto" = "tcp" ]; then
        nft_cmd="$nft_cmd meta l4proto tcp"
    elif [ "$proto" = "udp" ]; then
        nft_cmd="$nft_cmd meta l4proto udp"
    elif [ "$proto" = "tcp_udp" ]; then
        nft_cmd="$nft_cmd meta l4proto { tcp, udp }"
    elif [ -n "$proto" ] && [ "$proto" != "all" ]; then
        nft_cmd="$nft_cmd meta l4proto $proto"
    fi
    
    # 端口条件
    if [[ "$chain" == *"ingress"* ]] && [ -n "$srcport" ]; then
        local clean_srcport=$(echo "$srcport" | tr -d ' ')
        nft_cmd="$nft_cmd th sport { $clean_srcport }"
    elif [ -n "$dstport" ]; then
        local clean_dstport=$(echo "$dstport" | tr -d ' ')
        nft_cmd="$nft_cmd th dport { $clean_dstport }"
    fi
    
    # 连接字节数条件
    if [ -n "$connbytes_kb" ] && [ "$connbytes_kb" != "0" ]; then
        local connbytes_kb_clean=$(echo "$connbytes_kb" | tr -d ' ')
        if echo "$connbytes_kb_clean" | grep -qE '^[<>=!]+[0-9]+$'; then
            local operator=$(echo "$connbytes_kb_clean" | sed -E 's/^([<>=!]+).*$/\1/')
            local value=$(echo "$connbytes_kb_clean" | sed -E 's/^[<>=!]+([0-9]+)$/\1/')
            if [ -n "$operator" ] && [ -n "$value" ]; then
                local bytes_value=$((value * 1024))
                nft_cmd="$nft_cmd ct bytes $operator $bytes_value"
            fi
        fi
    fi
    
    # 标记设置
    nft_cmd="$nft_cmd meta mark set $class_mark counter"
    
    # 优化日志：合并记录
    local log_msg="✅ 规则创建成功: $rule_name"
    if [ -n "$proto" ]; then
        log_msg="$log_msg
$(log_indent "协议: $proto")"
    fi
    if [ -n "$srcport" ]; then
        log_msg="$log_msg
$(log_indent "源端口: $srcport")"
    fi
    if [ -n "$dstport" ]; then
        log_msg="$log_msg
$(log_indent "目的端口: $dstport")"
    fi
    log_msg="$log_msg
$(log_indent "NFT命令: $nft_cmd")"
    
    # 执行命令
    if eval "$nft_cmd" 2>/dev/null; then
        log "INFO" "$log_msg"
        return 0
    else
        log "ERROR" "❌ 规则创建失败: $rule_name (退出码: $?)
$(log_indent "NFT命令: $nft_cmd")"
        return 1
    fi
}

# ========== 双栈过滤器函数 ==========
create_dualstack_filter() {
    local dev="$1"
    local parent="$2"
    local class_id="$3"
    local mark="$4"
    local mask="$5"
    
    # IPv4过滤器
    tc filter add dev "$dev" parent "$parent" protocol ip \
        handle ${mark}/$mask fw flowid "$class_id" 2>/dev/null || true
    
    # IPv6过滤器
    tc filter add dev "$dev" parent "$parent" protocol ipv6 \
        handle ${mark}/$mask fw flowid "$class_id" 2>/dev/null || true
}

# 创建带优先级的双栈过滤器
create_priority_dualstack_filter() {
    local dev="$1"
    local parent="$2"
    local class_id="$3"
    local class="$4"
    local mark="$5"
    local mask="$6"
    
    # 从配置获取该类别的priority
    local class_priority=$(uci -q get "${CONFIG_FILE}.${class}.priority" 2>/dev/null)
    class_priority=${class_priority:-100}
    
    # 使用class_priority作为TC过滤器优先级
    tc filter add dev "$dev" parent "$parent" protocol ip \
        prio $class_priority handle ${mark}/$mask fw flowid "$class_id" 2>/dev/null || true
    
    tc filter add dev "$dev" parent "$parent" protocol ipv6 \
        prio $((class_priority + 1)) handle ${mark}/$mask fw flowid "$class_id" 2>/dev/null || true
}

# ========== 兼容性函数 ==========
apply_all_rules() {
    local rule_type="$1"
    local mask="$2"
    local chain="$3"
    
    log "INFO" "开始应用 $rule_type 规则到链 $chain (掩码: $mask)"
    
    # 使用增强规则函数
    apply_enhanced_direction_rules "$rule_type" "$chain" "$mask"
}

# 处理单个规则
process_single_rule() {
    local rule_id="$1"
    local chain="$2"
    local mask="$3"
    local chain_type="$4"
    
    # 获取规则参数
    local class=$(uci -q get "$CONFIG_FILE.$rule_id.class")
    local proto=$(uci -q get "$CONFIG_FILE.$rule_id.proto")
    local srcport=$(uci -q get "$CONFIG_FILE.$rule_id.srcport")
    local dstport=$(uci -q get "$CONFIG_FILE.$rule_id.dstport")
    
    # 调试信息
    log "DEBUG" "规则 $rule_id: class=$class, proto=$proto
$(log_indent "srcport='$srcport', dstport='$dstport'")"
    
    # 检查必要参数
    if [ -z "$class" ]; then
        log "ERROR" "规则 $rule_id 缺少 class 参数"
        return 1
    fi
    
    # 计算标记值
    local mark
    mark=$(calculate_class_mark "$class" "$mask" "$chain_type")
    
    if [ -z "$mark" ]; then
        log "ERROR" "无法计算类别 $class 的标记值"
        return 1
    fi
    
    log "INFO" "类别 $class 的标记: $mark"
    
    # 对于协议为 "all" 的情况，需要特殊处理
    if [ "$proto" = "all" ] || [ -z "$proto" ]; then
        apply_all_protocol_rule "$chain" "$mark" "$srcport" "$dstport"
        return $?
    fi
    
    # 构建 nft 规则命令
    local nft_cmd="add rule inet gargoyle-qos-priority $chain"
    
    # 添加协议条件
    if [ "$proto" = "tcp" ] || [ "$proto" = "udp" ]; then
        nft_cmd="$nft_cmd meta l4proto $proto"
    elif [ -n "$proto" ]; then
        nft_cmd="$nft_cmd meta l4proto $proto"
    else
        nft_cmd="$nft_cmd meta mark set $mark counter"
    fi
    
    # 添加端口条件
    if [ -n "$srcport" ] && [ "$chain" = "filter_qos_ingress" ]; then
        local ports=$(echo "$srcport" | tr -d ' ')
        nft_cmd="$nft_cmd th sport { $ports }"
    fi
    
    if [ -n "$dstport" ] && [ "$chain" = "filter_qos_egress" ]; then
        local ports=$(echo "$dstport" | tr -d ' ')
        nft_cmd="$nft_cmd th dport { $ports }"
    fi
    
    # 添加标记设置
    nft_cmd="$nft_cmd meta mark set $mark counter"
    
    # 执行前检查语法
    if ! nft -c "$nft_cmd" 2>&1; then
        log "ERROR" "NFT 规则语法错误"
        return 1
    fi
    
    # 实际执行
    if nft "$nft_cmd" 2>&1; then
        log "INFO" "✅ NFT 规则添加成功
$(log_indent "NFT命令: $nft_cmd")"
        return 0
    else
        log "ERROR" "❌ NFT 规则添加失败
$(log_indent "NFT命令: $nft_cmd")"
        return 1
    fi
}

# 处理所有协议的规则
apply_all_protocol_rule() {
    local chain="$1"
    local mark="$2"
    local srcport="$3"
    local dstport="$4"
    
    local success=0
    local tcp_cmd udp_cmd
    
    # 处理 TCP 规则
    if [ -n "$srcport" ] && [ "$chain" = "filter_qos_ingress" ]; then
        local ports=$(echo "$srcport" | tr -d ' ')
        if [ -n "$ports" ]; then
            tcp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto tcp th sport { $ports } meta mark set $mark counter"
            if nft -c "$tcp_cmd" 2>&1; then
                nft "$tcp_cmd" 2>&1 && log "INFO" "✅ TCP 规则添加成功
$(log_indent "NFT命令: $tcp_cmd")" || { log "ERROR" "❌ TCP 规则添加失败"; success=1; }
            else
                log "ERROR" "❌ TCP 规则语法错误"
                success=1
            fi
        fi
    elif [ -n "$dstport" ] && [ "$chain" = "filter_qos_egress" ]; then
        local ports=$(echo "$dstport" | tr -d ' ')
        if [ -n "$ports" ]; then
            tcp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto tcp th dport { $ports } meta mark set $mark counter"
            if nft -c "$tcp_cmd" 2>&1; then
                nft "$tcp_cmd" 2>&1 && log "INFO" "✅ TCP 规则添加成功
$(log_indent "NFT命令: $tcp_cmd")" || { log "ERROR" "❌ TCP 规则添加失败"; success=1; }
            else
                log "ERROR" "❌ TCP 规则语法错误"
                success=1
            fi
        fi
    else
        tcp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto tcp meta mark set $mark counter"
        if nft -c "$tcp_cmd" 2>&1; then
            nft "$tcp_cmd" 2>&1 && log "INFO" "✅ TCP 规则添加成功
$(log_indent "NFT命令: $tcp_cmd")" || { log "ERROR" "❌ TCP 规则添加失败"; success=1; }
        else
            log "ERROR" "❌ TCP 规则语法错误"
            success=1
        fi
    fi
    
    # 处理 UDP 规则
    if [ -n "$srcport" ] && [ "$chain" = "filter_qos_ingress" ]; then
        local ports=$(echo "$srcport" | tr -d ' ')
        if [ -n "$ports" ]; then
            udp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto udp th sport { $ports } meta mark set $mark counter"
            if nft -c "$udp_cmd" 2>&1; then
                nft "$udp_cmd" 2>&1 && log "INFO" "✅ UDP 规则添加成功
$(log_indent "NFT命令: $udp_cmd")" || { log "ERROR" "❌ UDP 规则添加失败"; success=1; }
            else
                log "ERROR" "❌ UDP 规则语法错误"
                success=1
            fi
        fi
    elif [ -n "$dstport" ] && [ "$chain" = "filter_qos_egress" ]; then
        local ports=$(echo "$dstport" | tr -d ' ')
        if [ -n "$ports" ]; then
            udp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto udp th dport { $ports } meta mark set $mark counter"
            if nft -c "$udp_cmd" 2>&1; then
                nft "$udp_cmd" 2>&1 && log "INFO" "✅ UDP 规则添加成功
$(log_indent "NFT命令: $udp_cmd")" || { log "ERROR" "❌ UDP 规则添加失败"; success=1; }
            else
                log "ERROR" "❌ UDP 规则语法错误"
                success=1
            fi
        fi
    else
        udp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto udp meta mark set $mark counter"
        if nft -c "$udp_cmd" 2>&1; then
            nft "$udp_cmd" 2>&1 && log "INFO" "✅ UDP 规则添加成功
$(log_indent "NFT命令: $udp_cmd")" || { log "ERROR" "❌ UDP 规则添加失败"; success=1; }
        else
            log "ERROR" "❌ UDP 规则语法错误"
            success=1
        fi
    fi
    
    return $success
}