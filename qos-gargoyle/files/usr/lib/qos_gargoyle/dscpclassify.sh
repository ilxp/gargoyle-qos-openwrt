#!/bin/sh
# dscpclassify_core.sh - 修复 meter 名称问题，完整规则解析版本
# 用于 qos_gargoyle 集成
# 使用方法: . /path/to/dscpclassify_core.sh
#           dscpclassify_load <lan_iface> <wan_iface>
#           dscpclassify_unload

SERVICE_NAME="dscpclassify"
TABLE="$SERVICE_NAME"
CONFIG_FILE="/etc/config/$SERVICE_NAME"

# 静态 nft 文件路径（必须存在）
MAIN="/etc/${SERVICE_NAME}.d/main.nft"
VERDICTS="/etc/${SERVICE_NAME}.d/verdicts.nft"
MAPS="/etc/${SERVICE_NAME}.d/maps.nft"

# 临时文件路径
INCLUDES_PATH="/tmp/etc/${SERVICE_NAME}.d"
PRE_INCLUDE="${INCLUDES_PATH}/pre-include.nft"
POST_INCLUDE="${INCLUDES_PATH}/post-include.nft"

# ---------- 常量定义（来自原生脚本） ----------
CLASS_BULK="cs1"
CLASS_LOW_EFFORT="le"
CLASS_HIGH_THROUGHPUT="af13"
DEFAULT_CLASS_LOW_EFFORT="$CLASS_LOW_EFFORT"
DEFAULT_CLASS_HIGH_THROUGHPUT="$CLASS_HIGH_THROUGHPUT"

CONFIG_CLIENT_CLASS_ADOPTION="client_class_adoption"
CONFIG_BULK_CLIENT_DETECTION="bulk_client_detection"
CONFIG_HIGH_THROUGHPUT_SERVICE_DETECTION="high_throughput_service_detection"
CONFIG_RULE="rule"
CONFIG_SET="set"

NFT_VAR_CLASS_LE="lephb"
NFT_VAR_CT_DSCP="ct_dscp"
NFT_VAR_CT_DYNAMIC="ct_dynamic"

FAMILY_IPV4="ipv4"
FAMILY_IPV6="ipv6"
ADDR_IPV4="${FAMILY_IPV4}_addr"
ADDR_IPV6="${FAMILY_IPV6}_addr"
ADDR_ETHER="ether_addr"

# 链名称（与 main.nft 一致）
CHAIN_CLIENT_CLASSIFY="client_classify"
CHAIN_DYNAMIC_CLASSIFY="dynamic_classify"
CHAIN_DYNAMIC_CLASSIFY_REPLY="${CHAIN_DYNAMIC_CLASSIFY}_reply"
CHAIN_ESTABLISHED_CONNECTION="established_connection"
CHAIN_BULK_CLIENT="bulk_client"
CHAIN_BULK_CLIENT_REPLY="${CHAIN_BULK_CLIENT}_reply"
CHAIN_HIGH_THROUGHPUT_SERVICE="high_throughput_service"
CHAIN_HIGH_THROUGHPUT_SERVICE_REPLY="${CHAIN_HIGH_THROUGHPUT_SERVICE}_reply"
CHAIN_RULE_CLASSIFY="rule_classify"

# 内置集合名称
SET_BULK_CLIENTS="bulk_clients"
SET_BULK_CLIENTS6="${SET_BULK_CLIENTS}6"
SET_HIGH_THROUGHPUT_SERVICES="high_throughput_services"
SET_HIGH_THROUGHPUT_SERVICES6="${SET_HIGH_THROUGHPUT_SERVICES}6"

# 内核兼容性常量
KERNEL_VERSION_DSCP_LE="5.13"
KERNEL_VERSION_NFT_DESTROY="6.3"

# ---------- 辅助函数（来自原生） ----------
log() {
    local level="$1" message="$2"
    logger -t "$SERVICE_NAME" -p "daemon.${level}" "$message"
    case "$level" in
        info|warning|err) echo "$message" >&2 ;;
    esac
}

check_minimum_kernel_release() {
    local minimum_release="$1"
    local current_release current_major current_minor minimum_major minimum_minor
    minimum_major=$(echo "$minimum_release" | awk -F '.' '{print $1}')
    minimum_minor=$(echo "$minimum_release" | awk -F '.' '{print $2}')
    current_release=$(uname -r)
    current_major=$(echo "$current_release" | awk -F '.' '{print $1}')
    current_minor=$(echo "$current_release" | awk -F '.' '{print $2}')
    if [ "$current_major" -gt "$minimum_major" ] || { [ "$current_major" = "$minimum_major" ] && [ "$current_minor" -ge "${minimum_minor:-0}" ]; }; then
        return 0
    fi 2>/dev/null
    return 1
}

determine_compatibility() {
    [ -z "$compat_nft_destroy" ] && {
        check_minimum_kernel_release "$KERNEL_VERSION_NFT_DESTROY" && compat_nft_destroy=1 || compat_nft_destroy=0
    }
    [ -z "$compat_dscp_le" ] && {
        check_minimum_kernel_release "$KERNEL_VERSION_DSCP_LE" && compat_dscp_le=1 || compat_dscp_le=0
    }
    return 0
}

destroy_table() {
    nft delete table inet "$TABLE" &>/dev/null
    return 0
}

delete_includes() {
    rm -rf "$INCLUDES_PATH"
}

cleanup_setup() {
    delete_includes
}

format_list() {
    local items="$1" delimiter="$2" encapsulator="$3" wrapper="$4"
    local list
    list=$(echo "$items" | tr '\n' ' ' | sed -e "s/^\s*/${encapsulator}/" -e "s/\s*$/${encapsulator}/" -e "s/\s\+/${encapsulator}${delimiter}${encapsulator}/g")
    case ${#wrapper} in
        0) echo "$list" ;;
        2) echo "${wrapper:0:1} ${list} ${wrapper:1:1}" ;;
        *) return 1 ;;
    esac
}

