#!/bin/bash
# HFSC_CAKE算法实现模块
# 版本: 3.4.7 - 修复内存限制解析、CAKE带宽忽略、IFB删除控制、RTT验证
# 基于HFSC与CAKE组合算法实现QoS流量控制。

# ========== 全局配置常量 ==========
: ${CONFIG_FILE:=qos_gargoyle}
: ${MAX_PHYSICAL_BANDWIDTH:=10000000}
: ${UPLOAD_MASK:=0xFFFF}
: ${DOWNLOAD_MASK:=0xFFFF0000}
: ${DELETE_IFB_ON_STOP:=0}
: ${DEBUG:=0}

# 全局变量
upload_class_list=""
download_class_list=""
upload_class_mark_list=""
download_class_mark_list=""
qos_interface=""
IFB_DEVICE=""

CLASS_MARKS_FILE="/etc/qos_gargoyle/class_marks"

# 加载规则辅助模块（必须）
if [[ -f "/usr/lib/qos_gargoyle/rule.sh" ]]; then
    . /usr/lib/qos_gargoyle/rule.sh
    qos_log() { log "$@"; }
else
    echo "错误: 规则辅助模块 /usr/lib/qos_gargoyle/rule.sh 未找到" >&2
    exit 1
fi

# 清理函数：仅清理临时文件（锁已由 procd 管理）
main_cleanup() {
    cleanup_temp_files 2>/dev/null
}
trap main_cleanup EXIT INT TERM HUP QUIT

. /lib/functions.sh
. /lib/functions/network.sh
include /lib/network

# ========== 参数消毒 ==========
sanitize_param() {
    echo "$1" | sed 's/[^a-zA-Z0-9_./:-]//g'
}

# ========== HFSC 与 CAKE 专属配置加载 ==========
load_hfsc_cake_config() {
    qos_log "INFO" "加载HFSC与CAKE配置"
    if [[ -z "$total_upload_bandwidth" ]] || [[ -z "$total_download_bandwidth" ]]; then
        qos_log "ERROR" "带宽环境变量未设置，请确保主脚本已正确加载带宽配置"
        return 1
    fi
    qos_log "INFO" "使用主脚本提供的带宽: 上传=${total_upload_bandwidth}kbit, 下载=${total_download_bandwidth}kbit"

    if [[ -n "$IFB_DEVICE" ]]; then
        qos_log "INFO" "使用环境变量 IFB_DEVICE=$IFB_DEVICE"
    else
        IFB_DEVICE=$(uci -q get ${CONFIG_FILE}.download.ifb_device 2>/dev/null)
        [[ -z "$IFB_DEVICE" ]] && IFB_DEVICE="ifb0"
        qos_log "WARN" "IFB设备未通过环境变量传递，从 UCI 读取: $IFB_DEVICE"
    fi

    # 读取 HFSC 参数
    HFSC_LATENCY_MODE=$(uci -q get ${CONFIG_FILE}.hfsc.latency_mode 2>/dev/null)
    HFSC_MINRTT_ENABLED=$(uci -q get ${CONFIG_FILE}.hfsc.minrtt_enabled 2>/dev/null)
    [[ -z "$HFSC_MINRTT_ENABLED" ]] && HFSC_MINRTT_ENABLED=0
    HFSC_MINRTT_DELAY=$(uci -q get ${CONFIG_FILE}.hfsc.minrtt_delay 2>/dev/null)
    [[ -z "$HFSC_MINRTT_DELAY" ]] && HFSC_MINRTT_DELAY="1000us"

    # 验证 MINRTT_DELAY 格式
    if [[ -n "$HFSC_MINRTT_DELAY" ]] && ! echo "$HFSC_MINRTT_DELAY" | grep -qiE '^[0-9]+(us|ms|s)$'; then
        qos_log "WARN" "无效的 minrtt_delay 格式 '$HFSC_MINRTT_DELAY'，使用默认值 1000us"
        HFSC_MINRTT_DELAY="1000us"
    fi

    # 读取 DELETE_IFB_ON_STOP 配置
    local delete_ifb=$(uci -q get ${CONFIG_FILE}.cake.delete_ifb_on_stop 2>/dev/null)
    case "$delete_ifb" in
        1|yes|true|on) DELETE_IFB_ON_STOP=1 ;;
        *) DELETE_IFB_ON_STOP=0 ;;
    esac

    # 强制忽略 CAKE_BANDWIDTH，防止二次整形
    local cake_bw=$(uci -q get ${CONFIG_FILE}.cake.bandwidth 2>/dev/null)
    if [[ -n "$cake_bw" ]]; then
        qos_log "ERROR" "检测到 CAKE_BANDWIDTH 已配置 (值: $cake_bw)，这将导致CAKE二次整形，严重影响HFSC调度性能。已强制忽略该配置，使用HFSC主导整形。"
        # 运行时忽略，不修改UCI
        CAKE_BANDWIDTH=""
    else
        CAKE_BANDWIDTH=""
    fi

    # 读取 CAKE 参数
    CAKE_RTT=$(uci -q get ${CONFIG_FILE}.cake.rtt 2>/dev/null)
    if [[ -n "$CAKE_RTT" ]] && ! echo "$CAKE_RTT" | grep -qiE '^[0-9]+(us|ms|s)$'; then
        qos_log "WARN" "无效的 RTT 格式: $CAKE_RTT，将使用默认值 100ms"
        CAKE_RTT="100ms"
    fi

    CAKE_FLOWMODE=$(uci -q get ${CONFIG_FILE}.cake.flowmode 2>/dev/null)
    [[ -z "$CAKE_FLOWMODE" ]] && CAKE_FLOWMODE="srchost"
    CAKE_DIFFSERV=$(uci -q get ${CONFIG_FILE}.cake.diffserv_mode 2>/dev/null)
    [[ -z "$CAKE_DIFFSERV" ]] && CAKE_DIFFSERV="diffserv4"
    CAKE_NAT=$(uci -q get ${CONFIG_FILE}.cake.nat 2>/dev/null)
    [[ -z "$CAKE_NAT" ]] && CAKE_NAT="1"
    CAKE_WASH=$(uci -q get ${CONFIG_FILE}.cake.wash 2>/dev/null)
    [[ -z "$CAKE_WASH" ]] && CAKE_WASH="1"
    CAKE_OVERHEAD=$(uci -q get ${CONFIG_FILE}.cake.overhead 2>/dev/null)
    CAKE_MPU=$(uci -q get ${CONFIG_FILE}.cake.mpu 2>/dev/null)
    CAKE_ACK_FILTER=$(uci -q get ${CONFIG_FILE}.cake.ack_filter 2>/dev/null)
    [[ -z "$CAKE_ACK_FILTER" ]] && CAKE_ACK_FILTER="0"
    CAKE_SPLIT_GSO=$(uci -q get ${CONFIG_FILE}.cake.split_gso 2>/dev/null)
    [[ -z "$CAKE_SPLIT_GSO" ]] && CAKE_SPLIT_GSO="0"
    CAKE_MEMLIMIT=$(uci -q get ${CONFIG_FILE}.cake.memlimit 2>/dev/null)
    if [[ -n "$CAKE_MEMLIMIT" ]]; then
        CAKE_MEMLIMIT=$(calculate_memory_limit "$CAKE_MEMLIMIT")
    fi
    CAKE_ECN=$(uci -q get ${CONFIG_FILE}.cake.ecn 2>/dev/null)
    if [[ -n "$CAKE_ECN" ]]; then
        case "$CAKE_ECN" in
            yes|1|enable|on|true|ecn) CAKE_ECN="ecn"; qos_log "INFO" "CAKE ECN 已启用" ;;
            no|0|disable|off|false|noecn) CAKE_ECN=""; qos_log "INFO" "CAKE ECN 已禁用" ;;
            *) qos_log "WARN" "无效的 ECN 配置值 '$CAKE_ECN'，将禁用 ECN"; CAKE_ECN="" ;;
        esac
    else
        CAKE_ECN=""
        qos_log "INFO" "CAKE ECN 未配置，使用默认禁用"
    fi

    qos_log "INFO" "HFSC配置: latency_mode=${HFSC_LATENCY_MODE}, minrtt_enabled=${HFSC_MINRTT_ENABLED}, minrtt_delay=${HFSC_MINRTT_DELAY}"
    qos_log "INFO" "CAKE参数: bandwidth=${CAKE_BANDWIDTH:-未配置}, rtt=${CAKE_RTT:-未配置}, flowmode=${CAKE_FLOWMODE}, diffserv=${CAKE_DIFFSERV}, nat=${CAKE_NAT}, wash=${CAKE_WASH}, overhead=${CAKE_OVERHEAD:-未配置}, mpu=${CAKE_MPU:-未配置}, ack_filter=${CAKE_ACK_FILTER}, split_gso=${CAKE_SPLIT_GSO}, memlimit=${CAKE_MEMLIMIT:-未配置}, ecn=${CAKE_ECN}"
    return 0
}

