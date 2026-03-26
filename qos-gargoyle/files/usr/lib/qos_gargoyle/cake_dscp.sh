#!/bin/sh
# CAKE_DSCP算法实现模块 - 多队列增强版
# 版本: 2.6.0 - 统一锁机制(flock)，集成 dscpclassify 智能分类，优化入口重定向
# 基于 CAKE 算法，通过 dscpclassify 进行 DSCP 标记，实现 QoS 分类
# 必要工具：tc, nft, conntrack, ethtool, sysctl
# 内核模块：sch_cake, act_ctinfo (用于 DSCP 恢复)

# ========== 变量初始化 ==========
: ${total_upload_bandwidth:=50000}
: ${total_download_bandwidth:=100000}
: ${IFB_DEVICE:=ifb0}
QOS_RUNNING_FILE="/var/run/cake_dscp_qos.running"
RUNTIME_PARAMS_FILE="/tmp/cake_dscp_runtime_params"

# 加载 dscpclassify 核心库（用于智能分类）- 先检查文件是否存在
DSCPCLASSIFY_LIB="/usr/lib/qos_gargoyle/dscpclassify.sh"
if [ ! -f "$DSCPCLASSIFY_LIB" ]; then
    echo "错误: dscpclassify 库文件 $DSCPCLASSIFY_LIB 不存在，请安装 qos-gargoyle-dscpclassify 包"
    exit 1
fi
. "$DSCPCLASSIFY_LIB"

# 如果 qos_interface 未设置，尝试获取
if [ -z "$qos_interface" ]; then
    qos_interface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
    qos_interface="${qos_interface:-pppoe-wan}"
fi

# 加载规则辅助模块（必须）
if [ -f "/usr/lib/qos_gargoyle/rule.sh" ]; then
    . /usr/lib/qos_gargoyle/rule.sh
    qos_log() { log "$@"; }
else
    echo "错误: 规则辅助模块 /usr/lib/qos_gargoyle/rule.sh 未找到" >&2
    exit 1
fi

# 掩码变量（DSCP 模式下未使用，但 rule.sh 需要）
UPLOAD_MASK=0
DOWNLOAD_MASK=0

echo "CAKE_DSCP 模块初始化完成 (v2.6.0)"
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

    if ! lsmod | grep -q act_ctinfo && ! modprobe act_ctinfo 2>/dev/null; then
        qos_log "WARN" "act_ctinfo 内核模块未加载，下载方向 DSCP 恢复可能失败，请安装 kmod-sched-ctinfo"
    fi

    return 0
}

# ========== 带宽单位转换（严格区分字节与比特）==========
convert_bandwidth_to_kbit() {
    local bw="$1"
    local num unit result

    [ -z "$bw" ] && { qos_log "ERROR" "带宽值为空"; return 1; }

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
                qos_log "WARN" "检测到字节单位 '$unit'，将自动乘以 8 转换为 kbit"
                result=$(echo "$num * 8" | awk '{printf "%.0f", $1}')
                ;;
            MB|MIB)
                qos_log "WARN" "检测到字节单位 '$unit'，将自动乘以 8 转换为 kbit"
                result=$(echo "$num * 8000" | awk '{printf "%.0f", $1}')
                ;;
            GB|GIB)
                qos_log "WARN" "检测到字节单位 '$unit'，将自动乘以 8 转换为 kbit"
                result=$(echo "$num * 8000000" | awk '{printf "%.0f", $1}')
                ;;
            *)
                qos_log "ERROR" "未知带宽单位: $unit"
                return 1
                ;;
        esac

        if [ -z "$result" ] || ! echo "$result" | grep -qE '^[0-9]+$' || [ "$result" -lt 0 ] 2>/dev/null; then
            qos_log "ERROR" "带宽转换结果无效: $result"
            return 1
        fi

        echo "$result"
        return 0
    else
        qos_log "ERROR" "无效带宽格式: $bw (应为数字或数字+单位，例如 100mbit、10MB)"
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

# ========== 检测内核是否支持特定 CAKE 参数 ==========
check_cake_param_support() {
    local param="$1"
    # 使用临时 dummy 接口避免影响 lo
    local dummy_dev="dummy0"
    ip link add "$dummy_dev" type dummy 2>/dev/null || {
        dummy_dev="lo"
    }
    tc qdisc del dev "$dummy_dev" root 2>/dev/null
    if tc qdisc add dev "$dummy_dev" root cake bandwidth 1mbit "$param" 2>/dev/null; then
        tc qdisc del dev "$dummy_dev" root 2>/dev/null
        [ "$dummy_dev" != "lo" ] && ip link del "$dummy_dev" 2>/dev/null
        return 0
    else
        [ "$dummy_dev" != "lo" ] && ip link del "$dummy_dev" 2>/dev/null
        return 1
    fi
}

