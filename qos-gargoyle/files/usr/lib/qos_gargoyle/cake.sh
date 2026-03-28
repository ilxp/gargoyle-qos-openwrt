#!/bin/bash
# CAKE算法实现模块 - 多队列增强版
# 版本: 3.5.1 - 修复多队列带宽分配、CAKE参数检测清理、SFO检测警告、全局常量统一
# 支持与 idclass 集成，通过 DSCP 进行分类（diffserv4 模式）
# 必要工具：tc, nft, conntrack, ethtool, sysctl
# 内核模块：sch_cake

# ========== 变量初始化 ==========
: ${IFB_DEVICE:=ifb0}
: ${qos_interface:=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)}
: ${qos_interface:=pppoe-wan}

# 加载规则辅助模块（必须）
if [ -f "/usr/lib/qos_gargoyle/rule.sh" ]; then
    . /usr/lib/qos_gargoyle/rule.sh
    qos_log() { log "$@"; }
else
    echo "错误: 规则辅助模块 /usr/lib/qos_gargoyle/rule.sh 未找到" >&2
    exit 1
fi

# 设置退出时清理临时文件
trap cleanup_temp_files EXIT INT TERM HUP QUIT

# 确保全局变量定义（避免未定义）
CLASS_MARKS_FILE="${CLASS_MARKS_FILE:-/etc/qos_gargoyle/class_marks}"
RUNTIME_PARAMS_FILE="${RUNTIME_PARAMS_FILE:-/tmp/cake_runtime_params}"

# 掩码变量（CAKE 模式下未使用，但 rule.sh 需要）
UPLOAD_MASK=0xFFFF
DOWNLOAD_MASK=0xFFFF0000

echo "CAKE 模块初始化完成"
echo "  网络接口: $qos_interface"
echo "  IFB 设备: $IFB_DEVICE"
echo "  上传带宽: ${total_upload_bandwidth:-未配置}kbit/s"
echo "  下载带宽: ${total_download_bandwidth:-未配置}kbit/s"

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

# ========== 辅助函数 ==========

# 参数消毒
sanitize_param() {
    echo "$1" | sed 's/[^a-zA-Z0-9_./:-]//g'
}

# ========== 依赖检查 ==========
check_dependencies() {
    if ! command -v tc >/dev/null 2>&1; then
        qos_log "ERROR" "tc 命令未找到，请安装 iproute2"
        return 1
    fi
    if ! command -v ip >/dev/null 2>&1; then
        qos_log "ERROR" "ip 命令未找到，请安装 iproute2"
        return 1
    fi
    if ! command -v uci >/dev/null 2>&1; then
        qos_log "ERROR" "uci 命令未找到，请安装 uci"
        return 1
    fi
    if ! command -v ethtool >/dev/null 2>&1; then
        qos_log "WARN" "ethtool 命令未找到，队列数检测将回退到 sysfs"
    fi
    return 0
}

# ========== 参数验证 ==========
validate_cake_parameters() {
    local param_value="$1"
    local param_name="$2"
    local num unit ms mb

    case "$param_name" in
        bandwidth)
            if ! echo "$param_value" | grep -qE '^[0-9]+$'; then
                qos_log "ERROR" "无效的带宽值 (必须是数字): $1"
                return 1
            fi
            if [ "$param_value" -lt 8 ] 2>/dev/null; then
                qos_log "WARN" "带宽过小: ${param_value}kbit (建议至少8kbit)"
            fi
            if [ "$param_value" -gt 10000000 ] 2>/dev/null; then
                qos_log "WARN" "带宽过大: ${param_value}kbit (超过10Gbit)"
            fi
            ;;

        rtt)
            if [ -n "$param_value" ] && ! echo "$param_value" | grep -qiE '^[0-9]*\.?[0-9]+(us|ms|s)$'; then
                qos_log "WARN" "无效的RTT格式: $param_value (应为数字+单位: us/ms/s)"
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
                    qos_log "WARN" "RTT值过大 (>10秒): $param_value"
                elif [ -n "$ms" ] && [ "$ms" -lt 1 ] 2>/dev/null && [ "$ms" != "0" ]; then
                    qos_log "WARN" "RTT值过小 (<1ms): $param_value"
                fi
            fi
            ;;

        memory_limit)
            if [ -n "$param_value" ] && ! echo "$param_value" | grep -qiE '^[0-9]+(b|kb|mb|gb)$'; then
                qos_log "WARN" "无效的内存限制格式: $param_value"
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
                    qos_log "WARN" "内存限制过大 (>512MB): $param_value"
                elif [ "$mb" -lt 1 ] 2>/dev/null && [ "$mb" -ne 0 ]; then
                    qos_log "WARN" "内存限制过小 (<1MB): $param_value"
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
    qos_log "WARN" "无效的DiffServ模式: $mode，使用默认值diffserv4"
    return 1
}

