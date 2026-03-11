#!/bin/bash
# 确保脚本由 bash 执行，如果不是则重新用 bash 执行
if [ -z "$BASH" ] || [ "$BASH" = "/bin/sh" ]; then
    exec bash "$0" "$@"
fi

# CAKE算法实现模块 - 精简版
# version=4.3 最终修正版
# 修复：
# - 入口重定向检查的 grep 模式，确保正确匹配
# - safe_tc_command 中超时 kill 后增加 wait，避免僵尸进程
# - release_lock 避免误杀自身进程

# ========== 权限检查 ==========
check_script_permissions() {
    local script_path="$0"
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误: 此脚本需要root权限运行" >&2
        echo "请使用: sudo $0 $@" >&2
        exit 1
    fi
    local script_perms=$(stat -c "%a" "$script_path" 2>/dev/null)
    if [ -n "$script_perms" ] && [ "$script_perms" -gt 700 ]; then
        echo "警告: 脚本权限过于宽松 ($script_perms)，建议设置为700" >&2
        chmod 700 "$script_path" 2>/dev/null && echo "已自动修复脚本权限为700"
    fi
    local script_owner=$(stat -c "%U:%G" "$script_path" 2>/dev/null)
    if [ "$script_owner" != "root:root" ] && [ -n "$script_owner" ]; then
        echo "警告: 脚本所有者非root ($script_owner)，建议设置为root:root" >&2
    fi
}
check_script_permissions "$@"

# ========== 变量初始化 ==========
: ${total_upload_bandwidth:=40000}
: ${total_download_bandwidth:=95000}
: ${CONFIG_FILE:=qos_gargoyle}
: ${IFB_DEVICE:=ifb0}
: ${UPLOAD_MASK:=0x007F}
: ${DOWNLOAD_MASK:=0x7F00}
LOCK_FILE="/var/run/cake_qos_$(basename "$0" 2>/dev/null || echo "cake").lock"
DEBUG="${DEBUG:-0}"
PREV_DROP_RATE=0

get_timestamp_ms() {
    date +%s%3N
}

if [ -z "$qos_interface" ]; then
    qos_interface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
    qos_interface="${qos_interface:-pppoe-wan}"
fi

echo "CAKE 模块初始化完成 (v4.3 最终修正版)"
echo "  网络接口: $qos_interface"
echo "  IFB 设备: $IFB_DEVICE"
echo "  上传带宽: ${total_upload_bandwidth}kbit/s"
echo "  下载带宽: ${total_download_bandwidth}kbit/s"
echo "  锁文件: $LOCK_FILE"
[ "$DEBUG" = "1" ] && echo "  DEBUG模式: 启用"

# ========= CAKE专属常量 ==========
CAKE_DIFFSERV_MODE="diffserv4"
CAKE_OVERHEAD="0"
CAKE_MPU="0"
CAKE_RTT="100ms"
CAKE_ACK_FILTER="0"
CAKE_NAT="0"
CAKE_WASH="0"
CAKE_SPLIT_GSO="0"
CAKE_INGRESS="0"
CAKE_AUTORATE_INGRESS="0"
CAKE_MEMORY_LIMIT="32mb"

# ========== 安全tc命令执行（修复僵尸进程）==========
safe_tc_command() {
    local timeout="${1:-5}"
    shift
    local tc_args=("$@")
    local tmp_output="/tmp/tc_output_$$.tmp"
    trap 'rm -f "$tmp_output" 2>/dev/null' RETURN EXIT INT TERM

    local retry=3
    local success=false
    local output=""

    while [ $retry -gt 0 ]; do
        # 直接执行命令，不使用 eval
        {
            tc "${tc_args[@]}" > "$tmp_output" 2>&1
        } &
        local pid=$!

        # 等待命令完成，超时则 kill
        local count=0
        while kill -0 "$pid" 2>/dev/null && [ $count -lt $timeout ]; do
            sleep 1
            count=$((count + 1))
        done

        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null
            wait $pid 2>/dev/null   # 回收僵尸进程
            log_warn "tc命令执行超时: ${tc_args[*]}"
            retry=$((retry - 1))
            [ $retry -gt 0 ] && sleep 1
        else
            wait $pid
            local exit_code=$?
            if [ $exit_code -eq 0 ]; then
                success=true
                break
            else
                log_warn "tc命令执行失败 (exit $exit_code): ${tc_args[*]}"
                retry=$((retry - 1))
                [ $retry -gt 0 ] && sleep 1
            fi
        fi
    done

    if [ -f "$tmp_output" ]; then
        output=$(cat "$tmp_output")
    fi

    rm -f "$tmp_output" 2>/dev/null
    if [ "$success" = true ]; then
        echo "$output"
        return 0
    else
        log_error "tc命令执行失败，重试次数用尽: ${tc_args[*]}"
        echo "$output" >&2
        return 1
    fi
}

