#!/bin/sh
# 规则辅助模块 (rule-helper.sh) - 增强完整版
# 支持多样化端口、协议、IPv6双栈和连接字节数过滤

CONFIG_FILE="qos_gargoyle"

# 日志函数
log() {
    logger -t "qos_gargoyle" "规则辅助: $1"
    echo "[$(date '+%H:%M:%S')] 规则辅助: $1"
}

# 加载所有配置段
load_all_config_sections() {
    local config_name="$1"
    local section_type="$2"
    
    # 使用uci命令获取所有配置段
    local config_output=$(uci show "$config_name" 2>/dev/null)
    
    if [ -z "$config_output" ]; then
        echo ""
        return
    fi
    
    if [ -n "$section_type" ]; then
        # 修复：同时支持两种配置格式
        
        # 格式1：匿名配置节（例如：@upload_class[0]=upload_class）
        local anonymous_sections=$(echo "$config_output" | \
            grep -E "^${config_name}\\.@${section_type}\\[[0-9]+\\]=" | \
            cut -d= -f1 | sed "s/${config_name}\.@${section_type}\[//g; s/\]//g")
        
        # 格式2：命名配置节（例如：uclass_1=upload_class）
        local named_sections=$(echo "$config_output" | \
            grep -E "^${config_name}\\.[a-zA-Z0-9_]+=${section_type}(['\"])?$" | \
            cut -d. -f2 | cut -d= -f1)
        
        # 格式3：旧格式（例如：upload_class_1=upload_class）
        local old_format_sections=$(echo "$config_output" | \
            grep -E "^${config_name}\\.${section_type}_[0-9]+=" | \
            cut -d= -f1 | cut -d. -f2)
        
        # 合并所有结果
        local all_sections=$(echo "$anonymous_sections" "$named_sections" "$old_format_sections" | \
            tr ' ' '\n' | grep -v "^$" | sort -u | tr '\n' ' ')
        
        # 输出结果，移除多余空格
        echo "$all_sections" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    else
        # 查找所有配置段
        echo "$config_output" | grep -E "^${config_name}\\.[a-zA-Z_]+[0-9]*=" | \
            cut -d= -f1 | cut -d. -f2
    fi
}

# 加载并排序所有配置段
load_and_sort_all_config_sections() {
    local config_name="$1"
    local section_type="$2"
    local sort_variable="$3"
    
    # 获取所有配置段
    local sections=$(load_all_config_sections "$config_name" "$section_type")
    
    if [ -z "$sections" ]; then
        echo ""
        return
    fi
    
    # 如果有排序变量，按排序值排序
    if [ -n "$sort_variable" ]; then
        # 创建临时数组来存储排序值
        local sorted_list=""
        
        for section in $sections; do
            local order=$(uci -q get "${config_name}.${section}.${sort_variable}")
            order=${order:-9999}  # 默认值
            sorted_list="${sorted_list}${order}:${section}\n"
        done
        
        # 排序并输出
        echo -e "$sorted_list" | sort -n -t ':' | cut -d: -f2- | grep -v "^$"
    else
        echo "$sections"
    fi
}

# 加载所有配置选项 - 增强版
load_all_config_options() {
    local config_name="$1"
    local section_id="$2"
    
    # 清空全局变量
    unset ALL_OPTION_VARIABLES
    
    # 使用 uci 命令获取该 section 的所有选项
    local config_output=$(uci show "${config_name}.${section_id}" 2>/dev/null)
    
    if [ -z "$config_output" ]; then
        return
    fi
    
    # 提取选项名
    ALL_OPTION_VARIABLES=$(echo "$config_output" | \
        grep -E "^${config_name}\\.${section_id}\\." | \
        cut -d. -f3 | \
        cut -d= -f1)
    
    # 为每个选项设置变量
    for var in $ALL_OPTION_VARIABLES; do
        local value=$(uci -q get "${config_name}.${section_id}.${var}")
        eval "${var}=\"\${value}\""
    done
}

