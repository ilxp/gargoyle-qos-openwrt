#!/bin/sh
# CAKE算法实现模块 - 最终优化版 v4.12
# 基于v4.11，优化：状态显示使用运行时参数、带宽单位转换增强警告
# 修正：带宽转换函数中警告使用未初始化变量的问题

# ========== 变量初始化 ==========
: ${total_upload_bandwidth:=40000}
: ${total_download_bandwidth:=95000}
: ${IFB_DEVICE:=ifb0}
LOCK_DIR="/var/run/cake_qos.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"
RUNTIME_PARAMS_FILE="/tmp/cake_runtime_params"

# 如果 qos_interface 未设置，尝试获取
if [ -z "$qos_interface" ]; then
    qos_interface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
    qos_interface="${qos_interface:-pppoe-wan}"
fi

echo "CAKE 模块初始化完成 (v4.12)"
echo "  网络接口: $qos_interface"
echo "  IFB 设备: $IFB_DEVICE"
echo "  上传带宽: ${total_upload_bandwidth}kbit/s"
echo "  下载带宽: ${total_download_bandwidth}kbit/s"

# ========= CAKE专属常量 ==========
CAKE_DIFFSERV_MODE="diffserv4"
CAKE_OVERHEAD="0"
CAKE_MPU="0"
CAKE_RTT="100ms"
CAKE_ACK_FILTER="0"
CAKE_NAT="0"
CAKE_WASH="0"
CAKE_SPLIT_GSO="0"
CAKE_INGRESS="0"          # 用户配置，决定是否附加 ingress 参数
CAKE_AUTORATE_INGRESS="0"
CAKE_MEMORY_LIMIT="32mb"
ENABLE_AUTO_TUNE="1"

# ========== 参数消毒 ==========
sanitize_param() {
    echo "$1" | sed 's/[^a-zA-Z0-9_./:-]//g'
}

# ========== 日志函数 ==========
log_info() {
    logger -t "qos_gargoyle" "CAKE: $1"
    echo "[$(date '+%H:%M:%S')] CAKE: $1"
}

log_error() {
    logger -t "qos_gargoyle" "CAKE错误: $1"
    echo "[$(date '+%H:%M:%S')] ❌ CAKE错误: $1" >&2
}

log_warn() {
    logger -t "qos_gargoyle" "CAKE警告: $1"
    echo "[$(date '+%H:%M:%S')] ⚠️ CAKE警告: $1"
}

log_debug() {
    [ "${DEBUG:-0}" = "1" ] && {
        logger -t "qos_gargoyle" "CAKE调试: $1"
        echo "[$(date '+%H:%M:%S')] 🔍 CAKE调试: $1"
    }
}

# ========== 依赖检查 ==========
check_dependencies() {
    if ! command -v tc >/dev/null 2>&1; then
        log_error "tc 命令未找到，请安装 iproute2"
        return 1
    fi
    if ! command -v ip >/dev/null 2>&1; then
        log_error "ip 命令未找到，请安装 iproute2"
        return 1
    fi
    if ! command -v uci >/dev/null 2>&1; then
        log_error "uci 命令未找到，请安装 uci"
        return 1
    fi
    return 0
}

# ========== 带宽单位转换（增强警告，修正版）==========
convert_bandwidth_to_kbit() {
    local bw="$1"
    local num unit result
    if echo "$bw" | grep -qiE '^[0-9]+[kKmMgG]?'; then
        num=$(echo "$bw" | sed 's/[^0-9]//g')
        unit=$(echo "$bw" | sed 's/[0-9]//g' | tr '[:lower:]' '[:upper:]' | sed 's/^\([KMG]\).*$/\1/')
        case "$unit" in
            "K") result=$num ;;
            "M") result=$((num * 1000)) ;;
            "G") result=$((num * 1000000)) ;;
            "") result=$num ;;
            *) log_error "未知带宽单位: $unit"; return 1 ;;
        esac
        # 检查单位后是否有额外字符（如 "MB" -> 单位 "M"，但原字符串非纯单位）
        local raw_unit=$(echo "$bw" | sed 's/[0-9]//g' | tr '[:lower:]' '[:upper:]')
        if [ "$raw_unit" != "$unit" ] && [ -n "$raw_unit" ]; then
            log_warn "带宽单位 '$raw_unit' 可能不标准，已按 '${unit}' 处理（${num}${unit}=${result}kbit）"
        fi
        echo "$result"
        return 0
    else
        if echo "$bw" | grep -qE '^[0-9]+$'; then
            echo "$bw"
            return 0
        else
            log_error "无效带宽格式: $bw"
            return 1
        fi
    fi
}

