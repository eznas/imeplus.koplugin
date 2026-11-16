--[[
imeplus.koplugin — 拼音输入增强：数字选字 / ←/→ 翻页 / 模糊拼音 / 记忆常用词（简拼）

接管方式：启动时把 require("ui/data/keyboardlayouts/generic_ime") 重定向到插件自带的
引擎副本 ime_engine.lua（stock v2025.10 快照 + 功能补丁），系统文件零改动。
系统引擎版本不符时自动放弃接管，回退原生输入法。

新增行为只对拼音布局生效（switch_char == "→"；越南语/笔画布局不受影响）。
与其它拼音增强插件（pinyin_enhancement / pinyinplus / pinyinime）不可同时启用。
]]

local logger = require("logger")
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")

local ENGINE_MODULE = "ui/data/keyboardlayouts/generic_ime"
local STOCK_FILE = "frontend/ui/data/keyboardlayouts/generic_ime.lua"
local STOCK_SIZE = 15741 -- bytes, KOReader v2025.10

-- Only take over when the system engine matches the version the patched copy was made from.
local function systemEngineCompatible()
    local f = io.open(STOCK_FILE, "rb")
    if not f then
        return false, "cannot open " .. STOCK_FILE
    end
    local size = f:seek("end")
    f:close()
    if size ~= STOCK_SIZE then
        return false, string.format("size mismatch: got %d, want %d", size, STOCK_SIZE)
    end
    local g = io.open(STOCK_FILE, "rb")
    local data = g:read("*a")
    g:close()
    if not data:find("function IME:wrappedDelChar", 1, true)
        or not data:find("function IME:getCandidates", 1, true) then
        return false, "marker mismatch"
    end
    return true
end

local took_over = false
local takeover_reason

local ok, err = pcall(function()
    local compatible, why = systemEngineCompatible()
    if compatible then
        package.preload[ENGINE_MODULE] = function()
            return dofile("plugins/imeplus.koplugin/ime_engine.lua")
        end
        took_over = true
    else
        takeover_reason = why
    end
end)
if not ok then
    takeover_reason = err
end
if not took_over then
    logger.warn("imeplus: engine takeover skipped (" .. tostring(takeover_reason) .. "), stock IME stays")
else
    -- insert_menu is KOReader's official singleton for non-core plugins to join the
    -- more_tools order tables (both reader and filemanager) without touching system files.
    pcall(function() require("ui/plugin/insert_menu").add("imeplus") end)
end

local ImePlus = WidgetContainer:extend{
    name = "imeplus",
}

function ImePlus:init()
    -- v2026.07: a plugin instance must register itself into the menu's widget list,
    -- otherwise addToMainMenu is never called and the menu item never appears.
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function ImePlus:addToMainMenu(menu_items)
    if not took_over then return end
    menu_items.imeplus = {
        text = _("拼音输入增强"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("模糊拼音"),
                checked_func = function()
                    return G_reader_settings:readSetting("imeplus_fuzzy", true)
                end,
                callback = function()
                    local new_value = not G_reader_settings:readSetting("imeplus_fuzzy", true)
                    G_reader_settings:saveSetting("imeplus_fuzzy", new_value)
                end,
                keep_menu_open = true,
            },
            {
                text = _("记忆常用词"),
                checked_func = function()
                    return G_reader_settings:readSetting("imeplus_learn", true)
                end,
                callback = function()
                    local new_value = not G_reader_settings:readSetting("imeplus_learn", true)
                    G_reader_settings:saveSetting("imeplus_learn", new_value)
                end,
                keep_menu_open = true,
            },
            {
                text = _("清空记忆词"),
                callback = function()
                    G_reader_settings:saveSetting("imeplus_user_words", {})
                    UIManager:show(InfoMessage:new{
                        text = _("已清空记忆词。上屏过的词不再参与简拼候选。"),
                        timeout = 3,
                    })
                end,
                keep_menu_open = true,
            },
            {
                text = _("关于"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("拼音输入增强已接管内置输入法引擎：候选 9 个带数字编号，数字键选字，←/→ 翻页，空格上屏。上屏过的词会被记住，之后可用声母简拼打出（如完整输入 jiazai 一次后，jz 即出 加载）。模糊拼音与记忆词可在上方开关。"),
                        timeout = 10,
                    })
                end,
            },
        },
    }
end

return ImePlus
