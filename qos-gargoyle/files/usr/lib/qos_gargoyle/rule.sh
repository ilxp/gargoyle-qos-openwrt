#!/bin/sh
# 规则辅助模块 (rule.sh)
# 支持多样化端口、协议、IPv6双栈、连接字节数过滤和连接状态过滤
# version=2.1.0 - 新增 ct state 支持
# 更新日志：
#   - 更严格的协议验证，仅支持标准协议
#   - 连接字节数解析改进，支持 >, <, >=, <=, =, !=
#   - 添加标记冲突检测（精确匹配），防止多个类别共用同一标记
#   - 移除未使用的旧函数 process_single_rule 和 apply_all_protocol_rule
#   - 优化排序，预加载类优先级，减少 UCI 调用
#   - 临时文件统一使用 mktemp，提高兼容性
#   - 新增 ct state 条件支持（state 选项）

CONFIG_FILE="qos_gargoyle"
TEMP_FILES=""
trap 'rm -f $TEMP_FILES 2>/dev/null' EXIT INT TERM HUP

# ========== 检测算法，若为CAKE则直接退出 ==========
ALGORITHM=$(uci -q get ${CONFIG_FILE}.global.algorithm 2>/dev/null || echo "hfsc_fqcodel")
if [ "$ALGORITHM" = "cake" ]; then
    echo "[$(date '+%H:%M:%S')] qos_gargoyle 信息: 当前算法为 CAKE，无需生成分类规则，退出" >&2
    logger -t "qos_gargoyle" "信息: 当前算法为 CAKE，无需生成分类规则，退出"
    return 0
fi

# ========== 辅助函数 ==========
# 转义字符串中的特殊字符，使其可安全用于 eval 赋值
escape_for_eval() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g'
}

# 清理输入字符串，只保留可打印字符，移除控制字符
sanitize_input() {
    echo "$1" | tr -cd '[:print:]' 2>/dev/null || echo "$1"
}

# 统一日志函数，支持级别过滤
# 全局变量 DEBUG 可设为 1 启用调试输出
log() {
    local level="$1"
    local message="$2"
    local tag="qos_gargoyle"
    local prefix=""
    
    [ -z "$message" ] && return
    
    case "$level" in
        ERROR|error)   prefix="错误:" ;;
        WARN|warn|WARNING|warning) prefix="警告:" ;;
        INFO|info)     prefix="信息:" ;;
        DEBUG|debug)   [ "${DEBUG:-0}" = "1" ] || return; prefix="调试:" ;;
        *)             prefix="$level:" ;;
    esac
    
    echo "$message" | while IFS= read -r line; do
        logger -t "$tag" "$prefix $line"
    done
    
    echo "$message" | while IFS= read -r line; do
        echo "[$(date '+%H:%M:%S')] $tag $prefix $line" >&2
    done
}

# ========== 验证函数 ==========
# 验证数字是否在指定范围内
validate_number() {
    local value="$1"
    local param_name="$2"
    local min="${3:-0}"
    local max="${4:-2147483647}"
    
    if ! echo "$value" | grep -qE '^[0-9]+$'; then
        log "ERROR" "参数 $param_name 必须是整数: $value"
        return 1
    fi
    
    if [ "$value" -lt "$min" ] 2>/dev/null; then
        log "ERROR" "参数 $param_name 必须大于等于 $min: $value"
        return 1
    fi
    
    if [ "$value" -gt "$max" ] 2>/dev/null; then
        log "ERROR" "参数 $param_name 必须小于等于 $max: $value"
        return 1
    fi
    
    return 0
}

