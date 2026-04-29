-- =============================================================================
--  enemy.lua  PentagonMan (Love2D port)
--  Patrulla, detección de bordes, muerte por pisada, animación de muerte
-- =============================================================================

local Enemy = {}
Enemy.__index = Enemy

local SPRITE_W = 60
local SPRITE_H = 60

-- =============================================================================
--  Constructor
-- =============================================================================

function Enemy.new(x, y, passets)
    local self = setmetatable({}, Enemy)

    self.assets = passets

    self.x  = x
    self.y  = y
    self.hw = SPRITE_W
    self.hh = SPRITE_H

    -- Física
    self.speed        = 2.0
    self.gravity      = 0.5
    self.maxFallSpeed = 12
    self.velX         = -self.speed   -- empieza moviéndose a la izquierda
    self.velY         = 0
    self.direction    = -1            -- -1 = izquierda, 1 = derecha
    self.onGround     = false

    -- Estado
    self.alive      = true
    self.deathTimer = 0
    self.deathDuration = 0.25   -- tiempo antes de ser removido

    -- Animación de muerte (spritesheet)
    self.deathFrameIdx  = 1
    self.deathAnimTimer = 0
    self.deathAnimSpeed = 0.08
    self.deathQuads     = self:_buildDeathQuads()

    return self
end

-- =============================================================================
--  Quads de muerte
-- =============================================================================

function Enemy:_buildDeathQuads()
    local quads = {}
    local sheet = self.assets.images.enemyDeathSheet
    local data  = self.assets.data.enemyDeathFrames
    if not sheet or not data then return quads end

    local sw, sh = sheet:getDimensions()
    -- El JSON tiene data.frames como dict ordenado por nombre
    local names = {}
    for name in pairs(data.frames or {}) do
        names[#names + 1] = name
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local f = data.frames[name].frame
        quads[#quads + 1] = love.graphics.newQuad(f.x, f.y, f.w, f.h, sw, sh)
    end
    return quads
end

-- =============================================================================
--  Update
-- =============================================================================

function Enemy:update(dt, platforms)
    if not self.alive then
        self.deathTimer = self.deathTimer + dt
        -- Avanzar animación de muerte
        if #self.deathQuads > 0 then
            self.deathAnimTimer = self.deathAnimTimer + dt
            if self.deathAnimTimer >= self.deathAnimSpeed then
                self.deathAnimTimer = 0
                if self.deathFrameIdx < #self.deathQuads then
                    self.deathFrameIdx = self.deathFrameIdx + 1
                end
            end
        end
        return
    end

    -- Gravedad
    self.velY = self.velY + self.gravity * dt * 60
    if self.velY > self.maxFallSpeed then self.velY = self.maxFallSpeed end

    -- Movimiento horizontal
    self.x = self.x + self.velX * dt * 60
    self:_resolveHorizontal(platforms)

    -- Movimiento vertical
    self.y = self.y + self.velY * dt * 60
    self:_resolveVertical(platforms)

    -- Detección de borde de plataforma
    self:_checkEdge(platforms)
end

-- =============================================================================
--  Colisiones AABB
-- =============================================================================

function Enemy:overlaps(rx, ry, rw, rh)
    return self.x < rx + rw and self.x + self.hw > rx
       and self.y < ry + rh and self.y + self.hh > ry
end

function Enemy:_resolveHorizontal(platforms)
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

function Enemy:_resolveVertical(platforms)
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

function Enemy:_checkEdge(platforms)
    if not self.onGround then return end

    local checkDist = 10
    local checkX
    if self.direction == -1 then
        checkX = self.x - checkDist
    else
        checkX = self.x + self.hw + checkDist
    end
    local checkY = self.y + self.hh + 5

    local onPlatform = false
    for _, p in ipairs(platforms) do
        if checkX >= p.x and checkX <= p.x + p.w
        and checkY >= p.y and checkY <= p.y + p.h then
            onPlatform = true
            break
        end
    end

    if not onPlatform then
        self:_turnAround()
    end
end

function Enemy:_turnAround()
    self.direction = self.direction * -1
    self.velX      = self.speed * self.direction
end

-- =============================================================================
--  Daño
-- =============================================================================

function Enemy:takeHit()
    self.alive      = false
    self.deathTimer = 0
    self.deathFrameIdx  = 1
    self.deathAnimTimer = 0
end

function Enemy:shouldRemove()
    return not self.alive and self.deathTimer >= self.deathDuration
end

-- =============================================================================
--  Draw
-- =============================================================================

function Enemy:draw(camX, camY)
    local drawX = self.x - camX
    local drawY = self.y - camY

    love.graphics.setColor(1, 1, 1, 1)

    if not self.alive and #self.deathQuads > 0 then
        -- La animación de muerte no necesita flip (es simétrica)
        local sheet = self.assets.images.enemyDeathSheet
        local q     = self.deathQuads[self.deathFrameIdx]
        local _, _, qw, qh = q:getViewport()
        love.graphics.draw(sheet, q, drawX, drawY, 0,
            self.hw / qw, self.hh / qh)
    else
        -- FIX: voltear el sprite horizontalmente según la dirección de movimiento.
        -- La imagen base mira hacia la derecha (direction == 1).
        -- Cuando va hacia la izquierda (direction == -1) se dibuja con scaleX
        -- negativo, desplazando el origen al borde derecho del hitbox para que
        -- el sprite no se desplace fuera de él.
        local img    = self.assets.images.enemy
        local scaleX = self.hw / img:getWidth()
        local scaleY = self.hh / img:getHeight()
        if self.direction == -1 then
            -- Flip horizontal: origen en borde derecho, scaleX negativo
            love.graphics.draw(img, drawX + self.hw, drawY, 0, -scaleX, scaleY)
        else
            love.graphics.draw(img, drawX, drawY, 0, scaleX, scaleY)
        end
    end
end

return Enemy
