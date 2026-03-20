#!/bin/sh
# 规则辅助模块 (rule.sh)
# 支持多样化端口、协议、IPv6双栈、连接字节数过滤和连接状态过滤
# version=2.0 - 统一标记分配、增强验证、移除死代码、优化错误处理

CONFIG_FILE="qos_gargoyle"
TEMP_FILES=""
RULESET_DIR="/etc/qos_gargoyle/rulesets"          # 规则集存储目录
RULESET_MERGED_FLAG="/tmp/qos_ruleset_merged"     # 标记文件，避免重复合并
CLASS_MARKS_FILE=""                                # 标记映射文件（由主脚本设置或自动创建）

# ========== 日志函数别名 ==========
log_debug() { log "DEBUG" "$@"; }
log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# 统一日志函数
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

# ========== 规则集合并函数（备份恢复机制） ==========
init_ruleset() {
    # 如果已经合并过，则直接返回
    [ -f "$RULESET_MERGED_FLAG" ] && return 0

    local ruleset ruleset_file

    ruleset=$(uci -q get ${CONFIG_FILE}.global.ruleset 2>/dev/null)
    [ -z "$ruleset" ] && ruleset="default.conf"

    case "$ruleset" in
        *.conf) ;;
        *) ruleset="${ruleset}.conf" ;;
    esac

    ruleset_file="$RULESET_DIR/$ruleset"
    if [ ! -f "$ruleset_file" ]; then
        log_error "规则集文件 $ruleset_file 不存在，无法加载任何规则！"
        return 1
    fi

    # 检查主配置中是否已存在该规则集的标记（防止重复追加）
    if grep -q "^# === RULESET_${ruleset} ===" /etc/config/${CONFIG_FILE} 2>/dev/null; then
        log_info "规则集 $ruleset 已合并到主配置文件，跳过"
        touch "$RULESET_MERGED_FLAG"
        return 0
    fi

    # 如果主配置中已有其他规则集标记，则先删除之前追加的部分
    if grep -q "^# === RULESET_" /etc/config/${CONFIG_FILE}; then
        sed -i '/^# === RULESET_/,/^# === RULESET_END ===/d' "/etc/config/${CONFIG_FILE}"
        log_info "已清理之前的规则集"
    fi

    # 备份主配置文件
    cp "/etc/config/${CONFIG_FILE}" "/etc/config/${CONFIG_FILE}.bak"

    # 将规则集文件内容追加到主配置文件末尾，并添加标记
    {
        echo ""
        echo "# === RULESET_${ruleset} ==="
        cat "$ruleset_file"
        echo "# === RULESET_END ==="
    } >> "/etc/config/${CONFIG_FILE}"

    # 重新加载 UCI 配置
    uci commit ${CONFIG_FILE}

    touch "$RULESET_MERGED_FLAG"
    log_info "已将规则集 $ruleset 合并到主配置文件"
    return 0
}

restore_main_config() {
    if [ -f "/etc/config/${CONFIG_FILE}.bak" ]; then
        cp "/etc/config/${CONFIG_FILE}.bak" "/etc/config/${CONFIG_FILE}"
        rm -f "/etc/config/${CONFIG_FILE}.bak"
        uci commit ${CONFIG_FILE}
        log_info "已恢复主配置文件备份"
    fi
    rm -f "$RULESET_MERGED_FLAG"
}

# ========== 验证函数 ==========
validate_number() {
    local value="$1"
    local param_name="$2"
    local min="${3:-0}"
    local max="${4:-2147483647}"
    
    if ! echo "$value" | grep -qE '^[0-9]+$'; then
        log_error "参数 $param_name 必须是整数: $value"
        return 1
    fi
    
    if [ "$value" -lt "$min" ] 2>/dev/null; then
        log_error "参数 $param_name 必须大于等于 $min: $value"
        return 1
    fi
    
    if [ "$value" -gt "$max" ] 2>/dev/null; then
        log_error "参数 $param_name 必须小于等于 $max: $value"
        return 1
    fi
    
    return 0
}