# ========== 获取设备发送队列数（增强版）==========
get_tx_queues() {
    local dev="$1"
    local queues=1
    local ethtool_out

    if ! ip link show dev "$dev" >/dev/null 2>&1; then
        qos_log "WARN" "设备 $dev 不存在，返回默认队列数 1"
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
            qos_log "DEBUG" "ethtool (current) 获取 $dev 队列数: $queues"
            echo "$queues"
            return
        fi
        ethtool_out=$(ethtool -l "$dev" 2>/dev/null | grep "Combined:" | tail -1 | awk '{print $2}')
        if [ -n "$ethtool_out" ] && [ "$ethtool_out" -gt 0 ] 2>/dev/null; then
            queues=$ethtool_out
            qos_log "DEBUG" "ethtool (fallback) 获取 $dev 队列数: $queues"
            echo "$queues"
            return
        fi
    fi

    if [ -d "/sys/class/net/$dev/queues" ]; then
        queues=$(ls -d /sys/class/net/$dev/queues/tx-* 2>/dev/null | wc -l)
        qos_log "DEBUG" "sysfs 获取 $dev 队列数: $queues"
    fi

    if [ -z "$queues" ] || [ "$queues" -eq 0 ] 2>/dev/null; then
        queues=1
    fi

    echo "$queues"
}

# ========== 配置加载 ==========
load_cake_config() {
    qos_log "INFO" "加载CAKE配置"
    local uci_ifb val

    uci_ifb=$(uci -q get ${CONFIG_FILE}.download.ifb_device 2>/dev/null)
    [ -n "$uci_ifb" ] && IFB_DEVICE=$(sanitize_param "$uci_ifb")

    val=$(uci -q get ${CONFIG_FILE}.cake.diffserv_mode 2>/dev/null)
    CAKE_DIFFSERV_MODE=$(sanitize_param "${val:-diffserv4}")

    val=$(uci -q get ${CONFIG_FILE}.cake.flowmode 2>/dev/null)
    [ -n "$val" ] && CAKE_FLOWMODE=$(sanitize_param "$val")

    val=$(uci -q get ${CONFIG_FILE}.cake.overhead 2>/dev/null)
    CAKE_OVERHEAD=$(sanitize_param "${val:-0}")

    val=$(uci -q get ${CONFIG_FILE}.cake.mpu 2>/dev/null)
    CAKE_MPU=$(sanitize_param "${val:-0}")

    val=$(uci -q get ${CONFIG_FILE}.cake.rtt 2>/dev/null)
    [ -n "$val" ] && CAKE_RTT=$(sanitize_param "$val")

    val=$(uci -q get ${CONFIG_FILE}.cake.ack_filter 2>/dev/null)
    CAKE_ACK_FILTER=$(sanitize_param "${val:-0}")

    val=$(uci -q get ${CONFIG_FILE}.cake.nat 2>/dev/null)
    CAKE_NAT=$(sanitize_param "${val:-0}")

    val=$(uci -q get ${CONFIG_FILE}.cake.wash 2>/dev/null)
    CAKE_WASH=$(sanitize_param "${val:-0}")

    val=$(uci -q get ${CONFIG_FILE}.cake.split_gso 2>/dev/null)
    CAKE_SPLIT_GSO=$(sanitize_param "${val:-0}")

    val=$(uci -q get ${CONFIG_FILE}.cake.ingress 2>/dev/null)
    CAKE_INGRESS=$(sanitize_param "${val:-0}")

    val=$(uci -q get ${CONFIG_FILE}.cake.autorate_ingress 2>/dev/null)
    CAKE_AUTORATE_INGRESS=$(sanitize_param "${val:-0}")

    val=$(uci -q get ${CONFIG_FILE}.cake.memlimit 2>/dev/null)
    if [ -n "$val" ]; then
        CAKE_MEMORY_LIMIT=$(calculate_memory_limit "$val")
    else
        CAKE_MEMORY_LIMIT="32mb"
    fi

    val=$(uci -q get ${CONFIG_FILE}.cake.ecn 2>/dev/null)
    if [ -n "$val" ]; then
        case "$val" in
            yes|1|enable|on|true|ecn)
                CAKE_ECN="ecn"
                qos_log "INFO" "CAKE ECN 已启用"
                ;;
            no|0|disable|off|false|noecn)
                CAKE_ECN="noecn"
                qos_log "INFO" "CAKE ECN 已禁用"
                ;;
            *)
                qos_log "WARN" "无效的 ECN 配置值 '$val'，将忽略"
                CAKE_ECN=""
                ;;
        esac
    fi

    val=$(uci -q get ${CONFIG_FILE}.cake.enable_auto_tune 2>/dev/null)
    [ -n "$val" ] && ENABLE_AUTO_TUNE=$(sanitize_param "$val")

    val=$(uci -q get ${CONFIG_FILE}.cake.enable_mq 2>/dev/null)
    [ -n "$val" ] && CAKE_MQ_ENABLED=$(sanitize_param "$val")

    val=$(uci -q get ${CONFIG_FILE}.cake.delete_ifb_on_stop 2>/dev/null)
    [ -n "$val" ] && CAKE_DELETE_IFB_ON_STOP=$(sanitize_param "$val")

    qos_log "INFO" "CAKE配置加载完成"
}

