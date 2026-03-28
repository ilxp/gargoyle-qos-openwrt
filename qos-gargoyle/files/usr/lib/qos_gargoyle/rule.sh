#!/bin/bash
# 规则辅助模块 (rule.sh)
# 版本: 3.5.6 - ack tcp udp 新语法
# 完全移除锁机制，适配 procd 管理

# 加载核心库
if [[ -f "/usr/lib/qos_gargoyle/common.sh" ]]; then
    . /usr/lib/qos_gargoyle/common.sh
else
    echo "错误: 核心库 /usr/lib/qos_gargoyle/common.sh 未找到" >&2
    exit 1
fi

# ========== 清理函数 ==========
main_cleanup() {
    cleanup_temp_files 2>/dev/null
}
trap main_cleanup EXIT INT TERM HUP QUIT

# ========== 获取 WAN 接口 ==========
get_wan_interface() {
    local wan_if
    wan_if=$(uci -q get ${CONFIG_FILE}.global.wan_interface 2>/dev/null)
    if [[ -z "$wan_if" ]] && [[ -f "/lib/functions/network.sh" ]]; then
        . /lib/functions/network.sh
        network_find_wan wan_if
    fi
    echo "$wan_if"
}

# ========== 辅助函数：调整协议以适应地址族 ==========
adjust_proto_for_family() {
    local proto="$1" family="$2"
    local adjusted="$proto"
    [[ -z "$proto" || "$proto" == "all" ]] && { echo "$proto"; return 0; }
    case "$family" in
        ipv4|ip|inet4)
            case "$proto" in
                icmpv6) adjusted="icmp" ;;
                *) adjusted="$proto" ;;
            esac
            ;;
        ipv6|ip6|inet6)
            case "$proto" in
                icmp) adjusted="icmpv6" ;;
                *) adjusted="$proto" ;;
            esac
            ;;
        inet)
            if [[ "$proto" == "icmp" ]]; then
                adjusted="icmp"
            elif [[ "$proto" == "icmpv6" ]]; then
                adjusted="icmpv6"
            fi
            ;;
    esac
    echo "$adjusted"
}

# ========== 将逗号分隔的多值字段转换为 nftables 集合表达式 ==========
# 输入: field_value (如 "80,443" 或 "!=22,23" 或 "!=", 支持 "!=22" 单值)
# 输出: 生成的表达式片段 (如 "{ 80, 443 }" 或 "!= { 22, 23 }" 或 "!= 22")
format_multivalue() {
    local val="$1"
    local prefix=""
    [[ "$val" == "!="* ]] && { prefix="!="; val="${val#!=}"; }
    if [[ "$val" == *","* ]]; then
        # 集合形式
        local elements=""
        IFS=',' read -ra parts <<< "$val"
        for part in "${parts[@]}"; do
            part="$(echo "$part" | xargs)"  # 去除空格
            elements="${elements}${elements:+, }$part"
        done
        echo "${prefix}{ $elements }"
    else
        # 单值
        echo "${prefix}${val}"
    fi
}

# ========== TCP 标志位映射 ==========
declare -A TCP_FLAG_MAP=(
    [syn]=0x02
    [ack]=0x10
    [rst]=0x04
    [fin]=0x01
    [urg]=0x20
    [psh]=0x08
    [ecn]=0x40
    [cwr]=0x80
)

flags_to_mask() {
    local flags_list="$1"
    local mask=0
    local flag
    IFS=',' read -ra flags <<< "$flags_list"
    for flag in "${flags[@]}"; do
        flag="${flag// /}"
        [[ -z "$flag" ]] && continue
        mask=$((mask | ${TCP_FLAG_MAP[$flag]:-0}))
    done
    printf "0x%x" "$mask"
}

# ========== 通用规则构建函数（支持多值字段，使用集合） ==========
build_nft_rule_generic() {
    local rule_name="$1" chain="$2" class_mark="$3" family="$4" proto="$5"
    local srcport="$6" dstport="$7" connbytes_kb="$8" state="$9" src_ip="${10}" dest_ip="${11}"
    local packet_len="${12}" tcp_flags="${13}" iif="${14}" oif="${15}" udp_length="${16}"
    local dscp="${17}" ttl="${18}" icmp_type="${19}"
    
    local proto_v4=$(adjust_proto_for_family "$proto" "ipv4")
    local proto_v6=$(adjust_proto_for_family "$proto" "ipv6")
    
    local ipv4_rules=()
    local ipv6_rules=()
    
    add_ipv4_rule() {
        local cmd="add rule inet ${NFT_TABLE} $chain meta mark == 0 meta nfproto ipv4"
        [ -n "$1" ] && cmd="$cmd $1"
        [ -n "$2" ] && cmd="$cmd $2"
        [ -n "$3" ] && cmd="$cmd $3"
        if [[ "$chain" == *"ingress"* ]]; then
            cmd="$cmd meta mark set $class_mark ct mark set meta mark counter"
        else
            cmd="$cmd meta mark set $class_mark ct mark set meta mark counter"
        fi
        ipv4_rules+=("$cmd")
    }
    
    add_ipv6_rule() {
        local cmd="add rule inet ${NFT_TABLE} $chain meta mark == 0 meta nfproto ipv6"
        [ -n "$1" ] && cmd="$cmd $1"
        [ -n "$2" ] && cmd="$cmd $2"
        [ -n "$3" ] && cmd="$cmd $3"
        if [[ "$chain" == *"ingress"* ]]; then
            cmd="$cmd meta mark set $class_mark ct mark set meta mark counter"
        else
            cmd="$cmd meta mark set $class_mark ct mark set meta mark counter"
        fi
        ipv6_rules+=("$cmd")
    }
    
    local common_cond=""
    if [[ -n "$packet_len" ]]; then
        if [[ "$packet_len" == *-* ]]; then
            local min="${packet_len%-*}" max="${packet_len#*-}"
            common_cond="$common_cond meta length >= $min meta length <= $max"
        elif [[ "$packet_len" =~ ^([<>]=?|!=)[0-9]+$ ]]; then
            local operator="${packet_len%%[0-9]*}"
            local num="${packet_len##*[!0-9]}"
            local nft_op=""
            case "$operator" in
                ">") nft_op="gt" ;;
                ">=") nft_op="ge" ;;
                "<") nft_op="lt" ;;
                "<=") nft_op="le" ;;
                "!=") nft_op="ne" ;;
                "=")  nft_op="eq" ;;
                *)   nft_op="$operator" ;;
            esac
            common_cond="$common_cond meta length $nft_op $num"
        elif [[ "$packet_len" =~ ^[0-9]+$ ]]; then
            common_cond="$common_cond meta length eq $packet_len"
        fi
    fi
    
    # TCP 标志处理
    local tcp_flag_expr=""
    if [[ -n "$tcp_flags" ]] && [[ "$proto" == "tcp" ]]; then
        local set_flags=""
        local unset_flags=""
        IFS=',' read -ra flags <<< "$tcp_flags"
        for f in "${flags[@]}"; do
            [[ -z "$f" ]] && continue
            if [[ "$f" == !* ]]; then
                unset_flags="${unset_flags}${unset_flags:+,}${f#!}"
            else
                set_flags="${set_flags}${set_flags:+,}$f"
            fi
        done
        if [[ -n "$set_flags" && -z "$unset_flags" ]]; then
            tcp_flag_expr="tcp flags { ${set_flags//,/ } }"
        elif [[ -n "$set_flags" || -n "$unset_flags" ]]; then
            local mask_set=0
            local mask_unset=0
            if [[ -n "$set_flags" ]]; then
                mask_set=$(flags_to_mask "$set_flags")
            fi
            if [[ -n "$unset_flags" ]]; then
                mask_unset=$(flags_to_mask "$unset_flags")
            fi
            local total_mask=$((mask_set | mask_unset))
            if [[ $total_mask -ne 0 ]]; then
                tcp_flag_expr="tcp flags & 0x$(printf '%x' "$total_mask") == 0x$(printf '%x' "$mask_set")"
            fi
        fi
    fi
    
    [[ -n "$iif" ]] && common_cond="$common_cond iifname \"$iif\""
    [[ -n "$oif" ]] && common_cond="$common_cond oifname \"$oif\""
    
    if [[ -n "$udp_length" ]] && [[ "$proto" == "udp" ]]; then
        if [[ "$udp_length" == *-* ]]; then
            local min="${udp_length%-*}" max="${udp_length#*-}"
            common_cond="$common_cond udp length >= $min udp length <= $max"
        elif [[ "$udp_length" =~ ^([<>]=?|!=)[0-9]+$ ]]; then
            local operator="${udp_length%%[0-9]*}"
            local num="${udp_length##*[!0-9]}"
            local nft_op=""
            case "$operator" in
                ">") nft_op="gt" ;;
                ">=") nft_op="ge" ;;
                "<") nft_op="lt" ;;
                "<=") nft_op="le" ;;
                "!=") nft_op="ne" ;;
                "=")  nft_op="eq" ;;
                *)   nft_op="$operator" ;;
            esac
            common_cond="$common_cond udp length $nft_op $num"
        elif [[ "$udp_length" =~ ^[0-9]+$ ]]; then
            common_cond="$common_cond udp length eq $udp_length"
        fi
    fi
    
    local port_cond=""
    if [[ "$proto" =~ ^(tcp|udp|tcp_udp)$ ]]; then
        if [[ "$chain" == *"ingress"* ]]; then
            if [[ -n "$srcport" ]]; then
                local sport_val="$srcport"
                port_cond="th sport $(format_multivalue "$sport_val")"
            fi
        else
            if [[ -n "$dstport" ]]; then
                local dport_val="$dstport"
                port_cond="th dport $(format_multivalue "$dport_val")"
            fi
        fi
        if [[ -n "$port_cond" ]]; then
            common_cond="$common_cond $port_cond"
        fi
    fi
    
    if [[ -n "$state" ]]; then
        local state_value="${state//[{}]/}"
        if [[ "$state_value" == *,* ]]; then
            common_cond="$common_cond ct state { $state_value }"
        else
            common_cond="$common_cond ct state $state_value"
        fi
    fi
    
    if [[ -n "$connbytes_kb" ]]; then
        if [[ "$connbytes_kb" == *-* ]]; then
            local min_val="${connbytes_kb%-*}" max_val="${connbytes_kb#*-}"
            local min_bytes=$((min_val * 1024)) max_bytes=$((max_val * 1024))
            common_cond="$common_cond ct bytes >= $min_bytes ct bytes <= $max_bytes"
        elif [[ "$connbytes_kb" =~ ^([<>]=?|!=)[0-9]+$ ]]; then
            local operator="${connbytes_kb%%[0-9]*}"
            local num="${connbytes_kb##*[!0-9]}"
            local op=""
            case "$operator" in
                ">") op="gt" ;;
                ">=") op="ge" ;;
                "<") op="lt" ;;
                "<=") op="le" ;;
                "!=") op="ne" ;;
                "=")  op="eq" ;;
                *)   op="$operator" ;;
            esac
            local bytes_value=$((num * 1024))
            common_cond="$common_cond ct bytes $op $bytes_value"
        elif [[ "$connbytes_kb" =~ ^[0-9]+$ ]]; then
            local bytes_value=$((connbytes_kb * 1024))
            common_cond="$common_cond ct bytes eq $bytes_value"
        fi
    fi
    
    process_ip_field() {
        local ip_val="$1" direction="$2"
        local ipv4_cond=""
        local ipv6_cond=""
        if [[ -n "$ip_val" ]]; then
            local neg=""
            local val="$ip_val"
            [[ "$val" == "!="* ]] && { neg="!="; val="${val#!=}"; }
            if [[ "$val" == @* ]]; then
                local setname="${val#@}"
                local set_family=$(get_set_family "$setname")
                if [[ "$set_family" == "ipv6" ]]; then
                    ipv6_cond="ip6 $direction $neg $val"
                else
                    ipv4_cond="ip $direction $neg $val"
                fi
            elif [[ "$val" =~ : ]]; then
                ipv6_cond="ip6 $direction $neg $val"
            else
                ipv4_cond="ip $direction $neg $val"
            fi
        fi
        eval "$3=\"\$ipv4_cond\""
        eval "$4=\"\$ipv6_cond\""
    }
    
    local src_ipv4_cond=""
    local src_ipv6_cond=""
    local dst_ipv4_cond=""
    local dst_ipv6_cond=""
    process_ip_field "$src_ip" "saddr" src_ipv4_cond src_ipv6_cond
    process_ip_field "$dest_ip" "daddr" dst_ipv4_cond dst_ipv6_cond
    
    local has_ipv4=0 has_ipv6=0
    case "$family" in
        ip|ipv4|inet4)
            has_ipv4=1
            ;;
        ip6|ipv6|inet6)
            has_ipv6=1
            ;;
        inet)
            if [[ -n "$src_ipv4_cond" ]] || [[ -n "$dst_ipv4_cond" ]]; then
                has_ipv4=1
            fi
            if [[ -n "$src_ipv6_cond" ]] || [[ -n "$dst_ipv6_cond" ]]; then
                has_ipv6=1
            fi
            if [[ $has_ipv4 -eq 0 && $has_ipv6 -eq 0 ]]; then
                has_ipv4=1
                has_ipv6=1
            fi
            ;;
        *) log_error "规则 $rule_name 无效的 family '$family'"; return ;;
    esac
    
    local icmp_v4_cond=""
    local icmp_v6_cond=""
    if [[ -n "$icmp_type" ]]; then
        if [[ "$proto_v4" == "icmp" ]]; then
            icmp_v4_cond=$(build_icmp_cond "$icmp_type")
        fi
        if [[ "$proto_v6" == "icmpv6" ]]; then
            icmp_v6_cond=$(build_icmp_cond "$icmp_type")
        fi
    fi
    
    if (( has_ipv4 )); then
        local ipv4_full_cond="$common_cond"
        if [[ -n "$proto_v4" && "$proto_v4" != "all" ]]; then
            case "$proto_v4" in
                tcp) ipv4_full_cond="$ipv4_full_cond meta l4proto tcp" ;;
                udp) ipv4_full_cond="$ipv4_full_cond meta l4proto udp" ;;
                tcp_udp) ipv4_full_cond="$ipv4_full_cond meta l4proto { tcp, udp }" ;;
                icmp|icmpv6|gre|esp|ah|sctp|dccp|udplite) ipv4_full_cond="$ipv4_full_cond meta l4proto $proto_v4" ;;
                all|"") ;;
                *) ipv4_full_cond="$ipv4_full_cond meta l4proto $proto_v4" ;;
            esac
        fi
        [[ -n "$src_ipv4_cond" ]] && ipv4_full_cond="$ipv4_full_cond $src_ipv4_cond"
        [[ -n "$dst_ipv4_cond" ]] && ipv4_full_cond="$ipv4_full_cond $dst_ipv4_cond"
        if [[ -n "$dscp" ]]; then
            local dscp_val="$dscp"
            local neg=""
            [[ "$dscp_val" == "!="* ]] && { neg="!="; dscp_val="${dscp_val#!=}"; }
            ipv4_full_cond="$ipv4_full_cond ip dscp $neg $dscp_val"
        fi
        if [[ -n "$ttl" ]]; then
            local ttl_val="$ttl"
            if [[ "$ttl_val" =~ ^([<>]=?|!=)[0-9]+$ ]]; then
                local operator="${ttl_val%%[0-9]*}"
                local num="${ttl_val##*[!0-9]}"
                local nft_op=""
                case "$operator" in
                    ">") nft_op="gt" ;;
                    ">=") nft_op="ge" ;;
                    "<") nft_op="lt" ;;
                    "<=") nft_op="le" ;;
                    "!=") nft_op="ne" ;;
                    "=")  nft_op="eq" ;;
                    *)   nft_op="$operator" ;;
                esac
                ipv4_full_cond="$ipv4_full_cond ip ttl $nft_op $num"
            else
                ipv4_full_cond="$ipv4_full_cond ip ttl eq $ttl_val"
            fi
        fi
        [[ -n "$icmp_v4_cond" ]] && ipv4_full_cond="$ipv4_full_cond $icmp_v4_cond"
        [[ -n "$tcp_flag_expr" ]] && ipv4_full_cond="$ipv4_full_cond $tcp_flag_expr"
        add_ipv4_rule "$ipv4_full_cond"
    fi
    
    if (( has_ipv6 )); then
        local ipv6_full_cond="$common_cond"
        if [[ -n "$proto_v6" && "$proto_v6" != "all" ]]; then
            case "$proto_v6" in
                tcp) ipv6_full_cond="$ipv6_full_cond meta l4proto tcp" ;;
                udp) ipv6_full_cond="$ipv6_full_cond meta l4proto udp" ;;
                tcp_udp) ipv6_full_cond="$ipv6_full_cond meta l4proto { tcp, udp }" ;;
                icmp|icmpv6|gre|esp|ah|sctp|dccp|udplite) ipv6_full_cond="$ipv6_full_cond meta l4proto $proto_v6" ;;
                all|"") ;;
                *) ipv6_full_cond="$ipv6_full_cond meta l4proto $proto_v6" ;;
            esac
        fi
        [[ -n "$src_ipv6_cond" ]] && ipv6_full_cond="$ipv6_full_cond $src_ipv6_cond"
        [[ -n "$dst_ipv6_cond" ]] && ipv6_full_cond="$ipv6_full_cond $dst_ipv6_cond"
        if [[ -n "$dscp" ]]; then
            local dscp_val="$dscp"
            local neg=""
            [[ "$dscp_val" == "!="* ]] && { neg="!="; dscp_val="${dscp_val#!=}"; }
            ipv6_full_cond="$ipv6_full_cond ip6 dscp $neg $dscp_val"
        fi
        if [[ -n "$ttl" ]]; then
            local hop_val="$ttl"
            if [[ "$hop_val" =~ ^([<>]=?|!=)[0-9]+$ ]]; then
                local operator="${hop_val%%[0-9]*}"
                local num="${hop_val##*[!0-9]}"
                local nft_op=""
                case "$operator" in
                    ">") nft_op="gt" ;;
                    ">=") nft_op="ge" ;;
                    "<") nft_op="lt" ;;
                    "<=") nft_op="le" ;;
                    "!=") nft_op="ne" ;;
                    "=")  nft_op="eq" ;;
                    *)   nft_op="$operator" ;;
                esac
                ipv6_full_cond="$ipv6_full_cond ip6 hoplimit $nft_op $num"
            else
                ipv6_full_cond="$ipv6_full_cond ip6 hoplimit eq $hop_val"
            fi
        fi
        [[ -n "$icmp_v6_cond" ]] && ipv6_full_cond="$ipv6_full_cond $icmp_v6_cond"
        [[ -n "$tcp_flag_expr" ]] && ipv6_full_cond="$ipv6_full_cond $tcp_flag_expr"
        add_ipv6_rule "$ipv6_full_cond"
    fi
    
    for rule in "${ipv4_rules[@]}"; do
        echo "$rule"
    done
    for rule in "${ipv6_rules[@]}"; do
        echo "$rule"
    done
}

