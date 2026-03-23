#!/bin/bash
# HTB_FQCODEL算法实现模块
# 版本: 3.0.5 - 修复默认类ID范围、移除eval、改进connmark回退、优化停止逻辑
# 基于HTB与FQ_CODEL组合算法实现QoS流量控制。

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

# 锁持有标志（由 rule.sh 管理）
HAVE_LOCK=0

# 清理函数：合并 rule.sh 的临时文件清理和锁释放
main_cleanup() {
    cleanup_temp_files 2>/dev/null
    release_lock 2>/dev/null
}
trap main_cleanup EXIT INT TERM HUP QUIT

. /lib/functions.sh
. /lib/functions/network.sh
include /lib/network

# ========== 辅助函数：去除前导零 ==========
strip_leading_zeros() {
    local val="$1"
    val=$(echo "$val" | sed 's/^0*//')
    [[ -z "$val" ]] && val=0
    echo "$val"
}

# ========== 检查是否已经在运行 ==========
check_already_running() {
    if [[ -f "$QOS_RUNNING_FILE" ]]; then
        local old_pid=$(cat "$QOS_RUNNING_FILE" 2>/dev/null)
        if kill -0 "$old_pid" 2>/dev/null; then
            return 1
        else
            rm -f "$QOS_RUNNING_FILE"
        fi
    fi
    echo $$ > "$QOS_RUNNING_FILE"
    return 0
}

# ========== HTB 与 FQ_CODEL 专属配置加载 ==========
load_htb_fqcodel_config() {
    qos_log "INFO" "加载HTB与fq_codel配置"
    # 带宽已由主脚本加载并导出为环境变量，直接使用
    if [[ -z "$total_upload_bandwidth" ]] || [[ -z "$total_download_bandwidth" ]]; then
        qos_log "ERROR" "带宽环境变量未设置，请确保主脚本已正确加载带宽配置"
        return 1
    fi
    qos_log "INFO" "使用主脚本提供的带宽: 上传=${total_upload_bandwidth}kbit, 下载=${total_download_bandwidth}kbit"

    # IFB 设备：优先使用环境变量，否则从 UCI 读取或使用默认值
    if [[ -n "$IFB_DEVICE" ]]; then
        qos_log "INFO" "使用环境变量 IFB_DEVICE=$IFB_DEVICE"
    else
        IFB_DEVICE=$(uci -q get ${CONFIG_FILE}.download.ifb_device 2>/dev/null)
        [[ -z "$IFB_DEVICE" ]] && IFB_DEVICE="ifb0"
        qos_log "WARN" "IFB设备未通过环境变量传递，从 UCI 读取: $IFB_DEVICE"
    fi

    HTB_R2Q=$(uci -q get ${CONFIG_FILE}.htb.r2q 2>/dev/null)
    [[ -z "$HTB_R2Q" ]] && HTB_R2Q=10
    HTB_DRR_QUANTUM=$(uci -q get ${CONFIG_FILE}.htb.drr_quantum 2>/dev/null)
    [[ -z "$HTB_DRR_QUANTUM" ]] && HTB_DRR_QUANTUM="auto"

    # fq_codel 参数：提供合理的默认值
    FQCODEL_LIMIT=$(uci -q get ${CONFIG_FILE}.fq_codel.limit 2>/dev/null)
    if [[ -z "$FQCODEL_LIMIT" ]]; then
        FQCODEL_LIMIT=1000
        qos_log "WARN" "fq_codel limit 未配置，使用默认值: $FQCODEL_LIMIT"
    fi
    if ! validate_number "$FQCODEL_LIMIT" "fq_codel.limit" 1 65535; then
        qos_log "ERROR" "fq_codel limit 无效，使用默认值 1000"
        FQCODEL_LIMIT=1000
    fi

    FQCODEL_INTERVAL=$(uci -q get ${CONFIG_FILE}.fq_codel.interval 2>/dev/null)
    if [[ -z "$FQCODEL_INTERVAL" ]]; then
        FQCODEL_INTERVAL=100
        qos_log "WARN" "fq_codel interval 未配置，使用默认值: ${FQCODEL_INTERVAL}us"
    fi
    if ! validate_number "$FQCODEL_INTERVAL" "fq_codel.interval" 1 1000000; then
        qos_log "ERROR" "fq_codel interval 无效，使用默认值 100"
        FQCODEL_INTERVAL=100
    fi

    FQCODEL_TARGET=$(uci -q get ${CONFIG_FILE}.fq_codel.target 2>/dev/null)
    if [[ -z "$FQCODEL_TARGET" ]]; then
        FQCODEL_TARGET=5
        qos_log "WARN" "fq_codel target 未配置，使用默认值: ${FQCODEL_TARGET}us"
    fi
    if ! validate_number "$FQCODEL_TARGET" "fq_codel.target" 1 1000000; then
        qos_log "ERROR" "fq_codel target 无效，使用默认值 5"
        FQCODEL_TARGET=5
    fi

    FQCODEL_FLOWS=$(uci -q get ${CONFIG_FILE}.fq_codel.flows 2>/dev/null)
    if [[ -z "$FQCODEL_FLOWS" ]]; then
        FQCODEL_FLOWS=1024
        qos_log "WARN" "fq_codel flows 未配置，使用默认值: $FQCODEL_FLOWS"
    fi
    if ! validate_number "$FQCODEL_FLOWS" "fq_codel.flows" 1 65535; then
        qos_log "ERROR" "fq_codel flows 无效，使用默认值 1024"
        FQCODEL_FLOWS=1024
    fi

    FQCODEL_QUANTUM=$(uci -q get ${CONFIG_FILE}.fq_codel.quantum 2>/dev/null)
    if [[ -z "$FQCODEL_QUANTUM" ]]; then
        FQCODEL_QUANTUM=300
        qos_log "WARN" "fq_codel quantum 未配置，使用默认值: $FQCODEL_QUANTUM"
    fi
    if ! validate_number "$FQCODEL_QUANTUM" "fq_codel.quantum" 1 10000; then
        qos_log "ERROR" "fq_codel quantum 无效，使用默认值 300"
        FQCODEL_QUANTUM=300
    fi

    FQCODEL_MEMORY_LIMIT=$(uci -q get ${CONFIG_FILE}.fq_codel.memory_limit 2>/dev/null)
    if [[ -n "$FQCODEL_MEMORY_LIMIT" ]]; then
        FQCODEL_MEMORY_LIMIT=$(calculate_memory_limit "$FQCODEL_MEMORY_LIMIT")
        FQCODEL_MEMORY_LIMIT=$(echo "$FQCODEL_MEMORY_LIMIT" | tr 'A-Z' 'a-z')
    fi

    FQCODEL_CE_THRESHOLD=$(uci -q get ${CONFIG_FILE}.fq_codel.ce_threshold 2>/dev/null)
    if [[ -n "$FQCODEL_CE_THRESHOLD" ]]; then
        if ! echo "$FQCODEL_CE_THRESHOLD" | grep -qiE '^0$|^[0-9]+(\.[0-9]+)?(us|ms)?$'; then
            qos_log "WARN" "无效的 ce_threshold 格式 '$FQCODEL_CE_THRESHOLD'，将忽略此设置"
            FQCODEL_CE_THRESHOLD=""
        fi
    fi

    FQCODEL_ECN=$(uci -q get ${CONFIG_FILE}.fq_codel.ecn 2>/dev/null)
    if [[ -n "$FQCODEL_ECN" ]]; then
        case "$FQCODEL_ECN" in
            yes|1|enable|on|true) FQCODEL_ECN="ecn"; qos_log "INFO" "fq_codel ECN: 启用" ;;
            no|0|disable|off|false) FQCODEL_ECN="noecn"; qos_log "INFO" "fq_codel ECN: 禁用" ;;
            ecn|noecn) qos_log "INFO" "fq_codel ECN: 使用配置值 ($FQCODEL_ECN)" ;;
            *) qos_log "WARN" "无效的ECN配置值 '$FQCODEL_ECN'，将不使用ECN"; FQCODEL_ECN="" ;;
        esac
    else
        FQCODEL_ECN=""
        qos_log "INFO" "fq_codel ECN: 未配置"
    fi

    qos_log "INFO" "HTB配置: R2Q=${HTB_R2Q}, DRR量子=${HTB_DRR_QUANTUM}"
    qos_log "INFO" "fq_codel参数: limit=${FQCODEL_LIMIT}, interval=${FQCODEL_INTERVAL}us, target=${FQCODEL_TARGET}us, flows=${FQCODEL_FLOWS}, quantum=${FQCODEL_QUANTUM}, memory_limit=${FQCODEL_MEMORY_LIMIT:-未配置}, ce_threshold=${FQCODEL_CE_THRESHOLD:-未配置}, ecn=${FQCODEL_ECN:-未配置}"
    return 0
}

