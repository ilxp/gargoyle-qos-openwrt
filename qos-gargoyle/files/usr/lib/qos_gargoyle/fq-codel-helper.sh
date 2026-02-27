#!/bin/sh
# ========== 变量初始化 ==========
# 确保变量只在使用前才设置默认值
: ${upload_shift:=0}
: ${download_shift:=8}
: ${UPLOAD_MASK:=0x007F}
: ${DOWNLOAD_MASK:=0x7F00}
: ${total_upload_bandwidth:=40000}
: ${total_download_bandwidth:=95000}
: ${CONFIG_FILE:=qos_gargoyle}
: ${IFB_DEVICE:=ifb0}

# 全局变量声明
upload_class_list=""
download_class_list=""
upload_class_mark_list=""
download_class_mark_list=""

# 如果 qos_interface 未设置，尝试获取
if [ -z "$qos_interface" ]; then
    # 尝试从 UCI 配置读取
    qos_interface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
    
    # 如果配置中没有，尝试系统检测
    if [ -z "$qos_interface" ] && [ -f "/lib/functions/network.sh" ]; then
        . /lib/functions/network.sh
        network_find_wan qos_interface
    fi
    
    # 设置默认值
    qos_interface="${qos_interface:-pppoe-wan}"
fi

echo "FQ-CoDel 模块初始化完成"
echo "  网络接口: $qos_interface"
echo "  IFB 设备: $IFB_DEVICE"
echo "  上传带宽: ${total_upload_bandwidth}kbit/s"
echo "  下载带宽: ${total_download_bandwidth}kbit/s"

# 加载必要的库
. /lib/functions.sh
. /lib/functions/network.sh
include /lib/network
# 加载公共规则辅助模块
if [ -f "/usr/lib/qos_gargoyle/rule-helper.sh" ]; then
    . /usr/lib/qos_gargoyle/rule-helper.sh
    logger -t "qos_gargoyle" "已加载规则辅助模块"
else
    logger -t "qos_gargoyle" "警告: 规则辅助模块未找到"
fi

# ========= FQ-CoDel专属常量 ==========
FQ_CODEL_QUANTUM=""
FQ_CODEL_FLOWS="1024"
FQ_CODEL_INTERVAL="100"
FQ_CODEL_TARGET="5"
FQ_CODEL_ECN_ENABLED="0"
FQ_CODEL_CE_THRESHOLD="0"
FQ_CODEL_MEMORY_LIMIT="32"
FQ_CODEL_FLOW_PRIOMAP="1,2,2,2,1,2,0,0,1,1,1,1,1,1,1,1"

# ========== 配置加载函数 ==========

# 加载FQ-CoDel专属配置
load_fq_codel_config() {
    logger -t "qos_gargoyle" "加载FQ-CoDel配置"
    
    # 从UCI配置读取FQ-CoDel特定参数
    FQ_CODEL_QUANTUM=$(uci -q get qos_gargoyle.fq_codel.quantum 2>/dev/null)
    FQ_CODEL_QUANTUM="${FQ_CODEL_QUANTUM:-}"
    
    FQ_CODEL_FLOWS=$(uci -q get qos_gargoyle.fq_codel.flows 2>/dev/null)
    FQ_CODEL_FLOWS="${FQ_CODEL_FLOWS:-1024}"
    
    FQ_CODEL_INTERVAL=$(uci -q get qos_gargoyle.fq_codel.interval 2>/dev/null)
    FQ_CODEL_INTERVAL="${FQ_CODEL_INTERVAL:-100}"
    
    FQ_CODEL_TARGET=$(uci -q get qos_gargoyle.fq_codel.target 2>/dev/null)
    FQ_CODEL_TARGET="${FQ_CODEL_TARGET:-5}"
    
    FQ_CODEL_ECN_ENABLED=$(uci -q get qos_gargoyle.fq_codel.ecn_enabled 2>/dev/null)
    FQ_CODEL_ECN_ENABLED="${FQ_CODEL_ECN_ENABLED:-0}"
    
    FQ_CODEL_CE_THRESHOLD=$(uci -q get qos_gargoyle.fq_codel.ce_threshold 2>/dev/null)
    FQ_CODEL_CE_THRESHOLD="${FQ_CODEL_CE_THRESHOLD:-0}"
    
    FQ_CODEL_MEMORY_LIMIT=$(uci -q get qos_gargoyle.fq_codel.memory_limit 2>/dev/null)
    FQ_CODEL_MEMORY_LIMIT="${FQ_CODEL_MEMORY_LIMIT:-32}"
    
    FQ_CODEL_FLOW_PRIOMAP=$(uci -q get qos_gargoyle.fq_codel.flow_priomap 2>/dev/null)
    FQ_CODEL_FLOW_PRIOMAP="${FQ_CODEL_FLOW_PRIOMAP:-1,2,2,2,1,2,0,0,1,1,1,1,1,1,1,1}"
    
    # 处理quantum参数
    if [ "$FQ_CODEL_QUANTUM" = "auto" ] || [ -z "$FQ_CODEL_QUANTUM" ]; then
        # 根据MTU自动计算quantum
        local mtu=$(cat /sys/class/net/pppoe-wan/mtu 2>/dev/null || echo 1500)
        FQ_CODEL_QUANTUM=$((mtu + 100))
    fi
    
    logger -t "qos_gargoyle" "FQ-CoDel配置: 队列数=${FQ_CODEL_FLOWS}, interval=${FQ_CODEL_INTERVAL}ms, target=${FQ_CODEL_TARGET}ms, ECN=${FQ_CODEL_ECN_ENABLED}, quantum=${FQ_CODEL_QUANTUM}"
}

# 加载上传类别配置
load_upload_class_configurations() {
    logger -t "qos_gargoyle" "正在加载上传类别配置..."
    
    # 直接使用UCI命令查找upload_class配置节
    upload_class_list=""
    config_get upload_class_list global upload_classes
    if [ -z "$upload_class_list" ]; then
        # 如果没有预定义列表，从UCI配置中查找
        upload_class_list=$(uci show qos_gargoyle 2>/dev/null | \
            grep -E "^qos_gargoyle\.[a-zA-Z0-9_]+=upload_class$" | \
            cut -d. -f2 | cut -d= -f1 | tr '\n' ' ')
    fi
    
    if [ -n "$upload_class_list" ]; then
        logger -t "qos_gargoyle" "找到上传类别: $upload_class_list"
    else
        logger -t "qos_gargoyle" "警告: 没有找到上传类别配置"
        upload_class_list=""
    fi
    
    return 0
}

# 加载下载类别配置
load_download_class_configurations() {
    logger -t "qos_gargoyle" "正在加载下载类别配置..."
    
    # 直接使用UCI命令查找download_class配置节
    download_class_list=""
    config_get download_class_list global download_classes
    if [ -z "$download_class_list" ]; then
        # 如果没有预定义列表，从UCI配置中查找
        download_class_list=$(uci show qos_gargoyle 2>/dev/null | \
            grep -E "^qos_gargoyle\.[a-zA-Z0-9_]+=download_class$" | \
            cut -d. -f2 | cut -d= -f1 | tr '\n' ' ')
    fi
    
    if [ -n "$download_class_list" ]; then
        logger -t "qos_gargoyle" "找到下载类别: $download_class_list"
    else
        logger -t "qos_gargoyle" "警告: 没有找到下载类别配置"
        download_class_list=""
    fi
    
    return 0
}