# ========== 自动调优 ==========
auto_tune_cake() {
    qos_log "INFO" "自动调整CAKE参数"
    local total_bw=0
    local user_set_rtt user_set_mem

    user_set_rtt=$(uci -q get ${CONFIG_FILE}.cake.rtt 2>/dev/null)
    user_set_mem=$(uci -q get ${CONFIG_FILE}.cake.memlimit 2>/dev/null)

    if [ "$total_upload_bandwidth" -gt 0 ] && [ "$total_download_bandwidth" -gt 0 ]; then
        total_bw=$((total_upload_bandwidth + total_download_bandwidth))
    elif [ "$total_upload_bandwidth" -gt 0 ]; then
        total_bw=$total_upload_bandwidth
    elif [ "$total_download_bandwidth" -gt 0 ]; then
        total_bw=$total_download_bandwidth
    fi

    if [ -z "$user_set_mem" ]; then
        if [ "$total_bw" -gt 200000 ]; then
            CAKE_MEMORY_LIMIT="128mb"
        elif [ "$total_bw" -gt 100000 ]; then
            CAKE_MEMORY_LIMIT="64mb"
        elif [ "$total_bw" -gt 50000 ]; then
            CAKE_MEMORY_LIMIT="32mb"
        elif [ "$total_bw" -gt 10000 ]; then
            CAKE_MEMORY_LIMIT="16mb"
        else
            CAKE_MEMORY_LIMIT="8mb"
        fi
        qos_log "INFO" "自动调整 memlimit=${CAKE_MEMORY_LIMIT}"
    fi

    if [ -z "$user_set_rtt" ]; then
        if [ "$total_bw" -gt 200000 ]; then
            CAKE_RTT="20ms"
        elif [ "$total_bw" -gt 100000 ]; then
            CAKE_RTT="50ms"
        elif [ "$total_bw" -gt 50000 ]; then
            CAKE_RTT="100ms"
        elif [ "$total_bw" -gt 10000 ]; then
            CAKE_RTT="150ms"
        else
            CAKE_RTT="200ms"
        fi
        qos_log "INFO" "自动调整 rtt=${CAKE_RTT}"
    fi
}

# ========== 配置验证 ==========
validate_cake_config() {
    qos_log "INFO" "验证CAKE配置..."

    if [ -z "$qos_interface" ]; then
        qos_log "ERROR" "缺少必要变量: qos_interface"
        return 1
    fi
    if ! ip link show dev "$qos_interface" >/dev/null 2>&1; then
        qos_log "ERROR" "接口 $qos_interface 不存在"
        return 1
    fi

    if [ "$total_upload_bandwidth" -le 0 ] 2>/dev/null; then
        qos_log "WARN" "上传带宽未配置或为0，跳过上传方向"
    else
        validate_cake_parameters "$total_upload_bandwidth" "bandwidth" || return 1
    fi

    if [ "$total_download_bandwidth" -le 0 ] 2>/dev/null; then
        qos_log "WARN" "下载带宽未配置或为0，跳过下载方向"
    else
        validate_cake_parameters "$total_download_bandwidth" "bandwidth" || return 1
    fi

    validate_diffserv_mode "$CAKE_DIFFSERV_MODE" || CAKE_DIFFSERV_MODE="diffserv4"
    validate_cake_parameters "$CAKE_RTT" "rtt" || return 1
    validate_cake_parameters "$CAKE_MEMORY_LIMIT" "memory_limit" || return 1

    qos_log "INFO" "✅ CAKE配置验证通过"
    return 0
}

