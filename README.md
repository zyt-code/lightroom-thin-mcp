# Lightroom Thin MCP

通过本地 Python 桥接，让 Agent 读取和调整 **Adobe Lightroom Classic 当前选中的照片**。图像处理与 JPEG 渲染由 Lightroom 完成，RAW 文件保留在本机。

这是一个实验性项目。已在 Windows + Lightroom Classic 15.5 上完成 NEF 全局调整、天空蒙版、对象蒙版、植被蒙版、线性渐变和 JPEG 导出的实际工作流验证。部分操作仍需在 Lightroom 面板里完成，尚不是全自动修图工具。

## 工作方式

```text
Agent / MCP 客户端
        │ stdio
        ▼
Python server.py ── 本机 HTTP 桥接 127.0.0.1:49888
        ▲
        │ /poll 获取指令，/reply 提交结果
        │
Lightroom Classic 插件 ── 当前照片 / Develop API / JPEG 导出
```

Lightroom 插件作为 HTTP 客户端主动轮询 Python，避免在 Lightroom 内使用原始 TCP 监听。

## 环境要求

- Adobe Lightroom **Classic**；不适用于云版 Lightroom。
- Python 3.10 或以上。Python 端仅使用标准库，无需安装 pip 依赖；实际运行使用 Python 3.12。
- 两端运行在同一台计算机上。
- 已在 Windows 上验证；macOS 安装路径和行为未验证。
- AI 蒙版能力取决于 Lightroom 版本。插件声明的 SDK 最低版本不代表旧版支持全部功能。

## 安装与启动

### 1. 获取项目

```powershell
git clone https://github.com/zyt-code/lightroom-thin-mcp.git
cd lightroom-thin-mcp
```

### 2. 安装 Lightroom 插件

在 Lightroom Classic 中打开 **文件 → 增效工具管理器（插件管理器）→ 添加**，选择项目里的：

```text
plugin/LightroomThin.lrplugin
```

保留完整 `.lrplugin` 文件夹。加载插件后，它会尝试启动轮询；也可以在管理器里点击 **启动服务**。

### 3. 启动 Python 桥接

独立 HTTP 模式适合先验证连接：

```powershell
python server.py --daemon
```

这个进程需要保持运行。关闭终端或按 Ctrl+C 会停止服务。无需另外启动旧版 Lua TCP 服务。

### 4. 打开照片并检查连接

在 Lightroom 中选中一张照片，进入 **修改照片 / Develop** 模块。

```powershell
Invoke-RestMethod http://127.0.0.1:49888/health
```

正常响应包含：

```json
{
  "status": "ok",
  "service": "lightroom-thin-mcp",
  "client_connected": true
}
```

`status: ok` 只说明 Python 桥接在线；`client_connected: true` 才说明近期收到 Lightroom 轮询。最终应通过一次 `get_current_photo` 确认实际调用正常。

**关闭 Lightroom 后，插件连接自然断开。** 再次打开 Lightroom 后检查插件是否启用；必要时在插件管理器点击启动服务。状态弹窗是打开时的快照，重新打开才能看到更新。

## MCP 接入与兼容性

默认运行 `python server.py` 会启动 stdio MCP 服务，并自动创建或复用本地 HTTP 桥接。客户端应启动以下命令，路径替换成自己的绝对路径：

```json
{
  "mcpServers": {
    "lightroom-thin": {
      "command": "python",
      "args": ["C:/path/to/lightroom-thin-mcp/server.py"]
    }
  }
}
```

**当前 stdio 实现使用 `Content-Length` 消息封装。** 客户端若要求逐行 JSON（JSON Lines），不能直接连接这版服务，需要适配传输层。这份配置只描述进程启动方式，不保证所有 MCP 客户端兼容。initialize 返回协议版本也不代表传输兼容性已经通过验证。

HTTP `/call` 是本地调试接口，不是标准 MCP Streamable HTTP 端点。

## 支持的 MCP 工具

| 工具 | 用途与边界 |
| --- | --- |
| `get_current_photo` | 当前照片文件名、路径和模块；每次修改前先确认目标 |
| `get_develop_settings` | 基础滑块及已有蒙版的名称、ID、组件和调整值；不返回完整全局设置 |
| `set_develop_settings` | 批量写入 Lightroom Develop 设置，如 Basic、HSL、曲线、Detail、Optics |
| `create_mask` | AI subject / sky / background / objects / people / landscape；范围蒙版 color / luminance / depth |
| `update_mask` | 按蒙版名称、组件名称或 CorrectionID 更新已有蒙版 |
| `add_to_mask` | 向面板中当前选中的蒙版添加组件 |
| `subtract_from_mask` | 从当前蒙版减去组件 |
| `intersect_mask` | 当前蒙版与另一组件相交 |
| `invert_mask` | 反相当前蒙版；取决于 SDK 暴露的 API |
| `create_linear_gradient` | 创建或更新同名线性渐变；已验证可渲染 |
| `create_radial_gradient` | 实验接口，当前版本未能生成有效径向选区，勿依赖其成功响应 |
| `export_preview` | 导出 sRGB JPEG，返回本机文件路径；长边 256–8000，默认 1600 |

`probe` 和 `delete_mask` 目前是 Lua/HTTP 调试方法，没有列入 MCP `tools/list`。

