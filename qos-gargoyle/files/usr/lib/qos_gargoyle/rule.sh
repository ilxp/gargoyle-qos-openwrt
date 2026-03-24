#!/bin/bash
# 规则辅助模块 (rule.sh)
# 版本: 3.1.6 - 支持集合，ipv6掩码，自定义内联骨子额，自定义nft表
# 基于 HTB 与 CAKE 组合算法实现 QoS 流量控制

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
_QOS_TABLE_FLUSHED=0
_IPSET_LOADED=0
_HOOKS_SETUP=0
_UCI_CONFIG_CACHED=0
_UCI_CACHE_FILE=""      # 存储临时导出文件路径

# 临时文件数组
TEMP_FILES=()

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

# ========== 锁机制（mkdir 原子操作 + 嵌套计数 + 僵尸锁清理） ==========
LOCK_DIR="/var/run/qos_gargoyle.lockdir"
LOCK_DEPTH=0

acquire_lock() {
    if (( LOCK_DEPTH > 0 )); then
        if [[ -d "$LOCK_DIR" ]]; then
            ((LOCK_DEPTH++))
            log_debug "锁深度增加，当前深度: $LOCK_DEPTH"
            return 0
        else
            log_warn "锁目录丢失，重置深度计数"
            LOCK_DEPTH=0
        fi
    fi

    if [[ -d "$LOCK_DIR" ]] && [[ -f "$LOCK_DIR/pid" ]]; then
        local lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
            log_warn "检测到僵尸锁 (PID $lock_pid 已不存在)，清理锁目录"
            rm -rf "$LOCK_DIR" 2>/dev/null
        fi
    fi

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        LOCK_DEPTH=1
        log_debug "成功获取锁 (mkdir)"
        return 0
    fi

    if [[ -f "$LOCK_DIR/pid" ]] && [[ "$(cat "$LOCK_DIR/pid")" == "$$" ]]; then
        log_warn "锁目录已由当前进程持有，可能是未释放残留，视为已获取"
        LOCK_DEPTH=1
        return 0
    fi

    log_warn "等待锁释放..."
    local wait=0
    while (( wait < 5 )); do
        sleep 1
        if [[ -d "$LOCK_DIR" ]] && [[ -f "$LOCK_DIR/pid" ]]; then
            local lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                log_warn "检测到僵尸锁 (PID $lock_pid 已不存在)，清理锁目录"
                rm -rf "$LOCK_DIR" 2>/dev/null
            fi
        fi
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo $$ > "$LOCK_DIR/pid"
            LOCK_DEPTH=1
            log_debug "成功获取锁 (mkdir)"
            return 0
        fi
        ((wait++))
    done
    log_error "获取锁超时（5秒）"
    return 1
}

release_lock() {
    if (( LOCK_DEPTH == 0 )); then
        log_debug "未持有锁，无需释放"
        return
    fi

    ((LOCK_DEPTH--))
    if (( LOCK_DEPTH > 0 )); then
        log_debug "锁深度减少，当前深度: $LOCK_DEPTH"
        return
    fi

    if [[ -d "$LOCK_DIR" ]] && [[ -f "$LOCK_DIR/pid" ]] && [[ "$(cat "$LOCK_DIR/pid")" == "$$" ]]; then
        rm -rf "$LOCK_DIR" 2>/dev/null
        log_debug "锁已释放"
    else
        log_debug "锁目录异常，跳过删除"
    fi
}

# 检查内联规则文件是否包含禁止的顶层关键字
check_inline_forbidden_keywords() {
    local file="$1"
    if grep -Eq '^[[:space:]]*(table|chain|type|hook|priority)[[:space:]]+' "$file"; then
        log_error "自定义规则文件 $file 包含禁止的顶层关键字 (table, chain, type, hook, priority)，已忽略"
        return 1
    fi
    return 0
}

# ========== 外部辅助函数（供 htb_cake.sh 调用） ==========
cleanup_qos_state() {
    log_info "执行 QoS 状态清理"
    rm -f "$QOS_RUNNING_FILE" 2>/dev/null
    rm -f "$SET_FAMILIES_FILE" 2>/dev/null
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
}

# ========== 数字验证（处理前导零） ==========
validate_number() {
    local value="$1" param_name="$2" min="${3:-0}" max="${4:-2147483647}"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log_error "参数 $param_name 必须是整数: $value"
        return 1
    fi
    value=$(echo "$value" | sed 's/^0*//')
    [[ -z "$value" ]] && value=0
    local clean_value=$((value))
    if (( clean_value < min || clean_value > max )); then
        log_error "参数 $param_name 范围应为 $min-$max: $value"
        return 1
    fi
    return 0
}

# 验证浮点数（用于 burst_factor）
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

    # 集合引用：以 @ 开头
    if [[ "$value" == @* ]]; then
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

# ========== IP 地址/CIDR 验证，支持集合、ipv6掩码 ==========
validate_ip() {
    local ip="$1"
    local raw="${ip#!=}"

    # 集合引用：以 @ 开头
    if [[ "$raw" == @* ]]; then
        return 0
    fi

    # IPv6 掩码格式：::suffix/::mask
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
    # 去除所有空白字符
    val=$(echo "$val" | tr -d '[:space:]' | tr -d '\r\n')
    [[ -z "$val" ]] && return 0

    # 如果值中包含字母 'k'，视为 'ack' 并直接通过
    if [[ "$val" == *k* ]]; then
        return 0
    fi

    IFS=',' read -ra flags <<< "$val"
    for f in "${flags[@]}"; do
        [[ -z "$f" ]] && continue
        case "$f" in
            syn|ack|rst|fin|urg|psh|ecn|cwr) ;;
            *) log_error "无效的 TCP 标志 '$f' (允许: syn,ack,rst,fin,urg,psh,ecn,cwr)"; return 1 ;;
        esac
    done
    return 0
}

# ========== 长度验证（包长度、UDP长度） ==========
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

