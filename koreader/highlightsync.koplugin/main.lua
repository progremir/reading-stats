--[[--
Uploads each book's highlights to the Readstreak server, and downloads the
books sent to the e-reader from its website.

It reuses the WebDAV server configured for Reading statistics cloud sync and
PUTs one JSON file per book to <server folder>/highlights/<md5>.json, plus the
stock Kindle "My Clippings.txt" to <server folder>/highlights/clippings.txt.

Files are written to an outbox first, so highlights made offline are sent the
next time the Kindle is online.

Books sent from the website wait in <server folder>/inbox/. Whenever the
e-reader is online (and from the Tools menu) each one is downloaded into an
Inbox folder in the home folder, then deleted from the server.
--]]--

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
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
local _ = require("gettext")
local T = require("ffi/util").template

local OUTBOX = DataStorage:getSettingsDir() .. "/highlightsync_outbox"
local CLIPPINGS = "/mnt/us/documents/My Clippings.txt"
local STATS_INTERVAL = 30 * 60

local HighlightSync = WidgetContainer:extend{
    name = "highlightsync",
    is_doc_only = false,
}

-- The WebDAV folder statistics.sqlite3 syncs to; highlights/ and inbox/ live in it.
local function server()
    local stats = G_reader_settings:readSetting("statistics")
    local sv = stats and stats.sync_server
    if not sv or sv.type ~= "webdav" or not sv.address then return end
    local base = sv.address:gsub("/+$", "") .. "/" .. (sv.url or ""):gsub("^/+", ""):gsub("/+$", "")
    return (base:gsub("/+$", "")), sv.username, sv.password
end

local function request(t)
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request(t))
    socketutil:reset_timeout()
    return type(code) == "number" and code >= 200 and code < 300, code
end

local function url_escape(name)
    return (name:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function url_unescape(s)
    s = s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- The files in a WebDAV folder, as { name = ..., size = ... }.
local function list_folder(url, user, pass)
    local chunks = {}
    local ok, code = request{
        url = url,
        method = "PROPFIND",
        user = user,
        password = pass,
        headers = { ["Depth"] = "1", ["Content-Length"] = "0" },
        sink = ltn12.sink.table(chunks),
    }
    if not ok then return nil, code end
    local files = {}
    for entry in table.concat(chunks):gmatch("<%w*:?response>(.-)</%w*:?response>") do
        local href = entry:match("<%w*:?href>%s*(.-)%s*</%w*:?href>")
        local name = href and not href:match("/$") and url_unescape(href:match("([^/]+)$") or "")
        if name and name ~= "" and not name:match("^%.") then
            table.insert(files, { name = name, size = tonumber(entry:match("<%w*:?getcontentlength>%s*(%d+)")) })
        end
    end
    return files
end

local function inbox_folder()
    local home = G_reader_settings:readSetting("home_dir")
    if not home then
        local ok, util = pcall(require, "apps/filemanager/filemanagerutil")
        home = ok and util.getDefaultDir and util.getDefaultDir()
    end
    return (home or DataStorage:getDataDir()):gsub("/+$", "") .. "/Inbox"
end

-- Where a book named `name` should go: its own name, unless another file already has it.
local function free_path(dir, name)
    local stem, ext = name:match("^(.*)(%.[^.]+)$")
    stem, ext = stem or name, ext or ""
    local path, n = dir .. "/" .. name, 1
    while lfs.attributes(path, "mode") do
        n = n + 1
        path = string.format("%s/%s (%d)%s", dir, stem, n, ext)
    end
    return path
end

local function put(url, user, pass, body, content_type)
    return (request{
        url = url,
        method = "PUT",
        user = user,
        password = pass,
        source = ltn12.source.string(body),
        headers = { ["Content-Type"] = content_type, ["Content-Length"] = #body },
    })
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
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    if NetworkMgr:isConnected() then
        self:scheduleFlush()
        self:scheduleStatsSync()
    end
end

function HighlightSync:addToMainMenu(menu_items)
    menu_items.highlightsync_inbox = {
        text = _("Get books sent from the web"),
        sorting_hint = "tools",
        callback = function()
            NetworkMgr:runWhenOnline(function() self:fetchInbox(true) end)
        end,
    }
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
    local root, user, pass = server()
    if not root then
        logger.info("HighlightSync: no sync server set")
        return
    end
    local base = root .. "/highlights"
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

-- Download the books waiting in the server's inbox, deleting each from the server once it's here.
-- `interactive` (from the menu) also says when there's nothing new or something went wrong.
function HighlightSync:fetchInbox(interactive)
    local ok, err = pcall(self._fetchInbox, self, interactive)
    if not ok then
        logger.err("HighlightSync: inbox failed:", err)
        if interactive then UIManager:show(InfoMessage:new{ text = _("Could not get the books sent from the web.") }) end
    end
end

function HighlightSync:_fetchInbox(interactive)
    local root, user, pass = server()
    if not root or not NetworkMgr:isOnline() then
        if interactive then UIManager:show(InfoMessage:new{ text = _("Set up Reading statistics cloud sync first.") }) end
        return
    end
    local base = root .. "/inbox/"
    local files, code = list_folder(base, user, pass)
    if not files then
        -- 404: the server has no inbox folder because nothing was ever sent.
        if code ~= 404 then logger.warn("HighlightSync: could not list inbox:", code) end
        if interactive then
            UIManager:show(InfoMessage:new{
                text = code == 404 and _("No new books.")
                    or code == 401 and _("The server didn't accept this e-reader's password.")
                    or _("Could not reach the server."),
                timeout = 3,
            })
        end
        return
    end
    if #files == 0 then
        if interactive then UIManager:show(InfoMessage:new{ text = _("No new books."), timeout = 3 }) end
        return
    end
    local dir = inbox_folder()
    lfs.mkdir(dir)
    local got = {}
    for _i, f in ipairs(files) do  -- not `_`, which is gettext here
        local url = base .. url_escape(f.name)
        local path = dir .. "/" .. f.name
        -- Already here from a run whose delete didn't reach the server: just delete it again.
        if not (f.size and lfs.attributes(path, "size") == f.size) then
            path = free_path(dir, f.name)
            local part = path .. ".part"
            local out = io.open(part, "wb")
            local ok = out and request{ url = url, user = user, password = pass, sink = ltn12.sink.file(out) }
            local size = lfs.attributes(part, "size")
            if not ok or (f.size and size ~= f.size) or not os.rename(part, path) then
                os.remove(part)
                logger.warn("HighlightSync: could not download", f.name)
                break
            end
            table.insert(got, path:match("([^/]+)$"))
            logger.info("HighlightSync: downloaded", f.name, "to", path)
        end
        if not request{ url = url, method = "DELETE", user = user, password = pass } then
            logger.warn("HighlightSync: could not delete", f.name, "from the server")
        end
    end
    if #got == 0 then
        if interactive then UIManager:show(InfoMessage:new{ text = _("Could not download the books. Try again later."), timeout = 3 }) end
        return
    end
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then FileManager.instance:onRefresh() end
    UIManager:show(InfoMessage:new{
        text = T(_("New in Inbox:\n%1"), table.concat(got, "\n")),
        timeout = 5,
    })
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
        self:fetchInbox()
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
