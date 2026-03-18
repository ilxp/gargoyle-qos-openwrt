#!/bin/sh
# 规则辅助模块 (rule.sh)
# 支持多样化端口、协议、IPv6双栈、连接字节数过滤和连接状态过滤
# version=1.8.4 - 修复哈希算法，移除自实现；移除缓存；参数简化

CONFIG_FILE="qos_gargoyle"
TEMP_FILES=""

# ========== 检测算法，若为CAKE或CAKE_DSCP则直接退出 ==========
ALGORITHM=$(uci -q get ${CONFIG_FILE}.global.algorithm 2>/dev/null || echo "htb_cake")
if [ "$ALGORITHM" = "cake" ] || [ "$ALGORITHM" = "cake_dscp" ]; then
    echo "[$(date '+%H:%M:%S')] qos_gargoyle 信息: 当前算法为 $ALGORITHM，无需生成分类规则，退出" >&2
    logger -t "qos_gargoyle" "信息: 当前算法为 $ALGORITHM，无需生成分类规则，退出"
    return 0
fi

# ========== 辅助函数 ==========
# 转义字符串中的特殊字符，使其可安全用于 eval 赋值
escape_for_eval() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g'
}

# 清理输入字符串，只允许安全字符，防止命令注入
# 允许的字符：字母、数字、下划线、冒号、斜杠、点、逗号、空格、减号
sanitize_input() {
    echo "$1" | sed 's/[^a-zA-Z0-9_:/., -]//g'
}

# 统一日志函数，同时输出到系统日志和控制台
log() {
    local level="$1"
    local message="$2"
    local tag="qos_gargoyle"
    local prefix=""
    
    [ -z "$message" ] && return
    
    case "$level" in
        ERROR|error)   prefix="错误:" ;;
        WARN|warn|WARNING|warning) prefix="警告:" ;;
        INFO|info)     prefix="信息:" ;;
        DEBUG|debug)   prefix="调试:" ;;
        *)             prefix="$level:" ;;
    esac
    
    echo "$message" | while IFS= read -r line; do
        logger -t "$tag" "$prefix $line"
    done
    
    echo "$message" | while IFS= read -r line; do
        echo "[$(date '+%H:%M:%S')] $tag $prefix $line" >&2
    done
}

# ========== 验证函数 ==========
# 验证数字是否在指定范围内
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

# 验证端口参数（支持逗号分隔列表和端口范围）
validate_port() {
    local value="$1"
    local param_name="$2"
    local old_ifs="$IFS"
    
    [ -z "$value" ] && return 0
    
    value=$(sanitize_input "$value")
    local clean_value=$(echo "$value" | tr -d '[:space:]')
    
    if echo "$clean_value" | grep -q ','; then
        IFS=,
        for port in $clean_value; do
            [ -z "$port" ] && continue
            if echo "$port" | grep -q '-'; then
                if ! echo "$port" | grep -qE '^[0-9]+-[0-9]+$'; then
                    log "ERROR" "无效的端口范围格式 '$port'"
                    IFS="$old_ifs"
                    return 1
                fi
                local min_port max_port
                min_port=$(echo "$port" | cut -d'-' -f1)
                max_port=$(echo "$port" | cut -d'-' -f2)
                if ! validate_number "$min_port" "$param_name" 1 65535 ||
                   ! validate_number "$max_port" "$param_name" 1 65535 ||
                   [ "$min_port" -gt "$max_port" ]; then
                    IFS="$old_ifs"
                    return 1
                fi
            else
                if ! validate_number "$port" "$param_name" 1 65535; then
                    IFS="$old_ifs"
                    return 1
                fi
            fi
        done
        IFS="$old_ifs"
    elif echo "$clean_value" | grep -q '-'; then
        if ! echo "$clean_value" | grep -qE '^[0-9]+-[0-9]+$'; then
            log "ERROR" "无效的端口范围格式 '$clean_value'"
            return 1
        fi
        local min_port max_port
        min_port=$(echo "$clean_value" | cut -d'-' -f1)
        max_port=$(echo "$clean_value" | cut -d'-' -f2)
        if ! validate_number "$min_port" "$param_name" 1 65535 ||
           ! validate_number "$max_port" "$param_name" 1 65535 ||
           [ "$min_port" -gt "$max_port" ]; then
            return 1
        fi
    else
        if ! validate_number "$clean_value" "$param_name" 1 65535; then
            return 1
        fi
    fi
    
    return 0
}

