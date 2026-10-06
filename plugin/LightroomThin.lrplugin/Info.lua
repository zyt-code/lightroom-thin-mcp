return {
    LrSdkVersion = 8.0,
    LrSdkMinimumVersion = 8.0,
    LrToolkitIdentifier = "com.zhang.lightroom-thin-mcp",
    LrPluginName = "Lightroom Thin MCP",
    LrPluginInfoProvider = "PluginInfoProvider.lua",
    LrInitPlugin = "PluginInit.lua",
    LrForceInitPlugin = true,
    LrLibraryMenuItems = {
        {
            title = "Thin MCP Status",
            file = "ShowStatus.lua",
        },
    },
    LrDevelopMenuItems = {
        {
            title = "Thin MCP Status",
            file = "ShowStatus.lua",
        },
    },
    VERSION = { major = 0, minor = 1, revision = 0 },
}