# 加载HTB类别配置（使用全局变量传递）
load_htb_class_config() {
    local class_name="$1"
    local percent_bandwidth per_min_bandwidth per_max_bandwidth priority name
    qos_log "INFO" "加载HTB类别配置: $class_name"
    percent_bandwidth=$(uci -q get ${CONFIG_FILE}.$class_name.percent_bandwidth 2>/dev/null)
    per_min_bandwidth=$(uci -q get ${CONFIG_FILE}.$class_name.per_min_bandwidth 2>/dev/null)
    per_max_bandwidth=$(uci -q get ${CONFIG_FILE}.$class_name.per_max_bandwidth 2>/dev/null)
    priority=$(uci -q get ${CONFIG_FILE}.$class_name.priority 2>/dev/null)
    name=$(uci -q get ${CONFIG_FILE}.$class_name.name 2>/dev/null)

    # 验证并去除前导零
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
    if [[ -n "$priority" ]]; then
        if validate_number "$priority" "$class_name.priority" 0 7; then
            priority=$(strip_leading_zeros "$priority")
        else
            priority=""
        fi
    fi

    qos_log "DEBUG" "HTB配置: $class_name -> percent=$percent_bandwidth, min=$per_min_bandwidth, max=$per_max_bandwidth, priority=$priority"
    if [[ -z "$percent_bandwidth" ]] && [[ -z "$per_min_bandwidth" ]] && [[ -z "$per_max_bandwidth" ]]; then
        qos_log "WARN" "未找到 $class_name 的带宽参数"
        return 1
    fi
    # 使用全局变量传递
    HTB_CLASS_PERCENT="$percent_bandwidth"
    HTB_CLASS_MIN="$per_min_bandwidth"
    HTB_CLASS_MAX="$per_max_bandwidth"
    HTB_CLASS_PRIO="$priority"
    HTB_CLASS_NAME="$name"
    return 0
}

# 以下函数已在 rule.sh 中定义，但为保持兼容性保留
load_upload_class_configurations() {
    qos_log "INFO" "正在加载上传类别配置..."
    upload_class_list=$(load_all_config_sections "$CONFIG_FILE" "upload_class")
    if [[ -n "$upload_class_list" ]]; then
        qos_log "INFO" "找到上传类别: $upload_class_list"
    else
        qos_log "WARN" "没有找到上传类别配置"
        upload_class_list=""
    fi
    return 0
}

load_download_class_configurations() {
    qos_log "INFO" "正在加载下载类别配置..."
    download_class_list=$(load_all_config_sections "$CONFIG_FILE" "download_class")
    if [[ -n "$download_class_list" ]]; then
        qos_log "INFO" "找到下载类别: $download_class_list"
    else
        qos_log "WARN" "没有找到下载类别配置"
        download_class_list=""
    fi
    return 0
}

# ========== HTB 辅助函数（优化 burst 计算） ==========
calculate_htb_burst() {
    local rate="$1"  # 单位: kbit
    local ceil="$2"  # 单位: kbit
    local mtu="$3"   # MTU大小
    if [[ -z "$mtu" ]]; then
        mtu=1500
    fi

    # 使用向上取整确保 burst 不小于 MTU 的三倍
    local burst_kb=$(awk "BEGIN {printf \"%.0f\", ($rate + 7) / 8}")
    local min_burst_kb=$((mtu * 3 / 1024))
    (( min_burst_kb < 1 )) && min_burst_kb=1
    (( burst_kb < min_burst_kb )) && burst_kb=$min_burst_kb
    # 限制 burst 最大为 1GB，避免 tc 拒绝
    if (( burst_kb > 1048576 )); then
        burst_kb=1048576
        qos_log "WARN" "burst值超过1GB，已限制为1048576KB"
    fi
    local cburst_kb=$((burst_kb * 2))
    (( cburst_kb > 1048576 )) && cburst_kb=1048576
    echo "${burst_kb}kb ${cburst_kb}kb"
}

# ========== fq_codel 参数构建 ==========
build_fq_codel_params() {
    local params="limit ${FQCODEL_LIMIT} target ${FQCODEL_TARGET} interval ${FQCODEL_INTERVAL} flows ${FQCODEL_FLOWS} quantum ${FQCODEL_QUANTUM}"
    if [[ -n "$FQCODEL_MEMORY_LIMIT" ]]; then
        params="$params memory_limit ${FQCODEL_MEMORY_LIMIT}"
    fi
    if [[ -n "$FQCODEL_CE_THRESHOLD" ]]; then
        params="$params ce_threshold ${FQCODEL_CE_THRESHOLD}"
    fi
    if [[ -n "$FQCODEL_ECN" ]]; then
        params="$params $FQCODEL_ECN"
    fi
    echo "$params"
}