# ========== 依赖检查 ==========
check_dependencies() {
    log_info "检查系统依赖"
    local missing_deps=0
    local required_cmds="tc ip uci"
    if command -v nft >/dev/null 2>&1; then
        required_cmds="$required_cmds nft"
    fi
    for cmd in $required_cmds; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "缺少依赖命令: $cmd"
            missing_deps=$((missing_deps + 1))
        fi
    done

    local required_modules="sch_cake act_mirred ifb"
    for module in $required_modules; do
        if ! modinfo "$module" >/dev/null 2>&1; then
            log_error "内核模块 $module 不存在"
            missing_deps=$((missing_deps + 1))
        elif ! lsmod | grep -q "^$module\s" 2>/dev/null; then
            if ! modprobe -q "$module" 2>/dev/null; then
                log_error "内核模块 $module 加载失败"
                missing_deps=$((missing_deps + 1))
            else
                log_info "内核模块 $module 已加载"
            fi
        fi
    done

    if [ $missing_deps -gt 0 ]; then
        log_error "缺少 $missing_deps 个必要依赖，请安装后重试"
        return 1
    fi
    log_info "✅ 所有依赖检查通过"
    return 0
}

# ========== 并发锁（修复误杀自身）==========
acquire_lock() {
    local lock_file="$LOCK_FILE"
    exec 200>"$lock_file"
    if ! flock -n 200; then
        log_error "锁已被占用，无法获取锁文件: $lock_file"
        exit 1
    fi
    echo "$$" > "$lock_file"
    trap 'release_lock' EXIT INT TERM HUP QUIT
    log_debug "已获取锁文件: $lock_file (PID: $$)"
    return 0
}

release_lock() {
    [ -f "$LOCK_FILE" ] || return 0
    local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    # 如果锁中记录的不是当前进程，且进程存在，则尝试终止（可能是残留）
    if [ -n "$lock_pid" ] && [ "$lock_pid" -ne $$ ] && kill -0 "$lock_pid" 2>/dev/null; then
        log_warn "发现残留进程 PID=$lock_pid，正在终止..."
        kill "$lock_pid" 2>/dev/null
        sleep 1
        if kill -0 "$lock_pid" 2>/dev/null; then
            kill -9 "$lock_pid" 2>/dev/null
        fi
    fi
    rm -f "$LOCK_FILE" 2>/dev/null
    log_debug "锁已释放"
    return 0
}

# ========== 信号处理 ==========
setup_signal_handlers() {
    trap 'handle_exit_signal' INT TERM
    trap 'handle_hup_signal' HUP
    trap 'handle_quit_signal' QUIT
    log_debug "信号处理器已设置"
}

handle_exit_signal() {
    log_info "收到终止信号，清理资源..."
    stop_cake_qos
    release_lock
    exit 0
}

handle_hup_signal() {
    log_info "收到HUP信号，忽略（如需重载请使用 restart）"
    return 0
}

handle_quit_signal() {
    log_info "收到QUIT信号，执行快速清理..."
    quick_cleanup
    exit 0
}

quick_cleanup() {
    log_info "执行快速清理..."
    tc qdisc del dev "$qos_interface" root 2>/dev/null || true
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null || true
    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null || true
    fi
    log_info "快速清理完成"
}

# ========== 日志函数 ==========
log_info() {
    local timestamp=$(date '+%H:%M:%S')
    local debug_timestamp=""
    [ "$DEBUG" = "1" ] && debug_timestamp="[$(get_timestamp_ms)] "
    local sanitized_message="$1"
    sanitized_message=$(echo "$sanitized_message" | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[IP_REDACTED]/g')
    sanitized_message=$(echo "$sanitized_message" | sed -E 's/([0-9a-fA-F:]+:[0-9a-fA-F:]+)/[IPv6_REDACTED]/g')
    sanitized_message=$(echo "$sanitized_message" | sed 's/\(password\|secret\|key\|token\)=[^ ]*/\1=****/g')
    logger -t "qos_gargoyle" "CAKE: $sanitized_message"
    echo "${debug_timestamp}[$timestamp] CAKE: $sanitized_message"
}

log_error() {
    local timestamp=$(date '+%H:%M:%S')
    local debug_timestamp=""
    [ "$DEBUG" = "1" ] && debug_timestamp="[$(get_timestamp_ms)] "
    logger -t "qos_gargoyle" "CAKE错误: $1"
    echo "${debug_timestamp}[$timestamp] ❌ CAKE错误: $1" >&2
}

log_warn() {
    local timestamp=$(date '+%H:%M:%S')
    local debug_timestamp=""
    [ "$DEBUG" = "1" ] && debug_timestamp="[$(get_timestamp_ms)] "
    logger -t "qos_gargoyle" "CAKE警告: $1"
    echo "${debug_timestamp}[$timestamp] ⚠️ CAKE警告: $1"
}

log_debug() {
    [ "${DEBUG:-0}" = "1" ] && {
        local timestamp=$(date '+%H:%M:%S')
        local debug_timestamp="[$(get_timestamp_ms)] "
        local sanitized_message="$1"
        sanitized_message=$(echo "$sanitized_message" | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[IP_REDACTED]/g')
        sanitized_message=$(echo "$sanitized_message" | sed -E 's/([0-9a-fA-F:]+:[0-9a-fA-F:]+)/[IPv6_REDACTED]/g')
        sanitized_message=$(echo "$sanitized_message" | sed 's/\(password\|secret\|key\|token\)=[^ ]*/\1=****/g')
        logger -t "qos_gargoyle" "CAKE调试: $sanitized_message"
        echo "${debug_timestamp}[$timestamp] 🔍 CAKE调试: $sanitized_message"
    }
}

# ========== 参数消毒 ==========
sanitize_param() {
    local param="$1"
    echo "$param" | sed 's/[^a-zA-Z0-9_./:-]//g'
}

# ========== 带宽单位转换 ==========
convert_bandwidth_to_kbit() {
    local bw_value="$1"
    if echo "$bw_value" | grep -qE '^[0-9]+$'; then
        echo "$bw_value"
        return 0
    fi
    if ! [[ "$bw_value" =~ ^([0-9]+)([kKmMgG]?)$ ]]; then
        log_error "无效带宽格式: $bw_value"
        return 1
    fi
    local num=$(echo "$bw_value" | sed 's/[^0-9]//g')
    local unit=$(echo "$bw_value" | sed 's/[0-9]//g' | tr '[:lower:]' '[:upper:]')
    [ -z "$num" ] && { echo "$bw_value"; return 1; }
    case "$unit" in
        "K") result=$num ;;
        "M") result=$((num * 1000)) ;;
        "G") result=$((num * 1000000)) ;;
        "") result=$num ;;
        *) log_warn "未知带宽单位: $unit，使用kbit"; result=$num ;;
    esac
    echo "$result"
    return 0
}

