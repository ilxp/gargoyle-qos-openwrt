#!/bin/sh
# version=5.6-mq
# CAKE算法实现模块 - 多队列增强版 v5.6
# 优化：带宽单位转换区分字节/比特；IPv6重定向循环简化并增加全局地址检测；
#       锁机制强化（含僵尸进程检测）；变量作用域限定

# ========== 变量初始化 ==========
: ${total_upload_bandwidth:=50000}
: ${total_download_bandwidth:=100000}
: ${IFB_DEVICE:=ifb0}
LOCK_DIR="/var/run/cake_qos.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"
RUNTIME_PARAMS_FILE="/tmp/cake_runtime_params"
QOS_RUNNING_FILE="/var/run/cake_qos.running"

# 如果 qos_interface 未设置，尝试获取
if [ -z "$qos_interface" ]; then
    qos_interface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
    qos_interface="${qos_interface:-pppoe-wan}"
fi

echo "CAKE 模块初始化完成 (v5.6-mq)"
echo "  网络接口: $qos_interface"
echo "  IFB 设备: $IFB_DEVICE"
echo "  上传带宽: ${total_upload_bandwidth}kbit/s"
echo "  下载带宽: ${total_download_bandwidth}kbit/s"

# ========= CAKE专属常量 ==========
CAKE_DIFFSERV_MODE="diffserv4"
CAKE_FLOWMODE="srchost"          # 流模式，默认 srchost
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
CAKE_ECN=""               # ECN 启用标志
ENABLE_AUTO_TUNE="1"
CAKE_MQ_ENABLED="1"        # 是否启用多队列 CAKE-MQ
CAKE_DELETE_IFB_ON_STOP="1" # 停止时是否删除 IFB 设备（默认删除）

# 运行时生效的高级参数标志（初始为0）
RUNTIME_SPLIT_GSO=0
RUNTIME_INGRESS=0
RUNTIME_AUTORATE_INGRESS=0

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
    if ! command -v ethtool >/dev/null 2>&1; then
        log_warn "ethtool 命令未找到，队列数检测将回退到 sysfs"
    fi
    return 0
}

# ========== 幂等性检查 ==========
check_already_running() {
    if [ -f "$QOS_RUNNING_FILE" ]; then
        local pid=$(cat "$QOS_RUNNING_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log_error "CAKE QoS 已经在运行中 (PID: $pid)"
            return 1
        else
            log_warn "发现残留的运行标记文件，清理中"
            rm -f "$QOS_RUNNING_FILE"
        fi
    fi
    echo "$$" > "$QOS_RUNNING_FILE"
    return 0
}

# ========== 带宽单位转换（严格区分字节与比特）==========
convert_bandwidth_to_kbit() {
    local bw="$1"
    local num unit result

    [ -z "$bw" ] && { log_error "带宽值为空"; return 1; }

    # 纯数字视为 kbit
    if echo "$bw" | grep -qE '^[0-9]+$'; then
        echo "$bw"
        return 0
    fi

    # 提取数字和单位
    if echo "$bw" | grep -qiE '^[0-9]+(\.[0-9]+)?[a-zA-Z]+$'; then
        num=$(echo "$bw" | grep -oE '^[0-9]+(\.[0-9]+)?')
        unit=$(echo "$bw" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')

        case "$unit" in
            # 比特单位
            K|KBIT|KILOBIT)
                result=$(echo "$num * 1" | awk '{printf "%.0f", $1}')
                ;;
            M|MBIT|MEGABIT)
                result=$(echo "$num * 1000" | awk '{printf "%.0f", $1}')
                ;;
            G|GBIT|GIGABIT)
                result=$(echo "$num * 1000000" | awk '{printf "%.0f", $1}')
                ;;
            # 字节单位 → 乘以 8 转换为比特
            KB|KIB)
                log_warn "检测到字节单位 '$unit'，将自动乘以 8 转换为 kbit"
                result=$(echo "$num * 8" | awk '{printf "%.0f", $1}')
                ;;
            MB|MIB)
                log_warn "检测到字节单位 '$unit'，将自动乘以 8 转换为 kbit"
                result=$(echo "$num * 8000" | awk '{printf "%.0f", $1}')
                ;;
            GB|GIB)
                log_warn "检测到字节单位 '$unit'，将自动乘以 8 转换为 kbit"
                result=$(echo "$num * 8000000" | awk '{printf "%.0f", $1}')
                ;;
            *)
                log_error "未知带宽单位: $unit"
                return 1
                ;;
        esac

        if [ -z "$result" ] || ! echo "$result" | grep -qE '^[0-9]+$' || [ "$result" -lt 0 ] 2>/dev/null; then
            log_error "带宽转换结果无效: $result"
            return 1
        fi

        echo "$result"
        return 0
    else
        log_error "无效带宽格式: $bw (应为数字或数字+单位，例如 100mbit、10MB)"
        return 1
    fi
}

