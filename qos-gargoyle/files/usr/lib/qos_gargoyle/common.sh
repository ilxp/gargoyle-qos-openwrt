#!/bin/bash
# 核心库模块 (common.sh)
# 版本: 3.5.11 (修复版)
# 提供 QoS 系统基础功能

# ========== 防止重复加载 ==========
if [[ -n "$_QOS_COMMON_SH_LOADED" ]]; then
    return 0
fi
_QOS_COMMON_SH_LOADED=1

# ========== 全局常量定义 ==========
readonly NFT_TABLE="qos-gargoyle-priority"
readonly NFT_FAMILY="inet"
readonly DEFAULT_IFB="ifb0"
readonly MAX_PRIORITY_INDEX=16

# ========== 加载 OpenWrt 标准函数库 ==========
. /lib/functions.sh 2>/dev/null || true

# ========== 全局配置常量 ==========
: ${DEBUG:=0}
: ${CONFIG_FILE:=qos_gargoyle}
: ${MAX_PHYSICAL_BANDWIDTH:=10000000}
: ${QOS_RUNNING_FILE:=/var/run/qos_gargoyle.running}
: ${CLASS_MARKS_FILE:=/etc/qos_gargoyle/class_marks}
: ${RULESET_DIR:=/etc/qos_gargoyle/rulesets}
: ${RULESET_MERGED_FLAG:=/tmp/qos_ruleset_merged}
: ${SET_FAMILIES_FILE:=/tmp/qos_gargoyle_set_families}
: ${CUSTOM_INLINE_FILE:=/etc/qos_gargoyle/egress_custom.nft}
: ${CUSTOM_EGRESS_FILE:=/etc/qos_gargoyle/egress_custom.nft}
: ${CUSTOM_INGRESS_FILE:=/etc/qos_gargoyle/ingress_custom.nft}
: ${CUSTOM_FULL_TABLE_FILE:=/etc/qos_gargoyle/custom_rules.nft}
: ${RATELIMIT_CHAIN:=ratelimit}
: ${CUSTOM_VALIDATION_FILE:=/tmp/qos_gargoyle_custom_validation.txt}
: ${EBPF_PROG_DIR:=/etc/qos_gargoyle/bpf}
: ${EBPF_PROG_EGRESS:=egress.o}
: ${EBPF_PROG_INGRESS:=ingress.o}
: ${ENABLE_EBPF:=0}
: ${DCLASSIFY_PRIO:=last}

# ========== 全局变量 ==========
if [[ -z "$_QOS_LIB_SH_LOADED" ]]; then
    _QOS_LIB_SH_LOADED=1

    upload_class_list=""
    download_class_list=""
    ENABLE_RATELIMIT=0
    ENABLE_ACK_LIMIT=0
    ENABLE_TCP_UPGRADE=0
    SAVE_NFT_RULES=0
    UDP_RATE_LIMIT_ENABLE=0
    UDP_RATE_LIMIT_RATE=450
    UDP_RATE_LIMIT_ACTION="mark"
    UDP_RATE_LIMIT_MARK_CLASS="bulk"
    AUTO_SPEEDTEST=0
    ENABLE_DYNAMIC_CLASSIFY=0
    _QOS_TABLE_FLUSHED=0
    _IPSET_LOADED=0
    _HOOKS_SETUP=0
    _EBPF_LOADED=0
    METER_SUPPORT_CHECKED=0
    METER_SUPPORT_AVAILABLE=0

    declare -A UCI_CACHE
    declare -A _SET_FAMILY_CACHE
    TEMP_FILES=()
fi

# ========== 检查是否已经在运行 ==========
check_already_running() {
    if [ -f "$QOS_RUNNING_FILE" ]; then
        local old_pid=$(cat "$QOS_RUNNING_FILE" 2>/dev/null)
        if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
            return 1
        else
            rm -f "$QOS_RUNNING_FILE"
        fi
    fi
    echo $$ > "$QOS_RUNNING_FILE"
    return 0
}

# ========== 公共辅助函数 ==========
strip_leading_zeros() {
    local val="$1"
    [[ -z "$val" || ! "$val" =~ ^[0-9]+$ ]] && { echo "0"; return; }
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
    local level="$1" message="$2" tag="qos_gargoyle" prefix=""
    [[ -z "$message" ]] && return
    case "$level" in
        ERROR|error)   prefix="错误:" ;;
        WARN|warn)     prefix="警告:" ;;
        INFO|info)     prefix="信息:" ;;
        DEBUG|debug)   prefix="调试:" ;;
        *)             prefix="$level:" ;;
    esac
    local syslog_level=$(echo "$level" | tr '[:upper:]' '[:lower:]')
    echo "$message" | logger -t "$tag" -p "user.$syslog_level" 2>/dev/null || \
        echo "$message" | while IFS= read -r line; do
            logger -t "$tag" "$prefix $line"
        done
    [[ "$DEBUG" == "1" ]] && echo "$message" | while IFS= read -r line; do
        echo "[$(date '+%H:%M:%S')] $tag $prefix $line" >&2
    done
}

# ========== 临时文件管理 ==========
register_temp_file() {
    local file="$1"
    if [[ -n "$file" ]]; then
        TEMP_FILES+=("$file")
    fi
}

cleanup_temp_files() {
    for f in "${TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null
    done
    TEMP_FILES=()
}

# ========== trap 串联（优化 #18） ==========
_old_trap=$(trap -p EXIT | awk '{print $3}' | sed "s/^'//;s/'$//")
if [[ -n "$_old_trap" ]]; then
    trap "cleanup_temp_files; $_old_trap" EXIT
else
    trap cleanup_temp_files EXIT
fi

# ========== 外部辅助函数 ==========
cleanup_qos_state() {
    log_info "执行 QoS 状态清理"
    rm -f "$QOS_RUNNING_FILE" "$SET_FAMILIES_FILE" "$CUSTOM_VALIDATION_FILE" 2>/dev/null
    [[ -d "/sys/fs/bpf/qos_gargoyle" ]] && rm -rf "/sys/fs/bpf/qos_gargoyle" 2>/dev/null
    _EBPF_LOADED=0
    _QOS_TABLE_FLUSHED=0
    _IPSET_LOADED=0
    _HOOKS_SETUP=0
    METER_SUPPORT_CHECKED=0
    METER_SUPPORT_AVAILABLE=0
    _SET_FAMILY_CACHE=()
    log_debug "已重置全局状态标志"
}

check_and_handle_zero_bandwidth() {
    local upload_bw="$1" download_bw="$2"
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
    val=$(uci -q get ${CONFIG_FILE}.global.save_nft_rules 2>/dev/null)
    case "$val" in 1|yes|true|on) SAVE_NFT_RULES=1 ;; *) SAVE_NFT_RULES=0 ;; esac
    val=$(uci -q get ${CONFIG_FILE}.global.enable_ebpf 2>/dev/null)
    case "$val" in 1|yes|true|on) ENABLE_EBPF=1 ;; *) ENABLE_EBPF=0 ;; esac

    # ACK 限速开关（从 global 节读取）
    local ack_enabled=$(uci -q get ${CONFIG_FILE}.global.enable_ack_limit 2>/dev/null)
    case "$ack_enabled" in 1|yes|true|on) ENABLE_ACK_LIMIT=1 ;; *) ENABLE_ACK_LIMIT=0 ;; esac

    # TCP 升级开关（从 global 节读取）
    local tcp_enabled=$(uci -q get ${CONFIG_FILE}.global.enable_tcp_upgrade 2>/dev/null)
    case "$tcp_enabled" in 1|yes|true|on) ENABLE_TCP_UPGRADE=1 ;; *) ENABLE_TCP_UPGRADE=0 ;; esac

    # UDP 限速开关（从 global 节读取）
    local udp_enabled=$(uci -q get ${CONFIG_FILE}.global.enable_udp_limit 2>/dev/null)
    case "$udp_enabled" in 1|yes|true|on) UDP_RATE_LIMIT_ENABLE=1 ;; *) UDP_RATE_LIMIT_ENABLE=0 ;; esac

    # 动态分类
    val=$(uci -q get ${CONFIG_FILE}.global.enable_dclassify 2>/dev/null)
    case "$val" in 1|yes|true|on) ENABLE_DCLASSIFY=1 ;; *) ENABLE_DCLASSIFY=0 ;; esac
	
    # 动态分类优先级
    DCLASSIFY_PRIO=$(uci -q get ${CONFIG_FILE}.global.dclassify_prio 2>/dev/null)
    : ${DCLASSIFY_PRIO:=last}
}

# ========== eBPF 支持函数 ==========
check_ebpf_support() {
    nft --help 2>&1 | grep -q "bpf" && return 0
    log_warn "当前 nftables 版本不支持 bpf 关键字，eBPF 功能将禁用"
    return 1
}