# 验证 IP 地址（支持 IPv4 和 IPv6，包括 IPv4-mapped 格式）
validate_ip_address() {
    local ip="$1"
    local param_name="$2"
    
    [ -z "$ip" ] && return 0
    ip=$(sanitize_input "$ip")
    
    if echo "$ip" | grep -qE '^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'; then
        return 0
    fi
    
    if echo "$ip" | grep -qiE '^([0-9a-f]{1,4}:){7}[0-9a-f]{1,4}$|^([0-9a-f]{1,4}:){1,7}:$|^([0-9a-f]{1,4}:){1,6}:[0-9a-f]{1,4}$|^([0-9a-f]{1,4}:){1,5}(:[0-9a-f]{1,4}){1,2}$|^([0-9a-f]{1,4}:){1,4}(:[0-9a-f]{1,4}){1,3}$|^([0-9a-f]{1,4}:){1,3}(:[0-9a-f]{1,4}){1,4}$|^([0-9a-f]{1,4}:){1,2}(:[0-9a-f]{1,4}){1,5}$|^[0-9a-f]{1,4}:((:[0-9a-f]{1,4}){1,6})$|^:((:[0-9a-f]{1,4}){1,7})$|^::$|^::ffff:(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$'; then
        return 0
    fi
    
    log "ERROR" "$param_name IP地址格式不正确: $ip"
    return 1
}

# 验证协议名称，接受标准协议或 tcp_udp 作为组合协议
validate_protocol() {
    local proto="$1"
    local param_name="$2"
    
    [ -z "$proto" ] || [ "$proto" = "all" ] && return 0
    proto=$(sanitize_input "$proto")
    
    case "$proto" in
        tcp|udp|icmp|icmpv6|gre|esp|ah|sctp|dccp|udplite|tcp_udp) return 0 ;;
        *) log "WARN" "$param_name 协议名称 $proto 不是标准协议，将继续处理"; return 0 ;;
    esac
}

# 验证连接状态值，只接受 nftables 支持的关键字（单个或逗号分隔）
validate_state() {
    local state="$1"
    local param_name="$2"
    
    [ -z "$state" ] && return 0
    state=$(sanitize_input "$state" | tr -d ' ')
    
    local old_ifs="$IFS"
    IFS=','
    for s in $state; do
        s=$(echo "$s" | tr -d '{}')
        case "$s" in
            new|established|related|untracked|invalid)
                # 有效
                ;;
            *)
                log "ERROR" "$param_name 无效的连接状态 '$s'，允许的值: new, established, related, untracked, invalid"
                IFS="$old_ifs"
                return 1
                ;;
        esac
    done
    IFS="$old_ifs"
    return 0
}

# ========== 配置加载函数 ==========
# 加载指定类型的所有配置节名称
load_all_config_sections() {
    local config_name="$1"
    local section_type="$2"
    local config_output=$(uci show "$config_name" 2>/dev/null)
    
    [ -z "$config_output" ] && { echo ""; return; }
    
    if [ -n "$section_type" ]; then
        local anonymous_sections=$(echo "$config_output" | grep -E "^${config_name}\\.@${section_type}\\[[0-9]+\\]=" | cut -d= -f1 | sed "s/^${config_name}\\.//")
        local named_sections=$(echo "$config_output" | grep -E "^${config_name}\\.[a-zA-Z0-9_]+=${section_type}"'$' | cut -d= -f1 | cut -d. -f2)
        local old_format_sections=$(echo "$config_output" | grep -E "^${config_name}\\.${section_type}_[0-9]+=" | cut -d= -f1 | cut -d. -f2)
        local all_sections=$(echo "$anonymous_sections" "$named_sections" "$old_format_sections" | tr ' ' '\n' | grep -v "^$" | sort -u | tr '\n' ' ')
        echo "$all_sections" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    else
        echo "$config_output" | grep -E "^${config_name}\\.[a-zA-Z_]+[0-9]*=" | cut -d= -f1 | cut -d. -f2
    fi
}