# 读取标记文件
read_mark_from_file() {
    local class_name="$1"      # 类别名称 (如: upload_class_1, download_class_1)
    local direction="$2"       # 方向: "upload" 或 "download"
    local mark_file=""
    local class_pattern=""
    
    # 根据方向选择文件
    if [ "$direction" = "upload" ]; then
        mark_file="/etc/qos_gargoyle/upload_class_marks"
        # 支持多种类别名称格式
        if echo "$class_name" | grep -q "^upload_class_"; then
            class_pattern="u${class_name#upload_class_}"
        elif echo "$class_name" | grep -q "^uclass_"; then
            class_pattern="${class_name#uclass_}"
        else
            class_pattern="$class_name"
        fi
    elif [ "$direction" = "download" ]; then
        mark_file="/etc/qos_gargoyle/download_class_marks"
        # 支持多种类别名称格式
        if echo "$class_name" | grep -q "^download_class_"; then
            class_pattern="d${class_name#download_class_}"
        elif echo "$class_name" | grep -q "^dclass_"; then
            class_pattern="${class_name#dclass_}"
        else
            class_pattern="$class_name"
        fi
    else
        logger -t "qos_gargoyle" "错误: 未知方向: $direction"
        echo ""
        return 1
    fi
    
    # 检查文件是否存在
    if [ ! -f "$mark_file" ]; then
        logger -t "qos_gargoyle" "错误: 标记文件不存在: $mark_file"
        echo ""
        return 1
    fi
    
    # 尝试多种格式查找
    local mark=""
    
    # 格式1: 完整格式 (upload:upload_class_1:0x1)
    if echo "$class_name" | grep -q "_class_"; then
        mark=$(grep "^${direction}:${class_name}:" "$mark_file" 2>/dev/null | awk -F: '{print $3}' | tr -d '[:space:]')
    fi
    
    # 格式2: 简短格式 (upload:uclass_1:0x1 或 download:dclass_1:0x100)
    if [ -z "$mark" ]; then
        local short_name=""
        if [ "$direction" = "upload" ]; then
            short_name="uclass_${class_pattern}"
        else
            short_name="dclass_${class_pattern}"
        fi
        mark=$(grep "^${direction}:${short_name}:" "$mark_file" 2>/dev/null | awk -F: '{print $3}' | tr -d '[:space:]')
    fi
    
    # 格式3: 仅数字 (1, 2, 3...)
    if [ -z "$mark" ] && echo "$class_pattern" | grep -qE '^[0-9]+$'; then
        if [ "$direction" = "upload" ]; then
            mark=$(grep "^upload:uclass_${class_pattern}:" "$mark_file" 2>/dev/null | awk -F: '{print $3}' | tr -d '[:space:]')
        else
            mark=$(grep "^download:dclass_${class_pattern}:" "$mark_file" 2>/dev/null | awk -F: '{print $3}' | tr -d '[:space:]')
        fi
    fi
    
    if [ -n "$mark" ]; then
        # 确保标记格式正确
        if echo "$mark" | grep -qE '^0x[0-9A-Fa-f]+$'; then
            echo "$mark"
            return 0
        else
            logger -t "qos_gargoyle" "警告: 读取的标记格式不正确: $mark"
        fi
    fi
    
    # 如果文件中没有找到，返回空值
    logger -t "qos_gargoyle" "错误: 在 $mark_file 中未找到 $direction:$class_name 的标记"
    echo ""
    return 1
}

# ========== IPv6增强支持 ==========

# 设置IPv6特定规则（关键流量高优先级）
setup_ipv6_specific_rules() {
    logger -t "qos_gargoyle" "设置IPv6特定规则"
    
    # ICMPv6关键类型（邻居发现、路由通告等）
    local ICMPV6_CRITICAL_TYPES="133,134,135,136,137"
    
    # 使用nftables设置IPv6关键流量标记
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 icmpv6 type { $ICMPV6_CRITICAL_TYPES } \
        meta mark set 0x7F counter
    
    # DHCPv6流量（UDP 546/547）
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport { 546, 547 } \
        meta mark set 0x7F counter
    
    # IPv6多播流量（ff00::/8）
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 daddr ff00::/8 \
        meta mark set 0x3F counter
    
    logger -t "qos_gargoyle" "IPv6关键流量规则设置完成"
}

# ========== HTB核心队列函数 (修改为使用FQ-CoDel作为叶子队列) ==========

# 创建HTB根队列 (保留HTB进行带宽分类)
create_htb_root_qdisc() {
    local device="$1"
    local direction="$2"
    local root_handle="$3"
    local root_classid="$4"
    
    local bandwidth=""
    if [ "$direction" = "upload" ]; then
        bandwidth="${total_upload_bandwidth}"
    elif [ "$direction" = "download" ]; then
        bandwidth="${total_download_bandwidth}"
    else
        logger -t "qos_gargoyle" "错误: 未知方向: $direction"
        return 1
    fi
    
    logger -t "qos_gargoyle" "为$device创建$direction方向HTB根队列 (带宽: ${bandwidth}kbit)"
    
    # 删除现有队列
    tc qdisc del dev "$device" root 2>/dev/null || true
    tc qdisc del dev "$device" ingress 2>/dev/null || true
    
    # 创建HTB根队列
    echo "正在为 $device 创建 HTB 根队列..."
    if ! tc qdisc add dev "$device" root handle $root_handle htb default 1 r2q 10; then
        logger -t "qos_gargoyle" "错误: 无法在 $device 上创建HTB根队列"
        return 1
    fi
    
    # 创建根类
    echo "正在为 $device 创建 HTB 根类..."
    if ! tc class add dev "$device" parent 1:0 classid 1:1 htb \
        rate ${bandwidth}kbit ceil ${bandwidth}kbit burst 15k cburst 15k; then
        logger -t "qos_gargoyle" "错误: 无法在$device上创建HTB根类"
        echo "错误: 无法在 $device 上创建 HTB 根类"
        return 1
    fi
    
    logger -t "qos_gargoyle" "$device的$direction方向HTB根队列创建完成"
    echo "$device 的 $direction 方向 HTB 根队列创建完成"
    return 0
}

# 计算HTB参数
calculate_htb_parameters() {
    local percent_bandwidth="$1"
    local min_bandwidth="$2"
    local max_bandwidth="$3"
    local direction="$4"
    local class_name="$5"
    
    local total_bandwidth=0
    if [ "$direction" = "upload" ]; then
        total_bandwidth=$total_upload_bandwidth
    else
        total_bandwidth=$total_download_bandwidth
    fi
    
    local rate=""
    local ceil=""
    local burst=""
    local cburst=""
    
    # 计算rate（保证带宽）
    if [ -n "$min_bandwidth" ] && [ "$min_bandwidth" -gt 0 ] 2>/dev/null; then
        rate="${min_bandwidth}kbit"
    elif [ -n "$percent_bandwidth" ] && [ "$percent_bandwidth" -gt 0 ] 2>/dev/null; then
        local calculated_rate=$((total_bandwidth * percent_bandwidth / 100))
        rate="${calculated_rate}kbit"
    else
        rate="$((total_bandwidth / 10))kbit"
    fi
    
    # 计算ceil（最大带宽）
    if [ -n "$max_bandwidth" ] && [ "$max_bandwidth" -gt 0 ] 2>/dev/null; then
        ceil="${max_bandwidth}kbit"
    else
        ceil="${total_bandwidth}kbit"
    fi
    
    # 计算burst和cburst
    local rate_num=$(echo "$rate" | sed 's/kbit//')
    burst="$((rate_num * 1000 / 8 / 100))"
    burst="${burst}b"
    cburst="$((rate_num * 1000 / 8 / 50))"
    cburst="${cburst}b"
    
    if [ "$burst" = "0b" ]; then
        burst="1kb"
    fi
    if [ "$cburst" = "0b" ]; then
        cburst="2kb"
    fi
    
    echo "$rate $ceil $burst $cburst"
}