# 加载HFSC类别配置（使用全局变量传递，并在函数开头重置）
load_hfsc_class_config() {
    local class_name="$1"
    # 重置全局变量，避免前一个类的配置残留
    HFSC_CLASS_PERCENT=""
    HFSC_CLASS_MIN=""
    HFSC_CLASS_MAX=""
    HFSC_CLASS_MINRTT=""
    HFSC_CLASS_NAME=""

    qos_log "INFO" "加载HFSC类别配置: $class_name"
    percent_bandwidth=$(uci -q get ${CONFIG_FILE}.$class_name.percent_bandwidth 2>/dev/null)
    per_min_bandwidth=$(uci -q get ${CONFIG_FILE}.$class_name.per_min_bandwidth 2>/dev/null)
    per_max_bandwidth=$(uci -q get ${CONFIG_FILE}.$class_name.per_max_bandwidth 2>/dev/null)
    minRTT=$(uci -q get ${CONFIG_FILE}.$class_name.minRTT 2>/dev/null)
    priority=$(uci -q get ${CONFIG_FILE}.$class_name.priority 2>/dev/null)  # HFSC 中 priority 无效，保留读取以兼容
    name=$(uci -q get ${CONFIG_FILE}.$class_name.name 2>/dev/null)

    if [[ -n "$percent_bandwidth" ]]; then
        if validate_number "$percent_bandwidth" "$class_name.percent_bandwidth" 0 100; then
            percent_bandwidth=$(strip_leading_zeros "$percent_bandwidth")
        else
            percent_bandwidth=""
        fi
    fi
    if [[ -n "$per_min_bandwidth" ]]; then
        if validate_number "$per_min_bandwidth" "$class_name.per_min_bandwidth" 0 100; then
            per_min_bandwidth=$(strip_leading_zeros "$per_min_bandwidth")
        else
            per_min_bandwidth=""
        fi
    fi
    if [[ -n "$per_max_bandwidth" ]]; then
        if validate_number "$per_max_bandwidth" "$class_name.per_max_bandwidth" 0 1000; then
            per_max_bandwidth=$(strip_leading_zeros "$per_max_bandwidth")
        else
            per_max_bandwidth=""
        fi
    fi

    qos_log "DEBUG" "HFSC配置: $class_name -> percent=$percent_bandwidth, min=$per_min_bandwidth, max=$per_max_bandwidth, minRTT=$minRTT"
    if [[ -z "$percent_bandwidth" ]] && [[ -z "$per_min_bandwidth" ]] && [[ -z "$per_max_bandwidth" ]]; then
        qos_log "WARN" "未找到 $class_name 的带宽参数"
        return 1
    fi
    # 使用全局变量传递
    HFSC_CLASS_PERCENT="$percent_bandwidth"
    HFSC_CLASS_MIN="$per_min_bandwidth"
    HFSC_CLASS_MAX="$per_max_bandwidth"
    HFSC_CLASS_MINRTT="$minRTT"
    HFSC_CLASS_NAME="$name"
    return 0
}

# ========== HFSC 核心队列函数 ==========
create_hfsc_root_qdisc() {
    local device="$1"
    local direction="$2"
    local root_handle="$3"
    local root_classid="$4"
    local bandwidth=""
    if [[ "$direction" == "upload" ]]; then
        bandwidth="$total_upload_bandwidth"
    elif [[ "$direction" == "download" ]]; then
        bandwidth="$total_download_bandwidth"
    else
        qos_log "ERROR" "未知方向: $direction"
        return 1
    fi
    if (( bandwidth <= 0 )); then
        qos_log "ERROR" "方向 $direction 带宽无效或为0，无法创建根队列"
        return 1
    fi
    if ! validate_number "$bandwidth" "bandwidth" 1 "$MAX_PHYSICAL_BANDWIDTH"; then
        qos_log "ERROR" "无效的带宽值: $bandwidth"
        return 1
    fi
    qos_log "INFO" "为$device创建$direction方向HFSC根队列 (带宽: ${bandwidth}kbit)"
    tc qdisc del dev "$device" ingress 2>/dev/null || true
    tc qdisc del dev "$device" root 2>/dev/null || true
    if ! tc qdisc add dev "$device" root handle $root_handle hfsc; then
        qos_log "ERROR" "无法在 $device 上创建HFSC根队列"
        return 1
    fi
    # 修复：HFSC 根类使用 ls m2 和 ul m2，而非 ls rate 和 ul rate
    if ! tc class add dev "$device" parent $root_handle classid $root_classid hfsc ls m2 ${bandwidth}kbit ul m2 ${bandwidth}kbit; then
        qos_log "ERROR" "无法在$device上创建HFSC根类"
        tc qdisc del dev "$device" root 2>/dev/null
        return 1
    fi
    qos_log "INFO" "$device的$direction方向HFSC根队列创建完成"
    return 0
}

# 设置默认类（HFSC 无 default 参数，使用全匹配过滤器）
set_hfsc_default_class() {
    local device="$1"
    local default_classid="$2"
    if ! validate_number "$default_classid" "default_classid" 2 17; then
        qos_log "ERROR" "无效的默认类ID: $default_classid (有效范围 2-17)"
        return 1
    fi
    # 添加全匹配过滤器作为默认类（优先级 999，确保最后匹配）
    if tc filter add dev "$device" parent 1:0 protocol all prio 999 u32 match u32 0 0 flowid 1:$default_classid 2>/dev/null; then
        qos_log "INFO" "已通过全匹配过滤器设置默认类 1:$default_classid"
        return 0
    else
        qos_log "ERROR" "无法设置默认类（全匹配过滤器失败）"
        return 1
    fi
}

# ========== CAKE 参数支持检查 ==========
check_cake_param_support() {
    local param="$1"
    local dummy_dev="qos_test_cake_$$"
    local created=0
    if ! ip link add "$dummy_dev" type dummy 2>/dev/null; then
        qos_log "DEBUG" "无法创建 dummy 设备，假定 $param 不支持"
        return 1
    fi
    created=1
    tc qdisc del dev "$dummy_dev" root 2>/dev/null
    local ret=1
    if tc qdisc add dev "$dummy_dev" root cake bandwidth 1mbit "$param" 2>/dev/null; then
        ret=0
        tc qdisc del dev "$dummy_dev" root 2>/dev/null
    fi
    if [[ $created -eq 1 ]]; then
        ip link del "$dummy_dev" 2>/dev/null
    fi
    return $ret
}

