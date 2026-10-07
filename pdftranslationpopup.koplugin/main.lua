local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local RenderText = require("ui/rendertext")
local RenderImage = require("ui/renderimage")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local MARKER_V2 = "KOPOPZH2\n"
local MARKER_V1 = "KOPOPZH1\n"
local POSITION_SETTING = "pdftranslationpopup_positions_v2"
local DIRTY_SETTING = "pdftranslationpopup_positions_dirty_v2"
local PENDING_ANNOTATIONS_SETTING = "pdftranslationpopup_pending_annotations_v1"
local EMBEDDED_POS_PREFIX = "@KOPOP_POS "
local EMBEDDED_EMOJI_PREFIX = "@KOPOP_EMOJI "
local EMBEDDED_EMOJI_SIZE_PREFIX = "@KOPOP_EMOJI_SIZE "
local EMOJI_SIZE_SETTING = "pdftranslationpopup_emoji_size"
local PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("@?(.*)/[^/]*$") or "."

-- Keep the plugin loadable if an older installation has not copied the new
-- artwork/catalog yet; the add-mode gesture must still work for plain dots.
local faces_loaded, loaded_faces = pcall(dofile, PLUGIN_DIR .. "/faces.lua")
local FACE_EMOJIS = faces_loaded and type(loaded_faces) == "table" and loaded_faces or {}

-- Visual marker stays small, while the tappable/holdable area is much larger.
local MARKER_DIAMETER = Screen:scaleBySize(10)
local TAP_DIAMETER = Screen:scaleBySize(34)
local MARKER_BORDER = math.max(1, Screen:scaleBySize(1))
local EMOJI_SIZES = { 18, 24, 30 }

local ACTIVE = rawget(_G, "__pdftranslationpopup_active")
if not ACTIVE then
    ACTIVE = setmetatable({}, { __mode = "k" })
    rawset(_G, "__pdftranslationpopup_active", ACTIVE)
end

local PdfTranslationPopup = WidgetContainer:extend{
    name = "pdftranslationpopup",
    is_doc_only = true,
}

local function starts_with(s, prefix)
    return type(s) == "string" and s:sub(1, #prefix) == prefix
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function popup_width(text, face)
    local longest = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local measured = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, line, true).x
        longest = math.max(longest, measured)
    end
    local padding = Screen:scaleBySize(36)
    return math.floor(clamp(
        longest + padding,
        Screen:getWidth() * 0.24,
        Screen:getWidth() * 0.78
    ))
end