# 验证内联规则文件（用于 include 嵌入）
validate_inline_rules() {
    local file_path="$1"
    local check_file=$(mktemp)
    local ret=0

    # 检查禁止关键字
    if ! check_inline_forbidden_keywords "$file_path"; then
        rm -f "$check_file"
        return 1
    fi

    # 包裹在临时 table/chain 中进行语法检查
    {
        printf '%s\n\t%s\n' "table inet __qos_custom_check {" "chain __temp_chain {"
        cat "$file_path"
        printf '\n\t%s\n%s\n' "}" "}"
    } > "$check_file"

    if nft --check --file "$check_file" 2>/dev/null; then
        ret=0
    else
        log_warn "内联规则文件 $file_path 语法错误"
        nft --check --file "$check_file" 2>&1 | while IFS= read -r err; do
            log_error "nft语法错误: $err"
        done
        ret=1
    fi
    rm -f "$check_file"
    return $ret
}

# 验证完整的 nftables 表规则文件（可直接 nft -f 加载）
validate_full_table_rules() {
    local file_path="$1"
    if nft --check --file "$file_path" 2>/dev/null; then
        return 0
    else
        log_warn "完整表规则文件 $file_path 语法错误"
        nft --check --file "$file_path" 2>&1 | while IFS= read -r err; do
            log_error "nft语法错误: $err"
        done
        return 1
    fi
}

# 加载完整表规则（供主脚本调用）
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

    # 直接执行文件，由文件中的语句自行管理表的删除与创建
    if nft -f "$custom_table_file" 2>&1; then
        log_info "完整表规则加载成功"
        return 0
    else
        log_error "完整表规则加载失败"
        return 1
    fi
}

# ========== 映射连接字节操作符 ==========
map_connbytes_operator() {
    local op="$1"
    case "$op" in
        ">")  echo "gt" ;;
        ">=") echo "ge" ;;
        "<")  echo "lt" ;;
        "<=") echo "le" ;;
        "!=") echo "ne" ;;
        "=")  echo "eq" ;;
        *)    echo "$op" ;;
    esac
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

    # 收集已指定的索引（包括可能禁用的类）
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

    # 为所有类分配索引（包括禁用的，以便将来启用时索引不变）
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

load_all_config_options() {
    local config_name="$1" section_id="$2" prefix="$3"
    for var in class order enabled proto srcport dstport connbytes_kb family state src_ip dest_ip \
          tcp_flags packet_len dscp iif oif icmp_type udp_length ttl; do
        eval "${prefix}${var}=''"
    done

    local val=""
    
    # 如果缓存可用，从 shell 变量读取
    if [[ $_UCI_CONFIG_CACHED -eq 1 ]]; then
        # 构造变量名: config_${section_id}_${opt}
        local var_name
        # 1. class
        var_name="config_${section_id}_class"
        eval "val=\${${var_name}:-}"
        if [[ -n "$val" ]]; then
            # 去除首尾引号（UCI 导出时会加引号）
            val="${val#\'}"; val="${val%\'}"; val="${val#\"}"; val="${val%\"}"
            # 去除换行和回车
            val=$(echo "$val" | tr -d '\n\r')
            # 只允许字母数字下划线连字符
            val=$(echo "$val" | sed 's/[^a-zA-Z0-9_-]//g')
            eval "${prefix}class=$(printf "%q" "$val")"
        else
            log_warn "配置节 $section_id 缺少 class 参数，忽略此规则"
            return 1
        fi

        # 2. 其他选项
        for opt in order enabled proto srcport dstport connbytes_kb family state src_ip dest_ip \
            tcp_flags packet_len dscp iif oif icmp_type udp_length ttl; do
            var_name="config_${section_id}_${opt}"
            eval "val=\${${var_name}:-}"
            [[ -z "$val" ]] && continue
            # 去除引号
            val="${val#\'}"; val="${val%\'}"; val="${val#\"}"; val="${val%\"}"
            # 去除换行
            val=$(echo "$val" | tr -d '\n\r')
            
            case "$opt" in
                order)   val=$(echo "$val" | sed 's/[^0-9]//g'); [[ -n "$val" ]] && eval "${prefix}order=$(printf "%q" "$val")" ;;
                enabled) val=$(echo "$val" | grep -o '^[01]'); [[ -n "$val" ]] && eval "${prefix}enabled=$(printf "%q" "$val")" ;;
                proto)   if validate_protocol "$val" "${section_id}.proto"; then
                             val=$(echo "$val" | sed 's/[^a-zA-Z0-9_]//g')
                             eval "${prefix}proto=$(printf "%q" "$val")"
                         else log_warn "规则 $section_id 协议 '$val' 无效，忽略此字段"; fi ;;
                srcport) if validate_port "$val" "${section_id}.srcport"; then
                             val=$(echo "$val" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')
                             eval "${prefix}srcport=$(printf "%q" "$val")"
                         else log_warn "规则 $section_id 源端口 '$val' 无效，忽略此字段"; fi ;;
                dstport) if validate_port "$val" "${section_id}.dstport"; then
                             val=$(echo "$val" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')
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
                    # 让 validate_tcp_flags 自行处理
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
}

