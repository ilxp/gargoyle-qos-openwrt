-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.
-- Modded by ErickG <erickguo999@gmail.com>

local wa  = require "luci.tools.webadmin"
local uci = require "luci.model.uci".cursor()
local qos = require "luci.model.qos_gargoyle"

local m, s, o
local sid = arg[1]
local download_classes = {}
local qos_gargoyle = "qos_gargoyle"

-- 查看可用的download_class
uci:foreach(qos_gargoyle, "download_class", function(s)
	local class_alias = s.name
	if class_alias then
		download_classes[#download_classes + 1] = {name = s[".name"], alias = class_alias}
	end
end)

m = Map(qos_gargoyle, translate("Edit Download Classification Rule"))
m.redirect = luci.dispatcher.build_url("admin/qos/qos_gargoyle/download")

-- 如果section不等于 download_rule, 就重定向连接
if m.uci:get(qos_gargoyle, sid) ~= "download_rule" then
	luci.http.redirect(m.redirect)
	return
end

s = m:section(NamedSection, sid, "download_rule")
s.anonymous = true
s.addremove = false

-- 服务类型
-- 可能需要重写: 如果没有找到对应的class就不给保存
-- 找到了值再设置default不然default就为空
o = s:option(ListValue, "class", translate("Service Class"))
for _, s in ipairs(download_classes) do o:value(s.name, s.alias) end

-- 新添加,地址族
o = s:option(ListValue, "family", translate("IP family"))
o.datatype="string"
o.default="inet"
o.rmempty = false
o:value("ip", "IPV4")
o:value("inet", translate("IPV6 and IPV4"))
o:value("ip6", "IPV6")

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
o.default = "0"
-- o.rmempty = false
o:value("0", "echo reply")
o:value("3", "destination unreachable")
o:value("4", "source quench")
o:value("5", "redirect")
o:value("8", "echo request")
o:value("11", "time exceeded")
o:value("12", "parameter problem")
o:value("13", "timestamp request")
o:value("14", "timestamp reply")
o:value("15", "info request")
o:value("16", "info reply")
o:value("17", "address mask request")
o:value("18", "address mask reply")
o:value("9", "router advertisement")
o:value("10", "router solicitation")
-- 添加v6
o:value("128", "v6 echo request")
o:value("129", "v6 echo reply")
o:value("1", "v6 destination unreachable")
o:value("2", "v6 packet too big")
o:value("130", "v6 mld listener query")
o:value("131", "v6 mld listener report")
o:value("132", "v6 mld listener reduction")
o:value("133", "v6 nd router solicit")
o:value("134", "v6 nd router advert")
o:value("135", "v6 nd neighbor solicit")
o:value("136", "v6 nd neighbor advert")
o:value("4", "v6 parameter problem")
o:value("143", "v6 mld2 listener report")
o:depends("proto", "icmp")

o = s:option(Value, "source", translate("Source IP(s)"),
	translate("Packet's source ip, can optionally have /[mask] after it (see -s option in iptables "
	.. "man page)."))
o:value("", translate("All"))
wa.cbi_add_knownips(o)
-- o.datatype = "ipmask4"
o.datatype = "ipmask"

o = s:option(Value, "srcport", translate("Source Port(s)"),
	translate("Packet's source port, support multi ports (eg. 80:90,443,6000)."))
o:value("", translate("All"))
-- 使用字符串
-- o.datatype = "or(port, portrange)"
o.datatype  = "string"

o = s:option(Value, "destination", translate("Destination IP(s)"),
	translate("Packet's destination ip, can optionally have /[mask] after it (see -d option in "
	.. "iptables man page)."))
o:value("", translate("All"))
wa.cbi_add_knownips(o)
-- o.datatype = "ipmask4"
o.datatype = "ipmask"

o = s:option(Value, "dstport", translate("Destination Port(s)"),
	translate("Packet's destination port, support multi ports (eg. 80:90,443,6000)."))
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

o = s:option(Value, "connbytes_kb", translate("Connection Bytes Reach (eg. 800:900 or 80: or :90)."),
	translate("The total size of data transmitted since the establishment of the link (in kBytes)."))
-- 改成string
-- o.datatype = "range(0, 4194303)"
o.datatype = "string"

--ndpi
if qos.has_ndpi() then
o = s:option(ListValue, "ndpi", translate("DPI Protocol"))
o:value("", translate("All"))
qos.cbi_add_dpi_protocols(o)
end

return m