unique_list() {
    local items="$1"
    printf '%s\n' $items | sort -u
}

nft_element_list() {
    format_list "$1" ", " "" "{}"
}

nft_interface_list() {
    format_list "$1" ", " "\"" "{}"
}

nft_flag_list() {
    format_list "$1" ", "
}

nft_chain_exists() {
    nft -t list chain inet "$1" "$2" &>/dev/null
}

nft_set_exists() {
    nft -t list set inet "$1" "$2" &>/dev/null
}

nft_table_exists() {
    nft -t list table inet "$1" &>/dev/null
}

nft_script_compat() {
    local command="$1" table element
    table=$(echo "$command" | awk '{print $4}')
    element=$(echo "$command" | awk '{print $5}')
    case "$command" in
        "destroy chain "*) nft_chain_exists "$table" "$element" || return 1 ;;
        "destroy set "*) nft_set_exists "$table" "$element" || return 1 ;;
        "destroy table "*) nft_table_exists "$table" || return 1 ;;
    esac
    [ "$compat_nft_destroy" = 1 ] || command=$(echo "$command" | sed "s/^destroy /delete /")
    echo "$command"
    return 0
}

pre_include() {
    local command
    command=$(nft_script_compat "$1") || return 0
    echo "$command" >> "$PRE_INCLUDE"
}

post_include() {
    local command
    command=$(nft_script_compat "$1") || return 0
    echo "$command" >> "$POST_INCLUDE"
}

config_foreach_reverse() {
    local ___function="$1"
    local ___type="$2"
    shift 2
    for section in $(config_foreach echo "$___type" | sort -r); do
        "$___function" "$section" "$@"
    done
}

config_get_exclusive_section() {
    local type="${2:-$1}" variable="${2:+$1}"
    local section
    case "${type}${variable}" in *[!A-Za-z0-9_]*) return 1 ;; esac
    for _section in $(config_foreach echo "$type"); do
        [ -n "$section" ] && { log warning "Duplicate ${type} config section ignored"; break; }
        section="$_section"
    done
    [ -n "$variable" ] && { eval "${variable}=\${section}"; return 0; }
    echo "$section"
}

convert_duration_to_seconds() {
    local duration="$1"
    local seconds
    for component in $(echo "$duration" | sed -e 's/\([dhms]\)/\1 /g'); do
        case "$component" in
            *d) seconds=$((seconds + ${component::-1} * 86400)) || return 1 ;;
            *h) seconds=$((seconds + ${component::-1} * 3600)) || return 1 ;;
            *m) seconds=$((seconds + ${component::-1} * 60)) || return 1 ;;
            *s) seconds=$((seconds + ${component::-1})) || return 1 ;;
            *) return 1 ;;
        esac
    done
    echo "$seconds"
}

check_uint() { [ "$1" -ge 0 ] 2>/dev/null; }

# ---------- 地址检查函数（原生） ----------
check_addr_ether() {
    echo "$1" | grep -q -E -e "^([0-9a-fA-F]{2}[:]){5}[0-9a-fA-F]{2}$"
}

check_addr_ipv4() {
    echo "$1" | grep -q -E -e "^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\/(3[0-2]|[12]?[0-9]))?$"
}

check_addr_ipv6() {
    local addr="$1" mask colons segment remaining
    check_addr_ether "$addr" && return 1
    case "$addr" in */[0-9]*)
        mask="${addr#*/}"
        addr="${addr%%/*}"
        [ "$mask" -ge 0 ] && [ "$mask" -le 128 ] || return 1
        ;;
    esac
    colons="${addr//[^:]}"
    [ "${#colons}" -gt 7 ] && return 1
    case "$addr" in *::*::* ) return 1 ;; esac
    remaining="$addr"
    while [ -n "$remaining" ]; do
        case "$remaining" in
            *:* )
                segment="${remaining%%:*}"
                remaining="${remaining#*:}"
                ;;
            * )
                segment="$remaining"
                remaining=""
                ;;
        esac
        case "$segment" in
            "") continue ;;
            *[!0-9a-fA-F]* | ????? ) return 1 ;;
        esac
    done
    return 0
}

check_addr() {
    local addr="$1" addr_type="$2"
    case $addr_type in
        "$ADDR_ETHER") check_addr_ether "$addr"; return $? ;;
        "$ADDR_IPV4") check_addr_ipv4 "$addr"; return $? ;;
        "$ADDR_IPV6") check_addr_ipv6 "$addr"; return $? ;;
        "") check_addr_ether "$addr" || check_addr_ipv4 "$addr" || check_addr_ipv6 "$addr"; return $? ;;
    esac
    return 1
}

check_duration() {
    echo "$1" | grep -q -E -e "^([1-9][0-9]*[smhd]){1,4}$"
}

check_family() {
    case "$1" in "$FAMILY_IPV4" | "$FAMILY_IPV6") return 0 ;; esac
    return 1
}

check_port_proto() {
    for i in $1; do
        case "$i" in tcp|udp|udplite) true ;; *) return 1 ;; esac
    done
}

get_addr_type() {
    local addr="$1"
    check_addr_ipv4 "$addr" && { echo "$ADDR_IPV4"; return 0; }
    check_addr_ipv6 "$addr" && { echo "$ADDR_IPV6"; return 0; }
    check_addr_ether "$addr" && { echo "$ADDR_ETHER"; return 0; }
    return 1
}