load_ebpf_program() {
    local prog_type="$1" target_chain="$2" prog_file=""
    [[ "$ENABLE_EBPF" != "1" ]] && return 0
    [[ $_EBPF_LOADED -eq 1 ]] && return 0
    case "$prog_type" in
        egress)   prog_file="$EBPF_PROG_DIR/$EBPF_PROG_EGRESS" ;;
        ingress)  prog_file="$EBPF_PROG_DIR/$EBPF_PROG_INGRESS" ;;
        *) log_error "未知 eBPF 程序类型: $prog_type"; return 1 ;;
    esac
    [[ ! -f "$prog_file" ]] && { log_info "eBPF 程序文件 $prog_file 不存在，跳过加载"; return 0; }
    if ! check_ebpf_support; then
        log_warn "内核不支持 nftables bpf 扩展，eBPF 程序无法加载"
        return 1
    fi
    local pin_path="/sys/fs/bpf/qos_gargoyle/${prog_type}"
    mkdir -p "/sys/fs/bpf/qos_gargoyle" 2>/dev/null
    if [[ ! -f "$pin_path" ]]; then
        if ! command -v bpftool >/dev/null 2>&1; then
            log_warn "bpftool 未安装，无法自动加载 eBPF 程序"
            return 1
        fi
        if bpftool prog load "$prog_file" "$pin_path" 2>/dev/null; then
            log_info "eBPF 程序 $prog_type 已加载并 pin 到 $pin_path"
        else
            log_warn "加载 eBPF 程序 $prog_file 失败"
            return 1
        fi
    fi
    [[ ! -f "$pin_path" ]] && { log_error "eBPF 程序 pin 文件不存在: $pin_path"; return 1; }
    local bpf_rule="insert rule inet ${NFT_TABLE} $target_chain meta mark == 0 bpf obj $pin_path counter"
    log_info "添加 eBPF 跳转规则: $bpf_rule"
    nft "$bpf_rule" 2>/dev/null || { log_warn "挂载 eBPF 程序失败"; return 1; }
    return 0
}

