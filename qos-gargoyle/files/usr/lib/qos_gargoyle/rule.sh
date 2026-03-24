#!/bin/bash
# 规则辅助模块 (rule.sh)
# 版本: 3.2.9
# 提供 nftables 规则生成与系统钩子挂载

# 加载核心库
if [[ -f "/usr/lib/qos_gargoyle/lib.sh" ]]; then
    . /usr/lib/qos_gargoyle/lib.sh
else
    echo "错误: 核心库 /usr/lib/qos_gargoyle/lib.sh 未找到" >&2
    exit 1
fi

# ========== 辅助函数：调整协议以适应地址族 ==========
adjust_proto_for_family() {
    local proto="$1"
    local family="$2"
    local adjusted="$proto"
    
    # 空协议或 all 保持原样
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
            # inet 族保持原样，但需确保协议在 inet 下有效
            if [[ "$proto" == "icmp" ]]; then
                adjusted="icmp"
            elif [[ "$proto" == "icmpv6" ]]; then
                adjusted="icmpv6"
            fi
            ;;
    esac
    echo "$adjusted"
}

# ========== 拆分多集合字段（如 @set1,@set2）为数组 ==========
split_multiset() {
    local field="$1"
    local result=()
    if [[ "$field" == @* && "$field" == *,* ]]; then
        IFS=',' read -ra parts <<< "$field"
        for part in "${parts[@]}"; do
            result+=("$part")
        done
    else
        result+=("$field")
    fi
    printf '%s\n' "${result[@]}"
}

