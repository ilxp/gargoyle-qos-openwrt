-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.
-- Modified 2026 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>ilxp/gargoyle-qos-openwrt

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

m = Map("qos_gargoyle", translate("Gargoyle QoS"),
    translate("QoS Gargoyle provides more refined bandwidth control, supporting 4 algorithms including HTP+CAKE,HFSC+CAKE,HTP+FQCODEL,CAKE. It also supports active congestion control, dynamic classification, ACK speed limit, and TCP/UDP optimization. Ensure low latency for gaming and VoIP while efficiently managing high traffic.") ..
    '<br/>' ..
    translate("Contributed by ilxp: ") .. '<a href="https://github.com/ilxp/iqos-openwrt" target="_blank">iQoS On Github</a>')

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
o:value("htb_fqcodel", "HTB+Fq_Codel (HTB With Fq_Codel)")
o.default = "htb_cake"

-- 自定义规则选择
local ruleset_dir = "/etc/qos_gargoyle/rulesets"
local ruleset_opts = { ["default.ru"] = "Default" }
if nixio.fs.access(ruleset_dir) then
    for f in nixio.fs.dir(ruleset_dir) do
        if f:match("%.ru$") then
            ruleset_opts[f] = f
        end
    end
end

local ruleset = s:option(ListValue, "ruleset", translate("Custom Rule"))
ruleset.default = "default.ru"
for k, v in pairs(ruleset_opts) do
    ruleset:value(k, v)
end
ruleset.description = translate("Select a custom rule file to override built-in rules.")

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

-- ACK 限速开关
o = s:option(Flag, "enable_ack_limit", translate("Enable ACK Limit"),
             translate("Limit ACK packets to prevent bufferbloat. Recommended for asymmetric links."))
o.default = "1"
o.rmempty = false

-- TCP 升级开关
o = s:option(Flag, "enable_tcp_upgrade", translate("Enable TCP Upgrade"),
             translate("Prioritize slow TCP connections (e.g., web browsing) to improve responsiveness."))
o.default = "0"
o.rmempty = false

-- UDP 限速开关
o = s:option(Flag, "enable_udp_limit", translate("Enable UDP Limit"),
             translate("Rate limit UDP packets to prevent abuse. Packets exceeding the limit will be dropped or marked as bulk."))
o.default = "0"
o.rmempty = false

-- 动态分类总开关
o = s:option(Flag, "enable_dclassify", translate("Enable Dynamic Classification"),
             translate("Automatically detect bulk clients and high-throughput services, and adjust their priority accordingly."))
o.default = "0"
o.rmempty = false

-- 调整百分比开关
o = s:option(Flag, "auto_adjust_percentages", translate("Auto Adjust Percentages"),
             translate("Automatically adjust class percentages and min/max bandwidth based on total bandwidth and linklayer type with priorities ranging from 1 to 4,Only supports 4 class."))
o.default = "1"
o.rmempty = false

-- 获取当前规则集文件路径
local function get_current_ruleset_file()
    local ruleset = uci:get(qos_gargoyle, "global", "ruleset") or "default.ru"
    if not ruleset:match("%.ru$") then ruleset = ruleset .. ".ru" end
    return "/etc/qos_gargoyle/rulesets/" .. ruleset
end

-- 从规则集文件中解析指定类型的类别
local function parse_classes_from_file(filepath, class_type)
    local classes = {}
    local f = io.open(filepath, "r")
    if not f then return classes end
    local in_class = false
    local class_name = nil
    for line in f:lines() do
        local match = line:match("^%s*config%s+" .. class_type .. "%s+'([^']+)'")
        if match then
            class_name = match
            in_class = true
        elseif in_class and line:match("^%s*option%s+name%s+'([^']+)'") then
            local name = line:match("^%s*option%s+name%s+'([^']+)'")
            if name then
                table.insert(classes, { name = class_name, alias = name })
            end
            in_class = false
        end
    end
    f:close()
    return classes
end