# 从标记列表中获取类别对应的标记
get_classname_mark() {
    local class="$1"
    local class_mark_list="$2"
    local direction="$3"  # 可选参数: upload 或 download
    
    # 调试日志
    logger -t qos_gargoyle "寻找类别标记: class=$class, list=$class_mark_list, direction=$direction"
    
    # 1. 首先尝试从传入的标记列表查找
    if [ -n "$class_mark_list" ]; then
        local IFS=' '
        for item in $class_mark_list; do
            local item_class="${item%:*}"
            local item_mark="${item#*:}"
            if [ "$item_class" = "$class" ]; then
                echo "$item_mark"
                logger -t qos_gargoyle "从列表找到类别标记: $class -> $item_mark"
                return
            fi
        done
    fi
    
    # 2. 如果没找到，尝试从标记文件中查找
    if [ -f "/etc/qos_gargoyle/qos_class_marks" ]; then
        while IFS=: read -r mark_direction mark_class mark_value; do
            if [ -n "$direction" ]; then
                # 如果指定了方向，需要方向匹配
                if [ "$mark_direction" = "$direction" ] && [ "$mark_class" = "$class" ]; then
                    echo "$mark_value"
                    logger -t qos_gargoyle "从文件找到类别标记: $direction:$class -> $mark_value"
                    return
                fi
            else
                # 如果没指定方向，只匹配类别名称
                if [ "$mark_class" = "$class" ]; then
                        echo "$mark_value"
                    logger -t qos_gargoyle "从文件找到类别标记(无方向): $class -> $mark_value"
                    return
                fi
            fi
        done < /etc/qos_gargoyle/qos_class_marks
    fi
}

# 计算类别标记 - 使用掩码和链类型
calculate_class_mark() {
    local class="$1"
    local mask="$2"
    local chain_type="$3"  # "upload" 或 "download"
    
    # 从类别名称提取索引
    local index
    
    # 支持多种类别名称格式
    if echo "$class" | grep -qE "^(uclass_|upload_class_)"; then
        # 格式1: uclass_1, 格式2: upload_class_1
        index=$(echo "$class" | sed -E 's/^(uclass_|upload_class_)//')
    elif echo "$class" | grep -qE "^(dclass_|download_class_)"; then
        # 格式1: dclass_1, 格式2: download_class_1
        index=$(echo "$class" | sed -E 's/^(dclass_|download_class_)//')
    else
        log "警告: 无法解析类别名称格式: $class"
        echo ""
        return
    fi
    
    # 检查索引是否为数字
    if ! echo "$index" | grep -qE '^[0-9]+$'; then
        log "警告: 类别索引不是数字: $class (索引: $index)"
        echo ""
        return
    fi
    
    # 根据链类型计算基础值
    local base_value=0
    
    if [ "$chain_type" = "upload" ]; then
        base_value=$((0x1))
    elif [ "$chain_type" = "download" ]; then
        base_value=$((0x100))
    else
        log "错误: 未知链类型: $chain_type"
        echo ""
        return
    fi
    
    # 计算标记值: base_value << (index-1)
    local shift_amount=$((index - 1))
    local mark_value=$((base_value << shift_amount))
    
    # 输出16进制格式
    local mark_hex=$(printf "0x%X" "$mark_value")
    echo "$mark_hex"
}

# ========== 增强规则应用函数 ==========

# 应用增强的方向规则
apply_enhanced_direction_rules() {
    local rule_type="$1"
    local chain="$2"
    local mask="$3"
    
    log "应用增强$rule_type规则到链: $chain, 掩码: $mask"
    
    # 加载并排序规则
    local rule_list=$(load_and_sort_all_config_sections "$CONFIG_FILE" "$rule_type" "test_order")
    
    if [ -z "$rule_list" ]; then
        log "未找到$rule_type规则配置"
        return
    fi
    
    log "找到$rule_type规则: $rule_list"
    
    for rule_name in $rule_list; do
        apply_single_enhanced_rule "$rule_name" "$chain" "$mask"
    done
}

