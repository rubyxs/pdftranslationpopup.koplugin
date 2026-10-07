-- A paged, image-only OpenMoji picker for the PDF popup text dialog.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Screen = Device.screen
local COLS = 6

local function gridMetrics()
    local width = math.floor(Screen:getWidth() * 0.92)
    local cell = math.floor((width - 2 * Size.padding.default) / COLS)
    local rows = math.min(5, math.max(3,
        math.floor(Screen:getHeight() * 0.70 / cell)))
    return width, cell, rows
end

local EmojiTile = InputContainer:extend{
    file = nil,
    size = nil,
    selected = false,
    callback = nil,
}

function EmojiTile:init()
    self.dimen = Geom:new{ w = self.size, h = self.size }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    local border = self.selected and math.max(2, Screen:scaleBySize(2)) or 1
    local icon_size = math.floor(self.size * 0.72)
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        bordersize = border,
        padding = 0,
        margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = self.size - 2 * border, h = self.size - 2 * border },
            ImageWidget:new{
                file = self.file,
                width = icon_size,
                height = icon_size,
                alpha = true,
            },
        },
    }
end

function EmojiTile:onTap()
    if self.callback then self.callback() end
    return true
end

local EmojiGrid = InputContainer:extend{
    name = "pdftranslationpopup_emoji_grid",
    faces = nil,
    assets_dir = nil,
    selected = nil,
    page = 1,
    on_select = nil,
    on_cancel = nil,
}

function EmojiGrid.pageForCode(faces, code)
    if not code then return 1 end
    local _, _, rows = gridMetrics()
    for index, face in ipairs(faces) do
        if face.code == code then
            return math.ceil(index / (COLS * rows))
        end
    end
    return 1
end

function EmojiGrid:init()
    self.dimen = Screen:getSize()
    self.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:_build()
    UIManager:setDirty(self, "ui")
end

function EmojiGrid:_build()
    local width, cell, rows = gridMetrics()
    local per_page = COLS * rows
    local pages = math.max(1, math.ceil(#self.faces / per_page))
    self.page = math.max(1, math.min(self.page, pages))

    local top = ButtonTable:new{
        width = width,
        show_parent = self,
        buttons = {{
            { text = _("普通圆点"), callback = function() self:_choose(nil) end },
            { text = _("取消"), callback = function() UIManager:close(self) end },
        }},
    }
    local title = TextWidget:new{
        text = _("选择表情"),
        face = Font:getFace("smallinfofont"),
    }
    local title_row = CenterContainer:new{
        dimen = Geom:new{ w = width, h = title:getSize().h + Size.padding.default },
        title,
    }

    local grid = VerticalGroup:new{}
    local first = (self.page - 1) * per_page + 1
    local last = math.min(#self.faces, first + per_page - 1)
    local row
    for index = first, last do
        if (index - first) % COLS == 0 then
            row = HorizontalGroup:new{}
            table.insert(grid, row)
        end
        local face = self.faces[index]
        table.insert(row, EmojiTile:new{
            file = self.assets_dir .. "/" .. face.code .. ".svg",
            size = cell,
            selected = self.selected == face.code,
            callback = function() self:_choose(face.code) end,
        })
    end

    local page_row = ButtonTable:new{
        width = width,
        show_parent = self,
        buttons = {{
            { text = "◀", enabled = self.page > 1,
                callback = function() self:_switchPage(self.page - 1) end },
            { text = self.page .. " / " .. pages, enabled = false },
            { text = "▶", enabled = self.page < pages,
                callback = function() self:_switchPage(self.page + 1) end },
        }},
    }
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = 0,
        VerticalGroup:new{
            align = "center",
            top,
            title_row,
            grid,
            page_row,
        },
    }
    self.movable = MovableContainer:new{ self.frame }
    self[1] = CenterContainer:new{ dimen = self.dimen, self.movable }
end

function EmojiGrid:_choose(code)
    self.choice_made = true
    UIManager:close(self)
    if self.on_select then self.on_select(code) end
end

function EmojiGrid:_switchPage(page)
    self.replacing = true
    UIManager:close(self)
    UIManager:show(EmojiGrid:new{
        faces = self.faces,
        assets_dir = self.assets_dir,
        selected = self.selected,
        page = page,
        on_select = self.on_select,
        on_cancel = self.on_cancel,
    })
end

function EmojiGrid:onTapClose(_, ges)
    if self.frame.dimen and ges.pos:notIntersectWith(self.frame.dimen) then
        UIManager:close(self)
        return true
    end
    return false
end

function EmojiGrid:onClose()
    UIManager:close(self)
    return true
end

function EmojiGrid:onCloseWidget()
    UIManager:setDirty(nil, "ui", self.frame.dimen)
    if not self.choice_made and not self.replacing and self.on_cancel then
        self.on_cancel()
    end
end

return EmojiGrid
