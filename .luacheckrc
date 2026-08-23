-- .luacheckrc -- luacheck 1.2.0 configuration for SkooBot: Reclauded. T-002.
--
-- WHAT THIS IS
--
-- The global surface that T-Engine 1.7.6 and the `tome` module leave in _G for
-- ADDON code, declared so that luacheck reports signal -- a typo, a leaked
-- global, the W582 class the pre-commit hook exists for -- instead of hundreds
-- of "accessing undefined variable 'game'". Every group below names the file
-- that creates its globals. Path legend: engine/ is the T-Engine Lua tree
-- (engine/ inside the unpacked engine archive), tome/ the tome module (mod/ and
-- data/), game/ is <install>/game (loader/, thirdparty/), bootstrap/ is
-- <install>/bootstrap. Line numbers are for the 1.7.6 sources.
--
-- WHAT IS DELIBERATELY ABSENT
--
-- Names that exist only inside a data-file loader environment are NOT
-- declared: newTalent, newTalentType, Talents, newEffect, newEntity, rarity,
-- DamageType, Map, Particles, defineTile, addSpot, newChat, newLore, newAI,
-- newBirthDescriptor, newAchievement, newDamageType, t, section, and the
-- helpers talent files define on top of them (damDesc, spells_req1, ...).
-- Each loader runs its files under setfenv() with a private table whose
-- __index is _G and which has no __newindex, so nothing assigned or injected
-- there ever reaches _G: engine/interface/ActorTalents.lua:32-41,
-- engine/interface/ActorTemporaryEffects.lua:31-36, engine/Entity.lua:1213-1263,
-- engine/DamageType.lua:45-50, engine/generator/map/Static.lua:69-167,
-- engine/Chat.lua:50-69, engine/I18N.lua:97-109 (locales: t, section), and so
-- on. Declaring them globally would hide a real nil in hook or class code.
-- The loader names this repo's own trees run under (defineAction,
-- loadPrevious, superload, the manifest fields) are scoped per path at the
-- bottom of this file, and only there.
--
-- Also absent: names luacheck mis-reads as globals in the engine's own files
-- (_M, DIFFICULTY_*, TOOLTIP_*, TERRAIN, _F1, shat ...). engine/class.lua:27-50
-- replaces module() with a proxy environment whose __newindex writes to the
-- class table, so a bare assignment after module(...) is a class field, never
-- _G. And names the game never registers as globals at all: ffi (luacheck's
-- luajit std omits it too; tome/mod/class/AsciiMap.lua:20 requires it), md5,
-- sha1, tween and the other game/thirdparty modules that `return` a table.
--
-- HOW TO RUN
--
-- From the repo root: `luacheck .` -- no --std, no --ignore. This file carries
-- everything. A command-line --std replaces the top-level std (the per-path
-- std entries below still win -- both verified on 1.2.0), so `--std luajit` is
-- redundant and any other value is wrong; a command-line --ignore silences
-- those classes EVERYWHERE, including the real leaks this file exists to make
-- visible (verified: W111/W113 probes vanish under `--ignore 111 113`).
-- `luacheck src/` with a trailing slash checks nothing and exits 3 (T-046);
-- `luacheck src` is fine. The `files` keys are matched against paths relative
-- to this file's directory, so running from a subdirectory also works; passing
-- --config with another path does not.

std = "luajit"
-- LuaJIT 2.0.2 is Lua 5.1: this std supplies bit, jit, unpack, setfenv,
-- getfenv, loadstring, module, table.getn and friends. It cannot express what
-- the game REMOVES: os.execute, os.getenv, os.remove and os.rename are nil
-- in-game (game/loader/pre-init.lua:216-219) and os.exit is rebound to
-- core.game.exit_engine (engine/utils.lua:3161). A call to any of them passes
-- lint and fails at runtime, so never use them under src/ (spec/ runs under
-- busted, where they exist).

-- Globals this repo assigns BY NAME: none, and that is the intent. The bot's
-- runtime table is exported exactly once, with an explicit
-- `_G.skoobot_reclauded = ...` in the Player superload (the devbridge tools
-- export `_G.bridge` the same way), because superload and hook chunks run in
-- sandboxes whose bare assignments are invisible to everything else
-- (game/loader/init.lua:171-177, engine/Module.lua:699). luacheck accepts
-- `_G.x = ...` and `rawget(_G, "x")` silently; the names themselves are
-- declared read-only below, so a bare rebinding anywhere -- which a sandboxed
-- chunk would silently swallow -- is still flagged (W121). Field writes the
-- repo does make by design (config.settings.*, game.paused) are declared
-- field-precise on the read_globals entries instead of moving the name here:
-- that keeps every OTHER field of those globals write-protected (verified on
-- 1.2.0, including writes through local aliases; method calls such as
-- game.key:addBinds are reads and need nothing). Extend the same way if the
-- port ever writes another engine-owned field.
globals = {}

