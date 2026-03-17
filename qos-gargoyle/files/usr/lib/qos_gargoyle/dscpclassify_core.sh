#!/bin/sh
# dscpclassify_core.sh - 精简核心库，用于 qos_gargoyle 集成
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

# 临时文件
INCLUDES_PATH="/tmp/${SERVICE_NAME}.d"
PRE_INCLUDE="${INCLUDES_PATH}/pre-include.nft"
POST_INCLUDE="${INCLUDES_PATH}/post-include.nft"

# 内核兼容性常量
KERNEL_VERSION_DSCP_LE="5.13"

# 日志函数
log() {
    local level="$1" msg="$2"
    logger -t "$SERVICE_NAME" -p "daemon.$level" "$msg"
    echo "$msg" >&2
}

# 格式化辅助函数
nft_element_list() {
    local items="$1"
    items=$(echo "$items" | tr '\n' ' ' | sed -e 's/^ *//;s/ *$//')
    [ -z "$items" ] && return
    echo "{ $(echo "$items" | sed 's/ /, /g') }"
}

nft_interface_list() {
    local items="$1"
    items=$(echo "$items" | tr '\n' ' ' | sed -e 's/^ *//;s/ *$//')
    [ -z "$items" ] && return
    echo "{ $(echo "$items" | sed 's/ /", "/g' | sed 's/^/"/;s/$/"/') }"
}

# 解析 DSCP 类名
parse_dscp_class() {
    local class="$1"
    class=$(echo "$class" | tr 'A-Z' 'a-z')
    case "$class" in
        be|df) echo "cs0" ;;
        le)
            # 检查内核版本是否支持 LE (>=5.13)
            local cur major_cur minor_cur
            cur=$(uname -r)
            major_cur=$(echo "$cur" | cut -d. -f1)
            minor_cur=$(echo "$cur" | cut -d. -f2)
            if [ "$major_cur" -gt 5 ] || { [ "$major_cur" -eq 5 ] && [ "$minor_cur" -ge 13 ]; }; then
                echo "le"
            else
                log warning "LE not supported on kernel <5.13, using cs1"
                echo "cs1"
            fi
            ;;
        cs0|cs1|af11|af12|af13|cs2|af21|af22|af23|cs3|af31|af32|af33|cs4|af41|af42|af43|cs5|va|ef|cs6|cs7) echo "$class" ;;
        *) return 1 ;;
    esac
}

# 读取集合配置
create_user_set() {
    local section="$1"
    local name family type entries entry
    config_get name "$section" name
    config_get family "$section" family
    config_get type "$section" type
    config_get entries "$section" entry
    [ -n "$name" ] || return

    # 自动检测类型（若未指定）
    if [ -z "$type" ]; then
        local first_entry
        for first_entry in $entries; do break; done
        case "$first_entry" in
            *:*|*.*) type="ipv4_addr" ;;      # 简化判断，实际应更精确
            *::*) type="ipv6_addr" ;;
            [0-9a-f][0-9a-f]:*) type="ether_addr" ;;
        esac
    fi

    echo "add set inet $TABLE $name { type $type; ${family:+family $family;} }" >> "$POST_INCLUDE"
    [ -n "$entries" ] && echo "add element inet $TABLE $name $(nft_element_list "$entries")" >> "$POST_INCLUDE"
}

# 生成用户规则
create_user_rule() {
    local section="$1"
    local family proto dest_ip dest_port src_ip src_port class name
    config_get family "$section" family
    config_get proto "$section" proto
    config_get dest_ip "$section" dest_ip
    config_get dest_port "$section" dest_port
    config_get src_ip "$section" src_ip
    config_get src_port "$section" src_port
    config_get class "$section" class
    config_get name "$section" name

    [ -n "$class" ] || return
    class=$(parse_dscp_class "$class") || { log warning "Invalid class in rule $name"; return; }

    local match=""
    [ -n "$family" ] && match="$match meta nfproto $family"
    [ -n "$proto" ] && match="$match meta l4proto $proto"
    [ -n "$dest_ip" ] && match="$match ip daddr $dest_ip"
    [ -n "$dest_port" ] && match="$match th dport $dest_port"
    [ -n "$src_ip" ] && match="$match ip saddr $src_ip"
    [ -n "$src_port" ] && match="$match th sport $src_port"

    echo "insert rule inet $TABLE rule_classify $match counter goto ct_set_${class}" >> "$POST_INCLUDE"
}