# ========== 清理队列 ==========
cleanup_existing_queues() {
    local device="$1"
    local direction="$2"

    qos_log "INFO" "清理$device上的现有$direction队列"

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

# ========== 构建CAKE参数串 ==========
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
            qos_log "WARN" "内核不支持 $CAKE_ECN 参数，已忽略 ECN 设置"
            CAKE_ECN=""
        fi
    fi

    if [ "$CAKE_SPLIT_GSO" = "1" ]; then
        if check_cake_param_support "split-gso"; then
            params="$params split-gso"
            RUNTIME_SPLIT_GSO=1
        else
            qos_log "WARN" "内核不支持 split-gso 参数，已禁用"
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
                    qos_log "WARN" "内核不支持 autorate-ingress 参数，已禁用"
                fi
            fi
        else
            qos_log "WARN" "内核不支持 ingress 参数，已禁用 ingress 相关功能"
        fi
    fi

    echo "$params"
}

# ========== 创建CAKE队列（支持多队列，修复带宽分配） ==========
create_cake_root_qdisc() {
    local device="$1"
    local direction="$2"
    local bandwidth="$3"
    local queues=1 use_mq=0 base_bw remainder full_params base_params i queue_bw success=0

    qos_log "INFO" "为$device创建$direction方向CAKE队列 (带宽: ${bandwidth}kbit)"

    if ! validate_cake_parameters "$bandwidth" "bandwidth"; then
        return 1
    fi

    cleanup_existing_queues "$device" "$direction"

    if [ "$CAKE_MQ_ENABLED" = "1" ]; then
        queues=$(get_tx_queues "$device")
        if ! echo "$queues" | grep -qE '^[0-9]+$' || [ "$queues" -lt 1 ]; then
            qos_log "WARN" "获取到的队列数无效: $queues，使用默认值1"
            queues=1
        fi
        if [ "$queues" -gt 1 ]; then
            use_mq=1
            qos_log "INFO" "设备 $device 支持 $queues 个发送队列，启用 CAKE-MQ"
        else
            qos_log "INFO" "设备 $device 仅单个队列，使用普通 CAKE"
        fi
    else
        qos_log "INFO" "CAKE-MQ 已被禁用，使用普通 CAKE"
    fi

    # 修复：当带宽小于队列数时强制回退到单队列模式，并明确重置变量
    if [ "$use_mq" = "1" ] && [ "$bandwidth" -lt "$queues" ] 2>/dev/null; then
        qos_log "WARN" "总带宽 ${bandwidth}kbit 小于队列数 ${queues}，强制使用单队列模式"
        use_mq=0
        queues=1
        qos_log "INFO" "已回退至普通 CAKE 模式，队列数重置为 $queues"
    fi

    if [ "$use_mq" = "1" ]; then
        base_bw=$(( bandwidth / queues ))
        remainder=$(( bandwidth % queues ))
        if [ "$base_bw" -lt 1 ]; then
            base_bw=1
            remainder=0
            qos_log "WARN" "带宽分配后基础带宽为0，已调整为1kbit/队列"
        fi
        if [ "$base_bw" -le 5 ] 2>/dev/null; then
            qos_log "WARN" "带宽分配后每个队列的基础带宽仅为 ${base_bw}kbit，可能导致部分队列性能不佳。建议关闭多队列或增加总带宽。"
        fi
        qos_log "INFO" "带宽分配: 基础 ${base_bw}kbit/队列，余数 ${remainder}kbit 给队列1"

        if ! tc qdisc add dev "$device" root handle 1: mq; then
            qos_log "ERROR" "无法在$device上创建 mq 根队列"
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
                qos_log "ERROR" "无法在$device队列$i上创建CAKE子队列"
                success=1
                break
            fi
            i=$((i + 1))
        done

        if [ "$success" -ne 0 ]; then
            tc qdisc del dev "$device" root 2>/dev/null
            return 1
        fi

        qos_log "INFO" "$device 的 $direction 方向 CAKE-MQ 队列创建完成 (共 $queues 个队列)"
        echo "✅ $device 的 $direction 方向 CAKE-MQ 队列创建完成 (队列数: $queues)"
    else
        local cake_params=$(build_cake_params "$bandwidth" "$direction")
        echo "正在为 $device 创建普通CAKE队列..."
        echo "  参数: $cake_params"
        if ! tc qdisc add dev "$device" root cake $cake_params; then
            qos_log "ERROR" "无法在$device上创建普通CAKE队列"
            return 1
        fi
        qos_log "INFO" "$device 的 $direction 方向普通CAKE队列创建完成"
        echo "✅ $device 的 $direction 方向普通CAKE队列创建完成"
    fi
	
	# 上传方向的 ctinfo 规则（仅当方向为 upload 时）
    if [[ "$direction" == "upload" ]]; then
        if ! setup_egress_ctinfo "$device"; then
            qos_log "WARN" "出口方向 ctinfo 设置失败，SFO 下 QoS 可能不完整"
        fi
    fi

    return 0
}