# 辅助函数：构建 ICMP 条件
build_icmp_cond() {
    local icmp_val="$1"
    local cond=""
    local neg=""
    [[ "$icmp_val" == "!="* ]] && { neg="!="; icmp_val="${icmp_val#!=}"; }
    if [[ "$icmp_val" == */* ]]; then
        local type="${icmp_val%/*}" code="${icmp_val#*/}"
        if [[ -n "$neg" ]]; then
            cond="(icmp type != $type) and (icmp code != $code)"
        else
            cond="icmp type $type icmp code $code"
        fi
    else
        cond="icmp type $neg $icmp_val"
    fi
    echo "$cond"
}

# ========== DSCP 映射函数（根据 diffserv 模式） ==========
map_priority_to_dscp() {
    local priority="$1"
    local mode="${2:-diffserv4}"
    case "$mode" in
        diffserv8)
            case "$priority" in
                1) echo 46 ;;
                2) echo 34 ;;
                3) echo 26 ;;
                4) echo 18 ;;
                5) echo 10 ;;
                6) echo 0  ;;
                7) echo 8  ;;
                8) echo 16 ;;
                *) echo 0 ;;
            esac
            ;;
        diffserv4|*)
            case "$priority" in
                1) echo 46 ;;
                2) echo 0  ;;
                3) echo 8  ;;
                *) echo 0 ;;
            esac
            ;;
    esac
}

# ========== 获取 CAKE diffserv 模式 ==========
get_cake_diffserv_mode() {
    local mode
    mode=$(uci -q get ${CONFIG_FILE}.cake.diffserv_mode 2>/dev/null)
    case "$mode" in
        diffserv3|diffserv4|diffserv5|diffserv8|besteffort)
            echo "$mode"
            ;;
        *)
            echo "diffserv4"
            ;;
    esac
}

