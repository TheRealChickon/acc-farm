-- Closed-loop seed steering for one battle-tower wave (2026-10-17, v4). Whousleaks only, slot_15 only.
-- Commands: fightBattleTowerWave once (floor 1 on a safe second; skipped with _G.__ST_ATTACH), setBattleSpeed only otherwise.
-- >= 1.5 s between commands. Needs steer_helper.py on the PC (answers steer_req.json with steer_plan_<seed>.json).
-- Every floor: press until the speed is the base speed (_G.__ST_SPEED), ask the PC for the engine plan at that speed.
-- At every client turn key the plan knows, forecast the end:  P = t_key + KA * engine s left * (plan speed / speed now)
--   + KB * turn changes left + TAIL   (fitted on live floors). Next floor's seed = floor(P - D).
-- If that second loses or sits near a boundary, pick the nearest reachable winning second (neighbours winning preferred) and press
-- (speed s -> s + 0.5, which shortens the rest; 4.5 wraps to 1, which lengthens it) at the moment that puts the end in its middle.
-- Up to MAXP steering presses per floor (a coarse early one, then corrections). Log: AnimeCardClash/steer_log.json. Stop: _G.__ST_STOP = true.
if game.Players.LocalPlayer.Name ~= "Whousleaks" then print("ST WRONG ACCOUNT") return end
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local comps = require(RS.shared.components)
local jecs = require(RS.rbxts_include.node_modules["@rbxts"].jecs.src.jecs)
local ctx = _G.__BS_CTX
if not ctx then print("ST ABORT no ctx") return end
local function remote(n) for _, d in ipairs(RS:GetDescendants()) do if d.Name == n and d:IsA("RemoteEvent") and not d:GetFullName():find("JABBY", 1, true) then return d end end end
local R = { fight = remote("fightBattleTowerWave"), speed = remote("setBattleSpeed") }
if not R.fight or not R.speed then print("ST ABORT remote missing") return end
local TOWER, WAVE, SPEED = _G.__ST_TOWER or "darkness", _G.__ST_WAVE or 6, _G.__ST_SPEED or 2
local D = _G.__ST_D or 0.085           -- client sees the fight end this long after the server (0.08-0.09, from 15 floors)
local KA = _G.__ST_KA or 1.16          -- real s per engine s (delay/speed)
local KB = _G.__ST_KB or 0.49          -- real s per remaining turn change
local TAIL = _G.__ST_TAIL or 0.5       -- end seen this long after the engine's last turn
local DECIDE = _G.__ST_DECIDE or 25    -- consider presses once the forecast end is this close (s)
local LAT = _G.__ST_LAT or 0.07        -- fire this much before the computed press moment
local MAXP = _G.__ST_MAXP or 3         -- steering presses per floor
local ATTACH = _G.__ST_ATTACH == true
local W = ctx.world
local now = function() return workspace:GetServerTimeNow() end
_G.__ST_STOP = false
_G.__ST_GEN = (_G.__ST_GEN or 0) + 1
local GEN = _G.__ST_GEN
local LOG = { tower = TOWER, wave = WAVE, speed = SPEED, D = D, KA = KA, KB = KB, TAIL = TAIL, events = {} }
local lastSave = 0
local function save(force) if force or os.clock() - lastSave > 0.5 then lastSave = os.clock() pcall(writefile, "AnimeCardClash/steer_log.json", HS:JSONEncode(LOG)) end end
local function log(kind, t) t = t or {} t.kind = kind t.at = now() table.insert(LOG.events, t) save(kind ~= "pred") end
local function stopped() return _G.__ST_STOP or _G.__ST_GEN ~= GEN end
local function moonNow() local ok, m = pcall(ctx.moonCycle) if ok and m and m.current then return m.current, (m.lastChanged and m.duration) and (m.lastChanged + m.duration) or nil end return "none", nil end
local function sess() for e, v in W:query(comps.BattleSession) do if v.type == "battle_tower" then return e, v end end end
local function battle() for e, b in W:query(comps.Battle) do return e, b end end
local function turnKey(be, b)
  local t = {}
  for _, p in W:query(comps.BattlePlayer, jecs.pair(jecs.ChildOf, be)) do if p.side then t[p.side] = p.turn end end
  return tostring(t.player_1) .. "/" .. tostring(t.player_2) .. "/" .. tostring(b.activeSide)
