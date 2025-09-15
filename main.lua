local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local DocumentRegistry = require("document/documentregistry")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local WebBrowser = WidgetContainer:extend{
    name = "webbrowser",
}

function WebBrowser:onDispatcherRegisterActions()
    Dispatcher:registerAction("web_open_url", { category = "none", event = "WebOpenUrl", title = _("Open URL…"), filemanager = true, general = true })
end

function WebBrowser:init()
    self:onDispatcherRegisterActions()
    -- Add to main menu in File Manager only
    if not self.ui.document then
        self.ui.menu:registerToMainMenu(self)
    end
    -- Inject a handler into ReaderLink for http(s) links
    self:injectReaderLinkHandler()
end

function WebBrowser:addToMainMenu(menu_items)
    if not self.ui.document then
        menu_items.web_open_url = {
            text = _("Open URL…"),
            sorting_hint = "more_tools",
            callback = function()
                self:onWebOpenUrl()
            end,
        }
    end
end

-- Tiny helper to fetch a URL with LuaSocket (synchronous, cancel-free).
local function fetch_url(url, timeout, maxtime)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    timeout = timeout or 15
    maxtime = maxtime or 30
    socketutil:set_timeout(timeout, maxtime)
    local chunks = {}
    local ok, code, headers, status = http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(chunks),
    }
    socketutil:reset_timeout()
    if not ok then
        return false, code or status or "request failed"
    end
    if code < 200 or code > 299 then
        return false, status or ("HTTP "..tostring(code))
    end
    return true, table.concat(chunks), headers
end

-- Very small asset discoverer: find src/href of images, stylesheets, scripts with absolute/relative URLs.
local function discover_assets(html)
    local assets = {}
    -- <img ... src="..."> or src='...'
    for src in html:gmatch("<img%s+[^>]-src%s*=%s*['\"]%s*(.-)%s*['\"]") do
        table.insert(assets, src)
    end
    -- <link rel="stylesheet" ... href="..."> or single-quoted
    for href in html:gmatch("<link[^>]-rel%s*=%s*['\"]%s*stylesheet%s*['\"][^>]-href%s*=%s*['\"]%s*(.-)%s*['\"]") do
        table.insert(assets, href)
    end
    -- <script ... src="..."> or src='...'
    for src in html:gmatch("<script[^>]-src%s*=%s*['\"]%s*(.-)%s*['\"]") do
        table.insert(assets, src)
    end
    return assets
end

local function resolve_url(base_url, ref)
    local urlmod = require("socket.url")
    local parsed_base = urlmod.parse(base_url)
    local parsed_ref = urlmod.parse(ref)
    if not parsed_ref.scheme then
        -- Relative URL; build absolute
        parsed_ref = urlmod.parse(urlmod.absolute(base_url, ref))
    end
    return urlmod.build(parsed_ref)
end

local function ensure_dir(path)
    -- Delegate to the platform utility; silently ignore errors here.
    pcall(util.makePath, path)
end

local function dirname(path)
    local dir = path:match("(.+)/[^/]+$")
    return dir or ""
end

-- Save a string to file
local function write_file(path, data)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write(data)
    f:close()
    return true
end

-- Escape a string for use as a Lua pattern (so gsub/find treat it literally)
local function escape_pattern(s)
    return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- Compute relative path from a directory to a target absolute path
local function relative_path(from_dir, to_path)
    if not from_dir or not to_path then return to_path end
    -- Split into path components, ignoring leading '/'
    local function split(path)
        local t = {}
        for part in path:gmatch("[^/]+") do table.insert(t, part) end
        return t
    end
    local a = split(from_dir)
    local b = split(to_path)
    -- Find common prefix length
    local i = 1
    while i <= #a and i <= #b and a[i] == b[i] do i = i + 1 end
    -- Build "../" segments to go up from from_dir to common parent
    local ups = #a - (i - 1)
    local prefix = ups > 0 and string.rep("../", ups) or ""
    -- Build tail to descend to target
    local tail = table.concat(b, "/", i)
    if tail == "" then
        return prefix ~= "" and prefix:sub(1, -2) or "./"
    end
    return prefix .. tail
end

-- Rewrite relative <a href> links to absolute URLs, honoring <base href> if present
local function rewrite_relative_links_to_absolute(html, page_url)
    local urlmod = require("socket.url")
    -- Honor <base href="..."> if present (best-effort, lowercase match)
    local base_href = html:match("<base%s+[^>]-href%s*=%s*['\"]%s*(.-)%s*['\"]")
    local base = page_url
    if base_href and base_href ~= "" then
        if urlmod.parse(base_href).scheme then
            base = base_href
        else
            base = urlmod.absolute(page_url, base_href)
        end
    end

    local function is_relative_link(href)
        if not href or href == "" then return false end
        if href:sub(1, 1) == "#" then return false end -- in-page anchors
        if href:match("^[%w][%w%+%-.]*:") then return false end -- has scheme
        return true
    end

    -- Replace href values in <a ... href="..."> with absolute URLs when they are relative
    html = html:gsub("(<a%s+[^>]-href%s*=%s*['\"])%s*(.-)%s*([\"'])", function(pre, href, closeq)
        if is_relative_link(href) then
            local abs = urlmod.absolute(base, href)
            return pre .. abs .. closeq
        else
            return pre .. href .. closeq
        end
    end)

    return html