read_globals = {
    -- C side of t-engine.exe, proven by use before any Lua could define them:
    -- fs at bootstrap/boot.lua:6, rng at game/loader/pre-init.lua:48, core at
    -- game/loader/init.lua:52. The engine only adds fields (engine/utils.lua).
    "core", "fs", "rng",

    -- C-side libraries, proven by bare use with no Lua definition and no
    -- require: lpeg (engine/LogDisplay.lua:115), zlib
    -- (engine/PlayerProfile.lua:593), lxp (game/thirdparty/lxp/lom.lua:9
    -- `local lxp = lxp` right after `require "lxp"`), __uids
    -- (engine/Entity.lua:40 calls setmetatable(__uids, ...) on a table it never
    -- creates; go through __get_uid_entity instead).
    "lpeg", "zlib", "lxp", "__uids",

    -- game/loader/pre-init.lua:75,79
    "get_printlog", "truncate_printlog",

    -- game/loader/init.lua:29-42,80 (reboot arguments) and :137-138 (superload
    -- bookkeeping, reset at engine/Module.lua:679). Loader internals, not API;
    -- declared so a read is not a false positive. __module_extra_info is the
    -- one the unattended harness may care about (auto_birth, no_quickbirth ...).
    "__load_module", "__player_name", "__player_new", "__request_profile",
    "__module_extra_info", "__available_engines",
    "__addons_superload_order", "__addons_fn_superloads",

    -- game/thirdparty: Lua 5.1 module() globals. socket.lua:14, ltn12.lua:14
    -- and mime.lua:16 via engine/PlayerProfile.lua:21-23 (socket.http requires
    -- ltn12 and mime); Json2.lua:41 registers `json`, not Json2
    -- (engine/PlayerProfile.lua:27).
    "socket", "ltn12", "mime", "json",

    -- game/thirdparty/config.lua:5 module("config"), required at
    -- engine/init.lua:29. The NAME is read-only, but config.settings
    -- (config.lua:7) is the engine's mutable store for addon settings --
    -- data/settings.lua seeds config.settings.tome.skoobot_reclauded and the
    -- options tab writes it back through game:saveSettings -- so that one
    -- field tree is writable, aliases included (verified on 1.2.0).
    -- load/loadString/loadFile/loadFunction are its API (config.lua:9-47).
    config = { fields = {
        settings = { read_only = false, other_fields = true },
        "load", "loadString", "loadFile", "loadFunction",
    } },

    -- The addon's own runtime table: assigned exactly once, explicitly, as
    -- _G.skoobot_reclauded in src/superload/mod/class/Player.lua, and read
    -- bare everywhere else (hooks/load.lua, the dialogs). Read-only so a
    -- second, bare assignment stays flagged -- inside a hook or superload
    -- sandbox it would not even reach _G.
    "skoobot_reclauded",

    -- engine/class.lua:54 module("class") -- class:bindHook, class.inherit;
    -- :51 is the guard flag for its module() wrapper.
    "class", "__class_module",

    -- Namespaces created by Lua 5.1 module(): `engine` on the first
    -- module("engine.X") (engine/Game.lua:29, engine.version at
    -- engine/version.lua:24-26), `mod` on module("mod.class.Game")
    -- (tome/mod/class/Game.lua:62).
    "engine", "mod",

    -- engine/init.lua:179 (game = false until a module starts), :193, :197;
    -- engine/Module.lua:1086 (_G.game = M.new()), :1093-1096 (_G.world).
    -- `game` is false while hooks/load.lua runs and nil-guards there are
    -- legitimate; it is a real object from the ToME:run hook onward. The name
    -- must never be rebound (W121 stays), and its fields stay write-protected
    -- (W122) except `paused`: the pause flag ToME's own player code toggles
    -- (tome/mod/class/Player.lua:424,436, GameState.lua:868), which the
    -- ACTION_DELAY port writes in the Player superload by design (D-12).
    game = { fields = { paused = { read_only = false } }, other_fields = true },
    "profile", "savefile_pipe", "world",

    -- engine/utils.lua, dofile'd by engine/init.lua:23 with no module() call,
    -- so its column-1 definitions are real globals: util :2225, tstring :1563,
    -- line :2938 (Bresenham; an unfortunately generic name -- a local `line`
    -- shadows it and luacheck will say so), iterators :117-151, tprint :251,
    -- require_first :3169, and the uid/debug internals :1408, :1420, :3164.
    "util", "tstring", "line",
    "ipairsclone", "pairsclone", "ripairsclone", "ripairs",
    "ipairs_value", "ripairs_value", "tprint", "require_first",
    "__get_uid_surface", "__get_uid_entity", "__dump_fct",

    -- engine/colors.lua:24-27,37, dofile'd by engine/init.lua:24
    "colors", "colors_simple", "r_colors", "r_colors_simple", "defineColor",

    -- engine/resolvers.lua:30, dofile'd by engine/init.lua:27; tome adds its
    -- own at tome/mod/resolvers.lua. Defining a resolver is a field write --
    -- see the note above `globals`.
    "resolvers",

    -- engine/I18N.lua:37,61,65,72 -- explicit _G. assignments. `_t` is the
    -- translation marker; it is not the locale-file `t`, which is absent here.
    "_t", "_nt", "_getFlagI18N", "default_tformat",

    -- engine/KeyCommand.lua:41 (_G.profiling) -- set only by the profiler
    -- debug chord, nil in normal play.
    "profiling",

    -- tome/mod/load.lua:101,103 -- the starter chunk has no module() call, so
    -- these two are the only _G globals the tome module's own code adds.
    "_3DNoise", "_2DNoise",

    -- Standard tables the engine extends. luacheck checks field access on std
    -- tables (W143), so the additions are listed; the std's own fields are
    -- merged in, not replaced (verified on 1.2.0).

    -- table: engine/utils.lua:97-898 and game/loader/pre-init.lua:136 (serialize)
    table = { fields = {
        "serialize",
        "concatNice", "to_strings", "weak_keys", "weak_values", "empty",
        "replaceWith", "count", "min", "max", "print_shallow", "print", "iprint",
        "genrange", "minus_keys", "clone", "NIL_MERGE", "merge",
        "mergeAppendArray", "mergeAdd", "mergeAddAppendArray", "append",
        "reverse", "reversekey", "listify", "keys_to_values", "keys", "ts",
        "lower", "capitalize", "values", "equivalence", "extract_field",
        "same_values", "from_list", "hasInList", "removeFromList", "pairsRemove",
        "check", "update", "readonly", "map", "mapv", "maplist", "splitlist",
        "compareKeys", "has", "get", "sget", "set", "getTable", "orderedPairs",
        "orderedPairs2", "shuffle", "rules", "applyRules", "ruleMergeAppendAdd",
    } },

    -- string: engine/utils.lua:49-1628, game/loader/pre-init.lua:204
    -- (unserialize), engine/I18N.lua:87 (tformat), and one from tome --
    -- mod/class/NicerTiles.lua:1902 (get), top level of a class file
    -- mod/class/Game.lua:40 always requires
    string = { fields = {
        "unserialize", "tformat", "get",
        "limit_decimals", "tslash", "ttype", "nextUTF", "ordinal", "trim",
        "a_an", "he_she", "his_her", "him_her", "his_her_self", "capitalize",
        "bookCapitalize", "noun_sub", "lpegSub", "lpegSubT", "prefix", "suffix",
        "iterateUTF", "removeColorCodes", "removeColorCodesT", "removeUIDCodes",
        "splitAtSizeSimple", "splitAtSize", "splitLine", "splitLines",
        "fromFunction", "fromValue", "fromTable", "levenshtein_distance",
        "split", "levenshtein", "levenshtein_p", "parseHex", "toHex",
        "toTString",
    } },

    -- math: engine/utils.lua:28-86
    math = { fields = {
        "decimals", "round", "scale", "boundscale", "triangle_area",
        "find_closest_lower", "find_closest_higher",
    } },

    -- os: engine/utils.lua:3160 (crash = the original os.exit). The removals
    -- listed under `std` above cannot be expressed here.
    os = { fields = { "crash" } },

    -- package: game/loader/pre-init.lua:43
    package = { fields = { "moonpath" } },
}

