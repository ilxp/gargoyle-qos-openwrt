#!/bin/bash
# 核心库模块 (lib.sh)
# 版本: 3.3.0 - 统一公共函数，增强命令检测，优化临时文件管理
# 提供 QoS 系统基础功能

# ========== 全局配置常量 ==========
: ${DEBUG:=0}
: ${CONFIG_FILE:=qos_gargoyle}
: ${MAX_PHYSICAL_BANDWIDTH:=10000000}
: ${QOS_RUNNING_FILE:=/var/run/qos_gargoyle.running}
: ${CLASS_MARKS_FILE:=/etc/qos_gargoyle/class_marks}
: ${RULESET_DIR:=/etc/qos_gargoyle/rulesets}
: ${RULESET_MERGED_FLAG:=/tmp/qos_ruleset_merged}
: ${SET_FAMILIES_FILE:=/tmp/qos_gargoyle_set_families}
: ${CUSTOM_INLINE_FILE:=/etc/qos_gargoyle/custom_inline.nft}
: ${CUSTOM_FULL_TABLE_FILE:=/etc/qos_gargoyle/custom_rules.nft}
: ${RATELIMIT_CHAIN:=ratelimit}
: ${CUSTOM_VALIDATION_FILE:=/tmp/qos_gargoyle_custom_validation.txt}

# ========== 全局变量 ==========
upload_class_list=""
download_class_list=""
ENABLE_RATELIMIT=0
ENABLE_ACK_LIMIT=0
ENABLE_TCP_UPGRADE=0
SAVE_NFT_RULES=0
ACK_SLOW=50
ACK_MED=100
ACK_FAST=500
ACK_XFAST=5000
AUTO_SPEEDTEST=0
_QOS_TABLE_FLUSHED=0
_IPSET_LOADED=0
_HOOKS_SETUP=0
_UCI_CONFIG_CACHED=0
_UCI_CACHE_FILE=""

# 集合族缓存
declare -A _SET_FAMILY_CACHE=()

# 临时文件数组
TEMP_FILES=()

# ========== 公共辅助函数 ==========
# 去除前导零（空字符串返回空）
strip_leading_zeros() {
    local val="$1"
    if [[ -z "$val" ]]; then
        echo ""
        return
    fi
    val=$(echo "$val" | sed 's/^0*//')
    [[ -z "$val" ]] && val=0
    echo "$val"
}

# ========== 日志函数 ==========
log_debug() { [[ "$DEBUG" == "1" ]] && log "DEBUG" "$@"; }
log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

log() {
    local level="$1"
    local message="$2"
    local tag="qos_gargoyle"
    local prefix=""

    [[ -z "$message" ]] && return

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

    if [[ "$DEBUG" == "1" ]]; then
        echo "$message" | while IFS= read -r line; do
            echo "[$(date '+%H:%M:%S')] $tag $prefix $line" >&2
        done
    fi
}

# ========== 临时文件清理 ==========
cleanup_temp_files() {
    for f in "${TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null
    done
    TEMP_FILES=()
}
trap cleanup_temp_files EXIT INT TERM HUP QUIT

# ========== 锁机制 ==========
LOCK_FILE="/var/run/qos_gargoyle.lock"
LOCK_FD=200
_LOCK_FD_OPEN=0

acquire_lock() {
    if [[ $_LOCK_FD_OPEN -eq 0 ]]; then
        if [[ ! -f "$LOCK_FILE" ]]; then
            touch "$LOCK_FILE" 2>/dev/null || {
                log_error "无法创建锁文件 $LOCK_FILE"
                return 1
            }
        fi
        eval "exec $LOCK_FD>>$LOCK_FILE" 2>/dev/null || {
            log_error "无法打开锁文件 $LOCK_FILE"
            return 1
        }
        _LOCK_FD_OPEN=1
    fi

    if ! flock -n "$LOCK_FD"; then
        log_warn "等待锁释放..."
        if ! flock -w 5 "$LOCK_FD"; then
            log_error "获取锁超时（5秒）"
            eval "exec $LOCK_FD>&-"
            _LOCK_FD_OPEN=0
            return 1
        fi
    fi
    log_debug "成功获取锁"
    return 0
}

release_lock() {
    if [[ $_LOCK_FD_OPEN -eq 1 ]]; then
        flock -u "$LOCK_FD" 2>/dev/null
        eval "exec $LOCK_FD>&-"
        _LOCK_FD_OPEN=0
        log_debug "锁已释放"
    fi
}

# ========== 外部辅助函数 ==========
cleanup_qos_state() {
    log_info "执行 QoS 状态清理"
    rm -f "$QOS_RUNNING_FILE" 2>/dev/null
    rm -f "$SET_FAMILIES_FILE" 2>/dev/null
    rm -f "$CUSTOM_VALIDATION_FILE" 2>/dev/null
}

check_and_handle_zero_bandwidth() {
    local upload_bw="$1"
    local download_bw="$2"
    if [[ "$upload_bw" == "0" ]] && [[ "$download_bw" == "0" ]]; then
        log_info "上传和下载带宽均为 0，QoS 未启动，清除运行文件"
        rm -f "$QOS_RUNNING_FILE" 2>/dev/null
        return 0
    fi
    return 1
}

# ========== 加载全局配置 ==========
load_global_config() {
    local val
    val=$(uci -q get ${CONFIG_FILE}.global.enable_ratelimit 2>/dev/null)
    case "$val" in 1|yes|true|on) ENABLE_RATELIMIT=1 ;; *) ENABLE_RATELIMIT=0 ;; esac

    val=$(uci -q get ${CONFIG_FILE}.global.enable_ack_limit 2>/dev/null)
    case "$val" in 1|yes|true|on) ENABLE_ACK_LIMIT=1 ;; *) ENABLE_ACK_LIMIT=0 ;; esac

    val=$(uci -q get ${CONFIG_FILE}.global.enable_tcp_upgrade 2>/dev/null)
    case "$val" in 1|yes|true|on) ENABLE_TCP_UPGRADE=1 ;; *) ENABLE_TCP_UPGRADE=0 ;; esac

    val=$(uci -q get ${CONFIG_FILE}.global.save_nft_rules 2>/dev/null)
    case "$val" in 1|yes|true|on) SAVE_NFT_RULES=1 ;; *) SAVE_NFT_RULES=0 ;; esac

    val=$(uci -q get ${CONFIG_FILE}.global.auto_speedtest 2>/dev/null)
    case "$val" in 1|yes|true|on) AUTO_SPEEDTEST=1 ;; *) AUTO_SPEEDTEST=0 ;; esac
}

# ========== 数字验证 ==========
validate_number() {
    local value="$1" param_name="$2" min="${3:-0}" max="${4:-2147483647}"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log_error "参数 $param_name 必须是整数: $value"
        return 1
    fi
    value=$(strip_leading_zeros "$value")
    local clean_value=$((value))
    if (( clean_value < min || clean_value > max )); then
        log_error "参数 $param_name 范围应为 $min-$max: $value"
        return 1
    fi
    return 0
}

validate_float() {
    local value="$1" param_name="$2"
    if [[ ! "$value" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        log_error "参数 $param_name 必须是正浮点数: $value"
        return 1
    fi
    return 0
}

# ========== 端口验证 ==========
validate_port() {
    local value="$1" param_name="$2"
    [[ -z "$value" ]] && return 0

    if [[ "$value" == @* ]]; then
        local setname="${value#@}"
        if [[ ! "$setname" =~ ^[a-zA-Z0-9_]+$ ]]; then
            log_error "$param_name 集合名 '$setname' 无效"
            return 1
        fi
        return 0
    fi

    local clean=$(echo "$value" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')
    IFS=',' read -ra parts <<< "$clean"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            local min_port=${part%-*} max_port=${part#*-}
            if ! validate_number "$min_port" "$param_name" 1 65535 ||
               ! validate_number "$max_port" "$param_name" 1 65535 ||
               (( min_port > max_port )); then
                return 1
            fi
        else
            if ! validate_number "$part" "$param_name" 1 65535; then
                return 1
            fi
        fi
    done
    return 0
}

# ========== 协议验证 ==========
validate_protocol() {
    local proto="$1" param_name="$2"
    [[ -z "$proto" || "$proto" == "all" ]] && return 0
    case "$proto" in
        tcp|udp|icmp|icmpv6|gre|esp|ah|sctp|dccp|udplite|tcp_udp) return 0 ;;
        *) log_warn "$param_name 协议名称 '$proto' 不是标准协议，将继续处理"; return 0 ;;
    esac
}

# ========== 地址族验证 ==========
validate_family() {
    local family="$1" param_name="$2"
    [[ -z "$family" ]] && return 0
    case "$family" in
        inet|ip|ip6|inet6|ipv4|ipv6) return 0 ;;
        *) log_error "$param_name 无效的地址族 '$family'"; return 1 ;;
    esac
}

# ========== 连接字节数验证 ==========
validate_connbytes() {
    local value="$1" param_name="$2"
    [[ -z "$value" ]] && return 0
    value=$(echo "$value" | tr -d '[:space:]')

    if [[ "$value" =~ ^[0-9]+-[0-9]+$ ]]; then
        local min=${value%-*} max=${value#*-}
        validate_number "$min" "$param_name" 0 1048576 &&
        validate_number "$max" "$param_name" 0 1048576 &&
        (( min <= max ))
    elif [[ "$value" =~ ^([<>]=?|!=)[0-9]+$ ]]; then
        local num=$(echo "$value" | grep -o '[0-9]\+')
        validate_number "$num" "$param_name" 0 1048576
    elif [[ "$value" =~ ^[0-9]+$ ]]; then
        validate_number "$value" "$param_name" 0 1048576
    else
        log_error "$param_name 无效格式 '$value'"
        return 1
    fi
}

# ========== 连接状态验证 ==========
validate_state() {
    local state="$1" param_name="$2"
    [[ -z "$state" ]] && return 0
    local clean=$(echo "$state" | tr -d '[:space:]' | sed 's/[{}]//g')
    IFS=',' read -ra states <<< "$clean"
    for s in "${states[@]}"; do
        case "$s" in
            new|established|related|untracked|invalid) ;;
            *) log_error "$param_name 无效连接状态 '$s'"; return 1 ;;
        esac
    done
    return 0
}