# 验证端口参数（支持逗号分隔列表和端口范围）
validate_port() {
    local value="$1"
    local param_name="$2"
    local old_ifs="$IFS"
    
    [ -z "$value" ] && return 0
    
    value=$(sanitize_input "$value")
    local clean_value=$(echo "$value" | tr -d '[:space:]')
    
    if echo "$clean_value" | grep -q ','; then
        IFS=,
        for port in $clean_value; do
            [ -z "$port" ] && continue
            if echo "$port" | grep -q '-'; then
                if ! echo "$port" | grep -qE '^[0-9]+-[0-9]+$'; then
                    log "ERROR" "无效的端口范围格式 '$port'"
                    IFS="$old_ifs"
                    return 1
                fi
                local min_port max_port
                min_port=$(echo "$port" | cut -d'-' -f1)
                max_port=$(echo "$port" | cut -d'-' -f2)
                if ! validate_number "$min_port" "$param_name" 1 65535 ||
                   ! validate_number "$max_port" "$param_name" 1 65535 ||
                   [ "$min_port" -gt "$max_port" ]; then
                    IFS="$old_ifs"
                    return 1
                fi
            else
                if ! validate_number "$port" "$param_name" 1 65535; then
                    IFS="$old_ifs"
                    return 1
                fi
            fi
        done
        IFS="$old_ifs"
    elif echo "$clean_value" | grep -q '-'; then
        if ! echo "$clean_value" | grep -qE '^[0-9]+-[0-9]+$'; then
            log "ERROR" "无效的端口范围格式 '$clean_value'"
            return 1
        fi
        local min_port max_port
        min_port=$(echo "$clean_value" | cut -d'-' -f1)
        max_port=$(echo "$clean_value" | cut -d'-' -f2)
        if ! validate_number "$min_port" "$param_name" 1 65535 ||
           ! validate_number "$max_port" "$param_name" 1 65535 ||
           [ "$min_port" -gt "$max_port" ]; then
            return 1
        fi
    else
        if ! validate_number "$clean_value" "$param_name" 1 65535; then
            return 1
        fi
    fi
    
    return 0
}

# 验证 IP 地址（支持 IPv4 和 IPv6，包括 IPv4-mapped 格式）
validate_ip_address() {
    local ip="$1"
    local param_name="$2"
    
    [ -z "$ip" ] && return 0
    ip=$(sanitize_input "$ip")
    
    if echo "$ip" | grep -qE '^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'; then
        return 0
    fi
    
    if echo "$ip" | grep -qiE '^([0-9a-f]{1,4}:){7}[0-9a-f]{1,4}$|^([0-9a-f]{1,4}:){1,7}:$|^([0-9a-f]{1,4}:){1,6}:[0-9a-f]{1,4}$|^([0-9a-f]{1,4}:){1,5}(:[0-9a-f]{1,4}){1,2}$|^([0-9a-f]{1,4}:){1,4}(:[0-9a-f]{1,4}){1,3}$|^([0-9a-f]{1,4}:){1,3}(:[0-9a-f]{1,4}){1,4}$|^([0-9a-f]{1,4}:){1,2}(:[0-9a-f]{1,4}){1,5}$|^[0-9a-f]{1,4}:((:[0-9a-f]{1,4}){1,6})$|^:((:[0-9a-f]{1,4}){1,7})$|^::$|^::ffff:(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$'; then
        return 0
    fi
    
    log "ERROR" "$param_name IP地址格式不正确: $ip"
    return 1
}

# 验证协议名称，只接受标准协议或 tcp_udp 作为组合协议
validate_protocol() {
    local proto="$1"
    local param_name="$2"
    
    [ -z "$proto" ] && return 0  # 空协议表示所有（等同于 all）
    proto=$(sanitize_input "$proto")
    
    case "$proto" in
        all|tcp|udp|tcp_udp|icmp|icmpv6|gre|esp|ah|sctp|dccp|udplite)
            return 0
            ;;
        *)
            log "ERROR" "$param_name 不支持的协议 '$proto'，必须为 tcp/udp/tcp_udp/icmp/icmpv6 等标准协议"
            return 1
            ;;
    esac
}