# ========== 构建CAKE参数串 ==========
build_cake_params() {
    local direction="$1"   # upload 或 download
    local params=""
    local bandwidth=""
    
    # 根据方向选择对应的总带宽
    if [[ "$direction" == "upload" ]]; then
        bandwidth="$total_upload_bandwidth"
    elif [[ "$direction" == "download" ]]; then
        bandwidth="$total_download_bandwidth"
    else
        qos_log "ERROR" "build_cake_params: 未知方向 $direction"
        return 1
    fi
    
    # 如果用户显式配置了 CAKE_BANDWIDTH，则优先使用，否则使用 HFSC 总带宽（避免二次整形）
    if [[ -n "$CAKE_BANDWIDTH" ]]; then
        params="$params bandwidth $CAKE_BANDWIDTH"
        qos_log "INFO" "用户显式配置了CAKE bandwidth: $CAKE_BANDWIDTH，CAKE将进行二次整形（可能影响HFSC调度）"
    else
        # 默认使用 HFSC 该方向的总带宽，使 CAKE 只作为队列调度而不做速率整形
        params="$params bandwidth ${bandwidth}kbit"
        qos_log "DEBUG" "CAKE 使用 HFSC 总带宽 ${bandwidth}kbit，避免二次整形"
    fi
    
    [[ -n "$CAKE_RTT" ]] && params="$params rtt $CAKE_RTT"
    [[ -n "$CAKE_FLOWMODE" ]] && params="$params $CAKE_FLOWMODE"
    [[ -n "$CAKE_DIFFSERV" ]] && params="$params $CAKE_DIFFSERV"
    if [[ "$CAKE_NAT" == "1" ]] || [[ "$CAKE_NAT" == "yes" ]] || [[ "$CAKE_NAT" == "true" ]]; then
        params="$params nat"
    else
        params="$params nonat"
    fi
    if [[ "$CAKE_WASH" == "1" ]] || [[ "$CAKE_WASH" == "yes" ]] || [[ "$CAKE_WASH" == "true" ]]; then
        params="$params wash"
    else
        params="$params nowash"
    fi
    [[ -n "$CAKE_OVERHEAD" ]] && params="$params overhead $CAKE_OVERHEAD"
    [[ -n "$CAKE_MPU" ]] && params="$params mpu $CAKE_MPU"
    if [[ "$CAKE_ACK_FILTER" == "1" ]] || [[ "$CAKE_ACK_FILTER" == "yes" ]] || [[ "$CAKE_ACK_FILTER" == "true" ]]; then
        params="$params ack-filter"
    else
        params="$params noack-filter"
    fi
    if [[ "$CAKE_SPLIT_GSO" == "1" ]] || [[ "$CAKE_SPLIT_GSO" == "yes" ]] || [[ "$CAKE_SPLIT_GSO" == "true" ]]; then
        params="$params split-gso"
    else
        params="$params no-split-gso"
    fi
    [[ -n "$CAKE_MEMLIMIT" ]] && params="$params memlimit $CAKE_MEMLIMIT"
    if [[ -n "$CAKE_ECN" ]]; then
        if check_cake_param_support "$CAKE_ECN"; then
            params="$params $CAKE_ECN"
        else
            logger -t "qos_gargoyle" "CAKE警告: 内核不支持 $CAKE_ECN 参数，已忽略 ECN 设置"
        fi
    fi
    echo "$params"
}

# 创建单个上传类
create_hfsc_upload_class() {
    local class_name="$1"
    local class_index="$2"
    qos_log "INFO" "创建上传类别: $class_name, ID: 1:$class_index"
    if ! load_hfsc_class_config "$class_name"; then
        qos_log "ERROR" "加载HFSC配置失败: $class_name"
        return 1
    fi
    local percent_bandwidth="$HFSC_CLASS_PERCENT"
    local per_min_bandwidth="$HFSC_CLASS_MIN"
    local per_max_bandwidth="$HFSC_CLASS_MAX"
    local minRTT="$HFSC_CLASS_MINRTT"
    local name="$HFSC_CLASS_NAME"
    
    local class_mark
    class_mark=$(get_class_mark "upload" "$class_name")
    if [[ -z "$class_mark" ]]; then
        qos_log "ERROR" "无法获取类别 $class_name 的标记"
        return 1
    fi
    qos_log "INFO" "类别 $class_name 使用的标记: 0x$(printf '%X' $class_mark)"
    local m1="0bit"
    local d="0us"
    local m2=""
    local ul_m2=""
    local class_total_bw=0
    if [[ -z "$percent_bandwidth" ]] || (( percent_bandwidth <= 0 )); then
        qos_log "ERROR" "类别 $class_name 未配置有效的 percent_bandwidth (>0)"
        return 1
    fi
    if [[ -n "$total_upload_bandwidth" ]] && (( total_upload_bandwidth > 0 )); then
        class_total_bw=$((total_upload_bandwidth * percent_bandwidth / 100))
        qos_log "INFO" "类别 $class_name 总带宽: ${class_total_bw}kbit (${percent_bandwidth}% of ${total_upload_bandwidth}kbit)"
    else
        qos_log "ERROR" "total_upload_bandwidth无效"
        return 1
    fi
    # 处理最小保证带宽（per_min_bandwidth），缺失时使用 50% 作为默认
    if [[ -n "$per_min_bandwidth" ]] && (( per_min_bandwidth >= 0 )); then
        if (( per_min_bandwidth == 0 )); then
            m2="1kbit"
            qos_log "INFO" "类别 $class_name 不保证最小带宽 (per_min_bandwidth=0)"
        else
            m2="$((class_total_bw * per_min_bandwidth / 100))kbit"
            qos_log "INFO" "类别 $class_name 使用百分比计算保证带宽: $m2 (${per_min_bandwidth}% of ${class_total_bw}kbit)"
        fi
    else
        # 未配置 per_min_bandwidth，使用默认 50%
        m2="$((class_total_bw * 50 / 100))kbit"
        qos_log "INFO" "类别 $class_name 使用默认保证带宽: $m2 (50% of ${class_total_bw}kbit)"
    fi
    # 处理上限带宽（per_max_bandwidth），缺失时使用类别总带宽
    if [[ -n "$per_max_bandwidth" ]] && (( per_max_bandwidth > 0 )); then
        ul_m2="$((class_total_bw * per_max_bandwidth / 100))kbit"
        qos_log "INFO" "类别 $class_name 使用百分比计算上限带宽: $ul_m2 (${per_max_bandwidth}% of ${class_total_bw}kbit)"
    else
        ul_m2="${class_total_bw}kbit"
        qos_log "INFO" "类别 $class_name 使用类别总带宽作为上限带宽: $ul_m2"
    fi
    # 确保 ul_m2 至少为 1kbit（防止为0）
    local ul_m2_value=$(echo "$ul_m2" | sed 's/kbit//')
    if (( ul_m2_value < 1 )); then
        ul_m2="1kbit"
        ul_m2_value=1
        qos_log "WARN" "类别 $class_name 上限带宽为0，调整为1kbit"
    fi
    local m2_value=$(echo "$m2" | sed 's/kbit//')
    if (( m2_value > ul_m2_value )); then
        qos_log "WARN" "类别 $class_name 保证带宽($m2)超过上限带宽($ul_m2)，调整为上限带宽"
        m2="$ul_m2"
    fi
    local enable_minrtt=0
    if [[ -n "$minRTT" ]]; then
        case "$minRTT" in
            [Yy]es|[Yy]|1|[Tt]rue) enable_minrtt=1 ;;
            [Nn]o|[Nn]|0|[Ff]alse) enable_minrtt=0 ;;
            *) enable_minrtt="${HFSC_MINRTT_ENABLED:-0}" ;;
        esac
    else
        enable_minrtt="${HFSC_MINRTT_ENABLED:-0}"
    fi
    if (( enable_minrtt == 1 )); then
        d="${HFSC_MINRTT_DELAY:-1000us}"
        qos_log "INFO" "类别 $class_name 启用最小延迟模式 (d=$d)"
    fi
    qos_log "INFO" "正在创建HFSC类别 1:$class_index (带宽: ls=$m2, ul=$ul_m2)"
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:$class_index hfsc \
        ls m1 $m1 d $d m2 $m2 \
        ul m2 $ul_m2; then
        qos_log "ERROR" "创建上传类别 1:$class_index 失败"
        return 1
    fi
    local cake_params=$(build_cake_params "upload")
    qos_log "INFO" "添加上传CAKE队列参数: $cake_params"
    if ! tc qdisc add dev "$qos_interface" parent 1:$class_index \
        handle ${class_index}:1 cake $cake_params; then
        qos_log "ERROR" "添加上传CAKE队列失败"
        tc class del dev "$qos_interface" classid 1:$class_index 2>/dev/null
        return 1
    fi
    if [[ "$class_mark" != "0x0" ]]; then
        if ! tc filter add dev "$qos_interface" parent 1:0 protocol ip \
            prio $class_index handle ${class_mark}/$UPLOAD_MASK fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加上传IPv4过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            qos_log "INFO" "添加上传IPv4过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
    fi
    if [[ "$class_mark" != "0x0" ]]; then
        local base_prio=100
        local ipv6_priority=$((base_prio + class_index))
        if ! tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
            prio $ipv6_priority handle ${class_mark}/$UPLOAD_MASK fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加上传IPv6过滤器失败 (标记:$class_mark -> 类别:1:$class_index, 优先级:$ipv6_priority)"
        else
            qos_log "INFO" "添加上传IPv6过滤器: 标记:$class_mark -> 类别:1:$class_index (优先级:$ipv6_priority)"
        fi
    fi
    qos_log "INFO" "上传类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, 带宽: ls=$m2, ul=$ul_m2)"
    return 0
}