# ========== HTB 核心队列函数（修正默认类范围） ==========
create_htb_root_qdisc() {
    local device="$1"
    local direction="$2"
    local root_handle="$3"
    local root_classid="$4"
    local default_classid="$5"   # 默认类ID
    local bandwidth=""
    if [[ "$direction" == "upload" ]]; then
        bandwidth="$total_upload_bandwidth"
    elif [[ "$direction" == "download" ]]; then
        bandwidth="$total_download_bandwidth"
    else
        qos_log "ERROR" "未知方向: $direction"
        return 1
    fi
    if ! validate_number "$bandwidth" "bandwidth" 1 "$MAX_PHYSICAL_BANDWIDTH"; then
        qos_log "ERROR" "无效的带宽值: $bandwidth"
        return 1
    fi
    qos_log "INFO" "为$device创建$direction方向HTB根队列 (带宽: ${bandwidth}kbit)"
    tc qdisc del dev "$device" ingress 2>/dev/null || true
    tc qdisc del dev "$device" root 2>/dev/null || true

    local default_opt=""
    # 修正默认类ID范围：支持最多16个启用类，索引最大17
    if [[ -n "$default_classid" ]]; then
        if validate_number "$default_classid" "default_classid" 2 17; then
            default_opt="default $default_classid"
        else
            qos_log "ERROR" "无效的默认类ID: $default_classid (有效范围 2-17)"
            return 1
        fi
    else
        qos_log "ERROR" "未指定默认类ID"
        return 1
    fi

    if ! tc qdisc add dev "$device" root handle $root_handle htb r2q $HTB_R2Q $default_opt; then
        qos_log "ERROR" "无法在 $device 上创建HTB根队列"
        return 1
    fi
    local burst_params=$(calculate_htb_burst "$bandwidth" "$bandwidth")
    local burst=$(echo "$burst_params" | awk '{print $1}')
    local cburst=$(echo "$burst_params" | awk '{print $2}')
    if ! tc class add dev "$device" parent $root_handle classid $root_classid htb \
        rate ${bandwidth}kbit ceil ${bandwidth}kbit burst $burst cburst $cburst; then
        qos_log "ERROR" "无法在$device上创建HTB根类"
        tc qdisc del dev "$device" root 2>/dev/null
        return 1
    fi
    qos_log "INFO" "$device的$direction方向HTB根队列创建完成"
    return 0
}

create_htb_upload_class() {
    local class_name="$1"
    local class_index="$2"
    qos_log "INFO" "创建上传类别: $class_name, ID: 1:$class_index"
    if ! load_htb_class_config "$class_name"; then
        qos_log "ERROR" "加载HTB配置失败: $class_name"
        return 1
    fi
    # 使用全局变量
    local percent_bandwidth="$HTB_CLASS_PERCENT"
    local per_min_bandwidth="$HTB_CLASS_MIN"
    local per_max_bandwidth="$HTB_CLASS_MAX"
    local priority="$HTB_CLASS_PRIO"
    local name="$HTB_CLASS_NAME"
    
    local class_mark
    class_mark=$(get_class_mark "upload" "$class_name")
    if [[ -z "$class_mark" ]]; then
        qos_log "ERROR" "无法获取类别 $class_name 的标记"
        return 1
    fi
    qos_log "INFO" "类别 $class_name 使用的标记: 0x$(printf '%X' $class_mark)"
    local rate=""
    local ceil=""
    local rate_value=0
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
    if [[ -n "$per_min_bandwidth" ]] && (( per_min_bandwidth >= 0 )); then
        if (( per_min_bandwidth == 0 )); then
            rate="1kbit"
            rate_value=1
            qos_log "INFO" "类别 $class_name 设置最小保证带宽: $rate (per_min_bandwidth=0)"
        else
            rate_value=$((class_total_bw * per_min_bandwidth / 100))
            (( rate_value < 1 )) && rate_value=1
            rate="${rate_value}kbit"
            qos_log "INFO" "类别 $class_name 使用百分比计算保证带宽: $rate (${per_min_bandwidth}% of ${class_total_bw}kbit)"
        fi
    else
        rate_value=$((class_total_bw * 50 / 100))
        (( rate_value < 1 )) && rate_value=1
        rate="${rate_value}kbit"
        qos_log "INFO" "类别 $class_name 使用默认保证带宽: $rate (50% of ${class_total_bw}kbit)"
    fi
    if [[ -n "$per_max_bandwidth" ]] && (( per_max_bandwidth > 0 )); then
        ceil="$((class_total_bw * per_max_bandwidth / 100))kbit"
        qos_log "INFO" "类别 $class_name 使用百分比计算上限带宽: $ceil (${per_max_bandwidth}% of ${class_total_bw}kbit)"
    else
        ceil="${class_total_bw}kbit"
        qos_log "INFO" "类别 $class_name 使用类别总带宽作为上限带宽: $ceil"
    fi
    local ceil_value=$(echo "$ceil" | sed 's/kbit//')
    if (( rate_value > ceil_value )); then
        qos_log "WARN" "类别 $class_name 保证带宽($rate)超过上限带宽($ceil)，调整为上限带宽"
        rate="$ceil"
        rate_value="$ceil_value"
    fi
    local mtu=$(cat /sys/class/net/$qos_interface/mtu 2>/dev/null || echo 1500)
    local burst_params=$(calculate_htb_burst "$rate_value" "$ceil_value" "$mtu")
    local burst=$(echo "$burst_params" | awk '{print $1}')
    local cburst=$(echo "$burst_params" | awk '{print $2}')
    local prio="prio 3"
    if [[ -n "$priority" ]] && (( priority >= 0 && priority <= 7 )); then
        prio="prio $priority"
    fi
    qos_log "INFO" "正在创建HTB类别 1:$class_index (rate=$rate, ceil=$ceil, burst=$burst, cburst=$cburst, $prio)"
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:$class_index htb \
        rate $rate ceil $ceil burst $burst cburst $cburst $prio; then
        qos_log "ERROR" "创建上传类别 1:$class_index 失败"
        return 1
    fi
    local fq_codel_params=$(build_fq_codel_params)
    qos_log "INFO" "添加上传fq_codel队列参数: $fq_codel_params"
    if ! tc qdisc add dev "$qos_interface" parent 1:$class_index \
        handle ${class_index}:1 fq_codel $fq_codel_params; then
        qos_log "ERROR" "添加上传fq_codel队列失败"
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
    qos_log "INFO" "上传类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, 带宽: rate=$rate, ceil=$ceil)"
    return 0
}

