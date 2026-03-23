#!/bin/sh
# 规则辅助模块 (rule.sh)
# 版本: 2.7.6 - 改进 ipset 元素处理兼容性；确保 nft 规则保存目录存在；
#               优化数字验证去除前导零；修复若干细微问题
# 注意：算法模块中不应重复定义 load_upload_class_configurations / load_download_class_configurations

: ${DEBUG:=0}

CONFIG_FILE="qos_gargoyle"
TEMP_FILES=""
RULESET_DIR="/etc/qos_gargoyle/rulesets"
RULESET_MERGED_FLAG="/tmp/qos_ruleset_merged"
CLASS_MARKS_FILE="/etc/qos_gargoyle/class_marks"

ENABLE_RATELIMIT=0
ENABLE_ACK_LIMIT=0
ENABLE_TCP_UPGRADE=0
SAVE_NFT_RULES=0
RATELIMIT_CHAIN="ratelimit"
CUSTOM_EGRESS_FILE="/etc/qos_gargoyle/egress_custom.nft"
CUSTOM_INGRESS_FILE="/etc/qos_gargoyle/ingress_custom.nft"
ACK_SLOW=50
ACK_MED=100
ACK_FAST=500
ACK_XFAST=5000

: ${QOS_RUNNING_FILE:=/var/run/qos_gargoyle.running}
: ${MAX_PHYSICAL_BANDWIDTH:=10000000}

SET_FAMILIES_FILE="/tmp/qos_gargoyle_set_families"
_IPSET_LOADED=0
HAVE_LOCK=0
_QOS_TABLE_FLUSHED=0
_NFT_VERSION_MAJOR=0
_NFT_VERSION_MINOR=0

upload_class_list=""
download_class_list=""

# ========== 日志函数 ==========
log_debug() { [ "$DEBUG" = "1" ] && log "DEBUG" "$@"; }
log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

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
        DEBUG|debug)   prefix="调试:" ;;
        *)             prefix="$level:" ;;
    esac

    echo "$message" | while IFS= read -r line; do
        logger -t "$tag" "$prefix $line"
    done

    if [ "$DEBUG" = "1" ]; then
        echo "$message" | while IFS= read -r line; do
            echo "[$(date '+%H:%M:%S')] $tag $prefix $line" >&2
        done
    fi
}

# ========== 加载全局配置 ==========
load_global_config() {
    ENABLE_RATELIMIT=$(uci -q get ${CONFIG_FILE}.global.enable_ratelimit 2>/dev/null)
    [ -z "$ENABLE_RATELIMIT" ] && ENABLE_RATELIMIT=0

    ENABLE_ACK_LIMIT=$(uci -q get ${CONFIG_FILE}.global.enable_ack_limit 2>/dev/null)
    [ -z "$ENABLE_ACK_LIMIT" ] && ENABLE_ACK_LIMIT=0

    ENABLE_TCP_UPGRADE=$(uci -q get ${CONFIG_FILE}.global.enable_tcp_upgrade 2>/dev/null)
    [ -z "$ENABLE_TCP_UPGRADE" ] && ENABLE_TCP_UPGRADE=0

    SAVE_NFT_RULES=$(uci -q get ${CONFIG_FILE}.global.save_nft_rules 2>/dev/null)
    [ -z "$SAVE_NFT_RULES" ] && SAVE_NFT_RULES=0
}

# ========== 获取 nftables 版本 ==========
get_nft_version() {
    local version_str
    version_str=$(nft --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -n "$version_str" ]; then
        _NFT_VERSION_MAJOR=$(echo "$version_str" | cut -d. -f1)
        _NFT_VERSION_MINOR=$(echo "$version_str" | cut -d. -f2)
    else
        _NFT_VERSION_MAJOR=0
        _NFT_VERSION_MINOR=0
    fi
}

# ========== 验证函数 ==========
validate_number() {
    local value="$1" param_name="$2" min="${3:-0}" max="${4:-2147483647}"
    if ! echo "$value" | grep -qE '^[0-9]+$'; then
        log_error "参数 $param_name 必须是整数: $value"
        return 1
    fi
    # 去除前导零，避免八进制问题
    local clean_value=$(echo "$value" | sed 's/^0*//')
    [ -z "$clean_value" ] && clean_value=0
    if [ "$clean_value" -lt "$min" ] 2>/dev/null || [ "$clean_value" -gt "$max" ] 2>/dev/null; then
        log_error "参数 $param_name 范围应为 $min-$max: $value"
        return 1
    fi
    return 0
}

validate_port() {
    local value="$1" param_name="$2"
    local old_ifs="$IFS"
    [ -z "$value" ] && return 0
    local clean_value=$(echo "$value" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')

    if echo "$clean_value" | grep -q ','; then
        IFS=,
        for port in $clean_value; do
            [ -z "$port" ] && continue
            if echo "$port" | grep -q '-'; then
                if ! echo "$port" | grep -qE '^[0-9]+-[0-9]+$'; then
                    log_error "无效的端口范围格式 '$port'"
                    IFS="$old_ifs"; return 1
                fi
                local min_port=${port%-*} max_port=${port#*-}
                if ! validate_number "$min_port" "$param_name" 1 65535 ||
                   ! validate_number "$max_port" "$param_name" 1 65535 ||
                   [ "$min_port" -gt "$max_port" ]; then
                    IFS="$old_ifs"; return 1
                fi
            else
                if ! validate_number "$port" "$param_name" 1 65535; then
                    IFS="$old_ifs"; return 1
                fi
            fi
        done
        IFS="$old_ifs"
    elif echo "$clean_value" | grep -q '-'; then
        if ! echo "$clean_value" | grep -qE '^[0-9]+-[0-9]+$'; then
            log_error "无效的端口范围格式 '$clean_value'"
            return 1
        fi
        local min_port=${clean_value%-*} max_port=${clean_value#*-}
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

validate_protocol() {
    local proto="$1" param_name="$2"
    [ -z "$proto" ] || [ "$proto" = "all" ] && return 0
    case "$proto" in
        tcp|udp|icmp|icmpv6|gre|esp|ah|sctp|dccp|udplite|tcp_udp) return 0 ;;
        *) log_warn "$param_name 协议名称 '$proto' 不是标准协议，将继续处理"; return 0 ;;
    esac
}

validate_family() {
    local family="$1" param_name="$2"
    [ -z "$family" ] && return 0
    case "$family" in
        inet|ip|ip6|inet6|ipv4|ipv6) return 0 ;;
        *) log_error "$param_name 无效的地址族 '$family'"; return 1 ;;
    esac
}

validate_connbytes() {
    local value="$1" param_name="$2"
    [ -z "$value" ] && return 0
    value=$(echo "$value" | tr -d ' \t\r')
    
    if echo "$value" | grep -qE '^[0-9]+-[0-9]+$'; then
        local min=${value%-*} max=${value#*-}
        if ! validate_number "$min" "$param_name" 0 1048576 ||
           ! validate_number "$max" "$param_name" 0 1048576 ||
           [ "$min" -gt "$max" ]; then
            return 1
        fi
    elif echo "$value" | grep -qE '^(<|<=|>|>=|=|!=)[0-9]+$'; then
        local operator=$(echo "$value" | sed 's/[0-9]*$//')
        local num=$(echo "$value" | grep -o '[0-9]\+')
        if ! validate_number "$num" "$param_name" 0 1048576; then
            return 1
        fi
        case "$operator" in
            '>'|'>='|'<'|'<='|'='|'!=') ;;
            *) log_error "$param_name 无效操作符 '$operator'"; return 1 ;;
        esac
    elif echo "$value" | grep -qE '^[0-9]+$'; then
        if ! validate_number "$value" "$param_name" 0 1048576; then return 1; fi
    else
        log_error "$param_name 无效格式 '$value'"
        return 1
    fi
    return 0
}

validate_state() {
    local state="$1" param_name="$2"
    local old_ifs="$IFS"
    [ -z "$state" ] && return 0
    local clean_state=$(echo "$state" | tr -d ' ')
    IFS=','
    for s in $clean_state; do
        s=$(echo "$s" | tr -d '{}')
        case "$s" in new|established|related|untracked|invalid) ;; *)
            log_error "$param_name 无效连接状态 '$s'"
            IFS="$old_ifs"; return 1 ;;
        esac
    done
    IFS="$old_ifs"
    return 0
}

validate_ip() {
    local ip="$1"
    local raw="${ip#!=}"

    if echo "$raw" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$'; then
        local ipnum="${raw%%/*}"
        local oct1=$(echo "$ipnum" | cut -d. -f1)
        local oct2=$(echo "$ipnum" | cut -d. -f2)
        local oct3=$(echo "$ipnum" | cut -d. -f3)
        local oct4=$(echo "$ipnum" | cut -d. -f4)
        for oct in "$oct1" "$oct2" "$oct3" "$oct4"; do
            if ! validate_number "$oct" "IP八位组" 0 255; then return 1; fi
        done
        if echo "$raw" | grep -q '/'; then
            local prefix="${raw#*/}"
            if ! validate_number "$prefix" "CIDR前缀" 0 32; then return 1; fi
        fi
        return 0
    fi

    if echo "$raw" | grep -qiE '^(([0-9a-fA-F]{1,4}:){0,7}[0-9a-fA-F]{1,4}|::|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){0,6}:[0-9a-fA-F]{1,4})(/[0-9]{1,3})?$'; then
        if echo "$raw" | grep -q '::.*::'; then
            log_error "IPv6地址 '$raw' 包含多个 '::'"
            return 1
        fi
        if echo "$raw" | grep -q ':::'; then
            log_error "IPv6地址 '$raw' 包含非法序列 ':::'"
            return 1
        fi
        if echo "$raw" | grep -qE '^:[^:]' || echo "$raw" | grep -qE '[^:]:$'; then
            if ! echo "$raw" | grep -qE '^(::|::/|::/.*)$'; then
                log_error "IPv6地址 '$raw' 不能以单个冒号开头或结尾"
                return 1
            fi
        fi
        local segments=$(echo "$raw" | cut -d/ -f1 | tr ':' ' ' | sed 's/  */ /g')
        local seg
        for seg in $segments; do
            if [ -n "$seg" ] && [ ${#seg} -gt 4 ]; then
                log_error "IPv6地址段 '$seg' 长度超过4个十六进制字符"
                return 1
            fi
        done
        if echo "$raw" | grep -q '/'; then
            local prefix="${raw#*/}"
            if ! validate_number "$prefix" "CIDR前缀" 0 128; then return 1; fi
        fi
        return 0
    fi

    if echo "$raw" | grep -qiE '^(([0-9a-fA-F]{1,4}:){0,6}):?[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,3})?$'; then
        local ipv4_part=$(echo "$raw" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
        if validate_ip "$ipv4_part"; then
            return 0
        fi
    fi

    return 1
}

validate_tcp_flags() {
    local val="$1" param_name="$2"
    val=$(echo "$val" | tr -d ' \t\r\n')
    [ -z "$val" ] && return 0

    local old_ifs="$IFS"
    IFS=','
    for f in $val; do
        [ -z "$f" ] && continue
        case "$f" in
            syn|ack|rst|fin|urg|psh|ecn|cwr) ;;
            *) log_error "无效的 TCP 标志 '$f' (允许: syn,ack,rst,fin,urg,psh,ecn,cwr)"; IFS="$old_ifs"; return 1 ;;
        esac
    done
    IFS="$old_ifs"
    return 0
}

validate_length() {
    local value="$1" param_name="$2"
    [ -z "$value" ] && return 0
    value=$(echo "$value" | tr -d ' \t\r')
    
    if echo "$value" | grep -qE '^[0-9]+-[0-9]+$'; then
        local min=${value%-*} max=${value#*-}
        if ! validate_number "$min" "$param_name" 0 65535 ||
           ! validate_number "$max" "$param_name" 0 65535 ||
           [ "$min" -gt "$max" ]; then
            return 1
        fi
    elif echo "$value" | grep -qE '^(<|<=|>|>=|=|!=)[0-9]+$'; then
        local operator=$(echo "$value" | sed 's/[0-9]*$//')
        local num=$(echo "$value" | grep -o '[0-9]\+')
        if ! validate_number "$num" "$param_name" 0 65535; then
            return 1
        fi
        case "$operator" in
            '>'|'>='|'<'|'<='|'='|'!=') ;;
            *) log_error "$param_name 无效操作符 '$operator'"; return 1 ;;
        esac
    elif echo "$value" | grep -qE '^[0-9]+$'; then
        if ! validate_number "$value" "$param_name" 0 65535; then return 1; fi
    else
        log_error "$param_name 无效格式 '$value'"
        return 1
    fi
    return 0
}