local function payload_version_and_text(contents)
    if type(contents) ~= "string" then return end
    contents = contents:gsub("\r\n", "\n")

    if starts_with(contents, MARKER_V2) then
        local rest = contents:sub(#MARKER_V2 + 1)
        local x, y, after_pos = rest:match(
            "^@KOPOP_POS%s+([%+%-%.%dEe]+)%s+([%+%-%.%dEe]+)%s*\n(.*)$"
        )
        if x and y then
            rest = after_pos or ""
        end
        local emoji, after_emoji = rest:match("^@KOPOP_EMOJI%s+([%x%-]+)\n(.*)$")
        if emoji then
            rest = after_emoji or ""
        end
        local emoji_size
        if emoji then
            local saved_size, after_size = rest:match("^@KOPOP_EMOJI_SIZE%s+(%d+)\n(.*)$")
            if saved_size then
                emoji_size = tonumber(saved_size)
                if emoji_size ~= 18 and emoji_size ~= 24 and emoji_size ~= 30 then
                    emoji_size = nil
                end
                rest = after_size or ""
            end
        end
        if not x then rest = rest:gsub("^%s+", "") end
        return 2, rest, tonumber(x), tonumber(y), emoji, emoji_size
    end
    if starts_with(contents, MARKER_V1) then
        return 1, contents:sub(#MARKER_V1 + 1):gsub("^%s+", ""), nil, nil
    end
end

local function build_v2_payload(text, x, y, emoji, emoji_size)
    local payload = MARKER_V2
    if x and y then
        payload = payload .. string.format("%s%.6f %.6f\n", EMBEDDED_POS_PREFIX, x, y)
    end
    if emoji and emoji:match("^[%x%-]+$") then
        payload = payload .. EMBEDDED_EMOJI_PREFIX .. emoji .. "\n"
        if emoji_size then
            payload = payload .. EMBEDDED_EMOJI_SIZE_PREFIX .. emoji_size .. "\n"
        end
    end
    return payload .. (text or "")
end

local function marker_key(page, index)
    return string.format("p%d:%d", page, index)
end

function PdfTranslationPopup:_activate()
    if self.ui and self.ui.document then
        ACTIVE[self.ui] = self
    end
end

function PdfTranslationPopup:_loadPositions()
    self.positions = {}
    self.dirty_positions = {}
    self.pending_annotations = {}

    if not (self.ui and self.ui.doc_settings) then
        return
    end

    self.positions = self.ui.doc_settings:readSetting(POSITION_SETTING) or {}
    self.pending_annotations = self.ui.doc_settings:readSetting(PENDING_ANNOTATIONS_SETTING) or {}
    self.emoji_size = tonumber(self.ui.doc_settings:readSetting(EMOJI_SIZE_SETTING)) or 24
    if self.emoji_size ~= 18 and self.emoji_size ~= 24 and self.emoji_size ~= 30 then
        self.emoji_size = 24
    end
    local saved_dirty = self.ui.doc_settings:readSetting(DIRTY_SETTING)
    if saved_dirty then
        self.dirty_positions = saved_dirty
    else
        -- Migration from v2.0/v2.1: every sidecar position predates PDF
        -- embedding, so treat it as pending and flush it on the next clean
        -- close/manual write.
        for key in pairs(self.positions) do
            self.dirty_positions[key] = "move"
        end
    end
end

function PdfTranslationPopup:_savePositions()
    if self.ui and self.ui.doc_settings then
        self.ui.doc_settings:saveSetting(POSITION_SETTING, self.positions or {})
        self.ui.doc_settings:saveSetting(DIRTY_SETTING, self.dirty_positions or {})
        self.ui.doc_settings:saveSetting(PENDING_ANNOTATIONS_SETTING, self.pending_annotations or {})
        if self.ui.doc_settings.flush then
            local ok, saved = pcall(self.ui.doc_settings.flush, self.ui.doc_settings)
            if not ok or not saved then
                logger.warn("PDF popup sidecar save failed:", saved)
                return false
            end
        end
        return true
    end
    return false
end

function PdfTranslationPopup:_writePdfOnce()
    local doc = self.ui.document
    if self.pdf_write_attempted then
        doc.is_edited = false
        error("PDF already saved in this reading session")
    end
    local original_size = lfs.attributes(doc.file, "size")
    if not original_size then
        doc.is_edited = false
        error("cannot read original PDF size")
    end
    if self.open_pdf_size and original_size ~= self.open_pdf_size then
        doc.is_edited = false
        error("PDF changed on disk during this reading session")
    end
    self.pdf_write_attempted = true
    local ok, err = pcall(doc.writeDocument, doc)
    if ok then
        ok, err = pcall(function()
            local check = require("ffi/mupdf").openDocument(doc.file)
            local valid, validation_error = pcall(function()
                local pages = check:getPages()
                if pages ~= doc.info.number_of_pages then
                    error("saved PDF page count changed")
                end
                for page_number = 1, pages do
                    local page = check:openPage(page_number)
                    page:close()
                end
            end)
            check:close()
            if not valid then error(validation_error) end
        end)
    end
    if not ok then
        -- An incremental save only appends bytes. Restore the previous valid
        -- revision if the write or fresh-document validation failed.
        local rollback_ok, rollback_error = pcall(function()
            local ffi = require("ffi")
            require("ffi/posix_h")
            local current_size = lfs.attributes(doc.file, "size")
            if not current_size or current_size < original_size then
                error("PDF shrank during save")
            end
            local fd = ffi.C.open(doc.file, ffi.C.O_WRONLY)
            if fd < 0 then error("cannot open PDF for rollback") end
            local truncated = ffi.C.ftruncate(fd, original_size)
            ffi.C.close(fd)
            if truncated ~= 0 then error("cannot truncate PDF to previous revision") end
        end)
        if not rollback_ok then logger.warn("PDF popup rollback failed:", rollback_error) end
        -- Do not let PdfDocument:close() retry the failed save.
        doc.is_edited = false
        error(err)
    end
    doc.is_edited = false
end

function PdfTranslationPopup:_dirtyCount()
    local count = 0
    for _ in pairs(self.dirty_positions or {}) do
        count = count + 1
    end
    return count
end

function PdfTranslationPopup:_setDirty(mode)
    if self.ui and self.ui.dialog then
        UIManager:setDirty(self.ui.dialog, mode or "ui")
    end
end

function PdfTranslationPopup:init()
    self.marker_cache = {}
    self.emoji_cache = {}
    self.emoji_size = 24
    self.positions = {}
    self.dirty_positions = {}
    self.pending_annotations = {}
    self.pending_replay_failed = false
    self.move_mode = false
    self.add_mode = false
    self.move_selected = nil
    self.add_mode_marker_hold = false
    self.pdf_write_attempted = false
    self.open_pdf_path = self.ui and self.ui.document and self.ui.document.file
    self.open_pdf_size = self.open_pdf_path
        and lfs.attributes(self.open_pdf_path, "size")

    self:onDispatcherRegisterActions()
    self:_activate()
    self:_loadPositions()
    self:_installHooks()

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    if self.ui and self.ui.view and self.ui.view.registerViewModule then
        self.ui.view:registerViewModule("pdftranslationpopup_markers", self)
    end
end

function PdfTranslationPopup:onDispatcherRegisterActions()
    -- Refresh a registration left in memory by a plugin reload. Saved
    -- gestures refer to the action key and continue to work.
    Dispatcher:removeAction("pdftranslationpopup_add_dot")
    Dispatcher:registerAction("pdftranslationpopup_add_dot", {
        category = "none",
        event = "PdfTranslationPopupAddDot",
        title = _("PDF 中文弹窗：添加圆点"),
        general = true,
    })
end

function PdfTranslationPopup:onPdfTranslationPopupAddDot()
    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf) then
        UIManager:show(Notification:new{ text = _("请先打开 PDF 文档。"), timeout = 2 })
        return true
    end
    local already_active = self.add_mode
    self:_setAddMode(true)
    if already_active then
        UIManager:show(Notification:new{
            text = _("已处于添加圆点模式。"), timeout = 2,
        })
    end
    return true
end

function PdfTranslationPopup:onReaderReady()
    self:_activate()
    self:_loadPositions()
    self.marker_cache = {}
    self:_replayPendingAnnotations()
    local path = self.ui and self.ui.document and self.ui.document.file
    if path ~= self.open_pdf_path then
        self.pdf_write_attempted = false
        self.open_pdf_path = path
        self.open_pdf_size = path and lfs.attributes(path, "size")
    end
end

function PdfTranslationPopup:onSuspend()
    self:_savePositions()
end

function PdfTranslationPopup:onCloseDocument()
    -- Sidecar is the crash-safe journal while reading. On a clean close, batch
    -- all pending marker metadata changes into the PDF and write it once.
    local flushed, _, flush_error
    if self.pending_replay_failed then
        flushed, flush_error = false, "pending popup replay did not finish"
    else
        flushed, _, flush_error = self:_flushPendingToPdf(true, true)
    end
    local saved = flushed
    local doc = self.ui and self.ui.document
    if not flushed then
        logger.warn("PDF popup close-time save failed:", flush_error)
        if doc then doc.is_edited = false end
    elseif doc and doc.is_pdf and doc.is_edited then
        -- No positions were pending, but add/edit may have changed annotations.
        local ok, err = pcall(self._writePdfOnce, self)
        saved = ok
        if not ok then logger.warn("PDF popup close-time save failed:", err) end
    end
    if saved and not self.pending_replay_failed then
        self.pending_annotations = {}
    end
    self:_savePositions()
    self.move_selected = nil
    for _, image in pairs(self.emoji_cache) do
        if image then image:free() end
    end
    self.emoji_cache = {}
    if self.ui then
        ACTIVE[self.ui] = nil
    end
end

function PdfTranslationPopup:_show(text)
    local face = Font:getFace("infofont")
    local message = {
        text = text,
        face = face,
        show_icon = false,
        width = popup_width(text, face),
        dismissable = true,
        alignment = "left",
        lang = "zh",
    }

    local char_count = #util.splitToChars(text)
    local _, line_breaks = text:gsub("\n", "")
    if char_count > 240 or line_breaks > 8 then
        message.height = math.floor(Screen:getHeight() * 0.58)
    end

    UIManager:show(InfoMessage:new(message))
end

function PdfTranslationPopup:_notice(text)
    UIManager:show(InfoMessage:new{
        text = text,
        show_icon = false,
        timeout = 2,
    })
end

function PdfTranslationPopup:_getPageMarkers(page)
    if self.marker_cache[page] then
        return self.marker_cache[page]
    end

    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf and doc._document) then
        self.marker_cache[page] = {}
        return self.marker_cache[page]
    end

    local ok, raw_page = pcall(doc._document.openPage, doc._document, page)
    if not ok or not raw_page then
        self.marker_cache[page] = {}
        return self.marker_cache[page]
    end

    local ok_ann, annots = pcall(raw_page.getEmbeddedAnnotations, raw_page)
    pcall(raw_page.close, raw_page)
    if not ok_ann or type(annots) ~= "table" then
        self.marker_cache[page] = {}
        return self.marker_cache[page]
    end

    local markers = {}
    local marker_index = 0
    for _, annot in ipairs(annots) do
        local version, text, embedded_x, embedded_y, emoji, emoji_size = payload_version_and_text(annot.contents)
        if version and type(annot.boxes) == "table" and #annot.boxes > 0 then
            local native_box = annot.boxes[1]
            local page_box = doc:nativeToPageRectTransform(page, native_box)
            if page_box then
                marker_index = marker_index + 1
                markers[#markers + 1] = {
                    key = marker_key(page, marker_index),
                    page = page,
                    index = marker_index,
                    version = version,
                    text = text,
                    emoji = emoji,
                    emoji_size = emoji_size,
                    embedded_x = embedded_x,
                    embedded_y = embedded_y,
                    native_boxes = annot.boxes,
                    base_x = page_box.x + page_box.w / 2,
                    base_y = page_box.y + page_box.h / 2,
                }
            end
        end
    end

    self.marker_cache[page] = markers
    return markers