parse_dscp_class() {
    local class="$1"
    class="$(echo "$class" | tr 'A-Z' 'a-z')"
    case "$class" in
        be|df) class="cs0" ;;
        le) [ "$compat_dscp_le" = 1 ] || { log warning "DSCP class 'le' is not supported by kernel versions < ${KERNEL_VERSION_DSCP_LE}"; return 1; } ;;
        cs0|cs1|af11|af12|af13|cs2|af21|af22|af23|cs3|af31|af32|af33|cs4|af41|af42|af43|cs5|va|ef|cs6|cs7) true ;;
        *) return 1 ;;
    esac
    echo "$class"
}

parse_dscp_class_for_var() {
    local class="$1"
    class="$(parse_dscp_class "$class")" || return 1
    [ "$class" = "le" ] && class="$NFT_VAR_CLASS_LE"
    echo "$class"
    return 0
}

# ---------- 规则解析辅助函数（原生） ----------
parse_rule_ports() {
    for i in $1; do
        echo "$i" | grep -q -E -e "^!?[1-9][0-9]*(-[1-9][0-9]*)?$" || return 1
        case "$i" in
            "!"*) port_negate="$port_negate ${i#*!}" ;;
            *) port="$port $i" ;;
        esac
    done
}

set_in_user_sets() {
    local name="$1" match_list="$2"
    for set in $match_list; do
        case $name in
            "@$set") return 0 ;;
            "!@$set") return 1 ;;
        esac
    done
    return 2
}

parse_rule_ip_addr_entries() {
    local entries="$1"
    for i in $(unique_list "$entries"); do
        check_addr_ipv4 "$i" && {
            case "$i" in
                "!"*) ipv4_addr_negate="$ipv4_addr_negate ${i#*!}" ;;
                *) ipv4_addr="$ipv4_addr $i" ;;
            esac
            continue
        }
        check_addr_ipv6 "$i" && {
            case "$i" in
                "!"*) ipv6_addr_negate="$ipv6_addr_negate ${i#*!}" ;;
                *) ipv6_addr="$ipv6_addr $i" ;;
            esac
            continue
        }
        set_in_user_sets "$i" "$sets_ipv4"
        case $? in
            0) ipv4_set="${ipv4_set:+$ipv4_set }$i"; continue ;;
            1) ipv4_set_negate="${ipv4_set_negate:+$ipv4_set_negate }${i#*!}"; continue ;;
        esac
        set_in_user_sets "$i" "$sets_ipv6"
        case $? in
            0) ipv6_set="${ipv6_set:+$ipv6_set }$i"; continue ;;
            1) ipv6_set_negate="${ipv6_set_negate:+$ipv6_set_negate }${i#*!}"; continue ;;
        esac
        log warning "Invalid ip addr/set: $i"
        return 1
    done
    return 0
}

parse_rule_ether_addr_entries() {
    local entries="$1"
    for i in $(unique_list "$entries"); do
        check_addr_ether "$i" && {
            case "$i" in
                "!"*) ether_addr_negate="$ether_addr_negate ${i#*!}" ;;
                *) ether_addr="$ether_addr $i" ;;
            esac
            continue
        }
        set_in_user_sets "$i" "$sets_ether"
        case $? in
            0) ether_set="${ether_set:+$ether_set }$i"; continue ;;
            1) ether_set_negate="${ether_set_negate:+$ether_set_negate }${i#*!}"; continue ;;
        esac
        log warning "Invalid mac addr/set: $i"
        return 1
    done
    return 0
}

# ---------- 集合处理 ----------
sets_ipv4=""
sets_ipv6=""
sets_ether=""

create_user_set() {
    local section="$1"
    local comment enabled family flags match size name timeout type loadfile
    local flag_constant flag_interval flag_timeout auto_merge
    local entries loadfile_entries validated_entries addr_type
    local error=0

    config_get_bool enabled "$section" enabled 1
    [ "$enabled" = 1 ] || return 0

    config_get comment "$section" comment
    config_get name "$section" name
    config_get family "$section" family
    config_get match "$section" match
    config_get size "$section" maxelem
    config_get timeout "$section" timeout
    config_get loadfile "$section" loadfile
    config_get entries "$section" entry
    config_get_bool flag_constant "$section" constant
    config_get_bool flag_interval "$section" interval 1
    config_get type "$section" type

    # 简化版：不支持 loadfile、timeout 等高级特性
    if [ -z "$type" ] && [ -n "$entries" ]; then
        local first_entry
        for first_entry in $entries; do break; done
        type=$(get_addr_type "$first_entry")
        if [ -z "$type" ]; then
            log warning "Could not detect type for set $name, skipping"
            return
        fi
    fi

    if [ -n "$family" ]; then
        case "$family" in
            ipv4) type="ipv4_addr" ;;
            ipv6) type="ipv6_addr" ;;
            *) log warning "Invalid family $family for set $name"; return ;;
        esac
    fi

    [ -z "$type" ] && { log warning "Set $name has no type"; return; }

    # 检查是否有 CIDR 条目需要 interval 标志
    local has_cidr=0
    for entry in $entries; do
        if echo "$entry" | grep -q '/'; then
            has_cidr=1
            break
        fi
    done

    local set_def="add set inet $TABLE $name { type $type;"
    [ "$has_cidr" = 1 ] && set_def="$set_def flags interval;"
    set_def="$set_def }"
    post_include "$set_def"

    if [ -n "$entries" ]; then
        local elem_list=$(nft_element_list "$entries")
        post_include "add element inet $TABLE $name $elem_list"
    fi

    case $type in
        "$ADDR_IPV4") sets_ipv4="${sets_ipv4:+$sets_ipv4 }$name" ;;
        "$ADDR_IPV6") sets_ipv6="${sets_ipv6:+$sets_ipv6 }$name" ;;
        "$ADDR_ETHER") sets_ether="${sets_ether:+$sets_ether }$name" ;;
    esac
}

