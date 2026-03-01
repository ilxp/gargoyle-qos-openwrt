-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.

local wa  = require "luci.tools.webadmin"
local uci = require "luci.model.uci".cursor()
local qos = require "luci.model.qos_gargoyle"

local m, s, o
local sid = arg[1]
local upload_classes = {}
local qos_gargoyle = "qos_gargoyle"

-- 获取上传分类
uci:foreach(qos_gargoyle, "upload_class", function(s)
	local class_alias = s.name
	if class_alias then
		upload_classes[#upload_classes + 1] = {name = s[".name"], alias = class_alias}
	end
end)

m = Map(qos_gargoyle, translate("Edit Upload Classification Rule"))
m.redirect = luci.dispatcher.build_url("admin/qos/qos_gargoyle/upload")

if m.uci:get(qos_gargoyle, sid) ~= "upload_rule" then
	luci.http.redirect(m.redirect)
	return
end

s = m:section(NamedSection, sid, "upload_rule")
s.anonymous = true
s.addremove = false

-- 添加描述字段
o = s:option(Value, "description", translate("Description"),
	translate("Optional description for this rule."))
o.rmempty = true

-- 服务类型
o = s:option(ListValue, "class", translate("Service Class"))
o.rmempty = false
for _, cls in ipairs(upload_classes) do 
	o:value(cls.name, cls.alias) 
end

-- IP协议族
o = s:option(ListValue, "family", translate("IP Family"))
o.default = "inet"
o:value("ip", "IPv4")
o:value("inet", translate("IPv4 and IPv6"))
o:value("ip6", "IPv6")

-- 传输协议
o = s:option(ListValue, "proto", translate("Transport Protocol"))
o:value("", translate("All"))
o:value("tcp", "TCP")
o:value("udp", "UDP")
o:value("icmp", "ICMP")
o:value("gre", "GRE")
o:value("icmpv6", "ICMPv6")

-- ICMP类型（仅在协议为ICMP时显示）
o = s:option(ListValue, "icmptype", translate("ICMP Type"))
o:depends("proto", "icmp")
o:depends("proto", "icmpv6")
o:value("", translate("All"))
o:value("echo-reply", "Echo Reply")
o:value("destination-unreachable", "Destination Unreachable")
o:value("source-quench", "Source Quench")
o:value("redirect", "Redirect")
o:value("echo-request", "Echo Request")
o:value("time-exceeded", "Time Exceeded")
o:value("parameter-problem", "Parameter Problem")

-- 源IP
o = s:option(Value, "source", translate("Source IP Address(es)"))
o:value("", translate("All"))
wa.cbi_add_knownips(o)
o.datatype = "ipaddr"

-- 源端口
o = s:option(Value, "srcport", translate("Source Port(s)"))
o:value("", translate("All"))
o.placeholder = "e.g., 80,443,8000-9000"
o.datatype = "string"

-- 目标IP
o = s:option(Value, "destination", translate("Destination IP Address(es)"))
o:value("", translate("All"))
wa.cbi_add_knownips(o)
o.datatype = "ipaddr"

-- 目标端口
o = s:option(Value, "dstport", translate("Destination Port(s)"))
o:value("", translate("All"))
o.placeholder = "e.g., 80,443,8000-9000"
o.datatype = "string"

-- 数据包大小限制
o = s:option(Value, "min_pkt_size", translate("Minimum Packet Size (bytes)"))
o.datatype = "range(1, 1500)"
o.placeholder = "e.g., 64"

o = s:option(Value, "max_pkt_size", translate("Maximum Packet Size (bytes)"))
o.datatype = "range(1, 1500)"
o.placeholder = "e.g., 1500"

-- 连接字节数
o = s:option(Value, "connbytes_kb", translate("Connection Bytes (KB)"))
o.datatype = "string"
o.placeholder = "e.g., 1024 or 100-1000"

-- 特征码匹配
o = s:option(Value, "match_feature_code", translate("Packet Feature Code"))
o.datatype = "string"
o.placeholder = "e.g., 0x12,0x34"

-- 应用协议检测
if qos.has_ndpi() then
	o = s:option(ListValue, "ndpi", translate("DPI Protocol"))
	o:value("", translate("All"))
	qos.cbi_add_dpi_protocols(o)
end

-- 连接状态
o = s:option(ListValue, "connstate", translate("Connection State"))
o:value("", translate("All"))
o:value("NEW", "NEW")
o:value("ESTABLISHED", "ESTABLISHED")
o:value("RELATED", "RELATED")
o:value("INVALID", "INVALID")

-- 时间范围
o = s:option(Value, "time", translate("Time Range"))
o.datatype = "string"
o.placeholder = "e.g., 08:00-18:00"

-- 星期几
o = s:option(ListValue, "weekdays", translate("Week Days"))
o:value("", translate("All"))
o:value("mon", "Monday")
o:value("tue", "Tuesday")
o:value("wed", "Wednesday")
o:value("thu", "Thursday")
o:value("fri", "Friday")
o:value("sat", "Saturday")
o:value("sun", "Sunday")

return m