end
local lastCmd, presses = -10, 0
local function fire(se, why)
  local sv = ctx.clientToServerEntities[se]
  if sv == nil or presses >= 150 then log("pressFail", { why = why }) return false end
  while now() - lastCmd < 1.5 do task.wait(0.01) end
  R.speed:FireServer(sv) lastCmd = now() presses += 1
  log("press", { why = why, n = presses })
  return true
end
local function nextSpeed(s) if s >= 4.5 then return 1 end return s + 0.5 end
local function readJson(f) local ok, v = pcall(function() return HS:JSONDecode(readfile(f)) end) return ok and v or nil end

task.spawn(function()
  if ATTACH then
    if not sess() then print("ST ABORT nothing to attach to") return end
    log("attach")
  else
    local plan1 = readJson(("AnimeCardClash/tw_times_%s_%d.json"):format(TOWER, WAVE))
    local T
    for _, s in ipairs(plan1 and plan1.safe or {}) do if s >= now() + 10 and (T == nil or s < T) then T = s end end
    if not T then print("ST ABORT no safe second") log("abort", { why = "no safe second" }) return end
    if sess() then print("ST ABORT a tower session already exists") log("abort", { why = "session exists" }) return end
    log("planned", { target = T })
    print("ST start at", T, "in", math.floor(T - now()), "s")
    while now() < T + 0.1 do task.wait(0.05) if stopped() then log("aborted") return end end
    while now() < T + 0.35 do end
    R.fight:FireServer(TOWER, WAVE, "slot_15") lastCmd = now()
    log("fight", { target = T })
  end

  local t0, lastSeen, seen = os.clock(), os.clock(), false
  local F = nil
  local prevTarget = nil
  local reqN = 0
  local function newFloor(seed, tStart, speedNow)
    local m, mEnd = moonNow()
    if F and F.wins then log("landed", { seed = seed, wins = F.wins[seed] == true, target = prevTarget, hit = prevTarget == seed }) end
    prevTarget = nil
    F = { seed = seed, tStart = tStart, plan = nil, key = nil, steers = 0, tPress = nil, choice = nil, settled = false, moon = m, moonEnd = mEnd }
    log("floor", { seed = seed, tStart = tStart, speed = speedNow, moon = m, moonEnd = mEnd })
  end

  while not stopped() and os.clock() - t0 < 2400 do
    task.wait(0.02)
    local ok, err = pcall(function()
      local se, s = sess()
      if not se then
        if seen and os.clock() - lastSeen > 15 then _G.__ST_STOP = true end
        if not seen and os.clock() - t0 > 40 then log("nostart") _G.__ST_STOP = true end
        return
      end
      seen, lastSeen = true, os.clock()
      if F == nil or s.seed ~= F.seed then
        local _, b0 = battle()
        newFloor(s.seed, now(), b0 and b0.speed or s.battleSpeed)
      end
      local be, b = battle()
      if not be then return end
      -- 1) base speed, then ask the PC for the plan at that speed
      if not F.settled then
        if b.speed == SPEED then
          F.settled = true F.speed = SPEED reqN += 1
          pcall(writefile, "AnimeCardClash/steer_req.json", HS:JSONEncode({ id = F.seed * 10 + reqN % 10, seed = F.seed, speed = SPEED, moon = F.moon, moonEnd = F.moonEnd, tStart = F.tStart }))
          log("settled", { speed = SPEED })
        elseif now() - lastCmd >= 1.5 and b.winner == nil then
          fire(se, "base speed")
        end
        return
      end
      if not F.plan then
        local p = readJson(("AnimeCardClash/steer_plan_%d.json"):format(F.seed))
        if p and p.seed == F.seed and p.speed == F.speed then
          F.plan = p F.wins = {} F.mt = {}
          for _, x in ipairs(p.wins) do F.wins[x] = true end
          for _, v in pairs(p.marks) do table.insert(F.mt, v[1]) end
          log("plan", { winner = p.winner, total = p.total, nwins = #p.wins, from = p.from, to = p.to })
        end
      end
      if not F.plan then return end
      -- 2) forecast at each known turn key
      local k = turnKey(be, b)
      if k ~= F.key then
        F.key = k
        local m = F.plan.marks[k]
        if m then
          local tk, ek = now(), m[1]
          local keysLeft = 0
          for _, x in ipairs(F.mt) do if x > ek + 1e-6 then keysLeft += 1 end end
          local q = F.speed / b.speed
          F.fixed = KB * keysLeft + TAIL
          F.P = tk + KA * (F.plan.total - ek) * q + F.fixed
          F.choice = nil   -- re-decide with the fresh forecast
          log("pred", { key = k, e = ek, P = F.P, speed = b.speed, keysLeft = keysLeft, next = math.floor(F.P - D) })
        else
          log("pred", { key = k, unknown = true })
        end
      end
      local P = F.P
      if not P or F.plan.winner ~= "player_1" then return end
      if P - now() > DECIDE then return end
      -- 3) decide
      if not F.choice then
        local x = P - D
        local Scur = math.floor(x)
        local frac = x - Scur
        local wn = F.wins
        local okHere = wn[Scur] and ((frac >= 0.3 and frac <= 0.7) or (frac < 0.3 and wn[Scur - 1]) or (frac > 0.7 and wn[Scur + 1]))
        if okHere then
          F.choice = { keep = true, S = Scur } F.tPress = nil prevTarget = Scur
          log("keep", { S = Scur, frac = frac, P = P })
        elseif F.steers >= MAXP then
          F.choice = { none = true } F.tPress = nil
          log("noPressLeft", { P = P, Scur = Scur, frac = frac })
        else
          local s1 = b.speed local s2 = nextSpeed(s1) local qq = s1 / s2
          local fx = F.fixed or TAIL
          local best
          for pass = 1, 2 do
            for d = 0, 30 do
              local S = (qq < 1) and (Scur - d) or (Scur + d)
              local good = wn[S] and (pass == 2 or (wn[S - 1] and wn[S + 1]))
              if good and not best then
                local X = S + 0.5 + D
                local tp = (X - fx - (P - fx) * qq) / (1 - qq)
                if tp >= math.max(now() + 0.3, lastCmd + 1.5) and tp < P - fx - 0.1 then best = { S = S, X = X, tp = tp, pass = pass } end
              end
            end
          end
          if best then
            F.choice = best F.tPress = best.tp prevTarget = best.S
            log("steer", { S = best.S, X = best.X, tPress = best.tp, P = P, s1 = s1, s2 = s2, pass = best.pass })
          else
            F.choice = { none = true } F.tPress = nil
            log("noChoice", { P = P, Scur = Scur, frac = frac })
          end
        end
      end
      -- 4) press at the computed moment
      if F.tPress and now() >= F.tPress - LAT then
        local s1 = b.speed
        F.tPress = nil
        if fire(se, "steer to " .. tostring(F.choice.S)) then
          F.steers += 1
          local fx = F.fixed or TAIL
          local q = s1 / nextSpeed(s1)
          local at = now()
          F.P = at + (P - fx - at) * q + fx
          log("pressed", { target = F.choice.S, Pbefore = P, Pafter = F.P, s1 = s1, steers = F.steers })
          F.choice = nil
        end
      end
    end)
    if not ok then log("error", { err = tostring(err) }) end
  end
  if F and F.wins and prevTarget then log("landed", { seed = nil, note = "session ended", target = prevTarget }) end
  log("stop") save(true) print("ST over")
end)