# 创建使用FQ-CoDel作为叶子队列的上传类别
create_htb_upload_class_fq_codel() {
    local class_name="$1"
    local class_index="$2"
    
    logger -t "qos_gargoyle" "创建上传类别(使用FQ-CoDel): $class_name, ID: 1:$class_index"
    
    load_all_config_options "$CONFIG_FILE" "$class_name"
    
    local class_mark=$(read_mark_from_file "$class_name" "upload")
    
    if [ -z "$class_mark" ]; then
        local class_num=$(echo "$class_name" | sed -E 's/^upload_class_//')
        if [ -n "$class_num" ] && echo "$class_num" | grep -qE '^[0-9]+$'; then
            class_mark=$(printf "0x%X" $((0x1 << (class_num - 1))))
        else
            class_mark=$(printf "0x%X" $((0x1 << (class_index - 2))))
        fi
        logger -t "qos_gargoyle" "警告: 从文件读取标记失败，使用计算值: $class_mark"
    else
        logger -t "qos_gargoyle" "从文件获取上传标记: $class_mark"
    fi
    
    # 计算HTB参数
    local htb_params=$(calculate_htb_parameters "$percent_bandwidth" "$min_bandwidth" "$max_bandwidth" "upload" "$class_name")
    local rate=$(echo "$htb_params" | awk '{print $1}')
    local ceil=$(echo "$htb_params" | awk '{print $2}')
    local burst=$(echo "$htb_params" | awk '{print $3}')
    local cburst=$(echo "$htb_params" | awk '{print $4}')
    
    # 优先级设置
    local prio=""
    if [ -n "$priority" ] && [ "$priority" -ge 1 ] && [ "$priority" -le 7 ] 2>/dev/null; then
        prio="prio $priority"
    else
        prio="prio 3"
    fi
    
    if [ "${minRTT:-No}" = "Yes" ]; then
        prio="prio 1"
    fi
    
    # 创建HTB类别
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:$class_index htb \
        rate $rate ceil $ceil burst $burst cburst $cburst $prio; then
        logger -t "qos_gargoyle" "错误: 创建上传类别 1:$class_index 失败 (rate=$rate, ceil=$ceil)"
        return 1
    fi
    
    # 创建FQ-CoDel队列作为叶子队列
    echo "创建FQ-CoDel队列 (上传: $class_name, 类ID: 1:$class_index)"
    
    # 构建FQ-CoDel参数 - 注意：不要加"ms"单位
    local fq_codel_params=""
    
    # 基本参数（去掉了ms后缀）
    fq_codel_params="$fq_codel_params flows ${FQ_CODEL_FLOWS}"
    fq_codel_params="$fq_codel_params target ${FQ_CODEL_TARGET}"
    fq_codel_params="$fq_codel_params interval ${FQ_CODEL_INTERVAL}"
    
    # 可选参数
    if [ -n "$FQ_CODEL_QUANTUM" ]; then
        fq_codel_params="$fq_codel_params quantum $FQ_CODEL_QUANTUM"
    fi
    
    if [ "$FQ_CODEL_ECN_ENABLED" = "1" ]; then
        fq_codel_params="$fq_codel_params ecn"
    fi
    
    if [ "$FQ_CODEL_CE_THRESHOLD" -gt 0 ] 2>/dev/null; then
        fq_codel_params="$fq_codel_params ce_threshold $FQ_CODEL_CE_THRESHOLD"
    fi
    
    if [ -n "$FQ_CODEL_MEMORY_LIMIT" ]; then
        fq_codel_params="$fq_codel_params memory_limit ${FQ_CODEL_MEMORY_LIMIT}mb"
    fi
    
    # 添加FQ-CoDel队列
    if ! tc qdisc add dev "$qos_interface" parent 1:$class_index \
        handle ${class_index}:1 fq_codel $fq_codel_params 2>/dev/null; then
        logger -t "qos_gargoyle" "错误: 添加FQ-CoDel队列失败，尝试简化参数"
        
        # 尝试简化参数
        if ! tc qdisc add dev "$qos_interface" parent 1:$class_index \
            handle ${class_index}:1 fq_codel flows ${FQ_CODEL_FLOWS} \
            target ${FQ_CODEL_TARGET} interval ${FQ_CODEL_INTERVAL} 2>/dev/null; then
            logger -t "qos_gargoyle" "错误: 简化参数也失败，使用默认fq_codel"
            
            # 使用最基本的fq_codel
            if ! tc qdisc add dev "$qos_interface" parent 1:$class_index \
                handle ${class_index}:1 fq_codel 2>/dev/null; then
                logger -t "qos_gargoyle" "错误: 添加fq_codel队列失败"
                return 1
            fi
        fi
    fi
    
    # 添加过滤器
    if [ "$class_mark" != "0x0" ]; then
        # IPv4过滤器
        if ! tc filter add dev "$qos_interface" parent 1:0 protocol ip \
            prio $class_index handle $class_mark fw classid 1:$class_index 2>/dev/null; then
            logger -t "qos_gargoyle" "警告: 添加上传IPv4过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            logger -t "qos_gargoyle" "添加上传IPv4过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
        
        # IPv6过滤器
        local ipv6_priority=$((class_index + 100))
        if ! tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
            prio $ipv6_priority handle $class_mark fw classid 1:$class_index 2>/dev/null; then
            logger -t "qos_gargoyle" "警告: 添加上传IPv6过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            logger -t "qos_gargoyle" "添加上传IPv6过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
    fi
    
    logger -t "qos_gargoyle" "上传类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, rate=$rate, ceil=$ceil)"
    return 0
}