# ---------- 规则构建函数 ----------
rule_l4proto() {
    [ -n "$1" ] || return 0
    l4proto="meta l4proto $(nft_element_list "$1")"
}

rule_nfproto() {
    [ -n "$1" ] || return 0
    nfproto="meta nfproto $(nft_element_list "$1")"
}

rule_oifname() {
    [ -n "$1" ] || return 0
    oifname="oifname $(nft_interface_list "$1")"
}

rule_iifname() {
    [ -n "$1" ] || return 0
    iifname="iifname $(nft_interface_list "$1")"
}

rule_zone() {
    local direction="$1" zone="$2"
    local interfaces
    [ -n "$zone" ] || return 0
    # 简化：不支持 zone，直接返回
    log warning "zone matching not implemented in core library"
    return 1
}

rule_port() {
    local direction="$1" ports="$2" protocol="$3"
    local port port_negate rule xport
    case "$direction" in
        src) xport="sport" ;;
        dest) xport="dport" ;;
        *) log err "Invalid direction for port function"; return 1 ;;
    esac
    [ -n "$ports" ] || return 0
    check_port_proto "$protocol" || { log warning "Rules cannot combine a ${direction}_port with protocols other than 'tcp', 'udp' or 'udplite'"; return 1; }
    parse_rule_ports "$ports" || { log warning "Rule contains an invalid ${direction}_port"; return 1; }
    [ -n "$port" ] && rule="th $xport $(nft_element_list "$port")"
    [ -n "$port_negate" ] && rule="$rule th $xport != $(nft_element_list "$port_negate")"
    eval "$xport"='$rule'
    return 0
}

# shellcheck disable=SC2016
rule_addr() {
    local direction="$1" addresses="$2" type="$3" family="$4"
    local xaddr negate_ip negate_ip6 negate_ether rule_list rule6_list
    local ether_addr ether_addr_negate ether_set ether_set_negate
    local ipv4_addr ipv4_addr_negate ipv4_set ipv4_set_negate
    local ipv6_addr ipv6_addr_negate ipv6_set ipv6_set_negate

    case "$direction" in src) xaddr="saddr" ;; dest) xaddr="daddr" ;; *) log err "Invalid direction for addr rule"; return 1 ;; esac
    [ -n "$addresses" ] || return 0
    case "$type" in
        ip) parse_rule_ip_addr_entries "$addresses" || { log warning "Rule ${name:+'$name' }contains an invalid ${direction}_ip"; return 1; } ;;
        ether) parse_rule_ether_addr_entries "$addresses" || { log warning "Rule ${name:+'$name' }contains an invalid ${direction}_mac"; return 1; } ;;
        *) log err "Invalid type for addr rule"; return 1 ;;
    esac

    if [ "$family" = "$FAMILY_IPV6" ] && [ -n "$ipv4_addr$ipv4_addr_negate$ipv4_set$ipv4_set_negate" ]; then
        log warning "Rules cannot combine an $FAMILY_IPV4 ${direction}_ip with the '$FAMILY_IPV6' family option${name:+, rule: '$name'}"; return 1
    fi
    if [ "$family" = "$FAMILY_IPV4" ] && [ -n "$ipv6_addr$ipv6_addr_negate$ipv6_set$ipv6_set_negate" ]; then
        log warning "Rules cannot combine an $FAMILY_IPV6 ${direction}_ip with the '$FAMILY_IPV4' family option${name:+, rule: '$name'}"; return 1
    fi

    eval "rule_list=\$${xaddr}_list"
    eval "rule6_list=\$${xaddr}6_list"

    [ -n "$ipv4_addr_negate" ] && ipv4_addr_negate="$(nft_element_list "$ipv4_addr_negate")"
    for entry in $ipv4_set_negate ${ipv4_addr_negate:+"$ipv4_addr_negate"}; do negate_ip="ip $xaddr != $entry $negate_ip"; done
    [ -n "$ipv6_addr_negate" ] && ipv6_addr_negate="$(nft_element_list "$ipv6_addr_negate")"
    for entry in $ipv6_set_negate ${ipv6_addr_negate:+"$ipv6_addr_negate"}; do negate_ip6="ip6 $xaddr != $entry $negate_ip6"; done
    [ -n "$ether_addr_negate" ] && ether_addr_negate="$(nft_element_list "$ether_addr_negate")"
    for entry in $ether_set_negate ${ether_addr_negate:+"$ether_addr_negate"}; do negate_ether="ether $xaddr != $entry $negate_ether"; done

    [ -n "$ipv4_addr" ] && ipv4_addr="$(nft_element_list "$ipv4_addr")"
    for entry in $ipv4_set ${ipv4_addr:+"$ipv4_addr"}; do rule_list=${rule_list:+${rule_list}$'\n'}"ip $xaddr $entry $negate_ip $negate_ether"; done
    [ -n "$ipv6_addr" ] && ipv6_addr="$(nft_element_list "$ipv6_addr")"
    for entry in $ipv6_set ${ipv6_addr:+"$ipv6_addr"}; do rule6_list=${rule6_list:+${rule6_list}$'\n'}"ip6 $xaddr $entry $negate_ip6 $negate_ether"; done
    [ -n "$ether_addr" ] && ether_addr="$(nft_element_list "$ether_addr")"
    for entry in $ether_set ${ether_addr:+"$ether_addr"}; do
        [ "$family" != "$FAMILY_IPV6" ] && rule_list=${rule_list:+${rule_list}$'\n'}"ether $xaddr $entry $negate_ip $negate_ether"
        [ "$family" != "$FAMILY_IPV4" ] && rule6_list=${rule6_list:+${rule6_list}$'\n'}"ether $xaddr $entry $negate_ip6 $negate_ether"
    done

    eval "$xaddr"_list='$rule_list'
    eval "$xaddr"6_list='$rule6_list'
    return 0
}