validate_dscp() {
    local val="$1" param_name="$2"
    local neg=""
    case "$val" in '!='*) neg="!="; val="${val#!=}"; ;; esac
    if ! validate_number "$val" "$param_name" 0 63; then
        return 1
    fi
    return 0
}

validate_ifname() {
    local val="$1" param_name="$2"
    if ! echo "$val" | grep -qE '^[a-zA-Z0-9_.-]+$'; then
        log_error "$param_name 接口名无效: $val"
        return 1
    fi
    return 0
}

validate_icmp_type() {
    local val="$1" param_name="$2"
    local neg=""
    case "$val" in '!='*) neg="!="; val="${val#!=}"; ;; esac
    if echo "$val" | grep -q '/'; then
        local type=${val%/*} code=${val#*/}
        if ! validate_number "$type" "$param_name" 0 255 || ! validate_number "$code" "$param_name" 0 255; then
            return 1
        fi
    else
        if ! validate_number "$val" "$param_name" 0 255; then
            return 1
        fi
    fi
    return 0
}

validate_ttl() {
    local value="$1" param_name="$2"
    [ -z "$value" ] && return 0
    if echo "$value" | grep -qE '^([<>]?=?|!=)[0-9]+$'; then
        local operator=$(echo "$value" | sed 's/[0-9]*$//')
        local num=$(echo "$value" | grep -o '[0-9]\+')
        if ! validate_number "$num" "$param_name" 1 255; then
            return 1
        fi
        case "$operator" in '>'|'>='|'<'|'<='|'='|'!=') ;; *) log_error "$param_name 无效操作符 '$operator'"; return 1 ;; esac
    elif echo "$value" | grep -qE '^[0-9]+$'; then
        if ! validate_number "$value" "$param_name" 1 255; then
            return 1
        fi
    else
        log_error "$param_name 无效格式 '$value'"
        return 1
    fi
    return 0
}

map_connbytes_operator() {
    local op="$1"
    case "$op" in
        ">")  echo "gt" ;;
        ">=") echo "ge" ;;
        "<")  echo "lt" ;;
        "<=") echo "le" ;;
        "!=") echo "ne" ;;
        "=")  echo "eq" ;;
        *)    echo "$op" ;;
    esac
}

# ========== 标记分配 ==========
init_class_marks_file() {
    mkdir -p "$(dirname "$CLASS_MARKS_FILE")" 2>/dev/null
}

allocate_class_marks() {
    local direction="$1" class_list="$2"
    local base_value i=1 mark mark_index
    local used_indexes=""
    local temp_file="${CLASS_MARKS_FILE}.tmp.$$"

    init_class_marks_file
    if [ "$direction" = "upload" ]; then
        base_value=1
    else
        base_value=65536
    fi

    for class in $class_list; do
        mark_index=$(uci -q get "${CONFIG_FILE}.${class}.mark_index" 2>/dev/null)
        if [ -n "$mark_index" ]; then
            if ! validate_number "$mark_index" "$class.mark_index" 1 16; then
                return 1
            fi
            case " $used_indexes " in
                *" $mark_index "*)
                    log_error "类别 $class 指定的标记索引 $mark_index 已被占用"
                    return 1
                    ;;
            esac
            used_indexes="$used_indexes $mark_index"
        fi
    done

    local next_auto=1
    for class in $class_list; do
        mark_index=$(uci -q get "${CONFIG_FILE}.${class}.mark_index" 2>/dev/null)
        if [ -n "$mark_index" ] && validate_number "$mark_index" "$class.mark_index" 1 16 2>/dev/null; then
            :
        else
            while [ $next_auto -le 16 ]; do
                case " $used_indexes " in
                    *" $next_auto "*) next_auto=$((next_auto + 1)) ;;
                    *) break ;;
                esac
            done
            if [ $next_auto -gt 16 ]; then
                log_error "没有可用的标记索引，无法为类别 $class 分配标记"
                return 1
            fi
            mark_index=$next_auto
            used_indexes="$used_indexes $mark_index"
            next_auto=$((next_auto + 1))
        fi
        mark=$(( (base_value << (mark_index - 1)) & 0xFFFFFFFF ))
        echo "$direction:$class:$mark" >> "$temp_file"
        log_info "类别 $class 分配标记索引 $mark_index (值: $mark / 0x$(printf '%X' $mark))"
    done

    if [ -s "$temp_file" ]; then
        if [ -f "$CLASS_MARKS_FILE" ]; then
            grep -v "^$direction:" "$CLASS_MARKS_FILE" 2>/dev/null > "${temp_file}.merge"
            cat "$temp_file" >> "${temp_file}.merge"
            mv "${temp_file}.merge" "$CLASS_MARKS_FILE"
        else
            mv "$temp_file" "$CLASS_MARKS_FILE"
        fi
        chmod 644 "$CLASS_MARKS_FILE"
    fi
    rm -f "$temp_file" 2>/dev/null
    return 0
}

get_class_mark() {
    local direction="$1" class="$2" mark_line
    init_class_marks_file
    [ ! -f "$CLASS_MARKS_FILE" ] && { log_error "类标记文件不存在"; return 1; }
    mark_line=$(grep "^$direction:$class:" "$CLASS_MARKS_FILE" 2>/dev/null | head -1)
    if [ -n "$mark_line" ]; then
        echo "${mark_line##*:}"
        return 0
    else
        log_error "类别 $class 的标记值未找到"
        return 1
    fi
}

clear_class_marks() {
    log_debug "标记文件持久化，停止时不删除"
}

# ========== 配置加载函数 ==========
load_all_config_sections() {
    local config_name="$1" section_type="$2"
    local config_output=$(uci show "$config_name" 2>/dev/null)
    [ -z "$config_output" ] && { echo ""; return; }

    if [ -n "$section_type" ]; then
        local anonymous=$(echo "$config_output" | grep -E "^${config_name}\\.@${section_type}\\[[0-9]+\\]=" | cut -d= -f1 | sed "s/^${config_name}\\.//")
        local named=$(echo "$config_output" | grep -E "^${config_name}\\.[a-zA-Z0-9_]+=${section_type}"'$' | cut -d= -f1 | cut -d. -f2)
        local old=$(echo "$config_output" | grep -E "^${config_name}\\.${section_type}_[0-9]+=" | cut -d= -f1 | cut -d. -f2)
        echo "$anonymous $named $old" | tr ' ' '\n' | grep -v "^$" | sort -u | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    else
        echo "$config_output" | grep -E "^${config_name}\\.[a-zA-Z_]+[0-9]*=" | cut -d= -f1 | cut -d. -f2
    fi
}

load_upload_class_configurations() {
    log_info "正在加载上传类别配置..."
    upload_class_list=$(load_all_config_sections "$CONFIG_FILE" "upload_class")
    if [ -n "$upload_class_list" ]; then
        log_info "找到上传类别: $upload_class_list"
    else
        log_warn "没有找到上传类别配置"
        upload_class_list=""
    fi
    return 0
}

load_download_class_configurations() {
    log_info "正在加载下载类别配置..."
    download_class_list=$(load_all_config_sections "$CONFIG_FILE" "download_class")
    if [ -n "$download_class_list" ]; then
        log_info "找到下载类别: $download_class_list"
    else
        log_warn "没有找到下载类别配置"
        download_class_list=""
    fi
    return 0
}

load_all_config_options() {
    local config_name="$1" section_id="$2" prefix="$3"
    local escaped_section_id=$(printf "%s" "$section_id" | sed 's/[][\.*?^$()+{}|]/\\&/g')
    for var in class order enabled proto srcport dstport connbytes_kb family state src_ip dest_ip \
          tcp_flags packet_len dscp iif oif icmp_type udp_length ttl; do
        eval "${prefix}${var}=''"
    done
    local config_data=$(uci show "${config_name}.${section_id}" 2>/dev/null)
    local val

    val=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.class=" | cut -d= -f2-)
    if [ -n "$val" ]; then
        val=$(echo "$val" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//" | tr -d '\n\r' | sed 's/[^a-zA-Z0-9_-]//g')
        eval "${prefix}class=\"$val\""
    else
        log_warn "配置节 $section_id 缺少 class 参数，忽略此规则"
        return 1
    fi

    local multi_opts="srcport dstport connbytes_kb src_ip dest_ip tcp_flags packet_len udp_length"
    
    for opt in order enabled proto srcport dstport connbytes_kb family state src_ip dest_ip \
          tcp_flags packet_len dscp iif oif icmp_type udp_length ttl; do
        local lines=$(echo "$config_data" | grep "^${config_name}\\.${escaped_section_id}\\.${opt}=")
        [ -z "$lines" ] && continue
        
        if echo " $multi_opts " | grep -q " $opt "; then
            val=$(echo "$lines" | tail -n1 | sed -n "s/^.*=//p" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        else
            val=$(echo "$lines" | tail -n1 | sed -n "s/^.*=//p" | sed "s/^'//; s/'$//; s/^\"//; s/\"$//")
        fi
        
        val=$(echo "$val" | tr -d '\r')
        [ -z "$val" ] && continue
        
        case "$opt" in
            order)   val=$(echo "$val" | sed 's/[^0-9]//g'); [ -n "$val" ] && eval "${prefix}order=\"$val\"" ;;
            enabled) val=$(echo "$val" | grep -o '^[01]'); [ -n "$val" ] && eval "${prefix}enabled=\"$val\"" ;;
            proto)   if validate_protocol "$val" "${section_id}.proto"; then
                         val=$(echo "$val" | sed 's/[^a-zA-Z0-9_]//g')
                         eval "${prefix}proto=\"$val\""
                     else log_warn "规则 $section_id 协议 '$val' 无效，忽略此字段"; fi ;;
            srcport) if validate_port "$val" "${section_id}.srcport"; then
                         val=$(echo "$val" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')
                         eval "${prefix}srcport=\"$val\""
                     else log_warn "规则 $section_id 源端口 '$val' 无效，忽略此字段"; fi ;;
            dstport) if validate_port "$val" "${section_id}.dstport"; then
                         val=$(echo "$val" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')
                         eval "${prefix}dstport=\"$val\""
                     else log_warn "规则 $section_id 目的端口 '$val' 无效，忽略此字段"; fi ;;
            connbytes_kb) if validate_connbytes "$val" "${section_id}.connbytes_kb"; then
                              val=$(echo "$val" | sed 's/[^0-9<>!= -]//g' | tr -d ' ')
                              eval "${prefix}connbytes_kb=\"$val\""
                          else log_warn "规则 $section_id 连接字节数 '$val' 无效，忽略此字段"; fi ;;
            family)  if validate_family "$val" "${section_id}.family"; then
                         val=$(echo "$val" | sed 's/[^a-zA-Z0-9]//g')
                         eval "${prefix}family=\"$val\""
                     else log_warn "规则 $section_id 地址族 '$val' 无效，忽略此字段"; fi ;;
            state)   if validate_state "$val" "${section_id}.state"; then
                         val=$(echo "$val" | tr -d '[:space:]' | sed 's/[^{},a-zA-Z]//g')
                         eval "${prefix}state=\"$val\""
                     else log_warn "规则 $section_id 连接状态 '$val' 无效，忽略此字段"; fi ;;
            src_ip)  if validate_ip "$val"; then
                         eval "${prefix}src_ip=\"$val\""
                     else log_warn "规则 $section_id 源 IP '$val' 格式无效，忽略此字段"; fi ;;
            dest_ip) if validate_ip "$val"; then
                         eval "${prefix}dest_ip=\"$val\""
                     else log_warn "规则 $section_id 目的 IP '$val' 格式无效，忽略此字段"; fi ;;
            tcp_flags) 
                val=$(echo "$val" | tr -d ' \t\r\n')
                case "$val" in
                    k|k,*) val="ack"; log_debug "规则 $section_id TCP标志从 '$val' 修正为 'ack'" ;;
                    *k*) val="ack"; log_debug "规则 $section_id TCP标志包含 'k'，已修正为 'ack'" ;;
                esac
                if [ -n "$val" ] && validate_tcp_flags "$val" "${section_id}.tcp_flags"; then
                    eval "${prefix}tcp_flags=\"$val\""
                else
                    log_warn "规则 $section_id TCP标志 '$val' 无效，忽略此字段"
                fi
                ;;
            packet_len) if validate_length "$val" "${section_id}.packet_len"; then
                            eval "${prefix}packet_len=\"$val\""
                        else log_warn "规则 $section_id 包长度 '$val' 无效，忽略此字段"; fi ;;
            dscp)       if validate_dscp "$val" "${section_id}.dscp"; then
                            eval "${prefix}dscp=\"$val\""
                        else log_warn "规则 $section_id DSCP值 '$val' 无效，忽略此字段"; fi ;;
            iif)        if validate_ifname "$val" "${section_id}.iif"; then
                            eval "${prefix}iif=\"$val\""
                        else log_warn "规则 $section_id 入接口 '$val' 无效，忽略此字段"; fi ;;
            oif)        if validate_ifname "$val" "${section_id}.oif"; then
                            eval "${prefix}oif=\"$val\""
                        else log_warn "规则 $section_id 出接口 '$val' 无效，忽略此字段"; fi ;;
            icmp_type)  if validate_icmp_type "$val" "${section_id}.icmp_type"; then
                            eval "${prefix}icmp_type=\"$val\""
                        else log_warn "规则 $section_id ICMP类型 '$val' 无效，忽略此字段"; fi ;;
            udp_length) if validate_length "$val" "${section_id}.udp_length"; then
                            eval "${prefix}udp_length=\"$val\""
                        else log_warn "规则 $section_id UDP长度 '$val' 无效，忽略此字段"; fi ;;
            ttl)        if validate_ttl "$val" "${section_id}.ttl"; then
                            eval "${prefix}ttl=\"$val\""
                        else log_warn "规则 $section_id TTL值 '$val' 无效，忽略此字段"; fi ;;
        esac
    done
    return 0
}

