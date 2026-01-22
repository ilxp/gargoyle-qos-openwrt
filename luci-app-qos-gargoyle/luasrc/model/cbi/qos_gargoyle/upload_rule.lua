-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.
-- Modded by ErickG <erickguo999@gmail.com>

local wa  = require "luci.tools.webadmin"
local uci = require "luci.model.uci".cursor()
local qos = require "luci.model.qos_gargoyle"

local m, s, o
local sid = arg[1]
local upload_classes = {}
local qos_gargoyle = "qos_gargoyle"

-- 查看可用的upload_class
uci:foreach(qos_gargoyle, "upload_class", function(s)
	local class_alias = s.name
	if class_alias then
		upload_classes[#upload_classes + 1] = {name = s[".name"], alias = class_alias}
	end
end)

m = Map(qos_gargoyle, translate("Edit Upload Classification Rule"))
m.redirect = luci.dispatcher.build_url("admin/qos/qos_gargoyle/upload")

-- 如果section不等于 download_rule, 就重定向连接
if m.uci:get(qos_gargoyle, sid) ~= "upload_rule" then
	luci.http.redirect(m.redirect)
	return
end

s = m:section(NamedSection, sid, "upload_rule")
s.anonymous = true
s.addremove = false

-- 服务类型
o = s:option(ListValue, "class", translate("Service Class"))
for _, s in ipairs(upload_classes) do o:value(s.name, s.alias) end

-- 新添加,地址族
o = s:option(ListValue, "family", translate("IP family"))
o.datatype="string"
o.default="inet"
o.rmempty = false
o:value("ip", "IPV4")
o:value("inet", translate("IPV6 and IPV4"))
o:value("ip6", "IPV6")
o.rmempty = true

-- 端口协议
o = s:option(Value, "proto", translate("Transport Protocol"))
o:value("", translate("All"))
o:value("tcp", "TCP")
o:value("udp", "UDP")
o:value("icmp", "ICMP")
o:value("gre", "GRE")
o.write = function(self, section, value)
	Value.write(self, section, value:lower())
end

-- icmp拓展(在协议被选到icmp就会弹出)
-- 算了, 不搞那么复杂了,那种按判断添加值的我不会弄
o = s:option(Value, "icmpext", translate("ICMP Extension"))
o.datatype = "string"
o.default = "echo-reply"
-- o.rmempty = false
o:value("echo-reply", "echo reply")
o:value("destination-unreachable", "destination unreachable")
o:value("source-quench", "source quench")
o:value("redirect", "redirect")
o:value("echo-request", "echo request")
o:value("time-exceeded", "time exceeded")
o:value("parameter-problem", "parameter problem")
o:value("timestamp-request", "timestamp request")
o:value("timestamp-reply", "timestamp reply")
o:value("info-request", "info request")
o:value("info-reply", "info reply")
o:value("address-mask-request", "address mask request")
o:value("address-mask-reply", "address mask reply")
o:value("router-advertisement", "router advertisement")
o:value("router-solicitation", "router solicitation")
o:value("packet-too-big", "packet too big")
o:value("mld-listener-query", "mld listener query")
o:value("mld-listener-report", "mld listener report")
o:value("mld-listener-reduction", "mld listener reduction")
o:value("nd-router-solicit", "nd router solicit")
o:value("nd-router-advert", "nd router advert")
o:value("nd-neighbor-solicit", "nd neighbor solicit")
o:value("nd-neighbor-advert", "nd neighbor advert")
o:value("parameter-problem", "parameter problem")
o:value("mld2-listener-report", "mld2 listener report")
o:depends("proto", "icmp")

-- 这是ipv6 icmp选项
-- o:value("destination-unreachable", "destination unreachable")
-- o:value("packet-too-big", "packet too big")
-- o:value("time-exceeded", "time exceeded")
-- o:value("echo-request", "echo request")
-- o:value("echo-reply", "echo reply")
-- o:value("mld-listener-query", "mld listener query")
-- o:value("mld-listener-report", "mld listener report")
-- o:value("mld-listener-reduction", "mld listener reduction")
-- o:value("nd-router-solicit", "nd router solicit")
-- o:value("nd-router-advert", "nd router advert")
-- o:value("nd-neighbor-solicit", "nd neighbor solicit")
-- o:value("nd-neighbor-advert", "nd neighbor advert")
-- o:value("parameter-problem", "parameter problem")
-- o:value("mld2-listener-report", "mld2 listener report")

o = s:option(Value, "source", translate("Source IP(s)"),
	translate("Packet's source ip, can optionally have /[mask] after it (see -s option in iptables "
	.. "man page)."))
o:value("", translate("All"))
wa.cbi_add_knownips(o)
o.datatype = "ipaddr"

o = s:option(Value, "srcport", translate("Source Port(s)"),
	translate("Packet's source port, support multi ports (eg. 80-90, 443, 6000)."))
o:value("", translate("All"))
-- 使用字符串
-- o.datatype = "or(port, portrange)"
o.datatype  = "string"

o = s:option(Value, "destination", translate("Destination IP(s)"),
	translate("Packet's destination ip, can optionally have /[mask] after it (see -d option in "
	.. "iptables man page)."))
o:value("", translate("All"))
wa.cbi_add_knownips(o)
o.datatype = "ipaddr"

o = s:option(Value, "dstport", translate("Destination Port(s)"),
	translate("Packet's destination port, can be a range (eg. 80-90, 443, 6000)."))
o:value("", translate("All"))
-- 使用字符串
-- o.datatype = "or(port, portrange)"
o.datatype  = "string"

o = s:option(Value, "min_pkt_size", translate("Minimum Packet Length"),
	translate("Packet's minimum size (in bytes)."))
o.datatype = "range(1, 1500)"

o = s:option(Value, "max_pkt_size", translate("Maximum Packet Length"),
	translate("Packet's maximum size (in bytes)."))
o.datatype = "range(1, 1500)"

o = s:option(Value, "connbytes_kb", translate("Connection Bytes Reach"),
	translate("The total size of data transmitted since the establishment of the link (in kBytes)."))
-- 改成string
-- o.datatype = "range(0, 4194303)"
o.datatype = "string"

--  特征码匹配
o = s:option(Value, "match_feature_code", translate("Packet Feature Code Match"),
	translate("Match feature code in a packet"))
o.datatype = "string"

-- ndpi
if qos.has_ndpi() then
	o = s:option(ListValue, "ndpi", translate("DPI Protocol"))
	o:value("", translate("All"))
	qos.cbi_add_dpi_protocols(o)
end

return m