# 应用单条增强规则
apply_single_enhanced_rule() {
    local rule_name="$1"
    local chain="$2"
    local mask="$3"
    
    log "处理增强规则: $rule_name"
    
    # 加载规则配置
    local class=""
    local family=""
    local proto=""
    local srcport=""
    local dstport=""
    local connbytes_kb=""
    
    load_all_config_options "$CONFIG_FILE" "$rule_name"
    
    if [ -z "$class" ]; then
        log "规则 $rule_name 缺少class参数，跳过"
        return
    fi
    
    # 获取类别标记
    local class_mark=""
    if [ "$chain" = "filter_qos_egress" ]; then
        class_mark=$(get_classname_mark "$class" "$upload_class_mark_list")
    else
        class_mark=$(get_classname_mark "$class" "$download_class_mark_list")
    fi
    
    if [ -z "$class_mark" ]; then
        log "规则 $rule_name 的类别 $class 未找到，跳过"
        return
    fi
    
    # 设置地址族（支持IPv6双栈）
    if [ -z "$family" ]; then
        # 如果未指定，使用inet（双栈）
        family="inet"
    fi
    
    # 修复：当协议为"all"时，需要分别创建TCP和UDP规则
    if [ "$proto" = "all" ] || [ -z "$proto" ]; then
        # 检查是否有端口条件
        local has_port_condition="false"
        if [[ "$chain" == *"ingress"* ]] && [ -n "$srcport" ] && [ "$srcport" != "0" ] && [ "$srcport" != "0x0" ]; then
            has_port_condition="true"
        elif [[ "$chain" == *"egress"* ]] && [ -n "$dstport" ] && [ "$dstport" != "0" ] && [ "$dstport" != "0x0" ]; then
            has_port_condition="true"
        fi
        
        if [ "$has_port_condition" = "true" ]; then
            # 如果有端口条件，分别创建TCP和UDP规则
            log "为规则 $rule_name 创建TCP和UDP规则（协议: all）"
            
            # 创建TCP规则
            build_enhanced_nft_rule "$rule_name" "$chain" "$class_mark" "$mask" "$family" "tcp" "$srcport" "$dstport" "$connbytes_kb"
            
            # 创建UDP规则
            build_enhanced_nft_rule "$rule_name" "$chain" "$class_mark" "$mask" "$family" "udp" "$srcport" "$dstport" "$connbytes_kb"
        else
            # 没有端口条件，直接创建协议为空的规则
            build_enhanced_nft_rule "$rule_name" "$chain" "$class_mark" "$mask" "$family" "$proto" "$srcport" "$dstport" "$connbytes_kb"
        fi
    else
        # 指定了特定协议，直接调用
        build_enhanced_nft_rule "$rule_name" "$chain" "$class_mark" "$mask" "$family" "$proto" "$srcport" "$dstport" "$connbytes_kb"
    fi
}

