-- =============================================================================
--  controls.lua  PentagonMan (Love2D port)
--  Gestión de controles: teclado, gamepad (botones + ejes analógicos),
--  zonas muertas, save/load persistente, helpers de consulta.
--
--  DISEÑO DE COMPATIBILIDAD:
--  El global `controls` sigue siendo la tabla de bindings que ya usan
--  player.lua y levels.lua.  Los valores pueden ser:
--    • plain string  →  tecla de teclado (formato legacy y default)
--    • { type="key",    value="a" }
--    • { type="button", value="a" }   (nombre de gamepad estándar Love2D)
--    • { type="axis",   axis=1, dir=1 }
--  Controls.isActionPressed() y Controls.getMovementValue() aceptan
--  los tres formatos, además de los fallbacks implícitos de D-pad y
--  stick izquierdo.
--
--  INTEGRACIÓN CON main.lua  (cambios necesarios):
--    1. Al inicio de love.load():
--         local Controls = require("controls")
--         Controls.load()          -- reemplaza a loadControls()
--
--    2. En saveControls():
--         Controls.save()
--
--    3. En el display de Settings, reemplazar  controls[item.key]:upper()
--       por  Controls.getBindingName(controls[item.key])
--
--    4. Al rebindear con gamepad (en love.keypressed / joystickpressed):
--         controls[waitingForKey] = { type="button", value=button }
--
--    5. En player.lua, para que el gamepad también mueva al jugador,
--       reemplazar love.keyboard.isDown(controls.xxx) por
--       Controls.isActionPressed("xxx")
-- =============================================================================

local json = require("libs/json")

local Controls = {}

-- =============================================================================
--  MOBILE OVERRIDES
--  Permite que mobile_controls.lua inyecte el estado de los botones virtuales
--  antes de que isActionPressed() consulte el hardware real.
--  Misma semántica que _mobile_override en controls.py.
-- =============================================================================

local _mobileOverride = {}

--- Marca una acción virtual como presionada o liberada.
--- Llamar una vez por frame ANTES de que se evalúe la física.
function Controls.setMobileOverride(action, pressed)
    _mobileOverride[action] = pressed or false
end

--- Limpia todos los overrides móviles.
--- Llamar UNA VEZ al inicio del frame, antes de setMobileOverride().
function Controls.clearMobileOverrides()
    _mobileOverride = {}
end

-- =============================================================================
--  ARCHIVO DE PERSISTENCIA
-- =============================================================================

Controls.FILE = "controls.json"

-- =============================================================================
--  DEFAULTS
--  Se usan plain strings para teclado: así el código existente en player.lua
--  que hace `love.keyboard.isDown(controls.move_left)` sigue funcionando
--  sin cambios.  Solo cuando el usuario rebindea a gamepad se guarda tabla.
-- =============================================================================

local DEFAULT_CONTROLS = {
    -- ── Jugador ───────────────────────────────────────────────────────────────
    move_left   = "a",
    move_right  = "d",
    move_up     = "w",
    move_down   = "s",
    jump        = "space",

    -- ── General ───────────────────────────────────────────────────────────────
    back        = "escape",
    map_editor  = "/",

    -- ── Editor: cámara ────────────────────────────────────────────────────────
    editor_cam_up    = "up",
    editor_cam_down  = "down",
    editor_cam_left  = "left",
    editor_cam_right = "right",

    -- ── Editor: selección de tile ─────────────────────────────────────────────
    editor_tile_prev = "q",
    editor_tile_next = "e",

    -- ── Editor: colocar / borrar ──────────────────────────────────────────────
    editor_place_tile  = "return",
    editor_delete_tile = "backspace",

    -- ── Editor: otros ─────────────────────────────────────────────────────────
    custom_background = "b",

    -- ── Visual / performance ───────────────────────────────────────────────────
    gamepad_dead_zone = 0.20,
    show_hitboxes     = false,
    show_fps          = false,
    fps_limit         = 60,

    -- ── Controles táctiles (ACTIVADOS por defecto) ─────────────────────────
    mobile_mode = true,
}

-- =============================================================================
--  FALLBACKS IMPLÍCITOS DE GAMEPAD
--  Activos siempre, independientemente de los bindings del usuario.
--  Así el gamepad "funciona desde el primer momento" sin configuración.
-- =============================================================================

