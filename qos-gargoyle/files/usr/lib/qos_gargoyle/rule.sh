#!/bin/sh
# 规则辅助模块 (rule.sh)
# 版本: 2.4.3 - 修复速率限制链中注释行误处理；集合族文件路径常量；ipset 加载失败不中断
# 完全吸收 qosmate 优点：支持 UCI ipset、速率限制、ACK 限速、TCP 升级、内联规则、健康检查等

: ${DEBUG:=0}  # 默认关闭调试

CONFIG_FILE="qos_gargoyle"
TEMP_FILES=""
RULESET_DIR="/etc/qos_gargoyle/rulesets"
RULESET_MERGED_FLAG="/tmp/qos_ruleset_merged"
CLASS_MARKS_FILE=""  # 标记映射文件（由主脚本设置或自动创建）

# ========== 新增配置常量（可从 UCI 覆盖） ==========
ENABLE_RATELIMIT=0
ENABLE_ACK_LIMIT=0
ENABLE_TCP_UPGRADE=0
SAVE_NFT_RULES=0
RATELIMIT_CHAIN="ratelimit"
CUSTOM_EGRESS_FILE="/etc/qos_gargoyle/egress_custom.nft"
CUSTOM_INGRESS_FILE="/etc/qos_gargoyle/ingress_custom.nft"
ACK_SLOW=50
ACK_MED=100
ACK_FAST=500
ACK_XFAST=5000

# ========== 新增常量：集合族文件路径 ==========
SET_FAMILIES_FILE="/tmp/qos_gargoyle_set_families"

# ========== 全局标志 ==========
_IPSET_LOADED=0  # 防止重复加载 ipset 集合

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

# ========== 加载全局配置中的开关 ==========
load_global_config() {
    ENABLE_RATELIMIT=$(uci -q get ${CONFIG_FILE}.global.enable_ratelimit 2>/dev/null)
    [ -z "$ENABLE_RATELIMIT" ] && ENABLE_RATELIMIT=0
    
    ENABLE_ACK_LIMIT=$(uci -q get ${CONFIG_FILE}.global.enable_ack_limit 2>/dev/null)
    [ -z "$ENABLE_ACK_LIMIT" ] && ENABLE_ACK_LIMIT=0
    
    ENABLE_TCP_UPGRADE=$(uci -q get ${CONFIG_FILE}.global.enable_tcp_upgrade 2>/dev/null)
    [ -z "$ENABLE_TCP_UPGRADE" ] && ENABLE_TCP_UPGRADE=0
    
    SAVE_NFT_RULES=$(uci -q get ${CONFIG_FILE}.global.save_nft_rules 2>/dev/null)
    [ -z "$SAVE_NFT_RULES" ] && SAVE_NFT_RULES=0
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

# ========== 哈希函数 ==========
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

# ========== 标记分配 ==========
init_class_marks_file() {
    if [ -z "$CLASS_MARKS_FILE" ]; then
        CLASS_MARKS_FILE="/tmp/qos_class_marks_$$"
        TEMP_FILES="$TEMP_FILES $CLASS_MARKS_FILE"
    fi
}

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

    i=1
    while [ $i -le 16 ]; do
        eval "mark_used_${direction}_${i}=0"
        i=$((i + 1))
    done

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

load_all_config_options() {
    local config_name="$1"
    local section_id="$2"
    local prefix="$3"
    
    local escaped_section_id=$(printf "%s" "$section_id" | sed 's/[][\.*?^$()+{}|]/\\&/g')
    
    for var in class order enabled proto srcport dstport connbytes_kb family state src_ip dest_ip; do
        eval "${prefix}${var}=''"
    done
    
    local config_data=$(uci show "${config_name}.${section_id}" 2>/dev/null)
    local val
    
    # class 必须存在
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.class=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
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
            val=$(echo "$val" | tr -d '[:space:]' | sed 's/[^{},a-zA-Z]//g')
            eval "${prefix}state=\"$val\""
        else
            log_warn "规则 $section_id 连接状态 '$val' 无效，忽略此字段"
        fi
    fi
    
    # src_ip (扩展字段)
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.src_ip=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        eval "${prefix}src_ip=\"$val\""
    fi
    
    # dest_ip (扩展字段)
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.dest_ip=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r')
        eval "${prefix}dest_ip=\"$val\""
    fi
    
    return 0
}

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
        IFS=':' read -r r_name r_class r_order r_enabled r_proto r_srcport r_dstport r_connbytes r_family r_state r_src_ip r_dest_ip <<EOF
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

# ========== UCI ipset 生成 nftables 集合 ==========
generate_ipset_sets() {
    [ "$_IPSET_LOADED" -eq 1 ] && return 0  # 已加载过，跳过
    
    local sets_file=$(mktemp /tmp/qos_ipset_sets_XXXXXX)
    local families_file="$SET_FAMILIES_FILE"
    TEMP_FILES="$TEMP_FILES $sets_file"
    
    # 清空或创建族文件
    > "$families_file"
    
    process_ipset_section() {
        local section="$1"
        local name enabled mode family timeout ip4 ip6
        local ip4_list ip6_list
        
        config_get_bool enabled "$section" enabled 1
        [ "$enabled" -eq 0 ] && return 0
        
        config_get name "$section" name
        [ -z "$name" ] && { log_warn "ipset 节 $section 缺少 name，跳过"; return 0; }
        
        config_get mode "$section" mode "static"
        config_get family "$section" family "ipv4"
        config_get timeout "$section" timeout "1h"
        
        # 验证族
        case "$family" in
            ipv4|ipv6) ;;
            *) log_warn "ipset $name 族 '$family' 无效，使用 ipv4"; family="ipv4" ;;
        esac
        
        # 获取 IP 列表
        if [ "$family" = "ipv6" ]; then
            config_get ip6 "$section" ip6
            ip6_list="$ip6"
        else
            config_get ip4 "$section" ip4
            ip4_list="$ip4"
        fi
        
        # 写入族信息供其他函数使用
        echo "$name $family" >> "$families_file"
        
        local set_flags=""
        local elements=""
        
        if [ "$mode" = "dynamic" ]; then
            set_flags="dynamic, timeout"
            echo "add set inet gargoyle-qos-priority $name { type ${family}_addr; flags $set_flags; timeout $timeout; }" >> "$sets_file"
        else
            set_flags="interval"
            local ip_list=""
            if [ "$family" = "ipv6" ]; then
                ip_list="$ip6_list"
            else
                ip_list="$ip4_list"
            fi
            
            if [ -n "$ip_list" ]; then
                # 压缩连续空格为单逗号
                elements=$(echo "$ip_list" | sed 's/ \+/,/g')
                echo "add set inet gargoyle-qos-priority $name { type ${family}_addr; flags $set_flags; elements = { $elements }; }" >> "$sets_file"
            else
                echo "add set inet gargoyle-qos-priority $name { type ${family}_addr; flags $set_flags; }" >> "$sets_file"
            fi
        fi
        
        log_info "已生成 ipset: $name ($family, mode=$mode)"
    }
    
    # 遍历所有 ipset 节
    local sections=$(load_all_config_sections "$CONFIG_FILE" "ipset")
    for section in $sections; do
        process_ipset_section "$section"
    done
    
    # 如果有集合定义，执行批量添加
    if [ -s "$sets_file" ]; then
        nft -f "$sets_file" 2>/dev/null || {
            log_warn "部分 ipset 集合加载失败，请检查 UCI 配置"
        }
        log_info "已加载 UCI 定义的 ipset 集合"
    fi
    
    rm -f "$sets_file"
    _IPSET_LOADED=1
}