# 构建增强 NFT 规则
build_enhanced_nft_rule() {
    local rule_name="$1"      # 参数1: 规则名称
    local chain="$2"          # 参数2: 链名称
    local class_mark="$3"     # 参数3: 类别标记
    local mask="$4"           # 参数4: 标记掩码
    local family="$5"         # 参数5: 地址族
    local proto="$6"          # 参数6: 协议
    local srcport="$7"        # 参数7: 源端口
    local dstport="$8"        # 参数8: 目的端口
    local connbytes_kb="$9"   # 参数9: 连接字节数
    
    echo "构建增强 NFT 规则: 名称='$rule_name' 链='$chain' 标记='$class_mark' 地址族='$family'"
    echo "掩码='$mask' 协议='$proto' 源端口='$srcport' 目的端口='$dstport' 连接字节='$connbytes_kb'"
    
    # 验证必要参数
    if [ -z "$rule_name" ] || [ -z "$family" ] || [ -z "$chain" ] || [ -z "$class_mark" ]; then
        echo "错误: 缺少必要参数"
        echo "  需要的参数: rule_name, family, chain, class_mark"
        echo "  收到的参数: $@"
        return 1
    fi
    
    # 构建规则条件字符串
    local condition=""
    
    # 1. 协议条件
    if [ -n "$proto" ] && [ "$proto" != "all" ] && [ "$proto" != "none" ]; then
        condition="$condition $proto"
    fi
    
    # 2. 端口条件 - 根据链类型决定使用源端口还是目的端口
    if [[ "$chain" == *"ingress"* ]]; then
        # ingress链使用源端口
        if [ -n "$srcport" ] && [ "$srcport" != "0" ] && [ "$srcport" != "0x0" ]; then
            local clean_srcport=$(echo "$srcport" | tr -d ' ')
            # 检查端口列表是否包含范围
            if echo "$clean_srcport" | grep -q ','; then
                condition="$condition sport { $clean_srcport }"
            else
                condition="$condition sport $clean_srcport"
            fi
        fi
    else
        # egress链使用目的端口
        if [ -n "$dstport" ] && [ "$dstport" != "0" ] && [ "$dstport" != "0x0" ]; then
            local clean_dstport=$(echo "$dstport" | tr -d ' ')
            # 检查端口列表是否包含范围
            if echo "$clean_dstport" | grep -q ','; then
                condition="$condition dport { $clean_dstport }"
            else
                condition="$condition dport $clean_dstport"
            fi
        fi
    fi
    
    # 3. 连接字节数条件
    if [ -n "$connbytes_kb" ] && [ "$connbytes_kb" != "0" ] && [ "$connbytes_kb" != "" ]; then
        # 先移除可能存在的空格
        local connbytes_kb_clean=$(echo "$connbytes_kb" | tr -d ' ')
        
        # 检查是否是比较表达式
        if echo "$connbytes_kb_clean" | grep -qE '^[<>=!]+[0-9]+$'; then
            # 提取操作符
            local operator=$(echo "$connbytes_kb_clean" | sed -E 's/^([<>=!]+).*$/\1/')
            # 提取数值
            local value=$(echo "$connbytes_kb_clean" | sed -E 's/^[<>=!]+([0-9]+)$/\1/')
            
            if [ -n "$operator" ] && [ -n "$value" ]; then
                # 将KB转换为字节
                local bytes_value=$((value * 1024))
                # NFT使用 ct bytes 而不是 conn bytes
                condition="$condition ct bytes $operator $bytes_value"
            else
                echo "警告: 无法解析连接字节数条件: '$connbytes_kb'，将忽略此条件"
            fi
        elif echo "$connbytes_kb_clean" | grep -qE '^[0-9]+$'; then
            # 如果是纯数字，则转换为字节
            local bytes_value=$((connbytes_kb_clean * 1024))
            condition="$condition ct bytes $bytes_value"
        elif echo "$connbytes_kb_clean" | grep -qE '^[0-9]+-[0-9]+$'; then
            # 处理范围格式，如 10-768
            # 提取最小值和最大值
            local min_value=$(echo "$connbytes_kb_clean" | cut -d'-' -f1)
            local max_value=$(echo "$connbytes_kb_clean" | cut -d'-' -f2)
            
            if [ -n "$min_value" ] && [ -n "$max_value" ]; then
                # 将KB转换为字节
                local min_bytes=$((min_value * 1024))
                local max_bytes=$((max_value * 1024))
                condition="$condition ct bytes >= $min_bytes ct bytes <= $max_bytes"
            else
                echo "警告: 无法解析连接字节数范围条件: '$connbytes_kb'，将忽略此条件"
            fi
        else
            echo "警告: 无效的连接字节数格式: '$connbytes_kb'，将忽略此条件"
        fi
    fi
    
    # 构建完整的 nft 命令
    local nft_cmd=""
    
    # 如果没有条件，则匹配所有流量
    if [ -z "$condition" ] || [ "$condition" = " " ]; then
        nft_cmd="add rule $family gargoyle-qos-priority $chain meta mark set $class_mark counter"
    else
        # 如果有条件，则添加条件
        nft_cmd="add rule $family gargoyle-qos-priority $chain$condition meta mark set $class_mark counter"
    fi
    
    echo "NFT 命令: $nft_cmd"
    
    # 检查命令语法
    if ! nft -c "$nft_cmd" 2>/dev/null; then
        echo "错误: NFT 命令语法检查失败"
        echo "失败的命令: $nft_cmd"
        return 1
    fi
    
    # 执行命令
    nft $nft_cmd
    local ret=$?
    if [ $ret -ne 0 ]; then
        echo "错误: NFT 命令执行失败 (返回码: $ret)"
        return 1
    else
        echo "✅ 规则创建成功: $rule_name"
        return 0
    fi
}

# ========== 双栈过滤器函数 ==========

# 创建双栈过滤器
create_dualstack_filter() {
    local dev="$1"
    local parent="$2"
    local class_id="$3"
    local mark="$4"
    local mask="$5"
    
    # IPv4过滤器
    tc filter add dev "$dev" parent "$parent" protocol ip \
        handle ${mark}/$mask fw flowid "$class_id"
    
    # IPv6过滤器
    tc filter add dev "$dev" parent "$parent" protocol ipv6 \
        handle ${mark}/$mask fw flowid "$class_id"
    
    # 处理IPv4-mapped IPv6地址（::ffff:0:0/96）
    tc filter add dev "$dev" parent "$parent" protocol ipv6 \
        u32 match ip6 dst ::ffff:0:0/96 \
        action connmark zone 0 set $mark \
        flowid "$class_id"
}