# ========== IP 地址/CIDR 验证 ==========
validate_ip() {
    local ip="$1"
    local raw="${ip#!=}"

    if [[ "$raw" == @* ]]; then
        local setname="${raw#@}"
        if [[ ! "$setname" =~ ^[a-zA-Z0-9_]+$ ]]; then
            log_error "IP 集合名 '$setname' 无效"
            return 1
        fi
        return 0
    fi

    if [[ "$raw" =~ ^::[0-9a-fA-F]+/::[0-9a-fA-F]+$ ]]; then
        return 0
    fi

    if [[ "$raw" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        local ipnum="${raw%%/*}"
        IFS='.' read -r o1 o2 o3 o4 <<< "$ipnum"
        for oct in "$o1" "$o2" "$o3" "$o4"; do
            (( oct < 0 || oct > 255 )) && return 1
        done
        if [[ "$raw" =~ / ]]; then
            local prefix="${raw#*/}"
            (( prefix < 0 || prefix > 32 )) && return 1
        fi
        return 0
    fi

    if [[ "$raw" =~ ^(([0-9a-fA-F]{1,4}:){0,7}[0-9a-fA-F]{1,4}|::|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){0,6}:[0-9a-fA-F]{1,4})(/[0-9]{1,3})?$ ]]; then
        if [[ "$raw" =~ ::.*:: ]]; then
            log_error "IPv6地址 '$raw' 包含多个 '::'"
            return 1
        fi
        if [[ "$raw" =~ / ]]; then
            local prefix="${raw#*/}"
            (( prefix < 0 || prefix > 128 )) && return 1
        fi
        return 0
    fi

    if [[ "$raw" =~ ^(([0-9a-fA-F]{1,4}:){0,6}):?[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,3})?$ ]]; then
        local ipv4_part=$(echo "$raw" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
        validate_ip "$ipv4_part" && return 0
    fi

    return 1
}

# ========== TCP 标志验证 ==========
validate_tcp_flags() {
    local val="$1" param_name="$2"
    val=$(echo "$val" | tr -d '[:space:]' | tr -d '\r\n')
    [[ -z "$val" ]] && return 0

    IFS=',' read -ra flags <<< "$val"
    for f in "${flags[@]}"; do
        [[ -z "$f" ]] && continue
        local flag="${f#!}"
        case "$flag" in
            syn|ack|rst|fin|urg|psh|ecn|cwr) ;;
            *) log_error "无效的 TCP 标志 '$flag' (允许: syn,ack,rst,fin,urg,psh,ecn,cwr)"; return 1 ;;
        esac
    done
    return 0
}

