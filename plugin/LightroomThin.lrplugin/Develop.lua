-- Current-photo develop and mask operations.
-- Slider numbers on the wire are the panel numbers. Stored Local* values are
-- not: exposure is EV, and the other local sliders are panel/100.
-- createNewMask must not run inside catalog:withWriteAccessDo; that rolls it back.

local LrApplication = import "LrApplication"
local LrApplicationView = import "LrApplicationView"
local LrDevelopController = import "LrDevelopController"
local LrExportSession = import "LrExportSession"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrTasks = import "LrTasks"
local LrUUID = import "LrUUID"

local Develop = {}

local STORED = {
    exposure = { key = "LocalExposure2012", scale = 1 },
    contrast = { key = "LocalContrast2012", scale = 0.01 },
    highlights = { key = "LocalHighlights2012", scale = 0.01 },
    shadows = { key = "LocalShadows2012", scale = 0.01 },
    whites = { key = "LocalWhites2012", scale = 0.01 },
    blacks = { key = "LocalBlacks2012", scale = 0.01 },
    texture = { key = "LocalTexture", scale = 0.01 },
    clarity = { key = "LocalClarity2012", scale = 0.01 },
    dehaze = { key = "LocalDehaze", scale = 0.01 },
    saturation = { key = "LocalSaturation", scale = 0.01 },
    temperature = { key = "LocalTemperature", scale = 0.01 },
    tint = { key = "LocalTint", scale = 0.01 },
    sharpness = { key = "LocalSharpness", scale = 0.01 },
}

local GLOBAL = {
    "Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012",
    "Whites2012", "Blacks2012", "Texture", "Clarity2012", "Dehaze",
    "Vibrance", "Saturation", "Temperature", "Tint",
}

-- MaskSubType 1 is subject, 2 is the sky mask on this Classic 15.5 catalog.
local SUBTYPE_NUMBER = { subject = 1, sky = 2 }

local NAME_HINTS = {
    sky = { "天空", "sky" },
    subject = { "主体", "subject" },
    background = { "背景", "background" },
}

local AI_SUBTYPES = {
    subject = true, sky = true, background = true,
    objects = true, people = true, landscape = true,
}

local RANGE_SUBTYPES = { color = true, luminance = true, depth = true }

local function roundTo(value, places)
    local factor = 10 ^ places
    return math.floor(value * factor + 0.5) / factor
end

local function toUI(stored, scale)
    if scale == 1 then
        return roundTo(stored, 2)
    end
    return roundTo(stored / scale, 0)
end

local function toStored(ui, scale)
    return ui * scale
end

local function applyAdjustments(group, adjustments)
    if type(adjustments) ~= "table" then
        return nil
    end
    for name, ui in pairs(adjustments) do
        local spec = STORED[name]
        if not spec then
            return "未知滑块 " .. tostring(name)
        end
        if type(ui) ~= "number" then
            return name .. " 必须是数字"
        end
        group[spec.key] = toStored(ui, spec.scale)
    end
    return nil
end

local function adjustmentsOf(group)
    local ui = {}
    local stored = {}
    for name, spec in pairs(STORED) do
        local value = group[spec.key]
        if type(value) == "number" then
            ui[name] = toUI(value, spec.scale)
            stored[name] = value
        end
    end
    return ui, stored
end

local function asArray(items)
    return setmetatable(items, { json = "array" })
end

local function maskSummary(group)
    local components = asArray({})
    for _, mask in ipairs(group.CorrectionMasks or {}) do
        components[#components + 1] = {
            name = mask.MaskName,
            what = mask.What,
            subtype = mask.MaskSubType,
            inverted = mask.MaskInverted == true,
            active = mask.MaskActive ~= false,
        }
    end
    local ui, stored = adjustmentsOf(group)
    return {
        name = group.CorrectionName,
        id = group.CorrectionID,
        active = group.CorrectionActive ~= false,
        components = components,
        adjustments = ui,
        stored = stored,
    }
end

local function groupsOf(settings)
    return settings.MaskGroupBasedCorrections or {}
end