# ========== 速率限制辅助函数 ==========
build_device_conditions_for_direction() {
    local target_values="$1" direction="$2" result_var="$3"
    local result="" ipv4_pos="" ipv4_neg="" ipv6_pos="" ipv6_neg=""
    local value negation v
    
    for value in $target_values; do
        negation=""
        v="$value"
        case "$v" in '!='*) negation="!="; v="${v#!=}"; ;; esac
        
        # 集合引用
        case "$v" in '@'*)
            local setname="${v#@}"
            local set_family
            # 尝试从缓存文件获取族，若文件不存在或找不到，尝试查询现有集合
            if [ -f "$SET_FAMILIES_FILE" ]; then
                set_family="$(awk -v set="$setname" '$1 == set {print $2}' "$SET_FAMILIES_FILE" 2>/dev/null)"
            fi
            if [ -z "$set_family" ]; then
                # 尝试从现有 nft 集合获取族（需要 nft 支持）
                if command -v nft >/dev/null 2>&1; then
                    set_family=$(nft list set inet gargoyle-qos-priority "$setname" 2>/dev/null | grep -o 'type [a-z0-9_]*' | head -1 | awk '{print $2}')
                    set_family=${set_family%_addr}
                fi
            fi
            if [ -z "$set_family" ]; then
                log_warn "无法确定集合 $setname 的地址族，将视为 IPv4（可能导致规则错误）"
                set_family="ipv4"
            fi
            local ip_prefix='ip'
            [ "$set_family" = "ipv6" ] && ip_prefix='ip6'
            if [ -n "$negation" ]; then
                result="${result}${result:+ }${ip_prefix} ${direction} != @${setname}"
            else
                result="${result}${result:+ }${ip_prefix} ${direction} @${setname}"
            fi
            ;;
        *)
            # 检测地址类型
            if printf '%s' "$v" | grep -q ':' && ! printf '%s' "$v" | grep -qE '^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$'; then
                # IPv6
                if [ -n "$negation" ]; then
                    ipv6_neg="${ipv6_neg}${ipv6_neg:+,}${v}"
                else
                    ipv6_pos="${ipv6_pos}${ipv6_pos:+,}${v}"
                fi
            else
                # IPv4
                if [ -n "$negation" ]; then
                    ipv4_neg="${ipv4_neg}${ipv4_neg:+,}${v}"
                else
                    ipv4_pos="${ipv4_pos}${ipv4_pos:+,}${v}"
                fi
            fi
            ;;
        esac
    done
    
    [ -n "$ipv4_neg" ] && result="${result}${result:+ }ip ${direction} != { ${ipv4_neg} }"
    [ -n "$ipv4_pos" ] && result="${result}${result:+ }ip ${direction} { ${ipv4_pos} }"
    [ -n "$ipv6_neg" ] && result="${result}${result:+ }ip6 ${direction} != { ${ipv6_neg} }"
    [ -n "$ipv6_pos" ] && result="${result}${result:+ }ip6 ${direction} { ${ipv6_pos} }"
    
    eval "${result_var}=\"\${result}\""
}