create_htb_download_class() {
    local class_name="$1"
    local class_index="$2"
    local filter_prio="$3"
    local ifb_dev="$IFB_DEVICE"
    qos_log "INFO" "创建下载类别: $class_name, ID: 1:$class_index, 过滤器优先级: $filter_prio"
    if ! ip link show dev "$ifb_dev" >/dev/null 2>&1; then
        qos_log "ERROR" "IFB设备 $ifb_dev 不存在，无法创建下载类"
        return 1
    fi
    if ! load_htb_class_config "$class_name"; then
        qos_log "ERROR" "加载HTB配置失败: $class_name"
        return 1
    fi
    local percent_bandwidth="$HTB_CLASS_PERCENT"
    local per_min_bandwidth="$HTB_CLASS_MIN"
    local per_max_bandwidth="$HTB_CLASS_MAX"
    local priority="$HTB_CLASS_PRIO"
    local name="$HTB_CLASS_NAME"
    
    local class_mark
    class_mark=$(get_class_mark "download" "$class_name")
    if [[ -z "$class_mark" ]]; then
        qos_log "ERROR" "无法获取类别 $class_name 的标记"
        return 1
    fi
    qos_log "INFO" "类别 $class_name 使用的标记: 0x$(printf '%X' $class_mark)"
    local rate=""
    local ceil=""
    local rate_value=0
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
            rate="1kbit"
            rate_value=1
            qos_log "INFO" "类别 $class_name 设置最小保证带宽: $rate (per_min_bandwidth=0)"
        else
            rate_value=$((class_total_bw * per_min_bandwidth / 100))
            (( rate_value < 1 )) && rate_value=1
            rate="${rate_value}kbit"
            qos_log "INFO" "类别 $class_name 使用百分比计算保证带宽: $rate (${per_min_bandwidth}% of ${class_total_bw}kbit)"
        fi
    else
        rate_value=$((class_total_bw * 50 / 100))
        (( rate_value < 1 )) && rate_value=1
        rate="${rate_value}kbit"
        qos_log "INFO" "类别 $class_name 使用默认保证带宽: $rate (50% of ${class_total_bw}kbit)"
    fi
    if [[ -n "$per_max_bandwidth" ]] && (( per_max_bandwidth > 0 )); then
        ceil="$((class_total_bw * per_max_bandwidth / 100))kbit"
        qos_log "INFO" "类别 $class_name 使用百分比计算上限带宽: $ceil (${per_max_bandwidth}% of ${class_total_bw}kbit)"
    else
        ceil="${class_total_bw}kbit"
        qos_log "INFO" "类别 $class_name 使用类别总带宽作为上限带宽: $ceil"
    fi
    local ceil_value=$(echo "$ceil" | sed 's/kbit//')
    if (( rate_value > ceil_value )); then
        qos_log "WARN" "类别 $class_name 保证带宽($rate)超过上限带宽($ceil)，调整为上限带宽"
        rate="$ceil"
        rate_value="$ceil_value"
    fi
    local mtu=$(cat /sys/class/net/$ifb_dev/mtu 2>/dev/null || echo 1500)
    local burst_params=$(calculate_htb_burst "$rate_value" "$ceil_value" "$mtu")
    local burst=$(echo "$burst_params" | awk '{print $1}')
    local cburst=$(echo "$burst_params" | awk '{print $2}')
    local prio="prio 3"
    if [[ -n "$priority" ]] && (( priority >= 0 && priority <= 7 )); then
        prio="prio $priority"
    fi
    qos_log "INFO" "正在创建下载HTB类别 1:$class_index (rate=$rate, ceil=$ceil, burst=$burst, cburst=$cburst, $prio)"
    if ! tc class add dev "$ifb_dev" parent 1:1 \
        classid 1:$class_index htb \
        rate $rate ceil $ceil burst $burst cburst $cburst $prio; then
        qos_log "ERROR" "创建下载类别 1:$class_index 失败"
        return 1
    fi
    local fq_codel_params=$(build_fq_codel_params)
    qos_log "INFO" "添加下载fq_codel队列参数: $fq_codel_params"
    if ! tc qdisc add dev "$ifb_dev" parent 1:$class_index \
        handle ${class_index}:1 fq_codel $fq_codel_params; then
        qos_log "ERROR" "添加下载fq_codel队列失败"
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
    qos_log "INFO" "下载类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, 带宽: rate=$rate, ceil=$ceil)"
    return 0
}

