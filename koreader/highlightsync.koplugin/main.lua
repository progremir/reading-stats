--[[--
Uploads each book's highlights to the reading stats server.

It reuses the WebDAV server configured for Reading statistics cloud sync and
PUTs one JSON file per book to <server folder>/highlights/<md5>.json, plus the
stock Kindle "My Clippings.txt" to <server folder>/highlights/clippings.txt.

Files are written to an outbox first, so highlights made offline are sent the
next time the Kindle is online.
--]]--

local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")

local OUTBOX = DataStorage:getSettingsDir() .. "/highlightsync_outbox"
local CLIPPINGS = "/mnt/us/documents/My Clippings.txt"
local STATS_INTERVAL = 30 * 60

local HighlightSync = WidgetContainer:extend{
    name = "highlightsync",
    is_doc_only = false,
}

local function server()
    local stats = G_reader_settings:readSetting("statistics")
    local sv = stats and stats.sync_server
    if not sv or sv.type ~= "webdav" or not sv.address then return end
    local base = sv.address:gsub("/+$", "") .. "/" .. (sv.url or ""):gsub("^/+", ""):gsub("/+$", "")
    return base:gsub("/+$", "") .. "/highlights", sv.username, sv.password
end

local function put(url, user, pass, body, content_type)
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request{
        url = url,
        method = "PUT",
        user = user,
        password = pass,
        source = ltn12.source.string(body),
        headers = { ["Content-Type"] = content_type, ["Content-Length"] = #body },
    })
    socketutil:reset_timeout()
    return type(code) == "number" and code >= 200 and code < 300
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return end
    local data = f:read("*a")
    f:close()
    return data
end

function HighlightSync:init()
    lfs.mkdir(OUTBOX)
    if NetworkMgr:isConnected() then
        self:scheduleFlush()
        self:scheduleStatsSync()
    end
end

-- Snapshot the open book's annotations into the outbox.
function HighlightSync:queueCurrentBook()
    local ok, err = pcall(self._queueCurrentBook, self)
    if not ok then logger.err("HighlightSync: queue failed:", err) end
end

function HighlightSync:_queueCurrentBook()
    local ui = self.ui
    if not (ui and ui.document and ui.annotation and ui.doc_settings) then
        logger.info("HighlightSync: no open book to queue")
        return
    end
    local md5 = ui.doc_settings:readSetting("partial_md5_checksum")
    if not md5 then
        logger.info("HighlightSync: book has no md5")
        return
    end
    local items = {}
    for _, a in ipairs(ui.annotation.annotations or {}) do
        if a.text and a.text ~= "" then
            table.insert(items, {
                text = a.text,
                note = a.note,
                chapter = a.chapter,
                datetime = a.datetime,
                datetime_updated = a.datetime_updated,
                pageno = a.pageno,
                color = a.color,
                drawer = a.drawer,
            })
        end
    end
    local props = ui.doc_props or {}
    local body, encode_err = rapidjson.encode({
        md5 = md5,
        title = props.display_title or props.title,
        authors = props.authors,
        file = ui.document.file and ui.document.file:match("([^/]+)$"),
        pages = ui.document:getPageCount(),
        highlights = items,
    })
    if not body then
        logger.err("HighlightSync: could not encode highlights:", encode_err)
        return
    end
    local path = OUTBOX .. "/" .. md5 .. ".json"
    logger.info("HighlightSync: queued", #items, "highlights for", md5)
    if read_file(path) == body then return end
    local f = io.open(path, "wb")
    if f then
        f:write(body)
        f:close()
    end
end

-- Send everything in the outbox (and changed clippings); keep what fails.
function HighlightSync:flush()
    local ok, err = pcall(self._flush, self)
    if not ok then logger.err("HighlightSync: flush failed:", err) end
end

function HighlightSync:_flush()
    local base, user, pass = server()
    if not base then
        logger.info("HighlightSync: no sync server set")
        return
    end
    if not NetworkMgr:isOnline() then
        logger.info("HighlightSync: offline, keeping outbox")
        return
    end
    for name in lfs.dir(OUTBOX) do
        if name:match("%.json$") then
            local path = OUTBOX .. "/" .. name
            local body = read_file(path)
            if body and put(base .. "/" .. name, user, pass, body, "application/json") then
                os.remove(path)
                logger.info("HighlightSync: uploaded", name)
            else
                logger.warn("HighlightSync: upload failed for", name)
                return
            end
        end
    end
    local mtime = lfs.attributes(CLIPPINGS, "modification")
    if mtime and mtime ~= G_reader_settings:readSetting("highlightsync_clippings_mtime") then
        local body = read_file(CLIPPINGS)
        if body and put(base .. "/clippings.txt", user, pass, body, "text/plain; charset=utf-8") then
            G_reader_settings:saveSetting("highlightsync_clippings_mtime", mtime)
        end
    end
end

-- Push reading statistics too, quietly, without waiting for a book to be closed.
function HighlightSync:syncStats()
    local stats = self.ui and self.ui.statistics
    if not (stats and stats:canSync() and NetworkMgr:isOnline()) then return end
    if self.ui.document then stats:insertDB() end
    self.ui.cloudstorage:sync(stats.settings.sync_server, DataStorage:getSettingsDir() .. "/statistics.sqlite3",
        stats.onSync, true)
end

function HighlightSync:scheduleStatsSync()
    UIManager:unschedule(self.stats_task)
    self.stats_task = self.stats_task or function()
        self:syncStats()
        UIManager:scheduleIn(STATS_INTERVAL, self.stats_task)
    end
    UIManager:scheduleIn(10, self.stats_task)
end

function HighlightSync:scheduleFlush()
    UIManager:unschedule(self.flush_task)
    self.flush_task = self.flush_task or function() self:flush() end
    UIManager:scheduleIn(5, self.flush_task)
end

function HighlightSync:onAnnotationsModified()
    self:queueCurrentBook()
    self:scheduleFlush()
end

function HighlightSync:onCloseDocument()
    self:queueCurrentBook()
    self:flush()
end

function HighlightSync:onSuspend()
    self:queueCurrentBook()
end

function HighlightSync:onNetworkConnected()
    self:scheduleFlush()
    self:scheduleStatsSync()
end

function HighlightSync:onCloseWidget()
    if self.flush_task then UIManager:unschedule(self.flush_task) end
    if self.stats_task then UIManager:unschedule(self.stats_task) end
end

return HighlightSync
