-- =============================================================================
--  map.lua  PentagonMan (Love2D port)
--  Mapa overworld: el jugador camina entre nodos de nivel, con cámara suave,
--  animación del sprite, detección de proximidad y entrada al nivel.
--
--  Puerto fiel de Map.py, adaptado al paradigma de módulo de Love2D
--  (sin bucle propio: usa update/draw/keypressed igual que levels.lua).
--
--  USO EN main.lua:
--    local Map = require("map")
--
--    -- Al entrar al estado "map":
--    activeMap = Map.new(levelList, completedLevels, assets)
--    activeMap:setStartPos(savedWX, savedWY)  -- opcional al volver de un nivel
--    state = "map"
--
--    -- En love.update(dt):
--    if state == "map" and activeMap then
--        local result = activeMap:update(dt)
--        if result == "back" then
--            activeMap = nil
--            state = "menu"
--        elseif type(result) == "table" then
--            -- result = { name, path, playerWX, playerWY }
--            savedWX = result.playerWX
--            savedWY = result.playerWY
--            enterGame(result)   -- tu función existente
--            state = "game"
--        end
--    end
--
--    -- En love.draw():
--    if state == "map" and activeMap then
--        activeMap:draw()
--    end
--
--    -- En love.keypressed(key):
--    if state == "map" and activeMap then
--        activeMap:keypressed(key)
--    end
--
--    -- En love.joystickpressed(joy, button):
--    if state == "map" and activeMap then
--        activeMap:joystickpressed(joy, button)
--    end
-- =============================================================================

local Controls = require("controls")

local Map = {}
Map.__index = Map

-- =============================================================================
--  CONSTANTES
-- =============================================================================

local LOGI_W  = 1280
local LOGI_H  = 720

-- Layout de nodos (mismo que Python)
local NODE_SIZE      = 56
local COLS_PER_ROW   = 4
local H_SPACING      = 380
local V_SPACING      = 320
local MARGIN_X       = 300
local MARGIN_X_RIGHT = 300
local MARGIN_Y_TOP   = 200

-- Sprite del jugador en el mapa
local SPRITE_SCALE = 3       -- escala aplicada a los frames del spritesheet
local PLAYER_SPEED = 220.0   -- px/s en coordenadas de mundo
local ANIM_SPEED   = 0.12    -- segundos por frame de caminata

-- =============================================================================
--  COLORES  (r,g,b normalizados a [0,1])
-- =============================================================================

local function rgb(r, g, b)  return r/255, g/255, b/255  end

local COL_GRASS_BASE   = { rgb( 43, 136,  49) }
local COL_GRASS_DARK   = { rgb(110, 195,  32) }
local COL_PATH         = { rgb(196, 164,  97) }
local COL_PATH_BORDER  = { rgb(158, 130,  70) }
local COL_NODE_NORMAL  = { rgb(210,  40,  40) }
local COL_NODE_DONE    = { rgb( 60, 180,  80) }
local COL_NODE_HOVER   = { rgb(255, 200,  50) }

-- =============================================================================
--  CONSTRUCTOR
-- =============================================================================

--- Crea una nueva instancia del mapa overworld.
---
--- @param levelList        table   Lista de { name, path } igual que en main.lua
--- @param completedLevels  table   { ["Nivel 1"] = true, ... }
--- @param passets          table   Tabla global `assets`
--- @return Map
function Map.new(levelList, completedLevels, passets, pmobileControls)
    local self = setmetatable({}, Map)

    self.levelList       = levelList
    self.completedLevels = completedLevels
    self.assets          = passets
    self.mobileControls  = pmobileControls   -- puede ser nil

    -- Construir nodos y tamaño del mundo
    self.nodes, self.worldW, self.worldH = self:_buildNodes()

    -- Posición inicial del jugador: primer nodo
    local first = self.nodes[1]
    self.playerWX  = first and first.cx or (LOGI_W / 2)
    self.playerWY  = first and (first.cy + 30) or (LOGI_H / 2)

    self.playerDir = "down"
    self.animFrame = 1       -- 1 = idle, 2..N = frames de caminata
    self.animTimer = 0.0

    -- Cámara (coordenadas de mundo, esquina superior izquierda del viewport)
    self.camX = 0.0
    self.camY = 0.0

    -- Nodo actualmente bajo el jugador (dentro de radio de interacción)
    self.hoveredNode = nil

    -- Tiempo acumulado para pulso de nodo
    self.animTime = 0.0

    -- Banderas de input (las setea keypressed/joystickpressed, las lee update)
    self._wantsEnter = false
    self._wantsBack  = false

    -- Spritesheet del jugador en el mapa
    self.mapAnims = self:_loadMapAnims()

    return self