# ========== 参数验证 ==========
validate_cake_parameters() {
    local param_value="$1"
    local param_name="$2"
    local num unit ms mb

    case "$param_name" in
        bandwidth)
            if ! echo "$param_value" | grep -qE '^[0-9]+$'; then
                log_error "无效的带宽值 (必须是数字): $1"
                return 1
            fi
            if [ "$param_value" -lt 8 ] 2>/dev/null; then
                log_warn "带宽过小: ${param_value}kbit (建议至少8kbit)"
            fi
            if [ "$param_value" -gt 10000000 ] 2>/dev/null; then
                log_warn "带宽过大: ${param_value}kbit (超过10Gbit)"
            fi
            ;;

        rtt)
            if [ -n "$param_value" ] && ! echo "$param_value" | grep -qiE '^[0-9]*\.?[0-9]+(us|ms|s)$'; then
                log_warn "无效的RTT格式: $param_value (应为数字+单位: us/ms/s)"
                return 1
            fi
            if [ -n "$param_value" ]; then
                num=$(echo "$param_value" | grep -oE '^[0-9]*\.?[0-9]+')
                unit=$(echo "$param_value" | grep -oiE '(us|ms|s)$' | tr 'A-Z' 'a-z')
                case "$unit" in
                    us) ms=$(( ${num%.*} / 1000 )) ;;
                    ms) ms="${num%.*}" ;;
                    s)  ms=$(( ${num%.*} * 1000 )) ;;
                esac
                if [ -n "$ms" ] && [ "$ms" -gt 10000 ] 2>/dev/null; then
                    log_warn "RTT值过大 (>10秒): $param_value"
                elif [ -n "$ms" ] && [ "$ms" -lt 1 ] 2>/dev/null && [ "$ms" != "0" ]; then
                    log_warn "RTT值过小 (<1ms): $param_value"
                fi
            fi
            ;;

        memory_limit)
            if [ -n "$param_value" ] && ! echo "$param_value" | grep -qiE '^[0-9]+(b|kb|mb|gb)$'; then
                log_warn "无效的内存限制格式: $param_value"
                return 1
            fi
            if [ -n "$param_value" ]; then
                num=$(echo "$param_value" | grep -oE '[0-9]+')
                unit=$(echo "$param_value" | grep -oiE '(b|kb|mb|gb)$' | tr 'A-Z' 'a-z')
                case "$unit" in
                    b)  mb=$((num / 1024 / 1024)) ;;
                    kb) mb=$((num / 1024)) ;;
                    mb) mb=$num ;;
                    gb) mb=$((num * 1024)) ;;
                esac
                if [ "$mb" -gt 512 ] 2>/dev/null; then
                    log_warn "内存限制过大 (>512MB): $param_value"
                elif [ "$mb" -lt 1 ] 2>/dev/null && [ "$mb" -ne 0 ]; then
                    log_warn "内存限制过小 (<1MB): $param_value"
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