# ========== 上传初始化 ==========
init_cake_upload() {
    qos_log "INFO" "初始化上传方向CAKE"
    if [ -z "$total_upload_bandwidth" ] || [ "$total_upload_bandwidth" -le 0 ] 2>/dev/null; then
        qos_log "INFO" "上传带宽未配置，跳过上传方向初始化"
        return 0
    fi
    echo "为 $qos_interface 创建上传CAKE队列 (带宽: ${total_upload_bandwidth}kbit/s)"
    create_cake_root_qdisc "$qos_interface" "upload" "$total_upload_bandwidth"
}

# ========== 下载初始化 ==========
init_cake_download() {
    qos_log "INFO" "初始化下载方向CAKE"
    local expected_queues=1 current_queues actual_queues

    if [ -z "$total_download_bandwidth" ] || [ "$total_download_bandwidth" -le 0 ] 2>/dev/null; then
        qos_log "INFO" "下载带宽未配置，跳过下载方向初始化"
        return 0
    fi

    if [ "$CAKE_MQ_ENABLED" = "1" ]; then
        expected_queues=$(get_tx_queues "$qos_interface")
        if ! echo "$expected_queues" | grep -qE '^[0-9]+$' || [ "$expected_queues" -lt 1 ]; then
            qos_log "WARN" "获取到的期望队列数无效: $expected_queues，使用默认值1"
            expected_queues=1
        fi
    fi

    # IFB 设备管理
    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        qos_log "INFO" "IFB设备 $IFB_DEVICE 已存在，检查队列数一致性"
        current_queues=$(get_tx_queues "$IFB_DEVICE")
        if ! echo "$current_queues" | grep -qE '^[0-9]+$' || [ "$current_queues" -lt 1 ]; then
            qos_log "WARN" "获取到的当前队列数无效: $current_queues，将重建IFB设备"
            ip link set dev "$IFB_DEVICE" down
            ip link del "$IFB_DEVICE" 2>/dev/null || {
                qos_log "ERROR" "无法删除旧的IFB设备 $IFB_DEVICE"
                return 1
            }
        elif [ "$current_queues" -ne "$expected_queues" ]; then
            qos_log "WARN" "IFB设备队列数 ($current_queues) 与期望值 ($expected_queues) 不符，将删除并重建"
            ip link set dev "$IFB_DEVICE" down
            ip link del "$IFB_DEVICE" 2>/dev/null || {
                qos_log "ERROR" "无法删除旧的IFB设备 $IFB_DEVICE"
                return 1
            }
        else
            qos_log "INFO" "IFB设备队列数一致 ($current_queues)，继续使用"
        fi
    fi

    if ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        qos_log "INFO" "创建IFB设备 $IFB_DEVICE，期望队列数: $expected_queues"
        if ! ip link add "$IFB_DEVICE" numtxqueues "$expected_queues" numrxqueues "$expected_queues" type ifb 2>/dev/null; then
            qos_log "WARN" "无法使用 numtxqueues 参数创建 IFB 设备，尝试普通创建"
            if ! ip link add "$IFB_DEVICE" type ifb 2>/dev/null; then
                qos_log "ERROR" "无法创建IFB设备 $IFB_DEVICE"
                return 1
            fi
            qos_log "WARN" "由于 IFB 创建时无法设置队列数，将禁用多队列模式"
            CAKE_MQ_ENABLED="0"
            actual_queues=$(get_tx_queues "$IFB_DEVICE")
            if [ "$actual_queues" -lt "$expected_queues" ]; then
                qos_log "WARN" "IFB设备实际队列数 ($actual_queues) 小于期望 ($expected_queues)，多队列功能已禁用"
            fi
        else
            qos_log "INFO" "IFB设备创建成功，队列数: $expected_queues"
        fi
    fi

    if ! ip link set dev "$IFB_DEVICE" up; then
        qos_log "ERROR" "无法启动IFB设备 $IFB_DEVICE"
        return 1
    fi
    if ! ip link show dev "$IFB_DEVICE" | grep -q "UP"; then
        qos_log "ERROR" "IFB设备 $IFB_DEVICE 未成功进入 UP 状态"
        return 1
    fi
    qos_log "INFO" "IFB设备 $IFB_DEVICE 已启动"

    if ! setup_ingress_redirect; then
        qos_log "ERROR" "入口重定向设置失败"
        return 1
    fi
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
    echo "===== CAKE QoS状态报告 （$QOS_VERSION） ====="
    echo "时间: $(date)"
    echo "网络接口: ${qos_interface:-未知}"

    load_cake_config

    if [ -f "$RUNTIME_PARAMS_FILE" ]; then
        . "$RUNTIME_PARAMS_FILE"
        qos_log "DEBUG" "使用运行时参数: RTT=$CAKE_RTT, MEM=$CAKE_MEMORY_LIMIT"
    else
        qos_log "DEBUG" "无运行时参数文件，使用UCI配置"
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

    if command -v conntrack >/dev/null 2>&1; then
        echo -e "\n===== conntrack 标记示例 (最近5条) ====="
        conntrack -L 2>/dev/null | grep -E "mark=[1-9][0-9]*" | head -n 10 | while IFS= read -r line; do
            proto=$(echo "$line" | awk '{print $1}')
            src=$(echo "$line" | awk '{print $4}' | cut -d= -f2)
            dst=$(echo "$line" | awk '{print $6}' | cut -d= -f2)
            sport=$(echo "$line" | awk '{print $5}' | cut -d= -f2)
            dport=$(echo "$line" | awk '{print $7}' | cut -d= -f2)
            mark=$(echo "$line" | grep -o "mark=[0-9]\+" | cut -d= -f2)
            dscp=$((mark & 0x3F))
            case $dscp in
                0) class="CS0/BE" ;;
                8) class="CS1" ;;
                10) class="AF11" ;;
                12) class="AF12" ;;
                14) class="AF13" ;;
                16) class="CS2" ;;
                18) class="AF21" ;;
                20) class="AF22" ;;
                22) class="AF23" ;;
                24) class="CS3" ;;
                26) class="AF31" ;;
                28) class="AF32" ;;
                30) class="AF33" ;;
                32) class="CS4" ;;
                34) class="AF41" ;;
                36) class="AF42" ;;
                38) class="AF43" ;;
                40) class="CS5" ;;
                44) class="VA" ;;
                46) class="EF" ;;
                48) class="CS6" ;;
                56) class="CS7" ;;
                *) class="Unknown" ;;
            esac
            printf "  %-5s %-30s:%-5s → %-30s:%-5s [mark=%-6s dscp=%2d (%s)]\n" \
                "$proto" "${src:-N/A}" "${sport:-N/A}" "${dst:-N/A}" "${dport:-N/A}" "$mark" "$dscp" "$class"
        done
    else
        echo "  conntrack 工具未安装，无法显示连接标记"
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
    qos_log "INFO" "停止CAKE QoS"

    if tc qdisc show dev "$qos_interface" root 2>/dev/null | grep -q "cake"; then
        tc qdisc del dev "$qos_interface" root 2>/dev/null && \
            qos_log "INFO" "清理上传方向CAKE队列" || qos_log "WARN" "上传队列清理可能未完全成功"
    fi

    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        if tc qdisc show dev "$IFB_DEVICE" root 2>/dev/null | grep -q "cake"; then
            tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null && \
                qos_log "INFO" "清理下载方向CAKE队列 (IFB)" || qos_log "WARN" "下载队列清理可能未完全成功"
        fi
    fi

    tc qdisc del dev "$qos_interface" ingress 2>/dev/null && qos_log "INFO" "清理入口重定向队列" || true

    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link set dev "$IFB_DEVICE" down
        if [ "$CAKE_DELETE_IFB_ON_STOP" = "1" ]; then
            ip link del "$IFB_DEVICE" 2>/dev/null && qos_log "INFO" "删除IFB设备: $IFB_DEVICE"
        else
            qos_log "INFO" "停用IFB设备: $IFB_DEVICE (保留)"
        fi
    fi

    rm -f "$RUNTIME_PARAMS_FILE"
    rm -f "$QOS_RUNNING_FILE"

    cleanup_qos_state
    cleanup_dynamic_detection
    restore_main_config

    qos_log "INFO" "CAKE QoS停止完成"
}

