#!/bin/sh
# 规则辅助模块 (rule.sh)
# 支持多样化端口、协议、IPv6双栈和连接字节数过滤
# version=1.4.2 修复NFT语法和空格问题
# 修复内容：
# 1. 修复th th重复问题
# 2. 统一端口格式为大括号
# 3. 修正tcp_udp协议处理
# 4. 彻底清理多余空格

CONFIG_FILE="qos_gargoyle"

# ========== 统一日志函数 ==========
log() {
    local level="$1"
    local message="$2"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    case "$level" in
        "ERROR"|"error")
            logger -t "qos_gargoyle" "错误: $message"
            echo "[$timestamp] 错误: $message" >&2
            ;;
        "WARN"|"warn"|"WARNING"|"warning")
            logger -t "qos_gargoyle" "警告: $message"
            echo "[$timestamp] 警告: $message" >&2
            ;;
        "INFO"|"info")
            logger -t "qos_gargoyle" "信息: $message"
            echo "[$timestamp] 信息: $message"
            ;;
        "DEBUG"|"debug")
            logger -t "qos_gargoyle" "调试: $message"
            echo "[$timestamp] 调试: $message"
            ;;
        *)
            logger -t "qos_gargoyle" "$message"
            echo "[$timestamp] $message"
            ;;
    esac
}

# 验证数值参数
validate_number() {
    local value="$1"
    local param_name="$2"
    
    if ! echo "$value" | grep -qE '^[0-9]+$'; then
        log "ERROR" "参数 $param_name 必须是整数: $value"
        return 1
    fi
    
    return 0
}

# 验证端口参数
validate_port() {
    local value="$1"
    local param_name="$2"
    
    # 检查是否为空
    if [ -z "$value" ]; then
        return 0
    fi
    
    # 去除所有空格
    local clean_value=$(echo "$value" | tr -d '[:space:]')
    
    # 检查是否是逗号分隔的列表
    if echo "$clean_value" | grep -q ','; then
        local IFS=','
        for port in $clean_value; do
            if echo "$port" | grep -q '-'; then
                # 端口范围
                local min_port=$(echo "$port" | cut -d'-' -f1)
                local max_port=$(echo "$port" | cut -d'-' -f2)
                
                if ! validate_number "$min_port" "$param_name"; then
                    return 1
                fi
                if ! validate_number "$max_port" "$param_name"; then
                    return 1
                fi
                if [ "$min_port" -gt "$max_port" ]; then
                    log "ERROR" "端口范围 $param_name 起始端口 $min_port 大于结束端口 $max_port"
                    return 1
                fi
            else
                # 单个端口
                if ! validate_number "$port" "$param_name"; then
                    return 1
                fi
            fi
        done
    elif echo "$clean_value" | grep -q '-'; then
        # 单个端口范围
        local min_port=$(echo "$clean_value" | cut -d'-' -f1)
        local max_port=$(echo "$clean_value" | cut -d'-' -f2)
        
        if ! validate_number "$min_port" "$param_name"; then
            return 1
        fi
        if ! validate_number "$max_port" "$param_name"; then
            return 1
        fi
        if [ "$min_port" -gt "$max_port" ]; then
            log "ERROR" "端口范围 $param_name 起始端口 $min_port 大于结束端口 $max_port"
            return 1
        fi
    else
        # 单个端口
        if ! validate_number "$clean_value" "$param_name"; then
            return 1
        fi
    fi
    
    return 0
}

# 验证IP地址（简单验证）
validate_ip_address() {
    local ip="$1"
    local param_name="$2"
    
    if [ -z "$ip" ]; then
        return 0
    fi
    
    # IPv4验证
    if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        # 检查每个部分是否在0-255范围内
        local IFS='.'
        local octet_count=0
        for octet in $ip; do
            if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
                log "ERROR" "$param_name IPv4地址 $ip 的八位组 $octet 超出范围(0-255)"
                return 1
            fi
            octet_count=$((octet_count + 1))
        done
        
        if [ "$octet_count" -ne 4 ]; then
            log "ERROR" "$param_name IPv4地址 $ip 格式不正确"
            return 1
        fi
        return 0
    fi
    
    # IPv6验证（简化）
    if echo "$ip" | grep -q ':' && echo "$ip" | grep -qE '^[0-9a-fA-F:]+$'; then
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
        
        # 格式2：命名配置节
        local named_sections=$(echo "$config_output" | \
            grep -E "^${config_name}\\.[a-zA-Z0-9_]+=${section_type}(['\"])?$" | \
            cut -d. -f2 | cut -d= -f1)
        
        # 格式3：旧格式
        local old_format_sections=$(echo "$config_output" | \
            grep -E "^${config_name}\\.${section_type}_[0-9]+=" | \
            cut -d= -f1 | cut -d. -f2)
        
        # 合并所有结果
        local all_sections=$(echo "$anonymous_sections" "$named_sections" "$old_format_sections" | \
            tr ' ' '\n' | grep -v "^$" | sort -u | tr '\n' ' ')
        
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
        # 创建临时文件
        local temp_file
        temp_file=$(mktemp 2>/dev/null)
        [ -z "$temp_file" ] && { echo "$sections"; return 1; }
        
        # 设置trap确保临时文件被清理
        trap 'rm -f "$temp_file" 2>/dev/null' EXIT INT TERM HUP
        
        for section in $sections; do
            local order=$(uci -q get "${config_name}.${section}.${sort_variable}")
            order=${order:-9999}  # 默认值
            echo "${order}:${section}" >> "$temp_file"
        done
        
        # 排序并输出
        sort -n -t ':' -k1 "$temp_file" 2>/dev/null | cut -d: -f2- 2>/dev/null | grep -v "^$"
    else
        echo "$sections"
    fi
}