rule_device() {
    local device="$1" direction="$2"
    [ -n "$device" ] || return 0
    [ -n "$direction" ] || { log warning "Rules must use the options 'device' and 'direction' in conjunction"; return 1; }
    case "$direction" in
        in) rule_iifname "$device" ;;
        out) rule_oifname "$device" ;;
        *) log warning "The rule option 'direction' must contain either 'in' or 'out'"; return 1 ;;
    esac
}

rule_verdict() {
    local class="$1"
    [ -n "$class" ] || { log warning "Rule is missing the DSCP 'class' option"; return 1; }
    class="$(parse_dscp_class "$class")" || { log warning "Rule option 'class' contains an invalid DSCP value"; return 1; }
    verdict="goto ct_set_${class}"
}

# ---------- 创建用户规则 ----------
create_user_rule() {
    local section="$1"
    local enabled family proto direction device dest dest_ip dest_port dest_mac src src_ip src_port src_mac counter class name
    local nfproto l4proto iifname smac sport oifname dmac dport verdict
    local saddr_list saddr6_list daddr_list daddr6_list
    local error=0

    config_get_bool enabled "$section" enabled 1
    [ "$enabled" = 1 ] || return 0

    config_get family "$section" family
    config_get proto "$section" proto
    config_get device "$section" device
    config_get direction "$section" direction
    config_get dest "$section" dest
    config_get dest_ip "$section" dest_ip
    config_get dest_port "$section" dest_port
    config_get dest_mac "$section" dest_mac
    config_get src "$section" src
    config_get src_ip "$section" src_ip
    config_get src_port "$section" src_port
    config_get src_mac "$section" src_mac
    config_get_bool counter "$section" counter
    config_get class "$section" class
    config_get name "$section" name

    [ "$family" = "any" ] && family=""
    if [ -n "$family" ] && ! check_family "$family"; then
        log warning "Rule ${name:+'$name' }contains an invalid family"
        return 1
    fi

    rule_nfproto "$family" || error=1
    rule_l4proto "$proto" || error=1
    rule_zone dest "$dest" || error=1
    rule_addr dest "$dest_mac" ether "$family" || error=1
    rule_addr dest "$dest_ip" ip "$family" || error=1
    rule_port dest "$dest_port" "$proto" || error=1
    rule_zone src "$src" || error=1
    rule_addr src "$src_mac" ether "$family" || error=1
    rule_addr src "$src_ip" ip "$family" || error=1
    rule_port src "$src_port" "$proto" || error=1
    rule_device "$device" "$direction" || error=1
    rule_verdict "$class" || error=1
    [ "$error" = 0 ] || return 1

    [ -z "$saddr_list$saddr6_list$daddr_list$daddr6_list" ] && {
        post_include "insert rule inet $TABLE $CHAIN_RULE_CLASSIFY $nfproto $l4proto $iifname $sport $oifname $dport ${counter:+counter} $verdict ${name:+comment \"$name\"}"
        return 0
    }

    for_each_ip_saddr_daddr() {
        local saddr_list="$1" daddr_list="$2"
        [ -n "$saddr_list$daddr_list" ] || return 0
        printf '%s\n' "${saddr_list:-}" | while IFS= read -r saddr || [ -n "$saddr" ]; do
            printf '%s\n' "${daddr_list:-}" | while IFS= read -r daddr || [ -n "$daddr" ]; do
                [ -n "$saddr$daddr" ] || continue
                post_include "insert rule inet $TABLE $CHAIN_RULE_CLASSIFY $nfproto $l4proto $iifname $saddr $sport $oifname $daddr $dport ${counter:+counter} $verdict ${name:+comment \"$name\"}"
            done
        done
    }
    for_each_ip_saddr_daddr "$saddr_list" "$daddr_list"
    for_each_ip_saddr_daddr "$saddr6_list" "$daddr6_list"
    return 0
}

# ---------- 自动分类规则 ----------
destroy_client_class_adoption_rules() { post_include "destroy chain inet $TABLE $CHAIN_CLIENT_CLASSIFY"; }

create_client_class_adoption_rules() {
    local enabled=1 exclude_class_always="cs0" exclude_class_defaults="cs6 cs7" exclude_class src_ip src_mac
    local saddr_list saddr6_list
    config_get_bool enabled "$client_adoption_section" enabled "$enabled"
    [ "$enabled" = 1 ] || { destroy_client_class_adoption_rules; return 0; }
    config_get exclude_class "$client_adoption_section" exclude_class "$exclude_class_defaults"
    for class in $exclude_class; do
        class="$(parse_dscp_class_for_var "$class")" || { log err "The client_class_adoption config option 'exclude_class' contains an invalid DSCP class"; return 1; }
        exclude_class="${exclude_class:+$exclude_class }\$$class"
    done
    exclude_class=$(unique_list "$exclude_class_always $exclude_class")
    config_get src_ip "$client_adoption_section" src_ip
    config_get src_mac "$client_adoption_section" src_mac
    # 简化：忽略 src_ip/src_mac
    exclude_class="$(nft_element_list "$exclude_class")"
    post_include "add rule inet $TABLE $CHAIN_CLIENT_CLASSIFY ip dscp != $exclude_class ip dscp vmap @dscp_ct"
    post_include "add rule inet $TABLE $CHAIN_CLIENT_CLASSIFY ip6 dscp != $exclude_class ip6 dscp vmap @dscp_ct"
    post_include "add rule inet $TABLE input ct mark & \$$NFT_VAR_CT_DYNAMIC != 0 ct direction original iifname != \$wan jump $CHAIN_CLIENT_CLASSIFY"
    post_include "add rule inet $TABLE postrouting ct mark & \$$NFT_VAR_CT_DYNAMIC != 0 ct direction original iifname != \$wan jump $CHAIN_CLIENT_CLASSIFY"
}

