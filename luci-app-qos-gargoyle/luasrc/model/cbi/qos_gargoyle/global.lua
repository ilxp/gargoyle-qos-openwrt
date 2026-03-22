-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.
-- Modified 2026 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>
-- 版本: 支持带宽为 0（禁用对应方向），新增 ACK/TCP 升级开关

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
    translate("HFSC: Guarantees low latency, ideal for gaming/voip.HTB: Flexible bandwidth control, good for multi-service management.CAKE: Modern and plug-and-play, simple to use."))
o:value("hfsc_cake", "HFSC+CAKE (HFSC With CAKE)")
o:value("htb_cake", "HTB+CAKE (HTB With CAKE)")
o:value("cake", "CAKE (Common Applications Kept Enhanced)")
o:value("cake_dscp", "CAKE+DSCP (CAKE With Dscp)")
o:value("htb_fqcodel", "HTB+Fq_Codel (HTB With Fq_Codel)")
o.default = "htb_cake"

-- 自定义规则选择
local ruleset_dir = "/etc/qos_gargoyle/rulesets"
local ruleset_opts = { ["default.conf"] = "Default" }
if nixio.fs.access(ruleset_dir) then
    for f in nixio.fs.dir(ruleset_dir) do
        if f:match("%.conf$") then
            ruleset_opts[f] = f
        end
    end
end

local ruleset = s:option(ListValue, "ruleset", translate("Custom Rule"))
ruleset.default = "default.conf"
for k, v in pairs(ruleset_opts) do
    ruleset:value(k, v)
end
ruleset.description = translate("Select a custom rule file to override built-in rules.")

-- 管理自定义规则按钮
local manage_btn = s:option(Button, "_manage_custom_rules")
manage_btn.inputtitle = translate("Manage Custom Rules")
manage_btn.inputstyle = "apply"
manage_btn.write = function()
    luci.http.redirect(luci.dispatcher.build_url("admin/network/qos_gargoyle/ruleset_manager"))
end

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

-- 调整百分比开关
o = s:option(Flag, "auto_adjust_percentages", translate("Auto Adjust Percentages"),
             translate("Automatically adjust class percentages and min/max bandwidth based on total bandwidth and linklayer type."))
o.default = "1"
o.rmempty = false

-- ========== 新增开关 ==========
-- ACK 限速开关
o = s:option(Flag, "enable_ack_limit", translate("Enable ACK Limit"),
             translate("Limit ACK packets to prevent bufferbloat. Recommended for asymmetric links."))
o.default = "1"
o.rmempty = false

-- TCP 升级开关
o = s:option(Flag, "enable_tcp_upgrade", translate("Enable TCP Upgrade"),
             translate("Prioritize slow TCP connections (e.g., web browsing) to improve responsiveness."))
o.default = "1"
o.rmempty = false

-- 速率限制开关（可选，若需要可在页面中启用）
-- o = s:option(Flag, "enable_ratelimit", translate("Enable Rate Limit"),
--              translate("Rate limit specific IPs or networks as defined in the 'ratelimit' sections."))
-- o.default = "0"
-- o.rmempty = false

-- ========== 上传带宽配置 ==========
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
-- 允许 0 或空值（0 表示禁用上传 QoS）

-- ========== 下载带宽配置 ==========
s = m:section(NamedSection, "download", "download", translate("Download Settings"))
s.anonymous = true

o = s:option(ListValue, "default_class", translate("Default Service Class"),
    translate("Specifie how packets that do not match any rule should be classified."))
for _, s in ipairs(download_classes) do o:value(s.name, s.alias) end

o = s:option(Value, "total_bandwidth", translate("Total Download Bandwidth"),
    translate("Specifying correctly is crucial to making QoS work. Note that bandwidth is specified "
    .. "in kbps, leave blank to disable download QoS. There are 8 kilobits per kilobyte."))
o.datatype = "uinteger"
-- 允许 0 或空值（0 表示禁用下载 QoS）