# ========== 入口重定向（改进 connmark 回退） ==========
setup_ingress_redirect() {
    if [[ -z "$qos_interface" ]]; then
        qos_log "ERROR" "无法确定 WAN 接口"
        return 1
    fi

    # 检查 tc connmark 动作支持
    local connmark_ok=0
    if check_tc_connmark_support; then
        connmark_ok=1
        qos_log "INFO" "tc connmark 动作受支持"
    else
        qos_log "WARN" "tc connmark 动作不受支持，入口重定向将不使用 connmark，标记可能无法传递"
    fi

    qos_log "INFO" "设置入口重定向: $qos_interface -> $IFB_DEVICE"
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null || true
    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        qos_log "ERROR" "无法在 $qos_interface 上创建入口队列"
        return 1
    fi
    tc filter del dev "$qos_interface" parent ffff: 2>/dev/null || true

    # IPv4 重定向
    if (( connmark_ok )); then
        if ! tc filter add dev "$qos_interface" parent ffff: protocol ip \
            u32 match u32 0 0 \
            action connmark \
            action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
            qos_log "ERROR" "IPv4入口重定向规则添加失败（使用 connmark）"
            tc qdisc del dev "$qos_interface" ingress 2>/dev/null
            return 1
        else
            qos_log "INFO" "IPv4入口重定向规则添加成功（使用 connmark）"
        fi
    else
        # 降级：不使用 connmark，仅重定向
        if ! tc filter add dev "$qos_interface" parent ffff: protocol ip \
            u32 match u32 0 0 \
            action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
            qos_log "ERROR" "IPv4入口重定向规则添加失败（无 connmark）"
            tc qdisc del dev "$qos_interface" ingress 2>/dev/null
            return 1
        else
            qos_log "WARN" "IPv4入口重定向规则添加成功（未使用 connmark，标记将丢失）"
        fi
    fi

    local has_ipv6_global=0
    if ip -6 addr show dev "$qos_interface" scope global 2>/dev/null | grep -q "inet6"; then
        has_ipv6_global=1
        qos_log "INFO" "接口 $qos_interface 拥有全局 IPv6 地址，将强制 IPv6 重定向必须成功"
    else
        qos_log "INFO" "接口 $qos_interface 无全局 IPv6 地址，IPv6 重定向失败仅警告"
    fi

    # IPv6 重定向，尝试多种匹配方式
    local ipv6_success=false
    if (( connmark_ok )); then
        # 第一优先：flower 匹配全球单播地址 (2000::/3)
        if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
            flower dst_ip 2000::/3 \
            action connmark \
            action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
            ipv6_success=true
            qos_log "INFO" "IPv6入口重定向规则（flower 匹配全球单播，带 connmark）添加成功"
        else
            qos_log "WARN" "flower 规则添加失败，尝试 u32 全球单播匹配"
            if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                u32 match u32 0x20000000 0xe0000000 at 24 \
                action connmark \
                action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                ipv6_success=true
                qos_log "INFO" "IPv6入口重定向规则（u32 全球单播，带 connmark）添加成功"
            else
                qos_log "WARN" "u32 全球单播规则添加失败，尝试无过滤规则"
                if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                    u32 match u32 0 0 \
                    action connmark \
                    action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                    ipv6_success=true
                    qos_log "INFO" "IPv6入口重定向规则（无过滤，带 connmark）添加成功"
                else
                    ipv6_success=false
                    qos_log "WARN" "IPv6入口重定向规则添加失败，IPv6流量将不会通过IFB"
                fi
            fi
        fi
    else
        # 不使用 connmark
        if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
            flower dst_ip 2000::/3 \
            action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
            ipv6_success=true
            qos_log "INFO" "IPv6入口重定向规则（flower 匹配全球单播，无 connmark）添加成功"
        else
            if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                u32 match u32 0x20000000 0xe0000000 at 24 \
                action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                ipv6_success=true
                qos_log "INFO" "IPv6入口重定向规则（u32 全球单播，无 connmark）添加成功"
            else
                if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                    u32 match u32 0 0 \
                    action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                    ipv6_success=true
                    qos_log "INFO" "IPv6入口重定向规则（无过滤，无 connmark）添加成功"
                else
                    ipv6_success=false
                    qos_log "WARN" "IPv6入口重定向规则添加失败，IPv6流量将不会通过IFB"
                fi
            fi
        fi
    fi

    if (( has_ipv6_global == 1 )); then
        if [[ "$ipv6_success" != "true" ]]; then
            qos_log "ERROR" "接口存在全局 IPv6 地址，但 IPv6 入口重定向配置失败，QoS 无法正常工作"
            tc qdisc del dev "$qos_interface" ingress 2>/dev/null
            return 1
        else
            qos_log "INFO" "IPv6 入口重定向成功（强制）"
        fi
    else
        if [[ "$ipv6_success" == "true" ]]; then
            qos_log "INFO" "IPv6 入口重定向成功（尽管无全局 IPv6 地址，仍添加了规则）"
        else
            qos_log "WARN" "IPv6 入口重定向失败，但因接口无全局 IPv6 地址，继续启动"
        fi
    fi

    local ipv4_rule_count=$(tc filter show dev "$qos_interface" parent ffff: protocol ip 2>/dev/null | grep -c "mirred.*Redirect to device $IFB_DEVICE")
    local ipv6_rule_count=$(tc filter show dev "$qos_interface" parent ffff: protocol ipv6 2>/dev/null | grep -c "mirred.*Redirect to device $IFB_DEVICE")
    if (( ipv4_rule_count >= 1 )) && (( ipv6_rule_count >= 1 )); then
        qos_log "INFO" "入口重定向已成功设置: IPv4和IPv6规则均生效"
    elif (( ipv4_rule_count >= 1 )); then
        qos_log "INFO" "入口重定向已成功设置: 仅IPv4生效"
    fi
    return 0
}

check_ingress_redirect() {
    local iface="$1"
    local ifb_dev="$2"
    [[ -z "$ifb_dev" ]] && ifb_dev="$IFB_DEVICE"
    echo "检查入口重定向 (接口: $iface, IFB设备: $ifb_dev)"
    echo "  IPv4入口规则:"
    local ipv4_rules=$(tc filter show dev "$iface" parent ffff: protocol ip 2>/dev/null)
    if [[ -n "$ipv4_rules" ]]; then
        echo "$ipv4_rules" | sed 's/^/    /'
        if echo "$ipv4_rules" | grep -q "mirred.*Redirect to device $ifb_dev"; then
            echo "    ✓ IPv4 重定向到 $ifb_dev: 已生效"
        else
            echo "    ✗ IPv4 重定向: mirred动作未找到"
        fi
    else
        echo "    无IPv4入口规则"
    fi
    echo ""
    echo "  IPv6入口规则:"
    local ipv6_rules=$(tc filter show dev "$iface" parent ffff: protocol ipv6 2>/dev/null)
    if [[ -n "$ipv6_rules" ]]; then
        echo "$ipv6_rules" | sed 's/^/    /'
        if echo "$ipv6_rules" | grep -q "mirred.*Redirect to device $ifb_dev"; then
            echo "    ✓ IPv6 重定向到 $ifb_dev: 已生效"
        else
            echo "    ✗ IPv6 重定向: mirred动作未找到"
        fi
    else
        echo "    无IPv6入口规则"
    fi
    return 0
}

# ========== 上传方向初始化（使用关联数组替换 eval） ==========
init_htb_fqcodel_upload() {
    qos_log "INFO" "初始化上传方向HTB"
    load_upload_class_configurations
    if [[ -z "$upload_class_list" ]]; then
        qos_log "ERROR" "未找到上传类别配置，请至少配置一个上传类"
        return 1
    fi

    # 检查所有类的数量（包括禁用），防止标记冲突
    local total_classes=0
    for class in $upload_class_list; do
        ((total_classes++))
    done
    if (( total_classes > 16 )); then
        qos_log "ERROR" "上传方向总类别数量为 $total_classes，超过16个，将导致标记冲突，启动中止！"
        return 1
    fi

    # 构建启用类列表并计算索引
    local enabled_classes=""
    local class_index=2
    local default_class_index=""
    local default_class_name=""
    local first_enabled_class=""

    # 使用关联数组存储类索引
    declare -A class_index_map

    # 获取配置的默认类
    default_class_name=$(uci -q get ${CONFIG_FILE}.upload.default_class 2>/dev/null)

    for class in $upload_class_list; do
        local enabled=$(uci -q get ${CONFIG_FILE}.${class}.enabled 2>/dev/null)
        if [[ "$enabled" == "1" ]] || [[ -z "$enabled" ]]; then
            enabled_classes="$enabled_classes $class"
            [[ -z "$first_enabled_class" ]] && first_enabled_class="$class"
            # 记录该类的索引
            class_index_map["$class"]=$class_index
            # 判断是否为默认类
            if [[ -n "$default_class_name" ]] && [[ "$class" == "$default_class_name" ]]; then
                default_class_index=$class_index
            fi
            ((class_index++))
        fi
    done
    enabled_classes=$(echo "$enabled_classes" | xargs)  # 去除多余空格

    if [[ -z "$enabled_classes" ]]; then
        qos_log "ERROR" "没有启用的上传类，请至少启用一个上传类"
        return 1
    fi

    # 确定默认类索引
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

    # 创建根队列，直接指定默认类
    if ! create_htb_root_qdisc "$qos_interface" "upload" "1:0" "1:1" "$default_class_index"; then
        qos_log "ERROR" "创建上传根队列失败"
        return 1
    fi

    # 创建各个子类
    upload_class_mark_list=""
    for class_name in $enabled_classes; do
        local idx=${class_index_map["$class_name"]}
        if create_htb_upload_class "$class_name" "$idx"; then
            local class_mark_hex=$(get_class_mark "upload" "$class_name")
            upload_class_mark_list="$upload_class_mark_list$class_name:0x$(printf '%X' $class_mark_hex) "
        else
            qos_log "ERROR" "创建上传类别 $class_name 失败，停止初始化"
            tc qdisc del dev "$qos_interface" root 2>/dev/null
            return 1
        fi
    done

    qos_log "INFO" "上传方向HTB初始化完成"
    return 0
}