# ========== class_mark 映射设置 ==========
setup_class_mark_map() {
    qos_log "信息" "设置 class_mark 映射（map 方式）..."
    
    # ========== 新增：检查 CAKE wash 冲突 ==========
    local cake_wash=$(uci -q get ${CONFIG_FILE}.cake.wash 2>/dev/null)
    if [[ "$cake_wash" == "1" ]] || [[ "$cake_wash" == "yes" ]] || [[ "$cake_wash" == "true" ]]; then
        qos_log "WARN" "CAKE wash 已启用，将清除数据包中的 DSCP 字段。DSCP 映射设置的 DSCP 可能被覆盖，建议设置 cake.wash=0 或确认预期行为。"
    fi
    
    local tmp_nft_file=$(mktemp)
    register_temp_file "$tmp_nft_file"

    cat << EOF >> "$tmp_nft_file"
delete map inet ${NFT_TABLE} class_mark 2>/dev/null
add map inet ${NFT_TABLE} class_mark { type mark : dscp; }
EOF

    config_load "$CONFIG_FILE"
    local diffserv_mode=$(get_cake_diffserv_mode)

    local elements=""
    while IFS=: read -r dir cls mark_raw; do
        [ -z "$dir" ] || [ -z "$cls" ] && continue
        local cls_clean=$(echo "$cls" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
        local mark="${mark_raw%%#*}"
        mark=$(echo "$mark" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$mark" ] && continue

        local dscp_raw=$(uci -q get "${CONFIG_FILE}.${cls_clean}.dscp" 2>/dev/null)
        local dscp=$(echo "$dscp_raw" | tr -d '\r' | tr -d '[:space:]')
        if [ -z "$dscp" ]; then
            local priority=$(uci -q get "${CONFIG_FILE}.${cls_clean}.priority" 2>/dev/null)
            if ! echo "$priority" | grep -qE '^[0-9]+$' || [ "$priority" -lt 1 ] 2>/dev/null; then
                priority=2
            fi
            dscp=$(map_priority_to_dscp "$priority" "$diffserv_mode")
            qos_log "调试" "类别 $cls_clean 未配置 DSCP，根据优先级 $priority 自动映射为 $dscp (模式 $diffserv_mode)"
        else
            if ! [ "$dscp" -ge 0 ] 2>/dev/null || ! [ "$dscp" -le 63 ] 2>/dev/null; then
                dscp=0
            fi
        fi

        elements="${elements}${elements:+, }${mark} : $dscp"
        qos_log "调试" "收集映射: 标记 $mark -> DSCP $dscp (类 $cls_clean)"
    done < "$CLASS_MARKS_FILE"

    if [ -n "$elements" ]; then
        echo "add element inet ${NFT_TABLE} class_mark { $elements }" >> "$tmp_nft_file"
    fi

    cat << EOF >> "$tmp_nft_file"
# DSCP mapping rules
add rule inet ${NFT_TABLE} filter_qos_egress ct mark != 0 ip dscp set @class_mark[ct mark]
add rule inet ${NFT_TABLE} filter_qos_egress ct mark != 0 ip6 dscp set @class_mark[ct mark]
add rule inet ${NFT_TABLE} filter_qos_ingress ct mark != 0 ip dscp set @class_mark[ct mark]
add rule inet ${NFT_TABLE} filter_qos_ingress ct mark != 0 ip6 dscp set @class_mark[ct mark]
add rule inet ${NFT_TABLE} filter_qos_egress ct state established,related ct mark != 0 ip dscp set @class_mark[ct mark]
add rule inet ${NFT_TABLE} filter_qos_egress ct state established,related ct mark != 0 ip6 dscp set @class_mark[ct mark]
add rule inet ${NFT_TABLE} filter_qos_ingress ct state established,related ct mark != 0 ip dscp set @class_mark[ct mark]
add rule inet ${NFT_TABLE} filter_qos_ingress ct state established,related ct mark != 0 ip6 dscp set @class_mark[ct mark]
EOF

    if nft -f "$tmp_nft_file" 2>&1 | logger -t qos_gargoyle; then
        qos_log "信息" "class_mark map 规则加载成功"
        rm -f "$tmp_nft_file"
        return 0
    else
        qos_log "错误" "加载 class_mark map 规则失败"
        cat "$tmp_nft_file" | logger -t qos_gargoyle
        rm -f "$tmp_nft_file"
        return 1
    fi
}

# ========== 增强规则应用（无笛卡尔积展开） ==========
apply_enhanced_direction_rules() {
    local rule_type="$1" chain="$2" mask="$3"
    qos_log "INFO" "应用增强$rule_type规则到链: $chain, 掩码: $mask"
    nft add chain inet ${NFT_TABLE} "$chain" 2>/dev/null || true
    nft flush chain inet ${NFT_TABLE} "$chain" 2>/dev/null || true
    local direction=""
    [[ "$chain" == "filter_qos_egress" ]] && direction="upload"
    [[ "$chain" == "filter_qos_ingress" ]] && direction="download"
    local rule_list=$(load_all_config_sections "$CONFIG_FILE" "$rule_type")
    [[ -z "$rule_list" ]] && { qos_log "INFO" "未找到$rule_type规则配置"; return 0; }
    qos_log "INFO" "找到$rule_type规则: $rule_list"
    declare -A class_priority_map
    local class_list=""
    [[ "$direction" == "upload" ]] && class_list="$upload_class_list"
    [[ "$direction" == "download" ]] && class_list="$download_class_list"
    for class in $class_list; do
        local prio=$(uci -q get ${CONFIG_FILE}.${class}.priority 2>/dev/null)
        class_priority_map["$class"]=${prio:-999}
    done
    local rule_prio_file=$(mktemp)
    register_temp_file "$rule_prio_file"
    local rule
    for rule in $rule_list; do
        [[ -n "$rule" ]] || continue
        if load_all_config_options "$CONFIG_FILE" "$rule" "tmp_"; then
            [[ "$tmp_enabled" != "1" ]] && continue
            local class_priority=${class_priority_map["$tmp_class"]:-999}
            local rule_order=${tmp_order:-100}
            echo "$class_priority $rule_order $rule" >> "$rule_prio_file"
        fi
    done
    local sorted_rule_list=$(sort -n -k1,1 -k2,2 "$rule_prio_file" | awk '{print $3}' | tr '\n' ' ')
    rm -f "$rule_prio_file"
    if [[ -z "$sorted_rule_list" ]]; then
        qos_log "INFO" "没有可用的启用规则"
        return 0
    fi

    # ========== 移除全局集合检查，改为在生成规则时逐条检查 ==========
    local nft_batch_file=$(mktemp /tmp/qos_nft_batch_XXXXXX)
    register_temp_file "$nft_batch_file"
    qos_log "INFO" "按优先级顺序生成nft规则（使用集合，避免展开）..."
    local rule_count=0
    for rule_name in $sorted_rule_list; do
        if ! load_all_config_options "$CONFIG_FILE" "$rule_name" "tmp_"; then
            continue
        fi
        [[ "$tmp_enabled" == "1" ]] || continue

        if [[ -z "$tmp_class" ]]; then
            qos_log "WARN" "规则 $rule_name 缺少 class 参数，跳过"
            continue
        fi

        local class_mark=$(get_class_mark "$direction" "$tmp_class")
        if [[ -z "$class_mark" ]]; then
            qos_log "ERROR" "规则 $rule_name 的类 $tmp_class 无法获取标记，跳过"
            continue
        fi

        # ========== 新增：检查该规则引用的集合是否存在 ==========
        local rule_sets=""
        for field in src_ip dest_ip; do
            local var_name="tmp_${field}"
            local val=${!var_name}
            [[ -z "$val" ]] && continue
            [[ "$val" == "!="* ]] && val="${val#!=}"
            if [[ "$val" == @* ]]; then
                local setname="${val#@}"
                rule_sets="$rule_sets $setname"
            fi
        done

        local missing_set=""
        for setname in $rule_sets; do
            if ! nft list set inet ${NFT_TABLE} "$setname" &>/dev/null; then
                missing_set="$setname"
                break
            fi
        done
        if [[ -n "$missing_set" ]]; then
            qos_log "WARN" "规则 $rule_name 引用了不存在的集合 @$missing_set，已跳过该规则"
            continue
        fi
        # ========== 集合检查结束 ==========

        [[ -z "$tmp_family" ]] && tmp_family="inet"
        # 直接调用构建函数，所有多值字段在函数内处理为集合
        build_nft_rule_generic "$rule_name" "$chain" "$class_mark" "$tmp_family" "$tmp_proto" \
            "$tmp_srcport" "$tmp_dstport" "$tmp_connbytes_kb" "$tmp_state" "$tmp_src_ip" "$tmp_dest_ip" \
            "$tmp_packet_len" "$tmp_tcp_flags" "$tmp_iif" "$tmp_oif" "$tmp_udp_length" \
            "$tmp_dscp" "$tmp_ttl" "$tmp_icmp_type" >> "$nft_batch_file"
        ((rule_count++))
    done

    local custom_file=""
    if [[ "$chain" == "filter_qos_egress" ]]; then
        custom_file="/etc/qos_gargoyle/egress_custom.nft"
    else
        custom_file="/etc/qos_gargoyle/ingress_custom.nft"
    fi
    if [[ -s "$custom_file" ]]; then
        qos_log "INFO" "验证自定义规则: $custom_file"
        local check_file=$(mktemp)
        register_temp_file "$check_file"
        {
            printf '%s\n\t%s\n' "table inet __qos_custom_check {" "chain __temp_chain {"
            cat "$custom_file"
            printf '\n\t%s\n%s\n' "}" "}"
        } > "$check_file"
        if nft --check --file "$check_file" 2>/dev/null; then
            qos_log "INFO" "自定义规则语法正确: $custom_file"
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line#"${line%%[![:space:]]*}"}"
                line="${line%"${line##*[![:space:]]}"}"
                [[ -z "$line" || "$line" == \#* ]] && continue
                echo "add rule inet ${NFT_TABLE} $chain $line" >> "$nft_batch_file"
                ((rule_count++))
            done < "$custom_file"
        else
            qos_log "WARN" "自定义规则文件 $custom_file 语法错误，已忽略"
            nft --check --file "$check_file" 2>&1 | while IFS= read -r err; do
                qos_log "ERROR" "nft语法错误: $err"
            done
        fi
        rm -f "$check_file"
    fi

    local batch_success=0
    if [[ -s "$nft_batch_file" ]]; then
        qos_log "INFO" "执行批量nft规则语法检查 (共 $rule_count 条)..."
        local check_output
        if check_output=$(nft --check --file "$nft_batch_file" 2>&1); then
            qos_log "INFO" "语法检查通过，开始应用规则..."
            local nft_output
            nft_output=$(nft -f "$nft_batch_file" 2>&1)
            local nft_ret=$?
            if [[ $nft_ret -eq 0 ]]; then
                qos_log "INFO" "✅ 批量规则应用成功"
                if [[ $SAVE_NFT_RULES -eq 1 ]]; then
                    mkdir -p /etc/nftables.d
                    local nft_save_file="/etc/nftables.d/qos_gargoyle_${chain}.nft"
                    cp "$nft_batch_file" "$nft_save_file"
                    qos_log "INFO" "规则已保存到 $nft_save_file"
                fi
            else
                qos_log "ERROR" "❌ 批量规则应用失败 (退出码: $nft_ret)"
                qos_log "ERROR" "nft 错误输出: $nft_output"
                batch_success=1
            fi
        else
            qos_log "ERROR" "❌ 批量规则语法检查失败，无法应用规则"
            qos_log "ERROR" "检查错误: $check_output"
            batch_success=1
        fi
    else
        qos_log "INFO" "没有生成任何规则，跳过应用"
    fi
    rm -f "$nft_batch_file"
    return $batch_success
}

# ========== ACK 限速规则（新语法，支持连接级，ip级和两者混合） ==========
setup_ack_limit_sets() {
    [[ $ENABLE_ACK_LIMIT != 1 ]] && return

    local ack_enabled=$(uci -q get ${CONFIG_FILE}.ack_limit.enabled 2>/dev/null)
    case "$ack_enabled" in 1|yes|true|on) ;; *) return ;; esac

    # 读取粒度配置
    local granularity=$(uci -q get ${CONFIG_FILE}.ack_limit.granularity 2>/dev/null)
    case "$granularity" in
        ip)   granularity="ip" ;;
        both) granularity="both" ;;
        *)    granularity="conn" ;;
    esac
    qos_log "INFO" "ACK 限速粒度: $granularity，正在创建动态集合..."

    # 定义所有可能的 ACK 集合名称（用于清理）
    local all_rates="xfst fast med slow"
    local all_sets=""
    for rate in $all_rates; do
        all_sets="$all_sets qos_${rate}_ack qos_${rate}_ack_v4 qos_${rate}_ack_v6"
    done

    # 删除所有可能存在的旧集合
    for setname in $all_sets; do
        nft delete set inet ${NFT_TABLE} "$setname" 2>/dev/null || true
    done

    # 根据粒度创建新集合
    local ack_failed=0
    local set_flags="flags dynamic; timeout 30s;"

    for rate in $all_rates; do
        case "$granularity" in
            ip)
                # IPv4 集合
                nft add set inet ${NFT_TABLE} qos_${rate}_ack_v4 "{ typeof ip saddr; $set_flags }" 2>/dev/null || {
                    qos_log "ERROR" "无法创建 IPv4 ACK 限速集合 qos_${rate}_ack_v4"
                    ack_failed=1
                }
                # IPv6 集合
                nft add set inet ${NFT_TABLE} qos_${rate}_ack_v6 "{ typeof ip6 saddr; $set_flags }" 2>/dev/null || {
                    qos_log "ERROR" "无法创建 IPv6 ACK 限速集合 qos_${rate}_ack_v6"
                    ack_failed=1
                }
                ;;
            both)
                # 复合键 IPv4
                nft add set inet ${NFT_TABLE} qos_${rate}_ack_v4 "{ typeof ip saddr . ct id . ct direction; $set_flags }" 2>/dev/null || {
                    qos_log "ERROR" "无法创建复合键 IPv4 ACK 限速集合 qos_${rate}_ack_v4"
                    ack_failed=1
                }
                # 复合键 IPv6
                nft add set inet ${NFT_TABLE} qos_${rate}_ack_v6 "{ typeof ip6 saddr . ct id . ct direction; $set_flags }" 2>/dev/null || {
                    qos_log "ERROR" "无法创建复合键 IPv6 ACK 限速集合 qos_${rate}_ack_v6"
                    ack_failed=1
                }
                ;;
            conn)
                # 连接级（通用，键与地址族无关）
                nft add set inet ${NFT_TABLE} qos_${rate}_ack "{ typeof ct id . ct direction; $set_flags }" 2>/dev/null || {
                    qos_log "ERROR" "无法创建连接级 ACK 限速集合 qos_${rate}_ack"
                    ack_failed=1
                }
                ;;
        esac
    done

    if [[ $ack_failed -eq 1 ]]; then
        qos_log "ERROR" "ACK 限速集合创建失败，功能将被禁用"
        ENABLE_ACK_LIMIT=0
    else
        qos_log "INFO" "ACK 限速集合创建成功"
    fi
}

