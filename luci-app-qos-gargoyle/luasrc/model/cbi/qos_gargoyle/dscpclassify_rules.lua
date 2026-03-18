local m = Map("dscpclassify", translate("DSCP Classify - Rules"),
              translate("Define custom classification rules. Rules are processed in order; first match wins."))

local s = m:section(TypedSection, "rule", translate("Rules"))
s.template = "cbi/tblsection"
s.anonymous = true
s.addremove = true

s:option(Flag, "enabled", translate("Enable")).default = 1

s:option(Value, "name", translate("Rule Name")).datatype = "string"

local family = s:option(ListValue, "family", translate("Address Family"))
family:value("", translate("Any"))
family:value("ipv4", translate("IPv4"))
family:value("ipv6", translate("IPv6"))
family.optional = true

-- Protocol (multi-select list)
local proto = s:option(DynamicList, "proto", translate("Protocol"))
proto:value("tcp", "TCP")
proto:value("udp", "UDP")
proto:value("udplite", "UDPLite")
proto:value("icmp", "ICMP")
proto:value("icmpv6", "ICMPv6")
proto:value("esp", "ESP")
proto:value("ah", "AH")
proto:value("sctp", "SCTP")
proto.placeholder = "Leave empty for all protocols"

-- Source/Destination Zones (optional text)
s:option(Value, "src", translate("Source Zone"))
    .optional = true
    .placeholder = "e.g., lan"

s:option(Value, "dest", translate("Destination Zone"))
    .optional = true
    .placeholder = "e.g., wan"

-- Source/Destination IP (supports @set)
local src_ip = s:option(DynamicList, "src_ip", translate("Source IP / Set"))
src_ip.datatype = "string"
src_ip.placeholder = "e.g., 192.168.1.0/24 or @myset"

local dest_ip = s:option(DynamicList, "dest_ip", translate("Destination IP / Set"))
dest_ip.datatype = "string"
dest_ip.placeholder = "e.g., 8.8.8.8 or @doh"

-- Source/Destination Port
local src_port = s:option(DynamicList, "src_port", translate("Source Port"))
src_port.datatype = "portrange"
src_port.placeholder = "e.g., 53, 80, 1000-2000"

local dest_port = s:option(DynamicList, "dest_port", translate("Destination Port"))
dest_port.datatype = "portrange"
dest_port.placeholder = "e.g., 443, 3478-3481"

-- MAC address
local src_mac = s:option(DynamicList, "src_mac", translate("Source MAC"))
src_mac.datatype = "macaddr"
src_mac.placeholder = "aa:bb:cc:dd:ee:ff"

local dest_mac = s:option(DynamicList, "dest_mac", translate("Destination MAC"))
dest_mac.datatype = "macaddr"
dest_mac.placeholder = "aa:bb:cc:dd:ee:ff"

-- Device + Direction
s:option(Value, "device", translate("Interface Device"))
    .optional = true
    .placeholder = "e.g., br-lan"

local direction = s:option(ListValue, "direction", translate("Direction"))
direction:value("", "")
direction:value("in", "In")
direction:value("out", "Out")
direction.optional = true

-- DSCP class
local dscp = s:option(ListValue, "class", translate("DSCP Class"))
local classes = {"cs0","cs1","cs2","cs3","cs4","cs5","cs6","cs7","af11","af12","af13","af21","af22","af23","af31","af32","af33","af41","af42","af43","ef","va","le"}
for _, v in ipairs(classes) do
    dscp:value(v, v:upper())
end
dscp.rmempty = false

-- Counter
s:option(Flag, "counter", translate("Enable Counter"))
    .default = 0
    .rmempty = false

return m