sort_rules_by_priority_fast() {
    local config_file="$1" temp_sort
    temp_sort=$(mktemp /tmp/qos_sort_XXXXXX) || { log_error "无法创建排序临时文件"; return 1; }
    TEMP_FILES="$TEMP_FILES $temp_sort"

    while IFS=$'\t' read -r r_name r_class r_order r_enabled r_proto r_srcport r_dstport r_connbytes r_family r_state r_src_ip r_dest_ip; do
        [ -z "$r_name" ] && continue
        [ "$r_enabled" != "1" ] && continue
        local class_priority=$(uci -q get "${CONFIG_FILE}.${r_class}.priority" 2>/dev/null)
        class_priority=${class_priority:-999}
        local rule_order=${r_order:-100}
        local composite=$(( class_priority * 1000 + rule_order ))
        echo "$composite:$r_name" >> "$temp_sort"
    done < "$config_file"

    local result=$(sort -t ':' -k1,1n "$temp_sort" 2>/dev/null | cut -d: -f2- | tr '\n' ' ' | sed 's/ $//')
    rm -f "$temp_sort" 2>/dev/null
    echo "$result"
}

# ========== UCI ipset 生成 nftables 集合 ==========
generate_ipset_sets() {
    [ "$_IPSET_LOADED" -eq 1 ] && return 0

    if ! nft list table inet gargoyle-qos-priority >/dev/null 2>&1; then
        nft add table inet gargoyle-qos-priority 2>/dev/null || true
    fi

    if ! type config_get_bool >/dev/null 2>&1; then
        . /lib/functions.sh
    fi
    config_load "$CONFIG_FILE" 2>/dev/null

    local sets_file=$(mktemp /tmp/qos_ipset_sets_XXXXXX)
    local families_file="$SET_FAMILIES_FILE"
    TEMP_FILES="$TEMP_FILES $sets_file"
    > "$families_file"

    process_ipset_section() {
        local section="$1" name enabled mode family timeout ip4 ip6 ip4_list ip6_list
        local elements=""

        config_get_bool enabled "$section" enabled 1
        [ "$enabled" -eq 0 ] && return 0
        config_get name "$section" name
        [ -z "$name" ] && { log_warn "ipset 节 $section 缺少 name，跳过"; return 0; }
        config_get mode "$section" mode "static"
        config_get family "$section" family "ipv4"
        config_get timeout "$section" timeout "1h"
        case "$family" in ipv4|ipv6) ;; *) log_warn "ipset $name 族 '$family' 无效，使用 ipv4"; family="ipv4"; ;; esac

        if [ "$family" = "ipv6" ]; then
            config_get ip6 "$section" ip6
            ip6_list="$ip6"
        else
            config_get ip4 "$section" ip4
            ip4_list="$ip4"
        fi

        echo "$name $family" >> "$families_file"

        if [ "$mode" = "dynamic" ]; then
            echo "add set inet gargoyle-qos-priority $name { type ${family}_addr; flags dynamic, timeout; timeout $timeout; } 2>/dev/null || true" >> "$sets_file"
        else
            if [ "$family" = "ipv6" ]; then
                [ -n "$ip6_list" ] && elements=$(echo "$ip6_list" | tr -s ' ' ',' | sed 's/^,//;s/,$//')
            else
                [ -n "$ip4_list" ] && elements=$(echo "$ip4_list" | tr -s ' ' ',' | sed 's/^,//;s/,$//')
            fi
            if [ -n "$elements" ]; then
                echo "add set inet gargoyle-qos-priority $name { type ${family}_addr; flags interval; elements = { $elements }; } 2>/dev/null || true" >> "$sets_file"
            else
                echo "add set inet gargoyle-qos-priority $name { type ${family}_addr; flags interval; } 2>/dev/null || true" >> "$sets_file"
            fi
        fi
        log_info "已生成 ipset: $name ($family, mode=$mode)"
    }

    local sections=$(load_all_config_sections "$CONFIG_FILE" "ipset")
    for section in $sections; do process_ipset_section "$section"; done

    if [ -s "$sets_file" ]; then
        nft -f "$sets_file" 2>/dev/null || log_warn "部分 ipset 集合加载失败，请检查 UCI 配置"
        log_info "已加载 UCI 定义的 ipset 集合"
    fi
    rm -f "$sets_file"
    _IPSET_LOADED=1
}

# ========== 速率限制辅助函数 ==========
build_ip_conditions_for_direction() {
    local ip_list="$1" direction="$2" result_var="$3"
    local result="" ipv4_pos="" ipv4_neg="" ipv6_pos="" ipv6_neg=""
    local value negation v

    for value in $ip_list; do
        negation=""; v="$value"
        case "$v" in '!='*) negation="!="; v="${v#!=}"; ;; esac
        if printf '%s' "$v" | grep -q ':' && ! printf '%s' "$v" | grep -qE '^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$'; then
            if [ -n "$negation" ]; then
                ipv6_neg="${ipv6_neg}${ipv6_neg:+,}${v}"
            else
                ipv6_pos="${ipv6_pos}${ipv6_pos:+,}${v}"
            fi
        else
            if [ -n "$negation" ]; then
                ipv4_neg="${ipv4_neg}${ipv4_neg:+,}${v}"
            else
                ipv4_pos="${ipv4_pos}${ipv4_pos:+,}${v}"
            fi
        fi
    done

    [ -n "$ipv4_neg" ] && result="${result}${result:+ }ip ${direction} != { ${ipv4_neg} }"
    [ -n "$ipv4_pos" ] && result="${result}${result:+ }ip ${direction} { ${ipv4_pos} }"
    [ -n "$ipv6_neg" ] && result="${result}${result:+ }ip6 ${direction} != { ${ipv6_neg} }"
    [ -n "$ipv6_pos" ] && result="${result}${result:+ }ip6 ${direction} { ${ipv6_pos} }"
    eval "${result_var}=\"\${result}\""
}