# ========== UCI ipset 生成 nftables 集合 ==========
generate_ipset_sets() {
    [[ $_IPSET_LOADED -eq 1 ]] && return 0

    nft add table inet gargoyle-qos-priority 2>/dev/null || true

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
    # 移除版本检测，默认使用动态集合模式（nftables >= 0.9）
    local use_meter=0

    process_ratelimit_section() {
        local section="$1" name enabled download_limit upload_limit burst_factor target_values
        local meter_suffix download_kbytes upload_kbytes download_burst upload_burst meter_hash
        local sets_neg_v4="" sets_pos_v4="" ips_neg_v4="" ips_pos_v4=""
        local sets_neg_v6="" sets_pos_v6="" ips_neg_v6="" ips_pos_v6=""
        local value prefix setname set_family
        local download_burst_param='' upload_burst_param=''

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

        meter_hash=$(printf "%s" "$section" | cksum | cut -d' ' -f1)
        meter_suffix="${name}_${meter_hash}"
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

        # 动态集合模式（nftables >= 0.9）
        local timeout=60
        local set_timeout=$(uci -q get ${CONFIG_FILE}.${section}.timeout 2>/dev/null)
        [[ -n "$set_timeout" ]] && timeout="$set_timeout"
        local set_name_dl4="${prefix_set}${meter_suffix}_dl4"
        local set_name_ul4="${prefix_set}${meter_suffix}_ul4"
        local set_name_dl6="${prefix_set}${meter_suffix}_dl6"
        local set_name_ul6="${prefix_set}${meter_suffix}_ul6"

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
        # ${name} - Download limit (IPv4 IP ${type}) - in set drop
        ${cond} ip daddr @${set_name_dl4} counter drop comment \"${name} download (in set)\"
        # ${name} - Download limit (IPv4 IP ${type}) - rate limit
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
        # ${name} - Download limit (IPv6 IP ${type}) - in set drop
        ${cond} ip6 daddr @${set_name_dl6} counter drop comment \"${name} download (in set)\"
        # ${name} - Download limit (IPv6 IP ${type}) - rate limit
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
        # ${name} - Upload limit (IPv4 IP ${type}) - in set drop
        ${cond} ip saddr @${set_name_ul4} counter drop comment \"${name} upload (in set)\"
        # ${name} - Upload limit (IPv4 IP ${type}) - rate limit
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
        # ${name} - Upload limit (IPv6 IP ${type}) - in set drop
        ${cond} ip6 saddr @${set_name_ul6} counter drop comment \"${name} upload (in set)\"
        # ${name} - Upload limit (IPv6 IP ${type}) - rate limit
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
        echo "add chain inet gargoyle-qos-priority $RATELIMIT_CHAIN '{ type filter hook forward priority -10; policy accept; }'" > "$temp_ratelimit_file"
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

# ========== ACK 限速规则（统一使用 ct id 键） ==========
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

# ========== TCP 升级规则（统一使用 ct id 键） ==========
generate_tcp_upgrade_rules() {
    [[ $ENABLE_TCP_UPGRADE != 1 ]] && return
    local realtime_class=""
    
    # 查找 name=realtime 的上传类
    local upload_classes=$(load_all_config_sections "$CONFIG_FILE" "upload_class")
    for cls in $upload_classes; do
        local name=$(uci -q get ${CONFIG_FILE}.${cls}.name 2>/dev/null)
        [[ "$name" == "realtime" ]] && { realtime_class="$cls"; break; }
    done
    
    # 如果未找到 realtime，使用第一个启用的上传类
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

    # 检查类是否启用
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

# ========== nft 规则生成（核心，优化版） ==========
build_nft_rule_fast() {
    local rule_name="$1" chain="$2" class_mark="$3" mask="$4" family="$5" proto="$6"
    local srcport="$7" dstport="$8" connbytes_kb="$9" state="${10}" src_ip="${11}" dest_ip="${12}"
    local packet_len="${13}" tcp_flags="${14}" iif="${15}" oif="${16}" udp_length="${17}"
    local dscp="${18}" ttl="${19}" icmp_type="${20}"
    local has_ipv4=0 has_ipv6=0 ipv4_cond="" ipv6_cond=""
    local nft_op
    local common_cond=""

    # 使用 Bash 内置去除空白
    connbytes_kb="${connbytes_kb//[[:space:]]/}"
    packet_len="${packet_len//[[:space:]]/}"
    udp_length="${udp_length//[[:space:]]/}"
    tcp_flags="${tcp_flags//[[:space:]]/}"

    # 源 IP 处理
    if [[ -n "$src_ip" ]]; then
        local src_neg=""
        local src_val="$src_ip"
        [[ "$src_val" == "!="* ]] && { src_neg="!="; src_val="${src_val#!=}"; }
        if [[ "$src_val" == @* ]]; then
            # 集合引用，不分 IPv4/IPv6，直接使用
            ipv4_cond="$ipv4_cond ip saddr $src_neg $src_val"
            ipv6_cond="$ipv6_cond ip6 saddr $src_neg $src_val"
            has_ipv4=1
            has_ipv6=1
        elif [[ "$src_val" =~ ^::[0-9a-fA-F]+/::[0-9a-fA-F]+$ ]]; then
            # IPv6 掩码格式 ::suffix/::mask
            has_ipv6=1
            local suffix="${src_val%%/::*}"
            local mask="${src_val#*/::}"
            ipv6_cond="$ipv6_cond ip6 saddr & $mask == $suffix"
        elif [[ "$src_val" =~ : ]]; then
            has_ipv6=1
            ipv6_cond="$ipv6_cond ip6 saddr $src_neg $src_val"
        else
            has_ipv4=1
            ipv4_cond="$ipv4_cond ip saddr $src_neg $src_val"
        fi
    fi
    # 目的 IP 处理
    if [[ -n "$dest_ip" ]]; then
        local dest_neg=""
        local dest_val="$dest_ip"
        [[ "$dest_val" == "!="* ]] && { dest_neg="!="; dest_val="${dest_val#!=}"; }
        if [[ "$dest_val" == @* ]]; then
            ipv4_cond="$ipv4_cond ip daddr $dest_neg $dest_val"
            ipv6_cond="$ipv6_cond ip6 daddr $dest_neg $dest_val"
            has_ipv4=1
            has_ipv6=1
        elif [[ "$dest_val" =~ ^::[0-9a-fA-F]+/::[0-9a-fA-F]+$ ]]; then
            has_ipv6=1
            local suffix="${dest_val%%/::*}"
            local mask="${dest_val#*/::}"
            ipv6_cond="$ipv6_cond ip6 daddr & $mask == $suffix"
        elif [[ "$dest_val" =~ : ]]; then
            has_ipv6=1
            ipv6_cond="$ipv6_cond ip6 daddr $dest_neg $dest_val"
        else
            has_ipv4=1
            ipv4_cond="$ipv4_cond ip daddr $dest_neg $dest_val"
        fi
    fi

    local do_ipv4=0 do_ipv6=0
    case "$family" in
        ip|ipv4|inet4)
            if (( has_ipv4 )); then do_ipv4=1
            elif (( has_ipv6 )); then
                log_warn "规则 $rule_name 指定 family=ipv4 但只包含 IPv6 地址，规则将被忽略"
                return
            else do_ipv4=1; fi ;;
        ip6|ipv6|inet6)
            if (( has_ipv6 )); then do_ipv6=1
            elif (( has_ipv4 )); then
                log_warn "规则 $rule_name 指定 family=ipv6 但只包含 IPv4 地址，规则将被忽略"
                return
            else do_ipv6=1; fi ;;
        inet)
            (( has_ipv4 )) && do_ipv4=1
            (( has_ipv6 )) && do_ipv6=1
            if (( do_ipv4 == 0 && do_ipv6 == 0 )); then
                do_ipv4=1; do_ipv6=1
            fi ;;
        *) log_error "规则 $rule_name 无效的 family '$family'"; return ;;
    esac

    # 协议
    case "$proto" in
        tcp) common_cond="meta l4proto tcp" ;;
        udp) common_cond="meta l4proto udp" ;;
        tcp_udp) common_cond="meta l4proto { tcp, udp }" ;;
        all|"") ;;
        *) common_cond="meta l4proto $proto" ;;
    esac

    # 包长度
    if [[ -n "$packet_len" ]]; then
        if [[ "$packet_len" == *-* ]]; then
            local min="${packet_len%-*}" max="${packet_len#*-}"
            common_cond="$common_cond meta length >= $min meta length <= $max"
        elif [[ "$packet_len" =~ ^([<>]=?|!=)[0-9]+$ ]]; then
            local operator="${packet_len%%[0-9]*}"
            local num="${packet_len##*[!0-9]}"
            case "$operator" in
                ">") nft_op="gt" ;;
                ">=") nft_op="ge" ;;
                "<") nft_op="lt" ;;
                "<=") nft_op="le" ;;
                "!=") nft_op="ne" ;;
                "=")  nft_op="eq" ;;
                *)   nft_op="$operator" ;;
            esac
            common_cond="$common_cond meta length $nft_op $num"
        elif [[ "$packet_len" =~ ^[0-9]+$ ]]; then
            common_cond="$common_cond meta length eq $packet_len"
        else
            log_warn "规则 $rule_name 包长度 '$packet_len' 格式无效，已忽略"
        fi
    fi

    # TCP 标志
    if [[ -n "$tcp_flags" ]] && [[ "$proto" == "tcp" ]]; then
        local clean_flags=""
        IFS=',' read -ra flags <<< "$tcp_flags"
        for flag in "${flags[@]}"; do
            flag="${flag//[[:space:]]/}"
            if [[ "$flag" == *k* ]]; then
                flag="ack"
            fi
            case "$flag" in
                syn|ack|rst|fin|urg|psh|ecn|cwr)
                    if [[ -z "$clean_flags" ]]; then
                        clean_flags="$flag"
                    else
                        clean_flags="$clean_flags,$flag"
                    fi
                    ;;
                *) log_warn "规则 $rule_name TCP标志 '$flag' 无效，已忽略" ;;
            esac
        done
        if [[ -n "$clean_flags" ]]; then
            common_cond="$common_cond tcp flags { $clean_flags }"
        fi
    fi

    # 接口
    [[ -n "$iif" ]] && common_cond="$common_cond iifname \"$iif\""
    [[ -n "$oif" ]] && common_cond="$common_cond oifname \"$oif\""

    # UDP 长度
    if [[ -n "$udp_length" ]] && [[ "$proto" == "udp" ]]; then
        if [[ "$udp_length" == *-* ]]; then
            local min="${udp_length%-*}" max="${udp_length#*-}"
            common_cond="$common_cond udp length >= $min udp length <= $max"
        elif [[ "$udp_length" =~ ^([<>]=?|!=)[0-9]+$ ]]; then
            local operator="${udp_length%%[0-9]*}"
            local num="${udp_length##*[!0-9]}"
            case "$operator" in
                ">") nft_op="gt" ;;
                ">=") nft_op="ge" ;;
                "<") nft_op="lt" ;;
                "<=") nft_op="le" ;;
                "!=") nft_op="ne" ;;
                "=")  nft_op="eq" ;;
                *)   nft_op="$operator" ;;
            esac
            common_cond="$common_cond udp length $nft_op $num"
        elif [[ "$udp_length" =~ ^[0-9]+$ ]]; then
            common_cond="$common_cond udp length eq $udp_length"
        else
            log_warn "规则 $rule_name UDP长度 '$udp_length' 格式无效，已忽略"
        fi
    fi

    # 端口匹配（上传/下载方向不同，支持集合引用）
    if [[ "$proto" =~ ^(tcp|udp|tcp_udp)$ ]]; then
        if [[ "$chain" == *"ingress"* ]]; then
            if [[ -n "$srcport" ]]; then
                local sport_val="${srcport//[[:space:]]/}"
                if [[ "$sport_val" == @* ]]; then
                    common_cond="$common_cond th sport $sport_val"
                else
                    common_cond="$common_cond th sport { $sport_val }"
                fi
            fi
        else
            if [[ -n "$dstport" ]]; then
                local dport_val="${dstport//[[:space:]]/}"
                if [[ "$dport_val" == @* ]]; then
                    common_cond="$common_cond th dport $dport_val"
                else
                    common_cond="$common_cond th dport { $dport_val }"
                fi
            fi
        fi
    fi

    # 连接状态
    if [[ -n "$state" ]]; then
        local state_value="${state//[{}]/}"
        if [[ "$state_value" == *,* ]]; then
            common_cond="$common_cond ct state { $state_value }"
        else
            common_cond="$common_cond ct state $state_value"
        fi
    fi

    # 连接字节数
    if [[ -n "$connbytes_kb" ]]; then
        if [[ "$connbytes_kb" == *-* ]]; then
            local min_val="${connbytes_kb%-*}" max_val="${connbytes_kb#*-}"
            local min_bytes=$((min_val * 1024)) max_bytes=$((max_val * 1024))
            common_cond="$common_cond ct bytes >= $min_bytes ct bytes <= $max_bytes"
        elif [[ "$connbytes_kb" =~ ^([<>]=?|!=)[0-9]+$ ]]; then
            local operator="${connbytes_kb%%[0-9]*}"
            local num="${connbytes_kb##*[!0-9]}"
            local op=""
            case "$operator" in
                ">") op="gt" ;;
                ">=") op="ge" ;;
                "<") op="lt" ;;
                "<=") op="le" ;;
                "!=") op="ne" ;;
                "=")  op="eq" ;;
                *)   op="$operator" ;;
            esac
            local bytes_value=$((num * 1024))
            common_cond="$common_cond ct bytes $op $bytes_value"
        elif [[ "$connbytes_kb" =~ ^[0-9]+$ ]]; then
            local bytes_value=$((connbytes_kb * 1024))
            common_cond="$common_cond ct bytes eq $bytes_value"
        else
            log_warn "规则 $rule_name 连接字节数 '$connbytes_kb' 格式无效，已忽略"
        fi
    fi

    local base_cmd="add rule inet gargoyle-qos-priority $chain meta mark == 0"

    # IPv4 规则
    if (( do_ipv4 )); then
        local cmd="$base_cmd meta nfproto ipv4"
        [[ -n "$common_cond" ]] && cmd="$cmd $common_cond"
        [[ -n "$ipv4_cond" ]] && cmd="$cmd $ipv4_cond"

        if [[ -n "$dscp" ]]; then
            local dscp_val="$dscp"
            local neg=""
            [[ "$dscp_val" == "!="* ]] && { neg="!="; dscp_val="${dscp_val#!=}"; }
            cmd="$cmd ip dscp $neg $dscp_val"
        fi

        if [[ -n "$ttl" ]]; then
            local ttl_val="$ttl"
            if [[ "$ttl_val" =~ ^([<>]=?|!=)[0-9]+$ ]]; then
                local operator="${ttl_val%%[0-9]*}"
                local num="${ttl_val##*[!0-9]}"
                case "$operator" in
                    ">") nft_op="gt" ;;
                    ">=") nft_op="ge" ;;
                    "<") nft_op="lt" ;;
                    "<=") nft_op="le" ;;
                    "!=") nft_op="ne" ;;
                    "=")  nft_op="eq" ;;
                    *)   nft_op="$operator" ;;
                esac
                cmd="$cmd ip ttl $nft_op $num"
            else
                cmd="$cmd ip ttl eq $ttl_val"
            fi
        fi

        if [[ -n "$icmp_type" ]] && [[ "$proto" == "icmp" ]]; then
            local icmp_val="$icmp_type"
            local neg=""
            [[ "$icmp_val" == "!="* ]] && { neg="!="; icmp_val="${icmp_val#!=}"; }
            if [[ "$icmp_val" == */* ]]; then
                local type="${icmp_val%/*}" code="${icmp_val#*/}"
                cmd="$cmd icmp type $neg $type icmp code $code"
            else
                cmd="$cmd icmp type $neg $icmp_val"
            fi
        fi

        if [[ "$chain" == *"ingress"* ]]; then
            cmd="$cmd meta mark set $class_mark ct mark set meta mark counter"
        else
            cmd="$cmd meta mark set $class_mark counter"
        fi
        echo "$cmd"
    fi

    # IPv6 规则
    if (( do_ipv6 )); then
        local cmd="$base_cmd meta nfproto ipv6"
        [[ -n "$common_cond" ]] && cmd="$cmd $common_cond"
        [[ -n "$ipv6_cond" ]] && cmd="$cmd $ipv6_cond"

        if [[ -n "$dscp" ]]; then
            local dscp_val="$dscp"
            local neg=""
            [[ "$dscp_val" == "!="* ]] && { neg="!="; dscp_val="${dscp_val#!=}"; }
            cmd="$cmd ip6 dscp $neg $dscp_val"
        fi

        if [[ -n "$ttl" ]]; then
            local hop_val="$ttl"
            if [[ "$hop_val" =~ ^([<>]=?|!=)[0-9]+$ ]]; then
                local operator="${hop_val%%[0-9]*}"
                local num="${hop_val##*[!0-9]}"
                case "$operator" in
                    ">") nft_op="gt" ;;
                    ">=") nft_op="ge" ;;
                    "<") nft_op="lt" ;;
                    "<=") nft_op="le" ;;
                    "!=") nft_op="ne" ;;
                    "=")  nft_op="eq" ;;
                    *)   nft_op="$operator" ;;
                esac
                cmd="$cmd ip6 hoplimit $nft_op $num"
            else
                cmd="$cmd ip6 hoplimit eq $hop_val"
            fi
        fi

        if [[ -n "$icmp_type" ]] && [[ "$proto" == "icmpv6" ]]; then
            local icmp_val="$icmp_type"
            local neg=""
            [[ "$icmp_val" == "!="* ]] && { neg="!="; icmp_val="${icmp_val#!=}"; }
            if [[ "$icmp_val" == */* ]]; then
                local type="${icmp_val%/*}" code="${icmp_val#*/}"
                cmd="$cmd icmpv6 type $neg $type icmpv6 code $code"
            else
                cmd="$cmd icmpv6 type $neg $icmp_val"
            fi
        fi

        if [[ "$chain" == *"ingress"* ]]; then
            cmd="$cmd meta mark set $class_mark ct mark set meta mark counter"
        else
            cmd="$cmd meta mark set $class_mark counter"
        fi
        echo "$cmd"
    fi
}