-- 配置IFB设备
local function get_ifb_devices()
    local devices = {}
    local handle = io.popen("ls /sys/class/net/ 2>/dev/null | grep '^ifb'")
    if handle then
        for line in handle:lines() do
            devices[#devices+1] = line
        end
        handle:close()
    end
    return devices
end

local ifb_devices_list = get_ifb_devices()

o = s:option(Value, "ifb_device", translate("IFB Device"),
    translate("Select or enter the IFB (Intermediate Functional Block) device used for ingress shaping. Typically ifb0."))

for _, ifb in ipairs(ifb_devices_list) do
    o:value(ifb)
end

local current_ifb = uci:get(qos_gargoyle, "download", "ifb_device")
if current_ifb and current_ifb ~= "" then
    o.default = current_ifb
else
    if #ifb_devices_list > 0 then
        o.default = ifb_devices_list[1]
    else
        o.default = "ifb0"
    end
end
o.placeholder = "ifb0"

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

-- 修改后的应用百分比函数，接受 UCI 游标作为参数
local function apply_class_percentages(cursor, direction, bw, linklayer, adjust_minmax)
    -- 如果带宽为 0 或空，跳过调整
    if not bw or bw == 0 then
        sys.call("logger -t qos_gargoyle '警告：方向 " .. direction .. " 带宽为 0 或未配置，跳过自动调整'")
        return
    end
    local percents = get_percentages(direction, bw, linklayer)
    local class_names = { "realtime", "normal", "bulk" }
    
    for idx, class_name in ipairs(class_names) do
        local section = nil
        cursor:foreach(qos_gargoyle, direction .. "_class", function(s)
            if s.name == class_name then
                section = s[".name"]
                return false -- 找到后停止遍历
            end
        end)
        if section then
            -- 设置百分比
            cursor:set(qos_gargoyle, section, "percent_bandwidth", tostring(percents[idx]))
            
            if adjust_minmax then
                local min_pct, max_pct
                if class_name == "realtime" then
                    min_pct = 60    -- 保证带宽占分类带宽的 60%
                    max_pct = 200   -- 最大带宽占分类带宽的 200%
                elseif class_name == "normal" then
                    min_pct = 0
                    max_pct = 200
                else -- bulk
                    min_pct = 0
                    max_pct = 100
                end
                
                cursor:set(qos_gargoyle, section, "per_min_bandwidth", tostring(min_pct))
                if max_pct then
                    cursor:set(qos_gargoyle, section, "per_max_bandwidth", tostring(max_pct))
                else
                    cursor:delete(qos_gargoyle, section, "per_max_bandwidth")  -- 留空表示无限制
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

-- 保存配置后的钩子函数（修改版，使用开关）
local function after_apply(self)
    sys.call("logger -t qos_gargoyle '配置已应用，正在处理服务启停'")
    os.execute("sleep 0.5")
    handle_service_control()
    
    -- 检查自动调整开关
    local auto_adjust = self.uci:get(qos_gargoyle, "global", "auto_adjust_percentages") or "1"
    if auto_adjust == "1" then
        local upload_bw = tonumber(self.uci:get(qos_gargoyle, "upload", "total_bandwidth")) or 0
        local download_bw = tonumber(self.uci:get(qos_gargoyle, "download", "total_bandwidth")) or 0
        local linklayer = self.uci:get(qos_gargoyle, "global", "linklayer") or "atm"
        
        -- 仅当带宽 > 0 时才调整，避免除零或负数
        if upload_bw > 0 then
            apply_class_percentages(self.uci, "upload", upload_bw, linklayer, true)
        else
            sys.call("logger -t qos_gargoyle '上传带宽为 0，跳过自动调整'")
        end
        if download_bw > 0 then
            apply_class_percentages(self.uci, "download", download_bw, linklayer, true)
        else
            sys.call("logger -t qos_gargoyle '下载带宽为 0，跳过自动调整'")
        end
        
        self.uci:commit(qos_gargoyle)
    else
        sys.call("logger -t qos_gargoyle '自动调整已禁用'")
    end
    
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