# 创建使用FQ-CoDel作为叶子队列的下载类别
create_htb_download_class_fq_codel() {
    local class_name="$1"
    local class_index="$2"
    local priority="$3"
    
    logger -t "qos_gargoyle" "创建下载类别(使用FQ-CoDel): $class_name, ID: 1:$class_index, 优先级: $priority"
    
    load_all_config_options "$CONFIG_FILE" "$class_name"
    
    local class_mark=$(read_mark_from_file "$class_name" "download")
    
    if [ -z "$class_mark" ]; then
        local class_num=$(echo "$class_name" | sed -E 's/^download_class_//')
        if [ -n "$class_num" ] && echo "$class_num" | grep -qE '^[0-9]+$'; then
            class_mark=$(printf "0x%X" $((0x100 << (class_num - 1))))
        else
            class_mark=$(printf "0x%X" $((0x100 << (class_index - 2))))
        fi
        logger -t "qos_gargoyle" "警告: 从文件读取标记失败，使用计算值: $class_mark"
    else
        logger -t "qos_gargoyle" "从文件获取下载标记: $class_mark"
    fi
    
    # 计算HTB参数
    local htb_params=$(calculate_htb_parameters "$percent_bandwidth" "$min_bandwidth" "$max_bandwidth" "download" "$class_name")
    local rate=$(echo "$htb_params" | awk '{print $1}')
    local ceil=$(echo "$htb_params" | awk '{print $2}')
    local burst=$(echo "$htb_params" | awk '{print $3}')
    local cburst=$(echo "$htb_params" | awk '{print $4}')
    
    # 优先级设置
    local prio=""
    if [ -n "$priority" ] && [ "$priority" -ge 1 ] && [ "$priority" -le 7 ] 2>/dev/null; then
        prio="prio $priority"
    else
        prio="prio 3"
    fi
    
    if [ "${minRTT:-No}" = "Yes" ]; then
        prio="prio 1"
    fi
    
    # 创建HTB类别
    if ! tc class add dev "$IFB_DEVICE" parent 1:1 \
        classid 1:$class_index htb \
        rate $rate ceil $ceil burst $burst cburst $cburst $prio; then
        logger -t "qos_gargoyle" "错误: 创建下载类别 1:$class_index 失败 (rate=$rate, ceil=$ceil)"
        return 1
    fi
    
    # 创建FQ-CoDel队列作为叶子队列
    echo "创建FQ-CoDel队列 (下载: $class_name, 类ID: 1:$class_index)"
    
    # 构建FQ-CoDel参数 - 注意：不要加"ms"单位
    local fq_codel_params=""
    
    # 基本参数（去掉了ms后缀）
    fq_codel_params="$fq_codel_params flows ${FQ_CODEL_FLOWS}"
    fq_codel_params="$fq_codel_params target ${FQ_CODEL_TARGET}"
    fq_codel_params="$fq_codel_params interval ${FQ_CODEL_INTERVAL}"
    
    # 可选参数
    if [ -n "$FQ_CODEL_QUANTUM" ]; then
        fq_codel_params="$fq_codel_params quantum $FQ_CODEL_QUANTUM"
    fi
    
    if [ "$FQ_CODEL_ECN_ENABLED" = "1" ]; then
        fq_codel_params="$fq_codel_params ecn"
    fi
    
    if [ "$FQ_CODEL_CE_THRESHOLD" -gt 0 ] 2>/dev/null; then
        fq_codel_params="$fq_codel_params ce_threshold $FQ_CODEL_CE_THRESHOLD"
    fi
    
    if [ -n "$FQ_CODEL_MEMORY_LIMIT" ]; then
        fq_codel_params="$fq_codel_params memory_limit ${FQ_CODEL_MEMORY_LIMIT}mb"
    fi
    
    # 添加FQ-CoDel队列
    if ! tc qdisc add dev "$IFB_DEVICE" parent 1:$class_index \
        handle ${class_index}:1 fq_codel $fq_codel_params 2>/dev/null; then
        logger -t "qos_gargoyle" "错误: 添加FQ-CoDel队列失败，尝试简化参数"
        
        # 尝试简化参数
        if ! tc qdisc add dev "$IFB_DEVICE" parent 1:$class_index \
            handle ${class_index}:1 fq_codel flows ${FQ_CODEL_FLOWS} \
            target ${FQ_CODEL_TARGET} interval ${FQ_CODEL_INTERVAL} 2>/dev/null; then
            logger -t "qos_gargoyle" "错误: 简化参数也失败，使用默认fq_codel"
            
            # 使用最基本的fq_codel
            if ! tc qdisc add dev "$IFB_DEVICE" parent 1:$class_index \
                handle ${class_index}:1 fq_codel 2>/dev/null; then
                logger -t "qos_gargoyle" "错误: 添加fq_codel队列失败"
                return 1
            fi
        fi
    fi
    
    # 添加过滤器
    if [ "$class_mark" != "0x0" ]; then
        # 下载过滤器使用优先级参数
        if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ip \
            prio $priority handle $class_mark fw classid 1:$class_index 2>/dev/null; then
            logger -t "qos_gargoyle" "警告: 添加下载IPv4过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            logger -t "qos_gargoyle" "添加下载IPv4过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
        
        # IPv6过滤器
        local ipv6_priority=$((priority + 100))
        if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
            prio $ipv6_priority handle $class_mark fw classid 1:$class_index 2>/dev/null; then
            logger -t "qos_gargoyle" "警告: 添加下载IPv6过滤器失败 (标记:$class_mark -> 类别:1:$class_index)"
        else
            logger -t "qos_gargoyle" "添加下载IPv6过滤器: 标记:$class_mark -> 类别:1:$class_index"
        fi
    fi
    
    logger -t "qos_gargoyle" "下载类别创建成功: $class_name -> 1:$class_index (标记: $class_mark, rate=$rate, ceil=$ceil)"
    return 0
}

# 创建默认上传类别
create_default_upload_class_fq_codel() {
    logger -t "qos_gargoyle" "创建默认上传类别(使用FQ-CoDel)"
    
    if ! create_htb_root_qdisc "$qos_interface" "upload" "1:0" "1:1"; then
        logger -t "qos_gargoyle" "错误：创建上传根队列失败"
        return 1
    fi
    
    # 创建默认类别（类ID为1:2）
    local rate="$((total_upload_bandwidth * 80 / 100))kbit"
    local ceil="${total_upload_bandwidth}kbit"
    local burst="5kb"
    local cburst="10kb"
    
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:2 htb rate $rate ceil $ceil burst $burst cburst $cburst prio 4; then
        logger -t "qos_gargoyle" "错误: 创建上传类 1:2 失败"
        return 1
    fi
    
    # 构建FQ-CoDel参数 - 注意：不要加"ms"单位
    local fq_codel_params=""
    fq_codel_params="$fq_codel_params flows ${FQ_CODEL_FLOWS}"
    fq_codel_params="$fq_codel_params target ${FQ_CODEL_TARGET}"
    fq_codel_params="$fq_codel_params interval ${FQ_CODEL_INTERVAL}"
    
    if [ -n "$FQ_CODEL_QUANTUM" ]; then
        fq_codel_params="$fq_codel_params quantum $FQ_CODEL_QUANTUM"
    fi
    
    if [ "$FQ_CODEL_ECN_ENABLED" = "1" ]; then
        fq_codel_params="$fq_codel_params ecn"
    fi
    
    # 添加FQ-CoDel队列
    if ! tc qdisc add dev "$qos_interface" parent 1:2 \
        handle 2:1 fq_codel $fq_codel_params 2>/dev/null; then
        logger -t "qos_gargoyle" "错误: 添加FQ-CoDel队列失败"
        return 1
    fi
    
    # 添加过滤器
    local mark_hex="0x1"
    if ! tc filter add dev "$qos_interface" parent 1:0 protocol ip \
        prio 1 handle ${mark_hex}/$UPLOAD_MASK fw flowid 1:2; then
        logger -t "qos_gargoyle" "警告: 添加上传IPv4过滤器失败"
    fi
    
    if ! tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
        prio 2 handle ${mark_hex}/$UPLOAD_MASK fw flowid 1:2; then
        logger -t "qos_gargoyle" "警告: 添加上传IPv6过滤器失败"
    fi
    
    upload_class_mark_list="default_class:$mark_hex"
    logger -t "qos_gargoyle" "默认上传类别创建完成 (类ID: 1:2, 标记: $mark_hex, rate=$rate, ceil=$ceil)"
    return 0
}