end

-- Map a URL to a cache file path relative to base_dir.
local function url_to_cache_path(base_dir, url)
    local urlmod = require("socket.url")
    local parsed = urlmod.parse(url)
    -- Build path: host/path, ensure no query/fragment in filename.
    local host = parsed.host or "_"
    local path = parsed.path or "/"
    -- Normalize directory ending; if ends with '/', name it index.html/png/etc depending on content-type later.
    if path:sub(-1) == "/" then
        path = path .. "index"
    end
    local clean = (host .. path):gsub("[^%w%._%-%/]", "_")
    return base_dir .. "/" .. clean
end

-- Best-effort content-type to extension mapping
local function ext_for_content_type(ct)
    if not ct then return "" end
    ct = ct:lower()
    if ct:find("text/html") or ct:find("application/xhtml") then return ".html" end
    if ct:find("text/css") then return ".css" end
    if ct:find("javascript") then return ".js" end
    if ct:find("image/png") then return ".png" end
    if ct:find("image/jpeg") then return ".jpg" end
    if ct:find("image/gif") then return ".gif" end
    if ct:find("image/webp") then return ".webp" end
    if ct:find("image/svg") then return ".svg" end
    return ""
end

-- Fetch URL and assets, save under cache, return main HTML file path.
function WebBrowser:fetchAndStore(url)
    local base_cache = DataStorage:getDataDir() .. "/cache/web"
    ensure_dir(base_cache)

    -- Fetch main document
    local ok, body, headers = fetch_url(url)
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("Failed fetching URL") .. "\n" .. tostring(body) })
        return nil
    end

    -- Discover assets
    local assets = discover_assets(body)

    -- Store main HTML
    local html_path_base = url_to_cache_path(base_cache, url)
    local html_ext = ".html"
    local main_html_path = html_path_base .. html_ext
    local main_dir = dirname(main_html_path)
    if main_dir ~= "" then ensure_dir(main_dir) end
    write_file(main_html_path, body)

    -- Download assets best-effort
    for _, ref in ipairs(assets) do
        local abs = resolve_url(url, ref)
        local a_ok, a_body, a_headers = fetch_url(abs, 10, 20)
        if a_ok and a_body then
            local asset_base = url_to_cache_path(base_cache, abs)
            local ext = ext_for_content_type(a_headers and a_headers["content-type"])
            local asset_path = asset_base .. ext
            local asset_dir = dirname(asset_path)
            if asset_dir ~= "" then ensure_dir(asset_dir) end
            local okw = write_file(asset_path, a_body)
            if not okw then
                logger.warn("Failed writing asset", asset_path)
            end
            -- Update references in main HTML from abs URL and original ref to a path relative to the HTML file
            local rel = relative_path(main_dir, asset_path)
            body = body:gsub(escape_pattern(abs), rel)
            body = body:gsub(escape_pattern(ref), rel)
        end
    end

    -- Rewrite relative <a href> links to absolute http(s)
    body = rewrite_relative_links_to_absolute(body, url)

    -- Re-save main HTML with rewritten asset URLs and links
    write_file(main_html_path, body)
    UIManager:show(InfoMessage:new{ text = _("Saved page to cache"), timeout = 1.5 })
    return main_html_path
end

function WebBrowser:onWebOpenUrl()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Open URL"),
        input_hint = _("Enter a URL (http/https)"),
        input = "https://example.org/",
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(input_dialog) end },
                { text = _("Open"), callback = function()
                    local url = input_dialog:getInputValue()
                    UIManager:close(input_dialog)
                    if not url or url == "" then return end
                    if not (url:match("^https?://")) then
                        url = "http://" .. url
                    end
                    local html_file = self:fetchAndStore(url)
                    if html_file then
                        -- Force MuPDF provider to render HTML
                        local mupdf_provider = DocumentRegistry:getProviderFromKey("mupdf")
                        if self.ui.document then
                            self.ui:showReader(html_file, mupdf_provider, true, true)
                        else
                            -- FileManager context
                            self.ui:openFile(html_file, mupdf_provider)
                        end
                    end
                end },
            }
        }
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

-- Add a button in the external link dialog to open via this plugin, staying inside KOReader
function WebBrowser:injectReaderLinkHandler()
    -- ReaderLink is only instantiated inside ReaderUI. Inject lazily on next tick if available.
    UIManager:nextTick(function()
        if self.ui and self.ui.link and self.ui.link.addToExternalLinkDialog then
            self.ui.link:addToExternalLinkDialog("35_open_here_mupdf", function(this, link_url)
                return {
                    text = _("Open here (MuPDF)"),
                    callback = function()
                        UIManager:close(this.external_link_dialog)
                        local url = link_url
                        if not (url and url:match("^https?://")) then return end
                        local html_file = self:fetchAndStore(url)
                        if html_file then
                            local mupdf_provider = DocumentRegistry:getProviderFromKey("mupdf")
                            self.ui:showReader(html_file, mupdf_provider, true, true)
                        end
                    end,
                    show_in_dialog_func = function()
                        return link_url and link_url:match("^https?://") and true or false
                    end,
                }
            end)
        end
    end)
end

return WebBrowser
