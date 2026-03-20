#!/bin/sh
# 规则辅助模块 (rule.sh)
# 支持多样化端口、协议、IPv6双栈、连接字节数过滤和连接状态过滤
# version=2.2.3 - 修复启用规则统计误匹配、标记文件清空时机、集合名大小写

: ${DEBUG:=0}

CONFIG_FILE="qos_gargoyle"
TEMP_FILES=""
RULESET_DIR="/etc/qos_gargoyle/rulesets"
RULESET_MERGED_FLAG="/tmp/qos_ruleset_merged"
PERSISTENT_CLASS_MARKS="/etc/qos_gargoyle/class_marks"
IPV6_SET_SUFFIX="6"

# ========== 日志函数 ==========
log_debug() { [ "$DEBUG" = "1" ] && log "DEBUG" "$@"; }
log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

log() {
    local level="$1"
    local message="$2"
    local tag="qos_gargoyle"
    local prefix=""

    [ -z "$message" ] && return

    case "$level" in
        ERROR|error)   prefix="错误:" ;;
        WARN|warn)     prefix="警告:" ;;
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

# ========== 规则集合并 ==========
init_ruleset() {
    [ -f "$RULESET_MERGED_FLAG" ] && return 0
    local ruleset ruleset_file
    ruleset=$(uci -q get ${CONFIG_FILE}.global.ruleset 2>/dev/null) || ruleset="default.conf"
    case "$ruleset" in *.conf) ;; *) ruleset="${ruleset}.conf" ;; esac
    ruleset_file="$RULESET_DIR/$ruleset"
    [ ! -f "$ruleset_file" ] && { log_error "规则集文件 $ruleset_file 不存在"; return 1; }
    if grep -q "^# === RULESET_${ruleset} ===" /etc/config/${CONFIG_FILE} 2>/dev/null; then
        log_info "规则集 $ruleset 已合并，跳过"
        touch "$RULESET_MERGED_FLAG"
        return 0
    fi
    if grep -q "^# === RULESET_" /etc/config/${CONFIG_FILE}; then
        sed -i '/^# === RULESET_/,/^# === RULESET_END ===/d' "/etc/config/${CONFIG_FILE}"
    fi
    cp "/etc/config/${CONFIG_FILE}" "/etc/config/${CONFIG_FILE}.bak"
    {
        echo ""
        echo "# === RULESET_${ruleset} ==="
        cat "$ruleset_file"
        echo "# === RULESET_END ==="
    } >> "/etc/config/${CONFIG_FILE}"
    uci commit ${CONFIG_FILE}
    touch "$RULESET_MERGED_FLAG"
    log_info "已将规则集 $ruleset 合并到主配置"
    return 0
}

restore_main_config() {
    [ -f "/etc/config/${CONFIG_FILE}.bak" ] && {
        cp "/etc/config/${CONFIG_FILE}.bak" "/etc/config/${CONFIG_FILE}"
        rm -f "/etc/config/${CONFIG_FILE}.bak"
        uci commit ${CONFIG_FILE}
        log_info "已恢复主配置备份"
    }
    rm -f "$RULESET_MERGED_FLAG"
}

# ========== 验证函数 ==========
validate_number() {
    local value="$1" param_name="$2" min="${3:-0}" max="${4:-2147483647}"
    if ! echo "$value" | grep -qE '^[0-9]+$'; then
        log_error "参数 $param_name 必须是整数: $value"
        return 1
    fi
    [ "$value" -lt "$min" ] 2>/dev/null && { log_error "$param_name 必须 ≥ $min"; return 1; }
    [ "$value" -gt "$max" ] 2>/dev/null && { log_error "$param_name 必须 ≤ $max"; return 1; }
    return 0
}