# 创建带优先级的双栈过滤器
create_priority_dualstack_filter() {
    local dev="$1"
    local parent="$2"
    local class_id="$3"
    local mark="$4"
    local mask="$5"
    local priority="$6"
    
    # IPv4过滤器（带优先级）
    tc filter add dev "$dev" parent "$parent" protocol ip \
        prio $priority handle ${mark}/$mask fw flowid "$class_id"
    
    # IPv6过滤器（优先级+1）
    tc filter add dev "$dev" parent "$parent" protocol ipv6 \
        prio $((priority + 1)) handle ${mark}/$mask fw flowid "$class_id"
}

# ========== 兼容性函数 ==========

# 应用所有规则（兼容旧版本）
apply_all_rules() {
    local rule_type="$1"    # "upload_rule" 或 "download_rule"
    local mask="$2"         # 标记掩码 (0x007F 或 0x7F00)
    local chain="$3"        # NFT 链名称
    
    log "开始应用 $rule_type 规则到链 $chain (掩码: $mask)"
    
    # 使用增强规则函数
    apply_enhanced_direction_rules "$rule_type" "$chain" "$mask"
}

# 处理单个规则（兼容旧版本）
process_single_rule() {
    local rule_id="$1"
    local chain="$2"
    local mask="$3"
    local chain_type="$4"  # "upload" 或 "download"
    
    # 获取规则参数
    local class=$(uci -q get "$CONFIG_FILE.$rule_id.class")
    local proto=$(uci -q get "$CONFIG_FILE.$rule_id.proto")
    local srcport=$(uci -q get "$CONFIG_FILE.$rule_id.srcport")
    local dstport=$(uci -q get "$CONFIG_FILE.$rule_id.dstport")
    local test_order=$(uci -q get "$CONFIG_FILE.$rule_id.test_order")
    
    # 调试信息
    log "规则 $rule_id: class=$class, proto=$proto, test_order=$test_order"
    log "  srcport='$srcport', dstport='$dstport'"
    
    # 检查必要参数
    if [ -z "$class" ]; then
        log "错误: 规则 $rule_id 缺少 class 参数"
        return 1
    fi
    
    # 计算标记值
    local mark
    mark=$(calculate_class_mark "$class" "$mask" "$chain_type")
    
    if [ -z "$mark" ]; then
        log "错误: 无法计算类别 $class 的标记值"
        return 1
    fi
    
    log "类别 $class 的标记: $mark"
    
    # 对于协议为 "all" 的情况，需要特殊处理
    if [ "$proto" = "all" ] || [ -z "$proto" ]; then
        apply_all_protocol_rule "$chain" "$mark" "$srcport" "$dstport"
        return $?
    fi
    
    # 构建 nft 规则命令
    local nft_cmd="add rule inet gargoyle-qos-priority $chain"
    
    # 添加协议条件
    if [ "$proto" = "tcp" ] || [ "$proto" = "udp" ]; then
        nft_cmd="$nft_cmd ip protocol $proto $proto"
    elif [ -n "$proto" ]; then
        nft_cmd="$nft_cmd meta l4proto $proto"
    else
        # 如果协议为空，则匹配所有流量
        nft_cmd="$nft_cmd meta mark set $mark counter"
    fi
    
    # 添加端口条件
    if [ -n "$srcport" ] && [ "$chain" = "filter_qos_ingress" ]; then
        # 清理端口字符串
        local ports=$(echo "$srcport" | tr -d ' ')
        nft_cmd="$nft_cmd sport { $ports }"
    fi
    
    if [ -n "$dstport" ] && [ "$chain" = "filter_qos_egress" ]; then
        # 清理端口字符串
        local ports=$(echo "$dstport" | tr -d ' ')
        nft_cmd="$nft_cmd dport { $ports }"
    fi
    
    # 添加标记设置
    nft_cmd="$nft_cmd meta mark set $mark counter"
    
    # 调试：显示构建的规则
    echo "Debug: NFT command to be executed:" >&2
    echo "  $nft_cmd" >&2
    
    # 执行前检查语法
    if ! nft -c "$nft_cmd" 2>&1; then
        log "NFT 规则语法错误"
        return 1
    fi
    
    # 实际执行
    local nft_output
    nft_output=$(nft "$nft_cmd" 2>&1)
    local nft_exit_code=$?
    
    if [ $nft_exit_code -eq 0 ]; then
        log "✅ NFT 规则添加成功"
        return 0
    else
        log "❌ NFT 规则添加失败，退出码: $nft_exit_code"
        log "详细错误: $nft_output"
        return 1
    fi
}

