-- HTTP Long-Polling client for Lightroom Thin MCP.
-- Lightroom acts as an HTTP client, polling the local Python MCP server.
-- This completely avoids opening raw TCP server sockets on Windows.

local LrDialogs = import "LrDialogs"
local LrHttp = import "LrHttp"
local LrLogger = import "LrLogger"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"

local Json = dofile(_PLUGIN.path .. "/Json.lua")
local Develop = dofile(_PLUGIN.path .. "/Develop.lua")

local BASE_URL = "http://127.0.0.1:49888"
local POLL_URL = BASE_URL .. "/poll"
local REPLY_URL = BASE_URL .. "/reply"

local HEADERS = {
    { field = "Content-Type", value = "application/json" },
    { field = "User-Agent", value = "LightroomThinMCP/2.0" },
}

local log = LrLogger("LightroomThinMCP")
log:enable("logfile")

-- Persist state across dofile() reloads
if not _G.LightroomThinClientState then
    _G.LightroomThinClientState = {
        running = false,
        connected = false,
        lastSeen = 0,
        requestCount = 0,
    }
end
local state = _G.LightroomThinClientState

local Client = {}

local function homeDir()
    return LrPathUtils.getStandardFilePath("home")
end

local function configDir()
    return LrPathUtils.child(LrPathUtils.child(homeDir(), ".config"), "lightroom-thin-mcp")
end

local function note(line)
    local dir = configDir()
    local LrFileUtils = import "LrFileUtils"
    if not LrFileUtils.exists(dir) then
        pcall(function() LrFileUtils.createAllDirectories(dir) end)
    end
    local path = LrPathUtils.child(dir, "client.log")
    local handle = io.open(path, "ab")
    if not handle then
        return
    end
    handle:write(os.date("!%H:%M:%S ") .. tostring(line) .. "\n")
    handle:close()
end

local function dispatch(request)
    local Develop = dofile(_PLUGIN.path .. "/Develop.lua")
    local method = request.method
    local params = request.params or {}
    local ok, result, failure
    if method == "get_current_photo" then
        result, failure = Develop.currentPhoto()
        ok = failure == nil
    elseif method == "get_develop_settings" then
        result, failure = Develop.developSettings()
        ok = failure == nil
    elseif method == "create_mask" then
        result, failure = Develop.createMask(params.mask_type, params.subtype, params.adjustments)
        ok = failure == nil
    elseif method == "update_mask" then
        result, failure = Develop.updateMask(params.name, params.adjustments)
        ok = failure == nil
    elseif method == "add_to_mask" then
        result, failure = Develop.addToMask(params.mask_type, params.subtype)
        ok = failure == nil
    elseif method == "subtract_from_mask" then
        result, failure = Develop.subtractFromMask(params.mask_type, params.subtype)
        ok = failure == nil
    elseif method == "intersect_mask" then
        result, failure = Develop.intersectMask(params.mask_type, params.subtype)
        ok = failure == nil
    elseif method == "invert_mask" then
        result, failure = Develop.invertMask()
        ok = failure == nil
    elseif method == "create_linear_gradient" then
        result, failure = Develop.createLinearGradient(params)
        ok = failure == nil
    elseif method == "create_radial_gradient" then
        result, failure = Develop.createRadialGradient(params)
        ok = failure == nil
    elseif method == "export_preview" then
        result, failure = Develop.exportPreview(params.long_edge)
        ok = failure == nil
    elseif method == "set_develop_settings" then
        result, failure = Develop.setDevelopSettings(params.settings or params)
        ok = failure == nil
    elseif method == "delete_mask" then
        result, failure = Develop.deleteMask(params.name)
        ok = failure == nil
    elseif method == "probe" then
        result = Develop.probeDump()
        ok = true
    else
        ok = false
        failure = "未知方法 " .. tostring(method)
    end
    if ok and result == nil and failure == nil then
        failure = "没有返回结果"
        ok = false
    end
    return ok, result, failure
end

function Client.start(context)
    if state.running then
        note("Client.start ignored, already running")
        return
    end
    state.running = true
    note("Client.start starting HTTP worker loop...")

    if context and type(context.addCleanupHandler) == "function" then
        context:addCleanupHandler(function()
            state.running = false
            state.connected = false
            note("Client context cleanup handler executed")
        end)
    end

    local pollBody = Json.encode({
        client = "LightroomClassic",
        version = "2.0",
        api = Develop.apiSurface(),
    })

    while state.running do
        local callOk, responseBody, responseHeaders = LrTasks.pcall(function()
            return LrHttp.post(POLL_URL, pollBody, HEADERS, "POST", 15)
        end)

        note("poll iter callOk=" .. tostring(callOk) .. " len=" .. tostring(responseBody and string.len(responseBody) or 0) .. " body=" .. tostring(responseBody))

        if callOk and responseBody and responseBody ~= "" then
            state.connected = true
            state.lastSeen = os.time()
            local decOk, cmd = pcall(function()
                return Json.decode(responseBody)
            end)
            if decOk and type(cmd) == "table" then
                if cmd.method and cmd.id then
                    state.requestCount = state.requestCount + 1
                    note("Dispatching cmd: " .. tostring(cmd.method) .. " id: " .. tostring(cmd.id))

                    local dispOk, ok, result, err = LrTasks.pcall(dispatch, cmd)
                    if not dispOk then
                        ok = false
                        result = nil
                        err = "Lightroom 运行时异常: " .. tostring(ok)
                    end
                    note("Dispatch finished: ok=" .. tostring(ok) .. " err=" .. tostring(err))

                    local replyBody = Json.encode({
                        id = cmd.id,
                        ok = ok,
                        result = result,
                        error = err,
                    })
                    LrTasks.pcall(function()
                        LrHttp.post(REPLY_URL, replyBody, HEADERS, "POST", 5)
                    end)
                    note("Reply posted for id: " .. tostring(cmd.id))
                end
                -- If cmd.wait == true or after reply, loop continues
            else
                note("JSON decode failed: " .. tostring(cmd))
            end
        else
            state.connected = false
            -- Server offline or waiting; sleep 1s
            LrTasks.sleep(1)
        end
    end

    state.connected = false
    note("Client.start loop exited")
end

function Client.stop()
    state.running = false
    state.connected = false
    note("Client.stop requested")
end

function Client.showStatus()
    local api = Develop.apiSurface()
    local lines = {
        "Lightroom Thin MCP (HTTP Mode)",
        "Server: " .. BASE_URL,
        "Running: " .. tostring(state.running),
        "Connected to Python: " .. tostring(state.connected),
        "Requests Handled: " .. tostring(state.requestCount),
        "Last Seen: " .. tostring(state.lastSeen),
        "--- Supported Develop APIs ---",
    }
    for name, kind in pairs(api) do
        lines[#lines + 1] = name .. " = " .. kind
    end
    LrDialogs.message("Lightroom Thin MCP", table.concat(lines, "\n"))
end

function Client.getStatus()
    return state
end

return Client