# ========== 下载方向初始化（使用关联数组替换 eval） ==========
init_htb_fqcodel_download() {
    qos_log "INFO" "初始化下载方向HTB"
    load_download_class_configurations
    if [[ -z "$download_class_list" ]]; then
        qos_log "ERROR" "未找到下载类别配置，请至少配置一个下载类"
        return 1
    fi

    # 检查所有类的数量（包括禁用），防止标记冲突
    local total_classes=0
    for class in $download_class_list; do
        ((total_classes++))
    done
    if (( total_classes > 16 )); then
        qos_log "ERROR" "下载方向总类别数量为 $total_classes，超过16个，将导致标记冲突，启动中止！"
        return 1
    fi

    # 构建启用类列表并计算索引
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

    if ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        qos_log "ERROR" "IFB设备 $IFB_DEVICE 不存在"
        return 1
    fi
    if ! ip link set dev "$IFB_DEVICE" up; then
        qos_log "ERROR" "无法启动IFB设备 $IFB_DEVICE"
        return 1
    fi
    if ! create_htb_root_qdisc "$IFB_DEVICE" "download" "1:0" "1:1" "$default_class_index"; then
        qos_log "ERROR" "创建下载根队列失败"
        return 1
    fi

    local filter_prio=3
    download_class_mark_list=""
    for class_name in $enabled_classes; do
        local idx=${class_index_map["$class_name"]}
        if create_htb_download_class "$class_name" "$idx" "$filter_prio"; then
            local class_mark_hex=$(get_class_mark "download" "$class_name")
            download_class_mark_list="$download_class_mark_list$class_name:0x$(printf '%X' $class_mark_hex) "
        else
            qos_log "ERROR" "创建下载类别 $class_name 失败，停止初始化"
            tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null
            return 1
        fi
        filter_prio=$((filter_prio + 2))
    done

    if ! setup_ingress_redirect; then
        qos_log "ERROR" "设置入口重定向失败"
        return 1
    fi
    qos_log "INFO" "下载方向HTB初始化完成"
    return 0
}

# ========== HTB 增强规则链 ==========
setup_htb_enhance_chains() {
    qos_log "INFO" "设置HTB增强规则链"
    nft add chain inet gargoyle-qos-priority filter_qos_egress_enhance 2>/dev/null || true
    nft add chain inet gargoyle-qos-priority filter_qos_ingress_enhance 2>/dev/null || true
    nft insert rule inet gargoyle-qos-priority filter_qos_egress \
        jump filter_qos_egress_enhance 2>/dev/null || true
    nft insert rule inet gargoyle-qos-priority filter_qos_ingress \
        jump filter_qos_ingress_enhance 2>/dev/null || true
}

apply_htb_specific_rules() {
    qos_log "INFO" "应用HTB特定增强规则（专用链）"
    nft flush chain inet gargoyle-qos-priority filter_qos_egress_enhance 2>/dev/null || true
    nft flush chain inet gargoyle-qos-priority filter_qos_ingress_enhance 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_qos_egress_enhance \
        meta mark and 0x007f != 0 counter meta priority set "bulk" 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_qos_ingress_enhance \
        meta mark and 0x7f00 != 0 counter meta priority set "bulk" 2>/dev/null || true
    # 将连接跟踪标记复制到包标记（用于保持标记连续性）
    nft add rule inet gargoyle-qos-priority filter_qos_egress_enhance \
        ct state established,related counter meta mark set ct mark 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_qos_egress_enhance \
        meta mark and 0x0010 != 0 counter meta priority set "critical" 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_qos_ingress_enhance \
        meta mark and 0x1000 != 0 counter meta priority set "critical" 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_qos_egress_enhance \
        ct bytes lt 200 counter meta priority set "normal" 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_qos_ingress_enhance \
        ct bytes lt 200 counter meta priority set "normal" 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_qos_egress_enhance \
        tcp flags syn tcp option maxseg size set rt mtu counter meta mark set 0x3F 2>/dev/null || true
    qos_log "INFO" "HTB特定增强规则应用完成"
}

