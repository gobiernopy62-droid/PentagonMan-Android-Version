-- =============================================================================
--  main.lua  PentagonMan (Love2D port)
--  Entry point, state machine, menús, assets globales, guardado
-- =============================================================================

local json            = require("libs/json")
local Controls        = require("controls")
local Map             = require("map")
local MobileControls  = require("mobile_controls")

-- ── Módulos del juego (se asignan en love.load para que assets ya estén listos)
local Player, Enemy, Boss, Level

-- ── Instancia de controles móviles (única, compartida entre todos los estados)
local mobileControls = nil

-- ── Resolución lógica ─────────────────────────────────────────────────────────
local LOGI_W, LOGI_H = 1280, 720
local gameCanvas

-- ── Estado global ─────────────────────────────────────────────────────────────
-- "menu" | "map" | "game" | "settings" | "credits"
local state = "menu"

-- ── Assets globales (accesibles desde todos los módulos vía parámetros) ───────
assets = {
    images = {},
    fonts  = {},
}

-- ── Controles ─────────────────────────────────────────────────────────────────
-- `controls` es global para que levels.lua, player.lua y map.lua lo lean.
-- Su inicialización la gestiona Controls.load(); ya no se define DEFAULT aquí.
controls = {}

-- ── Progreso ──────────────────────────────────────────────────────────────────
local completedLevels = {}  -- { ["Level 1"] = true, ... }
local levelList       = {}  -- { { name="Level 1", path="Levels/Level 1.json" }, ... }

-- ── Menú principal ────────────────────────────────────────────────────────────
local MENU_ITEMS   = { "Play", "Settings", "Credits", "Quit" }
local menuSelected = 1

-- ── Mapa overworld ────────────────────────────────────────────────────────────
local activeMap    = nil   -- instancia de Map
local savedMapWX   = nil   -- posición del jugador al volver de un nivel
local savedMapWY   = nil

-- ── Settings ─────────────────────────────────────────────────────────────────
local SETTINGS_ITEMS = {
    { label = "Move Left:",   key = "move_left"   },
    { label = "Move Right:",  key = "move_right"  },
    { label = "Move Up:",     key = "move_up"     },
    { label = "Move Down:",   key = "move_down"   },
    { label = "Jump:",        key = "jump"        },
}

-- Ajustes booleanos que se muestran como ON/OFF (no rebindeables)
local TOGGLE_ITEMS = {
    { label = "Mobile Controls:", key = "mobile_mode"  },
}
local settingsSelected = 1
local waitingForKey    = nil   -- nombre del control esperando rebind
local showFPS          = false

-- ── Partida activa ────────────────────────────────────────────────────────────
local activeLevel      = nil   -- instancia de Level
local activeLevelEntry = nil   -- { name, path } del nivel en curso

-- =============================================================================
--  HELPERS DE CANVAS
-- =============================================================================

-- Devuelve (offsetX, offsetY, scale) para centrar el canvas lógico en pantalla
local function getCanvasTransform()
    local sw, sh = love.graphics.getDimensions()
    local scale  = math.min(sw / LOGI_W, sh / LOGI_H)
    local ox     = math.floor((sw - LOGI_W * scale) / 2)
    local oy     = math.floor((sh - LOGI_H * scale) / 2)
    return ox, oy, scale
end

-- Convierte coordenadas físicas de pantalla a coordenadas lógicas del canvas
local function toLogical(px, py)
    local ox, oy, scale = getCanvasTransform()
    return (px - ox) / scale, (py - oy) / scale
end

-- =============================================================================
--  SAVE / LOAD
-- =============================================================================

-- saveControls / loadControls ahora delegan a controls.lua
local function saveControls()
    Controls.save()
end

local function loadControls()
    Controls.load()
end