generate_ratelimit_rules() {
    [ "$ENABLE_RATELIMIT" != "1" ] && return

    if ! type config_load >/dev/null 2>&1; then
        . /lib/functions.sh
    fi
    config_load "$CONFIG_FILE" 2>/dev/null

    local rules=""
    local use_meter=0

    get_nft_version
    if [ "$_NFT_VERSION_MAJOR" -eq 0 ] && [ "$_NFT_VERSION_MINOR" -lt 9 ]; then
        use_meter=1
        log_info "nftables 版本低于 0.9.0，速率限制使用 meter 模式"
    elif [ "$_NFT_VERSION_MAJOR" -eq 0 ] && [ "$_NFT_VERSION_MINOR" -ge 9 ] && [ "$_NFT_VERSION_MAJOR" -lt 1 ]; then
        use_meter=0
        log_info "nftables 版本 $_NFT_VERSION_MAJOR.$_NFT_VERSION_MINOR，速率限制使用动态集合 + limit 模式"
    elif [ "$_NFT_VERSION_MAJOR" -ge 1 ]; then
        use_meter=0
        log_info "nftables 版本 $_NFT_VERSION_MAJOR.$_NFT_VERSION_MINOR，速率限制使用动态集合 + limit 模式"
    else
        use_meter=0
    fi

    process_ratelimit_section() {
        local section="$1" name enabled download_limit upload_limit burst_factor target_values
        local meter_suffix download_kbytes upload_kbytes download_burst upload_burst meter_hash
        local sets_neg_v4="" sets_pos_v4="" ips_neg_v4="" ips_pos_v4=""
        local sets_neg_v6="" sets_pos_v6="" ips_neg_v6="" ips_pos_v6=""
        local value prefix setname set_family
        local download_burst_param='' upload_burst_param=''
        local burst_int burst_dec

        config_get_bool enabled "$section" enabled 1
        [ "$enabled" -eq 0 ] && return 0
        config_get name "$section" name
        [ -z "$name" ] && return 0
        config_get download_limit "$section" download_limit "0"
        config_get upload_limit "$section" upload_limit "0"
        config_get burst_factor "$section" burst_factor "1.0"
        config_get target_values "$section" target
        [ -z "$target_values" ] && return 0
        [ "$download_limit" -eq 0 ] && [ "$upload_limit" -eq 0 ] && return 0

        meter_hash=$(printf "%s" "$section" | cksum | cut -d' ' -f1)
        meter_suffix="${name}_${meter_hash}"
        download_kbytes=$((download_limit / 8))
        upload_kbytes=$((upload_limit / 8))

        case "$burst_factor" in
            0|0.0|0.00) ;;
            *.*) 
                burst_int="${burst_factor%.*}" burst_dec="${burst_factor#*.}"
                [ -z "$burst_int" ] && burst_int='0'
                [ -z "$burst_dec" ] && burst_dec='0'
                case "${#burst_dec}" in 1) burst_dec="${burst_dec}0" ;; 2) ;; *) burst_dec="${burst_dec:0:2}" ;; esac
                download_burst=$((download_kbytes * burst_int + download_kbytes * burst_dec / 100))
                upload_burst=$((upload_kbytes * burst_int + upload_kbytes * burst_dec / 100))
                [ "$download_burst" -gt 0 ] && download_burst_param=" burst ${download_burst} kbytes"
                [ "$upload_burst" -gt 0 ] && upload_burst_param=" burst ${upload_burst} kbytes"
                ;;
            *)
                download_burst=$((download_kbytes * burst_factor))
                upload_burst=$((upload_kbytes * burst_factor))
                download_burst_param=" burst ${download_burst} kbytes"
                upload_burst_param=" burst ${upload_burst} kbytes"
                ;;
        esac

        for value in $target_values; do
            prefix=''
            case "$value" in '!='*) prefix='!='; value="${value#!=}"; ;; esac
            case "$value" in '@'*)
                setname="${value#@}"
                if [ -f "$SET_FAMILIES_FILE" ]; then
                    set_family="$(awk -v set="$setname" '$1 == set {print $2}' "$SET_FAMILIES_FILE" 2>/dev/null)"
                fi
                if [ -z "$set_family" ]; then
                    if command -v nft >/dev/null 2>&1; then
                        set_family=$(nft list set inet gargoyle-qos-priority "$setname" 2>/dev/null | grep -o 'type [a-z0-9_]*' | head -1 | awk '{print $2}')
                        set_family=${set_family%_addr}
                    fi
                fi
                [ -z "$set_family" ] && set_family="ipv4"
                if [ "$set_family" = "ipv6" ]; then
                    if [ -n "$prefix" ]; then
                        sets_neg_v6="${sets_neg_v6}${sets_neg_v6:+, }${setname}"
                    else
                        sets_pos_v6="${sets_pos_v6}${sets_pos_v6:+, }${setname}"
                    fi
                else
                    if [ -n "$prefix" ]; then
                        sets_neg_v4="${sets_neg_v4}${sets_neg_v4:+, }${setname}"
                    else
                        sets_pos_v4="${sets_pos_v4}${sets_pos_v4:+, }${setname}"
                    fi
                fi
                ;;
            *)
                if printf '%s' "$value" | grep -q ':' && ! printf '%s' "$value" | grep -qE '^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$'; then
                    if [ -n "$prefix" ]; then
                        ips_neg_v6="${ips_neg_v6}${ips_neg_v6:+, }${value}"
                    else
                        ips_pos_v6="${ips_pos_v6}${ips_pos_v6:+, }${value}"
                    fi
                else
                    if [ -n "$prefix" ]; then
                        ips_neg_v4="${ips_neg_v4}${ips_neg_v4:+, }${value}"
                    else
                        ips_pos_v4="${ips_pos_v4}${ips_pos_v4:+, }${value}"
                    fi
                fi
                ;;
            esac
        done

        if [ "$use_meter" -eq 1 ]; then
            # 使用 meter 的原始实现
            if [ "$download_limit" -gt 0 ]; then
                for grp in "pos:$ips_pos_v4" "neg:$ips_neg_v4"; do
                    local type="${grp%:*}" iplist="${grp#*:}"
                    [ -z "$iplist" ] && continue
                    local cond=""
                    build_ip_conditions_for_direction "$iplist" "daddr" cond
                    if [ -n "$cond" ]; then
                        local meter_name="${meter_suffix}_dl4_ip_${type}"
                        rules="${rules}
        # ${name} - Download limit (IPv4 IP ${type})
        ${cond} meter ${meter_name} { ip daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} } counter drop comment \"${name} download\""
                    fi
                done
                for set in $sets_pos_v4; do
                    rules="${rules}
        # ${name} - Download limit (IPv4 set @${set})
        ip daddr @${set} meter ${meter_suffix}_dl4_set_${set} { ip daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} } counter drop comment \"${name} download\""
                done
                for set in $sets_neg_v4; do
                    rules="${rules}
        # ${name} - Download limit (IPv4 set != @${set})
        ip daddr != @${set} meter ${meter_suffix}_dl4_set_neg_${set} { ip daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} } counter drop comment \"${name} download\""
                done
            fi

            if [ "$upload_limit" -gt 0 ]; then
                for grp in "pos:$ips_pos_v4" "neg:$ips_neg_v4"; do
                    local type="${grp%:*}" iplist="${grp#*:}"
                    [ -z "$iplist" ] && continue
                    local cond=""
                    build_ip_conditions_for_direction "$iplist" "saddr" cond
                    if [ -n "$cond" ]; then
                        local meter_name="${meter_suffix}_ul4_ip_${type}"
                        rules="${rules}
        # ${name} - Upload limit (IPv4 IP ${type})
        ${cond} meter ${meter_name} { ip saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} } counter drop comment \"${name} upload\""
                    fi
                done
                for set in $sets_pos_v4; do
                    rules="${rules}
        # ${name} - Upload limit (IPv4 set @${set})
        ip saddr @${set} meter ${meter_suffix}_ul4_set_${set} { ip saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} } counter drop comment \"${name} upload\""
                done
                for set in $sets_neg_v4; do
                    rules="${rules}
        # ${name} - Upload limit (IPv4 set != @${set})
        ip saddr != @${set} meter ${meter_suffix}_ul4_set_neg_${set} { ip saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} } counter drop comment \"${name} upload\""
                done
            fi

            if [ "$download_limit" -gt 0 ]; then
                for grp in "pos:$ips_pos_v6" "neg:$ips_neg_v6"; do
                    local type="${grp%:*}" iplist="${grp#*:}"
                    [ -z "$iplist" ] && continue
                    local cond=""
                    build_ip_conditions_for_direction "$iplist" "daddr" cond
                    if [ -n "$cond" ]; then
                        local meter_name="${meter_suffix}_dl6_ip_${type}"
                        rules="${rules}
        # ${name} - Download limit (IPv6 IP ${type})
        ${cond} meter ${meter_name} { ip6 daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} } counter drop comment \"${name} download\""
                    fi
                done
                for set in $sets_pos_v6; do
                    rules="${rules}
        # ${name} - Download limit (IPv6 set @${set})
        ip6 daddr @${set} meter ${meter_suffix}_dl6_set_${set} { ip6 daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} } counter drop comment \"${name} download\""
                done
                for set in $sets_neg_v6; do
                    rules="${rules}
        # ${name} - Download limit (IPv6 set != @${set})
        ip6 daddr != @${set} meter ${meter_suffix}_dl6_set_neg_${set} { ip6 daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} } counter drop comment \"${name} download\""
                done
            fi

            if [ "$upload_limit" -gt 0 ]; then
                for grp in "pos:$ips_pos_v6" "neg:$ips_neg_v6"; do
                    local type="${grp%:*}" iplist="${grp#*:}"
                    [ -z "$iplist" ] && continue
                    local cond=""
                    build_ip_conditions_for_direction "$iplist" "saddr" cond
                    if [ -n "$cond" ]; then
                        local meter_name="${meter_suffix}_ul6_ip_${type}"
                        rules="${rules}
        # ${name} - Upload limit (IPv6 IP ${type})
        ${cond} meter ${meter_name} { ip6 saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} } counter drop comment \"${name} upload\""
                    fi
                done
                for set in $sets_pos_v6; do
                    rules="${rules}
        # ${name} - Upload limit (IPv6 set @${set})
        ip6 saddr @${set} meter ${meter_suffix}_ul6_set_${set} { ip6 saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} } counter drop comment \"${name} upload\""
                done
                for set in $sets_neg_v6; do
                    rules="${rules}
        # ${name} - Upload limit (IPv6 set != @${set})
        ip6 saddr != @${set} meter ${meter_suffix}_ul6_set_neg_${set} { ip6 saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} } counter drop comment \"${name} upload\""
                done
            fi
        else
            local timeout=60
            local set_timeout=$(uci -q get ${CONFIG_FILE}.${section}.timeout 2>/dev/null)
            [ -n "$set_timeout" ] && timeout="$set_timeout"

            local set_name_dl4="ratelimit_${meter_suffix}_dl4"
            local set_name_ul4="ratelimit_${meter_suffix}_ul4"
            local set_name_dl6="ratelimit_${meter_suffix}_dl6"
            local set_name_ul6="ratelimit_${meter_suffix}_ul6"

            if [ "$download_limit" -gt 0 ]; then
                rules="${rules}
add set inet gargoyle-qos-priority ${set_name_dl4} { type ipv4_addr; flags dynamic, timeout; timeout ${timeout}s; } 2>/dev/null || true
add set inet gargoyle-qos-priority ${set_name_dl6} { type ipv6_addr; flags dynamic, timeout; timeout ${timeout}s; } 2>/dev/null || true"
            fi
            if [ "$upload_limit" -gt 0 ]; then
                rules="${rules}