## 调用示例

读取当前照片：

```powershell
$body = @{
    method = 'get_current_photo'
    params = @{}
    timeout = 15
} | ConvertTo-Json -Depth 8

Invoke-RestMethod http://127.0.0.1:49888/call `
    -Method Post -ContentType 'application/json' -Body $body
```

确认目标后，写入全局参数（绝对值覆盖指定字段，不是增量）：

```json
{
  "method": "set_develop_settings",
  "params": {
    "settings": {
      "WhiteBalance": "Custom",
      "Temperature": 6550,
      "Tint": 7,
      "Exposure2012": 0.30,
      "Highlights2012": -42,
      "Shadows2012": 48,
      "Blacks2012": -18
    }
  }
}
```

更新已有天空蒙版：

```json
{
  "method": "update_mask",
  "params": {
    "name": "sky",
    "adjustments": {
      "exposure": -0.0375,
      "highlights": -15,
      "dehaze": 5,
      "saturation": 0
    }
  }
}
```

上述局部 `exposure: -0.0375` 对应本次验证的面板 **-0.15 EV**，原因见下方单位限制。全局 `Exposure2012` 不需要此补偿。

导出检查图：

```json
{
  "method": "export_preview",
  "params": { "long_edge": 1600 }
}
```

建议工作顺序：确认照片 → 记录当前参数 → 覆盖需要的全局字段 → 检查已有蒙版 → 创建或更新局部调整 → 导出 → 视觉验收 → 只修改有问题的区域。

## 已知限制

- **局部曝光单位不一致：** 当前插件把 `LocalExposure2012` 当作 EV 直接存储，但本次 Classic 验证中，面板曝光是存储值的四倍。因此当前版本局部曝光传参使用 `期望 EV / 4`，例如 +0.18 EV 传 0.045。读取结果也使用错误比例并四舍五入，不能直接当作面板 EV。务必核对 Lightroom 面板；其他版本需要重新确认。其余局部滑块一般按面板值 / 100 存储。
- **对象选择需要交互：** `objects` 只打开工具，不能接受对象名称或坐标。需要在 Lightroom 框选或涂抹后，再用新蒙版 ID 调整。
- **Landscape / People：** 可能停在选择面板。Landscape 需要勾选植被、建筑等区域并点击创建；工具超时后，选项面板可能仍然打开。
- **径向渐变未实现可靠渲染：** 本次调用返回成功，但 Lightroom 中组件消失、没有有效选区。应在 Lightroom UI 创建径向选区，然后调用 `update_mask`。
- **同名组件可能不唯一：** 多个对象选区可能都叫“对象 1”。优先使用 `CorrectionID`，避免更新错误蒙版。
- **部分操作依赖当前选区：** 加、减、交集和反相不会按名称选择目标，需要先在面板选中正确蒙版。
- **不自动重置原片：** `set_develop_settings` 仅覆盖提供的字段，其余曲线、裁剪、蒙版等可能继续生效。需要原片基准时，先检查现有设置。
- **配置文件必须核查：** 直接写入 Look 数据可能显示“配置文件缺失”。应从 Lightroom 自带列表选择可用配置文件，不能只靠名称判断已生效。
- **没有完整回滚接口：** 参数读取不是完整备份；重要照片建议先建虚拟副本或 Lightroom 快照。修改后可以使用 Lightroom 历史记录检查和撤销。
- **导出规格固定：** JPEG 质量 0.9、sRGB、不额外添加输出锐化。当前接口可能放大小尺寸照片，不是完整的导出设置管理器。
- **本地信任边界：** HTTP 桥接仅监听 127.0.0.1，没有认证。不要通过端口转发公开；本机其他进程可以调用该接口。

## 日志和输出

| 内容 | 位置 |
| --- | --- |
| Python 桥接日志 | `~/.config/lightroom-thin-mcp/bridge.log` |
| Lightroom 轮询日志 | `~/.config/lightroom-thin-mcp/client.log` |
| Windows JPEG 输出 | `%LOCALAPPDATA%/lightroom-thin-mcp/previews/<时间戳>/` |

日志可能包含照片路径或调整参数。分享诊断信息前检查内容。

## 自检

```powershell
python server.py --selftest
```

自检使用模拟 Lightroom 客户端验证参数校验、MCP 消息处理和 HTTP 指令往返，不需要打开 Lightroom。建议在独立环境运行，避免与正在调色的客户端争抢指令。**自检通过不代表 Lightroom SDK、AI 选区、实际渲染或所有 MCP 客户端兼容性通过验证。**

## 项目结构

```text
server.py                         Python stdio 服务与 HTTP 桥接
plugin/LightroomThin.lrplugin/     Lightroom Classic 插件
  Info.lua                        插件声明
  PluginInit.lua                  轮询初始化
  PluginInfoProvider.lua          管理器启动/停止/状态按钮
  Client.lua                      HTTP 轮询与指令分发
  Develop.lua                     当前照片、蒙版、导出操作
  Json.lua                        JSON 编解码
  ShowStatus.lua                  状态入口
```

项目只发布实现文件与文档，不包含 RAW、成片、个人调整记录或本机诊断输出。旧版 TCP 服务与个人探测脚本不属于本次发布内容。