apply_enhanced_direction_rules() {
    local rule_type="$1" chain="$2" mask="$3"
    log_info "应用增强$rule_type规则到链: $chain, 掩码: $mask"

    nft add chain inet gargoyle-qos-priority "$chain" 2>/dev/null || true
    nft flush chain inet gargoyle-qos-priority "$chain" 2>/dev/null || true

    local direction=""
    [[ "$chain" == "filter_qos_egress" ]] && direction="upload"
    [[ "$chain" == "filter_qos_ingress" ]] && direction="download"

    local rule_list=$(load_all_config_sections "$CONFIG_FILE" "$rule_type")
    [[ -z "$rule_list" ]] && { log_info "未找到$rule_type规则配置"; return 0; }
    log_info "找到$rule_type规则: $rule_list"

    # 预加载当前方向所有类的优先级
    local class_priority_map
    declare -A class_priority_map
    local class_list=""
    [[ "$direction" == "upload" ]] && class_list="$upload_class_list"
    [[ "$direction" == "download" ]] && class_list="$download_class_list"
    for class in $class_list; do
        local prio=$(uci -q get ${CONFIG_FILE}.${class}.priority 2>/dev/null)
        class_priority_map["$class"]=${prio:-999}
    done

    # 临时文件：存储 "composite_priority rule_name"
    local rule_prio_file=$(mktemp)
    TEMP_FILES+=("$rule_prio_file")

    # 第一遍遍历：收集规则优先级信息
    local rule
    for rule in $rule_list; do
        [[ -n "$rule" ]] || continue
        if load_all_config_options "$CONFIG_FILE" "$rule" "tmp_"; then
            [[ "$tmp_enabled" != "1" ]] && continue
            local class_priority=${class_priority_map["$tmp_class"]:-999}
            local rule_order=${tmp_order:-100}
            local composite=$(( class_priority * 1000 + rule_order ))
            echo "$composite $rule" >> "$rule_prio_file"
        fi
    done

    # 排序（按数字升序）
    local sorted_rule_list=$(sort -n -k1,1 "$rule_prio_file" | awk '{print $2}' | tr '\n' ' ')
    rm -f "$rule_prio_file"

    if [[ -z "$sorted_rule_list" ]]; then
        log_info "没有可用的启用规则"
        return 0
    fi

    local nft_batch_file=$(mktemp /tmp/qos_nft_batch_XXXXXX)
    TEMP_FILES+=("$nft_batch_file")

    log_info "按优先级顺序生成nft规则..."
    local rule_count=0
    for rule_name in $sorted_rule_list; do
        if ! load_all_config_options "$CONFIG_FILE" "$rule_name" "tmp_"; then
            continue
        fi
        [[ "$tmp_enabled" == "1" ]] || continue

        local class_mark=$(get_class_mark "$direction" "$tmp_class")
        [[ -z "$class_mark" ]] && { log_error "规则 $rule_name 的类 $tmp_class 无法获取标记，跳过"; continue; }
        [[ -z "$tmp_family" ]] && tmp_family="inet"

        local clean_srcport=$(echo "$tmp_srcport" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')
        local clean_dstport=$(echo "$tmp_dstport" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')

        build_nft_rule_fast "$rule_name" "$chain" "$class_mark" "$mask" "$tmp_family" "$tmp_proto" \
            "$clean_srcport" "$clean_dstport" "$tmp_connbytes_kb" "$tmp_state" "$tmp_src_ip" "$tmp_dest_ip" \
            "$tmp_packet_len" "$tmp_tcp_flags" "$tmp_iif" "$tmp_oif" "$tmp_udp_length" \
            "$tmp_dscp" "$tmp_ttl" "$tmp_icmp_type" >> "$nft_batch_file"
        ((rule_count++))
    done

    # 自定义内联规则（出口和入口共用，使用 include）
    local custom_inline_file="$CUSTOM_INLINE_FILE"
    if [[ -s "$custom_inline_file" ]]; then
        log_info "验证自定义内联规则: $custom_inline_file"
        local check_file=$(mktemp)
        TEMP_FILES+=("$check_file")
        {
            printf '%s\n\t%s\n' "table inet __qos_custom_check {" "chain __temp_chain {"
            cat "$custom_inline_file"
            printf '\n\t%s\n%s\n' "}" "}"
        } > "$check_file"
        if nft --check --file "$check_file" 2>/dev/null; then
            log_info "自定义内联规则语法正确: $custom_inline_file"
            echo "include \"$custom_inline_file\";" >> "$nft_batch_file"
            ((rule_count++))
        else
            log_warn "自定义内联规则文件 $custom_inline_file 语法错误，已忽略"
            nft --check --file "$check_file" 2>&1 | while IFS= read -r err; do
                log_error "nft语法错误: $err"
            done
        fi
        rm -f "$check_file"
    fi

    local batch_success=0
    if [[ -s "$nft_batch_file" ]]; then
        log_info "执行批量nft规则 (共 $rule_count 条)..."
        local nft_output
        nft_output=$(nft -f "$nft_batch_file" 2>&1)
        local nft_ret=$?
        if [[ $nft_ret -eq 0 ]]; then
            log_info "✅ 批量规则应用成功"
            if [[ $SAVE_NFT_RULES -eq 1 ]]; then
                mkdir -p /etc/nftables.d
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

    rm -f "$nft_batch_file"
    return $batch_success
}

# ========== 获取 WAN 接口 ==========
get_wan_interface() {
    local wan_if
    wan_if=$(uci -q get ${CONFIG_FILE}.global.wan_interface 2>/dev/null)
    if [[ -z "$wan_if" ]] && [[ -f "/lib/functions/network.sh" ]]; then
        . /lib/functions/network.sh
        network_find_wan wan_if
    fi
    echo "$wan_if"
}

# ========== 应用所有规则（包括钩子挂载） ==========
apply_all_rules() {
    local rule_type="$1" mask="$2" chain="$3"
    log_info "开始应用 $rule_type 规则到链 $chain (掩码: $mask)"

    if ! nft list table inet gargoyle-qos-priority &>/dev/null; then
        log_info "nft 表不存在，将重新初始化"
        _QOS_TABLE_FLUSHED=0
        _IPSET_LOADED=0
        _HOOKS_SETUP=0
    fi

    if [[ $_QOS_TABLE_FLUSHED -eq 0 ]]; then
        log_info "初始化 nftables 表"
        nft add table inet gargoyle-qos-priority 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop995 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop95 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop50 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority $RATELIMIT_CHAIN 2>/dev/null || true
        nft add chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null || true
        nft add chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null || true
        generate_ipset_sets

        local sets_ok=1
        for set in _qos_xfst_ack _qos_fast_ack _qos_med_ack _qos_slow_ack _qos_slow_tcp; do
            if ! nft list set inet gargoyle-qos-priority "$set" &>/dev/null; then
                #nft add set inet gargoyle-qos-priority "$set" '{ type ct id; flags dynamic; timeout 5m; }' 2>/dev/null || sets_ok=0
				nft add set inet gargoyle-qos-priority "$set" '{ typeof ct id . ct direction; flags dynamic; timeout 5m; }'
            fi
        done

        if [[ $sets_ok -eq 0 ]]; then
            log_error "动态集合创建失败，ACK 限速和 TCP 升级功能将被禁用"
            ENABLE_ACK_LIMIT=0
            ENABLE_TCP_UPGRADE=0
        fi

        nft add chain inet gargoyle-qos-priority drop995 2>/dev/null || true
        nft add chain inet gargoyle-qos-priority drop95 2>/dev/null || true
        nft add chain inet gargoyle-qos-priority drop50 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop995 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop95 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop50 2>/dev/null || true
        nft add rule inet gargoyle-qos-priority drop995 numgen random mod 1000 ge 995 return
        nft add rule inet gargoyle-qos-priority drop995 drop
        nft add rule inet gargoyle-qos-priority drop95 numgen random mod 1000 ge 950 return
        nft add rule inet gargoyle-qos-priority drop95 drop
        nft add rule inet gargoyle-qos-priority drop50 numgen random mod 1000 ge 500 return
        nft add rule inet gargoyle-qos-priority drop50 drop

        _QOS_TABLE_FLUSHED=1
    fi

    if [[ $_HOOKS_SETUP -eq 0 ]]; then
        log_info "挂载 nftables 钩子链"

        local wan_if=$(get_wan_interface)
        if [[ -z "$wan_if" ]]; then
            log_error "无法获取 WAN 接口，钩子链可能不完整，QoS 可能无法正确区分方向"
        else
            log_info "使用 WAN 接口: $wan_if"
        fi

        nft add chain inet gargoyle-qos-priority filter_output '{ type filter hook output priority 0; policy accept; }' 2>/dev/null || true
        nft add chain inet gargoyle-qos-priority filter_input  '{ type filter hook input  priority 0; policy accept; }' 2>/dev/null || true
        nft add chain inet gargoyle-qos-priority filter_forward '{ type filter hook forward priority 0; policy accept; }' 2>/dev/null || true

        nft flush chain inet gargoyle-qos-priority filter_output 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority filter_input  2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority filter_forward 2>/dev/null || true

        nft add rule inet gargoyle-qos-priority filter_output jump filter_qos_egress 2>/dev/null || true
        if [[ -n "$wan_if" ]]; then
            nft add rule inet gargoyle-qos-priority filter_forward oifname "$wan_if" jump filter_qos_egress 2>/dev/null || true
            nft add rule inet gargoyle-qos-priority filter_forward iifname "$wan_if" jump filter_qos_ingress 2>/dev/null || true
        else
            log_warn "未配置 WAN 接口，将不使用方向区分，所有转发流量同时进入上传和下载链（可能导致双重标记）"
            nft add rule inet gargoyle-qos-priority filter_forward jump filter_qos_egress 2>/dev/null || true
            nft add rule inet gargoyle-qos-priority filter_forward jump filter_qos_ingress 2>/dev/null || true
        fi
        nft add rule inet gargoyle-qos-priority filter_input jump filter_qos_ingress 2>/dev/null || true

        _HOOKS_SETUP=1
		
	# 确保动态集合存在，并同步 ACK/TCP 启用标志
	local sets_ok=1
	for set in _qos_xfst_ack _qos_fast_ack _qos_med_ack _qos_slow_ack _qos_slow_tcp; do
		if ! nft list set inet gargoyle-qos-priority "$set" &>/dev/null; then
			nft add set inet gargoyle-qos-priority "$set" '{ typeof ct id . ct direction; flags dynamic; timeout 5m; }' 2>/dev/null || sets_ok=0
		fi
	done

	if [[ $sets_ok -eq 0 ]]; then
		log_error "动态集合创建失败，ACK 限速和 TCP 升级功能将被禁用"
		ENABLE_ACK_LIMIT=0
		ENABLE_TCP_UPGRADE=0
	else
		# 从 UCI 重新获取启用状态（确保与配置一致）
		local ack_val=$(uci -q get ${CONFIG_FILE}.global.enable_ack_limit 2>/dev/null)
		case "$ack_val" in 1|yes|true|on) ENABLE_ACK_LIMIT=1 ;; *) ENABLE_ACK_LIMIT=0 ;; esac
		local tcp_val=$(uci -q get ${CONFIG_FILE}.global.enable_tcp_upgrade 2>/dev/null)
		case "$tcp_val" in 1|yes|true|on) ENABLE_TCP_UPGRADE=1 ;; *) ENABLE_TCP_UPGRADE=0 ;; esac
	fi
        log_info "nftables 钩子链挂载完成"
    fi
    
	# 一次性加载所有 UCI 配置到 shell 变量（避免重复 uci show）
    if [[ $_UCI_CONFIG_CACHED -eq 0 ]]; then
        # 创建临时文件存放 uci -X export 结果
        _UCI_CACHE_FILE=$(mktemp)
        TEMP_FILES+=("$_UCI_CACHE_FILE")
        uci -X export ${CONFIG_FILE} > "$_UCI_CACHE_FILE" 2>/dev/null
        if [[ -s "$_UCI_CACHE_FILE" ]]; then
            # source 该文件，定义所有 config_* 变量
            source "$_UCI_CACHE_FILE"
            _UCI_CONFIG_CACHED=1
            log_debug "已加载 UCI 配置缓存"
        else
            log_warn "无法导出 UCI 配置，将回退到单次查询模式"
            _UCI_CONFIG_CACHED=2   # 标记为失败，后续使用原逻辑
        fi
    fi
	
    apply_enhanced_direction_rules "$rule_type" "$chain" "$mask"
    local ret=$?
    return $ret
}