# 创建单个下载类（使用IFB设备）
create_hfsc_download_class() {
    local class_name="$1"
    local class_index="$2"
    local filter_prio="$3"
    local ifb_dev="$IFB_DEVICE"
    qos_log "INFO" "创建下载类别: $class_name, ID: 1:$class_index, 过滤器优先级: $filter_prio"
    if ! ip link show dev "$ifb_dev" >/dev/null 2>&1; then
        qos_log "ERROR" "IFB设备 $ifb_dev 不存在，无法创建下载类"
        return 1
    fi
    if ! load_hfsc_class_config "$class_name"; then
        qos_log "ERROR" "加载HFSC配置失败: $class_name"
        return 1
    fi
    local percent_bandwidth="$HFSC_CLASS_PERCENT"
    local per_min_bandwidth="$HFSC_CLASS_MIN"
    local per_max_bandwidth="$HFSC_CLASS_MAX"
    local minRTT="$HFSC_CLASS_MINRTT"
    local name="$HFSC_CLASS_NAME"
    
    local class_mark
    class_mark=$(get_class_mark "download" "$class_name")
    if [[ -z "$class_mark" ]]; then
        qos_log "ERROR" "无法获取类别 $class_name 的标记"
        return 1
    fi
    qos_log "INFO" "类别 $class_name 使用的标记: 0x$(printf '%X' $class_mark)"
    local m1="0bit"
    local d="0us"
    local m2=""
    local ul_m2=""
    local class_total_bw=0
    if [[ -z "$percent_bandwidth" ]] || (( percent_bandwidth <= 0 )); then
        qos_log "ERROR" "类别 $class_name 未配置有效的 percent_bandwidth (>0)"
        return 1
    fi
    if [[ -n "$total_download_bandwidth" ]] && (( total_download_bandwidth > 0 )); then
        class_total_bw=$((total_download_bandwidth * percent_bandwidth / 100))
        qos_log "INFO" "类别 $class_name 总带宽: ${class_total_bw}kbit (${percent_bandwidth}% of ${total_download_bandwidth}kbit)"
    else
        qos_log "ERROR" "total_download_bandwidth无效"
        return 1
    fi
    if [[ -n "$per_min_bandwidth" ]] && (( per_min_bandwidth >= 0 )); then
        if (( per_min_bandwidth == 0 )); then
            m2="1kbit"
            qos_log "INFO" "类别 $class_name 不保证最小带宽 (per_min_bandwidth=0)"
        else
            m2="$((class_total_bw * per_min_bandwidth / 100))kbit"
            qos_log "INFO" "类别 $class_name 使用百分比计算保证带宽: $m2 (${per_min_bandwidth}% of ${class_total_bw}kbit)"
        fi
    else
        m2="$((class_total_bw * 50 / 100))kbit"
        qos_log "INFO" "类别 $class_name 使用默认保证带宽: $m2 (50% of ${class_total_bw}kbit)"
    fi
    if [[ -n "$per_max_bandwidth" ]] && (( per_max_bandwidth > 0 )); then
        ul_m2="$((class_total_bw * per_max_bandwidth / 100))kbit"
        qos_log "INFO" "类别 $class_name 使用百分比计算上限带宽: $ul_m2 (${per_max_bandwidth}% of ${class_total_bw}kbit)"
    else
        ul_m2="${class_total_bw}kbit"
        qos_log "INFO" "类别 $class_name 使用类别总带宽作为上限带宽: $ul_m2"
    fi
    local ul_m2_value=$(echo "$ul_m2" | sed 's/kbit//')
    if (( ul_m2_value < 1 )); then
        ul_m2="1kbit"
        ul_m2_value=1
        qos_log "WARN" "类别 $class_name 上限带宽为0，调整为1kbit"
    fi
    local m2_value=$(echo "$m2" | sed 's/kbit//')
    if (( m2_value > ul_m2_value )); then
        qos_log "WARN" "类别 $class_name 保证带宽($m2)超过上限带宽($ul_m2)，调整为上限带宽"
        m2="$ul_m2"
    fi
    local enable_minrtt=0
    if [[ -n "$minRTT" ]]; then
        case "$minRTT" in
            [Yy]es|[Yy]|1|[Tt]rue) enable_minrtt=1 ;;
            [Nn]o|[Nn]|0|[Ff]alse) enable_minrtt=0 ;;
            *) enable_minrtt="${HFSC_MINRTT_ENABLED:-0}" ;;
        esac
    else
        enable_minrtt="${HFSC_MINRTT_ENABLED:-0}"
    fi
    if (( enable_minrtt == 1 )); then
        d="${HFSC_MINRTT_DELAY:-1000us}"
        qos_log "INFO" "类别 $class_name 启用最小延迟模式 (d=$d)"
    fi
    qos_log "INFO" "正在创建下载HFSC类别 1:$class_index (带宽: ls=$m2, ul=$ul_m2)"
    if ! tc class add dev "$ifb_dev" parent 1:1 \
        classid 1:$class_index hfsc \
        ls m1 $m1 d $d m2 $m2 \
        ul m2 $ul_m2; then
        qos_log "ERROR" "创建下载类别 1:$class_index 失败"
        return 1
    fi
    local cake_params=$(build_cake_params "download")
    qos_log "INFO" "添加下载CAKE队列参数: $cake_params"
    if ! tc qdisc add dev "$ifb_dev" parent 1:$class_index \
        handle ${class_index}:1 cake $cake_params; then
        qos_log "ERROR" "添加下载CAKE队列失败"
        tc class del dev "$ifb_dev" classid 1:$class_index 2>/dev/null
        return 1
    fi
    if [[ "$class_mark" != "0x0" ]]; then
        if ! tc filter add dev "$ifb_dev" parent 1:0 protocol ip \
            prio $filter_prio handle ${class_mark}/$DOWNLOAD_MASK fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加下载IPv4过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            qos_log "INFO" "添加下载IPv4过滤器: 标记:$class_mark -> 类别:1:$class_index (优先级:$filter_prio)"
        fi
    fi
    if [[ "$class_mark" != "0x0" ]]; then
        local base_prio=100
        local ipv6_priority=$((base_prio + filter_prio))
        if ! tc filter add dev "$ifb_dev" parent 1:0 protocol ipv6 \
            prio $ipv6_priority handle ${class_mark}/$DOWNLOAD_MASK fw classid 1:$class_index 2>/dev/null; then
            qos_log "WARN" "添加下载IPv6过滤器失败 (标记:$class_mark -> 类别:1:$class_index, 优先级:$ipv6_priority)"
        else
            qos_log "INFO" "添加下载IPv6过滤器: 标记:$class_mark -> 类别:1:$class_index (优先级:$ipv6_priority)"
        fi
    fi
    qos_log "INFO" "下载类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, 带宽: ls=$m2, ul=$ul_m2)"
    return 0
}

