#!/bin/sh
# 规则辅助模块 (rule.sh)
# 支持多样化端口、协议、IPv6双栈、连接字节数过滤和连接状态过滤
# version=2.1.3 - 移除未使用的 mask 参数，增强错误处理，IPv6集合名后缀统一

: ${DEBUG:=0}  # 默认关闭调试

CONFIG_FILE="qos_gargoyle"
TEMP_FILES=""
RULESET_DIR="/etc/qos_gargoyle/rulesets"          # 规则集存储目录
RULESET_MERGED_FLAG="/tmp/qos_ruleset_merged"     # 标记文件，避免重复合并
PERSISTENT_CLASS_MARKS="/etc/qos_gargoyle/class_marks"   # 持久化标记文件
IPV6_SET_SUFFIX="6"                                # IPv6集合名后缀，便于统一调整

# ========== 日志函数别名 ==========
log_debug() { [ "$DEBUG" = "1" ] && log "DEBUG" "$@"; }
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

# ========== 规则集合并函数（保持原有备份恢复机制） ==========
init_ruleset() {
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

    if grep -q "^# === RULESET_${ruleset} ===" /etc/config/${CONFIG_FILE} 2>/dev/null; then
        log_info "规则集 $ruleset 已合并到主配置文件，跳过"
        touch "$RULESET_MERGED_FLAG"
        return 0
    fi

    if grep -q "^# === RULESET_" /etc/config/${CONFIG_FILE}; then
        sed -i '/^# === RULESET_/,/^# === RULESET_END ===/d' "/etc/config/${CONFIG_FILE}"
        log_info "已清理之前的规则集"
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

validate_family() {
    local family="$1"
    local param_name="$2"
    
    [ -z "$family" ] && return 0
    
    case "$family" in
        inet|ip|ip6|inet6|ipv4|ipv6) return 0 ;;
        *)
            log_error "$param_name 无效的地址族 '$family'，允许的值: inet, ip, ip6, inet6, ipv4, ipv6"
            return 1 ;;
    esac
}