generate_ratelimit_rules() {
    local rules=""
    
    process_ratelimit_section() {
        local section="$1"
        local name enabled download_limit upload_limit burst_factor target_values
        local meter_suffix download_kbytes upload_kbytes
        local download_burst upload_burst
        local meter_hash
        
        config_get_bool enabled "$section" enabled 1
        [ "$enabled" -eq 0 ] && return 0
        
        config_get name "$section" name
        [ -z "$name" ] && return 0
        
        config_get download_limit "$section" download_limit "0"
        config_get upload_limit "$section" upload_limit "0"
        config_get burst_factor "$section" burst_factor "1.0"
        config_get target_values "$section" target
        
        [ -z "$target_values" ] && return 0
        [ "$download_limit" -eq 0 ] && [ "$upload_limit" -eq 0 ] && return 0
        
        # 生成唯一 meter 后缀（防止冲突）
        meter_hash=$(printf "%s" "$section" | cksum | cut -d' ' -f1)
        meter_suffix="${name}_${meter_hash}"
        download_kbytes=$((download_limit / 8))
        upload_kbytes=$((upload_limit / 8))
        
        # 计算 burst
        local download_burst_param='' upload_burst_param=''
        case "$burst_factor" in
            0|0.0|0.00) ;;
            *.*) 
                local burst_int="${burst_factor%.*}" burst_dec="${burst_factor#*.}"
                [ -z "$burst_int" ] && burst_int='0'
                [ -z "$burst_dec" ] && burst_dec='0'
                case "${#burst_dec}" in
                    1) burst_dec="${burst_dec}0" ;;
                    2) ;;
                    *) burst_dec="${burst_dec:0:2}" ;;
                esac
                local download_burst=$((download_kbytes * burst_int + download_kbytes * burst_dec / 100))
                local upload_burst=$((upload_kbytes * burst_int + upload_kbytes * burst_dec / 100))
                [ "$download_burst" -gt 0 ] && download_burst_param=" burst ${download_burst} kbytes"
                [ "$upload_burst" -gt 0 ] && upload_burst_param=" burst ${upload_burst} kbytes"
                ;;
            *)
                local download_burst=$((download_kbytes * burst_factor))
                local upload_burst=$((upload_kbytes * burst_factor))
                download_burst_param=" burst ${download_burst} kbytes"
                upload_burst_param=" burst ${upload_burst} kbytes"
                ;;
        esac
        
        # 分离 IPv4 和 IPv6 目标
        local targets_v4='' targets_v6='' value prefix setname set_family
        for value in $target_values; do
            prefix=''
            case "$value" in '!='*) prefix='!='; value="${value#!=}"; ;; esac
            case "$value" in '@'*)
                setname="${value#@}"
                if [ -f "$SET_FAMILIES_FILE" ]; then
                    set_family="$(awk -v set="$setname" '$1 == set {print $2}' "$SET_FAMILIES_FILE" 2>/dev/null)"
                else
                    set_family="ipv4"
                fi
                if [ "$set_family" = "ipv6" ]; then
                    targets_v6="${targets_v6}${targets_v6:+ }${prefix}${value}"
                else
                    targets_v4="${targets_v4}${targets_v4:+ }${prefix}${value}"
                fi
                ;;
            *)
                if printf '%s' "$value" | grep -q ':' && ! printf '%s' "$value" | grep -qE '^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$'; then
                    targets_v6="${targets_v6}${targets_v6:+ }${prefix}${value}"
                else
                    targets_v4="${targets_v4}${targets_v4:+ }${prefix}${value}"
                fi
                ;;
            esac
        done
        
        # 生成 IPv4 规则
        if [ -n "$targets_v4" ]; then
            if [ "$download_limit" -gt 0 ]; then
                local download_conditions_v4=''
                build_device_conditions_for_direction "$targets_v4" "daddr" download_conditions_v4
                [ -n "$download_conditions_v4" ] && rules="${rules}
        # ${name} - Download limit (IPv4)
        ${download_conditions_v4} meter ${meter_suffix}_dl4 { ip daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} } counter drop comment \"${name} download\""
            fi
            if [ "$upload_limit" -gt 0 ]; then
                local upload_conditions_v4=''
                build_device_conditions_for_direction "$targets_v4" "saddr" upload_conditions_v4
                [ -n "$upload_conditions_v4" ] && rules="${rules}
        # ${name} - Upload limit (IPv4)
        ${upload_conditions_v4} meter ${meter_suffix}_ul4 { ip saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} } counter drop comment \"${name} upload\""
            fi
        fi
        
        # 生成 IPv6 规则
        if [ -n "$targets_v6" ]; then
            if [ "$download_limit" -gt 0 ]; then
                local download_conditions_v6=''
                build_device_conditions_for_direction "$targets_v6" "daddr" download_conditions_v6
                [ -n "$download_conditions_v6" ] && rules="${rules}
        # ${name} - Download limit (IPv6)
        ${download_conditions_v6} meter ${meter_suffix}_dl6 { ip6 daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} } counter drop comment \"${name} download\""
            fi
            if [ "$upload_limit" -gt 0 ]; then
                local upload_conditions_v6=''
                build_device_conditions_for_direction "$targets_v6" "saddr" upload_conditions_v6
                [ -n "$upload_conditions_v6" ] && rules="${rules}
        # ${name} - Upload limit (IPv6)
        ${upload_conditions_v6} meter ${meter_suffix}_ul6 { ip6 saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} } counter drop comment \"${name} upload\""
            fi
        fi
    }
    
    # 遍历所有 ratelimit 节
    local sections=$(load_all_config_sections "$CONFIG_FILE" "ratelimit")
    for section in $sections; do
        process_ratelimit_section "$section"
    done
    
    echo "$rules"
}

