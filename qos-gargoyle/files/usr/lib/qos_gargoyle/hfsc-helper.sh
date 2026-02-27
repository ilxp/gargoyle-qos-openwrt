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

echo "HFSC 模块初始化完成"
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

# ========= HFSC专属常量 ==========
HFSC_SFQ_DEPTH=""
HFSC_LATENCY_MODE="normal"
HFSC_MINRTT_ENABLED="0"

# ========== 配置加载函数 ==========

# 加载HFSC专属配置
load_hfsc_config() {
    logger -t "qos_gargoyle" "加载HFSC配置"
    
    # 从UCI配置读取HFSC特定参数
    local sfq_depth_config=$(uci -q get qos_gargoyle.hfsc.sfq_depth 2>/dev/null)
    HFSC_SFQ_DEPTH="${sfq_depth_config:-}"
    
    HFSC_LATENCY_MODE=$(uci -q get qos_gargoyle.hfsc.latency_mode 2>/dev/null)
    HFSC_LATENCY_MODE="${HFSC_LATENCY_MODE:-normal}"
    
    HFSC_MINRTT_ENABLED=$(uci -q get qos_gargoyle.hfsc.minrtt_enabled 2>/dev/null)
    HFSC_MINRTT_ENABLED="${HFSC_MINRTT_ENABLED:-0}"
    
    # 处理SFQ深度参数 - 修复"auto"参数问题
    if [ "$HFSC_SFQ_DEPTH" = "auto" ] || [ -z "$HFSC_SFQ_DEPTH" ]; then
        # 根据系统内存自动设置SFQ深度
        local total_mem=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
        if [ -z "$total_mem" ]; then
            total_mem=0
        fi
        
        if [ "$total_mem" -lt 64000 ]; then
            HFSC_SFQ_DEPTH="depth 32"
        elif [ "$total_mem" -lt 128000 ]; then
            HFSC_SFQ_DEPTH="depth 64"
        else
            HFSC_SFQ_DEPTH="depth 128"
        fi
    elif [ -n "$HFSC_SFQ_DEPTH" ]; then
        # 用户指定了具体的深度值
        HFSC_SFQ_DEPTH="depth $HFSC_SFQ_DEPTH"
    fi
    
    logger -t "qos_gargoyle" "HFSC配置: SFQ深度设置=${HFSC_SFQ_DEPTH:-未设置}, 延迟模式=${HFSC_LATENCY_MODE}, minRTT=${HFSC_MINRTT_ENABLED}"
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

#读取标记文件
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

# ========== HFSC核心队列函数 ==========

# 创建HFSC根队列 - 专为HFSC算法设计
create_hfsc_root_qdisc() {
    local device="$1"
    local direction="$2"  # upload 或 download
    local root_handle="$3"  # 1:0 或 2:0
    local root_classid="$4"  # 1:1 或 2:1
    
    # 根据方向获取带宽
    local bandwidth=""
    if [ "$direction" = "upload" ]; then
        bandwidth="${total_upload_bandwidth}"
    elif [ "$direction" = "download" ]; then
        bandwidth="${total_download_bandwidth}"
    else
        logger -t "qos_gargoyle" "错误: 未知方向: $direction"
        return 1
    fi
    
    logger -t "qos_gargoyle" "为$device创建$direction方向HFSC根队列 (带宽: ${bandwidth}kbit)"
    
    # 删除现有队列
    tc qdisc del dev "$device" root 2>/dev/null || true
    tc qdisc del dev "$device" ingress 2>/dev/null || true
    
    # 创建HFSC根队列
    echo "正在为 $device 创建 HFSC 根队列..."
    if ! tc qdisc add dev "$device" root handle $root_handle hfsc; then
        logger -t "qos_gargoyle" "错误: 无法在 $device 上创建HFSC根队列"
        return 1
    fi
    
    # 创建根类
    echo "正在为 $device 创建 HFSC 根类..."
    if ! tc class add dev "$device" parent $root_handle classid $root_classid hfsc ls m2 ${bandwidth}kbit ul m2 ${bandwidth}kbit; then
        logger -t "qos_gargoyle" "错误: 无法在$device上创建HFSC根类"
        echo "错误: 无法在 $device 上创建 HFSC 根类"
        return 1
    fi
    
    logger -t "qos_gargoyle" "$device的$direction方向HFSC根队列创建完成"
    echo "$device 的 $direction 方向 HFSC 根队列创建完成"
    return 0
}

# 创建HFSC上传类别
create_hfsc_upload_class() {
    local class_name="$1"
    local class_index="$2"
    
    logger -t "qos_gargoyle" "创建上传类别: $class_name, ID: 1:$class_index"
    
    # 加载类别配置
    load_all_config_options "$CONFIG_FILE" "$class_name"
    
    # 获取标记值
    local class_mark=$(read_mark_from_file "$class_name" "upload")
    
    if [ -z "$class_mark" ]; then
        # 备用方案：基于类别索引计算
        local class_num=$(echo "$class_name" | sed -E 's/^upload_class_//')
        if [ -n "$class_num" ] && echo "$class_num" | grep -qE '^[0-9]+$'; then
            class_mark=$(printf "0x%X" $((0x1 << (class_num - 1))))
        else
            # 基于class_index计算
            class_mark=$(printf "0x%X" $((0x1 << (class_index - 2))))
        fi
        logger -t "qos_gargoyle" "警告: 从文件读取标记失败，使用计算值: $class_mark"
    else
        logger -t "qos_gargoyle" "从文件获取上传标记: $class_mark"
    fi
    
    # 计算带宽参数
    local m1="0bit"
    local d="0us"
    local m2="${total_upload_bandwidth}kbit"  # 默认值
    local ul_m2="${total_upload_bandwidth}kbit"  # 默认值
    
    # 如果有百分比带宽
    if [ -n "$percent_bandwidth" ] && [ "$percent_bandwidth" -gt 0 ] 2>/dev/null; then
        m2="$((total_upload_bandwidth * percent_bandwidth / 100))kbit"
    fi
    
    # 如果有最小带宽
    if [ -n "$min_bandwidth" ] && [ "$min_bandwidth" -gt 0 ] 2>/dev/null; then
        m2="${min_bandwidth}kbit"
    fi
    
    # 如果有最大带宽
    if [ -n "$max_bandwidth" ] && [ "$max_bandwidth" -gt 0 ] 2>/dev/null; then
        ul_m2="${max_bandwidth}kbit"
    fi
    
    # 如果是最小延迟类别
    if [ "${minRTT:-No}" = "Yes" ]; then
        d="5ms"  # 5毫秒延迟上限
    fi
    
    # 创建HFSC类别
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:$class_index hfsc \
        ls m1 $m1 d $d m2 $m2 \
        ul rate $ul_m2 2>&1 | logger -t "qos_gargoyle"; then
        logger -t "qos_gargoyle" "错误: 创建上传类别 1:$class_index 失败 (带宽: ls=$m2, ul=$ul_m2)"
        return 1
    fi
    
    # 创建SFQ队列
    if [ -n "$HFSC_SFQ_DEPTH" ]; then
        if ! tc qdisc add dev "$qos_interface" parent 1:$class_index \
            handle ${class_index}:1 sfq headdrop limit 1000 $HFSC_SFQ_DEPTH divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加上传SFQ队列失败"
            return 1
        fi
    else
        if ! tc qdisc add dev "$qos_interface" parent 1:$class_index \
            handle ${class_index}:1 sfq headdrop limit 1000 divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加上传SFQ队列失败"
            return 1
        fi
    fi
    
    # 添加过滤器（如果配置了标记）
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
    
    logger -t "qos_gargoyle" "上传类别创建成功: $class_name -> 1:$class_index (标记: $class_mark)"
    return 0
}

# 创建HFSC下载类别
create_hfsc_download_class() {
    local class_name="$1"
    local class_index="$2"
    local priority="$3"
    
    logger -t "qos_gargoyle" "创建下载类别: $class_name, ID: 1:$class_index, 优先级: $priority"
    
    # 加载类别配置
    load_all_config_options "$CONFIG_FILE" "$class_name"
    
    # 获取标记值
    local class_mark=$(read_mark_from_file "$class_name" "download")
    
    if [ -z "$class_mark" ]; then
        # 备用方案：基于类别索引计算
        # 重要：下载标记的计算基数是0x100，不是0x1
        local class_num=$(echo "$class_name" | sed -E 's/^download_class_//')
        if [ -n "$class_num" ] && echo "$class_num" | grep -qE '^[0-9]+$'; then
            # 下载标记: 0x100 << (class_num-1)
            class_mark=$(printf "0x%X" $((0x100 << (class_num - 1))))
        else
            # 基于class_index计算
            # 重要：下载标记的基数是0x100
            class_mark=$(printf "0x%X" $((0x100 << (class_index - 2))))
        fi
        logger -t "qos_gargoyle" "警告: 从文件读取标记失败，使用计算值: $class_mark"
    else
        # 注意日志信息也要改为"下载标记"
        logger -t "qos_gargoyle" "从文件获取下载标记: $class_mark"
    fi
    
    # 计算带宽参数
    local m1="0bit"
    local d="0us"
    local m2="${total_download_bandwidth}kbit"  # 默认值
    local ul_m2="${total_download_bandwidth}kbit"  # 默认值
    
    # 如果有百分比带宽
    if [ -n "$percent_bandwidth" ] && [ "$percent_bandwidth" -gt 0 ] 2>/dev/null; then
        m2="$((total_download_bandwidth * percent_bandwidth / 100))kbit"
    fi
    
    # 如果有最小带宽
    if [ -n "$min_bandwidth" ] && [ "$min_bandwidth" -gt 0 ] 2>/dev/null; then
        m2="${min_bandwidth}kbit"
    fi
    
    # 如果有最大带宽
    if [ -n "$max_bandwidth" ] && [ "$max_bandwidth" -gt 0 ] 2>/dev/null; then
        ul_m2="${max_bandwidth}kbit"
    fi
    
    # 如果是最小延迟类别
    if [ "${minRTT:-No}" = "Yes" ]; then
        d="5ms"  # 5毫秒延迟上限
    fi
    
    # 创建HFSC类别
    if ! tc class add dev "$IFB_DEVICE" parent 1:1 \
        classid 1:$class_index hfsc \
        ls m1 $m1 d $d m2 $m2 \
        ul m1 0bit d 0us m2 $ul_m2; then
        logger -t "qos_gargoyle" "错误: 创建下载类别 1:$class_index 失败"
        return 1
    fi
    
    # 创建SFQ队列
    if [ -n "$HFSC_SFQ_DEPTH" ]; then
        if ! tc qdisc add dev "$IFB_DEVICE" parent 1:$class_index \
            handle ${class_index}:1 sfq headdrop limit 1000 $HFSC_SFQ_DEPTH divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加下载SFQ队列失败"
            return 1
        fi
    else
        if ! tc qdisc add dev "$IFB_DEVICE" parent 1:$class_index \
            handle ${class_index}:1 sfq headdrop limit 1000 divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加下载SFQ队列失败"
            return 1
        fi
    fi
    
    # 添加过滤器（如果配置了标记）
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
    
    logger -t "qos_gargoyle" "下载类别创建成功: $class_name -> 1:$class_index (标记: $class_mark)"
    return 0
}

# 创建默认上传类别
create_default_upload_class() {
    logger -t "qos_gargoyle" "创建默认上传类别"
    
    # 首先创建根队列
    if ! create_hfsc_root_qdisc "$qos_interface" "upload" "1:0" "1:1"; then
        logger -t "qos_gargoyle" "错误：创建上传根队列失败"
        return 1
    fi
    
    # 创建默认类别（类ID为1:2）
    if ! tc class add dev "$qos_interface" parent 1:1 \
        classid 1:2 hfsc ls m2 ${total_upload_bandwidth}kbit ul m2 ${total_upload_bandwidth}kbit; then
        logger -t "qos_gargoyle" "错误: 创建上传类 1:2 失败"
        return 1
    fi
    
    # 添加SFQ队列
    if [ -n "$HFSC_SFQ_DEPTH" ]; then
        if ! tc qdisc add dev "$qos_interface" parent 1:2 \
            handle 2:1 sfq headdrop limit 1000 $HFSC_SFQ_DEPTH divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加上传SFQ队列失败"
            return 1
        fi
    else
        if ! tc qdisc add dev "$qos_interface" parent 1:2 \
            handle 2:1 sfq headdrop limit 1000 divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加上传SFQ队列失败"
            return 1
        fi
    fi
    
    # 设置根队列的默认类为1:2
    if ! tc qdisc change dev "$qos_interface" root handle 1:0 hfsc default 2; then
        logger -t "qos_gargoyle" "警告: 设置上传默认类失败"
    fi
    
    # 添加过滤器（将标记为0x1的流量导向该类）
    local mark_hex="0x1"
    if ! tc filter add dev "$qos_interface" parent 1:0 protocol ip \
        prio 1 handle ${mark_hex}/$UPLOAD_MASK fw flowid 1:2; then
        logger -t "qos_gargoyle" "警告: 添加上传IPv4过滤器失败"
    fi
    
    # IPv6过滤器
    if ! tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
        prio 2 handle ${mark_hex}/$UPLOAD_MASK fw flowid 1:2; then
        logger -t "qos_gargoyle" "警告: 添加上传IPv6过滤器失败"
    fi
    
    upload_class_mark_list="default_class:$mark_hex"
    logger -t "qos_gargoyle" "默认上传类别创建完成 (类ID: 1:2, 标记: $mark_hex)"
    return 0
}

# 创建默认下载类别
create_default_download_class() {
    logger -t "qos_gargoyle" "创建默认下载类别"
    
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
    if ! create_hfsc_root_qdisc "$IFB_DEVICE" "download" "1:0" "1:1"; then
        logger -t "qos_gargoyle" "错误：创建下载根队列失败"
        return 1
    fi
    
    # 创建默认类别（类ID为1:2）
    if ! tc class add dev "$IFB_DEVICE" parent 1:1 \
        classid 1:2 hfsc ls m2 ${total_download_bandwidth}kbit ul m2 ${total_download_bandwidth}kbit; then
        logger -t "qos_gargoyle" "错误: 创建下载类 1:2 失败"
        return 1
    fi
    
    # 添加SFQ队列
    if [ -n "$HFSC_SFQ_DEPTH" ]; then
        if ! tc qdisc add dev "$IFB_DEVICE" parent 1:2 \
            handle 2:1 sfq headdrop limit 1000 $HFSC_SFQ_DEPTH divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加下载SFQ队列失败"
            return 1
        fi
    else
        if ! tc qdisc add dev "$IFB_DEVICE" parent 1:2 \
            handle 2:1 sfq headdrop limit 1000 divisor 256; then
            logger -t "qos_gargoyle" "错误: 添加下载SFQ队列失败"
            return 1
        fi
    fi
    
    # 设置根队列的默认类为1:2
    if ! tc qdisc change dev "$IFB_DEVICE" root handle 1:0 hfsc default 2; then
        logger -t "qos_gargoyle" "警告: 设置下载默认类失败"
    fi
    
    # 添加过滤器（将标记为0x100的流量导向该类）
    local mark_hex="0x100"
    if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ip \
        prio 1 handle ${mark_hex}/$DOWNLOAD_MASK fw flowid 1:2; then
        logger -t "qos_gargoyle" "警告: 添加下载IPv4过滤器失败"
    fi
    
    # IPv6过滤器
    if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
        prio 2 handle ${mark_hex}/$DOWNLOAD_MASK fw flowid 1:2; then
        logger -t "qos_gargoyle" "警告: 添加下载IPv6过滤器失败"
    fi
    
    # 设置入口重定向
    if ! setup_ingress_redirect; then
        logger -t "qos_gargoyle" "警告: 设置入口重定向失败"
    fi
    
    download_class_mark_list="default_class:$mark_hex"
    logger -t "qos_gargoyle" "默认下载类别创建完成 (类ID: 1:2, 标记: $mark_hex)"
    return 0
}

# ========== HFSC过滤器函数 ==========

# 创建双栈过滤器
create_dualstack_filter() {
    # HFSC特定的TC过滤器实现
    tc filter add dev "$1" parent "$2" protocol ip \
        handle ${4}/$5 fw flowid "$3"
    
    tc filter add dev "$1" parent "$2" protocol ipv6 \
        handle ${4}/$5 fw flowid "$3"
}

# 创建带优先级的双栈过滤器
create_priority_dualstack_filter() {
    # HFSC特定的带优先级的TC过滤器
    tc filter add dev "$1" parent "$2" protocol ip \
        prio $6 handle ${4}/$5 fw flowid "$3"
    
    tc filter add dev "$1" parent "$2" protocol ipv6 \
        prio $((6 + 1)) handle ${4}/$5 fw flowid "$3"
}

# 应用HFSC特定增强规则
apply_hfsc_specific_rules() {
    logger -t "qos_gargoyle" "应用HFSC特定增强规则"
    
    # 只添加HFSC特有的规则，而不是所有分类规则
    # 例如：HFSC优先级映射、TC过滤器等
    
    # 1. HFSC优先级设置
    nft add rule inet gargoyle-qos-priority filter_qos_egress \
        meta mark and 0x007f != 0 counter meta priority set "bulk"
    
    nft add rule inet gargoyle-qos-priority filter_qos_ingress \
        meta mark and 0x7f00 != 0 counter meta priority set "bulk"
    
    # 2. HFSC连接跟踪优化
    nft add rule inet gargoyle-qos-priority filter_qos_egress \
        ct state established,related counter meta mark set ct mark
    
    logger -t "qos_gargoyle" "HFSC特定增强规则应用完成"
}

# 保留这些函数，但重命名以明确其用途
apply_hfsc_tc_filters() {
    logger -t "qos_gargoyle" "应用HFSC TC过滤器"
    
    # 这些是HFSC特有的TC过滤器，不是nftables规则
    if [ -n "$total_upload_bandwidth" ] && [ "$total_upload_bandwidth" -gt 0 ]; then
        apply_upload_tc_filters
    fi
    
    if [ -n "$total_download_bandwidth" ] && [ "$total_download_bandwidth" -gt 0 ]; then
        apply_download_tc_filters
    fi
}

# 添加上傳 TC 過濾器
apply_upload_tc_filters() {
    logger -t "qos_gargoyle" "應用上傳 TC 過濾器（空實現）"
    # 此處留空，因為在 HFSC 初始化時已經設置了過濾器
    return 0
}

# 添加下載 TC 過濾器
apply_download_tc_filters() {
    logger -t "qos_gargoyle" "應用下載 TC 過濾器（空實現）"
    # 此處留空，因為在 HFSC 初始化時已經設置了過濾器
    return 0
}

# ========== 入口重定向相关函数 ==========

# 设置入口重定向
setup_ingress_redirect() {
    # 确保 qos_interface 有值
    if [ -z "$qos_interface" ]; then
        # 从配置获取
        qos_interface=$(uci -q get qos_gargoyle.global.wan_interface 2>/dev/null)
        
        # 如果配置中没有，尝试从系统检测
        if [ -z "$qos_interface" ] && [ -f "/lib/functions/network.sh" ]; then
            . /lib/functions/network.sh
            network_find_wan qos_interface
        fi
        
        # 如果还是没有，使用默认值
        qos_interface="${qos_interface:-pppoe-wan}"
    fi
    
    # 确保 IFB_DEVICE 有值
    if [ -z "$IFB_DEVICE" ]; then
        IFB_DEVICE="ifb0"
    fi
    
    # 再次调试输出
    echo "DEBUG: qos_interface = $qos_interface"
    echo "DEBUG: IFB_DEVICE = $IFB_DEVICE"
    
    # 检查变量是否有效
    if [ -z "$qos_interface" ]; then
        echo "错误: 无法确定 WAN 接口"
        return 1
    fi
    
    if [ -z "$IFB_DEVICE" ]; then
        echo "错误: IFB 设备名称未设置"
        return 1
    fi   
    logger -t "qos_gargoyle" "设置入口重定向: $qos_interface -> $IFB_DEVICE"
    
    # 在WAN接口上创建ingress队列
    echo "在 $qos_interface 上创建入口队列..."
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null
    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        logger -t "qos_gargoyle" "错误: 无法在 $qos_interface 上创建入口队列"
        return 1
    fi
    
    # 清除现有的入口过滤器
    echo "清理现有入口过滤器..."
    tc filter del dev "$qos_interface" parent ffff: 2>/dev/null
    
    # 重定向所有IPv4流量到IFB设备
    echo "设置IPv4入口重定向规则..."
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ip \
        u32 match u32 0 0 \
        action connmark \
        action mirred egress redirect dev "$IFB_DEVICE"; then
        logger -t "qos_gargoyle" "警告: IPv4入口重定向规则添加失败"
    else
        echo "IPv4入口重定向规则添加成功"
    fi
    
    # 重定向所有IPv6流量到IFB设备
    echo "设置IPv6入口重定向规则..."
    if ! tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
        u32 match u32 0 0 \
        action connmark pipe \
        action mirred egress redirect dev "$IFB_DEVICE"; then
        logger -t "qos_gargoyle" "警告: IPv6入口重定向规则添加失败"
    else
        echo "IPv6入口重定向规则添加成功"
    fi
    
    # 验证入口重定向配置
    echo "验证入口重定向配置..."
    local ingress_rules=$(tc filter show dev "$qos_interface" parent ffff: 2>/dev/null | wc -l)
    
    if [ "$ingress_rules" -ge 2 ]; then
        logger -t "qos_gargoyle" "入口重定向已成功设置: $qos_interface -> $IFB_DEVICE"
        echo "入口重定向设置完成"
        
        # 显示当前入口过滤器配置
        echo "当前入口过滤器配置:"
        tc filter show dev "$qos_interface" parent ffff: 2>/dev/null || echo "  无入口过滤器"
    else
        logger -t "qos_gargoyle" "错误: 入口重定向规则数量不足 ($ingress_rules 条)"
        echo "警告: 入口重定向规则可能未完全设置"
        return 1
    fi
    
    return 0
}

check_ingress_redirect() {
    local iface="$1"
    local ifb_dev="${IFB_DEVICE:-ifb0}"
    echo "检查入口重定向 (接口: $iface, IFB设备: $ifb_dev)"
    
    # 分别检查IPv4和IPv6规则
    echo "  IPv4入口规则:"
    local ipv4_rules=$(tc filter show dev "$iface" parent ffff: protocol ip 2>/dev/null)
    if [ -n "$ipv4_rules" ]; then
        echo "$ipv4_rules" | sed 's/^/    /'
        
        # 检查mirred动作
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
    if [ -n "$ipv6_rules" ]; then
        echo "$ipv6_rules" | sed 's/^/    /'
        
        # 检查mirred动作
        if echo "$ipv6_rules" | grep -q "mirred.*Redirect to device $ifb_dev"; then
            echo "    ✓ IPv6 重定向到 $ifb_dev: 已生效"
        else
            # 尝试其他可能的匹配
            if echo "$ipv6_rules" | grep -q "mirred.*Egress Redirect to device $ifb_dev"; then
                echo "    ✓ IPv6 重定向到 $ifb_dev: 已生效 (完整格式)"
            else
                echo "    ✗ IPv6 重定向: mirred动作未找到"
            fi
        fi
    else
        echo "    无IPv6入口规则"
    fi
}

# ========== 上传方向初始化 ==========

initialize_hfsc_upload() {
    logger -t "qos_gargoyle" "初始化上传方向HFSC"
    
    # 加载上传类别配置
    load_upload_class_configurations
    
    if [ -z "$upload_class_list" ]; then
        logger -t "qos_gargoyle" "警告：未找到上传类别配置，使用默认类别"
        create_default_upload_class
        return 0
    fi
    
    logger -t "qos_gargoyle" "找到上传类别：$upload_class_list"
    
    # 创建根队列
    if ! create_hfsc_root_qdisc "$qos_interface" "upload" "1:0" "1:1"; then
        logger -t "qos_gargoyle" "错误：创建上传根队列失败"
        return 1
    fi
    
    # 创建各个类别
    local class_index=2
    upload_class_mark_list=""
    
    for class_name in $upload_class_list; do
        create_hfsc_upload_class "$class_name" "$class_index"
        if [ $? -eq 0 ]; then
            # 尝试从配置获取标记值
            local class_mark_hex=""
            
            # 加载类别配置
            load_all_config_options "$CONFIG_FILE" "$class_name"
            
            # 如果配置中有 class_mark，使用配置的值
            if [ -n "$class_mark" ] && [ "$class_mark" != "0x0" ]; then
                class_mark_hex="$class_mark"
                logger -t "qos_gargoyle" "使用配置的标记值: $class_name -> $class_mark_hex"
            else
                # 否则使用自动计算的值
                local mark_value=$((class_index << upload_shift))
                class_mark_hex=$(printf "0x%X" $mark_value)
                logger -t "qos_gargoyle" "自动计算标记值: $class_name -> $class_mark_hex"
            fi
            
            # 添加标记到列表
            upload_class_mark_list="$upload_class_mark_list$class_name:$class_mark_hex "
            
            # 添加过滤器
            if [ -n "$class_mark_hex" ] && [ "$class_mark_hex" != "0x0" ]; then
                tc filter add dev "$qos_interface" parent 1:0 protocol ip \
                    prio 1 handle ${class_mark_hex}/$UPLOAD_MASK fw flowid 1:$class_index
                    
                tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
                    prio 2 handle ${class_mark_hex}/$DOWNLOAD_MASK fw flowid 1:$class_index
            fi
        fi
        class_index=$((class_index + 1))
    done
    
    # 设置默认类别
    set_default_upload_class
    
    # 创建上传链
    create_upload_chain
    
    logger -t "qos_gargoyle" "上传方向HFSC初始化完成"
    return 0
}

# ========== 下载方向初始化 ==========

initialize_hfsc_download() {
    logger -t "qos_gargoyle" "初始化下载方向HFSC"
    
    # 加载下载类别配置
    load_download_class_configurations
    
    if [ -z "$download_class_list" ]; then
        logger -t "qos_gargoyle" "警告：未找到下载类别配置，使用默认类别"
        create_default_download_class
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
    
    # 创建根队列（在IFB设备上）
    if ! create_hfsc_root_qdisc "$IFB_DEVICE" "download" "1:0" "1:1"; then
        logger -t "qos_gargoyle" "错误：创建下载根队列失败"
        return 1
    fi
    
    # 创建各个类别
    local class_index=2
    local priority=3  # 为高优先级类别预留1-2
    download_class_mark_list=""
    
    for class_name in $download_class_list; do
        create_hfsc_download_class "$class_name" "$class_index" "$priority"
        if [ $? -eq 0 ]; then
            # 尝试从配置获取标记值
            local class_mark_hex=""
            
            # 加载类别配置
            load_all_config_options "$CONFIG_FILE" "$class_name"
            
            # 如果配置中有 class_mark，使用配置的值
            if [ -n "$class_mark" ] && [ "$class_mark" != "0x0" ]; then
                class_mark_hex="$class_mark"
                logger -t "qos_gargoyle" "使用配置的标记值: $class_name -> $class_mark_hex"
            else
                # 否则使用自动计算的值
                local mark_value=$((class_index << download_shift))
                class_mark_hex=$(printf "0x%X" $mark_value)
                logger -t "qos_gargoyle" "自动计算标记值: $class_name -> $class_mark_hex"
            fi
            
            # 添加标记到列表
            download_class_mark_list="$download_class_mark_list$class_name:$class_mark_hex "
            
            # 添加过滤器到IFB设备
            if [ -n "$class_mark_hex" ] && [ "$class_mark_hex" != "0x0" ]; then
                # IPv4过滤器
                if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ip \
                    prio $priority handle ${class_mark_hex}/$DOWNLOAD_MASK fw flowid 1:$class_index; then
                    logger -t "qos_gargoyle" "警告: 添加下载IPv4过滤器失败 (类别: $class_name)"
                else
                    logger -t "qos_gargoyle" "下载IPv4过滤器添加成功: 标记=$class_mark_hex, 类别ID=1:$class_index"
                fi
                
                # IPv6过滤器
                if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
                    prio $((priority + 1)) handle ${class_mark_hex}/$DOWNLOAD_MASK fw flowid 1:$class_index; then
                    logger -t "qos_gargoyle" "警告: 添加下载IPv6过滤器失败 (类别: $class_name)"
                else
                    logger -t "qos_gargoyle" "下载IPv6过滤器添加成功: 标记=$class_mark_hex, 类别ID=1:$class_index"
                fi
                
                # 处理IPv4-mapped IPv6地址的过滤器
                if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
                    u32 match ip6 dst ::ffff:0:0/96 \
                    action connmark set $class_mark_hex \
                    flowid 1:$class_index; then
                    logger -t "qos_gargoyle" "警告: 添加IPv4-mapped IPv6过滤器失败 (类别: $class_name)"
                fi
            fi
        fi
        class_index=$((class_index + 1))
        priority=$((priority + 2))
    done
    
    # 设置默认类别
    set_default_download_class
    
    # 创建下载链和入口重定向
    create_download_chain
    setup_ingress_redirect
    
    logger -t "qos_gargoyle" "下载方向HFSC初始化完成"
    return 0
}


#================默认配置分类==========
# 从配置读取默认类别，并动态映射到对应的TC类ID
create_upload_chain() {
    logger -t "qos_gargoyle" "创建上传链（空函数，已由initialize_hfsc_upload处理）"
    return 0
}

# 从配置读取默认类别，并动态映射到对应的TC类ID
set_default_upload_class() {
    logger -t "qos_gargoyle" "设置上传默认类别"
    
    # 1. 从配置获取用户选择的默认类别名称
    local default_class_name=$(uci -q get qos_gargoyle.upload.default_class 2>/dev/null)
    default_class_name="${default_class_name:-Normal}"
    
    logger -t "qos_gargoyle" "用户配置的上传默认类别名称: $default_class_name"
    
    # 2. 查找这个类别在upload_class_list中的索引位置
    local class_index=2  # TC类ID从1:2开始
    local found_index=2  # 默认值
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
    
    # 3. 设置TC默认类别
    tc qdisc change dev "$qos_interface" root handle 1:0 hfsc default $found_index
    logger -t "qos_gargoyle" "上传默认类别设置为TC类ID: 1:$found_index (对应配置: $default_class_name)"
}

set_default_download_class() {
    logger -t "qos_gargoyle" "设置下载默认类别"
    
    # 1. 从配置获取用户选择的默认类别名称
    local default_class_name=$(uci -q get qos_gargoyle.download.default_class 2>/dev/null)
    default_class_name="${default_class_name:-Normal}"
    
    logger -t "qos_gargoyle" "用户配置的下载默认类别名称: $default_class_name"
    
    # 2. 查找这个类别在download_class_list中的索引位置
    local class_index=2  # TC类ID从1:2开始
    local found_index=2  # 默认值
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
    
    # 3. 设置TC默认类别
    tc qdisc change dev "$IFB_DEVICE" root handle 1:0 hfsc default $found_index
    logger -t "qos_gargoyle" "下载默认类别设置为TC类ID: 1:$found_index (对应配置: $default_class_name)"
}

create_download_chain() {
    logger -t "qos_gargoyle" "创建下载链（包括入口重定向）"
    setup_ingress_redirect
}


# ========== 主初始化函数 ==========

# 主入口：初始化HFSC QoS
initialize_hfsc_qos() {
    logger -t "qos_gargoyle" "开始初始化HFSC QoS系统"
    
    # 1. 加载HFSC专属配置
    load_hfsc_config
    
    # 2. 设置IPv6特定规则
    setup_ipv6_specific_rules
    
    # 3. 初始化上传方向
    if [ "$total_upload_bandwidth" -ge 0 ] && [ "$total_upload_bandwidth" -gt 0 ]; then
        initialize_hfsc_upload
    else
        logger -t "qos_gargoyle" "上传带宽未配置，跳过上传方向初始化"
    fi
    
    # 4. 初始化下载方向
    if [ "$total_download_bandwidth" -ge 0 ] && [ "$total_download_bandwidth" -gt 0 ]; then
        initialize_hfsc_download
    else
        logger -t "qos_gargoyle" "下载带宽未配置，跳过下载方向初始化"
    fi
    
    # 5. 应用HFSC特有的TC过滤器规则
    apply_hfsc_tc_filters
    
    logger -t "qos_gargoyle" "HFSC QoS初始化完成"
}

# ========== 停止和清理函数 ==========

stop_hfsc_qos() {
    logger -t "qos_gargoyle" "停止HFSC QoS"
    
    # 清理上传方向
    if tc qdisc show dev "$qos_interface" | grep -q "hfsc"; then
        tc qdisc del dev "$qos_interface" root 2>/dev/null
        logger -t "qos_gargoyle" "清理上传方向HFSC队列"
    fi
    
    # 清理下载方向
    if tc qdisc show dev "$IFB_DEVICE" | grep -q "hfsc"; then
        tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null
        logger -t "qos_gargoyle" "清理下载方向HFSC队列"
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
    
    logger -t "qos_gargoyle" "HFSC QoS停止完成"
}

# ========== 状态查询函数 ==========

show_hfsc_status() {
    # 确保必要的变量已设置
    local qos_ifb="${IFB_DEVICE:-ifb0}"
    local mark_dir="/etc/qos_gargoyle"
    local upload_marks_file="$mark_dir/upload_class_marks"
    local download_marks_file="$mark_dir/download_class_marks"
    
    # 如果接口未定义，尝试获取
    if [ -z "$qos_interface" ]; then
        # 尝试从TC输出推断接口
        qos_interface=$(tc qdisc show 2>/dev/null | grep -E "hfsc.*root" | awk '{print $5}' | head -1)
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
    
    echo "===== QoS状态报告 ====="
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
    if ! tc qdisc show dev "${qos_interface}" 2>/dev/null | grep -q hfsc; then
        echo "警告: QoS未在接口 ${qos_interface} 上激活"
        return 1
    fi
    
    # 显示出口配置
    echo -e "\n======== 出口QoS ($qos_interface) ========"
    echo "NFT规则:"
    nft list chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null || echo "  无NFT规则"
    
    echo -e "\nTC统计:"
    tc -s qdisc show dev "$qos_interface" 2>/dev/null || echo "  无TC队列"
    
    if tc class show dev "$qos_interface" >/dev/null 2>&1; then
        echo "TC类别:"
        tc -s class show dev "$qos_interface" 2>/dev/null
    fi
    
    echo "TC过滤器:"
    tc -s filter show dev "$qos_interface" 2>/dev/null || echo "  无过滤器"
    
    # 显示入口配置
    echo -e "\n======== 入口QoS ($qos_ifb) ========"
    echo "NFT规则:"
    nft list chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null || echo "  无NFT规则"
    
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\nTC统计:"
        tc -s qdisc show dev "$qos_ifb" 2>/dev/null || echo "  无TC队列"
        
        if tc class show dev "$qos_ifb" >/dev/null 2>&1; then
            echo "TC类别:"
            tc -s class show dev "$qos_ifb" 2>/dev/null
        fi
        
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
    echo -n "CPU负载: "
    uptime | awk -F'load average:' '{print $2}' | sed 's/^[[:space:]]*//' || echo "未知"
    
    # 连接跟踪
    echo -n "连接跟踪条目: "
    if [ -f /proc/sys/net/netfilter/nf_conntrack_count ]; then
        cat /proc/sys/net/netfilter/nf_conntrack_count
    elif command -v conntrack >/dev/null 2>&1; then
        conntrack -C 2>/dev/null || echo "未知"
    else
        echo "未知"
    fi
    
    # QoS状态摘要
    echo -e "\n===== QoS状态摘要 ====="
    
    # 出口状态
    if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q hfsc; then
        local qdisc_info=$(tc qdisc show dev "$qos_interface" 2>/dev/null | grep "hfsc" | head -1)
        echo "出口队列: ${qdisc_info:-已配置 (hfsc)}"
        
        if nft list chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null | grep -q "meta mark set"; then
            echo "出口标记规则: 已配置"
        else
            echo "出口标记规则: 未配置"
        fi
    else
        echo "出口队列: 未配置"
        echo "出口标记规则: 未配置"
    fi
    
    # 入口状态
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        if tc qdisc show dev "$qos_ifb" 2>/dev/null | grep -q hfsc; then
            local ifb_qdisc=$(tc qdisc show dev "$qos_ifb" 2>/dev/null | grep "hfsc" | head -1)
            echo "入口队列: ${ifb_qdisc:-已配置 (hfsc)}"
            
            if nft list chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null | grep -q "meta mark set"; then
                echo "入口标记规则: 已配置"
            else
                echo "入口标记规则: 未配置"
            fi
        else
            echo "入口队列: IFB设备存在但无HFSC队列"
            echo "入口标记规则: 未配置"
        fi
        
        # 检查入口重定向
        if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "ingress"; then
            echo "入口重定向: 已配置"
        else
            echo "入口重定向: 未配置"
        fi
    else
        echo "入口队列: IFB设备未创建"
        echo "入口标记规则: 未配置"
        echo "入口重定向: 未配置"
    fi
    
    # 总体状态
    if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q hfsc; then
        echo "QoS状态: 运行中"
    else
        echo "QoS状态: 已停止"
    fi
}


# ========== 主程序入口 ==========

# 主程序入口
main_hfsc_qos() {
    local action="$1"
    
    case "$action" in
        "start")
            initialize_hfsc_qos
            ;;
        "stop")
            stop_hfsc_qos
            ;;
        "restart")
            stop_hfsc_qos
            sleep 1
            initialize_hfsc_qos
            ;;
        "status")
            show_hfsc_status
            ;;
        *)
            echo "用法: $0 {start|stop|restart|status|debug}"
            exit 1
            ;;
    esac
}

# 如果脚本被直接调用
if [ "$(basename "$0")" = "hfsc-qos.sh" ]; then
    main_hfsc_qos "$1"
fi

logger -t "qos_gargoyle" "HFSC助手模块加载完成"