generate_ack_limit_rules() {
    [[ $ENABLE_ACK_LIMIT != 1 ]] && return

    local ack_enabled=$(uci -q get ${CONFIG_FILE}.ack_limit.enabled 2>/dev/null)
    case "$ack_enabled" in 1|yes|true|on) ;; *) return ;; esac

    # 读取并验证速率
    local slow_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.slow_rate 2>/dev/null)
    local med_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.med_rate 2>/dev/null)
    local fast_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.fast_rate 2>/dev/null)
    local xfast_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.xfast_rate 2>/dev/null)

    if ! validate_number "$slow_rate" "ack_limit.slow_rate" 1 100000 2>/dev/null; then
        slow_rate=50
        qos_log "WARN" "ACK slow_rate 无效，使用默认值 50"
    fi
    if ! validate_number "$med_rate" "ack_limit.med_rate" 1 100000 2>/dev/null; then
        med_rate=100
        qos_log "WARN" "ACK med_rate 无效，使用默认值 100"
    fi
    if ! validate_number "$fast_rate" "ack_limit.fast_rate" 1 100000 2>/dev/null; then
        fast_rate=500
        qos_log "WARN" "ACK fast_rate 无效，使用默认值 500"
    fi
    if ! validate_number "$xfast_rate" "ack_limit.xfast_rate" 1 100000 2>/dev/null; then
        xfast_rate=5000
        qos_log "WARN" "ACK xfast_rate 无效，使用默认值 5000"
    fi

    # 读取粒度
    local granularity=$(uci -q get ${CONFIG_FILE}.ack_limit.granularity 2>/dev/null)
    case "$granularity" in
        ip)   granularity="ip" ;;
        both) granularity="both" ;;
        *)    granularity="conn" ;;
    esac

    # 辅助函数：生成一组 ACK 限速规则（四个级别）
    generate_ack_rules_for_family() {
        local family="$1"          # "ip" / "ip6" / ""（通用）
        local set_suffix="$2"     # "_v4" / "_v6" / ""（集合名称后缀）
        local key_expr="$3"       # 键表达式（如 ip saddr）

        local addr_match=""
        if [[ "$family" == "ip" ]]; then
            addr_match="meta nfproto ipv4"
        elif [[ "$family" == "ip6" ]]; then
            addr_match="meta nfproto ipv6"
        fi

        local final_key="$key_expr"
        # 为 IPv6 适配键中的地址字段
        if [[ "$family" == "ip6" && "$key_expr" == *"ip saddr"* ]]; then
            final_key="${key_expr/ip saddr/ip6 saddr}"
        fi

        cat <<EOF
# ACK rate limiting - xfst (extreme fast)
add rule inet ${NFT_TABLE} filter_qos_egress $addr_match meta length < 100 tcp flags ack \
    $final_key limit rate over ${xfast_rate}/second \
    update @qos_xfst_ack${set_suffix} { $final_key } counter jump drop995

# fast
add rule inet ${NFT_TABLE} filter_qos_egress $addr_match meta length < 100 tcp flags ack \
    $final_key limit rate over ${fast_rate}/second \
    update @qos_fast_ack${set_suffix} { $final_key } counter jump drop95

# medium
add rule inet ${NFT_TABLE} filter_qos_egress $addr_match meta length < 100 tcp flags ack \
    $final_key limit rate over ${med_rate}/second \
    update @qos_med_ack${set_suffix} { $final_key } counter jump drop50

# slow
add rule inet ${NFT_TABLE} filter_qos_egress $addr_match meta length < 100 tcp flags ack \
    $final_key limit rate over ${slow_rate}/second \
    update @qos_slow_ack${set_suffix} { $final_key } counter jump drop50
EOF
    }

    # 根据粒度生成规则
    case "$granularity" in
        conn)
            generate_ack_rules_for_family "" "" "ct id . ct direction"
            ;;
        ip)
            generate_ack_rules_for_family "ip" "_v4" "ip saddr"
            generate_ack_rules_for_family "ip6" "_v6" "ip6 saddr"
            ;;
        both)
            generate_ack_rules_for_family "ip" "_v4" "ip saddr . ct id . ct direction"
            generate_ack_rules_for_family "ip6" "_v6" "ip6 saddr . ct id . ct direction"
            ;;
    esac
}

# ========== TCP 升级规则 （采用官方新语法）==========
generate_tcp_upgrade_rules() {
    local tcp_enabled=$(uci -q get ${CONFIG_FILE}.tcp_upgrade.enabled 2>/dev/null)
    case "$tcp_enabled" in 1|yes|true|on) ;; *) return ;; esac

    # 检查集合是否存在
    if ! nft list set inet ${NFT_TABLE} qos_slow_tcp &>/dev/null; then
        qos_log "WARN" "TCP 升级所需集合 qos_slow_tcp 不存在，功能已禁用"
        return
    fi

    local rate=$(uci -q get ${CONFIG_FILE}.tcp_upgrade.rate 2>/dev/null)
    local burst=$(uci -q get ${CONFIG_FILE}.tcp_upgrade.burst 2>/dev/null)

    if ! validate_number "$rate" "tcp_upgrade.rate" 1 1000000 2>/dev/null; then
        rate=150
        qos_log "WARN" "TCP upgrade rate 无效，使用默认值 150"
    fi
    if ! validate_number "$burst" "tcp_upgrade.burst" 1 1000000 2>/dev/null; then
        burst=150
        qos_log "WARN" "TCP upgrade burst 无效，使用默认值 150"
    fi

    local highest_class=$(get_highest_priority_class "upload")
    if [[ -z "$highest_class" ]]; then
        log_warn "TCP升级：未找到任何启用的上传类，将禁用此功能"
        return
    fi

    local class_mark=$(get_class_mark "upload" "$highest_class" 2>/dev/null)
    if [[ -z "$class_mark" || "$class_mark" == "0" || "$class_mark" == "0x0" ]]; then
        log_error "TCP升级：类 $highest_class 的标记无效（值为 $class_mark），跳过规则生成"
        return
    fi

    cat <<EOF
# TCP upgrade for connections exceeding rate (per-connection)
add rule inet ${NFT_TABLE} filter_qos_egress meta l4proto tcp ct state established meta nfproto ipv4 \
    ct id . ct direction limit rate over ${rate}/second burst ${burst} packets \
    update @qos_slow_tcp { ct id . ct direction } \
    meta mark set $class_mark ct mark set meta mark counter
add rule inet ${NFT_TABLE} filter_qos_egress meta l4proto tcp ct state established meta nfproto ipv6 \
    ct id . ct direction limit rate over ${rate}/second burst ${burst} packets \
    update @qos_slow_tcp { ct id . ct direction } \
    meta mark set $class_mark ct mark set meta mark counter
EOF
}

# ========== UDP 限速规则（采用官方新语法，默认 mark，增加有效性检查） ==========
# ========== UDP 限速规则（采用官方新语法，默认 mark，增加有效性检查） ==========
generate_udp_limit_rules() {
    local udp_enable=$(uci -q get ${CONFIG_FILE}.udp_limit.enabled 2>/dev/null)
    local udp_rate=$(uci -q get ${CONFIG_FILE}.udp_limit.rate 2>/dev/null)
    local udp_action=$(uci -q get ${CONFIG_FILE}.udp_limit.action 2>/dev/null)
    local udp_mark_class=$(uci -q get ${CONFIG_FILE}.udp_limit.mark_class 2>/dev/null)

    case "$udp_enable" in 1|yes|true|on) udp_enable=1 ;; *) udp_enable=0 ;; esac

    if [[ "$udp_enable" != "1" ]]; then
        return
    fi

    if ! validate_number "$udp_rate" "udp_limit.rate" 1 1000000 2>/dev/null; then
        qos_log "WARN" "UDP 速率值无效，使用默认 450"
        udp_rate=450
    fi

    # 默认 action 为 mark
    if [[ -z "$udp_action" ]]; then
        udp_action="mark"
    fi
    if [[ "$udp_action" != "mark" ]] && [[ "$udp_action" != "drop" ]]; then
        qos_log "WARN" "UDP 限速 action '$udp_action' 无效，使用默认 mark"
        udp_action="mark"
    fi
    if [[ "$udp_action" == "drop" ]]; then
        qos_log "WARN" "UDP 限速 action 配置为 drop，可能导致关键服务中断，建议使用 mark"
    fi

    [[ -z "$udp_mark_class" ]] && udp_mark_class="bulk"

    local wan_if="${qos_interface:-$(uci -q get ${CONFIG_FILE}.global.wan_interface 2>/dev/null)}"
    if [[ -z "$wan_if" ]]; then
        qos_log "WARN" "无法确定 WAN 接口，UDP 速率限制规则将被跳过"
        return
    fi

    local lower_mark_class=$(echo "$udp_mark_class" | tr '[:upper:]' '[:lower:]')
    local upload_mark="" download_mark=""

    if [[ "$udp_action" == "mark" ]]; then
        if [[ -z "$upload_class_list" ]]; then
            load_upload_class_configurations
        fi
        if [[ -z "$download_class_list" ]]; then
            load_download_class_configurations
        fi

        for class in $upload_class_list; do
            local class_display=$(uci -q get ${CONFIG_FILE}.${class}.name 2>/dev/null)
            [[ -z "$class_display" ]] && class_display="$class"
            class_display=$(echo "$class_display" | tr '[:upper:]' '[:lower:]')
            if [[ "$class_display" == "$lower_mark_class" ]]; then
                upload_mark=$(get_class_mark "upload" "$class")
                break
            fi
        done

        for class in $download_class_list; do
            local class_display=$(uci -q get ${CONFIG_FILE}.${class}.name 2>/dev/null)
            [[ -z "$class_display" ]] && class_display="$class"
            class_display=$(echo "$class_display" | tr '[:upper:]' '[:lower:]')
            if [[ "$class_display" == "$lower_mark_class" ]]; then
                download_mark=$(get_class_mark "download" "$class")
                break
            fi
        done

        if [[ -z "$upload_mark" ]] || [[ -z "$download_mark" ]]; then
            qos_log "ERROR" "UDP 限速目标类 '$udp_mark_class' 未同时存在于上传/下载类中，无法启用 mark 动作。请检查类名或改用 drop 动作。"
            return
        fi
    fi

    local rules=""
    if [[ "$udp_action" == "mark" ]] && [[ -n "$upload_mark" ]] && [[ -n "$download_mark" ]]; then
        rules="${rules}
# UDP per-IP rate limit - upload direction (mark)
add rule inet ${NFT_TABLE} filter_qos_egress oifname \"$wan_if\" meta l4proto udp ct mark == 0 \
    ip saddr limit rate over ${udp_rate}/second \
    update @udp_per_ip_upload { ip saddr } counter \
    meta mark set $upload_mark ct mark set $upload_mark
add rule inet ${NFT_TABLE} filter_qos_egress oifname \"$wan_if\" meta l4proto udp ct mark == 0 \
    ip6 saddr limit rate over ${udp_rate}/second \
    update @udp_per_ip_upload_v6 { ip6 saddr } counter \
    meta mark set $upload_mark ct mark set $upload_mark

# UDP per-IP rate limit - download direction (mark)
add rule inet ${NFT_TABLE} filter_qos_ingress iifname \"$wan_if\" meta l4proto udp ct mark == 0 \
    ip daddr limit rate over ${udp_rate}/second \
    update @udp_per_ip_download { ip daddr } counter \
    meta mark set $download_mark ct mark set $download_mark