# ========== 参数验证 ==========
validate_cake_parameters() {
    local param_value="$1"
    local param_name="$2"
    param_value=$(sanitize_param "$param_value")
    case "$param_name" in
        bandwidth)
            local clean_value=$(echo "$param_value" | sed 's/^ *//;s/ *$//')
            if ! echo "$clean_value" | grep -qiE '^[0-9]+([kKmMgG]?)$'; then
                log_error "无效的带宽值: $param_value"
                return 1
            fi
            local bw_kbit=$(convert_bandwidth_to_kbit "$clean_value")
            if [ "$bw_kbit" -lt 8 ]; then
                log_warn "带宽过小: ${param_value} (${bw_kbit}kbit) (建议至少8kbit)"
            fi
            if [ "$bw_kbit" -gt 1000000 ]; then
                log_warn "带宽过大: ${param_value} (${bw_kbit}kbit) (超过1Gbit)"
            fi
            ;;
        rtt)
            if [ -n "$param_value" ]; then
                local rtt_clean=$(echo "$param_value" | sed 's/^ *//;s/ *$//')
                if ! echo "$rtt_clean" | grep -qE '^[0-9]*\.?[0-9]+(us|ms|s)$'; then
                    log_warn "无效的RTT格式: $param_value (应为数字+单位: us/ms/s)"
                    return 1
                fi
            fi
            ;;
        memory_limit)
            if [ -n "$param_value" ]; then
                param_value=$(echo "$param_value" | tr 'A-Z' 'a-z')
                if ! echo "$param_value" | grep -qiE '^[0-9]+(b|kb|mb|gb)$'; then
                    log_warn "无效的内存限制格式: $param_value"
                    return 1
                fi
            fi
            ;;
    esac
    return 0
}

validate_diffserv_mode() {
    local mode="$1"
    local valid_modes="besteffort diffserv3 diffserv4 diffserv5 diffserv8"
    for valid_mode in $valid_modes; do
        [ "$mode" = "$valid_mode" ] && return 0
    done
    log_warn "无效的DiffServ模式: $mode，使用默认值diffserv4"
    return 1
}

# ========== 配置加载 ==========
load_cake_config() {
    log_info "加载CAKE配置"
    CAKE_DIFFSERV_MODE=$(uci -q get qos_gargoyle.cake.diffserv_mode 2>/dev/null) || CAKE_DIFFSERV_MODE="diffserv4"
    CAKE_OVERHEAD=$(uci -q get qos_gargoyle.cake.overhead 2>/dev/null) || CAKE_OVERHEAD="0"
    CAKE_MPU=$(uci -q get qos_gargoyle.cake.mpu 2>/dev/null) || CAKE_MPU="0"
    CAKE_RTT=$(uci -q get qos_gargoyle.cake.rtt 2>/dev/null) || CAKE_RTT="100ms"
    CAKE_ACK_FILTER=$(uci -q get qos_gargoyle.cake.ack_filter 2>/dev/null) || CAKE_ACK_FILTER="0"
    CAKE_NAT=$(uci -q get qos_gargoyle.cake.nat 2>/dev/null) || CAKE_NAT="0"
    CAKE_WASH=$(uci -q get qos_gargoyle.cake.wash 2>/dev/null) || CAKE_WASH="0"
    CAKE_SPLIT_GSO=$(uci -q get qos_gargoyle.cake.split_gso 2>/dev/null) || CAKE_SPLIT_GSO="0"
    CAKE_INGRESS=$(uci -q get qos_gargoyle.cake.ingress 2>/dev/null) || CAKE_INGRESS="0"
    CAKE_AUTORATE_INGRESS=$(uci -q get qos_gargoyle.cake.autorate_ingress 2>/dev/null) || CAKE_AUTORATE_INGRESS="0"
    CAKE_MEMORY_LIMIT=$(uci -q get qos_gargoyle.cake.memlimit 2>/dev/null) || CAKE_MEMORY_LIMIT="32mb"
    CAKE_MEMORY_LIMIT=$(echo "$CAKE_MEMORY_LIMIT" | tr 'A-Z' 'a-z')
    log_info "CAKE配置加载完成"
    return 0
}