end

function PdfTranslationPopup:_getVisiblePages()
    local view = self.ui and self.ui.view
    if not view then return {} end

    if view.getCurrentPageList then
        local pages = view:getCurrentPageList()
        if pages and #pages > 0 then
            return pages
        end
    end

    local doc = self.ui and self.ui.document
    if doc and doc.getCurrentPage then
        return { doc:getCurrentPage() }
    end
    return {}
end

function PdfTranslationPopup:_markerPageCenter(marker)
    local moved = self.positions and self.positions[marker.key]
    if moved and moved.x and moved.y then
        return moved.x, moved.y
    end

    -- A pending reset deliberately masks an embedded PDF position until the
    -- next PDF flush succeeds.
    if self.dirty_positions and self.dirty_positions[marker.key] == "reset" then
        return marker.base_x, marker.base_y
    end

    if marker.embedded_x and marker.embedded_y then
        return marker.embedded_x, marker.embedded_y
    end
    return marker.base_x, marker.base_y
end

function PdfTranslationPopup:_markerScreenCenter(marker)
    local view = self.ui and self.ui.view
    if not view then return nil end

    local page_x, page_y = self:_markerPageCenter(marker)
    local rect = Geom:new{
        x = page_x - 0.5,
        y = page_y - 0.5,
        w = 1,
        h = 1,
    }
    local screen_rect = view:pageToScreenTransform(marker.page, rect)
    if not screen_rect then return nil end

    return screen_rect.x + screen_rect.w / 2,
           screen_rect.y + screen_rect.h / 2
end

function PdfTranslationPopup:_findMarkerAt(pos, v2_only)
    if not pos then return nil end

    local half = TAP_DIAMETER / 2
    local nearest
    for _, page in ipairs(self:_getVisiblePages()) do
        for _, marker in ipairs(self:_getPageMarkers(page)) do
            if not v2_only or marker.version == 2 then
                local x, y = self:_markerScreenCenter(marker)
                if x and math.abs(pos.x - x) <= half and math.abs(pos.y - y) <= half then
                    local dx = pos.x - x
                    local dy = pos.y - y
                    local distance = dx * dx + dy * dy
                    if not nearest or distance < nearest.distance then
                        nearest = {
                            distance = distance,
                            marker = marker,
                        }
                    end
                end
            end
        end
    end

    return nearest and nearest.marker or nil
end

function PdfTranslationPopup:_moveSelectedToScreenPos(pos, exit_add_mode)
    local view = self.ui and self.ui.view
    local selected = self.move_selected
    if not (view and selected and pos) then return false end

    local page_pos = view:screenToPageTransform(pos)
    if not (page_pos and page_pos.page) then return true end
    if page_pos.page ~= selected.page then
        self:_notice(_("请在同一页内选择新位置。"))
        return true
    end

    local previous_position = self.positions[selected.key]
    local previous_dirty = self.dirty_positions[selected.key]
    self.positions[selected.key] = {
        x = page_pos.x,
        y = page_pos.y,
    }
    self.dirty_positions[selected.key] = "move"
    if not self:_savePositions() then
        self.positions[selected.key] = previous_position
        self.dirty_positions[selected.key] = previous_dirty
        self:_notice(_("无法保存圆点位置；请检查 sidecar 存储。"))
        return true
    end
    self.move_selected = nil
    if exit_add_mode then
        self:_setAddMode(false)
    end
    self:_setDirty("ui")
    return true
end