validate_port() {
    local value="$1"
    local param_name="$2"
    local old_ifs="$IFS"
    
    [ -z "$value" ] && return 0
    
    # 清理输入，只允许数字、逗号、横线
    local clean_value=$(echo "$value" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')
    
    if echo "$clean_value" | grep -q ','; then
        IFS=,
        for port in $clean_value; do
            [ -z "$port" ] && continue
            if echo "$port" | grep -q '-'; then
                if ! echo "$port" | grep -qE '^[0-9]+-[0-9]+$'; then
                    log_error "无效的端口范围格式 '$port'"
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
            log_error "无效的端口范围格式 '$clean_value'"
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

# 验证协议名称
validate_protocol() {
    local proto="$1"
    local param_name="$2"
    
    [ -z "$proto" ] || [ "$proto" = "all" ] && return 0
    
    case "$proto" in
        tcp|udp|icmp|icmpv6|gre|esp|ah|sctp|dccp|udplite|tcp_udp) return 0 ;;
        *)
            log_warn "$param_name 协议名称 '$proto' 不是标准协议，将继续处理"
            return 0 ;;
    esac
}

# 验证地址族
validate_family() {
    local family="$1"
    local param_name="$2"
    
    [ -z "$family" ] && return 0
    
    case "$family" in
        inet|ip|ip6|inet6) return 0 ;;
        *)
            log_error "$param_name 无效的地址族 '$family'，允许的值: inet, ip, ip6, inet6"
            return 1 ;;
    esac
}

# 验证连接字节数格式
validate_connbytes() {
    local value="$1"
    local param_name="$2"
    
    [ -z "$value" ] && return 0
    
    # 支持格式：数字范围（如 10-100）、带操作符（如 >=50, <100）、纯数字（默认 >=）
    if echo "$value" | grep -qE '^[0-9]+-[0-9]+$'; then
        local min=$(echo "$value" | cut -d- -f1)
        local max=$(echo "$value" | cut -d- -f2)
        if ! validate_number "$min" "$param_name" 0 1048576 ||
           ! validate_number "$max" "$param_name" 0 1048576 ||
           [ "$min" -gt "$max" ]; then
            return 1
        fi
    elif echo "$value" | grep -qE '^([<>]=?|!=)[0-9]+$'; then
        local operator=$(echo "$value" | sed 's/[0-9]*$//')
        local num=$(echo "$value" | grep -o '[0-9]\+')
        if ! validate_number "$num" "$param_name" 0 1048576; then
            return 1
        fi
        case "$operator" in
            '>'|'>='|'<'|'<='|'!=') ;;
            *)
                log_error "$param_name 无效的操作符 '$operator'，允许的操作符: >, >=, <, <=, !="
                return 1 ;;
        esac
    elif echo "$value" | grep -qE '^[0-9]+$'; then
        # 纯数字，视为 >= 该值
        if ! validate_number "$value" "$param_name" 0 1048576; then
            return 1
        fi
    else
        log_error "$param_name 无效的格式 '$value'，应为数字、数字-数字、或带操作符的数字"
        return 1
    fi
    return 0
}

# 验证连接状态
validate_state() {
    local state="$1"
    local param_name="$2"
    
    [ -z "$state" ] && return 0
    
    local clean_state=$(echo "$state" | tr -d ' ')
    local old_ifs="$IFS"
    IFS=','
    for s in $clean_state; do
        s=$(echo "$s" | tr -d '{}')
        case "$s" in
            new|established|related|untracked|invalid) ;;
            *)
                log_error "$param_name 无效的连接状态 '$s'，允许的值: new, established, related, untracked, invalid"
                IFS="$old_ifs"
                return 1
                ;;
        esac
    done
    IFS="$old_ifs"
    return 0
}