# ========== 上传方向初始化 ==========
init_hfsc_cake_upload() {
    qos_log "INFO" "初始化上传方向HFSC"
    load_upload_class_configurations
    if [[ -z "$upload_class_list" ]]; then
        qos_log "ERROR" "未找到上传类别配置，请至少配置一个上传类"
        return 1
    fi

    # 统计启用的类数量，而不是所有类
    local enabled_class_count=0
    local class_list="$upload_class_list"
    for class in $class_list; do
        local enabled=$(uci -q get ${CONFIG_FILE}.${class}.enabled 2>/dev/null)
        if [[ "$enabled" == "1" ]] || [[ -z "$enabled" ]]; then
            ((enabled_class_count++))
        fi
    done
    if (( enabled_class_count > 16 )); then
        qos_log "ERROR" "上传方向启用的类别数量为 $enabled_class_count，超过16个，将导致标记冲突，启动中止！"
        return 1
    fi

    local enabled_classes=""
    local class_index=2
    local default_class_index=""
    local default_class_name=""
    local first_enabled_class=""

    declare -A class_index_map
    default_class_name=$(uci -q get ${CONFIG_FILE}.upload.default_class 2>/dev/null)

    for class in $upload_class_list; do
        local enabled=$(uci -q get ${CONFIG_FILE}.${class}.enabled 2>/dev/null)
        if [[ "$enabled" == "1" ]] || [[ -z "$enabled" ]]; then
            enabled_classes="$enabled_classes $class"
            [[ -z "$first_enabled_class" ]] && first_enabled_class="$class"
            class_index_map["$class"]=$class_index
            if [[ -n "$default_class_name" ]] && [[ "$class" == "$default_class_name" ]]; then
                default_class_index=$class_index
            fi
            ((class_index++))
        fi
    done
    enabled_classes=$(echo "$enabled_classes" | xargs)

    if [[ -z "$enabled_classes" ]]; then
        qos_log "ERROR" "没有启用的上传类，请至少启用一个上传类"
        return 1
    fi

    if [[ -z "$default_class_index" ]]; then
        if [[ -n "$default_class_name" ]]; then
            qos_log "WARN" "未找到上传默认类别 '$default_class_name' 或该类未启用，将使用第一个启用的类别"
        fi
        if [[ -n "$first_enabled_class" ]]; then
            default_class_index=${class_index_map["$first_enabled_class"]}
            qos_log "INFO" "自动选择第一个启用的类别: $first_enabled_class (ID: 1:$default_class_index)"
        else
            qos_log "ERROR" "没有启用的上传类，无法设置默认类"
            return 1
        fi
    else
        qos_log "INFO" "上传默认类别: $default_class_name (ID: 1:$default_class_index)"
    fi

    # 创建根队列
    if ! create_hfsc_root_qdisc "$qos_interface" "upload" "1:0" "1:1"; then
        qos_log "ERROR" "创建上传根队列失败"
        return 1
    fi

    # 创建各个子类
    upload_class_mark_list=""
    for class_name in $enabled_classes; do
        local idx=${class_index_map["$class_name"]}
        if create_hfsc_upload_class "$class_name" "$idx"; then
            local class_mark_hex=$(get_class_mark "upload" "$class_name")
            upload_class_mark_list="$upload_class_mark_list$class_name:0x$(printf '%X' $class_mark_hex) "
        else
            qos_log "ERROR" "创建上传类别 $class_name 失败，停止初始化"
            tc qdisc del dev "$qos_interface" root 2>/dev/null
            return 1
        fi
    done

    # 设置默认类
    if ! set_hfsc_default_class "$qos_interface" "$default_class_index"; then
        qos_log "ERROR" "设置上传默认类失败"
        tc qdisc del dev "$qos_interface" root 2>/dev/null
        return 1
    fi

    qos_log "INFO" "上传方向HFSC初始化完成"
    return 0
}

# ========== 下载方向初始化 ==========
init_hfsc_cake_download() {
    qos_log "INFO" "初始化下载方向HFSC"
    load_download_class_configurations
    if [[ -z "$download_class_list" ]]; then
        qos_log "ERROR" "未找到下载类别配置，请至少配置一个下载类"
        return 1
    fi

    # 统计启用的类数量，而不是所有类
    local enabled_class_count=0
    local class_list="$download_class_list"
    for class in $class_list; do
        local enabled=$(uci -q get ${CONFIG_FILE}.${class}.enabled 2>/dev/null)
        if [[ "$enabled" == "1" ]] || [[ -z "$enabled" ]]; then
            ((enabled_class_count++))
        fi
    done
    if (( enabled_class_count > 16 )); then
        qos_log "ERROR" "下载方向启用的类别数量为 $enabled_class_count，超过16个，将导致标记冲突，启动中止！"
        return 1
    fi

    local enabled_classes=""
    local class_index=2
    local default_class_index=""
    local default_class_name=""
    local first_enabled_class=""

    declare -A class_index_map
    default_class_name=$(uci -q get ${CONFIG_FILE}.download.default_class 2>/dev/null)

    for class in $download_class_list; do
        local enabled=$(uci -q get ${CONFIG_FILE}.${class}.enabled 2>/dev/null)
        if [[ "$enabled" == "1" ]] || [[ -z "$enabled" ]]; then
            enabled_classes="$enabled_classes $class"
            [[ -z "$first_enabled_class" ]] && first_enabled_class="$class"
            class_index_map["$class"]=$class_index
            if [[ -n "$default_class_name" ]] && [[ "$class" == "$default_class_name" ]]; then
                default_class_index=$class_index
            fi
            ((class_index++))
        fi
    done
    enabled_classes=$(echo "$enabled_classes" | xargs)

    if [[ -z "$enabled_classes" ]]; then
        qos_log "ERROR" "没有启用的下载类，请至少启用一个下载类"
        return 1
    fi

    if [[ -z "$default_class_index" ]]; then
        if [[ -n "$default_class_name" ]]; then
            qos_log "WARN" "未找到下载默认类别 '$default_class_name' 或该类未启用，将使用第一个启用的类别"
        fi
        if [[ -n "$first_enabled_class" ]]; then
            default_class_index=${class_index_map["$first_enabled_class"]}
            qos_log "INFO" "自动选择第一个启用的类别: $first_enabled_class (ID: 1:$default_class_index)"
        else
            qos_log "ERROR" "没有启用的下载类，无法设置默认类"
            return 1
        fi
    else
        qos_log "INFO" "下载默认类别: $default_class_name (ID: 1:$default_class_index)"
    fi

    # 检查并创建 IFB 设备（尝试指定队列数）
    local expected_queues=1
    if [[ -d "/sys/class/net/$qos_interface/queues" ]]; then
        expected_queues=$(ls -d /sys/class/net/$qos_interface/queues/tx-* 2>/dev/null | wc -l)
        (( expected_queues < 1 )) && expected_queues=1
    fi

    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        qos_log "INFO" "IFB设备 $IFB_DEVICE 已存在"
        # 检查队列数是否匹配
        local current_queues=1
        if [[ -d "/sys/class/net/$IFB_DEVICE/queues" ]]; then
            current_queues=$(ls -d /sys/class/net/$IFB_DEVICE/queues/tx-* 2>/dev/null | wc -l)
        fi
        if (( current_queues != expected_queues )); then
            qos_log "WARN" "IFB设备队列数 ($current_queues) 与期望 ($expected_queues) 不符，将删除重建"
            ip link set dev "$IFB_DEVICE" down
            ip link del "$IFB_DEVICE" 2>/dev/null
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
            qos_log "INFO" "IFB设备创建成功，但可能队列数不符预期。如需多队列，请检查内核支持。"
        else
            qos_log "INFO" "IFB设备创建成功，队列数: $expected_queues"
        fi
    fi

    if ! ip link set dev "$IFB_DEVICE" up; then
        qos_log "ERROR" "无法启动IFB设备 $IFB_DEVICE"
        return 1
    fi

    # 创建根队列
    if ! create_hfsc_root_qdisc "$IFB_DEVICE" "download" "1:0" "1:1"; then
        qos_log "ERROR" "创建下载根队列失败"
        return 1
    fi

    local filter_prio=3
    download_class_mark_list=""
    for class_name in $enabled_classes; do
        local idx=${class_index_map["$class_name"]}
        if create_hfsc_download_class "$class_name" "$idx" "$filter_prio"; then
            local class_mark_hex=$(get_class_mark "download" "$class_name")
            download_class_mark_list="$download_class_mark_list$class_name:0x$(printf '%X' $class_mark_hex) "
        else
            qos_log "ERROR" "创建下载类别 $class_name 失败，停止初始化"
            tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null
            return 1
        fi
        filter_prio=$((filter_prio + 2))
    done

    # 设置默认类
    if ! set_hfsc_default_class "$IFB_DEVICE" "$default_class_index"; then
        qos_log "ERROR" "设置下载默认类失败"
        tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null
        return 1
    fi

    # 调用 rule.sh 中的入口重定向函数
    if ! setup_ingress_redirect; then
        qos_log "ERROR" "设置入口重定向失败"
        return 1
    fi
    qos_log "INFO" "下载方向HFSC初始化完成"
    return 0
}