function PdfTranslationPopup:_addMarkerAtScreenPos(pos)
    local doc = self.ui and self.ui.document
    local view = self.ui and self.ui.view
    if not (doc and view and pos) then return false end

    local page_pos = view:screenToPageTransform(pos)
    if not (page_pos and page_pos.page and page_pos.x and page_pos.y) then
        return true
    end
    -- KOReader has no inverse mapping from a reflowed page point to the PDF's
    -- native coordinates, which are required for an embedded annotation.
    if doc.configurable and doc.configurable.text_wrap == 1 then
        self:_notice(_("请关闭 PDF 文字重排后添加圆点。"))
        return true
    end
    local page_size = doc:getNativePageDimensions(page_pos.page)
    if page_pos.x < 1 or page_pos.y < 1
        or page_pos.x >= page_size.w - 1 or page_pos.y >= page_size.h - 1 then
        self:_notice(_("请在 PDF 页面内选择圆点位置。"))
        return true
    end
    if not (doc._checkIfWritable and doc:_checkIfWritable() == true) then
        self:_notice(_("PDF 当前不可写，无法添加圆点。"))
        return true
    end

    self:_promptNewMarkerText(page_pos)
    return true
end

function PdfTranslationPopup:_openEmojiGrid(dialog, current, on_selected)
    local available = {}
    for _, face in ipairs(FACE_EMOJIS) do
        if lfs.attributes(PLUGIN_DIR .. "/openmoji-black/" .. face.code .. ".svg", "mode") == "file" then
            available[#available + 1] = face
        end
    end
    if #available == 0 then
        self:_notice(_("没有找到 OpenMoji SVG 文件；请安装完整插件目录。"))
        return
    end
    local ok, EmojiGrid = pcall(dofile, PLUGIN_DIR .. "/emoji_grid.lua")
    if not ok then
        self:_notice(_("无法打开表情网格：") .. tostring(EmojiGrid))
        return
    end
    local keyboard_was_visible = dialog:isKeyboardVisible()
    if keyboard_was_visible then dialog:onCloseKeyboard() end
    local function restore_keyboard()
        if keyboard_was_visible then
            UIManager:scheduleIn(0.05, function()
                if self.add_mode and not dialog._pdfpopup_closed and dialog._input_widget then
                    dialog:onShowKeyboard()
                end
            end)
        end
    end
    UIManager:show(EmojiGrid:new{
        faces = available,
        assets_dir = PLUGIN_DIR .. "/openmoji-black",
        selected = current,
        page = EmojiGrid.pageForCode(available, current),
        on_select = function(code)
            on_selected(code)
            restore_keyboard()
        end,
        on_cancel = restore_keyboard,
    })
end

function PdfTranslationPopup:_promptNewMarkerText(page_pos)
    local doc = self.ui.document
    local emoji
    local dialog
    dialog = InputDialog:new{
        title = _("新圆点的注释内容"),
        input = "",
        allow_newline = true,
        buttons = {{
            { text = _("取消"), id = "close", callback = function()
                UIManager:close(dialog)
                self:_setAddMode(false)
            end },
            { text = _("表情…"), callback = function()
                self:_openEmojiGrid(dialog, emoji, function(code) emoji = code end)
            end },
            { text = _("添加"), is_enter_default = true, callback = function()
                local contents = dialog:getInputText()
                if not contents or contents:match("^%s*$") then
                    self:_notice(_("请先输入注释内容。"))
                    return
                end
                local was_edited = doc.is_edited

                -- A tiny highlight supplies the native PDF annotation anchor.
                -- The normal-sized circle remains a KOReader view overlay.
                local item = { pboxes = {{
                    x = page_pos.x - 1, y = page_pos.y - 1, w = 2, h = 2,
                }} }
                local pending = {
                    kind = "add", page = page_pos.page,
                    x = page_pos.x, y = page_pos.y,
                    text = contents, emoji = emoji, emoji_size = self.emoji_size,
                }
                table.insert(self.pending_annotations, pending)
                if not self:_savePositions() then
                    table.remove(self.pending_annotations)
                    self:_notice(_("无法保存圆点待写记录；请检查 sidecar 存储。"))
                    return
                end
                local created = false
                local ok, err = pcall(function()
                    doc:saveHighlight(page_pos.page, item)
                    created = true
                    local payload = build_v2_payload(contents, page_pos.x, page_pos.y,
                        emoji, self.emoji_size)
                    doc:updateHighlightContents(page_pos.page, item, payload)
                    local raw_page = doc._document:openPage(page_pos.page)
                    local annots = raw_page:getEmbeddedAnnotations()
                    raw_page:close()
                    local found = false
                    for _, annot in ipairs(annots or {}) do
                        if annot.contents == payload then
                            found = true
                            break
                        end
                    end
                    if not found then error("new annotation contents were not stored") end
                end)
                if not ok then
                    for index, entry in ipairs(self.pending_annotations) do
                        if entry == pending then
                            table.remove(self.pending_annotations, index)
                            break
                        end
                    end
                    self:_savePositions()
                    if created then
                        -- Remove the unsaved in-memory annotation so retrying
                        -- Add cannot create a duplicate marker.
                        pcall(doc.deleteHighlight, doc, page_pos.page, item)
                        doc.is_edited = was_edited
                        self.marker_cache[page_pos.page] = nil
                        self:_setDirty("ui")
                    end
                    self:_notice(_("添加圆点或保存 PDF 失败：") .. tostring(err))
                    return
                end

                self.marker_cache[page_pos.page] = nil
                for _, marker in ipairs(self:_getPageMarkers(page_pos.page)) do
                    if marker.version == 2 and marker.text == contents
                        and marker.embedded_x and marker.embedded_y
                        and math.abs(marker.embedded_x - page_pos.x) < 0.00001
                        and math.abs(marker.embedded_y - page_pos.y) < 0.00001 then
                        pending.key = marker.key
                        break
                    end
                end
                self:_savePositions()
                self:_setDirty("ui")
                UIManager:close(dialog)
                self:_setAddMode(false)
            end },
        }},
    }
    local inherited_close_widget = dialog.onCloseWidget
    function dialog:onCloseWidget(...)
        self._pdfpopup_closed = true
        self.plugin:_setAddMode(false)
        if inherited_close_widget then
            return inherited_close_widget(self, ...)
        end
    end
    dialog.plugin = self
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function PdfTranslationPopup:_editMarker(marker)
    local doc = self.ui and self.ui.document
    if not (doc and doc._checkIfWritable and doc:_checkIfWritable() == true) then
        self:_notice(_("PDF 当前不可写，无法修改圆点表情或文字。"))
        self:_setAddMode(false)
        return true
    end

    -- KOPOPZH1 has a baked-in circle, so only its text can be changed.
    self:_promptEditMarker(marker)
    return true
end

function PdfTranslationPopup:_promptEditMarker(marker)
    local doc = self.ui.document
    local emoji = marker.emoji
    local dialog
    dialog = InputDialog:new{
        title = marker.version == 2 and _("编辑圆点文字与表情") or _("编辑圆点文字"),
        input = marker.text,
        allow_newline = true,
        buttons = {{
            { text = _("取消"), id = "close", callback = function()
                UIManager:close(dialog)
                self:_setAddMode(false)
            end },
            { text = _("表情…"), enabled = marker.version == 2,
                callback = function()
                    self:_openEmojiGrid(dialog, emoji, function(code) emoji = code end)
                end },
            { text = _("保存"), is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                if not text or text:match("^%s*$") then
                    self:_notice(_("请先输入注释内容。"))
                    return
                end
                if text == marker.text and emoji == marker.emoji then
                    UIManager:close(dialog)
                    self:_setAddMode(false)
                    return
                end

                local chosen_size = emoji and (marker.emoji_size
                    or (marker.emoji and 24 or self.emoji_size)) or nil
                local payload = marker.version == 2
                    and build_v2_payload(text, marker.embedded_x, marker.embedded_y,
                        emoji, chosen_size)
                    or MARKER_V1 .. text
                local pending
                for _, entry in ipairs(self.pending_annotations) do
                    if entry.key == marker.key then
                        pending = entry
                        break
                    end
                end
                local newly_pending = not pending
                if not pending then
                    pending = { kind = "edit", key = marker.key }
                    table.insert(self.pending_annotations, pending)
                end
                local previous_text = pending.text
                local previous_emoji = pending.emoji
                local previous_size = pending.emoji_size
                pending.text = text
                pending.emoji = emoji
                pending.emoji_size = chosen_size
                if not self:_savePositions() then
                    if newly_pending then
                        table.remove(self.pending_annotations)
                    else
                        pending.text = previous_text
                        pending.emoji = previous_emoji
                        pending.emoji_size = previous_size
                    end
                    self:_notice(_("无法保存圆点待写记录；请检查 sidecar 存储。"))
                    return
                end
                local updated = false
                local ok, err = pcall(function()
                    doc:updateHighlightContents(marker.page,
                        { pboxes = marker.native_boxes }, payload)

                    -- updateHighlightContents silently succeeds if its PDF
                    -- annotation lookup misses. Verify this exact anchor.
                    local raw_page = doc._document:openPage(marker.page)
                    local annots = raw_page:getEmbeddedAnnotations()
                    raw_page:close()
                    local target = marker.native_boxes[1]
                    for _, annot in ipairs(annots or {}) do
                        local box = annot.boxes and annot.boxes[1]
                        if annot.contents == payload and box
                            and math.abs(box.x - target.x) < 0.01
                            and math.abs(box.y - target.y) < 0.01 then
                            updated = true
                            break
                        end
                    end
                    if not updated then error("annotation contents were not updated") end
                end)
                if ok and updated then
                    marker.text = text
                    marker.emoji = emoji
                    marker.emoji_size = chosen_size
                    self:_setDirty("ui")
                    UIManager:close(dialog)
                    self:_setAddMode(false)
                end
                if not ok then
                    self:_notice(_("圆点修改未完成；sidecar 已保留待写记录，重新打开时会重试：") .. tostring(err))
                    return
                end
            end },
        }},
    }
    local inherited_close_widget = dialog.onCloseWidget
    function dialog:onCloseWidget(...)
        self._pdfpopup_closed = true
        self.plugin:_setAddMode(false)
        if inherited_close_widget then
            return inherited_close_widget(self, ...)
        end
    end
    dialog.plugin = self
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return true
end

function PdfTranslationPopup:_findMarkerByKey(key)
    local page, index = key:match("^p(%d+):(%d+)$")
    page, index = tonumber(page), tonumber(index)
    if not (page and index) then return nil end

    for _, marker in ipairs(self:_getPageMarkers(page)) do
        if marker.index == index then
            return marker
        end
    end
end

function PdfTranslationPopup:_replayPendingAnnotations()
    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf and doc._document) then return end
    self.pending_replay_failed = false
    local rekeyed = false

    local function has_payload(page_number, payload, target_box)
        local page = doc._document:openPage(page_number)
        local annotations = page:getEmbeddedAnnotations()
        page:close()
        for _, annotation in ipairs(annotations or {}) do
            local box = annotation.boxes and annotation.boxes[1]
            if annotation.contents == payload and (not target_box
                or (box and math.abs(box.x - target_box.x) < 0.01
                    and math.abs(box.y - target_box.y) < 0.01)) then
                return true
            end
        end
        return false
    end

    for _, pending in ipairs(self.pending_annotations or {}) do
        local ok, err = pcall(function()
            if pending.kind == "add" then
                local payload = build_v2_payload(pending.text, pending.x, pending.y,
                    pending.emoji, pending.emoji_size)
                if not has_payload(pending.page, payload) then
                    local item = { pboxes = {{
                        x = pending.x - 1, y = pending.y - 1, w = 2, h = 2,
                    }} }
                    doc:saveHighlight(pending.page, item)
                    doc:updateHighlightContents(pending.page, item, payload)
                    if not has_payload(pending.page, payload) then
                        error("pending popup was not restored")
                    end
                    self.marker_cache[pending.page] = nil
                end
                for _, marker in ipairs(self:_getPageMarkers(pending.page)) do
                    if marker.version == 2 and marker.text == pending.text
                        and marker.embedded_x and marker.embedded_y
                        and math.abs(marker.embedded_x - pending.x) < 0.00001
                        and math.abs(marker.embedded_y - pending.y) < 0.00001 then
                        if pending.key and pending.key ~= marker.key then
                            self.positions[marker.key] = self.positions[pending.key]
                            self.dirty_positions[marker.key] = self.dirty_positions[pending.key]
                            self.positions[pending.key] = nil
                            self.dirty_positions[pending.key] = nil
                        end
                        if pending.key ~= marker.key then
                            pending.key = marker.key
                            rekeyed = true
                        end
                        break
                    end
                end
            elseif pending.kind == "edit" then
                local marker = self:_findMarkerByKey(pending.key)
                if not marker then error("pending popup target was not found") end
                local payload = marker.version == 2
                    and build_v2_payload(pending.text, marker.embedded_x,
                        marker.embedded_y, pending.emoji, pending.emoji_size)
                    or MARKER_V1 .. pending.text
                local target = marker.native_boxes[1]
                if not has_payload(marker.page, payload, target) then
                    doc:updateHighlightContents(marker.page,
                        { pboxes = marker.native_boxes }, payload)
                    if not has_payload(marker.page, payload, target) then
                        error("pending popup edit was not restored")
                    end
                    self.marker_cache[marker.page] = nil
                end
            else
                error("unknown pending popup operation")
            end
        end)
        if not ok then
            self.pending_replay_failed = true
            logger.warn("PDF popup pending change replay failed:", err)
        end
    end
    if rekeyed then self:_savePositions() end