load_ebpf_programs() {
    [[ "$ENABLE_EBPF" != "1" ]] && return 0
    [[ $_EBPF_LOADED -eq 1 ]] && return 0
    log_info "开始加载 eBPF 程序..."
    nft add chain inet ${NFT_TABLE} filter_qos_egress 2>/dev/null || true
    nft add chain inet ${NFT_TABLE} filter_qos_ingress 2>/dev/null || true
    local ret=0
    load_ebpf_program "egress" "filter_qos_egress" || ret=1
    load_ebpf_program "ingress" "filter_qos_ingress" || ret=1
    if [[ $ret -eq 0 ]]; then
        _EBPF_LOADED=1
        log_info "eBPF 程序加载完成"
    else
        log_warn "部分 eBPF 程序加载失败，eBPF 功能可能不完整"
    fi
    return $ret
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
        validate_number "$min" "$param_name" 0 10485760 &&
        validate_number "$max" "$param_name" 0 10485760 &&
        (( min <= max ))
    elif [[ "$value" =~ ^([<>]=?|!=)[0-9]+$ ]]; then
        local num=$(echo "$value" | grep -o '[0-9]\+')
        validate_number "$num" "$param_name" 0 10485760
    elif [[ "$value" =~ ^[0-9]+$ ]]; then
        validate_number "$value" "$param_name" 0 10485760
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
    val=$(echo "$val" | tr -d '[:space:]' | tr -d '\r')
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

# 辅助函数：移除文件中的 BOM 头、Windows 行尾，并过滤注释和空行
_preprocess_nft_file() {
    local src="$1"
    local dst="$2"
    # 移除 UTF-8 BOM (如果存在)
    sed '1s/^\xEF\xBB\xBF//' "$src" | \
    # 移除 Windows 换行符 \r
    sed 's/\r$//' | \
    # 过滤掉注释行和空行
    grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' > "$dst"
    return 0
}

validate_full_table_rules() {
    local file_path="$1"
    [[ ! -s "$file_path" ]] && return 0

    local temp_file=$(mktemp)
    register_temp_file "$temp_file"
    _preprocess_nft_file "$file_path" "$temp_file"

    if [[ ! -s "$temp_file" ]]; then
        # 文件全是注释或空行，视为有效
        rm -f "$temp_file"
        return 0
    fi

    # 检查语法
    if nft --check --file "$temp_file" > "$CUSTOM_VALIDATION_FILE" 2>&1; then
        rm -f "$temp_file"
        return 0
    else
        log_warn "完整表规则文件 $file_path 语法错误"
        rm -f "$temp_file"
        return 1
    fi
}

validate_inline_rules() {
    local file_path="$1"
    [[ ! -s "$file_path" ]] && return 0

    # 检查是否有实际内容（过滤注释、空行、BOM、行尾）
    local temp_content=$(mktemp)
    register_temp_file "$temp_content"
    _preprocess_nft_file "$file_path" "$temp_content"

    if [[ ! -s "$temp_content" ]]; then
        # 文件全是注释或空行，视为有效
        rm -f "$temp_content"
        return 0
    fi
    rm -f "$temp_content"

    local check_file=$(mktemp)
    register_temp_file "$check_file"
    local ret=0
    if ! check_inline_forbidden_keywords "$file_path"; then
        rm -f "$check_file"
        return 1
    fi
    {
        printf '%s\n\t%s\n' "table inet __qos_custom_check {" "chain __temp_chain {"
        # 使用预处理后的内容，避免 BOM/^M 干扰
        _preprocess_nft_file "$file_path" "$check_file.tmp"
        cat "$check_file.tmp"
        rm -f "$check_file.tmp"
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

load_custom_full_table() {
    local custom_table_file="$CUSTOM_FULL_TABLE_FILE"
    if [[ ! -s "$custom_table_file" ]]; then
        log_debug "完整表规则文件不存在或为空，跳过加载"
        return 0
    fi

    # 预处理文件：移除 BOM、Windows 行尾、注释和空行
    local temp_file=$(mktemp)
    register_temp_file "$temp_file"
    _preprocess_nft_file "$custom_table_file" "$temp_file"

    if [[ ! -s "$temp_file" ]]; then
        log_debug "完整表规则文件无有效内容（全部为注释或空行），跳过加载"
        rm -f "$temp_file"
        return 0
    fi

    log_info "加载完整表规则: $custom_table_file"
    # 可选：仍然保留原始语法检查，但现在直接加载预处理文件
    if ! validate_full_table_rules "$custom_table_file"; then
        log_error "完整表规则文件 $custom_table_file 语法错误，跳过加载"
        rm -f "$temp_file"
        return 1
    fi

    # 删除旧的自定义表
    local custom_tables=$(nft list tables inet 2>/dev/null | sed -n 's/^table inet \([a-zA-Z0-9_]*\)$/\1/p' | grep '^gargoyle_custom_')
    for tbl in $custom_tables; do
        log_debug "删除旧的自定义表: $tbl"
        nft destroy table inet "$tbl" 2>/dev/null || true
    done

    # 加载预处理后的文件（而不是原始文件）
    if nft -f "$temp_file" 2>&1; then
        log_info "完整表规则加载成功"
        rm -f "$temp_file"
        return 0
    else
        log_error "完整表规则加载失败"
        rm -f "$temp_file"
        return 1
    fi
}

# ========== 标记分配 ==========
init_class_marks_file() {
    mkdir -p "$(dirname "$CLASS_MARKS_FILE")" 2>/dev/null
}

# 从标记值反推索引
get_index_from_mark() {
    local mark="$1" direction="$2"
    local base_value
    if [[ "$direction" == "upload" ]]; then
        base_value=1
    else
        base_value=65536
    fi
    local idx=1
    local tmp=$((mark / base_value))
    while [[ $((tmp & 1)) -eq 0 ]] && [[ $idx -le $MAX_PRIORITY_INDEX ]]; do
        tmp=$((tmp >> 1))
        idx=$((idx + 1))
    done
    if [[ $idx -le $MAX_PRIORITY_INDEX ]]; then
        echo "$idx"
    else
        echo ""
    fi
}

allocate_class_marks() {
    local direction="$1" class_list="$2"
    local base_value mark mark_index class_mark
    local -a used_indexes=()
    local temp_file=$(mktemp /tmp/qos_marks_XXXXXX)
    register_temp_file "$temp_file"
    init_class_marks_file
    
    if [[ "$direction" == "upload" ]]; then
        base_value=1
    else
        base_value=65536
    fi

    # 读取现有标记文件，建立 class -> mark 映射（清理注释和空格）
    declare -A class_mark_map
    if [[ -f "$CLASS_MARKS_FILE" ]]; then
        while IFS=: read -r dir cls mark; do
            [[ -z "$dir" || -z "$cls" || -z "$mark" ]] && continue
            # 去除 # 注释和所有空格
            mark="${mark%%#*}"
            mark="${mark// /}"
            [[ -z "$mark" ]] && continue
            if [[ "$dir" == "$direction" ]]; then
                class_mark_map["$cls"]="$mark"
            fi
        done < "$CLASS_MARKS_FILE"
    fi

    # 收集当前启用的类（过滤 enabled != 0）
    local enabled_classes=""
    for class in $class_list; do
        local enabled=$(uci -q get "${CONFIG_FILE}.${class}.enabled" 2>/dev/null)
        if [[ "$enabled" != "0" ]]; then
            enabled_classes="$enabled_classes $class"
        fi
    done
    enabled_classes=$(echo "$enabled_classes" | xargs)

    # 构建 used_indexes：只包含当前启用的类中，那些已有标记的索引
    for class in $enabled_classes; do
        if [[ -n "${class_mark_map[$class]}" ]]; then
            local idx=$(get_index_from_mark "${class_mark_map[$class]}" "$direction")
            if [[ -n "$idx" ]] && [[ ! " ${used_indexes[*]} " == *" $idx "* ]]; then
                used_indexes+=("$idx")
            fi
        fi
    done

    # 准备写入的条目
    local -a marks_to_write=()
    local next_auto=1

    for class in $enabled_classes; do
        # 如果该类已有标记，直接使用
        if [[ -n "${class_mark_map[$class]}" ]]; then
            class_mark="${class_mark_map[$class]}"
            log_info "类别 $class 使用原有标记值: $class_mark"
        else
            # 新类：优先使用用户指定的 mark_index
            mark_index=$(uci -q get "${CONFIG_FILE}.${class}.mark_index" 2>/dev/null)
            if [[ -n "$mark_index" ]] && validate_number "$mark_index" "$class.mark_index" 1 $MAX_PRIORITY_INDEX 2>/dev/null; then
                # 检查该索引是否被当前启用的类占用
                if [[ " ${used_indexes[*]} " == *" $mark_index "* ]]; then
                    log_error "类别 $class 指定的标记索引 $mark_index 已被占用"
                    rm -f "$temp_file"
                    return 1
                fi
                class_mark=$(( (base_value << (mark_index - 1)) & 0xFFFFFFFF ))
                used_indexes+=("$mark_index")
                log_info "类别 $class 使用用户指定索引 $mark_index (值: $class_mark)"
            else
                # 自动分配最小空闲索引（从1开始，跳过 used_indexes）
                while [[ " ${used_indexes[*]} " == *" $next_auto "* ]]; do
                    ((next_auto++))
                    if (( next_auto > $MAX_PRIORITY_INDEX )); then
                        log_error "没有可用的标记索引，无法为类别 $class 分配标记"
                        rm -f "$temp_file"
                        return 1
                    fi
                done
                mark_index=$next_auto
                class_mark=$(( (base_value << (mark_index - 1)) & 0xFFFFFFFF ))
                used_indexes+=("$mark_index")
                ((next_auto++))
                log_info "类别 $class 自动分配索引 $mark_index (值: $class_mark)"
            fi
        fi
        marks_to_write+=("$direction:$class:$class_mark")
    done

    # 写入标记文件：保留其他方向的条目，覆盖当前方向
    if [[ -f "$CLASS_MARKS_FILE" ]]; then
        grep -v "^$direction:" "$CLASS_MARKS_FILE" > "${temp_file}.keep" 2>/dev/null || true
        mv "${temp_file}.keep" "$CLASS_MARKS_FILE" 2>/dev/null
    else
        > "$CLASS_MARKS_FILE"
    fi
    for entry in "${marks_to_write[@]}"; do
        echo "$entry" >> "$CLASS_MARKS_FILE"
    done
    chmod 644 "$CLASS_MARKS_FILE"
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

# ========== 辅助函数：获取 CAKE diffserv 模式 ==========
get_cake_diffserv_mode() {
    local mode
    mode=$(uci -q get ${CONFIG_FILE}.cake.diffserv_mode 2>/dev/null)
    case "$mode" in
        diffserv3|diffserv4|diffserv5|diffserv8|besteffort)
            echo "$mode"
            ;;
        *)
            echo "diffserv4"
            ;;
    esac
}

# ========== 辅助函数：获取已分配标记中的最小/最大值 ==========
# 获取某方向的最小或最大标记值
# 参数: $1: 方向 (upload/download), $2: min|max
# 输出: 标记值，若找不到则返回空字符串并记录错误
get_min_max_mark() {
    local direction="$1"
    local which="$2"
    local marks=()

    if [[ ! -f "$CLASS_MARKS_FILE" ]]; then
        log_error "get_min_max_mark: class_marks 文件不存在"
        echo ""
        return 1
    fi

    while IFS=: read -r dir cls mark; do
        # 跳过无效行
        [[ -z "$dir" || -z "$cls" || -z "$mark" ]] && continue
        if [[ "$dir" == "$direction" && -n "$mark" ]]; then
            marks+=("$mark")
        fi
    done < "$CLASS_MARKS_FILE"

    if [[ ${#marks[@]} -eq 0 ]]; then
        log_error "get_min_max_mark: $direction 方向没有有效标记"
        echo ""
        return 1
    fi

    local sorted=($(printf "%s\n" "${marks[@]}" | sort -n))
    if [[ "$which" == "min" ]]; then
        echo "${sorted[0]}"
    else
        echo "${sorted[-1]}"
    fi
    return 0
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
        echo "$anonymous $named $old" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    else
        echo "$output" | grep -E "^${config_name}\\.[a-zA-Z_]+[0-9]*=" | cut -d= -f1 | cut -d. -f2
    fi
}

load_upload_class_configurations() {
    log_info "正在加载上传类别配置..."
    upload_class_list=$(load_all_config_sections "$CONFIG_FILE" "upload_class")
    # 过滤掉以 @ 开头的匿名节引用和空行
    upload_class_list=$(echo "$upload_class_list" | tr ' ' '\n' | grep -v '^@' | grep -v '^$' | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
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
    # 过滤掉以 @ 开头的匿名节引用和空行
    download_class_list=$(echo "$download_class_list" | tr ' ' '\n' | grep -v '^@' | grep -v '^$' | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [[ -n "$download_class_list" ]]; then
        log_info "找到下载类别: $download_class_list"
    else
        log_warn "没有找到下载类别配置"
        download_class_list=""
    fi
    return 0
}

# 加载配置选项（验证失败时记录错误并返回1，class 缺失视为致命错误）
load_all_config_options() {
    local config_name="$1" section_id="$2" prefix="$3"
    local var_name val
    # 清空变量（安全方式）
    for var in class order enabled proto srcport dstport connbytes_kb family state src_ip dest_ip \
          tcp_flags packet_len dscp iif oif icmp_type udp_length ttl; do
        printf -v "${prefix}${var}" "%s" ""
    done

    if [[ ${#UCI_CACHE[@]} -gt 0 ]]; then
        local key="${config_name}.${section_id}.class"
        val="${UCI_CACHE[$key]}"
        if [[ -z "$val" ]]; then
            log_error "配置节 $section_id 缺少 class 参数，忽略此规则"
            return 1
        fi
        printf -v "${prefix}class" "%s" "$val"
        for opt in order enabled proto srcport dstport connbytes_kb family state src_ip dest_ip \
            tcp_flags packet_len dscp iif oif icmp_type udp_length ttl; do
            local key="${config_name}.${section_id}.${opt}"
            val="${UCI_CACHE[$key]}"
            [[ -z "$val" ]] && continue
            case "$opt" in
                order)   val=$(echo "$val" | sed 's/[^0-9]//g') ;;
                enabled) val=$(echo "$val" | grep -o '^[01]') ;;
                proto)   if ! validate_protocol "$val" "${section_id}.proto"; then continue; fi ;;
                srcport) if ! validate_port "$val" "${section_id}.srcport"; then log_warn "规则 $section_id: srcport 无效，已忽略"; continue; fi ;;
                dstport) if ! validate_port "$val" "${section_id}.dstport"; then log_warn "规则 $section_id: dstport 无效，已忽略"; continue; fi ;;
                connbytes_kb) if ! validate_connbytes "$val" "${section_id}.connbytes_kb"; then continue; fi ;;
                family)  if ! validate_family "$val" "${section_id}.family"; then continue; fi ;;
                state)   val=$(echo "$val" | tr -d '{}' | sed 's/[^a-zA-Z,]//g'); if ! validate_state "$val" "${section_id}.state"; then continue; fi ;;
                src_ip)  if ! validate_ip "$val"; then log_warn "规则 $section_id: src_ip 无效，已忽略"; continue; fi ;;
                dest_ip) if ! validate_ip "$val"; then log_warn "规则 $section_id: dest_ip 无效，已忽略"; continue; fi ;;
                tcp_flags) if ! validate_tcp_flags "$val" "${section_id}.tcp_flags"; then continue; fi ;;
                packet_len) if ! validate_length "$val" "${section_id}.packet_len"; then continue; fi ;;
                dscp)       if ! validate_dscp "$val" "${section_id}.dscp"; then continue; fi ;;
                iif)        if ! validate_ifname "$val" "${section_id}.iif"; then continue; fi ;;
                oif)        if ! validate_ifname "$val" "${section_id}.oif"; then continue; fi ;;
                icmp_type)  if ! validate_icmp_type "$val" "${section_id}.icmp_type"; then continue; fi ;;
                udp_length) if ! validate_length "$val" "${section_id}.udp_length"; then continue; fi ;;
                ttl)        if ! validate_ttl "$val" "${section_id}.ttl"; then continue; fi ;;
            esac
            printf -v "${prefix}${opt}" "%s" "$val"
        done
        return 0
    fi

    log_debug "配置缓存不可用，从 UCI 直接读取规则 $section_id"
    local tmp_class
    tmp_class=$(uci -q get "${config_name}.${section_id}.class" 2>/dev/null)
    if [[ -z "$tmp_class" ]]; then
        log_error "配置节 $section_id 缺少 class 参数，忽略此规则"
        return 1
    fi
    printf -v "${prefix}class" "%s" "$tmp_class"
    for opt in order enabled proto srcport dstport connbytes_kb family state src_ip dest_ip \
        tcp_flags packet_len dscp iif oif icmp_type udp_length ttl; do
        local val
        val=$(uci -q get "${config_name}.${section_id}.${opt}" 2>/dev/null)
        [[ -z "$val" ]] && continue
        case "$opt" in
            order)   val=$(echo "$val" | sed 's/[^0-9]//g') ;;
            enabled) val=$(echo "$val" | grep -o '^[01]') ;;
            proto)   if ! validate_protocol "$val" "${section_id}.proto"; then continue; fi ;;
            srcport) if ! validate_port "$val" "${section_id}.srcport"; then log_warn "规则 $section_id: srcport 无效，已忽略"; continue; fi ;;
            dstport) if ! validate_port "$val" "${section_id}.dstport"; then log_warn "规则 $section_id: dstport 无效，已忽略"; continue; fi ;;
            connbytes_kb) if ! validate_connbytes "$val" "${section_id}.connbytes_kb"; then continue; fi ;;
            family)  if ! validate_family "$val" "${section_id}.family"; then continue; fi ;;
            state)   val=$(echo "$val" | tr -d '{}' | sed 's/[^a-zA-Z,]//g'); if ! validate_state "$val" "${section_id}.state"; then continue; fi ;;
            src_ip)  if ! validate_ip "$val"; then log_warn "规则 $section_id: src_ip 无效，已忽略"; continue; fi ;;
            dest_ip) if ! validate_ip "$val"; then log_warn "规则 $section_id: dest_ip 无效，已忽略"; continue; fi ;;
            tcp_flags) if ! validate_tcp_flags "$val" "${section_id}.tcp_flags"; then continue; fi ;;
            packet_len) if ! validate_length "$val" "${section_id}.packet_len"; then continue; fi ;;
            dscp)       if ! validate_dscp "$val" "${section_id}.dscp"; then continue; fi ;;
            iif)        if ! validate_ifname "$val" "${section_id}.iif"; then continue; fi ;;
            oif)        if ! validate_ifname "$val" "${section_id}.oif"; then continue; fi ;;
            icmp_type)  if ! validate_icmp_type "$val" "${section_id}.icmp_type"; then continue; fi ;;
            udp_length) if ! validate_length "$val" "${section_id}.udp_length"; then continue; fi ;;
            ttl)        if ! validate_ttl "$val" "${section_id}.ttl"; then continue; fi ;;
        esac
        printf -v "${prefix}${opt}" "%s" "$val"
    done
    return 0
}