local function findGroup(groups, wanted)
    if type(wanted) ~= "string" or wanted == "" then
        return nil
    end
    local needle = string.lower(wanted)
    for index, group in ipairs(groups) do
        if group.CorrectionName == wanted or string.lower(tostring(group.CorrectionName or "")) == needle then
            return group, index
        end
        if group.CorrectionID == wanted then
            return group, index
        end
        for _, mask in ipairs(group.CorrectionMasks or {}) do
            if mask.MaskName == wanted or string.lower(tostring(mask.MaskName or "")) == needle then
                return group, index
            end
        end
    end
    return nil
end

local function nameMatches(maskName, hints)
    local text = string.lower(tostring(maskName or ""))
    for _, hint in ipairs(hints) do
        if string.find(text, string.lower(hint), 1, true) then
            return true
        end
    end
    return false
end

local function findExistingAI(groups, subtype)
    local hints = NAME_HINTS[subtype]
    local number = SUBTYPE_NUMBER[subtype]
    for index, group in ipairs(groups) do
        for _, mask in ipairs(group.CorrectionMasks or {}) do
            if number and mask.MaskSubType == number then
                return group, index
            end
            if hints and nameMatches(mask.MaskName, hints) then
                return group, index
            end
        end
        if hints and nameMatches(group.CorrectionName, hints) then
            return group, index
        end
    end
    return nil
end

-- withReadAccessDo / withWriteAccessDo keep only the callback's first return.
-- A second return such as nil, "找不到蒙版" has to be stored outside the callback.
-- error() inside the write gate would also pop a dialog, so failures just return.

local function readPhoto(fn)
    local catalog = LrApplication.activeCatalog()
    local result, failure
    local callOk, callErr = LrTasks.pcall(function()
        catalog:withReadAccessDo(function()
            local photo = catalog:getTargetPhoto()
            if not photo then
                failure = "没有当前照片"
                return
            end
            local value, err = fn(photo, catalog)
            if err then
                failure = err
                return
            end
            result = value
        end)
    end)
    if failure then
        return nil, failure
    end
    if not callOk then
        return nil, tostring(callErr)
    end
    return result
end

local function writePhoto(title, fn)
    local catalog = LrApplication.activeCatalog()
    local result, failure
    local callOk, callErr = LrTasks.pcall(function()
        catalog:withWriteAccessDo(title, function()
            local photo = catalog:getTargetPhoto()
            if not photo then
                failure = "没有当前照片"
                return
            end
            local value, err = fn(photo, catalog)
            if err then
                failure = err
                return
            end
            result = value
        end)
    end)
    if failure then
        return nil, failure
    end
    if not callOk then
        return nil, tostring(callErr)
    end
    return result
end

local function ensureDevelop()
    if LrApplicationView.getCurrentModuleName() ~= "develop" then
        LrApplicationView.switchToModule("develop")
        LrTasks.sleep(0.5)
    end
    if type(LrDevelopController.goToMasking) == "function" then
        pcall(function()
            LrDevelopController.goToMasking()
        end)
    end
end

local function syncId()
    return (LrUUID.generateUUID():gsub("-", ""))
end

function Develop.apiSurface()
    local names = {
        "createNewMask", "addToCurrentMask", "subtractFromCurrentMask",
        "intersectWithCurrentMask", "invertMask", "invertCurrentMask",
        "toggleInvertMask", "goToMasking", "deleteMask", "selectMask",
        "getSelectedMask", "getSelectedMaskTool",
    }
    local found = {}
    for _, name in ipairs(names) do
        found[name] = type(LrDevelopController[name])
    end
    return found
end

function Develop.currentPhoto()
    return readPhoto(function(photo)
        return {
            filename = photo:getFormattedMetadata("fileName"),
            path = photo:getRawMetadata("path"),
            module = LrApplicationView.getCurrentModuleName(),
            in_develop = LrApplicationView.getCurrentModuleName() == "develop",
        }
    end)
end