-- ---------------------------------------------------------------------------
-- Per-path environments. Each block models how the engine actually executes
-- that kind of file. Keys are luacheck globs relative to this directory
-- (`*` stops at a slash, `**` does not); every key below was verified to
-- match its files on 1.2.0.
-- ---------------------------------------------------------------------------

-- Addon manifest. engine/Module.lua:384-388: loadfile(dir.."/init.lua"),
-- `local add = {}`, setfenv(add_def, add), add_def(). An EMPTY table with no
-- metatable: the manifest can read nothing -- not string, not require, not
-- game -- and every top-level assignment is a manifest field. So std = "none"
-- and a fresh, exact global list: any read here is a real nil at load time.
-- Fields the engine reads: short_name, long_name, for_module, version,
-- addon_version (:390-400, :488-532), weight (:437), hooks/overload/
-- superload/data (:498-532), cheat_only (:574), dlc, id_dlc, dlc_files
-- (:401-402, :602-604), disable_addons (:630), requires_addons (:655-658).
-- author, homepage, description and tags have no engine consumer (te4.org
-- metadata by convention; tome/mod/init.lua sets them too). Left out on
-- purpose so a manifest that sets them is flagged: dir, teaa, teaac,
-- natural_compatible, version_txt, addon_version_txt, version_name,
-- hash_valid, hash_err -- the engine writes those onto the table itself
-- (:391-402, :488, :1062). The description is one long [[string]]; line
-- length is meaningless inside it.
local function manifest()
    return {
        std = "none",
        new_read_globals = {},
        new_globals = {
            "long_name", "short_name", "for_module", "version", "addon_version",
            "weight", "author", "homepage", "description", "tags",
            "hooks", "overload", "superload", "data",
            "cheat_only", "dlc", "id_dlc", "dlc_files",
            "disable_addons", "requires_addons",
        },
        max_line_length = false,
    }