# ========== 健康检查 ==========
health_check() {
    local errors=0 status=""
    uci -q show ${CONFIG_FILE} >/dev/null 2>&1 && status="${status}config:ok;" || { status="${status}config:missing;"; ((errors++)); }
    nft list table inet gargoyle-qos-priority >/dev/null 2>&1 && status="${status}nft:ok;" || { status="${status}nft:missing;"; ((errors++)); }
    local wan_if=$(uci -q get ${CONFIG_FILE}.global.wan_interface 2>/dev/null)
    if [[ -n "$wan_if" ]] && tc qdisc show dev "$wan_if" 2>/dev/null | grep -qE "htb|hfsc|cake"; then
        status="${status}tc:ok;"
    else
        status="${status}tc:missing;"; ((errors++))
    fi
    for mod in ifb sch_htb sch_hfsc sch_cake sch_fq_codel; do
        if ! lsmod 2>/dev/null | grep -q "^$mod"; then
            modprobe "$mod" 2>/dev/null || true
            if ! lsmod 2>/dev/null | grep -q "^$mod"; then
                status="${status}module_${mod}:missing;"
                ((errors++))
            fi
        fi
    done
    [[ -f "$CLASS_MARKS_FILE" ]] && status="${status}marks:ok;" || { status="${status}marks:missing;"; ((errors++)); }
    echo "status=$status;errors=$errors"
    return $((errors == 0 ? 0 : 1))
}