# 计算哈希索引（复用 cksum/sha1）
calculate_hash_index() {
    local class="$1"
    local hash_val

    if command -v cksum >/dev/null 2>&1; then
        hash_val=$(printf "%s" "$class" | cksum | cut -d' ' -f1)
        echo "$hash_val"
    elif command -v sha1sum >/dev/null 2>&1; then
        hash_val=$(printf "%s" "$class" | sha1sum | cut -c1-8)
        printf "%u" "0x$hash_val" 2>/dev/null || echo "$((0x$hash_val & 0x7FFFFFFF))"
    elif command -v sha1 >/dev/null 2>&1; then
        hash_val=$(printf "%s" "$class" | sha1 | cut -c1-8)
        printf "%u" "0x$hash_val" 2>/dev/null || echo "$((0x$hash_val & 0x7FFFFFFF))"
    else
        log_error "没有可用的哈希工具 (cksum, sha1sum, sha1)，无法计算类标记"
        return 1
    fi
}

# ========== 统一标记分配 ==========
# 初始化标记文件（如果未设置）
init_class_marks_file() {
    if [ -z "$CLASS_MARKS_FILE" ]; then
        CLASS_MARKS_FILE="/tmp/qos_class_marks_$$"
        TEMP_FILES="$TEMP_FILES $CLASS_MARKS_FILE"
    fi
}

# 为指定方向分配所有类的标记
# 参数：方向（upload/download），类列表（空格分隔）
# 返回：0成功，1失败（冲突无法解决）
allocate_class_marks() {
    local direction="$1"
    local class_list="$2"
    local mask base_value i class mark

    init_class_marks_file

    if [ "$direction" = "upload" ]; then
        base_value=1
    else
        base_value=65536
    fi

    # 初始化标记使用数组（16个独立变量）
    i=1
    while [ $i -le 16 ]; do
        eval "mark_used_${direction}_${i}=0"
        i=$((i + 1))
    done

    # 清除之前该方向的映射（避免冲突）
    if [ -f "$CLASS_MARKS_FILE" ]; then
        sed -i "/^$direction:/d" "$CLASS_MARKS_FILE" 2>/dev/null
    fi

    for class in $class_list; do
        local index
        index=$(calculate_hash_index "$class") || return 1
        index=$(( (index % 16) + 1 ))
        local original_index=$index
        local found=0
        local probe=0

        while [ $probe -lt 16 ]; do
            eval "used=\${mark_used_${direction}_${index}}"
            if [ "$used" = "0" ]; then
                eval "mark_used_${direction}_${index}=1"
                local mark_value=$((base_value << (index - 1)))
                mark_value=$((mark_value & 0xFFFFFFFF))

                echo "$direction:$class:$mark_value" >> "$CLASS_MARKS_FILE"
                log_info "类别 $class 分配标记索引 $index (原始哈希: $original_index, 探测次数: $probe)"
                found=1
                break
            fi
            index=$(( (index % 16) + 1 ))
            probe=$((probe + 1))
        done

        if [ $found -eq 0 ]; then
            log_error "类别 $class 无法分配唯一标记，所有16个索引均已占用"
            return 1
        fi
    done

    return 0
}

# 获取类别的标记值
get_class_mark() {
    local direction="$1"
    local class="$2"
    local mark_line

    init_class_marks_file
    [ ! -f "$CLASS_MARKS_FILE" ] && { log_error "类标记文件 $CLASS_MARKS_FILE 不存在"; return 1; }

    mark_line=$(grep "^$direction:$class:" "$CLASS_MARKS_FILE" 2>/dev/null | head -1)
    if [ -n "$mark_line" ]; then
        echo "${mark_line##*:}"
        return 0
    else
        log_error "类别 $class 的标记值未找到"
        return 1
    fi
}

# 清空标记文件（停止时调用）
clear_class_marks() {
    rm -f "$CLASS_MARKS_FILE" 2>/dev/null
}

# ========== 配置加载函数 ==========
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