# ========== 参数验证 ==========
validate_cake_parameters() {
    local param_value="$1"
    local param_name="$2"

    case "$param_name" in
        bandwidth)
            if ! echo "$param_value" | grep -qE '^[0-9]+$'; then
                log_error "无效的带宽值 (必须是数字): $1"
                return 1
            fi
            [ "$param_value" -lt 8 ] && log_warn "带宽过小: ${param_value}kbit (建议至少8kbit)"
            [ "$param_value" -gt 1000000 ] && log_warn "带宽过大: ${param_value}kbit (超过1Gbit)"
            ;;

        rtt)
            if [ -n "$param_value" ] && ! echo "$param_value" | grep -qiE '^[0-9]*\.?[0-9]+(us|ms|s)$'; then
                log_warn "无效的RTT格式: $param_value (应为数字+单位: us/ms/s)"
                return 1
            fi
            ;;

        memory_limit)
            if [ -n "$param_value" ] && ! echo "$param_value" | grep -qiE '^[0-9]+(b|kb|mb|gb)$'; then
                log_warn "无效的内存限制格式: $param_value"
                return 1
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

# ========== 配置加载（带消毒）==========
load_cake_config() {
    log_info "加载CAKE配置"

    # 全局带宽
    local uci_upload=$(uci -q get qos_gargoyle.global.upload_bandwidth 2>/dev/null)
    local uci_download=$(uci -q get qos_gargoyle.global.download_bandwidth 2>/dev/null)
    [ -n "$uci_upload" ] && total_upload_bandwidth=$(sanitize_param "$uci_upload")
    [ -n "$uci_download" ] && total_download_bandwidth=$(sanitize_param "$uci_download")

    # IFB设备
    local uci_ifb=$(uci -q get qos_gargoyle.global.ifb_device 2>/dev/null)
    [ -n "$uci_ifb" ] && IFB_DEVICE=$(sanitize_param "$uci_ifb")

    # CAKE参数（所有值均消毒，内存限制转换为小写）
    local val
    val=$(uci -q get qos_gargoyle.cake.diffserv_mode 2>/dev/null)
    CAKE_DIFFSERV_MODE=$(sanitize_param "${val:-diffserv4}")

    val=$(uci -q get qos_gargoyle.cake.overhead 2>/dev/null)
    CAKE_OVERHEAD=$(sanitize_param "${val:-0}")

    val=$(uci -q get qos_gargoyle.cake.mpu 2>/dev/null)
    CAKE_MPU=$(sanitize_param "${val:-0}")

    val=$(uci -q get qos_gargoyle.cake.rtt 2>/dev/null)
    CAKE_RTT=$(sanitize_param "${val:-100ms}")

    val=$(uci -q get qos_gargoyle.cake.ack_filter 2>/dev/null)
    CAKE_ACK_FILTER=$(sanitize_param "${val:-0}")

    val=$(uci -q get qos_gargoyle.cake.nat 2>/dev/null)
    CAKE_NAT=$(sanitize_param "${val:-0}")

    val=$(uci -q get qos_gargoyle.cake.wash 2>/dev/null)
    CAKE_WASH=$(sanitize_param "${val:-0}")

    val=$(uci -q get qos_gargoyle.cake.split_gso 2>/dev/null)
    CAKE_SPLIT_GSO=$(sanitize_param "${val:-0}")

    val=$(uci -q get qos_gargoyle.cake.ingress 2>/dev/null)
    CAKE_INGRESS=$(sanitize_param "${val:-0}")

    val=$(uci -q get qos_gargoyle.cake.autorate_ingress 2>/dev/null)
    CAKE_AUTORATE_INGRESS=$(sanitize_param "${val:-0}")

    val=$(uci -q get qos_gargoyle.cake.memlimit 2>/dev/null)
    CAKE_MEMORY_LIMIT=$(sanitize_param "${val:-32mb}")
    # 统一转换为小写，避免tc不识别大写单位
    CAKE_MEMORY_LIMIT=$(echo "$CAKE_MEMORY_LIMIT" | tr 'A-Z' 'a-z')

    val=$(uci -q get qos_gargoyle.cake.enable_auto_tune 2>/dev/null)
    [ -n "$val" ] && ENABLE_AUTO_TUNE=$(sanitize_param "$val")

    log_info "CAKE配置加载完成"
}