# ========== 长度验证 ==========
validate_length() {
    local value="$1" param_name="$2"
    [[ -z "$value" ]] && return 0
    value=$(echo "$value" | tr -d '[:space:]')

    if [[ "$value" =~ ^[0-9]+-[0-9]+$ ]]; then
        local min=${value%-*} max=${value#*-}
        validate_number "$min" "$param_name" 0 65535 &&
        validate_number "$max" "$param_name" 0 65535 &&
        (( min <= max ))
    elif [[ "$value" =~ ^([<>]=?|!=)[0-9]+$ ]]; then
        local num=$(echo "$value" | grep -o '[0-9]\+')
        validate_number "$num" "$param_name" 0 65535
    elif [[ "$value" =~ ^[0-9]+$ ]]; then
        validate_number "$value" "$param_name" 0 65535
    else
        log_error "$param_name 无效格式 '$value'"
        return 1
    fi
}

# ========== DSCP 验证 ==========
validate_dscp() {
    local val="$1" param_name="$2"
    local neg=""
    [[ "$val" == "!="* ]] && { neg="!="; val="${val#!=}"; }
    validate_number "$val" "$param_name" 0 63
}

# ========== 接口名验证 ==========
validate_ifname() {
    local val="$1" param_name="$2"
    [[ "$val" =~ ^[a-zA-Z0-9_.-]+$ ]] || {
        log_error "$param_name 接口名无效: $val"
        return 1
    }
    return 0
}

# ========== ICMP 类型验证 ==========
validate_icmp_type() {
    local val="$1" param_name="$2"
    local neg=""
    [[ "$val" == "!="* ]] && { neg="!="; val="${val#!=}"; }
    if [[ "$val" =~ / ]]; then
        local type=${val%/*} code=${val#*/}
        validate_number "$type" "$param_name" 0 255 &&
        validate_number "$code" "$param_name" 0 255
    else
        validate_number "$val" "$param_name" 0 255
    fi
}

# ========== TTL/Hoplimit 验证 ==========
validate_ttl() {
    local value="$1" param_name="$2"
    [[ -z "$value" ]] && return 0
    value=$(echo "$value" | tr -d '[:space:]')

    if [[ "$value" =~ ^([<>]=?|!=)[0-9]+$ ]]; then
        local num=$(echo "$value" | grep -o '[0-9]\+')
        validate_number "$num" "$param_name" 1 255
    elif [[ "$value" =~ ^[0-9]+$ ]]; then
        validate_number "$value" "$param_name" 1 255
    else
        log_error "$param_name 无效格式 '$value'"
        return 1
    fi
}

# ========== 验证内联规则 ==========
check_inline_forbidden_keywords() {
    local file="$1"
    if grep -Eq '^[[:space:]]*(table|chain|type|hook|priority)[[:space:]]+' "$file"; then
        log_error "自定义规则文件 $file 包含禁止的顶层关键字 (table, chain, type, hook, priority)，已忽略"
        return 1
    fi
    return 0
}

validate_inline_rules() {
    local file_path="$1"
    local check_file=$(mktemp)
    TEMP_FILES+=("$check_file")
    local ret=0

    if ! check_inline_forbidden_keywords "$file_path"; then
        rm -f "$check_file"
        return 1
    fi

    {
        printf '%s\n\t%s\n' "table inet __qos_custom_check {" "chain __temp_chain {"
        cat "$file_path"
        printf '\n\t%s\n%s\n' "}" "}"
    } > "$check_file"

    if nft --check --file "$check_file" > "$CUSTOM_VALIDATION_FILE" 2>&1; then
        ret=0
    else
        log_warn "内联规则文件 $file_path 语法错误"
        ret=1
    fi
    rm -f "$check_file"
    return $ret
}

validate_full_table_rules() {
    local file_path="$1"
    if nft --check --file "$file_path" > "$CUSTOM_VALIDATION_FILE" 2>&1; then
        return 0
    else
        log_warn "完整表规则文件 $file_path 语法错误"
        return 1
    fi
}

load_custom_full_table() {
    local custom_table_file="$CUSTOM_FULL_TABLE_FILE"
    if [[ ! -s "$custom_table_file" ]]; then
        log_debug "完整表规则文件不存在或为空，跳过加载"
        return 0
    fi

    log_info "加载完整表规则: $custom_table_file"
    if ! validate_full_table_rules "$custom_table_file"; then
        log_error "完整表规则文件 $custom_table_file 语法错误，跳过加载"
        return 1
    fi

    if nft -f "$custom_table_file" 2>&1; then
        log_info "完整表规则加载成功"
        return 0
    else
        log_error "完整表规则加载失败"
        return 1
    fi
}

# ========== 标记分配 ==========
init_class_marks_file() {
    mkdir -p "$(dirname "$CLASS_MARKS_FILE")" 2>/dev/null
}

allocate_class_marks() {
    local direction="$1" class_list="$2"
    local base_value i=1 mark mark_index
    local -a used_indexes=()
    local temp_file=$(mktemp /tmp/qos_marks_XXXXXX)
    TEMP_FILES+=("$temp_file")

    init_class_marks_file
    if [[ "$direction" == "upload" ]]; then
        base_value=1
    else
        base_value=65536
    fi

    for class in $class_list; do
        mark_index=$(uci -q get "${CONFIG_FILE}.${class}.mark_index" 2>/dev/null)
        if [[ -n "$mark_index" ]]; then
            if ! validate_number "$mark_index" "$class.mark_index" 1 16; then
                rm -f "$temp_file"
                return 1
            fi
            if [[ " ${used_indexes[*]} " == *" $mark_index "* ]]; then
                log_error "类别 $class 指定的标记索引 $mark_index 已被占用"
                rm -f "$temp_file"
                return 1
            fi
            used_indexes+=("$mark_index")
        fi
    done

    local next_auto=1
    for class in $class_list; do
        mark_index=$(uci -q get "${CONFIG_FILE}.${class}.mark_index" 2>/dev/null)
        if [[ -z "$mark_index" || ! "$mark_index" =~ ^[0-9]+$ ]] || ! validate_number "$mark_index" "$class.mark_index" 1 16 2>/dev/null; then
            while [[ " ${used_indexes[*]} " == *" $next_auto "* ]]; do
                ((next_auto++))
            done
            if (( next_auto > 16 )); then
                log_error "没有可用的标记索引，无法为类别 $class 分配标记"
                rm -f "$temp_file"
                return 1
            fi
            mark_index=$next_auto
            used_indexes+=("$mark_index")
            ((next_auto++))
        fi
        mark=$(( (base_value << (mark_index - 1)) & 0xFFFFFFFF ))
        echo "$direction:$class:$mark" >> "$temp_file"
        log_info "类别 $class 分配标记索引 $mark_index (值: $mark / 0x$(printf '%X' $mark))"
    done

    if [[ -s "$temp_file" ]]; then
        if [[ -f "$CLASS_MARKS_FILE" ]]; then
            grep -v "^$direction:" "$CLASS_MARKS_FILE" 2>/dev/null > "${temp_file}.merge"
            cat "$temp_file" >> "${temp_file}.merge"
            mv "${temp_file}.merge" "$CLASS_MARKS_FILE"
        else
            mv "$temp_file" "$CLASS_MARKS_FILE"
        fi
        chmod 644 "$CLASS_MARKS_FILE"
    fi
    rm -f "$temp_file"
    return 0
}

get_class_mark() {
    local direction="$1" class="$2"
    init_class_marks_file
    [[ ! -f "$CLASS_MARKS_FILE" ]] && { log_error "类标记文件不存在"; return 1; }
    local mark_line=$(grep "^$direction:$class:" "$CLASS_MARKS_FILE" 2>/dev/null | head -1)
    if [[ -n "$mark_line" ]]; then
        echo "${mark_line##*:}"
        return 0
    else
        log_error "类别 $class 的标记值未找到"
        return 1
    fi
}

clear_class_marks() {
    log_debug "标记文件持久化，停止时不删除"
}

# ========== 配置加载函数 ==========
load_all_config_sections() {
    local config_name="$1" section_type="$2"
    local output
    output=$(uci show "$config_name" 2>/dev/null)
    [[ -z "$output" ]] && { echo ""; return; }

    if [[ -n "$section_type" ]]; then
        local anonymous=$(echo "$output" | grep -E "^${config_name}\\.@${section_type}\\[[0-9]+\\]=" | cut -d= -f1 | sed "s/^${config_name}\\.//")
        local named=$(echo "$output" | grep -E "^${config_name}\\.[a-zA-Z0-9_]+=${section_type}"'$' | cut -d= -f1 | cut -d. -f2)
        local old=$(echo "$output" | grep -E "^${config_name}\\.${section_type}_[0-9]+=" | cut -d= -f1 | cut -d. -f2)
        echo "$anonymous $named $old" | tr ' ' '\n' | grep -v "^$" | sort -u | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    else
        echo "$output" | grep -E "^${config_name}\\.[a-zA-Z_]+[0-9]*=" | cut -d= -f1 | cut -d. -f2
    fi
}

load_upload_class_configurations() {
    log_info "正在加载上传类别配置..."
    upload_class_list=$(load_all_config_sections "$CONFIG_FILE" "upload_class")
    if [[ -n "$upload_class_list" ]]; then
        log_info "找到上传类别: $upload_class_list"
    else
        log_warn "没有找到上传类别配置"
        upload_class_list=""
    fi
    return 0
}

load_download_class_configurations() {
    log_info "正在加载下载类别配置..."
    download_class_list=$(load_all_config_sections "$CONFIG_FILE" "download_class")
    if [[ -n "$download_class_list" ]]; then
        log_info "找到下载类别: $download_class_list"
    else
        log_warn "没有找到下载类别配置"
        download_class_list=""
    fi
    return 0
}

# 加载配置选项
load_all_config_options() {
    local config_name="$1" section_id="$2" prefix="$3"
    local var_name val

    for var in class order enabled proto srcport dstport connbytes_kb family state src_ip dest_ip \
          tcp_flags packet_len dscp iif oif icmp_type udp_length ttl; do
        eval "${prefix}${var}=''"
    done

    if [[ $_UCI_CONFIG_CACHED -eq 1 ]]; then
        var_name="config_${section_id}_class"
        eval "val=\${${var_name}:-}"
        if [[ -n "$val" ]]; then
            val="${val#\'}"; val="${val%\'}"; val="${val#\"}"; val="${val%\"}"
            val=$(echo "$val" | tr -d '\n\r')
            eval "${prefix}class=$(printf "%q" "$val")"
        else
            log_warn "配置节 $section_id 缺少 class 参数，忽略此规则"
            return 1
        fi

        for opt in order enabled proto srcport dstport connbytes_kb family state src_ip dest_ip \
            tcp_flags packet_len dscp iif oif icmp_type udp_length ttl; do
            var_name="config_${section_id}_${opt}"
            eval "val=\${${var_name}:-}"
            [[ -z "$val" ]] && continue
            val="${val#\'}"; val="${val%\'}"; val="${val#\"}"; val="${val%\"}"
            val=$(echo "$val" | tr -d '\n\r')

            case "$opt" in
                order)   val=$(echo "$val" | sed 's/[^0-9]//g'); [[ -n "$val" ]] && eval "${prefix}order=$(printf "%q" "$val")" ;;
                enabled) val=$(echo "$val" | grep -o '^[01]'); [[ -n "$val" ]] && eval "${prefix}enabled=$(printf "%q" "$val")" ;;
                proto)   if validate_protocol "$val" "${section_id}.proto"; then
                             val=$(echo "$val" | sed 's/[^a-zA-Z0-9_]//g')
                             eval "${prefix}proto=$(printf "%q" "$val")"
                         else log_warn "规则 $section_id 协议 '$val' 无效，忽略此字段"; fi ;;
                srcport) if validate_port "$val" "${section_id}.srcport"; then
                             val=$(echo "$val" | tr -d '[:space:]')
                             eval "${prefix}srcport=$(printf "%q" "$val")"
                         else log_warn "规则 $section_id 源端口 '$val' 无效，忽略此字段"; fi ;;
                dstport) if validate_port "$val" "${section_id}.dstport"; then
                             val=$(echo "$val" | tr -d '[:space:]')
                             eval "${prefix}dstport=$(printf "%q" "$val")"
                         else log_warn "规则 $section_id 目的端口 '$val' 无效，忽略此字段"; fi ;;
                connbytes_kb) if validate_connbytes "$val" "${section_id}.connbytes_kb"; then
                                  val=$(echo "$val" | sed 's/[^0-9<>!= -]//g' | tr -d ' ')
                                  eval "${prefix}connbytes_kb=$(printf "%q" "$val")"
                              else log_warn "规则 $section_id 连接字节数 '$val' 无效，忽略此字段"; fi ;;
                family)  if validate_family "$val" "${section_id}.family"; then
                             val=$(echo "$val" | sed 's/[^a-zA-Z0-9]//g')
                             eval "${prefix}family=$(printf "%q" "$val")"
                         else log_warn "规则 $section_id 地址族 '$val' 无效，忽略此字段"; fi ;;
                state)   val=$(echo "$val" | tr -d '{}' | sed 's/[^a-zA-Z,]//g')
                         if validate_state "$val" "${section_id}.state"; then
                             eval "${prefix}state=$(printf "%q" "$val")"
                         else log_warn "规则 $section_id 连接状态 '$val' 无效，忽略此字段"; fi ;;
                src_ip)  if validate_ip "$val"; then
                             eval "${prefix}src_ip=$(printf "%q" "$val")"
                         else log_warn "规则 $section_id 源 IP '$val' 格式无效，忽略此字段"; fi ;;
                dest_ip) if validate_ip "$val"; then
                             eval "${prefix}dest_ip=$(printf "%q" "$val")"
                         else log_warn "规则 $section_id 目的 IP '$val' 格式无效，忽略此字段"; fi ;;
                tcp_flags)
                    val=$(echo "$val" | tr -d '[:space:]')
                    if [[ -n "$val" ]] && validate_tcp_flags "$val" "${section_id}.tcp_flags"; then
                        eval "${prefix}tcp_flags=$(printf "%q" "$val")"
                    else
                        log_warn "规则 $section_id TCP标志 '$val' 无效，忽略此字段"
                    fi
                    ;;
                packet_len) if validate_length "$val" "${section_id}.packet_len"; then
                                eval "${prefix}packet_len=$(printf "%q" "$val")"
                            else log_warn "规则 $section_id 包长度 '$val' 无效，忽略此字段"; fi ;;
                dscp)       if validate_dscp "$val" "${section_id}.dscp"; then
                                eval "${prefix}dscp=$(printf "%q" "$val")"
                            else log_warn "规则 $section_id DSCP值 '$val' 无效，忽略此字段"; fi ;;
                iif)        if validate_ifname "$val" "${section_id}.iif"; then
                                eval "${prefix}iif=$(printf "%q" "$val")"
                            else log_warn "规则 $section_id 入接口 '$val' 无效，忽略此字段"; fi ;;
                oif)        if validate_ifname "$val" "${section_id}.oif"; then
                                eval "${prefix}oif=$(printf "%q" "$val")"
                            else log_warn "规则 $section_id 出接口 '$val' 无效，忽略此字段"; fi ;;
                icmp_type)  if validate_icmp_type "$val" "${section_id}.icmp_type"; then
                                eval "${prefix}icmp_type=$(printf "%q" "$val")"
                            else log_warn "规则 $section_id ICMP类型 '$val' 无效，忽略此字段"; fi ;;
                udp_length) if validate_length "$val" "${section_id}.udp_length"; then
                                eval "${prefix}udp_length=$(printf "%q" "$val")"
                            else log_warn "规则 $section_id UDP长度 '$val' 无效，忽略此字段"; fi ;;
                ttl)        if validate_ttl "$val" "${section_id}.ttl"; then
                                eval "${prefix}ttl=$(printf "%q" "$val")"
                            else log_warn "规则 $section_id TTL值 '$val' 无效，忽略此字段"; fi ;;
            esac
        done
        return 0
    fi

    # 缓存不可用，回退到直接读取 UCI
    log_debug "配置缓存不可用，从 UCI 直接读取规则 $section_id"
    local tmp_class
    tmp_class=$(uci -q get "${config_name}.${section_id}.class" 2>/dev/null)
    if [[ -z "$tmp_class" ]]; then
        log_warn "配置节 $section_id 缺少 class 参数，忽略此规则"
        return 1
    fi
    eval "${prefix}class='$tmp_class'"

    for opt in order enabled proto srcport dstport connbytes_kb family state src_ip dest_ip \
        tcp_flags packet_len dscp iif oif icmp_type udp_length ttl; do
        local val
        val=$(uci -q get "${config_name}.${section_id}.${opt}" 2>/dev/null)
        [[ -z "$val" ]] && continue
        case "$opt" in
            order)   val=$(echo "$val" | sed 's/[^0-9]//g') ;;
            enabled) val=$(echo "$val" | grep -o '^[01]') ;;
            proto)   if ! validate_protocol "$val" "${section_id}.proto"; then continue; fi ;;
            srcport) if ! validate_port "$val" "${section_id}.srcport"; then continue; fi ;;
            dstport) if ! validate_port "$val" "${section_id}.dstport"; then continue; fi ;;
            connbytes_kb) if ! validate_connbytes "$val" "${section_id}.connbytes_kb"; then continue; fi ;;
            family)  if ! validate_family "$val" "${section_id}.family"; then continue; fi ;;
            state)   val=$(echo "$val" | tr -d '{}' | sed 's/[^a-zA-Z,]//g'); if ! validate_state "$val" "${section_id}.state"; then continue; fi ;;
            src_ip)  if ! validate_ip "$val"; then continue; fi ;;
            dest_ip) if ! validate_ip "$val"; then continue; fi ;;
            tcp_flags) if ! validate_tcp_flags "$val" "${section_id}.tcp_flags"; then continue; fi ;;
            packet_len) if ! validate_length "$val" "${section_id}.packet_len"; then continue; fi ;;
            dscp)       if ! validate_dscp "$val" "${section_id}.dscp"; then continue; fi ;;
            iif)        if ! validate_ifname "$val" "${section_id}.iif"; then continue; fi ;;
            oif)        if ! validate_ifname "$val" "${section_id}.oif"; then continue; fi ;;
            icmp_type)  if ! validate_icmp_type "$val" "${section_id}.icmp_type"; then continue; fi ;;
            udp_length) if ! validate_length "$val" "${section_id}.udp_length"; then continue; fi ;;
            ttl)        if ! validate_ttl "$val" "${section_id}.ttl"; then continue; fi ;;
        esac
        eval "${prefix}${opt}='$val'"
    done
    return 0
}