# 创建默认下载类别
create_default_download_class_fq_codel() {
    logger -t "qos_gargoyle" "创建默认下载类别(使用FQ-CoDel)"
    
    # 确保IFB设备存在并已启动
    if ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        logger -t "qos_gargoyle" "错误: IFB设备 $IFB_DEVICE 不存在"
        return 1
    fi
    
    if ! ip link set dev "$IFB_DEVICE" up; then
        logger -t "qos_gargoyle" "错误: 无法启动IFB设备 $IFB_DEVICE"
        return 1
    fi
    
    # 首先创建根队列
    if ! create_htb_root_qdisc "$IFB_DEVICE" "download" "1:0" "1:1"; then
        logger -t "qos_gargoyle" "错误：创建下载根队列失败"
        return 1
    fi
    
    # 创建默认类别（类ID为1:2）
    local rate="$((total_download_bandwidth * 80 / 100))kbit"
    local ceil="${total_download_bandwidth}kbit"
    local burst="5kb"
    local cburst="10kb"
    
    if ! tc class add dev "$IFB_DEVICE" parent 1:1 \
        classid 1:2 htb rate $rate ceil $ceil burst $burst cburst $cburst prio 4; then
        logger -t "qos_gargoyle" "错误: 创建下载类 1:2 失败"
        return 1
    fi
    
    # 构建FQ-CoDel参数 - 注意：不要加"ms"单位
    local fq_codel_params=""
    fq_codel_params="$fq_codel_params flows ${FQ_CODEL_FLOWS}"
    fq_codel_params="$fq_codel_params target ${FQ_CODEL_TARGET}"
    fq_codel_params="$fq_codel_params interval ${FQ_CODEL_INTERVAL}"
    
    if [ -n "$FQ_CODEL_QUANTUM" ]; then
        fq_codel_params="$fq_codel_params quantum $FQ_CODEL_QUANTUM"
    fi
    
    if [ "$FQ_CODEL_ECN_ENABLED" = "1" ]; then
        fq_codel_params="$fq_codel_params ecn"
    fi
    
    # 添加FQ-CoDel队列
    if ! tc qdisc add dev "$IFB_DEVICE" parent 1:2 \
        handle 2:1 fq_codel $fq_codel_params 2>/dev/null; then
        logger -t "qos_gargoyle" "错误: 添加FQ-CoDel队列失败"
        return 1
    fi
    
    # 添加过滤器
    local mark_hex="0x100"
    if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ip \
        prio 1 handle ${mark_hex}/$DOWNLOAD_MASK fw flowid 1:2; then
        logger -t "qos_gargoyle" "警告: 添加下载IPv4过滤器失败"
    fi
    
    if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
        prio 2 handle ${mark_hex}/$DOWNLOAD_MASK fw flowid 1:2; then
        logger -t "qos_gargoyle" "警告: 添加下载IPv6过滤器失败"
    fi
    
    # 设置入口重定向
    if ! setup_ingress_redirect; then
        logger -t "qos_gargoyle" "警告: 设置入口重定向失败"
    fi
    
    download_class_mark_list="default_class:$mark_hex"
    logger -t "qos_gargoyle" "默认下载类别创建完成 (类ID: 1:2, 标记: $mark_hex, rate=$rate, ceil=$ceil)"
    return 0
}

# ========== 入口重定向相关函数 ==========

setup_ingress_redirect() {
    if [ -z "$qos_interface" ]; then
        qos_interface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
        
        if [ -z "$qos_interface" ] && [ -f "/lib/functions/network.sh" ]; then
            . /lib/functions/network.sh
            network_find_wan qos_interface
        fi
        
        qos_interface="${qos_interface:-pppoe-wan}"
    fi
    
    if [ -z "$IFB_DEVICE" ]; then
        IFB_DEVICE="ifb0"
    fi
    
    logger -t "qos_gargoyle" "设置入口重定向: $qos_interface -> $IFB_DEVICE"
    
    # 在WAN接口上创建ingress队列
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null
    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        logger -t "qos_gargoyle" "错误: 无法在 $qos_interface 上创建入口队列"
        return 1
    fi
    
    # 清除现有的入口过滤器
    tc filter del dev "$qos_interface" parent ffff: 2>/dev/null
    
    # 修复IPv4重定向规则 - 使用正确的语法
    echo "设置IPv4入口重定向..."
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ip \
        u32 match u32 0 0 \
        action connmark pipe \
        action mirred egress redirect dev "$IFB_DEVICE"; then
        logger -t "qos_gargoyle" "警告: IPv4入口重定向规则添加失败"
        
        # 尝试简化版本
        if ! tc filter add dev "$qos_interface" parent ffff: \
            u32 match u32 0 0 action mirred egress redirect dev "$IFB_DEVICE"; then
            logger -t "qos_gargoyle" "错误: IPv4入口重定向完全失败"
            return 1
        fi
    else
        logger -t "qos_gargoyle" "IPv4入口重定向设置成功"
    fi
    
    # 修复IPv6重定向规则
    echo "设置IPv6入口重定向..."
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
        u32 match u32 0 0 \
        action connmark pipe \
        action mirred egress redirect dev "$IFB_DEVICE"; then
        logger -t "qos_gargoyle" "警告: IPv6入口重定向规则添加失败"
        
        # 尝试简化版本
        if ! tc filter add dev "$qos_interface" parent ffff: \
            u32 match u32 0 0 action mirred egress redirect dev "$IFB_DEVICE"; then
            logger -t "qos_gargoyle" "警告: IPv6入口重定向简化版本失败"
        fi
    else
        logger -t "qos_gargoyle" "IPv6入口重定向设置成功"
    fi
    
    local ingress_rules=$(tc filter show dev "$qos_interface" parent ffff: 2>/dev/null | wc -l)
    
    if [ "$ingress_rules" -ge 2 ]; then
        logger -t "qos_gargoyle" "入口重定向已成功设置: $qos_interface -> $IFB_DEVICE (共 $ingress_rules 条规则)"
    else
        logger -t "qos_gargoyle" "错误: 入口重定向规则数量不足 ($ingress_rules 条)"
        return 1
    fi
    
    return 0
}

check_ingress_redirect() {
    local wan_if="$1"
    local ifb_dev="$2"
    
    echo "检查入口重定向 (接口: $wan_if, IFB设备: $ifb_dev)"
    
    # 检查入口队列是否存在
    if ! tc qdisc show dev "$wan_if" 2>/dev/null | grep -q "ingress"; then
        echo "  ✗ 入口队列未配置"
        return 1
    fi
    
    # 获取入口过滤器
    local ingress_filters=$(tc filter show dev "$wan_if" parent ffff: 2>/dev/null)
    
    if [ -z "$ingress_filters" ]; then
        echo "  ✗ 入口过滤器未配置"
        return 1
    fi
    
    local ipv4_found=0
    local ipv6_found=0
    
    # 检查IPv4入口规则
    echo "  IPv4入口规则:"
    local ipv4_rule=$(tc filter show dev "$wan_if" parent ffff: 2>/dev/null | grep -A5 -B2 "protocol ip")
    if [ -n "$ipv4_rule" ]; then
        echo "$ipv4_rule" | sed 's/^/    /'
        echo "    ✓ IPv4 重定向到 $ifb_dev: 已生效"
        ipv4_found=1
    else
        echo "    ✗ IPv4 入口规则未找到"
    fi
    
    # 检查IPv6入口规则
    echo -e "\n  IPv6入口规则:"
    local ipv6_rule=$(tc filter show dev "$wan_if" parent ffff: 2>/dev/null | grep -A5 -B2 "protocol ipv6")
    if [ -n "$ipv6_rule" ]; then
        echo "$ipv6_rule" | sed 's/^/    /'
        echo "    ✓ IPv6 重定向到 $ifb_dev: 已生效"
        ipv6_found=1
    else
        echo "    ✗ IPv6 入口规则未找到"
    fi
    
    # 检查IFB设备是否有流量
    local ifb_tx_packets=$(tc -s qdisc show dev "$ifb_dev" 2>/dev/null | awk '/Sent/ {print $2}' | head -1)
    
    if [ -n "$ifb_tx_packets" ] && [ "$ifb_tx_packets" -gt 0 ]; then
        echo -e "\n  ✓ IFB设备流量: 正常 ($ifb_tx_packets 个包)"
    else
        echo -e "\n  ⚠ IFB设备流量: 无或较低"
    fi
    
    if [ "$ipv4_found" -eq 1 ] && [ "$ipv6_found" -eq 1 ]; then
        echo -e "\n  ✓ 入口重定向配置完整"
        return 0
    else
        echo -e "\n  ⚠ 入口重定向配置不完整"
        return 1
    fi
}