end
files["src/init.lua"] = manifest()
files["tools/*/init.lua"] = manifest()

-- hooks/load.lua. engine/Module.lua:690-699 runs it with
-- setmetatable({superload = fn, __addon_name = short_name}, {__index = _G}).
-- Only load.lua itself: files pulled in with class:loadHooksFile get a bare
-- {} -> _G env (engine/class.lua:402) and do not see these two. Bare
-- assignments stay in the sandbox, so W111 here is a real bug, not noise.
files["src/hooks/load.lua"] = { read_globals = { "superload", "__addon_name" } }
files["tools/*/hooks/load.lua"] = { read_globals = { "superload", "__addon_name" } }

-- superload/**. game/loader/init.lua:171-177 (te4_loader, installed at
-- package.loaders[2] by :188) runs each /mod/addons/<addon>/superload/<path>
-- chunk with setmetatable({loadPrevious = fn}, {__index = _G}). loadPrevious
-- returns package.loaded[<class>]; the idiom is `local _M = loadPrevious(...)`,
-- so _M is a local and needs no declaration. Bare assignments are sandboxed,
-- as with hooks -- the original's `aiStop`, `skoobot_act` and friends never
-- leaked for exactly this reason, and never became visible either.
files["src/superload/**/*.lua"] = { read_globals = { "loadPrevious" } }
files["tools/**/superload/**/*.lua"] = { read_globals = { "loadPrevious" } }

-- overload/data/keybinds/*.lua. Mounted at /data/keybinds/<name>.lua through
-- the overload mount (engine/Module.lua:519-523) and executed only by
-- KeyBind:load("<name>") (engine/KeyBind.lua:46-60), with
-- setmetatable({defineAction = ...}, {__index = _G}) at :52-54. Key symbols
-- such as _F3 appear only inside the binding strings and are engine.Key
-- class fields, not globals.
files["src/overload/data/keybinds/*.lua"] = { read_globals = { "defineAction" } }

-- overload/mod/**: ordinary class files. The overload mount puts them on the
-- module's own paths (engine/Module.lua:519-523) and they run as plain
-- require()d chunks. Each calls module(..., package.seeall,
-- class.inherit(...)), and Lua 5.1 module() -- kept by the wrapper at
-- engine/class.lua:27-50 -- defines _M, _NAME and _PACKAGE in the chunk's
-- environment; `function _M:init()` is the idiom, hence _M writable. Only
-- here: superload files make _M a local, so a global _M would hide real nils
-- everywhere else.
files["src/overload/mod/**/*.lua"] = {
    globals = { "_M" },
    read_globals = { "_NAME", "_PACKAGE" },
}

-- src/data/*.lua needs nothing extra: these files are loaded with dofile
-- (settings.lua from hooks/load.lua, power.lua from the Player superload),
-- which runs the chunk in plain _G -- the same mechanism that makes
-- engine/utils.lua's definitions global -- so a bare assignment there IS a
-- real global and W111 must stay on. If talent, effect or entity files are
-- ever added under data/, give them their own block built from the loader
-- environments listed at the top of this file.

-- Unit tests run under busted (.busted pins the interpreter to luajit).
-- spec/support/manifest.lua uses os.getenv and io.popen, which exist there.
files["spec/**/*.lua"] = { std = "luajit+busted" }