validate_connbytes() {
    local value="$1"
    local param_name="$2"
    
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
        if ! validate_number "$value" "$param_name" 0 1048576; then
            return 1
        fi
    else
        log_error "$param_name 无效的格式 '$value'，应为数字、数字-数字、或带操作符的数字"
        return 1
    fi
    return 0
}

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
# 初始化标记文件（使用持久化文件）
init_class_marks_file() {
    # 确保目录存在
    mkdir -p /etc/qos_gargoyle
    # 使用持久化文件
    CLASS_MARKS_FILE="$PERSISTENT_CLASS_MARKS"
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

# 获取类别的 class_id（上传 1-16，下载 17-32）
get_class_id() {
    local direction="$1"
    local class="$2"
    local class_id

    class_id=$(echo "$class" | sed -n 's/^[ud]class_\([0-9]\+\)$/\1/p')
    if [ -z "$class_id" ]; then
        log_error "无法从类名 $class 解析 class_id"
        return 1
    fi
    if [ "$direction" = "download" ]; then
        class_id=$((class_id + 16))
    fi
    echo "$class_id"
}

# 为指定方向分配所有类的标记
# 参数：方向（upload/download），类列表（空格分隔）
# 返回：0成功，1失败（冲突无法解决）
allocate_class_marks() {
    local direction="$1"
    local class_list="$2"
    local base_value i class mark

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

    # 检查文件是否可写
    touch "$CLASS_MARKS_FILE" 2>/dev/null || {
        log_error "无法写入标记文件 $CLASS_MARKS_FILE"
        return 1
    }

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

                echo "$direction:$class:$mark_value" >> "$CLASS_MARKS_FILE" || {
                    log_error "写入标记文件失败"
                    return 1
                }
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

# 清空标记文件（停止时调用）
clear_class_marks() {
    rm -f "$PERSISTENT_CLASS_MARKS" 2>/dev/null
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
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r' | sed 's/[^a-zA-Z0-9_-]//g')
        eval "${prefix}class=\"$val\""
    else
        log_warn "配置节 $section_id 缺少 class 参数，忽略此规则"
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
            log_warn "规则 $section_id 协议 '$val' 无效，忽略此字段"
        fi
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.srcport=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_port "$val" "${section_id}.srcport"; then
            val=$(echo "$val" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')
            eval "${prefix}srcport=\"$val\""
        else
            log_warn "规则 $section_id 源端口 '$val' 无效，忽略此字段"
        fi
    fi
    
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
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.connbytes_kb=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_connbytes "$val" "${section_id}.connbytes_kb"; then
            val=$(echo "$val" | sed 's/[^0-9<>!= -]//g' | tr -d ' ')
            eval "${prefix}connbytes_kb=\"$val\""
        else
            log_warn "规则 $section_id 连接字节数 '$val' 无效，忽略此字段"
        fi
    fi
    
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
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.state=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        if validate_state "$val" "${section_id}.state"; then
            val=$(echo "$val" | tr -d '[:space:]' | sed 's/[^{},a-zA-Z]//g')
            eval "${prefix}state=\"$val\""
        else
            log_warn "规则 $section_id 连接状态 '$val' 无效，忽略此字段"
        fi
    fi
    
    return 0
}

# ========== 内存限制计算 ==========
calculate_memory_limit() {
    local config_value="$1"
    local result

    if [ -z "$config_value" ]; then
        echo ""
        return
    fi
    
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
            local min_limit=4
            local max_limit=32
            local result_value=$(echo "$result" | sed 's/Mb//')
            if [ "$result_value" -lt "$min_limit" ] 2>/dev/null; then
                result="${min_limit}Mb"
            elif [ "$result_value" -gt "$max_limit" ] 2>/dev/null; then
                result="${max_limit}Mb"
            fi
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

# ========== 构建nft规则（支持conntrack mark设置） ==========
# 注意：原 mask 参数已移除（此前未被使用）
build_nft_rule_fast() {
    local rule_name="$1"
    local chain="$2"
    local class_mark="$3"
    local family="$4"
    local proto="$5"
    local srcport="$6"
    local dstport="$7"
    local connbytes_kb="$8"
    local state="$9"
    local class_id="${10}"

    local nft_cmd="add rule inet gargoyle-qos-priority $chain"
    
    case "$family" in
        ip|inet4|ipv4)
            nft_cmd="$nft_cmd meta nfproto ipv4"
            ;;
        ip6|inet6|ipv6)
            nft_cmd="$nft_cmd meta nfproto ipv6"
            ;;
        inet|*)
            ;;
    esac
    
    if [ "$proto" = "tcp" ]; then
        nft_cmd="$nft_cmd meta l4proto tcp"
    elif [ "$proto" = "udp" ]; then
        nft_cmd="$nft_cmd meta l4proto udp"
    elif [ "$proto" = "tcp_udp" ]; then
        nft_cmd="$nft_cmd meta l4proto { tcp, udp }"
    elif [ -n "$proto" ] && [ "$proto" != "all" ]; then
        nft_cmd="$nft_cmd meta l4proto $proto"
    fi
    
    if [ "$proto" = "tcp" ] || [ "$proto" = "udp" ] || [ "$proto" = "tcp_udp" ]; then
        case "$chain" in
            *"ingress"*)
                if [ -n "$dstport" ]; then
                    local clean_port=$(echo "$dstport" | tr -d ' ')
                    nft_cmd="$nft_cmd th dport { $clean_port }"
                elif [ -n "$srcport" ]; then
                    local clean_port=$(echo "$srcport" | tr -d ' ')
                    nft_cmd="$nft_cmd th sport { $clean_port }"
                fi
                ;;
            *)
                if [ -n "$srcport" ]; then
                    local clean_port=$(echo "$srcport" | tr -d ' ')
                    nft_cmd="$nft_cmd th sport { $clean_port }"
                elif [ -n "$dstport" ]; then
                    local clean_port=$(echo "$dstport" | tr -d ' ')
                    nft_cmd="$nft_cmd th dport { $clean_port }"
                fi
                ;;
        esac
    fi
    
    if [ -n "$state" ]; then
        local state_value=$(echo "$state" | tr -d '{}')
        if echo "$state_value" | grep -q ','; then
            nft_cmd="$nft_cmd ct state { $state_value }"
        else
            nft_cmd="$nft_cmd ct state $state_value"
        fi
    fi
    
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

    # 设置 conntrack mark（存储 class_id）
    nft_cmd="$nft_cmd ct mark set $class_id"
    # 设置 skb mark
    nft_cmd="$nft_cmd meta mark set $class_mark counter"
    
    echo "$nft_cmd"
}