# 验证连接状态值，只接受 nftables 支持的关键字（单个或逗号分隔）
validate_state() {
    local state="$1"
    local param_name="$2"
    
    [ -z "$state" ] && return 0
    state=$(sanitize_input "$state" | tr -d ' ')
    
    # 支持花括号语法，但 UCI 配置中通常不包含花括号，所以先简化处理
    # 允许逗号分隔的列表
    local old_ifs="$IFS"
    IFS=','
    for s in $state; do
        s=$(echo "$s" | tr -d '{}')  # 移除可能的花括号
        case "$s" in
            new|established|related|untracked|invalid)
                # 有效
                ;;
            *)
                log "ERROR" "$param_name 无效的连接状态 '$s'，允许的值: new, established, related, untracked, invalid"
                IFS="$old_ifs"
                return 1
                ;;
        esac
    done
    IFS="$old_ifs"
    return 0
}

# ========== 配置加载函数 ==========
# 加载指定类型的所有配置节名称
load_all_config_sections() {
    local config_name="$1"
    local section_type="$2"
    local config_output=$(uci show "$config_name" 2>/dev/null)
    
    [ -z "$config_output" ] && { echo ""; return; }
    
    if [ -n "$section_type" ]; then
        local anonymous_sections=$(echo "$config_output" | grep -E "^${config_name}\\.@${section_type}\\[[0-9]+\\]=" | cut -d= -f1 | sed "s/^${config_name}\\.//")
        local named_sections=$(echo "$config_output" | grep -E "^${config_name}\\.[a-zA-Z0-9_]+=${section_type}"'$' | cut -d= -f1 | cut -d. -f2)
        local old_format_sections=$(echo "$config_output" | grep -E "^${config_name}\\.${section_type}_[0-9]+=" | cut -d= -f1 | cut -d. -f2)
        local all_sections=$(echo "$anonymous_sections" "$named_sections" "$old_format_sections" | tr ' ' '\n' | grep -v "^$" | sort -u | tr '\n' ' ')
        echo "$all_sections" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    else
        echo "$config_output" | grep -E "^${config_name}\\.[a-zA-Z_]+[0-9]*=" | cut -d= -f1 | cut -d. -f2
    fi
}

# 加载指定配置节的所有选项，并赋值给带前缀的变量
load_all_config_options() {
    local config_name="$1"
    local section_id="$2"
    local prefix="$3"
    
    local escaped_section_id=$(printf "%s" "$section_id" | sed 's/[][\.*?^$()+{}|]/\\&/g')
    
    for var in class order enabled proto srcport dstport connbytes_kb family state; do
        eval "${prefix}${var}=''"
    done
    
    local config_data=$(uci show "${config_name}.${section_id}" 2>/dev/null)
    local val
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.class=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        val=$(escape_for_eval "$val")
        eval "${prefix}class=\"$val\""
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.order=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        val=$(escape_for_eval "$val")
        eval "${prefix}order=\"$val\""
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.enabled=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        val=$(escape_for_eval "$val")
        eval "${prefix}enabled=\"$val\""
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.proto=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        if validate_protocol "$val" "${section_id}.proto"; then
            val=$(escape_for_eval "$val")
            eval "${prefix}proto=\"$val\""
        else
            log "WARN" "协议参数验证失败: $val，将使用空值（视为 all）"
            eval "${prefix}proto=''"
        fi
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.srcport=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        if validate_port "$val" "${section_id}.srcport"; then
            val=$(escape_for_eval "$val")
            eval "${prefix}srcport=\"$val\""
        else
            log "WARN" "源端口参数验证失败: $val，将使用空值"
            eval "${prefix}srcport=''"
        fi
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.dstport=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        if validate_port "$val" "${section_id}.dstport"; then
            val=$(escape_for_eval "$val")
            eval "${prefix}dstport=\"$val\""
        else
            log "WARN" "目的端口参数验证失败: $val，将使用空值"
            eval "${prefix}dstport=''"
        fi
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.connbytes_kb=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        val=$(escape_for_eval "$val")
        eval "${prefix}connbytes_kb=\"$val\""
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.family=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        val=$(escape_for_eval "$val")
        eval "${prefix}family=\"$val\""
    fi
    
    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.state=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        if validate_state "$val" "${section_id}.state"; then
            val=$(escape_for_eval "$val")
            eval "${prefix}state=\"$val\""
        else
            log "WARN" "连接状态参数验证失败: $val，将忽略"
            eval "${prefix}state=''"
        fi
    fi
}

