-- Copyright 2026 ilxp <lixp@live.com>
-- Licensed to the public under the Apache License 2.0.
-- 优化版：完整支持 rule.sh 中的所有匹配参数
-- 支持的参数：family, proto, src_ip, dest_ip, srcport, dstport, state, connbytes_kb,
--             tcp_flags, packet_len, dscp, iif, oif, icmp_type, udp_length, ttl

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

-- ==================== 基本信息 ====================
o = s:option(Value, "description", translate("Description"),
	translate("Optional description for this rule."))
o.rmempty = true

-- 规则顺序（只读）
local current_order = m.uci:get(qos_gargoyle, sid, "order") or "?"
o = s:option(DummyValue, "_order", translate("Rule Order"))
o.value = translate("Position") .. ": " .. current_order

-- 服务分类
o = s:option(ListValue, "class", translate("Service Class"))
o.rmempty = false
for _, cls in ipairs(upload_classes) do 
	o:value(cls.name, cls.alias) 
end

-- ==================== 基础匹配条件 ====================
-- IP 协议族
o = s:option(ListValue, "family", translate("IP Family"))
o.default = "inet"
o:value("ip", "IPv4")
o:value("inet", translate("IPv4 and IPv6"))
o:value("ip6", "IPv6")

-- 传输层协议
o = s:option(ListValue, "proto", translate("Protocol"))
o:value("", translate("All"))
o:value("tcp", "TCP")
o:value("udp", "UDP")
o:value("icmp", "ICMP")
o:value("icmpv6", "ICMPv6")
o:value("gre", "GRE")
o:value("esp", "ESP")
o:value("ah", "AH")
o:value("sctp", "SCTP")
o:value("dccp", "DCCP")
o:value("udplite", "UDPLite")
o:value("tcp_udp", "TCP/UDP")

-- 源 IP
o = s:option(Value, "source", translate("Source IP"),
	translate("Source IP address or CIDR (e.g., 192.168.1.0/24). Use != for negation."))
o:value("", translate("All"))
wa.cbi_add_knownips(o)
o.datatype = "ipaddr"

-- 源端口（仅 TCP/UDP）
o = s:option(Value, "srcport", translate("Source Port"),
	translate("Single port, range (80-90), or comma-separated list. Use != for negation."))
o:depends("proto", "tcp")
o:depends("proto", "udp")
o:depends("proto", "tcp_udp")
o.placeholder = "e.g., 80,443,8000-9000"
o.datatype = "string"

-- 目标 IP
o = s:option(Value, "destination", translate("Dest IP"),
	translate("Destination IP address or CIDR. Use != for negation."))
o:value("", translate("All"))
wa.cbi_add_knownips(o)
o.datatype = "ipaddr"

-- 目标端口（仅 TCP/UDP）
o = s:option(Value, "dstport", translate("Dest Port"),
	translate("Single port, range, or list. Use != for negation."))
o:depends("proto", "tcp")
o:depends("proto", "udp")
o:depends("proto", "tcp_udp")
o.placeholder = "e.g., 80,443,8000-9000"
o.datatype = "string"

-- 连接状态
o = s:option(Value, "state", translate("Connection State"),
	translate("Comma-separated list of states: new, established, related, untracked, invalid. Use { } for set."))
o.placeholder = "e.g., new,established"
o.datatype = "string"

-- 连接传输字节数
o = s:option(Value, "connbytes_kb", translate("Connection Bytes (KB)"),
	translate("Total bytes transferred in the connection (KB). Supports: >100, <1024, 100-1000, !=512."))
o.placeholder = "e.g., >1024 or 1000-5000"
o.datatype = "string"

-- ==================== 高级包匹配 ====================
-- TCP 标志位
o = s:option(Value, "tcp_flags", translate("TCP Flags"),
	translate("Comma-separated flags: syn, ack, rst, fin, urg, psh, ecn, cwr. Use ! for negation."))
o:depends("proto", "tcp")
o.placeholder = "e.g., syn,ack or !rst"
o.datatype = "string"

-- 包长度
o = s:option(Value, "packet_len", translate("Packet Length (bytes)"),
	translate("Supports: <100, >500, 100-200, !=1500"))
o.placeholder = "e.g., 64-1500 or >100"
o.datatype = "string"

-- DSCP 值
o = s:option(Value, "dscp", translate("DSCP Value"),
	translate("Match DSCP (0-63). Use != for negation."))
o.placeholder = "e.g., 46 or !=0"
o.datatype = "string"

-- 入接口
o = s:option(Value, "iif", translate("Input Interface"),
	translate("Interface where packet arrived (e.g., pppoe-wan, eth0)."))
o.placeholder = "e.g., pppoe-wan"
o.datatype = "string"

-- 出接口
o = s:option(Value, "oif", translate("Output Interface"),
	translate("Interface where packet is leaving (e.g., br-lan, eth1)."))
o.placeholder = "e.g., br-lan"
o.datatype = "string"

-- ICMP 类型/代码（替代旧的 icmptype）
o = s:option(Value, "icmp_type", translate("ICMP/ICMPv6 Type/Code"),
	translate("Format: type/code (e.g., 8/0) or just type. Use != for negation."))
o:depends("proto", "icmp")
o:depends("proto", "icmpv6")
o.placeholder = "e.g., 8/0 or !=3"
o.datatype = "string"

-- UDP 长度
o = s:option(Value, "udp_length", translate("UDP Length (bytes)"),
	translate("Match UDP packet length. Supports comparisons and ranges."))
o:depends("proto", "udp")
o.placeholder = "e.g., >100 or 64-1500"
o.datatype = "string"

-- TTL / Hop Limit
o = s:option(Value, "ttl", translate("TTL / Hop Limit"),
	translate("Supports: >64, <128, !=255, =64."))
o.placeholder = "e.g., >64"
o.datatype = "string"

-- DPI 协议（如果可用）
if qos.has_ndpi() then
	o = s:option(ListValue, "ndpi", translate("DPI Protocol (deprecated)"))
	o:value("", translate("All"))
	qos.cbi_add_dpi_protocols(o)
	o.description = translate("Not used by CAKE/HFSC/HTB backends, only for compatibility.")
end

return m