end

function PdfTranslationPopup:_flushPendingToPdf(write_now, quiet)
    local pending = self:_dirtyCount()
    if pending == 0 then
        return true, 0
    end

    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf and doc._document) then
        return false, 0, _("当前文档不是可写 PDF。")
    end

    local can_write = doc._checkIfWritable and doc:_checkIfWritable()
    if can_write ~= true then
        if not quiet then
            self:_notice(_("PDF 当前不可写；圆点位置仍安全保存在 sidecar，稍后可再次写入。"))
        end
        return false, 0, _("PDF 不可写")
    end

    local updated_keys = {}
    local updated_count = 0

    for key, state in pairs(self.dirty_positions or {}) do
        local marker = self:_findMarkerByKey(key)
        if marker and marker.version == 2 and marker.native_boxes then
            local x, y
            if state ~= "reset" then
                local moved = self.positions[key]
                if moved then
                    x, y = moved.x, moved.y
                end
            end

            local contents = build_v2_payload(marker.text, x, y,
                marker.emoji, marker.emoji_size)
            local ok_update, result = pcall(
                doc.updateHighlightContents,
                doc,
                marker.page,
                { pboxes = marker.native_boxes },
                contents
            )
            if not ok_update or result == false then
                doc.is_edited = false
                if not quiet then
                    self:_notice(_("写入 PDF 注释失败；sidecar 中的待写位置已保留。"))
                end
                return false, updated_count, tostring(result)
            end

            marker.embedded_x = x
            marker.embedded_y = y
            updated_keys[#updated_keys + 1] = key
            updated_count = updated_count + 1
        end
    end

    if updated_count == 0 then
        return true, 0
    end

    if write_now then
        local ok_write, err = pcall(self._writePdfOnce, self)
        if not ok_write then
            if not quiet then
                self:_notice(_("PDF 保存失败；sidecar 中的待写位置已保留。"))
            end
            return false, updated_count, tostring(err)
        end

        -- The single incremental save has persisted all in-memory PDF edits, including
        -- any ordinary KOReader PDF annotations that were already pending.
        doc.is_edited = false

        -- Once durable in the PDF, the sidecar stops overriding it. This makes
        -- the PDF authoritative after a successful flush and prevents stale
        -- clean sidecar positions from winning after the file is moved/copied.
        for _, key in ipairs(updated_keys) do
            self.positions[key] = nil
            self.dirty_positions[key] = nil
        end
        self:_savePositions()
    end

    return true, updated_count
end

-- TAP BEHAVIOUR
-- Normal mode:
--   marker tap -> open translation
-- Editing mode, no marker selected:
--   marker tap -> STILL open translation
--   elsewhere  -> normal KOReader tap/page-turn behaviour
-- Editing mode, after a marker was long-pressed:
--   next tap -> place that marker
-- Adding mode:
--   empty page tap -> enter text, optionally choose a face, then create an annotation
--   marker tap -> edit the annotation's face and text
--   long-press marker, then tap a new position -> move it and exit add mode
function PdfTranslationPopup:_handleTap(readerlink, ges)
    local ui = readerlink and readerlink.ui
    local doc = ui and ui.document
    local view = readerlink and readerlink.view
    if not (ges and ges.pos and doc and view and doc.is_pdf and doc._document) then
        return false
    end

    if self.move_mode and self.move_selected then
        return self:_moveSelectedToScreenPos(ges.pos)
    end
    if self.add_mode and self.move_selected then
        return self:_moveSelectedToScreenPos(ges.pos, true)
    end

    local marker = self:_findMarkerAt(ges.pos, false)
    if marker then
        if self.add_mode then
            return self:_editMarker(marker)
        end
        self:_show(marker.text)
        return true
    end

    if self.add_mode then
        return self:_addMarkerAtScreenPos(ges.pos)
    end

    -- Important: edit mode does NOT consume ordinary short taps. This keeps
    -- page turning/navigation usable while edit mode stays enabled.
    return false
end

-- HOLD BEHAVIOUR
-- When editing mode is on, ALL normal KOReader long-press actions are blocked.
-- A long press on a V2 marker selects it for moving. Long press elsewhere is
-- simply consumed, preventing text selection/panel zoom/etc.
function PdfTranslationPopup:_handleHold(ges)
    if not self.move_mode then
        return false
    end

    if not (ges and ges.pos) then
        return true
    end

    local marker = self:_findMarkerAt(ges.pos, false)
    if marker then
        if marker.version ~= 2 then
            self:_notice(_("这是旧版 PDF 的内嵌圆点。请先用新版转换器重新转换后再移动。"))
        else
            self.move_selected = marker
            self:_setDirty("ui")
        end
    end

    return true
end

function PdfTranslationPopup:_handleAddModeHold(ges)
    if not (ges and ges.pos) then return false end
    local marker = self:_findMarkerAt(ges.pos, false)
    if not marker then return false end

    self.add_mode_marker_hold = true
    self.move_selected = nil
    if marker.version ~= 2 then
        self:_notice(_("这是旧版 PDF 的内嵌圆点。请先用新版转换器重新转换后再移动。"))
    else
        self.move_selected = marker
    end
    self:_setDirty("ui")
    return true
end

function PdfTranslationPopup:_installHooks()
    if not rawget(_G, "__pdftranslationpopup_readerlink_hook_v2_1") then
        local ok, ReaderLink = pcall(require, "apps/reader/modules/readerlink")
        if ok and ReaderLink and type(ReaderLink.onTap) == "function" then
            local original_onTap = ReaderLink.onTap
            ReaderLink.onTap = function(readerlink, event, ges)
                local instance = readerlink and readerlink.ui and ACTIVE[readerlink.ui]
                if instance then
                    local ok_hit, consumed = pcall(instance._handleTap, instance, readerlink, ges)
                    if ok_hit and consumed then
                        return true
                    end
                end
                return original_onTap(readerlink, event, ges)
            end
            rawset(_G, "__pdftranslationpopup_readerlink_hook_v2_1", true)
        end
    end

    if not rawget(_G, "__pdftranslationpopup_readerhighlight_hook_v2_1") then
        local ok, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
        if ok and ReaderHighlight and type(ReaderHighlight.onHold) == "function" then
            local original_onHold = ReaderHighlight.onHold
            local original_onHoldPan = ReaderHighlight.onHoldPan
            local original_onHoldRelease = ReaderHighlight.onHoldRelease

            ReaderHighlight.onHold = function(readerhighlight, event, ges)
                local instance = readerhighlight and readerhighlight.ui and ACTIVE[readerhighlight.ui]
                if instance and instance.move_mode then
                    local ok_hold, consumed = pcall(instance._handleHold, instance, ges)
                    if ok_hold and consumed then
                        return true
                    end
                    -- Even if marker lookup itself failed, edit mode owns long
                    -- press and deliberately blocks KOReader's other hold action.
                    return true
                end
                if instance and instance.add_mode then
                    local ok_hold, consumed = pcall(instance._handleAddModeHold, instance, ges)
                    if ok_hold and consumed then return true end
                end
                return original_onHold(readerhighlight, event, ges)
            end

            if type(original_onHoldPan) == "function" then
                ReaderHighlight.onHoldPan = function(readerhighlight, event, ges)
                    local instance = readerhighlight and readerhighlight.ui and ACTIVE[readerhighlight.ui]
                    if instance and instance.move_mode then
                        return true
                    end
                    if instance and instance.add_mode and instance.add_mode_marker_hold then
                        return true
                    end
                    return original_onHoldPan(readerhighlight, event, ges)
                end
            end

            if type(original_onHoldRelease) == "function" then
                ReaderHighlight.onHoldRelease = function(readerhighlight, ...)
                    local instance = readerhighlight and readerhighlight.ui and ACTIVE[readerhighlight.ui]
                    if instance and instance.move_mode then
                        return true
                    end
                    if instance and instance.add_mode and instance.add_mode_marker_hold then
                        instance.add_mode_marker_hold = false
                        return true
                    end
                    return original_onHoldRelease(readerhighlight, ...)
                end
            end

            rawset(_G, "__pdftranslationpopup_readerhighlight_hook_v2_1", true)
        end
    end
end

function PdfTranslationPopup:_getEmojiImage(code, size)
    local key = code .. ":" .. size
    local cached = self.emoji_cache[key]
    if cached ~= nil then return cached or nil end
    local path = PLUGIN_DIR .. "/openmoji-black/" .. code .. ".svg"
    local ok, image = pcall(RenderImage.renderSVGImageFile, RenderImage, path, size, size)
    self.emoji_cache[key] = ok and image or false
    return self.emoji_cache[key] or nil
end

-- ReaderView view-module hook. V2 markers are painted by KOReader, not the PDF.
function PdfTranslationPopup:paintTo(bb, x, y)
    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf) then return end

    local diameter = math.max(4, math.floor(MARKER_DIAMETER))
    local radius = math.floor(diameter / 2)

    for _, page in ipairs(self:_getVisiblePages()) do
        for _, marker in ipairs(self:_getPageMarkers(page)) do
            -- V1 already contains its own baked circle. Painting only V2 avoids
            -- duplicate circles on older documents.
            if marker.version == 2 then
                local cx, cy = self:_markerScreenCenter(marker)
                if cx and cy then
                    local selected = (self.move_mode or self.add_mode)
                        and self.move_selected
                        and self.move_selected.key == marker.key
                    local emoji_size = Screen:scaleBySize(marker.emoji_size or 24)
                    local image = marker.emoji
                        and self:_getEmojiImage(marker.emoji, emoji_size)
                    if image then
                        local left = math.floor(x + cx - emoji_size / 2)
                        local top = math.floor(y + cy - emoji_size / 2)
                        bb:paintRoundedRect(left, top, emoji_size, emoji_size,
                            Blitbuffer.COLOR_WHITE, math.floor(emoji_size / 2))
                        bb:alphablitFrom(image, left, top, 0, 0, emoji_size, emoji_size)
                        if selected then
                            bb:paintBorder(left - 2, top - 2,
                                emoji_size + 4, emoji_size + 4,
                                MARKER_BORDER, Blitbuffer.COLOR_BLACK,
                                math.floor(emoji_size / 2) + 2)
                        end
                    elseif selected then
                        local left = math.floor(x + cx - radius)
                        local top = math.floor(y + cy - radius)
                        bb:paintRoundedRect(
                            left, top, diameter, diameter,
                            Blitbuffer.COLOR_BLACK, radius
                        )
                        local inner = math.max(2, math.floor(diameter / 3))
                        local inner_r = math.floor(inner / 2)
                        bb:paintRoundedRect(
                            math.floor(x + cx - inner_r),
                            math.floor(y + cy - inner_r),
                            inner, inner,
                            Blitbuffer.COLOR_WHITE, inner_r
                        )
                    else
                        local left = math.floor(x + cx - radius)
                        local top = math.floor(y + cy - radius)
                        bb:paintRoundedRect(
                            left, top, diameter, diameter,
                            Blitbuffer.COLOR_WHITE, radius
                        )
                        bb:paintBorder(
                            left, top, diameter, diameter,
                            MARKER_BORDER, Blitbuffer.COLOR_BLACK, radius
                        )
                    end
                end
            end
        end
    end