# ========== UCI ipset 生成 nftables 集合 ==========
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
    echo "$name $family" >> "$SET_FAMILIES_FILE"
    if [[ "$mode" == "dynamic" ]]; then
        echo "add set inet ${NFT_TABLE} $name { type ${family}_addr; flags dynamic, timeout; timeout $timeout; }" >> "$IPSET_TEMP_FILE"
    else
        if [[ "$family" == "ipv6" ]]; then
            [[ -n "$ip6_list" ]] && elements=$(echo "$ip6_list" | tr '\n' ' ' | tr -s ' ' ',' | sed 's/^,//;s/,$//')
        else
            [[ -n "$ip4_list" ]] && elements=$(echo "$ip4_list" | tr '\n' ' ' | tr -s ' ' ',' | sed 's/^,//;s/,$//')
        fi
        if [[ -n "$elements" ]]; then
            echo "add set inet ${NFT_TABLE} $name { type ${family}_addr; flags interval; elements = { $elements }; }" >> "$IPSET_TEMP_FILE"
        else
            echo "add set inet ${NFT_TABLE} $name { type ${family}_addr; flags interval; }" >> "$IPSET_TEMP_FILE"
        fi
    fi
    log_info "已生成 ipset: $name ($family, mode=$mode)"
}

generate_ipset_sets() {
    [[ $_IPSET_LOADED -eq 1 ]] && return 0
    nft add table inet ${NFT_TABLE} 2>/dev/null || true
    if ! type config_load >/dev/null 2>&1; then
        . /lib/functions.sh
    fi
    config_load "$CONFIG_FILE" 2>/dev/null
    local IPSET_TEMP_FILE=$(mktemp /tmp/qos_ipset_sets_XXXXXX)
    register_temp_file "$IPSET_TEMP_FILE"
    > "$SET_FAMILIES_FILE"
    local sections=$(load_all_config_sections "$CONFIG_FILE" "ipset")
    for section in $sections; do
        process_ipset_section "$section"
    done
    if [[ -s "$IPSET_TEMP_FILE" ]]; then
        nft -f "$IPSET_TEMP_FILE" 2>/dev/null || log_warn "部分 ipset 集合加载失败，请检查 UCI 配置"
        log_info "已加载 UCI 定义的 ipset 集合"
    fi
    rm -f "$IPSET_TEMP_FILE"
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
        case "$burst_factor" in
            *.*)
                local burst_int="${burst_factor%.*}"
                local burst_dec="${burst_factor#*.}"
                [ -z "$burst_int" ] && burst_int='0'
                [ -z "$burst_dec" ] && burst_dec='0'
                case "${#burst_dec}" in
                    1) burst_dec="${burst_dec}0" ;;
                    2) ;;
                    *) burst_dec="${burst_dec:0:2}" ;;
                esac
                if command -v bc >/dev/null 2>&1; then
                    download_burst=$(echo "$download_kbytes * $burst_int + $download_kbytes * $burst_dec / 100" | bc | awk '{printf "%.0f", $1}')
                    upload_burst=$(echo "$upload_kbytes * $burst_int + $upload_kbytes * $burst_dec / 100" | bc | awk '{printf "%.0f", $1}')
                else
                    download_burst=$(awk "BEGIN {printf \"%.0f\", $download_kbytes * $burst_int + $download_kbytes * $burst_dec / 100}")
                    upload_burst=$(awk "BEGIN {printf \"%.0f\", $upload_kbytes * $burst_int + $upload_kbytes * $burst_dec / 100}")
                fi
                ;;
            *)
                download_burst=$((download_kbytes * burst_factor))
                upload_burst=$((upload_kbytes * burst_factor))
                ;;
        esac
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
                set_family=$(nft list set inet ${NFT_TABLE} "$setname" 2>/dev/null | grep -o 'type [a-z0-9_]*' | head -1 | awk '{print $2}')
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
        echo "create set inet ${NFT_TABLE} ${set_name_dl4} { type ipv4_addr; flags dynamic, timeout; timeout ${timeout}; }" >> "$RATELIMIT_TEMP_FILE"
        echo "create set inet ${NFT_TABLE} ${set_name_dl6} { type ipv6_addr; flags dynamic, timeout; timeout ${timeout}; }" >> "$RATELIMIT_TEMP_FILE"
    fi
    if [[ $upload_limit -gt 0 ]]; then
        echo "create set inet ${NFT_TABLE} ${set_name_ul4} { type ipv4_addr; flags dynamic, timeout; timeout ${timeout}; }" >> "$RATELIMIT_TEMP_FILE"
        echo "create set inet ${NFT_TABLE} ${set_name_ul6} { type ipv6_addr; flags dynamic, timeout; timeout ${timeout}; }" >> "$RATELIMIT_TEMP_FILE"
    fi
    if [[ $download_limit -gt 0 ]]; then
        for grp in "pos:$ips_pos_v4" "neg:$ips_neg_v4"; do
            local type="${grp%:*}" iplist="${grp#*:}"
            [[ -z "$iplist" ]] && continue
            local cond=""
            build_ip_conditions_for_direction "$iplist" "daddr" cond
            if [[ -n "$cond" ]]; then
                echo "# ${name} - Download limit (IPv4 IP ${type})" >> "$RATELIMIT_TEMP_FILE"
                echo "${cond} ip daddr @${set_name_dl4} counter drop comment \"${name} download (in set)\"" >> "$RATELIMIT_TEMP_FILE"
                echo "${cond} ip daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl4} { ip daddr } counter drop comment \"${name} download (rate limit)\"" >> "$RATELIMIT_TEMP_FILE"
            fi
        done
        for set in $sets_pos_v4; do
            echo "# ${name} - Download limit (IPv4 set @${set})" >> "$RATELIMIT_TEMP_FILE"
            echo "ip daddr @${set} ip daddr @${set_name_dl4} counter drop comment \"${name} download (in set)\"" >> "$RATELIMIT_TEMP_FILE"
            echo "ip daddr @${set} ip daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl4} { ip daddr } counter drop comment \"${name} download (rate limit)\"" >> "$RATELIMIT_TEMP_FILE"
        done
        for set in $sets_neg_v4; do
            echo "# ${name} - Download limit (IPv4 set != @${set})" >> "$RATELIMIT_TEMP_FILE"
            echo "ip daddr != @${set} ip daddr @${set_name_dl4} counter drop comment \"${name} download (in set)\"" >> "$RATELIMIT_TEMP_FILE"
            echo "ip daddr != @${set} ip daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl4} { ip daddr } counter drop comment \"${name} download (rate limit)\"" >> "$RATELIMIT_TEMP_FILE"
        done
        for grp in "pos:$ips_pos_v6" "neg:$ips_neg_v6"; do
            local type="${grp%:*}" iplist="${grp#*:}"
            [[ -z "$iplist" ]] && continue
            local cond=""
            build_ip_conditions_for_direction "$iplist" "daddr" cond
            if [[ -n "$cond" ]]; then
                echo "# ${name} - Download limit (IPv6 IP ${type})" >> "$RATELIMIT_TEMP_FILE"
                echo "${cond} ip6 daddr @${set_name_dl6} counter drop comment \"${name} download (in set)\"" >> "$RATELIMIT_TEMP_FILE"
                echo "${cond} ip6 daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl6} { ip6 daddr } counter drop comment \"${name} download (rate limit)\"" >> "$RATELIMIT_TEMP_FILE"
            fi
        done
        for set in $sets_pos_v6; do
            echo "# ${name} - Download limit (IPv6 set @${set})" >> "$RATELIMIT_TEMP_FILE"
            echo "ip6 daddr @${set} ip6 daddr @${set_name_dl6} counter drop comment \"${name} download (in set)\"" >> "$RATELIMIT_TEMP_FILE"
            echo "ip6 daddr @${set} ip6 daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl6} { ip6 daddr } counter drop comment \"${name} download (rate limit)\"" >> "$RATELIMIT_TEMP_FILE"
        done
        for set in $sets_neg_v6; do
            echo "# ${name} - Download limit (IPv6 set != @${set})" >> "$RATELIMIT_TEMP_FILE"
            echo "ip6 daddr != @${set} ip6 daddr @${set_name_dl6} counter drop comment \"${name} download (in set)\"" >> "$RATELIMIT_TEMP_FILE"
            echo "ip6 daddr != @${set} ip6 daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl6} { ip6 daddr } counter drop comment \"${name} download (rate limit)\"" >> "$RATELIMIT_TEMP_FILE"
        done
    fi
    if [[ $upload_limit -gt 0 ]]; then
        for grp in "pos:$ips_pos_v4" "neg:$ips_neg_v4"; do
            local type="${grp%:*}" iplist="${grp#*:}"
            [[ -z "$iplist" ]] && continue
            local cond=""
            build_ip_conditions_for_direction "$iplist" "saddr" cond
            if [[ -n "$cond" ]]; then
                echo "# ${name} - Upload limit (IPv4 IP ${type})" >> "$RATELIMIT_TEMP_FILE"
                echo "${cond} ip saddr @${set_name_ul4} counter drop comment \"${name} upload (in set)\"" >> "$RATELIMIT_TEMP_FILE"
                echo "${cond} ip saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul4} { ip saddr } counter drop comment \"${name} upload (rate limit)\"" >> "$RATELIMIT_TEMP_FILE"
            fi
        done
        for set in $sets_pos_v4; do
            echo "# ${name} - Upload limit (IPv4 set @${set})" >> "$RATELIMIT_TEMP_FILE"
            echo "ip saddr @${set} ip saddr @${set_name_ul4} counter drop comment \"${name} upload (in set)\"" >> "$RATELIMIT_TEMP_FILE"
            echo "ip saddr @${set} ip saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul4} { ip saddr } counter drop comment \"${name} upload (rate limit)\"" >> "$RATELIMIT_TEMP_FILE"
        done
        for set in $sets_neg_v4; do
            echo "# ${name} - Upload limit (IPv4 set != @${set})" >> "$RATELIMIT_TEMP_FILE"
            echo "ip saddr != @${set} ip saddr @${set_name_ul4} counter drop comment \"${name} upload (in set)\"" >> "$RATELIMIT_TEMP_FILE"
            echo "ip saddr != @${set} ip saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul4} { ip saddr } counter drop comment \"${name} upload (rate limit)\"" >> "$RATELIMIT_TEMP_FILE"
        done
        for grp in "pos:$ips_pos_v6" "neg:$ips_neg_v6"; do
            local type="${grp%:*}" iplist="${grp#*:}"
            [[ -z "$iplist" ]] && continue
            local cond=""
            build_ip_conditions_for_direction "$iplist" "saddr" cond
            if [[ -n "$cond" ]]; then
                echo "# ${name} - Upload limit (IPv6 IP ${type})" >> "$RATELIMIT_TEMP_FILE"
                echo "${cond} ip6 saddr @${set_name_ul6} counter drop comment \"${name} upload (in set)\"" >> "$RATELIMIT_TEMP_FILE"
                echo "${cond} ip6 saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul6} { ip6 saddr } counter drop comment \"${name} upload (rate limit)\"" >> "$RATELIMIT_TEMP_FILE"
            fi
        done
        for set in $sets_pos_v6; do
            echo "# ${name} - Upload limit (IPv6 set @${set})" >> "$RATELIMIT_TEMP_FILE"
            echo "ip6 saddr @${set} ip6 saddr @${set_name_ul6} counter drop comment \"${name} upload (in set)\"" >> "$RATELIMIT_TEMP_FILE"
            echo "ip6 saddr @${set} ip6 saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul6} { ip6 saddr } counter drop comment \"${name} upload (rate limit)\"" >> "$RATELIMIT_TEMP_FILE"
        done
        for set in $sets_neg_v6; do
            echo "# ${name} - Upload limit (IPv6 set != @${set})" >> "$RATELIMIT_TEMP_FILE"
            echo "ip6 saddr != @${set} ip6 saddr @${set_name_ul6} counter drop comment \"${name} upload (in set)\"" >> "$RATELIMIT_TEMP_FILE"
            echo "ip6 saddr != @${set} ip6 saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul6} { ip6 saddr } counter drop comment \"${name} upload (rate limit)\"" >> "$RATELIMIT_TEMP_FILE"
        done
    fi
}