# ========== 配置语法验证 ==========
validate_config_syntax() {
    log_info "验证配置文件语法..."
    if ! uci show qos_gargoyle >/dev/null 2>&1; then
        log_error "配置文件语法错误: uci show qos_gargoyle 失败"
        return 1
    fi
    local required_sections="global"
    for section in $required_sections; do
        if ! uci -q get qos_gargoyle.$section >/dev/null 2>&1; then
            log_error "缺少必要的配置节: $section"
            return 1
        fi
    done
    local upload_bandwidth=$(uci -q get qos_gargoyle.global.upload_bandwidth 2>/dev/null)
    local download_bandwidth=$(uci -q get qos_gargoyle.global.download_bandwidth 2>/dev/null)
    if [ -n "$upload_bandwidth" ] && [ "$upload_bandwidth" -gt 1000000 ]; then
        log_error "上传带宽超过物理限制: ${upload_bandwidth}kbit"
        return 1
    fi
    if [ -n "$download_bandwidth" ] && [ "$download_bandwidth" -gt 1000000 ]; then
        log_error "下载带宽超过物理限制: ${download_bandwidth}kbit"
        return 1
    fi
    log_info "✅ 配置文件语法检查通过"
    return 0
}

# ========== 验证CAKE配置 ==========
validate_cake_config() {
    log_info "验证CAKE配置..."
    if ! check_dependencies; then
        return 1
    fi
    if [ -z "$qos_interface" ]; then
        log_error "缺少必要变量: qos_interface"
        return 1
    fi
    if ! ip link show dev "$qos_interface" >/dev/null 2>&1; then
        log_error "接口 $qos_interface 不存在"
        return 1
    fi
    if [ -n "$total_upload_bandwidth" ] && [ "$total_upload_bandwidth" -gt 0 ]; then
        validate_cake_parameters "$total_upload_bandwidth" "bandwidth" || return 1
    fi
    if [ -n "$total_download_bandwidth" ] && [ "$total_download_bandwidth" -gt 0 ]; then
        validate_cake_parameters "$total_download_bandwidth" "bandwidth" || return 1
    fi
    validate_diffserv_mode "$CAKE_DIFFSERV_MODE" || CAKE_DIFFSERV_MODE="diffserv4"
    validate_cake_parameters "$CAKE_RTT" "rtt"
    validate_cake_parameters "$CAKE_MEMORY_LIMIT" "memory_limit"
    log_info "✅ CAKE配置验证通过"
    return 0
}

# ========== 入口重定向 ==========
setup_ingress_redirect() {
    log_info "设置入口重定向: $qos_interface -> $IFB_DEVICE"
    cleanup_tc_rules_completely "$qos_interface"
    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        log_error "无法在$qos_interface上创建入口队列"
        return 1
    fi
    local ipv4_success=false
    local ipv6_success=false

    # IPv4重定向
    if tc filter add dev "$qos_interface" parent ffff: protocol ip \
        u32 match u32 0 0 \
        action mirred egress redirect dev "$IFB_DEVICE" 2>/dev/null; then
        ipv4_success=true
    else
        log_error "IPv4入口重定向规则添加失败"
    fi

    # IPv6重定向（限制全球单播地址）
    if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
        u32 match u32 0 0 dst 2000::/3 src 0::/0 flowlabel 0:0 \
        action mirred egress redirect dev "$IFB_DEVICE" 2>/dev/null; then
        ipv6_success=true
    else
        log_warn "IPv6入口重定向规则添加失败，尝试无过滤规则"
        if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
            u32 match u32 0 0 \
            action mirred egress redirect dev "$IFB_DEVICE" 2>/dev/null; then
            ipv6_success=true
        else
            log_error "IPv6入口重定向规则添加失败"
        fi
    fi

    if [ "$ipv4_success" = false ] || [ "$ipv6_success" = false ]; then
        log_warn "部分入口重定向规则添加失败，清理已创建的队列"
        cleanup_tc_rules_completely "$qos_interface"
        return 1
    fi
    log_info "入口重定向设置完成"
    return 0
}

cleanup_tc_rules_completely() {
    local device="$1"
    log_info "彻底清理 $device 上的TC规则"
    tc qdisc del dev "$device" root 2>/dev/null || true
    tc class del dev "$device" root 2>/dev/null || true
    tc filter del dev "$device" parent ffff: 2>/dev/null || true
    for parent in ffff: 1:0; do
        tc filter del dev "$device" parent "$parent" 2>/dev/null || true
    done
    local classes=$(tc class show dev "$device" 2>/dev/null | awk '{print $2}')
    for cls in $classes; do
        if [ "$cls" != "root" ] && [ "$cls" != "ffff:" ]; then
            tc class del dev "$device" classid "$cls" 2>/dev/null || true
        fi
    done
    log_info "$device TC规则清理完成"
}

