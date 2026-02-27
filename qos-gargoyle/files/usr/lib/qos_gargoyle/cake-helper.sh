#!/bin/sh
# CAKE算法实现模块
# 基于Common Applications Kept Enhanced算法实现QoS流量控制

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

echo "CAKE 模块初始化完成"
echo "  网络接口: $qos_interface"
echo "  IFB 设备: $IFB_DEVICE"
echo "  上传带宽: ${total_upload_bandwidth}kbit/s"
echo "  下载带宽: ${total_download_bandwidth}kbit/s"

# 加载必要的库
if [ -f "/lib/functions.sh" ]; then
    . /lib/functions.sh
fi

if [ -f "/lib/functions/network.sh" ]; then
    . /lib/functions/network.sh
fi

# 加载公共规则辅助模块
if [ -f "/usr/lib/qos_gargoyle/rule-helper.sh" ]; then
    . /usr/lib/qos_gargoyle/rule-helper.sh
    logger -t "qos_gargoyle" "已加载规则辅助模块"
else
    logger -t "qos_gargoyle" "警告: 规则辅助模块未找到"
fi

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
CAKE_MEMORY_LIMIT="32Mb"

# ========== 辅助函数 ==========

# 加载配置选项
load_all_config_options() {
    local config_file="$1"
    local config_section="$2"
    
    # 清除所有配置选项变量
    unset class_mark priority min_bandwidth max_bandwidth percent_bandwidth minRTT
    unset class rate family proto srcport dstport connbytes_kb
    
    # 通过 config_get 加载配置
    config_get class_mark "$config_section" class_mark
    config_get priority "$config_section" priority
    config_get min_bandwidth "$config_section" min_bandwidth
    config_get max_bandwidth "$config_section" max_bandwidth
    config_get percent_bandwidth "$config_section" percent_bandwidth
    config_get minRTT "$config_section" minRTT
    config_get class "$config_section" class
    config_get rate "$config_section" rate
    config_get family "$config_section" family
    config_get proto "$config_section" proto
    config_get srcport "$config_section" srcport
    config_get dstport "$config_section" dstport
    config_get connbytes_kb "$config_section" connbytes_kb
}

# 加载所有配置节
load_all_config_sections() {
    local config_file="$1"
    local config_type="$2"
    local result=""
    
    # 从UCI配置中查找指定类型的节
    local sections=$(uci show "$config_file" 2>/dev/null | \
        grep -E "^$config_file\.[a-zA-Z0-9_]+=$config_type\$" | \
        cut -d. -f2 | cut -d= -f1)
    
    echo "$sections"
}

# 加载并按排序值排序配置节
load_and_sort_all_config_sections() {
    local config_file="$1"
    local config_type="$2"
    local sort_option="$3"
    local result=""
    
    # 简单的实现，不排序
    load_all_config_sections "$config_file" "$config_type"
}

# 根据类别名称获取标记
get_classname_mark() {
    local class_name="$1"
    local class_mark_list="$2"
    
    # 在类别标记列表中查找
    for entry in $class_mark_list; do
        local name=$(echo "$entry" | cut -d: -f1)
        local mark=$(echo "$entry" | cut -d: -f2)
        
        if [ "$name" = "$class_name" ]; then
            echo "$mark"
            return 0
        fi
    done
    
    echo ""
    return 1
}

