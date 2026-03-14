-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.
-- Modified 2026 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>

local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()
local net = require "luci.model.network".init()
local qos = require "luci.model.qos_gargoyle"
local http = require "luci.http"
local json = require "luci.jsonc"

local m, s, o
local upload_classes = {}
local download_classes = {}
local qos_gargoyle = "qos_gargoyle"

local function qos_enabled()
    local enabled = uci:get(qos_gargoyle, "global", "enabled")
    return enabled == "1"
end

uci:foreach(qos_gargoyle, "upload_class", function(s)
    local class_alias = s.name
    if class_alias then
        upload_classes[#upload_classes + 1] = {name = s[".name"], alias = class_alias}
    end
end)

uci:foreach(qos_gargoyle, "download_class", function(s)
    local class_alias = s.name
    if class_alias then
        download_classes[#download_classes + 1] = {name = s[".name"], alias = class_alias}
    end
end)

m = Map(qos_gargoyle, translate("Gargoyle QoS"),
    translate("Quality of Service (QoS) provides a way to control how available bandwidth is allocated."))

s = m:section(NamedSection, "global", "global", translate("Global Settings"))
s.anonymous = true

-- QoS 启用/禁用开关 (使用Flag替代Button)
o = s:option(Flag, "enabled", translate("Enable QoS"), translate("Enable or disable the QoS service"))
o.default = "0"
o.rmempty = false
o.enabled = "1"
o.disabled = "0"

-- 网络接口设置
o = s:option(Value, "wan_interface", translate("Network Interface"), translate("Select the network interface"))
local interfaces = sys.exec("ls -l /sys/class/net/ | grep virtual 2>/dev/null |awk '{print $9}' 2>/dev/null")
for interface in string.gmatch(interfaces, "%S+") do
   o:value(interface)
end
local wan = qos.get_wan()
if wan then o.default = wan:ifname() end
o.rmempty = false

-- QoS算法选择
o = s:option(ListValue, "algorithm", translate("QoS Algorithm"), 
    translate("HFSC+fq_codel: Guarantees low latency, ideal for gaming/voip.HTB+fq_codel: Flexible bandwidth control, good for multi-service management.CAKE: Modern and plug-and-play, simple to use."))
o:value("hfsc_cake", "HFSC_CAKE (Hfsc With Cake)")
o:value("htb_cake", "HTB_CAKE (Htb With Cake)")
o:value("cake", "CAKE (Common Applications Kept Enhanced)")
o:value("hfsc_fqcodel", "HFSC_Fqcodel (Hfsc With Fq_Codel)")
o:value("htb_fqcodel", "HTB_Fqcodel (Htb With Fq_Codel)")
o.default = "hfsc_cake"

-- 链路类型
o = s:option(ListValue, "linklayer", translate("Linklayer Type"), translate("Select linkelayer type"))
o:value("ethernet", translate("Ethernet"))
o:value("atm", "ATM")
o:value("adsl", "ADSL")
o.default = "atm"

-- 链路开销
o = s:option(Value, "overhead", translate("Linklayer Overhead"), translate("Set linklayer overhead"))
o.datatype = "uinteger"
o.default="32"

s = m:section(NamedSection, "upload", "upload", translate("Upload Settings"))
s.anonymous = true

o = s:option(ListValue, "default_class", translate("Default Service Class"),
    translate("Specifie how packets that do not match any rule should be classified."))
for _, s in ipairs(upload_classes) do o:value(s.name, s.alias) end

o = s:option(Value, "total_bandwidth", translate("Total Upload Bandwidth"),
    translate("Should be set to around 98% of your available upload bandwidth. Entering a number "
    .. "which is too high will result in QoS not meeting its class requirements. Entering a number "
    .. "which is too low will needlessly penalize your upload speed. You should use a speed test "
    .. "program (with QoS off) to determine available upload bandwidth. Note that bandwidth is "
    .. "specified in kbps, leave blank to disable update QoS. There are 8 kilobits per kilobyte."))
o.datatype = "uinteger"

s = m:section(NamedSection, "download", "download", translate("Download Settings"))
s.anonymous = true

o = s:option(ListValue, "default_class", translate("Default Service Class"),
    translate("Specifie how packets that do not match any rule should be classified."))
for _, s in ipairs(download_classes) do o:value(s.name, s.alias) end

o = s:option(Value, "total_bandwidth", translate("Total Download Bandwidth"),
    translate("Specifying correctly is crucial to making QoS work. Note that bandwidth is specified "
    .. "in kbps, leave blank to disable download QoS. There are 8 kilobits per kilobyte."))
o.datatype = "uinteger"

-- ==================== 自动调整分类百分比及 min/max ====================
-- 上传分档表
local upload_tiers = {
    { threshold = 10000,   realtime = 25, normal = 50, bulk = 25 },
    { threshold = 30000,   realtime = 20, normal = 60, bulk = 20 },
    { threshold = 50000,   realtime = 15, normal = 70, bulk = 15 },
    { threshold = 100000,  realtime = 12, normal = 73, bulk = 15 },
    { threshold = math.huge, realtime = 10, normal = 75, bulk = 15 }
}

-- 下载分档表
local download_tiers = {
    { threshold = 20000,   realtime = 20, normal = 60, bulk = 20 },
    { threshold = 50000,   realtime = 15, normal = 70, bulk = 15 },
    { threshold = 100000,  realtime = 12, normal = 73, bulk = 15 },
    { threshold = 200000,  realtime = 10, normal = 70, bulk = 20 },
    { threshold = 500000,  realtime = 8,  normal = 67, bulk = 25 },
    { threshold = math.huge, realtime = 5,  normal = 65, bulk = 30 }
}

-- 根据带宽和链路类型获取百分比数组（返回 {realtime, normal, bulk}）
local function get_percentages(direction, bw, linklayer)
    local tiers = (direction == "upload") and upload_tiers or download_tiers
    local percents
    for _, tier in ipairs(tiers) do
        if bw < tier.threshold then
            percents = { tier.realtime, tier.normal, tier.bulk }
            break
        end
    end
    if not percents then
        local last = tiers[#tiers]
        percents = { last.realtime, last.normal, last.bulk }
    end

    -- ADSL 上行微调：realtime +5，优先从 normal 扣除
    if direction == "upload" and linklayer == "adsl" then
        if percents[2] >= 5 then
            percents[1] = percents[1] + 5
            percents[2] = percents[2] - 5
        else
            percents[1] = percents[1] + 5
            percents[3] = percents[3] - 5
        end
        -- 边界保护
        percents[1] = math.min(percents[1], 100)
        percents[2] = math.max(percents[2], 0)
        percents[3] = math.max(percents[3], 0)
    end

    return percents
end

-- 应用百分比及 min/max（通过分类名称直接查找 section）
-- adjust_minmax: 是否同时更新最小/最大带宽
local function apply_class_percentages(direction, bw, linklayer, adjust_minmax)
    local percents = get_percentages(direction, bw, linklayer)
    local class_names = { "realtime", "normal", "bulk" }
    
    for idx, class_name in ipairs(class_names) do
        local section = nil
        uci:foreach(qos_gargoyle, direction .. "_class", function(s)
            if s.name == class_name then
                section = s[".name"]
                return false -- 找到后停止遍历
            end
        end)
        if section then
            -- 设置百分比
            uci:set(qos_gargoyle, section, "percent_bandwidth", tostring(percents[idx]))
            
            if adjust_minmax then
                local min_pct, max_pct
                if class_name == "realtime" then
                    min_pct = 60    -- 保证带宽占分类带宽的 60%
                    max_pct = 200   -- nil 表示删除（无限制）
                elseif class_name == "normal" then
                    min_pct = 1
                    max_pct = 200   -- 最大带宽占分类带宽的 200%
                else -- bulk
                    min_pct = 1
                    max_pct = 100   -- 最大带宽占分类带宽的 100%
                end
                
                uci:set(qos_gargoyle, section, "per_min_bandwidth", tostring(min_pct))
                if max_pct then
                    uci:set(qos_gargoyle, section, "per_max_bandwidth", tostring(max_pct))
                else
                    uci:delete(qos_gargoyle, section, "per_max_bandwidth")  -- 留空表示无限制
                end
            end
        else
            sys.call("logger -t qos_gargoyle '警告：未找到分类 " .. class_name .. "，跳过自动调整'")
        end
    end
end

-- 保存配置后的服务控制函数
local function handle_service_control()
    -- 创建新的uci游标，获取最新的配置值
    local cursor = uci.cursor()
    local enabled = cursor:get(qos_gargoyle, "global", "enabled") or "0"
    
    -- 调试信息
    sys.call("logger -t qos_gargoyle_debug '服务控制函数被调用，enabled 值: " .. tostring(enabled) .. "'")
    
    if enabled == "1" then
        sys.call("logger -t qos_gargoyle '启用 QoS 服务'")
        -- 启用并启动服务
        os.execute("/etc/init.d/qos_gargoyle enable >/dev/null 2>&1")
        os.execute("/etc/init.d/qos_gargoyle start >/dev/null 2>&1")
    else
        sys.call("logger -t qos_gargoyle '禁用 QoS 服务'")
        -- 停止并禁用服务
        os.execute("/etc/init.d/qos_gargoyle stop >/dev/null 2>&1")
        os.execute("/etc/init.d/qos_gargoyle disable >/dev/null 2>&1")
    end
    
    return true
end

-- 保存配置前的钩子函数
local function before_apply(self)
    sys.call("logger -t qos_gargoyle '配置即将应用'")
    return true
end

-- 保存配置后的钩子函数
local function after_apply(self)
    sys.call("logger -t qos_gargoyle '配置已应用，正在处理服务启停'")
    
    -- 等待一小段时间，确保配置已保存
    os.execute("sleep 0.5")
    
    -- 处理服务控制
    handle_service_control()
    
    -- ===== 自动调整分类百分比 =====
    local upload_bw = tonumber(uci:get(qos_gargoyle, "upload", "total_bandwidth")) or 50000
    local download_bw = tonumber(uci:get(qos_gargoyle, "download", "total_bandwidth")) or 100000
    local linklayer = uci:get(qos_gargoyle, "global", "linklayer") or "atm"
    
    apply_class_percentages("upload", upload_bw, linklayer, true)
    apply_class_percentages("download", download_bw, linklayer, true)
    
    uci:commit(qos_gargoyle)
    -- ===== 结束 =====
    
    return true
end

-- 重写 Map 的 parse 方法
local parse_original = m.parse
function m.parse(self, ...)
    local result = parse_original(self, ...)
    
    -- 检查是否点击了保存/应用按钮
    local apply = luci.http.formvalue("cbi.apply")
    local save = luci.http.formvalue("cbi.cbid.qos_gargoyle.global.enabled")
    
    sys.call("logger -t qos_gargoyle_debug 'parse 函数被调用，apply: " .. tostring(apply) .. ", save: " .. tostring(save) .. "'")
    
    if apply then
        sys.call("logger -t qos_gargoyle '检测到应用按钮点击'")
        after_apply(self)
    end
    
    return result
end

-- 重写 Map 的 write 方法
local write_original = m.write
function m.write(self, section, value)
    sys.call("logger -t qos_gargoyle_debug 'write 函数被调用，section: ' .. tostring(section) .. ', value: ' .. tostring(value)")
    
    local result = write_original(self, section, value)
    
    -- 保存配置后立即提交
    uci:commit(qos_gargoyle)
    
    return result
end

-- 设置自动应用
m.apply_on_parse = true

return m