# ========== UCI ipset 生成 nftables 集合 ==========
generate_ipset_sets() {
    [[ $_IPSET_LOADED -eq 1 ]] && return 0

    nft add table inet gargoyle-qos-priority 2>/dev/null || true

    # 确保 /lib/functions.sh 已加载，以便使用 config_get_bool
    if ! type config_get_bool >/dev/null 2>&1; then
        . /lib/functions.sh
    fi
    config_load "$CONFIG_FILE" 2>/dev/null

    local sets_file=$(mktemp /tmp/qos_ipset_sets_XXXXXX)
    local families_file="$SET_FAMILIES_FILE"
    TEMP_FILES+=("$sets_file")
    > "$families_file"

    process_ipset_section() {
        local section="$1" name enabled mode family timeout ip4 ip6 ip4_list ip6_list
        local elements=""

        config_get_bool enabled "$section" enabled 1
        [[ $enabled -eq 0 ]] && return 0
        config_get name "$section" name
        [[ -z "$name" ]] && { log_warn "ipset 节 $section 缺少 name，跳过"; return 0; }

        if [[ ! "$name" =~ ^[a-zA-Z0-9_]+$ ]]; then
            log_error "ipset 节 $section 的 name '$name' 包含非法字符，跳过"
            return 0
        fi

        config_get mode "$section" mode "static"
        config_get family "$section" family "ipv4"
        config_get timeout "$section" timeout "1h"
        case "$family" in ipv4|ipv6) ;; *) log_warn "ipset $name 族 '$family' 无效，使用 ipv4"; family="ipv4"; ;; esac

        if [[ "$family" == "ipv6" ]]; then
            config_get ip6 "$section" ip6
            ip6_list="$ip6"
        else
            config_get ip4 "$section" ip4
            ip4_list="$ip4"
        fi

        echo "$name $family" >> "$families_file"

        if [[ "$mode" == "dynamic" ]]; then
            echo "add set inet gargoyle-qos-priority $name { type ${family}_addr; flags dynamic, timeout; timeout $timeout; }" >> "$sets_file"
        else
            if [[ "$family" == "ipv6" ]]; then
                [[ -n "$ip6_list" ]] && elements=$(echo "$ip6_list" | tr -s ' ' ',' | sed 's/^,//;s/,$//')
            else
                [[ -n "$ip4_list" ]] && elements=$(echo "$ip4_list" | tr -s ' ' ',' | sed 's/^,//;s/,$//')
            fi
            if [[ -n "$elements" ]]; then
                echo "add set inet gargoyle-qos-priority $name { type ${family}_addr; flags interval; elements = { $elements }; }" >> "$sets_file"
            else
                echo "add set inet gargoyle-qos-priority $name { type ${family}_addr; flags interval; }" >> "$sets_file"
            fi
        fi
        log_info "已生成 ipset: $name ($family, mode=$mode)"
    }

    local sections=$(load_all_config_sections "$CONFIG_FILE" "ipset")
    for section in $sections; do process_ipset_section "$section"; done

    if [[ -s "$sets_file" ]]; then
        nft -f "$sets_file" 2>/dev/null || log_warn "部分 ipset 集合加载失败，请检查 UCI 配置"
        log_info "已加载 UCI 定义的 ipset 集合"
    fi
    rm -f "$sets_file"
    _IPSET_LOADED=1
}

# ========== 速率限制辅助函数 ==========
build_ip_conditions_for_direction() {
    local ip_list="$1" direction="$2" result_var="$3"
    local result="" ipv4_pos="" ipv4_neg="" ipv6_pos="" ipv6_neg=""
    local value negation v

    for value in $ip_list; do
        negation=""; v="$value"
        [[ "$v" == "!="* ]] && { negation="!="; v="${v#!=}"; }
        if [[ "$v" =~ : ]] && ! [[ "$v" =~ ^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$ ]]; then
            if [[ -n "$negation" ]]; then
                ipv6_neg="${ipv6_neg}${ipv6_neg:+,}${v}"
            else
                ipv6_pos="${ipv6_pos}${ipv6_pos:+,}${v}"
            fi
        else
            if [[ -n "$negation" ]]; then
                ipv4_neg="${ipv4_neg}${ipv4_neg:+,}${v}"
            else
                ipv4_pos="${ipv4_pos}${ipv4_pos:+,}${v}"
            fi
        fi
    done

    [[ -n "$ipv4_neg" ]] && result="${result}${result:+ }ip ${direction} != { ${ipv4_neg} }"
    [[ -n "$ipv4_pos" ]] && result="${result}${result:+ }ip ${direction} { ${ipv4_pos} }"
    [[ -n "$ipv6_neg" ]] && result="${result}${result:+ }ip6 ${direction} != { ${ipv6_neg} }"
    [[ -n "$ipv6_pos" ]] && result="${result}${result:+ }ip6 ${direction} { ${ipv6_pos} }"
    eval "${result_var}=\"\${result}\""
}