# ========== 类别标记计算函数 ==========
# 计算类名的哈希索引（基于 SHA1 或 CRC32）- 修复溢出问题
calculate_hash_index() {
    local class="$1"
    local hash_val
    
    if command -v sha1sum >/dev/null 2>&1; then
        hash_val=$(printf "%s" "$class" | sha1sum | cut -c1-8)
        # 转换为无符号32位整数
        printf "%u" "0x$hash_val" 2>/dev/null || echo "$((0x$hash_val & 0x7FFFFFFF))"
    elif command -v sha1 >/dev/null 2>&1; then
        hash_val=$(printf "%s" "$class" | sha1 | cut -c1-8)
        printf "%u" "0x$hash_val" 2>/dev/null || echo "$((0x$hash_val & 0x7FFFFFFF))"
    else
        local sum=0 i=0
        while [ $i -lt ${#class} ]; do
            # 获取字符的ASCII值，使用 printf 获取数值，确保在32位范围内
            local char=$(printf "%d" "'${class:$i:1}" 2>/dev/null || echo 0)
            sum=$(( ( (sum << 5) - sum + char ) & 0x7FFFFFFF ))
            i=$((i + 1))
        done
        echo $((sum & 0x7FFFFFFF))
    fi
}

# 获取类别的标记值，强制使用计算标记，忽略文件和 UCI 配置
get_class_mark_for_rule() {
    local class="$1"
    local direction="$2"
    
    # 首次调用时记录一次（避免刷屏）
    local cache_var="__mark_calculated_${class}_${direction}"
    if eval [ -z \"\${$cache_var+x}\" ]; then
        log "INFO" "类别 $class ($direction) 标记将使用计算值"
        eval "$cache_var=1"
    fi
    
    local calculated_mark
    calculated_mark=$(calculate_class_mark "$class" "0x0" "$direction")
    if [ -n "$calculated_mark" ] && echo "$calculated_mark" | grep -qE '^0x[0-9A-Fa-f]+$'; then
        echo "$calculated_mark"
        return 0
    else
        log "ERROR" "无法为类别 $class 生成有效标记"
        return 1
    fi
}

# 计算类别的标记值（哈希取模 7 后左移）
calculate_class_mark() {
    local class="$1"
    local mask="$2"
    local chain_type="$3"
    
    local index=$(calculate_hash_index "$class")
    # 确保index是正数且进行模运算
    index=$(( (index % 7) + 1 ))
    
    local base_value=0
    [ "$chain_type" = "upload" ] && base_value=$((0x1))
    [ "$chain_type" = "download" ] && base_value=$((0x100))
    [ $base_value -eq 0 ] && { log "ERROR" "未知链类型: $chain_type"; echo ""; return; }
    
    local mark_value=$((base_value << (index - 1)))
    # 确保mark_value在有效范围内且为正数
    mark_value=$((mark_value & 0x7FFF))
    printf "0x%X" "$mark_value"
}

# ========== 规则排序函数 ==========
# 从临时文件读取规则配置，获取类优先级，生成排序键
sort_rules_by_priority_fast() {
    local config_file="$1"
    local temp_sort=$(mktemp /tmp/qos_sort_XXXXXX 2>/dev/null)
    if [ -z "$temp_sort" ]; then
        log "ERROR" "无法创建排序临时文件"
        return 1
    fi
    TEMP_FILES="$TEMP_FILES $temp_sort"
    
    # 预加载所有类的优先级，避免在循环中多次调用 uci
    # 先收集所有出现过的类名
    local all_classes=$(cut -d: -f2 "$config_file" | sort -u)
    local class_priority_cache=""
    for cls in $all_classes; do
        [ -n "$cls" ] || continue
        local prio=$(uci -q get "${CONFIG_FILE}.${cls}.priority" 2>/dev/null)
        prio=${prio:-999}
        class_priority_cache="$class_priority_cache$cls:$prio "
    done
    
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IFS=':' read -r r_name r_class r_order r_enabled r_proto r_srcport r_dstport r_connbytes r_family r_state <<EOF
$line
EOF
        [ "$r_enabled" != "1" ] && continue
        
        # 从缓存中查找类优先级
        local class_prio=999
        for entry in $class_priority_cache; do
            if [ "${entry%%:*}" = "$r_class" ]; then
                class_prio="${entry#*:}"
                break
            fi
        done
        
        local rule_order=${r_order:-100}
        local composite=$(( class_prio * 1000 + rule_order ))
        echo "$composite:$r_name" >> "$temp_sort"
    done < "$config_file"
    
    # 排序输出
    local result=$(sort -t ':' -k1,1n "$temp_sort" 2>/dev/null | cut -d: -f2- | tr '\n' ' ' | sed 's/ $//')
    
    # 立即删除临时文件
    rm -f "$temp_sort" 2>/dev/null
    
    echo "$result"
}

# ========== 构建 nft 规则 ==========
# 构建单条 nft 规则命令并输出到标准输出
# 参数顺序：rule_name, chain, class_mark, mask, family, proto, srcport, dstport, connbytes_kb, state
build_nft_rule_fast() {
    local rule_name="$1"
    local chain="$2"
    local class_mark="$3"
    local mask="$4"
    local family="$5"
    local proto="$6"
    local srcport="$7"
    local dstport="$8"
    local connbytes_kb="$9"
    local state="${10}"
    
    local nft_cmd="add rule $family gargoyle-qos-priority $chain"
    
    # 处理协议
    if [ "$proto" = "tcp" ]; then
        nft_cmd="$nft_cmd meta l4proto tcp"
    elif [ "$proto" = "udp" ]; then
        nft_cmd="$nft_cmd meta l4proto udp"
    elif [ "$proto" = "tcp_udp" ]; then
        nft_cmd="$nft_cmd meta l4proto { tcp, udp }"
    elif [ -n "$proto" ] && [ "$proto" != "all" ]; then
        nft_cmd="$nft_cmd meta l4proto $proto"
    fi
    
    # 端口处理（根据方向）
    case "$chain" in
        *"ingress"*)
            if [ -n "$srcport" ]; then
                local clean_srcport=$(echo "$srcport" | tr -d ' ')
                nft_cmd="$nft_cmd th sport { $clean_srcport }"
            fi
            ;;
        *)
            if [ -n "$dstport" ]; then
                local clean_dstport=$(echo "$dstport" | tr -d ' ')
                nft_cmd="$nft_cmd th dport { $clean_dstport }"
            fi
            ;;
    esac
    
    # 处理连接状态条件
    if [ -n "$state" ]; then
        # 移除可能的花括号，确保 nft 语法正确
        local state_value=$(echo "$state" | tr -d '{}')
        # 如果包含逗号，需要包装为集合
        if echo "$state_value" | grep -q ','; then
            nft_cmd="$nft_cmd ct state { $state_value }"
        else
            nft_cmd="$nft_cmd ct state $state_value"
        fi
    fi
    
    # 处理连接字节数条件
    if [ -n "$connbytes_kb" ] && [ "$connbytes_kb" != "0" ]; then
        local clean=$(echo "$connbytes_kb" | tr -d ' ')
        # 匹配操作符和数字，操作符可以是 >, <, >=, <=, =, !=
        if echo "$clean" | grep -qE '^([<>]?=?|!=)[0-9]+$'; then
            local operator=$(echo "$clean" | sed -n 's/^\([<>]\?=\?\|!=\)[0-9]*/\1/p')
            local value=$(echo "$clean" | grep -o '[0-9]\+$')
            [ -z "$operator" ] && operator=">="  # 默认 >=
            local bytes=$((value * 1024))
            nft_cmd="$nft_cmd ct bytes $operator $bytes"
        else
            log "WARN" "规则 $rule_name 的 connbytes_kb 格式无效: $clean，忽略此条件"
        fi
    fi
    
    nft_cmd="$nft_cmd meta mark set $class_mark counter"
    echo "$nft_cmd"
}

# ========== 增强规则应用函数（主入口） ==========
# 应用指定方向的所有规则（上传或下载），支持优先级排序和批量提交
apply_direction_rules() {
    local rule_type="$1"
    local chain="$2"
    local mask="$3"
    
    log "INFO" "应用 $rule_type 规则到链: $chain, 掩码: $mask"
    
    local direction=""
    [ "$chain" = "filter_qos_egress" ] && direction="upload"
    [ "$chain" = "filter_qos_ingress" ] && direction="download"
    
    local rule_list=$(load_all_config_sections "$CONFIG_FILE" "$rule_type")
    [ -z "$rule_list" ] && { log "INFO" "未找到 $rule_type 规则配置"; return; }
    
    log "INFO" "找到 $rule_type 规则: $rule_list"
    
    # 预加载规则配置到临时文件
    local temp_config=$(mktemp /tmp/qos_rule_config_XXXXXX 2>/dev/null)
    if [ -z "$temp_config" ]; then
        log "ERROR" "无法创建配置临时文件"
        return 1
    fi
    TEMP_FILES="$TEMP_FILES $temp_config"
    
    local IFS=' '
    set -- $rule_list
    for rule; do
        [ -n "$rule" ] || continue
        load_all_config_options "$CONFIG_FILE" "$rule" "tmp_"
        # 格式：规则名:类:顺序:启用:协议:源端口:目的端口:连接字节数:地址族:连接状态
        echo "$rule:$tmp_class:$tmp_order:$tmp_enabled:$tmp_proto:$tmp_srcport:$tmp_dstport:$tmp_connbytes_kb:$tmp_family:$tmp_state" >> "$temp_config"
    done
    
    # 提取所有用到的类（用于后续数量检查）
    local class_list=$(cut -d: -f2 "$temp_config" | sort -u)
    local class_count=0
    for class in $class_list; do
        [ -n "$class" ] || continue
        class_count=$((class_count + 1))
    done
    
    # 类数量超限警告（最多7个标记可用）
    if [ $class_count -gt 7 ]; then
        log "WARN" "方向 $direction 的启用类数量为 $class_count，超过7个，可能导致标记冲突！"
    fi
    
    # 快速排序（使用预加载的类优先级）
    local sorted_rule_list=$(sort_rules_by_priority_fast "$temp_config")
    if [ -z "$sorted_rule_list" ]; then
        log "INFO" "没有可用的启用规则"
        rm -f "$temp_config" 2>/dev/null
        return
    fi
    
    # 批量生成nft规则（实时获取标记）
    local nft_batch_file=$(mktemp /tmp/qos_nft_batch_XXXXXX 2>/dev/null)
    if [ -z "$nft_batch_file" ]; then
        log "ERROR" "无法创建nft批处理文件"
        rm -f "$temp_config" 2>/dev/null
        return 1
    fi
    TEMP_FILES="$TEMP_FILES $nft_batch_file"
    
    # 用于检测标记冲突的关联数组（模拟），使用精确匹配
    local seen_marks=""
    local rule_count=0
    local conflict_detected=0
    
    log "INFO" "按优先级顺序生成nft规则..."
    for rule_name in $sorted_rule_list; do
        local rule_line=$(grep "^$rule_name:" "$temp_config")
        IFS=':' read -r r_name r_class r_order r_enabled r_proto r_srcport r_dstport r_connbytes r_family r_state <<EOF
$rule_line
EOF
        [ "$r_enabled" = "1" ] || continue
        
        local class_mark=$(get_class_mark_for_rule "$r_class" "$direction" | tr -d '[:space:]')
        if [ -z "$class_mark" ]; then
            log "ERROR" "规则 $rule_name 的类 $r_class 无法获取标记，跳过"
            continue
        fi
        
        # 精确检查标记冲突
        local conflict=0
        for m in $seen_marks; do
            if [ "$m" = "$class_mark" ]; then
                conflict=1
                break
            fi
        done
        if [ $conflict -eq 1 ]; then
            log "ERROR" "标记冲突：类 $r_class 的标记 $class_mark 已被其他规则使用，规则 $rule_name 将被跳过"
            conflict_detected=1
            continue
        fi
        seen_marks="$seen_marks $class_mark"
        
        [ -z "$r_family" ] && r_family="inet"
        
        # 调用构建函数，传入所有参数
        build_nft_rule_fast "$rule_name" "$chain" "$class_mark" "$mask" "$r_family" "$r_proto" "$r_srcport" "$r_dstport" "$r_connbytes" "$r_state" >> "$nft_batch_file"
        rule_count=$((rule_count + 1))
    done
    
    if [ $conflict_detected -eq 1 ]; then
        log "WARN" "存在标记冲突，部分规则可能未生效。建议减少类别数量或调整类别名称。"
    fi
    
    local batch_success=0
    if [ -s "$nft_batch_file" ]; then
        log "INFO" "执行批量nft规则 (共 $rule_count 条)..."
        nft_output=$(nft -f "$nft_batch_file" 2>&1)
        nft_ret=$?
        if [ $nft_ret -eq 0 ]; then
            log "INFO" "✅ 批量规则应用成功"
        else
            log "ERROR" "❌ 批量规则应用失败 (退出码: $nft_ret)"
            log "ERROR" "nft 错误输出: $nft_output"
            log "ERROR" "批处理文件内容:"
            cat "$nft_batch_file" | while IFS= read -r line; do
                log "ERROR" "  $line"
            done
            batch_success=1
        fi
        log "INFO" "当前链 $chain 中的规则:"
        nft list chain inet gargoyle-qos-priority $chain 2>&1 | while IFS= read -r line; do
            log "INFO" "  $line"
        done
    fi
    
    # 清理临时文件
    rm -f "$nft_batch_file" 2>/dev/null
    rm -f "$temp_config" 2>/dev/null
    
    return $batch_success
}

# ========== 双栈过滤器函数（可选，但主脚本中已用 nft 处理，此处保留以供参考） ==========
create_dualstack_filter() {
    local dev="$1"
    local parent="$2"
    local class_id="$3"
    local mark="$4"
    local mask="$5"
    
    tc filter add dev "$dev" parent "$parent" protocol ip \
        handle ${mark}/$mask fw flowid "$class_id" 2>/dev/null || true
    tc filter add dev "$dev" parent "$parent" protocol ipv6 \
        handle ${mark}/$mask fw flowid "$class_id" 2>/dev/null || true
}

create_priority_dualstack_filter() {
    local dev="$1"
    local parent="$2"
    local class_id="$3"
    local class="$4"
    local mark="$5"
    local mask="$6"
    
    local class_priority=$(uci -q get "${CONFIG_FILE}.${class}.priority" 2>/dev/null)
    class_priority=${class_priority:-100}
    
    tc filter add dev "$dev" parent "$parent" protocol ip \
        prio $class_priority handle ${mark}/$mask fw flowid "$class_id" 2>/dev/null || true
    tc filter add dev "$dev" parent "$parent" protocol ipv6 \
        prio $((class_priority + 1)) handle ${mark}/$mask fw flowid "$class_id" 2>/dev/null || true
}

# ========== 兼容旧版本调用的别名 ==========
# 为保持与旧版主脚本的兼容性，保留以下别名
apply_all_rules() {
    log "WARN" "apply_all_rules 已废弃，请使用 apply_direction_rules"
    apply_direction_rules "$1" "$2" "$3"
}

# 脚本被 source 时不会执行任何操作
# 如果直接执行，则提示用法
if [ "$(basename "$0")" = "rule.sh" ]; then
    echo "此脚本为辅助模块，不应直接执行" >&2
    exit 1
fi