# ========== 主函数 ==========
init_cake_qos() {
    local action="$1"

    case "$action" in
        start)
            qos_log "INFO" "启动CAKE QoS"
            
            # 检测 SFO 并警告（修复10）
            if check_sfo_enabled; then
                qos_log "WARN" "检测到软件/硬件流加速已启用，QoS标记可能被绕过"
                qos_log "WARN" "建议禁用流加速以获得完整QoS功能:"
                qos_log "WARN" "  uci set firewall.@defaults[0].flow_offloading=0"
                qos_log "WARN" "  uci set firewall.@defaults[0].flow_offloading_hw=0"
                qos_log "WARN" "  uci commit firewall && /etc/init.d/firewall restart"
            fi
            
            check_dependencies || exit 1
            init_ruleset || exit 1

            if ! check_already_running; then
                qos_log "ERROR" "CAKE QoS 已经在运行中"
                exit 1
            fi

            RUNTIME_SPLIT_GSO=0
            RUNTIME_INGRESS=0
            RUNTIME_AUTORATE_INGRESS=0

            load_global_config

            if ! load_bandwidth_from_config; then
                qos_log "ERROR" "加载带宽配置失败"
                rm -f "$QOS_RUNNING_FILE"
                exit 1
            fi

            load_cake_config

            total_upload_bandwidth=$(convert_bandwidth_to_kbit "$total_upload_bandwidth") || {
                rm -f "$QOS_RUNNING_FILE"
                exit 1
            }
            total_download_bandwidth=$(convert_bandwidth_to_kbit "$total_download_bandwidth") || {
                rm -f "$QOS_RUNNING_FILE"
                exit 1
            }

            [ "$ENABLE_AUTO_TUNE" = "1" ] && auto_tune_cake
            validate_cake_config || {
                rm -f "$QOS_RUNNING_FILE"
                exit 1
            }

            load_upload_class_configurations
            load_download_class_configurations

            # ====== 关键修复：分配标记 ======
            if [ -n "$upload_class_list" ]; then
                if ! allocate_class_marks "upload" "$upload_class_list"; then
                    qos_log "ERROR" "上传方向标记分配失败"
                    stop_cake_qos
                    rm -f "$QOS_RUNNING_FILE"
                    exit 1
                fi
            fi
            if [ -n "$download_class_list" ]; then
                if ! allocate_class_marks "download" "$download_class_list"; then
                    qos_log "ERROR" "下载方向标记分配失败"
                    stop_cake_qos
                    rm -f "$QOS_RUNNING_FILE"
                    exit 1
                fi
            fi
            # ====== 标记分配结束 ======

            if [ ! -s "$CLASS_MARKS_FILE" ]; then
                qos_log "ERROR" "Class marks file $CLASS_MARKS_FILE is missing or empty"
                stop_cake_qos
                rm -f "$QOS_RUNNING_FILE"
                exit 1
            fi
            qos_log "INFO" "Using existing class marks file: $CLASS_MARKS_FILE"

            nft add table inet ${NFT_TABLE} 2>/dev/null || true

            nft add map inet ${NFT_TABLE} upload_tcp_dport_map '{ type mark : verdict; flags interval; }' 2>/dev/null || true
            nft add map inet ${NFT_TABLE} upload_udp_dport_map '{ type mark : verdict; flags interval; }' 2>/dev/null || true
            nft add map inet ${NFT_TABLE} download_tcp_sport_map '{ type mark : verdict; flags interval; }' 2>/dev/null || true
            nft add map inet ${NFT_TABLE} download_udp_sport_map '{ type mark : verdict; flags interval; }' 2>/dev/null || true

            if [ -f "$CLASS_MARKS_FILE" ]; then
                for class_name in $(cut -d: -f2 "$CLASS_MARKS_FILE" | sort -u); do
                    realname=$(uci -q get ${CONFIG_FILE}.${class_name}.name 2>/dev/null | tr '[:upper:]' '[:lower:]')
                    [ -z "$realname" ] && continue
                    nft add set inet ${NFT_TABLE} upload_${realname} '{ type ipv4_addr; flags dynamic, timeout; }' 2>/dev/null || true
                    nft add set inet ${NFT_TABLE} upload_${realname}6 '{ type ipv6_addr; flags dynamic, timeout; }' 2>/dev/null || true
                    nft add set inet ${NFT_TABLE} download_${realname} '{ type ipv4_addr; flags dynamic, timeout; }' 2>/dev/null || true
                    nft add set inet ${NFT_TABLE} download_${realname}6 '{ type ipv6_addr; flags dynamic, timeout; }' 2>/dev/null || true
                done
            fi

            if ! apply_all_rules "upload_rule" "$UPLOAD_MASK" "filter_qos_egress"; then
                qos_log "ERROR" "上传规则应用失败"
                stop_cake_qos
                rm -f "$QOS_RUNNING_FILE"
                exit 1
            fi
            if ! apply_all_rules "download_rule" "$DOWNLOAD_MASK" "filter_qos_ingress"; then
                qos_log "ERROR" "下载规则应用失败"
                stop_cake_qos
                rm -f "$QOS_RUNNING_FILE"
                exit 1
            fi

            if ! setup_class_mark_map; then
                qos_log "ERROR" "class_mark 映射设置失败"
                stop_cake_qos
                rm -f "$QOS_RUNNING_FILE"
                exit 1
            fi

            apply_enhanced_features

            echo "应用ipv6特别规则..."
            setup_ipv6_specific_rules

            local upload_success=0 download_success=0
            init_cake_upload || upload_success=1
            init_cake_download || download_success=1

            if [ $upload_success -eq 1 ] || [ $download_success -eq 1 ]; then
                qos_log "ERROR" "CAKE QoS 初始化部分失败"
                stop_cake_qos
                rm -f "$QOS_RUNNING_FILE"
                exit 1
            fi

            if [ "$total_download_bandwidth" -gt 0 ] 2>/dev/null; then
                check_ingress_redirect "$qos_interface" "$IFB_DEVICE"
            fi

            {
                echo "CAKE_RTT='$CAKE_RTT'"
                echo "CAKE_MEMORY_LIMIT='$CAKE_MEMORY_LIMIT'"
                echo "RUNTIME_SPLIT_GSO='$RUNTIME_SPLIT_GSO'"
                echo "RUNTIME_INGRESS='$RUNTIME_INGRESS'"
                echo "RUNTIME_AUTORATE_INGRESS='$RUNTIME_AUTORATE_INGRESS'"
            } > "$RUNTIME_PARAMS_FILE"

            health_check_cake
            qos_log "INFO" "CAKE QoS 启动成功"
            return 0
            ;;

        stop)
            qos_log "INFO" "停止CAKE QoS"
            stop_cake_qos || exit 1
            ;;

        restart)
            qos_log "INFO" "重启CAKE QoS"
            stop_cake_qos
            sleep 2
            init_cake_qos start
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
            init_cake_qos "help"
            exit 1
            ;;
    esac
}

# 确保函数被导出，供主脚本调用
export -f init_cake_qos

# 验证函数是否可用
if type init_cake_qos >/dev/null 2>&1; then
    qos_log "INFO" "✓ init_cake_qos 函数已就绪"
else
    qos_log "ERROR" "✗ init_cake_qos 函数未定义"
fi

if [ "$(basename "$0")" = "cake.sh" ]; then
    if [ $# -eq 0 ]; then
        echo "错误: 缺少参数"
        echo ""
        init_cake_qos "help"
        exit 1
    fi
    init_cake_qos "$@"
fi

qos_log "INFO" "CAKE模块加载完成"