# ========== 自动调优 ==========
auto_tune_cake() {
    log_info "自动调整CAKE参数"

    local total_bw=0
    if [ "$total_upload_bandwidth" -gt 0 ] && [ "$total_download_bandwidth" -gt 0 ]; then
        total_bw=$((total_upload_bandwidth + total_download_bandwidth))
    elif [ "$total_upload_bandwidth" -gt 0 ]; then
        total_bw=$total_upload_bandwidth
    elif [ "$total_download_bandwidth" -gt 0 ]; then
        total_bw=$total_download_bandwidth
    fi

    # 检查用户是否显式设置了RTT和内存限制
    local user_set_rtt=$(uci -q get qos_gargoyle.cake.rtt 2>/dev/null)
    local user_set_mem=$(uci -q get qos_gargoyle.cake.memlimit 2>/dev/null)

    if [ "$total_bw" -gt 200000 ]; then
        [ -z "$user_set_mem" ] && CAKE_MEMORY_LIMIT="128mb"
        [ -z "$user_set_rtt" ] && CAKE_RTT="20ms"
        log_info "自动调整: 超高带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}"
    elif [ "$total_bw" -gt 100000 ]; then
        [ -z "$user_set_mem" ] && CAKE_MEMORY_LIMIT="64mb"
        [ -z "$user_set_rtt" ] && CAKE_RTT="50ms"
        log_info "自动调整: 高带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}"
    elif [ "$total_bw" -gt 50000 ]; then
        [ -z "$user_set_mem" ] && CAKE_MEMORY_LIMIT="32mb"
        [ -z "$user_set_rtt" ] && CAKE_RTT="100ms"
        log_info "自动调整: 中等带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}"
    elif [ "$total_bw" -gt 10000 ]; then
        [ -z "$user_set_mem" ] && CAKE_MEMORY_LIMIT="16mb"
        [ -z "$user_set_rtt" ] && CAKE_RTT="150ms"
        log_info "自动调整: 低带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}"
    else
        [ -z "$user_set_mem" ] && CAKE_MEMORY_LIMIT="8mb"
        [ -z "$user_set_rtt" ] && CAKE_RTT="200ms"
        log_info "自动调整: 极低带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}"
    fi
}

# ========== 配置验证 ==========
validate_cake_config() {
    log_info "验证CAKE配置..."

    if [ -z "$qos_interface" ]; then
        log_error "缺少必要变量: qos_interface"
        return 1
    fi
    if ! ip link show dev "$qos_interface" >/dev/null 2>&1; then
        log_error "接口 $qos_interface 不存在"
        return 1
    fi

    if [ "$total_upload_bandwidth" -le 0 ]; then
        log_warn "上传带宽未配置或为0，跳过上传方向"
    else
        validate_cake_parameters "$total_upload_bandwidth" "bandwidth" || return 1
    fi

    if [ "$total_download_bandwidth" -le 0 ]; then
        log_warn "下载带宽未配置或为0，跳过下载方向"
    else
        validate_cake_parameters "$total_download_bandwidth" "bandwidth" || return 1
    fi

    validate_diffserv_mode "$CAKE_DIFFSERV_MODE" || CAKE_DIFFSERV_MODE="diffserv4"
    validate_cake_parameters "$CAKE_RTT" "rtt"
    validate_cake_parameters "$CAKE_MEMORY_LIMIT" "memory_limit"

    log_info "✅ CAKE配置验证通过"
    return 0
}

