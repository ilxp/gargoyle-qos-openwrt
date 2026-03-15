-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.
-- Modified 2026 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>

local m, s, o
local sid = arg[1]
local qos_gargoyle = "qos_gargoyle"

m = Map(qos_gargoyle, translate("Edit Download Service Class"))
m.redirect = luci.dispatcher.build_url("admin/qos/qos_gargoyle/download")

if m.uci:get(qos_gargoyle, sid) ~= "download_class" then
	luci.http.redirect(m.redirect)
	return
end

s = m:section(NamedSection, sid, "download_class")
s.anonymous = true
s.addremove = false

o = s:option(Value, "name", translate("Service Class Name"))
o.rmempty = false

o = s:option(Value, "priority", translate("Priority"),
    translate("Priority of this class. Lower number means higher priority. Used for sorting and bandwidth allocation."))
o.datatype = "uinteger"
o.default = "1"
o.rmempty = false

o = s:option(Value, "percent_bandwidth", translate("Percent"),
	translate("The percentage of total bandwidth occupied by this service type."))
o.datatype = "range(1, 100)"
o.rmempty  = false

o = s:option(Value, "per_min_bandwidth", translate("Min bandwidth(%)"),
	translate("The minimum percentage of bandwidth that can be allocated to this service type."))
o:value("0", translate("Zero"))
o.datatype = "uinteger"
o.default  = "0"

o = s:option(Value, "per_max_bandwidth", translate("Max bandwidth(%)"),
	translate("The maximum bandwidth value (in percentage) that can be allocated to this service type."))
o:value("", translate("Unlimited"))
o.datatype = "uinteger"

o = s:option(Flag, "minRTT", translate("Minimize RTT"),
	translate("Indicates to the active congestion controller that you wish to minimize round trip "
	.. "times (RTT) when this class is active. Use this setting for online gaming or VoIP "
	.. "applications that need low round trip times (ping times). Minimizing RTT comes at the expense "
	.. "of efficient WAN throughput so while these class are active your WAN throughput will decline "
	.. "(usually around 20%)."))
o.enabled  = "Yes"
o.disabled = "No"

o = s:option(Value, "description", translate("Description"),
    translate("Optional description for this service class."))
o.rmempty = true

return m