add rule inet ${NFT_TABLE} filter_qos_ingress iifname \"$wan_if\" meta l4proto udp ct mark == 0 \
    ip6 daddr limit rate over ${udp_rate}/second \
    update @udp_per_ip_download_v6 { ip6 daddr } counter \
    meta mark set $download_mark ct mark set $download_mark"
    elif [[ "$udp_action" == "drop" ]]; then
        rules="${rules}
# UDP per-IP rate limit - drop (upload)
add rule inet ${NFT_TABLE} filter_qos_egress oifname \"$wan_if\" meta l4proto udp ct mark == 0 \
    ip saddr limit rate over ${udp_rate}/second drop
add rule inet ${NFT_TABLE} filter_qos_egress oifname \"$wan_if\" meta l4proto udp ct mark == 0 \
    ip6 saddr limit rate over ${udp_rate}/second drop

# UDP per-IP rate limit - drop (download)
add rule inet ${NFT_TABLE} filter_qos_ingress iifname \"$wan_if\" meta l4proto udp ct mark == 0 \
    ip daddr limit rate over ${udp_rate}/second drop
add rule inet ${NFT_TABLE} filter_qos_ingress iifname \"$wan_if\" meta l4proto udp ct mark == 0 \
    ip6 daddr limit rate over ${udp_rate}/second drop"
    fi

    echo "$rules"
}

# ========== 动态检测函数 ==========
check_meter_support() {
    # 使用缓存结果
    if [[ $METER_SUPPORT_CHECKED -eq 1 ]]; then
        return $METER_SUPPORT_AVAILABLE
    fi
    
    local test_file=$(mktemp)
    register_temp_file "$test_file"
    cat > "$test_file" <<EOF
add table inet qos_meter_test
add set inet qos_meter_test meter_test_set { type ipv4_addr . inet_service . inet_proto; flags timeout; }
add chain inet qos_meter_test meter_test_chain
add rule inet qos_meter_test meter_test_chain meter meter_test { ip daddr . th dport . meta l4proto timeout 5s } limit rate over 1/minute add @meter_test_set { ip daddr . th dport . meta l4proto timeout 30s }
EOF
    if nft -c -f "$test_file" 2>/dev/null; then
        nft delete table inet qos_meter_test 2>/dev/null
        rm -f "$test_file"
        METER_SUPPORT_CHECKED=1
        METER_SUPPORT_AVAILABLE=1
        return 0
    else
        if [[ "$DEBUG" == "1" ]]; then
            local error_output=$(nft -c -f "$test_file" 2>&1)
            log_debug "meter 支持检测失败: $error_output"
        fi
        nft delete table inet qos_meter_test 2>/dev/null
        rm -f "$test_file"
        METER_SUPPORT_CHECKED=1
        METER_SUPPORT_AVAILABLE=0
        return 1
    fi
}

cleanup_dynamic_detection() {
    nft delete set inet ${NFT_TABLE} qos_bulk_clients 2>/dev/null || true
    nft delete set inet ${NFT_TABLE} qos_bulk_clients6 2>/dev/null || true
    nft delete chain inet ${NFT_TABLE} qos_bulk_client 2>/dev/null || true
    nft delete chain inet ${NFT_TABLE} qos_bulk_client_reply 2>/dev/null || true
    nft delete chain inet ${NFT_TABLE} qos_dynamic_classify 2>/dev/null || true
    nft delete chain inet ${NFT_TABLE} qos_dynamic_classify_reply 2>/dev/null || true
    nft delete chain inet ${NFT_TABLE} qos_established_connection 2>/dev/null || true
    nft delete chain inet ${NFT_TABLE} qos_high_throughput_service 2>/dev/null || true
    nft delete chain inet ${NFT_TABLE} qos_high_throughput_service_reply 2>/dev/null || true
    nft delete set inet ${NFT_TABLE} qos_high_throughput_services 2>/dev/null || true
    nft delete set inet ${NFT_TABLE} qos_high_throughput_services6 2>/dev/null || true
}

# ========== 批量客户端检测（修复 meter 语法，增加支持检测） ==========
create_bulk_client_rules() {
    local enabled=1 min_bytes=10000 min_connections=10 class="bulk"
    local bulk_section="bulk_detect"  # 先定义变量
    
    # 检查 meter 支持
    if ! check_meter_support; then
        qos_log "WARN" "内核不支持 nftables meter 关键字，动态分类 '$bulk_section' 功能已禁用"
        return 0
    fi
    
    local uci_enabled=$(uci -q get ${CONFIG_FILE}.${bulk_section}.enabled 2>/dev/null)
    [ -n "$uci_enabled" ] && enabled="$uci_enabled"
    local uci_min_bytes=$(uci -q get ${CONFIG_FILE}.${bulk_section}.min_bytes 2>/dev/null)
    [ -n "$uci_min_bytes" ] && min_bytes="$uci_min_bytes"
    local uci_min_connections=$(uci -q get ${CONFIG_FILE}.${bulk_section}.min_connections 2>/dev/null)
    [ -n "$uci_min_connections" ] && min_connections="$uci_min_connections"
    local uci_class=$(uci -q get ${CONFIG_FILE}.${bulk_section}.class 2>/dev/null)
    [ -n "$uci_class" ] && class="$uci_class"

    [ "$enabled" != "1" ] && return 0
    if ! validate_number "$min_bytes" "bulk_detect.min_bytes" 1 1000000000 2>/dev/null; then
        qos_log "WARN" "min_bytes 无效，使用默认值 10000"
        min_bytes=10000
    fi
    if ! validate_number "$min_connections" "bulk_detect.min_connections" 1 10000 2>/dev/null; then
        qos_log "WARN" "min_connections 无效，使用默认值 10"
        min_connections=10
    fi
    
    local upload_mark="" download_mark=""
    if [[ -n "$uci_class" ]]; then
        upload_mark=$(get_class_mark "upload" "$uci_class" 2>/dev/null)
        download_mark=$(get_class_mark "download" "$uci_class" 2>/dev/null)
        if [[ -z "$upload_mark" ]] && [[ -z "$download_mark" ]]; then
            qos_log "警告" "批量客户端检测: 用户指定的类 '$uci_class' 不存在，将自动选择优先级最低的类"
            upload_mark=""
            download_mark=""
        else
            qos_log "信息" "批量客户端检测: 使用用户指定的类 '$uci_class' (上传标记=$upload_mark, 下载标记=$download_mark)"
        fi
    fi
    if [[ -z "$upload_mark" ]]; then
        local lowest_upload_mark=$(get_min_max_mark "upload" "min")
        if [[ -n "$lowest_upload_mark" && "$lowest_upload_mark" -ne 0 ]]; then
            upload_mark="$lowest_upload_mark"
            qos_log "信息" "批量客户端检测: 自动使用上传方向最小标记 $upload_mark (对应最低优先级类)"
        else
            upload_mark=8
            qos_log "警告" "批量客户端检测: 未找到有效上传标记，使用回退标记 $upload_mark"
        fi
    fi
    if [[ -z "$download_mark" ]]; then
        local lowest_download_mark=$(get_min_max_mark "download" "min")
        if [[ -n "$lowest_download_mark" && "$lowest_download_mark" -ne 0 ]]; then
            download_mark="$lowest_download_mark"
            qos_log "信息" "批量客户端检测: 自动使用下载方向最小标记 $download_mark (对应最低优先级类)"
        else
            download_mark=65536
            qos_log "警告" "批量客户端检测: 未找到有效下载标记，使用回退标记 $download_mark"
        fi
    fi

    nft add set inet ${NFT_TABLE} qos_bulk_clients '{ type ipv4_addr . inet_service . inet_proto; flags timeout; }' 2>/dev/null || true
    nft add set inet ${NFT_TABLE} qos_bulk_clients6 '{ type ipv6_addr . inet_service . inet_proto; flags timeout; }' 2>/dev/null || true

    nft add chain inet ${NFT_TABLE} qos_established_connection 2>/dev/null || true
    nft add chain inet ${NFT_TABLE} qos_dynamic_classify 2>/dev/null || true
    nft add chain inet ${NFT_TABLE} qos_dynamic_classify_reply 2>/dev/null || true
    nft add chain inet ${NFT_TABLE} qos_bulk_client 2>/dev/null || true
    nft add chain inet ${NFT_TABLE} qos_bulk_client_reply 2>/dev/null || true

    # 建立连接检测（上行）：将源 IP+源端口加入集合（修复 meter 语法）
    nft add rule inet ${NFT_TABLE} qos_established_connection \
        meter qos_bulk_detect { ip saddr . th sport . meta l4proto timeout 5s } \
        limit rate over $((min_connections - 1))/minute \
        add @qos_bulk_clients { ip saddr . th sport . meta l4proto timeout 30s } 2>/dev/null || true

    nft add rule inet ${NFT_TABLE} qos_established_connection \
        meter qos_bulk_detect6 { ip6 saddr . th sport . meta l4proto timeout 5s } \
        limit rate over $((min_connections - 1))/minute \
        add @qos_bulk_clients6 { ip6 saddr . th sport . meta l4proto timeout 30s } 2>/dev/null || true

    # 上行流量：匹配后设置上传标记
    nft add rule inet ${NFT_TABLE} qos_bulk_client \
        ip saddr . th sport . meta l4proto @qos_bulk_clients \
        meta mark set $upload_mark ct mark set $upload_mark return 2>/dev/null || true

    nft add rule inet ${NFT_TABLE} qos_bulk_client \
        ip6 saddr . th sport . meta l4proto @qos_bulk_clients6 \
        meta mark set $upload_mark ct mark set $upload_mark return 2>/dev/null || true

    # 下行流量：匹配后设置下载标记
    nft add rule inet ${NFT_TABLE} qos_bulk_client_reply \
        ip daddr . th dport . meta l4proto @qos_bulk_clients \
        meta mark set $download_mark ct mark set $download_mark return 2>/dev/null || true

    nft add rule inet ${NFT_TABLE} qos_bulk_client_reply \
        ip6 daddr . th dport . meta l4proto @qos_bulk_clients6 \
        meta mark set $download_mark ct mark set $download_mark return 2>/dev/null || true

    # 挂载规则到动态分类链
    nft add rule inet ${NFT_TABLE} qos_dynamic_classify "ct mark == 0" ip saddr . th sport . meta l4proto @qos_bulk_clients goto qos_bulk_client 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} qos_dynamic_classify "ct mark == 0" ip6 saddr . th sport . meta l4proto @qos_bulk_clients6 goto qos_bulk_client 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} qos_dynamic_classify_reply "ct mark == 0" ip daddr . th dport . meta l4proto @qos_bulk_clients goto qos_bulk_client_reply 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} qos_dynamic_classify_reply "ct mark == 0" ip6 daddr . th dport . meta l4proto @qos_bulk_clients6 goto qos_bulk_client_reply 2>/dev/null || true

    qos_log "信息" "批量客户端检测已启用: 最小连接数=$min_connections, 最小字节数=$min_bytes 字节/秒, 上传标记=$upload_mark, 下载标记=$download_mark"
}

