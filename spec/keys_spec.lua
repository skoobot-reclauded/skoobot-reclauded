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