setup_ratelimit_chain() {
    [ "$ENABLE_RATELIMIT" != "1" ] && return 0
    local rules=$(generate_ratelimit_rules)
    if [ -n "$rules" ]; then
        local temp_ratelimit_file=$(mktemp /tmp/qos_ratelimit_XXXXXX)
        TEMP_FILES="$TEMP_FILES $temp_ratelimit_file"
        
        # 创建链（如果不存在）
        echo "add chain inet gargoyle-qos-priority $RATELIMIT_CHAIN '{ type filter hook forward priority 0; policy accept; }'" > "$temp_ratelimit_file"
        # 清空链
        echo "flush chain inet gargoyle-qos-priority $RATELIMIT_CHAIN" >> "$temp_ratelimit_file"
        # 添加规则，跳过注释行和空行
        echo "$rules" | while IFS= read -r rule; do
            [ -z "$rule" ] && continue
            [ "${rule#\#}" != "$rule" ] && continue  # 跳过以 # 开头的行
            echo "add rule inet gargoyle-qos-priority $RATELIMIT_CHAIN $rule" >> "$temp_ratelimit_file"
        done
        
        # 执行批量添加
        nft -f "$temp_ratelimit_file" 2>/dev/null || {
            log_error "无法创建速率限制链，请检查 nftables 语法"
            return 1
        }
        log_info "速率限制链已创建并填充规则"
    fi
}

# ========== ACK 限速规则生成（输出 add rule） ==========
generate_ack_limit_rules() {
    [ "$ENABLE_ACK_LIMIT" != "1" ] && return
    local slow_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.slow_rate 2>/dev/null)
    local med_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.med_rate 2>/dev/null)
    local fast_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.fast_rate 2>/dev/null)
    local xfast_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.xfast_rate 2>/dev/null)
    [ -n "$slow_rate" ] && ACK_SLOW="$slow_rate"
    [ -n "$med_rate" ] && ACK_MED="$med_rate"
    [ -n "$fast_rate" ] && ACK_FAST="$fast_rate"
    [ -n "$xfast_rate" ] && ACK_XFAST="$xfast_rate"
    
    cat <<EOF