# 加载指定配置节的所有选项，并赋值给带前缀的变量
# 安全性增强：从 UCI 读取的值先经过 sanitize_input 过滤
load_all_config_options() {
    local config_name="$1"
    local section_id="$2"
    local prefix="$3"
    
    local escaped_section_id=$(printf "%s" "$section_id" | sed 's/[][\.*?^$()+{}|]/\\&/g')
    
    for var in class order enabled proto srcport dstport connbytes_kb family state; do
        eval "${prefix}${var}=''"
    done
    
    local config_data=$(uci show "${config_name}.${section_id}" 2>/dev/null)
    local val
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.class=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        val=$(sanitize_input "$val")
        val=$(escape_for_eval "$val")
        eval "${prefix}class=\"$val\""
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.order=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        val=$(sanitize_input "$val")
        val=$(escape_for_eval "$val")
        eval "${prefix}order=\"$val\""
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.enabled=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        val=$(sanitize_input "$val")
        val=$(escape_for_eval "$val")
        eval "${prefix}enabled=\"$val\""
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.proto=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        val=$(sanitize_input "$val")
        val=$(escape_for_eval "$val")
        eval "${prefix}proto=\"$val\""
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.srcport=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        if validate_port "$val" "${section_id}.srcport"; then
            val=$(sanitize_input "$val")
            val=$(escape_for_eval "$val")
            eval "${prefix}srcport=\"$val\""
        else
            log "WARN" "源端口参数验证失败: $val，将使用空值"
            eval "${prefix}srcport=''"
        fi
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.dstport=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        if validate_port "$val" "${section_id}.dstport"; then
            val=$(sanitize_input "$val")
            val=$(escape_for_eval "$val")
            eval "${prefix}dstport=\"$val\""
        else
            log "WARN" "目的端口参数验证失败: $val，将使用空值"
            eval "${prefix}dstport=''"
        fi
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.connbytes_kb=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        val=$(sanitize_input "$val")
        val=$(escape_for_eval "$val")
        eval "${prefix}connbytes_kb=\"$val\""
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.family=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        val=$(sanitize_input "$val")
        val=$(escape_for_eval "$val")
        eval "${prefix}family=\"$val\""
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.state=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        if validate_state "$val" "${section_id}.state"; then
            val=$(sanitize_input "$val")
            val=$(escape_for_eval "$val")
            eval "${prefix}state=\"$val\""
        else
            log "WARN" "连接状态参数验证失败: $val，将忽略"
            eval "${prefix}state=''"
        fi
    fi
}

# ========== 类别标记计算函数 ==========
# 计算类名的哈希索引（优先使用 cksum，其次 sha1sum/sha1）
calculate_hash_index() {
    local class="$1"
    local hash_val

    if command -v cksum >/dev/null 2>&1; then
        hash_val=$(printf "%s" "$class" | cksum | cut -d' ' -f1)
        echo "$hash_val"
    elif command -v sha1sum >/dev/null 2>&1; then
        hash_val=$(printf "%s" "$class" | sha1sum | cut -c1-8)
        # 转换为无符号32位整数
        printf "%u" "0x$hash_val" 2>/dev/null || echo "$((0x$hash_val & 0x7FFFFFFF))"
    elif command -v sha1 >/dev/null 2>&1; then
        hash_val=$(printf "%s" "$class" | sha1 | cut -c1-8)
        printf "%u" "0x$hash_val" 2>/dev/null || echo "$((0x$hash_val & 0x7FFFFFFF))"
    else
        log "ERROR" "没有可用的哈希工具 (cksum, sha1sum, sha1)，无法计算类标记"
        return 1
    fi
}