# ========== 检查入口重定向（修正grep模式）==========
# ========== 检查入口重定向（修正大小写和协议区分）==========
check_ingress_redirect() {
    log_info "检查入口重定向状态"
    local has_ipv4=false
    local has_ipv6=false

    # 分别检查 IPv4 和 IPv6 协议的重定向规则
    if tc filter show dev "$qos_interface" parent ffff: protocol ip 2>/dev/null | grep -qi "redirect.*$IFB_DEVICE"; then
        has_ipv4=true
        echo "✅ IPv4入口重定向: 已生效"
    else
        echo "❌ IPv4入口重定向: 未生效"
    fi

    if tc filter show dev "$qos_interface" parent ffff: protocol ipv6 2>/dev/null | grep -qi "redirect.*$IFB_DEVICE"; then
        has_ipv6=true
        echo "✅ IPv6入口重定向: 已生效"
    else
        echo "❌ IPv6入口重定向: 未生效"
    fi

    [ "$has_ipv4" = true ] && [ "$has_ipv6" = true ] && return 0
    return 1
}

# ========== CAKE队列创建 ==========
create_cake_root_qdisc() {
    local device="$1"
    local direction="$2"
    local bandwidth="$3"

    log_info "为$device创建$direction方向CAKE根队列 (带宽: ${bandwidth}kbit)"
    if ! validate_cake_parameters "$bandwidth" "bandwidth"; then
        return 1
    fi

    cleanup_existing_queues "$device" "$direction"

    local cake_params=("bandwidth" "${bandwidth}kbit" "$CAKE_DIFFSERV_MODE")
    [ "$CAKE_OVERHEAD" != "0" ] && cake_params+=("overhead" "$CAKE_OVERHEAD")
    [ "$CAKE_MPU" != "0" ] && cake_params+=("mpu" "$CAKE_MPU")
    [ -n "$CAKE_RTT" ] && cake_params+=("rtt" "$CAKE_RTT")
    [ "$CAKE_ACK_FILTER" = "1" ] && cake_params+=("ack-filter")
    [ "$CAKE_NAT" = "1" ] && cake_params+=("nat")
    [ "$CAKE_WASH" = "1" ] && cake_params+=("wash")
    [ "$CAKE_SPLIT_GSO" = "1" ] && cake_params+=("split-gso")
    [ -n "$CAKE_MEMORY_LIMIT" ] && cake_params+=("memlimit" "$CAKE_MEMORY_LIMIT")

    if [ "$direction" = "upload" ]; then
        echo "正在为 $device 创建上传CAKE队列..."
        echo "  参数: ${cake_params[*]}"
        local tc_cmd=("qdisc" "add" "dev" "$device" "root" "cake")
        tc_cmd+=("${cake_params[@]}")
        if ! safe_tc_command 10 "${tc_cmd[@]}"; then
            log_error "无法在$device上创建上传CAKE队列"
            return 1
        fi
    elif [ "$direction" = "download" ]; then
        if [ "$CAKE_INGRESS" = "1" ]; then
            echo "正在为 $device 创建下载CAKE入口队列..."
            cake_params+=("ingress")
            [ "$CAKE_AUTORATE_INGRESS" = "1" ] && cake_params+=("autorate-ingress")
            echo "  参数: ${cake_params[*]}"
            local tc_cmd=("qdisc" "add" "dev" "$device" "ingress" "cake")
            tc_cmd+=("${cake_params[@]}")
            if ! safe_tc_command 10 "${tc_cmd[@]}"; then
                log_error "无法在$device上创建下载CAKE入口队列"
                return 1
            fi
        else
            echo "正在为 $device 创建下载CAKE根队列..."
            echo "  参数: ${cake_params[*]}"
            local tc_cmd=("qdisc" "add" "dev" "$device" "root" "cake")
            tc_cmd+=("${cake_params[@]}")
            if ! safe_tc_command 10 "${tc_cmd[@]}"; then
                log_error "无法在$device上创建下载CAKE队列"
                return 1
            fi
        fi
    fi
    log_info "$device的$direction方向CAKE队列创建完成"
    echo "✅ $device 的 $direction 方向 CAKE 队列创建完成"
    return 0
}

cleanup_existing_queues() {
    local device="$1"
    local direction="$2"
    log_info "清理$device上的现有$direction队列"
    if [ "$direction" = "upload" ]; then
        cleanup_tc_rules_completely "$device"
        echo "  清理上传队列完成"
    elif [ "$direction" = "download" ]; then
        cleanup_tc_rules_completely "$device"
        echo "  清理下载队列完成"
    fi
}

# ========== 上传初始化 ==========
initialize_cake_upload() {
    log_info "初始化上传方向CAKE"
    if [ -z "$total_upload_bandwidth" ] || [ "$total_upload_bandwidth" -le 0 ]; then
        log_info "上传带宽未配置，跳过上传方向初始化"
        return 0
    fi
    echo "为 $qos_interface 创建上传CAKE队列 (带宽: ${total_upload_bandwidth}kbit/s)"
    if create_cake_root_qdisc "$qos_interface" "upload" "$total_upload_bandwidth"; then
        log_info "上传方向CAKE初始化完成"
        return 0
    else
        log_error "上传方向CAKE初始化失败"
        return 1
    fi
}