# ACK rate limiting
add rule inet gargoyle-qos-priority filter_qos_egress meta length < 100 tcp flags ack add @xfst4ack {ct id . ct direction limit rate over ${ACK_XFAST}/second} counter jump drop995
add rule inet gargoyle-qos-priority filter_qos_egress meta length < 100 tcp flags ack add @fast4ack {ct id . ct direction limit rate over ${ACK_FAST}/second} counter jump drop95
add rule inet gargoyle-qos-priority filter_qos_egress meta length < 100 tcp flags ack add @med4ack {ct id . ct direction limit rate over ${ACK_MED}/second} counter jump drop50
add rule inet gargoyle-qos-priority filter_qos_egress meta length < 100 tcp flags ack add @slow4ack {ct id . ct direction limit rate over ${ACK_SLOW}/second} counter jump drop50
EOF
}

# ========== TCP 升级规则生成（输出 add rule） ==========
generate_tcp_upgrade_rules() {
    [ "$ENABLE_TCP_UPGRADE" != "1" ] && return
    
    # 获取 realtime 类的标记
    local realtime_class=""
    local class_id=$(uci -q get ${CONFIG_FILE}.idclass.class_realtime 2>/dev/null)
    
    # 方式1：通过 idclass.class_realtime 数字查找
    if [ -n "$class_id" ]; then
        # 尝试常见的类名模式
        for prefix in upload_class uclass; do
            local candidate="${prefix}_${class_id}"
            if uci -q get ${CONFIG_FILE}.${candidate} >/dev/null 2>&1; then
                realtime_class="$candidate"
                break
            fi
        done
        # 也可能直接是 upload_class_realtime 或 uclass_realtime
        if [ -z "$realtime_class" ]; then
            for prefix in upload_class uclass; do
                local candidate="${prefix}_realtime"
                if uci -q get ${CONFIG_FILE}.${candidate} >/dev/null 2>&1; then
                    realtime_class="$candidate"
                    break
                fi
            done
        fi
    fi
    
    # 方式2：查找名称包含 "realtime" 的 upload_class
    if [ -z "$realtime_class" ]; then
        local upload_classes=$(load_all_config_sections "$CONFIG_FILE" "upload_class")
        for cls in $upload_classes; do
            local name=$(uci -q get ${CONFIG_FILE}.${cls}.name 2>/dev/null)
            if [ "$name" = "realtime" ]; then
                realtime_class="$cls"
                break
            fi
        done
    fi
    
    # 方式3：回退到第一个 upload_class 或默认 uclass_1
    if [ -z "$realtime_class" ]; then
        local first_upload=$(load_all_config_sections "$CONFIG_FILE" "upload_class" | head -1)
        if [ -n "$first_upload" ]; then
            realtime_class="$first_upload"
            log_warn "TCP升级：未找到 realtime 类，将使用第一个上传类 $realtime_class"
        else
            log_warn "TCP升级：未找到任何上传类，将禁用此功能"
            return
        fi
    fi
    
    local realtime_mark=$(get_class_mark "upload" "$realtime_class" 2>/dev/null)
    if [ -z "$realtime_mark" ]; then
        log_error "TCP升级：无法获取类 $realtime_class 的标记，跳过规则生成"
        return
    fi
    
    cat <<EOF
# TCP upgrade for slow connections (using fwmark)
add rule inet gargoyle-qos-priority filter_qos_egress meta l4proto tcp ct state established meta nfproto ipv4 add @slowtcp {ct id . ct direction limit rate 150/second burst 150 packets } meta mark set $realtime_mark counter
add rule inet gargoyle-qos-priority filter_qos_egress meta l4proto tcp ct state established meta nfproto ipv6 add @slowtcp {ct id . ct direction limit rate 150/second burst 150 packets } meta mark set $realtime_mark counter
EOF
}

# ========== 内联规则支持 ==========
get_custom_include() {
    local file="$1"
    local tmp_file="/tmp/qos_gargoyle_custom_check.nft"
    if [ -s "$file" ]; then
        {
            printf '%s\n\t%s\n' "table inet __qos_gargoyle_ctx {" "chain __custom_ctx {"
            cat "$file"
            printf '\n\t%s\n%s\n' "}" "}"
        } > "$tmp_file"
        if nft --check --file "$tmp_file" 2>/dev/null; then
            echo "include \"$file\""
        else
            log_warn "自定义规则文件 $file 语法错误，已忽略"
        fi
        rm -f "$tmp_file"
    fi
}