# ========== 获取设备发送队列数（增强版）==========
get_tx_queues() {
    local dev="$1"
    local queues=1
    local ethtool_out

    if ! ip link show dev "$dev" >/dev/null 2>&1; then
        log_warn "设备 $dev 不存在，返回默认队列数 1"
        echo "1"
        return
    fi

    if command -v ethtool >/dev/null 2>&1; then
        ethtool_out=$(ethtool -l "$dev" 2>/dev/null | awk '
            /^Current hardware settings:/ { in_current=1; next }
            /^[^ ]/ { in_current=0 }
            in_current && /Combined:/ { print $2; exit }
        ')
        if [ -n "$ethtool_out" ] && [ "$ethtool_out" -gt 0 ] 2>/dev/null; then
            queues=$ethtool_out
            log_debug "ethtool (current) 获取 $dev 队列数: $queues"
            echo "$queues"
            return
        fi
        ethtool_out=$(ethtool -l "$dev" 2>/dev/null | grep "Combined:" | tail -1 | awk '{print $2}')
        if [ -n "$ethtool_out" ] && [ "$ethtool_out" -gt 0 ] 2>/dev/null; then
            queues=$ethtool_out
            log_debug "ethtool (fallback) 获取 $dev 队列数: $queues"
            echo "$queues"
            return
        fi
    fi

    if [ -d "/sys/class/net/$dev/queues" ]; then
        queues=$(ls -d /sys/class/net/$dev/queues/tx-* 2>/dev/null | wc -l)
        log_debug "sysfs 获取 $dev 队列数: $queues"
    fi

    if [ -z "$queues" ] || [ "$queues" -eq 0 ] 2>/dev/null; then
        queues=1
    fi

    echo "$queues"
}

# ========== 检测内核是否支持特定 CAKE 参数 ==========
check_cake_param_support() {
    local param="$1"
    tc qdisc del dev lo root 2>/dev/null
    if tc qdisc add dev lo root cake bandwidth 1mbit "$param" 2>/dev/null; then
        tc qdisc del dev lo root 2>/dev/null
        return 0
    else
        return 1
    fi
}

# ========== 配置加载（带消毒）==========
load_cake_config() {
    log_info "加载CAKE配置"
    local uci_upload uci_download uci_ifb val

    uci_upload=$(uci -q get qos_gargoyle.global.upload_bandwidth 2>/dev/null)
    uci_download=$(uci -q get qos_gargoyle.global.download_bandwidth 2>/dev/null)
    [ -n "$uci_upload" ] && total_upload_bandwidth=$(sanitize_param "$uci_upload")
    [ -n "$uci_download" ] && total_download_bandwidth=$(sanitize_param "$uci_download")

    uci_ifb=$(uci -q get qos_gargoyle.download.ifb_device 2>/dev/null)
    [ -n "$uci_ifb" ] && IFB_DEVICE=$(sanitize_param "$uci_ifb")

    val=$(uci -q get qos_gargoyle.cake.diffserv_mode 2>/dev/null)
    CAKE_DIFFSERV_MODE=$(sanitize_param "${val:-diffserv4}")

    val=$(uci -q get qos_gargoyle.cake.flowmode 2>/dev/null)
    [ -n "$val" ] && CAKE_FLOWMODE=$(sanitize_param "$val")

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
    CAKE_MEMORY_LIMIT=$(echo "$CAKE_MEMORY_LIMIT" | tr 'A-Z' 'a-z')

    val=$(uci -q get qos_gargoyle.cake.ecn 2>/dev/null)
    if [ -n "$val" ]; then
        case "$val" in
            yes|1|enable|on|true|ecn)
                CAKE_ECN="ecn"
                log_info "CAKE ECN 已启用"
                ;;
            no|0|disable|off|false|noecn)
                CAKE_ECN="noecn"
                log_info "CAKE ECN 已禁用"
                ;;
            *)
                log_warn "无效的 ECN 配置值 '$val'，将忽略"
                CAKE_ECN=""
                ;;
        esac
    fi

    val=$(uci -q get qos_gargoyle.cake.enable_auto_tune 2>/dev/null)
    [ -n "$val" ] && ENABLE_AUTO_TUNE=$(sanitize_param "$val")

    val=$(uci -q get qos_gargoyle.cake.enable_mq 2>/dev/null)
    [ -n "$val" ] && CAKE_MQ_ENABLED=$(sanitize_param "$val")

    val=$(uci -q get qos_gargoyle.cake.delete_ifb_on_stop 2>/dev/null)
    [ -n "$val" ] && CAKE_DELETE_IFB_ON_STOP=$(sanitize_param "$val")

    log_info "CAKE配置加载完成"
}

# ========== 自动调优 ==========
auto_tune_cake() {
    log_info "自动调整CAKE参数"
    local total_bw=0
    local user_set_rtt user_set_mem

    if [ "$total_upload_bandwidth" -gt 0 ] && [ "$total_download_bandwidth" -gt 0 ]; then
        total_bw=$((total_upload_bandwidth + total_download_bandwidth))
    elif [ "$total_upload_bandwidth" -gt 0 ]; then
        total_bw=$total_upload_bandwidth
    elif [ "$total_download_bandwidth" -gt 0 ]; then
        total_bw=$total_download_bandwidth
    fi

    user_set_rtt=$(uci -q get qos_gargoyle.cake.rtt 2>/dev/null)
    user_set_mem=$(uci -q get qos_gargoyle.cake.memlimit 2>/dev/null)

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

    if [ "$total_upload_bandwidth" -le 0 ] 2>/dev/null; then
        log_warn "上传带宽未配置或为0，跳过上传方向"
    else
        validate_cake_parameters "$total_upload_bandwidth" "bandwidth" || return 1
    fi

    if [ "$total_download_bandwidth" -le 0 ] 2>/dev/null; then
        log_warn "下载带宽未配置或为0，跳过下载方向"
    else
        validate_cake_parameters "$total_download_bandwidth" "bandwidth" || return 1
    fi

    validate_diffserv_mode "$CAKE_DIFFSERV_MODE" || CAKE_DIFFSERV_MODE="diffserv4"
    validate_cake_parameters "$CAKE_RTT" "rtt" || return 1
    validate_cake_parameters "$CAKE_MEMORY_LIMIT" "memory_limit" || return 1

    log_info "✅ CAKE配置验证通过"
    return 0
}