end

function PdfTranslationPopup:_toggleMoveMode()
    self.move_mode = not self.move_mode
    if self.move_mode then self.add_mode = false end
    self.move_selected = nil
    self:_setDirty("ui")
end

function PdfTranslationPopup:_toggleAddMode()
    self:_setAddMode(not self.add_mode)
end

function PdfTranslationPopup:_setAddMode(enabled)
    local entering = enabled and not self.add_mode
    self.add_mode = enabled
    if enabled then
        self:_activate()
        self.move_mode = false
        self.move_selected = nil
    end
    self.add_mode_marker_hold = false
    self:_setDirty("ui")
    if entering then
        UIManager:show(Notification:new{
            text = _("已进入添加圆点模式：点击 PDF 页面添加圆点。"),
            timeout = 2,
        })
    end
end

function PdfTranslationPopup:_setEmojiSize(size)
    self.emoji_size = size
    if self.ui and self.ui.doc_settings then
        self.ui.doc_settings:saveSetting(EMOJI_SIZE_SETTING, size)
    end
    self:_setDirty("ui")
end

function PdfTranslationPopup:_resetMarker(marker)
    if not marker or marker.version ~= 2 then return false end

    local has_pending = self.positions[marker.key] ~= nil
    local has_embedded = marker.embedded_x ~= nil and marker.embedded_y ~= nil
    local already_reset = self.dirty_positions[marker.key] == "reset"
    if not has_pending and not has_embedded and not already_reset then
        return false
    end

    self.positions[marker.key] = nil
    self.dirty_positions[marker.key] = "reset"
    return true