# ========== 主初始化函数 ==========
init_hfsc_cake_qos() {
    local action="${1:-start}"
    qos_log "INFO" "开始初始化HFSC+CAKE QoS系统 (action=$action)"
    
    # 检查是否已在运行（由 procd 保证，但保留辅助检查）
    if ! check_already_running; then
        qos_log "ERROR" "HFSC+CAKE QoS 已经在运行中"
        return 1
    fi
    
    if ! init_ruleset; then
        qos_log "ERROR" "初始化规则集失败，QoS 无法启动"
        rm -f "$QOS_RUNNING_FILE"
        return 1
    fi
    
    nft flush chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null
    nft flush chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null
    qos_log "INFO" "已清空 nft 规则链"
    
    if ! check_required_commands; then
        qos_log "ERROR" "缺少必需的命令，请安装对应软件包"
        rm -f "$QOS_RUNNING_FILE"
        return 1
    fi
    
    if ! load_required_modules; then
        qos_log "ERROR" "无法加载必需的内核模块"
        rm -f "$QOS_RUNNING_FILE"
        return 1
    fi
    
    # 加载 HFSC 和 CAKE 调度器模块
    local missing=0
    for mod in sch_hfsc sch_cake; do
        if ! lsmod 2>/dev/null | grep -q "^$mod"; then
            log_info "尝试加载内核模块: $mod"
            modprobe "$mod" 2>/dev/null || { log_error "无法加载内核模块 $mod"; missing=1; }
            if ! lsmod 2>/dev/null | grep -q "^$mod"; then
                log_error "内核模块 $mod 加载失败"
                missing=1
            fi
        fi
    done
    if (( missing )); then
        qos_log "ERROR" "HFSC/CAKE 内核模块加载失败"
        rm -f "$QOS_RUNNING_FILE"
        return 1
    fi
    
    nft add table inet gargoyle-qos-priority 2>/dev/null || true
    if [[ -z "$qos_interface" ]]; then
        qos_interface=$(uci -q get ${CONFIG_FILE}.global.wan_interface 2>/dev/null)
        if [[ -z "$qos_interface" ]] && [[ -f "/lib/functions/network.sh" ]]; then
            . /lib/functions/network.sh
            network_find_wan qos_interface
        fi
        if [[ -z "$qos_interface" ]]; then
            qos_log "ERROR" "无法确定 WAN 接口，请检查配置"
            rm -f "$QOS_RUNNING_FILE"
            return 1
        fi
    fi
    qos_log "INFO" "使用WAN接口: $qos_interface"
    
    # ========== 自动测速与带宽加载 ==========
    # 自动测速开关处理（需要在加载带宽配置之前执行）
    if [[ "$AUTO_SPEEDTEST" == "1" ]]; then
        qos_log "INFO" "自动测速开关已开启，正在执行速度测试..."
        # 非交互模式，强制覆盖现有配置
        if ! auto_speedtest -n -f; then
            qos_log "WARN" "自动测速失败，将使用原有带宽配置（若有）"
        fi
    fi

    # 加载带宽配置（会设置 total_upload_bandwidth 和 total_download_bandwidth）
    if ! load_bandwidth_from_config; then
        qos_log "ERROR" "加载带宽配置失败"
        rm -f "$QOS_RUNNING_FILE"
        return 1
    fi
    # ====================================
    
    if ! load_hfsc_cake_config; then
        qos_log "ERROR" "加载HFSC+CAKE配置失败"
        rm -f "$QOS_RUNNING_FILE"
        return 1
    fi
    
    if [[ "$UPLOAD_MASK" == "0" ]] || [[ "$DOWNLOAD_MASK" == "0" ]]; then
        qos_log "ERROR" "UPLOAD_MASK 或 DOWNLOAD_MASK 为 0，无法正确匹配标记"
        rm -f "$QOS_RUNNING_FILE"
        return 1
    fi

    load_upload_class_configurations
    load_download_class_configurations

    local upload_enabled=0
    local download_enabled=0

    if [[ -n "$total_upload_bandwidth" ]] && [[ "$total_upload_bandwidth" =~ ^[0-9]+$ ]] && (( total_upload_bandwidth > 0 )); then
        upload_enabled=1
        qos_log "INFO" "上传带宽有效，将启用上传QoS"
    else
        qos_log "INFO" "上传带宽未配置或为0，禁用上传QoS"
    fi

    if [[ -n "$total_download_bandwidth" ]] && [[ "$total_download_bandwidth" =~ ^[0-9]+$ ]] && (( total_download_bandwidth > 0 )); then
        download_enabled=1
        qos_log "INFO" "下载带宽有效，将启用下载QoS"
    else
        qos_log "INFO" "下载带宽未配置或为0，禁用下载QoS"
    fi

    if (( upload_enabled == 0 )) && (( download_enabled == 0 )); then
        qos_log "WARN" "上传和下载带宽均为0，QoS未启动任何方向"
        check_and_handle_zero_bandwidth "$total_upload_bandwidth" "$total_download_bandwidth"
        rm -f "$QOS_RUNNING_FILE"
        return 0
    fi

    if (( upload_enabled == 1 )) && [[ -n "$upload_class_list" ]]; then
        if ! allocate_class_marks "upload" "$upload_class_list"; then
            qos_log "ERROR" "上传方向标记分配失败"
            rm -f "$QOS_RUNNING_FILE"
            return 1
        fi
    fi

    if (( download_enabled == 1 )) && [[ -n "$download_class_list" ]]; then
        if ! allocate_class_marks "download" "$download_class_list"; then
            qos_log "ERROR" "下载方向标记分配失败"
            rm -f "$QOS_RUNNING_FILE"
            return 1
        fi
    fi

    if (( upload_enabled == 1 )); then
        echo "调用上传分类规则应用..." 
        if ! apply_all_rules "upload_rule" "$UPLOAD_MASK" "filter_qos_egress"; then
            qos_log "ERROR" "上传规则应用失败，回滚"
            stop_hfsc_cake_qos
            return 1
        fi
    fi

    if (( download_enabled == 1 )); then
        echo "调用下载分类规则应用..." 
        if ! apply_all_rules "download_rule" "$DOWNLOAD_MASK" "filter_qos_ingress"; then
            qos_log "ERROR" "下载规则应用失败，回滚"
            stop_hfsc_cake_qos
            return 1
        fi
    fi

    # ========== 添加 DSCP 映射 ==========
    if ! setup_class_mark_map; then
        qos_log "ERROR" "class_mark 映射设置失败"
        stop_hfsc_cake_qos
        return 1
    fi

    qos_log "INFO" "应用自定义规则成功"
    if (( ENABLE_RATELIMIT == 1 )); then
        echo "应用速率限制链..." 
        setup_ratelimit_chain
    fi
    
    # 增强功能函数（ACK/TCP/UDP/动态分类）
    apply_enhanced_features
    
    echo "应用ipv6特别规则..." 
    setup_ipv6_specific_rules
    
    local upload_failed=0
    local download_failed=0
    local upload_skipped=0
    local download_skipped=0

    if (( upload_enabled == 1 )); then
        if ! init_hfsc_cake_upload; then
            qos_log "ERROR" "上传方向初始化失败"
            upload_failed=1
        fi
    else
        upload_skipped=1
    fi

    if (( download_enabled == 1 )); then
        if ! init_hfsc_cake_download; then
            qos_log "ERROR" "下载方向初始化失败"
            download_failed=1
        fi
    else
        download_skipped=1
    fi

    if (( upload_failed == 1 )) || (( download_failed == 1 )); then
        qos_log "ERROR" "HFSC+CAKE QoS 初始化部分失败"
        stop_hfsc_cake_qos
        return 1
    fi

    if (( upload_skipped == 1 )) && (( download_skipped == 1 )); then
        qos_log "WARN" "上传和下载带宽均为0，QoS未启动任何方向"
    fi
    
    qos_log "INFO" "HFSC+CAKE QoS初始化完成"
    return 0
}

# ========== 停止函数 ==========
stop_hfsc_cake_qos() {
    qos_log "INFO" "停止HFSC+CAKE QoS"
    rm -f "$QOS_RUNNING_FILE"
    if [[ "$SAVE_NFT_RULES" == "1" ]]; then
        rm -f /etc/nftables.d/qos_gargoyle_*.nft 2>/dev/null
    fi
    if [[ -n "$qos_interface" ]] && ip link show "$qos_interface" >/dev/null 2>&1; then
        tc filter del dev "$qos_interface" parent 1:0 protocol all 2>/dev/null || true
        tc qdisc del dev "$qos_interface" ingress 2>/dev/null || true
        tc qdisc del dev "$qos_interface" root 2>/dev/null || true
    fi
    if [[ -n "$IFB_DEVICE" ]]; then
        if ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
            tc filter del dev "$IFB_DEVICE" parent 1:0 protocol all 2>/dev/null || true
            tc qdisc del dev "$IFB_DEVICE" ingress 2>/dev/null || true
            tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null || true
            ip link set dev "$IFB_DEVICE" down
            if [[ "${DELETE_IFB_ON_STOP:-0}" == "1" ]]; then
                if ! tc qdisc show dev "$IFB_DEVICE" 2>/dev/null | grep -q .; then
                    ip link del dev "$IFB_DEVICE" 2>/dev/null
                    qos_log "INFO" "IFB设备 $IFB_DEVICE 已删除"
                else
                    qos_log "INFO" "IFB设备 $IFB_DEVICE 仍有队列，保留"
                fi
            else
                qos_log "INFO" "IFB设备 $IFB_DEVICE 已停用（保留）"
            fi
        else
            qos_log "INFO" "IFB设备 $IFB_DEVICE 不存在，跳过"
        fi
    fi
    
    # 清理动态检测相关资源
    cleanup_dynamic_detection
    
    nft delete table inet gargoyle-qos-priority 2>/dev/null || true
    clear_class_marks
    qos_log "INFO" "HFSC+CAKE QoS停止完成"
    
    # 恢复配置（已在 common.sh 中增加有效性检查）
    restore_main_config
    
    _QOS_TABLE_FLUSHED=0
    _IPSET_LOADED=0
    cleanup_qos_state
    cleanup_temp_files
}