validate_port() {
    local value="$1" param_name="$2" old_ifs="$IFS"
    [ -z "$value" ] && return 0
    local clean_value=$(echo "$value" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')
    if echo "$clean_value" | grep -q ','; then
        IFS=,
        for port in $clean_value; do
            [ -z "$port" ] && continue
            if echo "$port" | grep -q '-'; then
                if ! echo "$port" | grep -qE '^[0-9]+-[0-9]+$'; then
                    log_error "无效端口范围 '$port'"; IFS="$old_ifs"; return 1
                fi
                local min_port=$(echo "$port" | cut -d- -f1)
                local max_port=$(echo "$port" | cut -d- -f2)
                if ! validate_number "$min_port" "$param_name" 1 65535 ||
                   ! validate_number "$max_port" "$param_name" 1 65535 ||
                   [ "$min_port" -gt "$max_port" ]; then
                    IFS="$old_ifs"; return 1
                fi
            else
                validate_number "$port" "$param_name" 1 65535 || { IFS="$old_ifs"; return 1; }
            fi
        done
        IFS="$old_ifs"
    elif echo "$clean_value" | grep -q '-'; then
        if ! echo "$clean_value" | grep -qE '^[0-9]+-[0-9]+$'; then
            log_error "无效端口范围 '$clean_value'"; return 1
        fi
        local min_port=$(echo "$clean_value" | cut -d- -f1)
        local max_port=$(echo "$clean_value" | cut -d- -f2)
        if ! validate_number "$min_port" "$param_name" 1 65535 ||
           ! validate_number "$max_port" "$param_name" 1 65535 ||
           [ "$min_port" -gt "$max_port" ]; then
            return 1
        fi
    else
        validate_number "$clean_value" "$param_name" 1 65535 || return 1
    fi
    return 0
}

validate_protocol() {
    local proto="$1" param_name="$2"
    [ -z "$proto" ] || [ "$proto" = "all" ] && return 0
    case "$proto" in
        tcp|udp|icmp|icmpv6|gre|esp|ah|sctp|dccp|udplite|tcp_udp) return 0 ;;
        *) log_warn "$param_name 协议 '$proto' 非标准，将继续处理"; return 0 ;;
    esac
}

validate_family() {
    local family="$1" param_name="$2"
    [ -z "$family" ] && return 0
    case "$family" in
        inet|ip|ip6|inet6|ipv4|ipv6) return 0 ;;
        *) log_error "$param_name 无效地址族 '$family'"; return 1 ;;
    esac
}

validate_connbytes() {
    local value="$1" param_name="$2"
    [ -z "$value" ] && return 0
    if echo "$value" | grep -qE '^[0-9]+-[0-9]+$'; then
        local min=$(echo "$value" | cut -d- -f1)
        local max=$(echo "$value" | cut -d- -f2)
        if ! validate_number "$min" "$param_name" 0 1048576 ||
           ! validate_number "$max" "$param_name" 0 1048576 ||
           [ "$min" -gt "$max" ]; then
            return 1
        fi
    elif echo "$value" | grep -qE '^([<>]?=?|!=)[0-9]+$'; then
        local operator=$(echo "$value" | sed 's/[0-9]*$//')
        local num=$(echo "$value" | grep -o '[0-9]\+')
        validate_number "$num" "$param_name" 0 1048576 || return 1
        case "$operator" in
            '>'|'>='|'<'|'<='|'!=') ;;
            *) log_error "$param_name 无效操作符 '$operator'"; return 1 ;;
        esac
    elif echo "$value" | grep -qE '^[0-9]+$'; then
        validate_number "$value" "$param_name" 0 1048576 || return 1
    else
        log_error "$param_name 格式无效"; return 1
    fi
    return 0
}

validate_state() {
    local state="$1" param_name="$2"
    [ -z "$state" ] && return 0
    local clean_state=$(echo "$state" | tr -d ' ')
    local old_ifs="$IFS"
    IFS=','
    for s in $clean_state; do
        s=$(echo "$s" | tr -d '{}')
        case "$s" in
            new|established|related|untracked|invalid) ;;
            *) log_error "$param_name 无效状态 '$s'"; IFS="$old_ifs"; return 1 ;;
        esac
    done
    IFS="$old_ifs"
    return 0
}

calculate_hash_index() {
    local class="$1" hash_val
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
        log_error "无可用哈希工具，无法计算标记"
        return 1
    fi
}

