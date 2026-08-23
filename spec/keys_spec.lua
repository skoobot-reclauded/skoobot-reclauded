-- luacheck: std luajit+busted

-- data/keys.lua expands an engine key string ("sym:_F7:false:true:false:false")
-- into the form a player reads ("Shift+F7"). Messages name the key the player
-- actually has bound, looked up at message time (#57); this is the rendering
-- half, tested without a running game by passing the symbol-name resolver in.

local manifest = require "spec.support.manifest"

local function loadKeys()
  local chunk = assert(loadfile(manifest.path("src/data/keys.lua")))
  return chunk()
end

describe("data/keys.lua describe()", function()
  local keys

  setup(function() keys = loadKeys() end)

  -- What core.key.symName would answer for the symbols used below.
  local names = { _F3 = "F3", _F7 = "F7", _a = "A", _KP1 = "Keypad 1", ["64"] = "F7" }
  local function symname(sym) return names[sym] end

  it("renders the default menu key as Shift+F7, not the engine's SF7", function()
    assert.equals("Shift+F7", keys.describe("sym:_F7:false:true:false:false", symname))
  end)

  it("renders the default toggle key as Shift+F3", function()
    assert.equals("Shift+F3", keys.describe("sym:_F3:false:true:false:false", symname))
  end)

  it("renders an unmodified key bare", function()
    assert.equals("A", keys.describe("sym:_a:false:false:false:false", symname))
  end)

  it("orders modifiers Ctrl, Alt, Shift, Meta", function()
    assert.equals("Ctrl+Alt+Shift+Meta+F7", keys.describe("sym:_F7:true:true:true:true", symname))
    assert.equals("Ctrl+F7", keys.describe("sym:_F7:true:false:false:false", symname))
    assert.equals("Alt+Shift+F7", keys.describe("sym:_F7:false:true:true:false", symname))
  end)

  it("keeps a keypad name readable", function()
    assert.equals("Keypad 1", keys.describe("sym:_KP1:false:false:false:false", symname))
  end)

  it("accepts a numeric symbol code", function()
    assert.equals("Shift+F7", keys.describe("sym:64:false:true:false:false", symname))
  end)

  it("takes a literal name after '=' without asking the resolver", function()
    assert.equals("Ctrl+Space", keys.describe("sym:=Space:true:false:false:false", function() error("not asked") end))
  end)

  it("falls back to the bare symbol when the resolver does not know it", function()
    assert.equals("Shift+F13", keys.describe("sym:_F13:false:true:false:false", symname))
    assert.equals("Shift+F13", keys.describe("sym:_F13:false:true:false:false", nil))
    assert.equals("Shift+F13", keys.describe("sym:_F13:false:true:false:false", function() return "" end))
  end)

  it("returns the character of a unicode binding", function()
    assert.equals("é", keys.describe("uni:é", symname))
  end)

  it("returns nil for mouse and gesture bindings, so the caller can fall back", function()
    assert.is_nil(keys.describe("mouse:button1:false:false:false:false", symname))
    assert.is_nil(keys.describe("gest:LR", symname))
  end)

  it("returns nil for anything that is not a binding string", function()
    assert.is_nil(keys.describe(nil, symname))
    assert.is_nil(keys.describe(42, symname))
    assert.is_nil(keys.describe("sym:oops", symname))
    assert.is_nil(keys.describe("", symname))
  end)
end)

-- #50: which of the addon's actions share a key with another action. The
-- engine's two class-level tables come in as plain data: binds_def (what every
-- addon defined, with its default keys) and binds_remap (what the player
-- changed, replacing the default for that action). Nothing is rebound.
describe("data/keys.lua collisions()", function()
  local keys

  setup(function() keys = loadKeys() end)

  local SF3 = "sym:_F3:false:true:false:false"   -- Shift+F3, the default toggle
  local SF7 = "sym:_F7:false:true:false:false"   -- Shift+F7, the default menu key
  local F3  = "sym:_F3:false:false:false:false"  -- bare F3, the base game's party switch

  local OURS = { "TOGGLE_SKOOBOT_RECLAUDED", "MENU_SKOOBOT_RECLAUDED" }

  -- The base game's F3 and Ctrl+F3, plus this addon's two, the way
  -- KeyBind:defineAction stores them.
  local function defs()
    return {
      SWITCH_PARTY_3           = { default = { F3 }, name = "Switch control to character 3" },
      ORDER_PARTY_3            = { default = { "sym:_F3:true:false:false:false" },
                                   name = "Give orders to character 3" },
      TOGGLE_SKOOBOT_RECLAUDED = { default = { SF3 }, name = "Toggle SkooBot: Reclauded" },
      MENU_SKOOBOT_RECLAUDED   = { default = { SF7 }, name = "Open the SkooBot: Reclauded menu" },
    }
  end

  it("finds no collision with the default binds", function()
    assert.same({}, keys.collisions(defs(), nil, OURS))
    assert.same({}, keys.collisions(defs(), {}, OURS))
  end)

  it("reports a collision with the base game when the player remaps onto F3", function()
    local remap = { TOGGLE_SKOOBOT_RECLAUDED = { F3 } }
    assert.same({
      { type = "TOGGLE_SKOOBOT_RECLAUDED", keystring = F3, others = { "SWITCH_PARTY_3" } },
    }, keys.collisions(defs(), remap, OURS))
  end)

  it("reports a collision with another addon that defaults to Shift+F3", function()
    local d = defs()
    d.OTHER_ADDON_THING = { default = { SF3 }, name = "Do the other addon's thing" }
    assert.same({
      { type = "TOGGLE_SKOOBOT_RECLAUDED", keystring = SF3, others = { "OTHER_ADDON_THING" } },
    }, keys.collisions(d, nil, OURS))
  end)

  it("follows the other addon's remap, not its default", function()
    -- Its default collides; the player moved it away. No collision.
    local d = defs()
    d.OTHER_ADDON_THING = { default = { SF3 }, name = "Do the other addon's thing" }
    assert.same({}, keys.collisions(d, { OTHER_ADDON_THING = { "sym:_F9:false:false:false:false" } }, OURS))
  end)

  it("treats an unbound SkooBot action as colliding with nothing", function()
    -- Unbound by the player (an empty remap) and unbound by default.
    local d = defs()
    d.ASK_SKOOBOT_RECLAUDED = { default = {}, name = "Ask SkooBot: Reclauded what it would do" }
    local ours = { "TOGGLE_SKOOBOT_RECLAUDED", "ASK_SKOOBOT_RECLAUDED", "MENU_SKOOBOT_RECLAUDED" }
    assert.same({}, keys.collisions(d, { MENU_SKOOBOT_RECLAUDED = {} }, ours))
  end)

  it("skips an action of ours that was never defined", function()
    assert.same({}, keys.collisions(defs(), nil, { "NOT_LOADED_SKOOBOT_RECLAUDED" }))
  end)

  it("lists every other action on the key, sorted, and one entry per key", function()
    local d = defs()
    d.ZZZ_THING = { default = { SF3 }, name = "z" }
    d.AAA_THING = { default = { "sym:_x:false:false:false:false", SF3 }, name = "a" }
    -- Our toggle is bound to Shift+F3 twice over (a remap can list a key
    -- twice): one entry, not two.
    local remap = { TOGGLE_SKOOBOT_RECLAUDED = { SF3, SF3 } }
    assert.same({
      { type = "TOGGLE_SKOOBOT_RECLAUDED", keystring = SF3, others = { "AAA_THING", "ZZZ_THING" } },
    }, keys.collisions(d, remap, OURS))
  end)

  it("reports in the order the addon lists its actions, one key at a time", function()
    local remap = {
      MENU_SKOOBOT_RECLAUDED   = { F3, SF3 },   -- F3 hits the party switch; Shift+F3 hits our toggle
      TOGGLE_SKOOBOT_RECLAUDED = { SF3 },
    }
    assert.same({
      { type = "TOGGLE_SKOOBOT_RECLAUDED", keystring = SF3, others = { "MENU_SKOOBOT_RECLAUDED" } },
      { type = "MENU_SKOOBOT_RECLAUDED",   keystring = F3,  others = { "SWITCH_PARTY_3" } },
      { type = "MENU_SKOOBOT_RECLAUDED",   keystring = SF3, others = { "TOGGLE_SKOOBOT_RECLAUDED" } },
    }, keys.collisions(defs(), remap, OURS))
  end)

  it("renders the menu's status line", function()
    assert.equals("Keybinds: OK", keys.summary(0))
    assert.equals("Keybinds: OK", keys.summary(nil))
    assert.equals("Keybinds: 1 collision (see log)", keys.summary(1))
    assert.equals("Keybinds: 2 collisions (see log)", keys.summary(2))
  end)

  it("renders one collision with the key first and our action first", function()
    local d = defs()
    d.OTHER_ADDON_THING = { default = { SF3 }, name = "Do the other addon's thing" }
    local function nameOf(t) return d[t] and d[t].name or t end
    local c = keys.collisions(d, nil, OURS)[1]
    assert.equals('Shift+F3: "Toggle SkooBot: Reclauded" and "Do the other addon\'s thing"',
      keys.collisionText(c, "Shift+F3", nameOf))
    c.others = { "OTHER_ADDON_THING", "SWITCH_PARTY_3" }
    assert.equals('Shift+F3: "Toggle SkooBot: Reclauded", "Do the other addon\'s thing"'
      .. ' and "Switch control to character 3"',
      keys.collisionText(c, "Shift+F3", nameOf))
  end)
end)