generate_ratelimit_rules() {
    [[ $ENABLE_RATELIMIT != 1 ]] && return

    if ! type config_load >/dev/null 2>&1; then
        . /lib/functions.sh
    fi
    config_load "$CONFIG_FILE" 2>/dev/null

    local rules=""
    process_ratelimit_section() {
        local section="$1" name enabled download_limit upload_limit burst_factor target_values
        local set_name_dl4 set_name_ul4 set_name_dl6 set_name_ul6
        local download_kbytes upload_kbytes download_burst upload_burst
        local download_burst_param='' upload_burst_param=''
        local sets_neg_v4="" sets_pos_v4="" ips_neg_v4="" ips_pos_v4=""
        local sets_neg_v6="" sets_pos_v6="" ips_neg_v6="" ips_pos_v6=""
        local value prefix setname set_family

        config_get_bool enabled "$section" enabled 1
        [[ $enabled -eq 0 ]] && return 0
        config_get name "$section" name
        [[ -z "$name" ]] && return 0
        name=$(echo "$name" | sed 's/[^a-zA-Z0-9_]/_/g')
        config_get download_limit "$section" download_limit "0"
        config_get upload_limit "$section" upload_limit "0"
        config_get burst_factor "$section" burst_factor "1.0"
        if ! validate_float "$burst_factor" "${section}.burst_factor" 2>/dev/null; then
            log_warn "规则 $section 的 burst_factor '$burst_factor' 无效，使用默认值 1.0"
            burst_factor="1.0"
        fi
        config_get target_values "$section" target
        [[ -z "$target_values" ]] && return 0
        [[ $download_limit -eq 0 && $upload_limit -eq 0 ]] && return 0

        download_kbytes=$((download_limit / 8))
        upload_kbytes=$((upload_limit / 8))

        if [[ -n "$burst_factor" && "$burst_factor" != "0" && "$burst_factor" != "0.0" ]]; then
            if command -v bc >/dev/null 2>&1; then
                download_burst=$(echo "$download_kbytes * $burst_factor" | bc | awk '{printf "%.0f", $1}')
                upload_burst=$(echo "$upload_kbytes * $burst_factor" | bc | awk '{printf "%.0f", $1}')
            else
                download_burst=$(awk "BEGIN {printf \"%.0f\", $download_kbytes * $burst_factor}")
                upload_burst=$(awk "BEGIN {printf \"%.0f\", $upload_kbytes * $burst_factor}")
            fi
            (( download_burst < 1 )) && download_burst=1
            (( upload_burst < 1 )) && upload_burst=1
            download_burst_param=" burst ${download_burst} kbytes"
            upload_burst_param=" burst ${upload_burst} kbytes"
        fi

        for value in $target_values; do
            prefix=''
            [[ "$value" == "!="* ]] && { prefix='!='; value="${value#!=}"; }
            if [[ "$value" == '@'* ]]; then
                setname="${value#@}"
                if [[ -f "$SET_FAMILIES_FILE" ]]; then
                    set_family=$(awk -v set="$setname" '$1 == set {print $2}' "$SET_FAMILIES_FILE" 2>/dev/null)
                fi
                if [[ -z "$set_family" ]]; then
                    set_family=$(nft list set inet gargoyle-qos-priority "$setname" 2>/dev/null | grep -o 'type [a-z0-9_]*' | head -1 | awk '{print $2}')
                    set_family=${set_family%_addr}
                fi
                [[ -z "$set_family" ]] && set_family="ipv4"
                if [[ "$set_family" == "ipv6" ]]; then
                    [[ -n "$prefix" ]] && sets_neg_v6="${sets_neg_v6}${sets_neg_v6:+, }${setname}" || sets_pos_v6="${sets_pos_v6}${sets_pos_v6:+, }${setname}"
                else
                    [[ -n "$prefix" ]] && sets_neg_v4="${sets_neg_v4}${sets_neg_v4:+, }${setname}" || sets_pos_v4="${sets_pos_v4}${sets_pos_v4:+, }${setname}"
                fi
            else
                if [[ "$value" =~ : ]] && ! [[ "$value" =~ ^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$ ]]; then
                    [[ -n "$prefix" ]] && ips_neg_v6="${ips_neg_v6}${ips_neg_v6:+, }${value}" || ips_pos_v6="${ips_pos_v6}${ips_pos_v6:+, }${value}"
                else
                    [[ -n "$prefix" ]] && ips_neg_v4="${ips_neg_v4}${ips_neg_v4:+, }${value}" || ips_pos_v4="${ips_pos_v4}${ips_pos_v4:+, }${value}"
                fi
            fi
        done

        local prefix_set="rl_"
        local timeout=60
        local set_timeout=$(uci -q get ${CONFIG_FILE}.${section}.timeout 2>/dev/null)
        [[ -n "$set_timeout" ]] && timeout="$set_timeout"
        if [[ "$timeout" =~ ^[0-9]+$ ]]; then
            timeout="${timeout}s"
        fi

        set_name_dl4="${prefix_set}${name}_dl4"
        set_name_ul4="${prefix_set}${name}_ul4"
        set_name_dl6="${prefix_set}${name}_dl6"
        set_name_ul6="${prefix_set}${name}_ul6"

        if [[ $download_limit -gt 0 ]]; then
            rules="${rules}
add set inet gargoyle-qos-priority ${set_name_dl4} { type ipv4_addr; flags dynamic, timeout; timeout ${timeout}; }
add set inet gargoyle-qos-priority ${set_name_dl6} { type ipv6_addr; flags dynamic, timeout; timeout ${timeout}; }"
        fi
        if [[ $upload_limit -gt 0 ]]; then
            rules="${rules}
add set inet gargoyle-qos-priority ${set_name_ul4} { type ipv4_addr; flags dynamic, timeout; timeout ${timeout}; }
add set inet gargoyle-qos-priority ${set_name_ul6} { type ipv6_addr; flags dynamic, timeout; timeout ${timeout}; }"
        fi

        if [[ $download_limit -gt 0 ]]; then
            for grp in "pos:$ips_pos_v4" "neg:$ips_neg_v4"; do
                local type="${grp%:*}" iplist="${grp#*:}"
                [[ -z "$iplist" ]] && continue
                local cond=""
                build_ip_conditions_for_direction "$iplist" "daddr" cond
                if [[ -n "$cond" ]]; then
                    rules="${rules}
        # ${name} - Download limit (IPv4 IP ${type})
        ${cond} ip daddr @${set_name_dl4} counter drop comment \"${name} download (in set)\"
        ${cond} ip daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl4} { ip daddr } counter drop comment \"${name} download (rate limit)\""
                fi
            done
            for set in $sets_pos_v4; do
                rules="${rules}
        # ${name} - Download limit (IPv4 set @${set})
        ip daddr @${set} ip daddr @${set_name_dl4} counter drop comment \"${name} download (in set)\"
        ip daddr @${set} ip daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl4} { ip daddr } counter drop comment \"${name} download (rate limit)\""
            done
            for set in $sets_neg_v4; do
                rules="${rules}
        # ${name} - Download limit (IPv4 set != @${set})
        ip daddr != @${set} ip daddr @${set_name_dl4} counter drop comment \"${name} download (in set)\"
        ip daddr != @${set} ip daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl4} { ip daddr } counter drop comment \"${name} download (rate limit)\""
            done

            for grp in "pos:$ips_pos_v6" "neg:$ips_neg_v6"; do
                local type="${grp%:*}" iplist="${grp#*:}"
                [[ -z "$iplist" ]] && continue
                local cond=""
                build_ip_conditions_for_direction "$iplist" "daddr" cond
                if [[ -n "$cond" ]]; then
                    rules="${rules}
        # ${name} - Download limit (IPv6 IP ${type})
        ${cond} ip6 daddr @${set_name_dl6} counter drop comment \"${name} download (in set)\"
        ${cond} ip6 daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl6} { ip6 daddr } counter drop comment \"${name} download (rate limit)\""
                fi
            done
            for set in $sets_pos_v6; do
                rules="${rules}
        # ${name} - Download limit (IPv6 set @${set})
        ip6 daddr @${set} ip6 daddr @${set_name_dl6} counter drop comment \"${name} download (in set)\"
        ip6 daddr @${set} ip6 daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl6} { ip6 daddr } counter drop comment \"${name} download (rate limit)\""
            done
            for set in $sets_neg_v6; do
                rules="${rules}
        # ${name} - Download limit (IPv6 set != @${set})
        ip6 daddr != @${set} ip6 daddr @${set_name_dl6} counter drop comment \"${name} download (in set)\"
        ip6 daddr != @${set} ip6 daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl6} { ip6 daddr } counter drop comment \"${name} download (rate limit)\""
            done
        fi

        if [[ $upload_limit -gt 0 ]]; then
            for grp in "pos:$ips_pos_v4" "neg:$ips_neg_v4"; do
                local type="${grp%:*}" iplist="${grp#*:}"
                [[ -z "$iplist" ]] && continue
                local cond=""
                build_ip_conditions_for_direction "$iplist" "saddr" cond
                if [[ -n "$cond" ]]; then
                    rules="${rules}
        # ${name} - Upload limit (IPv4 IP ${type})
        ${cond} ip saddr @${set_name_ul4} counter drop comment \"${name} upload (in set)\"
        ${cond} ip saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul4} { ip saddr } counter drop comment \"${name} upload (rate limit)\""
                fi
            done
            for set in $sets_pos_v4; do
                rules="${rules}
        # ${name} - Upload limit (IPv4 set @${set})
        ip saddr @${set} ip saddr @${set_name_ul4} counter drop comment \"${name} upload (in set)\"
        ip saddr @${set} ip saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul4} { ip saddr } counter drop comment \"${name} upload (rate limit)\""
            done
            for set in $sets_neg_v4; do
                rules="${rules}
        # ${name} - Upload limit (IPv4 set != @${set})
        ip saddr != @${set} ip saddr @${set_name_ul4} counter drop comment \"${name} upload (in set)\"
        ip saddr != @${set} ip saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul4} { ip saddr } counter drop comment \"${name} upload (rate limit)\""
            done

            for grp in "pos:$ips_pos_v6" "neg:$ips_neg_v6"; do
                local type="${grp%:*}" iplist="${grp#*:}"
                [[ -z "$iplist" ]] && continue
                local cond=""
                build_ip_conditions_for_direction "$iplist" "saddr" cond
                if [[ -n "$cond" ]]; then
                    rules="${rules}
        # ${name} - Upload limit (IPv6 IP ${type})
        ${cond} ip6 saddr @${set_name_ul6} counter drop comment \"${name} upload (in set)\"
        ${cond} ip6 saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul6} { ip6 saddr } counter drop comment \"${name} upload (rate limit)\""
                fi
            done
            for set in $sets_pos_v6; do
                rules="${rules}
        # ${name} - Upload limit (IPv6 set @${set})
        ip6 saddr @${set} ip6 saddr @${set_name_ul6} counter drop comment \"${name} upload (in set)\"
        ip6 saddr @${set} ip6 saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul6} { ip6 saddr } counter drop comment \"${name} upload (rate limit)\""
            done
            for set in $sets_neg_v6; do
                rules="${rules}
        # ${name} - Upload limit (IPv6 set != @${set})
        ip6 saddr != @${set} ip6 saddr @${set_name_ul6} counter drop comment \"${name} upload (in set)\"
        ip6 saddr != @${set} ip6 saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul6} { ip6 saddr } counter drop comment \"${name} upload (rate limit)\""
            done
        fi
    }

    local sections=$(load_all_config_sections "$CONFIG_FILE" "ratelimit")
    for section in $sections; do process_ratelimit_section "$section"; done
    echo "$rules"
}

setup_ratelimit_chain() {
    [[ $ENABLE_RATELIMIT != 1 ]] && return 0
    local rules=$(generate_ratelimit_rules)
    if [[ -n "$rules" ]]; then
        local temp_ratelimit_file=$(mktemp /tmp/qos_ratelimit_XXXXXX)
        TEMP_FILES+=("$temp_ratelimit_file")
        echo "create chain inet gargoyle-qos-priority $RATELIMIT_CHAIN '{ type filter hook forward priority -10; policy accept; }'" > "$temp_ratelimit_file"
        echo "flush chain inet gargoyle-qos-priority $RATELIMIT_CHAIN" >> "$temp_ratelimit_file"
        echo "$rules" | while IFS= read -r rule; do
            [[ -z "$rule" ]] && continue
            [[ "${rule#\#}" != "$rule" ]] && continue
            echo "add rule inet gargoyle-qos-priority $RATELIMIT_CHAIN $rule" >> "$temp_ratelimit_file"
        done
        nft -f "$temp_ratelimit_file" 2>/dev/null || { log_error "无法创建速率限制链"; return 1; }
        log_info "速率限制链已创建并填充规则"
        rm -f "$temp_ratelimit_file"
    fi
}