# ========== 入口重定向（IPv4必须成功，IPv6可选）==========
setup_ingress_redirect() {
    log_info "设置入口重定向: $qos_interface -> $IFB_DEVICE"

    tc qdisc del dev "$qos_interface" ingress 2>/dev/null

    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        log_error "无法在$qos_interface上创建入口队列"
        return 1
    fi

    local ipv4_success=false
    local ipv6_success=false

    # IPv4重定向（必须成功）
    if tc filter add dev "$qos_interface" parent ffff: protocol ip \
        u32 match u32 0 0 \
        action mirred egress redirect dev "$IFB_DEVICE" 2>/dev/null; then
        ipv4_success=true
    else
        log_error "IPv4入口重定向规则添加失败"
        # 清理已创建的队列
        tc qdisc del dev "$qos_interface" ingress 2>/dev/null
        return 1
    fi

    # IPv6重定向：限制全球单播地址 2000::/3（可选）
    if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
        match ip6 dst 2000::/3 \
        action mirred egress redirect dev "$IFB_DEVICE" 2>/dev/null; then
        ipv6_success=true
    else
        log_warn "IPv6入口重定向规则（全球单播）添加失败，尝试无过滤规则"
        if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
            u32 match u32 0 0 \
            action mirred egress redirect dev "$IFB_DEVICE" 2>/dev/null; then
            ipv6_success=true
        else
            log_warn "IPv6入口重定向规则添加失败，IPv6流量将不会通过IFB"
        fi
    fi

    log_info "入口重定向设置完成 (IPv4: ${ipv4_success}, IPv6: ${ipv6_success})"
    return 0
}

# ========== 检查入口重定向 ==========
check_ingress_redirect() {
    log_info "检查入口重定向状态"

    local has_ipv4=false
    local has_ipv6=false

    if tc filter show dev "$qos_interface" parent ffff: protocol ip 2>/dev/null | \
        grep -qi "mirred.*redirect dev $IFB_DEVICE"; then
        has_ipv4=true
        echo "✅ IPv4入口重定向: 已生效"
    else
        echo "❌ IPv4入口重定向: 未生效"
    fi

    if tc filter show dev "$qos_interface" parent ffff: protocol ipv6 2>/dev/null | \
        grep -qi "mirred.*redirect dev $IFB_DEVICE"; then
        has_ipv6=true
        echo "✅ IPv6入口重定向: 已生效"
    else
        echo "❌ IPv6入口重定向: 未生效"
    fi

    [ "$has_ipv4" = true ] && return 0
    return 1
}

# ========== 清理队列 ==========
cleanup_existing_queues() {
    local device="$1"
    local direction="$2"

    log_info "清理$device上的现有$direction队列"

    if [ "$direction" = "upload" ]; then
        tc qdisc del dev "$device" root 2>/dev/null && \
            echo "  清理上传队列完成" || echo "  无上传队列可清理"
    elif [ "$direction" = "download" ]; then
        if [ "$device" = "$IFB_DEVICE" ]; then
            tc qdisc del dev "$device" root 2>/dev/null && \
                echo "  清理IFB队列完成" || echo "  无IFB队列可清理"
        fi
    fi
}