local function saveProgress()
    local list = {}
    for name in pairs(completedLevels) do
        list[#list + 1] = name
    end
    love.filesystem.write("progress.json", json.encode(list))
end

local function loadProgress()
    completedLevels = {}
    if love.filesystem.getInfo("progress.json") then
        local raw = love.filesystem.read("progress.json")
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == "table" then
            for _, name in ipairs(data) do
                completedLevels[name] = true
            end
        end
    end
end

-- =============================================================================
--  ESCANEO DE NIVELES
-- =============================================================================

local function scanLevels()
    levelList = {}

    -- En Love2D el filesystem virtual monta el directorio del juego.
    -- getDirectoryItems devuelve tabla vacía (no error) si no existe.
    -- Verificamos con getInfo primero.
    local folderName = nil
    for _, candidate in ipairs({ "Levels", "levels" }) do
        local info = love.filesystem.getInfo(candidate)
        if info and info.type == "directory" then
            folderName = candidate
            break
        end
    end

    if not folderName then
        -- Último recurso: leer desde el sistema de archivos real con io
        local base = love.filesystem.getSourceBaseDirectory()
        local sep  = package.config:sub(1, 1)  -- \ en Windows, / en Unix
        local full = base .. sep .. "Levels"
        local ok, pipe = pcall(io.popen, (sep == "\\" and 'dir "' .. full .. '" /b 2>nul'
                                                          or 'ls "' .. full .. '" 2>/dev/null'))
        if ok and pipe then
            for line in pipe:lines() do
                if line:match("%.json$") then
                    local name = line:sub(1, -6)
                    levelList[#levelList + 1] = { name = name, path = full .. sep .. line }
                end
            end
            pipe:close()
        end
        if #levelList == 0 then
            print("[WARNING] No 'Levels' folder found next to main.lua")
            print("  Source dir: " .. base)
        end
        return
    end

    local items = love.filesystem.getDirectoryItems(folderName)
    table.sort(items)
    for _, fname in ipairs(items) do
        if fname:match("%.json$") then
            local name = fname:sub(1, -6)
            levelList[#levelList + 1] = {
                name = name,
                path = folderName .. "/" .. fname,
            }
        end
    end
    print("[scanLevels] " .. #levelList .. " level(s) found in '" .. folderName .. "'")
end

-- =============================================================================
--  CARGA DE ASSETS
-- =============================================================================

-- Carga una imagen; si no existe devuelve un pixel blanco de fallback.
-- FIX: dentro de un .love (ZIP) el filesystem es case-sensitive, por lo que
-- "Background.png" y "Background.PNG" son rutas distintas.  Intentamos primero
-- la ruta tal como está y, si falla, probamos el caso opuesto de la extensión
-- (.PNG ↔ .png) antes de rendirnos con el fallback magenta.
local function loadImage(path)
    if love.filesystem.getInfo(path) then
        return love.graphics.newImage(path)
    end

    -- Intentar extensión con caso opuesto
    local alt
    if path:match("%.PNG$") then
        alt = path:sub(1, -5) .. ".png"
    elseif path:match("%.png$") then
        alt = path:sub(1, -5) .. ".PNG"
    end
    if alt and love.filesystem.getInfo(alt) then
        return love.graphics.newImage(alt)
    end

    -- fallback: cuadrado magenta de 32x32
    local id = love.image.newImageData(32, 32)
    for y = 0, 31 do
        for x = 0, 31 do
            id:setPixel(x, y, 1, 0, 1, 1)
        end
    end
    return love.graphics.newImage(id)
end

local function loadAssets()
    -- ── Fuentes ──────────────────────────────────────────────────────────────
    assets.fonts.title   = love.graphics.newFont(52)
    assets.fonts.large   = love.graphics.newFont(36)
    assets.fonts.medium  = love.graphics.newFont(26)
    assets.fonts.small   = love.graphics.newFont(20)
    assets.fonts.tiny    = love.graphics.newFont(16)
    -- Fuente del overlay de game-over/victoria (cargada aquí una sola vez para
    -- evitar el crash en Android que ocurría al crearla dentro de Level.new()
    -- en cada entrada a un nivel, dejando texturas GPU sin liberar).
    assets.fonts.overlay = love.graphics.newFont(72)

    -- ── Menú principal ────────────────────────────────────────────────────────
    assets.images.menuBg   = loadImage("Assets/MainMenu/Background.png")
    assets.images.menuIcon = loadImage("Assets/MainMenu/Icon.png")

    -- ── Tiles (índice 0-7, mismo orden que pygame) ────────────────────────────
    local tileFiles = {
        [0] = "Grass.png",
        [1] = "Stone.png",
        [2] = "Dirt.png",
        [3] = "DeathBlock.png",
        [4] = "WaterSurface.png",
        [5] = "Waterfall.png",
        [6] = "Water.png",
        [7] = "Checkpoint.png",
    }
    assets.images.tiles = {}
    for idx, fname in pairs(tileFiles) do
        assets.images.tiles[idx] = loadImage("Assets/Platforms/" .. fname)
    end
    assets.images.checkpointActive = loadImage("Assets/Platforms/Checkpoint_Checkpointed.png")
    assets.images.door             = loadImage("Assets/Platforms/Door.png")

    -- ── Fondo por defecto ─────────────────────────────────────────────────────
    assets.images.skyBg = loadImage("Assets/Backgrounds/SkyBackground.PNG")

    -- ── Jugador  sprites individuales ────────────────────────────────────────
    local animPath = "Assets/Player/Animations/"
    assets.images.player = {
        Idle_Right = loadImage(animPath .. "Idle_Right.png"),
        Idle_Left  = loadImage(animPath .. "Idle_Left.png"),
        Walk_Right = loadImage(animPath .. "Walk_Right.png"),
        Walk_Left  = loadImage(animPath .. "Walk_Left.png"),
        Jump_Right = loadImage(animPath .. "Jump_Right.png"),
        Jump_Left  = loadImage(animPath .. "Jump_Left.png"),
        Victory    = loadImage(animPath .. "Victory.png"),
        head_normal  = loadImage(animPath .. "Head.png"),
        head_injured = loadImage(animPath .. "Injured.png"),
        head_dead    = loadImage(animPath .. "Dead.png"),
    }

    -- Spritesheet de muerte del jugador
    if love.filesystem.getInfo(animPath .. "PentagonManDeathAnimation.png") then
        assets.images.playerDeathSheet = love.graphics.newImage(animPath .. "PentagonManDeathAnimation.png")
        local raw = love.filesystem.read(animPath .. "PentagonManDeathAnimation.json")
        local ok, data = pcall(json.decode, raw)
        assets.data.playerDeathFrames = (ok and data) or nil
    end

    -- ── Enemigo ───────────────────────────────────────────────────────────────
    assets.images.enemy = loadImage("Assets/Enemies/Enemy.png")

    -- Spritesheet de muerte del enemigo
    if love.filesystem.getInfo("Assets/Enemies/DeadCircleAnimation.png") then
        assets.images.enemyDeathSheet = love.graphics.newImage("Assets/Enemies/DeadCircleAnimation.png")
        local raw = love.filesystem.read("Assets/Enemies/DeadCircleAnimation.json")
        local ok, data = pcall(json.decode, raw)
        assets.data.enemyDeathFrames = (ok and data) or nil
    end

    -- ── Boss ──────────────────────────────────────────────────────────────────
    local bossPath = "Assets/Enemies/Bosses/"
    assets.images.boss = {
        normal  = loadImage(bossPath .. "KingCircle.png"),
        injured = loadImage(bossPath .. "InjuredKingCircle.png"),
        dead    = loadImage(bossPath .. "DeadKingCircle.png"),
    }

    -- ── Spritesheet del jugador en el mapa overworld ──────────────────────────
    -- Se carga UNA SOLA VEZ aquí, dentro de love.load(), para que el contexto
    -- OpenGL esté en el estado correcto.  map.lua leerá estos datos desde
    -- assets en lugar de llamar a love.graphics.newImage() cada vez que se
    -- crea un Map (lo que causaba crash en Android en la segunda entrada).
    local mapSheetPath = "Assets/Player/Animations/PentagonManMap.png"
    local mapJsonPath  = "Assets/Player/Animations/PentagonManMap.json"
    assets.images.mapPlayerSheet = nil
    assets.data.mapPlayerFrames  = nil
    if love.filesystem.getInfo(mapSheetPath) and love.filesystem.getInfo(mapJsonPath) then
        local ok1, sheet = pcall(love.graphics.newImage, mapSheetPath)
        if ok1 then
            local raw2 = love.filesystem.read(mapJsonPath)
            local ok2, mapData = pcall(json.decode, raw2)
            if ok2 and type(mapData) == "table" then
                assets.images.mapPlayerSheet = sheet
                assets.data.mapPlayerFrames  = mapData
                print("[Assets] PentagonManMap spritesheet loaded.")
            else
                print("[Assets] Error parsing PentagonManMap.json.")
            end
        else
            print("[Assets] Error loading PentagonManMap.png: " .. tostring(sheet))
        end
    else
        print("[Assets] PentagonManMap spritesheet not found — map will use fallback sprite.")
    end
end

-- =============================================================================
--  DIBUJO DE UI  helpers reutilizables
-- =============================================================================

local function drawButton(text, font, cx, cy, w, h, hovered, pressed)
    local r, g, b
    if pressed      then r, g, b = 0.16, 0.40, 0.59
    elseif hovered  then r, g, b = 0.31, 0.68, 0.93
    else                 r, g, b = 0.22, 0.57, 0.84
    end
    love.graphics.setColor(r, g, b, 1)
    love.graphics.rectangle("fill", cx - w/2, cy - h/2, w, h, 10, 10)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(font)
    local tw = font:getWidth(text)
    local th = font:getHeight()
    love.graphics.print(text, cx - tw/2, cy - th/2)
end

local function drawShadowText(text, font, x, y, r, g, b)
    love.graphics.setFont(font)
    love.graphics.setColor(0, 0, 0, 0.7)
    love.graphics.print(text, x + 2, y + 2)
    love.graphics.setColor(r or 1, g or 1, b or 1, 1)
    love.graphics.print(text, x, y)
end

-- =============================================================================
--  PANTALLAS
-- =============================================================================

-- ── Menú principal  layout compartido entre draw e input ────────────────────

-- Devuelve { iconX, iconY, iconSc, topY, startY, BTN_W, BTN_H, cx }
-- Usar esta función SIEMPRE que se necesiten las coordenadas del menú,
-- tanto en draw como en los handlers de mouse, para que coincidan exactamente.
local function getMenuLayout()
    local icon   = assets.images.menuIcon
    local iconW  = math.min(180, icon:getWidth())
    local iconSc = iconW / icon:getWidth()
    local iconH  = icon:getHeight() * iconSc
    local iconX  = (LOGI_W - iconW) / 2
    local iconY  = 20
    local topY   = iconY + iconH + 14          -- primer texto debajo del ícono
    local startY = topY + 150                  -- primer botón (un poco más abajo)
    return {
        iconX  = iconX,  iconY  = iconY,
        iconSc = iconSc,
        topY   = topY,
        startY = startY,
        BTN_W  = 220, BTN_H = 52,
        BTN_GAP = 66,
        cx     = LOGI_W / 2,
    }
end

local function drawMenu(mx, my)
    local L = getMenuLayout()

    -- Fondo
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(assets.images.menuBg, 0, 0,
        0, LOGI_W / assets.images.menuBg:getWidth(),
           LOGI_H / assets.images.menuBg:getHeight())

    -- Ícono centrado
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(assets.images.menuIcon,
        L.iconX, L.iconY, 0, L.iconSc, L.iconSc)

    -- Títulos centrados (una sola vez, sin duplicados)
    local titles = {
        { text = "Welcome To",  font = assets.fonts.large, dy = 0  },
        { text = "PentagonMan", font = assets.fonts.title, dy = 46 },
    }
    for _, t in ipairs(titles) do
        local tw = t.font:getWidth(t.text)
        local tx = L.cx - tw / 2
        local ty = L.topY + t.dy
        love.graphics.setFont(t.font)
        love.graphics.setColor(0, 0, 0, 0.65)
        love.graphics.print(t.text, tx + 2, ty + 2)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.print(t.text, tx, ty)
    end

    -- Botones
    for i, label in ipairs(MENU_ITEMS) do
        local by      = L.startY + (i - 1) * L.BTN_GAP
        local hovered = menuSelected == i
        drawButton(label, assets.fonts.medium, L.cx, by, L.BTN_W, L.BTN_H, hovered, false)
    end
end

-- ── Settings ─────────────────────────────────────────────────────────────────

local function drawSettings(mx, my)
    love.graphics.setColor(0.12, 0.12, 0.24, 1)
    love.graphics.rectangle("fill", 0, 0, LOGI_W, LOGI_H)

    local title = "Settings"
    drawShadowText(title, assets.fonts.title,
        LOGI_W/2 - assets.fonts.title:getWidth(title)/2, 30)

    local BTN_W, BTN_H = 380, 50
    local cx     = LOGI_W / 2
    local startY = 140

    -- ── Bindings rebindeables ─────────────────────────────────────────────────
    for i, item in ipairs(SETTINGS_ITEMS) do
        local by      = startY + (i - 1) * 64
        local active  = settingsSelected == i
        local waiting = waitingForKey == item.key

        if waiting then
            love.graphics.setColor(1, 0.58, 0, 1)
        elseif active then
            love.graphics.setColor(0.31, 0.68, 0.93, 1)
        else
            love.graphics.setColor(0.22, 0.57, 0.84, 1)
        end
        love.graphics.rectangle("fill", cx - BTN_W/2, by - BTN_H/2, BTN_W, BTN_H, 8, 8)

        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setFont(assets.fonts.small)

        love.graphics.print(item.label, cx - BTN_W/2 + 12, by - assets.fonts.small:getHeight()/2)

        local val = waiting and "Press a key / button..."
                             or Controls.getBindingName(controls[item.key])
        local vw  = assets.fonts.small:getWidth(val)
        love.graphics.print(val, cx + BTN_W/2 - vw - 12, by - assets.fonts.small:getHeight()/2)
    end

    -- ── Toggles ON/OFF ────────────────────────────────────────────────────────
    local toggleStartY = startY + #SETTINGS_ITEMS * 64 + 12
    for i, item in ipairs(TOGGLE_ITEMS) do
        local by    = toggleStartY + (i - 1) * 64
        local tIdx  = #SETTINGS_ITEMS + i
        local active = settingsSelected == tIdx
        local val   = controls[item.key]

        love.graphics.setColor(active and 0.31 or 0.22,
                               active and 0.68 or 0.57,
                               active and 0.93 or 0.84, 1)
        love.graphics.rectangle("fill", cx - BTN_W/2, by - BTN_H/2, BTN_W, BTN_H, 8, 8)

        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setFont(assets.fonts.small)
        love.graphics.print(item.label, cx - BTN_W/2 + 12, by - assets.fonts.small:getHeight()/2)

        -- Valor coloreado: verde = ON, rojo = OFF
        local valStr = val and "ON" or "OFF"
        if val then love.graphics.setColor(0.30, 0.90, 0.30, 1)
        else        love.graphics.setColor(0.95, 0.30, 0.30, 1) end
        local vw = assets.fonts.small:getWidth(valStr)
        love.graphics.print(valStr, cx + BTN_W/2 - vw - 12, by - assets.fonts.small:getHeight()/2)
    end

    -- ── Botón Back ────────────────────────────────────────────────────────────
    local totalItems = #SETTINGS_ITEMS + #TOGGLE_ITEMS
    local backY   = toggleStartY + #TOGGLE_ITEMS * 64 + 12
    local backHov = settingsSelected == totalItems + 1
    love.graphics.setColor(1, 1, 1, 1)
    drawButton("Back", assets.fonts.medium, cx, backY, 180, 50, backHov, false)

    -- ── Instrucción ───────────────────────────────────────────────────────────
    love.graphics.setColor(0.7, 0.7, 0.7, 1)
    love.graphics.setFont(assets.fonts.tiny)
    love.graphics.print("Click / ENTER: rebind key   Move gamepad stick/button to rebind gamepad   ESC: back", 20, LOGI_H - 30)
end

-- ── Credits ───────────────────────────────────────────────────────────────────

local CREDITS_LINES = {
    { text = "Creator: Joaco",                           bold = true  },
    { text = "Programmer: TheNoSkillDev",                bold = false },
    { text = "Designer: TheNoSkillDev",                  bold = false },
    { text = "Level Designers: TheNoSkillDev and Joaco", bold = true  },
}

local function drawCredits()
    love.graphics.setColor(0.12, 0.12, 0.24, 1)
    love.graphics.rectangle("fill", 0, 0, LOGI_W, LOGI_H)

    drawShadowText("Credits", assets.fonts.title,
        LOGI_W/2 - assets.fonts.title:getWidth("Credits")/2, 60)

    local startY = LOGI_H / 4 + 40
    for i, line in ipairs(CREDITS_LINES) do
        local font  = line.bold and assets.fonts.large or assets.fonts.medium
        local color = line.bold and {1,1,1,1} or {0.75,0.75,0.75,1}
        love.graphics.setColor(unpack(color))
        love.graphics.setFont(font)
        local tw = font:getWidth(line.text)
        love.graphics.print(line.text, LOGI_W/2 - tw/2, startY + (i-1) * 68)
    end

    local backY = LOGI_H - 110
    drawButton("Back", assets.fonts.medium, LOGI_W/2, backY, 180, 50, true, false)
end

-- =============================================================================
--  FLUJO DE ESTADOS  transiciones
-- =============================================================================

local function enterGame(entry)
    if not entry then
        print("[ERROR] enterGame called with nil entry — no levels loaded?")
        return
    end
    activeLevelEntry = entry
    local Level = require("levels")
    activeLevel = Level.new(entry.path, entry.name, assets, controls, mobileControls)
    mobileControls:setGameMode()
    state = "game"
end

local function exitGame(completed)
    if completed and activeLevelEntry then
        completedLevels[activeLevelEntry.name] = true
        saveProgress()
        -- Actualizar el mapa con el nuevo progreso (por si hay nuevos nodos desbloqueados)
        if activeMap then
            activeMap.completedLevels = completedLevels
        end
    end
    activeLevel      = nil
    activeLevelEntry = nil
    -- Volver al mapa y restaurar posición del jugador
    if activeMap then
        activeMap:setStartPos(savedMapWX, savedMapWY)
        mobileControls:setMapMode()
        state = "map"
    else
        state = "menu"
    end
end

-- =============================================================================
--  LOVE2D  CALLBACKS PRINCIPALES
-- =============================================================================

function love.load()
    love.graphics.setDefaultFilter("linear", "linear")
    gameCanvas = love.graphics.newCanvas(LOGI_W, LOGI_H)

    -- Inicializar tabla de datos de assets antes de cargar
    assets.data = {}

    -- Cargar módulos
    Player = require("player")
    Enemy  = require("enemy")
    Boss   = require("boss")

    loadControls()
    loadProgress()
    scanLevels()
    loadAssets()

    -- Instanciar controles táctiles (una sola vez para toda la sesión)
    mobileControls = MobileControls.new()
end

-- ── Update ────────────────────────────────────────────────────────────────────

function love.update(dt)
    -- ── Mapa overworld ────────────────────────────────────────────────────────
    if state == "map" and activeMap then
        local result = activeMap:update(dt)
        if result == "back" then
            activeMap = nil
            state     = "menu"
        elseif type(result) == "table" then
            -- El jugador eligió un nivel desde el mapa
            savedMapWX = result.playerWX
            savedMapWY = result.playerWY
            enterGame({ name = result.name, path = result.path })
        end

    -- ── Nivel en juego ────────────────────────────────────────────────────────
    elseif state == "game" and activeLevel then
        local result = activeLevel:update(dt)
        -- result puede ser nil (sigue), "victory" o "exit"
        if result == "victory" then
            exitGame(true)
        elseif result == "exit" then
            exitGame(false)
        end

    -- ── Rebind de gamepad en Settings ─────────────────────────────────────────
    -- Se detecta en update() porque los ejes no disparan keypressed.
    elseif state == "settings" and waitingForKey then
        local detected = Controls.detectInput()
        if detected then
            controls[waitingForKey] = detected
            waitingForKey           = nil
            Controls.save()
        end
    end

    -- Avanzar prevState de los controles táctiles (necesario para justPressed)
    mobileControls:tick()
end

-- ── Draw ──────────────────────────────────────────────────────────────────────

function love.draw()
    local mx, my = toLogical(love.mouse.getPosition())

    -- Dibujar todo dentro del canvas lógico
    love.graphics.setCanvas(gameCanvas)
    love.graphics.clear(0.1, 0.1, 0.2, 1)

    if state == "menu" then
        drawMenu(mx, my)
    elseif state == "map" and activeMap then
        activeMap:draw()
    elseif state == "settings" then
        drawSettings(mx, my)
    elseif state == "credits" then
        drawCredits()
    elseif state == "game" and activeLevel then
        activeLevel:draw()
    end

    -- FPS
    if showFPS then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setFont(assets.fonts.small)
        local fps = "FPS: " .. love.timer.getFPS()
        love.graphics.print(fps, LOGI_W - assets.fonts.small:getWidth(fps) - 4, 4)
    end

    -- Escalar canvas a pantalla real
    love.graphics.setCanvas()
    love.graphics.clear(0, 0, 0, 1)

    local ox, oy, scale = getCanvasTransform()
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(gameCanvas, ox, oy, 0, scale, scale)
end

-- ── Teclado ───────────────────────────────────────────────────────────────────

function love.keypressed(key)
    -- F11: alternar pantalla completa
    if key == "f11" then
        local isFS = love.window.getFullscreen()
        love.window.setFullscreen(not isFS)
        return
    end

    -- Rebind de teclado en settings (gamepad se detecta en love.update)
    if state == "settings" and waitingForKey then
        controls[waitingForKey] = { type = "key", value = key }
        waitingForKey           = nil
        Controls.save()
        return
    end

    if state == "menu" then
        if key == "up" or key == "w" then
            menuSelected = ((menuSelected - 2) % #MENU_ITEMS) + 1
        elseif key == "down" or key == "s" then
            menuSelected = (menuSelected % #MENU_ITEMS) + 1
        elseif key == "return" or key == "space" then
            handleMenuAction(menuSelected)
        elseif key == "escape" then
            love.event.quit()
        end

    elseif state == "map" and activeMap then
        activeMap:keypressed(key)

    elseif state == "settings" then
        local totalItems = #SETTINGS_ITEMS + #TOGGLE_ITEMS + 1  -- +1 por Back
        if key == "up" or key == "w" then
            settingsSelected = ((settingsSelected - 2) % totalItems) + 1
        elseif key == "down" or key == "s" then
            settingsSelected = (settingsSelected % totalItems) + 1
        elseif key == "return" then
            if settingsSelected <= #SETTINGS_ITEMS then
                -- Rebind de tecla
                waitingForKey = SETTINGS_ITEMS[settingsSelected].key
            elseif settingsSelected <= #SETTINGS_ITEMS + #TOGGLE_ITEMS then
                -- Toggle ON/OFF
                local tIdx = settingsSelected - #SETTINGS_ITEMS
                local k    = TOGGLE_ITEMS[tIdx].key
                controls[k] = not controls[k]
                Controls.save()
            else
                state = "menu"  -- Back
            end
        elseif key == "escape" then
            state = "menu"
        end

    elseif state == "credits" then
        if key == "escape" or key == "return" or key == "space" then
            state = "menu"
        end

    elseif state == "game" and activeLevel then
        activeLevel:keypressed(key)
    end
end

-- ── Gamepad ───────────────────────────────────────────────────────────────────

function love.joystickpressed(joystick, button)
    if state == "map" and activeMap then
        activeMap:joystickpressed(joystick, button)

    elseif state == "game" and activeLevel then
        -- Pasar botón de gamepad al nivel como evento de back si corresponde
        if type(controls.back) == "table"
        and controls.back.type   == "button"
        and controls.back.value  == button then
            activeLevel:keypressed(controls.back.value)
        end

    elseif state == "menu" then
        if button == "a" or button == "start" then
            handleMenuAction(menuSelected)
        elseif button == "dpup"   then menuSelected = ((menuSelected - 2) % #MENU_ITEMS) + 1
        elseif button == "dpdown" then menuSelected = (menuSelected % #MENU_ITEMS) + 1
        end

    elseif state == "settings" then
        if button == "b" or button == "start" then state = "menu" end

    elseif state == "credits" then
        if button == "b" or button == "start" then state = "menu" end
    end
end

-- ── Mouse ─────────────────────────────────────────────────────────────────────

function love.mousepressed(px, py, button)
    -- Reenviar al overlay táctil solo si mobile_mode está activo
    if button == 1 and controls.mobile_mode
    and (state == "game" or state == "map") then
        mobileControls:onMousePressed(px, py)
    end

    if button ~= 1 then return end
    local mx, my = toLogical(px, py)

    if state == "settings" and waitingForKey then
        -- click cancela el rebind
        waitingForKey = nil
        return
    end

    if state == "menu" then
        local L = getMenuLayout()
        for i in ipairs(MENU_ITEMS) do
            local by = L.startY + (i - 1) * L.BTN_GAP
            if mx >= L.cx - L.BTN_W/2 and mx <= L.cx + L.BTN_W/2
            and my >= by - L.BTN_H/2  and my <= by + L.BTN_H/2  then
                menuSelected = i
                handleMenuAction(i)
                return
            end
        end

    elseif state == "settings" then
        local BTN_W, BTN_H = 380, 50
        local cx      = LOGI_W / 2
        local startY  = 140

        -- Rebind buttons
        for i, item in ipairs(SETTINGS_ITEMS) do
            local by = startY + (i - 1) * 64
            if mx >= cx - BTN_W/2 and mx <= cx + BTN_W/2
            and my >= by - BTN_H/2 and my <= by + BTN_H/2 then
                settingsSelected = i
                waitingForKey    = item.key
                return
            end
        end

        -- Toggle buttons
        local toggleStartY = startY + #SETTINGS_ITEMS * 64 + 12
        for i, item in ipairs(TOGGLE_ITEMS) do
            local by = toggleStartY + (i - 1) * 64
            if mx >= cx - BTN_W/2 and mx <= cx + BTN_W/2
            and my >= by - BTN_H/2 and my <= by + BTN_H/2 then
                settingsSelected = #SETTINGS_ITEMS + i
                controls[item.key] = not controls[item.key]
                Controls.save()
                return
            end
        end

        -- Back
        local backY = toggleStartY + #TOGGLE_ITEMS * 64 + 12
        if mx >= cx - 90 and mx <= cx + 90
        and my >= backY - 25 and my <= backY + 25 then
            state = "menu"
        end

    elseif state == "credits" then
        state = "menu"
    end
end

function love.mousemoved(px, py)
    -- Arrastre sobre botones táctiles (mobile testing)
    if controls.mobile_mode then
        mobileControls:onMouseMoved(px, py)
    end

    if state ~= "menu" then return end
    local mx, my = toLogical(px, py)
    local L = getMenuLayout()
    for i in ipairs(MENU_ITEMS) do
        local by = L.startY + (i - 1) * L.BTN_GAP
        if mx >= L.cx - L.BTN_W/2 and mx <= L.cx + L.BTN_W/2
        and my >= by - L.BTN_H/2  and my <= by + L.BTN_H/2  then
            menuSelected = i
            return
        end
    end
end

function love.mousereleased(px, py, button)
    if button == 1 and controls.mobile_mode then
        mobileControls:onMouseReleased()
    end
end

-- ── Touch (Android / SDL2) ────────────────────────────────────────────────────

function love.touchpressed(id, x, y, dx, dy, pressure)
    -- Si hay un rebind activo, cualquier toque lo cancela (un dedo no es
    -- un binding válido) y no se reenvía al overlay para evitar el crash.
    if waitingForKey then
        waitingForKey = nil
        return
    end
    if controls.mobile_mode then
        mobileControls:onTouchPressed(id, x, y)
    end
end

function love.touchreleased(id, x, y, dx, dy, pressure)
    if controls.mobile_mode then
        mobileControls:onTouchReleased(id, x, y)
    end
end

function love.touchmoved(id, x, y, dx, dy, pressure)
    if controls.mobile_mode then
        mobileControls:onTouchMoved(id, x, y)
    end
end

-- ── Resize ────────────────────────────────────────────────────────────────────

function love.resize(w, h)
    -- Nada que hacer; getCanvasTransform() recalcula en cada frame.
end

-- =============================================================================
--  ACCIONES DEL MENÚ
-- =============================================================================

function handleMenuAction(idx)
    local label = MENU_ITEMS[idx]
    if label == "Play" then
        if #levelList == 0 then scanLevels() end
        -- Crear (o reusar) el mapa overworld
        activeMap  = Map.new(levelList, completedLevels, assets, mobileControls)
        savedMapWX = nil
        savedMapWY = nil
        mobileControls:setMapMode()
        state      = "map"
    elseif label == "Settings" then
        settingsSelected = 1
        waitingForKey    = nil
        state = "settings"
    elseif label == "Credits" then
        state = "credits"
    elseif label == "Quit" then
        love.event.quit()
    end
end