# ========== nft 规则构建 ==========
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
    local src_ip="${11}"
    local dest_ip="${12}"
    
    # 自动检测 IPv4/IPv6
    local has_ipv4=0 has_ipv6=0
    local ipv4_cond="" ipv6_cond=""
    
    if [ -n "$src_ip" ]; then
        if echo "$src_ip" | grep -q ':'; then
            has_ipv6=1
            ipv6_cond="$ipv6_cond ip6 saddr $src_ip"
        else
            has_ipv4=1
            ipv4_cond="$ipv4_cond ip saddr $src_ip"
        fi
    fi
    if [ -n "$dest_ip" ]; then
        if echo "$dest_ip" | grep -q ':'; then
            has_ipv6=1
            ipv6_cond="$ipv6_cond ip6 daddr $dest_ip"
        else
            has_ipv4=1
            ipv4_cond="$ipv4_cond ip daddr $dest_ip"
        fi
    fi
    
    # 根据 family 覆盖自动检测
    case "$family" in
        ip|inet4|ipv4) has_ipv4=1; has_ipv6=0 ;;
        ip6|inet6|ipv6) has_ipv4=0; has_ipv6=1 ;;
        inet) ;; # 保留自动检测
    esac
    
    # 如果没有指定任何 IP，且 family=inet，则生成双栈规则
    if [ "$has_ipv4" -eq 0 ] && [ "$has_ipv6" -eq 0 ]; then
        has_ipv4=1
        has_ipv6=1
    fi
    
    # 公共条件
    local common_cond=""
    if [ "$proto" = "tcp" ]; then
        common_cond="$common_cond meta l4proto tcp"
    elif [ "$proto" = "udp" ]; then
        common_cond="$common_cond meta l4proto udp"
    elif [ "$proto" = "tcp_udp" ]; then
        common_cond="$common_cond meta l4proto { tcp, udp }"
    elif [ -n "$proto" ] && [ "$proto" != "all" ]; then
        common_cond="$common_cond meta l4proto $proto"
    fi
    
    # 端口处理
    if [ "$proto" = "tcp" ] || [ "$proto" = "udp" ] || [ "$proto" = "tcp_udp" ]; then
        case "$chain" in
            *"ingress"*)
                if [ -n "$dstport" ]; then
                    common_cond="$common_cond th dport { $(echo "$dstport" | tr -d ' ') }"
                elif [ -n "$srcport" ]; then
                    common_cond="$common_cond th sport { $(echo "$srcport" | tr -d ' ') }"
                fi
                ;;
            *)
                if [ -n "$srcport" ]; then
                    common_cond="$common_cond th sport { $(echo "$srcport" | tr -d ' ') }"
                elif [ -n "$dstport" ]; then
                    common_cond="$common_cond th dport { $(echo "$dstport" | tr -d ' ') }"
                fi
                ;;
        esac
    fi
    
    # 连接状态
    if [ -n "$state" ]; then
        local state_value=$(echo "$state" | tr -d '{}')
        if echo "$state_value" | grep -q ','; then
            common_cond="$common_cond ct state { $state_value }"
        else
            common_cond="$common_cond ct state $state_value"
        fi
    fi
    
    # 连接字节数
    if [ -n "$connbytes_kb" ] && [ "$connbytes_kb" != "0" ]; then
        if echo "$connbytes_kb" | grep -q '-'; then
            local min_val=$(echo "$connbytes_kb" | cut -d- -f1)
            local max_val=$(echo "$connbytes_kb" | cut -d- -f2)
            local min_bytes=$((min_val * 1024))
            local max_bytes=$((max_val * 1024))
            common_cond="$common_cond ct bytes >= $min_bytes ct bytes <= $max_bytes"
        elif echo "$connbytes_kb" | grep -qE '^([<>]?=?|!=)[0-9]+$'; then
            local operator=$(echo "$connbytes_kb" | sed 's/[0-9]*$//')
            local value=$(echo "$connbytes_kb" | grep -o '[0-9]\+')
            [ -z "$operator" ] && operator=">="
            local bytes_value=$((value * 1024))
            common_cond="$common_cond ct bytes $operator $bytes_value"
        fi
    fi
    
    local base_cmd="add rule inet gargoyle-qos-priority $chain"
    
    # 生成 IPv4 规则
    if [ "$has_ipv4" -eq 1 ]; then
        local cmd="$base_cmd meta nfproto ipv4 $common_cond"
        [ -n "$ipv4_cond" ] && cmd="$cmd $ipv4_cond"
        cmd="$cmd meta mark set $class_mark counter"
        echo "$cmd"
    fi
    
    # 生成 IPv6 规则
    if [ "$has_ipv6" -eq 1 ]; then
        local cmd="$base_cmd meta nfproto ipv6 $common_cond"
        [ -n "$ipv6_cond" ] && cmd="$cmd $ipv6_cond"
        cmd="$cmd meta mark set $class_mark counter"
        echo "$cmd"
    fi
}