-- D-pad → acciones de movimiento
local DPAD_FALLBACK = {
    move_left  = "dpleft",
    move_right = "dpright",
    move_up    = "dpup",
    move_down  = "dpdown",
    jump       = "a",      -- A / Cross
    back       = "b",      -- B / Circle
}

-- Stick izquierdo (eje 1 = X, eje 2 = Y) → movimiento analógico
local STICK_FALLBACK = {
    move_left  = { axis = 1, dir = -1 },
    move_right = { axis = 1, dir =  1 },
    move_up    = { axis = 2, dir = -1 },
    move_down  = { axis = 2, dir =  1 },
}

-- =============================================================================
--  TABLAS DE NOMBRES LEGIBLES
-- =============================================================================

-- Botones estándar Love2D → nombre legible para la UI de Settings
local BUTTON_NAMES = {
    a             = "A / Cross",
    b             = "B / Circle",
    x             = "X / Square",
    y             = "Y / Triangle",
    leftshoulder  = "LB / L1",
    rightshoulder = "RB / R1",
    lefttrigger   = "LT / L2",
    righttrigger  = "RT / R2",
    back          = "Select / Share",
    start         = "Start / Options",
    dpup          = "D-Up",
    dpdown        = "D-Down",
    dpleft        = "D-Left",
    dpright       = "D-Right",
    leftstick     = "L-Stick Btn",
    rightstick    = "R-Stick Btn",
    guide         = "Guide / Home",
}

-- Ejes estándar Love2D (1-indexed) → nombre legible
local AXIS_NAMES = {
    [1] = "L-Stick X",
    [2] = "L-Stick Y",
    [3] = "R-Stick X",
    [4] = "R-Stick Y",
    [5] = "L-Trigger",
    [6] = "R-Trigger",
}

-- =============================================================================
--  HELPER: JOYSTICK
-- =============================================================================

--- Devuelve el primer joystick que sea un gamepad real (tiene mapeo SDL), o nil.
---
--- En Android, SDL2 expone el acelerómetro y el giroscopio como joysticks
--- virtuales. Si se devuelve sticks[1] sin filtrar, esos sensores reciben
--- toda la cadena de input (STICK_FALLBACK, getAxis, etc.) y el movimiento
--- del teléfono mueve al personaje aunque no haya ningún mando conectado.
---
--- joy:isGamepad() devuelve true únicamente para dispositivos con mapeo SDL
--- (mandos Bluetooth, USB, etc.) y false para sensores del SO, descartándolos.
function Controls.getJoy()
    local sticks = love.joystick.getJoysticks()
    for _, joy in ipairs(sticks) do
        if joy:isGamepad() then
            return joy
        end
    end
    return nil
end

-- =============================================================================
--  NOMBRE LEGIBLE DE UN BINDING
-- =============================================================================

--- Devuelve una cadena legible para cualquier valor de binding.
--- Útil para mostrar los controles en la pantalla de Settings.
---
--- @param binding  string | table | boolean | number
--- @return string
function Controls.getBindingName(binding)
    -- Booleanos y números (ajustes, no bindings)
    if type(binding) == "boolean" then
        return binding and "ON" or "OFF"
    end
    if type(binding) == "number" then
        return tostring(binding)
    end

    -- Plain string = tecla de teclado (legacy y default)
    if type(binding) == "string" then
        return binding:upper()
    end

    if type(binding) ~= "table" then return "?" end

    local btype = binding.type

    if btype == "key" then
        return (binding.value or "?"):upper()

    elseif btype == "button" then
        return BUTTON_NAMES[binding.value]
            or ("BTN " .. tostring(binding.value))

    elseif btype == "axis" then
        local name   = AXIS_NAMES[binding.axis]
                    or ("AXIS " .. tostring(binding.axis))
        local dirStr = ((binding.dir or 1) > 0) and "+" or "-"
        return name .. " " .. dirStr
    end

    return "?"
end

-- =============================================================================
--  CONSULTA: isActionPressed
-- =============================================================================

