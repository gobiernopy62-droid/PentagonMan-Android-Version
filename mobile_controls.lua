-- =============================================================================
--  mobile_controls.lua  PentagonMan (Love2D port)
--  Port fiel de mobile_controls.py
--
--  Overlay de controles táctiles para Android y PC (mouse, para testing).
--
--  Assets → Assets/MobileControls/
--    btn_dpad_left.png   btn_dpad_right.png   btn_dpad_up.png   btn_dpad_down.png
--    btn_jump.png        btn_editor.png       btn_esc.png
--    btn_prev.png        btn_next.png         btn_bg.png
--
--  Todo el layout se calcula en espacio lógico (1280×720).
--  La conversión de coordenadas físicas → lógicas usa la misma
--  fórmula que getCanvasTransform() en main.lua.
--
--  INTEGRACIÓN — ver main.lua para el ejemplo completo.
-- =============================================================================

local MobileControls = {}
MobileControls.__index = MobileControls

-- ── Resolución lógica (debe coincidir con main.lua) ───────────────────────────
local LOGI_W = 1280
local LOGI_H = 720

-- ── Grupos de botones por modo ────────────────────────────────────────────────
--  Mismos grupos que GAME_BUTTONS / MAP_BUTTONS / EDITOR_BUTTONS en Python.
local GAME_BUTTONS   = { "left","right","up","down","jump","esc" }
local MAP_BUTTONS    = { "left","right","up","down","jump","esc" }
local EDITOR_BUTTONS = { "left","right","up","down","esc","tile_prev","tile_next","custom_bg" }
local ALL_BUTTONS    = {
    "left","right","up","down","jump",
    "esc","tile_prev","tile_next","custom_bg",
}

-- ── Archivos de imagen (ruta idéntica a Python) ───────────────────────────────
local IMG_FILES = {
    left       = "Assets/MobileControls/btn_dpad_left.png",
    right      = "Assets/MobileControls/btn_dpad_right.png",
    up         = "Assets/MobileControls/btn_dpad_up.png",
    down       = "Assets/MobileControls/btn_dpad_down.png",
    jump       = "Assets/MobileControls/btn_jump.png",
    esc        = "Assets/MobileControls/btn_esc.png",
    tile_prev  = "Assets/MobileControls/btn_prev.png",
    tile_next  = "Assets/MobileControls/btn_next.png",
    custom_bg  = "Assets/MobileControls/btn_bg.png",
}

-- ── Etiquetas de fallback (cuando no hay PNG) ─────────────────────────────────
local FALLBACK_LABELS = {
    left="◄", right="►", up="▲", down="▼",
    jump="↑", esc="ESC",
    tile_prev="<", tile_next=">", custom_bg="BG",
}

-- =============================================================================
--  Constructor
-- =============================================================================

function MobileControls.new()
    local self = setmetatable({}, MobileControls)

    self.mode = "game"   -- "game" | "map" | "editor"

    -- Estado de botones: frame actual y frame anterior (para justPressed)
    self.state     = {}
    self.prevState = {}
    for _, btn in ipairs(ALL_BUTTONS) do
        self.state[btn]     = false
        self.prevState[btn] = false
    end

    -- Multi-touch: id de dedo → nombre del botón que está presionando
    self.fingerMap = {}

    -- Mouse (PC testing): botón presionado actualmente con el ratón
    self._mouseBtn = nil

    -- Rectángulos de cada botón en coordenadas lógicas
    self.rects = {}
    self:_buildLayout()

    -- Imágenes (o canvas de fallback si el PNG no existe)
    self.images = {}
    self._font  = love.graphics.newFont(14)
    self:_loadImages()

    return self
end

-- =============================================================================
--  Conversión de coordenadas
-- =============================================================================