# ========== 高吞吐服务检测（修复 meter 语法，增加支持检测） ==========
create_high_throughput_service_rules() {
    local enabled=1 min_bytes=1000000 min_connections=3 class="realtime"
    local htp_section="htp_detect"  # 先定义变量
    
    if ! check_meter_support; then
        qos_log "WARN" "内核不支持 nftables meter 关键字，动态分类 '$htp_section' 功能已禁用"
        return 0
    fi
    
    local uci_enabled=$(uci -q get ${CONFIG_FILE}.${htp_section}.enabled 2>/dev/null)
    [ -n "$uci_enabled" ] && enabled="$uci_enabled"
    local uci_min_bytes=$(uci -q get ${CONFIG_FILE}.${htp_section}.min_bytes 2>/dev/null)
    [ -n "$uci_min_bytes" ] && min_bytes="$uci_min_bytes"
    local uci_min_connections=$(uci -q get ${CONFIG_FILE}.${htp_section}.min_connections 2>/dev/null)
    [ -n "$uci_min_connections" ] && min_connections="$uci_min_connections"
    local uci_class=$(uci -q get ${CONFIG_FILE}.${htp_section}.class 2>/dev/null)
    [ -n "$uci_class" ] && class="$uci_class"

    [ "$enabled" != "1" ] && return 0
    if ! validate_number "$min_bytes" "htp_detect.min_bytes" 1 1000000000 2>/dev/null; then
        qos_log "WARN" "min_bytes 无效，使用默认值 1000000"
        min_bytes=1000000
    fi
    if ! validate_number "$min_connections" "htp_detect.min_connections" 1 10000 2>/dev/null; then
        qos_log "WARN" "min_connections 无效，使用默认值 3"
        min_connections=3
    fi

    local upload_mark="" download_mark=""
    if [[ -n "$uci_class" ]]; then
        upload_mark=$(get_class_mark "upload" "$uci_class" 2>/dev/null)
        download_mark=$(get_class_mark "download" "$uci_class" 2>/dev/null)
        if [[ -z "$upload_mark" ]] && [[ -z "$download_mark" ]]; then
            qos_log "警告" "高吞吐服务检测: 用户指定的类 '$uci_class' 不存在，将自动选择优先级最高的类"
            upload_mark=""
            download_mark=""
        else
            qos_log "信息" "高吞吐服务检测: 使用用户指定的类 '$uci_class' (上传标记=$upload_mark, 下载标记=$download_mark)"
        fi
    fi
    if [[ -z "$upload_mark" ]]; then
        local highest_upload_mark=$(get_min_max_mark "upload" "max")
        if [[ -n "$highest_upload_mark" && "$highest_upload_mark" -ne 0 ]]; then
            upload_mark="$highest_upload_mark"
            qos_log "信息" "高吞吐服务检测: 自动使用上传方向最大标记 $upload_mark (对应最高优先级类)"
        else
            upload_mark=1
            qos_log "警告" "高吞吐服务检测: 未找到有效上传标记，使用回退标记 $upload_mark"
        fi
    fi
    if [[ -z "$download_mark" ]]; then
        local highest_download_mark=$(get_min_max_mark "download" "max")
        if [[ -n "$highest_download_mark" && "$highest_download_mark" -ne 0 ]]; then
            download_mark="$highest_download_mark"
            qos_log "信息" "高吞吐服务检测: 自动使用下载方向最大标记 $download_mark (对应最高优先级类)"
        else
            download_mark=65536
            qos_log "警告" "高吞吐服务检测: 未找到有效下载标记，使用回退标记 $download_mark"
        fi
    fi

    nft add set inet ${NFT_TABLE} qos_high_throughput_services '{ type ipv4_addr . inet_service . inet_proto; flags timeout; }' 2>/dev/null || true
    nft add set inet ${NFT_TABLE} qos_high_throughput_services6 '{ type ipv6_addr . inet_service . inet_proto; flags timeout; }' 2>/dev/null || true

    nft add chain inet ${NFT_TABLE} qos_high_throughput_service 2>/dev/null || true
    nft add chain inet ${NFT_TABLE} qos_high_throughput_service_reply 2>/dev/null || true

    # 建立连接检测：将目的 IP+目的端口加入集合（服务端标识）（修复 meter 语法）
    nft add rule inet ${NFT_TABLE} qos_established_connection \
        meter qos_htp_detect { ip daddr . th dport . meta l4proto timeout 5s } \
        limit rate over $((min_connections - 1))/minute \
        add @qos_high_throughput_services { ip daddr . th dport . meta l4proto timeout 30s } 2>/dev/null || true

    nft add rule inet ${NFT_TABLE} qos_established_connection \
        meter qos_htp_detect6 { ip6 daddr . th dport . meta l4proto timeout 5s } \
        limit rate over $((min_connections - 1))/minute \
        add @qos_high_throughput_services6 { ip6 daddr . th dport . meta l4proto timeout 30s } 2>/dev/null || true

    # 上行流量：匹配目的 IP+端口（服务端）
    nft add rule inet ${NFT_TABLE} qos_high_throughput_service "ct bytes original < $min_bytes return" 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} qos_high_throughput_service \
        ip daddr . th dport . meta l4proto @qos_high_throughput_services \
        meta mark set $upload_mark ct mark set $upload_mark return 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} qos_high_throughput_service \
        ip6 daddr . th dport . meta l4proto @qos_high_throughput_services6 \
        meta mark set $upload_mark ct mark set $upload_mark return 2>/dev/null || true

    # 下行流量：匹配源 IP+端口（服务端）
    nft add rule inet ${NFT_TABLE} qos_high_throughput_service_reply "ct bytes reply < $min_bytes return" 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} qos_high_throughput_service_reply \
        ip saddr . th sport . meta l4proto @qos_high_throughput_services \
        meta mark set $download_mark ct mark set $download_mark return 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} qos_high_throughput_service_reply \
        ip6 saddr . th sport . meta l4proto @qos_high_throughput_services6 \
        meta mark set $download_mark ct mark set $download_mark return 2>/dev/null || true

    # 挂载规则到动态分类链
    nft add rule inet ${NFT_TABLE} qos_dynamic_classify "ct mark == 0" ip daddr . th dport . meta l4proto @qos_high_throughput_services goto qos_high_throughput_service 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} qos_dynamic_classify "ct mark == 0" ip6 daddr . th dport . meta l4proto @qos_high_throughput_services6 goto qos_high_throughput_service 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} qos_dynamic_classify_reply "ct mark == 0" ip saddr . th sport . meta l4proto @qos_high_throughput_services goto qos_high_throughput_service_reply 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} qos_dynamic_classify_reply "ct mark == 0" ip6 saddr . th sport . meta l4proto @qos_high_throughput_services6 goto qos_high_throughput_service_reply 2>/dev/null || true
    
    qos_log "信息" "高吞吐服务检测已启用: 最小连接数=$min_connections, 最小字节数=$min_bytes 字节/秒, 上传标记=$upload_mark, 下载标记=$download_mark"
}

setup_dynamic_classification() {
    qos_log "信息" "初始化动态分类链..."
    nft add chain inet ${NFT_TABLE} qos_established_connection 2>/dev/null || true
    nft add chain inet ${NFT_TABLE} qos_dynamic_classify 2>/dev/null || true
    nft add chain inet ${NFT_TABLE} qos_dynamic_classify_reply 2>/dev/null || true

    nft insert rule inet ${NFT_TABLE} filter_forward ct state established jump qos_established_connection 2>/dev/null || true
    nft insert rule inet ${NFT_TABLE} filter_input ct state established jump qos_established_connection 2>/dev/null || true
    nft insert rule inet ${NFT_TABLE} filter_output ct state established jump qos_established_connection 2>/dev/null || true

    nft insert rule inet ${NFT_TABLE} filter_input "ct mark == 0" jump qos_dynamic_classify 2>/dev/null || true
    nft insert rule inet ${NFT_TABLE} filter_output "ct mark == 0" jump qos_dynamic_classify 2>/dev/null || true
    nft insert rule inet ${NFT_TABLE} filter_forward "ct mark == 0" jump qos_dynamic_classify 2>/dev/null || true
    nft insert rule inet ${NFT_TABLE} filter_forward "ct mark == 0" jump qos_dynamic_classify_reply 2>/dev/null || true

    create_bulk_client_rules
    create_high_throughput_service_rules
}