# ========== 配置加载（带消毒）==========
load_cake_config() {
    qos_log "INFO" "加载CAKE配置"
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

    val=$(uci -q get qos_gargoyle.cake.enable_auto_tune 2>/dev/null)
    [ -n "$val" ] && ENABLE_AUTO_TUNE=$(sanitize_param "$val")

    val=$(uci -q get qos_gargoyle.cake.enable_mq 2>/dev/null)
    [ -n "$val" ] && CAKE_MQ_ENABLED=$(sanitize_param "$val")

    val=$(uci -q get qos_gargoyle.cake.delete_ifb_on_stop 2>/dev/null)
    [ -n "$val" ] && CAKE_DELETE_IFB_ON_STOP=$(sanitize_param "$val")

    qos_log "INFO" "CAKE配置加载完成"
}

# ========== 自动调优 ==========
auto_tune_cake() {
    qos_log "INFO" "自动调整CAKE参数"
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
        qos_log "INFO" "自动调整: 超高带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}"
    elif [ "$total_bw" -gt 100000 ]; then
        [ -z "$user_set_mem" ] && CAKE_MEMORY_LIMIT="64mb"
        [ -z "$user_set_rtt" ] && CAKE_RTT="50ms"
        qos_log "INFO" "自动调整: 高带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}"
    elif [ "$total_bw" -gt 50000 ]; then
        [ -z "$user_set_mem" ] && CAKE_MEMORY_LIMIT="32mb"
        [ -z "$user_set_rtt" ] && CAKE_RTT="100ms"
        qos_log "INFO" "自动调整: 中等带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}"
    elif [ "$total_bw" -gt 10000 ]; then
        [ -z "$user_set_mem" ] && CAKE_MEMORY_LIMIT="16mb"
        [ -z "$user_set_rtt" ] && CAKE_RTT="150ms"
        qos_log "INFO" "自动调整: 低带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}"
    else
        [ -z "$user_set_mem" ] && CAKE_MEMORY_LIMIT="8mb"
        [ -z "$user_set_rtt" ] && CAKE_RTT="200ms"
        qos_log "INFO" "自动调整: 极低带宽场景 (${total_bw}kbit) -> memlimit=${CAKE_MEMORY_LIMIT}, rtt=${CAKE_RTT}"
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

# ========== 入口重定向（IPv4必须成功，IPv6三阶尝试，带 ctinfo，并增加全局地址检测）==========
setup_ingress_redirect() {
    qos_log "INFO" "设置入口重定向: $qos_interface -> $IFB_DEVICE"
    local ipv4_success=false
    local ipv6_success=false
    local match_cmd

    tc qdisc del dev "$qos_interface" ingress 2>/dev/null

    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        qos_log "ERROR" "无法在$qos_interface上创建入口队列"
        return 1
    fi

    # IPv4 重定向（带 ctinfo）
    if tc filter add dev "$qos_interface" parent ffff: protocol ip \
        u32 match u32 0 0 \
        action ctinfo dscp 0x3f 0 pipe \
        action mirred egress redirect dev "$IFB_DEVICE" 2>/dev/null; then
        ipv4_success=true
    else
        qos_log "ERROR" "IPv4入口重定向规则添加失败（含 ctinfo）"
        tc qdisc del dev "$qos_interface" ingress 2>/dev/null
        return 1
    fi

    # 检测接口是否有全局 IPv6 地址，以决定是否强制 IPv6 必须成功
    local has_ipv6_global=0
    if ip -6 addr show dev "$qos_interface" scope global 2>/dev/null | grep -q "inet6"; then
        has_ipv6_global=1
        qos_log "INFO" "接口 $qos_interface 拥有全局 IPv6 地址，将强制 IPv6 重定向必须成功"
    else
        qos_log "INFO" "接口 $qos_interface 无全局 IPv6 地址，IPv6 重定向失败仅警告"
    fi

    # IPv6 重定向：按优先级尝试三种匹配方式
    for match_cmd in \
        "flower dst_ip 2000::/3" \
        "u32 match u32 0x20000000 0xe0000000 at 24" \
        "u32 match u32 0 0"; do
        if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
            $match_cmd \
            action ctinfo dscp 0x3f 0 pipe \
            action mirred egress redirect dev "$IFB_DEVICE" 2>/dev/null; then
            ipv6_success=true
            qos_log "INFO" "IPv6入口重定向规则 ($match_cmd + ctinfo) 添加成功"
            break
        else
            qos_log "WARN" "IPv6规则 ($match_cmd + ctinfo) 添加失败"
        fi
    done

    # 根据是否有全局 IPv6 地址决定是否必须成功
    if [ "$has_ipv6_global" = "1" ]; then
        if [ "$ipv6_success" != "true" ]; then
            qos_log "ERROR" "接口存在全局 IPv6 地址，但 IPv6 入口重定向配置失败，QoS 无法正常工作"
            tc qdisc del dev "$qos_interface" ingress 2>/dev/null
            return 1
        else
            qos_log "INFO" "IPv6 入口重定向成功（强制）"
        fi
    else
        if [ "$ipv6_success" = "true" ]; then
            qos_log "INFO" "IPv6 入口重定向成功（尽管无全局 IPv6 地址，仍添加了规则）"
        else
            qos_log "WARN" "所有IPv6重定向规则均失败，IPv6流量将不会通过IFB"
        fi
    fi

    qos_log "INFO" "入口重定向设置完成 (IPv4: ${ipv4_success}, IPv6: ${ipv6_success})"
    return 0
}

# ========== 检查入口重定向 ==========
check_ingress_redirect() {
    qos_log "INFO" "检查入口重定向状态"
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

# ========== 创建CAKE队列（支持多队列）==========
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

    if [ "$use_mq" = "1" ] && [ "$bandwidth" -lt "$queues" ] 2>/dev/null; then
        qos_log "WARN" "总带宽 ${bandwidth}kbit 小于队列数 $queues，多队列可能导致部分队列带宽为0，已自动回退到单队列模式。"
        use_mq=0
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
    local expected_queues=1 current_queues

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
        qos_log "INFO" "创建IFB设备 $IFB_DEVICE，队列数: $expected_queues"
        if ! ip link add "$IFB_DEVICE" numtxqueues "$expected_queues" numrxqueues "$expected_queues" type ifb; then
            qos_log "ERROR" "无法创建IFB设备 $IFB_DEVICE (队列数: $expected_queues)"
            return 1
        fi
    fi

    if ! ip link show dev "$IFB_DEVICE" | grep -q "UP"; then
        ip link set dev "$IFB_DEVICE" up || {
            qos_log "ERROR" "无法启动IFB设备 $IFB_DEVICE"
            return 1
        }
    else
        qos_log "INFO" "IFB设备 $IFB_DEVICE 已是 UP 状态"
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
    echo "===== CAKE_DSCP QoS状态报告 (v2.6.0) ====="
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

    # conntrack 标记显示
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

    echo -e "\n===== CAKE-DSCP 状态报告结束 ====="
    return 0
}

# ========== 停止清理 ==========
stop_cake_qos() {
    qos_log "INFO" "停止CAKE_DSCP QoS"
    # 使用 rule.sh 的统一锁机制（支持嵌套）
    acquire_lock

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

    # 卸载 dscpclassify
    qos_log "INFO" "卸载 dscpclassify 分类规则..."
    dscpclassify_unload

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

    release_lock
    qos_log "INFO" "CAKE_DSCP QoS停止完成"
}

# ========== 主函数 ==========
init_cake_dscp_qos() {
    local action="$1"

    case "$action" in
        start)
            qos_log "INFO" "启动CAKE_DSCP QoS"
            check_dependencies || exit 1
            # 使用 rule.sh 的统一锁机制
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

            # 加载 dscpclassify
            qos_log "INFO" "dscpclassify 正在加载智能分类规则..."
            local lan_iface="br-lan"
            if uci -q get qos_gargoyle.global.lan_interface >/dev/null; then
                lan_iface=$(uci -q get qos_gargoyle.global.lan_interface)
            fi
            if dscpclassify_load "$lan_iface" "$qos_interface"; then
                qos_log "INFO" "dscpclassify 智能分类规则加载成功"
            else
                qos_log "ERROR" "dscpclassify 加载失败"
                release_lock
                rm -f "$QOS_RUNNING_FILE"
                exit 1
            fi

            local upload_success=0 download_success=0
            init_cake_upload || upload_success=1
            init_cake_download || download_success=1

            if [ $upload_success -eq 1 ] || [ $download_success -eq 1 ]; then
                qos_log "ERROR" "CAKE_DSCP QoS 初始化部分失败"
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
            qos_log "INFO" "CAKE_DSCP QoS 启动成功"
            release_lock
            return 0
            ;;

        stop)
            qos_log "INFO" "停止CAKE_DSCP QoS"
            stop_cake_qos || exit 1
            ;;

        restart)
            qos_log "INFO" "重启CAKE_DSCP QoS"
            stop_cake_qos
            sleep 2
            init_cake_dscp_qos start
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
            echo "  start    启动CAKE_DSCP QoS"
            echo "  stop     停止CAKE_DSCP QoS"
            echo "  restart  重启CAKE_DSCP QoS"
            echo "  status   显示CAKE_DSCP状态"
            echo "  health   执行健康检查"
            echo "  validate 验证CAKE配置"
            echo "  help     显示此帮助信息"
            ;;

        *)
            echo "错误: 未知操作 '$action'"
            echo ""
            init_cake_dscp_qos "help"
            exit 1
            ;;
    esac
}

if [ "$(basename "$0")" = "cake_dscp.sh" ]; then
    if [ $# -eq 0 ]; then
        echo "错误: 缺少参数"
        echo ""
        init_cake_dscp_qos "help"
        exit 1
    fi
    init_cake_dscp_qos "$@"
fi

qos_log "INFO" "CAKE_DSCP模块加载完成"