# ========== 上传方向初始化 ==========

initialize_fq_codel_upload() {
    logger -t "qos_gargoyle" "初始化上传方向HTB+FQ-CoDel"
    
    load_upload_class_configurations
    
    if [ -z "$upload_class_list" ]; then
        logger -t "qos_gargoyle" "警告：未找到上传类别配置，使用默认类别"
        create_default_upload_class_fq_codel
        return 0
    fi
    
    logger -t "qos_gargoyle" "找到上传类别：$upload_class_list"
    
    # 创建根队列
    if ! create_htb_root_qdisc "$qos_interface" "upload" "1:0" "1:1"; then
        logger -t "qos_gargoyle" "错误：创建上传根队列失败"
        return 1
    fi
    
    # 创建各个类别
    local class_index=2
    upload_class_mark_list=""
    
    for class_name in $upload_class_list; do
        create_htb_upload_class_fq_codel "$class_name" "$class_index"
        if [ $? -eq 0 ]; then
            local class_mark_hex=""
            
            load_all_config_options "$CONFIG_FILE" "$class_name"
            
            if [ -n "$class_mark" ] && [ "$class_mark" != "0x0" ]; then
                class_mark_hex="$class_mark"
                logger -t "qos_gargoyle" "使用配置的标记值: $class_name -> $class_mark_hex"
            else
                local mark_value=$((class_index << upload_shift))
                class_mark_hex=$(printf "0x%X" $mark_value)
                logger -t "qos_gargoyle" "自动计算标记值: $class_name -> $class_mark_hex"
            fi
            
            upload_class_mark_list="$upload_class_mark_list$class_name:$class_mark_hex "
            
            # 添加过滤器
            if [ -n "$class_mark_hex" ] && [ "$class_mark_hex" != "0x0" ]; then
                tc filter add dev "$qos_interface" parent 1:0 protocol ip \
                    prio 1 handle ${class_mark_hex}/$UPLOAD_MASK fw flowid 1:$class_index
                    
                tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
                    prio 2 handle ${class_mark_hex}/$UPLOAD_MASK fw flowid 1:$class_index
            fi
        fi
        class_index=$((class_index + 1))
    done
    
    # 设置默认类别
    set_default_upload_class
    
    create_upload_chain
    
    logger -t "qos_gargoyle" "上传方向HTB+FQ-CoDel初始化完成"
    return 0
}

# ========== 下载方向初始化 ==========

initialize_fq_codel_download() {
    logger -t "qos_gargoyle" "初始化下载方向HTB+FQ-CoDel"
    
    load_download_class_configurations
    
    if [ -z "$download_class_list" ]; then
        logger -t "qos_gargoyle" "警告：未找到下载类别配置，使用默认类别"
        create_default_download_class_fq_codel
        return 0
    fi
    
    logger -t "qos_gargoyle" "找到下载类别：$download_class_list"
    
    # 确保IFB设备已启动
    if ! ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        logger -t "qos_gargoyle" "错误: IFB设备 $IFB_DEVICE 不存在"
        return 1
    fi
    
    if ! ip link set dev "$IFB_DEVICE" up; then
        logger -t "qos_gargoyle" "错误: 无法启动IFB设备 $IFB_DEVICE"
        return 1
    fi
    
    # 创建根队列
    if ! create_htb_root_qdisc "$IFB_DEVICE" "download" "1:0" "1:1"; then
        logger -t "qos_gargoyle" "错误：创建下载根队列失败"
        return 1
    fi
    
    # 创建各个类别
    local class_index=2
    local priority=3
    download_class_mark_list=""
    
    for class_name in $download_class_list; do
        create_htb_download_class_fq_codel "$class_name" "$class_index" "$priority"
        if [ $? -eq 0 ]; then
            local class_mark_hex=""
            
            load_all_config_options "$CONFIG_FILE" "$class_name"
            
            if [ -n "$class_mark" ] && [ "$class_mark" != "0x0" ]; then
                class_mark_hex="$class_mark"
                logger -t "qos_gargoyle" "使用配置的标记值: $class_name -> $class_mark_hex"
            else
                local mark_value=$((class_index << download_shift))
                class_mark_hex=$(printf "0x%X" $mark_value)
                logger -t "qos_gargoyle" "自动计算标记值: $class_name -> $class_mark_hex"
            fi
            
            download_class_mark_list="$download_class_mark_list$class_name:$class_mark_hex "
            
            # 添加过滤器
            if [ -n "$class_mark_hex" ] && [ "$class_mark_hex" != "0x0" ]; then
                if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ip \
                    prio $priority handle ${class_mark_hex}/$DOWNLOAD_MASK fw flowid 1:$class_index; then
                    logger -t "qos_gargoyle" "警告: 添加下载IPv4过滤器失败 (类别: $class_name)"
                else
                    logger -t "qos_gargoyle" "下载IPv4过滤器添加成功: 标记=$class_mark_hex, 类别ID=1:$class_index"
                fi
                
                if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
                    prio $((priority + 1)) handle ${class_mark_hex}/$DOWNLOAD_MASK fw flowid 1:$class_index; then
                    logger -t "qos_gargoyle" "警告: 添加下载IPv6过滤器失败 (类别: $class_name)"
                else
                    logger -t "qos_gargoyle" "下载IPv6过滤器添加成功: 标记=$class_mark_hex, 类别ID=1:$class_index"
                fi
            fi
        fi
        class_index=$((class_index + 1))
        priority=$((priority + 2))
    done
    
    # 设置默认类别
    set_default_download_class
    
    create_download_chain
    setup_ingress_redirect
    
    logger -t "qos_gargoyle" "下载方向HTB+FQ-CoDel初始化完成"
    return 0
}

# ========== 默认配置分类 ==========

create_upload_chain() {
    logger -t "qos_gargoyle" "创建上传链（空函数，已由initialize_fq_codel_upload处理）"
    return 0
}

set_default_upload_class() {
    logger -t "qos_gargoyle" "设置上传默认类别"
    
    local default_class_name=$(uci -q get qos_gargoyle.upload.default_class 2>/dev/null)
    default_class_name="${default_class_name:-Normal}"
    
    logger -t "qos_gargoyle" "用户配置的上传默认类别名称: $default_class_name"
    
    local class_index=2
    local found_index=2
    local found=0
    
    for class_name in $upload_class_list; do
        if [ "$class_name" = "$default_class_name" ]; then
            found_index=$class_index
            found=1
            logger -t "qos_gargoyle" "找到上传默认类别 '$default_class_name' 在索引位置 $found_index"
            break
        fi
        class_index=$((class_index + 1))
    done
    
    if [ $found -eq 0 ]; then
        logger -t "qos_gargoyle" "警告: 未找到上传默认类别 '$default_class_name'，使用第一个类别"
    fi
    
    tc qdisc change dev "$qos_interface" root handle 1:0 htb default $found_index
    logger -t "qos_gargoyle" "上传默认类别设置为TC类ID: 1:$found_index (对应配置: $default_class_name)"
}