# ========== ACK 限速规则 ==========
generate_ack_limit_rules() {
    [[ $ENABLE_ACK_LIMIT != 1 ]] && return
    local slow_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.slow_rate 2>/dev/null)
    local med_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.med_rate 2>/dev/null)
    local fast_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.fast_rate 2>/dev/null)
    local xfast_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.xfast_rate 2>/dev/null)
    [[ -n "$slow_rate" ]] && ACK_SLOW="$slow_rate"
    [[ -n "$med_rate" ]] && ACK_MED="$med_rate"
    [[ -n "$fast_rate" ]] && ACK_FAST="$fast_rate"
    [[ -n "$xfast_rate" ]] && ACK_XFAST="$xfast_rate"

    cat <<EOF
# ACK rate limiting using dynamic sets (ct id . ct direction key)
add rule inet gargoyle-qos-priority filter_qos_egress meta length < 100 tcp flags ack limit rate over ${ACK_XFAST}/second add @_qos_xfst_ack { ct id . ct direction } counter jump drop995
add rule inet gargoyle-qos-priority filter_qos_egress meta length < 100 tcp flags ack limit rate over ${ACK_FAST}/second add @_qos_fast_ack { ct id . ct direction } counter jump drop95
add rule inet gargoyle-qos-priority filter_qos_egress meta length < 100 tcp flags ack limit rate over ${ACK_MED}/second add @_qos_med_ack { ct id . ct direction } counter jump drop50
add rule inet gargoyle-qos-priority filter_qos_egress meta length < 100 tcp flags ack limit rate over ${ACK_SLOW}/second add @_qos_slow_ack { ct id . ct direction } counter jump drop50
EOF
}

# ========== TCP 升级规则 ==========
generate_tcp_upgrade_rules() {
    [[ $ENABLE_TCP_UPGRADE != 1 ]] && return
    local realtime_class=""
    
    local upload_classes=$(load_all_config_sections "$CONFIG_FILE" "upload_class")
    for cls in $upload_classes; do
        local name=$(uci -q get ${CONFIG_FILE}.${cls}.name 2>/dev/null)
        [[ "$name" == "realtime" ]] && { realtime_class="$cls"; break; }
    done
    
    if [[ -z "$realtime_class" ]]; then
        for cls in $upload_classes; do
            local enabled=$(uci -q get ${CONFIG_FILE}.${cls}.enabled 2>/dev/null)
            if [[ "$enabled" == "1" ]] || [[ -z "$enabled" ]]; then
                realtime_class="$cls"
                log_warn "TCP升级：未找到 realtime 类，将使用第一个启用的上传类 $realtime_class"
                break
            fi
        done
    fi

    if [[ -z "$realtime_class" ]]; then
        log_warn "TCP升级：未找到任何上传类，将禁用此功能"
        return
    fi

    local enabled=$(uci -q get ${CONFIG_FILE}.${realtime_class}.enabled 2>/dev/null)
    if [[ "$enabled" != "1" ]] && [[ -n "$enabled" ]]; then
        log_warn "TCP升级：realtime 类 $realtime_class 未启用，跳过规则生成"
        return
    fi

    local realtime_mark=$(get_class_mark "upload" "$realtime_class" 2>/dev/null)
    if [[ -z "$realtime_mark" || "$realtime_mark" == "0" || "$realtime_mark" == "0x0" ]]; then
        log_error "TCP升级：realtime 类 $realtime_class 的标记无效（值为 $realtime_mark），跳过规则生成"
        return
    fi

    cat <<EOF
# TCP upgrade for slow connections (using dynamic set, ct id . ct direction key)
add rule inet gargoyle-qos-priority filter_qos_egress meta l4proto tcp ct state established meta nfproto ipv4 add @_qos_slow_tcp { ct id . ct direction limit rate 150/second burst 150 packets } meta mark set $realtime_mark counter
add rule inet gargoyle-qos-priority filter_qos_egress meta l4proto tcp ct state established meta nfproto ipv6 add @_qos_slow_tcp { ct id . ct direction limit rate 150/second burst 150 packets } meta mark set $realtime_mark counter
EOF
}

# ========== 集合族缓存 ==========
get_set_family() {
    local setname="$1"
    local family=""

    if [[ -n "${_SET_FAMILY_CACHE["$setname"]}" ]]; then
        echo "${_SET_FAMILY_CACHE["$setname"]}"
        return 0
    fi

    if [[ -f "$SET_FAMILIES_FILE" ]]; then
        family=$(awk -v set="$setname" '$1 == set {print $2}' "$SET_FAMILIES_FILE" 2>/dev/null)
    fi

    if [[ -z "$family" ]]; then
        family=$(nft list set inet gargoyle-qos-priority "$setname" 2>/dev/null | grep -o 'type [a-z0-9_]*' | head -1 | awk '{print $2}')
        family=${family%_addr}
    fi

    [[ -z "$family" ]] && family="ipv4"
    _SET_FAMILY_CACHE["$setname"]="$family"
    echo "$family"
    return 0
}

# ========== 批量查询集合存在性 ==========
get_existing_sets() {
    local table="$1"
    local sets=()
    local output

    if command -v jq >/dev/null 2>&1; then
        output=$(nft -j list sets "$table" 2>/dev/null)
        if [[ -n "$output" ]]; then
            while IFS= read -r name; do
                [[ -n "$name" ]] && sets+=("$name")
            done < <(echo "$output" | jq -r '.[].name' 2>/dev/null)
        fi
    fi

    if [[ ${#sets[@]} -eq 0 ]]; then
        local set_list=$(nft list sets "$table" 2>/dev/null | grep -oP 'set \K[a-zA-Z0-9_]+' || true)
        while IFS= read -r set; do
            [[ -n "$set" ]] && sets+=("$set")
        done <<< "$set_list"
    fi

    printf '%s\n' "${sets[@]}"
}

# ========== 获取物理接口最大带宽 ==========
get_physical_interface_max_bandwidth() {
    local interface="$1" max_bandwidth=""
    
    case "$interface" in
        ppp*|tun*|tap*|veth*|gre*|gretap*)
            log_info "接口 $interface 为虚拟接口，跳过物理带宽检测"
            echo "$MAX_PHYSICAL_BANDWIDTH"
            return 0
            ;;
    esac

    if command -v ethtool >/dev/null 2>&1; then
        local speed=$(ethtool "$interface" 2>/dev/null | grep -i speed | awk '{print $2}' | sed 's/[^0-9]//g')
        if [[ -n "$speed" ]] && (( speed > 0 )); then
            max_bandwidth=$((speed * 1000))
            log_info "接口 $interface 物理速度: ${speed}Mbps (${max_bandwidth}kbit)"
        fi
    fi
    if [[ -z "$max_bandwidth" ]] && [[ -d "/sys/class/net/$interface" ]]; then
        local speed_file="/sys/class/net/$interface/speed"
        if [[ -f "$speed_file" ]]; then
            local speed=$(cat "$speed_file" 2>/dev/null)
            if [[ -n "$speed" ]] && (( speed > 0 )); then
                max_bandwidth=$((speed * 1000))
                log_info "接口 $interface 物理速度: ${speed}Mbps (${max_bandwidth}kbit)"
            fi
        fi
    fi
    if [[ -z "$max_bandwidth" ]]; then
        max_bandwidth="$MAX_PHYSICAL_BANDWIDTH"
        log_warn "无法获取接口 $interface 的物理速度，使用默认最大值 ${max_bandwidth}kbit"
    fi
    echo "$max_bandwidth"
}

# ========== 带宽单位转换 ==========
convert_bandwidth_to_kbit() {
    local bw="$1" num unit multiplier result
    [[ -z "$bw" ]] && { log_error "带宽值为空"; return 1; }
    bw=$(echo "$bw" | tr -d '[:space:]')
    if [[ "$bw" =~ ^[0-9]+$ ]]; then echo "$bw"; return 0; fi

    if [[ "$bw" =~ ^([0-9]+(\.[0-9]+)?)([a-zA-Z]+)$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[3]}"
        unit=$(echo "$unit" | tr '[:upper:]' '[:lower:]')
        case "$unit" in
            kbit|kbits|kbit/s|kbps|kb|kib) multiplier=1 ;;
            mbit|mbits|mbit/s|mbps|mb|mib) multiplier=1000 ;;
            gbit|gbits|gbit/s|gbps|gb|gib) multiplier=1000000 ;;
            k|kb|kib) multiplier=8 ;;
            m|mb|mib) multiplier=8000 ;;
            g|gb|gib) multiplier=8000000 ;;
            *) log_error "未知带宽单位: $unit"; return 1 ;;
        esac
        if command -v bc >/dev/null 2>&1; then
            result=$(echo "$num * $multiplier" | bc | awk '{printf "%.0f", $1}')
        else
            result=$(awk "BEGIN {printf \"%.0f\", $num * $multiplier}")
        fi
        [[ -z "$result" || ! "$result" =~ ^[0-9]+$ || $result -lt 0 ]] && result=0
        echo "$result"; return 0
    else
        log_error "无效带宽格式: $bw (应为数字或数字+单位，例如 100mbit、10MB)"
        return 1
    fi
}

