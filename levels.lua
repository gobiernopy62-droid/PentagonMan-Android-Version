-- =============================================================================
--  levels.lua  PentagonMan (Love2D port)
--  Carga JSON de nivel, lógica de plataformas, cámara, checkpoints,
--  door, death blocks, agua, overlays de Game Over y Victory
-- =============================================================================

local json     = require("libs/json")
local Player   = require("player")
local Enemy    = require("enemy")
local Boss     = require("boss")
local Controls = require("controls")

local Level = {}
Level.__index = Level

local LOGI_W = 1280
local LOGI_H = 720
local TILE_SIZE = 60

-- Índices de tile especiales (mismos que en Python)
local IDX_DEATH      = 3
local IDX_WATER_SURF = 4
local IDX_WATERFALL  = 5
local IDX_WATER      = 6

-- Tiles de agua (índices que se renderizan debajo de todo)
local WATER_INDICES = { [4] = true, [5] = true, [6] = true }

-- =============================================================================
--  Constructor
-- =============================================================================

function Level.new(jsonPath, levelName, passets, pcontrols, pmobileControls)
    local self = setmetatable({}, Level)

    self.assets          = passets
    self.controls        = pcontrols
    self.mobileControls  = pmobileControls   -- puede ser nil si no se usa móvil
    self.name            = levelName

    -- Cargar JSON del nivel
    --
    -- Se usa love.filesystem.newFile() + lectura por chunks en lugar de
    -- love.filesystem.read() de una sola pasada. En Android, los archivos
    -- grandes (>~64 KB) dentro del .love (zip) hacen que read() devuelva
    -- nil silenciosamente porque el descompresor los lee en bloques
    -- internamente pero la API de una sola pasada falla al intentar
    -- materializar el buffer completo en memoria de una vez.
    -- La lectura por chunks fuerza ese mismo camino de forma explícita,
    -- lo que funciona correctamente en todos los dispositivos.
    local raw = ""
    local file, openErr = love.filesystem.newFile(jsonPath)
    if file and file:open("r") then
        local CHUNK = 16 * 1024   -- 16 KB por chunk
        while true do
            local chunk, readErr = file:read(CHUNK)
            if not chunk or #chunk == 0 then break end
            raw = raw .. chunk
        end
        file:close()
    else
        print("[Level] No se pudo abrir '" .. tostring(jsonPath)
              .. "': " .. tostring(openErr))
    end

    -- Manejo de archivo vacío o ilegible (mismo comportamiento que Python:
    -- usar una estructura de nivel por defecto en lugar de explotar).
    raw = raw:match("^%s*(.-)%s*$")   -- trim whitespace / CRLF
    local data
    if raw == "" then
        print("[Level] '" .. tostring(jsonPath) .. "' está vacío — usando nivel por defecto.")
        data = {}
    else
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == "table" then
            data = decoded
        else
            print("[Level] Error al parsear '" .. tostring(jsonPath) .. "': "
                  .. tostring(decoded) .. " — usando nivel por defecto.")
            data = {}
        end
    end

    -- ── Plataformas ───────────────────────────────────────────────────────────
    self.platforms   = {}   -- sólidas ({ x,y,w,h, imageIndex })
    self.deathBlocks = {}   -- matan al jugador
    self.waterBlocks = {}   -- agua / cascada

    for _, p in ipairs(data.platforms or {}) do
        local idx = p.image_index or 0
        local rect = {
            x = p.x, y = p.y,
            w = p.width, h = p.height,
            imageIndex = idx,
        }
        if idx == IDX_DEATH then
            self.deathBlocks[#self.deathBlocks + 1] = rect
        elseif WATER_INDICES[idx] then
            self.waterBlocks[#self.waterBlocks + 1] = rect
        else
            self.platforms[#self.platforms + 1] = rect
        end
    end

    -- ── Posición inicial del jugador ──────────────────────────────────────────
    local ps = data.player_start or { 100, 100 }
    self.spawnX = ps[1] or ps.x or 100
    self.spawnY = ps[2] or ps.y or 100

    -- ── Door (condición de victoria) ──────────────────────────────────────────
    self.doorRect = nil
    if data.door then
        local d = data.door
        self.doorRect = {
            x = d[1] or d.x,
            y = d[2] or d.y,
            w = TILE_SIZE,
            h = TILE_SIZE * 2,
        }
    end

    -- ── Checkpoints ───────────────────────────────────────────────────────────
    self.checkpoints = {}
    for _, cp in ipairs(data.checkpoints or {}) do
        self.checkpoints[#self.checkpoints + 1] = {
            x         = cp[1] or cp.x,
            y         = cp[2] or cp.y,
            w         = TILE_SIZE,
            h         = TILE_SIZE,
            activated = false,
        }
    end
    self.respawnPos = nil   -- Vector {x, y} del último checkpoint activado

    -- ── Fondo ─────────────────────────────────────────────────────────────────
    self.backgroundImg = nil
    if data.background and love.filesystem.getInfo(data.background) then
        local ok, img = pcall(love.graphics.newImage, data.background)
        if ok then self.backgroundImg = img end
    end
    if not self.backgroundImg then
        self.backgroundImg = passets.images.skyBg
    end

    -- ── Door sprite escalada ──────────────────────────────────────────────────
    self.doorSprite = self:_scaledImage(passets.images.door, TILE_SIZE, TILE_SIZE * 2)

    -- ── Tiles precalculados al tamaño TILE_SIZE ───────────────────────────────
    self.tileImgs = {}
    for idx, img in pairs(passets.images.tiles) do
        self.tileImgs[idx] = self:_scaleOf(img)
    end

    -- ── Entidades ─────────────────────────────────────────────────────────────
    self.enemies = {}
    self.bosses  = {}
    self.enemySpawns = {}
    self.bossSpawns  = {}

    for _, e in ipairs(data.enemies or {}) do
        local ex = e.x or (e[1])
        local ey = e.y or (e[2])
        self.enemySpawns[#self.enemySpawns + 1] = { x = ex, y = ey }
    end
    for _, b in ipairs(data.bosses or {}) do
        local bx = b.x or (b[1])
        local by = b.y or (b[2])
        self.bossSpawns[#self.bossSpawns + 1] = { x = bx, y = by }
    end

    -- ── Jugador ───────────────────────────────────────────────────────────────
    self.player = Player.new(self.spawnX, self.spawnY, passets)

    self:_spawnEntities()

    -- ── Cámara ────────────────────────────────────────────────────────────────
    self.camX = self.spawnX - LOGI_W / 2
    self.camY = self.spawnY - LOGI_H / 2

    -- Deadzone (píxeles desde el borde del canvas antes de que la cámara mueva)
    self.dzLeft   = 500
    self.dzRight  = 500
    self.dzTop    = 300
    self.dzBottom = 300
    self.camSmooth = 0.12

    -- ── Screen shake ──────────────────────────────────────────────────────────
    self.shakeIntensity = 0
    self.shakeDuration  = 0
    self.shakeTimer     = 0
    self.shakeOffX      = 0
    self.shakeOffY      = 0

    -- ── State machine del nivel ───────────────────────────────────────────────
    -- "playing" | "dying" | "respawning" | "victory"
    self.gameState      = "playing"
    self.respawnTimer   = 0
    self.respawnDelay   = 1.5
    self.victoryTimer   = 0
    self.victoryDelay   = 3.0

    -- ── Fuentes locales ───────────────────────────────────────────────────────
    self.fontHUD     = passets.fonts.small
    self.fontOverlay = passets.fonts.overlay   -- precargada en love.load() → no crea textura GPU aquí
    self.fontSub     = passets.fonts.medium

    -- ── Culling margin ────────────────────────────────────────────────────────
    self.cullMargin = 120

    return self
end

-- =============================================================================
--  Helpers internos
-- =============================================================================

function Level:_scaleOf(img)
    -- Devuelve la escala (sx, sy) para dibujar img a TILE_SIZE
    return img, TILE_SIZE / img:getWidth(), TILE_SIZE / img:getHeight()
end

function Level:_scaledImage(img, tw, th)
    -- Devuelve { img, sx, sy }
    return { img = img, sx = tw / img:getWidth(), sy = th / img:getHeight() }
end

function Level:_spawnEntities()
    self.enemies = {}
    self.bosses  = {}
    for _, sp in ipairs(self.enemySpawns) do
        self.enemies[#self.enemies + 1] = Enemy.new(sp.x, sp.y, self.assets)
    end
    for _, sp in ipairs(self.bossSpawns) do
        self.bosses[#self.bosses + 1] = Boss.new(sp.x, sp.y, self.assets)
    end
end

function Level:_rectOverlap(ax, ay, aw, ah, bx, by, bw, bh)
    return ax < bx + bw and ax + aw > bx
       and ay < by + bh and ay + ah > by
end

function Level:_isOnScreen(rx, ry, rw, rh)
    return rx + rw > self.camX - self.cullMargin
       and rx       < self.camX + LOGI_W + self.cullMargin
       and ry + rh > self.camY - self.cullMargin
       and ry       < self.camY + LOGI_H + self.cullMargin
end

-- =============================================================================
--  Update
-- =============================================================================

-- Devuelve nil (sigue), "victory" o "exit"
function Level:update(dt)
    -- ── Mobile: inyectar overrides ANTES de cualquier lectura de input ────────
    local mc = self.mobileControls
    if mc and controls.mobile_mode then
        Controls.clearMobileOverrides()
        Controls.setMobileOverride("move_left",  mc.state.left)
        Controls.setMobileOverride("move_right", mc.state.right)
        Controls.setMobileOverride("move_up",    mc.state.up)
        Controls.setMobileOverride("move_down",  mc.state.down)
        Controls.setMobileOverride("jump",       mc.state.jump)

        -- ESC táctil (justPressed evita disparo múltiple por frame)
        if mc:justPressed("esc") then
            self._exitRequested = true
        end
    end
    self:_updateShake(dt)

    local p = self.player

    -- ── State machine ─────────────────────────────────────────────────────────
    if self.gameState == "playing" then
        -- Detectar muerte por salud
        if p.health <= 0 then
            self.gameState = "dying"
            p:startDeath()
        end

    elseif self.gameState == "dying" then
        p:updateDeathAnimation(dt)
        if p.deathFinished then
            self.gameState  = "respawning"
            self.respawnTimer = 0
        end

    elseif self.gameState == "respawning" then
        self.respawnTimer = self.respawnTimer + dt
        if self.respawnTimer >= self.respawnDelay then
            local rx = self.respawnPos and self.respawnPos.x or self.spawnX
            local ry = self.respawnPos and self.respawnPos.y or self.spawnY
            p:reset(rx, ry)
            self:_spawnEntities()
            self.gameState = "playing"
        end
        return nil

    elseif self.gameState == "victory" then
        self.victoryTimer = self.victoryTimer + dt
        -- Seguir actualizando bosses para que no queden congelados
        local allPlats = self:_allSolidRects()
        for _, b in ipairs(self.bosses) do
            b:update(dt, allPlats)
        end
        if self.victoryTimer >= self.victoryDelay then
            return "victory"
        end
        return nil
    end

    -- ── Plataformas sólidas (para física) ─────────────────────────────────────
    local solidRects = self:_allSolidRects()

    -- ── Actualizar jugador ────────────────────────────────────────────────────
    if self.gameState == "playing" then
        p:update(dt, solidRects, self.enemies, self.waterBlocks)

        -- Death blocks
        for _, db in ipairs(self.deathBlocks) do
            if self:_isOnScreen(db.x, db.y, db.w, db.h) then
                if self:_rectOverlap(p.x, p.y, p.hw, p.hh, db.x, db.y, db.w, db.h) then
                    p:takeDamage(999)
                end
            end
        end

        -- Checkpoints
        for _, cp in ipairs(self.checkpoints) do
            if not cp.activated then
                if self:_rectOverlap(p.x, p.y, p.hw, p.hh, cp.x, cp.y, cp.w, cp.h) then
                    cp.activated = true
                    self.respawnPos = {
                        x = cp.x + cp.w / 2,
                        y = cp.y + cp.h,
                    }
                end
            end
        end

        -- Door (victoria)
        if self.doorRect then
            local d = self.doorRect
            if self:_rectOverlap(p.x, p.y, p.hw, p.hh, d.x, d.y, d.w, d.h) then
                self.gameState  = "victory"
                self.victoryTimer = 0
                p:startVictory()
            end
        end

        -- ── Enemigos ─────────────────────────────────────────────────────────
        for _, e in ipairs(self.enemies) do
            e:update(dt, solidRects)
        end
        -- Limpiar enemigos muertos
        local liveEnemies = {}
        for _, e in ipairs(self.enemies) do
            if not e:shouldRemove() then
                liveEnemies[#liveEnemies + 1] = e
            end
        end
        self.enemies = liveEnemies

        -- ── Bosses ───────────────────────────────────────────────────────────
        for _, b in ipairs(self.bosses) do
            b:update(dt, solidRects)

            -- Screen shake al aterrizar
            if b.justLanded then
                local dx = p.x - b.x
                local dy = p.y - b.y
                local dist = math.sqrt(dx*dx + dy*dy)
                if dist < 700 then
                    self:_triggerShake(8, 0.15)
                end
            end

            if b.alive then
                local sz = b:getStompZone()
                local dz = b:getDamageZone()

                -- Pisada del jugador sobre el boss
                if p.velY > 0
                and self:_rectOverlap(p.x, p.y, p.hw, p.hh, sz.x, sz.y, sz.w, sz.h) then
                    local defeated = b:takeDamageFromAbove()
                    p.velY = -8
                    if defeated then
                        self.gameState  = "victory"
                        self.victoryTimer = 0
                        p:startVictory()
                    end
                end

                -- Boss daña al jugador
                if not p.invincible then
                    if self:_rectOverlap(p.x, p.y, p.hw, p.hh, dz.x, dz.y, dz.w, dz.h) then
                        p:takeDamage(p.damagePerHit)
                    end
                end
            end
        end
        -- Limpiar bosses
        local liveBosses = {}
        for _, b in ipairs(self.bosses) do
            if not b:shouldRemove() then
                liveBosses[#liveBosses + 1] = b
            end
        end
        self.bosses = liveBosses
    end

    -- ── Cámara ────────────────────────────────────────────────────────────────
    self:_updateCamera(dt)

    return nil
end

-- =============================================================================
--  Cámara y shake
-- =============================================================================

function Level:_updateCamera(dt)
    local p  = self.player
    local pcx = p.x + p.hw / 2
    local pcy = p.y + p.hh / 2

    local psx = pcx - self.camX
    local psy = pcy - self.camY

    local tx = self.camX
    local ty = self.camY

    if psx < self.dzLeft             then tx = pcx - self.dzLeft             end
    if psx > LOGI_W - self.dzRight   then tx = pcx - (LOGI_W - self.dzRight) end
    if psy < self.dzTop              then ty = pcy - self.dzTop              end
    if psy > LOGI_H - self.dzBottom  then ty = pcy - (LOGI_H - self.dzBottom) end

    local s = self.camSmooth * dt * 60
    self.camX = self.camX + (tx - self.camX) * s
    self.camY = self.camY + (ty - self.camY) * s
end

function Level:_triggerShake(intensity, duration)
    self.shakeIntensity = intensity
    self.shakeDuration  = duration
    self.shakeTimer     = 0
end

function Level:_updateShake(dt)
    if self.shakeTimer < self.shakeDuration then
        self.shakeTimer = self.shakeTimer + dt
        self.shakeOffX  = love.math.random(-self.shakeIntensity, self.shakeIntensity)
        self.shakeOffY  = love.math.random(-self.shakeIntensity, self.shakeIntensity)
    else
        self.shakeOffX = 0
        self.shakeOffY = 0
    end
end

-- =============================================================================
--  Construcción de la lista de rectángulos sólidos
-- =============================================================================

function Level:_allSolidRects()
    local out = {}
    for _, p in ipairs(self.platforms) do
        out[#out + 1] = p
    end
    return out
end

-- =============================================================================
--  Draw
-- =============================================================================

function Level:draw()
    local cx = self.camX - self.shakeOffX
    local cy = self.camY - self.shakeOffY

    -- ── Fondo ─────────────────────────────────────────────────────────────────
    love.graphics.setColor(1, 1, 1, 1)
    local bg = self.backgroundImg
    love.graphics.draw(bg, 0, 0, 0,
        LOGI_W / bg:getWidth(),
        LOGI_H / bg:getHeight())

    -- ── Agua (se dibuja debajo de todo) ───────────────────────────────────────
    for _, w in ipairs(self.waterBlocks) do
        if self:_isOnScreen(w.x, w.y, w.w, w.h) then
            local idx = w.imageIndex
            local img, sx, sy = self:_scaleOf(self.assets.images.tiles[idx]
                                              or self.assets.images.tiles[0])
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(img, w.x - cx, w.y - cy, 0, sx, sy)
        end
    end

    -- ── Plataformas sólidas ────────────────────────────────────────────────────
    for _, p in ipairs(self.platforms) do
        if self:_isOnScreen(p.x, p.y, p.w, p.h) then
            local idx = p.imageIndex
            local tileImg = self.assets.images.tiles[idx]
            love.graphics.setColor(1, 1, 1, 1)
            if tileImg then
                local img, sx, sy = self:_scaleOf(tileImg)
                love.graphics.draw(img, p.x - cx, p.y - cy, 0, sx, sy)
            else
                love.graphics.setColor(0.78, 0.78, 0.78, 1)
                love.graphics.rectangle("fill", p.x - cx, p.y - cy, p.w, p.h)
            end
        end
    end

    -- ── Death blocks: invisibles intencionalmente (trampa oculta) ───────────
    -- La colisión sigue activa en el update, solo se omite el render.

    -- ── Checkpoints ───────────────────────────────────────────────────────────
    for _, cp in ipairs(self.checkpoints) do
        if self:_isOnScreen(cp.x, cp.y, cp.w, cp.h) then
            love.graphics.setColor(1, 1, 1, 1)
            local cpImg = cp.activated
                and self.assets.images.checkpointActive
                 or self.assets.images.tiles[7]
            if cpImg then
                local img, sx, sy = self:_scaleOf(cpImg)
                love.graphics.draw(img, cp.x - cx, cp.y - cy, 0, sx, sy)
            else
                love.graphics.setColor(1, 0.85, 0, 1)
                love.graphics.rectangle("fill", cp.x - cx, cp.y - cy, cp.w, cp.h)
            end
        end
    end

    -- ── Door ──────────────────────────────────────────────────────────────────
    if self.doorRect then
        local d = self.doorRect
        if self:_isOnScreen(d.x, d.y, d.w, d.h) then
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(self.doorSprite.img,
                d.x - cx, d.y - cy, 0,
                self.doorSprite.sx, self.doorSprite.sy)
        end
    end

    -- ── Enemigos ──────────────────────────────────────────────────────────────
    for _, e in ipairs(self.enemies) do
        e:draw(cx, cy)
    end

    -- ── Bosses ────────────────────────────────────────────────────────────────
    for _, b in ipairs(self.bosses) do
        b:draw(cx, cy, false)
    end

    -- ── Jugador ───────────────────────────────────────────────────────────────
    self.player:draw(cx, cy)

    -- ── HUD del jugador ───────────────────────────────────────────────────────
    self.player:drawUI(LOGI_W, LOGI_H)

    -- ── Info del nivel ────────────────────────────────────────────────────────
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(self.fontHUD)
    love.graphics.print(self.name .. "    ESC: exit", 20, 20)

    -- ── Overlay de Game Over ──────────────────────────────────────────────────
    if self.gameState == "respawning" then
        love.graphics.setColor(0, 0, 0, 0.70)
        love.graphics.rectangle("fill", 0, 0, LOGI_W, LOGI_H)

        love.graphics.setFont(self.fontOverlay)
        local txt = "GAME OVER"
        love.graphics.setColor(1, 0.19, 0.19, 1)
        love.graphics.print(txt,
            (LOGI_W - self.fontOverlay:getWidth(txt)) / 2,
            LOGI_H / 2 - 70)

        love.graphics.setFont(self.fontSub)
        local sub = "Respawning..."
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.print(sub,
            (LOGI_W - self.fontSub:getWidth(sub)) / 2,
            LOGI_H / 2 + 30)
    end

    -- ── Overlay de Victoria ───────────────────────────────────────────────────
    if self.gameState == "victory" then
        love.graphics.setColor(0, 0, 0, 0.60)
        love.graphics.rectangle("fill", 0, 0, LOGI_W, LOGI_H)

        love.graphics.setFont(self.fontOverlay)
        local txt = "VICTORY!"
        love.graphics.setColor(1, 0.84, 0, 1)
        love.graphics.print(txt,
            (LOGI_W - self.fontOverlay:getWidth(txt)) / 2,
            LOGI_H / 2 - 70)

        love.graphics.setFont(self.fontSub)
        local sub = "Level Complete!"
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.print(sub,
            (LOGI_W - self.fontSub:getWidth(sub)) / 2,
            LOGI_H / 2 + 30)
    end

    -- ── Overlay de controles móviles (siempre encima de todo) ─────────────────
    if self.mobileControls and controls.mobile_mode then
        self.mobileControls:draw()
    end
end

-- =============================================================================
--  Input desde main.lua
-- =============================================================================

function Level:keypressed(key)
    if key == controls.back or key == "escape" then
        -- Señal de salida sin completar el nivel
        -- main.lua la recibe como resultado "exit" en update()
        self._exitRequested = true
    end
end

-- Sobreescribir update para checar la señal de salida
local _originalUpdate = Level.update
function Level:update(dt)
    if self._exitRequested then return "exit" end
    return _originalUpdate(self, dt)
end

return Level