# ========== 标记分配 ==========
init_class_marks_file() {
    mkdir -p /etc/qos_gargoyle
    CLASS_MARKS_FILE="$PERSISTENT_CLASS_MARKS"
}

get_class_mark() {
    local direction="$1" class="$2" mark_line
    init_class_marks_file
    [ ! -f "$CLASS_MARKS_FILE" ] && { log_error "标记文件不存在"; return 1; }
    mark_line=$(grep "^$direction:$class:" "$CLASS_MARKS_FILE" 2>/dev/null | head -1)
    [ -n "$mark_line" ] && echo "${mark_line##*:}" || { log_error "类别 $class 标记未找到"; return 1; }
}

get_class_id() {
    local direction="$1" class="$2" class_id
    class_id=$(echo "$class" | sed -n 's/^[ud]class_\([0-9]\+\)$/\1/p')
    [ -z "$class_id" ] && { log_error "无法从 $class 解析 class_id"; return 1; }
    [ "$direction" = "download" ] && class_id=$((class_id + 16))
    echo "$class_id"
}

# 为指定方向分配所有类的标记
# 参数：方向（upload/download），类列表（空格分隔）
# 返回：0成功，1失败（冲突无法解决）
allocate_class_marks() {
    local direction="$1" class_list="$2" base_value i class

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
        i=$((i+1))
    done

    # 清除之前该方向的映射（避免冲突）
    [ -f "$CLASS_MARKS_FILE" ] && sed -i "/^$direction:/d" "$CLASS_MARKS_FILE" 2>/dev/null

    # 检查文件是否可写
    touch "$CLASS_MARKS_FILE" 2>/dev/null || {
        log_error "无法写入标记文件 $CLASS_MARKS_FILE"
        return 1
    }

    for class in $class_list; do
        local index original_index found=0 probe=0
        index=$(calculate_hash_index "$class") || return 1
        index=$(( (index % 16) + 1 )); original_index=$index
        while [ $probe -lt 16 ]; do
            eval "used=\${mark_used_${direction}_${index}}"
            if [ "$used" = "0" ]; then
                eval "mark_used_${direction}_${index}=1"
                local mark_value=$((base_value << (index-1) & 0xFFFFFFFF))
                echo "$direction:$class:$mark_value" >> "$CLASS_MARKS_FILE" || {
                    log_error "写入标记文件失败"
                    return 1
                }
                log_info "类别 $class 分配标记索引 $index (原始哈希 $original_index, 探测 $probe)"
                found=1; break
            fi
            index=$(( (index % 16) + 1 )); probe=$((probe+1))
        done
        [ $found -eq 0 ] && { log_error "类别 $class 无法分配唯一标记"; return 1; }
    done
    return 0
}

clear_class_marks() { rm -f "$PERSISTENT_CLASS_MARKS" 2>/dev/null; }

# ========== 配置加载函数 ==========
load_all_config_sections() {
    local config_name="$1" section_type="$2" config_output=$(uci show "$config_name" 2>/dev/null)
    [ -z "$config_output" ] && { echo ""; return; }
    if [ -n "$section_type" ]; then
        local anonymous=$(echo "$config_output" | grep -E "^${config_name}\\.@${section_type}\\[[0-9]+\\]=" | cut -d= -f1 | sed "s/^${config_name}\\.//")
        local named=$(echo "$config_output" | grep -E "^${config_name}\\.[a-zA-Z0-9_]+=${section_type}"'$' | cut -d= -f1 | cut -d. -f2)
        local old=$(echo "$config_output" | grep -E "^${config_name}\\.${section_type}_[0-9]+=" | cut -d= -f1 | cut -d. -f2)
        echo "$anonymous $named $old" | tr ' ' '\n' | grep -v "^$" | sort -u | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    else
        echo "$config_output" | grep -E "^${config_name}\\.[a-zA-Z_]+[0-9]*=" | cut -d= -f1 | cut -d. -f2
    fi
}