# ========== 通用规则构建函数 ==========
# 参数：规则名称、链名、类标记、掩码、family、proto、srcport、dstport、connbytes_kb、state、src_ip、dest_ip、packet_len、tcp_flags、iif、oif、udp_length、dscp、ttl、icmp_type
# 返回：输出一条或多条 nft 规则（通过 echo）
build_nft_rule_generic() {
    local rule_name="$1" chain="$2" class_mark="$3" mask="$4" family="$5" proto="$6"
    local srcport="$7" dstport="$8" connbytes_kb="$9" state="${10}" src_ip="${11}" dest_ip="${12}"
    local packet_len="${13}" tcp_flags="${14}" iif="${15}" oif="${16}" udp_length="${17}"
    local dscp="${18}" ttl="${19}" icmp_type="${20}"
    
    # 调整协议以适应地址族
    proto=$(adjust_proto_for_family "$proto" "$family")
    
    # 如果协议调整为空（不匹配），跳过该规则
    if [[ -z "$proto" ]]; then
        log_warn "规则 $rule_name: 协议与地址族不匹配，跳过"
        return
    fi
    
    local ipv4_rules=()
    local ipv6_rules=()
    
    # 辅助函数：添加一条 IPv4 规则
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
    
    # 辅助函数：添加一条 IPv6 规则
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
    
    # 构建通用条件
    local common_cond=""
    case "$proto" in
        tcp) common_cond="meta l4proto tcp" ;;
        udp) common_cond="meta l4proto udp" ;;
        tcp_udp) common_cond="meta l4proto { tcp, udp }" ;;
        icmp|icmpv6|gre|esp|ah|sctp|dccp|udplite) common_cond="meta l4proto $proto" ;;
        all|"") ;;
        *) common_cond="meta l4proto $proto" ;;
    esac
    
    # 包长度条件
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
    
    # TCP 标志处理（支持部分否定）
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
        if [[ -n "$set_flags" ]] || [[ -n "$unset_flags" ]]; then
            local mask_all=""
            local mask_set=""
            if [[ -n "$set_flags" ]]; then
                mask_set="$set_flags"
                mask_all="$set_flags"
            fi
            if [[ -n "$unset_flags" ]]; then
                if [[ -n "$mask_all" ]]; then
                    mask_all="$mask_all,$unset_flags"
                else
                    mask_all="$unset_flags"
                fi
            fi
            if [[ -n "$set_flags" ]] && [[ -n "$unset_flags" ]]; then
                tcp_flag_expr="tcp flags & ( $mask_all ) == $mask_set"
            elif [[ -n "$set_flags" ]]; then
                tcp_flag_expr="tcp flags { $set_flags }"
            elif [[ -n "$unset_flags" ]]; then
                tcp_flag_expr="tcp flags & ( $unset_flags ) == 0"
            fi
        fi
    fi
    if [[ -n "$tcp_flag_expr" ]]; then
        common_cond="$common_cond $tcp_flag_expr"
    fi
    
    # 接口条件
    [[ -n "$iif" ]] && common_cond="$common_cond iifname \"$iif\""
    [[ -n "$oif" ]] && common_cond="$common_cond oifname \"$oif\""
    
    # UDP 长度条件
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
    
    # 端口条件（注意方向）
    local port_cond=""
    if [[ "$proto" =~ ^(tcp|udp|tcp_udp)$ ]]; then
        if [[ "$chain" == *"ingress"* ]]; then
            if [[ -n "$srcport" ]]; then
                if [[ "$srcport" == @* ]]; then
                    port_cond="th sport $srcport"
                else
                    port_cond="th sport { $srcport }"
                fi
            fi
        else
            if [[ -n "$dstport" ]]; then
                if [[ "$dstport" == @* ]]; then
                    port_cond="th dport $dstport"
                else
                    port_cond="th dport { $dstport }"
                fi
            fi
        fi
        if [[ -n "$port_cond" ]]; then
            common_cond="$common_cond $port_cond"
        fi
    fi
    
    # 连接状态
    if [[ -n "$state" ]]; then
        local state_value="${state//[{}]/}"
        if [[ "$state_value" == *,* ]]; then
            common_cond="$common_cond ct state { $state_value }"
        else
            common_cond="$common_cond ct state $state_value"
        fi
    fi
    
    # 连接字节数
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
    
    # 辅助函数：将 ::mask 格式转换为十六进制数值
    ipv6_mask_to_hex() {
        local mask="$1"
        local hex=""
        mask="${mask#::}"
        if [[ -z "$mask" ]]; then
            hex="0"
        else
            hex="0x$mask"
        fi
        echo "$hex"
    }
    
    # 辅助函数：处理源/目的 IP 并生成对应的 IP 条件
    process_ip_field() {
        local ip_val="$1" direction="$2" # direction: "saddr" or "daddr"
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
            elif [[ "$val" =~ ^::[0-9a-fA-F]+/::[0-9a-fA-F]+$ ]]; then
                local suffix="${val%%/::*}"
                local mask="${val#*/::}"
                local hex_mask=$(ipv6_mask_to_hex "$mask")
                ipv6_cond="ip6 $direction & $hex_mask == $suffix"
            elif [[ "$val" =~ : ]]; then
                ipv6_cond="ip6 $direction $neg $val"
            else
                ipv4_cond="ip $direction $neg $val"
            fi
        fi
        eval "$3=\"\$ipv4_cond\""
        eval "$4=\"\$ipv6_cond\""
    }
    
    # 处理源 IP 和目的 IP
    local src_ipv4_cond=""
    local src_ipv6_cond=""
    local dst_ipv4_cond=""
    local dst_ipv6_cond=""
    process_ip_field "$src_ip" "saddr" src_ipv4_cond src_ipv6_cond
    process_ip_field "$dest_ip" "daddr" dst_ipv4_cond dst_ipv6_cond
    
    # 根据 family 决定生成哪些规则
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
    
    # 生成 IPv4 规则
    if (( has_ipv4 )); then
        local ipv4_full_cond="$common_cond"
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
        if [[ -n "$icmp_type" ]] && [[ "$proto" == "icmp" ]]; then
            local icmp_val="$icmp_type"
            local neg=""
            [[ "$icmp_val" == "!="* ]] && { neg="!="; icmp_val="${icmp_val#!=}"; }
            if [[ "$icmp_val" == */* ]]; then
                local type="${icmp_val%/*}" code="${icmp_val#*/}"
                ipv4_full_cond="$ipv4_full_cond icmp type $neg $type icmp code $code"
            else
                ipv4_full_cond="$ipv4_full_cond icmp type $neg $icmp_val"
            fi
        fi
        add_ipv4_rule "$ipv4_full_cond"
    fi
    
    # 生成 IPv6 规则
    if (( has_ipv6 )); then
        local ipv6_full_cond="$common_cond"
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
        if [[ -n "$icmp_type" ]] && [[ "$proto" == "icmpv6" ]]; then
            local icmp_val="$icmp_type"
            local neg=""
            [[ "$icmp_val" == "!="* ]] && { neg="!="; icmp_val="${icmp_val#!=}"; }
            if [[ "$icmp_val" == */* ]]; then
                local type="${icmp_val%/*}" code="${icmp_val#*/}"
                ipv6_full_cond="$ipv6_full_cond icmpv6 type $neg $type icmpv6 code $code"
            else
                ipv6_full_cond="$ipv6_full_cond icmpv6 type $neg $icmp_val"
            fi
        fi
        add_ipv6_rule "$ipv6_full_cond"
    fi
    
    # 输出所有规则
    for rule in "${ipv4_rules[@]}"; do
        echo "$rule"
    done
    for rule in "${ipv6_rules[@]}"; do
        echo "$rule"
    done
}

# ========== 增强规则应用 ==========
apply_enhanced_direction_rules() {
    local rule_type="$1" chain="$2" mask="$3"
    log_info "应用增强$rule_type规则到链: $chain, 掩码: $mask"

    nft add chain inet gargoyle-qos-priority "$chain" 2>/dev/null || true
    nft flush chain inet gargoyle-qos-priority "$chain" 2>/dev/null || true

    local direction=""
    [[ "$chain" == "filter_qos_egress" ]] && direction="upload"
    [[ "$chain" == "filter_qos_ingress" ]] && direction="download"

    local rule_list=$(load_all_config_sections "$CONFIG_FILE" "$rule_type")
    [[ -z "$rule_list" ]] && { log_info "未找到$rule_type规则配置"; return 0; }
    log_info "找到$rule_type规则: $rule_list"

    local class_priority_map
    declare -A class_priority_map
    local class_list=""
    [[ "$direction" == "upload" ]] && class_list="$upload_class_list"
    [[ "$direction" == "download" ]] && class_list="$download_class_list"
    for class in $class_list; do
        local prio=$(uci -q get ${CONFIG_FILE}.${class}.priority 2>/dev/null)
        class_priority_map["$class"]=${prio:-999}
    done

    local rule_prio_file=$(mktemp)
    TEMP_FILES+=("$rule_prio_file")

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
        log_info "没有可用的启用规则"
        return 0
    fi

    # 集合存在性验证
    local all_sets=()
    for rule_name in $sorted_rule_list; do
        if ! load_all_config_options "$CONFIG_FILE" "$rule_name" "tmp_"; then
            continue
        fi
        [[ "$tmp_enabled" != "1" ]] && continue
        for field in src_ip dest_ip; do
            local val="${tmp_$field}"
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
            log_error "以下集合不存在于 nftables 表中: ${missing_sets[*]}，请检查 UCI ipset 配置"
            return 1
        fi
        log_info "所有引用的集合验证通过"
    fi

    local nft_batch_file=$(mktemp /tmp/qos_nft_batch_XXXXXX)
    TEMP_FILES+=("$nft_batch_file")

    log_info "按优先级顺序生成nft规则..."
    local rule_count=0
    for rule_name in $sorted_rule_list; do
        if ! load_all_config_options "$CONFIG_FILE" "$rule_name" "tmp_"; then
            continue
        fi
        [[ "$tmp_enabled" == "1" ]] || continue

        local class_mark=$(get_class_mark "$direction" "$tmp_class")
        [[ -z "$class_mark" ]] && { log_error "规则 $rule_name 的类 $tmp_class 无法获取标记，跳过"; continue; }
        [[ -z "$tmp_family" ]] && tmp_family="inet"

        # 处理多集合引用的端口字段
        local srcport_list=()
        local dstport_list=()
        local src_ip_list=()
        local dest_ip_list=()

        if [[ -n "$tmp_srcport" ]]; then
            mapfile -t srcport_list < <(split_multiset "$tmp_srcport")
        else
            srcport_list=("")
        fi
        if [[ -n "$tmp_dstport" ]]; then
            mapfile -t dstport_list < <(split_multiset "$tmp_dstport")
        else
            dstport_list=("")
        fi
        if [[ -n "$tmp_src_ip" ]]; then
            mapfile -t src_ip_list < <(split_multiset "$tmp_src_ip")
        else
            src_ip_list=("")
        fi
        if [[ -n "$tmp_dest_ip" ]]; then
            mapfile -t dest_ip_list < <(split_multiset "$tmp_dest_ip")
        else
            dest_ip_list=("")
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

    local custom_inline_file="$CUSTOM_INLINE_FILE"
    if [[ -s "$custom_inline_file" ]]; then
        log_info "验证自定义内联规则: $custom_inline_file"
        if validate_inline_rules "$custom_inline_file"; then
            log_info "自定义内联规则语法正确: $custom_inline_file"
            echo "include \"$custom_inline_file\";" >> "$nft_batch_file"
            ((rule_count++))
        else
            log_warn "自定义内联规则文件 $custom_inline_file 语法错误，已忽略"
        fi
    fi

    local batch_success=0
    if [[ -s "$nft_batch_file" ]]; then
        log_info "执行批量nft规则 (共 $rule_count 条)..."
        local nft_output
        nft_output=$(nft -f "$nft_batch_file" 2>&1)
        local nft_ret=$?
        if [[ $nft_ret -eq 0 ]]; then
            log_info "✅ 批量规则应用成功"
            if [[ $SAVE_NFT_RULES -eq 1 ]]; then
                mkdir -p /etc/nftables.d
                local nft_save_file="/etc/nftables.d/qos_gargoyle_${chain}.nft"
                cp "$nft_batch_file" "$nft_save_file"
                log_info "规则已保存到 $nft_save_file"
            fi
        else
            log_error "❌ 批量规则应用失败 (退出码: $nft_ret)"
            log_error "nft 错误输出: $nft_output"
            batch_success=1
        fi
    fi

    rm -f "$nft_batch_file"
    return $batch_success
}

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

# ========== 应用所有规则（包括钩子挂载和辅助功能） ==========
apply_all_rules() {
    local rule_type="$1" mask="$2" chain="$3"
    log_info "开始应用 $rule_type 规则到链 $chain (掩码: $mask)"

    if ! nft list table inet gargoyle-qos-priority &>/dev/null; then
        log_info "nft 表不存在，将重新初始化"
        _QOS_TABLE_FLUSHED=0
        _IPSET_LOADED=0
        _HOOKS_SETUP=0
        _SET_FAMILY_CACHE=()
    fi

    if [[ $_QOS_TABLE_FLUSHED -eq 0 ]]; then
        log_info "初始化 nftables 表"
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

        # 创建动态集合，并检测是否成功
        local sets_ok=1
        for set in _qos_xfst_ack _qos_fast_ack _qos_med_ack _qos_slow_ack _qos_slow_tcp; do
            if ! nft list set inet gargoyle-qos-priority "$set" &>/dev/null; then
                nft add set inet gargoyle-qos-priority "$set" '{ typeof ct id . ct direction; flags dynamic; timeout 5m; }' 2>/dev/null || sets_ok=0
            fi
        done

        if [[ $sets_ok -eq 0 ]]; then
            log_error "动态集合创建失败，ACK 限速和 TCP 升级功能将被禁用"
            # 全局禁用相关功能，避免后续错误
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
        log_info "挂载 nftables 钩子链"

        local wan_if=$(get_wan_interface)
        if [[ -z "$wan_if" ]]; then
            log_error "无法获取 WAN 接口，钩子链可能不完整，QoS 可能无法正确区分方向"
        else
            log_info "使用 WAN 接口: $wan_if"
        fi

        nft add chain inet gargoyle-qos-priority filter_output '{ type filter hook output priority 0; policy accept; }' 2>/dev/null || true
        nft add chain inet gargoyle-qos-priority filter_input  '{ type filter hook input priority 0; policy accept; }' 2>/dev/null || true
        nft add chain inet gargoyle-qos-priority filter_forward '{ type filter hook forward priority 0; policy accept; }' 2>/dev/null || true

        nft flush chain inet gargoyle-qos-priority filter_output 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority filter_input  2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority filter_forward 2>/dev/null || true

        nft add rule inet gargoyle-qos-priority filter_output jump filter_qos_egress 2>/dev/null || true
        if [[ -n "$wan_if" ]]; then
            nft add rule inet gargoyle-qos-priority filter_forward oifname "$wan_if" jump filter_qos_egress 2>/dev/null || true
            nft add rule inet gargoyle-qos-priority filter_forward iifname "$wan_if" jump filter_qos_ingress 2>/dev/null || true
        else
            log_warn "未配置 WAN 接口，将不使用方向区分，所有转发流量同时进入上传和下载链（可能导致双重标记）"
            nft add rule inet gargoyle-qos-priority filter_forward jump filter_qos_egress 2>/dev/null || true
            nft add rule inet gargoyle-qos-priority filter_forward jump filter_qos_ingress 2>/dev/null || true
        fi
        nft add rule inet gargoyle-qos-priority filter_input jump filter_qos_ingress 2>/dev/null || true

        _HOOKS_SETUP=1
        log_info "nftables 钩子链挂载完成"
    fi

    if [[ $_UCI_CONFIG_CACHED -eq 0 ]]; then
        _UCI_CACHE_FILE=$(mktemp)
        TEMP_FILES+=("$_UCI_CACHE_FILE")
        uci -X export ${CONFIG_FILE} > "$_UCI_CACHE_FILE" 2>/dev/null
        if [[ -s "$_UCI_CACHE_FILE" ]]; then
            source "$_UCI_CACHE_FILE"
            _UCI_CONFIG_CACHED=1
            log_debug "已加载 UCI 配置缓存"
        else
            log_warn "无法导出 UCI 配置，将回退到单次查询模式"
            _UCI_CONFIG_CACHED=2
        fi
    fi

    # 应用增强规则，如果失败则返回错误，不继续加载其他规则
    if ! apply_enhanced_direction_rules "$rule_type" "$chain" "$mask"; then
        log_error "应用 $rule_type 规则失败"
        # 清理已挂载的钩子链？但停止函数会清理整个表，这里先返回错误
        return 1
    fi

    # 加载自定义完整表规则（不影响返回码，即使失败也不终止）
    load_custom_full_table

    # 应用 ACK 限速规则
    if [[ $ENABLE_ACK_LIMIT -eq 1 ]]; then
        local ack_rules=$(generate_ack_limit_rules)
        if [[ -n "$ack_rules" ]]; then
            local ack_file=$(mktemp)
            TEMP_FILES+=("$ack_file")
            echo "$ack_rules" | while IFS= read -r rule; do
                [[ -z "$rule" ]] && continue
                echo "${rule/add rule/insert rule}" >> "$ack_file"
            done
            nft -f "$ack_file" 2>/dev/null || log_warn "应用 ACK 限速规则失败"
        fi
    fi

    # 应用 TCP 升级规则
    if [[ $ENABLE_TCP_UPGRADE -eq 1 ]]; then
        local tcp_upgrade_rules=$(generate_tcp_upgrade_rules)
        if [[ -n "$tcp_upgrade_rules" ]]; then
            local tcp_file=$(mktemp)
            TEMP_FILES+=("$tcp_file")
            echo "$tcp_upgrade_rules" | while IFS= read -r rule; do
                [[ -z "$rule" ]] && continue
                echo "${rule/add rule/insert rule}" >> "$tcp_file"
            done
            nft -f "$tcp_file" 2>/dev/null || log_warn "应用 TCP 升级规则失败"
        fi
    fi

    return 0
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
    for mod in ifb sch_htb sch_hfsc sch_cake sch_fq_codel; do
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

# ========== 内存限制计算 ==========
calculate_memory_limit() {
    local config_value="$1" result
    [[ -z "$config_value" ]] && { echo ""; return; }
    if [[ "$config_value" == "auto" ]]; then
        local total_mem_mb=0
        if [[ -f /sys/fs/cgroup/memory.max ]]; then
            local total_mem_bytes=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
            if [[ "$total_mem_bytes" =~ ^[0-9]+$ ]] && (( total_mem_bytes > 0 )); then
                total_mem_mb=$(( total_mem_bytes / 1024 / 1024 ))
                log_info "从 cgroup v2 memory.max 获取内存限制: ${total_mem_mb}MB"
            fi
        fi
        if (( total_mem_mb == 0 )) && [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
            local total_mem_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
            if [[ -n "$total_mem_bytes" ]] && (( total_mem_bytes > 0 )); then
                total_mem_mb=$(( total_mem_bytes / 1024 / 1024 ))
                log_info "从 cgroup v1 memory.limit_in_bytes 获取内存限制: ${total_mem_mb}MB"
            fi
        fi
        if (( total_mem_mb == 0 )); then
            local total_mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
            if [[ -n "$total_mem_kb" ]] && (( total_mem_kb > 0 )); then
                total_mem_mb=$(( total_mem_kb / 1024 ))
                log_info "从 /proc/meminfo 获取内存: ${total_mem_mb}MB"
            fi
        fi
        if (( total_mem_mb > 0 )); then
            result="$(((total_mem_mb + 63) / 64))Mb"
            local min_limit=8 max_limit=32
            local result_value=${result%Mb}
            if (( result_value < min_limit )); then result="${min_limit}Mb"
            elif (( result_value > max_limit )); then result="${max_limit}Mb"; fi
            log_info "系统内存 ${total_mem_mb}MB，自动计算 memlimit=${result}"
        else
            log_warn "无法读取内存信息，使用默认值 16Mb"; result="16Mb"
        fi
    else
        if [[ "$config_value" =~ ^[0-9]+Mb$ ]]; then
            result="$config_value"; log_info "使用用户配置的 memlimit: ${result}"
        else
            log_warn "无效的 memlimit 格式 '$config_value'，使用默认值 16Mb"; result="16Mb"
        fi
    fi
    echo "$result"
}

# ========== IPv6增强支持 ==========
setup_ipv6_specific_rules() {
    log_info "设置IPv6特定规则（优化版）"
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
    log_info "IPv6关键流量规则设置完成"
}

# ========== 自动加载全局配置 ==========
if [[ -z "$_QOS_RULE_SH_LOADED" ]] && [[ "$(basename "$0")" != "rule.sh" ]]; then
    load_global_config
    _QOS_RULE_SH_LOADED=1
fi