end

--- Posiciona al jugador en coordenadas de mundo específicas.
--- Llamar después de Map.new() cuando el jugador vuelve de un nivel.
---
--- @param wx  number
--- @param wy  number
function Map:setStartPos(wx, wy)
    if wx and wy then
        self.playerWX = wx
        self.playerWY = wy
    end
end

-- =============================================================================
--  CONSTRUCCIÓN DE NODOS
-- =============================================================================

function Map:_buildNodes()
    local lf = self.levelList
    local nr = math.max(1, math.ceil(#lf / COLS_PER_ROW))

    -- Tamaño del mundo lógico (igual que build_nodes en Python)
    local ww = math.max(LOGI_W,
        MARGIN_X + (COLS_PER_ROW - 1) * H_SPACING + MARGIN_X_RIGHT + NODE_SIZE)
    local wh = math.max(LOGI_H,
        MARGIN_Y_TOP + (nr - 1) * V_SPACING + V_SPACING + NODE_SIZE + 200)

    -- Fila base: los nodos de la fila 0 se colocan cerca del fondo
    local baseY = wh - V_SPACING

    local nodes = {}
    for i, lev in ipairs(lf) do
        local idx = i - 1                          -- 0-based para el layout
        local row = math.floor(idx / COLS_PER_ROW)
        local col = idx % COLS_PER_ROW

        -- Patrón de serpentina: filas impares van de derecha a izquierda
        if row % 2 == 1 then
            col = (COLS_PER_ROW - 1) - col
        end

        local wx = MARGIN_X + col * H_SPACING
        local wy = baseY   - row * V_SPACING

        nodes[i] = {
            name = lev.name,
            path = lev.path,
            wx   = wx,
            wy   = wy,
            cx   = wx + NODE_SIZE / 2,   -- centro X del nodo
            cy   = wy + NODE_SIZE / 2,   -- centro Y del nodo
        }
    end

    return nodes, ww, wh
end

-- =============================================================================
--  CARGA DEL SPRITESHEET DEL JUGADOR EN EL MAPA
-- =============================================================================

--- Construye las secuencias de animación por dirección (down, up, left, right)
--- a partir de los assets precargados en love.load() (assets.images.mapPlayerSheet
--- y assets.data.mapPlayerFrames).
---
--- NO llama a love.graphics.newImage() para evitar el crash en Android que
--- ocurría cuando se creaba la textura fuera del ciclo de render en la
--- segunda (o posterior) entrada al mapa overworld.
---
--- Devuelve nil si los assets no están disponibles (se usará el fallback visual).
---
--- @return table | nil   { sheet, anims, frameW, frameH }
function Map:_loadMapAnims()
    local sheet = self.assets.images.mapPlayerSheet
    local data  = self.assets.data.mapPlayerFrames

    if not sheet or not data then
        print("[Map] PentagonManMap spritesheet not available — using fallback sprite.")
        return nil
    end

    local sw, sh = sheet:getDimensions()

    -- Construir tabla name → Quad  (el JSON tiene `frames` como diccionario)
    local quads = {}
    local frameW, frameH = 0, 0
    for name, info in pairs(data.frames or {}) do
        local f = info.frame
        quads[name] = love.graphics.newQuad(f.x, f.y, f.w, f.h, sw, sh)
        -- Tomar las dimensiones del primer frame para escalar después
        if frameW == 0 then
            frameW = f.w
            frameH = f.h
        end
    end

    -- Función auxiliar que devuelve el quad o nil si no existe
    local function q(name) return quads[name] end

    -- Secuencias de animación: [1] = idle, [2..5] = frames de caminata
    -- Los nombres coinciden exactamente con los de Python.
    local rawAnims = {
        down = {
            q("PentagonChibiFrontIdle.png"),
            q("PentagonChibiFrontWalkingAnimation1.png"),
            q("PentagonChibiFrontWalkingAnimation2.png"),
            q("PentagonChibiFrontWalkingAnimation3.png"),
            q("PentagonChibiFrontWalkingAnimation4.png"),
        },
        up = {
            q("PentagonChibiBeyondIdle.png"),
            q("PentagonChibiBeyondWalkingAnimation1.png"),
            q("PentagonChibiBeyondWalkingAnimation2.png"),
            q("PentagonChibiBeyondWalkingAnimation3.png"),
            q("PentagonChibiBeyondWalkingAnimation4.png"),
        },
        left = {
            q("PentagonChibiLeftIdle.png"),
            q("PentagonChibiLeftWalkingAnimationt1.png"),
            q("PentagonChibiLeftWalkingAnimationt2.png"),
            q("PentagonChibiLeftWalkingAnimationt3.png"),
            q("PentagonChibiLeftWalkingAnimationt4.png"),
        },
        right = {
            q("PentagonChibiRightIdle.png"),
            q("PentagonChibiRightWalkingAnimationt1.png"),
            q("PentagonChibiRightWalkingAnimationt2.png"),
            q("PentagonChibiRightWalkingAnimationt3.png"),
            q("PentagonChibiRightWalkingAnimationt4.png"),
        },
    }

    -- Reemplazar nils por el idle de cada dirección (igual que Python)
    for dir, seq in pairs(rawAnims) do
        local idle = seq[1]
        for i = 1, #seq do
            if not seq[i] then
                seq[i] = idle
            end
        end
    end

    return {
        sheet  = sheet,
        anims  = rawAnims,
        frameW = frameW,
        frameH = frameH,
    }
end

-- =============================================================================
--  HELPERS INTERNOS
-- =============================================================================

--- Dimensiones del sprite del jugador en el mapa en píxeles lógicos.
function Map:_spriteSize()
    if self.mapAnims and self.mapAnims.frameW > 0 then
        return self.mapAnims.frameW * SPRITE_SCALE,
               self.mapAnims.frameH * SPRITE_SCALE
    end
    return 48, 48   -- fallback
end

--- Avanza el frame de animación de caminata (frames 2..maxF, cíclico).
function Map:_advanceWalkFrame()
    if not self.mapAnims then return end
    local seq  = self.mapAnims.anims[self.playerDir]
    local maxF = #seq
    if maxF < 2 then return end

    if self.animFrame < 2 then
        -- Primera vez que se mueve: empezar desde el primer frame de caminata
        self.animFrame = 2
    else
        self.animFrame = self.animFrame + 1
        if self.animFrame > maxF then
            self.animFrame = 2   -- volver al primer frame de caminata (no al idle)
        end
    end
end

-- =============================================================================
--  UPDATE
-- =============================================================================

--- Actualiza el estado del mapa cada frame.
---
--- @param dt  number  Delta time en segundos
--- @return nil | "back" | table   nil = seguir, "back" = salir, table = nivel elegido
function Map:update(dt)
    self.animTime = self.animTime + dt

    -- ── Procesar banderas de input ────────────────────────────────────────────
    if self._wantsBack then
        self._wantsBack = false
        return "back"
    end

    if self._wantsEnter then
        self._wantsEnter = false
        if self.hoveredNode then
            return {
                name      = self.hoveredNode.name,
                path      = self.hoveredNode.path,
                playerWX  = self.playerWX,
                playerWY  = self.playerWY,
            }
        end
    end

    -- ── Inyectar mobile overrides ANTES de leer Controls ─────────────────────
    -- Misma lógica que levels.lua: los botones del overlay táctil se convierten
    -- en overrides de Controls para que isActionPressed() los recoja de forma
    -- transparente, igual que si fueran teclas de teclado.
    local mc = self.mobileControls
    if mc and controls.mobile_mode then
        Controls.clearMobileOverrides()
        Controls.setMobileOverride("move_left",  mc.state.left)
        Controls.setMobileOverride("move_right", mc.state.right)
        Controls.setMobileOverride("move_up",    mc.state.up)
        Controls.setMobileOverride("move_down",  mc.state.down)

        -- Botones discretos (justPressed evita disparo múltiple por frame)
        if mc:justPressed("jump") then self._wantsEnter = true end
        if mc:justPressed("esc")  then self._wantsBack  = true end
    end

    -- ── Input de movimiento ───────────────────────────────────────────────────
    local dx, dy = 0.0, 0.0

    -- Teclado, gamepad y mobile unificados a través del módulo Controls.
    -- Esto garantiza que:
    --   1. Los mobile overrides tengan prioridad (igual que en player.lua).
    --   2. El acelerómetro de Android NO se lea como joystick[1], lo que
    --      causaba un drift permanente hacia abajo al exponer el eje Y de
    --      gravedad como input analógico crudo.
    if Controls.isActionPressed("move_left")  then dx = dx - 1 end
    if Controls.isActionPressed("move_right") then dx = dx + 1 end
    if Controls.isActionPressed("move_up")    then dy = dy - 1 end
    if Controls.isActionPressed("move_down")  then dy = dy + 1 end

    -- Clampar a [-1, 1] por si hay acumulación
    dx = math.max(-1, math.min(1, dx))
    dy = math.max(-1, math.min(1, dy))

    local moving = (dx ~= 0 or dy ~= 0)

    if moving then
        -- Normalizar diagonal para velocidad constante
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 0 then dx = dx / len; dy = dy / len end

        self.playerWX = self.playerWX + dx * PLAYER_SPEED * dt
        self.playerWY = self.playerWY + dy * PLAYER_SPEED * dt

        -- Limitar al tamaño del mundo
        local pw, ph = self:_spriteSize()
        self.playerWX = math.max(pw / 2,
                            math.min(self.worldW - pw / 2, self.playerWX))
        self.playerWY = math.max(ph / 2 + 20,
                            math.min(self.worldH - ph / 2 + 20, self.playerWY))

        -- Dirección predominante (igual que Python)
        if math.abs(dy) >= math.abs(dx) then
            self.playerDir = (dy > 0) and "down" or "up"
        else
            self.playerDir = (dx > 0) and "right" or "left"
        end

        -- Avanzar animación de caminata
        self.animTimer = self.animTimer + dt
        if self.animTimer >= ANIM_SPEED then
            self.animTimer = 0
            self:_advanceWalkFrame()
        end
    else
        -- En reposo: frame idle (1) y timer reiniciado
        self.animFrame = 1
        self.animTimer = 0
    end

    -- ── Cámara suave siguiendo al jugador ────────────────────────────────────
    local targetCamX = self.playerWX - LOGI_W / 2
    local targetCamY = self.playerWY - LOGI_H / 2
    targetCamX = math.max(0, math.min(self.worldW - LOGI_W, targetCamX))
    targetCamY = math.max(0, math.min(self.worldH - LOGI_H, targetCamY))

    local lerp   = math.min(1.0, 8.0 * dt)
    self.camX    = self.camX + (targetCamX - self.camX) * lerp
    self.camY    = self.camY + (targetCamY - self.camY) * lerp

    -- ── Detección de proximidad a nodos ──────────────────────────────────────
    self.hoveredNode = nil
    for _, node in ipairs(self.nodes) do
        local dist = math.sqrt(
            (self.playerWX - node.cx) ^ 2 +
            (self.playerWY - node.cy) ^ 2)
        if dist < NODE_SIZE * 0.9 then
            self.hoveredNode = node
            break
        end
    end

    return nil
end

-- =============================================================================
--  INPUT DESDE main.lua
-- =============================================================================

--- Procesa eventos de teclado.  Llamar desde love.keypressed().
function Map:keypressed(key)
    -- Entrar al nivel
    if key == "space" or key == "return" then
        self._wantsEnter = true
    end

    -- Volver al menú
    local backKey = controls and controls.back or "escape"
    if key == backKey or key == "escape" then
        self._wantsBack = true
    end
end

--- Procesa botones de gamepad.  Llamar desde love.joystickpressed().
function Map:joystickpressed(joystick, button)
    -- A / Cross = confirmar entrada
    if button == "a" then
        self._wantsEnter = true
    end
    -- B / Circle o Start = volver
    if button == "b" or button == "start" then
        self._wantsBack = true
    end
end

-- =============================================================================
--  DRAW
-- =============================================================================

--- Dibuja el mapa completo dentro del canvas lógico (1280×720).
--- Llamar desde love.draw() después de setCanvas.
function Map:draw()
    local camX = math.floor(self.camX)
    local camY = math.floor(self.camY)

    self:_drawBackground(camX, camY)
    self:_drawPaths(camX, camY)
    self:_drawNodes(camX, camY)
    self:_drawPlayer(camX, camY)
    self:_drawTitle()
    self:_drawHUD()

    -- Overlay de controles móviles (siempre encima de todo)
    if self.mobileControls and controls.mobile_mode then
        self.mobileControls:draw()
    end
end

-- ── Fondo de hierba en tablero ────────────────────────────────────────────────

function Map:_drawBackground(camX, camY)
    -- Relleno base
    love.graphics.setColor(unpack(COL_GRASS_BASE))
    love.graphics.rectangle("fill", 0, 0, LOGI_W, LOGI_H)

    -- Tablero de cuadros más oscuros (solo los visibles)
    local tile = 80
    love.graphics.setColor(unpack(COL_GRASS_DARK))

    local firstCol = math.floor(camX / tile)
    local firstRow = math.floor(camY / tile)
    local lastCol  = math.ceil((camX + LOGI_W)  / tile)
    local lastRow  = math.ceil((camY + LOGI_H)  / tile)

    for r = firstRow, lastRow do
        for c = firstCol, lastCol do
            if (r + c) % 2 == 0 then
                local rx = c * tile - camX
                local ry = r * tile - camY
                love.graphics.rectangle("fill", rx, ry, tile, tile)
            end
        end
    end
end

-- ── Caminos entre nodos ───────────────────────────────────────────────────────

function Map:_drawPaths(camX, camY)
    local PATH_W   = 28
    local BORDER_W = PATH_W + 6

    love.graphics.setLineStyle("smooth")

    for i = 1, #self.nodes - 1 do
        local a = self.nodes[i]
        local b = self.nodes[i + 1]

        local ax = a.cx - camX
        local ay = a.cy - camY
        local bx = b.cx - camX
        local by = b.cy - camY

        -- Borde del camino
        love.graphics.setColor(unpack(COL_PATH_BORDER))
        love.graphics.setLineWidth(BORDER_W)
        love.graphics.line(ax, ay, bx, by)

        -- Superficie del camino
        love.graphics.setColor(unpack(COL_PATH))
        love.graphics.setLineWidth(PATH_W)
        love.graphics.line(ax, ay, bx, by)
    end

    love.graphics.setLineWidth(1)
end

-- ── Nodos de nivel ───────────────────────────────────────────────────────────

function Map:_drawNodes(camX, camY)
    for i, node in ipairs(self.nodes) do
        local cx = node.cx - camX
        local cy = node.cy - camY

        -- Culling simple
        if cx >= -NODE_SIZE - 10 and cx <= LOGI_W + NODE_SIZE + 10
        and cy >= -NODE_SIZE - 10 and cy <= LOGI_H + NODE_SIZE + 10 then

            local completed = self.completedLevels[node.name] == true
            local hovered   = self.hoveredNode == node

            -- Pulso de escala cuando el jugador está sobre el nodo
            local pulse = 1.0
            if hovered then
                pulse = 1.0 + 0.08 * math.sin(self.animTime * 4.0)
            end

            local dw = math.floor(NODE_SIZE * pulse)
            local dh = math.floor(NODE_SIZE * pulse)
            local dx = cx - dw / 2
            local dy = cy - dh / 2

            -- Color de relleno
            local fc
            if hovered    then fc = COL_NODE_HOVER
            elseif completed then fc = COL_NODE_DONE
            else              fc = COL_NODE_NORMAL
            end

            -- Sombra
            love.graphics.setColor(0, 0, 0, 0.3)
            love.graphics.rectangle("fill", dx + 4, dy + 4, dw, dh, 8, 8)

            -- Fondo del nodo
            love.graphics.setColor(unpack(fc))
            love.graphics.rectangle("fill", dx, dy, dw, dh, 8, 8)

            -- Borde blanco
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.setLineWidth(3)
            love.graphics.rectangle("line", dx, dy, dw, dh, 8, 8)
            love.graphics.setLineWidth(1)

            -- Número del nodo
            love.graphics.setFont(self.assets.fonts.medium)
            local numStr = tostring(i)
            local nw = self.assets.fonts.medium:getWidth(numStr)
            local nh = self.assets.fonts.medium:getHeight()
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.print(numStr,
                math.floor(cx - nw / 2),
                math.floor(cy - nh / 2))

            -- Etiqueta debajo del nodo (con sombra)
            love.graphics.setFont(self.assets.fonts.small)
            local label = node.name
            local lw = self.assets.fonts.small:getWidth(label)
            local lx = math.floor(cx - lw / 2)
            local ly = math.floor(dy + dh + 6)

            love.graphics.setColor(0, 0, 0, 0.8)
            love.graphics.print(label, lx + 1, ly + 1)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.print(label, lx, ly)
        end
    end
end

-- ── Sprite del jugador ────────────────────────────────────────────────────────

function Map:_drawPlayer(camX, camY)
    local pw, ph = self:_spriteSize()
    local drawX  = math.floor(self.playerWX - camX - pw / 2)
    local drawY  = math.floor(self.playerWY - camY - ph / 2)

    love.graphics.setColor(1, 1, 1, 1)

    if self.mapAnims then
        -- Spritesheet cargado correctamente
        local seq  = self.mapAnims.anims[self.playerDir]
        local fidx = math.max(1, math.min(self.animFrame, #seq))
        local quad = seq[fidx]

        if quad then
            local _, _, qw, qh = quad:getViewport()
            love.graphics.draw(
                self.mapAnims.sheet, quad,
                drawX, drawY,
                0,
                pw / qw, ph / qh)
        end
    else
        -- Fallback: rectángulo azul con borde
        love.graphics.setColor(0.20, 0.55, 1.0, 1)
        love.graphics.rectangle("fill", drawX, drawY, 48, 48, 10, 10)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", drawX, drawY, 48, 48, 10, 10)
        love.graphics.setLineWidth(1)
    end

    love.graphics.setColor(1, 1, 1, 1)
end

-- ── Título ────────────────────────────────────────────────────────────────────

function Map:_drawTitle()
    local title = "Select a Level"
    love.graphics.setFont(self.assets.fonts.title)
    local tw = self.assets.fonts.title:getWidth(title)
    local tx = math.floor(LOGI_W / 2 - tw / 2)

    -- Sombra
    love.graphics.setColor(0, 0, 0, 0.7)
    love.graphics.print(title, tx + 2, 22)

    -- Texto principal
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print(title, tx, 20)
end

-- ── HUD (instrucciones) ───────────────────────────────────────────────────────

function Map:_drawHUD()
    -- Construir líneas de texto
    local lines = { "ESC / B: Back to menu" }
    if self.hoveredNode then
        table.insert(lines, 1,
            "SPACE / A: Enter '" .. self.hoveredNode.name .. "'")
    end

    local font   = self.assets.fonts.small
    local lineH  = font:getHeight() + 4
    local pad    = 10
    local boxW   = 360
    local boxH   = lineH * #lines + pad * 2
    local boxX   = 10
    local boxY   = LOGI_H - boxH - 10

    -- Fondo semitransparente
    love.graphics.setColor(0, 0, 0, 0.60)
    love.graphics.rectangle("fill", boxX, boxY, boxW, boxH, 6, 6)

    -- Texto
    love.graphics.setFont(font)
    love.graphics.setColor(1, 1, 1, 1)
    for i, line in ipairs(lines) do
        love.graphics.print(line,
            boxX + pad,
            boxY + pad + (i - 1) * lineH)
    end
end

return Map