add set inet gargoyle-qos-priority ${set_name_ul4} { type ipv4_addr; flags dynamic, timeout; timeout ${timeout}s; } 2>/dev/null || true
add set inet gargoyle-qos-priority ${set_name_ul6} { type ipv6_addr; flags dynamic, timeout; timeout ${timeout}s; } 2>/dev/null || true"
            fi

            if [ "$download_limit" -gt 0 ]; then
                for grp in "pos:$ips_pos_v4" "neg:$ips_neg_v4"; do
                    local type="${grp%:*}" iplist="${grp#*:}"
                    [ -z "$iplist" ] && continue
                    local cond=""
                    build_ip_conditions_for_direction "$iplist" "daddr" cond
                    if [ -n "$cond" ]; then
                        rules="${rules}
        # ${name} - Download limit (IPv4 IP ${type}) - in set drop
        ${cond} ip daddr @${set_name_dl4} counter drop comment \"${name} download (in set)\"
        # ${name} - Download limit (IPv4 IP ${type}) - rate limit
        ${cond} ip daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl4} { ip daddr } counter drop comment \"${name} download (rate limit)\""
                    fi
                done
                for set in $sets_pos_v4; do
                    rules="${rules}
        # ${name} - Download limit (IPv4 set @${set})
        ip daddr @${set} ip daddr @${set_name_dl4} counter drop comment \"${name} download (in set)\"
        ip daddr @${set} ip daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl4} { ip daddr } counter drop comment \"${name} download (rate limit)\""
                done
                for set in $sets_neg_v4; do
                    rules="${rules}
        # ${name} - Download limit (IPv4 set != @${set})
        ip daddr != @${set} ip daddr @${set_name_dl4} counter drop comment \"${name} download (in set)\"
        ip daddr != @${set} ip daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl4} { ip daddr } counter drop comment \"${name} download (rate limit)\""
                done

                for grp in "pos:$ips_pos_v6" "neg:$ips_neg_v6"; do
                    local type="${grp%:*}" iplist="${grp#*:}"
                    [ -z "$iplist" ] && continue
                    local cond=""
                    build_ip_conditions_for_direction "$iplist" "daddr" cond
                    if [ -n "$cond" ]; then
                        rules="${rules}
        # ${name} - Download limit (IPv6 IP ${type}) - in set drop
        ${cond} ip6 daddr @${set_name_dl6} counter drop comment \"${name} download (in set)\"
        # ${name} - Download limit (IPv6 IP ${type}) - rate limit
        ${cond} ip6 daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl6} { ip6 daddr } counter drop comment \"${name} download (rate limit)\""
                    fi
                done
                for set in $sets_pos_v6; do
                    rules="${rules}
        # ${name} - Download limit (IPv6 set @${set})
        ip6 daddr @${set} ip6 daddr @${set_name_dl6} counter drop comment \"${name} download (in set)\"
        ip6 daddr @${set} ip6 daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl6} { ip6 daddr } counter drop comment \"${name} download (rate limit)\""
                done
                for set in $sets_neg_v6; do
                    rules="${rules}
        # ${name} - Download limit (IPv6 set != @${set})
        ip6 daddr != @${set} ip6 daddr @${set_name_dl6} counter drop comment \"${name} download (in set)\"
        ip6 daddr != @${set} ip6 daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} add @${set_name_dl6} { ip6 daddr } counter drop comment \"${name} download (rate limit)\""
                done
            fi

            if [ "$upload_limit" -gt 0 ]; then
                for grp in "pos:$ips_pos_v4" "neg:$ips_neg_v4"; do
                    local type="${grp%:*}" iplist="${grp#*:}"
                    [ -z "$iplist" ] && continue
                    local cond=""
                    build_ip_conditions_for_direction "$iplist" "saddr" cond
                    if [ -n "$cond" ]; then
                        rules="${rules}
        # ${name} - Upload limit (IPv4 IP ${type}) - in set drop
        ${cond} ip saddr @${set_name_ul4} counter drop comment \"${name} upload (in set)\"
        # ${name} - Upload limit (IPv4 IP ${type}) - rate limit
        ${cond} ip saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul4} { ip saddr } counter drop comment \"${name} upload (rate limit)\""
                    fi
                done
                for set in $sets_pos_v4; do
                    rules="${rules}
        # ${name} - Upload limit (IPv4 set @${set})
        ip saddr @${set} ip saddr @${set_name_ul4} counter drop comment \"${name} upload (in set)\"
        ip saddr @${set} ip saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul4} { ip saddr } counter drop comment \"${name} upload (rate limit)\""
                done
                for set in $sets_neg_v4; do
                    rules="${rules}
        # ${name} - Upload limit (IPv4 set != @${set})
        ip saddr != @${set} ip saddr @${set_name_ul4} counter drop comment \"${name} upload (in set)\"
        ip saddr != @${set} ip saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul4} { ip saddr } counter drop comment \"${name} upload (rate limit)\""
                done

                for grp in "pos:$ips_pos_v6" "neg:$ips_neg_v6"; do
                    local type="${grp%:*}" iplist="${grp#*:}"
                    [ -z "$iplist" ] && continue
                    local cond=""
                    build_ip_conditions_for_direction "$iplist" "saddr" cond
                    if [ -n "$cond" ]; then
                        rules="${rules}
        # ${name} - Upload limit (IPv6 IP ${type}) - in set drop
        ${cond} ip6 saddr @${set_name_ul6} counter drop comment \"${name} upload (in set)\"
        # ${name} - Upload limit (IPv6 IP ${type}) - rate limit
        ${cond} ip6 saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul6} { ip6 saddr } counter drop comment \"${name} upload (rate limit)\""
                    fi
                done
                for set in $sets_pos_v6; do
                    rules="${rules}
        # ${name} - Upload limit (IPv6 set @${set})
        ip6 saddr @${set} ip6 saddr @${set_name_ul6} counter drop comment \"${name} upload (in set)\"
        ip6 saddr @${set} ip6 saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul6} { ip6 saddr } counter drop comment \"${name} upload (rate limit)\""
                done
                for set in $sets_neg_v6; do
                    rules="${rules}
        # ${name} - Upload limit (IPv6 set != @${set})
        ip6 saddr != @${set} ip6 saddr @${set_name_ul6} counter drop comment \"${name} upload (in set)\"
        ip6 saddr != @${set} ip6 saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} add @${set_name_ul6} { ip6 saddr } counter drop comment \"${name} upload (rate limit)\""
                done
            fi
        fi
    }

    local sections=$(load_all_config_sections "$CONFIG_FILE" "ratelimit")
    for section in $sections; do process_ratelimit_section "$section"; done
    echo "$rules"
}

setup_ratelimit_chain() {
    [ "$ENABLE_RATELIMIT" != "1" ] && return 0
    local rules=$(generate_ratelimit_rules)
    if [ -n "$rules" ]; then
        local temp_ratelimit_file=$(mktemp /tmp/qos_ratelimit_XXXXXX)
        TEMP_FILES="$TEMP_FILES $temp_ratelimit_file"
        echo "add chain inet gargoyle-qos-priority $RATELIMIT_CHAIN '{ type filter hook forward priority -10; policy accept; }' 2>/dev/null || true" > "$temp_ratelimit_file"
        echo "flush chain inet gargoyle-qos-priority $RATELIMIT_CHAIN" >> "$temp_ratelimit_file"
        echo "$rules" | while IFS= read -r rule; do
            [ -z "$rule" ] && continue
            [ "${rule#\#}" != "$rule" ] && continue
            echo "add rule inet gargoyle-qos-priority $RATELIMIT_CHAIN $rule" >> "$temp_ratelimit_file"
        done
        nft -f "$temp_ratelimit_file" 2>/dev/null || { log_error "无法创建速率限制链"; return 1; }
        log_info "速率限制链已创建并填充规则"
        rm -f "$temp_ratelimit_file"
    fi
}

generate_ack_limit_rules() {
    [ "$ENABLE_ACK_LIMIT" != "1" ] && return
    local slow_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.slow_rate 2>/dev/null)
    local med_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.med_rate 2>/dev/null)
    local fast_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.fast_rate 2>/dev/null)
    local xfast_rate=$(uci -q get ${CONFIG_FILE}.ack_limit.xfast_rate 2>/dev/null)
    [ -n "$slow_rate" ] && ACK_SLOW="$slow_rate"
    [ -n "$med_rate" ] && ACK_MED="$med_rate"
    [ -n "$fast_rate" ] && ACK_FAST="$fast_rate"
    [ -n "$xfast_rate" ] && ACK_XFAST="$xfast_rate"

    cat <<EOF
# ACK rate limiting using dynamic sets
add rule inet gargoyle-qos-priority filter_qos_egress meta length < 100 tcp flags ack limit rate over ${ACK_XFAST}/second add @xfst4ack { ct id } counter jump drop995
add rule inet gargoyle-qos-priority filter_qos_egress meta length < 100 tcp flags ack limit rate over ${ACK_FAST}/second add @fast4ack { ct id } counter jump drop95
add rule inet gargoyle-qos-priority filter_qos_egress meta length < 100 tcp flags ack limit rate over ${ACK_MED}/second add @med4ack { ct id } counter jump drop50
add rule inet gargoyle-qos-priority filter_qos_egress meta length < 100 tcp flags ack limit rate over ${ACK_SLOW}/second add @slow4ack { ct id } counter jump drop50
EOF
}

generate_tcp_upgrade_rules() {
    [ "$ENABLE_TCP_UPGRADE" != "1" ] && return
    local realtime_class=""
    local class_id=$(uci -q get ${CONFIG_FILE}.idclass.class_realtime 2>/dev/null)

    if [ -n "$class_id" ]; then
        for prefix in upload_class uclass; do
            local candidate="${prefix}_${class_id}"
            if uci -q get ${CONFIG_FILE}.${candidate} >/dev/null 2>&1; then
                realtime_class="$candidate"; break
            fi
        done
        if [ -z "$realtime_class" ]; then
            for prefix in upload_class uclass; do
                local candidate="${prefix}_realtime"
                if uci -q get ${CONFIG_FILE}.${candidate} >/dev/null 2>&1; then
                    realtime_class="$candidate"; break
                fi
            done
        fi
    fi
    if [ -z "$realtime_class" ]; then
        local upload_classes=$(load_all_config_sections "$CONFIG_FILE" "upload_class")
        for cls in $upload_classes; do
            local name=$(uci -q get ${CONFIG_FILE}.${cls}.name 2>/dev/null)
            if [ "$name" = "realtime" ]; then realtime_class="$cls"; break; fi
        done
    fi
    if [ -z "$realtime_class" ]; then
        local first_upload=$(load_all_config_sections "$CONFIG_FILE" "upload_class" | head -1)
        if [ -n "$first_upload" ]; then
            realtime_class="$first_upload"
            log_warn "TCP升级：未找到 realtime 类，将使用第一个上传类 $realtime_class"
        else
            log_warn "TCP升级：未找到任何上传类，将禁用此功能"; return
        fi
    fi

    local enabled=$(uci -q get ${CONFIG_FILE}.${realtime_class}.enabled 2>/dev/null)
    if [ "$enabled" != "1" ] && [ -n "$enabled" ]; then
        log_warn "TCP升级：realtime 类 $realtime_class 未启用，跳过规则生成"
        return
    fi

    local realtime_mark=$(get_class_mark "upload" "$realtime_class" 2>/dev/null)
    if [ -z "$realtime_mark" ]; then
        log_error "TCP升级：无法获取类 $realtime_class 的标记，跳过规则生成"
        return
    fi

    cat <<EOF
# TCP upgrade for slow connections (using dynamic set)
add rule inet gargoyle-qos-priority filter_qos_egress meta l4proto tcp ct state established meta nfproto ipv4 ct id limit rate 150/second burst 150 packets add @slowtcp { ct id } meta mark set $realtime_mark counter
add rule inet gargoyle-qos-priority filter_qos_egress meta l4proto tcp ct state established meta nfproto ipv6 ct id limit rate 150/second burst 150 packets add @slowtcp { ct id } meta mark set $realtime_mark counter
EOF
}