generate_ratelimit_rules() {
    [[ $ENABLE_RATELIMIT != 1 ]] && return
    if ! type config_load >/dev/null 2>&1; then
        . /lib/functions.sh
    fi
    config_load "$CONFIG_FILE" 2>/dev/null
    local RATELIMIT_TEMP_FILE=$(mktemp /tmp/qos_ratelimit_rules_XXXXXX)
    register_temp_file "$RATELIMIT_TEMP_FILE"
    local sections=$(load_all_config_sections "$CONFIG_FILE" "ratelimit")
    for section in $sections; do
        process_ratelimit_section "$section"
    done

    cat "$RATELIMIT_TEMP_FILE"
    rm -f "$RATELIMIT_TEMP_FILE"
}

setup_ratelimit_chain() {
    [[ $ENABLE_RATELIMIT != 1 ]] && return 0
    local rules=$(generate_ratelimit_rules)
    if [[ -n "$rules" ]]; then
        local old_sets=$(nft list set inet ${NFT_TABLE} 2>/dev/null | sed -n 's/^[[:space:]]*set \([a-zA-Z0-9_]\+\).*/\1/p' | grep '^rl_')
        for set in $old_sets; do
            nft delete set inet ${NFT_TABLE} "$set" 2>/dev/null || true
        done

        local temp_ratelimit_file=$(mktemp /tmp/qos_ratelimit_XXXXXX)
        register_temp_file "$temp_ratelimit_file"
        echo "create chain inet ${NFT_TABLE} $RATELIMIT_CHAIN '{ type filter hook forward priority -10; policy accept; }'" > "$temp_ratelimit_file"
        echo "flush chain inet ${NFT_TABLE} $RATELIMIT_CHAIN" >> "$temp_ratelimit_file"
        echo "$rules" | while IFS= read -r rule; do
            [[ -z "$rule" ]] && continue
            [[ "${rule#\#}" != "$rule" ]] && continue
            echo "add rule inet ${NFT_TABLE} $RATELIMIT_CHAIN $rule" >> "$temp_ratelimit_file"
        done
        nft -f "$temp_ratelimit_file" 2>/dev/null || { log_error "无法创建速率限制链"; return 1; }
        log_info "速率限制链已创建并填充规则"
        rm -f "$temp_ratelimit_file"
    fi
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
        family=$(nft list set inet ${NFT_TABLE} "$setname" 2>/dev/null | grep -o 'type [a-z0-9_]*' | head -1 | awk '{print $2}')
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
        local set_list=$(nft list sets "$table" 2>/dev/null | sed -n 's/^[[:space:]]*set \([a-zA-Z0-9_]\+\).*/\1/p')
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

# ========== 带宽单位转换（修正单位歧义） ==========
convert_bandwidth_to_kbit() {
    local bw="$1" num unit multiplier result
    [[ -z "$bw" ]] && { log_error "带宽值为空"; return 1; }
    bw=$(echo "$bw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    
    # 纯数字直接返回（视为 kbit）
    if [[ "$bw" =~ ^[0-9]+$ ]]; then 
        echo "$bw"
        return 0
    fi
    
    # 匹配数字+单位
    if [[ "$bw" =~ ^([0-9]+(\.[0-9]+)?)([a-z]+)(/?s?)?$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[3]}"
        unit="${unit%/*}"
        
        case "$unit" in
            # 比特单位（直接转换）
            kbit|kbits|kbit/s|kbps)    multiplier=1 ;;
            mbit|mbits|mbit/s|mbps)    multiplier=1000 ;;
            gbit|gbits|gbit/s|gbps)    multiplier=1000000 ;;
            # 字节单位（需乘以8）
            kb|kib)                    multiplier=8 ;;
            mb|mib)                    multiplier=8000 ;;
            gb|gib)                    multiplier=8000000 ;;
            # 常见简写：单独 k/m/g 默认当作比特（因为网络配置中更常见）
            k)                         multiplier=1 ;;
            m)                         multiplier=1000 ;;
            g)                         multiplier=1000000 ;;
            *) log_error "未知带宽单位: $unit"; return 1 ;;
        esac
        
        # 使用 bc 或 awk 计算
        if command -v bc >/dev/null 2>&1; then
            result=$(echo "$num * $multiplier" | bc | awk '{printf "%.0f", $1}')
        else
            result=$(awk "BEGIN {printf \"%.0f\", $num * $multiplier}")
        fi
        
        if [[ -z "$result" || ! "$result" =~ ^[0-9]+$ ]]; then
            log_error "带宽转换失败: $bw"
            return 1
        fi
        echo "$result"
        return 0
    else
        log_error "无效带宽格式: $bw (应为数字或数字+单位，例如 100mbit、10M)"
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
    if [[ -n "$wan_if" ]]; then
        qos_interface="$wan_if"
        log_info "已设置 WAN 接口: $qos_interface"
    fi
    return 0
}