# 获取类别的标记值（直接计算，无缓存）
get_class_mark_for_rule() {
    local class="$1"
    local direction="$2"
    local calculated_mark
    calculated_mark=$(calculate_class_mark "$class" "$direction") || return 1
    if [ -n "$calculated_mark" ] && echo "$calculated_mark" | grep -qE '^0x[0-9A-Fa-f]+$'; then
        echo "$calculated_mark"
        return 0
    else
        log "ERROR" "无法为类别 $class 生成有效标记"
        return 1
    fi
}

# 计算类别的标记值（哈希取模 16 后左移）
calculate_class_mark() {
    local class="$1"
    local chain_type="$2"
    local index
    index=$(calculate_hash_index "$class") || return 1
    index=$(( (index % 16) + 1 ))

    local base_value=0
    [ "$chain_type" = "upload" ] && base_value=$((0x1))
    [ "$chain_type" = "download" ] && base_value=$((0x10000))
    [ $base_value -eq 0 ] && { log "ERROR" "未知链类型: $chain_type"; return 1; }

    local mark_value=$((base_value << (index - 1)))
    mark_value=$((mark_value & 0xFFFFFFFF))
    printf "0x%X" "$mark_value"
}

# ========== 快速排序（实时获取类优先级，并立即清理临时文件）==========
sort_rules_by_priority_fast() {
    local config_file="$1"
    local temp_sort
    
    temp_sort=$(mktemp /tmp/qos_sort_XXXXXX) || {
        log "ERROR" "无法创建排序临时文件"
        return 1
    }
    TEMP_FILES="$TEMP_FILES $temp_sort"
    
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IFS=':' read -r r_name r_class r_order r_enabled r_proto r_srcport r_dstport r_connbytes r_family r_state <<EOF
$line
EOF
        [ "$r_enabled" != "1" ] && continue
        
        local class_priority=$(uci -q get "${CONFIG_FILE}.${r_class}.priority" 2>/dev/null)
        class_priority=${class_priority:-999}
        local rule_order=${r_order:-100}
        
        local composite=$(( class_priority * 1000 + rule_order ))
        echo "$composite:$r_name" >> "$temp_sort"
    done < "$config_file"
    
    local result=$(sort -t ':' -k1,1n "$temp_sort" 2>/dev/null | cut -d: -f2- | tr '\n' ' ' | sed 's/ $//')
    
    rm -f "$temp_sort" 2>/dev/null
    
    echo "$result"
}

