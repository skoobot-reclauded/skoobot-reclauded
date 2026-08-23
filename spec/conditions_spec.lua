-- luacheck: std luajit+busted

-- data/conditions.lua is the condition list as data (#12): every code the
-- menu shows and the save keeps, its default policy, its detector, where the
-- act loop consults it, what it says, and what it blocks. These tests pin
-- the list's shape, the policy entries to v1's list (codes, order, labels,
-- defaults -- the save format), every predicate over fake actors, the
-- capability union, and the reconciliation T-019 (#52) moved here.

local manifest = require "spec.support.manifest"

local function load()
  local chunk = assert(loadfile(manifest.path("src/data/conditions.lua")))
  return chunk()
end

--- A stand-in for the player: attr() over a table of status attributes, a
--- life pair, nothing else.
local function actor(attrs, over)
  local a = { attrs = attrs or {}, life = 100, max_life = 100 }
  function a:attr(name) return self.attrs[name] end
  for k, v in pairs(over or {}) do a[k] = v end
  return a
end

--- A detector context: the settings v1 shipped, no hostiles, a quiet loop,
--- no chest.
local function context(over)
  local settings = {
    LOWHEALTH_RATIO = 0.5, MAX_INDIVIDUAL_POWER = 200, MAX_DIFF_POWER = 10,
    MAX_COMBINED_POWER = 500, MAX_ENEMY_COUNT = 12,
  }
  local ctx = {
    hostiles = 0,
    loop = { enemyCount = 0, maxVisibleEnemyPower = 0, sumVisibleEnemyPower = 0 },
    own = 50,
    cfg = function(k) return settings[k] end,
    chestInView = function() return false end,
    delta = 0,
  }
  for k, v in pairs(over or {}) do ctx[k] = v end
  return ctx
end

-- v1's list, as DEFAULT_CONDITIONS had it before #12: the save format.
local V1 = {
  { "DEBUFF_STUNNED",        "Debuff: STUNNED",            "WARN" },
  { "DEBUFF_CONFUSED",       "Debuff: CONFUSED",           "WARN" },
  { "DEBUFF_DAZED",          "Debuff: DAZED",              "WARN" },
  { "DEBUFF_FROZEN",         "Debuff: FROZEN",             "WARN" },
  { "DEBUFF_ASLEEP",         "Debuff: ASLEEP",             "WARN" },
  { "LIFE_BIGLOSS",          "Life: BIGLOSS",              "WARN" },
  { "LIFE_LOWLIFE",          "Life: LOWLIFE",              "STOP" },
  { "DIALOG_LORE",           "Dialog: LORE",               "IGNORE" },
  { "TERRAIN_GLOWING_CHEST", "Terrain: Glowing Chest",     "WARN" },
  { "SCOUTER_ENEMYCOUNT",    "Power Level: ENEMYCOUNT",    "STOP" },
  { "SCOUTER_BIGENEMY",      "Power Level: BIGENEMY",      "STOP" },
  { "SCOUTER_STRONGERENEMY", "Power Level: STRONGERENEMY", "STOP" },
  { "SCOUTER_CROWDPOWER",    "Power Level: CROWDPOWER",    "STOP" },
}

describe("data/conditions.lua", function()
  local C

  setup(function() C = load() end)

  describe("the list", function()
    it("has every field on every entry", function()
      local sites = { turn = true, explore = true, loop = true, dialog = true }
      for _, def in ipairs(C.LIST) do
        assert.is_string(def.code, "code")
        assert.is_string(def.label, def.code .. " label")
        assert.is_string(def.category, def.code .. " category")
        assert.is_true(sites[def.site] == true, def.code .. " site")
        assert.is_table(def.blocks, def.code .. " blocks")
        for what in pairs(def.blocks) do
          assert.is_true(what == "move" or what == "act" or what == "target", def.code .. " blocks " .. tostring(what))
          assert.is_string(def.blocked, def.code .. " names what blocks")
        end
        if def.default then
          assert.is_true(C.STOPTYPES[def.default] == true, def.code .. " default")
        else
          assert.equals("liveness", def.category, def.code .. " has no policy so it is liveness")
        end
        if def.site ~= "dialog" then
          assert.is_function(def.detect, def.code .. " detect")
        end
        if def.default and def.detect then
          assert.is_true(type(def.message) == "string" or type(def.message) == "function", def.code .. " message")
        end
      end
    end)

    it("has unique codes, and find() resolves each", function()
      local seen = {}
      for _, def in ipairs(C.LIST) do
        assert.is_nil(seen[def.code], "duplicate " .. def.code)
        seen[def.code] = true
        assert.equals(def, C.find(def.code))
      end
      assert.is_nil(C.find("NO_SUCH_CONDITION"))
    end)

    it("policy entries are exactly v1's thirteen, in order, with their labels and defaults", function()
      local policy = C.policy()
      assert.equals(#V1, #policy)
      for i, row in ipairs(V1) do
        assert.equals(row[1], policy[i].code, "code " .. i)
        assert.equals(row[2], policy[i].label, "label " .. row[1])
        assert.equals(row[3], policy[i].default, "default " .. row[1])
      end
    end)

    it("the liveness entries have no default and never reach the menu", function()
      local names = {}
      for _, def in ipairs(C.LIST) do
        if not def.default then names[#names + 1] = def.code end
      end
      assert.same({ "CANNOT_MOVE", "ENCASED" }, names)
      for _, def in ipairs(C.policy()) do assert.is_not_nil(def.default) end
    end)

    it("DIALOG_LORE has no detector: the dialog branch consults its policy by code", function()
      local d = C.find("DIALOG_LORE")
      assert.is_nil(d.detect)
      assert.equals(C.SITE_DIALOG, d.site)
    end)

    it("the glowing chest hands back rather than stopping", function()
      assert.equals(C.HANDED_BACK, C.find("TERRAIN_GLOWING_CHEST").severity)
      for _, def in ipairs(C.LIST) do
        if def.code ~= "TERRAIN_GLOWING_CHEST" then assert.is_nil(def.severity, def.code) end
      end
    end)
  end)

  describe("the debuff detectors read counters, never == 1", function()
    local function fires(code, attrs, ctx)
      return C.find(code).detect(actor(attrs), ctx or context())
    end

    it("stunned: once, twice, not at all", function()
      assert.is_false(fires("DEBUFF_STUNNED", {}))
      assert.is_true(fires("DEBUFF_STUNNED", { stunned = 1 }))
      assert.is_true(fires("DEBUFF_STUNNED", { stunned = 2 }))      -- v1's == 1 missed this
    end)

    it("stunned names the count when there is more than one source", function()
      local d = C.find("DEBUFF_STUNNED")
      assert.equals("you are stunned", C.message(d, actor({ stunned = 1 })))
      assert.equals("you are stunned (x2)", C.message(d, actor({ stunned = 2 })))
    end)

    it("confused is a percentage: 30% fires, 1% fires, 0 does not", function()
      assert.is_true(fires("DEBUFF_CONFUSED", { confused = 30 }))  -- v1's == 1 missed this
      assert.is_true(fires("DEBUFF_CONFUSED", { confused = 1 }))
      assert.is_false(fires("DEBUFF_CONFUSED", { confused = 0 }))
      assert.is_false(fires("DEBUFF_CONFUSED", {}))
      assert.equals("you are confused (30% chance to act randomly)",
        C.message(C.find("DEBUFF_CONFUSED"), actor({ confused = 30 })))
    end)

    it("dazed and frozen", function()
      assert.is_true(fires("DEBUFF_DAZED", { dazed = 1 }))
      assert.is_false(fires("DEBUFF_DAZED", {}))
      assert.is_true(fires("DEBUFF_FROZEN", { frozen = 2 }))
      assert.is_false(fires("DEBUFF_FROZEN", {}))
      assert.equals("you are dazed", C.message(C.find("DEBUFF_DAZED"), actor({ dazed = 1 })))
      assert.equals("you are frozen", C.message(C.find("DEBUFF_FROZEN"), actor({ frozen = 1 })))
    end)

    it("asleep is ToME's own gate: sleep and not lucid_dreamer", function()
      assert.is_true(fires("DEBUFF_ASLEEP", { sleep = 1 }))
      assert.is_true(fires("DEBUFF_ASLEEP", { sleep = 3 }))
      assert.is_false(fires("DEBUFF_ASLEEP", { sleep = 1, lucid_dreamer = 12 }))  -- the Solipsist sustain
      assert.is_false(fires("DEBUFF_ASLEEP", { sleep = 1, lucid_dreamer = 1 }))   -- an item
      assert.is_false(fires("DEBUFF_ASLEEP", {}))
      assert.equals("you are asleep", C.message(C.find("DEBUFF_ASLEEP"), actor({ sleep = 1 })))
    end)

    it("a non-number attribute counts as absent", function()
      assert.is_false(fires("DEBUFF_STUNNED", { stunned = "yes" }))
    end)
  end)

  describe("the life detectors", function()
    it("LOWLIFE only with something in view, below the ratio", function()
      local d = C.find("LIFE_LOWLIFE")
      local low = actor({}, { life = 40, max_life = 100 })
      assert.is_true(d.detect(low, context({ hostiles = 1 })))
      assert.is_false(d.detect(low, context({ hostiles = 0 })))
      assert.is_false(d.detect(actor({}, { life = 50, max_life = 100 }), context({ hostiles = 1 })))
      assert.equals("life is below LOWHEALTH_RATIO", C.message(d, low, context()))
    end)

    it("BIGLOSS is half the ratio lost in one turn, at the loop site", function()
      local d = C.find("LIFE_BIGLOSS")
      assert.equals(C.SITE_LOOP, d.site)
      assert.is_true(d.detect(actor(), context({ delta = -25 })))
      assert.is_false(d.detect(actor(), context({ delta = -24 })))
      assert.is_false(d.detect(actor(), context({ delta = 25 })))
      assert.equals("lost more than 25% of max life in one turn (half of LOWHEALTH_RATIO)",
        C.message(d, actor(), context({ delta = -25 })))
    end)
  end)

  describe("the power detectors compare v1's four thresholds over the #62 figures", function()
    local function loop(over)
      local l = { enemyCount = 3, maxVisibleEnemyPower = 100, sumVisibleEnemyPower = 250 }
      for k, v in pairs(over or {}) do l[k] = v end
      return l
    end

    it("ENEMYCOUNT", function()
      local d = C.find("SCOUTER_ENEMYCOUNT")
      assert.is_true(d.detect(actor(), context({ loop = loop({ enemyCount = 13 }) })))
      assert.is_false(d.detect(actor(), context({ loop = loop({ enemyCount = 12 }) })))
      assert.equals("13 enemies in sight, above MAX_ENEMY_COUNT",
        C.message(d, actor(), context({ loop = loop({ enemyCount = 13 }) })))
    end)

    it("BIGENEMY is absolute", function()
      local d = C.find("SCOUTER_BIGENEMY")
      assert.is_true(d.detect(actor(), context({ loop = loop({ maxVisibleEnemyPower = 201 }), own = 1000 })))
      assert.is_false(d.detect(actor(), context({ loop = loop({ maxVisibleEnemyPower = 200 }) })))
      assert.equals("an enemy's power level, 201, is above MAX_INDIVIDUAL_POWER",
        C.message(d, actor(), context({ loop = loop({ maxVisibleEnemyPower = 201 }) })))
    end)

    it("STRONGERENEMY is relative to the life-scaled own power", function()
      local d = C.find("SCOUTER_STRONGERENEMY")
      assert.is_true(d.detect(actor(), context({ loop = loop({ maxVisibleEnemyPower = 61 }), own = 50 })))
      assert.is_false(d.detect(actor(), context({ loop = loop({ maxVisibleEnemyPower = 60 }), own = 50 })))
      assert.equals("an enemy's power level, 61, is more than MAX_DIFF_POWER above yours (50.0 at current life)",
        C.message(d, actor(), context({ loop = loop({ maxVisibleEnemyPower = 61 }), own = 50 })))
    end)

    it("CROWDPOWER is the weighted sum against own power plus the margin", function()
      local d = C.find("SCOUTER_CROWDPOWER")
      assert.is_true(d.detect(actor(), context({ loop = loop({ sumVisibleEnemyPower = 551 }), own = 50 })))
      assert.is_false(d.detect(actor(), context({ loop = loop({ sumVisibleEnemyPower = 550 }), own = 50 })))
      assert.equals("the combined enemy power level, 551, is more than MAX_COMBINED_POWER above yours "
        .. "(50.0 at current life)",
        C.message(d, actor(), context({ loop = loop({ sumVisibleEnemyPower = 551 }), own = 50 })))
    end)
  end)

  describe("the terrain and liveness detectors", function()
    it("the chest reads the scan the act loop hands it", function()
      local d = C.find("TERRAIN_GLOWING_CHEST")
      assert.equals(C.SITE_EXPLORE, d.site)
      assert.is_true(d.detect(actor(), context({ chestInView = function() return true end })))
      assert.is_false(d.detect(actor(), context()))
    end)

    it("CANNOT_MOVE is never_move, whatever set it", function()
      local d = C.find("CANNOT_MOVE")
      assert.is_true(d.detect(actor({ never_move = 1 })))
      assert.is_true(d.detect(actor({ never_move = 3 })))
      assert.is_false(d.detect(actor({})))
    end)

    it("ENCASED is either encasement attribute", function()
      local d = C.find("ENCASED")
      assert.is_true(d.detect(actor({ encased_in_ice = 1 })))
      assert.is_true(d.detect(actor({ encased = 1 })))
      assert.is_false(d.detect(actor({ frozen = 1 })))   -- frozen feet: a pin, not a block on talents
    end)
  end)

  describe("capabilities()", function()
    it("nothing detected blocks nothing", function()
      local caps = C.capabilities(actor({}), context())
      assert.is_false(caps.any)
      assert.is_nil(caps.move)
      assert.is_nil(caps.act)
      assert.is_nil(caps.target)
    end)

    it("pinned blocks move only, and is named by the generic words", function()
      local caps = C.capabilities(actor({ never_move = 1 }), context())
      assert.is_true(caps.any)
      assert.equals(1, #caps.move)
      assert.equals("CANNOT_MOVE", caps.move[1].code)
      assert.is_nil(caps.act)
      assert.is_nil(caps.target)
      assert.equals("pinned, held, or overloaded", C.blockedText(caps.move))
    end)

    it("dazed blocks move and is named, not the generic catch-all it also trips", function()
      local caps = C.capabilities(actor({ dazed = 1, never_move = 1 }), context())
      assert.equals(2, #caps.move)
      assert.equals("dazed", C.blockedText(caps.move))
    end)

    it("asleep blocks move and act", function()
      local caps = C.capabilities(actor({ sleep = 1 }), context())
      assert.equals("asleep", C.blockedText(caps.move))
      assert.equals("asleep", C.blockedText(caps.act))
      assert.is_nil(caps.target)
    end)

    it("a Solipsist dreaming lucidly is blocked by nothing", function()
      assert.is_false(C.capabilities(actor({ sleep = 5, lucid_dreamer = 12 }), context()).any)
    end)

    it("encased in ice blocks move and target; frozen feet only move", function()
      local ice = C.capabilities(actor({ frozen = 1, never_move = 1, encased_in_ice = 1 }), context())
      assert.equals("frozen, encased in ice", C.blockedText(ice.move))
      assert.equals("encased in ice", C.blockedText(ice.target))
      assert.is_nil(ice.act)
      local feet = C.capabilities(actor({ frozen = 1, never_move = 1 }), context())
      assert.equals("frozen", C.blockedText(feet.move))
      assert.is_nil(feet.target)
    end)

    it("stunned and confused block nothing: they are model validity, not capability", function()
      assert.is_false(C.capabilities(actor({ stunned = 2, confused = 30 }), context()).any)
    end)

    it("blockedText of nothing is a word, not an error", function()
      assert.equals("blocked", C.blockedText(nil))
      assert.equals("blocked", C.blockedText({}))
    end)
  end)

  describe("reconcile()", function()
    local function stale()
      -- As a pre-T-013 build saved it: the twelve v1 codes with stale
      -- labels, one customised, plus a code no version defines.
      local list = {}
      for i, row in ipairs(V1) do
        if row[1] ~= "TERRAIN_GLOWING_CHEST" then
          list[#list + 1] = { label = "old " .. i, code = row[1], stoptype = "WARN" }
        end
      end
      list[7].stoptype = "IGNORE"                       -- LIFE_LOWLIFE, the user's choice
      list[#list + 1] = { label = "gone", code = "RETIRED_CONDITION", stoptype = "STOP" }
      return list
    end

    it("leaves a current list alone", function()
      local list = {}
      C.reconcile(list)
      local snapshot = {}
      for i, v in ipairs(list) do snapshot[i] = v end
      assert.is_false(C.reconcile(list))
      for i, v in ipairs(snapshot) do assert.equals(v, list[i]) end
    end)

    it("rebuilds an empty list at the defaults, in order", function()
      local list = {}
      assert.is_true(C.reconcile(list))
      assert.equals(#V1, #list)
      for i, row in ipairs(V1) do
        assert.same({ code = row[1], label = row[2], stoptype = row[3] }, list[i])
      end
    end)

    it("maps an old saved list: adds the missing code, drops the retired one, keeps the choice, refreshes labels",
    function()
      local list = stale()
      local same = list
      assert.is_true(C.reconcile(list))
      assert.equals(same, list)                          -- in place
      assert.equals(#V1, #list)
      local byCode = {}
      for _, v in ipairs(list) do byCode[v.code] = v end
      assert.equals("WARN", byCode.TERRAIN_GLOWING_CHEST.stoptype)
      assert.equals("IGNORE", byCode.LIFE_LOWLIFE.stoptype)
      assert.is_nil(byCode.RETIRED_CONDITION)
      assert.equals("Debuff: STUNNED", byCode.DEBUFF_STUNNED.label)
      for i, row in ipairs(V1) do assert.equals(row[1], list[i].code) end
    end)

    it("treats a malformed entry as unset", function()
      local list = { "junk", { code = "DEBUFF_STUNNED", stoptype = "MAYBE" },
        { code = "LIFE_LOWLIFE", stoptype = "IGNORE" } }
      assert.is_true(C.reconcile(list))
      local byCode = {}
      for _, v in ipairs(list) do byCode[v.code] = v end
      assert.equals("WARN", byCode.DEBUFF_STUNNED.stoptype)
      assert.equals("IGNORE", byCode.LIFE_LOWLIFE.stoptype)
    end)

    it("is idempotent", function()
      local list = stale()
      C.reconcile(list)
      assert.is_false(C.reconcile(list))
    end)

    it("never writes a liveness entry into the save", function()
      local list = {}
      C.reconcile(list)
      for _, v in ipairs(list) do
        assert.is_not_nil(C.find(v.code).default, v.code)
      end
    end)
  end)
end)