# ========== 检查必需的命令 ==========
check_required_commands() {
    local missing=0
    for cmd in tc nft ip awk logger; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "命令 '$cmd' 未找到，请安装相应软件包"
            missing=1
        fi
    done
    if ! command -v bc >/dev/null 2>&1; then
        log_info "bc 未安装，将使用 awk 进行浮点数运算"
    fi
    if ! command -v ethtool >/dev/null 2>&1; then
        log_info "ethtool 未安装，将尝试从 sysfs 获取接口速度"
    fi
    return $missing
}

# ========== 加载必需的内核模块（改进检测） ==========
load_required_modules() {
    local missing=0
    for mod in ifb sch_ingress; do
        # 直接尝试加载，无论是否已加载（modprobe 对已加载模块无影响）
        if ! modprobe "$mod" 2>/dev/null; then
            log_error "无法加载内核模块 $mod"
            missing=1
        fi
    done
    # 尝试加载可选模块，不检查错误
    modprobe act_connmark 2>/dev/null || log_info "act_connmark 模块未加载，入口 connmark 功能可能受限"
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

# ========== 检查 tc connmark 支持 ==========
# 检测 tc connmark 支持（实际测试为主）
check_tc_connmark_support() {
    # 方法1：检查 /proc/net/pkt_act（内核已加载 act_connmark 时存在）
    if grep -q "act_connmark" /proc/net/pkt_act 2>/dev/null; then
        log_debug "内核支持 act_connmark (在 /proc/net/pkt_act 中)"
        return 0
    fi
    
    # 方法2：检查已加载的模块
    if lsmod 2>/dev/null | grep -q "^act_connmark"; then
        log_debug "act_connmark 模块已加载"
        return 0
    fi
    
    # 方法3：直接尝试在回环接口上测试 connmark 动作（最准确）
    # 保存当前 lo 的 root qdisc 以便恢复
    local old_qdisc=$(tc qdisc show dev lo 2>/dev/null | grep -E "^qdisc" | head -1 | awk '{print $2}')
    
    # 创建 ingress qdisc（用于测试 filter）
    tc qdisc del dev lo ingress 2>/dev/null
    if ! tc qdisc add dev lo ingress 2>/dev/null; then
        log_warn "无法在 lo 上创建 ingress 队列，假定 connmark 不支持"
        return 1
    fi
    
    local ret=1
    if tc filter add dev lo parent ffff: protocol ip \
        u32 match u32 0 0 action connmark 2>/dev/null; then
        ret=0
        tc filter del dev lo parent ffff: 2>/dev/null
        log_debug "tc connmark 动作在 lo 接口上测试成功"
    fi
    
    # 清理测试队列
    tc qdisc del dev lo ingress 2>/dev/null
    
    # 恢复原来的 root qdisc（如果之前存在且不是 noqueue/pfifo_fast）
    if [[ -n "$old_qdisc" && "$old_qdisc" != "noqueue" && "$old_qdisc" != "pfifo_fast" ]]; then
        tc qdisc add dev lo root $old_qdisc 2>/dev/null || true
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

# 检查 tc ctinfo 支持（使用 lo 接口）
check_tc_ctinfo_support() {
    local ret=1
    local old_qdisc

    # 保存当前 lo 的 root qdisc
    old_qdisc=$(tc qdisc show dev lo 2>/dev/null | grep -E "^qdisc" | head -1 | awk '{print $2}')

    # 创建 ingress qdisc
    tc qdisc del dev lo ingress 2>/dev/null
    if ! tc qdisc add dev lo ingress 2>/dev/null; then
        log_warn "无法在 lo 上创建 ingress 队列，假定 ctinfo 不支持"
        return 1
    fi

    # 使用与出口方向相同的语法（仅 cpmark）
    if tc filter add dev lo parent ffff: protocol all matchall \
        action ctinfo cpmark 0xffffffff 2>/dev/null; then
        ret=0
        tc filter del dev lo parent ffff: 2>/dev/null
    else
        # 如果 cpmark 失败，再尝试完整的 dscp+cpmark 语法（兼容旧内核）
        if tc filter add dev lo parent ffff: protocol all matchall \
            action ctinfo dscp 0xfc000000 0x01000000 cpmark 0xffffffff 2>/dev/null; then
            ret=0
            tc filter del dev lo parent ffff: 2>/dev/null
        fi
    fi

    # 清理
    tc qdisc del dev lo ingress 2>/dev/null

    # 恢复原来的 root qdisc
    if [[ -n "$old_qdisc" && "$old_qdisc" != "noqueue" && "$old_qdisc" != "pfifo_fast" ]]; then
        tc qdisc add dev lo root $old_qdisc 2>/dev/null || true
    fi

    return $ret
}

# ========== 规则集合并（使用 uci batch 批量导入，在主初始化代码中调用） ==========
init_ruleset() {
    local nofix="$1"
    if [[ "$nofix" == "1" ]]; then
        return 0
    fi

    local current_ruleset ruleset_file
    current_ruleset=$(uci -q get ${CONFIG_FILE}.global.ruleset 2>/dev/null)
    [[ -z "$current_ruleset" ]] && current_ruleset="default.ru"
    case "$current_ruleset" in *.ru) ;; *) current_ruleset="${current_ruleset}.ru" ;; esac
    ruleset_file="$RULESET_DIR/$current_ruleset"
    if [[ ! -f "$ruleset_file" ]]; then
        log_error "规则集文件 $ruleset_file 不存在，无法加载任何规则！"
        return 1
    fi

    # 预验证：检查规则集文件是否包含至少一个带名称的有效节（包括分类规则和增强参数）
    if ! grep -qE "^[[:space:]]*config[[:space:]]+(upload_class|download_class|upload_rule|download_rule|ack_limit|tcp_upgrade|udp_limit|bulk_detect|htp_detect)[[:space:]]+'[^']+'" "$ruleset_file"; then
        log_error "规则集文件 $ruleset_file 不包含任何有效的节（upload_class/download_class/upload_rule/download_rule/ack_limit/tcp_upgrade/udp_limit/bulk_detect/htp_detect 且带名称），跳过导入"
        return 1
    fi

    local applied_ruleset=$(uci -q get ${CONFIG_FILE}.global.applied_ruleset 2>/dev/null)
    if [[ "$applied_ruleset" == "$current_ruleset" ]]; then
        log_debug "规则集未变更 ($current_ruleset)，跳过合并"
        return 0
    fi

    log_info "规则集已从 '$applied_ruleset' 变更为 '$current_ruleset'，将重新合并"

    # 备份
    local backup_base="/etc/config/${CONFIG_FILE}.bak.${current_ruleset}"
    local backup_file="${backup_base}.$(date +%s)"
    cp "/etc/config/${CONFIG_FILE}" "$backup_file" || {
        log_error "备份主配置文件失败"
        return 1
    }
    log_info "已备份主配置文件到 $backup_file"

    # 清理旧备份
    local backups=($(ls -t ${backup_base}.* 2>/dev/null))
    if [[ ${#backups[@]} -gt 3 ]]; then
        for ((i=3; i<${#backups[@]}; i++)); do
            rm -f "${backups[$i]}" 2>/dev/null
            log_debug "删除旧备份: ${backups[$i]}"
        done
    fi

    # 构建批量命令文件
    local batch_file=$(mktemp)
    register_temp_file "$batch_file"

    # 删除全局记录的应用规则集标记
    echo "delete ${CONFIG_FILE}.global.applied_ruleset" >> "$batch_file"

    # 删除所有匿名节（通过索引）
    for type in upload_class download_class upload_rule download_rule; do
        local idx=0
        while uci -q get ${CONFIG_FILE}.@${type}[${idx}] >/dev/null 2>&1; do
            echo "delete ${CONFIG_FILE}.@${type}[${idx}]" >> "$batch_file"
            idx=$((idx + 1))
        done
    done

    # 删除所有有名节（包括分类规则和增强参数节）
    local all_sections=$(uci show ${CONFIG_FILE} 2>/dev/null | grep -oE "${CONFIG_FILE}\.(upload_class|download_class|upload_rule|download_rule|ack_limit|tcp_upgrade|udp_limit|bulk_detect|htp_detect)\.[a-zA-Z0-9_]+" | cut -d. -f3 | sort -u)
    for section in $all_sections; do
        echo "delete ${CONFIG_FILE}.${section}" >> "$batch_file"
    done

    # 导入新规则集
    local in_config=0 config_type="" config_name=""
    local -A seen_sections

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ ^[[:space:]]*config[[:space:]]+([a-zA-Z0-9_]+)[[:space:]]+\'([^\']+)\' ]]; then
            config_type="${BASH_REMATCH[1]}"
            config_name="${BASH_REMATCH[2]}"
            if [ -z "$config_name" ]; then
                in_config=0
                continue
            fi
            case "$config_type" in
                upload_class|download_class|upload_rule|download_rule|ack_limit|tcp_upgrade|udp_limit|bulk_detect|htp_detect)
                    if [[ -n "${seen_sections[$config_name]}" ]]; then
                        log_warn "规则集文件 $ruleset_file 中存在重复的节名 '$config_name'，后面的定义将覆盖前面的"
                    fi
                    seen_sections["$config_name"]=1
                    echo "add ${CONFIG_FILE} ${config_type}" >> "$batch_file"
                    echo "set ${CONFIG_FILE}.${config_name}=${config_type}" >> "$batch_file"
                    in_config=1
                    ;;
                *) in_config=0 ;;
            esac
        elif [[ "$in_config" -eq 1 && "$line" =~ ^[[:space:]]*option[[:space:]]+([a-zA-Z0-9_]+)[[:space:]]+\'([^\']+)\' ]]; then
            local opt="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            echo "set ${CONFIG_FILE}.${config_name}.${opt}=${val}" >> "$batch_file"
        fi
    done < "$ruleset_file"

    echo "set ${CONFIG_FILE}.global.applied_ruleset=${current_ruleset}" >> "$batch_file"

    # 执行批量命令
    local batch_output
    if batch_output=$(uci -q batch < "$batch_file" 2>&1); then
        uci commit ${CONFIG_FILE}
        log_info "已将规则集 $current_ruleset 合并到主配置文件"
    else
        log_error "导入规则集 $current_ruleset 失败，错误输出: $batch_output"
        cp "$backup_file" "/etc/config/${CONFIG_FILE}" && uci commit ${CONFIG_FILE} 2>/dev/null
        rm -f "$batch_file"
        return 1
    fi

    rm -f "$batch_file"

    # 后处理：删除所有没有名称的 config 节（空节）
    local config_file="/etc/config/${CONFIG_FILE}"
    if [ -f "$config_file" ]; then
        cp "$config_file" "${config_file}.tmp"
        # 删除匹配 'config upload_class' 等后面没有引号的行（即空节）
        sed -i '/^config upload_class$/d' "$config_file"
        sed -i '/^config download_class$/d' "$config_file"
        sed -i '/^config upload_rule$/d' "$config_file"
        sed -i '/^config download_rule$/d' "$config_file"
        sed -i '/^config ack_limit$/d' "$config_file"
        sed -i '/^config tcp_upgrade$/d' "$config_file"
        sed -i '/^config udp_limit$/d' "$config_file"
        sed -i '/^config bulk_detect$/d' "$config_file"
        sed -i '/^config htp_detect$/d' "$config_file"
        if ! cmp -s "${config_file}.tmp" "$config_file"; then
            uci commit ${CONFIG_FILE}
            log_info "已清理配置文件中的空节"
        fi
        rm -f "${config_file}.tmp"
    fi

    log_info "规则集合并完成"
    return 0
}

# 停止时恢复配置（仅记录，无需实际恢复，因为规则集已持久化）
restore_main_config() {
    log_info "已清理 QoS 停止时的临时资源（规则集标记已保留在主配置文件中）"
}

# ========== 内存限制计算（增强版，支持大小写不敏感，返回小写单位） ==========
calculate_memory_limit() {
    local config_value="$1" result
    [[ -z "$config_value" ]] && { echo ""; return; }
    # 去除可能的引号和空格
    local cleaned=$(echo "$config_value" | sed "s/['\"]//g" | tr -d ' ')
    local lower_val=$(echo "$cleaned" | tr "A-Z" "a-z")
    
    if [[ "$lower_val" == "auto" ]]; then
        local total_mem_mb=0
        
        # 优先从 /proc/meminfo 获取物理内存总量（最可靠）
        local total_mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
        if [[ -n "$total_mem_kb" ]] && (( total_mem_kb > 0 )); then
            total_mem_mb=$(( total_mem_kb / 1024 ))
            log_info "从 /proc/meminfo 获取物理内存: ${total_mem_mb}MB"
        else
            # 回退到 cgroup v1 或 v2（但需处理 max 值）
            if [[ -f /sys/fs/cgroup/memory.max ]]; then
                local mem_max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
                if [[ "$mem_max" =~ ^[0-9]+$ ]]; then
                    total_mem_mb=$(( mem_max / 1024 / 1024 ))
                    log_info "从 cgroup v2 memory.max 获取内存限制: ${total_mem_mb}MB"
                else
                    log_debug "cgroup v2 memory.max 值为 '$mem_max'，忽略"
                fi
            fi
            if (( total_mem_mb == 0 )) && [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
                local mem_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
                if [[ "$mem_limit" =~ ^[0-9]+$ ]] && (( mem_limit > 0 )); then
                    total_mem_mb=$(( mem_limit / 1024 / 1024 ))
                    log_info "从 cgroup v1 memory.limit_in_bytes 获取内存限制: ${total_mem_mb}MB"
                fi
            fi
        fi
        
        if (( total_mem_mb > 0 )); then
            # 使用总内存的 6.25% (1/16)
            # 256MB -> 16MB, 512MB -> 32MB, 1GB -> 64MB, 2GB -> 128MB
            # 上限 128MB，避免过度占用
            # 使用 awk 计算 total_mem_mb / 16，四舍五入
            local result_mb=$(awk "BEGIN {printf \"%.0f\", $total_mem_mb / 16}")
            result="${result_mb}mb"   # 统一使用小写 mb
            local min_limit=8 max_limit=128
            local result_value=${result%mb}
            if (( result_value < min_limit )); then result="${min_limit}mb"
            elif (( result_value > max_limit )); then result="${max_limit}mb"; fi
            log_info "系统内存 ${total_mem_mb}MB，自动计算 memlimit=${result} (总内存的 6.25%)"
        else
            log_warn "无法读取内存信息，使用默认值 16mb"; result="16mb"
        fi
    else
        # 匹配数字+单位（kb, mb, gb），不区分大小写，统一转换为小写
        if [[ "$lower_val" =~ ^[0-9]+(kb|mb|gb)$ ]]; then
            # 将单位转换为小写（例如 16MB -> 16mb, 16Mb -> 16mb）
            result=$(echo "$cleaned" | tr '[:upper:]' '[:lower:]')
            log_info "使用用户配置的 memlimit: ${result}"
        else
            log_warn "无效的 memlimit 格式 '$config_value'，使用默认值 16mb"; result="16mb"
        fi
    fi
    echo "$result"
}

# ========== 获取最高优先级的类名称 ==========
get_highest_priority_class() {
    local direction="$1"
    local class_list=""
    if [[ "$direction" == "upload" ]]; then
        class_list="$upload_class_list"
    else
        class_list="$download_class_list"
    fi
    local highest_prio=999
    local best_class=""
    for class in $class_list; do
        local enabled=$(uci -q get ${CONFIG_FILE}.${class}.enabled 2>/dev/null)
        if [[ "$enabled" == "0" ]]; then
            continue
        fi
        local prio=$(uci -q get ${CONFIG_FILE}.${class}.priority 2>/dev/null)
        if [[ -z "$prio" ]]; then
            prio=999
        fi
        if (( prio < highest_prio )); then
            highest_prio=$prio
            best_class="$class"
        fi
    done
    echo "$best_class"
}

# 获取最低优先级的类（priority 数值最大的启用类）
get_lowest_priority_class() {
    local direction="$1"
    local class_list=""
    if [[ "$direction" == "upload" ]]; then
        class_list="$upload_class_list"
    else
        class_list="$download_class_list"
    fi
    local lowest_prio=-1
    local best_class=""
    for class in $class_list; do
        local enabled=$(uci -q get ${CONFIG_FILE}.${class}.enabled 2>/dev/null)
        if [[ "$enabled" == "0" ]]; then
            continue
        fi
        local prio=$(uci -q get ${CONFIG_FILE}.${class}.priority 2>/dev/null)
        if [[ -z "$prio" ]]; then
            prio=999
        fi
        if (( prio > lowest_prio )); then
            lowest_prio=$prio
            best_class="$class"
        fi
    done
    echo "$best_class"
}

# CAKE 参数支持检查（使用 lo 接口）
check_cake_param_support() {
    local param="$1"
    local old_qdisc ret=1

    # 保存当前 root qdisc（如果有）
    old_qdisc=$(tc qdisc show dev lo 2>/dev/null | grep -E "^qdisc" | head -1 | awk '{print $2}')
    # 删除现有的 root qdisc，确保可以测试新的参数
    tc qdisc del dev lo root 2>/dev/null

    # 尝试添加带参数的 cake qdisc
    if tc qdisc add dev lo root cake bandwidth 1mbit "$param" 2>/dev/null; then
        ret=0
        tc qdisc del dev lo root 2>/dev/null
    fi

    # 恢复原来的 qdisc（如果是有效的调度器）
    if [[ -n "$old_qdisc" && "$old_qdisc" != "noqueue" && "$old_qdisc" != "pfifo_fast" ]]; then
        tc qdisc add dev lo root $old_qdisc 2>/dev/null || true
    fi

    return $ret
}

# ========== 自动调整分类百分比及 min/max（检查优先级完整性，只支持默认4类） ==========
auto_adjust_class_percentages() {
    local auto_adjust=$(uci -q get ${CONFIG_FILE}.global.auto_adjust_percentages 2>/dev/null)
    [ "$auto_adjust" != "1" ] && return 0

    local linklayer=$(uci -q get ${CONFIG_FILE}.global.linklayer 2>/dev/null)
    linklayer=${linklayer:-atm}
    
    local upload_bw=$(uci -q get ${CONFIG_FILE}.upload.total_bandwidth 2>/dev/null)
    local download_bw=$(uci -q get ${CONFIG_FILE}.download.total_bandwidth 2>/dev/null)
    upload_bw=${upload_bw:-0}
    download_bw=${download_bw:-0}

    # 分档表（按优先级 1,2,3,4 顺序）
    local upload_tiers="10000:20,20,40,20;30000:15,25,45,15;50000:12,25,50,13;100000:10,25,55,10;inf:8,22,60,10"
    local download_tiers="20000:15,20,45,20;50000:12,22,50,16;100000:10,22,55,13;200000:8,22,55,15;500000:6,20,55,19;inf:5,20,55,20"

    get_percentages() {
        local direction="$1"
        local bw="$2"
        local tiers_str=""
        [ "$direction" = "upload" ] && tiers_str="$upload_tiers" || tiers_str="$download_tiers"
        local percents=""
        IFS=';' read -ra TIERS <<< "$tiers_str"
        for tier in "${TIERS[@]}"; do
            local threshold="${tier%%:*}"
            local values="${tier#*:}"
            if [ "$threshold" = "inf" ] || [ "$bw" -lt "$threshold" ]; then
                percents="$values"
                break
            fi
        done
        # 健壮性检查：如果解析失败，使用默认值
        if [ -z "$percents" ]; then
            log_warn "自动调整: ${direction} 方向分档表解析失败，使用默认值 20,20,40,20"
            percents="20,20,40,20"
        fi
        echo "$percents"
    }

    # 检查方向是否存在四个标准优先级
    check_priorities() {
        local direction="$1"
        for prio in 1 2 3 4; do
            local section=$(uci -q show ${CONFIG_FILE} 2>/dev/null | grep -E "\.${direction}_class\." | grep -E "\.priority='${prio}'" | head -1 | cut -d. -f2)
            if [ -z "$section" ]; then
                log_warn "自动调整: ${direction} 方向缺少优先级 ${prio} 的类别，跳过调整"
                return 1
            fi
        done
        return 0
    }

    apply_direction() {
        local direction="$1"
        local bw="$2"
        [ -z "$bw" ] || [ "$bw" -eq 0 ] && return 0
        
        check_priorities "$direction" || return 0
        
        local percents_str=$(get_percentages "$direction" "$bw")
        # 四个值分别对应优先级 1,2,3,4
        local p1=$(echo "$percents_str" | cut -d, -f1)
        local p2=$(echo "$percents_str" | cut -d, -f2)
        local p3=$(echo "$percents_str" | cut -d, -f3)
        local p4=$(echo "$percents_str" | cut -d, -f4)
        
        # 数值验证：确保四个值都是 1-100 之间的整数
        for val in p1 p2 p3 p4; do
            local v=${!val}
            if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt 1 ] || [ "$v" -gt 100 ]; then
                log_warn "自动调整: ${direction} 方向百分比值 ${val}=${v} 无效，跳过本次调整"
                return 0
            fi
        done
        
        # ADSL 上行微调（调整 p1,p2,p3,p4）
        if [ "$direction" = "upload" ] && [ "$linklayer" = "adsl" ]; then
            local deduct=8
            if [ "$p3" -ge "$deduct" ]; then
                p1=$((p1 + 5))
                p2=$((p2 + 3))
                p3=$((p3 - deduct))
            else
                p1=$((p1 + 5))
                p2=$((p2 + 3))
                p4=$((p4 - deduct))
            fi
            # 边界保护
            [ "$p1" -gt 100 ] && p1=100
            [ "$p2" -gt 100 ] && p2=100
            [ "$p3" -lt 0 ] && p3=0
            [ "$p4" -lt 0 ] && p4=0
        fi
        
        # 遍历优先级 1-4，设置百分比和 min/max
        for prio in 1 2 3 4; do
            local section=$(uci -q show ${CONFIG_FILE} 2>/dev/null | grep -E "\.${direction}_class\." | grep -E "\.priority='${prio}'" | head -1 | cut -d. -f2)
            [ -z "$section" ] && continue
            case "$prio" in
                1)
                    uci set ${CONFIG_FILE}.${section}.percent_bandwidth="$p1"
                    uci set ${CONFIG_FILE}.${section}.per_min_bandwidth="60"
                    uci set ${CONFIG_FILE}.${section}.per_max_bandwidth="200"
                    ;;
                2)
                    uci set ${CONFIG_FILE}.${section}.percent_bandwidth="$p2"
                    uci set ${CONFIG_FILE}.${section}.per_min_bandwidth="40"
                    uci set ${CONFIG_FILE}.${section}.per_max_bandwidth="200"
                    ;;
                3)
                    uci set ${CONFIG_FILE}.${section}.percent_bandwidth="$p3"
                    uci set ${CONFIG_FILE}.${section}.per_min_bandwidth="0"
                    uci set ${CONFIG_FILE}.${section}.per_max_bandwidth="200"
                    ;;
                4)
                    uci set ${CONFIG_FILE}.${section}.percent_bandwidth="$p4"
                    uci set ${CONFIG_FILE}.${section}.per_min_bandwidth="0"
                    uci set ${CONFIG_FILE}.${section}.per_max_bandwidth="100"
                    ;;
            esac
        done
    }

    if [ -n "$upload_bw" ] && [ "$upload_bw" -gt 0 ]; then
        apply_direction "upload" "$upload_bw"
    fi
    if [ -n "$download_bw" ] && [ "$download_bw" -gt 0 ]; then
        apply_direction "download" "$download_bw"
    fi
    uci commit ${CONFIG_FILE}
    log_info "自动调整分类百分比完成（上传=${upload_bw}kbit，下载=${download_bw}kbit）"
}

# ========== 自动加载全局配置 ==========
if [[ -z "$_QOS_LIB_SH_LOADED" ]] && [[ "$(basename "$0")" != "common.sh" ]]; then
    load_global_config
    _QOS_LIB_SH_LOADED=1
fi