load_all_config_options() {
    local config_name="$1" section_id="$2" prefix="$3"
    local escaped_section_id=$(printf "%s" "$section_id" | sed 's/[][\.*?^$()+{}|]/\\&/g')
    for var in class order enabled proto srcport dstport connbytes_kb family state; do eval "${prefix}${var}=''"; done
    local config_data=$(uci show "${config_name}.${section_id}" 2>/dev/null) val

    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.class=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r' | sed 's/[^a-zA-Z0-9_-]//g')
        eval "${prefix}class=\"$val\""
    else
        log_warn "配置节 $section_id 缺少 class，忽略"
        return 1
    fi

    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.order=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r' | sed 's/[^0-9]//g')
        [ -n "$val" ] && eval "${prefix}order=\"$val\""
    fi

    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.enabled=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r' | grep -o '^[01]')
        [ -n "$val" ] && eval "${prefix}enabled=\"$val\""
    fi

    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.proto=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_protocol "$val" "${section_id}.proto"; then
            val=$(echo "$val" | sed 's/[^a-zA-Z0-9_]//g')
            eval "${prefix}proto=\"$val\""
        else
            log_warn "规则 $section_id 协议 '$val' 无效"
        fi
    fi

    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.srcport=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_port "$val" "${section_id}.srcport"; then
            val=$(echo "$val" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')
            eval "${prefix}srcport=\"$val\""
        else
            log_warn "规则 $section_id 源端口 '$val' 无效"
        fi
    fi

    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.dstport=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_port "$val" "${section_id}.dstport"; then
            val=$(echo "$val" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')
            eval "${prefix}dstport=\"$val\""
        else
            log_warn "规则 $section_id 目的端口 '$val' 无效"
        fi
    fi

    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.connbytes_kb=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_connbytes "$val" "${section_id}.connbytes_kb"; then
            val=$(echo "$val" | sed 's/[^0-9<>!= -]//g' | tr -d ' ')
            eval "${prefix}connbytes_kb=\"$val\""
        else
            log_warn "规则 $section_id 连接字节数 '$val' 无效"
        fi
    fi

    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.family=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_family "$val" "${section_id}.family"; then
            val=$(echo "$val" | sed 's/[^a-zA-Z0-9]//g')
            eval "${prefix}family=\"$val\""
        else
            log_warn "规则 $section_id 地址族 '$val' 无效"
        fi
    fi

    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.state=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_state "$val" "${section_id}.state"; then
            val=$(echo "$val" | tr -d '[:space:]' | sed 's/[^{},a-zA-Z]//g')
            eval "${prefix}state=\"$val\""
        else
            log_warn "规则 $section_id 连接状态 '$val' 无效"
        fi
    fi

    return 0
}

calculate_memory_limit() {
    local config_value="$1" result
    [ -z "$config_value" ] && { echo ""; return; }
    if [ "$config_value" = "auto" ]; then
        local total_mem_mb=0
        if [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
            local total_mem_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
            if [ -n "$total_mem_bytes" ] && [ "$total_mem_bytes" -gt 0 ] 2>/dev/null; then
                total_mem_mb=$(( total_mem_bytes / 1024 / 1024 ))
                log_info "从cgroups获取内存限制: ${total_mem_mb}MB"
            fi
        fi
        if [ -z "$total_mem_mb" ] || [ "$total_mem_mb" -eq 0 ]; then
            local total_mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
            if [ -n "$total_mem_kb" ] && [ "$total_mem_kb" -gt 0 ] 2>/dev/null; then
                total_mem_mb=$(( total_mem_kb / 1024 ))
                log_info "从/proc/meminfo获取内存: ${total_mem_mb}MB"
            fi
        fi
        if [ -n "$total_mem_mb" ] && [ "$total_mem_mb" -gt 0 ] 2>/dev/null; then
            result="$(((total_mem_mb + 255) / 256))Mb"
            local min_limit=4 max_limit=32
            local result_value=$(echo "$result" | sed 's/Mb//')
            [ "$result_value" -lt "$min_limit" ] && result="${min_limit}Mb"
            [ "$result_value" -gt "$max_limit" ] && result="${max_limit}Mb"
            log_info "系统内存 ${total_mem_mb}MB，自动计算 memlimit=${result}"
        else
            log_warn "无法读取内存信息，使用默认值 16Mb"
            result="16Mb"
        fi
    else
        if echo "$config_value" | grep -qE '^[0-9]+Mb$'; then
            result="$config_value"
            log_info "使用用户配置的 memlimit: ${result}"
        else
            log_warn "无效的 memlimit 格式 '$config_value'，使用默认值 16Mb"
            result="16Mb"
        fi
    fi
    echo "$result"
}

sort_rules_by_priority_fast() {
    local config_file="$1" temp_sort
    temp_sort=$(mktemp /tmp/qos_sort_XXXXXX) || { log_error "无法创建排序临时文件"; return 1; }
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

# ========== 构建复杂规则 ==========
build_complex_rule_fast() {
    local rule_name="$1" chain="$2" class_mark="$3" family="$4" proto="$5"
    local srcport="$6" dstport="$7" connbytes_kb="$8" state="$9" class_id="${10}"
    local nft_cmd="add rule inet gargoyle-qos-priority $chain"
    case "$family" in
        ip|inet4|ipv4) nft_cmd="$nft_cmd meta nfproto ipv4" ;;
        ip6|inet6|ipv6) nft_cmd="$nft_cmd meta nfproto ipv6" ;;
    esac
    [ "$proto" = "tcp" ] && nft_cmd="$nft_cmd meta l4proto tcp"
    [ "$proto" = "udp" ] && nft_cmd="$nft_cmd meta l4proto udp"
    [ "$proto" = "tcp_udp" ] && nft_cmd="$nft_cmd meta l4proto { tcp, udp }"
    [ -n "$proto" ] && [ "$proto" != "tcp" ] && [ "$proto" != "udp" ] && [ "$proto" != "tcp_udp" ] && [ "$proto" != "all" ] && nft_cmd="$nft_cmd meta l4proto $proto"
    if [ "$proto" = "tcp" ] || [ "$proto" = "udp" ] || [ "$proto" = "tcp_udp" ]; then
        case "$chain" in
            *"ingress"*)
                if [ -n "$dstport" ]; then
                    nft_cmd="$nft_cmd th dport { $(echo "$dstport" | tr -d '[:space:]') }"
                elif [ -n "$srcport" ]; then
                    nft_cmd="$nft_cmd th sport { $(echo "$srcport" | tr -d '[:space:]') }"
                fi
                ;;
            *)
                if [ -n "$srcport" ]; then
                    nft_cmd="$nft_cmd th sport { $(echo "$srcport" | tr -d '[:space:]') }"
                elif [ -n "$dstport" ]; then
                    nft_cmd="$nft_cmd th dport { $(echo "$dstport" | tr -d '[:space:]') }"
                fi
                ;;
        esac
    fi
    if [ -n "$state" ]; then
        local state_val=$(echo "$state" | tr -d '{}')
        if [ -n "$state_val" ]; then
            if echo "$state_val" | grep -q ','; then
                nft_cmd="$nft_cmd ct state { $state_val }"
            else
                nft_cmd="$nft_cmd ct state $state_val"
            fi
        fi
    fi
    if [ -n "$connbytes_kb" ] && [ "$connbytes_kb" != "0" ]; then
        if echo "$connbytes_kb" | grep -q '-'; then
            local min=$(echo "$connbytes_kb" | cut -d- -f1)
            local max=$(echo "$connbytes_kb" | cut -d- -f2)
            if [ "$min" -le "$max" ] 2>/dev/null; then
                nft_cmd="$nft_cmd ct bytes >= $((min*1024)) ct bytes <= $((max*1024))"
            else
                log_warn "规则 $rule_name 连接字节数范围无效，忽略"
            fi
        elif echo "$connbytes_kb" | grep -qE '^([<>]?=?|!=)[0-9]+$'; then
            local op=$(echo "$connbytes_kb" | sed 's/[0-9]*$//')
            local val=$(echo "$connbytes_kb" | grep -o '[0-9]\+')
            [ -z "$op" ] && op=">="
            nft_cmd="$nft_cmd ct bytes $op $((val*1024))"
        else
            log_warn "规则 $rule_name 连接字节数格式无效，忽略"
        fi
    fi
    nft_cmd="$nft_cmd ct mark set $class_id meta mark set $class_mark counter"
    echo "$nft_cmd"
}