build_nft_rule_fast() {
    local rule_name="$1" chain="$2" class_mark="$3" mask="$4" family="$5" proto="$6"
    local srcport="$7" dstport="$8" connbytes_kb="$9" state="${10}" src_ip="${11}" dest_ip="${12}"
    local packet_len="${13}" tcp_flags="${14}" iif="${15}" oif="${16}" udp_length="${17}"
    local dscp="${18}" ttl="${19}" icmp_type="${20}"
    local has_ipv4=0 has_ipv6=0 ipv4_cond="" ipv6_cond=""
    local nft_op
    local common_cond=""

    connbytes_kb=$(echo "$connbytes_kb" | tr -d ' \t\r\n')
    packet_len=$(echo "$packet_len" | tr -d ' \t\r\n')
    udp_length=$(echo "$udp_length" | tr -d ' \t\r\n')
    tcp_flags=$(echo "$tcp_flags" | tr -d ' \t\r\n')

    if [ -n "$src_ip" ]; then
        local src_neg=""
        local src_val="$src_ip"
        case "$src_val" in '!='*) src_neg="!="; src_val="${src_val#!=}"; ;; esac
        if echo "$src_val" | grep -q ':'; then
            has_ipv6=1
            ipv6_cond="$ipv6_cond ip6 saddr $src_neg $src_val"
        else
            has_ipv4=1
            ipv4_cond="$ipv4_cond ip saddr $src_neg $src_val"
        fi
    fi
    if [ -n "$dest_ip" ]; then
        local dest_neg=""
        local dest_val="$dest_ip"
        case "$dest_val" in '!='*) dest_neg="!="; dest_val="${dest_val#!=}"; ;; esac
        if echo "$dest_val" | grep -q ':'; then
            has_ipv6=1
            ipv6_cond="$ipv6_cond ip6 daddr $dest_neg $dest_val"
        else
            has_ipv4=1
            ipv4_cond="$ipv4_cond ip daddr $dest_neg $dest_val"
        fi
    fi

    local do_ipv4=0 do_ipv6=0
    case "$family" in
        ip|ipv4|inet4)
            if [ "$has_ipv4" -eq 1 ]; then
                do_ipv4=1
            else
                if [ "$has_ipv6" -eq 1 ]; then
                    log_warn "规则 $rule_name 指定 family=ipv4 但只包含 IPv6 地址，规则将被忽略"
                    return
                fi
                do_ipv4=1
            fi
            ;;
        ip6|ipv6|inet6)
            if [ "$has_ipv6" -eq 1 ]; then
                do_ipv6=1
            else
                if [ "$has_ipv4" -eq 1 ]; then
                    log_warn "规则 $rule_name 指定 family=ipv6 但只包含 IPv4 地址，规则将被忽略"
                    return
                fi
                do_ipv6=1
            fi
            ;;
        inet)
            if [ "$has_ipv4" -eq 1 ]; then do_ipv4=1; fi
            if [ "$has_ipv6" -eq 1 ]; then do_ipv6=1; fi
            if [ "$do_ipv4" -eq 0 ] && [ "$do_ipv6" -eq 0 ]; then
                do_ipv4=1
                do_ipv6=1
            fi
            ;;
        *) log_error "规则 $rule_name 无效的 family '$family'"; return ;;
    esac

    if [ "$proto" = "tcp" ]; then
        common_cond="meta l4proto tcp"
    elif [ "$proto" = "udp" ]; then
        common_cond="meta l4proto udp"
    elif [ "$proto" = "tcp_udp" ]; then
        common_cond="meta l4proto { tcp, udp }"
    elif [ -n "$proto" ] && [ "$proto" != "all" ]; then
        common_cond="meta l4proto $proto"
    fi

    if [ -n "$packet_len" ]; then
        if echo "$packet_len" | grep -q '-'; then
            local min=${packet_len%-*} max=${packet_len#*-}
            common_cond="$common_cond meta length >= $min meta length <= $max"
        elif echo "$packet_len" | grep -qE '^(<|<=|>|>=|=|!=)[0-9]+$'; then
            local operator=$(echo "$packet_len" | sed 's/[0-9]*$//')
            local num=$(echo "$packet_len" | grep -o '[0-9]\+')
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
        elif echo "$packet_len" | grep -qE '^[0-9]+$'; then
            common_cond="$common_cond meta length eq $packet_len"
        else
            log_warn "规则 $rule_name 包长度 '$packet_len' 格式无效，已忽略"
        fi
    fi

    # 修复 tcp_flags 输出，保留逗号
    if [ -n "$tcp_flags" ] && [ "$proto" = "tcp" ]; then
        local clean_flags=""
        local old_ifs="$IFS"
        IFS=','
        for flag in $tcp_flags; do
            flag=$(echo "$flag" | tr -d '[:space:]')
            case "$flag" in
                syn|ack|rst|fin|urg|psh|ecn|cwr)
                    [ -z "$clean_flags" ] && clean_flags="$flag" || clean_flags="$clean_flags,$flag"
                    ;;
                *)
                    log_warn "规则 $rule_name TCP标志 '$flag' 无效，已忽略"
                    ;;
            esac
        done
        IFS="$old_ifs"
        if [ -n "$clean_flags" ]; then
            # 使用逗号分隔，保留在花括号内
            common_cond="$common_cond tcp flags { $clean_flags }"
        fi
    fi

    if [ -n "$iif" ]; then
        common_cond="$common_cond iifname \"$iif\""
    fi
    if [ -n "$oif" ]; then
        common_cond="$common_cond oifname \"$oif\""
    fi

    if [ -n "$udp_length" ] && [ "$proto" = "udp" ]; then
        if echo "$udp_length" | grep -q '-'; then
            local min=${udp_length%-*} max=${udp_length#*-}
            common_cond="$common_cond udp length >= $min udp length <= $max"
        elif echo "$udp_length" | grep -qE '^(<|<=|>|>=|=|!=)[0-9]+$'; then
            local operator=$(echo "$udp_length" | sed 's/[0-9]*$//')
            local num=$(echo "$udp_length" | grep -o '[0-9]\+')
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
        elif echo "$udp_length" | grep -qE '^[0-9]+$'; then
            common_cond="$common_cond udp length eq $udp_length"
        else
            log_warn "规则 $rule_name UDP长度 '$udp_length' 格式无效，已忽略"
        fi
    fi

    if [ "$proto" = "tcp" ] || [ "$proto" = "udp" ] || [ "$proto" = "tcp_udp" ]; then
        case "$chain" in
            *"ingress"*)
                if [ -n "$srcport" ]; then
                    common_cond="$common_cond th sport { $(echo "$srcport" | tr -d ' ') }"
                fi
                ;;
            *)
                if [ -n "$dstport" ]; then
                    common_cond="$common_cond th dport { $(echo "$dstport" | tr -d ' ') }"
                fi
                ;;
        esac
    fi

    if [ -n "$state" ]; then
        local state_value=$(echo "$state" | tr -d '{}')
        if echo "$state_value" | grep -q ','; then
            common_cond="$common_cond ct state { $state_value }"
        else
            common_cond="$common_cond ct state $state_value"
        fi
    fi

    if [ -n "$connbytes_kb" ]; then
        if echo "$connbytes_kb" | grep -q '-'; then
            local min_val=${connbytes_kb%-*} max_val=${connbytes_kb#*-}
            local min_bytes=$((min_val * 1024)) max_bytes=$((max_val * 1024))
            common_cond="$common_cond ct bytes >= $min_bytes ct bytes <= $max_bytes"
        elif echo "$connbytes_kb" | grep -qE '^(<|<=|>|>=|=|!=)[0-9]+$'; then
            local operator=$(echo "$connbytes_kb" | sed 's/[0-9]*$//')
            local num=$(echo "$connbytes_kb" | grep -o '[0-9]\+')
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
        elif echo "$connbytes_kb" | grep -qE '^[0-9]+$'; then
            local bytes_value=$((connbytes_kb * 1024))
            common_cond="$common_cond ct bytes eq $bytes_value"
        else
            log_warn "规则 $rule_name 连接字节数 '$connbytes_kb' 格式无效，已忽略"
        fi
    fi

    local base_cmd="add rule inet gargoyle-qos-priority $chain meta mark == 0"

    if [ "$do_ipv4" -eq 1 ]; then
        local cmd="$base_cmd meta nfproto ipv4 $common_cond"
        [ -n "$ipv4_cond" ] && cmd="$cmd $ipv4_cond"

        if [ -n "$dscp" ]; then
            local dscp_val="$dscp"
            local neg=""
            case "$dscp_val" in '!='*) neg="!="; dscp_val="${dscp_val#!=}"; ;; esac
            cmd="$cmd ip dscp $neg $dscp_val"
        fi

        if [ -n "$ttl" ]; then
            local ttl_val="$ttl"
            if echo "$ttl_val" | grep -qE '^(<|<=|>|>=|=|!=)[0-9]+$'; then
                local operator=$(echo "$ttl_val" | sed 's/[0-9]*$//')
                local num=$(echo "$ttl_val" | grep -o '[0-9]\+')
                case "$operator" in
                    ">") nft_op="gt" ;;
                    ">=") nft_op="ge" ;;
                    "<") nft_op="lt" ;;
                    "<=") nft_op="le" ;;
                    "!=") nft_op="ne" ;;
                    "=")  nft_op="eq" ;;
                    *)   nft_op="$operator" ;;
                esac
                cmd="$cmd ip ttl $nft_op $num"
            else
                cmd="$cmd ip ttl eq $ttl_val"
            fi
        fi

        if [ -n "$icmp_type" ] && [ "$proto" = "icmp" ]; then
            local icmp_val="$icmp_type"
            local neg=""
            case "$icmp_val" in '!='*) neg="!="; icmp_val="${icmp_val#!=}"; ;; esac
            if echo "$icmp_val" | grep -q '/'; then
                local type=${icmp_val%/*} code=${icmp_val#*/}
                cmd="$cmd icmp type $neg $type icmp code $code"
            else
                cmd="$cmd icmp type $neg $icmp_val"
            fi
        fi

        cmd="$cmd meta mark set $class_mark counter"
        echo "$cmd"
    fi

    if [ "$do_ipv6" -eq 1 ]; then
        local cmd="$base_cmd meta nfproto ipv6 $common_cond"
        [ -n "$ipv6_cond" ] && cmd="$cmd $ipv6_cond"

        if [ -n "$dscp" ]; then
            local dscp_val="$dscp"
            local neg=""
            case "$dscp_val" in '!='*) neg="!="; dscp_val="${dscp_val#!=}"; ;; esac
            cmd="$cmd ip6 dscp $neg $dscp_val"
        fi

        if [ -n "$ttl" ]; then
            local hop_val="$ttl"
            if echo "$hop_val" | grep -qE '^(<|<=|>|>=|=|!=)[0-9]+$'; then
                local operator=$(echo "$hop_val" | sed 's/[0-9]*$//')
                local num=$(echo "$hop_val" | grep -o '[0-9]\+')
                case "$operator" in
                    ">") nft_op="gt" ;;
                    ">=") nft_op="ge" ;;
                    "<") nft_op="lt" ;;
                    "<=") nft_op="le" ;;
                    "!=") nft_op="ne" ;;
                    "=")  nft_op="eq" ;;
                    *)   nft_op="$operator" ;;
                esac
                cmd="$cmd ip6 hoplimit $nft_op $num"
            else
                cmd="$cmd ip6 hoplimit eq $hop_val"
            fi
        fi

        if [ -n "$icmp_type" ] && [ "$proto" = "icmpv6" ]; then
            local icmp_val="$icmp_type"
            local neg=""
            case "$icmp_val" in '!='*) neg="!="; icmp_val="${icmp_val#!=}"; ;; esac
            if echo "$icmp_val" | grep -q '/'; then
                local type=${icmp_val%/*} code=${icmp_val#*/}
                cmd="$cmd icmpv6 type $neg $type icmpv6 code $code"
            else
                cmd="$cmd icmpv6 type $neg $icmp_val"
            fi
        fi

        cmd="$cmd meta mark set $class_mark counter"
        echo "$cmd"
    fi
}