# 加载所有配置选项 - 修复变量作用域问题，通过标准输出返回
load_all_config_options() {
    local config_name="$1"
    local section_id="$2"
    
    # 清空之前可能存在的变量
    unset class order enabled proto srcport dstport connbytes_kb family
    
    # 通过UCI读取配置
    local class_val order_val enabled_val proto_val srcport_val dstport_val connbytes_kb_val family_val
    
    class_val=$(uci -q get "${config_name}.${section_id}.class" 2>/dev/null)
    order_val=$(uci -q get "${config_name}.${section_id}.order" 2>/dev/null)
    enabled_val=$(uci -q get "${config_name}.${section_id}.enabled" 2>/dev/null)
    proto_val=$(uci -q get "${config_name}.${section_id}.proto" 2>/dev/null)
    srcport_val=$(uci -q get "${config_name}.${section_id}.srcport" 2>/dev/null)
    dstport_val=$(uci -q get "${config_name}.${section_id}.dstport" 2>/dev/null)
    connbytes_kb_val=$(uci -q get "${config_name}.${section_id}.connbytes_kb" 2>/dev/null)
    family_val=$(uci -q get "${config_name}.${section_id}.family" 2>/dev/null)
    
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

# 获取类别标记 - 通过标准输出返回
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

# 计算类别标记 - 增强鲁棒性
calculate_class_mark() {
    local class="$1"
    local mask="$2"
    local chain_type="$3"  # "upload" 或 "download"
    
    # 从类别名称提取索引
    local index=1
    
    # 支持多种类别名称格式
    if echo "$class" | grep -qE "^(uclass_|upload_class_)"; then
        # 格式1: uclass_1, 格式2: upload_class_1
        index=$(echo "$class" | sed -E 's/^(uclass_|upload_class_)//')
    elif echo "$class" | grep -qE "^(dclass_|download_class_)"; then
        # 格式1: dclass_1, 格式2: download_class_1
        index=$(echo "$class" | sed -E 's/^(dclass_|download_class_)//')
    else
        # 尝试从预定义的映射表中查找
        if [ -f "/etc/qos_gargoyle/class_mark_mapping" ]; then
            local mapped_index=$(grep "^${class}:" "/etc/qos_gargoyle/class_mark_mapping" 2>/dev/null | cut -d: -f2)
            if [ -n "$mapped_index" ] && echo "$mapped_index" | grep -qE '^[0-9]+$'; then
                index="$mapped_index"
            else
                log "WARN" "无法解析类别名称格式且无映射: $class，使用默认索引1"
                index=1
            fi
        else
            log "WARN" "无法解析类别名称格式: $class，使用默认索引1"
            index=1
        fi
    fi
    
    # 检查索引是否为数字
    if ! echo "$index" | grep -qE '^[0-9]+$'; then
        log "WARN" "类别索引不是数字: $class (索引: $index)，使用1"
        index=1
    fi
    
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
        echo "999999"
        return
    fi
    
    # 检查规则是否启用
    if [ "$rule_enabled" != "1" ]; then
        # 不输出日志，只返回分数
        echo "999999"
        return
    fi
    
    if [ -z "$rule_class" ]; then
        echo "999999"
        return
    fi
    
    # 获取规则自身的 order (默认为999)
    local rule_order=${rule_order:-999}
    
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
    
    # 计算综合优先级分数
    local composite_score=$((class_priority * 1000 + rule_order))
    
    echo "$composite_score"
}

# 按优先级分数排序 - 改进临时文件管理
sort_rules_by_priority() {
    local rule_list="$1"
    local direction="$2"
    local sort_direction="${3:-ascending}"
    
    # 如果输入为空，返回空
    [ -z "$rule_list" ] && { echo ""; return 0; }
    
    # 创建临时文件
    local temp_file
    temp_file=$(mktemp 2>/dev/null)
    [ -z "$temp_file" ] && { echo "$rule_list"; return 1; }
    
    # 设置trap确保临时文件被清理
    trap 'rm -f "$temp_file" 2>/dev/null' EXIT INT TERM HUP
    
    # 使用while read处理每个规则
    echo "$rule_list" | tr ' ' '\n' | while read -r rule; do
        [ -z "$rule" ] && continue
        
        # 使用calculate_composite_priority计算分数
        local score
        score=$(calculate_composite_priority "$rule" "$direction")
        
        # 写入临时文件
        echo "${score}:${rule}" >> "$temp_file"
    done
    
    # 排序
    if [ "$sort_direction" = "ascending" ]; then
        sort -n -t ':' -k1 "$temp_file" 2>/dev/null | cut -d: -f2- 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
    else
        sort -rn -t ':' -k1 "$temp_file" 2>/dev/null | cut -d: -f2- 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
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
    
    log "INFO" "按优先级排序后的规则: $sorted_rule_list"
    
    # 显示详细的优先级信息
    log "INFO" "=== 规则优先级详情 ==="
    for rule_name in $sorted_rule_list; do
        local score=$(calculate_composite_priority "$rule_name" "$direction")
        local class="" order=""
        
        # 加载规则配置
        local config_line
        if config_line=$(load_all_config_options "$CONFIG_FILE" "$rule_name"); then
            parse_config_line "$config_line" "rule"
            local class_priority=$(uci -q get "${CONFIG_FILE}.${rule_class}.priority" 2>/dev/null || echo "999")
            log "INFO" "  $rule_name -> 类[$rule_class:prio$class_priority] + 规则[order:${rule_order:-999}] = 总分:$score"
        fi
    done
    log "INFO" "====================="
    
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

# 构建增强 NFT 规则 - 使用字符串构建命令
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
    
    # 记录命令
    log "DEBUG" "NFT命令: $nft_cmd"
    
    # 执行命令
    eval "$nft_cmd"
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log "INFO" "✅ 规则创建成功: $rule_name"
        return 0
    else
        log "ERROR" "❌ 规则创建失败: $rule_name (退出码: $exit_code)"
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
    log "DEBUG" "规则 $rule_id: class=$class, proto=$proto"
    log "DEBUG" "  srcport='$srcport', dstport='$dstport'"
    
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
        log "INFO" "✅ NFT 规则添加成功"
        return 0
    else
        log "ERROR" "❌ NFT 规则添加失败"
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
    
    # 处理 TCP 规则
    if [ -n "$srcport" ] && [ "$chain" = "filter_qos_ingress" ]; then
        local ports=$(echo "$srcport" | tr -d ' ')
        if [ -n "$ports" ]; then
            local tcp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto tcp th sport { $ports } meta mark set $mark counter"
            if nft -c "$tcp_cmd" 2>&1; then
                nft "$tcp_cmd" 2>&1 && log "INFO" "✅ TCP 规则添加成功" || { log "ERROR" "❌ TCP 规则添加失败"; success=1; }
            else
                log "ERROR" "❌ TCP 规则语法错误"
                success=1
            fi
        fi
    elif [ -n "$dstport" ] && [ "$chain" = "filter_qos_egress" ]; then
        local ports=$(echo "$dstport" | tr -d ' ')
        if [ -n "$ports" ]; then
            local tcp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto tcp th dport { $ports } meta mark set $mark counter"
            if nft -c "$tcp_cmd" 2>&1; then
                nft "$tcp_cmd" 2>&1 && log "INFO" "✅ TCP 规则添加成功" || { log "ERROR" "❌ TCP 规则添加失败"; success=1; }
            else
                log "ERROR" "❌ TCP 规则语法错误"
                success=1
            fi
        fi
    else
        local tcp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto tcp meta mark set $mark counter"
        if nft -c "$tcp_cmd" 2>&1; then
            nft "$tcp_cmd" 2>&1 && log "INFO" "✅ TCP 规则添加成功" || { log "ERROR" "❌ TCP 规则添加失败"; success=1; }
        else
            log "ERROR" "❌ TCP 规则语法错误"
            success=1
        fi
    fi
    
    # 处理 UDP 规则
    if [ -n "$srcport" ] && [ "$chain" = "filter_qos_ingress" ]; then
        local ports=$(echo "$srcport" | tr -d ' ')
        if [ -n "$ports" ]; then
            local udp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto udp th sport { $ports } meta mark set $mark counter"
            if nft -c "$udp_cmd" 2>&1; then
                nft "$udp_cmd" 2>&1 && log "INFO" "✅ UDP 规则添加成功" || { log "ERROR" "❌ UDP 规则添加失败"; success=1; }
            else
                log "ERROR" "❌ UDP 规则语法错误"
                success=1
            fi
        fi
    elif [ -n "$dstport" ] && [ "$chain" = "filter_qos_egress" ]; then
        local ports=$(echo "$dstport" | tr -d ' ')
        if [ -n "$ports" ]; then
            local udp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto udp th dport { $ports } meta mark set $mark counter"
            if nft -c "$udp_cmd" 2>&1; then
                nft "$udp_cmd" 2>&1 && log "INFO" "✅ UDP 规则添加成功" || { log "ERROR" "❌ UDP 规则添加失败"; success=1; }
            else
                log "ERROR" "❌ UDP 规则语法错误"
                success=1
            fi
        fi
    else
        local udp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto udp meta mark set $mark counter"
        if nft -c "$udp_cmd" 2>&1; then
            nft "$udp_cmd" 2>&1 && log "INFO" "✅ UDP 规则添加成功" || { log "ERROR" "❌ UDP 规则添加失败"; success=1; }
        else
            log "ERROR" "❌ UDP 规则语法错误"
            success=1
        fi
    fi
    
    return $success
}