# ========== 下载初始化 ==========
initialize_cake_download() {
    log_info "初始化下载方向CAKE"
    if [ -z "$total_download_bandwidth" ] || [ "$total_download_bandwidth" -le 0 ]; then
        log_info "下载带宽未配置，跳过下载方向初始化"
        return 0
    fi

    if [ "$CAKE_INGRESS" = "1" ]; then
        echo "为 $qos_interface 创建下载CAKE入口队列 (带宽: ${total_download_bandwidth}kbit/s)"
        if create_cake_root_qdisc "$qos_interface" "download" "$total_download_bandwidth"; then
            log_info "下载方向CAKE入口队列初始化完成"
            return 0
        else
            log_error "下载方向CAKE入口队列初始化失败"
            return 1
        fi
    else
        echo "为 $IFB_DEVICE 创建下载CAKE队列 (带宽: ${total_download_bandwidth}kbit/s)"
        if ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
            log_info "IFB设备 $IFB_DEVICE 不存在，尝试创建"
            if ! ip link add "$IFB_DEVICE" type ifb; then
                log_error "无法创建IFB设备 $IFB_DEVICE"
                return 1
            fi
        fi
        if ! ip link set dev "$IFB_DEVICE" up; then
            log_error "无法启动IFB设备 $IFB_DEVICE"
            return 1
        fi
        if ! setup_ingress_redirect; then
            log_error "无法设置入口重定向"
            return 1
        fi
        if create_cake_root_qdisc "$IFB_DEVICE" "download" "$total_download_bandwidth"; then
            log_info "下载方向CAKE队列初始化完成 (通过IFB)"
            return 0
        else
            log_error "下载方向CAKE队列初始化失败"
            return 1
        fi
    fi
}

# ========== 状态显示辅助函数 ==========
calculate_drop_rate() {
    local device="$1"
    local sent_pkts="$2"
    local dropped="$3"
    if [ -z "$sent_pkts" ] || [ "$sent_pkts" -eq 0 ]; then
        echo "0.00"
        return
    fi
    if [ -z "$dropped" ] || [ "$dropped" -eq 0 ]; then
        echo "0.00"
        return
    fi
    local queue_info=$(tc qdisc show dev "$device" 2>/dev/null)
    local created_time=$(echo "$queue_info" | grep -oP 'created \K[^ ]+')
    if [ -n "$created_time" ] && command -v date >/dev/null 2>&1; then
        local created_ts=$(date -d "$created_time" +%s 2>/dev/null)
        local now_ts=$(date +%s)
        if [ -n "$created_ts" ] && [ "$created_ts" -gt 0 ] && [ "$now_ts" -gt "$created_ts" ]; then
            local elapsed=$((now_ts - created_ts))
            if [ "$elapsed" -gt 0 ]; then
                local rate=$(echo "scale=4; $dropped * 100 / $sent_pkts" | bc 2>/dev/null || echo "0")
                local window=300
                if [ "$elapsed" -gt "$window" ]; then
                    local avg_rate=$(echo "scale=4; ($PREV_DROP_RATE * 4 + $rate) / 5" | bc 2>/dev/null || echo "$rate")
                    PREV_DROP_RATE=$avg_rate
                    printf "%.2f\n" "$avg_rate"
                else
                    printf "%.2f\n" "$rate"
                fi
                return
            fi
        fi
    fi
    local drop_rate=$(echo "scale=2; $dropped * 100 / $sent_pkts" | bc 2>/dev/null)
    echo "${drop_rate:-0.00}"
}

get_cake_memory_usage() {
    local device="$1"
    local cake_info=$(tc qdisc show dev "$device" 2>/dev/null | grep "qdisc cake")
    if echo "$cake_info" | grep -q "memlimit"; then
        echo "$cake_info" | sed -n 's/.*memlimit \([^ ]*\).*/\1/p'
    else
        echo "N/A"
    fi
}