# ========== 应用所有规则 ==========
apply_all_rules() {
    local rule_type="$1" mask="$2" chain="$3"
    qos_log "INFO" "开始应用 $rule_type 规则到链 $chain (掩码: $mask)"
    load_global_config
    qos_log "INFO" "ENABLE_ACK_LIMIT=$ENABLE_ACK_LIMIT, ENABLE_TCP_UPGRADE=$ENABLE_TCP_UPGRADE"
    if [[ ${#UCI_CACHE[@]} -eq 0 ]]; then
        unset UCI_CACHE 2>/dev/null
        declare -A UCI_CACHE
        qos_log "INFO" "构建 UCI 配置缓存..."
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local key="${line%%=*}"
            local val="${line#*=}"
            val="${val#\'}"; val="${val%\'}"
            if [[ "$key" == "${CONFIG_FILE}."* ]]; then
                UCI_CACHE["$key"]="$val"
            fi
        done < <(uci show "${CONFIG_FILE}" 2>/dev/null)
        qos_log "DEBUG" "已加载 UCI 配置缓存 (${#UCI_CACHE[@]} 个选项)"
    fi
    if ! nft list table inet ${NFT_TABLE} &>/dev/null; then
        qos_log "INFO" "nft 表不存在，将重新初始化"
        _QOS_TABLE_FLUSHED=0
        _IPSET_LOADED=0
        _HOOKS_SETUP=0
        _SET_FAMILY_CACHE=()
    fi
    if [[ $_QOS_TABLE_FLUSHED -eq 0 ]]; then
        qos_log "INFO" "初始化 nftables 表"
        nft add table inet ${NFT_TABLE} 2>/dev/null || true
        nft flush chain inet ${NFT_TABLE} filter_qos_egress 2>/dev/null || true
        nft flush chain inet ${NFT_TABLE} filter_qos_ingress 2>/dev/null || true
        nft flush chain inet ${NFT_TABLE} drop995 2>/dev/null || true
        nft flush chain inet ${NFT_TABLE} drop95 2>/dev/null || true
        nft flush chain inet ${NFT_TABLE} drop50 2>/dev/null || true
        nft flush chain inet ${NFT_TABLE} $RATELIMIT_CHAIN 2>/dev/null || true
        nft add chain inet ${NFT_TABLE} filter_qos_egress 2>/dev/null || true
        nft add chain inet ${NFT_TABLE} filter_qos_ingress 2>/dev/null || true
        generate_ipset_sets
        
        # ========== 创建 ACK 限速所需的动态集合（使用官方新语法） ==========
        setup_ack_limit_sets   # 该函数内部会检查 ENABLE_ACK_LIMIT 并根据粒度创建集合，若失败则禁用功能

        # 创建 TCP 升级集合
        if [[ $ENABLE_TCP_UPGRADE -eq 1 ]]; then
            if ! nft list set inet ${NFT_TABLE} qos_slow_tcp &>/dev/null; then
                if ! nft add set inet ${NFT_TABLE} qos_slow_tcp '{ typeof ct id . ct direction; flags dynamic; timeout 30s; }' 2>/dev/null; then
                    qos_log "ERROR" "无法创建 TCP 升级集合 qos_slow_tcp，功能将禁用"
                    ENABLE_TCP_UPGRADE=0
                else
                    qos_log "DEBUG" "TCP 升级集合 qos_slow_tcp 创建成功"
                fi
            fi
        fi

        # 创建 UDP 限速集合（加强错误处理，失败则禁用功能）
        if [[ $UDP_RATE_LIMIT_ENABLE -eq 1 ]]; then
            local udp_set_failed=0
            # 上传方向 IPv4
            nft add set inet ${NFT_TABLE} udp_per_ip_upload '{ typeof ip saddr; flags dynamic; timeout 30s; }' 2>/dev/null || {
                qos_log "ERROR" "创建 UDP 上传集合 udp_per_ip_upload 失败"
                udp_set_failed=1
            }
            # 上传方向 IPv6
            nft add set inet ${NFT_TABLE} udp_per_ip_upload_v6 '{ typeof ip6 saddr; flags dynamic; timeout 30s; }' 2>/dev/null || {
                qos_log "ERROR" "创建 UDP 上传 IPv6 集合 udp_per_ip_upload_v6 失败"
                udp_set_failed=1
            }
            # 下载方向 IPv4
            nft add set inet ${NFT_TABLE} udp_per_ip_download '{ typeof ip daddr; flags dynamic; timeout 30s; }' 2>/dev/null || {
                qos_log "ERROR" "创建 UDP 下载集合 udp_per_ip_download 失败"
                udp_set_failed=1
            }
            # 下载方向 IPv6
            nft add set inet ${NFT_TABLE} udp_per_ip_download_v6 '{ typeof ip6 daddr; flags dynamic; timeout 30s; }' 2>/dev/null || {
                qos_log "ERROR" "创建 UDP 下载 IPv6 集合 udp_per_ip_download_v6 失败"
                udp_set_failed=1
            }
            if [[ $udp_set_failed -eq 1 ]]; then
                qos_log "ERROR" "UDP 限速所需集合创建失败，功能将被禁用"
                UDP_RATE_LIMIT_ENABLE=0
            fi
        fi
        
        nft add chain inet ${NFT_TABLE} drop995 2>/dev/null || true
        nft add chain inet ${NFT_TABLE} drop95 2>/dev/null || true
        nft add chain inet ${NFT_TABLE} drop50 2>/dev/null || true
        nft flush chain inet ${NFT_TABLE} drop995 2>/dev/null || true
        nft flush chain inet ${NFT_TABLE} drop95 2>/dev/null || true
        nft flush chain inet ${NFT_TABLE} drop50 2>/dev/null || true
        nft add rule inet ${NFT_TABLE} drop995 numgen random mod 1000 ge 995 return
        nft add rule inet ${NFT_TABLE} drop995 drop
        nft add rule inet ${NFT_TABLE} drop95 numgen random mod 1000 ge 950 return
        nft add rule inet ${NFT_TABLE} drop95 drop
        nft add rule inet ${NFT_TABLE} drop50 numgen random mod 1000 ge 500 return
        nft add rule inet ${NFT_TABLE} drop50 drop
        _QOS_TABLE_FLUSHED=1
    fi
    if [[ $_HOOKS_SETUP -eq 0 ]]; then
        qos_log "INFO" "挂载 nftables 钩子链"
        local wan_if=$(get_wan_interface)
        if [[ -z "$wan_if" ]]; then
            qos_log "ERROR" "无法获取 WAN 接口，钩子链可能不完整，QoS 可能无法正确区分方向"
            qos_log "WARN" "未配置 WAN 接口，将不使用方向区分，所有转发流量同时进入上传和下载链（可能导致双重标记）"
            nft add chain inet ${NFT_TABLE} filter_forward '{ type filter hook forward priority 0; policy accept; }' 2>/dev/null || true
            nft flush chain inet ${NFT_TABLE} filter_forward 2>/dev/null || true
            nft add rule inet ${NFT_TABLE} filter_forward jump filter_qos_egress 2>/dev/null || true
            nft add rule inet ${NFT_TABLE} filter_forward jump filter_qos_ingress 2>/dev/null || true
        else
            qos_log "INFO" "使用 WAN 接口: $wan_if"
            nft add chain inet ${NFT_TABLE} filter_output '{ type filter hook output priority 0; policy accept; }' 2>/dev/null || true
            nft add chain inet ${NFT_TABLE} filter_input  '{ type filter hook input priority 0; policy accept; }' 2>/dev/null || true
            nft add chain inet ${NFT_TABLE} filter_forward '{ type filter hook forward priority 0; policy accept; }' 2>/dev/null || true
            nft flush chain inet ${NFT_TABLE} filter_output 2>/dev/null || true
            nft flush chain inet ${NFT_TABLE} filter_input  2>/dev/null || true
            nft flush chain inet ${NFT_TABLE} filter_forward 2>/dev/null || true
            nft add rule inet ${NFT_TABLE} filter_output jump filter_qos_egress 2>/dev/null || true
            nft add rule inet ${NFT_TABLE} filter_forward oifname "$wan_if" jump filter_qos_egress 2>/dev/null || true
            nft add rule inet ${NFT_TABLE} filter_forward iifname "$wan_if" jump filter_qos_ingress 2>/dev/null || true
            nft add rule inet ${NFT_TABLE} filter_input jump filter_qos_ingress 2>/dev/null || true
        fi
        _HOOKS_SETUP=1
        qos_log "INFO" "nftables 钩子链挂载完成"
    fi
    if [[ $ENABLE_EBPF -eq 1 ]]; then
        qos_log "INFO" "eBPF 已启用，尝试加载 eBPF 程序..."
        if ! load_ebpf_programs; then
            qos_log "WARN" "eBPF 程序加载部分失败，将继续使用 nftables 规则"
        fi
    fi
    if ! apply_enhanced_direction_rules "$rule_type" "$chain" "$mask"; then
        qos_log "ERROR" "应用 $rule_type 规则失败"
        return 1
    fi
    load_custom_full_table
    
    return 0
}

# 应用增强功能
apply_enhanced_features() {
    # ACK 限速
    if [[ $ENABLE_ACK_LIMIT -eq 1 ]]; then
        qos_log "INFO" "ACK 限速已启用，生成规则..."
        local ack_rules=$(generate_ack_limit_rules)
        if [[ -n "$ack_rules" ]]; then
            local ack_file=$(mktemp)
            register_temp_file "$ack_file"
            echo "$ack_rules" | while IFS= read -r rule; do
                [[ -z "$rule" ]] && continue
                echo "${rule/add rule/insert rule}" >> "$ack_file"
            done
            qos_log "INFO" "ACK 规则文件内容:"
            cat "$ack_file" | logger -t qos_gargoyle
            if nft -f "$ack_file" 2>&1 | logger -t qos_gargoyle; then
                qos_log "INFO" "ACK 限速规则添加成功"
            else
                qos_log "ERROR" "ACK 限速规则添加失败，功能不可用"
            fi
        else
            qos_log "WARN" "ACK 限速规则生成失败（返回空）"
        fi
    else
        qos_log "INFO" "ACK 限速未启用"
    fi

    # TCP 升级
    if [[ $ENABLE_TCP_UPGRADE -eq 1 ]]; then
        qos_log "INFO" "TCP 升级已启用，生成规则..."
        local tcp_upgrade_rules=$(generate_tcp_upgrade_rules)
        if [[ -n "$tcp_upgrade_rules" ]]; then
            local tcp_file=$(mktemp)
            register_temp_file "$tcp_file"
            echo "$tcp_upgrade_rules" | while IFS= read -r rule; do
                [[ -z "$rule" ]] && continue
                echo "${rule/add rule/insert rule}" >> "$tcp_file"
            done
            qos_log "INFO" "TCP 升级规则文件内容:"
            cat "$tcp_file" | logger -t qos_gargoyle
            if nft -f "$tcp_file" 2>&1 | logger -t qos_gargoyle; then
                qos_log "INFO" "TCP 升级规则添加成功"
            else
                qos_log "ERROR" "TCP 升级规则添加失败，功能不可用"
            fi
        else
            qos_log "WARN" "TCP 升级规则生成失败（返回空）"
        fi
    else
        qos_log "INFO" "TCP 升级未启用"
    fi

    # UDP 限速
    if [[ $UDP_RATE_LIMIT_ENABLE -eq 1 ]]; then
        qos_log "INFO" "生成 UDP 限速规则..."
        local udp_limit_rules=$(generate_udp_limit_rules)
        if [[ -n "$udp_limit_rules" ]]; then
            local udp_file=$(mktemp)
            register_temp_file "$udp_file"
            udp_limit_rules=$(echo "$udp_limit_rules" | sed 's/^add rule/insert rule/')
            echo "$udp_limit_rules" > "$udp_file"
            qos_log "INFO" "UDP 限速规则文件内容:"
            cat "$udp_file" | logger -t qos_gargoyle
            if nft -f "$udp_file" 2>&1 | logger -t qos_gargoyle; then
                qos_log "INFO" "UDP 限速规则添加成功"
            else
                qos_log "ERROR" "UDP 限速规则添加失败，功能不可用"
            fi
        else
            qos_log "WARN" "UDP 限速规则生成失败（返回空）"
        fi
    else
        qos_log "INFO" "UDP 限速未启用"
    fi
    
    # 动态分类
    if [[ $ENABLE_DYNAMIC_CLASSIFY -eq 1 ]]; then
        qos_log "INFO" "动态分类总开关已启用，初始化动态检测..."
        setup_dynamic_classification
    else
        qos_log "INFO" "动态分类未启用"
    fi
}

# ========== 入口重定向（增强缓存清除机制） ==========
setup_ingress_redirect() {
    if [[ -z "$qos_interface" ]]; then
        qos_log "ERROR" "无法确定 WAN 接口"
        return 1
    fi
    
    local cache_file="/tmp/qos_gargoyle_ipv6_redirect_cache"
    local kernel_version=$(uname -r)
    local sfo_enabled=0
    if check_sfo_enabled; then
        sfo_enabled=1
        qos_log "INFO" "SFO 已启用，将使用 ctinfo 恢复标记"
    fi
    
    local connmark_ok=0
    if check_tc_connmark_support; then
        connmark_ok=1
        qos_log "INFO" "tc connmark 动作受支持"
    else
        qos_log "WARN" "tc connmark 动作不受支持"
    fi
    
    local ctinfo_ok=0
    if (( sfo_enabled )); then
        if check_tc_ctinfo_support; then
            ctinfo_ok=1
            qos_log "INFO" "tc ctinfo 动作受支持"
        else
            qos_log "WARN" "tc ctinfo 动作不受支持，将回退到 connmark"
        fi
    fi
    
    qos_log "INFO" "设置入口重定向: $qos_interface -> $IFB_DEVICE"
    tc qdisc del dev "$qos_interface" ingress 2>/dev/null || true
    if ! tc qdisc add dev "$qos_interface" handle ffff: ingress; then
        qos_log "ERROR" "无法在 $qos_interface 上创建入口队列"
        return 1
    fi
    tc filter del dev "$qos_interface" parent ffff: 2>/dev/null || true
    
    # IPv4 入口重定向（始终执行，无缓存）
    local ipv4_success=false
    if (( sfo_enabled && ctinfo_ok )); then
        if ! tc filter add dev "$qos_interface" parent ffff: protocol ip \
            u32 match u32 0 0 \
            action ctinfo mark 0xffffffff 0xffffffff \
            action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
            qos_log "ERROR" "IPv4入口重定向规则添加失败（使用 ctinfo）"
            tc qdisc del dev "$qos_interface" ingress 2>/dev/null
            return 1
        else
            ipv4_success=true
            qos_log "INFO" "IPv4入口重定向规则添加成功（使用 ctinfo，SFO 兼容）"
        fi
    elif (( connmark_ok )); then
        if ! tc filter add dev "$qos_interface" parent ffff: protocol ip \
            u32 match u32 0 0 \
            action connmark \
            action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
            qos_log "ERROR" "IPv4入口重定向规则添加失败（使用 connmark）"
            tc qdisc del dev "$qos_interface" ingress 2>/dev/null
            return 1
        else
            ipv4_success=true
            qos_log "INFO" "IPv4入口重定向规则添加成功（使用 connmark）"
        fi
    else
        if ! tc filter add dev "$qos_interface" parent ffff: protocol ip \
            u32 match u32 0 0 \
            action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
            qos_log "ERROR" "IPv4入口重定向规则添加失败（无标记）"
            tc qdisc del dev "$qos_interface" ingress 2>/dev/null
            return 1
        else
            ipv4_success=true
            qos_log "WARN" "IPv4入口重定向规则添加成功（未使用标记，标记将丢失）"
        fi
    fi
    
    if [[ "$ipv4_success" != "true" ]]; then
        qos_log "ERROR" "IPv4入口重定向配置失败"
        return 1
    fi
    
    # IPv6 入口重定向（带缓存清除机制）
    local ipv6_prefix=$(uci -q get ${CONFIG_FILE}.global.ipv6_redirect_prefix 2>/dev/null)
    [[ -z "$ipv6_prefix" ]] && ipv6_prefix="2000::/3"
    
    local has_ipv6_global=0
    if ip -6 addr show dev "$qos_interface" scope global 2>/dev/null | grep -q "inet6"; then
        has_ipv6_global=1
        qos_log "INFO" "接口 $qos_interface 拥有全局 IPv6 地址，将尝试配置 IPv6 重定向，前缀: $ipv6_prefix"
    else
        qos_log "INFO" "接口 $qos_interface 无全局 IPv6 地址，IPv6 重定向失败仅警告"
    fi
    
    local ipv6_action=""
    if (( sfo_enabled && ctinfo_ok )); then
        ipv6_action="action ctinfo mark 0xffffffff 0xffffffff"
    elif (( connmark_ok )); then
        ipv6_action="action connmark"
    fi
    
    local ipv6_success=false
    local cached_method=""
    
    # 检查接口是否变化（简单判断：若接口 up 但之前缓存的接口索引不同，则清除缓存）
    local ifindex=$(ip link show "$qos_interface" 2>/dev/null | awk '{print $1}' | tr -d ':')
    if [[ -f "$cache_file" ]]; then
        local cached_kernel cached_ifindex
        {
            read -r cached_method
            read -r cached_kernel
            read -r cached_ifindex
        } < "$cache_file" 2>/dev/null
        if [[ "$cached_kernel" != "$kernel_version" ]] || [[ "$cached_ifindex" != "$ifindex" ]]; then
            qos_log "INFO" "内核版本或接口索引已变更，清除 IPv6 重定向缓存"
            cached_method=""
            rm -f "$cache_file"
        else
            qos_log "DEBUG" "读取 IPv6 重定向缓存: $cached_method (内核: $cached_kernel, 接口索引: $cached_ifindex)"
        fi
    fi
    
    # 根据缓存优先尝试成功过的方式
    case "$cached_method" in
        "flower_mark")
            qos_log "INFO" "使用缓存的方式: flower 带标记"
            if [[ -n "$ipv6_action" ]]; then
                if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                    flower dst_ip "$ipv6_prefix" \
                    $ipv6_action \
                    action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                    ipv6_success=true
                    qos_log "INFO" "IPv6入口重定向规则（flower 前缀 $ipv6_prefix，带标记）添加成功"
                else
                    qos_log "WARN" "缓存的方式失败，尝试其他方式"
                    cached_method=""
                fi
            fi
            ;;
        "flower")
            qos_log "INFO" "使用缓存的方式: flower 无标记"
            if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                flower dst_ip "$ipv6_prefix" \
                action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                ipv6_success=true
                qos_log "INFO" "IPv6入口重定向规则（flower 前缀 $ipv6_prefix，无标记）添加成功"
            else
                qos_log "WARN" "缓存的方式失败，尝试其他方式"
                cached_method=""
            fi
            ;;
        "u32_mark")
            qos_log "INFO" "使用缓存的方式: u32 全球单播带标记"
            if [[ -n "$ipv6_action" ]]; then
                if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                    u32 match u32 0x20000000 0xe0000000 at 24 \
                    $ipv6_action \
                    action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                    ipv6_success=true
                    qos_log "INFO" "IPv6入口重定向规则（u32 全球单播，带标记）添加成功"
                else
                    qos_log "WARN" "缓存的方式失败，尝试其他方式"
                    cached_method=""
                fi
            fi
            ;;
        "u32")
            qos_log "INFO" "使用缓存的方式: u32 全球单播无标记"
            if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                u32 match u32 0x20000000 0xe0000000 at 24 \
                action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                ipv6_success=true
                qos_log "INFO" "IPv6入口重定向规则（u32 全球单播，无标记）添加成功"
            else
                qos_log "WARN" "缓存的方式失败，尝试其他方式"
                cached_method=""
            fi
            ;;
        "full_mark")
            qos_log "INFO" "使用缓存的方式: u32 全匹配带标记"
            if [[ -n "$ipv6_action" ]]; then
                if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                    u32 match u32 0 0 \
                    $ipv6_action \
                    action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                    ipv6_success=true
                    qos_log "INFO" "IPv6入口重定向规则（u32 全匹配，带标记）添加成功"
                else
                    qos_log "WARN" "缓存的方式失败，尝试其他方式"
                    cached_method=""
                fi
            fi
            ;;
        "full")
            qos_log "INFO" "使用缓存的方式: u32 全匹配无标记"
            if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                u32 match u32 0 0 \
                action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                ipv6_success=true
                qos_log "INFO" "IPv6入口重定向规则（u32 全匹配，无标记）添加成功"
            else
                qos_log "WARN" "缓存的方式失败，尝试其他方式"
                cached_method=""
            fi
            ;;
        *)
            # 无有效缓存，执行完整探测
            ;;
    esac
    
    # 如果缓存方式失败或没有缓存，执行完整探测
    if [[ "$ipv6_success" != "true" ]]; then
        qos_log "INFO" "执行 IPv6 重定向完整探测..."
        
        # 尝试 flower 带标记
        if [[ -n "$ipv6_action" ]] && [[ "$ipv6_success" != "true" ]]; then
            if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                flower dst_ip "$ipv6_prefix" \
                $ipv6_action \
                action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                ipv6_success=true
                cached_method="flower_mark"
                qos_log "INFO" "IPv6入口重定向规则（flower 前缀 $ipv6_prefix，带标记）添加成功"
            else
                qos_log "WARN" "flower 带标记规则失败，尝试无标记 flower"
            fi
        fi
        
        # 尝试 flower 无标记
        if [[ "$ipv6_success" != "true" ]]; then
            if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                flower dst_ip "$ipv6_prefix" \
                action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                ipv6_success=true
                cached_method="flower"
                qos_log "INFO" "IPv6入口重定向规则（flower 前缀 $ipv6_prefix，无标记）添加成功"
            else
                qos_log "WARN" "flower 无标记规则失败"
            fi
        fi
        
        # 尝试 u32 全球单播（仅当使用默认前缀时）
        if [[ "$ipv6_success" != "true" ]] && [[ "$ipv6_prefix" == "2000::/3" ]]; then
            if [[ -n "$ipv6_action" ]]; then
                if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                    u32 match u32 0x20000000 0xe0000000 at 24 \
                    $ipv6_action \
                    action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                    ipv6_success=true
                    cached_method="u32_mark"
                    qos_log "INFO" "IPv6入口重定向规则（u32 全球单播，带标记）添加成功"
                else
                    qos_log "WARN" "u32 全球单播带标记规则失败"
                fi
            fi
            if [[ "$ipv6_success" != "true" ]]; then
                if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                    u32 match u32 0x20000000 0xe0000000 at 24 \
                    action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                    ipv6_success=true
                    cached_method="u32"
                    qos_log "INFO" "IPv6入口重定向规则（u32 全球单播，无标记）添加成功"
                else
                    qos_log "WARN" "u32 全球单播无标记规则失败"
                fi
            fi
        fi
        
        # 最后尝试全匹配
        if [[ "$ipv6_success" != "true" ]]; then
            if [[ -n "$ipv6_action" ]]; then
                if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                    u32 match u32 0 0 \
                    $ipv6_action \
                    action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                    ipv6_success=true
                    cached_method="full_mark"
                    qos_log "INFO" "IPv6入口重定向规则（u32 全匹配，带标记）添加成功"
                else
                    qos_log "WARN" "u32 全匹配带标记规则失败"
                fi
            fi
            if [[ "$ipv6_success" != "true" ]]; then
                if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                    u32 match u32 0 0 \
                    action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                    ipv6_success=true
                    cached_method="full"
                    qos_log "INFO" "IPv6入口重定向规则（u32 全匹配，无标记）添加成功"
                else
                    qos_log "WARN" "IPv6全匹配回退规则添加失败"
                fi
            fi
        fi
    fi
    
    # 保存成功的方式到缓存（包含内核版本和接口索引）
    if [[ "$ipv6_success" == "true" ]] && [[ -n "$cached_method" ]]; then
        {
            echo "$cached_method"
            echo "$kernel_version"
            echo "$ifindex"
        } > "$cache_file"
        qos_log "DEBUG" "保存 IPv6 重定向缓存: $cached_method (内核: $kernel_version, 接口索引: $ifindex)"
    elif [[ "$ipv6_success" != "true" ]] && [[ -f "$cache_file" ]]; then
        rm -f "$cache_file"
        qos_log "DEBUG" "清除无效的 IPv6 重定向缓存"
    fi
    
    # 结果报告
    if (( has_ipv6_global == 1 )); then
        if [[ "$ipv6_success" != "true" ]]; then
            qos_log "WARN" "接口存在全局 IPv6 地址，但所有 IPv6 入口重定向配置失败，IPv6 流量可能不受 QoS 控制，但 IPv4 QoS 将继续工作"
        else
            qos_log "INFO" "IPv6 入口重定向成功"
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