# ========== 主初始化函数 ==========
init_htb_fqcodel_qos() {
    local action="${1:-start}"
    qos_log "INFO" "开始初始化HTB+FQ_CODEL QoS系统 (action=$action)"
    acquire_lock
    if ! check_already_running; then
        qos_log "ERROR" "HTB+FQ_CODEL QoS 已经在运行中"
        release_lock
        return 1
    fi
    if ! init_ruleset; then
        qos_log "ERROR" "初始化规则集失败，QoS 无法启动"
        release_lock
        rm -f "$QOS_RUNNING_FILE"
        return 1
    fi
    nft flush chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null
    nft flush chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null
    qos_log "INFO" "已清空 nft 规则链"
    if ! check_required_commands; then
        qos_log "ERROR" "缺少必需的命令，请安装对应软件包"
        release_lock
        rm -f "$QOS_RUNNING_FILE"
        return 1
    fi
    if ! load_required_modules; then
        qos_log "ERROR" "无法加载必需的内核模块"
        release_lock
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
            release_lock
            rm -f "$QOS_RUNNING_FILE"
            return 1
        fi
    fi
    qos_log "INFO" "使用WAN接口: $qos_interface"
    if ! load_htb_fqcodel_config; then
        qos_log "ERROR" "加载HTB+FQ_CODEL配置失败"
        release_lock
        rm -f "$QOS_RUNNING_FILE"
        return 1
    fi
    if ! ensure_ifb_device "$IFB_DEVICE"; then
        qos_log "ERROR" "IFB设备 $IFB_DEVICE 无法使用，请检查配置或启动IFB管理脚本"
        release_lock
        rm -f "$QOS_RUNNING_FILE"
        return 1
    fi

    # 验证掩码有效性
    if [[ "$UPLOAD_MASK" == "0" ]] || [[ "$DOWNLOAD_MASK" == "0" ]]; then
        qos_log "ERROR" "UPLOAD_MASK 或 DOWNLOAD_MASK 为 0，无法正确匹配标记"
        release_lock
        rm -f "$QOS_RUNNING_FILE"
        return 1
    fi

    load_upload_class_configurations
    load_download_class_configurations

    # 检查上传/下载带宽是否有效，决定是否进行标记分配和规则应用
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

    # 若两者均为0，则提前退出
    if (( upload_enabled == 0 )) && (( download_enabled == 0 )); then
        qos_log "WARN" "上传和下载带宽均为0，QoS未启动任何方向"
        check_and_handle_zero_bandwidth "$total_upload_bandwidth" "$total_download_bandwidth"
        release_lock
        rm -f "$QOS_RUNNING_FILE"
        return 0
    fi

    # 仅在对应方向启用时才分配标记和生成规则
    if (( upload_enabled == 1 )) && [[ -n "$upload_class_list" ]]; then
        if ! allocate_class_marks "upload" "$upload_class_list"; then
            qos_log "ERROR" "上传方向标记分配失败"
            release_lock
            rm -f "$QOS_RUNNING_FILE"
            return 1
        fi
    fi

    if (( download_enabled == 1 )) && [[ -n "$download_class_list" ]]; then
        if ! allocate_class_marks "download" "$download_class_list"; then
            qos_log "ERROR" "下载方向标记分配失败"
            release_lock
            rm -f "$QOS_RUNNING_FILE"
            return 1
        fi
    fi

    # 应用规则（仅当方向启用时）
    if (( upload_enabled == 1 )); then
        echo "调用上传分类规则应用..." 
        if ! apply_all_rules "upload_rule" "$UPLOAD_MASK" "filter_qos_egress"; then
            qos_log "ERROR" "上传规则应用失败，回滚"
            stop_htb_fqcodel_qos
            release_lock
            return 1
        fi
    fi

    if (( download_enabled == 1 )); then
        echo "调用下载分类规则应用..." 
        if ! apply_all_rules "download_rule" "$DOWNLOAD_MASK" "filter_qos_ingress"; then
            qos_log "ERROR" "下载规则应用失败，回滚"
            stop_htb_fqcodel_qos
            release_lock
            return 1
        fi
    fi

    qos_log "INFO" "应用自定义规则成功"
    if (( ENABLE_RATELIMIT == 1 )); then
        echo "应用速率限制链..." 
        setup_ratelimit_chain
    fi
    echo "应用ipv6特别规则..." 
    setup_ipv6_specific_rules
	
    local upload_failed=0
    local download_failed=0
    local upload_skipped=0
    local download_skipped=0

    # 检查上传带宽
    if (( upload_enabled == 1 )); then
        if ! init_htb_fqcodel_upload; then
            qos_log "ERROR" "上传方向初始化失败"
            upload_failed=1
        fi
    else
        upload_skipped=1
    fi

    # 检查下载带宽
    if (( download_enabled == 1 )); then
        if ! init_htb_fqcodel_download; then
            qos_log "ERROR" "下载方向初始化失败"
            download_failed=1
        fi
    else
        download_skipped=1
    fi

    # 如果有任何方向尝试初始化但失败，则整体失败
    if (( upload_failed == 1 )) || (( download_failed == 1 )); then
        qos_log "ERROR" "HTB+FQ_CODEL QoS 初始化部分失败"
        stop_htb_fqcodel_qos
        release_lock
        rm -f "$QOS_RUNNING_FILE"
        return 1
    fi

    if (( upload_skipped == 1 )) && (( download_skipped == 1 )); then
        qos_log "WARN" "上传和下载带宽均为0，QoS未启动任何方向"
    fi
	
    echo "应用HTB特别规则..." 
    setup_htb_enhance_chains
    apply_htb_specific_rules
    qos_log "INFO" "HTB+FQ_CODEL QoS初始化完成"
    release_lock
    return 0
}

# ========== 停止函数（移除配置恢复） ==========
stop_htb_fqcodel_qos() {
    qos_log "INFO" "停止HTB+FQ_CODEL QoS"
    acquire_lock
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
                # 简单检查是否有其他 qdisc 使用该 IFB（通常没有）
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
    nft delete table inet gargoyle-qos-priority 2>/dev/null || true
    clear_class_marks
    qos_log "INFO" "HTB+FQ_CODEL QoS停止完成"
    # 移除配置恢复，防止覆盖用户配置
    # restore_main_config   # 已删除
    # 重置 nftables 表刷新标志
    _QOS_TABLE_FLUSHED=0
    _IPSET_LOADED=0
    # 清理临时状态文件
    cleanup_qos_state
    # 清理临时文件
    cleanup_temp_files
    release_lock
}