# 加载配置节的所有选项，并进行验证
load_all_config_options() {
    local config_name="$1"
    local section_id="$2"
    local prefix="$3"
    
    local escaped_section_id=$(printf "%s" "$section_id" | sed 's/[][\.*?^$()+{}|]/\\&/g')
    
    # 初始化变量
    for var in class order enabled proto srcport dstport connbytes_kb family state; do
        eval "${prefix}${var}=''"
    done
    
    local config_data=$(uci show "${config_name}.${section_id}" 2>/dev/null)
    local val
    
    # class 必须存在，否则跳过
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.class=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        # 清理特殊字符（允许字母数字、下划线、横线）
        val=$(echo "$val" | tr -d '\n\r' | sed 's/[^a-zA-Z0-9_-]//g')
        eval "${prefix}class=\"$val\""
    else
        log_warn "配置节 $section_id 缺少 class 参数，忽略此规则"
        return 1
    fi
    
    # order
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.order=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        val=$(echo "$val" | sed 's/[^0-9]//g')
        [ -n "$val" ] && eval "${prefix}order=\"$val\""
    fi
    
    # enabled
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.enabled=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        val=$(echo "$val" | grep -o '^[01]')
        [ -n "$val" ] && eval "${prefix}enabled=\"$val\""
    fi
    
    # proto
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.proto=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_protocol "$val" "${section_id}.proto"; then
            # 允许字母数字和下划线
            val=$(echo "$val" | sed 's/[^a-zA-Z0-9_]//g')
            eval "${prefix}proto=\"$val\""
        else
            log_warn "规则 $section_id 协议 '$val' 无效，忽略此字段"
        fi
    fi
    
    # srcport
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.srcport=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_port "$val" "${section_id}.srcport"; then
            # 保留数字、逗号、横线
            val=$(echo "$val" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')
            eval "${prefix}srcport=\"$val\""
        else
            log_warn "规则 $section_id 源端口 '$val' 无效，忽略此字段"
        fi
    fi
    
    # dstport
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.dstport=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_port "$val" "${section_id}.dstport"; then
            val=$(echo "$val" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')
            eval "${prefix}dstport=\"$val\""
        else
            log_warn "规则 $section_id 目的端口 '$val' 无效，忽略此字段"
        fi
    fi
    
    # connbytes_kb
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.connbytes_kb=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_connbytes "$val" "${section_id}.connbytes_kb"; then
            # 保留数字、横线、操作符
            val=$(echo "$val" | sed 's/[^0-9<>!= -]//g' | tr -d ' ')
            eval "${prefix}connbytes_kb=\"$val\""
        else
            log_warn "规则 $section_id 连接字节数 '$val' 无效，忽略此字段"
        fi
    fi
    
    # family
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.family=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_family "$val" "${section_id}.family"; then
            val=$(echo "$val" | sed 's/[^a-zA-Z0-9]//g')
            eval "${prefix}family=\"$val\""
        else
            log_warn "规则 $section_id 地址族 '$val' 无效，忽略此字段"
        fi
    fi
    
    # state
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.state=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_state "$val" "${section_id}.state"; then
            # 保留字母、逗号、大括号
            val=$(echo "$val" | tr -d '[:space:]' | sed 's/[^{},a-zA-Z]//g')
            eval "${prefix}state=\"$val\""
        else
            log_warn "规则 $section_id 连接状态 '$val' 无效，忽略此字段"
        fi
    fi
    
    return 0
}

# ========== 规则排序 ==========
sort_rules_by_priority_fast() {
    local config_file="$1"
    local temp_sort
    
    temp_sort=$(mktemp /tmp/qos_sort_XXXXXX) || {
        log_error "无法创建排序临时文件"
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

# ========== 构建nft规则 ==========
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
    
    # 协议处理
    if [ "$proto" = "tcp" ]; then
        nft_cmd="$nft_cmd meta l4proto tcp"
    elif [ "$proto" = "udp" ]; then
        nft_cmd="$nft_cmd meta l4proto udp"
    elif [ "$proto" = "tcp_udp" ]; then
        nft_cmd="$nft_cmd meta l4proto { tcp, udp }"
    elif [ -n "$proto" ] && [ "$proto" != "all" ]; then
        nft_cmd="$nft_cmd meta l4proto $proto"
    fi
    
    # 端口处理（根据链方向）
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
    
    # 连接状态
    if [ -n "$state" ]; then
        local state_value=$(echo "$state" | tr -d '{}')
        if echo "$state_value" | grep -q ','; then
            nft_cmd="$nft_cmd ct state { $state_value }"
        else
            nft_cmd="$nft_cmd ct state $state_value"
        fi
    fi
    
    # 连接字节数
    if [ -n "$connbytes_kb" ] && [ "$connbytes_kb" != "0" ]; then
        if echo "$connbytes_kb" | grep -q '-'; then
            local min_val=$(echo "$connbytes_kb" | cut -d- -f1)
            local max_val=$(echo "$connbytes_kb" | cut -d- -f2)
            if [ "$min_val" -le "$max_val" ] 2>/dev/null; then
                local min_bytes=$((min_val * 1024))
                local max_bytes=$((max_val * 1024))
                nft_cmd="$nft_cmd ct bytes >= $min_bytes ct bytes <= $max_bytes"
            else
                log_warn "规则 $rule_name 的 connbytes_kb 范围无效: $connbytes_kb，忽略此条件"
            fi
        elif echo "$connbytes_kb" | grep -qE '^([<>]?=?|!=)[0-9]+$'; then
            local operator=$(echo "$connbytes_kb" | sed 's/[0-9]*$//')
            local value=$(echo "$connbytes_kb" | grep -o '[0-9]\+')
            [ -z "$operator" ] && operator=">="
            local bytes_value=$((value * 1024))
            nft_cmd="$nft_cmd ct bytes $operator $bytes_value"
        else
            log_warn "规则 $rule_name 的 connbytes_kb 格式无效: $connbytes_kb，忽略此条件"
        fi
    fi
    
    nft_cmd="$nft_cmd meta mark set $class_mark counter"
    echo "$nft_cmd"
}

# ========== 增强规则应用 ==========
# 应用方向规则（上传/下载）
# 返回：0成功，1失败
apply_enhanced_direction_rules() {
    local rule_type="$1"
    local chain="$2"
    local mask="$3"
    
    log_info "应用增强$rule_type规则到链: $chain, 掩码: $mask"
    
    local direction=""
    [ "$chain" = "filter_qos_egress" ] && direction="upload"
    [ "$chain" = "filter_qos_ingress" ] && direction="download"
    
    local rule_list=$(load_all_config_sections "$CONFIG_FILE" "$rule_type")
    [ -z "$rule_list" ] && { log_info "未找到$rule_type规则配置"; return 0; }
    
    log_info "找到$rule_type规则: $rule_list"
    
    local temp_config=$(mktemp /tmp/qos_rule_config_XXXXXX 2>/dev/null)
    if [ -z "$temp_config" ]; then
        log_error "无法创建配置临时文件"
        return 1
    fi
    TEMP_FILES="$TEMP_FILES $temp_config"
    
    local IFS=' '
    set -- $rule_list
    for rule; do
        [ -n "$rule" ] || continue
        if load_all_config_options "$CONFIG_FILE" "$rule" "tmp_"; then
            echo "$rule:$tmp_class:$tmp_order:$tmp_enabled:$tmp_proto:$tmp_srcport:$tmp_dstport:$tmp_connbytes_kb:$tmp_family:$tmp_state" >> "$temp_config"
        fi
    done
    
    # 检查类数量是否超过16
    local class_list=$(cut -d: -f2 "$temp_config" | sort -u)
    local class_count=0
    for class in $class_list; do
        [ -n "$class" ] || continue
        class_count=$((class_count + 1))
    done
    
    if [ $class_count -gt 16 ]; then
        log_error "方向 $direction 的启用类数量为 $class_count，超过16个，将导致标记冲突，启动中止！"
        rm -f "$temp_config" 2>/dev/null
        return 1
    fi
    
    local sorted_rule_list=$(sort_rules_by_priority_fast "$temp_config")
    if [ -z "$sorted_rule_list" ]; then
        log_info "没有可用的启用规则"
        rm -f "$temp_config" 2>/dev/null
        return 0
    fi
    
    local nft_batch_file=$(mktemp /tmp/qos_nft_batch_XXXXXX 2>/dev/null)
    if [ -z "$nft_batch_file" ]; then
        log_error "无法创建nft批处理文件"
        rm -f "$temp_config" 2>/dev/null
        return 1
    fi
    TEMP_FILES="$TEMP_FILES $nft_batch_file"
    
    log_info "按优先级顺序生成nft规则..."
    local rule_count=0
    for rule_name in $sorted_rule_list; do
        local rule_line=$(grep "^$rule_name:" "$temp_config")
        IFS=':' read -r r_name r_class r_order r_enabled r_proto r_srcport r_dstport r_connbytes r_family r_state <<EOF
$rule_line
EOF
        [ "$r_enabled" = "1" ] || continue
        
        local class_mark=$(get_class_mark "$direction" "$r_class")
        if [ -z "$class_mark" ]; then
            log_error "规则 $rule_name 的类 $r_class 无法获取标记，跳过"
            continue
        fi
        
        [ -z "$r_family" ] && r_family="inet"
        
        build_nft_rule_fast "$rule_name" "$chain" "$class_mark" "$mask" "$r_family" "$r_proto" "$r_srcport" "$r_dstport" "$r_connbytes" "$r_state" >> "$nft_batch_file"
        rule_count=$((rule_count + 1))
    done
    
    local batch_success=0
    if [ -s "$nft_batch_file" ]; then
        log_info "执行批量nft规则 (共 $rule_count 条)..."
        nft_output=$(nft -f "$nft_batch_file" 2>&1)
        nft_ret=$?
        if [ $nft_ret -eq 0 ]; then
            log_info "✅ 批量规则应用成功"
            batch_success=0
        else
            log_error "❌ 批量规则应用失败 (退出码: $nft_ret)"
            log_error "nft 错误输出: $nft_output"
            log_error "批处理文件内容:"
            cat "$nft_batch_file" | while IFS= read -r line; do
                log_error "  $line"
            done
            batch_success=1
        fi
    fi
    
    rm -f "$nft_batch_file" 2>/dev/null
    rm -f "$temp_config" 2>/dev/null
    
    return $batch_success
}

# 应用所有规则（主脚本调用）
# 返回：0成功，1失败
apply_all_rules() {
    local rule_type="$1"
    local mask="$2"
    local chain="$3"
    log_info "开始应用 $rule_type 规则到链 $chain (掩码: $mask)"
    apply_enhanced_direction_rules "$rule_type" "$chain" "$mask"
}

# 检测算法，若为CAKE或CAKE_DSCP则直接退出
ALGORITHM=$(uci -q get ${CONFIG_FILE}.global.algorithm 2>/dev/null || echo "htb_cake")
if [ "$ALGORITHM" = "cake" ] || [ "$ALGORITHM" = "cake_dscp" ]; then
    echo "[$(date '+%H:%M:%S')] qos_gargoyle 信息: 当前算法为 $ALGORITHM，无需生成分类规则，退出" >&2
    logger -t "qos_gargoyle" "信息: 当前算法为 $ALGORITHM，无需生成分类规则，退出"
    return 0
fi

# 脚本被 source 时不会执行任何操作
if [ "$(basename "$0")" = "rule.sh" ]; then
    echo "此脚本为辅助模块，不应直接执行" >&2
    exit 1
fi