apply_enhanced_direction_rules() {
    local rule_type="$1" chain="$2" mask="$3"
    log_info "应用增强$rule_type规则到链: $chain, 掩码: $mask"

    nft add chain inet gargoyle-qos-priority "$chain" 2>/dev/null || true

    local direction=""
    [ "$chain" = "filter_qos_egress" ] && direction="upload"
    [ "$chain" = "filter_qos_ingress" ] && direction="download"

    local rule_list=$(load_all_config_sections "$CONFIG_FILE" "$rule_type")
    [ -z "$rule_list" ] && { log_info "未找到$rule_type规则配置"; return 0; }
    log_info "找到$rule_type规则: $rule_list"

    local temp_config=$(mktemp /tmp/qos_rule_config_XXXXXX 2>/dev/null)
    [ -z "$temp_config" ] && { log_error "无法创建配置临时文件"; return 1; }
    TEMP_FILES="$TEMP_FILES $temp_config"

    local old_ifs="$IFS"
    IFS=' '
    set -- $rule_list
    IFS="$old_ifs"
    for rule; do
        [ -n "$rule" ] || continue
        if load_all_config_options "$CONFIG_FILE" "$rule" "tmp_"; then
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                "$rule" "$tmp_class" "$tmp_order" "$tmp_enabled" "$tmp_proto" "$tmp_srcport" "$tmp_dstport" \
                "$tmp_connbytes_kb" "$tmp_family" "$tmp_state" "$tmp_src_ip" "$tmp_dest_ip" >> "$temp_config"
        fi
    done

    local sorted_rule_list=$(sort_rules_by_priority_fast "$temp_config")
    if [ -z "$sorted_rule_list" ]; then
        log_info "没有可用的启用规则"
        rm -f "$temp_config" 2>/dev/null
        return 0
    fi

    local nft_batch_file=$(mktemp /tmp/qos_nft_batch_XXXXXX 2>/dev/null)
    [ -z "$nft_batch_file" ] && { log_error "无法创建nft批处理文件"; rm -f "$temp_config"; return 1; }
    TEMP_FILES="$TEMP_FILES $nft_batch_file"

    log_info "按优先级顺序生成nft规则..."
    local rule_count=0
    for rule_name in $sorted_rule_list; do
        if ! load_all_config_options "$CONFIG_FILE" "$rule_name" "tmp_"; then
            continue
        fi
        [ "$tmp_enabled" = "1" ] || continue

        local class_mark=$(get_class_mark "$direction" "$tmp_class")
        [ -z "$class_mark" ] && { log_error "规则 $rule_name 的类 $tmp_class 无法获取标记，跳过"; continue; }
        [ -z "$tmp_family" ] && tmp_family="inet"

        local clean_srcport=$(echo "$tmp_srcport" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')
        local clean_dstport=$(echo "$tmp_dstport" | tr -d '[:space:]' | sed 's/[^0-9,-]//g')

        build_nft_rule_fast "$rule_name" "$chain" "$class_mark" "$mask" "$tmp_family" "$tmp_proto" \
            "$clean_srcport" "$clean_dstport" "$tmp_connbytes_kb" "$tmp_state" "$tmp_src_ip" "$tmp_dest_ip" \
            "$tmp_packet_len" "$tmp_tcp_flags" "$tmp_iif" "$tmp_oif" "$tmp_udp_length" \
            "$tmp_dscp" "$tmp_ttl" "$tmp_icmp_type" >> "$nft_batch_file"
        rule_count=$((rule_count + 1))
    done

    local custom_file=""
    [ "$chain" = "filter_qos_egress" ] && custom_file="$CUSTOM_EGRESS_FILE" || custom_file="$CUSTOM_INGRESS_FILE"
    if [ -s "$custom_file" ]; then
        log_info "验证自定义规则: $custom_file"
        local check_file="/tmp/qos_custom_check_$$.nft"
        {
            printf '%s\n\t%s\n' "table inet __qos_custom_check {" "chain __temp_chain {"
            cat "$custom_file"
            printf '\n\t%s\n%s\n' "}" "}"
        } > "$check_file"
        if nft --check --file "$check_file" 2>/dev/null; then
            log_info "自定义规则语法正确: $custom_file"
            while IFS= read -r line || [ -n "$line" ]; do
                [ -z "$line" ] && continue
                case "$line" in
                    \#*) continue ;;
                esac
                echo "add rule inet gargoyle-qos-priority $chain $line" >> "$nft_batch_file"
                rule_count=$((rule_count + 1))
            done < "$custom_file"
        else
            log_warn "自定义规则文件 $custom_file 语法错误，已忽略"
            nft --check --file "$check_file" 2>&1 | while IFS= read -r err; do
                log_error "nft语法错误: $err"
            done
        fi
        rm -f "$check_file"
    fi

    if [ "$chain" = "filter_qos_egress" ]; then
        generate_ack_limit_rules >> "$nft_batch_file"
        generate_tcp_upgrade_rules >> "$nft_batch_file"
    fi

    local batch_success=0
    if [ -s "$nft_batch_file" ]; then
        log_info "执行批量nft规则 (共 $rule_count 条)..."
        nft_output=$(nft -f "$nft_batch_file" 2>&1)
        nft_ret=$?
        if [ $nft_ret -eq 0 ]; then
            log_info "✅ 批量规则应用成功"
            if [ "$SAVE_NFT_RULES" = "1" ]; then
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

    rm -f "$nft_batch_file" "$temp_config"
    return $batch_success
}

apply_all_rules() {
    local rule_type="$1" mask="$2" chain="$3"
    log_info "开始应用 $rule_type 规则到链 $chain (掩码: $mask)"

    if [ "$_QOS_TABLE_FLUSHED" -eq 0 ]; then
        log_info "初始化 nftables 表"
        nft add table inet gargoyle-qos-priority 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority filter_qos_egress 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority filter_qos_ingress 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop995 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop95 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority drop50 2>/dev/null || true
        nft flush chain inet gargoyle-qos-priority $RATELIMIT_CHAIN 2>/dev/null || true
        generate_ipset_sets

        local nft_version=$(nft --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        local set_key="ct id . ct direction"
        if [ -n "$nft_version" ] && echo "$nft_version" | awk -F. '{ if ($1<0 || ($1==0 && $2<9)) exit 0; else exit 1 }'; then
            log_warn "检测到 nftables 版本低于 0.9.0，动态集合将使用简单键 'ct id'（可能影响限速精度）"
            set_key="ct id"
        fi

        local sets_ok=1
        if [ "$set_key" = "ct id" ]; then
            nft add set inet gargoyle-qos-priority xfst4ack '{ type ct id; flags dynamic; timeout 5m; }' 2>/dev/null || sets_ok=0
            nft add set inet gargoyle-qos-priority fast4ack '{ type ct id; flags dynamic; timeout 5m; }' 2>/dev/null || sets_ok=0
            nft add set inet gargoyle-qos-priority med4ack '{ type ct id; flags dynamic; timeout 5m; }' 2>/dev/null || sets_ok=0
            nft add set inet gargoyle-qos-priority slow4ack '{ type ct id; flags dynamic; timeout 5m; }' 2>/dev/null || sets_ok=0
            nft add set inet gargoyle-qos-priority slowtcp '{ type ct id; flags dynamic; timeout 5m; }' 2>/dev/null || sets_ok=0
        else
            nft add set inet gargoyle-qos-priority xfst4ack '{ typeof ct id . ct direction; flags dynamic; timeout 5m; }' 2>/dev/null || sets_ok=0
            nft add set inet gargoyle-qos-priority fast4ack '{ typeof ct id . ct direction; flags dynamic; timeout 5m; }' 2>/dev/null || sets_ok=0
            nft add set inet gargoyle-qos-priority med4ack '{ typeof ct id . ct direction; flags dynamic; timeout 5m; }' 2>/dev/null || sets_ok=0
            nft add set inet gargoyle-qos-priority slow4ack '{ typeof ct id . ct direction; flags dynamic; timeout 5m; }' 2>/dev/null || sets_ok=0
            nft add set inet gargoyle-qos-priority slowtcp '{ typeof ct id . ct direction; flags dynamic; timeout 5m; }' 2>/dev/null || sets_ok=0
        fi

        if [ $sets_ok -eq 0 ]; then
            log_error "动态集合创建失败，ACK 限速和 TCP 升级功能将被禁用"
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

    apply_enhanced_direction_rules "$rule_type" "$chain" "$mask"
    return $?
}

# ========== 锁机制 (使用 mkdir 原子操作 + 嵌套计数) ==========
LOCK_DIR="/var/run/qos_gargoyle.lockdir"
LOCK_DEPTH=0

acquire_lock() {
    if [ "$LOCK_DEPTH" -gt 0 ]; then
        LOCK_DEPTH=$((LOCK_DEPTH + 1))
        log_debug "锁深度增加，当前深度: $LOCK_DEPTH"
        return 0
    fi

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        LOCK_DEPTH=1
        log_debug "成功获取锁 (mkdir)"
        return 0
    fi

    if [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid")" = "$$" ]; then
        log_warn "锁目录已由当前进程持有，可能是未释放残留，视为已获取"
        LOCK_DEPTH=1
        return 0
    fi

    log_warn "等待锁释放..."
    local wait=0
    while [ $wait -lt 5 ]; do
        sleep 1
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo $$ > "$LOCK_DIR/pid"
            LOCK_DEPTH=1
            log_debug "成功获取锁 (mkdir)"
            return 0
        fi
        wait=$((wait + 1))
    done
    log_error "获取锁超时（5秒）"
    return 1
}

release_lock() {
    if [ "$LOCK_DEPTH" -eq 0 ]; then
        log_debug "未持有锁，无需释放"
        return
    fi

    LOCK_DEPTH=$((LOCK_DEPTH - 1))
    if [ "$LOCK_DEPTH" -gt 0 ]; then
        log_debug "锁深度减少，当前深度: $LOCK_DEPTH"
        return
    fi

    if [ -d "$LOCK_DIR" ] && [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid")" = "$$" ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null
        log_debug "锁已释放"
    else
        log_debug "锁目录异常，跳过删除"
    fi
}

# ========== 健康检查 ==========
health_check() {
    local errors=0 status=""
    uci -q show ${CONFIG_FILE} >/dev/null 2>&1 && status="${status}config:ok;" || { status="${status}config:missing;"; errors=$((errors+1)); }
    nft list table inet gargoyle-qos-priority >/dev/null 2>&1 && status="${status}nft:ok;" || { status="${status}nft:missing;"; errors=$((errors+1)); }
    local wan_if=$(uci -q get ${CONFIG_FILE}.global.wan_interface 2>/dev/null)
    if [ -n "$wan_if" ] && tc qdisc show dev "$wan_if" 2>/dev/null | grep -qE "htb|hfsc|cake"; then
        status="${status}tc:ok;"
    else
        status="${status}tc:missing;"; errors=$((errors+1))
    fi
    for mod in ifb sch_htb sch_hfsc sch_cake sch_fq_codel; do
        if ! lsmod 2>/dev/null | grep -q "^$mod"; then
            modprobe "$mod" 2>/dev/null || true
            if ! lsmod 2>/dev/null | grep -q "^$mod"; then
                status="${status}module_${mod}:missing;"
                errors=$((errors+1))
            fi
        fi
    done
    [ -f "$CLASS_MARKS_FILE" ] && status="${status}marks:ok;" || { status="${status}marks:missing;"; errors=$((errors+1)); }
    echo "status=$status;errors=$errors"
    return $((errors == 0 ? 0 : 1))
}

# ========== 内存限制计算 ==========
calculate_memory_limit() {
    local config_value="$1" result
    [ -z "$config_value" ] && { echo ""; return; }
    if [ "$config_value" = "auto" ]; then
        local total_mem_mb=0
        if [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
            local total_mem_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
            if [ -n "$total_mem_bytes" ] && [ "$total_mem_bytes" -gt 0 ] 2>/dev/null; then
                total_mem_mb=$(( total_mem_bytes / 1024 / 1024 ))
                log_info "从cgroups获取内存限制: ${total_mem_mb}MB"
            fi
        fi
        if [ -z "$total_mem_mb" ] || [ "$total_mem_mb" -eq 0 ]; then
            local total_mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
            if [ -n "$total_mem_kb" ] && [ "$total_mem_kb" -gt 0 ] 2>/dev/null; then
                total_mem_mb=$(( total_mem_kb / 1024 ))
                log_info "从/proc/meminfo获取内存: ${total_mem_mb}MB"
            fi
        fi
        if [ -n "$total_mem_mb" ] && [ "$total_mem_mb" -gt 0 ] 2>/dev/null; then
            result="$(((total_mem_mb + 63) / 64))Mb"
            local min_limit=8 max_limit=32
            local result_value=$(echo "$result" | sed 's/Mb//')
            if [ "$result_value" -lt "$min_limit" ] 2>/dev/null; then result="${min_limit}Mb"
            elif [ "$result_value" -gt "$max_limit" ] 2>/dev/null; then result="${max_limit}Mb"; fi
            log_info "系统内存 ${total_mem_mb}MB，自动计算 memlimit=${result}"
        else
            log_warn "无法读取内存信息，使用默认值 16Mb"; result="16Mb"
        fi
    else
        if echo "$config_value" | grep -qE '^[0-9]+Mb$'; then
            result="$config_value"; log_info "使用用户配置的 memlimit: ${result}"
        else
            log_warn "无效的 memlimit 格式 '$config_value'，使用默认值 16Mb"; result="16Mb"
        fi
    fi
    echo "$result"
}

# ========== 带宽单位转换 ==========
convert_bandwidth_to_kbit() {
    local bw="$1" num unit multiplier result
    [ -z "$bw" ] && { log_error "带宽值为空"; return 1; }
    if echo "$bw" | grep -qE '^[0-9]+$'; then echo "$bw"; return 0; fi
    if echo "$bw" | grep -qiE '^[0-9]+(\.[0-9]+)?[a-zA-Z]+$'; then
        num=$(echo "$bw" | grep -oE '^[0-9]+(\.[0-9]+)?')
        unit=$(echo "$bw" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')
        case "$unit" in
            K|KBIT|KILOBIT) multiplier=1 ;;
            M|MBIT|MEGABIT) multiplier=1000 ;;
            G|GBIT|GIGABIT) multiplier=1000000 ;;
            KB|KIB) log_warn "检测到二进制字节单位 '$unit'，将自动乘以 8 转换为 kbit"; multiplier=8 ;;
            MB|MIB) log_warn "检测到二进制字节单位 '$unit'，将自动乘以 8 转换为 kbit"; multiplier=8000 ;;
            GB|GIB) log_warn "检测到二进制字节单位 '$unit'，将自动乘以 8 转换为 kbit"; multiplier=8000000 ;;
            *) log_error "未知带宽单位: $unit"; return 1 ;;
        esac
        if command -v bc >/dev/null 2>&1; then
            result=$(echo "$num * $multiplier" | bc | awk '{printf "%.0f", $1}')
        else
            result=$(awk "BEGIN {printf \"%.0f\", $num * $multiplier}")
        fi
        if [ -z "$result" ] || ! echo "$result" | grep -qE '^[0-9]+$' || [ "$result" -lt 0 ] 2>/dev/null; then
            log_error "带宽转换结果无效: $result"; return 1
        fi
        echo "$result"; return 0
    else
        log_error "无效带宽格式: $bw (应为数字或数字+单位，例如 100mbit、10MB)"; return 1
    fi
}