apply_enhanced_direction_rules() {
    local rule_type="$1"
    local chain="$2"
    local mask="$3"
    
    log_info "应用增强$rule_type规则到链: $chain, 掩码: $mask"
    
    local direction=""
    [ "$chain" = "filter_qos_egress" ] && direction="upload"
    [ "$chain" = "filter_qos_ingress" ] && direction="download"
    
    # 确保 ipset 集合已加载（仅在第一次调用时加载），失败时记录错误但不中断
    generate_ipset_sets || log_warn "ipset 集合加载失败，部分规则可能无法匹配集合引用"
    
    local rule_list=$(load_all_config_sections "$CONFIG_FILE" "$rule_type")
    [ -z "$rule_list" ] && { log_info "未找到$rule_type规则配置"; return 0; }
    
    log_info "找到$rule_type规则: $rule_list"
    
    local temp_config=$(mktemp /tmp/qos_rule_config_XXXXXX 2>/dev/null)
    [ -z "$temp_config" ] && { log_error "无法创建配置临时文件"; return 1; }
    TEMP_FILES="$TEMP_FILES $temp_config"
    
    local IFS=' '
    set -- $rule_list
    for rule; do
        [ -n "$rule" ] || continue
        if load_all_config_options "$CONFIG_FILE" "$rule" "tmp_"; then
            echo "$rule:$tmp_class:$tmp_order:$tmp_enabled:$tmp_proto:$tmp_srcport:$tmp_dstport:$tmp_connbytes_kb:$tmp_family:$tmp_state:$tmp_src_ip:$tmp_dest_ip" >> "$temp_config"
        fi
    done
    
    local sorted_rule_list=$(sort_rules_by_priority_fast "$temp_config")
    if [ -z "$sorted_rule_list" ]; then
        log_info "没有可用的启用规则"
        rm -f "$temp_config" 2>/dev/null
        return 0
    fi
    
    local nft_batch_file=$(mktemp /tmp/qos_nft_batch_XXXXXX 2>/dev/null)
    [ -z "$nft_batch_file" ] && { log_error "无法创建nft批处理文件"; rm -f "$temp_config"; return 1; }
    TEMP_FILES="$TEMP_FILES $nft_batch_file"
    
    # 为出口链预先添加必需的集合和链定义
    if [ "$chain" = "filter_qos_egress" ]; then
        cat <<EOF >> "$nft_batch_file"
# ACK 限速所需的动态集合
add set inet gargoyle-qos-priority xfst4ack { typeof ct id . ct direction; flags dynamic; timeout 5m; } 2>/dev/null
add set inet gargoyle-qos-priority fast4ack { typeof ct id . ct direction; flags dynamic; timeout 5m; } 2>/dev/null
add set inet gargoyle-qos-priority med4ack { typeof ct id . ct direction; flags dynamic; timeout 5m; } 2>/dev/null
add set inet gargoyle-qos-priority slow4ack { typeof ct id . ct direction; flags dynamic; timeout 5m; } 2>/dev/null
# 概率丢包链
add chain inet gargoyle-qos-priority drop995
add chain inet gargoyle-qos-priority drop95
add chain inet gargoyle-qos-priority drop50
# 概率丢包链内的规则
add rule inet gargoyle-qos-priority drop995 numgen random mod 1000 ge 995 return
add rule inet gargoyle-qos-priority drop995 drop
add rule inet gargoyle-qos-priority drop95 numgen random mod 1000 ge 950 return
add rule inet gargoyle-qos-priority drop95 drop
add rule inet gargoyle-qos-priority drop50 numgen random mod 1000 ge 500 return
add rule inet gargoyle-qos-priority drop50 drop
EOF
        if [ "$ENABLE_TCP_UPGRADE" = "1" ]; then
            cat <<EOF >> "$nft_batch_file"
# TCP 升级所需的动态集合
add set inet gargoyle-qos-priority slowtcp { typeof ct id . ct direction; flags dynamic; timeout 5m; } 2>/dev/null
EOF
        fi
    fi
    
    log_info "按优先级顺序生成nft规则..."
    local rule_count=0
    for rule_name in $sorted_rule_list; do
        local rule_line=$(grep "^$rule_name:" "$temp_config")
        IFS=':' read -r r_name r_class r_order r_enabled r_proto r_srcport r_dstport r_connbytes r_family r_state r_src_ip r_dest_ip <<EOF
$rule_line
EOF
        [ "$r_enabled" = "1" ] || continue
        
        local class_mark=$(get_class_mark "$direction" "$r_class")
        [ -z "$class_mark" ] && { log_error "规则 $rule_name 的类 $r_class 无法获取标记，跳过"; continue; }
        
        [ -z "$r_family" ] && r_family="inet"
        
        build_nft_rule_fast "$rule_name" "$chain" "$class_mark" "$mask" "$r_family" "$r_proto" "$r_srcport" "$r_dstport" "$r_connbytes" "$r_state" "$r_src_ip" "$r_dest_ip" >> "$nft_batch_file"
        rule_count=$((rule_count + 1))
    done
    
    # 添加内联规则 include
    local custom_file=""
    if [ "$chain" = "filter_qos_egress" ]; then
        custom_file="$CUSTOM_EGRESS_FILE"
    else
        custom_file="$CUSTOM_INGRESS_FILE"
    fi
    if [ -f "$custom_file" ]; then
        local include_stmt=$(get_custom_include "$custom_file")
        [ -n "$include_stmt" ] && echo "$include_stmt" >> "$nft_batch_file"
    fi
    
    # 添加 ACK 限速和 TCP 升级规则（仅 egress 链）
    if [ "$chain" = "filter_qos_egress" ]; then
        generate_ack_limit_rules >> "$nft_batch_file"
        generate_tcp_upgrade_rules >> "$nft_batch_file"
    fi
    
    # 执行批处理
    local batch_success=0
    if [ -s "$nft_batch_file" ]; then
        log_info "执行批量nft规则 (共 $rule_count 条)..."
        nft_output=$(nft -f "$nft_batch_file" 2>&1)
        nft_ret=$?
        if [ $nft_ret -eq 0 ]; then
            log_info "✅ 批量规则应用成功"
            if [ "$SAVE_NFT_RULES" = "1" ]; then
                local nft_save_file="/etc/nftables.d/qos_gargoyle_${chain}.nft"
                cp "$nft_batch_file" "$nft_save_file"
                log_info "规则已保存到 $nft_save_file"
            fi
        else
            log_error "❌ 批量规则应用失败 (退出码: $nft_ret)"
            log_error "nft 错误输出: $nft_output"
            batch_success=1
        fi
    fi
    
    rm -f "$nft_batch_file" "$temp_config"
    return $batch_success
}