# 客户端标记继承
create_client_adoption_rules() {
    local enabled exclude_class
    config_get_bool enabled "$client_adoption_section" enabled 0
    [ "$enabled" = 1 ] || return

    config_get exclude_class "$client_adoption_section" exclude_class "cs6 cs7"
    local exclude_list=""
    for c in $exclude_class; do
        c=$(parse_dscp_class "$c") && exclude_list="$exclude_list $c"
    done
    exclude_list=$(nft_element_list "$exclude_list")

    echo "add rule inet $TABLE input iifname \$lan ip dscp != $exclude_list ip dscp vmap @dscp_ct" >> "$POST_INCLUDE"
    echo "add rule inet $TABLE input iifname \$lan ip6 dscp != $exclude_list ip6 dscp vmap @dscp_ct" >> "$POST_INCLUDE"
}

# 大流量客户端检测
create_bulk_client_rules() {
    local enabled min_bytes min_connections class
    config_get_bool enabled "$bulk_section" enabled 0
    [ "$enabled" = 1 ] || return

    config_get min_bytes "$bulk_section" min_bytes 10000
    config_get min_connections "$bulk_section" min_connections 10
    config_get class "$bulk_section" class "le"
    class=$(parse_dscp_class "$class") || return

    # 在 established_connection 链中添加 meter 检测
    echo "add rule inet $TABLE established_connection meter bulk_detect { ip daddr . th dport . meta l4proto timeout 30s limit rate over $((min_connections-1))/minute } add @bulk_clients { ip daddr . th dport . meta l4proto }" >> "$POST_INCLUDE"
    echo "add rule inet $TABLE dynamic_classify ip saddr . th sport . meta l4proto @bulk_clients goto ct_set_${class}" >> "$POST_INCLUDE"
}

# 高吞吐服务检测
create_htp_rules() {
    local enabled min_bytes class
    config_get_bool enabled "$htp_section" enabled 0
    [ "$enabled" = 1 ] || return

    config_get min_bytes "$htp_section" min_bytes 1000000
    config_get class "$htp_section" class "af13"
    class=$(parse_dscp_class "$class") || return

    # 使用预定义的高吞吐服务集合（需用户定义）
    echo "add rule inet $TABLE dynamic_classify ip daddr @htp_services goto ct_set_${class}" >> "$POST_INCLUDE"
}

# 创建 DSCP 标记规则
create_dscp_mark_rules() {
    # 将 conntrack mark 的低6位映射到 DSCP 字段
    echo "add rule inet $TABLE postrouting ct mark & 0x3f vmap @ct_dscp" >> "$POST_INCLUDE"
    # WMM 映射（可选）
    config_get_bool wmm "$service_section" wmm_mark_lan 0
    [ "$wmm" = 1 ] && echo "add rule inet $TABLE postrouting oifname \$lan ct mark & 0x3f vmap @ct_wmm" >> "$POST_INCLUDE"
}

# 生成 pre-include 文件
gen_pre_include() {
    mkdir -p "$INCLUDES_PATH"
    cat > "$PRE_INCLUDE" <<EOF
define lan = $(nft_interface_list "$1")
define wan = $(nft_interface_list "$2")

add table inet $TABLE
flush chain inet $TABLE input
flush chain inet $TABLE output
flush chain inet $TABLE postrouting
flush chain inet $TABLE rule_classify
flush chain inet $TABLE dynamic_classify
flush chain inet $TABLE established_connection

include "$VERDICTS"
include "$MAPS"
EOF
}

# 生成 post-include 文件
gen_post_include() {
    rm -f "$POST_INCLUDE"

    # 加载 UCI 配置
    config_load "$(basename "$CONFIG_FILE")"

    # 处理集合
    config_foreach create_user_set set

    # 处理规则
    config_foreach create_user_rule rule

    # 获取各配置节（取第一个，因为每个类型只能有一个）
    client_adoption_section=""
    bulk_section=""
    htp_section=""
    service_section=""
    for s in $(config_foreach echo); do
        case "$(config_get "$s" TYPE)" in
            client_class_adoption) client_adoption_section="$s" ;;
            bulk_client_detection) bulk_section="$s" ;;
            high_throughput_service_detection) htp_section="$s" ;;
            service) service_section="$s" ;;
        esac
    done

    # 创建自动分类规则
    create_client_adoption_rules
    create_bulk_client_rules
    create_htp_rules
    create_dscp_mark_rules
}

# 加载核心
dscpclassify_load() {
    local lan_iface="$1" wan_iface="$2"
    [ -n "$lan_iface" ] && [ -n "$wan_iface" ] || { log err "Missing interface arguments"; return 1; }

    # 清理旧表
    nft delete table inet "$TABLE" 2>/dev/null

    # 生成临时文件
    gen_pre_include "$lan_iface" "$wan_iface"
    gen_post_include

    # 加载主文件
    nft -f "$MAIN" || { log err "Failed to load main.nft"; return 1; }

    log info "dscpclassify loaded (lan=$lan_iface, wan=$wan_iface)"
    return 0
}

# 卸载核心
dscpclassify_unload() {
    nft delete table inet "$TABLE" 2>/dev/null
    rm -rf "$INCLUDES_PATH"
    log info "dscpclassify unloaded"
}