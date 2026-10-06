local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrTasks = import "LrTasks"

LrFunctionContext.postAsyncTaskWithContext("LightroomThinMCP", function(context)
    LrTasks.sleep(0.5)
    local ok, err = LrTasks.pcall(function()
        local Client = dofile(_PLUGIN.path .. "/Client.lua")
        Client.start(context)
    end)
    if not ok then
        LrDialogs.message("Lightroom Thin MCP", tostring(err))
    end
end)
