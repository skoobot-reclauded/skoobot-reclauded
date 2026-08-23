-- luacheck: std luajit+busted

-- data/rules.lua holds the talent rules the bot reads and the talent screen
-- edits (#56): four ordered sections, a rule at most once per section but in
-- as many sections as wanted, order as priority. It is a pure module so that
-- the list operations -- the part of the screen the harness cannot drive with
-- a mouse -- are tested here.

local manifest = require "spec.support.manifest"

local function loadRules()
  local chunk = assert(loadfile(manifest.path("src/data/rules.lua")))
  return chunk()
end

local function tids(list)
  local out = {}
  for i, e in ipairs(list) do
    out[i] = e.tid or (e.object and ("@" .. tostring(e.object)))
      or ("!" .. tostring(e.action) .. ":" .. tostring(e.from))
  end
  return out
end

describe("data/rules.lua", function()
  local R

  setup(function() R = loadRules() end)

  it("is a pure module exposing the list operations", function()
    for _, f in ipairs({ "new", "normalize", "key", "same", "indexIn", "where", "remove", "removeAll",
                         "place", "shift", "prune", "tids", "count", "allowed", "isSection",
                         "isAction", "describeAction", "actionEntry" }) do
      assert.is_function(R[f], f)
    end
    assert.are.same({ "Combat", "DamagePrevention", "Recovery", "Sustain" }, R.SECTIONS)
    for _, s in ipairs(R.SECTIONS) do
      assert.is_string(R.LABELS[s], s)
      assert.is_string(R.DESCRIPTIONS[s], s)
      assert.is_true(R.isSection(s))
    end
    assert.is_false(R.isSection("Available"))
  end)

  describe("key and same", function()
    it("identifies a talent rule by tid and an item rule by name", function()
      assert.are.equal("tid:T_RUSH", R.key({ tid = "T_RUSH" }))
      assert.are.equal("object:wand of lightning", R.key({ object = "wand of lightning" }))
      assert.is_true(R.same({ tid = "T_RUSH", priority = 3 }, { tid = "T_RUSH" }))
      assert.is_false(R.same({ tid = "T_RUSH" }, { object = "T_RUSH" }))
    end)

    it("gives nothing an identity that is not a rule", function()
      assert.is_nil(R.key(nil))
      assert.is_nil(R.key("T_RUSH"))
      assert.is_nil(R.key({}))
      assert.is_nil(R.key({ tid = "" }))
      assert.is_nil(R.key({ usetype = "Combat", priority = 1 }))
      assert.is_false(R.same({}, {}))
    end)

    it("identifies a flee action by what it flees from (#59)", function()
      assert.are.equal("action:flee:nearest", R.key({ action = "flee", from = "nearest" }))
      assert.are.equal("action:flee:strongest", R.key({ action = "flee", from = "strongest" }))
      assert.is_true(R.same({ action = "flee", from = "nearest", hold = true }, { action = "flee", from = "nearest" }))
      assert.is_false(R.same({ action = "flee", from = "nearest" }, { action = "flee", from = "strongest" }))
      assert.is_true(R.isAction({ action = "flee", from = "strongest" }))
      assert.is_false(R.isAction({ tid = "T_RUSH" }))
    end)

    it("gives an unknown action or an unknown `from` no identity", function()
      assert.is_nil(R.key({ action = "flee" }))
      assert.is_nil(R.key({ action = "flee", from = "weakest" }))
      assert.is_nil(R.key({ action = "charge", from = "nearest" }))
      assert.is_false(R.isAction({ action = "flee", from = "weakest" }))
    end)
  end)

  describe("the built-in actions (#59)", function()
    it("lists a flee from the nearest and from the strongest, each with fixed prose", function()
      assert.are.equal(2, #R.ACTIONS)
      assert.are.same({ "nearest", "strongest" }, R.FLEE_FROM)
      for i, a in ipairs(R.ACTIONS) do
        assert.are.equal("flee", a.action)
        assert.are.equal(R.FLEE_FROM[i], a.from)
        assert.is_string(a.name)
        assert.is_string(a.desc)
        assert.is_true(#a.desc > 40)
      end
    end)

    it("describes a flee entry by its fixed prose, and nothing else", function()
      local d = R.describeAction({ action = "flee", from = "strongest", hold = true })
      assert.are.equal("Flee from the strongest hostile", d.name)
      assert.are.equal(R.ACTIONS[2].desc, d.desc)
      assert.are.equal("Flee from the nearest hostile", R.describeAction({ action = "flee", from = "nearest" }).name)
      assert.is_nil(R.describeAction({ tid = "T_RUSH" }))
      assert.is_nil(R.describeAction({ action = "flee", from = "weakest" }))
    end)

    it("hands out a fresh entry for a palette row, never the definition itself", function()
      local e = R.actionEntry(R.ACTIONS[1])
      assert.are.same({ action = "flee", from = "nearest" }, e)
      assert.are_not.equal(R.ACTIONS[1], e)
      e.hold = true
      assert.is_nil(R.ACTIONS[1].hold)
    end)
  end)

  describe("normalize", function()
    it("returns a fresh table for nil, with every section present and empty", function()
      local t, report = R.normalize(nil)
      for _, s in ipairs(R.SECTIONS) do
        assert.is_table(t[s])
        assert.are.equal(0, #t[s])
      end
      assert.are.same({ migrated = 0, dropped = 0 }, report)
    end)

    it("works in place and keeps the table's identity", function()
      local t = {}
      local out = R.normalize(t)
      assert.are.equal(t, out)
      assert.is_table(t.Combat)
    end)

    it("migrates a v1 flat list by usetype, highest priority first, ties in saved order", function()
      local t = {
        { tid = "T_A", usetype = "Combat",  priority = 1 },
        { tid = "T_B", usetype = "Combat",  priority = 5 },
        { tid = "T_C", usetype = "Sustain", priority = 2 },
        { tid = "T_D", usetype = "Combat",  priority = 5 },
        { tid = "T_E", usetype = "Recovery", priority = 1 },
        { tid = "T_F", usetype = "DamagePrevention", priority = 9 },
      }
      local out, report = R.normalize(t)
      assert.are.equal(t, out)
      assert.are.same({ "T_B", "T_D", "T_A" }, tids(t.Combat))
      assert.are.same({ "T_C" }, tids(t.Sustain))
      assert.are.same({ "T_E" }, tids(t.Recovery))
      assert.are.same({ "T_F" }, tids(t.DamagePrevention))
      assert.are.equal(0, #t, "the array part is emptied")
      assert.are.equal(6, report.migrated)
      assert.are.equal(0, report.dropped)
    end)

    it("strips usetype and priority from a migrated entry and keeps any other field", function()
      local t = { { tid = "T_A", usetype = "Combat", priority = 1, hold = true } }
      R.normalize(t)
      assert.are.same({ { tid = "T_A", hold = true } }, t.Combat)
    end)

    it("drops the add chain's placeholder, unknown use types and entries with no identity", function()
      local t = {
        { tid = "T_A", usetype = "",        priority = 1 },   -- escaped mid-add
        { tid = "T_B", usetype = "Healing", priority = 1 },   -- never a section
        { usetype = "Combat", priority = 1 },                 -- no tid
        "junk",
        { tid = "T_C", usetype = "Combat",  priority = 1 },
      }
      local _, report = R.normalize(t)
      assert.are.same({ "T_C" }, tids(t.Combat))
      assert.are.equal(1, report.migrated)
      assert.are.equal(4, report.dropped)
    end)

    it("keeps a v1 rule that was in two use types in both sections", function()
      -- v1 allowed a healing infusion as both Damage Prevention and Recovery;
      -- the owner's test of #56 asked for that back.
      local t = {
        { tid = "T_HEAL", usetype = "DamagePrevention", priority = 1 },
        { tid = "T_HEAL", usetype = "Recovery",         priority = 7 },
      }
      local _, report = R.normalize(t)
      assert.are.same({ "T_HEAL" }, tids(t.DamagePrevention))
      assert.are.same({ "T_HEAL" }, tids(t.Recovery))
      assert.are.equal(2, report.migrated)
      assert.are.equal(0, report.dropped)
    end)

    it("keeps a rule once per section: the highest-priority occurrence wins", function()
      local t = {
        { tid = "T_A", usetype = "Combat", priority = 1 },
        { tid = "T_A", usetype = "Combat", priority = 3 },
        { tid = "T_B", usetype = "Combat", priority = 2 },
      }
      local _, report = R.normalize(t)
      assert.are.same({ "T_A", "T_B" }, tids(t.Combat))
      assert.are.equal(2, report.migrated)
      assert.are.equal(1, report.dropped)
    end)

    it("absorbs v1-shaped entries pushed into the array part of a current table", function()
      -- What a scenario that predates #56 does: normalize once, then push.
      local t = R.normalize({})
      t.Combat[1] = { tid = "T_OLD" }
      t[#t + 1] = { tid = "T_NEW", usetype = "Combat",  priority = 1 }
      t[#t + 1] = { tid = "T_OLD", usetype = "Combat",  priority = 9 }   -- already there: dropped
      t[#t + 1] = { tid = "T_OLD", usetype = "Sustain", priority = 9 }   -- another section: kept
      local _, report = R.normalize(t)
      assert.are.same({ "T_OLD", "T_NEW" }, tids(t.Combat))
      assert.are.same({ "T_OLD" }, tids(t.Sustain))
      assert.are.equal(0, #t)
      assert.are.equal(2, report.migrated)
      assert.are.equal(1, report.dropped)
    end)

    it("dedupes within a section of a current table and drops non-rules, leaving other sections alone", function()
      local t = {
        Combat   = { { tid = "T_A" }, { tid = "T_B" }, { tid = "T_A" } },
        Recovery = { { tid = "T_B" }, { object = "rod" }, {} },
      }
      local _, report = R.normalize(t)
      assert.are.same({ "T_A", "T_B" }, tids(t.Combat))
      assert.are.same({ "T_B", "@rod" }, tids(t.Recovery))
      assert.are.equal(2, report.dropped)
    end)

    it("is idempotent", function()
      local t = R.normalize({ { tid = "T_A", usetype = "Combat", priority = 1 } })
      local before = tids(t.Combat)
      local _, report = R.normalize(t)
      assert.are.same(before, tids(t.Combat))
      assert.are.same({ migrated = 0, dropped = 0 }, report)
    end)

    it("leaves a flee action in Combat alone, fields and all (#59)", function()
      local flee = { action = "flee", from = "strongest", extra = true }
      local t = { Combat = { { tid = "T_A" }, flee, { tid = "T_B" } } }
      local _, report = R.normalize(t)
      assert.are.same({ "T_A", "!flee:strongest", "T_B" }, tids(t.Combat))
      assert.are.equal(flee, t.Combat[2], "the same table")
      assert.is_true(t.Combat[2].extra)
      assert.are.same({ migrated = 0, dropped = 0 }, report)
    end)

    it("migrates a v1-shaped flee by its usetype like any rule, and drops one it does not know", function()
      local t = {
        { action = "flee", from = "nearest", usetype = "Combat", priority = 3 },
        { tid = "T_A", usetype = "Combat", priority = 1 },
        { action = "flee", from = "weakest", usetype = "Combat", priority = 9 },   -- no such `from`
      }
      local _, report = R.normalize(t)
      assert.are.same({ "!flee:nearest", "T_A" }, tids(t.Combat))
      assert.is_nil(t.Combat[1].usetype)
      assert.is_nil(t.Combat[1].priority)
      assert.are.equal(2, report.migrated)
      assert.are.equal(1, report.dropped)
    end)

    it("dedupes a flee within a section like any rule", function()
      local t = { Combat = { { action = "flee", from = "nearest" }, { tid = "T_A" },
                             { action = "flee", from = "nearest" } } }
      local _, report = R.normalize(t)
      assert.are.same({ "!flee:nearest", "T_A" }, tids(t.Combat))
      assert.are.equal(1, report.dropped)
    end)
  end)

  describe("allowed", function()
    it("confines sustained talents to Sustain and keeps everything else out of it", function()
      assert.is_true(R.allowed("sustained", "Sustain"))
      for _, s in ipairs({ "Combat", "DamagePrevention", "Recovery" }) do
        local ok, why = R.allowed("sustained", s)
        assert.is_false(ok, s)
        assert.is_string(why)
        assert.is_true(R.allowed("activated", s), s)
        assert.is_true(R.allowed("object", s), s)
      end
      local ok, why = R.allowed("activated", "Sustain")
      assert.is_false(ok)
      assert.is_string(why)
      assert.is_false((R.allowed("activated", "Available")))
    end)

    it("confines a built-in action to Combat (#59)", function()
      assert.is_true(R.allowed("action", "Combat"))
      for _, s in ipairs({ "DamagePrevention", "Recovery", "Sustain" }) do
        local ok, why = R.allowed("action", s)
        assert.is_false(ok, s)
        assert.is_string(why)
      end
    end)
  end)

  describe("where and indexIn", function()
    it("report every placement of a rule", function()
      local t = R.new()
      t.Combat = { { tid = "T_A" }, { tid = "T_HEAL" } }
      t.Recovery = { { tid = "T_HEAL" } }
      assert.are.same({ { section = "Combat", index = 2 }, { section = "Recovery", index = 1 } },
        R.where(t, { tid = "T_HEAL" }))
      assert.are.same({}, R.where(t, { tid = "T_X" }))
      assert.are.equal(2, R.indexIn(t, "Combat", { tid = "T_HEAL" }))
      assert.is_nil(R.indexIn(t, "Sustain", { tid = "T_HEAL" }))
      assert.is_nil(R.indexIn(t, "Nowhere", { tid = "T_HEAL" }))
      assert.is_nil(R.indexIn(t, "Combat", {}))
    end)
  end)

  describe("place", function()
    local t
    before_each(function()
      t = R.new()
      t.Combat = { { tid = "T_A" }, { tid = "T_B" }, { tid = "T_C" } }
    end)

    it("adds a new rule at the end of a section", function()
      assert.are.equal(1, R.place(t, { tid = "T_X" }, "Recovery"))
      assert.are.same({ "T_X" }, tids(t.Recovery))
    end)

    it("adds a placed rule to a second section without touching the first", function()
      assert.are.equal(1, R.place(t, { tid = "T_B" }, "Recovery"))
      assert.are.same({ "T_A", "T_B", "T_C" }, tids(t.Combat))
      assert.are.same({ "T_B" }, tids(t.Recovery))
      assert.are.equal(4, R.count(t))
    end)

    it("adds a rule once per section: a repeat add leaves it where it is", function()
      assert.are.equal(2, R.place(t, { tid = "T_B" }, "Combat"))
      assert.are.same({ "T_A", "T_B", "T_C" }, tids(t.Combat))
    end)

    it("moves a rule between sections when told where it comes from", function()
      assert.are.equal(1, R.place(t, { tid = "T_B" }, "Recovery", nil, "Combat"))
      assert.are.same({ "T_A", "T_C" }, tids(t.Combat))
      assert.are.same({ "T_B" }, tids(t.Recovery))
      assert.are.equal(3, R.count(t))
    end)

    it("on a move into a section that already has the rule, leaves it in place there", function()
      t.Recovery = { { tid = "T_B" }, { tid = "T_Y" } }
      assert.are.equal(1, R.place(t, { tid = "T_B" }, "Recovery", nil, "Combat"))
      assert.are.same({ "T_A", "T_C" }, tids(t.Combat))
      assert.are.same({ "T_B", "T_Y" }, tids(t.Recovery))
    end)

    it("inserts before a given entry", function()
      assert.are.equal(2, R.place(t, { tid = "T_X" }, "Combat", { tid = "T_B" }))
      assert.are.same({ "T_A", "T_X", "T_B", "T_C" }, tids(t.Combat))
    end)

    it("reorders within a section, before an entry either side of it", function()
      assert.are.equal(1, R.place(t, { tid = "T_C" }, "Combat", { tid = "T_A" }, "Combat"))
      assert.are.same({ "T_C", "T_A", "T_B" }, tids(t.Combat))
      assert.are.equal(2, R.place(t, { tid = "T_C" }, "Combat", { tid = "T_B" }))
      assert.are.same({ "T_A", "T_C", "T_B" }, tids(t.Combat))
    end)

    it("moves the STORED table, so extra fields survive a move", function()
      t.Combat[2].hold = true
      R.place(t, { tid = "T_B" }, "Recovery", nil, "Combat")
      assert.is_true(t.Recovery[1].hold)
    end)

    it("treats a drop onto itself as a no-op", function()
      assert.are.equal(2, R.place(t, { tid = "T_B" }, "Combat", { tid = "T_B" }, "Combat"))
      assert.are.same({ "T_A", "T_B", "T_C" }, tids(t.Combat))
    end)

    it("appends when the `before` entry is not in the target section", function()
      assert.are.equal(4, R.place(t, { tid = "T_X" }, "Combat", { tid = "T_NOWHERE" }))
      assert.are.same({ "T_A", "T_B", "T_C", "T_X" }, tids(t.Combat))
    end)

    it("refuses a bad section or a non-rule", function()
      local at, why = R.place(t, { tid = "T_X" }, "Available")
      assert.is_nil(at)
      assert.is_string(why)
      at, why = R.place(t, {}, "Combat")
      assert.is_nil(at)
      assert.is_string(why)
      assert.are.equal(3, R.count(t))
    end)

    it("handles item rules the same way", function()
      assert.are.equal(4, R.place(t, { object = "wand of fire" }, "Combat"))
      assert.are.equal(1, R.place(t, { object = "wand of fire" }, "Combat", { tid = "T_A" }))
      assert.are.same({ "@wand of fire", "T_A", "T_B", "T_C" }, tids(t.Combat))
    end)

    it("places a flee action like any rule: at the end, before a talent, once per section (#59)", function()
      local flee = { action = "flee", from = "nearest" }
      assert.are.equal(4, R.place(t, flee, "Combat"))
      assert.are.equal(2, R.place(t, flee, "Combat", { tid = "T_B" }))
      assert.are.same({ "T_A", "!flee:nearest", "T_B", "T_C" }, tids(t.Combat))
      assert.are.equal(2, R.place(t, { action = "flee", from = "nearest" }, "Combat"), "a repeat add stays put")
      assert.are.equal(5, R.place(t, { action = "flee", from = "strongest" }, "Combat"), "both flee rows may be placed")
      assert.are.equal(5, R.count(t))
      assert.are.same({ { section = "Combat", index = 2 } }, R.where(t, flee))
    end)

    it("stores its own copy on an add, so two placements never share a table", function()
      -- The talent screen's "Also add to" hands over the stored entry of the
      -- section the row is in (#56); a per-placement field set afterwards in
      -- one section must not appear in the other.
      local stored = t.Combat[2]
      assert.are.equal(1, R.place(t, stored, "Recovery"))
      assert.are_not.equal(stored, t.Recovery[1])
      assert.are.same({ tid = "T_B" }, t.Recovery[1])
      t.Combat[2].extra = true
      assert.is_nil(t.Recovery[1].extra, "a field set in one section does not appear in the other")
      local given = { tid = "T_X", extra = true }
      R.place(t, given, "Combat")
      assert.are_not.equal(given, t.Combat[4])
      assert.is_true(t.Combat[4].extra, "the copy carries the fields it was given")
    end)

    it("keeps a flee's extra fields through a reposition and a shift (#59)", function()
      local flee = { action = "flee", from = "strongest", extra = true }
      R.place(t, flee, "Combat")
      local stored = t.Combat[4]
      assert.is_true(stored.extra)
      R.place(t, { action = "flee", from = "strongest" }, "Combat", { tid = "T_A" })
      assert.are.equal(stored, t.Combat[1], "repositioned in place: the same table")
      assert.is_true(t.Combat[1].extra)
      assert.are.equal(3, R.shift(t, { action = "flee", from = "strongest" }, "Combat", 2))
      assert.is_true(t.Combat[3].extra)
      assert.are.same({ "T_A", "T_B", "!flee:strongest", "T_C" }, tids(t.Combat))
    end)
  end)

  describe("remove and removeAll", function()
    local t
    before_each(function()
      t = R.new()
      t.Combat = { { tid = "T_A" }, { tid = "T_B" }, { tid = "T_C" } }
      t.Recovery = { { tid = "T_B" } }
    end)

    it("removes a rule from one section and reports where it was", function()
      local e, i = R.remove(t, { tid = "T_B" }, "Combat")
      assert.are.same({ tid = "T_B" }, e)
      assert.are.equal(2, i)
      assert.are.same({ "T_A", "T_C" }, tids(t.Combat))
      assert.are.same({ "T_B" }, tids(t.Recovery), "the other placement stays")
      assert.is_nil(R.remove(t, { tid = "T_B" }, "Combat"))
    end)

    it("removes a rule from every section", function()
      assert.are.equal(2, R.removeAll(t, { tid = "T_B" }))
      assert.are.same({ "T_A", "T_C" }, tids(t.Combat))
      assert.are.same({}, tids(t.Recovery))
      assert.are.equal(0, R.removeAll(t, { tid = "T_B" }))
    end)
  end)

  describe("shift", function()
    local t
    before_each(function()
      t = R.new()
      t.Recovery = { { tid = "T_A" }, { tid = "T_B" }, { tid = "T_C" } }
      t.Combat = { { tid = "T_B" } }
    end)

    it("moves a rule up and down within the named section only", function()
      assert.are.equal(1, R.shift(t, { tid = "T_B" }, "Recovery", -1))
      assert.are.same({ "T_B", "T_A", "T_C" }, tids(t.Recovery))
      assert.are.equal(3, R.shift(t, { tid = "T_B" }, "Recovery", 2))
      assert.are.same({ "T_A", "T_C", "T_B" }, tids(t.Recovery))
      assert.are.same({ "T_B" }, tids(t.Combat))
    end)

    it("clamps at the ends", function()
      assert.are.equal(1, R.shift(t, { tid = "T_A" }, "Recovery", -1))
      assert.are.equal(3, R.shift(t, { tid = "T_C" }, "Recovery", 5))
      assert.are.same({ "T_A", "T_B", "T_C" }, tids(t.Recovery))
    end)

    it("does nothing for a rule that is not in that section", function()
      assert.is_nil(R.shift(t, { tid = "T_X" }, "Recovery", 1))
      assert.is_nil(R.shift(t, { tid = "T_A" }, "Combat", 1))
    end)

  end)

  describe("remove, removeAll and prune with a flee (#59)", function()
    it("remove a flee by identity and leave the talents", function()
      local t = R.new()
      t.Combat = { { action = "flee", from = "nearest", extra = true }, { tid = "T_A" },
                   { action = "flee", from = "strongest" } }
      local e = R.remove(t, { action = "flee", from = "nearest" }, "Combat")
      assert.are.same({ action = "flee", from = "nearest", extra = true }, e)
      assert.are.same({ "T_A", "!flee:strongest" }, tids(t.Combat))
      assert.are.equal(1, R.removeAll(t, { action = "flee", from = "strongest" }))
      assert.are.same({ "T_A" }, tids(t.Combat))
    end)

    it("prune keeps a flee when the predicate does, whatever the character knows", function()
      local t = R.new()
      t.Combat = { { action = "flee", from = "nearest" }, { tid = "T_GONE" } }
      local removed = R.prune(t, function(e) return e.action ~= nil end)
      assert.are.same({ "!flee:nearest" }, tids(t.Combat))
      assert.are.equal(1, #removed)
    end)
  end)

  describe("prune and tids", function()
    it("drops what the predicate rejects and returns it", function()
      local t = R.new()
      t.Combat = { { tid = "T_A" }, { tid = "T_GONE" }, { object = "lost rod" } }
      t.Sustain = { { tid = "T_GONE" } }
      local removed = R.prune(t, function(e) return e.tid == "T_A" end)
      assert.are.same({ "T_A" }, tids(t.Combat))
      assert.are.same({}, tids(t.Sustain))
      assert.are.equal(3, #removed)
    end)

    it("lists a section's tids in order, skipping what does not resolve", function()
      local t = R.new()
      t.Combat = { { object = "carried rod" }, { tid = "T_A" }, { object = "dormant rod" }, { tid = "T_B" } }
      assert.are.same({ "T_A", "T_B" }, R.tids(t, "Combat"))
      local live = { ["carried rod"] = "T_ACTIVATE_OBJECT_3" }
      assert.are.same({ "T_ACTIVATE_OBJECT_3", "T_A", "T_B" },
        R.tids(t, "Combat", function(e) return e.tid or live[e.object] end))
      assert.are.same({}, R.tids(t, "Recovery"))
      assert.are.same({}, R.tids(t, "Nowhere"))
    end)

    it("skips a flee action when listing talent ids: it has none (#59)", function()
      local t = R.new()
      t.Combat = { { action = "flee", from = "nearest" }, { tid = "T_A" } }
      assert.are.same({ "T_A" }, R.tids(t, "Combat"))
    end)
  end)
end)
