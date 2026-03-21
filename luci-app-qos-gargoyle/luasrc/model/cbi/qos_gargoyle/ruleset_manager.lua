local fs = require "nixio.fs"
local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()

local RULESET_DIR = "/etc/qos_gargoyle/rulesets"

-- 获取所有规则集文件（.conf）
local function get_rulesets()
    local files = {}
    local dir = io.popen("ls " .. RULESET_DIR .. "/*.conf 2>/dev/null")
    if dir then
        for file in dir:lines() do
            local name = file:match("([^/]+)%.conf$")
            if name then
                files[name] = file
            end
        end
        dir:close()
    end
    return files
end

-- 读取文件内容
local function read_file(path)
    local fd = io.open(path, "r")
    if fd then
        local content = fd:read("*all")
        fd:close()
        return content or ""
    end
    return ""
end

-- 写入文件内容
local function write_file(path, content)
    local fd = io.open(path, "w")
    if fd then
        fd:write(content)
        fd:close()
        return true
    end
    return false
end

-- 获取当前使用的规则集
local function get_current_ruleset()
    local ruleset = uci:get("qos_gargoyle", "global", "ruleset") or "default.conf"
    -- 去掉可能的后缀
    return ruleset:gsub("%.conf$", "")
end

-- 设置当前使用的规则集并重启
local function set_current_ruleset(name)
    uci:set("qos_gargoyle", "global", "ruleset", name .. ".conf")
    uci:commit("qos_gargoyle")
    sys.call("/etc/init.d/qos_gargoyle restart")
end

-- 创建 SimpleForm
local f = SimpleForm("ruleset_manager", 
    luci.i18n.translate("Ruleset Manager"),
    luci.i18n.translate("Manage UCI ruleset files. You can edit, save, save as new, and select the active ruleset."))

-- 规则集选择器（用于编辑）
local selected = f:field(ListValue, "selected", luci.i18n.translate("Ruleset to Edit"))
selected.rmempty = false
selected:value("", luci.i18n.translate("Select a ruleset"))

-- 当前使用的规则集显示和选择器
local current = f:field(ListValue, "current", luci.i18n.translate("Active Ruleset"))
current.rmempty = false
current.description = luci.i18n.translate("Select the ruleset to apply and restart QoS.")

-- 文本编辑区
local content = f:field(TextValue, "content", luci.i18n.translate("Ruleset Content"))
content.rows = 25
content.wrap = "off"
content.monospace = true
content.description = luci.i18n.translate("Edit the ruleset in UCI format. Each section begins with 'config'.") ..
    "<br/><span style='color:red'>" .. luci.i18n.translate("Warning: Incorrect syntax may break QoS.") .. "</span>"

-- 动态填充下拉列表
local function populate_lists()
    local rulesets = get_rulesets()
    local items = {}
    for name, _ in pairs(rulesets) do
        items[#items+1] = name
    end
    table.sort(items)
    -- 清空并重新填充
    selected:valueitems(items)
    current:valueitems(items)
    
    -- 设置当前选中的值
    local cur = get_current_ruleset()
    current:value(cur, cur)
    
    -- 如果还没有选择编辑的规则集，默认选中当前使用的
    local sel = f:formvalue("selected")
    if not sel or sel == "" then
        selected:value(cur, cur)
    else
        selected:value(sel, sel)
    end
end

-- 页面加载时初始化
function f.on_parse(self)
    populate_lists()
end

-- 处理保存、另存为、应用等操作
function f.handle(self, state, data)
    if state == FORM_VALID then
        local action = self:formvalue("action")
        local sel = data.selected
        local cur = data.current
        local text = data.content
        
        -- 检查是否有编辑内容
        if not text then
            self.error = luci.i18n.translate("No content to save.")
            return
        end
        
        -- 处理保存（覆盖当前编辑的规则集）
        if action == "save" then
            if not sel or sel == "" then
                self.error = luci.i18n.translate("Please select a ruleset to edit first.")
                return
            end
            local filepath = RULESET_DIR .. "/" .. sel .. ".conf"
            if write_file(filepath, text) then
                self.message = luci.i18n.translate("Ruleset saved: %s").format(sel)
                -- 刷新列表以显示可能的新文件
                populate_lists()
                -- 保持当前选中的规则集不变
                selected:value(sel, sel)
                -- 重新加载内容（避免下次编辑时丢失）
                content.default = text
            else
                self.error = luci.i18n.translate("Failed to save ruleset. Check permissions.")
            end
        
        -- 处理另存为
        elseif action == "saveas" then
            local newname = self:formvalue("newname")
            if not newname or newname == "" then
                self.error = luci.i18n.translate("Please enter a new filename.")
                return
            end
            -- 文件名验证：只允许字母数字、下划线、横线、点（但点仅作为后缀分隔）
            if not newname:match("^[a-zA-Z0-9_-]+$") then
                self.error = luci.i18n.translate("Filename must contain only letters, numbers, underscore, and hyphen.")
                return
            end
            local filepath = RULESET_DIR .. "/" .. newname .. ".conf"
            if fs.access(filepath) then
                self.error = luci.i18n.translate("File already exists. Choose another name or overwrite with Save.")
                return
            end
            if write_file(filepath, text) then
                self.message = luci.i18n.translate("New ruleset saved: %s").format(newname)
                populate_lists()
                -- 自动选中新保存的规则集进行编辑
                selected:value(newname, newname)
                -- 如果希望自动应用新规则集，可以设置 current 为 newname，但用户可能想先检查
            else
                self.error = luci.i18n.translate("Failed to save new ruleset.")
            end
        
        -- 处理应用（切换当前使用的规则集）
        elseif action == "apply" then
            if not cur or cur == "" then
                self.error = luci.i18n.translate("No ruleset selected to apply.")
                return
            end
            set_current_ruleset(cur)
            self.message = luci.i18n.translate("Ruleset '%s' applied and QoS restarted.").format(cur)
        end
        
        -- 重定向以刷新页面（避免重复提交）
        luci.http.redirect(luci.dispatcher.build_url("admin/network/qos_gargoyle/ruleset_manager"))
        return true
    end
end

-- 添加隐藏字段用于识别操作
f:section(SimpleSection, nil, nil):append(
    function() 
        return '<input type="hidden" name="action" id="action" value="">' ..
               '<input type="hidden" name="newname" id="newname" value="">'
    end
)

-- 添加自定义按钮
f:section(SimpleSection, nil, nil):append(
    function()
        return [[
<script type="text/javascript">
function doAction(action) {
    var f = document.forms[0];
    document.getElementById('action').value = action;
    if (action == 'saveas') {
        var newname = prompt('Enter new ruleset name (letters, numbers, underscore, hyphen):', '');
        if (newname) {
            document.getElementById('newname').value = newname;
            f.submit();
        }
    } else {
        f.submit();
    }
}
</script>
<div class="cbi-button" style="margin-top:10px">
    <input class="btn cbi-button-apply" type="button" value="Save (overwrite)" onclick="doAction('save')">
    <input class="btn cbi-button-add" type="button" value="Save As..." onclick="doAction('saveas')">
    <input class="btn cbi-button-apply" type="button" value="Apply Active Ruleset" onclick="doAction('apply')">
</div>
]]
    end
)

return f