end

function PdfTranslationPopup:_resetVisiblePositions()
    local changed = false
    for _, page in ipairs(self:_getVisiblePages()) do
        for _, marker in ipairs(self:_getPageMarkers(page)) do
            if self:_resetMarker(marker) then
                changed = true
            end
        end
    end

    self.move_selected = nil
    if changed then
        self:_savePositions()
        self:_setDirty("ui")
    end
end

function PdfTranslationPopup:_resetAllPositions()
    local doc = self.ui and self.ui.document
    local page_count = doc and doc.info and doc.info.number_of_pages or 0
    local changed = false

    for page = 1, page_count do
        for _, marker in ipairs(self:_getPageMarkers(page)) do
            if self:_resetMarker(marker) then
                changed = true
            end
        end
    end

    self.move_selected = nil
    if changed then
        self:_savePositions()
        self:_setDirty("ui")
    end
end

function PdfTranslationPopup:addToMainMenu(menu_items)
    menu_items.pdftranslationpopup = {
        text = _("PDF 中文弹窗"),
        sorting_hint = "typeset",
        sub_item_table = {
            {
                text = _("圆点编辑模式"),
                checked_func = function()
                    return self.move_mode
                end,
                callback = function()
                    self:_toggleMoveMode()
                end,
            },
            {
                text = _("添加圆点模式"),
                checked_func = function()
                    return self.add_mode
                end,
                sub_item_table = {
                    {
                        text = _("进入／退出添加模式"),
                        checked_func = function() return self.add_mode end,
                        callback = function() self:_toggleAddMode() end,
                    },
                    {
                        text = _("自定义表情默认大小"),
                        sub_item_table = {
                            {
                                text = _("小（18）"),
                                checked_func = function() return self.emoji_size == EMOJI_SIZES[1] end,
                                callback = function() self:_setEmojiSize(EMOJI_SIZES[1]) end,
                            },
                            {
                                text = _("中（24）"),
                                checked_func = function() return self.emoji_size == EMOJI_SIZES[2] end,
                                callback = function() self:_setEmojiSize(EMOJI_SIZES[2]) end,
                            },
                            {
                                text = _("大（30）"),
                                checked_func = function() return self.emoji_size == EMOJI_SIZES[3] end,
                                callback = function() self:_setEmojiSize(EMOJI_SIZES[3]) end,
                            },
                        },
                    },
                },
            },
            {
                text = _("重置当前可见页的圆点位置"),
                callback = function()
                    self:_resetVisiblePositions()
                end,
            },
            {
                text = _("重置本书全部圆点位置"),
                callback = function()
                    self:_resetAllPositions()
                end,
                separator = true,
            },
            {
                text = _("说明"),
                keep_menu_open = true,
                callback = function()
                    self:_show(_(
                        "圆点编辑模式可以一直保持开启，不影响正常阅读。\n\n"
                        .. "• 短按圆点：正常打开翻译。\n"
                        .. "• 短按其他位置：仍由 KOReader 正常处理，例如翻页。\n"
                        .. "• 长按圆点：选中该圆点准备移动，圆点会变黑。\n"
                        .. "• 然后短按同一页的新位置：圆点和触摸区域一起移动。\n"
                        .. "• 编辑模式开启时，其他长按操作会被本插件禁用，以免误触文字选择、面板缩放等。\n\n"
                        .. "• 添加圆点模式：短按页面空白处输入注释内容，可用输入框下方的“表情…”按钮打开图标网格；保存或取消后自动退出。短按已有圆点可编辑其表情和文字。添加模式子菜单可设置新表情的默认大小。此模式下短按不会翻页。可将“PDF 中文弹窗：添加圆点”绑定到手势。PDF 必须可写；添加圆点还需关闭文字重排。\n\n"
                        .. "移动时会立即写入 sidecar，作为崩溃恢复用的待写日志。新增和修改的圆点在正常关闭 PDF 时与待写位置一起做一次增量写入。完成写入后，sidecar 的位置覆盖会被清除。如果 PDF 不可写或保存失败，sidecar 待写位置会保留。"
                    ))
                end,
            },
        },
    }
end

return PdfTranslationPopup