--- Convierte coordenadas físicas de pantalla → lógicas del canvas.
--- Usa la misma fórmula que getCanvasTransform() en main.lua.
function MobileControls:_toLogical(physX, physY)
    local sw, sh = love.graphics.getDimensions()
    local scale  = math.min(sw / LOGI_W, sh / LOGI_H)
    local ox     = math.floor((sw - LOGI_W * scale) / 2)
    local oy     = math.floor((sh - LOGI_H * scale) / 2)
    return (physX - ox) / scale, (physY - oy) / scale
end

-- =============================================================================
--  Layout
-- =============================================================================

--- Construye los rectángulos de cada botón en espacio lógico.
--- Lógica idéntica a _build_layout() en mobile_controls.py.
function MobileControls:_buildLayout()
    local w   = LOGI_W
    local h   = LOGI_H
    local sz  = math.max(60, math.floor(h * 0.11))    -- tamaño base de botón
    local pad = math.max(8,  math.floor(h * 0.018))   -- margen con los bordes
    local sz2 = sz * 2                                 -- doble (jump, tile_prev/next)

    -- D-pad: esquina inferior izquierda (elevado un 15% desde el borde)
    local cx = pad + sz
    local cy = h - pad - sz - math.floor(h * 0.15)

    self.rects.left  = { x = cx - sz, y = cy,      w = sz, h = sz }
    self.rects.right = { x = cx + sz, y = cy,      w = sz, h = sz }
    self.rects.up    = { x = cx,      y = cy - sz, w = sz, h = sz }
    self.rects.down  = { x = cx,      y = cy + sz, w = sz, h = sz }

    -- Salto: esquina inferior derecha, tamaño doble
    local rx = w - pad - sz2
    self.rects.jump = {
        x = rx,
        y = h - pad - sz2 - math.floor(h * 0.12),
        w = sz2, h = sz2,
    }

    -- ESC: esquina superior izquierda
    self.rects.esc = { x = pad, y = pad, w = sz, h = sz }

    -- Tile siguiente / anterior: esquina inferior derecha (modo editor)
    self.rects.tile_next = {
        x = w - pad - sz2,
        y = h - pad - sz2 - math.floor(h * 0.12),
        w = sz2, h = sz2,
    }
    self.rects.tile_prev = {
        x = w - pad - sz2 * 2 - pad,
        y = h - pad - sz2 - math.floor(h * 0.12),
        w = sz2, h = sz2,
    }

    -- Background custom: esquina superior derecha (modo editor)
    self.rects.custom_bg = { x = w - pad - sz, y = pad, w = sz, h = sz }
end

-- =============================================================================
--  Carga de imágenes
-- =============================================================================

function MobileControls:_loadImages()
    for _, btn in ipairs(ALL_BUTTONS) do
        local path = IMG_FILES[btn]
        local r    = self.rects[btn]
        local sz   = r and r.w or 60
        local loaded = false

        if path and love.filesystem.getInfo(path) then
            local ok, img = pcall(love.graphics.newImage, path)
            if ok then
                self.images[btn] = img
                loaded = true
            end
        end

        if not loaded then
            self.images[btn] = self:_makeFallback(sz, FALLBACK_LABELS[btn] or "?")
        end
    end
end

--- Dibuja en un Canvas el botón de fallback (mismo estilo que Python).
function MobileControls:_makeFallback(size, label)
    local canvas     = love.graphics.newCanvas(size, size)
    local prevCanvas = love.graphics.getCanvas()

    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)

    -- Fondo oscuro semitransparente
    love.graphics.setColor(55/255, 55/255, 55/255, 0.67)
    love.graphics.rectangle("fill", 0, 0, size, size, 10, 10)

    -- Borde gris
    love.graphics.setColor(190/255, 190/255, 190/255, 0.82)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", 1, 1, size - 2, size - 2, 10, 10)
    love.graphics.setLineWidth(1)

    -- Etiqueta centrada
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(self._font)
    local tw = self._font:getWidth(label)
    local th = self._font:getHeight()
    love.graphics.print(label,
        math.floor((size - tw) / 2),
        math.floor((size - th) / 2))

    love.graphics.setCanvas(prevCanvas)
    love.graphics.setColor(1, 1, 1, 1)

    return canvas