# ========== 创建CAKE队列 ==========
create_cake_root_qdisc() {
    local device="$1"
    local direction="$2"
    local bandwidth="$3"

    log_info "为$device创建$direction方向CAKE根队列 (带宽: ${bandwidth}kbit)"

    if ! validate_cake_parameters "$bandwidth" "bandwidth"; then
        return 1
    fi

    cleanup_existing_queues "$device" "$direction"

    local cake_params="bandwidth ${bandwidth}kbit $CAKE_DIFFSERV_MODE"
    [ "$CAKE_OVERHEAD" != "0" ] && cake_params="$cake_params overhead $CAKE_OVERHEAD"
    [ "$CAKE_MPU" != "0" ] && cake_params="$cake_params mpu $CAKE_MPU"
    [ -n "$CAKE_RTT" ] && cake_params="$cake_params rtt $CAKE_RTT"
    [ "$CAKE_ACK_FILTER" = "1" ] && cake_params="$cake_params ack-filter"
    [ "$CAKE_NAT" = "1" ] && cake_params="$cake_params nat"
    [ "$CAKE_WASH" = "1" ] && cake_params="$cake_params wash"
    [ "$CAKE_SPLIT_GSO" = "1" ] && cake_params="$cake_params split-gso"
    [ -n "$CAKE_MEMORY_LIMIT" ] && cake_params="$cake_params memlimit $CAKE_MEMORY_LIMIT"

    if [ "$direction" = "upload" ]; then
        echo "正在为 $device 创建上传CAKE队列..."
        echo "  参数: $cake_params"
        if ! tc qdisc add dev "$device" root cake $cake_params; then
            log_error "无法在$device上创建上传CAKE队列"
            return 1
        fi
    elif [ "$direction" = "download" ]; then
        # 为下载队列附加 ingress 相关参数（如果启用）
        if [ "$CAKE_INGRESS" = "1" ]; then
            cake_params="$cake_params ingress"
            [ "$CAKE_AUTORATE_INGRESS" = "1" ] && cake_params="$cake_params autorate-ingress"
        fi
        echo "正在为 $device 创建下载CAKE根队列..."
        echo "  参数: $cake_params"
        if ! tc qdisc add dev "$device" root cake $cake_params; then
            log_error "无法在$device上创建下载CAKE队列"
            return 1
        fi
    fi

    log_info "$device的$direction方向CAKE队列创建完成"
    echo "✅ $device 的 $direction 方向 CAKE 队列创建完成"
    return 0
}

# ========== 上传初始化 ==========
initialize_cake_upload() {
    log_info "初始化上传方向CAKE"

    if [ -z "$total_upload_bandwidth" ] || [ "$total_upload_bandwidth" -le 0 ]; then
        log_info "上传带宽未配置，跳过上传方向初始化"
        return 0
    fi

    echo "为 $qos_interface 创建上传CAKE队列 (带宽: ${total_upload_bandwidth}kbit/s)"
    create_cake_root_qdisc "$qos_interface" "upload" "$total_upload_bandwidth"
}

# ========== 下载初始化 ==========
initialize_cake_download() {
    log_info "初始化下载方向CAKE"

    if [ -z "$total_download_bandwidth" ] || [ "$total_download_bandwidth" -le 0 ]; then
        log_info "下载带宽未配置，跳过下载方向初始化"
        return 0
    fi

    echo "为 $IFB_DEVICE 创建下载CAKE队列 (带宽: ${total_download_bandwidth}kbit/s)"

    if ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        log_info "IFB设备 $IFB_DEVICE 不存在，尝试创建"
        ip link add "$IFB_DEVICE" type ifb || {
            log_error "无法创建IFB设备 $IFB_DEVICE"
            return 1
        }
    fi

    ip link set dev "$IFB_DEVICE" up || {
        log_error "无法启动IFB设备 $IFB_DEVICE"
        return 1
    }

    setup_ingress_redirect || return 1
    create_cake_root_qdisc "$IFB_DEVICE" "download" "$total_download_bandwidth"
}

# ========== 健康检查 ==========
health_check_cake() {
    echo "执行CAKE健康检查..."

    local health_score=100
    local issues=""

    if ! ip link show dev "$qos_interface" >/dev/null 2>&1; then
        health_score=$((health_score - 30))
        issues="${issues}接口 $qos_interface 不存在\n"
    fi

    if ! tc qdisc show dev "$qos_interface" root 2>/dev/null | grep -q "cake"; then
        health_score=$((health_score - 20))
        issues="${issues}上传CAKE队列未启用\n"
    fi

    if ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        health_score=$((health_score - 10))
        issues="${issues}IFB设备不存在\n"
    elif ! tc qdisc show dev "$IFB_DEVICE" root 2>/dev/null | grep -q "cake"; then
        health_score=$((health_score - 20))
        issues="${issues}下载CAKE队列未启用\n"
    fi

    if ! tc qdisc show dev "$qos_interface" ingress 2>/dev/null; then
        health_score=$((health_score - 10))
        issues="${issues}入口重定向未配置\n"
    fi

    echo -e "\n健康检查结果:"
    echo "  健康分数: $health_score/100"

    if [ -z "$issues" ]; then
        echo "  ✅ 所有检查通过"
    else
        echo "  ⚠️ 发现的问题:"
        printf "%b" "$issues" | while IFS= read -r line; do
            [ -n "$line" ] && echo "    - $line"
        done
    fi

    return $((health_score >= 70 ? 0 : 1))
}