# ========== 快速构建nft规则 ==========
build_nft_rule_fast() {
    local rule_name="$1"
    local chain="$2"
    local class_mark="$3"
    local mask="$4"
    local family="$5"
    local proto="$6"
    local srcport="$7"
    local dstport="$8"
    local connbytes_kb="$9"
    local state="${10}"
    
    local nft_cmd="add rule $family gargoyle-qos-priority $chain"
    
    if [ "$proto" = "tcp" ]; then
        nft_cmd="$nft_cmd meta l4proto tcp"
    elif [ "$proto" = "udp" ]; then
        nft_cmd="$nft_cmd meta l4proto udp"
    elif [ "$proto" = "tcp_udp" ]; then
        nft_cmd="$nft_cmd meta l4proto { tcp, udp }"
    elif [ -n "$proto" ] && [ "$proto" != "all" ]; then
        nft_cmd="$nft_cmd meta l4proto $proto"
    fi
    
    case "$chain" in
        *"ingress"*)
            if [ -n "$srcport" ]; then
                local clean_srcport=$(echo "$srcport" | tr -d ' ')
                nft_cmd="$nft_cmd th sport { $clean_srcport }"
            fi
            ;;
        *)
            if [ -n "$dstport" ]; then
                local clean_dstport=$(echo "$dstport" | tr -d ' ')
                nft_cmd="$nft_cmd th dport { $clean_dstport }"
            fi
            ;;
    esac
    
    if [ -n "$state" ]; then
        local state_value=$(echo "$state" | tr -d '{}')
        if echo "$state_value" | grep -q ','; then
            nft_cmd="$nft_cmd ct state { $state_value }"
        else
            nft_cmd="$nft_cmd ct state $state_value"
        fi
    fi
    
    if [ -n "$connbytes_kb" ] && [ "$connbytes_kb" != "0" ]; then
        local connbytes_kb_clean=$(echo "$connbytes_kb" | tr -d ' ')
        
        if echo "$connbytes_kb_clean" | grep -qE '^[0-9]+-[0-9]+$'; then
            local min_val=$(echo "$connbytes_kb_clean" | cut -d- -f1)
            local max_val=$(echo "$connbytes_kb_clean" | cut -d- -f2)
            if [ "$min_val" -le "$max_val" ] 2>/dev/null; then
                local min_bytes=$((min_val * 1024))
                local max_bytes=$((max_val * 1024))
                nft_cmd="$nft_cmd ct bytes >= $min_bytes ct bytes <= $max_bytes"
            else
                log "WARN" "规则 $rule_name 的 connbytes_kb 范围无效: $connbytes_kb_clean，忽略此条件"
            fi
        elif echo "$connbytes_kb_clean" | grep -qE '^([<>]?=?|!=)[0-9]+$'; then
            local operator=$(echo "$connbytes_kb_clean" | sed 's/[0-9]*$//')
            local value=$(echo "$connbytes_kb_clean" | grep -o '[0-9]\+')
            [ -z "$operator" ] && operator=">="
            local bytes_value=$((value * 1024))
            nft_cmd="$nft_cmd ct bytes $operator $bytes_value"
        else
            log "WARN" "规则 $rule_name 的 connbytes_kb 格式无效: $connbytes_kb_clean，忽略此条件"
        fi
    fi
    
    nft_cmd="$nft_cmd meta mark set $class_mark counter"
    echo "$nft_cmd"
}