destroy_dynamic_classify_rules() {
    post_include "destroy chain inet $TABLE $CHAIN_DYNAMIC_CLASSIFY"
    post_include "destroy chain inet $TABLE $CHAIN_DYNAMIC_CLASSIFY_REPLY"
    post_include "destroy chain inet $TABLE $CHAIN_ESTABLISHED_CONNECTION"
}

create_dynamic_classify_rules() {
    local bulk_client_detection=1 high_throughput_service_detection=1
    config_get_bool bulk_client_detection "$bulk_section" enabled "$bulk_client_detection"
    config_get_bool high_throughput_service_detection "$htp_section" enabled "$high_throughput_service_detection"
    if [ "$bulk_client_detection" != 1 ] && [ "$high_throughput_service_detection" != 1 ]; then
        destroy_dynamic_classify_rules
        return 0
    fi
    post_include "add rule inet $TABLE input ct mark & (\$$NFT_VAR_CT_DYNAMIC | \$$NFT_VAR_CT_DSCP) == \$$NFT_VAR_CT_DYNAMIC jump $CHAIN_DYNAMIC_CLASSIFY"
    post_include "add rule inet $TABLE postrouting ct mark & (\$$NFT_VAR_CT_DYNAMIC | \$$NFT_VAR_CT_DSCP) == \$$NFT_VAR_CT_DYNAMIC jump $CHAIN_DYNAMIC_CLASSIFY"
}

destroy_bulk_client_rules() {
    post_include "destroy chain inet $TABLE $CHAIN_BULK_CLIENT"
    post_include "destroy chain inet $TABLE $CHAIN_BULK_CLIENT_REPLY"
    post_include "destroy set inet $TABLE bulk_clients"
    post_include "destroy set inet $TABLE $SET_BULK_CLIENTS6"
}

create_bulk_client_rules() {
    local class="$class_low_effort" enabled=1 min_bytes=10000 min_connections=10
    config_get_bool enabled "$bulk_section" enabled "$enabled"
    [ "$enabled" = 1 ] || { destroy_bulk_client_rules; return 0; }
    config_get min_bytes "$bulk_section" min_bytes "$min_bytes"
    if ! check_uint "$min_bytes" || [ "$min_bytes" = 0 ]; then log err "bulk_client_detection config option 'min_bytes' contains an invalid value"; return 1; fi
    config_get min_connections "$bulk_section" min_connections "$min_connections"
    if ! check_uint "$min_connections" || [ "$min_connections" -lt 2 ]; then log err "bulk_client_detection config option 'min_connections' contains an invalid value"; return 1; fi
    config_get class "$bulk_section" class "$class"
    class="$(parse_dscp_class_for_var "$class")" || { log err "bulk_client_detection config option 'class' contains an invalid DSCP class"; return 1; }
    [ "$class" = "cs0" ] && { log warning "Disabling threaded client detection as its configured class CS0/DF/BE is the default packet class"; destroy_bulk_client_rules; return 0; }

    # 创建集合
    nft_set_exists "$TABLE" "$SET_BULK_CLIENTS" || post_include "add set inet $TABLE $SET_BULK_CLIENTS { type ipv4_addr . inet_service . inet_proto; flags timeout; }"
    nft_set_exists "$TABLE" "$SET_BULK_CLIENTS6" || post_include "add set inet $TABLE $SET_BULK_CLIENTS6 { type ipv6_addr . inet_service . inet_proto; flags timeout; }"

    # 检测规则（使用字符串常量作为 meter 名称，避免变量展开问题）
    post_include "add rule inet $TABLE $CHAIN_ESTABLISHED_CONNECTION meter bulk_client_detect { ip daddr . th dport . meta l4proto timeout 5s limit rate over $((min_connections - 1))/minute } add @$SET_BULK_CLIENTS { ip daddr . th dport . meta l4proto timeout 30s }"
    post_include "add rule inet $TABLE $CHAIN_ESTABLISHED_CONNECTION meter bulk_client_detect6 { ip6 daddr . th dport . meta l4proto timeout 5s limit rate over $((min_connections - 1))/minute } add @$SET_BULK_CLIENTS6 { ip6 daddr . th dport . meta l4proto timeout 30s }"

    # 分类链
    post_include "add chain inet $TABLE $CHAIN_BULK_CLIENT"
    post_include "add rule inet $TABLE $CHAIN_BULK_CLIENT meter bulk_client_orig_classify { ip saddr . th sport . meta l4proto timeout 5m limit rate over $((min_bytes - 1)) bytes/hour } update @$SET_BULK_CLIENTS { ip saddr . th sport . meta l4proto timeout 5m } ct mark set ct mark | \$${class} return"
    post_include "add rule inet $TABLE $CHAIN_BULK_CLIENT meter bulk_client_orig_classify6 { ip6 saddr . th sport . meta l4proto timeout 5m limit rate over $((min_bytes - 1)) bytes/hour } update @$SET_BULK_CLIENTS6 { ip6 saddr . th sport . meta l4proto timeout 5m } ct mark set ct mark | \$${class} return"

    post_include "add chain inet $TABLE $CHAIN_BULK_CLIENT_REPLY"
    post_include "add rule inet $TABLE $CHAIN_BULK_CLIENT_REPLY meter bulk_client_reply_classify { ip daddr . th dport . meta l4proto timeout 5m limit rate over $((min_bytes - 1)) bytes/hour } update @$SET_BULK_CLIENTS { ip daddr . th dport . meta l4proto timeout 5m } ct mark set ct mark | \$${class} return"
    post_include "add rule inet $TABLE $CHAIN_BULK_CLIENT_REPLY meter bulk_client_reply_classify6 { ip6 daddr . th dport . meta l4proto timeout 5m limit rate over $((min_bytes - 1)) bytes/hour } update @$SET_BULK_CLIENTS6 { ip6 daddr . th dport . meta l4proto timeout 5m } ct mark set ct mark | \$${class} return"

    # 跳转
    post_include "add rule inet $TABLE $CHAIN_DYNAMIC_CLASSIFY ip saddr . th sport . meta l4proto @$SET_BULK_CLIENTS goto $CHAIN_BULK_CLIENT"
    post_include "add rule inet $TABLE $CHAIN_DYNAMIC_CLASSIFY ip6 saddr . th sport . meta l4proto @$SET_BULK_CLIENTS6 goto $CHAIN_BULK_CLIENT"
    post_include "add rule inet $TABLE $CHAIN_DYNAMIC_CLASSIFY_REPLY ip daddr . th dport . meta l4proto @$SET_BULK_CLIENTS goto $CHAIN_BULK_CLIENT_REPLY"
    post_include "add rule inet $TABLE $CHAIN_DYNAMIC_CLASSIFY_REPLY ip6 daddr . th dport . meta l4proto @$SET_BULK_CLIENTS6 goto $CHAIN_BULK_CLIENT_REPLY"
}