--- True si la acción indicada está siendo presionada en este frame.
--- Comprueba: binding explícito → D-pad fallback → stick analógico fallback.
---
--- @param action  string  Clave en la tabla global `controls`
--- @return boolean
function Controls.isActionPressed(action)
    -- Mobile override tiene prioridad sobre todo el hardware.
    if _mobileOverride[action] then return true end

    local binding = controls[action]
    local dz      = (controls.gamepad_dead_zone or 0.20)

    -- ── 1. Binding explícito del usuario ─────────────────────────────────────
    if binding ~= nil then
        -- Plain string → tecla de teclado
        if type(binding) == "string" then
            if love.keyboard.isDown(binding) then return true end
            -- No return false aquí: sigue hacia los fallbacks de gamepad.

        elseif type(binding) == "table" then
            local btype = binding.type

            if btype == "key" then
                if love.keyboard.isDown(binding.value) then return true end

            elseif btype == "button" then
                local joy = Controls.getJoy()
                if joy and joy:isGamepadDown(binding.value) then return true end

            elseif btype == "axis" then
                local joy = Controls.getJoy()
                if joy then
                    local v  = joy:getAxis(binding.axis) or 0
                    if (v * (binding.dir or 1)) > dz then return true end
                end
            end
        end
    end

    -- ── 2. D-pad fallback (siempre activo si hay gamepad conectado) ──────────
    local dpadBtn = DPAD_FALLBACK[action]
    if dpadBtn then
        local joy = Controls.getJoy()
        if joy and joy:isGamepadDown(dpadBtn) then return true end
    end

    -- ── 3. Stick analógico fallback ──────────────────────────────────────────
    local stick = STICK_FALLBACK[action]
    if stick then
        local joy = Controls.getJoy()
        if joy then
            local v  = joy:getAxis(stick.axis) or 0
            if (v * stick.dir) > dz then return true end
        end
    end

    return false
end

-- =============================================================================
--  CONSULTA: getMovementValue
-- =============================================================================

--- Devuelve un flotante [0.0, 1.0] que representa la magnitud del input.
--- Para ejes analógicos devuelve el valor crudo (por encima de la zona muerta).
--- Para teclas y botones devuelve 0.0 o 1.0.
--- Útil para movimiento suave de cámara en el editor o cursores.
---
--- @param action  string
--- @return number
function Controls.getMovementValue(action)
    -- Mobile override tiene prioridad.
    if _mobileOverride[action] then return 1.0 end

    local binding = controls[action]
    local dz      = (controls.gamepad_dead_zone or 0.20)

    -- Plain string
    if type(binding) == "string" then
        if love.keyboard.isDown(binding) then return 1.0 end

    elseif type(binding) == "table" then
        local btype = binding.type

        if btype == "key" then
            return love.keyboard.isDown(binding.value) and 1.0 or 0.0

        elseif btype == "button" then
            local joy = Controls.getJoy()
            if joy and joy:isGamepadDown(binding.value) then return 1.0 end

        elseif btype == "axis" then
            local joy = Controls.getJoy()
            if joy then
                local v  = joy:getAxis(binding.axis) or 0
                local vd = v * (binding.dir or 1)
                if vd > dz then return math.max(0.0, vd) end
            end
        end
    end

    -- Stick analógico fallback
    local stick = STICK_FALLBACK[action]
    if stick then
        local joy = Controls.getJoy()
        if joy then
            local v  = joy:getAxis(stick.axis) or 0
            local vd = v * stick.dir
            if vd > dz then return math.max(0.0, vd) end
        end
    end

    return 0.0
end

-- =============================================================================
--  CONSULTA: isBindingEvent
-- =============================================================================

--- Comprueba si un evento de teclado o botón de gamepad coincide con el
--- binding de una acción.  Usar en love.keypressed / love.joystickpressed
--- en lugar de comparar directamente.
---
--- event debe ser una tabla con los campos:
---   { etype = "keypressed",       key    = "a"  }
---   { etype = "joybuttonpressed", button = "a"  }
---
--- @param action  string
--- @param event   table
--- @return boolean
function Controls.isBindingEvent(action, event)
    local binding = controls[action]
    if not binding then return false end

    if event.etype == "keypressed" then
        if type(binding) == "string" then
            return event.key == binding
        elseif type(binding) == "table" and binding.type == "key" then
            return event.key == binding.value
        end

    elseif event.etype == "joybuttonpressed" then
        if type(binding) == "table" and binding.type == "button" then
            return event.button == binding.value
        end
    end

    return false
end

-- =============================================================================
--  SAVE / LOAD
-- =============================================================================