function Develop.developSettings()
    return readPhoto(function(photo)
        local settings = photo:getDevelopSettings()
        local global = {}
        for _, key in ipairs(GLOBAL) do
            local value = settings[key]
            if type(value) == "number" then
                global[key] = value
            end
        end
        local masks = asArray({})
        for _, group in ipairs(groupsOf(settings)) do
            masks[#masks + 1] = maskSummary(group)
        end
        return {
            filename = photo:getFormattedMetadata("fileName"),
            module = LrApplicationView.getCurrentModuleName(),
            global = global,
            masks = masks,
        }
    end)
end

local function saveGroups(photo, groups)
    photo:applyDevelopSettings({ MaskGroupBasedCorrections = groups })
end

local function updateGroup(name, adjustments)
    if type(adjustments) ~= "table" then
        return nil, "adjustments 必须是对象"
    end
    return writePhoto("Thin MCP update mask", function(photo)
        local settings = photo:getDevelopSettings()
        local groups = groupsOf(settings)
        local group = findGroup(groups, name)
        if not group then
            return nil, "找不到蒙版 " .. tostring(name)
        end
        local problem = applyAdjustments(group, adjustments)
        if problem then
            return nil, problem
        end
        saveGroups(photo, groups)
        return { updated = true, mask = maskSummary(group) }
    end)
end

local ALIAS = {
    sky = "sky",
    subject = "subject",
    background = "background",
    ["天空"] = "sky",
    ["主体"] = "subject",
    ["背景"] = "background",
}

function Develop.updateMask(name, adjustments)
    local alias = ALIAS[tostring(name or "")] or ALIAS[string.lower(tostring(name or ""))]
    if alias then
        local existing
        readPhoto(function(photo)
            local group = findExistingAI(groupsOf(photo:getDevelopSettings()), alias)
            if group then
                existing = group.CorrectionID or group.CorrectionName
            end
        end)
        if existing then
            name = existing
        end
    end
    local result, failure = updateGroup(name, adjustments)
    if failure then
        return nil, failure
    end
    if result == nil then
        return nil, "找不到蒙版 " .. tostring(name)
    end
    return result
end

-- os.clock is process CPU time and does not move during LrTasks.sleep.
local function waitForNewGroup(beforeIds, timeoutSec)
    local steps = math.max(1, math.floor(timeoutSec / 0.3))
    for _ = 1, steps do
        LrTasks.sleep(0.3)
        local found
        readPhoto(function(photo)
            local settings = photo:getDevelopSettings()
            for index, group in ipairs(groupsOf(settings)) do
                local id = group.CorrectionID or ("idx" .. index)
                if not beforeIds[id] then
                    found = group.CorrectionID or group.CorrectionName
                end
            end
        end)
        if found then
            LrTasks.sleep(0.4)
            return found
        end
    end
    return nil
end

local function idsNow()
    local ids = {}
    readPhoto(function(photo)
        local settings = photo:getDevelopSettings()
        for index, group in ipairs(groupsOf(settings)) do
            ids[group.CorrectionID or ("idx" .. index)] = true
        end
    end)
    return ids
end

function Develop.createMask(maskType, subtype, adjustments)
    if maskType == "gradient" or maskType == "radialGradient" or maskType == "brush" then
        return nil, maskType .. " 只是拿起工具。线性渐变用 create_linear_gradient。"
    end
    local sdkType, sdkSubtype
    if maskType == "aiSelection" then
        if not AI_SUBTYPES[subtype] then
            return nil, "aiSelection 的 subtype 必须是 subject、sky、background、objects、people、landscape"
        end
        sdkType, sdkSubtype = "aiSelection", subtype
    elseif maskType == "rangeMask" then
        if not RANGE_SUBTYPES[subtype] then
            return nil, "rangeMask 的 subtype 必须是 color、luminance、depth"
        end
        sdkType, sdkSubtype = "rangeMask", subtype
    else
        return nil, "未知 mask_type " .. tostring(maskType)
    end

    if AI_SUBTYPES[subtype] and NAME_HINTS[subtype] then
        local existingName
        readPhoto(function(photo)
            local group = findExistingAI(groupsOf(photo:getDevelopSettings()), subtype)
            if group then
                existingName = group.CorrectionName
                for _, mask in ipairs(group.CorrectionMasks or {}) do
                    if mask.MaskName then
                        existingName = mask.MaskName
                        break
                    end
                end
            end
        end)
        if existingName then
            if type(adjustments) == "table" then
                local updated, failure = updateGroup(existingName, adjustments)
                if failure then
                    return nil, failure
                end
                updated.reused = true
                updated.name = existingName
                return updated
            end
            return { reused = true, name = existingName }
        end
    end

    ensureDevelop()
    local before = idsNow()
    local called, callErr = pcall(function()
        LrDevelopController.createNewMask(sdkType, sdkSubtype)
    end)
    if not called then
        return nil, "createNewMask 失败: " .. tostring(callErr)
    end

    local timeout = 60
    if subtype == "objects" or maskType == "rangeMask" then
        timeout = 2
    elseif subtype == "people" or subtype == "landscape" then
        timeout = 20
    end
    local createdId = waitForNewGroup(before, timeout)
    if not createdId then
        if subtype == "objects" then
            return {
                armed = true,
                message = "选择对象已打开，但没有生成蒙版。这个接口不能指定白塔的位置。",
            }
        end
        if maskType == "rangeMask" then
            return {
                armed = true,
                message = "范围蒙版工具已打开，但没有采样点，所以没有生成蒙版。",
            }
        end
        if subtype == "people" or subtype == "landscape" then
            return nil, "等待蒙版超时。people 或 landscape 可能停在选项上，没有生成蒙版。"
        end
        return nil, "等待蒙版超时，没有新蒙版出现"
    end

    if type(adjustments) == "table" then
        local updated, failure = updateGroup(createdId, adjustments)
        if failure then
            return nil, failure
        end
        updated.created = true
        return updated
    end
    local summary
    readPhoto(function(photo)
        local group = findGroup(groupsOf(photo:getDevelopSettings()), createdId)
        if group then
            summary = maskSummary(group)
        end
    end)
    return { created = true, mask = summary }
end

function Develop.createLinearGradient(params)
    params = params or {}
    -- Full at the bottom edge, zero near 0.45: bottom quarter stays strong,
    -- and the fade runs well up into the frame so there is no hard line.
    local fullX = params.full_x or 0.5
    local fullY = params.full_y or 1
    local zeroX = params.zero_x or 0.5
    local zeroY = params.zero_y or 0.45
    local name = params.name or "线性渐变 1"
    for _, value in ipairs({ fullX, fullY, zeroX, zeroY }) do
        if type(value) ~= "number" or value < 0 or value > 1 then
            return nil, "渐变坐标必须在 0 到 1。Y 从画面顶部往下增加。"
        end
    end
    ensureDevelop()
    return writePhoto("Thin MCP linear gradient", function(photo)
        local settings = photo:getDevelopSettings()
        local groups = groupsOf(settings)
        local group = findGroup(groups, name)
        local created = false
        if not group then
            created = true
            group = {
                What = "Correction",
                CorrectionActive = true,
                CorrectionAmount = 1,
                CorrectionID = LrUUID.generateUUID(),
                CorrectionName = name,
                CorrectionSyncID = syncId(),
                CorrectionReferenceX = fullX,
                CorrectionReferenceY = fullY,
                LocalCurveRefineSaturation = 100,
                CorrectionMasks = {
                    {
                        MaskActive = true,
                        MaskBlendMode = 0,
                        MaskInverted = false,
                        MaskName = name,
                        MaskID = LrUUID.generateUUID(),
                        MaskSyncID = syncId(),
                        MaskValue = 1,
                        MaskVersion = 1,
                        What = "Mask/Gradient",
                        ZeroX = zeroX,
                        ZeroY = zeroY,
                        FullX = fullX,
                        FullY = fullY,
                    },
                },
            }
            groups[#groups + 1] = group
        else
            local gradient
            for _, mask in ipairs(group.CorrectionMasks or {}) do
                if mask.What == "Mask/Gradient" then
                    gradient = mask
                    break
                end
            end
            if not gradient then
                return nil, name .. " 不是线性渐变"
            end
            gradient.ZeroX = zeroX
            gradient.ZeroY = zeroY
            gradient.FullX = fullX
            gradient.FullY = fullY
            group.CorrectionReferenceX = fullX
            group.CorrectionReferenceY = fullY
        end
        local problem = applyAdjustments(group, params.adjustments or {})
        if problem then
            return nil, problem
        end
        saveGroups(photo, groups)
        return {
            created = created,
            updated = not created,
            mask = maskSummary(group),
            geometry = { full_x = fullX, full_y = fullY, zero_x = zeroX, zero_y = zeroY },
        }
    end)
end

function Develop.createRadialGradient(params)
    local centerX = params.center_x or 0.5
    local centerY = params.center_y or 0.45
    local radiusX = params.radius_x or 0.18
    local radiusY = params.radius_y or 0.18
    local feather = params.feather or 80
    local name = params.name or "径向渐变 1"
    for _, value in ipairs({ centerX, centerY, radiusX, radiusY }) do
        if type(value) ~= "number" or value < 0 or value > 1 then
            return nil, "径向渐变坐标必须在 0 到 1。"
        end
    end
    local top = math.max(0, centerY - radiusY)
    local bottom = math.min(1, centerY + radiusY)
    local left = math.max(0, centerX - radiusX)
    local right = math.min(1, centerX + radiusX)
    ensureDevelop()
    return writePhoto("Thin MCP radial gradient", function(photo)
        local settings = photo:getDevelopSettings()
        local groups = groupsOf(settings)
        local group = findGroup(groups, name)
        local created = false
        if not group then
            created = true
            group = {
                What = "Correction",
                CorrectionActive = true,
                CorrectionAmount = 1,
                CorrectionID = LrUUID.generateUUID(),
                CorrectionName = name,
                CorrectionSyncID = syncId(),
                CorrectionReferenceX = centerX,
                CorrectionReferenceY = centerY,
                LocalCurveRefineSaturation = 100,
                CorrectionMasks = {
                    {
                        MaskActive = true,
                        MaskBlendMode = 0,
                        MaskInverted = false,
                        MaskName = name,
                        MaskID = LrUUID.generateUUID(),
                        MaskSyncID = syncId(),
                        MaskValue = 1,
                        MaskVersion = 1,
                        What = "Mask/CircularGradient",
                        Top = top,
                        Bottom = bottom,
                        Left = left,
                        Right = right,
                        Angle = 0,
                        Midpoint = 50,
                        Feather = feather,
                    },
                },
            }
            groups[#groups + 1] = group
        else
            local circle
            for _, mask in ipairs(group.CorrectionMasks or {}) do
                if mask.What == "Mask/CircularGradient" then
                    circle = mask
                    break
                end
            end
            if not circle then
                return nil, name .. " 不是径向渐变"
            end
            circle.Top = top
            circle.Bottom = bottom
            circle.Left = left
            circle.Right = right
            circle.Feather = feather
            group.CorrectionReferenceX = centerX
            group.CorrectionReferenceY = centerY
        end
        local problem = applyAdjustments(group, params.adjustments or {})
        if problem then
            return nil, problem
        end
        saveGroups(photo, groups)
        return {
            created = created,
            updated = not created,
            mask = maskSummary(group),
            geometry = { center_x = centerX, center_y = centerY, radius_x = radiusX, radius_y = radiusY, feather = feather },
        }
    end)
end

local function componentOp(which, maskType, subtype)
    local method = LrDevelopController[which]
    if type(method) ~= "function" then
        return nil, which .. " 在这版 SDK 里不存在"
    end
    ensureDevelop()
    local ok, err = pcall(function()
        if subtype and subtype ~= "" then
            method(maskType, subtype)
        else
            method(maskType)
        end
    end)
    if not ok then
        return nil, which .. " 失败: " .. tostring(err)
    end
    return {
        ok = true,
        op = which,
        note = "作用在蒙版面板里当前选中的蒙版上。",
    }
end

function Develop.addToMask(maskType, subtype)
    return componentOp("addToCurrentMask", maskType, subtype)
end

function Develop.subtractFromMask(maskType, subtype)
    return componentOp("subtractFromCurrentMask", maskType, subtype)
end

function Develop.intersectMask(maskType, subtype)
    return componentOp("intersectWithCurrentMask", maskType, subtype)
end

function Develop.invertMask()
    ensureDevelop()
    local names = { "invertMask", "invertCurrentMask", "toggleInvertMask" }
    for _, name in ipairs(names) do
        local method = LrDevelopController[name]
        if type(method) == "function" then
            local ok, err = pcall(method)
            if ok then
                return { ok = true, method = name }
            end
            return nil, name .. " 失败: " .. tostring(err)
        end
    end
    return nil, "这版 SDK 没有 invertMask、invertCurrentMask 或 toggleInvertMask"
end

function Develop.exportPreview(longEdge)
    longEdge = longEdge or 1600
    if type(longEdge) ~= "number" or longEdge < 256 or longEdge > 8000 then
        return nil, "long_edge 必须在 256 到 8000"
    end
    local dir = LrPathUtils.getStandardFilePath("home")
    for _, part in ipairs({ "AppData", "Local", "lightroom-thin-mcp", "previews", tostring(os.time()) }) do
        dir = LrPathUtils.child(dir, part)
    end
    LrFileUtils.createAllDirectories(dir)
    local photo
    readPhoto(function(item)
        photo = item
    end)
    if not photo then
        return nil, "没有当前照片"
    end
    local settings = {
        LR_format = "JPEG",
        LR_jpeg_quality = 0.9,
        LR_export_bitDepth = 8,
        LR_export_colorSpace = "sRGB",
        LR_export_destinationType = "specificFolder",
        LR_export_destinationPathPrefix = dir,
        LR_export_useSubfolder = false,
        LR_collisionHandling = "overwrite",
        LR_reimportExportedPhoto = false,
        LR_renamingTokensOn = false,
        LR_size_doConstrain = true,
        LR_size_doNotEnlarge = false,
        LR_size_maxWidth = longEdge,
        LR_size_maxHeight = longEdge,
        LR_size_resizeType = "longEdge",
        LR_size_units = "pixels",
        LR_outputSharpeningOn = false,
        LR_minimizeEmbeddedMetadata = true,
        LR_exportServiceProvider = "com.adobe.ag.export.file",
    }
    local session = LrExportSession({
        photosToExport = { photo },
        exportSettings = settings,
    })
    session:doExportOnCurrentTask()
    local rendition
    local r = session:renditions()
    if type(r) == "function" then
        for _, rend in r do
            rendition = rend
            break
        end
    elseif type(r) == "table" then
        rendition = r[1]
    end
    if not rendition then
        return nil, "未能获取 rendition"
    end
    local success, pathOrMessage = rendition:waitForRender()
    if success then
        return { path = pathOrMessage }
    end
    local found
    for file in LrFileUtils.files(dir) do
        if string.lower(file):sub(-4) == ".jpg" then
            found = file
            break
        end
    end
    if found then
        return { path = found, render_message = tostring(pathOrMessage) }
    end
    return nil, "导出失败: " .. tostring(pathOrMessage)
end

function Develop.setDevelopSettings(settings)
    if type(settings) ~= "table" then
        return nil, "settings 必须是对象"
    end
    return writePhoto("Thin MCP set develop settings", function(photo)
        photo:applyDevelopSettings(settings)
        return { applied = true }
    end)
end

function Develop.deleteMask(name)
    if type(name) ~= "string" or name == "" then
        return nil, "name 必须是蒙版名称或ID"
    end
    return writePhoto("Thin MCP delete mask", function(photo)
        local settings = photo:getDevelopSettings()
        local groups = groupsOf(settings)
        local group, index = findGroup(groups, name)
        if not group then
            return nil, "找不到蒙版 " .. tostring(name)
        end
        table.remove(groups, index)
        saveGroups(photo, groups)
        return { deleted = true, name = name }
    end)
end

function Develop.probeDump()
    local catalog = LrApplication.activeCatalog()
    local allKeys = {}
    local sample = {}
    catalog:withReadAccessDo(function()
        local photo = catalog:getTargetPhoto()
        if photo then
            local ds = photo:getDevelopSettings()
            for k, v in pairs(ds) do
                allKeys[#allKeys + 1] = k
                if type(v) ~= "table" then
                    sample[k] = v
                elseif k == "Look" then
                    sample[k] = v
                end
            end
        end
    end)
    table.sort(allKeys)
    return {
        keys = allKeys,
        sample = sample,
    }
end

return Develop
