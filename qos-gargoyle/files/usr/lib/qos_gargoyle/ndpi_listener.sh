#!/bin/sh
# ndpi_listener.sh - 监听 classifi 事件并设置 fwmark（动态计算标记，支持优先级和协议类型）
# 依赖：jsonfilter, nft, ubus, uci, rule.sh

CONFIG_FILE="qos_gargoyle"
TMP_DIR="/tmp/ndpi_listener"
PIDFILE="/var/run/ndpi_listener.pid"
PROTO_MAP="$TMP_DIR/proto_map.txt"
RULE_HELPER="/usr/lib/qos_gargoyle/rule.sh"

# 加载 rule.sh 以使用标记计算函数
if [ -f "$RULE_HELPER" ]; then
    . "$RULE_HELPER"
else
    echo "错误: 找不到 rule.sh，无法计算标记" >&2
    exit 1
fi

# 日志函数
log() {
    local level="$1"
    local msg="$2"
    logger -t "ndpi_listener" "$level: $msg"
    echo "[$(date '+%H:%M:%S')] ndpi_listener $level: $msg"
}

mkdir -p "$TMP_DIR"

# 从 UCI 加载 nDPI 规则，动态计算标记，按优先级排序后构建协议到标记的映射文件
build_mapping() {
    rm -f "$PROTO_MAP"
    local temp_rules=$(mktemp "$TMP_DIR/rules.XXXXXX")
    config_load "$CONFIG_FILE"
    config_foreach process_ndpi_rule ndpi_rule "$temp_rules"
    # 按优先级排序（数值越小越优先，未设置优先级默认为 999）
    sort -t: -k1,1n "$temp_rules" | cut -d: -f2- > "$PROTO_MAP"
    rm -f "$temp_rules"
}

process_ndpi_rule() {
    local section="$1"
    local temp_file="$2"
    local enabled proto upload_class download_class priority
    config_get enabled "$section" enabled 0
    [ "$enabled" != "1" ] && return
    config_get proto "$section" ndpi_proto
    config_get upload_class "$section" upload_class
    config_get download_class "$section" download_class
    config_get priority "$section" priority 999   # 默认最高优先级 999（数值越小越优先）

    [ -z "$proto" ] || [ -z "$upload_class" ] || [ -z "$download_class" ] && return

    # 计算上传标记
    local upload_mark download_mark
    upload_mark=$(get_class_mark_for_rule "$upload_class" "upload" 2>/dev/null)
    download_mark=$(get_class_mark_for_rule "$download_class" "download" 2>/dev/null)

    if [ -z "$upload_mark" ] || [ -z "$download_mark" ]; then
        log "WARN" "规则 $section 标记计算失败，跳过"
        return
    fi

    # 写入临时文件：优先级:协议列表:上传标记:下载标记
    echo "$priority:$proto:$upload_mark:$download_mark" >> "$temp_file"
}

# 根据 IP 地址判断地址族并返回对应的 nft 前缀
get_family_prefix() {
    case "$1" in
        *:*) echo "ip6" ;;
        *)   echo "ip"  ;;
    esac
}

# 构建 nft 匹配条件（根据协议类型决定是否使用端口）
build_nft_match() {
    local family="$1"
    local src_ip="$2"
    local dst_ip="$3"
    local proto_num="$4"
    local sport="$5"
    local dport="$6"
    local direction="$7"  # "egress" 或 "ingress"

    local match="$family saddr $src_ip $family daddr $dst_ip meta l4proto $proto_num"

    # 仅当协议为 TCP (6) 或 UDP (17) 时才添加端口匹配
    case "$proto_num" in
        6|17)
            if [ "$direction" = "egress" ]; then
                match="$match th sport $sport th dport $dport"
            else
                # ingress 方向端口需反转
                match="$match th dport $sport th sport $dport"
            fi
            ;;
    esac
    echo "$match"
}

# 监听 ubus 事件
listen() {
    ubus subscribe classifi.classified | while read -r event; do
        # 解析 JSON 事件（字段名需与 classifi 实际输出一致，此处为常见字段，请根据实际情况调整）
        proto=$(echo "$event" | jsonfilter -e '@.protocol' 2>/dev/null)
        src_ip=$(echo "$event" | jsonfilter -e '@.src_ip' 2>/dev/null)
        dst_ip=$(echo "$event" | jsonfilter -e '@.dst_ip' 2>/dev/null)
        sport=$(echo "$event" | jsonfilter -e '@.sport' 2>/dev/null)
        dport=$(echo "$event" | jsonfilter -e '@.dport' 2>/dev/null)
        proto_num=$(echo "$event" | jsonfilter -e '@.proto_num' 2>/dev/null)

        [ -z "$proto" ] && continue

        # 查找匹配的规则（按优先级排序，取第一个匹配的）
        upload_mark=""
        download_mark=""
        while IFS=: read -r rule_protos up down; do
            for p in $(echo "$rule_protos" | tr ',' ' '); do
                if [ "$p" = "$proto" ]; then
                    upload_mark="$up"
                    download_mark="$down"
                    break 2
                fi
            done
        done < "$PROTO_MAP"

        if [ -n "$upload_mark" ] && [ -n "$download_mark" ]; then
            # 确定地址族
            local src_family=$(get_family_prefix "$src_ip")
            local dst_family=$(get_family_prefix "$dst_ip")
            [ "$src_family" != "$dst_family" ] && continue

            # 构建上传方向规则（出口）
            local egress_match=$(build_nft_match "$src_family" "$src_ip" "$dst_ip" "$proto_num" "$sport" "$dport" "egress")
            nft add rule inet gargoyle-qos-priority filter_qos_egress \
                $egress_match meta mark set "$upload_mark" counter

            # 构建下载方向规则（入口）
            local ingress_match=$(build_nft_match "$dst_family" "$src_ip" "$dst_ip" "$proto_num" "$sport" "$dport" "ingress")
            nft add rule inet gargoyle-qos-priority filter_qos_ingress \
                $ingress_match ct mark set "$download_mark" counter
        fi
    done
}

start() {
    echo "$$" > "$PIDFILE"
    build_mapping
    log "INFO" "开始监听 classifi 事件"
    listen
}

stop() {
    kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
    rm -f "$PIDFILE"
    log "INFO" "监听已停止"
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; sleep 1; start ;;
    *) echo "Usage: $0 {start|stop|restart}" ;;
esac