--- Carga controles desde el archivo JSON de persistencia.
--- • Si el archivo no existe, aplica los defaults.
--- • Migra automáticamente el formato legacy de plain strings.
--- • Garantiza que todas las claves de DEFAULT existen en `controls`.
--- Modifica la tabla global `controls` en su lugar (no la reasigna).
function Controls.load()
    -- Paso 1: aplicar defaults en la tabla global existente
    for k, v in pairs(DEFAULT_CONTROLS) do
        controls[k] = v
    end

    -- Paso 2: leer archivo si existe
    if not love.filesystem.getInfo(Controls.FILE) then
        print("[Controls] No controls.json found — using defaults.")
        return
    end

    local raw = love.filesystem.read(Controls.FILE)
    if not raw or raw == "" then return end

    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then
        print("[Controls] Error parsing controls.json — keeping defaults.")
        return
    end

    -- Paso 3: mezclar valores guardados
    for k, v in pairs(data) do
        -- Migración: si la clave es una acción conocida y el valor es string
        -- se trata como plain string (ya es el formato correcto).
        if type(v) == "string"
        or type(v) == "table"
        or type(v) == "number"
        or type(v) == "boolean" then
            controls[k] = v
        end
    end

    -- Paso 4: garantizar que todas las acciones de DEFAULT existen
    for k, v in pairs(DEFAULT_CONTROLS) do
        if controls[k] == nil then
            controls[k] = v
        end
    end

    print("[Controls] Loaded from controls.json.")
end

--- Guarda el estado actual de la tabla global `controls` a disco.
function Controls.save()
    local ok, encoded = pcall(json.encode, controls)
    if not ok then
        print("[Controls] Error encoding controls: " .. tostring(encoded))
        return
    end
    love.filesystem.write(Controls.FILE, encoded)
    print("[Controls] Saved to controls.json.")
end

--- Restablece todos los controles a los valores por defecto y guarda.
function Controls.resetToDefaults()
    -- Borrar todo lo existente y aplicar defaults
    for k in pairs(controls) do
        controls[k] = nil
    end
    for k, v in pairs(DEFAULT_CONTROLS) do
        controls[k] = v
    end
    Controls.save()
    print("[Controls] Reset to defaults and saved.")
end

-- =============================================================================
--  DETECCIÓN DE INPUT PARA REBINDING
-- =============================================================================

--- Devuelve el primer binding detectado en este frame (para la pantalla de
--- Settings cuando el usuario está reasignando una tecla o botón).
---
--- Retorna:
---   nil           →  nada presionado
---   { type="key",    value="a" }
---   { type="button", value="a" }
---   { type="axis",   axis=1, dir=1 }
---
--- Llamar en love.update() mientras waitingForKey ~= nil.
--- IMPORTANTE: los ejes también actúan en este frame, no en keypressed,
--- por eso se necesita esta función separada.
---
--- @return table | nil
function Controls.detectInput()
    local dz = 0.50  -- zona muerta más alta para rebinding (evita falsos positivos)

    -- Teclado: iterar sobre todas las teclas conocidas y detectar cuál está presionada
    -- Love2D no tiene "get all pressed keys", pero love.keypressed() ya lo captura.
    -- Este método sirve para el eje analógico que no dispara keypressed.

    local joy = Controls.getJoy()
    if joy then
        -- Botones de gamepad
        for _, btn in ipairs({
            "a","b","x","y",
            "leftshoulder","rightshoulder","lefttrigger","righttrigger",
            "back","start","guide",
            "dpup","dpdown","dpleft","dpright",
            "leftstick","rightstick",
        }) do
            if joy:isGamepadDown(btn) then
                return { type = "button", value = btn }
            end
        end

        -- Ejes analógicos (detectamos el que más se desvíe por encima del umbral)
        local maxV   = dz
        local chosen = nil
        for axis = 1, joy:getAxisCount() do
            local v = joy:getAxis(axis) or 0
            if math.abs(v) > maxV then
                maxV   = math.abs(v)
                chosen = {
                    type = "axis",
                    axis = axis,
                    dir  = (v > 0) and 1 or -1,
                }
            end
        end
        if chosen then return chosen end
    end

    return nil  -- nada detectado (el teclado se captura en love.keypressed)
end

return Controls