show_queue_status() {
    local device="$1"
    local direction="$2"
    echo "===== $direction方向CAKE队列 ($device) ====="
    if tc qdisc show dev "$device" 2>/dev/null | grep -q "qdisc cake"; then
        echo "状态: 已启用 ✅"
        echo "队列参数:"
        tc qdisc show dev "$device" 2>/dev/null | grep "qdisc cake" | sed 's/^qdisc cake //' | sed 's/^/  /'
        local cake_mem=$(get_cake_memory_usage "$device")
        echo "  CAKE内存占用: $cake_mem"
        echo -e "\nTC队列统计:"
        local queue_stats=$(tc -s qdisc show dev "$device" 2>/dev/null)
        if [ -n "$queue_stats" ]; then
            echo "$queue_stats" | sed 's/^/  /'
        else
            echo "  无TC队列统计"
        fi
        local sent_bytes=$(echo "$queue_stats" | awk '/Sent [0-9]+ bytes/ {print $2; exit}')
        local sent_pkts=$(echo "$queue_stats" | awk '/Sent [0-9]+ bytes [0-9]+ pkt/ {print $4; exit}')
        local dropped=$(echo "$queue_stats" | awk '/dropped [0-9]+/ {print $2; exit}')
        local overlimits=$(echo "$queue_stats" | awk '/overlimits [0-9]+/ {print $2; exit}')
        if [ -n "$sent_bytes" ] && [ -n "$sent_pkts" ]; then
            local mb_size=$((sent_bytes / 1024 / 1024))
            echo -e "\n性能指标:"
            echo "  总流量: ${mb_size} MB (${sent_pkts} 个包)"
            if [ -n "$dropped" ] && [ "$dropped" -gt 0 ] && [ "$sent_pkts" -gt 0 ]; then
                echo "  丢包数: $dropped"
                local drop_rate=$(calculate_drop_rate "$device" "$sent_pkts" "$dropped")
                echo "  丢包率: ${drop_rate}%"
            fi
            if [ -n "$overlimits" ] && [ "$overlimits" -gt 0 ]; then
                echo "  超限次数: $overlimits"
            fi
        fi
    else
        echo "状态: 未启用 ❌"
    fi
}

show_cake_status() {
    echo "===== CAKE QoS状态报告 (v4.3 最终修正版) ====="
    echo "时间: $(date)"
    echo "系统运行时间: $(uptime | sed 's/.*up //; s/,.*//')"
    echo "网络接口: ${qos_interface:-未知}"
    if ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
        if tc qdisc show dev "$IFB_DEVICE" >/dev/null 2>&1; then
            echo "IFB设备: 已启动且运行中 ($IFB_DEVICE)"
        else
            echo "IFB设备: 已创建但无 TC 队列 ($IFB_DEVICE)"
        fi
    else
        echo "IFB设备: 未创建"
    fi

    load_cake_config

    if ! tc qdisc show dev "${qos_interface}" 2>/dev/null | grep -q "qdisc cake"; then
        echo "警告: QoS未在接口 ${qos_interface} 上激活"
        return 1
    fi

    show_queue_status "$qos_interface" "出口"

    if [ "$CAKE_INGRESS" = "1" ]; then
        show_queue_status "$qos_interface" "入口"
    else
        if ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
            show_queue_status "$IFB_DEVICE" "入口"
        else
            echo -e "\n===== 入口CAKE队列 ($IFB_DEVICE) ====="
            echo "状态: IFB设备不存在"
        fi
    fi

    echo -e "\n===== 入口重定向检查 ====="
    if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "ingress"; then
        echo "入口队列状态: 已配置"
        local ingress_filters=$(tc filter show dev "$qos_interface" parent ffff: 2>/dev/null)
        if [ -n "$ingress_filters" ]; then
            local ipv4_rules=$(echo "$ingress_filters" | grep -c "protocol ip")
            local ipv6_rules=$(echo "$ingress_filters" | grep -c "protocol ipv6")
            echo "  IPv4规则数: $ipv4_rules"
            echo "  IPv6规则数: $ipv6_rules"
            if echo "$ingress_filters" | grep -q "redirect.*dev $IFB_DEVICE"; then
                echo "  ✅ 入口重定向规则存在 (目标: $IFB_DEVICE)"
            else
                echo "$ingress_filters" | head -20 | sed 's/^/  /'
            fi
        else
            echo "  无过滤器规则"
        fi
    else
        echo "入口队列状态: 未配置"
    fi

    echo -e "\n===== 系统资源 ====="
    if [ -f /proc/meminfo ]; then
        mem_total=$(grep "MemTotal:" /proc/meminfo | awk '{print $2}')
        mem_available=$(grep "MemAvailable:" /proc/meminfo | awk '{print $2}')
        if [ -n "$mem_total" ] && [ -n "$mem_available" ]; then
            mem_used=$((mem_total - mem_available))
            mem_total_mb=$((mem_total / 1024))
            mem_used_mb=$((mem_used / 1024))
            echo "内存: ${mem_used_mb}MB 已用/${mem_total_mb}MB 总计"
        else
            echo "内存: 无法获取详细信息"
        fi
    else
        echo "内存: 无法获取"
    fi
    echo -n "CPU负载: "
    uptime | awk -F'load average:' '{print $2}' | sed 's/^[[:space:]]*//' || echo "未知"

    echo -e "\n===== 网络接口统计 ====="
    echo "WAN接口 ($qos_interface) 统计:"
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$qos_interface" 2>/dev/null | grep -E "(RX|TX) packets|bytes" | sed 's/^/  /' || echo "  无法获取接口统计"
    else
        ip -s link show dev "$qos_interface" 2>/dev/null | tail -6 | sed 's/^/  /' || echo "  无法获取接口统计"
    fi
    if ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
        echo -e "\nIFB接口 ($IFB_DEVICE) 统计:"
        if command -v ifconfig >/dev/null 2>&1; then
            ifconfig "$IFB_DEVICE" 2>/dev/null | grep -E "(RX|TX) packets|bytes" | sed 's/^/  /' || echo "  无法获取接口统计"
        else
            ip -s link show dev "$IFB_DEVICE" 2>/dev/null | tail -6 | sed 's/^/  /' || echo "  无法获取接口统计"
        fi
    fi

    echo -e "\n===== CAKE配置参数 ====="
    echo "DiffServ模式: $CAKE_DIFFSERV_MODE"
    echo "RTT: $CAKE_RTT"
    echo "Overhead: $CAKE_OVERHEAD"
    echo "MPU: $CAKE_MPU"
    echo "Memory Limit: $CAKE_MEMORY_LIMIT"
    echo "ACK过滤: $([ "$CAKE_ACK_FILTER" = "1" ] && echo "启用 ✅" || echo "禁用 ❌")"
    echo "NAT支持: $([ "$CAKE_NAT" = "1" ] && echo "启用 ✅" || echo "禁用 ❌")"
    echo "Wash: $([ "$CAKE_WASH" = "1" ] && echo "启用 ✅" || echo "禁用 ❌")"
    echo "Split GSO: $([ "$CAKE_SPLIT_GSO" = "1" ] && echo "启用 ✅" || echo "禁用 ❌")"
    echo "Ingress模式: $([ "$CAKE_INGRESS" = "1" ] && echo "启用 ✅" || echo "禁用 ❌")"
    echo "AutoRate Ingress: $([ "$CAKE_AUTORATE_INGRESS" = "1" ] && echo "启用 ✅" || echo "禁用 ❌")"

    if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "qdisc cake"; then
        echo -e "\n===== CAKE状态摘要 ====="
        echo "CAKE状态: 运行中 ✅"
    else
        echo -e "\n===== CAKE状态摘要 ====="
        echo "CAKE状态: 已停止 ❌"
    fi
    echo -e "\n===== 状态报告结束 ====="
    return 0
}