# ========== 状态显示函数 ==========
show_hfsc_cake_status() {
    # 从 UCI 获取真实 WAN 接口
    local real_wan_if=$(uci -q get ${CONFIG_FILE}.global.wan_interface 2>/dev/null)
    if [[ -z "$real_wan_if" ]] || [[ "$real_wan_if" == "auto" ]]; then
        if command -v network_find_wan >/dev/null 2>&1; then
            network_find_wan real_wan_if 2>/dev/null
        fi
        if [[ -z "$real_wan_if" ]]; then
            real_wan_if=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
        fi
        [[ -z "$real_wan_if" ]] && real_wan_if="未知"
    fi

    if [[ -z "$IFB_DEVICE" ]]; then
        IFB_DEVICE=$(uci -q get ${CONFIG_FILE}.download.ifb_device 2>/dev/null)
        [[ -z "$IFB_DEVICE" ]] && IFB_DEVICE="ifb0"
    fi
    local qos_ifb="$IFB_DEVICE"

    echo "===== HFSC-CAKE QoS 状态报告 ====="
    echo "时间: $(date)"
    echo "WAN接口: ${real_wan_if}"

    if [[ "$real_wan_if" == "未知" ]] || ! ip link show "$real_wan_if" >/dev/null 2>&1; then
        echo "警告: 无法确定有效的 WAN 接口，部分信息可能无法显示。"
    else
        if ! tc qdisc show dev "$real_wan_if" 2>/dev/null | grep -q hfsc; then
            echo "警告: 出口 QoS 未在接口 ${real_wan_if} 上激活"
        fi
    fi

    if [[ -n "$qos_ifb" ]] && ip link show "$qos_ifb" >/dev/null 2>&1; then
        if tc qdisc show dev "$qos_ifb" 2>/dev/null | grep -q "qdisc"; then
            echo "IFB设备: 已启动且运行中 ($qos_ifb)"
        else
            echo "IFB设备: 已创建但无 TC 队列 ($qos_ifb)"
        fi
    else
        echo "IFB设备: 未创建"
    fi

    if [[ "$real_wan_if" != "未知" ]] && ip link show "$real_wan_if" >/dev/null 2>&1; then
        echo -e "\n======== 出口QoS ($real_wan_if) ========"
        echo -e "\nTC队列:"
        tc -s qdisc show dev "$real_wan_if" 2>/dev/null | while read -r line; do
            if echo "$line" | grep -q "hfsc\|cake"; then
                echo "  $line"
            fi
        done
        if tc class show dev "$real_wan_if" >/dev/null 2>&1; then
            echo -e "\nTC类别:"
            tc -s class show dev "$real_wan_if" 2>/dev/null | while read -r line; do
                if echo "$line" | grep -q "hfsc"; then
                    echo "  $line"
                fi
            done
        fi
        echo -e "\nTC过滤器:"
        tc -s filter show dev "$real_wan_if" 2>/dev/null | while read -r line; do
            echo "  $line"
        done
    fi

    echo -e "\n======== nftables 分类规则 ========"
    if nft list table inet gargoyle-qos-priority &>/dev/null; then
        nft list table inet gargoyle-qos-priority 2>/dev/null | sed 's/^/  /'
    else
        echo "  nftables 表不存在"
    fi

    echo -e "\n======== 入口QoS ($qos_ifb) ========"
    if [[ -n "$qos_ifb" ]] && ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\nTC队列:"
        tc -s qdisc show dev "$qos_ifb" 2>/dev/null | while read -r line; do
            if echo "$line" | grep -q "hfsc\|cake"; then
                echo "  $line"
            fi
        done
        if tc class show dev "$qos_ifb" >/dev/null 2>&1; then
            echo -e "\nTC类别:"
            tc -s class show dev "$qos_ifb" 2>/dev/null | while read -r line; do
                if echo "$line" | grep -q "hfsc"; then
                    echo "  $line"
                fi
            done
        fi
        echo -e "\nTC过滤器:"
        tc -s filter show dev "$qos_ifb" 2>/dev/null | while read -r line; do
            echo "  $line"
        done

        echo -e "\n入口重定向检查:"
        if [[ "$real_wan_if" != "未知" ]] && ip link show "$real_wan_if" >/dev/null 2>&1; then
            if tc qdisc show dev "$real_wan_if" 2>/dev/null | grep -q "ingress"; then
                check_ingress_redirect "$real_wan_if" "$qos_ifb"
            else
                echo "  ✗ 入口队列未配置"
            fi
        else
            echo "  ✗ 无法检查入口重定向（WAN接口无效）"
        fi
    else
        echo "  IFB设备不存在，无入口配置"
    fi

    echo -e "\n===== QoS运行状态 ====="
    local upload_active=0
    local download_active=0
    if [[ "$real_wan_if" != "未知" ]] && ip link show "$real_wan_if" >/dev/null 2>&1; then
        tc qdisc show dev "$real_wan_if" 2>/dev/null | grep -q "hfsc" && upload_active=1
    fi
    [[ -n "$qos_ifb" ]] && tc qdisc show dev "$qos_ifb" 2>/dev/null | grep -q "hfsc" && download_active=1

    if (( upload_active == 1 )); then
        echo "上传QoS: 已启用 (HFSC+cake)"
    else
        echo "上传QoS: 未启用"
    fi

    if (( download_active == 1 )); then
        echo "下载QoS: 已启用 (HFSC+cake)"
    else
        echo "下载QoS: 未启用"
    fi

    if (( upload_active == 1 )) && (( download_active == 1 )); then
        echo -e "\n✓ QoS双向流量整形已启用"
    elif (( upload_active == 1 )) || (( download_active == 1 )); then
        echo -e "\n⚠ 部分方向QoS已启用"
    else
        echo -e "\n✗ QoS未运行"
    fi

    echo -e "\n===== 详细队列统计 ====="
    if [[ "$real_wan_if" != "未知" ]] && ip link show "$real_wan_if" >/dev/null 2>&1; then
        echo -e "\n上传方向cake队列:"
        tc -s qdisc show dev "$real_wan_if" 2>/dev/null | grep -A 3 "cake" | while read -r line; do
            if echo "$line" | grep -q "parent"; then
                echo "  $line"
            elif echo "$line" | grep -q "Sent" || echo "$line" | grep -q "maxpacket" || \
                 echo "$line" | grep -q "ecn_mark" || echo "$line" | grep -q "memory_used"; then
                echo "    $line"
            fi
        done
    fi

    if [[ -n "$qos_ifb" ]] && ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\n下载方向cake队列:"
        tc -s qdisc show dev "$qos_ifb" 2>/dev/null | grep -A 3 "cake" | while read -r line; do
            if echo "$line" | grep -q "parent"; then
                echo "  $line"
            elif echo "$line" | grep -q "Sent" || echo "$line" | grep -q "maxpacket" || \
                 echo "$line" | grep -q "ecn_mark" || echo "$line" | grep -q "memory_used"; then
                echo "    $line"
            fi
        done
    fi

    echo -e "\n===== 增强特性状态 ====="
    local rate_val=$(uci -q get ${CONFIG_FILE}.global.enable_ratelimit 2>/dev/null)
    local ack_val=$(uci -q get ${CONFIG_FILE}.ack_limit.enabled 2>/dev/null)
    local tcp_val=$(uci -q get ${CONFIG_FILE}.tcp_upgrade.enabled 2>/dev/null)
    local udp_val=$(uci -q get ${CONFIG_FILE}.udp_limit.enabled 2>/dev/null)

    case "$rate_val" in 1|yes|true|on) echo "速率限制: 已启用" ;; *) echo "速率限制: 未启用" ;; esac
    case "$ack_val"  in 1|yes|true|on) echo "ACK 限速: 已启用" ;; *) echo "ACK 限速: 未启用" ;; esac
    case "$tcp_val"  in 1|yes|true|on) echo "TCP 升级: 已启用" ;; *) echo "TCP 升级: 未启用" ;; esac
    case "$udp_val"  in 1|yes|true|on) echo "UDP 限速: 已启用" ;; *) echo "UDP 限速: 未启用" ;; esac

    echo -e "\n===== 健康检查 ====="
    health_check

    echo -e "\n===== 活动连接标记 ========"
    if ! command -v conntrack >/dev/null 2>&1; then
        echo "  conntrack 命令未安装，无法显示连接标记信息。"
        echo "  请安装 conntrack-tools 包以获取此功能。"
    else
        local wan_ipv4=""
        local wan_ipv6=""
        if [[ "$real_wan_if" != "未知" ]] && ip link show "$real_wan_if" >/dev/null 2>&1; then
            wan_ipv4=$(ip -4 addr show dev "$real_wan_if" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -1)
            [[ -z "$wan_ipv4" ]] && wan_ipv4=$(ifconfig "$real_wan_if" 2>/dev/null | grep "inet addr:" | awk '{print $2}' | cut -d: -f2)
            wan_ipv6=$(ip -6 addr show dev "$real_wan_if" 2>/dev/null | grep "inet6 " | grep -v "fe80::" | awk '{print $2}' | cut -d/ -f1 | head -1)
            [[ -z "$wan_ipv6" ]] && wan_ipv6=$(ifconfig "$real_wan_if" 2>/dev/null | grep "inet6 addr:" | grep -v "fe80::" | awk '{print $3}' | cut -d/ -f1)
        fi
        echo -e "\nIPv4 连接标记 (目标地址为 WAN):"
        if [[ -n "$wan_ipv4" ]]; then
            echo "WAN IPv4: $wan_ipv4"
            local ipv4_marks=$(conntrack -L -d "$wan_ipv4" 2>/dev/null | grep -E "mark=[0-9]+" | head -n 5)
            if [[ -n "$ipv4_marks" ]]; then
                echo "$ipv4_marks" | while IFS= read -r line; do
                    local src_ip=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^src=/) {sub(/^src=/, "", $i); print $i; exit}}')
                    local dst_ip=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^dst=/) {sub(/^dst=/, "", $i); print $i; exit}}')
                    local sport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^sport=/) {sub(/^sport=/, "", $i); print $i; exit}}')
                    local dport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^dport=/) {sub(/^dport=/, "", $i); print $i; exit}}')
                    local proto=$(echo "$line" | awk '{print $1}')
                    local dec_mark=$(echo "$line" | grep -o "mark=[0-9]\+" | cut -d= -f2 | head -1)
                    local mark_hex="0x$(printf '%x' "$dec_mark" 2>/dev/null || echo '0')"
                    printf "  %-7s %-15s:%-5s → %-15s:%-5s [标记: %s]\n" \
                        "$proto" "${src_ip:-N/A}" "${sport:-N/A}" "${dst_ip:-N/A}" "${dport:-N/A}" "$mark_hex"
                done
            else
                echo "  未找到带标记的 IPv4 连接"
            fi
        else
            echo "  WAN IPv4 地址不可用"
        fi
        echo -e "\nIPv6 连接标记 (目标地址为 WAN):"
        if [[ -n "$wan_ipv6" ]]; then
            echo "WAN IPv6: $wan_ipv6"
            local ipv6_marks=$(conntrack -L -d "$wan_ipv6" 2>/dev/null | grep -E "mark=[0-9]+" | head -n 5)
            if [[ -n "$ipv6_marks" ]]; then
                echo "$ipv6_marks" | while IFS= read -r line; do
                    local src_ip=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^src=/) {sub(/^src=/, "", $i); print $i; exit}}')
                    local dst_ip=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^dst=/) {sub(/^dst=/, "", $i); print $i; exit}}')
                    local sport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^sport=/) {sub(/^sport=/, "", $i); print $i; exit}}')
                    local dport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^dport=/) {sub(/^dport=/, "", $i); print $i; exit}}')
                    local proto=$(echo "$line" | awk '{print $1}')
                    local dec_mark=$(echo "$line" | grep -o "mark=[0-9]\+" | cut -d= -f2 | head -1)
                    local mark_hex="0x$(printf '%x' "$dec_mark" 2>/dev/null || echo '0')"
                    src_ip=$(echo "$src_ip" | sed 's/\(:\)[0:]*/\1/g')
                    dst_ip=$(echo "$dst_ip" | sed 's/\(:\)[0:]*/\1/g')
                    printf "  %-7s %-30s:%-5s → %-30s:%-5s [标记: %s]\n" \
                        "$proto" "${src_ip:-N/A}" "${sport:-N/A}" "${dst_ip:-N/A}" "${dport:-N/A}" "$mark_hex"
                done
            else
                echo "  未找到带标记的 IPv6 连接"
            fi
        else
            echo "  WAN IPv6 地址不可用"
        fi
        echo -e "\n上传方向连接标记 (源地址为 WAN):"
        if [[ -n "$wan_ipv4" ]]; then
            local upload_marks=$(conntrack -L -s "$wan_ipv4" 2>/dev/null | grep -E "mark=[0-9]+" | head -n 3)
            if [[ -n "$upload_marks" ]]; then
                echo "$upload_marks" | while IFS= read -r line; do
                    local src_ip=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^src=/) {sub(/^src=/, "", $i); print $i; exit}}')
                    local dst_ip=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^dst=/) {sub(/^dst=/, "", $i); print $i; exit}}')
                    local sport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^sport=/) {sub(/^sport=/, "", $i); print $i; exit}}')
                    local dport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^dport=/) {sub(/^dport=/, "", $i); print $i; exit}}')
                    local proto=$(echo "$line" | awk '{print $1}')
                    local dec_mark=$(echo "$line" | grep -o "mark=[0-9]\+" | cut -d= -f2 | head -1)
                    local mark_hex="0x$(printf '%x' "$dec_mark" 2>/dev/null || echo '0')"
                    printf "  %-7s %-15s:%-5s → %-15s:%-5s [标记: %s]\n" \
                        "$proto" "${src_ip:-N/A}" "${sport:-N/A}" "${dst_ip:-N/A}" "${dport:-N/A}" "$mark_hex"
                done
            else
                echo "  未找到带标记的上传方向连接"
            fi
        fi
    fi

    echo -e "\n===== HFSC-CAKE 状态报告结束 ====="
    return 0
}