end

-- =============================================================================
--  Helpers internos
-- =============================================================================

--- Lista de botones activos según el modo actual.
function MobileControls:_activeButtons()
    if self.mode == "editor" then return EDITOR_BUTTONS
    elseif self.mode == "map" then return MAP_BUTTONS
    else                           return GAME_BUTTONS
    end
end

--- True si el punto (lx, ly) está dentro del rect r.
local function inRect(lx, ly, r)
    return r
       and lx >= r.x and lx <= r.x + r.w
       and ly >= r.y and ly <= r.y + r.h
end

--- Devuelve el primer botón activo que contiene (lx, ly), o nil.
function MobileControls:_hitTest(lx, ly)
    for _, btn in ipairs(self:_activeButtons()) do
        if inRect(lx, ly, self.rects[btn]) then
            return btn
        end
    end
    return nil
end

-- =============================================================================
--  API pública: modos
-- =============================================================================

--- Modo juego: d-pad + salto + editor + ESC.
function MobileControls:setGameMode()
    self.mode = "game"
    self:_resetAll()
end

--- Modo mapa: d-pad + salto (= entrar al nivel) + ESC.
function MobileControls:setMapMode()
    self.mode = "map"
    self:_resetAll()
end

--- Modo editor: d-pad + ESC + tile_prev/next + custom_bg.
function MobileControls:setEditorMode()
    self.mode = "editor"
    self:_resetAll()
end

function MobileControls:_resetAll()
    for _, btn in ipairs(ALL_BUTTONS) do
        self.state[btn]     = false
        self.prevState[btn] = false
    end
    self.fingerMap = {}
    self._mouseBtn = nil
end

-- =============================================================================
--  API pública: consulta
-- =============================================================================

--- True solo en el frame en que el botón fue presionado por primera vez.
function MobileControls:justPressed(btn)
    return self.state[btn] == true and self.prevState[btn] == false
end

--- True si el punto (lx, ly) en coordenadas LÓGICAS está sobre algún botón activo.
--- Útil para que el editor ignore toques que caigan sobre el HUD.
function MobileControls:pointOnHUD(lx, ly)
    return self:_hitTest(lx, ly) ~= nil
end

--- Llamar UNA VEZ por frame, DESPUÉS de dibujar, ANTES del siguiente poll.
--- Avanza prevState para que justPressed() funcione correctamente.
function MobileControls:tick()
    for _, btn in ipairs(ALL_BUTTONS) do
        self.prevState[btn] = self.state[btn]
    end
end

-- =============================================================================
--  Eventos táctiles  (love.touchpressed / touchmoved / touchreleased)
-- =============================================================================
--
--  En LÖVE, love.touchpressed recibe coordenadas en PÍXELES FÍSICOS directamente,
--  sin necesidad de desnormalizar como en pygame. La separación entre touch y
--  mouse es automática — no existe el problema de mezcla que requería el flag
--  IS_ANDROID en Python.

--- Llamar desde love.touchpressed(id, x, y, ...).
function MobileControls:onTouchPressed(id, physX, physY)
    if self.fingerMap[id] then return end   -- dedo ya registrado
    local lx, ly = self:_toLogical(physX, physY)
    local btn    = self:_hitTest(lx, ly)
    if btn then
        self.state[btn]    = true
        self.fingerMap[id] = btn
    end
end

--- Llamar desde love.touchreleased(id, x, y, ...).
function MobileControls:onTouchReleased(id, physX, physY)
    local btn = self.fingerMap[id]
    if not btn then return end

    -- Solo libera el botón si ningún otro dedo lo sigue sosteniendo.
    local stillHeld = false
    for otherId, otherBtn in pairs(self.fingerMap) do
        if otherId ~= id and otherBtn == btn then
            stillHeld = true
            break
        end
    end
    if not stillHeld then
        self.state[btn] = false
    end
    self.fingerMap[id] = nil
