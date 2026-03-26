#!/bin/bash
# 规则辅助模块 (rule.sh)
# 版本: 3.4.5 - 修复 meter 语法、DSCP 映射顺序、动态分类标记、增强规则 ct mark、ICMP 否定逻辑
# 完全移除锁机制，适配 procd 管理

# 加载核心库（已修复）
if [[ -f "/usr/lib/qos_gargoyle/common.sh" ]]; then
    . /usr/lib/qos_gargoyle/common.sh
else
    echo "错误: 核心库 /usr/lib/qos_gargoyle/common.sh 未找到" >&2
    exit 1
fi

# ========== 清理函数（仅清理临时文件） ==========
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
    local proto="$1"
    local family="$2"
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

# ========== 拆分多集合字段（支持否定前缀和逗号） ==========
split_multiset() {
    local field="$1"
    local result=()
    if [[ "$field" == "!="* ]]; then
        result+=("$field")
    else
        IFS=',' read -ra parts <<< "$field"
        for part in "${parts[@]}"; do
            result+=("$part")
        done
    fi
    printf '%s\n' "${result[@]}"
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

# ========== 通用规则构建函数 ==========
build_nft_rule_generic() {
    local rule_name="$1" chain="$2" class_mark="$3" mask="$4" family="$5" proto="$6"
    local srcport="$7" dstport="$8" connbytes_kb="$9" state="${10}" src_ip="${11}" dest_ip="${12}"
    local packet_len="${13}" tcp_flags="${14}" iif="${15}" oif="${16}" udp_length="${17}"
    local dscp="${18}" ttl="${19}" icmp_type="${20}"
    
    local proto_v4=$(adjust_proto_for_family "$proto" "ipv4")
    local proto_v6=$(adjust_proto_for_family "$proto" "ipv6")
    
    local ipv4_rules=()
    local ipv6_rules=()
    
    add_ipv4_rule() {
        local cmd="add rule inet gargoyle-qos-priority $chain meta mark == 0 meta nfproto ipv4"
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
        local cmd="add rule inet gargoyle-qos-priority $chain meta mark == 0 meta nfproto ipv6"
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
    
    # TCP 标志处理优化：无否定时使用集合形式，有否定时使用掩码形式
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
            # 只有正标志：使用集合形式（更直观，且不要求其他位为零）
            tcp_flag_expr="tcp flags { ${set_flags//,/ } }"
        elif [[ -n "$set_flags" || -n "$unset_flags" ]]; then
            # 包含否定标志：使用掩码形式
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
                # 要求总掩码位中，set_flags 对应位必须为1，unset_flags 对应位必须为0
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
                local neg=""
                [[ "$sport_val" == "!="* ]] && { neg="!="; sport_val="${sport_val#!=}"; }
                if [[ "$sport_val" == @* ]]; then
                    port_cond="th sport $neg $sport_val"
                else
                    if [[ -n "$neg" ]]; then
                        port_cond="th sport $neg { $sport_val }"
                    else
                        port_cond="th sport { $sport_val }"
                    fi
                fi
            fi
        else
            if [[ -n "$dstport" ]]; then
                local dport_val="$dstport"
                local neg=""
                [[ "$dport_val" == "!="* ]] && { neg="!="; dport_val="${dport_val#!=}"; }
                if [[ "$dport_val" == @* ]]; then
                    port_cond="th dport $neg $dport_val"
                else
                    if [[ -n "$neg" ]]; then
                        port_cond="th dport $neg { $dport_val }"
                    else
                        port_cond="th dport { $dport_val }"
                    fi
                fi
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

# 辅助函数：构建 ICMP 条件（修复否定组合：使用 and 而非 or）
build_icmp_cond() {
    local icmp_val="$1"
    local cond=""
    local neg=""
    [[ "$icmp_val" == "!="* ]] && { neg="!="; icmp_val="${icmp_val#!=}"; }
    if [[ "$icmp_val" == */* ]]; then
        local type="${icmp_val%/*}" code="${icmp_val#*/}"
        if [[ -n "$neg" ]]; then
            # 否定组合：要求 type != type 且 code != code（即排除精确匹配）
            cond="(icmp type != $type) and (icmp code != $code)"
        else
            cond="icmp type $type icmp code $code"
        fi
    else
        cond="icmp type $neg $icmp_val"
    fi
    echo "$cond"
}

# ========== class_mark 映射设置（修复：使用 add rule 而非 insert rule，确保在分类之后） ==========
setup_class_mark_map() {
    qos_log "INFO" "设置 class_mark 映射..."
    local tmp_nft_file=$(mktemp)
    register_temp_file "$tmp_nft_file"

    cat << EOF >> "$tmp_nft_file"
delete map inet gargoyle-qos-priority class_mark 2>/dev/null
add map inet gargoyle-qos-priority class_mark { type mark : dscp; }
EOF

    config_load "$CONFIG_FILE"

    while IFS=: read -r dir cls mark_raw; do
        [ -z "$dir" ] || [ -z "$cls" ] && continue
        local cls_clean=$(echo "$cls" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
        local mark="${mark_raw%%#*}"
        mark=$(echo "$mark" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$mark" ] && continue

        local dscp_raw=$(uci -q get "${CONFIG_FILE}.${cls_clean}.dscp" 2>/dev/null)
        local dscp=$(echo "$dscp_raw" | tr -d '\r' | tr -d '[:space:]')
        if [ -z "$dscp" ]; then
            local priority_raw=$(uci -q get "${CONFIG_FILE}.${cls_clean}.priority" 2>/dev/null)
            local priority=$(echo "$priority_raw" | tr -d '\r' | tr -d '[:space:]')
            if [ -n "$priority" ] && [ "$priority" -ge 0 ] 2>/dev/null && [ "$priority" -le 7 ] 2>/dev/null; then
                dscp=$priority
            else
                dscp=0
            fi
        else
            if ! [ "$dscp" -ge 0 ] 2>/dev/null || ! [ "$dscp" -le 63 ] 2>/dev/null; then
                dscp=0
            fi
        fi

        echo "add element inet gargoyle-qos-priority class_mark { $mark : $dscp }" >> "$tmp_nft_file"
        qos_log "DEBUG" "Added map element $mark : $dscp for $cls_clean"
    done < "$CLASS_MARKS_FILE"

    cat << EOF >> "$tmp_nft_file"
# DSCP mapping rules: apply after classification (use add rule, not insert)
add rule inet gargoyle-qos-priority filter_qos_egress ct mark != 0 ip dscp set @class_mark[ct mark]
add rule inet gargoyle-qos-priority filter_qos_egress ct mark != 0 ip6 dscp set @class_mark[ct mark]
add rule inet gargoyle-qos-priority filter_qos_ingress ct mark != 0 ip dscp set @class_mark[ct mark]
add rule inet gargoyle-qos-priority filter_qos_ingress ct mark != 0 ip6 dscp set @class_mark[ct mark]
add rule inet gargoyle-qos-priority filter_qos_egress ct state established,related ip dscp set @class_mark[ct mark]
add rule inet gargoyle-qos-priority filter_qos_egress ct state established,related ip6 dscp set @class_mark[ct mark]
add rule inet gargoyle-qos-priority filter_qos_ingress ct state established,related ip dscp set @class_mark[ct mark]
add rule inet gargoyle-qos-priority filter_qos_ingress ct state established,related ip6 dscp set @class_mark[ct mark]
EOF

    if nft -f "$tmp_nft_file" 2>&1 | logger -t qos_gargoyle; then
        qos_log "INFO" "class_mark map and recovery rules loaded successfully"
        rm -f "$tmp_nft_file"
        return 0
    else
        qos_log "ERROR" "Failed to load class_mark map and recovery rules"
        cat "$tmp_nft_file" | logger -t qos_gargoyle
        rm -f "$tmp_nft_file"
        return 1
    fi
}

# ========== 增强规则应用 ==========
apply_enhanced_direction_rules() {
    local rule_type="$1" chain="$2" mask="$3"
    qos_log "INFO" "应用增强$rule_type规则到链: $chain, 掩码: $mask"
    nft add chain inet gargoyle-qos-priority "$chain" 2>/dev/null || true
    nft flush chain inet gargoyle-qos-priority "$chain" 2>/dev/null || true
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
    local all_sets=()
    for rule_name in $sorted_rule_list; do
        if ! load_all_config_options "$CONFIG_FILE" "$rule_name" "tmp_"; then
            continue
        fi
        [[ "$tmp_enabled" != "1" ]] && continue
        for field in src_ip dest_ip; do
            local var_name="tmp_${field}"
            local val
            eval "val=\${${var_name}}"
            [[ -z "$val" ]] && continue
            [[ "$val" == "!="* ]] && val="${val#!=}"
            if [[ "$val" == @* ]]; then
                local setname="${val#@}"
                all_sets+=("$setname")
            fi
        done
    done
    if [[ ${#all_sets[@]} -gt 0 ]]; then
        all_sets=($(printf "%s\n" "${all_sets[@]}" | sort -u))
        local existing_sets=$(get_existing_sets "inet gargoyle-qos-priority")
        local missing_sets=()
        for setname in "${all_sets[@]}"; do
            if ! echo "$existing_sets" | grep -qx "$setname"; then
                missing_sets+=("$setname")
            fi
        done
        if [[ ${#missing_sets[@]} -gt 0 ]]; then
            qos_log "ERROR" "以下集合不存在于 nftables 表中: ${missing_sets[*]}，请检查 UCI ipset 配置"
            return 1
        fi
        qos_log "INFO" "所有引用的集合验证通过"
    fi
    local nft_batch_file=$(mktemp /tmp/qos_nft_batch_XXXXXX)
    register_temp_file "$nft_batch_file"
    qos_log "INFO" "按优先级顺序生成nft规则..."
    local rule_count=0
    local MAX_COMBINATIONS=1000
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
        [[ -z "$tmp_family" ]] && tmp_family="inet"
        local srcport_list=()
        local dstport_list=()
        local src_ip_list=()
        local dest_ip_list=()
        
        if [[ -n "$tmp_srcport" ]]; then
            if [[ "$tmp_srcport" == "!="* ]]; then
                srcport_list=("$tmp_srcport")
            else
                mapfile -t srcport_list < <(split_multiset "$tmp_srcport")
            fi
        else
            srcport_list=("")
        fi
        if [[ -n "$tmp_dstport" ]]; then
            if [[ "$tmp_dstport" == "!="* ]]; then
                dstport_list=("$tmp_dstport")
            else
                mapfile -t dstport_list < <(split_multiset "$tmp_dstport")
            fi
        else
            dstport_list=("")
        fi
        
        if [[ -n "$tmp_src_ip" ]]; then
            if [[ "$tmp_src_ip" == "!="* ]]; then
                src_ip_list=("$tmp_src_ip")
            else
                mapfile -t src_ip_list < <(split_multiset "$tmp_src_ip")
            fi
        else
            src_ip_list=("")
        fi
        if [[ -n "$tmp_dest_ip" ]]; then
            if [[ "$tmp_dest_ip" == "!="* ]]; then
                dest_ip_list=("$tmp_dest_ip")
            else
                mapfile -t dest_ip_list < <(split_multiset "$tmp_dest_ip")
            fi
        else
            dest_ip_list=("")
        fi
        
        local total_combinations=$(( ${#srcport_list[@]} * ${#dstport_list[@]} * ${#src_ip_list[@]} * ${#dest_ip_list[@]} ))
        if [[ $total_combinations -gt $MAX_COMBINATIONS ]]; then
            qos_log "WARN" "规则 $rule_name 的组合数 $total_combinations 超过阈值 $MAX_COMBINATIONS，可能导致性能问题，请检查配置（端口/IP 集合过多）"
        fi
        for srcp in "${srcport_list[@]}"; do
            for dstp in "${dstport_list[@]}"; do
                for srcip in "${src_ip_list[@]}"; do
                    for dstip in "${dest_ip_list[@]}"; do
                        build_nft_rule_generic "$rule_name" "$chain" "$class_mark" "$mask" "$tmp_family" "$tmp_proto" \
                            "$srcp" "$dstp" "$tmp_connbytes_kb" "$tmp_state" "$srcip" "$dstip" \
                            "$tmp_packet_len" "$tmp_tcp_flags" "$tmp_iif" "$tmp_oif" "$tmp_udp_length" \
                            "$tmp_dscp" "$tmp_ttl" "$tmp_icmp_type" >> "$nft_batch_file"
                        ((rule_count++))
                    done
                done
            done
        done
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
                echo "add rule inet gargoyle-qos-priority $chain $line" >> "$nft_batch_file"
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

# 应用增强功能（ACK限速、TCP升级、UDP限速,动态分类） 修复：同时设置 meta mark 和 ct mark
apply_enhanced_features() {
    if [[ $ENABLE_ACK_LIMIT -eq 1 ]]; then
        qos_log "INFO" "ACK 限速已启用，生成规则..."
        local ack_rules=$(generate_ack_limit_rules)
        if [[ -n "$ack_rules" ]]; then
            local ack_file=$(mktemp)
            register_temp_file "$ack_file"
            echo "$ack_rules" | while IFS= read -r rule; do
                [[ -z "$rule" ]] && continue
                # ACK 限速规则使用 insert，确保在分类之前执行
                echo "${rule/add rule/insert rule}" >> "$ack_file"
            done
            qos_log "INFO" "ACK 规则文件内容:"
            cat "$ack_file" | logger -t qos_gargoyle
            if nft -f "$ack_file" 2>&1 | logger -t qos_gargoyle; then
                qos_log "INFO" "ACK 限速规则添加成功"
            else
                qos_log "WARN" "ACK 限速规则添加失败"
            fi
        else
            qos_log "WARN" "ACK 限速规则生成失败（返回空）"
        fi
    else
        qos_log "INFO" "ACK 限速未启用"
    fi

    if [[ $ENABLE_TCP_UPGRADE -eq 1 ]]; then
        qos_log "INFO" "TCP 升级已启用，生成规则..."
        local tcp_upgrade_rules=$(generate_tcp_upgrade_rules)
        if [[ -n "$tcp_upgrade_rules" ]]; then
            local tcp_file=$(mktemp)
            register_temp_file "$tcp_file"
            echo "$tcp_upgrade_rules" | while IFS= read -r rule; do
                [[ -z "$rule" ]] && continue
                # 修复：同时设置 meta mark 和 ct mark，使用 insert 确保优先执行
                rule=$(echo "$rule" | sed 's/meta mark set \([0-9]\+\)/meta mark set \1 ct mark set \1/')
                echo "${rule/add rule/insert rule}" >> "$tcp_file"
            done
            qos_log "INFO" "TCP 升级规则文件内容:"
            cat "$tcp_file" | logger -t qos_gargoyle
            if nft -f "$tcp_file" 2>&1 | logger -t qos_gargoyle; then
                qos_log "INFO" "TCP 升级规则添加成功"
            else
                qos_log "WARN" "TCP 升级规则添加失败"
            fi
        else
            qos_log "WARN" "TCP 升级规则生成失败（返回空）"
        fi
    else
        qos_log "INFO" "TCP 升级未启用"
    fi

    if [[ $UDP_RATE_LIMIT_ENABLE -eq 1 ]]; then
        qos_log "INFO" "生成 UDP 限速规则..."
        local udp_limit_rules=$(generate_udp_limit_rules)
        if [[ -n "$udp_limit_rules" ]]; then
            local udp_file=$(mktemp)
            register_temp_file "$udp_file"
            # 修复：同时设置 meta mark 和 ct mark
            udp_limit_rules=$(echo "$udp_limit_rules" | sed 's/meta mark set \([0-9]\+\)/meta mark set \1 ct mark set \1/g')
            echo "$udp_limit_rules" > "$udp_file"
            qos_log "INFO" "UDP 限速规则文件内容:"
            cat "$udp_file" | logger -t qos_gargoyle
            if nft -f "$udp_file" 2>&1 | logger -t qos_gargoyle; then
                qos_log "INFO" "UDP 限速规则添加成功"
            else
                qos_log "WARN" "UDP 限速规则添加失败"
            fi
        else
            qos_log "WARN" "UDP 限速规则生成失败（返回空）"
        fi
    else
        qos_log "INFO" "UDP 限速未启用"
    fi
    
    if [[ $ENABLE_DYNAMIC_CLASSIFY -eq 1 ]]; then
        qos_log "INFO" "动态分类总开关已启用，初始化动态检测..."
        setup_dynamic_classification
    else
        qos_log "INFO" "动态分类未启用"
    fi
}

# ========== 动态检测函数 ==========
check_meter_support() {
    local test_file=$(mktemp)
    register_temp_file "$test_file"
    echo "add table inet qos_meter_test" > "$test_file"
    echo "add chain inet qos_meter_test test { type filter hook forward priority 0; }" >> "$test_file"
    echo "add rule inet qos_meter_test test meter test_meter { ip daddr timeout 1s } limit rate 1/minute counter" >> "$test_file"
    if nft -c -f "$test_file" 2>/dev/null; then
        rm -f "$test_file"
        nft delete table inet qos_meter_test 2>/dev/null
        return 0
    else
        rm -f "$test_file"
        return 1
    fi
}

cleanup_dynamic_detection() {
    nft delete set inet gargoyle-qos-priority qos_bulk_clients 2>/dev/null || true
    nft delete set inet gargoyle-qos-priority qos_bulk_clients6 2>/dev/null || true
    nft delete chain inet gargoyle-qos-priority qos_bulk_client 2>/dev/null || true
    nft delete chain inet gargoyle-qos-priority qos_bulk_client_reply 2>/dev/null || true
    nft delete chain inet gargoyle-qos-priority qos_dynamic_classify 2>/dev/null || true
    nft delete chain inet gargoyle-qos-priority qos_dynamic_classify_reply 2>/dev/null || true
    nft delete chain inet gargoyle-qos-priority qos_established_connection 2>/dev/null || true
    nft delete chain inet gargoyle-qos-priority qos_high_throughput_service 2>/dev/null || true
    nft delete chain inet gargoyle-qos-priority qos_high_throughput_service_reply 2>/dev/null || true
    nft delete set inet gargoyle-qos-priority qos_high_throughput_services 2>/dev/null || true
    nft delete set inet gargoyle-qos-priority qos_high_throughput_services6 2>/dev/null || true
}

get_class_mark_for_dynamic() {
    local class_name="$1"
    local class_mark=$(get_class_mark "upload" "$class_name" 2>/dev/null)
    if [ -z "$class_mark" ]; then
        class_mark=$(get_class_mark "download" "$class_name" 2>/dev/null)
    fi
    class_mark=$((class_mark & 0x3F))
    echo "$class_mark"
}

# 修复：meter 语法修正，同时设置 meta mark 和 ct mark
create_bulk_client_rules() {
    local enabled=1 min_bytes=10000 min_connections=10 class="bulk"
    
    local bulk_section="bulk_detect"
    local uci_enabled=$(uci -q get ${CONFIG_FILE}.${bulk_section}.enabled 2>/dev/null)
    [ -n "$uci_enabled" ] && enabled="$uci_enabled"
    local uci_min_bytes=$(uci -q get ${CONFIG_FILE}.${bulk_section}.min_bytes 2>/dev/null)
    [ -n "$uci_min_bytes" ] && min_bytes="$uci_min_bytes"
    local uci_min_connections=$(uci -q get ${CONFIG_FILE}.${bulk_section}.min_connections 2>/dev/null)
    [ -n "$uci_min_connections" ] && min_connections="$uci_min_connections"
    local uci_class=$(uci -q get ${CONFIG_FILE}.${bulk_section}.class 2>/dev/null)
    [ -n "$uci_class" ] && class="$uci_class"

    [ "$enabled" != "1" ] && return 0
    [ "$min_bytes" -le 0 ] && min_bytes=10000
    [ "$min_connections" -le 1 ] && min_connections=10
    
    local dscp=$(get_class_mark_for_dynamic "$class")
    if [ -z "$dscp" ] || [ "$dscp" -eq 0 ]; then
        qos_log "WARN" "bulk_client_detection: class '$class' not found or class_mark=0, using default 8 (CS1)"
        dscp=8
    fi

    nft add set inet gargoyle-qos-priority qos_bulk_clients '{ type ipv4_addr . inet_service . inet_proto; flags timeout; }' 2>/dev/null || true
    nft add set inet gargoyle-qos-priority qos_bulk_clients6 '{ type ipv6_addr . inet_service . inet_proto; flags timeout; }' 2>/dev/null || true

    nft add chain inet gargoyle-qos-priority qos_established_connection 2>/dev/null || true
    nft add chain inet gargoyle-qos-priority qos_dynamic_classify 2>/dev/null || true
    nft add chain inet gargoyle-qos-priority qos_dynamic_classify_reply 2>/dev/null || true
    nft add chain inet gargoyle-qos-priority qos_bulk_client 2>/dev/null || true
    nft add chain inet gargoyle-qos-priority qos_bulk_client_reply 2>/dev/null || true

    if ! check_meter_support; then
        qos_log "WARN" "内核不支持 nftables meter 关键字，动态分类 bulk_client 功能将禁用"
        return 0
    fi

    # 修正 meter 语法：将 limit rate over 移到花括号外面
    nft add rule inet gargoyle-qos-priority qos_established_connection meter qos_bulk_detect { ip daddr . th dport . meta l4proto timeout 5s } limit rate over $((min_connections - 1))/minute add @qos_bulk_clients { ip daddr . th dport . meta l4proto timeout 30s } 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_established_connection meter qos_bulk_detect6 { ip6 daddr . th dport . meta l4proto timeout 5s } limit rate over $((min_connections - 1))/minute add @qos_bulk_clients6 { ip6 daddr . th dport . meta l4proto timeout 30s } 2>/dev/null || true

    # 同时设置 meta mark 和 ct mark
    nft add rule inet gargoyle-qos-priority qos_bulk_client meter qos_bulk_orig { ip saddr . th sport . meta l4proto timeout 5m } limit rate over $((min_bytes - 1)) bytes/hour update @qos_bulk_clients { ip saddr . th sport . meta l4proto timeout 5m } meta mark set $dscp ct mark set meta mark return 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_bulk_client meter qos_bulk_orig6 { ip6 saddr . th sport . meta l4proto timeout 5m } limit rate over $((min_bytes - 1)) bytes/hour update @qos_bulk_clients6 { ip6 saddr . th sport . meta l4proto timeout 5m } meta mark set $dscp ct mark set meta mark return 2>/dev/null || true

    nft add rule inet gargoyle-qos-priority qos_bulk_client_reply meter qos_bulk_reply { ip daddr . th dport . meta l4proto timeout 5m } limit rate over $((min_bytes - 1)) bytes/hour update @qos_bulk_clients { ip daddr . th dport . meta l4proto timeout 5m } meta mark set $dscp ct mark set meta mark return 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_bulk_client_reply meter qos_bulk_reply6 { ip6 daddr . th dport . meta l4proto timeout 5m } limit rate over $((min_bytes - 1)) bytes/hour update @qos_bulk_clients6 { ip6 daddr . th dport . meta l4proto timeout 5m } meta mark set $dscp ct mark set meta mark return 2>/dev/null || true

    nft add rule inet gargoyle-qos-priority qos_dynamic_classify ct mark & 0x3f == 0 ip saddr . th sport . meta l4proto @qos_bulk_clients goto qos_bulk_client 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_dynamic_classify ct mark & 0x3f == 0 ip6 saddr . th sport . meta l4proto @qos_bulk_clients6 goto qos_bulk_client 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_dynamic_classify_reply ct mark & 0x3f == 0 ip daddr . th dport . meta l4proto @qos_bulk_clients goto qos_bulk_client_reply 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_dynamic_classify_reply ct mark & 0x3f == 0 ip6 daddr . th dport . meta l4proto @qos_bulk_clients6 goto qos_bulk_client_reply 2>/dev/null || true

    qos_log "INFO" "bulk_client_detection enabled: min_conn=$min_connections, min_bytes=$min_bytes, class=$class (DSCP=$dscp)"
}

# 修复：high_throughput 规则，meter 语法修正，同时设置 meta mark 和 ct mark
create_high_throughput_service_rules() {
    local enabled=1 min_bytes=1000000 min_connections=3 class="realtime"
    
    local htp_section="htp_detect"
    local uci_enabled=$(uci -q get ${CONFIG_FILE}.${htp_section}.enabled 2>/dev/null)
    [ -n "$uci_enabled" ] && enabled="$uci_enabled"
    local uci_min_bytes=$(uci -q get ${CONFIG_FILE}.${htp_section}.min_bytes 2>/dev/null)
    [ -n "$uci_min_bytes" ] && min_bytes="$uci_min_bytes"
    local uci_min_connections=$(uci -q get ${CONFIG_FILE}.${htp_section}.min_connections 2>/dev/null)
    [ -n "$uci_min_connections" ] && min_connections="$uci_min_connections"
    local uci_class=$(uci -q get ${CONFIG_FILE}.${htp_section}.class 2>/dev/null)
    [ -n "$uci_class" ] && class="$uci_class"

    [ "$enabled" != "1" ] && return 0
    [ "$min_bytes" -le 0 ] && min_bytes=1000000
    [ "$min_connections" -le 1 ] && min_connections=3

    local dscp=$(get_class_mark_for_dynamic "$class")
    if [ -z "$dscp" ] || [ "$dscp" -eq 0 ]; then
        qos_log "WARN" "high_throughput_service_detection: class '$class' not found or class_mark=0, using default 46 (EF)"
        dscp=46
    fi

    if ! check_meter_support; then
        qos_log "WARN" "内核不支持 nftables meter 关键字，动态分类 high_throughput_service 功能将禁用"
        return 0
    fi

    nft add set inet gargoyle-qos-priority qos_high_throughput_services '{ type ipv4_addr . ipv4_addr . inet_service . inet_proto; flags timeout; }' 2>/dev/null || true
    nft add set inet gargoyle-qos-priority qos_high_throughput_services6 '{ type ipv6_addr . ipv6_addr . inet_service . inet_proto; flags timeout; }' 2>/dev/null || true

    nft add chain inet gargoyle-qos-priority qos_high_throughput_service 2>/dev/null || true
    nft add chain inet gargoyle-qos-priority qos_high_throughput_service_reply 2>/dev/null || true

    # 修正 meter 语法
    nft add rule inet gargoyle-qos-priority qos_established_connection meter qos_htp_detect { ip daddr . ip saddr and 255.255.255.0 . th sport . meta l4proto timeout 5s } limit rate over $((min_connections - 1))/minute add @qos_high_throughput_services { ip daddr . ip saddr and 255.255.255.0 . th sport . meta l4proto timeout 30s } 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_established_connection meter qos_htp_detect6 { ip6 daddr . ip6 saddr and ffff:ffff:ffff:: . th sport . meta l4proto timeout 5s } limit rate over $((min_connections - 1))/minute add @qos_high_throughput_services6 { ip6 daddr . ip6 saddr and ffff:ffff:ffff:: . th sport . meta l4proto timeout 30s } 2>/dev/null || true

    nft add rule inet gargoyle-qos-priority qos_high_throughput_service ct bytes original < $min_bytes return 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_high_throughput_service update @qos_high_throughput_services { ip saddr . ip daddr and 255.255.255.0 . th dport . meta l4proto timeout 5m } 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_high_throughput_service update @qos_high_throughput_services6 { ip6 saddr . ip6 daddr and ffff:ffff:ffff:: . th dport . meta l4proto timeout 5m } 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_high_throughput_service meta mark set $dscp ct mark set meta mark return 2>/dev/null || true

    nft add rule inet gargoyle-qos-priority qos_high_throughput_service_reply ct bytes reply < $min_bytes return 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_high_throughput_service_reply update @qos_high_throughput_services { ip daddr . ip saddr and 255.255.255.0 . th sport . meta l4proto timeout 5m } 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_high_throughput_service_reply update @qos_high_throughput_services6 { ip6 daddr . ip6 saddr and ffff:ffff:ffff:: . th sport . meta l4proto timeout 5m } 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_high_throughput_service_reply meta mark set $dscp ct mark set meta mark return 2>/dev/null || true

    nft add rule inet gargoyle-qos-priority qos_dynamic_classify ct mark & 0x3f == 0 ip saddr . ip daddr and 255.255.255.0 . th dport . meta l4proto @qos_high_throughput_services goto qos_high_throughput_service 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_dynamic_classify ct mark & 0x3f == 0 ip6 saddr . ip6 daddr and ffff:ffff:ffff:: . th dport . meta l4proto @qos_high_throughput_services6 goto qos_high_throughput_service 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_dynamic_classify_reply ct mark & 0x3f == 0 ip daddr . ip saddr and 255.255.255.0 . th sport . meta l4proto @qos_high_throughput_services goto qos_high_throughput_service_reply 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority qos_dynamic_classify_reply ct mark & 0x3f == 0 ip6 daddr . ip6 saddr and ffff:ffff:ffff:: . th sport . meta l4proto @qos_high_throughput_services6 goto qos_high_throughput_service_reply 2>/dev/null || true

    qos_log "INFO" "high_throughput_service_detection enabled: min_conn=$min_connections, min_bytes=$min_bytes, class=$class (DSCP=$dscp)"
}

setup_dynamic_classification() {
    qos_log "INFO" "初始化动态分类链..."
    nft add chain inet gargoyle-qos-priority qos_established_connection 2>/dev/null || true
    nft add chain inet gargoyle-qos-priority qos_dynamic_classify 2>/dev/null || true
    nft add chain inet gargoyle-qos-priority qos_dynamic_classify_reply 2>/dev/null || true

    # 使用 insert rule 确保动态分类在静态分类之前执行
    nft insert rule inet gargoyle-qos-priority filter_input ct mark & 0x3f == 0 jump qos_dynamic_classify 2>/dev/null || true
    nft insert rule inet gargoyle-qos-priority filter_output ct mark & 0x3f == 0 jump qos_dynamic_classify 2>/dev/null || true
    nft insert rule inet gargoyle-qos-priority filter_forward ct mark & 0x3f == 0 jump qos_dynamic_classify 2>/dev/null || true
    nft insert rule inet gargoyle-qos-priority filter_forward ct mark & 0x3f == 0 jump qos_dynamic_classify_reply 2>/dev/null || true

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
    if ! nft list table inet gargoyle-qos-priority &>/dev/null; then
        qos_log "INFO" "nft 表不存在，将重新初始化"
        _QOS_TABLE_FLUSHED=0
        _IPSET_LOADED=0
        _HOOKS_SETUP=0
        _SET_FAMILY_CACHE=()
    fi
    if [[ $_QOS_TABLE_FLUSHED -eq 0 ]]; then
        qos_log "INFO" "初始化 nftables 表"
        nft add table inet gargoyle-qos-priority 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop995 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop95 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop50 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority $RATELIMIT_CHAIN 2>/dev/null || true
        nft add chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null || true
        nft add chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null || true
        generate_ipset_sets
        local sets_ok=1
        for set in qos_xfst_ack qos_fast_ack qos_med_ack qos_slow_ack qos_slow_tcp; do
            if ! nft list set inet gargoyle-qos-priority "$set" &>/dev/null; then
                if ! nft add set inet gargoyle-qos-priority "$set" '{ typeof ct id . ct direction; flags dynamic; timeout 5m; }' 2>/dev/null; then
                    sets_ok=0
                fi
            fi
        done
        if [[ $sets_ok -eq 0 ]]; then
            qos_log "ERROR" "动态集合创建失败，ACK 限速和 TCP 升级功能将被禁用"
            ENABLE_ACK_LIMIT=0
            ENABLE_TCP_UPGRADE=0
        fi
        nft add chain inet gargoyle-qos-priority drop995 2>/dev/null || true
        nft add chain inet gargoyle-qos-priority drop95 2>/dev/null || true
        nft add chain inet gargoyle-qos-priority drop50 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop995 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop95 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop50 2>/dev/null || true
        nft add rule inet gargoyle-qos-priority drop995 numgen random mod 1000 ge 995 return
        nft add rule inet gargoyle-qos-priority drop995 drop
        nft add rule inet gargoyle-qos-priority drop95 numgen random mod 1000 ge 950 return
        nft add rule inet gargoyle-qos-priority drop95 drop
        nft add rule inet gargoyle-qos-priority drop50 numgen random mod 1000 ge 500 return
        nft add rule inet gargoyle-qos-priority drop50 drop
        _QOS_TABLE_FLUSHED=1
    fi
    if [[ $_HOOKS_SETUP -eq 0 ]]; then
        qos_log "INFO" "挂载 nftables 钩子链"
        local wan_if=$(get_wan_interface)
        if [[ -z "$wan_if" ]]; then
            qos_log "ERROR" "无法获取 WAN 接口，钩子链可能不完整，QoS 可能无法正确区分方向"
            qos_log "WARN" "未配置 WAN 接口，将不使用方向区分，所有转发流量同时进入上传和下载链（可能导致双重标记）"
            nft add chain inet gargoyle-qos-priority filter_forward '{ type filter hook forward priority 0; policy accept; }' 2>/dev/null || true
            nft flush chain inet gargoyle-qos-priority filter_forward 2>/dev/null || true
            nft add rule inet gargoyle-qos-priority filter_forward jump filter_qos_egress 2>/dev/null || true
            nft add rule inet gargoyle-qos-priority filter_forward jump filter_qos_ingress 2>/dev/null || true
        else
            qos_log "INFO" "使用 WAN 接口: $wan_if"
            nft add chain inet gargoyle-qos-priority filter_output '{ type filter hook output priority 0; policy accept; }' 2>/dev/null || true
            nft add chain inet gargoyle-qos-priority filter_input  '{ type filter hook input priority 0; policy accept; }' 2>/dev/null || true
            nft add chain inet gargoyle-qos-priority filter_forward '{ type filter hook forward priority 0; policy accept; }' 2>/dev/null || true
            nft flush chain inet gargoyle-qos-priority filter_output 2>/dev/null || true
            nft flush chain inet gargoyle-qos-priority filter_input  2>/dev/null || true
            nft flush chain inet gargoyle-qos-priority filter_forward 2>/dev/null || true
            nft add rule inet gargoyle-qos-priority filter_output jump filter_qos_egress 2>/dev/null || true
            nft add rule inet gargoyle-qos-priority filter_forward oifname "$wan_if" jump filter_qos_egress 2>/dev/null || true
            nft add rule inet gargoyle-qos-priority filter_forward iifname "$wan_if" jump filter_qos_ingress 2>/dev/null || true
            nft add rule inet gargoyle-qos-priority filter_input jump filter_qos_ingress 2>/dev/null || true
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

# ========== 入口重定向 ==========
setup_ingress_redirect() {
    if [[ -z "$qos_interface" ]]; then
        qos_log "ERROR" "无法确定 WAN 接口"
        return 1
    fi
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
    if [[ -n "$ipv6_action" ]]; then
        if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
            flower dst_ip "$ipv6_prefix" \
            $ipv6_action \
            action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
            ipv6_success=true
            qos_log "INFO" "IPv6入口重定向规则（flower 前缀 $ipv6_prefix，带标记）添加成功"
        else
            qos_log "WARN" "flower 带标记规则失败，尝试无标记 flower"
        fi
    fi
    if [[ "$ipv6_success" != "true" ]]; then
        if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
            flower dst_ip "$ipv6_prefix" \
            action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
            ipv6_success=true
            qos_log "INFO" "IPv6入口重定向规则（flower 前缀 $ipv6_prefix，无标记）添加成功"
        else
            qos_log "WARN" "flower 无标记规则失败"
        fi
    fi

    if [[ "$ipv6_success" != "true" ]] && [[ "$ipv6_prefix" == "2000::/3" ]]; then
        if [[ -n "$ipv6_action" ]]; then
            if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                u32 match u32 0x20000000 0xe0000000 at 24 \
                $ipv6_action \
                action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                ipv6_success=true
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
                qos_log "INFO" "IPv6入口重定向规则（u32 全球单播，无标记）添加成功"
            else
                qos_log "WARN" "u32 全球单播无标记规则失败"
            fi
        fi
    fi

    if [[ "$ipv6_success" != "true" ]]; then
        if [[ -n "$ipv6_action" ]]; then
            if tc filter add dev "$qos_interface" parent ffff: protocol ipv6 \
                u32 match u32 0 0 \
                $ipv6_action \
                action mirred egress redirect dev "$IFB_DEVICE" 2>&1; then
                ipv6_success=true
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
                qos_log "INFO" "IPv6入口重定向规则（u32 全匹配，无标记）添加成功"
            else
                qos_log "WARN" "IPv6全匹配回退规则添加失败"
            fi
        fi
    fi

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
    nft add chain inet gargoyle-qos-priority filter_prerouting '{ type filter hook prerouting priority 0; policy accept; }' 2>/dev/null || true
    nft flush chain inet gargoyle-qos-priority filter_prerouting 2>/dev/null || true
    local ICMPV6_CRITICAL_TYPES="133,134,135,136,137"
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 daddr { ff02::1:2, ff02::1:3 } meta mark set 0x80000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 daddr ::1 meta mark set 0x80000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 icmpv6 type { $ICMPV6_CRITICAL_TYPES } meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport { 546, 547 } meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport 53 meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 tcp dport 53 meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 tcp dport { 80, 443 } meta mark set 0x40000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport 123 meta mark set 0x40000000 counter 2>/dev/null || true
    qos_log "INFO" "IPv6关键流量规则设置完成"
}

# ========== 健康检查 ==========
health_check() {
    local errors=0 status=""
    uci -q show ${CONFIG_FILE} >/dev/null 2>&1 && status="${status}config:ok;" || { status="${status}config:missing;"; ((errors++)); }
    nft list table inet gargoyle-qos-priority >/dev/null 2>&1 && status="${status}nft:ok;" || { status="${status}nft:missing;"; ((errors++)); }
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