# ========== 主初始化 ==========
initialize_cake_qos() {
    log_info "开始初始化CAKE QoS系统 (v4.3)"
    setup_signal_handlers
    if ! acquire_lock; then
        log_error "无法获取并发锁，可能已有其他CAKE进程在运行"
        return 1
    fi

    validate_config_syntax || {
        log_error "配置文件语法检查失败"
        release_lock
        return 1
    }

    load_cake_config

    if ! validate_cake_config; then
        log_error "CAKE配置验证失败"
        release_lock
        return 1
    fi

    if [ -n "$total_upload_bandwidth" ] && [ "$total_upload_bandwidth" -gt 0 ]; then
        if ! initialize_cake_upload; then
            log_error "上传方向初始化失败"
            release_lock
            return 1
        fi
    else
        log_info "上传带宽未配置，跳过上传方向初始化"
    fi

    if [ -n "$total_download_bandwidth" ] && [ "$total_download_bandwidth" -gt 0 ]; then
        if ! initialize_cake_download; then
            log_error "下载方向初始化失败"
            release_lock
            return 1
        fi
    else
        log_info "下载带宽未配置，跳过下载方向初始化"
    fi

    if [ "$CAKE_INGRESS" = "0" ] && [ -n "$total_download_bandwidth" ] && [ "$total_download_bandwidth" -gt 0 ]; then
        check_ingress_redirect
    fi

    release_lock
    log_info "CAKE QoS初始化完成"
    return 0
}

# ========== 停止清理 ==========
stop_cake_qos() {
    log_info "停止CAKE QoS"
    cleanup_tc_rules_completely "$qos_interface"
    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        cleanup_tc_rules_completely "$IFB_DEVICE"
    fi
    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link set dev "$IFB_DEVICE" down
        log_info "停用IFB设备: $IFB_DEVICE"
    fi
    uci commit qos_gargoyle
    log_info "配置已保存"
    log_info "CAKE QoS停止完成"
}

# ========== 主函数 ==========
main_cake_qos() {
    local action="$1"
    case "$action" in
        start)
            log_info "启动CAKE QoS"
            initialize_cake_qos
            ;;
        stop)
            log_info "停止CAKE QoS"
            stop_cake_qos
            ;;
        restart)
            log_info "重启CAKE QoS"
            stop_cake_qos
            sleep 2
            initialize_cake_qos
            ;;
        status|show)
            show_cake_status
            ;;
        validate)
            load_cake_config
            validate_cake_config
            ;;
        config-check)
            validate_config_syntax
            ;;
        help)
            echo "用法: $0 {start|stop|restart|status|validate|config-check|help}"
            echo "  start        启动CAKE QoS"
            echo "  stop         停止CAKE QoS"
            echo "  restart      重启CAKE QoS"
            echo "  status       显示CAKE状态"
            echo "  validate     验证CAKE配置"
            echo "  config-check 检查配置文件语法"
            echo "  help         显示此帮助信息"
            ;;
        *)
            echo "用法: $0 {start|stop|restart|status|validate|config-check|help}"
            exit 1
            ;;
    esac
}

if [ "$(basename "$0")" = "cake.sh" ]; then
    if [ $# -eq 0 ]; then
        echo "错误: 缺少参数"
        echo ""
        main_cake_qos "help"
        exit 1
    fi
    main_cake_qos "$@"
fi

log_info "CAKE模块加载完成"