# 处理所有协议的规则（兼容旧版本）
apply_all_protocol_rule() {
    local chain="$1"
    local mark="$2"
    local srcport="$3"
    local dstport="$4"
    
    local success=0
    
    # 对于协议为 "all" 的情况，我们需要分别处理 TCP 和 UDP
    # 但不能创建不指定协议的端口规则
    
    # 处理 TCP 规则
    if [ -n "$srcport" ] && [ "$chain" = "filter_qos_ingress" ]; then
        # 入口链，使用源端口
        local ports=$(echo "$srcport" | tr -d ' ')
        if [ -n "$ports" ]; then
            local tcp_cmd="add rule inet gargoyle-qos-priority $chain ip protocol tcp tcp sport { $ports } meta mark set $mark counter"
            echo "Debug: 构建 TCP 规则: $tcp_cmd" >&2
            if nft -c "$tcp_cmd" 2>&1; then
                nft "$tcp_cmd" 2>&1 && log "✅ TCP 规则添加成功" || { log "❌ TCP 规则添加失败"; success=1; }
            else
                log "❌ TCP 规则语法错误"
                success=1
            fi
        fi
    elif [ -n "$dstport" ] && [ "$chain" = "filter_qos_egress" ]; then
        # 出口链，使用目的端口
        local ports=$(echo "$dstport" | tr -d ' ')
        if [ -n "$ports" ]; then
            local tcp_cmd="add rule inet gargoyle-qos-priority $chain ip protocol tcp tcp dport { $ports } meta mark set $mark counter"
            echo "Debug: 构建 TCP 规则: $tcp_cmd" >&2
            if nft -c "$tcp_cmd" 2>&1; then
                nft "$tcp_cmd" 2>&1 && log "✅ TCP 规则添加成功" || { log "❌ TCP 规则添加失败"; success=1; }
            else
                log "❌ TCP 规则语法错误"
                success=1
            fi
        fi
    else
        # 没有端口条件，仅指定协议
        local tcp_cmd="add rule inet gargoyle-qos-priority $chain ip protocol tcp meta mark set $mark counter"
        echo "Debug: 构建 TCP 规则: $tcp_cmd" >&2
        if nft -c "$tcp_cmd" 2>&1; then
            nft "$tcp_cmd" 2>&1 && log "✅ TCP 规则添加成功" || { log "❌ TCP 规则添加失败"; success=1; }
        else
            log "❌ TCP 规则语法错误"
            success=1
        fi
    fi
    
    # 处理 UDP 规则
    if [ -n "$srcport" ] && [ "$chain" = "filter_qos_ingress" ]; then
        # 入口链，使用源端口
        local ports=$(echo "$srcport" | tr -d ' ')
        if [ -n "$ports" ]; then
            local udp_cmd="add rule inet gargoyle-qos-priority $chain ip protocol udp udp sport { $ports } meta mark set $mark counter"
            echo "Debug: 构建 UDP 规则: $udp_cmd" >&2
            if nft -c "$udp_cmd" 2>&1; then
                nft "$udp_cmd" 2>&1 && log "✅ UDP 规则添加成功" || { log "❌ UDP 规则添加失败"; success=1; }
            else
                log "❌ UDP 规则语法错误"
                success=1
            fi
        fi
    elif [ -n "$dstport" ] && [ "$chain" = "filter_qos_egress" ]; then
        # 出口链，使用目的端口
        local ports=$(echo "$dstport" | tr -d ' ')
        if [ -n "$ports" ]; then
            local udp_cmd="add rule inet gargoyle-qos-priority $chain ip protocol udp udp dport { $ports } meta mark set $mark counter"
            echo "Debug: 构建 UDP 规则: $udp_cmd" >&2
            if nft -c "$udp_cmd" 2>&1; then
                nft "$udp_cmd" 2>&1 && log "✅ UDP 规则添加成功" || { log "❌ UDP 规则添加失败"; success=1; }
            else
                log "❌ UDP 规则语法错误"
                success=1
            fi
        fi
    else
        # 没有端口条件，仅指定协议
        local udp_cmd="add rule inet gargoyle-qos-priority $chain ip protocol udp meta mark set $mark counter"
        echo "Debug: 构建 UDP 规则: $udp_cmd" >&2
        if nft -c "$udp_cmd" 2>&1; then
            nft "$udp_cmd" 2>&1 && log "✅ UDP 规则添加成功" || { log "❌ UDP 规则添加失败"; success=1; }
        else
            log "❌ UDP 规则语法错误"
            success=1
        fi
    fi
    
    return $success
}