# ========== 生成基于 DNS 学习集合的规则（使用类别真实名称） ==========
generate_set_rules() {
    local direction="$1"
    local chain="$2"
    local nft_batch_file="$3"

    # 从持久化标记文件中提取该方向的所有类名（去重）
    local class_names=$(grep "^$direction:" "$PERSISTENT_CLASS_MARKS" 2>/dev/null | cut -d: -f2 | sort -u)
    [ -z "$class_names" ] && return 0

    local class_name class_mark class_id realname set_name
    for class_name in $class_names; do
        class_mark=$(get_class_mark "$direction" "$class_name")
        [ -z "$class_mark" ] && continue

        class_id=$(get_class_id "$direction" "$class_name") || continue

        # 获取类的真实名称（如 realtime），并转换为小写
        realname=$(uci -q get ${CONFIG_FILE}.${class_name}.name 2>/dev/null)
        if [ -z "$realname" ]; then
            log_warn "类别 $class_name 未配置 name 选项，无法生成集合规则，跳过"
            continue
        fi
        realname=$(echo "$realname" | tr '[:upper:]' '[:lower:]')
        set_name="${direction}_${realname}"

        if [ "$direction" = "upload" ]; then
            # IPv4 规则
            echo "add rule inet gargoyle-qos-priority $chain ip daddr @$set_name ct mark set $class_id meta mark set $class_mark" >> "$nft_batch_file"
            # IPv6 规则，使用统一后缀
            echo "add rule inet gargoyle-qos-priority $chain ip6 daddr @${set_name}${IPV6_SET_SUFFIX} ct mark set $class_id meta mark set $class_mark" >> "$nft_batch_file"
        else
            # 下载方向：匹配源 IP
            echo "add rule inet gargoyle-qos-priority $chain ip saddr @$set_name ct mark set $class_id meta mark set $class_mark" >> "$nft_batch_file"
            echo "add rule inet gargoyle-qos-priority $chain ip6 saddr @${set_name}${IPV6_SET_SUFFIX} ct mark set $class_id meta mark set $class_mark" >> "$nft_batch_file"
        fi
        log_info "添加集合规则: $direction $class_name ($realname) -> mark $class_mark, class_id $class_id"
    done
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
    
    # 统计启用规则中出现的类数量（只考虑启用规则）
    local class_list=$(grep ":1:" "$temp_config" | cut -d: -f2 | sort -u)
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
    
    log_info "首先生成基于DNS集合的规则..."
    generate_set_rules "$direction" "$chain" "$nft_batch_file"
    
    log_info "然后按优先级顺序生成用户规则..."
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

        # 获取 class_id
        local class_id=$(get_class_id "$direction" "$r_class")
        if [ -z "$class_id" ]; then
            log_error "规则 $rule_name 的类 $r_class 无法获取 class_id，跳过"
            continue
        fi
        
        [ -z "$r_family" ] && r_family="inet"
        
        # 注意：mask 参数已移除，原第4个参数现在为 family
        build_nft_rule_fast "$rule_name" "$chain" "$class_mark" "$r_family" "$r_proto" "$r_srcport" "$r_dstport" "$r_connbytes" "$r_state" "$class_id" >> "$nft_batch_file"
        rule_count=$((rule_count + 1))
    done
    
    local batch_success=0
    if [ -s "$nft_batch_file" ]; then
        log_info "执行批量nft规则 (共 $rule_count 条用户规则 + 集合规则)..."
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