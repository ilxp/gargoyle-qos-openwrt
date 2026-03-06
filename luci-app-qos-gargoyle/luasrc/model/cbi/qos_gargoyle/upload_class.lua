-- Copyright 2017 Xingwang Liao <kuoruan@gmail.com>
-- Licensed to the public under the Apache License 2.0.
-- Modified 2026 by ilxp <https://github.com/ilxp/gargoyle-qos-openwrt>

local m, s, o
local sid = arg[1]
local qos_gargoyle = "qos_gargoyle"

m = Map(qos_gargoyle, translate("Edit Upload Service Class"))
m.redirect = luci.dispatcher.build_url("admin/qos/qos_gargoyle/upload")

if m.uci:get(qos_gargoyle, sid) ~= "upload_class" then
    luci.http.redirect(m.redirect)
    return
end

s = m:section(NamedSection, sid, "upload_class")
s.anonymous = true
s.addremove = false

o = s:option(Value, "name", translate("Service Class Name"))
o.rmempty = false
o.default = "New Class"

o = s:option(Value, "priority", translate("Priority"),
    translate("Priority of this class. Lower number means higher priority. Used for sorting and bandwidth allocation."))
o.datatype = "uinteger"
o.default = "1"
o.rmempty = false

o = s:option(Value, "percent_bandwidth", translate("Percent"),
    translate("The percentage of total bandwidth occupied by this service type."))
o.datatype = "range(1, 100)"
o.default = "10"
o.rmempty  = false

o = s:option(Value, "per_min_bandwidth", translate("Min bandwidth(%)"),
    translate("The minimum percentage of bandwidth that can be allocated to this service type."))
o:value("0", translate("Zero"))
o.datatype = "uinteger"
o.default  = "0"

o = s:option(Value, "per_max_bandwidth", translate("Max bandwidth(%)"),
    translate("The maximum percentage of bandwidth that can be allocated to this service type."))
o:value("", translate("Unlimited"))
o.datatype = "uinteger"

o = s:option(Value, "description", translate("Description"),
    translate("Optional description for this service class."))
o.rmempty = true

return m