# ========== 增强规则应用函数 ==========
apply_enhanced_direction_rules() {
    local rule_type="$1"
    local chain="$2"
    local mask="$3"
    
    log "INFO" "应用增强$rule_type规则到链: $chain, 掩码: $mask"
    
    local direction=""
    [ "$chain" = "filter_qos_egress" ] && direction="upload"
    [ "$chain" = "filter_qos_ingress" ] && direction="download"
    
    local rule_list=$(load_all_config_sections "$CONFIG_FILE" "$rule_type")
    [ -z "$rule_list" ] && { log "INFO" "未找到$rule_type规则配置"; return; }
    
    log "INFO" "找到$rule_type规则: $rule_list"
    
    local temp_config=$(mktemp /tmp/qos_rule_config_XXXXXX 2>/dev/null)
    if [ -z "$temp_config" ]; then
        log "ERROR" "无法创建配置临时文件"
        return 1
    fi
    TEMP_FILES="$TEMP_FILES $temp_config"
    
    local IFS=' '
    set -- $rule_list
    for rule; do
        [ -n "$rule" ] || continue
        load_all_config_options "$CONFIG_FILE" "$rule" "tmp_"
        echo "$rule:$tmp_class:$tmp_order:$tmp_enabled:$tmp_proto:$tmp_srcport:$tmp_dstport:$tmp_connbytes_kb:$tmp_family:$tmp_state" >> "$temp_config"
    done
    
    local class_list=$(cut -d: -f2 "$temp_config" | sort -u)
    local class_count=0
    for class in $class_list; do
        [ -n "$class" ] || continue
        class_count=$((class_count + 1))
    done
    
    if [ $class_count -gt 16 ]; then
        log "ERROR" "方向 $direction 的启用类数量为 $class_count，超过16个，将导致标记冲突，启动中止！"
        rm -f "$temp_config" 2>/dev/null
        return 1
    fi
    
    local sorted_rule_list=$(sort_rules_by_priority_fast "$temp_config")
    if [ -z "$sorted_rule_list" ]; then
        log "INFO" "没有可用的启用规则"
        rm -f "$temp_config" 2>/dev/null
        return
    fi
    
    local nft_batch_file=$(mktemp /tmp/qos_nft_batch_XXXXXX 2>/dev/null)
    if [ -z "$nft_batch_file" ]; then
        log "ERROR" "无法创建nft批处理文件"
        rm -f "$temp_config" 2>/dev/null
        return 1
    fi
    TEMP_FILES="$TEMP_FILES $nft_batch_file"
    
    log "INFO" "按优先级顺序生成nft规则..."
    local rule_count=0
    for rule_name in $sorted_rule_list; do
        local rule_line=$(grep "^$rule_name:" "$temp_config")
        IFS=':' read -r r_name r_class r_order r_enabled r_proto r_srcport r_dstport r_connbytes r_family r_state <<EOF
$rule_line
EOF
        [ "$r_enabled" = "1" ] || continue
        
        local class_mark=$(get_class_mark_for_rule "$r_class" "$direction" | tr -d '[:space:]')
        if [ -z "$class_mark" ]; then
            log "ERROR" "规则 $rule_name 的类 $r_class 无法获取标记，跳过"
            continue
        fi
        
        [ -z "$r_family" ] && r_family="inet"
        
        build_nft_rule_fast "$rule_name" "$chain" "$class_mark" "$mask" "$r_family" "$r_proto" "$r_srcport" "$r_dstport" "$r_connbytes" "$r_state" >> "$nft_batch_file"
        rule_count=$((rule_count + 1))
    done
    
    local batch_success=0
    if [ -s "$nft_batch_file" ]; then
        log "INFO" "执行批量nft规则 (共 $rule_count 条)..."
        nft_output=$(nft -f "$nft_batch_file" 2>&1)
        nft_ret=$?
        if [ $nft_ret -eq 0 ]; then
            log "INFO" "✅ 批量规则应用成功"
            batch_success=0
        else
            log "ERROR" "❌ 批量规则应用失败 (退出码: $nft_ret)"
            log "ERROR" "nft 错误输出: $nft_output"
            log "ERROR" "批处理文件内容:"
            cat "$nft_batch_file" | while IFS= read -r line; do
                log "ERROR" "  $line"
            done
            batch_success=1
        fi
        log "INFO" "当前链 $chain 中的规则:"
        nft list chain inet gargoyle-qos-priority $chain 2>&1 | while IFS= read -r line; do
            log "INFO" "  $line"
        done
    fi
    
    rm -f "$nft_batch_file" 2>/dev/null
    rm -f "$temp_config" 2>/dev/null
    
    return $batch_success
}

apply_all_rules() {
    local rule_type="$1"
    local mask="$2"
    local chain="$3"
    log "INFO" "开始应用 $rule_type 规则到链 $chain (掩码: $mask)"
    apply_enhanced_direction_rules "$rule_type" "$chain" "$mask"
}