# ========== 生成基于 DNS 学习集合的规则（使用类别真实名称，统一小写） ==========
generate_set_rules() {
    local direction="$1" chain="$2" nft_batch_file="$3"

    # 从持久化标记文件中提取该方向的所有类名（去重）
    local class_names=$(grep "^$direction:" "$PERSISTENT_CLASS_MARKS" 2>/dev/null | cut -d: -f2 | sort -u)
    [ -z "$class_names" ] && return 0

    local class_name class_mark class_id realname set_name
    for class_name in $class_names; do
        class_mark=$(get_class_mark "$direction" "$class_name")
        [ -z "$class_mark" ] && continue

        class_id=$(get_class_id "$direction" "$class_name") || continue

        # 获取类的真实名称（如 realtime），并转换为小写（与 DNS 模块一致）
        realname=$(uci -q get ${CONFIG_FILE}.${class_name}.name 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if [ -z "$realname" ]; then
            log_warn "类别 $class_name 未配置 name 选项，无法生成集合规则，跳过"
            continue
        fi
        set_name="${direction}_${realname}"

        if [ "$direction" = "upload" ]; then
            echo "add rule inet gargoyle-qos-priority $chain ip daddr @$set_name ct mark set $class_id meta mark set $class_mark" >> "$nft_batch_file"
            echo "add rule inet gargoyle-qos-priority $chain ip6 daddr @${set_name}${IPV6_SET_SUFFIX} ct mark set $class_id meta mark set $class_mark" >> "$nft_batch_file"
        else
            echo "add rule inet gargoyle-qos-priority $chain ip saddr @$set_name ct mark set $class_id meta mark set $class_mark" >> "$nft_batch_file"
            echo "add rule inet gargoyle-qos-priority $chain ip6 saddr @${set_name}${IPV6_SET_SUFFIX} ct mark set $class_id meta mark set $class_mark" >> "$nft_batch_file"
        fi
        log_info "添加集合规则: $direction $class_name ($realname) -> mark $class_mark, class_id $class_id"
    done
}

# ========== 增强规则应用 ==========
apply_enhanced_direction_rules() {
    local rule_type="$1" chain="$2" mask="$3"
    log_info "应用 $rule_type 规则到链 $chain (掩码 $mask)"

    local direction=""
    [ "$chain" = "filter_qos_egress" ] && direction="upload"
    [ "$chain" = "filter_qos_ingress" ] && direction="download"

    local rule_list=$(load_all_config_sections "$CONFIG_FILE" "$rule_type")
    [ -z "$rule_list" ] && { log_info "无 $rule_type 规则"; return 0; }

    local temp_config=$(mktemp /tmp/qos_rule_config_XXXXXX)
    TEMP_FILES="$TEMP_FILES $temp_config"

    local IFS=' '
    for rule in $rule_list; do
        if load_all_config_options "$CONFIG_FILE" "$rule" "tmp_"; then
            echo "$rule:$tmp_class:$tmp_order:$tmp_enabled:$tmp_proto:$tmp_srcport:$tmp_dstport:$tmp_connbytes_kb:$tmp_family:$tmp_state" >> "$temp_config"
        fi
    done

    # 分离纯端口规则（无 connbytes, 无 state, 协议为 tcp/udp/tcp_udp, family 为 inet 或空）
    local pure_tcp_ports="" pure_udp_ports="" pure_tcp_udp_ports=""
    local complex_rules=""

    while IFS= read -r line; do
        IFS=':' read -r r_name r_class r_order r_enabled r_proto r_srcport r_dstport r_connbytes r_family r_state <<EOF
$line
EOF
        [ "$r_enabled" = "1" ] || continue
        if [ -z "$r_connbytes" ] && [ -z "$r_state" ] && { [ -z "$r_family" ] || [ "$r_family" = "inet" ]; } && { [ "$r_proto" = "tcp" ] || [ "$r_proto" = "udp" ] || [ "$r_proto" = "tcp_udp" ]; }; then
            local port_field=""
            if [ "$chain" = "filter_qos_egress" ]; then
                port_field="${r_srcport:-$r_dstport}"
            else
                port_field="${r_dstport:-$r_srcport}"
            fi
            [ -z "$port_field" ] && continue
            case "$r_proto" in
                tcp) pure_tcp_ports="$pure_tcp_ports $r_class:$port_field" ;;
                udp) pure_udp_ports="$pure_udp_ports $r_class:$port_field" ;;
                tcp_udp) pure_tcp_udp_ports="$pure_tcp_udp_ports $r_class:$port_field" ;;
            esac
        else
            complex_rules="$complex_rules $r_name:$r_class:$r_order:$r_proto:$r_srcport:$r_dstport:$r_connbytes:$r_family:$r_state"
        fi
    done < "$temp_config"

    # 统计纯端口规则涉及的类数量（根据方向匹配类名前缀，仅统计启用规则）
    local class_list=""
    if [ "$direction" = "upload" ]; then
        class_list=$(echo "$pure_tcp_ports $pure_udp_ports $pure_tcp_udp_ports" | grep -o 'uclass_[0-9]\+' | sort -u)
    else
        class_list=$(echo "$pure_tcp_ports $pure_udp_ports $pure_tcp_udp_ports" | grep -o 'dclass_[0-9]\+' | sort -u)
    fi
    local class_count=$(echo "$class_list" | wc -w)
    if [ $class_count -gt 16 ]; then
        log_error "方向 $direction 纯端口类数量 $class_count 超过16，启动中止"
        rm -f "$temp_config"
        return 1
    fi

    local nft_batch_file=$(mktemp /tmp/qos_nft_batch_XXXXXX)
    TEMP_FILES="$TEMP_FILES $nft_batch_file"

    # --- 1. 为每个类创建专用链 ---
    for class in $class_list; do
        local class_id=$(get_class_id "$direction" "$class") || continue
        echo "add chain inet gargoyle-qos-priority class_${class_id}_set" >> "$nft_batch_file" 2>/dev/null || true
        echo "flush chain inet gargoyle-qos-priority class_${class_id}_set" >> "$nft_batch_file" 2>/dev/null || true
        local class_mark=$(get_class_mark "$direction" "$class")
        [ -z "$class_mark" ] && continue
        echo "add rule inet gargoyle-qos-priority class_${class_id}_set ct mark set $class_id meta mark set $class_mark accept" >> "$nft_batch_file"
    done

    # --- 2. 处理纯端口规则，向 vmap 添加元素 ---
    local port_dir
    [ "$direction" = "upload" ] && port_dir="dport" || port_dir="sport"

    # 先清空 map（只一次）
    echo "flush map inet gargoyle-qos-priority ${direction}_tcp_${port_dir}_map" >> "$nft_batch_file" 2>/dev/null || true
    echo "flush map inet gargoyle-qos-priority ${direction}_udp_${port_dir}_map" >> "$nft_batch_file" 2>/dev/null || true

    add_elements_to_map() {
        local map_name="$1" entries="$2"
        [ -z "$entries" ] && return
        local entry
        for entry in $entries; do
            local class=$(echo "$entry" | cut -d: -f1)
            local ports=$(echo "$entry" | cut -d: -f2-)
            local clean_ports=$(echo "$ports" | tr -d '[:space:]')
            local nft_ports="$clean_ports"
            local class_id=$(get_class_id "$direction" "$class") || continue
            echo "add element inet gargoyle-qos-priority $map_name { $nft_ports : goto class_${class_id}_set }" >> "$nft_batch_file"
        done
    }

    if [ -n "$pure_tcp_ports" ]; then
        add_elements_to_map "${direction}_tcp_${port_dir}_map" "$pure_tcp_ports"
    fi
    if [ -n "$pure_udp_ports" ]; then
        add_elements_to_map "${direction}_udp_${port_dir}_map" "$pure_udp_ports"
    fi
    if [ -n "$pure_tcp_udp_ports" ]; then
        add_elements_to_map "${direction}_tcp_${port_dir}_map" "$pure_tcp_udp_ports"
        add_elements_to_map "${direction}_udp_${port_dir}_map" "$pure_tcp_udp_ports"
    fi

    # --- 3. 在分类链中添加 vmap 规则（优先于复杂规则） ---
    echo "flush chain inet gargoyle-qos-priority $chain" >> "$nft_batch_file"

    if [ -n "$pure_tcp_ports$pure_tcp_udp_ports" ]; then
        echo "add rule inet gargoyle-qos-priority $chain meta nfproto ipv4 meta l4proto tcp tcp $port_dir vmap @${direction}_tcp_${port_dir}_map" >> "$nft_batch_file"
        echo "add rule inet gargoyle-qos-priority $chain meta nfproto ipv6 meta l4proto tcp tcp $port_dir vmap @${direction}_tcp_${port_dir}_map" >> "$nft_batch_file"
    fi
    if [ -n "$pure_udp_ports$pure_tcp_udp_ports" ]; then
        echo "add rule inet gargoyle-qos-priority $chain meta nfproto ipv4 meta l4proto udp udp $port_dir vmap @${direction}_udp_${port_dir}_map" >> "$nft_batch_file"
        echo "add rule inet gargoyle-qos-priority $chain meta nfproto ipv6 meta l4proto udp udp $port_dir vmap @${direction}_udp_${port_dir}_map" >> "$nft_batch_file"
    fi

    # --- 4. 添加复杂规则 ---
    for rule_entry in $complex_rules; do
        IFS=':' read -r r_name r_class r_order r_proto r_srcport r_dstport r_connbytes r_family r_state <<EOF