end

--- Llamar desde love.touchmoved(id, x, y, ...).
--- Maneja el deslizamiento de un dedo entre botones, incluyendo el caso
--- en que el dedo comenzó en zona vacía y entra en un botón deslizando.
function MobileControls:onTouchMoved(id, physX, physY)
    local lx, ly = self:_toLogical(physX, physY)
    local oldBtn = self.fingerMap[id]

    if oldBtn then
        -- El dedo ya estaba sobre un botón registrado.
        -- Si sigue dentro, no hay nada que hacer.
        if inRect(lx, ly, self.rects[oldBtn]) then return end

        -- Salió del botón original → liberar si nadie más lo sostiene.
        local stillHeld = false
        for otherId, otherBtn in pairs(self.fingerMap) do
            if otherId ~= id and otherBtn == oldBtn then
                stillHeld = true
                break
            end
        end
        if not stillHeld then
            self.state[oldBtn] = false
        end
        self.fingerMap[id] = nil
    end

    -- En ambos casos (venía de botón o de zona vacía): si ahora está
    -- sobre un botón, registrarlo como presionado.
    local newBtn = self:_hitTest(lx, ly)
    if newBtn then
        self.state[newBtn] = true
        self.fingerMap[id] = newBtn
    end
end

-- =============================================================================
--  Eventos de mouse  (PC — testing)
-- =============================================================================

--- Llamar desde love.mousepressed(x, y, button) cuando button == 1.
function MobileControls:onMousePressed(physX, physY)
    local lx, ly = self:_toLogical(physX, physY)
    local btn    = self:_hitTest(lx, ly)
    if btn then
        self.state[btn] = true
        self._mouseBtn  = btn
    end
end

--- Llamar desde love.mousereleased(x, y, button) cuando button == 1.
function MobileControls:onMouseReleased()
    if self._mouseBtn then
        self.state[self._mouseBtn] = false
        self._mouseBtn = nil
    end
end

--- Llamar desde love.mousemoved(x, y, ...) para detectar arrastre entre botones.
--- Solo actúa cuando el botón izquierdo del mouse está sostenido.
function MobileControls:onMouseMoved(physX, physY)
    -- Si no hay botón del mouse sostenido, ignorar.
    if not love.mouse.isDown(1) then
        -- Si había un botón registrado y el mouse ya no está pulsado, limpiar.
        if self._mouseBtn then
            self.state[self._mouseBtn] = false
            self._mouseBtn = nil
        end
        return
    end

    local lx, ly = self:_toLogical(physX, physY)
    local newBtn = self:_hitTest(lx, ly)

    if newBtn == self._mouseBtn then return end  -- mismo botón, nada que hacer

    -- Liberar el botón anterior si había uno.
    if self._mouseBtn then
        self.state[self._mouseBtn] = false
        self._mouseBtn = nil
    end

    -- Activar el nuevo botón si el cursor entró en uno.
    if newBtn then
        self.state[newBtn] = true
        self._mouseBtn = newBtn
    end
end

-- =============================================================================
--  Draw
-- =============================================================================

--- Dibuja el overlay de botones sobre el canvas lógico (1280×720).
--- Llamar DENTRO del bloque setCanvas / setCanvas(nil), después del juego.
function MobileControls:draw()
    for _, btn in ipairs(self:_activeButtons()) do
        local r   = self.rects[btn]
        local img = self.images[btn]
        if r and img then
            local alpha = self.state[btn] and 1.0 or 0.63
            love.graphics.setColor(1, 1, 1, alpha)
            love.graphics.draw(img, r.x, r.y, 0,
                r.w / img:getWidth(),
                r.h / img:getHeight())
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
end

return MobileControls