set_default_download_class() {
    logger -t "qos_gargoyle" "设置下载默认类别"
    
    local default_class_name=$(uci -q get qos_gargoyle.download.default_class 2>/dev/null)
    default_class_name="${default_class_name:-Normal}"
    
    logger -t "qos_gargoyle" "用户配置的下载默认类别名称: $default_class_name"
    
    local class_index=2
    local found_index=2
    local found=0
    
    for class_name in $download_class_list; do
        if [ "$class_name" = "$default_class_name" ]; then
            found_index=$class_index
            found=1
            logger -t "qos_gargoyle" "找到下载默认类别 '$default_class_name' 在索引位置 $found_index"
            break
        fi
        class_index=$((class_index + 1))
    done
    
    if [ $found -eq 0 ]; then
        logger -t "qos_gargoyle" "警告: 未找到下载默认类别 '$default_class_name'，使用第一个类别"
    fi
    
    tc qdisc change dev "$IFB_DEVICE" root handle 1:0 htb default $found_index
    logger -t "qos_gargoyle" "下载默认类别设置为TC类ID: 1:$found_index (对应配置: $default_class_name)"
}

create_download_chain() {
    logger -t "qos_gargoyle" "创建下载链（包括入口重定向）"
    setup_ingress_redirect
}

# ========== 主初始化函数 ==========

initialize_fq_codel_qos() {
    logger -t "qos_gargoyle" "开始初始化HTB+FQ-CoDel QoS系统"
    
    # 1. 加载FQ-CoDel专属配置
    load_fq_codel_config
    
    # 2. 设置IPv6特定规则
    setup_ipv6_specific_rules
    
    # 3. 初始化上传方向
    if [ "$total_upload_bandwidth" -ge 0 ] && [ "$total_upload_bandwidth" -gt 0 ]; then
        initialize_fq_codel_upload
    else
        logger -t "qos_gargoyle" "上传带宽未配置，跳过上传方向初始化"
    fi
    
    # 4. 初始化下载方向
    if [ "$total_download_bandwidth" -ge 0 ] && [ "$total_download_bandwidth" -gt 0 ]; then
        initialize_fq_codel_download
    else
        logger -t "qos_gargoyle" "下载带宽未配置，跳过下载方向初始化"
    fi
    
    logger -t "qos_gargoyle" "HTB+FQ-CoDel QoS初始化完成"
}

# ========== 停止和清理函数 ==========

stop_fq_codel_qos() {
    logger -t "qos_gargoyle" "停止HTB+FQ-CoDel QoS"
    
    # 清理上传方向
    if tc qdisc show dev "$qos_interface" | grep -q "htb"; then
        tc qdisc del dev "$qos_interface" root 2>/dev/null
        logger -t "qos_gargoyle" "清理上传方向HTB队列"
    fi
    
    # 清理下载方向
    if tc qdisc show dev "$IFB_DEVICE" | grep -q "htb"; then
        tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null
        logger -t "qos_gargoyle" "清理下载方向HTB队列"
    fi
    
    # 清理NFTables规则
    nft delete chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null
    nft delete chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null
    
    # 清理入口队列
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null
    
    # 停用IFB设备
    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link set dev "$IFB_DEVICE" down
        logger -t "qos_gargoyle" "停用IFB设备: $IFB_DEVICE"
    fi
    
    # 清理连接标记
    conntrack -U --mark 0 2>/dev/null
    
    logger -t "qos_gargoyle" "HTB+FQ-CoDel QoS停止完成"
}

