local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"

local function sectionsForTopOfDialog(f, _)
    return {
        {
            title = "Lightroom Thin MCP",
            synopsis = "HTTP Client -> 127.0.0.1:49888",
            f:column {
                spacing = f:control_spacing(),
                f:static_text {
                    title = "Lightroom 保持打开并停在修改照片。插件作为 HTTP 客户端向本地 49888 端口轮询指令，无需在 Lightroom 监听端口。",
                    fill_horizontal = 1,
                    height_in_lines = 2,
                },
                f:row {
                    spacing = f:control_spacing(),
                    f:push_button {
                        title = "启动服务",
                        action = function()
                            LrFunctionContext.postAsyncTaskWithContext("LightroomThinStartButton", function(context)
                                local Client = dofile(_PLUGIN.path .. "/Client.lua")
                                Client.start(context)
                            end)
                        end,
                    },
                    f:push_button {
                        title = "停止服务",
                        action = function()
                            local Client = dofile(_PLUGIN.path .. "/Client.lua")
                            Client.stop()
                            LrDialogs.message("Lightroom Thin MCP", "已请求停止。")
                        end,
                    },
                    f:push_button {
                        title = "查看状态",
                        action = function()
                            local Client = dofile(_PLUGIN.path .. "/Client.lua")
                            Client.showStatus()
                        end,
                    },
                },
            },
        },
    }
end

return {
    sectionsForTopOfDialog = sectionsForTopOfDialog,
}