# ========== 状态显示（使用运行时参数）==========
show_cake_status() {
    echo "===== CAKE QoS状态报告 (v4.12) ====="
    echo "时间: $(date)"
    echo "网络接口: ${qos_interface:-未知}"

    # 加载UCI配置（用于显示默认配置，但运行时参数优先）
    load_cake_config

    # 如果运行时参数文件存在，则读取实际运行的RTT和内存限制
    if [ -f "$RUNTIME_PARAMS_FILE" ]; then
        . "$RUNTIME_PARAMS_FILE"
        log_debug "使用运行时参数: RTT=$CAKE_RTT, MEM=$CAKE_MEMORY_LIMIT"
    else
        log_debug "无运行时参数文件，使用UCI配置"
    fi

    if ! tc qdisc show dev "${qos_interface}" 2>/dev/null | grep -q "qdisc cake"; then
        echo "警告: QoS未在接口 ${qos_interface} 上激活"
        return 1
    fi

    # 出口队列
    echo -e "\n===== 出口CAKE队列 ($qos_interface) ====="
    if tc qdisc show dev "$qos_interface" root 2>/dev/null | grep -q "cake"; then
        echo "状态: 已启用 ✅"
        echo "队列参数:"
        tc qdisc show dev "$qos_interface" root 2>/dev/null | grep "qdisc cake" | sed 's/^qdisc cake //' | sed 's/^/  /'
        echo -e "\nTC队列统计:"
        tc -s qdisc show dev "$qos_interface" root 2>/dev/null | sed 's/^/  /'
    else
        echo "状态: 未启用 ❌"
    fi

    # 入口队列
    echo -e "\n===== 入口CAKE队列 ($IFB_DEVICE) ====="
    if ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
        if tc qdisc show dev "$IFB_DEVICE" root 2>/dev/null | grep -q "cake"; then
            echo "状态: 已启用 ✅"
            echo "队列参数:"
            tc qdisc show dev "$IFB_DEVICE" root 2>/dev/null | grep "qdisc cake" | sed 's/^qdisc cake //' | sed 's/^/  /'
            echo -e "\nTC队列统计:"
            tc -s qdisc show dev "$IFB_DEVICE" root 2>/dev/null | sed 's/^/  /'
        else
            echo "状态: IFB设备存在但无CAKE队列"
        fi
    else
        echo "状态: IFB设备未创建"
    fi

    # 入口重定向检查
    echo -e "\n===== 入口重定向检查 ====="
    if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "ingress"; then
        echo "入口队列状态: 已配置"
        tc filter show dev "$qos_interface" parent ffff: 2>/dev/null | sed 's/^/  /' || echo "  无过滤器规则"
    else
        echo "入口队列状态: 未配置"
    fi

    # CAKE配置参数（显示实际运行值）
    echo -e "\n===== CAKE配置参数 (运行时) ====="
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
    echo "自动调优: $([ "$ENABLE_AUTO_TUNE" = "1" ] && echo "启用 ✅" || echo "禁用 ❌")"

    echo -e "\n===== 状态报告结束 ====="
    return 0
}

# ========== 停止清理 ==========
stop_cake_qos() {
    log_info "停止CAKE QoS"

    if tc qdisc show dev "$qos_interface" root 2>/dev/null | grep -q "cake"; then
        tc qdisc del dev "$qos_interface" root 2>/dev/null
        log_info "清理上传方向CAKE队列"
    fi

    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        if tc qdisc show dev "$IFB_DEVICE" root 2>/dev/null | grep -q "cake"; then
            tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null
            log_info "清理下载方向CAKE队列 (IFB)"
        fi
    fi
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null && log_info "清理入口重定向队列"

    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link set dev "$IFB_DEVICE" down
        log_info "停用IFB设备: $IFB_DEVICE"
    fi

    # 清理运行时参数文件
    rm -f "$RUNTIME_PARAMS_FILE"
    log_info "CAKE QoS停止完成"
}

