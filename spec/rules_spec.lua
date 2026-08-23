-- luacheck: std luajit+busted

-- data/rules.lua holds the talent rules the bot reads and the talent screen
-- edits (#56): four ordered sections, one rule per talent or item, order as
-- priority. It is a pure module so that the list operations -- the part of
-- the screen the harness cannot drive with a mouse -- are tested here.

local manifest = require "spec.support.manifest"

local function loadRules()
  local chunk = assert(loadfile(manifest.path("src/data/rules.lua")))
  return chunk()
end

local function tids(list)
  local out = {}
  for i, e in ipairs(list) do out[i] = e.tid or ("@" .. tostring(e.object)) end
  return out
end

describe("data/rules.lua", function()
  local R

  setup(function() R = loadRules() end)

  it("is a pure module exposing the list operations", function()
    for _, f in ipairs({ "new", "normalize", "key", "same", "find", "remove", "place", "shift",
                         "prune", "tids", "count", "allowed", "isSection" }) do
      assert.is_function(R[f], f)
    end
    assert.are.same({ "Combat", "DamagePrevention", "Recovery", "Sustain" }, R.SECTIONS)
    for _, s in ipairs(R.SECTIONS) do
      assert.is_string(R.LABELS[s], s)
      assert.is_string(R.DESCRIPTIONS[s], s)
      assert.is_true(R.isSection(s))
    end
    assert.is_false(R.isSection("Unassigned"))
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

    it("keeps a rule in one section only: the highest-priority occurrence wins", function()
      local t = {
        { tid = "T_A", usetype = "Combat",   priority = 1 },
        { tid = "T_A", usetype = "Recovery", priority = 7 },
        { tid = "T_A", usetype = "Combat",   priority = 3 },
      }
      local _, report = R.normalize(t)
      assert.are.same({ "T_A" }, tids(t.Recovery))
      assert.are.same({}, tids(t.Combat))
      assert.are.equal(1, report.migrated)
      assert.are.equal(2, report.dropped)
    end)

    it("absorbs v1-shaped entries pushed into the array part of a current table", function()
      -- What a scenario that predates #56 does: normalize once, then push.
      local t = R.normalize({})
      t.Combat[1] = { tid = "T_OLD" }
      t[#t + 1] = { tid = "T_NEW", usetype = "Combat", priority = 1 }
      t[#t + 1] = { tid = "T_OLD", usetype = "Sustain", priority = 9 }   -- already placed: dropped
      local _, report = R.normalize(t)
      assert.are.same({ "T_OLD", "T_NEW" }, tids(t.Combat))
      assert.are.same({}, tids(t.Sustain))
      assert.are.equal(0, #t)
      assert.are.equal(1, report.migrated)
      assert.are.equal(1, report.dropped)
    end)

    it("dedupes within and across sections of a current table, existing sections first", function()
      local t = {
        Combat   = { { tid = "T_A" }, { tid = "T_B" }, { tid = "T_A" } },
        Recovery = { { tid = "T_B" }, { object = "rod" }, {} },
      }
      local _, report = R.normalize(t)
      assert.are.same({ "T_A", "T_B" }, tids(t.Combat))
      assert.are.same({ "@rod" }, tids(t.Recovery))
      assert.are.equal(3, report.dropped)
    end)

    it("is idempotent", function()
      local t = R.normalize({ { tid = "T_A", usetype = "Combat", priority = 1 } })
      local before = tids(t.Combat)
      local _, report = R.normalize(t)
      assert.are.same(before, tids(t.Combat))
      assert.are.same({ migrated = 0, dropped = 0 }, report)
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
      assert.is_false((R.allowed("activated", "Unassigned")))
    end)
  end)

  describe("place, find and remove", function()
    local t
    before_each(function()
      t = R.new()
      t.Combat = { { tid = "T_A" }, { tid = "T_B" }, { tid = "T_C" } }
    end)

    it("appends a new rule to a section", function()
      assert.are.equal(1, R.place(t, { tid = "T_X" }, "Recovery"))
      assert.are.same({ "T_X" }, tids(t.Recovery))
      assert.are.same({ "Recovery", 1 }, { R.find(t, { tid = "T_X" }) })
    end)

    it("inserts before a given entry", function()
      assert.are.equal(2, R.place(t, { tid = "T_X" }, "Combat", { tid = "T_B" }))
      assert.are.same({ "T_A", "T_X", "T_B", "T_C" }, tids(t.Combat))
    end)

    it("moves a rule between sections, taking it out of the old one", function()
      assert.are.equal(1, R.place(t, { tid = "T_B" }, "Recovery"))
      assert.are.same({ "T_A", "T_C" }, tids(t.Combat))
      assert.are.same({ "T_B" }, tids(t.Recovery))
      assert.are.equal(3, R.count(t))
    end)

    it("reorders within a section, before an entry either side of it", function()
      assert.are.equal(1, R.place(t, { tid = "T_C" }, "Combat", { tid = "T_A" }))
      assert.are.same({ "T_C", "T_A", "T_B" }, tids(t.Combat))
      assert.are.equal(2, R.place(t, { tid = "T_C" }, "Combat", { tid = "T_B" }))
      assert.are.same({ "T_A", "T_C", "T_B" }, tids(t.Combat))
      assert.are.equal(3, R.place(t, { tid = "T_A" }, "Combat"))
      assert.are.same({ "T_C", "T_B", "T_A" }, tids(t.Combat))
    end)

    it("moves the STORED table, so extra fields survive a move", function()
      t.Combat[2].hold = true
      R.place(t, { tid = "T_B" }, "Recovery")
      assert.is_true(t.Recovery[1].hold)
    end)

    it("treats a drop onto itself as a no-op", function()
      assert.are.equal(2, R.place(t, { tid = "T_B" }, "Combat", { tid = "T_B" }))
      assert.are.same({ "T_A", "T_B", "T_C" }, tids(t.Combat))
    end)

    it("appends when the `before` entry is not in the target section", function()
      assert.are.equal(4, R.place(t, { tid = "T_X" }, "Combat", { tid = "T_NOWHERE" }))
      assert.are.same({ "T_A", "T_B", "T_C", "T_X" }, tids(t.Combat))
    end)

    it("refuses a bad section or a non-rule", function()
      local at, why = R.place(t, { tid = "T_X" }, "Unassigned")
      assert.is_nil(at)
      assert.is_string(why)
      at, why = R.place(t, {}, "Combat")
      assert.is_nil(at)
      assert.is_string(why)
      assert.are.equal(3, R.count(t))
    end)

    it("removes a rule and reports where it was", function()
      local e, s, i = R.remove(t, { tid = "T_B" })
      assert.are.same({ tid = "T_B" }, e)
      assert.are.equal("Combat", s)
      assert.are.equal(2, i)
      assert.are.same({ "T_A", "T_C" }, tids(t.Combat))
      assert.is_nil(R.remove(t, { tid = "T_B" }))
      assert.is_nil(R.find(t, { tid = "T_B" }))
    end)

    it("handles item rules the same way", function()
      assert.are.equal(4, R.place(t, { object = "wand of fire" }, "Combat"))
      assert.are.equal(1, R.place(t, { object = "wand of fire" }, "Combat", { tid = "T_A" }))
      assert.are.same({ "@wand of fire", "T_A", "T_B", "T_C" }, tids(t.Combat))
    end)
  end)

  describe("shift", function()
    local t
    before_each(function()
      t = R.new()
      t.Recovery = { { tid = "T_A" }, { tid = "T_B" }, { tid = "T_C" } }
    end)

    it("moves a rule up and down within its section", function()
      assert.are.equal(1, R.shift(t, { tid = "T_B" }, -1))
      assert.are.same({ "T_B", "T_A", "T_C" }, tids(t.Recovery))
      assert.are.equal(3, R.shift(t, { tid = "T_B" }, 2))
      assert.are.same({ "T_A", "T_C", "T_B" }, tids(t.Recovery))
    end)

    it("clamps at the ends", function()
      assert.are.equal(1, R.shift(t, { tid = "T_A" }, -1))
      assert.are.equal(3, R.shift(t, { tid = "T_C" }, 5))
      assert.are.same({ "T_A", "T_B", "T_C" }, tids(t.Recovery))
    end)

    it("does nothing for a rule that is not placed", function()
      assert.is_nil(R.shift(t, { tid = "T_X" }, 1))
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
  end)
end)
