-- =============================================================================
--  boss.lua  PentagonMan (Love2D port)
--  KingCircleBoss: zonas stomp/daño, 3 hits, sprites normal/injured/dead
-- =============================================================================

local Boss = {}
Boss.__index = Boss

local DESIRED_H  = 160          -- altura lógica del boss
local STOMP_H    = 80           -- altura de la zona de pisada (parte superior)
local DAMAGE_H   = 80           -- altura de la zona de daño  (parte inferior)

-- =============================================================================
--  Constructor
-- =============================================================================

function Boss.new(x, y, passets)
    local self = setmetatable({}, Boss)

    self.assets = passets

    -- Calcular dimensiones escaladas a partir de los sprites
    local normImg = passets.images.boss.normal
    local origW, origH = normImg:getDimensions()
    local scale   = DESIRED_H / origH
    self.visualW  = math.max(1, math.floor(origW * scale))
    self.visualH  = DESIRED_H

    -- Posición (topleft del hitbox = visual)
    self.x  = x
    self.y  = y
    self.hw = self.visualW
    self.hh = self.visualH

    -- Física
    self.speed         = 3.5
    self.gravity       = 0.5
    self.jumpStrength  = -12
    self.maxFallSpeed  = 12
    self.velX          = self.speed
    self.velY          = 0
    self.direction     = 1          -- 1 = derecha, -1 = izquierda
    self.onGround      = false

    -- Combate
    self.hitsMax   = 3
    self.hitsTaken = 0
    self.alive     = true
    self.defeated  = false

    -- Invencibilidad temporal tras recibir golpe
    self.invincible         = false
    self.invincibleTimer    = 0
    self.invincibleDuration = 1.0

    -- Estados visuales
    self.showingInjured = false
    self.showingDead    = false
    self.animTimer      = 0         -- usado para remover al boss tras morir

    -- Detección de aterrizaje (para screen shake)
    self.wasInAir   = false
    self.justLanded = false

    -- Quads de sprites (uno por estado; se escalan en draw)
    self.spriteNormal  = passets.images.boss.normal
    self.spriteInjured = passets.images.boss.injured
    self.spriteDead    = passets.images.boss.dead

    return self
end

-- =============================================================================
--  Zonas de colisión (calculadas dinámicamente)
-- =============================================================================

-- Zona superior: donde el jugador pisa al boss
function Boss:getStompZone()
    return {
        x = self.x,
        y = self.y,
        w = self.hw,
        h = STOMP_H,
    }
end

-- Zona inferior: donde el boss daña al jugador
function Boss:getDamageZone()
    return {
        x = self.x,
        y = self.y + self.hh - DAMAGE_H,
        w = self.hw,
        h = DAMAGE_H,
    }
end

-- =============================================================================
--  Update
-- =============================================================================

function Boss:update(dt, platforms)
    if not self.alive then
        if self.showingDead then
            self.animTimer = self.animTimer + dt
        end
        return
    end

    -- Invencibilidad
    if self.invincible then
        self.invincibleTimer = self.invincibleTimer - dt
        if self.invincibleTimer <= 0 then
            self.invincible     = false
            self.showingInjured = false
        end
    end

    self.wasInAir = not self.onGround

    -- Gravedad
    self.velY = self.velY + self.gravity * dt * 60
    if self.velY > self.maxFallSpeed then self.velY = self.maxFallSpeed end

    -- Horizontal
    self.x = self.x + self.velX * dt * 60
    self:_resolveHorizontal(platforms)

    -- Vertical
    self.y = self.y + self.velY * dt * 60
    self:_resolveVertical(platforms)

    -- Aterrizaje detectado → salto automático
    self.justLanded = self.wasInAir and self.onGround
    if self.onGround then
        self.velY     = self.jumpStrength
        self.onGround = false
    end
end

-- =============================================================================
--  Colisiones AABB
-- =============================================================================

function Boss:overlaps(rx, ry, rw, rh)
    return self.x < rx + rw and self.x + self.hw > rx
       and self.y < ry + rh and self.y + self.hh > ry
end

function Boss:_resolveHorizontal(platforms)
    for _, p in ipairs(platforms) do
        if self:overlaps(p.x, p.y, p.w, p.h) then
            if self.velX < 0 then
                self.x = p.x + p.w
            elseif self.velX > 0 then
                self.x = p.x - self.hw
            end
            self:_turnAround()
        end
    end
end

function Boss:_resolveVertical(platforms)
    self.onGround = false
    for _, p in ipairs(platforms) do
        if self:overlaps(p.x, p.y, p.w, p.h) then
            if self.velY > 0 then
                self.y        = p.y - self.hh
                self.velY     = 0
                self.onGround = true
            elseif self.velY < 0 then
                self.y    = p.y + p.h
                self.velY = 0
            end
        end
    end
end

function Boss:_turnAround()
    self.direction = self.direction * -1
    self.velX      = self.speed * self.direction
end

-- =============================================================================
--  Recibir daño
-- =============================================================================

-- Devuelve true si el boss fue derrotado con este golpe
function Boss:takeDamageFromAbove()
    if self.invincible or not self.alive then return false end

    self.hitsTaken = self.hitsTaken + 1

    if self.hitsTaken >= self.hitsMax then
        self.alive        = false
        self.defeated     = true
        self.showingDead  = true
        self.animTimer    = 0
        return true
    else
        self.invincible      = true
        self.invincibleTimer = self.invincibleDuration
        self.showingInjured  = true
        return false
    end
end

function Boss:shouldRemove()
    -- Se elimina 1 segundo después de morir (para que se vea la animación de muerte)
    return self.showingDead and self.animTimer >= 1.0
end

-- =============================================================================
--  Draw
-- =============================================================================

function Boss:draw(camX, camY, showHitboxes)
    local drawX = self.x - camX
    local drawY = self.y - camY

    -- Parpadeo de invencibilidad
    local alpha = 1
    if self.invincible and not self.showingDead then
        alpha = (math.floor(self.invincibleTimer * 10) % 2 == 0) and 0.4 or 1
    end
    love.graphics.setColor(1, 1, 1, alpha)

    -- Elegir sprite según estado
    local img
    if self.showingDead then
        img = self.spriteDead
    elseif self.showingInjured then
        img = self.spriteInjured
    else
        img = self.spriteNormal
    end

    -- Flip horizontal según dirección
    local scaleX = self.hw / img:getWidth()
    local scaleY = self.hh / img:getHeight()
    if self.direction == -1 then
        -- Flip: dibujar desde la derecha hacia la izquierda
        love.graphics.draw(img,
            drawX + self.hw, drawY,
            0, -scaleX, scaleY)
    else
        love.graphics.draw(img, drawX, drawY, 0, scaleX, scaleY)
    end

    love.graphics.setColor(1, 1, 1, 1)

    -- Hitboxes de debug
    if showHitboxes then
        -- Hitbox principal (blanco)
        love.graphics.setColor(1, 1, 1, 0.7)
        love.graphics.rectangle("line", drawX, drawY, self.hw, self.hh)

        -- Zona stomp (verde)
        local sz = self:getStompZone()
        love.graphics.setColor(0, 1, 0, 0.7)
        love.graphics.rectangle("line", sz.x - camX, sz.y - camY, sz.w, sz.h)

        -- Zona daño (rojo)
        local dz = self:getDamageZone()
        love.graphics.setColor(1, 0, 0, 0.7)
        love.graphics.rectangle("line", dz.x - camX, dz.y - camY, dz.w, dz.h)

        love.graphics.setColor(1, 1, 1, 1)
    end
end

return Boss