show_fq_codel_status() {
    # 确保必要的变量已设置
    local qos_ifb="${IFB_DEVICE:-ifb0}"
    local mark_dir="/etc/qos_gargoyle"
    local upload_marks_file="$mark_dir/upload_class_marks"
    local download_marks_file="$mark_dir/download_class_marks"
    
    # 如果接口未定义，尝试获取
    if [ -z "$qos_interface" ]; then
        # 尝试从TC输出推断接口
        qos_interface=$(tc qdisc show 2>/dev/null | grep -E "htb.*root" | awk '{print $5}' | head -1)
        [ -z "$qos_interface" ] && qos_interface="未知"
    fi
    
    # 如果IP地址未定义，尝试获取
    if [ -z "$wan_ip" ] && [ -f "/lib/functions/network.sh" ]; then
        . /lib/functions/network.sh
        network_find_wan wan_interface
        network_get_ipaddr wan_ip "$wan_interface" 2>/dev/null || wan_ip=""
        network_get_ipaddr6 wan_ip6 "$wan_interface" 2>/dev/null || wan_ip6=""
        network_get_ipaddr local_ip lan 2>/dev/null || local_ip=""
        network_get_ipaddr6 local_ip6 lan 2>/dev/null || local_ip6=""
    fi
    
    echo "===== FQ-CoDel QoS状态报告 ====="
    echo "时间: $(date)"
    echo "系统运行时间: $(uptime | sed 's/.*up //; s/,.*//')"
    echo "WAN接口: ${qos_interface:-未知}"
    echo "WAN IPv4: ${wan_ip:-未检测到}"
    echo "WAN IPv6: ${wan_ip6:-未检测到}"
    echo "LAN IPv4: ${local_ip:-未检测到}"
    echo "LAN IPv6: ${local_ip6:-未检测到}"
    
    # 检查IFB设备
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        if tc qdisc show dev "$qos_ifb" >/dev/null 2>&1; then
            echo "IFB设备: 已启动且运行中 ($qos_ifb)"
        else
            echo "IFB设备: 已创建但无 TC 队列 ($qos_ifb)"
        fi
    else
        echo "IFB设备: 未创建"
    fi
    
    # 检查QoS是否实际运行
    if ! tc qdisc show dev "${qos_interface}" 2>/dev/null | grep -q htb; then
        echo "警告: QoS未在接口 ${qos_interface} 上激活"
        return 1
    fi
    
    # 显示出口配置
    echo -e "\n======== 出口QoS ($qos_interface) ========"
    echo "NFT规则:"
    nft list chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null || echo "  无NFT规则"
    
    echo -e "\nTC统计:"
    tc -s qdisc show dev "$qos_interface" 2>/dev/null || echo "  无TC队列"
    
    echo "TC过滤器:"
    tc -s filter show dev "$qos_interface" 2>/dev/null || echo "  无过滤器"
    
    # 显示入口配置
    echo -e "\n======== 入口QoS ($qos_ifb) ========"
    echo "NFT规则:"
    nft list chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null || echo "  无NFT规则"
    
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\nTC统计:"
        tc -s qdisc show dev "$qos_ifb" 2>/dev/null || echo "  无TC队列"
        
        echo "TC过滤器:"
        tc -s filter show dev "$qos_ifb" 2>/dev/null || echo "  无过滤器"
        
        # 检查入口重定向
        echo -e "\n入口重定向检查:"
        if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "ingress"; then
            check_ingress_redirect "$qos_interface" "$qos_ifb"
        else
            echo "  ✗ 入口队列未配置"
        fi
    else
        echo "  IFB设备不存在，无入口配置"
    fi
    
    # 显示连接标记
    echo -e "\n======== 活动连接标记 ========"
    local has_marked_connections=0
    
    # IPv4连接标记
    if [ -n "$wan_ip" ]; then
        echo "IPv4连接 (目标: $wan_ip):"
        conntrack -L -d "$wan_ip" 2>/dev/null | grep -E "mark=[0-9]+" | head -5 | while read -r line; do
            echo "  $line"
            has_marked_connections=1
        done
    fi
    
    # IPv6连接标记
    if [ -n "$wan_ip6" ]; then
        echo "IPv6连接 (目标: $wan_ip6):"
        conntrack -L -d "$wan_ip6" 2>/dev/null | grep -E "mark=[0-9]+" | head -5 | while read -r line; do
            echo "  $line"
            has_marked_connections=1
        done
    fi
    
    if [ "$has_marked_connections" -eq 0 ]; then
        echo "  未找到已标记的连接"
    fi
    
    # 显示标记文件
    echo -e "\n======== QoS分类标记 ========"
    
    if [ -f "$upload_marks_file" ]; then
        echo "上传标记文件 ($upload_marks_file):"
        cat "$upload_marks_file" 2>/dev/null || echo "  文件读取错误"
    else
        echo "上传标记文件: 未找到"
    fi
    
    echo ""
    
    if [ -f "$download_marks_file" ]; then
        echo "下载标记文件 ($download_marks_file):"
        cat "$download_marks_file" 2>/dev/null || echo "  文件读取错误"
    else
        echo "下载标记文件: 未找到"
    fi
    
    # 系统资源
    echo -e "\n===== 系统资源 ====="
    
    # 简化内存显示
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
    
    # CPU负载
    if [ -f /proc/loadavg ]; then
        load=$(cat /proc/loadavg)
        cpu_count=$(grep -c processor /proc/cpuinfo 2>/dev/null || echo 1)
        echo "CPU负载: $load (核心数: $cpu_count)"
    else
        echo "CPU负载: 无法获取"
    fi
    
    # 网络接口统计
    echo -e "\n===== 网络接口统计 ====="
    echo "WAN接口 ($qos_interface) 统计:"
    ifconfig "$qos_interface" 2>/dev/null | grep -E "(RX|TX) packets|bytes" | sed 's/^/  /'
    
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\nIFB接口 ($qos_ifb) 统计:"
        ifconfig "$qos_ifb" 2>/dev/null | grep -E "(RX|TX) packets|bytes" | sed 's/^/  /'
    fi
    
    # 连接跟踪统计
    if [ -f /proc/net/nf_conntrack ] || [ -f /proc/sys/net/netfilter/nf_conntrack_count ]; then
        echo -e "\n===== 连接跟踪 ====="
        if [ -f /proc/sys/net/netfilter/nf_conntrack_count ]; then
            conntrack_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "未知")
            conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "未知")
            echo "活动连接: $conntrack_count / $conntrack_max"
        elif [ -f /proc/net/nf_conntrack ]; then
            conntrack_count=$(wc -l < /proc/net/nf_conntrack 2>/dev/null || echo "0")
            conntrack_max=$(sysctl -n net.nf_conntrack_max 2>/dev/null || echo "未知")
            echo "活动连接: $conntrack_count / $conntrack_max"
        fi
    fi
    
    # QoS运行状态摘要
    echo -e "\n===== QoS运行状态 ====="
    local upload_active=0
    local download_active=0
    
    # 检查上传QoS
    if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "htb"; then
        upload_active=1
        echo "上传QoS: 已启用 (HTB+FQ-CoDel)"
        
        # 显示HTB统计
        tc -s qdisc show dev "$qos_interface" 2>/dev/null | grep -A5 "htb" | while read -r line; do
            echo "  $line"
        done
    else
        echo "上传QoS: 未启用"
    fi
    
    # 检查下载QoS
    if tc qdisc show dev "$qos_ifb" 2>/dev/null | grep -q "htb"; then
        download_active=1
        echo -e "\n下载QoS: 已启用 (HTB+FQ-CoDel)"
        
        # 显示HTB统计
        tc -s qdisc show dev "$qos_ifb" 2>/dev/null | grep -A5 "htb" | while read -r line; do
            echo "  $line"
        done
    else
        echo -e "\n下载QoS: 未启用"
    fi
    
    # 总体状态
    if [ "$upload_active" -eq 1 ] && [ "$download_active" -eq 1 ]; then
        echo -e "\n✓ QoS双向流量整形已启用 (HTB+FQ-CoDel)"
    elif [ "$upload_active" -eq 1 ]; then
        echo -e "\n⚠ 仅上传QoS已启用 (HTB+FQ-CoDel)"
    elif [ "$download_active" -eq 1 ]; then
        echo -e "\n⚠ 仅下载QoS已启用 (HTB+FQ-CoDel)"
    else
        echo -e "\n✗ QoS未运行"
    fi
    
    # 显示FQ-CoDel特定配置
    echo -e "\n===== FQ-CoDel专用配置 ====="
    echo "队列数: ${FQ_CODEL_FLOWS}"
    echo "Interval: ${FQ_CODEL_INTERVAL}ms"
    echo "Target: ${FQ_CODEL_TARGET}ms"
    echo "ECN: ${FQ_CODEL_ECN_ENABLED}"
    echo "Quantum: ${FQ_CODEL_QUANTUM}"
    echo "内存限制: ${FQ_CODEL_MEMORY_LIMIT}MB"
    echo "CE阈值: ${FQ_CODEL_CE_THRESHOLD}ms"
    echo "Flow Priomap: ${FQ_CODEL_FLOW_PRIOMAP}"
    
    # 显示带宽配置
    echo -e "\n带宽限制:"
    echo "  上传: ${total_upload_bandwidth:-未设置}kbit/s"
    echo "  下载: ${total_download_bandwidth:-未设置}kbit/s"
    
    # 显示当前连接数
    echo -e "\n===== 当前连接统计 ====="
    if command -v conntrack >/dev/null 2>&1; then
        local total_conn=$(conntrack -L 2>/dev/null | wc -l)
        local tcp_conn=$(conntrack -L -p tcp 2>/dev/null | wc -l)
        local udp_conn=$(conntrack -L -p udp 2>/dev/null | wc -l)
        local icmp_conn=$(conntrack -L -p icmp 2>/dev/null | wc -l)
        
        echo "总连接数: $total_conn"
        echo "  TCP: $tcp_conn"
        echo "  UDP: $udp_conn"
        echo "  ICMP: $icmp_conn"
    else
        echo "无法获取连接统计 (conntrack工具不可用)"
    fi
    
    # 显示最后配置时间
    if [ -f "/tmp/qos_gargoyle_last_config" ]; then
        local last_config=$(cat /tmp/qos_gargoyle_last_config 2>/dev/null)
        echo -e "\n最后配置时间: ${last_config:-未知}"
    fi
    
    echo -e "\n===== 状态报告结束 ====="
    
    return 0
}

# ========== 主函数 ==========

main_fq_codel_qos() {
    local action="$1"
    
    case "$action" in
        start)
            logger -t "qos_gargoyle" "启动HTB+FQ-CoDel QoS"
            initialize_fq_codel_qos
            ;;
        stop)
            logger -t "qos_gargoyle" "停止HTB+FQ-CoDel QoS"
            stop_fq_codel_qos
            ;;
        restart)
            logger -t "qos_gargoyle" "重启HTB+FQ-CoDel QoS"
            stop_fq_codel_qos
            sleep 2
            initialize_fq_codel_qos
            ;;
        status|show)
            # 显示状态
            echo "FQ-CoDel QoS状态:"
            echo "  接口: $qos_interface"
            echo "  IFB设备: $IFB_DEVICE"
            echo "  上传带宽: ${total_upload_bandwidth}kbit/s"
            echo "  下载带宽: ${total_download_bandwidth}kbit/s"
            
            # 检查TC队列
            echo -e "\nTC队列状态:"
            tc -s qdisc show dev "$qos_interface" 2>/dev/null
            if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
                tc -s qdisc show dev "$IFB_DEVICE" 2>/dev/null
            fi
            
            # 检查连接标记
            echo -e "\n连接标记统计:"
            conntrack -L 2>/dev/null | grep "mark=" | wc -l | awk '{print "  已标记连接: "$1}'
            ;;
        *)
            echo "用法: $0 {start|stop|restart|status}"
            exit 1
            ;;
    esac
}

# 如果脚本被直接调用
if [ "$(basename "$0")" = "fq-codel-helper.sh" ]; then
    main_fq_codel_qos "$1"
fi

logger -t "qos_gargoyle" "FQ-CoDel助手模块加载完成"