# 清理标记值（移除注释）
clean_mark_value() {
    local mark="$1"
    # 移除注释和空格
    echo "$mark" | sed -E 's/#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ========== 配置加载函数 ==========

# 加载CAKE专属配置
load_cake_config() {
    logger -t "qos_gargoyle" "加载CAKE配置"
    
    # 从UCI配置读取CAKE特定参数
    local diffserv_mode_config=$(uci -q get qos_gargoyle.cake.diffserv_mode 2>/dev/null)
    CAKE_DIFFSERV_MODE="${diffserv_mode_config:-diffserv4}"
    
    local overhead_config=$(uci -q get qos_gargoyle.cake.overhead 2>/dev/null)
    CAKE_OVERHEAD="${overhead_config:-0}"
    
    local mpu_config=$(uci -q get qos_gargoyle.cake.mpu 2>/dev/null)
    CAKE_MPU="${mpu_config:-0}"
    
    local rtt_config=$(uci -q get qos_gargoyle.cake.rtt 2>/dev/null)
    CAKE_RTT="${rtt_config:-100ms}"
    
    local ack_filter_config=$(uci -q get qos_gargoyle.cake.ack_filter 2>/dev/null)
    CAKE_ACK_FILTER="${ack_filter_config:-0}"
    
    local nat_config=$(uci -q get qos_gargoyle.cake.nat 2>/dev/null)
    CAKE_NAT="${nat_config:-0}"
    
    local wash_config=$(uci -q get qos_gargoyle.cake.wash 2>/dev/null)
    CAKE_WASH="${wash_config:-0}"
    
    local split_gso_config=$(uci -q get qos_gargoyle.cake.split_gso 2>/dev/null)
    CAKE_SPLIT_GSO="${split_gso_config:-0}"
    
    local ingress_config=$(uci -q get qos_gargoyle.cake.ingress 2>/dev/null)
    CAKE_INGRESS="${ingress_config:-0}"
    
    local autorate_ingress_config=$(uci -q get qos_gargoyle.cake.autorate_ingress 2>/dev/null)
    CAKE_AUTORATE_INGRESS="${autorate_ingress_config:-0}"
    
    local memlimit_config=$(uci -q get qos_gargoyle.cake.memlimit 2>/dev/null)
    CAKE_MEMORY_LIMIT="${memlimit_config:-32Mb}"
    
    logger -t "qos_gargoyle" "CAKE配置: diffserv=$CAKE_DIFFSERV_MODE, overhead=$CAKE_OVERHEAD, mpu=$CAKE_MPU, rtt=$CAKE_RTT, ack_filter=$CAKE_ACK_FILTER, nat=$CAKE_NAT, wash=$CAKE_WASH, split_gso=$CAKE_SPLIT_GSO, ingress=$CAKE_INGRESS, autorate_ingress=$CAKE_AUTORATE_INGRESS, memlimit=$CAKE_MEMORY_LIMIT"
}

# 加载上传类别配置
load_upload_class_configurations() {
    logger -t "qos_gargoyle" "正在加载上传类别配置..."
    
    upload_class_list=""
    config_get upload_class_list global upload_classes
    if [ -z "$upload_class_list" ]; then
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
    
    download_class_list=""
    config_get download_class_list global download_classes
    if [ -z "$download_class_list" ]; then
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
    local class_name="$1"
    local direction="$2"
    local mark_file=""
    local class_pattern=""
    
    if [ "$direction" = "upload" ]; then
        mark_file="/etc/qos_gargoyle/upload_class_marks"
        if echo "$class_name" | grep -q "^upload_class_"; then
            class_pattern="u${class_name#upload_class_}"
        elif echo "$class_name" | grep -q "^uclass_"; then
            class_pattern="${class_name#uclass_}"
        else
            class_pattern="$class_name"
        fi
    elif [ "$direction" = "download" ]; then
        mark_file="/etc/qos_gargoyle/download_class_marks"
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
    
    if [ ! -f "$mark_file" ]; then
        logger -t "qos_gargoyle" "错误: 标记文件不存在: $mark_file"
        echo ""
        return 1
    fi
    
    local mark=""
    
    # 格式1: 完整格式
    if echo "$class_name" | grep -q "_class_"; then
        mark=$(grep "^${direction}:${class_name}:" "$mark_file" 2>/dev/null | awk -F: '{print $3}' | tr -d '[:space:]')
    fi
    
    # 格式2: 简短格式
    if [ -z "$mark" ]; then
        local short_name=""
        if [ "$direction" = "upload" ]; then
            short_name="uclass_${class_pattern}"
        else
            short_name="dclass_${class_pattern}"
        fi
        mark=$(grep "^${direction}:${short_name}:" "$mark_file" 2>/dev/null | awk -F: '{print $3}' | tr -d '[:space:]')
    fi
    
    # 格式3: 仅数字
    if [ -z "$mark" ] && echo "$class_pattern" | grep -qE '^[0-9]+$'; then
        if [ "$direction" = "upload" ]; then
            mark=$(grep "^upload:uclass_${class_pattern}:" "$mark_file" 2>/dev/null | awk -F: '{print $3}' | tr -d '[:space:]')
        else
            mark=$(grep "^download:dclass_${class_pattern}:" "$mark_file" 2>/dev/null | awk -F: '{print $3}' | tr -d '[:space:]')
        fi
    fi
    
    if [ -n "$mark" ]; then
        if echo "$mark" | grep -qE '^0x[0-9A-Fa-f]+$'; then
            echo "$mark"
            return 0
        else
            logger -t "qos_gargoyle" "警告: 读取的标记格式不正确: $mark"
        fi
    fi
    
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

# ========== 入口重定向相关函数 ==========

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

# ========== CAKE核心队列函数 ==========

# 创建CAKE根队列
create_cake_root_qdisc() {
    local device="$1"
    local direction="$2"
    local bandwidth="$3"
    
    logger -t "qos_gargoyle" "为$device创建$direction方向CAKE根队列 (带宽: ${bandwidth}kbit)"
    
    # 删除现有队列
    tc qdisc del dev "$device" root 2>/dev/null || true
    tc qdisc del dev "$device" ingress 2>/dev/null || true
    
    # 构建CAKE参数字符串
    echo "正在为 $device 创建 CAKE 根队列..."
    
    # CAKE的基本格式: tc qdisc add dev DEV root cake bandwidth ... diffserv4 ...
    local cake_params="bandwidth ${bandwidth}kbit"
    
    # 添加可选参数
    [ -n "$CAKE_DIFFSERV_MODE" ] && cake_params="$cake_params $CAKE_DIFFSERV_MODE"
    [ "$CAKE_OVERHEAD" != "0" ] && cake_params="$cake_params overhead $CAKE_OVERHEAD"
    [ "$CAKE_MPU" != "0" ] && cake_params="$cake_params mpu $CAKE_MPU"
    [ -n "$CAKE_RTT" ] && cake_params="$cake_params rtt $CAKE_RTT"
    [ "$CAKE_ACK_FILTER" = "1" ] && cake_params="$cake_params ack-filter"
    [ "$CAKE_NAT" = "1" ] && cake_params="$cake_params nat"
    [ "$CAKE_WASH" = "1" ] && cake_params="$cake_params wash"
    [ "$CAKE_SPLIT_GSO" = "1" ] && cake_params="$cake_params split-gso"
    [ "$CAKE_INGRESS" = "1" ] && cake_params="$cake_params ingress"
    [ "$CAKE_AUTORATE_INGRESS" = "1" ] && cake_params="$cake_params autorate-ingress"
    [ -n "$CAKE_MEMORY_LIMIT" ] && cake_params="$cake_params memlimit $CAKE_MEMORY_LIMIT"
    
    logger -t "qos_gargoyle" "CAKE参数: $cake_params"
    
    if ! tc qdisc add dev "$device" root cake $cake_params; then
        logger -t "qos_gargoyle" "错误: 无法在$device上创建CAKE根队列"
        echo "错误: 无法在 $device 上创建 CAKE 根队列"
        return 1
    fi
    
    logger -t "qos_gargoyle" "$device的$direction方向CAKE根队列创建完成"
    echo "$device 的 $direction 方向 CAKE 根队列创建完成"
    return 0
}

# 创建默认上传CAKE
create_default_upload_cake() {
    logger -t "qos_gargoyle" "创建默认上传CAKE"
    
    # 首先创建根队列
    if ! create_cake_root_qdisc "$qos_interface" "upload" "$total_upload_bandwidth"; then
        logger -t "qos_gargoyle" "错误：创建上传根队列失败"
        return 1
    fi
    
    upload_class_mark_list="default_class:0x1"
    logger -t "qos_gargoyle" "默认上传CAKE创建完成"
    return 0
}

# 创建CAKE上传类别
create_cake_upload_class() {
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
    
    # 清理标记值
    class_mark=$(clean_mark_value "$class_mark")
    
    # 添加过滤器
    if [ "$class_mark" != "0x0" ]; then
        # IPv4过滤器
        if ! tc filter add dev "$qos_interface" parent 1:0 protocol ip \
            prio $class_index handle $class_mark fw 2>/dev/null; then
            logger -t "qos_gargoyle" "警告: 添加上传IPv4过滤器失败 (标记:$class_mark)"
        else
            logger -t "qos_gargoyle" "添加上传IPv4过滤器: 标记:$class_mark"
        fi
        
        # IPv6过滤器
        local ipv6_priority=$((class_index + 100))
        if ! tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
            prio $ipv6_priority handle $class_mark fw 2>/dev/null; then
            logger -t "qos_gargoyle" "警告: 添加上传IPv6过滤器失败 (标记:$class_mark)"
        else
            logger -t "qos_gargoyle" "添加上传IPv6过滤器: 标记:$class_mark"
        fi
    fi
    
    logger -t "qos_gargoyle" "上传类别创建成功: $class_name (标记: $class_mark)"
    return 0
}

# 创建默认下载CAKE
create_default_download_cake() {
    logger -t "qos_gargoyle" "创建默认下载CAKE"
    
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
    if ! create_cake_root_qdisc "$IFB_DEVICE" "download" "$total_download_bandwidth"; then
        logger -t "qos_gargoyle" "错误：创建下载根队列失败"
        return 1
    fi
    
    # 设置入口重定向
    if ! setup_ingress_redirect; then
        logger -t "qos_gargoyle" "警告: 设置入口重定向失败"
    fi
    
    download_class_mark_list="default_class:0x100"
    logger -t "qos_gargoyle" "默认下载CAKE创建完成"
    return 0
}

# 创建CAKE下载类别
create_cake_download_class() {
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
        local class_num=$(echo "$class_name" | sed -E 's/^download_class_//')
        if [ -n "$class_num" ] && echo "$class_num" | grep -qE '^[0-9]+$'; then
            class_mark=$(printf "0x%X" $((0x100 << (class_num - 1))))
        else
            # 基于class_index计算
            class_mark=$(printf "0x%X" $((0x100 << (class_index - 2))))
        fi
        logger -t "qos_gargoyle" "警告: 从文件读取标记失败，使用计算值: $class_mark"
    else
        logger -t "qos_gargoyle" "从文件获取下载标记: $class_mark"
    fi
    
    # 清理标记值
    class_mark=$(clean_mark_value "$class_mark")
    
    # 添加过滤器
    if [ "$class_mark" != "0x0" ]; then
        # 下载过滤器使用优先级参数
        if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ip \
            prio $priority handle $class_mark fw 2>/dev/null; then
            logger -t "qos_gargoyle" "警告: 添加下载IPv4过滤器失败 (标记:$class_mark)"
        else
            logger -t "qos_gargoyle" "添加下载IPv4过滤器: 标记:$class_mark"
        fi
        
        # IPv6过滤器
        local ipv6_priority=$((priority + 100))
        if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
            prio $ipv6_priority handle $class_mark fw 2>/dev/null; then
            logger -t "qos_gargoyle" "警告: 添加下载IPv6过滤器失败 (标记:$class_mark)"
        else
            logger -t "qos_gargoyle" "添加下载IPv6过滤器: 标记:$class_mark"
        fi
    fi
    
    logger -t "qos_gargoyle" "下载类别创建成功: $class_name (标记: $class_mark)"
    return 0
}

# ========== 上传方向初始化 ==========

initialize_cake_upload() {
    logger -t "qos_gargoyle" "初始化上传方向CAKE"
    
    # 加载上传类别配置
    load_upload_class_configurations
    
    if [ -z "$upload_class_list" ]; then
        logger -t "qos_gargoyle" "警告：未找到上传类别配置，使用默认配置"
        create_default_upload_cake
        return 0
    fi
    
    logger -t "qos_gargoyle" "找到上传类别：$upload_class_list"
    
    # 创建根队列
    if ! create_cake_root_qdisc "$qos_interface" "upload" "$total_upload_bandwidth"; then
        logger -t "qos_gargoyle" "错误：创建上传根队列失败"
        return 1
    fi
    
    # 创建各个类别
    local class_index=2
    upload_class_mark_list=""
    
    for class_name in $upload_class_list; do
        create_cake_upload_class "$class_name" "$class_index"
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
            
            # 清理标记值
            class_mark_hex=$(clean_mark_value "$class_mark_hex")
            
            # 添加标记到列表
            upload_class_mark_list="$upload_class_mark_list$class_name:$class_mark_hex "
            
            # 添加过滤器
            if [ -n "$class_mark_hex" ] && [ "$class_mark_hex" != "0x0" ]; then
                tc filter add dev "$qos_interface" parent 1:0 protocol ip \
                    prio 1 handle ${class_mark_hex}/$UPLOAD_MASK fw
                    
                tc filter add dev "$qos_interface" parent 1:0 protocol ipv6 \
                    prio 2 handle ${class_mark_hex}/$UPLOAD_MASK fw
            fi
        fi
        class_index=$((class_index + 1))
    done
    
    # 创建上传链
    create_upload_chain
    
    logger -t "qos_gargoyle" "上传方向CAKE初始化完成"
    return 0
}

# ========== 下载方向初始化 ==========

initialize_cake_download() {
    logger -t "qos_gargoyle" "初始化下载方向CAKE"
    
    # 加载下载类别配置
    load_download_class_configurations
    
    if [ -z "$download_class_list" ]; then
        logger -t "qos_gargoyle" "警告：未找到下载类别配置，使用默认配置"
        create_default_download_cake
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
    if ! create_cake_root_qdisc "$IFB_DEVICE" "download" "$total_download_bandwidth"; then
        logger -t "qos_gargoyle" "错误：创建下载根队列失败"
        return 1
    fi
    
    # 创建各个类别
    local class_index=2
    local priority=3
    download_class_mark_list=""
    
    for class_name in $download_class_list; do
        create_cake_download_class "$class_name" "$class_index" "$priority"
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
            
            # 清理标记值
            class_mark_hex=$(clean_mark_value "$class_mark_hex")
            
            # 添加标记到列表
            download_class_mark_list="$download_class_mark_list$class_name:$class_mark_hex "
            
            # 添加过滤器
            if [ -n "$class_mark_hex" ] && [ "$class_mark_hex" != "0x0" ]; then
                if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ip \
                    prio $priority handle ${class_mark_hex}/$DOWNLOAD_MASK fw; then
                    logger -t "qos_gargoyle" "警告: 添加下载IPv4过滤器失败 (类别: $class_name)"
                else
                    logger -t "qos_gargoyle" "下载IPv4过滤器添加成功: 标记=$class_mark_hex"
                fi
                
                if ! tc filter add dev "$IFB_DEVICE" parent 1:0 protocol ipv6 \
                    prio $((priority + 1)) handle ${class_mark_hex}/$DOWNLOAD_MASK fw; then
                    logger -t "qos_gargoyle" "警告: 添加下载IPv6过滤器失败 (类别: $class_name)"
                else
                    logger -t "qos_gargoyle" "下载IPv6过滤器添加成功: 标记=$class_mark_hex"
                fi
            fi
        fi
        class_index=$((class_index + 1))
        priority=$((priority + 2))
    done
    
    # 创建下载链和入口重定向
    create_download_chain
    setup_ingress_redirect
    
    logger -t "qos_gargoyle" "下载方向CAKE初始化完成"
    return 0
}

# ========== 链创建函数 ==========

create_upload_chain() {
    logger -t "qos_gargoyle" "创建上传链"
    
    # 清空现有的出口链
    nft flush chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null
    
    logger -t "qos_gargoyle" "上传链创建完成"
    return 0
}

create_download_chain() {
    logger -t "qos_gargoyle" "创建下载链"
    
    # 清空现有的入口链
    nft flush chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null
    
    logger -t "qos_gargoyle" "下载链创建完成"
    return 0
}

# ========== 主初始化函数 ==========

# 主入口：初始化CAKE QoS
initialize_cake_qos() {
    logger -t "qos_gargoyle" "开始初始化CAKE QoS系统"
    
    # 1. 加载CAKE专属配置
    load_cake_config
    
    # 2. 设置IPv6特定规则
    setup_ipv6_specific_rules
    
    # 3. 初始化上传方向
    if [ "$total_upload_bandwidth" -ge 0 ] && [ "$total_upload_bandwidth" -gt 0 ]; then
        initialize_cake_upload
    else
        logger -t "qos_gargoyle" "上传带宽未配置，跳过上传方向初始化"
    fi
    
    # 4. 初始化下载方向
    if [ "$total_download_bandwidth" -ge 0 ] && [ "$total_download_bandwidth" -gt 0 ]; then
        initialize_cake_download
    else
        logger -t "qos_gargoyle" "下载带宽未配置，跳过下载方向初始化"
    fi
    
    logger -t "qos_gargoyle" "CAKE QoS初始化完成"
}

# ========== 停止和清理函数 ==========

stop_cake_qos() {
    logger -t "qos_gargoyle" "停止CAKE QoS"
    
    # 清理上传方向
    if tc qdisc show dev "$qos_interface" | grep -q "cake"; then
        tc qdisc del dev "$qos_interface" root 2>/dev/null
        logger -t "qos_gargoyle" "清理上传方向CAKE队列"
    fi
    
    # 清理下载方向
    if tc qdisc show dev "$IFB_DEVICE" | grep -q "cake"; then
        tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null
        logger -t "qos_gargoyle" "清理下载方向CAKE队列"
    fi
    
    # 清理nftables规则
    nft delete chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null
    nft delete chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null
    
    # 清理入口队列
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null
    
    # 停用IFB设备
    if ip link show dev "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link set dev "$IFB_DEVICE" down
        logger -t "qos_gargoyle" "停用IFB设备: $IFB_DEVICE"
    fi
    
    logger -t "qos_gargoyle" "CAKE QoS停止完成"
}

# ========== 狀態查詢函數 ==========

show_cake_status() {
    # 确保必要的变量已设置
    local qos_ifb="${IFB_DEVICE:-ifb0}"
    
    # 如果接口未定义，尝试获取
    if [ -z "$qos_interface" ]; then
        qos_interface=$(tc qdisc show 2>/dev/null | grep -E "cake.*root" | awk '{print $5}' | head -1)
        [ -z "$qos_interface" ] && qos_interface="未知"
    fi
    
    echo "===== CAKE QoS状态报告 ====="
    echo "时间: $(date)"
    echo "系统运行时间: $(uptime | sed 's/.*up //; s/,.*//')"
    echo "WAN接口: ${qos_interface:-未知}"
    
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
    if ! tc qdisc show dev "${qos_interface}" 2>/dev/null | grep -q "qdisc cake"; then
        echo "警告: QoS未在接口 ${qos_interface} 上激活"
        return 1
    fi
    
    # 显示出口配置
    echo -e "\n======== 出口CAKE ($qos_interface) ========"
    
    echo -e "\nTC队列统计:"
    tc -s qdisc show dev "$qos_interface" 2>/dev/null || echo "  无TC队列"
    
    echo "TC过滤器:"
    tc -s filter show dev "$qos_interface" 2>/dev/null || echo "  无过滤器"
    
    # 显示入口配置
    echo -e "\n======== 入口CAKE ($qos_ifb) ========"
    
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\nTC队列统计:"
        tc -s qdisc show dev "$qos_ifb" 2>/dev/null || echo "  无TC队列"
        
        echo "TC过滤器:"
        tc -s filter show dev "$qos_ifb" 2>/dev/null || echo "  无过滤器"
        
        # 检查入口重定向
        echo -e "\n入口重定向检查:"
        if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "ingress"; then
            echo "  ✓ 入口队列已配置"
            
            # 显示入口过滤器
            echo "  入口过滤器配置:"
            tc filter show dev "$qos_interface" parent ffff: 2>/dev/null || echo "    无入口过滤器"
        else
            echo "  ✗ 入口队列未配置"
        fi
    else
        echo "  IFB设备不存在，无入口配置"
    fi
    
    # 系统资源
    echo -e "\n===== 系统资源 ====="
    
    # 内存
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
    echo -e "\n===== CAKE状态摘要 ====="
    
    # 出口状态
    if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "qdisc cake"; then
        local qdisc_info=$(tc qdisc show dev "$qos_interface" 2>/dev/null | grep "cake" | head -1)
        echo "出口队列: 已配置 (cake)"
        
        # 显示CAKE详细信息
        echo "  " $(echo "$qdisc_info" | sed 's/qdisc cake //')
    else
        echo "出口队列: 未配置"
    fi
    
    # 入口状态
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        if tc qdisc show dev "$qos_ifb" 2>/dev/null | grep -q "qdisc cake"; then
            local ifb_qdisc=$(tc qdisc show dev "$qos_ifb" 2>/dev/null | grep "cake" | head -1)
            echo "入口队列: 已配置 (cake)"
            
            # 显示CAKE详细信息
            echo "  " $(echo "$ifb_qdisc" | sed 's/qdisc cake //')
        else
            echo "入口队列: IFB设备存在但无CAKE队列"
        fi
        
        # 检查入口重定向
        if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "ingress"; then
            echo "入口重定向: 已配置"
        else
            echo "入口重定向: 未配置"
        fi
    else
        echo "入口队列: IFB设备未创建"
        echo "入口重定向: 未配置"
    fi
    
    # 总体状态
    if tc qdisc show dev "$qos_interface" 2>/dev/null | grep -q "qdisc cake"; then
        echo "CAKE状态: 运行中"
    else
        echo "CAKE状态: 已停止"
    fi
    
    # 网络接口统计
    echo -e "\n===== 网络接口统计 ====="
    echo "WAN接口 ($qos_interface) 统计:"
    ifconfig "$qos_interface" 2>/dev/null | grep -E "(RX|TX) packets|bytes" | sed 's/^/  /'
    
    if ip link show "$qos_ifb" >/dev/null 2>&1; then
        echo -e "\nIFB接口 ($qos_ifb) 统计:"
        ifconfig "$qos_ifb" 2>/dev/null | grep -E "(RX|TX) packets|bytes" | sed 's/^/  /'
    fi
    
    # NFTables规则
    echo -e "\n===== NFTables规则 ====="
    echo "QoS相关NFT规则:"
    nft list table inet gargoyle-qos-priority 2>/dev/null || echo "  无NFT规则"
    
    # 当前连接统计
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
    
    echo -e "\n===== 状态报告结束 ====="
    
    return 0
}


# ========== 主函数 ==========

main_cake_qos() {
    local action="$1"
    
    case "$action" in
        start)
            logger -t "qos_gargoyle" "启动CAKE QoS"
            initialize_cake_qos
            ;;
        stop)
            logger -t "qos_gargoyle" "停止CAKE QoS"
            stop_cake_qos
            ;;
        restart)
            logger -t "qos_gargoyle" "重启CAKE QoS"
            stop_cake_qos
            sleep 2
            initialize_cake_qos
            ;;
        status|show)
            # 简单的状态显示
            echo "CAKE QoS状态:"
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
            ;;
        *)
            echo "用法: $0 {start|stop|restart|status}"
            exit 1
            ;;
    esac
}

# 如果脚本被直接调用
if [ "$(basename "$0")" = "cake-helper.sh" ]; then
    main_cake_qos "$1"
fi

logger -t "qos_gargoyle" "CAKE助手模块加载完成"