$rule_entry
EOF
        local class_mark=$(get_class_mark "$direction" "$r_class")
        local class_id=$(get_class_id "$direction" "$r_class")
        [ -z "$class_mark" ] || [ -z "$class_id" ] && continue
        [ -z "$r_family" ] && r_family="inet"
        build_complex_rule_fast "$r_name" "$chain" "$class_mark" "$r_family" "$r_proto" "$r_srcport" "$r_dstport" "$r_connbytes" "$r_state" "$class_id" >> "$nft_batch_file"
    done

    # 执行批处理
    local batch_success=0
    if [ -s "$nft_batch_file" ]; then
        log_info "执行 nft 批处理..."
        local nft_output=$(nft -f "$nft_batch_file" 2>&1)
        local nft_ret=$?
        if [ -n "$nft_output" ]; then
            echo "$nft_output" | logger -t "qos_gargoyle"
        fi
        if [ $nft_ret -eq 0 ]; then
            log_info "✅ 规则应用成功"
            batch_success=0
        else
            log_error "❌ 规则应用失败 (退出码: $nft_ret)"
            log_error "批处理文件内容:"
            cat "$nft_batch_file" | while IFS= read -r line; do log_error "  $line"; done
            batch_success=1
        fi
    fi

    rm -f "$nft_batch_file" 2>/dev/null
    rm -f "$temp_config" 2>/dev/null
    return $batch_success
}

apply_all_rules() {
    local rule_type="$1" mask="$2" chain="$3"
    log_info "开始应用 $rule_type 规则到链 $chain (掩码: $mask)"
    apply_enhanced_direction_rules "$rule_type" "$chain" "$mask"
}

# 算法检测
ALGORITHM=$(uci -q get ${CONFIG_FILE}.global.algorithm 2>/dev/null || echo "htb_cake")
if [ "$ALGORITHM" = "cake" ] || [ "$ALGORITHM" = "cake_dscp" ]; then
    echo "[$(date '+%H:%M:%S')] qos_gargoyle 信息: 当前算法为 $ALGORITHM，无需生成分类规则，退出" >&2
    logger -t "qos_gargoyle" "信息: 当前算法为 $ALGORITHM，无需生成分类规则，退出"
    return 0
fi

if [ "$(basename "$0")" = "rule.sh" ]; then
    echo "此脚本为辅助模块，不应直接执行" >&2
    exit 1
fi