# ========== 内存限制计算 ==========
calculate_memory_limit() {
    local config_value="$1" result
    [[ -z "$config_value" ]] && { echo ""; return; }
    if [[ "$config_value" == "auto" ]]; then
        local total_mem_mb=0
        if [[ -f /sys/fs/cgroup/memory.max ]]; then
            local total_mem_bytes=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
            if [[ "$total_mem_bytes" =~ ^[0-9]+$ ]] && (( total_mem_bytes > 0 )); then
                total_mem_mb=$(( total_mem_bytes / 1024 / 1024 ))
                log_info "从 cgroup v2 memory.max 获取内存限制: ${total_mem_mb}MB"
            fi
        fi
        if (( total_mem_mb == 0 )) && [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
            local total_mem_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
            if [[ -n "$total_mem_bytes" ]] && (( total_mem_bytes > 0 )); then
                total_mem_mb=$(( total_mem_bytes / 1024 / 1024 ))
                log_info "从 cgroup v1 memory.limit_in_bytes 获取内存限制: ${total_mem_mb}MB"
            fi
        fi
        if (( total_mem_mb == 0 )); then
            local total_mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
            if [[ -n "$total_mem_kb" ]] && (( total_mem_kb > 0 )); then
                total_mem_mb=$(( total_mem_kb / 1024 ))
                log_info "从 /proc/meminfo 获取内存: ${total_mem_mb}MB"
            fi
        fi
        if (( total_mem_mb > 0 )); then
            result="$(((total_mem_mb + 63) / 64))Mb"
            local min_limit=8 max_limit=32
            local result_value=${result%Mb}
            if (( result_value < min_limit )); then result="${min_limit}Mb"
            elif (( result_value > max_limit )); then result="${max_limit}Mb"; fi
            log_info "系统内存 ${total_mem_mb}MB，自动计算 memlimit=${result}"
        else
            log_warn "无法读取内存信息，使用默认值 16Mb"; result="16Mb"
        fi
    else
        if [[ "$config_value" =~ ^[0-9]+Mb$ ]]; then
            result="$config_value"; log_info "使用用户配置的 memlimit: ${result}"
        else
            log_warn "无效的 memlimit 格式 '$config_value'，使用默认值 16Mb"; result="16Mb"
        fi
    fi
    echo "$result"
}

# ========== 带宽单位转换（增强版） ==========
convert_bandwidth_to_kbit() {
    local bw="$1" num unit multiplier result
    [[ -z "$bw" ]] && { log_error "带宽值为空"; return 1; }
    if [[ "$bw" =~ ^[0-9]+$ ]]; then echo "$bw"; return 0; fi

    # 提取数字和单位（支持小数）
    if [[ "$bw" =~ ^[0-9]+(\.[0-9]+)?[a-zA-Z]+$ ]]; then
        num=$(echo "$bw" | grep -oE '^[0-9]+(\.[0-9]+)?')
        unit=$(echo "$bw" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')
        case "$unit" in
            K|KBIT|KILOBIT|KBPS) multiplier=1 ;;
            M|MBIT|MEGABIT|MBPS) multiplier=1000 ;;
            G|GBIT|GIGABIT|GBPS) multiplier=1000000 ;;
            # 二进制字节单位（需乘8）
            KB|KIB) multiplier=8 ;;
            MB|MIB) multiplier=8000 ;;
            GB|GIB) multiplier=8000000 ;;
            *)
                # 尝试识别简写（如 10m -> 10M）
                if [[ "$unit" == "K" ]]; then multiplier=1
                elif [[ "$unit" == "M" ]]; then multiplier=1000
                elif [[ "$unit" == "G" ]]; then multiplier=1000000
                else
                    log_error "未知带宽单位: $unit"
                    return 1
                fi
                ;;
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