process_single_rule() {
    local rule_id="$1"
    local chain="$2"
    local mask="$3"
    local chain_type="$4"
    
    local class=$(uci -q get "$CONFIG_FILE.$rule_id.class")
    local proto=$(uci -q get "$CONFIG_FILE.$rule_id.proto")
    local srcport=$(uci -q get "$CONFIG_FILE.$rule_id.srcport")
    local dstport=$(uci -q get "$CONFIG_FILE.$rule_id.dstport")
    
    log "DEBUG" "规则 $rule_id: class=$class, proto=$proto\n  srcport='$srcport', dstport='$dstport'"
    
    [ -z "$class" ] && { log "ERROR" "规则 $rule_id 缺少 class 参数"; return 1; }
    
    local mark=$(calculate_class_mark "$class" "$chain_type")
    [ -z "$mark" ] && { log "ERROR" "无法计算类别 $class 的标记值"; return 1; }
    
    log "INFO" "类别 $class 的标记: $mark"
    
    if [ "$proto" = "all" ] || [ -z "$proto" ]; then
        apply_all_protocol_rule "$chain" "$mark" "$srcport" "$dstport"
        return $?
    fi
    
    local nft_cmd="add rule inet gargoyle-qos-priority $chain"
    
    if [ "$proto" = "tcp" ] || [ "$proto" = "udp" ]; then
        nft_cmd="$nft_cmd meta l4proto $proto"
    elif [ -n "$proto" ]; then
        nft_cmd="$nft_cmd meta l4proto $proto"
    else
        nft_cmd="$nft_cmd meta mark set $mark counter"
    fi
    
    case "$chain" in
        *"ingress"*)
            if [ -n "$srcport" ]; then
                local ports=$(echo "$srcport" | tr -d ' ')
                nft_cmd="$nft_cmd th sport { $ports }"
            fi
            ;;
        *"egress"*)
            if [ -n "$dstport" ]; then
                local ports=$(echo "$dstport" | tr -d ' ')
                nft_cmd="$nft_cmd th dport { $ports }"
            fi
            ;;
    esac
    
    nft_cmd="$nft_cmd meta mark set $mark counter"
    
    if ! nft -c "$nft_cmd" 2>&1; then
        log "ERROR" "NFT 规则语法错误"
        return 1
    fi
    
    if nft $nft_cmd 2>&1; then
        log "INFO" "✅ NFT 规则添加成功\n  NFT命令: nft $nft_cmd"
        return 0
    else
        log "ERROR" "❌ NFT 规则添加失败\n  NFT命令: nft $nft_cmd"
        return 1
    fi
}

