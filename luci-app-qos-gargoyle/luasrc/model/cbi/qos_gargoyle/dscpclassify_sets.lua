local m = Map("dscpclassify", translate("DSCP Classify - IP Sets"),
              translate("Manage named sets of IP addresses/CIDRs. Sets can be referenced in rules using @name."))

local s = m:section(TypedSection, "set", translate("Sets"))
s.template = "cbi/tblsection"
s.anonymous = true
s.addremove = true

local name = s:option(Value, "name", translate("Name"))
name.datatype = "string"
name.rmempty = false

local family = s:option(ListValue, "family", translate("Address Family"))
family:value("", translate("Auto"))
family:value("ipv4", translate("IPv4"))
family:value("ipv6", translate("IPv6"))
family.optional = true

local entries = s:option(DynamicList, "entry", translate("Entries"))
entries.datatype = "string"
entries.placeholder = "e.g., 192.168.1.0/24 or 2001:db8::/32"
entries.rmempty = false

return m