# ========== 加载带宽配置 ==========
load_bandwidth_from_config() {
    log_info "加载带宽配置"
    local wan_if="$qos_interface"
    if [[ -z "$wan_if" ]]; then
        if [[ -f "/lib/functions/network.sh" ]]; then
            . /lib/functions/network.sh
            network_find_wan wan_if
        fi
        if [[ -z "$wan_if" ]]; then
            log_error "无法确定 WAN 接口，请设置 qos_interface 变量或配置 global.wan_interface"
            return 1
        fi
        log_info "自动检测 WAN 接口: $wan_if"
    fi
    local max_physical_bw=$(get_physical_interface_max_bandwidth "$wan_if")

    local config_upload_bw=$(uci -q get ${CONFIG_FILE}.upload.total_bandwidth 2>/dev/null)
    if [[ -z "$config_upload_bw" ]]; then
        log_info "上传总带宽未配置，将禁用上传QoS"
        total_upload_bandwidth=0
    else
        total_upload_bandwidth=$(convert_bandwidth_to_kbit "$config_upload_bw") || {
            log_warn "上传带宽转换失败，将禁用上传QoS"
            total_upload_bandwidth=0
        }
        if (( total_upload_bandwidth == 0 )); then
            log_info "上传总带宽为0，将禁用上传QoS"
        elif ! validate_number "$total_upload_bandwidth" "upload.total_bandwidth" 1 "$max_physical_bw"; then
            log_warn "上传总带宽无效，将禁用上传QoS"
            total_upload_bandwidth=0
        else
            log_info "上传总带宽: ${total_upload_bandwidth}kbit/s"
        fi
    fi

    local config_download_bw=$(uci -q get ${CONFIG_FILE}.download.total_bandwidth 2>/dev/null)
    if [[ -z "$config_download_bw" ]]; then
        log_info "下载总带宽未配置，将禁用下载QoS"
        total_download_bandwidth=0
    else
        total_download_bandwidth=$(convert_bandwidth_to_kbit "$config_download_bw") || {
            log_warn "下载带宽转换失败，将禁用下载QoS"
            total_download_bandwidth=0
        }
        if (( total_download_bandwidth == 0 )); then
            log_info "下载总带宽为0，将禁用下载QoS"
        elif ! validate_number "$total_download_bandwidth" "download.total_bandwidth" 1 "$max_physical_bw"; then
            log_warn "下载总带宽无效，将禁用下载QoS"
            total_download_bandwidth=0
        else
            log_info "下载总带宽: ${total_download_bandwidth}kbit/s"
        fi
    fi

    return 0
}

# ========== 检查必需的命令 ==========
check_required_commands() {
    local missing=0
    for cmd in tc nft ip awk bc logger; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "命令 '$cmd' 未找到，请安装相应软件包"
            missing=1
        fi
    done
    if ! command -v ethtool >/dev/null 2>&1; then
        log_info "ethtool 未安装，将尝试从 sysfs 获取接口速度"
    fi
    return $missing
}

# ========== 加载必需的内核模块 ==========
load_required_modules() {
    local missing=0
    for mod in ifb sch_htb sch_hfsc sch_cake sch_fq_codel sch_ingress; do
        if ! lsmod 2>/dev/null | grep -q "^$mod"; then
            log_info "尝试加载内核模块: $mod"
            modprobe "$mod" 2>/dev/null || { log_error "无法加载内核模块 $mod"; missing=1; }
            if ! lsmod 2>/dev/null | grep -q "^$mod"; then
                log_error "内核模块 $mod 加载失败"
                missing=1
            fi
        fi
    done
    if ! lsmod 2>/dev/null | grep -q "^act_connmark"; then
        modprobe act_connmark 2>/dev/null || log_info "act_connmark 模块未加载，入口 connmark 功能可能受限"
    fi
    return $missing
}

# ========== 检查IFB设备 ==========
ensure_ifb_device() {
    local dev="$1"
    if ! ip link show "$dev" >/dev/null 2>&1; then
        log_info "IFB设备 $dev 不存在，尝试创建..."
        ip link add "$dev" type ifb 2>/dev/null || { log_error "无法创建IFB设备 $dev"; return 1; }
    fi
    local retry=0
    while (( retry < 3 )); do
        if ip link set dev "$dev" up 2>/dev/null; then
            log_info "IFB设备 $dev 已就绪"
            return 0
        fi
        retry=$((retry + 1))
        sleep 1
    done
    log_error "无法启动IFB设备 $dev，重试失败"
    return 1
}

# ========== 检查 tc connmark 支持（使用唯一 dummy 设备） ==========
check_tc_connmark_support() {
    modprobe sch_ingress 2>/dev/null
    modprobe act_connmark 2>/dev/null

    local dummy_dev="qos_test_dummy_$$"
    local created=0
    if ! ip link show "$dummy_dev" >/dev/null 2>&1; then
        ip link add "$dummy_dev" type dummy 2>/dev/null || {
            dummy_dev="lo"
        }
        created=1
    fi
    tc qdisc del dev "$dummy_dev" ingress 2>/dev/null
    if ! tc qdisc add dev "$dummy_dev" ingress 2>/dev/null; then
        [[ $created -eq 1 && "$dummy_dev" != "lo" ]] && ip link del "$dummy_dev" 2>/dev/null
        log_warn "无法在 $dummy_dev 上创建 ingress 队列，无法测试 connmark 支持"
        return 1
    fi
    local ret=1
    if tc filter add dev "$dummy_dev" parent ffff: protocol ip u32 match u32 0 0 action connmark 2>/dev/null; then
        ret=0
        tc filter del dev "$dummy_dev" parent ffff: 2>/dev/null
    fi
    tc qdisc del dev "$dummy_dev" ingress 2>/dev/null
    if [[ $created -eq 1 && "$dummy_dev" != "lo" ]]; then
        ip link del "$dummy_dev" 2>/dev/null
    fi
    return $ret
}

# ========== 检测 SFO 是否启用 ==========
check_sfo_enabled() {
    local flow_offloading=$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null)
    local flow_offloading_hw=$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)
    if [[ "$flow_offloading" == "1" ]] || [[ "$flow_offloading_hw" == "1" ]]; then
        return 0
    else
        return 1
    fi
}

# ========== 检查 tc ctinfo 支持（使用唯一 dummy 设备） ==========
check_tc_ctinfo_support() {
    local dummy_dev="qos_test_dummy_$$"
    local created=0
    if ! ip link show "$dummy_dev" >/dev/null 2>&1; then
        ip link add "$dummy_dev" type dummy 2>/dev/null || {
            dummy_dev="lo"
        }
        created=1
    fi
    tc qdisc del dev "$dummy_dev" ingress 2>/dev/null
    if ! tc qdisc add dev "$dummy_dev" ingress 2>/dev/null; then
        [[ $created -eq 1 && "$dummy_dev" != "lo" ]] && ip link del "$dummy_dev" 2>/dev/null
        log_warn "无法在 $dummy_dev 上创建 ingress 队列，无法测试 ctinfo 支持"
        return 1
    fi
    local ret=1
    if tc filter add dev "$dummy_dev" parent ffff: protocol ip u32 match u32 0 0 action ctinfo mark 0xffffffff 0xffffffff 2>/dev/null; then
        ret=0
        tc filter del dev "$dummy_dev" parent ffff: 2>/dev/null
    fi
    tc qdisc del dev "$dummy_dev" ingress 2>/dev/null
    if [[ $created -eq 1 && "$dummy_dev" != "lo" ]]; then
        ip link del "$dummy_dev" 2>/dev/null
    fi
    return $ret
}

# ========== 规则集合并 ==========
init_ruleset() {
    local nofix="$1"
    if [[ "$nofix" == "1" ]]; then
        [[ -f "$RULESET_MERGED_FLAG" ]] && return 0
        return 0
    fi
    [[ -f "$RULESET_MERGED_FLAG" ]] && return 0

    local ruleset ruleset_file
    ruleset=$(uci -q get ${CONFIG_FILE}.global.ruleset 2>/dev/null)
    [[ -z "$ruleset" ]] && ruleset="default.conf"
    case "$ruleset" in *.conf) ;; *) ruleset="${ruleset}.conf" ;; esac
    ruleset_file="$RULESET_DIR/$ruleset"
    if [[ ! -f "$ruleset_file" ]]; then
        log_error "规则集文件 $ruleset_file 不存在，无法加载任何规则！"
        return 1
    fi

    local backup_file="/etc/config/${CONFIG_FILE}.bak.$(date +%s)"
    cp "/etc/config/${CONFIG_FILE}" "$backup_file"
    log_info "已备份主配置文件到 $backup_file"

    if grep -q "^# === RULESET_" "/etc/config/${CONFIG_FILE}"; then
        local tmp_conf=$(mktemp /tmp/qos_config_$$.tmp)
        TEMP_FILES+=("$tmp_conf")
        sed '/^# === RULESET_/,/^# === RULESET_END ===/d' "/etc/config/${CONFIG_FILE}" > "$tmp_conf"
        mv "$tmp_conf" "/etc/config/${CONFIG_FILE}"
        log_info "已清理旧的规则集内容"
    fi

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
    local latest_backup=$(ls -t /etc/config/${CONFIG_FILE}.bak.* 2>/dev/null | head -1)
    if [[ -n "$latest_backup" ]]; then
        mv "$latest_backup" "/etc/config/${CONFIG_FILE}"
        uci commit ${CONFIG_FILE}
        log_info "已恢复主配置文件备份: $latest_backup"
    elif [[ -f "/etc/config/${CONFIG_FILE}.bak" ]]; then
        mv "/etc/config/${CONFIG_FILE}.bak" "/etc/config/${CONFIG_FILE}"
        uci commit ${CONFIG_FILE}
        log_info "已恢复主配置文件备份"
    else
        log_warn "未找到配置文件备份"
    fi
    rm -f "$RULESET_MERGED_FLAG"
    log_info "已清理规则集标记"
}