apply_all_protocol_rule() {
    local chain="$1"
    local mark="$2"
    local srcport="$3"
    local dstport="$4"
    
    local success=0
    local tcp_cmd udp_cmd
    
    case "$chain" in
        *"ingress"*)
            if [ -n "$srcport" ]; then
                local ports=$(echo "$srcport" | tr -d ' ')
                if [ -n "$ports" ]; then
                    tcp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto tcp th sport { $ports } meta mark set $mark counter"
                    if nft -c "$tcp_cmd" 2>&1; then
                        nft $tcp_cmd 2>&1 && log "INFO" "✅ TCP 规则添加成功\n  NFT命令: nft $tcp_cmd" || { log "ERROR" "❌ TCP 规则添加失败"; success=1; }
                    else
                        log "ERROR" "❌ TCP 规则语法错误"
                        success=1
                    fi
                fi
            else
                tcp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto tcp meta mark set $mark counter"
                if nft -c "$tcp_cmd" 2>&1; then
                    nft $tcp_cmd 2>&1 && log "INFO" "✅ TCP 规则添加成功\n  NFT命令: nft $tcp_cmd" || { log "ERROR" "❌ TCP 规则添加失败"; success=1; }
                else
                    log "ERROR" "❌ TCP 规则语法错误"
                    success=1
                fi
            fi
            ;;
        *"egress"*)
            if [ -n "$dstport" ]; then
                local ports=$(echo "$dstport" | tr -d ' ')
                if [ -n "$ports" ]; then
                    tcp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto tcp th dport { $ports } meta mark set $mark counter"
                    if nft -c "$tcp_cmd" 2>&1; then
                        nft $tcp_cmd 2>&1 && log "INFO" "✅ TCP 规则添加成功\n  NFT命令: nft $tcp_cmd" || { log "ERROR" "❌ TCP 规则添加失败"; success=1; }
                    else
                        log "ERROR" "❌ TCP 规则语法错误"
                        success=1
                    fi
                fi
            else
                tcp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto tcp meta mark set $mark counter"
                if nft -c "$tcp_cmd" 2>&1; then
                    nft $tcp_cmd 2>&1 && log "INFO" "✅ TCP 规则添加成功\n  NFT命令: nft $tcp_cmd" || { log "ERROR" "❌ TCP 规则添加失败"; success=1; }
                else
                    log "ERROR" "❌ TCP 规则语法错误"
                    success=1
                fi
            fi
            ;;
    esac
    
    case "$chain" in
        *"ingress"*)
            if [ -n "$srcport" ]; then
                local ports=$(echo "$srcport" | tr -d ' ')
                if [ -n "$ports" ]; then
                    udp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto udp th sport { $ports } meta mark set $mark counter"
                    if nft -c "$udp_cmd" 2>&1; then
                        nft $udp_cmd 2>&1 && log "INFO" "✅ UDP 规则添加成功\n  NFT命令: nft $udp_cmd" || { log "ERROR" "❌ UDP 规则添加失败"; success=1; }
                    else
                        log "ERROR" "❌ UDP 规则语法错误"
                        success=1
                    fi
                fi
            else
                udp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto udp meta mark set $mark counter"
                if nft -c "$udp_cmd" 2>&1; then
                    nft $udp_cmd 2>&1 && log "INFO" "✅ UDP 规则添加成功\n  NFT命令: nft $udp_cmd" || { log "ERROR" "❌ UDP 规则添加失败"; success=1; }
                else
                    log "ERROR" "❌ UDP 规则语法错误"
                    success=1
                fi
            fi
            ;;
        *"egress"*)
            if [ -n "$dstport" ]; then
                local ports=$(echo "$dstport" | tr -d ' ')
                if [ -n "$ports" ]; then
                    udp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto udp th dport { $ports } meta mark set $mark counter"
                    if nft -c "$udp_cmd" 2>&1; then
                        nft $udp_cmd 2>&1 && log "INFO" "✅ UDP 规则添加成功\n  NFT命令: nft $udp_cmd" || { log "ERROR" "❌ UDP 规则添加失败"; success=1; }
                    else
                        log "ERROR" "❌ UDP 规则语法错误"
                        success=1
                    fi
                fi
            else
                udp_cmd="add rule inet gargoyle-qos-priority $chain meta l4proto udp meta mark set $mark counter"
                if nft -c "$udp_cmd" 2>&1; then
                    nft $udp_cmd 2>&1 && log "INFO" "✅ UDP 规则添加成功\n  NFT命令: nft $udp_cmd" || { log "ERROR" "❌ UDP 规则添加失败"; success=1; }
                else
                    log "ERROR" "❌ UDP 规则语法错误"
                    success=1
                fi
            fi
            ;;
    esac
    
    return $success
}

# ========== 双栈过滤器函数 ==========
create_dualstack_filter() {
    local dev="$1"
    local parent="$2"
    local class_id="$3"
    local mark="$4"
    local mask="$5"
    
    tc filter add dev "$dev" parent "$parent" protocol ip \
        handle ${mark}/$mask fw flowid "$class_id" 2>/dev/null || true
    tc filter add dev "$dev" parent "$parent" protocol ipv6 \
        handle ${mark}/$mask fw flowid "$class_id" 2>/dev/null || true
}

create_priority_dualstack_filter() {
    local dev="$1"
    local parent="$2"
    local class_id="$3"
    local class="$4"
    local mark="$5"
    local mask="$6"
    
    local class_priority=$(uci -q get "${CONFIG_FILE}.${class}.priority" 2>/dev/null)
    class_priority=${class_priority:-100}
    
    tc filter add dev "$dev" parent "$parent" protocol ip \
        prio $class_priority handle ${mark}/$mask fw flowid "$class_id" 2>/dev/null || true
    tc filter add dev "$dev" parent "$parent" protocol ipv6 \
        prio $((class_priority + 1)) handle ${mark}/$mask fw flowid "$class_id" 2>/dev/null || true
}

# 脚本被 source 时不会执行任何操作
if [ "$(basename "$0")" = "rule.sh" ]; then
    echo "此脚本为辅助模块，不应直接执行" >&2
    exit 1
fi