# ========== 主入口 ==========
main_hfsc_cake_qos() {
    local action="$1"
    case "$action" in
        "start")
            if ! init_hfsc_cake_qos; then
                qos_log "ERROR" "HFSC+CAKE QoS启动失败"
                exit 1
            fi
            ;;
        "stop")
            stop_hfsc_cake_qos
            ;;
        "restart")
            stop_hfsc_cake_qos
            sleep 1
            if ! init_hfsc_cake_qos; then
                qos_log "ERROR" "HFSC+CAKE QoS重启失败"
                exit 1
            fi
            ;;
        "status")
            show_hfsc_cake_status
            ;;
        "health_check")
            health_check
            ;;
        "auto_speedtest")
            if ! auto_speedtest; then
                qos_log "ERROR" "自动速率测试失败"
                exit 1
            fi
           ;;
        *)
            echo "用法: $0 {start|stop|restart|status|health_check}"
            echo ""
            echo "命令:"
            echo "  start        启动HFSC+CAKE QoS"
            echo "  stop         停止HFSC+CAKE QoS"
            echo "  restart      重启HFSC+CAKE QoS"
            echo "  status       显示状态"
            echo "  health_check 执行健康检查"
            echo "  auto_speedtest   自动测速（测速或手动输入带宽）"
            exit 1
            ;;
    esac
}

if [[ "$(basename "$0")" == "hfsc_cake.sh" ]] || [[ "$(basename "$0")" == "hfsc-cake.sh" ]]; then
    main_hfsc_cake_qos "$1"
fi