# ========== 入口重定向（IPv4必须成功，IPv6按优先级尝试，并增加全局地址检测）==========
setup_ingress_redirect() {
    log_info "设置入口重定向: $qos_interface -> $IFB_DEVICE"
    local ipv4_success=false
    local ipv6_success=false
    local match_cmd

    tc qdisc del dev "$qos_interface" ingress 2>/dev/null

    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        log_error "无法在$qos_interface上创建入口队列"
        return 1
    fi

    # IPv4 重定向（必须成功）
    if tc filter add dev "$qos_interface" parent ffff: protocol ip \
        u32 match u32 0 0 \
        action mirred egress redirect dev "$IFB_DEVICE" 2>/dev/null; then
        ipv4_success=true
    else
        log_error "IPv4入口重定向规则添加失败"
        tc qdisc del dev "$qos_interface" ingress 2>/dev/null
        return 1
    fi

    # 检测接口是否有全局 IPv6 地址，以决定是否强制 IPv6 必须成功
    local has_ipv6_global=0
    if ip -6 addr show dev "$qos_interface" scope global 2>/dev/null | grep -q "inet6"; then
        has_ipv6_global=1
        log_info "接口 $qos_interface 拥有全局 IPv6 地址，将强制 IPv6 重定向必须成功"
    else
        log_info "接口 $qos_interface 无全局 IPv6 地址，IPv6 重定向失败仅警告"
    fi

    # IPv6 重定向：按优先级尝试三种匹配方式
    for match_cmd in \
        "flower dst_ip 2000::/3" \
        "u32 match u32 0x20000000 0xe0000000 at 24" \
        "u32 match u32 0 0"; do
        if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
            $match_cmd \
            action mirred egress redirect dev "$IFB_DEVICE" 2>/dev/null; then
            ipv6_success=true
            log_info "IPv6入口重定向规则 ($match_cmd) 添加成功"
            break
        else
            log_warn "IPv6规则 ($match_cmd) 添加失败"
        fi
    done

    # 根据是否有全局 IPv6 地址决定是否必须成功
    if [ "$has_ipv6_global" = "1" ]; then
        if [ "$ipv6_success" != "true" ]; then
            log_error "接口存在全局 IPv6 地址，但 IPv6 入口重定向配置失败，QoS 无法正常工作"
            tc qdisc del dev "$qos_interface" ingress 2>/dev/null
            return 1
        else
            log_info "IPv6 入口重定向成功（强制）"
        fi
    else
        if [ "$ipv6_success" = "true" ]; then
            log_info "IPv6 入口重定向成功（尽管无全局 IPv6 地址，仍添加了规则）"
        else
            log_warn "所有IPv6重定向规则均失败，IPv6流量将不会通过IFB"
        fi
    fi

    log_info "入口重定向设置完成 (IPv4: ${ipv4_success}, IPv6: ${ipv6_success})"
    return 0
}