# ========== 获取最高优先级的类名称 ==========
get_highest_priority_class() {
    local direction="$1"  # upload 或 download
    local class_list=""
    local best_class=""
    local best_prio=999  # 初始一个大数
    
    if [[ "$direction" == "upload" ]]; then
        class_list="$upload_class_list"
    else
        class_list="$download_class_list"
    fi
    
    for class in $class_list; do
        local enabled=$(uci -q get ${CONFIG_FILE}.${class}.enabled 2>/dev/null)
        if [[ "$enabled" == "0" ]]; then
            continue
        fi
        
        local prio=$(uci -q get ${CONFIG_FILE}.${class}.priority 2>/dev/null)
        if [[ -z "$prio" ]]; then
            prio=999
        fi
        
        if [[ "$prio" -lt "$best_prio" ]]; then
            best_prio="$prio"
            best_class="$class"
        fi
    done
    
    echo "$best_class"
}

# ========== 自动速率测试 ==========
auto_speedtest() {   
    local noninteractive=0 force=0 gaming_ip=""
    local WAN_IF="" DOWNLOAD_SPEED="" UPLOAD_SPEED="" SPEEDTEST_CMD=""
    local response cur_upload cur_download

    while getopts ":nf" opt; do
        case $opt in
            n) noninteractive=1 ;;
            f) force=1 ;;
            *) ;;
        esac
    done
    shift $((OPTIND-1))
    gaming_ip="$1"

    WAN_IF=$(uci -q get ${CONFIG_FILE}.global.wan_interface 2>/dev/null)
    if [[ -z "$WAN_IF" ]]; then
        if command -v network_find_wan >/dev/null 2>&1; then
            network_find_wan WAN_IF
        fi
    fi
    if [[ -z "$WAN_IF" ]]; then
        log_error "无法自动检测 WAN 接口，请手动配置 global.wan_interface"
        return 1
    fi
    log_info "检测到 WAN 接口: $WAN_IF"

    cur_upload=$(uci -q get ${CONFIG_FILE}.upload.total_bandwidth 2>/dev/null | sed 's/[^0-9]//g')
    cur_download=$(uci -q get ${CONFIG_FILE}.download.total_bandwidth 2>/dev/null | sed 's/[^0-9]//g')

    if [[ $force -eq 0 ]] && [[ -n "$cur_upload" ]] && [[ "$cur_upload" -gt 0 ]] && [[ -n "$cur_download" ]] && [[ "$cur_download" -gt 0 ]]; then
        if [[ $noninteractive -eq 0 ]]; then
            echo "当前已配置带宽：上传 ${cur_upload} kbit，下载 ${cur_download} kbit"
            echo "是否覆盖并重新测速？[y/N]"
            read -r response
            [[ ! "$response" =~ ^[Yy]$ ]] && { echo "已取消"; return 0; }
        else
            log_info "非交互模式且未指定 -f，跳过测速（已有带宽配置）"
            return 0
        fi
    fi

    if [[ -f "$QOS_RUNNING_FILE" ]]; then
        local old_pid=$(cat "$QOS_RUNNING_FILE" 2>/dev/null)
        if kill -0 "$old_pid" 2>/dev/null; then
            log_warn "QoS 正在运行，测速可能受影响。建议先停止服务。"
        else
            rm -f "$QOS_RUNNING_FILE"
        fi
    fi

    if command -v speedtest-go >/dev/null 2>&1; then
        SPEEDTEST_CMD="speedtest-go"
    elif command -v speedtest >/dev/null 2>&1 && speedtest --version 2>&1 | grep -q speedtest-cli; then
        SPEEDTEST_CMD="speedtest --simple"
    else
        log_warn "未找到 speedtest 工具，尝试安装 speedtest-go..."
        if command -v opkg >/dev/null 2>&1; then
            opkg update && opkg install speedtest-go || {
                log_error "安装 speedtest-go 失败，请手动安装"
                return 1
            }
            SPEEDTEST_CMD="speedtest-go"
        else
            log_error "无包管理器，请手动安装 speedtest 工具"
            return 1
        fi
    fi

    if [[ $noninteractive -eq 1 ]]; then
        log_info "非交互模式，开始速度测试..."
        SPEED_RESULT=$($SPEEDTEST_CMD 2>/dev/null)
    else
        echo "准备进行速度测试。请确保网络连接正常。"
        echo "是否继续? [y/N]"
        read -r response
        [[ ! "$response" =~ ^[Yy]$ ]] && { echo "已取消"; return 0; }
        SPEED_RESULT=$($SPEEDTEST_CMD 2>/dev/null)
    fi

    case "$SPEEDTEST_CMD" in
        *speedtest-go*)
            DOWNLOAD_SPEED=$(echo "$SPEED_RESULT" | grep "Download:" | awk '{print $2}')
            UPLOAD_SPEED=$(echo "$SPEED_RESULT" | grep "Upload:" | awk '{print $2}')
            ;;
        *speedtest\ --simple*)
            DOWNLOAD_SPEED=$(echo "$SPEED_RESULT" | grep "Download:" | awk '{print $2}')
            UPLOAD_SPEED=$(echo "$SPEED_RESULT" | grep "Upload:" | awk '{print $2}')
            ;;
    esac

    if [[ -z "$DOWNLOAD_SPEED" ]] || [[ -z "$UPLOAD_SPEED" ]]; then
        log_error "速度测试失败，请检查网络"
        return 1
    fi

    local DOWNRATE=$(echo "$DOWNLOAD_SPEED * 1000 * 0.9" | bc | awk '{printf "%.0f", $1}')
    local UPRATE=$(echo "$UPLOAD_SPEED * 1000 * 0.9" | bc | awk '{printf "%.0f", $1}')

    log_info "测试结果: 下载 ${DOWNLOAD_SPEED} Mbit/s, 上传 ${UPLOAD_SPEED} Mbit/s"
    log_info "设置带宽: 下载 ${DOWNRATE} kbit, 上传 ${UPRATE} kbit"

    uci set ${CONFIG_FILE}.upload.total_bandwidth="${UPRATE}kbit"
    uci set ${CONFIG_FILE}.download.total_bandwidth="${DOWNRATE}kbit"
    uci commit ${CONFIG_FILE}

    if [[ -n "$gaming_ip" ]] && [[ $noninteractive -eq 1 ]]; then
        if [[ "$gaming_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || [[ "$gaming_ip" =~ : ]]; then
            log_info "添加游戏设备 IP $gaming_ip 的规则"
            
            load_upload_class_configurations
            load_download_class_configurations
            
            local upload_best_class=$(get_highest_priority_class "upload")
            local download_best_class=$(get_highest_priority_class "download")
            
            if [[ -z "$upload_best_class" ]]; then
                log_warn "未找到上传方向的最高优先级类，跳过上传规则添加"
            fi
            if [[ -z "$download_best_class" ]]; then
                log_warn "未找到下载方向的最高优先级类，跳过下载规则添加"
            fi
            
            local old_upload_rule=$(uci -q show ${CONFIG_FILE} | grep -E "\.upload_rule.*\.src_ip='${gaming_ip}'" | cut -d. -f2 | head -1)
            local old_download_rule=$(uci -q show ${CONFIG_FILE} | grep -E "\.download_rule.*\.dest_ip='${gaming_ip}'" | cut -d. -f2 | head -1)
            [[ -n "$old_upload_rule" ]] && uci -q delete ${CONFIG_FILE}.${old_upload_rule}
            [[ -n "$old_download_rule" ]] && uci -q delete ${CONFIG_FILE}.${old_download_rule}
            
            if [[ -n "$upload_best_class" ]]; then
                uci add ${CONFIG_FILE} upload_rule
                uci set ${CONFIG_FILE}.@upload_rule[-1].name="Game_Console_Upload_${gaming_ip//[.:]/_}"
                uci set ${CONFIG_FILE}.@upload_rule[-1].enabled=1
                uci set ${CONFIG_FILE}.@upload_rule[-1].class="$upload_best_class"
                uci set ${CONFIG_FILE}.@upload_rule[-1].src_ip="$gaming_ip"
                uci set ${CONFIG_FILE}.@upload_rule[-1].proto="udp"
                uci set ${CONFIG_FILE}.@upload_rule[-1].counter=1
                log_info "已添加上传规则: 源IP=${gaming_ip}, 协议=UDP, 类=${upload_best_class}"
            fi
            
            if [[ -n "$download_best_class" ]]; then
                uci add ${CONFIG_FILE} download_rule
                uci set ${CONFIG_FILE}.@download_rule[-1].name="Game_Console_Download_${gaming_ip//[.:]/_}"
                uci set ${CONFIG_FILE}.@download_rule[-1].enabled=1
                uci set ${CONFIG_FILE}.@download_rule[-1].class="$download_best_class"
                uci set ${CONFIG_FILE}.@download_rule[-1].dest_ip="$gaming_ip"
                uci set ${CONFIG_FILE}.@download_rule[-1].proto="udp"
                uci set ${CONFIG_FILE}.@download_rule[-1].counter=1
                log_info "已添加下载规则: 目的IP=${gaming_ip}, 协议=UDP, 类=${download_best_class}"
            fi
            
            uci commit ${CONFIG_FILE}
        else
            log_warn "提供的 IP 格式无效: $gaming_ip，跳过规则添加"
        fi
    fi

    log_info "自动设置完成。请重启 QoS 服务生效（/etc/init.d/qos_gargoyle restart）。"
    return 0
}

# ========== 自动加载全局配置 ==========
if [[ -z "$_QOS_LIB_SH_LOADED" ]] && [[ "$(basename "$0")" != "lib.sh" ]]; then
    load_global_config
    _QOS_LIB_SH_LOADED=1
fi