# ========== 状态显示函数 ==========
show_htb_fqcodel_status() {
    if [[ -z "$IFB_DEVICE" ]]; then
        IFB_DEVICE=$(uci -q get ${CONFIG_FILE}.download.ifb_device 2>/dev/null)
        [[ -z "$IFB_DEVICE" ]] && IFB_DEVICE="ifb0"
    fi
    local qos_ifb="$IFB_DEVICE"
    if [[ -z "$qos_interface" ]]; then
        qos_interface=$(tc qdisc show 2>/dev/null | grep -E "htb.*root" | awk '{print $5}' | head -1)
        [[ -z "$qos_interface" ]] && qos_interface="未知"
    fi
    echo "===== HTB-FQ_CODEL QoS 状态报告 (v3.0.5) ====="
    echo "时间: $(date)"
    echo "WAN接口: ${qos_interface}"
    if ! tc qdisc show dev "${qos_interface}" 2>/dev/null | grep -q htb; then
        echo "警告: QoS未在接口 ${qos_interface} 上激活"
        return 1
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
    echo -e "\n======== 出口QoS ($qos_interface) ========"
    echo -e "\nTC队列:"
    tc -s qdisc show dev "$qos_interface" 2>/dev/null | while read -r line; do
        if echo "$line" | grep -q "htb\|fq_codel"; then
            echo "  $line"
        fi
    done
    if tc class show dev "$qos_interface" >/dev/null 2>&1; then
        echo -e "\nTC类别:"
        tc -s class show dev "$qos_interface" 2>/dev/null | while read -r line; do
            if echo "$line" | grep -q "htb"; then
                echo "  $line"
            fi
        done
    fi
    echo -e "\nTC过滤器:"
    tc -s filter show dev "$qos_interface" 2>/dev/null | while read -r line; do
        echo "  $line"
    done
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
            if echo "$line" | grep -q "htb\|fq_codel"; then
                echo "  $line"
            fi
        done
        if tc class show dev "$qos_ifb" >/dev/null 2>&1; then
            echo -e "\nTC类别:"
            tc -s class show dev "$qos_ifb" 2>/dev/null | while read -r line; do
                if echo "$line" | grep -q "htb"; then
                    echo "  $line"
                fi
            done
        fi
        echo -e "\nTC过滤器:"
        tc -s filter show dev "$qos_ifb" 2>/dev/null | while read -r line; do
            echo "  $line"
        done
        echo -e "\n入口重定向检查:"
        if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "ingress"; then
            check_ingress_redirect "$qos_interface" "$qos_ifb"
        else
            echo "  ✗ 入口队列未配置"
        fi
    else
        echo "  IFB设备不存在，无入口配置"
    fi
    echo -e "\n===== QoS运行状态 ====="
    local upload_active=0
    local download_active=0
    tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "htb" && upload_active=1
    [[ -n "$qos_ifb" ]] && tc qdisc show dev "$qos_ifb" 2>/dev/null | grep -q "htb" && download_active=1
    echo "上传QoS: $(( upload_active == 1 )) && echo "已启用 (HTB+fq_codel)" || echo "未启用")"
    echo "下载QoS: $(( download_active == 1 )) && echo "已启用 (HTB+fq_codel)" || echo "未启用")"
    if (( upload_active == 1 )) && (( download_active == 1 )); then
        echo -e "\n✓ QoS双向流量整形已启用"
    elif (( upload_active == 1 )) || (( download_active == 1 )); then
        echo -e "\n⚠ 部分方向QoS已启用"
    else
        echo -e "\n✗ QoS未运行"
    fi
	
    echo -e "\n===== 增强特性状态 ====="
    echo "速率限制: $(( ENABLE_RATELIMIT == 1 )) && echo "已启用" || echo "未启用")"
    echo "ACK 限速: $(( ENABLE_ACK_LIMIT == 1 )) && echo "已启用" || echo "未启用")"
    echo "TCP 升级: $(( ENABLE_TCP_UPGRADE == 1 )) && echo "已启用" || echo "未启用")"
    echo "自定义内联规则: $([ -f "$CUSTOM_EGRESS_FILE" ] && echo "存在" || echo "不存在") (出口) / $([ -f "$CUSTOM_INGRESS_FILE" ] && echo "存在" || echo "不存在") (入口)"
    echo "规则持久化: $(( SAVE_NFT_RULES == 1 )) && echo "已启用" || echo "未启用")"
    echo -e "\n===== 健康检查 ====="
    health_check
    echo -e "\n===== 活动连接标记 ========"
    if ! command -v conntrack >/dev/null 2>&1; then
        echo "  conntrack 命令未安装，无法显示连接标记信息。"
        echo "  请安装 conntrack-tools 包以获取此功能。"
    else
        local wan_ipv4=""
        local wan_ipv6=""
        wan_ipv4=$(ip -4 addr show dev "$qos_interface" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -1)
        [[ -z "$wan_ipv4" ]] && wan_ipv4=$(ifconfig "$qos_interface" 2>/dev/null | grep "inet addr:" | awk '{print $2}' | cut -d: -f2)
        wan_ipv6=$(ip -6 addr show dev "$qos_interface" 2>/dev/null | grep "inet6 " | grep -v "fe80::" | awk '{print $2}' | cut -d/ -f1 | head -1)
        [[ -z "$wan_ipv6" ]] && wan_ipv6=$(ifconfig "$qos_interface" 2>/dev/null | grep "inet6 addr:" | grep -v "fe80::" | awk '{print $3}' | cut -d/ -f1)
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
    echo -e "\n===== 网络接口统计 ====="
    echo -e "\n接口流量统计:"
    echo "WAN接口 ($qos_interface):"
    if command -v ip >/dev/null 2>&1; then
        ip -s link show "$qos_interface" 2>/dev/null | grep -E "RX:|TX:" | sed 's/^/  /'
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$qos_interface" 2>/dev/null | grep "RX bytes\|TX bytes" | sed 's/^/  /'
    else
        echo "  无法获取接口统计（缺少 ip 或 ifconfig 命令）"
    fi
    if [[ -n "$qos_ifb" ]] && ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\nIFB接口 ($qos_ifb):"
        if command -v ip >/dev/null 2>&1; then
            ip -s link show "$qos_ifb" 2>/dev/null | grep -E "RX:|TX:" | sed 's/^/  /'
        elif command -v ifconfig >/dev/null 2>&1; then
            ifconfig "$qos_ifb" 2>/dev/null | grep "RX bytes\|TX bytes" | sed 's/^/  /'
        else
            echo "  无法获取接口统计（缺少 ip 或 ifconfig 命令）"
        fi
    fi
    echo -e "\n===== HTB-FQ_CODEL 状态报告结束 ====="
    return 0
}

# ========== 主入口 ==========
main_htb_fqcodel_qos() {
    local action="$1"
    case "$action" in
        "start")
            if ! init_htb_fqcodel_qos; then
                qos_log "ERROR" "HTB+FQ_CODEL QoS启动失败"
                exit 1
            fi
            ;;
        "stop")
            stop_htb_fqcodel_qos
            ;;
        "restart")
            stop_htb_fqcodel_qos
            sleep 1
            if ! init_htb_fqcodel_qos; then
                qos_log "ERROR" "HTB+FQ_CODEL QoS重启失败"
                exit 1
            fi
            ;;
        "status")
            show_htb_fqcodel_status
            ;;
        "health_check")
            health_check
            ;;
        *)
            echo "用法: $0 {start|stop|restart|status|health_check}"
            echo ""
            echo "命令:"
            echo "  start        启动HTB+FQ_CODEL QoS"
            echo "  stop         停止HTB+FQ_CODEL QoS"
            echo "  restart      重启HTB+FQ_CODEL QoS"
            echo "  status       显示状态"
            echo "  health_check 执行健康检查"
            exit 1
            ;;
    esac
}

if [[ "$(basename "$0")" == "htb_fqcodel.sh" ]] || [[ "$(basename "$0")" == "htb-fqcodel.sh" ]]; then
    main_htb_fqcodel_qos "$1"
fi
