local LrFunctionContext = import "LrFunctionContext"
local LrTasks = import "LrTasks"

local Client = dofile(_PLUGIN.path .. "/Client.lua")

-- Stop any previous loop to ensure the latest Client code runs
Client.stop()

LrFunctionContext.postAsyncTaskWithContext("LightroomThinStatus", function(context)
    LrTasks.sleep(0.2)
    Client.start(context)
end)

Client.showStatus()