# ========== 检查入口重定向 ==========
check_ingress_redirect() {
    log_info "检查入口重定向状态"
    if tc filter show dev "$qos_interface" parent ffff: 2>/dev/null | grep -q "$IFB_DEVICE"; then
        echo "✅ 入口重定向: 已生效"
        return 0
    else
        echo "❌ 入口重定向: 未生效"
        return 1
    fi
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

# ========== 构建CAKE参数串（并记录运行时生效的参数）==========
build_cake_params() {
    local bandwidth="$1"
    local direction="$2"
    local params="bandwidth ${bandwidth}kbit $CAKE_DIFFSERV_MODE"

    [ -n "$CAKE_FLOWMODE" ] && params="$params $CAKE_FLOWMODE"
    [ "$CAKE_OVERHEAD" != "0" ] && params="$params overhead $CAKE_OVERHEAD"
    [ "$CAKE_MPU" != "0" ] && params="$params mpu $CAKE_MPU"
    [ -n "$CAKE_RTT" ] && params="$params rtt $CAKE_RTT"
    [ "$CAKE_ACK_FILTER" = "1" ] && params="$params ack-filter"
    [ "$CAKE_NAT" = "1" ] && params="$params nat"
    [ "$CAKE_WASH" = "1" ] && params="$params wash"
    [ -n "$CAKE_MEMORY_LIMIT" ] && params="$params memlimit $CAKE_MEMORY_LIMIT"

    if [ -n "$CAKE_ECN" ]; then
        if check_cake_param_support "$CAKE_ECN"; then
            params="$params $CAKE_ECN"
        else
            log_warn "内核不支持 $CAKE_ECN 参数，已忽略 ECN 设置"
            CAKE_ECN=""
        fi
    fi

    if [ "$CAKE_SPLIT_GSO" = "1" ]; then
        if check_cake_param_support "split-gso"; then
            params="$params split-gso"
            RUNTIME_SPLIT_GSO=1
        else
            log_warn "内核不支持 split-gso 参数，已禁用"
        fi
    fi

    if [ "$direction" = "download" ] && [ "$CAKE_INGRESS" = "1" ]; then
        if check_cake_param_support "ingress"; then
            params="$params ingress"
            RUNTIME_INGRESS=1
            if [ "$CAKE_AUTORATE_INGRESS" = "1" ]; then
                if check_cake_param_support "autorate-ingress"; then
                    params="$params autorate-ingress"
                    RUNTIME_AUTORATE_INGRESS=1
                else
                    log_warn "内核不支持 autorate-ingress 参数，已禁用"
                fi
            fi
        else
            log_warn "内核不支持 ingress 参数，已禁用 ingress 相关功能"
        fi
    fi

    echo "$params"
}

# ========== 创建CAKE队列（支持多队列）==========
create_cake_root_qdisc() {
    local device="$1"
    local direction="$2"
    local bandwidth="$3"
    local queues=1 use_mq=0 base_bw remainder full_params base_params i queue_bw success=0

    log_info "为$device创建$direction方向CAKE队列 (带宽: ${bandwidth}kbit)"

    if ! validate_cake_parameters "$bandwidth" "bandwidth"; then
        return 1
    fi

    cleanup_existing_queues "$device" "$direction"

    if [ "$CAKE_MQ_ENABLED" = "1" ]; then
        queues=$(get_tx_queues "$device")
        if ! echo "$queues" | grep -qE '^[0-9]+$' || [ "$queues" -lt 1 ]; then
            log_warn "获取到的队列数无效: $queues，使用默认值1"
            queues=1
        fi
        if [ "$queues" -gt 1 ]; then
            use_mq=1
            log_info "设备 $device 支持 $queues 个发送队列，启用 CAKE-MQ"
        else
            log_info "设备 $device 仅单个队列，使用普通 CAKE"
        fi
    else
        log_info "CAKE-MQ 已被禁用，使用普通 CAKE"
    fi

    if [ "$use_mq" = "1" ] && [ "$bandwidth" -lt "$queues" ] 2>/dev/null; then
        log_warn "总带宽 ${bandwidth}kbit 小于队列数 $queues，多队列可能导致部分队列带宽为0，已自动回退到单队列模式。"
        use_mq=0
    fi

    if [ "$use_mq" = "1" ]; then
        base_bw=$(( bandwidth / queues ))
        remainder=$(( bandwidth % queues ))
        if [ "$base_bw" -lt 1 ]; then
            base_bw=1
            remainder=0
            log_warn "带宽分配后基础带宽为0，已调整为1kbit/队列"
        fi
        if [ "$base_bw" -le 5 ] 2>/dev/null; then
            log_warn "带宽分配后每个队列的基础带宽仅为 ${base_bw}kbit，可能导致部分队列性能不佳。建议关闭多队列或增加总带宽。"
        fi
        log_info "带宽分配: 基础 ${base_bw}kbit/队列，余数 ${remainder}kbit 给队列1"

        if ! tc qdisc add dev "$device" root handle 1: mq; then
            log_error "无法在$device上创建 mq 根队列"
            return 1
        fi

        full_params=$(build_cake_params "$bandwidth" "$direction")
        base_params=$(echo "$full_params" | sed 's/bandwidth [0-9]*kbit //')

        i=1
        while [ $i -le $queues ]; do
            queue_bw=$base_bw
            [ $i -eq 1 ] && queue_bw=$((queue_bw + remainder))
            echo "正在为 $device 队列 $i 创建 CAKE 子队列 (带宽: ${queue_bw}kbit)..."
            if ! tc qdisc add dev "$device" parent 1:$i cake bandwidth ${queue_bw}kbit $base_params; then
                log_error "无法在$device队列$i上创建CAKE子队列"
                success=1
                break
            fi
            i=$((i + 1))
        done

        if [ "$success" -ne 0 ]; then
            tc qdisc del dev "$device" root 2>/dev/null
            return 1
        fi

        log_info "$device 的 $direction 方向 CAKE-MQ 队列创建完成 (共 $queues 个队列)"
        echo "✅ $device 的 $direction 方向 CAKE-MQ 队列创建完成 (队列数: $queues)"
    else
        local cake_params=$(build_cake_params "$bandwidth" "$direction")
        echo "正在为 $device 创建普通CAKE队列..."
        echo "  参数: $cake_params"
        if ! tc qdisc add dev "$device" root cake $cake_params; then
            log_error "无法在$device上创建普通CAKE队列"
            return 1
        fi
        log_info "$device 的 $direction 方向普通CAKE队列创建完成"
        echo "✅ $device 的 $direction 方向普通CAKE队列创建完成"
    fi

    return 0
}

# ========== 上传初始化 ==========
initialize_cake_upload() {
    log_info "初始化上传方向CAKE"
    if [ -z "$total_upload_bandwidth" ] || [ "$total_upload_bandwidth" -le 0 ] 2>/dev/null; then
        log_info "上传带宽未配置，跳过上传方向初始化"
        return 0
    fi
    echo "为 $qos_interface 创建上传CAKE队列 (带宽: ${total_upload_bandwidth}kbit/s)"
    create_cake_root_qdisc "$qos_interface" "upload" "$total_upload_bandwidth"
}

# ========== 下载初始化 ==========
initialize_cake_download() {
    log_info "初始化下载方向CAKE"
    local expected_queues=1 current_queues

    if [ -z "$total_download_bandwidth" ] || [ "$total_download_bandwidth" -le 0 ] 2>/dev/null; then
        log_info "下载带宽未配置，跳过下载方向初始化"
        return 0
    fi

    if [ "$CAKE_MQ_ENABLED" = "1" ]; then
        expected_queues=$(get_tx_queues "$qos_interface")
        if ! echo "$expected_queues" | grep -qE '^[0-9]+$' || [ "$expected_queues" -lt 1 ]; then
            log_warn "获取到的期望队列数无效: $expected_queues，使用默认值1"
            expected_queues=1
        fi
    fi

    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        log_info "IFB设备 $IFB_DEVICE 已存在，检查队列数一致性"
        current_queues=$(get_tx_queues "$IFB_DEVICE")
        if ! echo "$current_queues" | grep -qE '^[0-9]+$' || [ "$current_queues" -lt 1 ]; then
            log_warn "获取到的当前队列数无效: $current_queues，将重建IFB设备"
            ip link set dev "$IFB_DEVICE" down
            ip link del "$IFB_DEVICE" 2>/dev/null || {
                log_error "无法删除旧的IFB设备 $IFB_DEVICE"
                return 1
            }
        elif [ "$current_queues" -ne "$expected_queues" ]; then
            log_warn "IFB设备队列数 ($current_queues) 与期望值 ($expected_queues) 不符，将删除并重建"
            ip link set dev "$IFB_DEVICE" down
            ip link del "$IFB_DEVICE" 2>/dev/null || {
                log_error "无法删除旧的IFB设备 $IFB_DEVICE"
                return 1
            }
        else
            log_info "IFB设备队列数一致 ($current_queues)，继续使用"
        fi
    fi

    if ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        log_info "创建IFB设备 $IFB_DEVICE，队列数: $expected_queues"
        if ! ip link add "$IFB_DEVICE" numtxqueues "$expected_queues" numrxqueues "$expected_queues" type ifb; then
            log_error "无法创建IFB设备 $IFB_DEVICE (队列数: $expected_queues)"
            return 1
        fi
    fi

    if ! ip link show dev "$IFB_DEVICE" | grep -q "UP"; then
        ip link set dev "$IFB_DEVICE" up || {
            log_error "无法启动IFB设备 $IFB_DEVICE"
            return 1
        }
    else
        log_info "IFB设备 $IFB_DEVICE 已是 UP 状态"
    fi

    setup_ingress_redirect || return 1
    create_cake_root_qdisc "$IFB_DEVICE" "download" "$total_download_bandwidth"
}

# ========== 健康检查 ==========
health_check_cake() {
    echo "执行CAKE健康检查..."
    local health_score=100 issues=""

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

# ========== 状态显示 ==========
show_cake_status() {
    echo "===== CAKE QoS状态报告 (v5.6-mq) ====="
    echo "时间: $(date)"
    echo "网络接口: ${qos_interface:-未知}"

    load_cake_config

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

    echo -e "\n===== 出口CAKE队列 ($qos_interface) ====="
    if tc qdisc show dev "$qos_interface" root 2>/dev/null | grep -q "cake"; then
        echo "状态: 已启用 ✅"
        local egress_count=$(tc qdisc show dev "$qos_interface" 2>/dev/null | grep -c "qdisc cake")
        if [ "$egress_count" -gt 1 ]; then
            echo "多队列模式: 共 $egress_count 个队列"
        else
            echo "模式: 普通CAKE"
        fi
        echo "队列参数:"
        tc qdisc show dev "$qos_interface" root 2>/dev/null | grep "qdisc cake" | sed 's/^qdisc cake //' | sed 's/^/  /'
        echo -e "\nTC队列统计:"
        tc -s qdisc show dev "$qos_interface" root 2>/dev/null | sed 's/^/  /'
    else
        echo "状态: 未启用 ❌"
    fi

    echo -e "\n===== 入口CAKE队列 ($IFB_DEVICE) ====="
    if ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
        if tc qdisc show dev "$IFB_DEVICE" root 2>/dev/null | grep -q "cake"; then
            echo "状态: 已启用 ✅"
            local ingress_count=$(tc qdisc show dev "$IFB_DEVICE" 2>/dev/null | grep -c "qdisc cake")
            if [ "$ingress_count" -gt 1 ]; then
                echo "多队列模式: 共 $ingress_count 个队列"
            else
                echo "模式: 普通CAKE"
            fi
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

    echo -e "\n===== 入口重定向检查 ====="
    if tc filter show dev "$qos_interface" parent ffff: 2>/dev/null | grep -q "$IFB_DEVICE"; then
        echo "✅ 入口重定向: 已生效"
    else
        echo "❌ 入口重定向: 未生效"
    fi
    if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "ingress"; then
        echo "入口队列状态: 已配置"
        tc filter show dev "$qos_interface" parent ffff: 2>/dev/null | sed 's/^/  /' || echo "  无过滤器规则"
    else
        echo "入口队列状态: 未配置"
    fi

    echo -e "\n===== CAKE配置参数 ====="
    echo "DiffServ模式: $CAKE_DIFFSERV_MODE"
    echo "流模式: ${CAKE_FLOWMODE:-未配置}"
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
    echo "ECN: $([ -n "$CAKE_ECN" ] && echo "$CAKE_ECN" || echo "未配置")"
    echo "自动调优: $([ "$ENABLE_AUTO_TUNE" = "1" ] && echo "启用 ✅" || echo "禁用 ❌")"

    echo -e "\n===== CAKE-MQ 状态报告结束 ====="
    return 0
}

# ========== 停止清理 ==========
stop_cake_qos() {
    log_info "停止CAKE QoS"
    local got_lock=false
    local retry=3

    while [ $retry -gt 0 ]; do
        if acquire_lock 2>/dev/null; then
            got_lock=true
            log_debug "停止时获取锁成功"
            break
        else
            retry=$((retry - 1))
            [ $retry -gt 0 ] && sleep 1
        fi
    done

    if ! $got_lock; then
        log_error "无法获取锁，停止操作退出，请稍后重试"
        return 1
    fi

    if tc qdisc show dev "$qos_interface" root 2>/dev/null | grep -q "cake"; then
        tc qdisc del dev "$qos_interface" root 2>/dev/null && \
            log_info "清理上传方向CAKE队列" || log_warn "上传队列清理可能未完全成功"
    fi

    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        if tc qdisc show dev "$IFB_DEVICE" root 2>/dev/null | grep -q "cake"; then
            tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null && \
                log_info "清理下载方向CAKE队列 (IFB)" || log_warn "下载队列清理可能未完全成功"
        fi
    fi

    tc qdisc del dev "$qos_interface" ingress 2>/dev/null && log_info "清理入口重定向队列" || true

    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link set dev "$IFB_DEVICE" down
        if [ "$CAKE_DELETE_IFB_ON_STOP" = "1" ]; then
            ip link del "$IFB_DEVICE" 2>/dev/null && log_info "删除IFB设备: $IFB_DEVICE"
        else
            log_info "停用IFB设备: $IFB_DEVICE (保留)"
        fi
    fi

    rm -f "$RUNTIME_PARAMS_FILE"
    rm -f "$QOS_RUNNING_FILE"

    release_lock
    log_info "CAKE QoS停止完成"
}

# ========== 锁函数（增强：支持僵尸进程检测）==========
acquire_lock() {
    if [ -d "$LOCK_DIR" ]; then
        if [ -f "$LOCK_PID_FILE" ]; then
            local old_pid=$(cat "$LOCK_PID_FILE" 2>/dev/null)
            local now=$(date +%s)
            local mtime=0
			# 更严谨的检查：直接测试 -c 选项是否能正常工作
			if stat -c %Y /tmp >/dev/null 2>&1; then
				mtime=$(stat -c %Y "$LOCK_PID_FILE" 2>/dev/null || echo 0)
			fi

            # 如果锁文件存在超过120秒，且进程仍在运行（可能僵死），强制清理
            if [ "$mtime" -gt 0 ] && [ $((now - mtime)) -gt 120 ]; then
                log_warn "锁文件过期（超过120秒），进程 $old_pid 可能僵死，强制清理锁目录"
                rm -rf "$LOCK_DIR"
                # 重新尝试获取锁
                acquire_lock
                return $?
            fi

            if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
                if [ "$old_pid" -eq "$$" ]; then
                    log_debug "已持有锁 (PID: $$)"
                    return 0
                fi
                log_error "无法获取锁，进程 $old_pid 仍在运行"
                return 1
            else
                log_warn "发现残留锁目录，进程 $old_pid 已不存在，清理中"
                rm -rf "$LOCK_DIR"
            fi
        else
            log_warn "锁目录 $LOCK_DIR 存在但无PID文件，尝试强制清理"
            rm -rf "$LOCK_DIR" 2>/dev/null
            if [ -d "$LOCK_DIR" ]; then
                log_error "无法清理锁目录 $LOCK_DIR"
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
initialize_cake_qos() {
    local action="$1"

    case "$action" in
        start)
            log_info "启动CAKE QoS"
            check_dependencies || exit 1
            acquire_lock || exit 1
            check_already_running || { release_lock; exit 1; }

            RUNTIME_SPLIT_GSO=0
            RUNTIME_INGRESS=0
            RUNTIME_AUTORATE_INGRESS=0

            load_cake_config

            total_upload_bandwidth=$(convert_bandwidth_to_kbit "$total_upload_bandwidth") || {
                release_lock
                rm -f "$QOS_RUNNING_FILE"
                exit 1
            }
            total_download_bandwidth=$(convert_bandwidth_to_kbit "$total_download_bandwidth") || {
                release_lock
                rm -f "$QOS_RUNNING_FILE"
                exit 1
            }

            [ "$ENABLE_AUTO_TUNE" = "1" ] && auto_tune_cake
            validate_cake_config || {
                release_lock
                rm -f "$QOS_RUNNING_FILE"
                exit 1
            }

            local upload_success=0 download_success=0
            initialize_cake_upload || upload_success=1
            initialize_cake_download || download_success=1

            if [ $upload_success -eq 1 ] || [ $download_success -eq 1 ]; then
                log_error "CAKE QoS 初始化部分失败"
                stop_cake_qos
                release_lock
                rm -f "$QOS_RUNNING_FILE"
                exit 1
            fi

            if [ "$total_download_bandwidth" -gt 0 ] 2>/dev/null; then
                check_ingress_redirect
            fi

            {
                echo "CAKE_RTT='$CAKE_RTT'"
                echo "CAKE_MEMORY_LIMIT='$CAKE_MEMORY_LIMIT'"
                echo "RUNTIME_SPLIT_GSO='$RUNTIME_SPLIT_GSO'"
                echo "RUNTIME_INGRESS='$RUNTIME_INGRESS'"
                echo "RUNTIME_AUTORATE_INGRESS='$RUNTIME_AUTORATE_INGRESS'"
            } > "$RUNTIME_PARAMS_FILE"

            health_check_cake
            log_info "CAKE QoS 启动成功"
            release_lock
            return 0
            ;;

        stop)
            log_info "停止CAKE QoS"
            stop_cake_qos || exit 1
            ;;

        restart)
            log_info "重启CAKE QoS"
            stop_cake_qos
            sleep 2
            initialize_cake_qos start
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
            echo ""
            echo "命令:"
            echo "  start    启动CAKE QoS"
            echo "  stop     停止CAKE QoS"
            echo "  restart  重启CAKE QoS"
            echo "  status   显示CAKE状态"
            echo "  health   执行健康检查"
            echo "  validate 验证CAKE配置"
            echo "  help     显示此帮助信息"
            ;;

        *)
            echo "错误: 未知操作 '$action'"
            echo ""
            initialize_cake_qos "help"
            exit 1
            ;;
    esac
}

if [ "$(basename "$0")" = "cake.sh" ]; then
    if [ $# -eq 0 ]; then
        echo "错误: 缺少参数"
        echo ""
        initialize_cake_qos "help"
        exit 1
    fi
    initialize_cake_qos "$@"
fi

log_info "CAKE模块加载完成"