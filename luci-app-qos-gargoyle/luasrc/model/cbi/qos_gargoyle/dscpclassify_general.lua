local m = Map("dscpclassify", translate("DSCP Classify - General Settings"),
              translate("Configure global service options and automatic classification features."))

-- Service section
local s = m:section(NamedSection, "service", "service", translate("Service Options"))
s:tab("general", translate("General"))
s:tab("client", translate("Client Adoption"))
s:tab("bulk", translate("Bulk Client Detection"))
s:tab("htp", translate("High Throughput Detection"))

-- General tab
local wmm = s:taboption("general", Flag, "wmm_mark_lan", translate("WMM Mark LAN"),
                        translate("Mark packets going out of LAN interfaces with DSCP values respective of WMM (RFC-8325)."))
wmm.default = 0
wmm.rmempty = false

-- Client Class Adoption tab
local client = s:taboption("client", Flag, "enabled", translate("Enable"),
                           translate("Adopt the DSCP class supplied by a non-WAN client."))
client.default = 1
client.rmempty = false

local exclude = s:taboption("client", DynamicList, "exclude_class", translate("Exclude Classes"),
                            translate("DSCP classes to ignore from client class adoption (e.g., cs6, cs7)."))
local classes = {"cs0","cs1","cs2","cs3","cs4","cs5","cs6","cs7","af11","af12","af13","af21","af22","af23","af31","af32","af33","af41","af42","af43","ef","va","le"}
for _, v in ipairs(classes) do
    exclude:value(v, v:upper())
end

-- Bulk Client Detection tab
local bulk_en = s:taboption("bulk", Flag, "enabled", translate("Enable"),
                            translate("Detect and classify bulk client connections (i.e., P2P)."))
bulk_en.default = 1
bulk_en.rmempty = false

local min_bytes = s:taboption("bulk", Value, "min_bytes", translate("Minimum Bytes"),
                              translate("Minimum bytes before a client port is classified as bulk."))
min_bytes.default = 10000
min_bytes.datatype = "uinteger"
min_bytes.rmempty = false

local min_conn = s:taboption("bulk", Value, "min_connections", translate("Minimum Connections"),
                             translate("Minimum established connections for a client port to be considered as bulk."))
min_conn.default = 10
min_conn.datatype = "uinteger"
min_conn.rmempty = false

local bulk_class = s:taboption("bulk", Value, "class", translate("Class"),
                               translate("DSCP class to apply to bulk connections (overrides service default)."))
bulk_class:value("", translate("Use service default"))
for _, v in ipairs(classes) do
    bulk_class:value(v, v:upper())
end

-- High Throughput Detection tab
local htp_en = s:taboption("htp", Flag, "enabled", translate("Enable"),
                           translate("Detect and classify high throughput service connections (e.g., Steam downloads)."))
htp_en.default = 1
htp_en.rmempty = false

local htp_min_bytes = s:taboption("htp", Value, "min_bytes", translate("Minimum Bytes"),
                                  translate("Minimum bytes before the connection is classified as high-throughput."))
htp_min_bytes.default = 1000000
htp_min_bytes.datatype = "uinteger"
htp_min_bytes.rmempty = false

local htp_min_conn = s:taboption("htp", Value, "min_connections", translate("Minimum Connections"),
                                 translate("Minimum established connections for a service to be considered as high-throughput."))
htp_min_conn.default = 3
htp_min_conn.datatype = "uinteger"
htp_min_conn.rmempty = false

local htp_class = s:taboption("htp", Value, "class", translate("Class"),
                              translate("DSCP class to apply to high-throughput connections (overrides service default)."))
htp_class:value("", translate("Use service default"))
for _, v in ipairs(classes) do
    htp_class:value(v, v:upper())
end

return m