destroy_high_throughput_service_rules() {
    post_include "destroy chain inet $TABLE $CHAIN_HIGH_THROUGHPUT_SERVICE"
    post_include "destroy chain inet $TABLE $CHAIN_HIGH_THROUGHPUT_SERVICE_REPLY"
    post_include "destroy set inet $TABLE $SET_HIGH_THROUGHPUT_SERVICES"
    post_include "destroy set inet $TABLE $SET_HIGH_THROUGHPUT_SERVICES6"
}

create_high_throughput_service_rules() {
    local class="$class_high_throughput" enabled=1 min_bytes=1000000 min_connections=3
    config_get_bool enabled "$htp_section" enabled "$enabled"
    [ "$enabled" = 1 ] || { destroy_high_throughput_service_rules; return 0; }
    config_get min_bytes "$htp_section" min_bytes "$min_bytes"
    if ! check_uint "$min_bytes" || [ "$min_bytes" = 0 ]; then log err "high_throughput_service_detection config option 'min_bytes' contains an invalid value"; return 1; fi
    config_get min_connections "$htp_section" min_connections "$min_connections"
    if ! check_uint "$min_connections" || [ "$min_connections" -lt 2 ]; then log err "high_throughput_service_detection config option 'min_connections' contains an invalid value"; return 1; fi
    config_get class "$htp_section" class "$class"
    class="$(parse_dscp_class_for_var "$class")" || { log err "high_throughput_service_detection config option 'class' contains an invalid DSCP class"; return 1; }
    [ "$class" = "cs0" ] && { log warning "Disabling threaded service detection as its configured class CS0/DF/BE is the default packet class"; destroy_high_throughput_service_rules; return 0; }

    # 创建集合
    nft_set_exists "$TABLE" "$SET_HIGH_THROUGHPUT_SERVICES" || post_include "add set inet $TABLE $SET_HIGH_THROUGHPUT_SERVICES { type ipv4_addr . ipv4_addr . inet_service . inet_proto; flags timeout; }"
    nft_set_exists "$TABLE" "$SET_HIGH_THROUGHPUT_SERVICES6" || post_include "add set inet $TABLE $SET_HIGH_THROUGHPUT_SERVICES6 { type ipv6_addr . ipv6_addr . inet_service . inet_proto; flags timeout; }"

    # 检测规则（使用字符串常量作为 meter 名称）
    post_include "add rule inet $TABLE $CHAIN_ESTABLISHED_CONNECTION meter high_throughput_service_detect { ip daddr . ip saddr and 255.255.255.0 . th sport . meta l4proto timeout 5s limit rate over $((min_connections - 1))/minute } add @$SET_HIGH_THROUGHPUT_SERVICES { ip daddr . ip saddr and 255.255.255.0 . th sport . meta l4proto timeout 30s }"
    post_include "add rule inet $TABLE $CHAIN_ESTABLISHED_CONNECTION meter high_throughput_service_detect6 { ip6 daddr . ip6 saddr and ffff:ffff:ffff:: . th sport . meta l4proto timeout 5s limit rate over $((min_connections - 1))/minute } add @$SET_HIGH_THROUGHPUT_SERVICES6 { ip6 daddr . ip6 saddr and ffff:ffff:ffff:: . th sport . meta l4proto timeout 30s }"

    # 分类链
    post_include "add chain inet $TABLE $CHAIN_HIGH_THROUGHPUT_SERVICE"
    post_include "add rule inet $TABLE $CHAIN_HIGH_THROUGHPUT_SERVICE ct original bytes < $min_bytes return"
    post_include "add rule inet $TABLE $CHAIN_HIGH_THROUGHPUT_SERVICE update @$SET_HIGH_THROUGHPUT_SERVICES { ip saddr . ip daddr and 255.255.255.0 . th dport . meta l4proto timeout 5m }"
    post_include "add rule inet $TABLE $CHAIN_HIGH_THROUGHPUT_SERVICE update @$SET_HIGH_THROUGHPUT_SERVICES6 { ip6 saddr . ip6 daddr and ffff:ffff:ffff:: . th dport . meta l4proto timeout 5m }"
    post_include "add rule inet $TABLE $CHAIN_HIGH_THROUGHPUT_SERVICE ct mark set ct mark | \$${class} return"

    post_include "add chain inet $TABLE $CHAIN_HIGH_THROUGHPUT_SERVICE_REPLY"
    post_include "add rule inet $TABLE $CHAIN_HIGH_THROUGHPUT_SERVICE_REPLY ct reply bytes < $min_bytes return"
    post_include "add rule inet $TABLE $CHAIN_HIGH_THROUGHPUT_SERVICE_REPLY update @$SET_HIGH_THROUGHPUT_SERVICES { ip daddr . ip saddr and 255.255.255.0 . th sport . meta l4proto timeout 5m }"
    post_include "add rule inet $TABLE $CHAIN_HIGH_THROUGHPUT_SERVICE_REPLY update @$SET_HIGH_THROUGHPUT_SERVICES6 { ip6 daddr . ip6 saddr and ffff:ffff:ffff:: . th sport . meta l4proto timeout 5m }"
    post_include "add rule inet $TABLE $CHAIN_HIGH_THROUGHPUT_SERVICE_REPLY ct mark set ct mark | \$${class} return"

    # 跳转
    post_include "add rule inet $TABLE $CHAIN_DYNAMIC_CLASSIFY ip saddr . ip daddr and 255.255.255.0 . th dport . meta l4proto @$SET_HIGH_THROUGHPUT_SERVICES goto $CHAIN_HIGH_THROUGHPUT_SERVICE"
    post_include "add rule inet $TABLE $CHAIN_DYNAMIC_CLASSIFY ip6 saddr . ip6 daddr and ffff:ffff:ffff:: . th dport . meta l4proto @$SET_HIGH_THROUGHPUT_SERVICES6 goto $CHAIN_HIGH_THROUGHPUT_SERVICE"
    post_include "add rule inet $TABLE $CHAIN_DYNAMIC_CLASSIFY_REPLY ip daddr . ip saddr and 255.255.255.0 . th sport . meta l4proto @$SET_HIGH_THROUGHPUT_SERVICES goto $CHAIN_HIGH_THROUGHPUT_SERVICE_REPLY"
    post_include "add rule inet $TABLE $CHAIN_DYNAMIC_CLASSIFY_REPLY ip6 daddr . ip6 saddr and ffff:ffff:ffff:: . th sport . meta l4proto @$SET_HIGH_THROUGHPUT_SERVICES6 goto $CHAIN_HIGH_THROUGHPUT_SERVICE_REPLY"
}