# ========== 检查 tc connmark 支持 ==========
check_tc_connmark_support() {
    modprobe sch_ingress 2>/dev/null
    modprobe act_connmark 2>/dev/null

    local dummy_dev="dummy0"
    ip link add "$dummy_dev" type dummy 2>/dev/null || {
        dummy_dev="lo"
    }
    tc qdisc del dev "$dummy_dev" ingress 2>/dev/null
    if ! tc qdisc add dev "$dummy_dev" ingress 2>/dev/null; then
        [[ "$dummy_dev" != "lo" ]] && ip link del "$dummy_dev" 2>/dev/null
        log_warn "无法在 $dummy_dev 上创建 ingress 队列，无法测试 connmark 支持"
        return 1
    fi
    local ret=1
    if tc filter add dev "$dummy_dev" parent ffff: protocol ip u32 match u32 0 0 action connmark 2>/dev/null; then
        ret=0
        tc filter del dev "$dummy_dev" parent ffff: 2>/dev/null
    fi
    tc qdisc del dev "$dummy_dev" ingress 2>/dev/null
    [[ "$dummy_dev" != "lo" ]] && ip link del "$dummy_dev" 2>/dev/null
    return $ret
}

# ========== 检查必需的命令 ==========
check_required_commands() {
    local missing=0
    for cmd in tc nft ip; do
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

# ========== 获取物理接口最大带宽（增强虚拟接口处理） ==========
get_physical_interface_max_bandwidth() {
    local interface="$1" max_bandwidth=""
    
    # 检测是否为虚拟接口（常见前缀）
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

    cp "/etc/config/${CONFIG_FILE}" "/etc/config/${CONFIG_FILE}.bak"
    log_info "已备份主配置文件到 ${CONFIG_FILE}.bak"

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
    if [[ -f "/etc/config/${CONFIG_FILE}.bak" ]]; then
        mv "/etc/config/${CONFIG_FILE}.bak" "/etc/config/${CONFIG_FILE}"
        uci commit ${CONFIG_FILE}
        log_info "已恢复主配置文件备份"
    fi
    rm -f "$RULESET_MERGED_FLAG"
    log_info "已清理规则集标记"
}

# ========== IPv6增强支持 ==========
setup_ipv6_specific_rules() {
    log_info "设置IPv6特定规则（优化版）"
    nft add chain inet gargoyle-qos-priority filter_prerouting '{ type filter hook prerouting priority 0; policy accept; }' 2>/dev/null || true
    nft flush chain inet gargoyle-qos-priority filter_prerouting 2>/dev/null || true
    local ICMPV6_CRITICAL_TYPES="133,134,135,136,137"

    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 daddr { ff02::1:2, ff02::1:3 } meta mark set 0x80000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 daddr ::1 meta mark set 0x80000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 icmpv6 type { $ICMPV6_CRITICAL_TYPES } meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport { 546, 547 } meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport 53 meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 tcp dport 53 meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 tcp dport { 80, 443 } meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport 123 meta mark set 0x40000000 counter 2>/dev/null || true
    log_info "IPv6关键流量规则设置完成"
}

# ========== 自动加载全局配置 ==========
if [[ -z "$_QOS_RULE_SH_LOADED" ]] && [[ "$(basename "$0")" != "rule.sh" ]]; then
    load_global_config
    _QOS_RULE_SH_LOADED=1
fi