-- 获取上传类别列表
local upload_classes = {}
uci:foreach(qos_gargoyle, "upload_class", function(s)
    if s.name then
        upload_classes[#upload_classes+1] = {name = s[".name"], alias = s.name}
    end
end)
if #upload_classes == 0 then
    local ruleset_file = get_current_ruleset_file()
    upload_classes = parse_classes_from_file(ruleset_file, "upload_class")
end

-- 获取下载类别列表
local download_classes = {}
uci:foreach(qos_gargoyle, "download_class", function(s)
    if s.name then
        download_classes[#download_classes+1] = {name = s[".name"], alias = s.name}
    end
end)
if #download_classes == 0 then
    local ruleset_file = get_current_ruleset_file()
    download_classes = parse_classes_from_file(ruleset_file, "download_class")
end

-- ========== 上传带宽配置 ==========
s = m:section(NamedSection, "upload", "upload", translate("Upload Settings"))
s.anonymous = true

o = s:option(ListValue, "default_class", translate("Default Service Class"),
    translate("Specifies how packets that do not match any rule should be classified."))
for _, s in ipairs(upload_classes) do o:value(s.name, s.alias) end

o = s:option(Value, "total_bandwidth", translate("Total Upload Bandwidth"),
    translate("Enter the total upload bandwidth in kbit/s (kilobits per second). It is recommended to set this to about 90% of your actual upload speed. "
    .. "Enter 0 or leave blank to disable upload QoS. Example: 50000 for 50 Mbit/s."))
o.datatype = "uinteger"
o.placeholder = "50000"
o.rmempty = true

-- ========== 下载带宽配置 ==========
s = m:section(NamedSection, "download", "download", translate("Download Settings"))
s.anonymous = true

o = s:option(ListValue, "default_class", translate("Default Service Class"),
    translate("Specifies how packets that do not match any rule should be classified."))
for _, s in ipairs(download_classes) do o:value(s.name, s.alias) end

o = s:option(Value, "total_bandwidth", translate("Total Download Bandwidth"),
    translate("Enter the total download bandwidth in kbit/s (kilobits per second). It is recommended to set this to about 90% of your actual download speed. "
    .. "Enter 0 or leave blank to disable download QoS. Example: 100000 for 100 Mbit/s."))
o.datatype = "uinteger"
o.placeholder = "100000"
o.rmempty = true

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

-- 保存配置前的钩子函数
local function before_apply(self)
    sys.call("logger -t qos_gargoyle '配置即将应用'")
    return true
end

-- 保存配置后的钩子函数（修改版，使用重启确保算法切换生效）
-- 保存配置后的钩子函数（修改版，使用重启确保算法切换生效）
local function after_apply(self)
    sys.call("logger -t qos_gargoyle '配置已应用，正在处理服务启停'")
    
    -- 1. 同步增强功能开关到各自的配置节（确保服务启动时能读取到最新值）
    local ack_enabled = self.uci:get(qos_gargoyle, "global", "enable_ack_limit") or "1"
    local tcp_enabled = self.uci:get(qos_gargoyle, "global", "enable_tcp_upgrade") or "1"
    local udp_enabled = self.uci:get(qos_gargoyle, "global", "enable_udp_limit") or "1"

    if not self.uci:get(qos_gargoyle, "ack_limit") then
        self.uci:set(qos_gargoyle, "ack_limit", "ack_limit")
    end
    self.uci:set(qos_gargoyle, "ack_limit", "enabled", ack_enabled)

    if not self.uci:get(qos_gargoyle, "tcp_upgrade") then
        self.uci:set(qos_gargoyle, "tcp_upgrade", "tcp_upgrade")
    end
    self.uci:set(qos_gargoyle, "tcp_upgrade", "enabled", tcp_enabled)

    if not self.uci:get(qos_gargoyle, "udp_limit") then
        self.uci:set(qos_gargoyle, "udp_limit", "udp_limit")
    end
    self.uci:set(qos_gargoyle, "udp_limit", "enabled", udp_enabled)

    local dynamic_enabled = self.uci:get(qos_gargoyle, "global", "enable_dynamic_classify") or "1"
    self.uci:set(qos_gargoyle, "global", "enable_dynamic_classify", dynamic_enabled)

    self.uci:commit(qos_gargoyle)   -- 提交所有更改

    -- 2. 根据启用状态控制服务
    local enabled = self.uci:get(qos_gargoyle, "global", "enabled") or "0"
    if enabled == "1" then
        sys.call("/etc/init.d/qos_gargoyle restart >/dev/null 2>&1")
        sys.call("logger -t qos_gargoyle 'QoS 服务已重启'")
    else
        sys.call("/etc/init.d/qos_gargoyle stop >/dev/null 2>&1")
        sys.call("logger -t qos_gargoyle 'QoS 服务已停止'")
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