apply_all_rules() {
    local rule_type="$1"
    local mask="$2"
    local chain="$3"
    log_info "开始应用 $rule_type 规则到链 $chain (掩码: $mask)"
    apply_enhanced_direction_rules "$rule_type" "$chain" "$mask"
}

# ========== 健康检查 ==========
health_check() {
    local errors=0
    local status=""
    
    # 检查 UCI 配置
    if uci -q show ${CONFIG_FILE} >/dev/null 2>&1; then
        status="${status}config:ok;"
    else
        status="${status}config:missing;"
        errors=$((errors+1))
    fi
    
    # 检查 nftables 表
    if nft list table inet gargoyle-qos-priority >/dev/null 2>&1; then
        status="${status}nft:ok;"
    else
        status="${status}nft:missing;"
        errors=$((errors+1))
    fi
    
    # 检查 tc 队列（需要接口）
    local wan_if=$(uci -q get ${CONFIG_FILE}.global.wan_interface 2>/dev/null)
    if [ -n "$wan_if" ] && tc qdisc show dev "$wan_if" 2>/dev/null | grep -qE "htb|hfsc|cake"; then
        status="${status}tc:ok;"
    else
        status="${status}tc:missing;"
        errors=$((errors+1))
    fi
    
    # 检查内核模块
    for mod in ifb sch_htb sch_hfsc sch_cake sch_fq_codel; do
        if ! lsmod 2>/dev/null | grep -q "^$mod"; then
            status="${status}module_${mod}:missing;"
            errors=$((errors+1))
        fi
    done
    
    # 检查标记文件
    if [ -f "$CLASS_MARKS_FILE" ]; then
        status="${status}marks:ok;"
    else
        status="${status}marks:missing;"
        errors=$((errors+1))
    fi
    
    echo "status=$status;errors=$errors"
    return $((errors == 0 ? 0 : 1))
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

# ========== 规则集合并（原样保留） ==========
init_ruleset() {
    local nofix="$1"
    if [ "$nofix" = "1" ]; then
        [ -f "$RULESET_MERGED_FLAG" ] && return 0
        return 0
    fi
    
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

# ========== 自动加载全局配置（当被 source 时） ==========
if [ -z "$_QOS_RULE_SH_LOADED" ] && [ "$(basename "$0")" != "rule.sh" ]; then
    load_global_config
    _QOS_RULE_SH_LOADED=1
fi

# 如果脚本被直接执行
if [ "$(basename "$0")" = "rule.sh" ]; then
    load_global_config
    case "$1" in
        health_check) health_check ;;
        *) echo "此脚本为辅助模块，不应直接执行" >&2 ;;
    esac
    exit 0
fi