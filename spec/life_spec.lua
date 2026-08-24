-- luacheck: std luajit+busted

-- data/life.lua: how much life there really is (#91).
--
-- The bug is invisible from inside a single figure -- `life / max_life` is
-- perfectly self-consistent and perfectly wrong for anything carrying
-- die_at. These tests build each source kind the way 1.7.6 builds it, over
-- a fake actor, so the arithmetic and the trust rules are held to their
-- shape without a game: gear and passives (unattributable, permanent), a
-- sustain's talentTemporaryValue record, the two sustains and effects that
-- keep the id in a field of their own, a timed effect with duration left,
-- the same one about to lapse, and the adverse direction.
--
-- #91.

local manifest = require "spec.support.manifest"

local function load()
  local chunk = assert(loadfile(manifest.path("src/data/life.lua")))
  return chunk()
end

--- A fake actor, built the way the engine builds one: every temporary value
--- has an id, the amount lives at compute_vals[id], and whoever added it
--- kept the id somewhere. `add` returns the id, exactly as
--- Entity:addTemporaryValue does.
local function actor(over)
  local a = {
    life = 100, max_life = 100, die_at = 0,
    tmp = {}, tempeffect_def = {}, sustain_talents = {},
    compute_vals = { n = 0 },
  }
  function a:add(v)
    local id = self.compute_vals.n + 1
    self.compute_vals.n = id
    self.compute_vals[id] = v
    self.die_at = (self.die_at or 0) + v
    return id
  end
  --- A timed effect that went through effectTemporaryValue.
  function a:effect(id, name, amount, dur)
    self.tempeffect_def[id] = { name = name, desc = name:lower():gsub("_", " ") }
    self.tmp[id] = { effect_id = id, dur = dur, __tmpvals = { { "die_at", self:add(amount) } } }
    return self.tmp[id]
  end
  --- A timed effect that called addTemporaryValue and kept the id itself.
  function a:effectDirect(id, name, field, amount, dur)
    self.tempeffect_def[id] = { name = name, desc = name:lower():gsub("_", " ") }
    self.tmp[id] = { effect_id = id, dur = dur, [field] = self:add(amount) }
    return self.tmp[id]
  end
  --- A sustain, through talentTemporaryValue.
  function a:sustain(tid, amount)
    self.sustain_talents[tid] = { __tmpvals = { { "die_at", self:add(amount) } } }
  end
  --- A sustain that kept the id in a field of its own (Last Stand).
  function a:sustainDirect(tid, field, amount)
    self.sustain_talents[tid] = { [field] = self:add(amount) }
  end
  for k, v in pairs(over or {}) do a[k] = v end
  return a
end

describe("data/life.lua", function()
  local L

  setup(function() L = load() end)

  describe("the plain case", function()
    it("with no die_at at all it is life over max_life, as it always was", function()
      local r = L.of(actor({ life = 40 }))
      assert.equals(40, r.pool)
      assert.equals(100, r.max)
      assert.is_near(0.4, r.fraction, 1e-9)
      assert.is_near(0.4, r.safe_fraction, 1e-9)
      assert.is_true(r.trusted)
      assert.equals(0, r.permanent)
    end)

    it("reports full life when there is no life to read, rather than empty", function()
      -- max_life 0 is a broken or not-yet-built actor. Every site here read
      -- `or 1` before this module existed; reading 0 would stop the bot on
      -- a character that is fine.
      local r = L.of(actor({ life = 0, max_life = 0 }))
      assert.equals(1, r.fraction)
      assert.equals(1, r.safe_fraction)
    end)

    it("survives an actor with nothing on it", function()
      local r = L.of({})
      assert.equals(1, r.fraction)
      assert.equals(0, r.die_at)
      assert.same({}, r.expiring)
      assert.is_true(r.trusted)
      assert.equals(1, L.of().fraction)
    end)
  end)

  describe("permanent sources: gear and passives", function()
    -- A cloak of protection or a Lich's passive. Nothing records these
    -- against an effect or a sustain, so they are simply part of the
    -- character -- and the whole reason unattributed die_at is trusted.
    it("counts the whole pool: a Lich at -500 is not at 0% life", function()
      local a = actor({ life = 0, max_life = 100, die_at = -500 })
      local r = L.of(a)
      assert.equals(500, r.pool)
      assert.equals(600, r.max)
      assert.is_near(500 / 600, r.fraction, 1e-9)
      assert.is_near(500 / 600, r.safe_fraction, 1e-9)
      assert.equals(-500, r.permanent)
      assert.is_true(r.trusted)
    end)

    it("is exactly the game's own arithmetic", function()
      -- mod/class/Player.lua:465 and uiset/Minimalist.lua:785:
      -- (life - die_at) / (max_life - die_at).
      local a = actor({ life = -20, max_life = 200, die_at = -100 })
      local r = L.of(a)
      assert.is_near((-20 - -100) / (200 - -100), r.fraction, 1e-9)
    end)
  end)

  describe("sustains", function()
    it("trusts a sustain that is up, recorded through talentTemporaryValue", function()
      local a = actor({ life = 10 })
      a:sustain("T_NECROSIS", -300)
      local r = L.of(a)
      assert.equals(-300, r.sustained)
      assert.equals(0, r.permanent)
      assert.is_near(310 / 400, r.safe_fraction, 1e-9)
      assert.is_true(r.trusted)
    end)

    it("finds Last Stand, which keeps the id in a field of its own", function()
      -- techniques/weaponshield.lua:339 -- addTemporaryValue straight into
      -- ret.dieat, so __tmpvals has nothing to say about it.
      local a = actor({ life = -50, max_life = 100 })
      a:sustainDirect("T_LAST_STAND", "dieat", -400)
      local r = L.of(a)
      assert.equals(-400, r.sustained)
      assert.equals(0, r.permanent)
      assert.is_near(350 / 500, r.safe_fraction, 1e-9)
      assert.is_true(r.trusted)          -- at negative life, and not in danger
    end)

    it("a sustain with no die_at in it contributes nothing", function()
      local a = actor()
      a.sustain_talents.T_SOME_OTHER = { __tmpvals = { { "combat_def", 1 } } }
      a.sustain_talents.T_PLAIN = true
      assert.equals(0, L.of(a).sustained)
    end)
  end)

  describe("timed effects", function()
    it("counts one that outlasts the look-ahead", function()
      local a = actor({ life = -30, max_life = 100 })
      a:effect("EFF_HEROISM", "HEROISM", -200, 5)
      local r = L.of(a)
      assert.equals(-200, r.temporary)
      assert.is_near(170 / 300, r.safe_fraction, 1e-9)
      assert.is_true(r.trusted)
      assert.same({}, r.expiring)
    end)

    it("does NOT count one about to lapse: the point of the whole module", function()
      -- Heroism with one turn left, life below zero. The full figure says
      -- 57%; the bot must read empty and hand back BEFORE the effect goes,
      -- because afterwards life is 1 and the next hit is fatal.
      local a = actor({ life = -30, max_life = 100 })
      a:effect("EFF_HEROISM", "HEROISM", -200, 1)
      local r = L.of(a)
      assert.is_near(170 / 300, r.fraction, 1e-9)
      assert.equals(0, r.safe_fraction)
      assert.equals(-30, r.safe_pool)
      assert.is_false(r.trusted)
      assert.equals(1, #r.expiring)
      assert.equals("heroism", r.expiring[1].name)
    end)

    it("takes the look-ahead as given", function()
      local a = actor({ life = 10 })
      a:effect("EFF_HEROISM", "HEROISM", -100, 2)
      assert.is_true(L.of(a, 1).trusted)
      assert.is_false(L.of(a, 2).trusted)
      assert.is_true(L.of(a, 2).safe_fraction < L.of(a, 1).safe_fraction)
    end)

    it("finds the two effects that keep the id in a field of their own", function()
      -- mental.lua:1765 (eff.dieatid) and physical.lua:3528 (eff.die).
      local a = actor({ life = 10 })
      a:effectDirect("EFF_FRENZY", "FRENZY", "dieatid", -50, 4)
      a:effectDirect("EFF_ROGUE_S_BREW", "ROGUE_S_BREW", "die", -30, 4)
      local r = L.of(a)
      assert.equals(-80, r.temporary)
      assert.equals(0, r.permanent)
    end)

    it("ignores a numeric field on an effect that is not one of those", function()
      -- The field names are read only for the effects known to use them.
      -- Any effect may carry a number called `die`; treating it as a
      -- temporary-value id would invent a life pool out of nothing.
      local a = actor({ life = 10 })
      a:effectDirect("EFF_SOMETHING", "SOMETHING_ELSE", "die", -50, 4)
      local r = L.of(a)
      assert.equals(0, r.temporary)
      assert.equals(0, r.die_at - r.permanent - r.sustained - r.temporary)
    end)

    it("adds up several, and keeps only the lapsing ones as expiring", function()
      local a = actor({ life = 0, max_life = 100 })
      a:effect("EFF_HEROISM", "HEROISM", -200, 1)
      a:effect("EFF_OTHER", "OTHER", -100, 9)
      a:sustain("T_NECROSIS", -50)
      local r = L.of(a)
      assert.equals(-350, r.die_at)
      assert.equals(-300, r.temporary)
      assert.equals(-50, r.sustained)
      assert.equals(0, r.permanent)
      assert.equals(-150, r.safe_die_at)         -- 100 lasting + 50 sustained
      assert.equals(1, #r.expiring)
      assert.equals("heroism", r.expiring[1].name)
    end)
  end)

  describe("the adverse direction", function()
    -- magical.lua:3740: die_at +50. Death arrives EARLY, and no duration
    -- makes that discountable: dropping it would be the module handing back
    -- confidence it does not have.
    it("lowers both figures, whatever its duration", function()
      local a = actor({ life = 60, max_life = 100 })
      a:effect("EFF_CURSE", "CURSE_OF_DEATH", 50, 1)
      local r = L.of(a)
      assert.equals(50, r.die_at)
      assert.equals(50, r.safe_die_at)
      assert.is_near(10 / 50, r.fraction, 1e-9)
      assert.is_near(10 / 50, r.safe_fraction, 1e-9)
      assert.is_true(r.trusted)
      assert.same({}, r.expiring)
    end)

    it("reads empty when die_at has passed max_life", function()
      local a = actor({ life = 30, max_life = 40 })
      a:effect("EFF_CURSE", "CURSE_OF_DEATH", 50, 3)
      local r = L.of(a)
      assert.equals(0, r.fraction)
      assert.equals(0, r.safe_fraction)
    end)

    it("keeps an adverse effect while discounting a lapsing beneficial one", function()
      local a = actor({ life = 20, max_life = 100 })
      a:effect("EFF_HEROISM", "HEROISM", -200, 1)
      a:effect("EFF_CURSE", "CURSE_OF_DEATH", 50, 1)
      local r = L.of(a)
      assert.equals(-150, r.die_at)
      assert.equals(50, r.safe_die_at)
      assert.equals(1, #r.expiring)
      assert.equals("heroism", r.expiring[1].name)
    end)
  end)

  describe("what it says", function()
    it("gives one figure when the two agree", function()
      assert.equals("40% of your life pool", L.describe(L.of(actor({ life = 40 }))))
    end)

    it("gives both, and names what it did not count, when they differ", function()
      local a = actor({ life = -30, max_life = 100 })
      a:effect("EFF_HEROISM", "HEROISM", -200, 1)
      assert.equals("0% of your life pool (57% counting heroism, which is about to end)",
        L.describe(L.of(a)))
    end)

    it("rounds to nearest, and says nothing about nothing", function()
      assert.equals(57, L.percent(0.567))
      assert.equals(0, L.percent(nil))
      assert.equals("", L.describe(nil))
    end)
  end)
end)