# ========== 锁函数（增强）==========
acquire_lock() {
    if [ -d "$LOCK_DIR" ]; then
        if [ -f "$LOCK_PID_FILE" ]; then
            local old_pid=$(cat "$LOCK_PID_FILE" 2>/dev/null)
            if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
                log_warn "发现残留锁目录，进程 $old_pid 已不存在，清理中"
                rm -rf "$LOCK_DIR"
            else
                log_error "无法获取锁，进程 $old_pid 仍在运行"
                return 1
            fi
        else
            # 无PID文件，可能是不完整锁，但需确保目录为空再删除
            if rmdir "$LOCK_DIR" 2>/dev/null; then
                : # 目录为空，删除成功
            else
                log_error "锁目录 $LOCK_DIR 非空且无PID文件，无法清理"
                return 1
            fi
        fi
    fi

    mkdir "$LOCK_DIR" || {
        log_error "无法创建锁目录"
        return 1
    }
    echo "$$" > "$LOCK_PID_FILE"
    trap 'release_lock' EXIT INT TERM HUP QUIT
    log_debug "已获取锁: $LOCK_DIR (PID: $$)"
    return 0
}

release_lock() {
    rm -f "$LOCK_PID_FILE"
    rmdir "$LOCK_DIR" 2>/dev/null
    log_debug "锁已释放"
}

# ========== 主函数 ==========
main_cake_qos() {
    local action="$1"

    case "$action" in
        start)
            log_info "启动CAKE QoS"
            check_dependencies || exit 1
            acquire_lock || exit 1

            load_cake_config
            total_upload_bandwidth=$(convert_bandwidth_to_kbit "$total_upload_bandwidth") || { release_lock; exit 1; }
            total_download_bandwidth=$(convert_bandwidth_to_kbit "$total_download_bandwidth") || { release_lock; exit 1; }

            [ "$ENABLE_AUTO_TUNE" = "1" ] && auto_tune_cake

            validate_cake_config || { release_lock; exit 1; }

            initialize_cake_upload || { release_lock; exit 1; }
            initialize_cake_download || { release_lock; exit 1; }

            if [ "$total_download_bandwidth" -gt 0 ]; then
                check_ingress_redirect
            fi

            # 保存最终运行时参数
            echo "CAKE_RTT='$CAKE_RTT'" > "$RUNTIME_PARAMS_FILE"
            echo "CAKE_MEMORY_LIMIT='$CAKE_MEMORY_LIMIT'" >> "$RUNTIME_PARAMS_FILE"

            health_check_cake
            release_lock
            ;;
        stop)
            log_info "停止CAKE QoS"
            stop_cake_qos
            ;;
        restart)
            log_info "重启CAKE QoS"
            stop_cake_qos
            sleep 2
            main_cake_qos start
            ;;
        status|show)
            show_cake_status
            ;;
        health)
            health_check_cake
            ;;
        validate)
            check_dependencies || exit 1
            load_cake_config
            total_upload_bandwidth=$(convert_bandwidth_to_kbit "$total_upload_bandwidth") || exit 1
            total_download_bandwidth=$(convert_bandwidth_to_kbit "$total_download_bandwidth") || exit 1
            validate_cake_config
            ;;
        help)
            echo "用法: $0 {start|stop|restart|status|health|validate|help}"
            echo "  start    启动CAKE QoS"
            echo "  stop     停止CAKE QoS"
            echo "  restart  重启CAKE QoS"
            echo "  status   显示CAKE状态"
            echo "  health   执行健康检查"
            echo "  validate 验证CAKE配置"
            echo "  help     显示此帮助信息"
            ;;
        *)
            echo "用法: $0 {start|stop|restart|status|health|validate|help}"
            exit 1
            ;;
    esac
}

# 脚本入口
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