create_dscp_mark_rule() {
    local wmm_mark_lan=1
    config_get_bool wmm_mark_lan "$service_section" wmm_mark_lan "$wmm_mark_lan"
    [ "$wmm_mark_lan" = 1 ] && post_include "add rule inet $TABLE postrouting oifname \$lan ct mark & \$$NFT_VAR_CT_DSCP vmap @ct_wmm"
    post_include "add rule inet $TABLE postrouting ct mark & \$$NFT_VAR_CT_DSCP vmap @ct_dscp"
}

# ---------- 临时文件生成 ----------
create_pre_include() {
    rm -f "$PRE_INCLUDE"
    pre_include "define lan = $(nft_interface_list "$lan")"
    pre_include "define wan = $(nft_interface_list "$wan")"
    pre_include "add table inet $TABLE"
    pre_include "include \"${VERDICTS}\""
    pre_include "include \"${MAPS}\""
}

create_post_include() {
    rm -f "$POST_INCLUDE"
    sets_ipv4=""; sets_ipv6=""; sets_ether=""

    config_foreach create_user_set set
    config_foreach_reverse create_user_rule rule

    create_client_class_adoption_rules || return 1
    create_dynamic_classify_rules || return 1
    create_bulk_client_rules || return 1
    create_high_throughput_service_rules || return 1
    create_dscp_mark_rule || return 1
}

# ---------- 主加载/卸载接口 ----------
dscpclassify_load() {
    local lan_iface="$1" wan_iface="$2"
    [ -n "$lan_iface" ] && [ -n "$wan_iface" ] || { log err "Missing interface arguments"; return 1; }

    lan="$lan_iface"
    wan="$wan_iface"

    determine_compatibility
    destroy_table

    mkdir -p "$INCLUDES_PATH" || { log err "Failed to create path: $INCLUDES_PATH"; return 1; }

    config_load "$(basename "$CONFIG_FILE")" || { log err "Failed to load config file"; return 1; }

    client_adoption_section=$(config_get_exclusive_section client_class_adoption)
    bulk_section=$(config_get_exclusive_section bulk_client_detection)
    htp_section=$(config_get_exclusive_section high_throughput_service_detection)
    service_section=$(config_get_exclusive_section service)

    class_low_effort="le"
    class_high_throughput="af13"
    if [ -n "$service_section" ]; then
        config_get class_low_effort "$service_section" class_low_effort "$DEFAULT_CLASS_LOW_EFFORT"
        config_get class_high_throughput "$service_section" class_high_throughput "$DEFAULT_CLASS_HIGH_THROUGHPUT"
    fi
    if [ "$compat_dscp_le" != 1 ] && [ "$class_low_effort" = "le" ]; then
        log info "Falling back to cs1 for Low Effort class due to Kernel version < $KERNEL_VERSION_DSCP_LE"
        class_low_effort="cs1"
    fi

    create_pre_include
    create_post_include || { log err "Failed to create post-include rules"; return 1; }

    nft -f "$MAIN" || { log err "Failed to load main.nft"; return 1; }

    cleanup_setup
    log info "dscpclassify loaded (lan=$lan_iface, wan=$wan_iface)"
    return 0
}

dscpclassify_unload() {
    destroy_table
    cleanup_setup
    log info "dscpclassify unloaded"
}