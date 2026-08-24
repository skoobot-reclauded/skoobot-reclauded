-- luacheck: std luajit+busted

-- data/loadout.lua reads a suggested set of talent rules off the game's own
-- talent metadata (#18): the `tactical` tables the NPC AI uses, `mode`,
-- `sustain_slots`, `hide`, `cooldown`. It is a pure module, so every branch
-- of the classification rule is pinned here with fixture definitions, and the
-- rule is validated against the one hand-tuned build on record -- mishander's
-- rejected Sun Paladin preset (docs/salvage-mishander.md item 12), which it
-- reproduces 13 of 14 from metadata alone.
--
-- Fixture `tactical` tables are written the way the data files spell them
-- (UPPER CASE keys); the tome module lower-cases them when a talent is
-- loaded, and one test feeds the runtime form to prove both are read.

local manifest = require "spec.support.manifest"

local function load(rel)
  local chunk = assert(loadfile(manifest.path(rel)))
  return chunk()
end

--- One talent as the caller hands it in: {tid=, t=<def fields>, level=, active=, name=}.
local function talent(tid, def, over)
  local e = { tid = tid, t = def, name = tid }
  for k, v in pairs(over or {}) do e[k] = v end
  return e
end

local function sectionOf(proposal)
  local out = {}
  for _, e in ipairs(proposal.entries) do out[e.tid] = e.section end
  return out
end

local function tidsIn(proposal, section)
  local out = {}
  for _, e in ipairs(proposal.entries) do
    if e.section == section then out[#out + 1] = e.tid end
  end
  return out
end

local function find(list, tid)
  for _, e in ipairs(list) do if e.tid == tid then return e end end
  return nil
end

--- The Sun Paladin validation set: the field values of the real 1.7.6
--- definitions, copied from data/talents (celestial/sun.lua, combat.lua,
--- chants.lua; techniques/weaponshield.lua, 2hweapon.lua; misc/objects.lua,
--- inscriptions.lua). Chant of Fortress is the active chant, as in the preset.
local function sunPaladin()
  local sunRayTactical = function(self)
    local tacs = { attack = { LIGHT = 2 } }
    if self and self.level and self.level >= 3 then error("needs a target: aiTalentTactics on nil") end
    return tacs
  end
  return {
    talent("T_SUN_BEAM", { cooldown = 9, requires_target = true, tactical = sunRayTactical }),
    talent("T_SHIELD_PUMMEL", { cooldown = 6, requires_target = true,
      tactical = { ATTACK = 1, DISABLE = { stun = 3 } }, on_pre_use = function() return true end }),
    talent("T_STUNNING_BLOW", { cooldown = 6, requires_target = true,
      tactical = { ATTACK = { weapon = 2 }, DISABLE = { stun = 2 } }, on_pre_use = function() return true end }),
    talent("T_EXECUTION", { cooldown = 8, requires_target = true,
      tactical = { ATTACK = { weapon = 1 } }, on_pre_use = function() return true end }),
    talent("T_BLOCK", { cooldown = 8, requires_target = true,
      tactical = { ATTACK = 3, DEFEND = 3 }, on_pre_use = function() return true end }),
    talent("T_DEATH_DANCE", { cooldown = 10, requires_target = true,
      tactical = { ATTACKAREA = { weapon = 3 } }, on_pre_use = function() return true end }),
    talent("T_SHIELD_SLAM", { cooldown = 10, requires_target = true,
      tactical = { ATTACK = 2 }, on_pre_use = function() return true end }),
    talent("T_WAVE_OF_POWER", { cooldown = 6, requires_target = true, tactical = { ATTACK = 2 } }),
    talent("T_WEAPON_OF_LIGHT", { mode = "sustained", cooldown = 10, tactical = { BUFF = 2 } }),
    talent("T_WEAPON_OF_WRATH", { mode = "sustained", cooldown = 10, tactical = { BUFF = 2 } }),
    talent("T_CHANT_OF_FORTITUDE", { mode = "sustained", hide = true, cooldown = 12,
      tactical = { DEFEND = 2 }, sustain_slots = "celestial_chant" }),
    talent("T_CHANT_OF_FORTRESS", { mode = "sustained", hide = true, cooldown = 12,
      tactical = { DEFEND = 2 }, sustain_slots = "celestial_chant" }, { active = true }),
    talent("T_CHANT_OF_RESISTANCE", { mode = "sustained", hide = true, cooldown = 12,
      tactical = { DEFEND = 2 }, sustain_slots = "celestial_chant" }),
    talent("T_SECOND_LIFE", { mode = "sustained", cooldown = 30, tactical = { DEFEND = 2 } }),
    talent("T_RUNE:_SHIELDING_1", { cooldown = 14, tactical = { DEFEND = 2 },
      on_pre_use = function() return true end }),
    talent("T_INFUSION:_REGENERATION_1", { cooldown = 13, tactical = { HEAL = 2 },
      on_pre_use = function() return true end }),
    -- every actor knows these two; they are part of the real character
    talent("T_ATTACK", { hide = "always", requires_target = true, tactical = { ATTACK = { weapon = 1 } } }),
    talent("T_STAMINA_POOL", { mode = "passive", hide = "always" }),
  }
end

describe("data/loadout.lua", function()
  local L, R

  setup(function()
    L = load("src/data/loadout.lua")
    R = load("src/data/rules.lua")
  end)

  it("is a pure module exposing discover, unplaced and apply", function()
    assert.is_function(L.discover)
    assert.is_function(L.unplaced)
    assert.is_function(L.apply)
    assert.are.same(R.SECTIONS, L.SECTIONS, "the sections are the ones data/rules.lua names")
  end)

  it("returns an empty proposal for no talents", function()
    local p = L.discover({})
    assert.are.same({}, p.entries)
    assert.are.same({}, p.unassigned)
    assert.are.same({}, p.skipped)
    assert.are.same({}, p.choices)
    assert.are.same({ entries = 0, unassigned = 0, skipped = 0, choices = 0 }, p.counts)
    assert.are.same({}, L.discover(nil).entries)
  end)

  describe("the classification rule, step by step", function()
    it("1: ignores passive talents entirely", function()
      local p = L.discover({ talent("T_P", { mode = "passive", tactical = { ATTACK = 2 } }) })
      assert.are.equal(0, p.counts.entries + p.counts.unassigned + p.counts.skipped)
    end)

    it("2: skips what the game marks no_npc_use or no_dumb_use, and says so", function()
      local p = L.discover({
        talent("T_NPC", { no_npc_use = true, tactical = { ATTACK = 2 } }),
        talent("T_DUMB", { no_dumb_use = true, tactical = { HEAL = 2 } }),
      })
      assert.are.same({}, p.entries)
      assert.are.equal(2, #p.skipped)
      assert.matches("no_npc_use", find(p.skipped, "T_NPC").reason)
      assert.matches("no_dumb_use", find(p.skipped, "T_DUMB").reason)
      assert.are.same({}, p.unassigned, "skipped is not unassigned: these are not the player's to place")
    end)

    it("3: leaves a talent with no tactical data unassigned, with that reason", function()
      local p = L.discover({ talent("T_NONE", { cooldown = 5 }), talent("T_SUS", { mode = "sustained" }) })
      assert.are.same({}, p.entries)
      assert.are.equal(2, #p.unassigned)
      assert.are.equal("no tactical data", find(p.unassigned, "T_NONE").reason)
      assert.are.equal("no tactical data", find(p.unassigned, "T_SUS").reason)
    end)

    it("4: puts every sustained talent with tactical data in Sustain, whatever the keys", function()
      local p = L.discover({
        talent("T_A", { mode = "sustained", tactical = { BUFF = 2 } }),
        talent("T_B", { mode = "sustained", tactical = { ATTACK = 2 } }),
        talent("T_C", { mode = "sustained", tactical = { ESCAPE = 2 } }),
        talent("T_D", { mode = "sustained", tactical = function() error("needs a target") end }),
      })
      assert.are.same({ Sustain = true }, (function()
        local s = {} for _, e in ipairs(p.entries) do s[e.section] = true end return s
      end)())
      assert.are.equal(4, #p.entries)
      assert.matches("^sustained; BUFF", find(p.entries, "T_A").reason)
      assert.are.equal("sustained", find(p.entries, "T_D").reason)
    end)

    describe("5: a function-form tactical", function()
      it("is called once with the actor and no target, and its table is used", function()
        local calls = {}
        local def = { cooldown = 3, tactical = function(self, t, target)
          calls[#calls + 1] = { self = self, t = t, target = target }
          return { heal = 2 }
        end }
        local actor = { name = "me" }
        local p = L.discover({ talent("T_F", def) }, { self = actor })
        assert.are.equal(1, #calls)
        assert.are.equal(actor, calls[1].self)
        assert.are.equal(def, calls[1].t)
        assert.is_nil(calls[1].target)
        assert.are.equal("Recovery", sectionOf(p).T_F)
      end)

      it("that yields nothing goes to Combat when the talent requires a target", function()
        local p = L.discover({
          talent("T_ERR", { requires_target = true, tactical = function() error("no target") end }),
          talent("T_NIL", { requires_target = true, tactical = function() return nil end }),
        })
        assert.are.equal("Combat", sectionOf(p).T_ERR)
        assert.are.equal("Combat", sectionOf(p).T_NIL)
        assert.matches("needs a target", find(p.entries, "T_ERR").reason)
      end)

      it("that yields nothing and needs no target is unassigned", function()
        local p = L.discover({ talent("T_ERR", { tactical = function() error("no target") end }) })
        assert.are.same({}, p.entries)
        assert.matches("live target", find(p.unassigned, "T_ERR").reason)
      end)
    end)

    it("6: ATTACK, ATTACKAREA or DISABLE is Combat, even beside CLOSEIN or DEFEND", function()
      local p = L.discover({
        talent("T_ATK", { tactical = { ATTACK = { weapon = 2 } } }),
        talent("T_AREA", { tactical = { ATTACKAREA = { FIRE = 2 } } }),
        talent("T_DIS", { tactical = { DISABLE = { stun = 2 } } }),
        talent("T_RUSH", { tactical = { ATTACK = { weapon = 1 }, CLOSEIN = 3 } }),
        talent("T_BLOCK", { tactical = { ATTACK = 3, DEFEND = 3 } }),
        talent("T_HEALHIT", { tactical = { ATTACK = 2, HEAL = 1 } }),
      })
      local s = sectionOf(p)
      for _, tid in ipairs({ "T_ATK", "T_AREA", "T_DIS", "T_RUSH", "T_BLOCK", "T_HEALHIT" }) do
        assert.are.equal("Combat", s[tid], tid)
      end
      assert.matches("ATTACK, CLOSEIN", find(p.entries, "T_RUSH").reason)
    end)

    it("7: HEAL is Recovery", function()
      local p = L.discover({ talent("T_HEAL", { tactical = { HEAL = 2 } }),
        talent("T_HEALDEF", { tactical = { HEAL = 2, DEFEND = 1 } }) })
      assert.are.equal("Recovery", sectionOf(p).T_HEAL)
      assert.are.equal("Recovery", sectionOf(p).T_HEALDEF)
    end)

    it("8: DEFEND is Damage Prevention", function()
      local p = L.discover({ talent("T_SHIELD", { tactical = { DEFEND = 2 } }),
        talent("T_SHIELDCURE", { tactical = { DEFEND = 2, CURE = 2 } }) })
      assert.are.equal("DamagePrevention", sectionOf(p).T_SHIELD)
      assert.are.equal("DamagePrevention", sectionOf(p).T_SHIELDCURE)
    end)

    it("9: anything else is unassigned, with the key named and explained", function()
      local p = L.discover({
        talent("T_PHASE", { tactical = { ESCAPE = 3 } }),
        talent("T_BLINK", { tactical = { ESCAPE = 1, CLOSEIN = 1 } }),
        talent("T_RUSHONLY", { tactical = { CLOSEIN = 3 } }),
        talent("T_SHOUT", { tactical = { BUFF = 2 } }),
        talent("T_SHOOTDOWN", { tactical = { SPECIAL = 2 } }),
        talent("T_CURE", { tactical = { CURE = 2 } }),
        talent("T_MANA", { tactical = { MANA = 1 } }),
      })
      assert.are.same({}, p.entries)
      assert.are.equal(7, #p.unassigned)
      assert.matches("ESCAPE", find(p.unassigned, "T_PHASE").reason)
      assert.matches("flee", find(p.unassigned, "T_PHASE").reason)
      assert.matches("ESCAPE", find(p.unassigned, "T_BLINK").reason)
      assert.matches("CLOSEIN", find(p.unassigned, "T_BLINK").reason)
      assert.matches("CLOSEIN", find(p.unassigned, "T_RUSHONLY").reason)
      assert.matches("BUFF", find(p.unassigned, "T_SHOUT").reason)
      assert.matches("SPECIAL", find(p.unassigned, "T_SHOOTDOWN").reason)
      assert.matches("CURE", find(p.unassigned, "T_CURE").reason)
      assert.matches("MANA", find(p.unassigned, "T_MANA").reason)
      assert.matches("resource", find(p.unassigned, "T_MANA").reason)
    end)

    it("reads the runtime (lower-case) key form and a `self` sub-table", function()
      local p = L.discover({
        talent("T_LOW", { tactical = { attack = { weapon = 2 }, disable = { stun = 2 } } }),
        talent("T_SELF", { tactical = { self = { heal = 2 } } }),
      })
      assert.are.equal("Combat", sectionOf(p).T_LOW)
      assert.are.equal("Recovery", sectionOf(p).T_SELF)
    end)

    it("treats a missing mode as activated, the engine's default", function()
      local p = L.discover({ talent("T_ATTACK", { tactical = { ATTACK = { weapon = 1 } } }) })
      assert.are.equal("Combat", sectionOf(p).T_ATTACK)
    end)
  end)

  describe("the guards", function()
    it("keeps hidden talents and marks them", function()
      local p = L.discover({
        talent("T_H", { hide = true, tactical = { ATTACK = 2 } }),
        talent("T_A", { hide = "always", tactical = { ATTACK = 1 } }),
        talent("T_V", { hide = false, tactical = { ATTACK = 1 } }),
      })
      assert.is_true(find(p.entries, "T_H").hidden)
      assert.is_true(find(p.entries, "T_A").hidden)
      assert.is_false(find(p.entries, "T_V").hidden)
      assert.matches("hidden", find(p.entries, "T_H").reason)
      assert.is_nil(find(p.entries, "T_V").reason:match("hidden"))
    end)

    it("does not filter on on_pre_use, and marks such talents conditional", function()
      local p = L.discover({
        talent("T_HEADSHOT", { tactical = { ATTACK = 2 }, on_pre_use = function() return false end }),
      })
      assert.are.equal("Combat", sectionOf(p).T_HEADSHOT)
      assert.is_true(find(p.entries, "T_HEADSHOT").conditional)
      assert.matches("conditional", find(p.entries, "T_HEADSHOT").reason)
    end)

    describe("sustain_slots", function()
      local function chants(over)
        local def = function() return { mode = "sustained", hide = true, cooldown = 12,
          tactical = { DEFEND = 2 }, sustain_slots = "celestial_chant" } end
        over = over or {}
        return {
          talent("T_CHANT_OF_FORTITUDE", def(), over.fortitude),
          talent("T_CHANT_OF_FORTRESS", def(), over.fortress),
          talent("T_CHANT_OF_RESISTANCE", def(), over.resistance),
        }
      end

      it("places none of a group and lists it as a choice when nothing prefers one", function()
        local p = L.discover(chants())
        assert.are.same({}, p.entries)
        assert.are.equal(1, #p.choices)
        assert.are.equal("celestial_chant", p.choices[1].slot)
        assert.are.same({ "T_CHANT_OF_FORTITUDE", "T_CHANT_OF_FORTRESS", "T_CHANT_OF_RESISTANCE" }, p.choices[1].tids)
        assert.matches("pick one by hand", p.choices[1].reason)
        assert.are.same({}, p.unassigned, "a choice is not an unassigned talent")
      end)

      it("places the one that is already active", function()
        local p = L.discover(chants({ fortress = { active = true } }))
        assert.are.same({ "T_CHANT_OF_FORTRESS" }, tidsIn(p, "Sustain"))
        assert.matches("already active", find(p.entries, "T_CHANT_OF_FORTRESS").reason)
        assert.are.same({}, p.choices)
      end)

      it("places the highest level when exactly one is highest", function()
        local p = L.discover(chants({ fortitude = { level = 1 }, fortress = { level = 3 },
          resistance = { level = 1 } }))
        assert.are.same({ "T_CHANT_OF_FORTRESS" }, tidsIn(p, "Sustain"))
        assert.matches("highest level", find(p.entries, "T_CHANT_OF_FORTRESS").reason)
      end)

      it("lists the group when levels tie or two are active", function()
        assert.are.equal(1, #L.discover(chants({ fortitude = { level = 2 }, fortress = { level = 2 } })).choices)
        local two = L.discover(chants({ fortitude = { active = true }, fortress = { active = true } }))
        assert.are.equal(1, #two.choices)
        assert.are.same({}, two.entries)
      end)

      it("places a group of one without comment", function()
        local p = L.discover({ chants()[2] })
        assert.are.same({ "T_CHANT_OF_FORTRESS" }, tidsIn(p, "Sustain"))
        assert.are.same({}, p.choices)
      end)

      it("keeps groups apart", function()
        local list = chants({ fortress = { active = true } })
        local hymn = function()
          return { mode = "sustained", tactical = { BUFF = 1 }, sustain_slots = "celestial_hymn" }
        end
        list[#list + 1] = talent("T_HYMN_A", hymn())
        list[#list + 1] = talent("T_HYMN_B", hymn())
        local p = L.discover(list)
        assert.are.same({ "T_CHANT_OF_FORTRESS" }, tidsIn(p, "Sustain"))
        assert.are.equal(1, #p.choices)
        assert.are.equal("celestial_hymn", p.choices[1].slot)
      end)
    end)
  end)

  describe("priority", function()
    it("orders a section by cooldown descending, ties by tactical weight, then by tid", function()
      local p = L.discover({
        talent("T_FILLER", { cooldown = 2, tactical = { ATTACK = 2 } }),
        talent("T_BIG", { cooldown = 20, tactical = { ATTACK = 1 } }),
        talent("T_MID_LIGHT", { cooldown = 8, tactical = { ATTACK = 1 } }),
        talent("T_MID_HEAVY", { cooldown = 8, tactical = { ATTACK = { weapon = 2 }, DISABLE = { stun = 2 } } }),
        talent("T_NOCD_B", { tactical = { ATTACK = 1 } }),
        talent("T_NOCD_A", { tactical = { ATTACK = 1 } }),
      })
      assert.are.same({ "T_BIG", "T_MID_HEAVY", "T_MID_LIGHT", "T_FILLER", "T_NOCD_A", "T_NOCD_B" },
        tidsIn(p, "Combat"))
    end)

    it("numbers entries 100 downwards with gaps of ten, per section", function()
      local p = L.discover({
        talent("T_A", { cooldown = 9, tactical = { ATTACK = 2 } }),
        talent("T_B", { cooldown = 3, tactical = { ATTACK = 2 } }),
        talent("T_H", { cooldown = 5, tactical = { HEAL = 2 } }),
      })
      assert.are.equal(100, find(p.entries, "T_A").priority)
      assert.are.equal(90, find(p.entries, "T_B").priority)
      assert.are.equal(100, find(p.entries, "T_H").priority)
    end)

    it("keeps the numbers positive and distinct past ten entries", function()
      local list = {}
      for i = 1, 25 do list[i] = talent(("T_%02d"):format(i), { cooldown = i, tactical = { ATTACK = 1 } }) end
      local p = L.discover(list)
      local seen, last = {}, math.huge
      for _, e in ipairs(p.entries) do
        assert.is_true(e.priority > 0)
        assert.is_true(e.priority < last)
        assert.is_nil(seen[e.priority])
        seen[e.priority] = true
        last = e.priority
      end
    end)

    it("lists entries in section order", function()
      local p = L.discover({
        talent("T_S", { mode = "sustained", tactical = { BUFF = 1 } }),
        talent("T_H", { tactical = { HEAL = 1 } }),
        talent("T_D", { tactical = { DEFEND = 1 } }),
        talent("T_C", { tactical = { ATTACK = 1 } }),
      })
      local order = {}
      for i, e in ipairs(p.entries) do order[i] = e.section end
      assert.are.same({ "Combat", "DamagePrevention", "Recovery", "Sustain" }, order)
    end)

    it("treats a cooldown that was not resolved as none", function()
      local p = L.discover({
        talent("T_FN", { cooldown = function() return 30 end, tactical = { ATTACK = 1 } }),
        talent("T_N", { cooldown = 1, tactical = { ATTACK = 1 } }),
      })
      assert.are.same({ "T_N", "T_FN" }, tidsIn(p, "Combat"))
      assert.are.equal(0, find(p.entries, "T_FN").cooldown)
    end)
  end)

  describe("validation against mishander's Sun Paladin build (salvage item 12)", function()
    local p, s
    setup(function()
      p = L.discover(sunPaladin(), { self = { level = 1 } })
      s = sectionOf(p)
    end)

    it("reproduces the eight Combat placements", function()
      for _, tid in ipairs({ "T_SUN_BEAM", "T_SHIELD_PUMMEL", "T_STUNNING_BLOW", "T_EXECUTION", "T_BLOCK",
                             "T_DEATH_DANCE", "T_SHIELD_SLAM", "T_WAVE_OF_POWER" }) do
        assert.are.equal("Combat", s[tid], tid)
      end
    end)

    it("reproduces the four Sustain placements, with the active chant chosen", function()
      for _, tid in ipairs({ "T_WEAPON_OF_LIGHT", "T_WEAPON_OF_WRATH", "T_CHANT_OF_FORTRESS", "T_SECOND_LIFE" }) do
        assert.are.equal("Sustain", s[tid], tid)
      end
      assert.is_nil(s.T_CHANT_OF_FORTITUDE)
      assert.is_nil(s.T_CHANT_OF_RESISTANCE)
      assert.are.same({}, p.choices)
    end)

    it("reproduces Rune: Shielding in Damage Prevention", function()
      assert.are.equal("DamagePrevention", s["T_RUNE:_SHIELDING_1"])
    end)

    it("differs on the 14th: Infusion: Regeneration is Recovery, as the data says", function()
      assert.are.equal("Recovery", s["T_INFUSION:_REGENERATION_1"])
    end)

    it("puts the default Attack at the bottom of Combat, hidden, as the preset did", function()
      local combat = tidsIn(p, "Combat")
      assert.are.equal("T_ATTACK", combat[#combat])
      assert.is_true(find(p.entries, "T_ATTACK").hidden)
      assert.are.equal("T_DEATH_DANCE", combat[1], "the longest cooldown leads")
    end)

    it("ignores the passive pool and leaves nothing unassigned or skipped", function()
      assert.are.same({}, p.unassigned)
      assert.are.same({}, p.skipped)
      assert.are.equal(15, p.counts.entries, "the 13 reproduced, Regeneration, and Attack")
    end)

    it("still places Sun Ray when its tactical function needs a target (level 3+)", function()
      local hi = L.discover(sunPaladin(), { self = { level = 3 } })
      assert.are.equal("Combat", sectionOf(hi).T_SUN_BEAM)
      assert.matches("needs a target", find(hi.entries, "T_SUN_BEAM").reason)
    end)
  end)

  describe("unplaced", function()
    it("lists the proposed entries whose talent is in no section", function()
      local p = L.discover({
        talent("T_A", { tactical = { ATTACK = 1 } }),
        talent("T_B", { tactical = { HEAL = 1 } }),
        talent("T_C", { tactical = { DEFEND = 1 } }),
      })
      local rules = R.new()
      rules.Recovery = { { tid = "T_A" } }       -- placed, even if elsewhere
      rules.Sustain = { { tid = "T_C", suggested = true } }
      local u = L.unplaced(p, rules, R)
      assert.are.equal(1, #u)
      assert.are.equal("T_B", u[1].tid)
      assert.are.equal(3, #L.unplaced(p, R.new(), R))
      assert.are.same({}, L.unplaced(nil, R.new(), R))
    end)
  end)

  describe("apply", function()
    local proposal
    before_each(function()
      proposal = L.discover({
        talent("T_BIG", { cooldown = 10, tactical = { ATTACK = 1 } }),
        talent("T_SMALL", { cooldown = 2, tactical = { ATTACK = 1 } }),
        talent("T_HEAL", { cooldown = 5, tactical = { HEAL = 1 } }),
        talent("T_SUS", { mode = "sustained", tactical = { BUFF = 1 } }),
      })
    end)

    local function tids(list)
      local out = {}
      for i, e in ipairs(list) do out[i] = e.tid end
      return out
    end

    it("merge into an empty table writes every entry, in order, all marked suggested", function()
      local rules = R.new()
      local report = L.apply(proposal, rules, R, "merge")
      assert.are.same({ "T_BIG", "T_SMALL" }, tids(rules.Combat))
      assert.are.same({ "T_HEAL" }, tids(rules.Recovery))
      assert.are.same({ "T_SUS" }, tids(rules.Sustain))
      assert.are.same({}, rules.DamagePrevention)
      for _, s in ipairs(R.SECTIONS) do
        for _, e in ipairs(rules[s]) do assert.is_true(e.suggested, e.tid) end
      end
      assert.are.same({ added = 4, removed = 0, kept = 0, declined = 0, mode = "merge" }, report)
    end)

    it("defaults to merge", function()
      local rules = R.new()
      assert.are.equal("merge", L.apply(proposal, rules, R).mode)
      assert.are.equal(4, R.count(rules))
    end)

    it("merge leaves a hand-placed talent alone wherever it is, and adds the rest after hand rows", function()
      local rules = R.new()
      rules.Combat = { { tid = "T_SMALL" }, { tid = "T_MINE" } }
      rules.Recovery = { { tid = "T_BIG" } }      -- the player's call, even in another section
      local report = L.apply(proposal, rules, R, "merge")
      assert.are.same({ "T_SMALL", "T_MINE" }, tids(rules.Combat))
      assert.are.same({ "T_BIG", "T_HEAL" }, tids(rules.Recovery))
      assert.are.same({ "T_SUS" }, tids(rules.Sustain))
      assert.is_nil(rules.Combat[1].suggested)
      assert.is_nil(rules.Recovery[1].suggested)
      assert.is_true(rules.Recovery[2].suggested)
      assert.are.same({ added = 2, removed = 0, kept = 2, declined = 0, mode = "merge" }, report)
    end)

    it("merge re-run is idempotent: no duplicates, same order", function()
      local rules = R.new()
      rules.Combat = { { tid = "T_MINE" } }
      L.apply(proposal, rules, R, "merge")
      local before = { tids(rules.Combat), tids(rules.Recovery), tids(rules.Sustain) }
      local report = L.apply(proposal, rules, R, "merge")
      assert.are.same(before, { tids(rules.Combat), tids(rules.Recovery), tids(rules.Sustain) })
      assert.are.equal(4, report.removed, "its own rows were rewritten")
      assert.are.equal(4, report.added)
      assert.are.equal(5, R.count(rules))
    end)

    it("merge slots a newly learned talent among its own rows in priority order", function()
      local rules = R.new()
      rules.Combat = { { tid = "T_MINE" } }
      L.apply(proposal, rules, R, "merge")
      local bigger = L.discover({
        talent("T_BIG", { cooldown = 10, tactical = { ATTACK = 1 } }),
        talent("T_SMALL", { cooldown = 2, tactical = { ATTACK = 1 } }),
        talent("T_NEW", { cooldown = 30, tactical = { ATTACK = 1 } }),
      })
      L.apply(bigger, rules, R, "merge")
      assert.are.same({ "T_MINE", "T_NEW", "T_BIG", "T_SMALL" }, tids(rules.Combat))
    end)

    it("merge does not touch a suggested row once the talent has a hand row anywhere", function()
      local rules = R.new()
      rules.Combat = { { tid = "T_BIG", suggested = true } }
      rules.Recovery = { { tid = "T_BIG" } }
      L.apply(proposal, rules, R, "merge")
      assert.are.same({ "T_BIG", "T_SMALL" }, tids(rules.Combat))
      assert.is_true(rules.Combat[1].suggested)
    end)

    it("merge drops its own row for a talent the proposal no longer places", function()
      local rules = R.new()
      rules.Combat = { { tid = "T_GONE", suggested = true } }
      L.apply(proposal, rules, R, "merge")
      assert.are.same({ "T_BIG", "T_SMALL" }, tids(rules.Combat))
    end)

    it("replace empties every section first, hand rows included", function()
      local rules = R.new()
      rules.Combat = { { tid = "T_MINE" } }
      rules.DamagePrevention = { { tid = "T_SHIELD" }, { tid = "T_OLD", suggested = true } }
      local report = L.apply(proposal, rules, R, "replace")
      assert.are.same({ "T_BIG", "T_SMALL" }, tids(rules.Combat))
      assert.are.same({}, rules.DamagePrevention)
      assert.are.same({ "T_HEAL" }, tids(rules.Recovery))
      assert.are.same({ "T_SUS" }, tids(rules.Sustain))
      assert.are.same({ added = 4, removed = 3, kept = 0, declined = 0, mode = "replace" }, report)
    end)

    it("works on the table in place, so whoever holds it sees the result", function()
      local rules = R.new()
      local held = rules.Combat
      L.apply(proposal, rules, R, "replace")
      assert.are.equal(held, rules.Combat)
      assert.are.equal(2, #held)
    end)
  end)

  -- #98: the owner's playtest -- an Archer was recommended *Attack*, which
  -- with a bow in hand is a wrong recommendation on the first screen a new
  -- player sees. Keyed on the weapon, never on the class.
  describe("a melee attack the main hand cannot deliver (#98)", function()
    local MELEE  = { mode = "activated", tactical = { ATTACK = 2 }, range = 1 }
    local RANGED = { mode = "activated", tactical = { ATTACK = 2 }, range = 6 }
    local SLING  = { name = "a rough leather sling", subtype = "sling", archery = true }
    local SWORD  = { name = "an iron longsword", subtype = "longsword", archery = false }

    it("proposes the melee attack when there is no main hand to judge", function()
      local p = L.discover({ talent("T_ATTACK", MELEE) })
      assert.equals("Combat", sectionOf(p).T_ATTACK)
    end)

    it("proposes it with a melee weapon in hand", function()
      local p = L.discover({ talent("T_ATTACK", MELEE) }, { mainhand = SWORD })
      assert.equals("Combat", sectionOf(p).T_ATTACK)
    end)

    it("does NOT propose it with a sling in hand, and says why", function()
      local p = L.discover({ talent("T_ATTACK", MELEE) }, { mainhand = SLING })
      assert.is_nil(sectionOf(p).T_ATTACK)
      local u = find(p.unassigned, "T_ATTACK")
      assert.is_not_nil(u)
      assert.is_truthy(u.reason:find("cannot make a melee attack", 1, true))
      assert.is_truthy(u.reason:find("sling", 1, true))
    end)

    it("still proposes a RANGED attack with a sling in hand", function()
      local p = L.discover({ talent("T_SHOOT", RANGED) }, { mainhand = SLING })
      assert.equals("Combat", sectionOf(p).T_SHOOT)
    end)

    -- Fails safe: an unknown range must not be guessed at as melee, or a
    -- ranged talent the game would not report on quietly leaves the
    -- proposal -- a worse failure than the one being fixed.
    it("keeps a talent whose range the game did not report", function()
      local noRange = { mode = "activated", tactical = { ATTACK = 2 } }
      local p = L.discover({ talent("T_MYSTERY", noRange) }, { mainhand = SLING })
      assert.equals("Combat", sectionOf(p).T_MYSTERY)
    end)

    it("reads the subtype when the object does not say `archery`", function()
      local bare = { name = "a shortbow", subtype = "bow" }
      local p = L.discover({ talent("T_ATTACK", MELEE) }, { mainhand = bare })
      assert.is_nil(sectionOf(p).T_ATTACK)
    end)
  end)

  -- #85: the proposal screen is a preview, and a preview a player can argue
  -- with. Declining is theirs, kept on the character, and must survive a
  -- re-run -- otherwise every re-run re-recommends the thing they rejected.
  describe("declined talents (#85)", function()
    local ATTACK = { mode = "activated", tactical = { ATTACK = 2 }, range = 1 }
    local HEAL   = { mode = "activated", tactical = { HEAL = 2 } }

    it("still shows a declined talent, marked, rather than hiding it", function()
      local p = L.discover({ talent("T_ATTACK", ATTACK), talent("T_HEAL", HEAL) },
        { declined = { T_ATTACK = true } })
      local byTid = {}
      for _, e in ipairs(p.entries) do byTid[e.tid] = e end
      assert.is_not_nil(byTid.T_ATTACK, "a declined talent must stay visible")
      assert.is_true(byTid.T_ATTACK.declined)
      assert.is_nil(byTid.T_HEAL.declined)
    end)

    it("never writes one, whatever the mode", function()
      local rules = R.new()
      local p = L.discover({ talent("T_ATTACK", ATTACK), talent("T_HEAL", HEAL) },
        { declined = { T_ATTACK = true } })
      local report = L.apply(p, rules, R, "merge")
      assert.equals(1, report.declined)
      assert.equals(1, report.added)
      assert.equals(0, #R.where(rules, { tid = "T_ATTACK" }))
      assert.equals(1, #R.where(rules, { tid = "T_HEAL" }))
    end)

    it("un-declining puts it back, because the set is the only record", function()
      local p1 = L.discover({ talent("T_ATTACK", ATTACK) }, { declined = { T_ATTACK = true } })
      assert.is_true(p1.entries[1].declined)
      local p2 = L.discover({ talent("T_ATTACK", ATTACK) }, { declined = {} })
      assert.is_nil(p2.entries[1].declined)
      local rules = R.new()
      assert.equals(1, L.apply(p2, rules, R, "merge").added)
    end)
  end)

  -- #85 item 4: invested points say what the player cares about.
  describe("ordering by invested level (#85)", function()
    local function att(cd, lvl)
      return { mode = "activated", tactical = { ATTACK = 2 }, cooldown = cd }, lvl
    end

    it("a higher-level talent outranks a lower one in the same cooldown band", function()
      local defA, lvlA = att(5, 1)
      local defB, lvlB = att(5, 4)
      local p = L.discover({ talent("T_LOW", defA, { level = lvlA }),
                             talent("T_HIGH", defB, { level = lvlB }) })
      assert.same({ "T_HIGH", "T_LOW" }, tidsIn(p, "Combat"))
    end)

    -- Cooldown stays the FIRST key: it is about tempo, and a long cooldown
    -- wants firing first or it never fires at all. Level does not overturn
    -- that, it breaks ties within it.
    it("but does not overturn the cooldown band", function()
      local defLong, _ = att(9, 1)
      local defShort, _ = att(2, 5)
      local p = L.discover({ talent("T_LONG", defLong, { level = 1 }),
                             talent("T_SHORT", defShort, { level = 5 }) })
      assert.same({ "T_LONG", "T_SHORT" }, tidsIn(p, "Combat"))
    end)
  end)
end)