# ========== 检查 tc connmark 支持 ==========
check_tc_connmark_support() {
    modprobe sch_ingress 2>/dev/null
    modprobe act_connmark 2>/dev/null

    local dummy_dev="dummy0"
    ip link add "$dummy_dev" type dummy 2>/dev/null || {
        dummy_dev="lo"
    }
    tc qdisc del dev "$dummy_dev" ingress 2>/dev/null
    if ! tc qdisc add dev "$dummy_dev" ingress 2>/dev/null; then
        [ "$dummy_dev" != "lo" ] && ip link del "$dummy_dev" 2>/dev/null
        log_warn "无法在 $dummy_dev 上创建 ingress 队列，无法测试 connmark 支持"
        return 1
    fi
    local ret=1
    if tc filter add dev "$dummy_dev" parent ffff: protocol ip u32 match u32 0 0 action connmark 2>/dev/null; then
        ret=0
        tc filter del dev "$dummy_dev" parent ffff: 2>/dev/null
    fi
    tc qdisc del dev "$dummy_dev" ingress 2>/dev/null
    [ "$dummy_dev" != "lo" ] && ip link del "$dummy_dev" 2>/dev/null
    return $ret
}

# ========== 检查必需的命令（ethtool 改为可选） ==========
check_required_commands() {
    local missing=0
    for cmd in tc nft ip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "命令 '$cmd' 未找到，请安装相应软件包"
            missing=1
        fi
    done
    # ethtool 不是必须的，仅用于获取物理带宽
    if ! command -v ethtool >/dev/null 2>&1; then
        log_info "ethtool 未安装，将尝试从 sysfs 获取接口速度"
    fi
    return $missing
}

# ========== 加载必需的内核模块（act_connmark 可选） ==========
load_required_modules() {
    local missing=0
    for mod in ifb sch_htb sch_hfsc sch_cake sch_fq_codel sch_ingress; do
        if ! lsmod 2>/dev/null | grep -q "^$mod"; then
            log_info "尝试加载内核模块: $mod"
            modprobe "$mod" 2>/dev/null || { log_error "无法加载内核模块 $mod"; missing=1; }
        fi
    done
    # act_connmark 是可选的，不影响基本功能
    if ! lsmod 2>/dev/null | grep -q "^act_connmark"; then
        modprobe act_connmark 2>/dev/null || log_info "act_connmark 模块未加载，入口 connmark 功能可能受限"
    fi
    return $missing
}

# ========== 检查IFB设备，若不存在则创建 ==========
ensure_ifb_device() {
    local dev="$1"
    if ! ip link show "$dev" >/dev/null 2>&1; then
        log_info "IFB设备 $dev 不存在，尝试创建..."
        ip link add "$dev" type ifb 2>/dev/null || { log_error "无法创建IFB设备 $dev"; return 1; }
    fi
    ip link set dev "$dev" up || { log_error "无法启动IFB设备 $dev"; return 1; }
    log_info "IFB设备 $dev 已就绪"
    return 0
}

# ========== 获取物理接口最大带宽 ==========
get_physical_interface_max_bandwidth() {
    local interface="$1" max_bandwidth=""
    if command -v ethtool >/dev/null 2>&1; then
        local speed=$(ethtool "$interface" 2>/dev/null | grep -i speed | awk '{print $2}' | sed 's/[^0-9]//g')
        if [ -n "$speed" ] && [ "$speed" -gt 0 ] 2>/dev/null; then
            max_bandwidth=$((speed * 1000))
            log_info "接口 $interface 物理速度: ${speed}Mbps (${max_bandwidth}kbit)"
        fi
    fi
    if [ -z "$max_bandwidth" ] && [ -d "/sys/class/net/$interface" ]; then
        local speed_file="/sys/class/net/$interface/speed"
        if [ -f "$speed_file" ]; then
            local speed=$(cat "$speed_file" 2>/dev/null)
            if [ -n "$speed" ] && [ "$speed" -gt 0 ] 2>/dev/null; then
                max_bandwidth=$((speed * 1000))
                log_info "接口 $interface 物理速度: ${speed}Mbps (${max_bandwidth}kbit)"
            fi
        fi
    fi
    if [ -z "$max_bandwidth" ]; then
        max_bandwidth="$MAX_PHYSICAL_BANDWIDTH"
        log_warn "无法获取接口 $interface 的物理速度，使用默认最大值 ${max_bandwidth}kbit"
    fi
    echo "$max_bandwidth"
}

# ========== 加载带宽配置 ==========
load_bandwidth_from_config() {
    log_info "加载带宽配置"
    local wan_if="$qos_interface"
    if [ -z "$wan_if" ]; then
        if [ -f "/lib/functions/network.sh" ]; then
            . /lib/functions/network.sh
            network_find_wan wan_if
        fi
        if [ -z "$wan_if" ]; then
            log_error "无法确定 WAN 接口，请设置 qos_interface 变量或配置 global.wan_interface"
            return 1
        fi
        log_info "自动检测 WAN 接口: $wan_if"
    fi
    local max_physical_bw=$(get_physical_interface_max_bandwidth "$wan_if")

    local config_upload_bw=$(uci -q get qos_gargoyle.upload.total_bandwidth 2>/dev/null)
    if [ -z "$config_upload_bw" ]; then
        log_info "上传总带宽未配置，将禁用上传QoS"
        total_upload_bandwidth=0
    else
        total_upload_bandwidth=$(convert_bandwidth_to_kbit "$config_upload_bw") || {
            log_warn "上传带宽转换失败，将禁用上传QoS"
            total_upload_bandwidth=0
        }
        if [ "$total_upload_bandwidth" -eq 0 ]; then
            log_info "上传总带宽为0，将禁用上传QoS"
        elif ! validate_number "$total_upload_bandwidth" "upload.total_bandwidth" 1 "$max_physical_bw"; then
            log_warn "上传总带宽无效，将禁用上传QoS"
            total_upload_bandwidth=0
        else
            log_info "上传总带宽: ${total_upload_bandwidth}kbit/s"
        fi
    fi

    local config_download_bw=$(uci -q get qos_gargoyle.download.total_bandwidth 2>/dev/null)
    if [ -z "$config_download_bw" ]; then
        log_info "下载总带宽未配置，将禁用下载QoS"
        total_download_bandwidth=0
    else
        total_download_bandwidth=$(convert_bandwidth_to_kbit "$config_download_bw") || {
            log_warn "下载带宽转换失败，将禁用下载QoS"
            total_download_bandwidth=0
        }
        if [ "$total_download_bandwidth" -eq 0 ]; then
            log_info "下载总带宽为0，将禁用下载QoS"
        elif ! validate_number "$total_download_bandwidth" "download.total_bandwidth" 1 "$max_physical_bw"; then
            log_warn "下载总带宽无效，将禁用下载QoS"
            total_download_bandwidth=0
        else
            log_info "下载总带宽: ${total_download_bandwidth}kbit/s"
        fi
    fi

    return 0
}

# ========== 规则集合并 ==========
init_ruleset() {
    local nofix="$1"
    if [ "$nofix" = "1" ]; then
        [ -f "$RULESET_MERGED_FLAG" ] && return 0
        return 0
    fi
    [ -f "$RULESET_MERGED_FLAG" ] && return 0

    local ruleset ruleset_file
    ruleset=$(uci -q get ${CONFIG_FILE}.global.ruleset 2>/dev/null)
    [ -z "$ruleset" ] && ruleset="default.conf"
    case "$ruleset" in *.conf) ;; *) ruleset="${ruleset}.conf" ;; esac
    ruleset_file="$RULESET_DIR/$ruleset"
    if [ ! -f "$ruleset_file" ]; then
        log_error "规则集文件 $ruleset_file 不存在，无法加载任何规则！"
        return 1
    fi

    cp "/etc/config/${CONFIG_FILE}" "/etc/config/${CONFIG_FILE}.bak"
    log_info "已备份主配置文件到 ${CONFIG_FILE}.bak"

    if grep -q "^# === RULESET_" "/etc/config/${CONFIG_FILE}"; then
        sed -i '/^# === RULESET_/,/^# === RULESET_END ===/d' "/etc/config/${CONFIG_FILE}"
        log_info "已清理旧的规则集内容"
    fi

    {
        echo ""
        echo "# === RULESET_${ruleset} ==="
        cat "$ruleset_file"
        echo "# === RULESET_END ==="
    } >> "/etc/config/${CONFIG_FILE}"

    uci commit ${CONFIG_FILE}
    touch "$RULESET_MERGED_FLAG"
    log_info "已将规则集 $ruleset 合并到主配置文件"
    return 0
}

restore_main_config() {
    if [ -f "/etc/config/${CONFIG_FILE}.bak" ]; then
        mv "/etc/config/${CONFIG_FILE}.bak" "/etc/config/${CONFIG_FILE}"
        uci commit ${CONFIG_FILE}
        log_info "已恢复主配置文件备份"
    fi
    rm -f "$RULESET_MERGED_FLAG"
    log_info "已清理规则集标记"
}

# ========== IPv6增强支持 ==========
setup_ipv6_specific_rules() {
    log_info "设置IPv6特定规则（优化版）"
    nft add chain inet gargoyle-qos-priority filter_prerouting '{ type filter hook prerouting priority 0; policy accept; }' 2>/dev/null || true
    nft flush chain inet gargoyle-qos-priority filter_prerouting 2>/dev/null || true
    local ICMPV6_CRITICAL_TYPES="133,134,135,136,137"

    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 daddr { ff02::1:2, ff02::1:3 } meta mark set 0x10000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 ip6 daddr ::1 meta mark set 0x10000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 icmpv6 type { $ICMPV6_CRITICAL_TYPES } meta mark set 0x20000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport { 546, 547 } meta mark set 0x20000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport 53 meta mark set 0x20000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 tcp dport 53 meta mark set 0x20000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 tcp dport { 80, 443 } meta mark set 0x20000000 counter 2>/dev/null || true
    nft add rule inet gargoyle-qos-priority filter_prerouting \
        meta nfproto ipv6 udp dport 123 meta mark set 0x20000000 counter 2>/dev/null || true
    log_info "IPv6关键流量规则设置完成"
}

# ========== 自动加载全局配置 ==========
if [ -z "$_QOS_RULE_SH_LOADED" ] && [ "$(basename "$0")" != "rule.sh" ]; then
    load_global_config
    _QOS_RULE_SH_LOADED=1
fi