# ========== IPv6增强支持 ==========
setup_ipv6_specific_rules() {
    qos_log "INFO" "设置IPv6特定规则（优化版）"
    nft add chain inet ${NFT_TABLE} filter_prerouting '{ type filter hook prerouting priority 0; policy accept; }' 2>/dev/null || true
    nft flush chain inet ${NFT_TABLE} filter_prerouting 2>/dev/null || true
    local ICMPV6_CRITICAL_TYPES="133,134,135,136,137"
    nft add rule inet ${NFT_TABLE} filter_prerouting \
        meta nfproto ipv6 ip6 daddr { ff02::1:2, ff02::1:3 } meta mark set 0x80000000 counter 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} filter_prerouting \
        meta nfproto ipv6 ip6 daddr ::1 meta mark set 0x80000000 counter 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} filter_prerouting \
        meta nfproto ipv6 icmpv6 type { $ICMPV6_CRITICAL_TYPES } meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} filter_prerouting \
        meta nfproto ipv6 udp dport { 546, 547 } meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} filter_prerouting \
        meta nfproto ipv6 udp dport 53 meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} filter_prerouting \
        meta nfproto ipv6 tcp dport 53 meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} filter_prerouting \
        meta nfproto ipv6 tcp dport { 80, 443 } meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet ${NFT_TABLE} filter_prerouting \
        meta nfproto ipv6 udp dport 123 meta mark set 0x40000000 counter 2>/dev/null || true
    qos_log "INFO" "IPv6关键流量规则设置完成"
}

# ========== 健康检查 ==========
health_check() {
    local errors=0 status=""
    uci -q show ${CONFIG_FILE} >/dev/null 2>&1 && status="${status}config:ok;" || { status="${status}config:missing;"; ((errors++)); }
    nft list table inet ${NFT_TABLE} >/dev/null 2>&1 && status="${status}nft:ok;" || { status="${status}nft:missing;"; ((errors++)); }
    local wan_if=$(uci -q get ${CONFIG_FILE}.global.wan_interface 2>/dev/null)
    if [[ -n "$wan_if" ]] && tc qdisc show dev "$wan_if" 2>/dev/null | grep -qE "htb|hfsc|cake"; then
        status="${status}tc:ok;"
    else
        status="${status}tc:missing;"; ((errors++))
    fi
    for mod in ifb sch_htb sch_hfsc sch_cake sch_fq; do
        if ! lsmod 2>/dev/null | grep -q "^$mod"; then
            modprobe "$mod" 2>/dev/null || true
            if ! lsmod 2>/dev/null | grep -q "^$mod"; then
                status="${status}module_${mod}:missing;"
                ((errors++))
            fi
        fi
    done
    [[ -f "$CLASS_MARKS_FILE" ]] && status="${status}marks:ok;" || { status="${status}marks:missing;"; ((errors++)); }
    echo "status=$status;errors=$errors"
    return $((errors == 0 ? 0 : 1))
}

# ========== 自动加载全局配置 ==========
if [[ -z "$_QOS_RULE_SH_LOADED" ]] && [[ "$(basename "$0")" != "rule.sh" ]]; then
    load_global_config
    _QOS_RULE_SH_LOADED=1
fi