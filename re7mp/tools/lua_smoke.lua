-- Smoke test for lua/re7mp.lua: runs the script against a FAKE REFramework (no game needed) and checks the
-- parts that do not depend on the real game's classes: syntax, start-up, the enemy snapshot format, the ghost
-- drawing, the item give/drop message flow, the panel and the settings file.
--
--   luarun tools/lua_smoke.lua lua/re7mp.lua        (luarun: see tools/luarun.c; any Lua 5.4 works)
--
-- It cannot tell whether the REAL game accepts the calls (names, argument types); it only proves the script
-- does what it says given a game that behaves the way the traces say it does.

local SCRIPT = arg[1] or "lua/re7mp.lua"
local failed, passed = 0, 0
local function check(cond, what)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. what)
    end
end

local function deep(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deep(v) end
    return o
end

-- ---------------------------------------------------------------------------------------------
-- A tiny object model: Obj has methods (name -> function(self, ...)), fields, and a type name.
-- ---------------------------------------------------------------------------------------------
local TYPES = {} -- type name -> { methods = { name = {params = {...}, ret = "..."} }, fields = { {name, type} } }
local Obj = {}
Obj.__index = Obj
function Obj.new(typename, methods, fields)
    return setmetatable({ _type = typename, m = methods or {}, f = fields or {} }, Obj)
end
function Obj:call(name, ...)
    local fn = self.m[name]
    if fn == nil then error("fake: " .. self._type .. " has no method " .. tostring(name)) end
    return fn(self, ...)
end
function Obj:get_field(name)
    local v = self.f[name]
    if v == nil then error("fake: no field " .. tostring(name)) end
    return v
end
function Obj:set_field(name, v)
    if self.f[name] == nil then error("fake: no field " .. tostring(name)) end
    self.f[name] = v
end
function Obj:get_address()
    if self.addr == nil then error("fake: no address") end
    return self.addr
end
function Obj:get_type_definition()
    return TYPES[self._type] or { get_full_name = function() return self._type end, get_fields = function() return {} end,
        get_parent_type = function() return nil end }
end

local function make_td(name, def)
    def = def or {}
    local td = { _name = name, _def = def }
    function td.get_full_name() return name end
    function td.get_parent_type() return nil end
    function td.get_fields()
        local out = {}
        for _, fd in ipairs(def.fields or {}) do
            out[#out + 1] = {
                get_name = function() return fd[1] end,
                is_static = function() return fd.static == true end,
                get_data = function() return fd.value end,
                get_type = function()
                    return { get_full_name = function() return fd[2] end,
                        is_value_type = function() return (fd[2]:find("^System%.") ~= nil and fd[2] ~= "System.String") or fd[2]:find("Enum$") ~= nil end }
                end,
            }
        end
        return out
    end
    local function method_obj(mname, md)
        local mo = { _key = name .. "." .. mname }
        function mo.get_name() return mname end
        function mo.get_param_types()
            local out = {}
            for i, p in ipairs(md.params or {}) do
                out[i] = { get_full_name = function() return p end, is_value_type = function() return p:find("^System%.[IBS]") ~= nil and p ~= "System.String" end }
            end
            return out
        end
        function mo.get_return_type() return { get_full_name = function() return md.ret or "System.Void" end } end
        function mo.is_static() return false end
        return mo
    end
    function td.get_method(_, mname)
        local md = (def.methods or {})[mname]
        return md and method_obj(mname, md) or nil
    end
    function td.get_methods()
        local out = {}
        for mname, md in pairs(def.methods or {}) do out[#out + 1] = method_obj(mname, md) end
        return out
    end
    TYPES[name] = td
    return td
end

-- ---------------------------------------------------------------------------------------------
-- Scenes: a list of root GameObjects with transforms
-- ---------------------------------------------------------------------------------------------
local calls -- a log of what the script did to the fake game: { "Inventory.reduceItem Herb 1 true", ... }

local function vec(x, y, z) return { x = x, y = y, z = z } end

local next_addr = 0x10000
local weapons_by_type = {} -- 9.10: type name -> list of components, returned by scene:findComponents
local function make_go(name, pos, comps, rot0)
    local go, xf
    local rot = rot0 or { x = 0, y = 0, z = 0, w = 1 }
    xf = Obj.new("via.Transform", {
        get_GameObject = function() return go end,
        get_Position = function() return pos end,
        set_Position = function(_, v)
            pos = vec(v.x, v.y, v.z)
            calls[#calls + 1] = string.format("%s.set_Position %.2f %.2f %.2f", name, v.x, v.y, v.z)
        end,
        get_Rotation = function() return rot end,
        set_EulerAngle = function(_, v) calls[#calls + 1] = string.format("%s.set_EulerAngle %.2f", name, v.y) end,
        get_Child = function() return nil end,
        get_Parent = function() return nil end,
        get_Next = function(self) return self._next end,
    })
    go = Obj.new("via.GameObject", {
        get_Name = function() return name end,
        get_Transform = function() return xf end,
        get_Components = function()
            return { get_elements = function() return comps or {} end }
        end,
        getComponent = nil,
        ["getComponent(System.Type)"] = function(_, t)
            for _, c in ipairs(comps or {}) do
                if c._type == t then return c end
            end
            return nil
        end,
        clone = function() return go end,
        destroy = function() end,
    })
    go.xf = xf
    next_addr = next_addr + 0x100
    go.addr = next_addr
    go.set_rot = function(q) rot = q end
    return go
end

local function make_scene(gos)
    for i, go in ipairs(gos) do go.xf._next = gos[i + 1] and gos[i + 1].xf or nil end
    return Obj.new("via.Scene", {
        get_FirstTransform = function() return gos[1] and gos[1].xf or nil end,
        ["findComponents(System.Type)"] = function(_, t)
            if weapons_by_type[t] == nil then error("fake: findComponents is only faked for the weapon types") end
            return { get_elements = function() return weapons_by_type[t] end }
        end,
    })
end

-- ---------------------------------------------------------------------------------------------
-- The fake REFramework environment
-- ---------------------------------------------------------------------------------------------
local function new_environment()
    local env = {
        files = {}, log = {}, hooks = {}, posthooks = {}, frame_cbs = {}, ui_cbs = {}, reset_cbs = {},
        texts = {}, lines = 0, quads = 0, ui_texts = {}, ui_press = {}, combo_override = {}, check_override = {}, slider_override = {}, keys = {},
        clock = 100.0, singletons = {}, scene = nil, camera_pos = vec(0, 1.6, 0), phase_cbs = {},
        -- 9.9: the fake physics. A ray hits the floor (the plane y = 0) on the layers in floor_layers, and a wall (the plane
        -- x = wall_x, if set) on the layers in wall_layers. physics_broken makes every cast fail.
        floor_layers = { [3] = true, [5] = true }, wall_x = nil, wall_layers = { [3] = true }, physics_broken = false, casts = 0,
    }
    calls = {}
    TYPES = {}
    for k in pairs(weapons_by_type) do weapons_by_type[k] = nil end

    -- game classes (only what the traces say exists)
    make_td("via.SceneManager")
    make_td("app.Item", { methods = {
        isCanDiscard = { params = {}, ret = "System.Boolean" }, reduceNum = { params = { "System.Int32", "via.GameObject" } },
        getItemDataId = {}, getTotalStackNum = {}, disableFromScene = {}, setStackNum = { params = { "System.Int32" } }, destroyItem = {},
    } })
    make_td("app.ItemManager", { methods = {
        createItemInstance = { params = { "via.GameObject", "System.String" } },
        createDropItemInstance = { params = { "via.GameObject", "System.String", "System.Int32" } },
        findCombineDataByResultItem = { params = { "System.String" } },
    } })
    make_td("app.Inventory", { methods = {
        addItem = { params = { "app.Item", "via.GameObject", "System.Boolean", "System.Collections.Generic.List`1<via.GameObject>" } },
        getExtendLevelState = { params = { "System.Int32" } }, reduceItem = { params = { "System.String", "System.Int32", "System.Boolean" } }, isAddItem = {},
    } })
    -- the real Status components have NO health field (2026-11 dump); health is in the DamageController's HealthInfo
    make_td("app.Em2000Status", { fields = { { "<isStarted>k__BackingField", "System.Boolean" }, { "_AngerRate", "System.Single" } },
        methods = { get_IsDead = { ret = "System.Boolean" } } })
    make_td("app.Em3000Status", { fields = { { "<isStarted>k__BackingField", "System.Boolean" } } })
    make_td("app.Em3100Status", { fields = { { "<isStarted>k__BackingField", "System.Boolean" }, { "_Hp", "System.Single" } } })
    make_td("app.Em6100Status", { fields = { { "<isStarted>k__BackingField", "System.Boolean" } } })
    make_td("app.HealthInfo", { fields = { { "_CurrentHealth", "System.Single" }, { "_MaxHealth", "System.Single" } },
        methods = { set_health = { params = { "System.Single" } } } })
    -- the player: a DamageController holding a HealthInfo (the enemies use the same class), plus a few more components
    make_td("app.PlayerDamageController", { fields = { { "HealthInfo", "app.HealthInfo" } },
        methods = { doDamage = { params = { "app.DamageController.DamageRecord" } }, doDie = {}, setPosition = {}, get_Foo = {} } })
    make_td("app.PlayerStatus", { fields = { { "_Guard", "System.Boolean" } }, methods = { startGuard = {}, endGuard = {} } })
    make_td("app.GameEventManager", { methods = { startEvent = { params = { "System.Int32" } }, unrelatedThing = {} } })
    make_td("app.GameEventSetting", { fields = { { "_EventId", "System.Int32" }, { "_Name", "System.String" } },
        methods = { doStart = {}, set_timelineKickers = { params = { "System.Object" } } } })  -- the setter ran 13066 times a second in the 9.5 door trace
    -- what a debug file showed the real classes have (names only): the player's doors, the story-flag setters, the save/load calls
    -- (9.6: the method names are the ones the door trace saw fire, plus the hot / teardown ones it must never hook)
    make_td("app.DoorPush", { methods = { openDoor = {}, closeDoor = { params = { "System.Boolean" } }, doUpdate = {}, get_IsOpen = { ret = "System.Boolean" },
        setInteract = { params = { "via.GameObject", "System.Boolean", "System.Boolean" } }, playAutoOpen = { params = { "app.DoorPush.OpenSide" } },
        playAutoClose = { params = { "System.Single", "System.Int32", "System.Boolean" } }, playClosed = {}, closeDoorCore = {}, lockDoor = {}, lockDoorCore = {},
        callSE = { params = { "System.Int32" } }, passed = { params = { "System.Int32" } }, setActiveInteract = { params = { "System.Boolean" } },
        doOnDestroy = {}, releaseComponents = {}, gatherComponents = {}, getDoorPushSaveData = {}, setDoorPushSaveData = { params = { "System.Object" } },
        isMotionJack = {}, existNear = { params = { "System.Int32" } }, notifyInKnockArea = { params = { "System.Int32" } } } })
    make_td("app.InteractObjectBase", { methods = { successInteract = {}, waitFsmExecuteCheck = {}, getInteractSaveData = {}, FsmExecute = {} } })
    make_td("app.GameManager", { methods = { setFsmGlobalBoolValue = { params = { "System.String", "System.Boolean" } },
        setFsmGlobalIntValue = { params = { "System.String", "System.Int32" } },
        addFsmGlobalIntValue = { params = { "System.String", "System.Int32" } }, getFsmGlobalBoolValue = { params = { "System.String" }, ret = "System.Boolean" },
        chapterJumpRequest = { params = { "System.String", "System.Boolean", "System.String" } }, isPause = {}, getGameRank = {} } })
    make_td("app.SaveDataManager", { methods = { saveFileGameSaveData = { params = { "System.Object", "System.Int32", "System.Object" } },
        loadFileAutoRequest = { params = { "System.Int32", "System.Boolean" } }, isExistData = { params = { "System.Int32" } },
        saveFileSomethingElse = { params = { "System.Int32" } }, loadFileOther = {} } })
    make_td("app.InventoryMenu", { methods = { refreshList = {}, somethingElse = {}, discardItem = { params = { "app.Item" }, ret = "System.Boolean" } } })
    make_td("app.Em2000.Em2000DamageController", { fields = { { "<defaultMaxHealth>k__BackingField", "System.Single" },
        { "HealthInfo", "app.HealthInfo" } },
        methods = { doDamage = { params = { "app.DamageController.DamageRecord" } }, doDie = { params = { "app.DamageController.DamageRecord" } } } })
    make_td("app.DamageController.DamageRecord", { fields = { { "Damage", "System.Single" }, { "WeaponID", "System.Int32" } } })
    make_td("app.DamageController", { methods = { addDamage = { params = { "app.DamageController.DamageRecord" } } } })
    make_td("app.Inventory.ItemInfo", { fields = { { "Item", "app.Item" }, { "Slot", "System.Int32" } } })
    make_td("app.Em2000Think", { fields = { { "_Mode", "System.Int32" } } })
    make_td("app.EnemySave", { fields = { { "_Alive", "System.Boolean" } } })
    make_td("via.motion.Motion")
    make_td("via.physics.System", { methods = { ["castRay"] = {}, ["castSphere"] = {} } })
    make_td("via.physics.CastRayQuery", { methods = { setRay = {}, clearOptions = {}, get_FilterInfo = {}, set_FilterInfo = {} } })
    make_td("via.physics.CastRayResult", { methods = { get_NumContactPoints = {}, get_Finished = {} } })

    -- globals the script expects
    env.G = {
        print = function(...) end,
        pairs = pairs, ipairs = ipairs, next = next, type = type, tostring = tostring, tonumber = tonumber, select = select,
        pcall = pcall, error = error, assert = assert, setmetatable = setmetatable, getmetatable = getmetatable,
        rawget = rawget, rawset = rawset, unpack = table.unpack,
        string = string, table = table, math = math, utf8 = utf8,
        os = { clock = function() return env.clock end, time = function() return 1700000000 end, date = os.date },
    }
    local G = env.G
    G._G = G

    G.log = { info = function(s) env.log[#env.log + 1] = s end }
    G.json = {
        load_file = function(name)
            local v = env.files[name]
            if v == nil then return nil end
            return deep(v)
        end,
        dump_file = function(name, t)
            env.files[name] = deep(t)
            if name == "re7mp_lastcall.json" then -- (every crumb in order, so a test can see the one that was not the last)
                env.crumb_log = env.crumb_log or {}
                env.crumb_log[#env.crumb_log + 1] = tostring(t.stage) .. ": " .. tostring(t.call)
            end
            return true
        end,
    }
    G.Vector3f = { new = function(x, y, z) return vec(x, y, z) end }
    G.Quaternion = { new = function(w, x, y, z) return { w = w, x = x, y = y, z = z } end }
    G.reframework = { is_key_down = function(_, k) return env.keys[k] == true end }

    G.draw = {
        world_to_screen = function(v) return { x = 960 + v.x * 20, y = 540 - v.y * 20 } end,
        text = function(s) env.texts[#env.texts + 1] = tostring(s) end,
        line = function(x1, y1, x2, y2)
            env.lines = env.lines + 1
            if env.line_pts then env.line_pts[#env.line_pts + 1] = { x1, y1 } env.line_pts[#env.line_pts + 1] = { x2, y2 } end
        end,
        filled_quad = function() env.quads = env.quads + 1 end,
    }
    G.imgui = {
        tree_node = function() return true end, tree_pop = function() end,
        text = function(s) env.ui_texts[#env.ui_texts + 1] = tostring(s) end,
        button = function(label)
            if env.ui_press[label] then
                env.ui_press[label] = nil
                return true
            end
            return false
        end,
        checkbox = function(label, v)
            local o = env.check_override[label]
            if o ~= nil then
                env.check_override[label] = nil
                return true, o
            end
            return false, v
        end,
        same_line = function() end,
        slider_float = function(label, v)
            local o = env.slider_override[label]
            if o then
                env.slider_override[label] = nil
                return true, o
            end
            return false, v
        end,
        combo = function(label, idx)
            local o = env.combo_override[label]
            if o then
                env.combo_override[label] = nil
                return true, o
            end
            return false, idx
        end,
        input_text = function(_, v) return false, v end,
    }
    G.re = {
        on_frame = function(cb) env.frame_cbs[#env.frame_cbs + 1] = cb end,
        on_draw_ui = function(cb) env.ui_cbs[#env.ui_cbs + 1] = cb end,
        on_script_reset = function(cb) env.reset_cbs[#env.reset_cbs + 1] = cb end,
        -- 9.9: the game's update phases; env.phase_cbs["pre:UpdateBehavior"]() runs what the script registered there
        on_pre_application_entry = function(name, cb) env.phase_cbs["pre:" .. name] = cb end,
        on_application_entry = function(name, cb) env.phase_cbs["post:" .. name] = cb end,
    }
    G.sdk = {
        PreHookResult = { CALL_ORIGINAL = 0, SKIP_ORIGINAL = 1 },
        find_type_definition = function(name) return TYPES[name] end,
        hook = function(m, pre, post)
            -- like REFramework, every hook on a method runs (several can be installed on one method)
            local key = m._key
            env._pre = env._pre or {}
            env._post = env._post or {}
            env._pre[key] = env._pre[key] or {}
            env._post[key] = env._post[key] or {}
            table.insert(env._pre[key], pre)
            if post then table.insert(env._post[key], post) end
            env.hooks[key] = function(args)
                local r
                for i, f in ipairs(env._pre[key]) do
                    local v = f(args)
                    if i == 1 then r = v end
                end
                return r
            end
            env.posthooks[key] = function(retval)
                for _, f in ipairs(env._post[key]) do
                    local v = f(retval)
                    if v ~= nil then retval = v end
                end
                return retval
            end
        end,
        to_ptr = function(v) return { ptr = v } end, -- a return value a post-hook hands back
        to_managed_object = function(x) if type(x) == "table" then return x end return nil end,
        to_int64 = function(x) if type(x) == "table" and x.addr then return x.addr end return x end,
        to_float = function(x) return x end,
        typeof = function(name) return name end,
        create_managed_string = function(s) return s end,
        create_instance = function(name)
            if name == "via.physics.CastRayQuery" then
                local q
                local filter = Obj.new("via.physics.FilterInfo", {}, {})
                filter.m.set_Group = function() end
                filter.m.set_MaskBits = function() end
                filter.m.set_Layer = function(_, l) filter.layer = l end
                q = Obj.new(name, {
                    ["setRay(via.vec3, via.vec3)"] = function(self, a, b) self.a, self.b, self.cleared_now, self.front_now = a, b, false, false end,
                    enableFrontFacingTriangleHits = function(self) self.front_now = true end,
                    enableBackFacingTriangleHits = function() end,
                    enableInsideHits = function() end,
                    clearOptions = function(self) self.cleared_now = true end,
                    enableAllHits = function() end,
                    enableNearSort = function() end,
                    get_FilterInfo = function() return filter end,
                    set_FilterInfo = function(self, f)
                        if env.filter_broken then error("set_FilterInfo failed") end
                        self.layer = f.layer
                    end,
                })
                q.add_ref = function(self) return self end
                return q
            elseif name == "via.physics.CastRayResult" then
                local r = Obj.new(name, { get_NumContactPoints = function(self) return self.n or 0 end,
                    getContactCollidable = function(self, i)
                        local nm = (self.names or {})[i + 1]
                        local go = Obj.new("via.GameObject", { get_Name = function() return nm end })
                        return Obj.new("via.physics.Collidable", { get_GameObject = function() return go end })
                    end })
                r.add_ref = function(self) return self end
                return r
            end
            return {}
        end,
        get_managed_singleton = function(name)
            local s = env.singletons[name]
            if s == nil then error("no singleton " .. name) end
            return s
        end,
        get_native_singleton = function(name)
            if name == "via.physics.System" then
                if env.no_physics_singleton then return nil end
                return "physics"
            end
            return "scene manager"
        end,
        call_native_func = function(_, _, sig, q, r)
            if type(sig) == "string" and sig:find("^castRay") then
                env.casts = env.casts + 1
                if env.physics_broken then error("castRay failed") end
                local a, b = q.a, q.b
                local n, names = 0, {}
                -- (9.11) env.reject_clear: a query whose options were cleared for this cast sees nothing (so only the way
                -- "leave the options alone" works); env.filter_broken: set_FilterInfo fails, every layer is then "nil" and
                -- the only way that works is the one that leaves the filter alone.
                local blind = (env.reject_clear and q.cleared_now) or (env.need_front and not q.front_now)
                local lay = q.layer
                if env.filter_broken then lay = "any" end
                if not blind then
                    if (a.y > 0) ~= (b.y > 0) and (env.floor_layers[lay] or (lay == "any" and next(env.floor_layers))) then
                        n = n + 1 names[#names + 1] = "Floor"
                    end
                    if env.wall_x and (a.x < env.wall_x) ~= (b.x < env.wall_x) and (env.wall_layers[lay] or (lay == "any" and next(env.wall_layers))) then
                        n = n + 1 names[#names + 1] = "Wall"
                    end
                    -- a ray that starts inside your own body (env.body_layers) hits "Pl0000" first
                    if env.body_layers and env.body_layers[lay] then n = n + 1 table.insert(names, 1, "Pl0000") end
                    -- a solid thing right at the camera (the near-clip collider): a ray that starts there is blocked
                    if env.camera_collider and (lay == 3 or lay == "any") then
                        local c = env.camera_pos
                        if (a.x - c.x) ^ 2 + (a.y - c.y) ^ 2 + (a.z - c.z) ^ 2 < 0.04 then n = n + 1 names[#names + 1] = "CameraBlocker" end
                    end
                end
                r.n, r.names = n, names
                return nil
            end
            return env.scene
        end,
        get_primary_camera = function()
            local cam_go = make_go("Camera", env.camera_pos, nil, env.camera_rot)
            return Obj.new("via.Camera", { get_GameObject = function() return cam_go end })
        end,
    }
    return env
end

local function load_script(env)
    local f, err = loadfile(SCRIPT, "t", env.G)
    if not f then error("syntax: " .. tostring(err)) end
    f()
end

local function run_frames(env, seconds, step)
    step = step or 0.05
    local t_end = env.clock + seconds
    while env.clock < t_end do
        env.clock = env.clock + step
        for _, cb in ipairs(env.frame_cbs) do
            local ok, err = pcall(cb)
            if not ok then
                failed = failed + 1
                print("FAIL: frame callback error: " .. tostring(err))
                return
            end
        end
    end
end

local function run_ui(env)
    env.ui_texts = {}
    for _, cb in ipairs(env.ui_cbs) do
        local ok, err = pcall(cb)
        if not ok then
            failed = failed + 1
            print("FAIL: UI callback error: " .. tostring(err))
        end
    end
end

local function ui_has(env, needle)
    for _, t in ipairs(env.ui_texts) do
        if t:find(needle, 1, true) then return true end
    end
    return false
end
local function texts_have(env, needle)
    for _, t in ipairs(env.texts) do
        if t:find(needle, 1, true) then return true end
    end
    return false
end
local function calls_have(needle)
    for _, c in ipairs(calls) do
        if c:find(needle, 1, true) then return true end
    end
    return false
end
local function log_has(env, needle)
    for _, l in ipairs(env.log) do
        if l:find(needle, 1, true) then return true end
    end
    return false
end
local function messages_of_kind(env, kind)
    local out = {}
    local d = env.files["re7mp_msg_out.json"]
    for _, m in ipairs(d and d.msgs or {}) do
        if m.k == kind then out[#out + 1] = m.p end
    end
    return out
end

-- Game objects shared by the scenarios. The enemies copy what the 2026-11 dump showed:
--   Em2000  a live enemy (Status + DamageController with HealthInfo)         -> sent as live
--   Em3100  a live enemy whose Status has a plain _Hp field                  -> sent as live
--   Em6100  a live enemy with no health field at all                         -> sent as live, hp -1
--   Em8000  Status.isStarted = false, no animation, y = -7.8 (parked boss)   -> flagged parked
--   Em6190  no components, at the origin                                     -> flagged
--   Em3300  animated but no Status                                           -> flagged
local function build_world(env)
    local function layer_of(bank, motion, frame)
        return Obj.new("via.motion.TreeLayer", {
            get_MotionBankID = function() return bank end, get_MotionID = function() return motion end, get_Frame = function() return frame end,
        })
    end
    local function motion_of(bank, motion, frame)
        local l = layer_of(bank, motion, frame)
        return Obj.new("via.motion.Motion", { getLayer = function() return l end })
    end
    local function status(typename, fields)
        return Obj.new(typename, { get_IsDead = function() return false end }, fields)
    end

    local health_info = Obj.new("app.HealthInfo", {}, { _CurrentHealth = 820, _MaxHealth = 1000 })
    local dc = Obj.new("app.Em2000.Em2000DamageController", {}, { ["<defaultMaxHealth>k__BackingField"] = 1000, HealthInfo = health_info })
    local think = Obj.new("app.Em2000Think", { set_Enabled = function(_, on) calls[#calls + 1] = "Em2000Think.set_Enabled " .. tostring(on) end }, { _Mode = 1 })
    local save = Obj.new("app.EnemySave", {}, { _Alive = true })
    local jack = make_go("Em2000", vec(-1.8, 0, 1.8), {
        status("app.Em2000Status", { ["<isStarted>k__BackingField"] = true, _AngerRate = 180 }), dc, think, save, motion_of(7, 123, 12.5) })
    jack.set_rot({ x = 0, y = 0.7071, z = 0, w = 0.7071 })
    local marg = make_go("Em3100", vec(-2.61, 0.28, 35.8), {
        status("app.Em3100Status", { ["<isStarted>k__BackingField"] = true, _Hp = 500 }), motion_of(20, 1200, 0.9) })
    local mia = make_go("Em6100", vec(33, -1.9, -4.3), {
        status("app.Em6100Status", { ["<isStarted>k__BackingField"] = true }), motion_of(1, 1, 1) })
    local parked = make_go("Em8000", vec(-5.79, -7.77, 13.25), {
        status("app.Em3000Status", { ["<isStarted>k__BackingField"] = false }), motion_of(0, 4294967295, 0) })
    local placeholder = make_go("Em6190", vec(0, 0, 0), { motion_of(0, 4294967295, 0) })
    local prop = make_go("Em3300", vec(11.4, 4.03, 11.16), { motion_of(10, 0, 198.5) })
    local not_enemy = {
        make_go("Em2000WallBreakMansionAIZone", vec(0, 0, 0)), make_go("em5600_B1Ladder_Set_01", vec(16, 0, 11)),
        make_go("EnemySceneSurveillance", vec(0, 0, 0)), make_go("em6200_Blood_01", vec(17, -7, 16)),
        make_go("c01_Living01_dynamic", vec(0, 0, 0)),
    }

    -- the player, with an inventory whose _ItemList holds app.Inventory.ItemInfo entries (as in the dump)
    local inventory
    local added = {}
    inventory = Obj.new("app.Inventory", {
        reduceItem = function(_, id, n, flag)
            calls[#calls + 1] = string.format("Inventory.reduceItem %s %d %s", tostring(id), n, tostring(flag))
            if env.reduce_fails then return false end
            local h = env.reduce_fires_hook and env.hooks["app.Inventory.reduceItem"]
            if h then h({ 0, env.inventory, Obj.new("System.String", { ["ToString()"] = function() return tostring(id) end }), n, flag }) end
            return true
        end,
        isAddItem = function(_, item)
            if env.is_add_result ~= nil then return env.is_add_result end
            return not env.inventory_full
        end,
    }, {})
    local player_hi = Obj.new("app.HealthInfo", {}, { _CurrentHealth = 600, _MaxHealth = 1000 })
    player_hi.addr = 0x7001
    local player_dc = Obj.new("app.PlayerDamageController", {}, { HealthInfo = player_hi })
    local player_status = Obj.new("app.PlayerStatus", {}, { _Guard = false })
    local player = make_go("Pl0000", vec(0, 0, 0), { inventory, player_dc, player_status })
    env.player_hi = player_hi
    player.set_rot({ x = 0, y = 0, z = 0, w = 1 })

    local function make_item(id, count, managed_id)
        local item
        item = Obj.new("app.Item", {
            -- some items answer with a managed System.String object instead of a Lua string
            getItemDataId = function()
                if managed_id then return Obj.new("System.String", { ["ToString()"] = function() return id end }) end
                return id
            end,
            getTotalStackNum = function() return item.stack or count end,
            getStackNum = function() return item.stack or count end,
            getMaxStackNum = function() return env.max_stack or 99 end,
            setStackNum = function(_, n) if not env.stack_ignore then item.stack = n end end,
            destroyItem = function() calls[#calls + 1] = "Item.destroyItem " .. id end,
        })
        item.id = id
        return item
    end

    local entries = {}
    local inv_owner = make_go("InventoryOwner", vec(0, 0, 0)) -- (the real entries carry an Owner GameObject)
    env.inv_owner = inv_owner
    for i, it in ipairs({ { "Herb", 3 }, { "Gunpowder", 2, true }, { "HandgunBullet", 15 } }) do
        entries[i] = Obj.new("app.Inventory.ItemInfo", {}, { Item = make_item(it[1], it[2], it[3]), Slot = i, Owner = inv_owner })
    end
    env.entries = entries
    -- (9.14) addItem really adds (a new entry, or onto an existing stack) unless the inventory is full / the test says it refuses,
    -- and it answers with an app.Inventory.AddItemResult-like number (0 = added). The 2-parameter form exists only if the test says so.
    local function mock_add(_, item, who, flag, list)
        calls[#calls + 1] = "Inventory.addItem " .. tostring(item.id) .. " x" .. tostring(item.stack or 1)
        env.add_calls = (env.add_calls or 0) + 1
        env.add_owner = who
        added[#added + 1] = item
        if env.inventory_full or env.add_refuses then return 1 end
        for _, e in ipairs(entries) do
            local cur = e.f.Item
            if cur.id == item.id then
                cur.stack = cur:call("getStackNum") + (item.stack or 1)
                return 0
            end
        end
        entries[#entries + 1] = Obj.new("app.Inventory.ItemInfo", {}, { Item = item, Slot = #entries + 1, Owner = inv_owner })
        return 0
    end
    inventory.m.addItem = function(self, item, who, flag, list)
        if env.add_needs_list and list == nil then return 1 end -- (a game that refuses a nil list)
        return mock_add(self, item, who, flag, list)
    end
    inventory.m["addItem(app.Item, via.GameObject)"] = function(self, item, who)
        if not env.two_arg_add then error("fake: no such overload") end
        return mock_add(self, item, who)
    end
    local item_list = Obj.new("System.Collections.Generic.List`1<app.Inventory.ItemInfo>", {
        get_Count = function() return #entries end,
        get_Item = function(_, i) return entries[i + 1] end,
    })
    inventory.f._ItemList = item_list

    local im = Obj.new("app.ItemManager", {
        createItemInstance = function(_, who, id)
            calls[#calls + 1] = "ItemManager.createItemInstance " .. tostring(id)
            return make_item(id, 1)
        end,
        createDropItemInstance = function(_, who, id, n)
            calls[#calls + 1] = string.format("ItemManager.createDropItemInstance %s %d", tostring(id), n)
            local g = make_go("sm1800_" .. id .. "_Item", vec(0.4, 0, 0.5))
            return g
        end,
    })
    env.singletons["app.ItemManager"] = im
    env.make_item = make_item
    env.player = player
    env.inventory = inventory
    local event_obj = make_go("Ev_Dinner_Trigger", vec(5, 0, 5), { Obj.new("app.GameEventSetting", {}, { _EventId = 42, _Name = "DinnerStart" }) })
    env.scene_objects = { player, jack, marg, mia, parked, placeholder, prop, event_obj, table.unpack(not_enemy) }
    env.scene = make_scene(env.scene_objects)
    env.jack, env.mia = jack, mia
end

local function host_role_files(env, role, transport)
    env.files["re7mp_in.json"] = {
        seq = 1, x = 3, y = 1.6, z = 4, qx = 0, qy = 0, qz = 0, qw = 1, flags = 0, recv_count = 1,
        name = "Bob", transport = transport or "tcp", role = role, exe = "0.7", proto = 6,
    }
end

local function push_msgs(env, list)
    env.msg_n = env.msg_n or 0
    local msgs = {}
    for _, m in ipairs(list) do
        env.msg_n = env.msg_n + 1
        msgs[#msgs + 1] = { n = env.msg_n, id = env.msg_n, k = m[1], p = m[2] }
    end
    env.files["re7mp_msg_in.json"] = { epoch = 1, msgs = msgs }
end

local function bump_remote(env, n)
    local d = env.files["re7mp_in.json"]
    d.seq = d.seq + 1
    d.recv_count = d.recv_count + 1
end

-- =============================================================================================
-- Scenario 1: start-up
-- =============================================================================================
do
    local env = new_environment()
    build_world(env)
    local ok, err = pcall(load_script, env)
    check(ok, "script loads without error: " .. tostring(err))
    check(log_has(env, "script v9.15 loaded"), "script announces v9.15")
    check(env.hooks["app.Item.isCanDiscard"] and env.hooks["app.Item.reduceNum"], "item discard hooks installed")
    check(env.hooks["app.ItemManager.createItemInstance"] and env.hooks["app.Inventory.getExtendLevelState"], "manager hooks installed")
    check(#env.frame_cbs == 1 and #env.ui_cbs == 1, "one frame callback and one UI callback")
    run_frames(env, 1.0)
    run_ui(env)
    for _, t in ipairs(env.ui_texts) do
        check(not t:find("UI error", 1, true), "no UI error in the panel: " .. t)
    end
    check(ui_has(env, "Nothing given or dropped yet."), "Items panel is shown")
    check(ui_has(env, "Enemy sync needs TCP"), "Enemies panel explains TCP when there is no connection")
end

-- =============================================================================================
-- Scenario 2: the HOST sends its enemies
-- =============================================================================================
do
    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "host", "tcp")
    for i = 1, 30 do
        run_frames(env, 0.05)
        bump_remote(env) -- the other player keeps sending, so they count as present
    end
    local d = env.files["re7mp_state_out.json"]
    check(d ~= nil and type(d.p) == "string" and d.seq >= 1, "host wrote a snapshot")
    local by = {}
    if d then
        local entries = {}
        for e in d.p:gmatch("[^;]+") do entries[#entries + 1] = e end
        check(#entries == 6, "all six Em#### objects are in the snapshot, the AI zones and props named like enemies are not (got " .. #entries .. "): " .. d.p)
        for _, e in ipairs(entries) do
            local f = {}
            for x in e:gmatch("[^,]+") do f[#f + 1] = x end
            check(#f == 13, "entry has 13 fields: " .. e)
            by[f[1]] = f
        end
        local jack, marg, mia = by.Em2000, by.Em3100, by.Em6100
        check(jack and marg and mia and by.Em8000 and by.Em6190 and by.Em3300, "all six names present")
        if jack and marg and mia then
            check(tonumber(jack[2]) == -1.8 and tonumber(jack[4]) == 1.8, "Jack position")
            check(math.abs(tonumber(jack[6]) - 0.707) < 0.01 and math.abs(tonumber(jack[8]) - 0.707) < 0.01, "Jack rotation")
            check(tonumber(jack[9]) == 820, "Jack health read from HealthInfo._CurrentHealth: " .. tostring(jack[9]))
            check(tonumber(marg[9]) == 500, "Em3100 health read from a plain _Hp field: " .. tostring(marg[9]))
            check(tonumber(mia[9]) == -1, "Mia has no health field: -1")
            check(tonumber(jack[11]) == 7 and tonumber(jack[12]) == 123 and tonumber(jack[13]) == 12.5, "animation ids sent")
            check(tonumber(jack[10]) == 1 and tonumber(marg[10]) == 1 and tonumber(mia[10]) == 1, "live enemies have flags 1")
        end
        -- the stray red box: parked and placeholder objects are flagged so the joiner does not draw them
        check(by.Em8000 and tonumber(by.Em8000[10]) == 3, "parked Em8000 (isStarted=false, no animation) is flagged 3: " .. tostring(by.Em8000 and by.Em8000[10]))
        check(by.Em6190 and tonumber(by.Em6190[10]) == 15, "Em6190 (no Status, parked, origin) is flagged 15: " .. tostring(by.Em6190 and by.Em6190[10]))
        check(by.Em3300 and tonumber(by.Em3300[10]) == 5, "Em3300 (animated, no Status) is flagged 5: " .. tostring(by.Em3300 and by.Em3300[10]))
        check(#d.p < 3000, "snapshot is small")
    end
    check(log_has(env, "health of Em2000 is read from app.Em2000.Em2000DamageController.HealthInfo._CurrentHealth"), "health source was found and logged")
    check(log_has(env, "health of Em3100 is read from _Hp"), "plain _Hp source logged")
    check(log_has(env, "no health field found for Em6100"), "missing health field is logged for Mia")
    run_ui(env)
    check(ui_has(env, "You are the HOST"), "panel says host")
    check(ui_has(env, "Em#### objects in your scene: 6   (3 look like live enemies)"), "panel counts 6 objects, 3 live")
    check(ui_has(env, "   Em8000   not sent as live: parked"), "panel says why Em8000 is not live")
    check(ui_has(env, "   Em6190   not sent as live: parked, no Status component, at the origin"), "panel says why Em6190 is not live")

    -- no role (the exe has not said host or join): nothing is written
    local env2 = new_environment()
    build_world(env2)
    load_script(env2)
    host_role_files(env2, "none", "tcp")
    for i = 1, 20 do run_frames(env2, 0.05) bump_remote(env2) end
    check(env2.files["re7mp_state_out.json"] == nil, "no snapshot is written without a host / join role")
end

-- =============================================================================================
-- Scenario 2b (9.9): enemy health when the HealthInfo field is not found. Your enemy scan listed get_health() /
-- get_maxHealth() on app.DamageController; the script falls back to them, and looks again a few times for an enemy
-- that had no health object yet when it was first seen.
-- =============================================================================================
do
    local env = new_environment()
    build_world(env)
    make_td("app.Em4000.Em4000DamageController", { methods = { get_health = { ret = "System.Single" }, get_maxHealth = { ret = "System.Single" } } })
    make_td("app.Em4100.Em4100DamageController", { fields = { { "HealthInfo", "app.HealthInfo" } } })
    make_td("app.Em4200.Em4200DamageController", { methods = { get_health = { ret = "System.Single" } } })
    make_td("app.Em4000Status", { fields = { { "<isStarted>k__BackingField", "System.Boolean" } } })
    make_td("app.Em4100Status", { fields = { { "<isStarted>k__BackingField", "System.Boolean" } } })
    make_td("app.Em4200Status", { fields = { { "<isStarted>k__BackingField", "System.Boolean" } } })
    local function mk_status(tn) return Obj.new(tn, { get_IsDead = function() return false end }, { ["<isStarted>k__BackingField"] = true }) end
    local function motion3()
        local l = Obj.new("via.motion.TreeLayer", { get_MotionBankID = function() return 3 end, get_MotionID = function() return 30 end, get_Frame = function() return 1.5 end })
        return Obj.new("via.motion.Motion", { getLayer = function() return l end })
    end
    -- Em4000: no HealthInfo field at all, but get_health() answers
    local dc4000 = Obj.new("app.Em4000.Em4000DamageController", { get_health = function() return 275 end, get_maxHealth = function() return 400 end }, {})
    local comps4000 = { mk_status("app.Em4000Status"), dc4000, motion3() }
    local e4000 = make_go("Em4000", vec(4, 0, 4), comps4000)
    -- Em4100: the HealthInfo field is empty for the first seconds, then the game fills it
    local late_hi = Obj.new("app.HealthInfo", {}, { _CurrentHealth = 90, _MaxHealth = 100 })
    local dc4100 = Obj.new("app.Em4100.Em4100DamageController", {}, {})
    local e4100 = make_go("Em4100", vec(6, 0, 4), { mk_status("app.Em4100Status"), dc4100, motion3() })
    -- Em4200: get_health throws until the enemy has started, then answers
    local ready4200 = false
    local dc4200 = Obj.new("app.Em4200.Em4200DamageController", { get_health = function()
        if not ready4200 then error("not started") end
        return 33
    end }, {})
    local e4200 = make_go("Em4200", vec(8, 0, 4), { mk_status("app.Em4200Status"), dc4200, motion3() })
    make_td("app.Em4300.Em4300DamageController", { methods = { get_health = { ret = "System.Single" } } })
    make_td("app.Em4300Status", { fields = { { "<isStarted>k__BackingField", "System.Boolean" } } })
    env.dead_asks = 0
    local dc4300 = Obj.new("app.Em4300.Em4300DamageController", { get_health = function() env.dead_asks = env.dead_asks + 1 error("never") end }, {})
    local e4300 = make_go("Em4300", vec(10, 0, 4), { mk_status("app.Em4300Status"), dc4300, motion3() })
    for _, g in ipairs({ e4000, e4100, e4200, e4300 }) do env.scene_objects[#env.scene_objects + 1] = g end
    env.scene = make_scene(env.scene_objects)
    load_script(env)
    host_role_files(env, "host", "tcp")
    for i = 1, 20 do run_frames(env, 0.05) bump_remote(env) end
    local function snapshot_health()
        local out = {}
        local d = env.files["re7mp_state_out.json"]
        for e in ((d and d.p) or ""):gmatch("[^;]+") do
            local f = {}
            for x in e:gmatch("[^,]+") do f[#f + 1] = x end
            out[f[1]] = tonumber(f[9])
        end
        return out
    end
    local h = snapshot_health()
    check(h.Em2000 == 820, "the HealthInfo reader still works: " .. tostring(h.Em2000))
    check(h.Em4000 == 275, "no HealthInfo field: health comes from DamageController.get_health(): " .. tostring(h.Em4000))
    check(log_has(env, "health of Em4000 is read from app.Em4000.Em4000DamageController.get_health()"), "...and the source is logged")
    check(h.Em4100 == -1 and h.Em4200 == -1, "enemies without a health object yet report -1 at first")
    check(log_has(env, "no health field found for Em4100"), "...and say so")
    -- the game fills them in a moment later
    dc4100.f.HealthInfo = late_hi
    ready4200 = true
    for i = 1, 100 do run_frames(env, 0.05) bump_remote(env) end -- 5 s: more than one retry interval
    h = snapshot_health()
    check(h.Em4100 == 90, "a HealthInfo that appears later is found by the retry: " .. tostring(h.Em4100))
    check(h.Em4200 == 33, "a get_health() that starts answering later is found by the retry: " .. tostring(h.Em4200))
    check(log_has(env, "health of Em4100 is read from app.Em4100.Em4100DamageController.HealthInfo._CurrentHealth"), "...and the late success is logged")
    check(h.Em6100 == -1, "an enemy that has no health anywhere (Mia) stays -1")
    -- the retries are limited: an enemy with nothing to find does not make the script search forever
    check(env.dead_asks ~= nil and env.dead_asks >= 2, "the enemy whose get_health never answers was asked again (" .. tostring(env.dead_asks) .. " times)")
    for i = 1, 400 do run_frames(env, 0.05) bump_remote(env) end -- 20 s: every retry has happened by now
    local asked = env.dead_asks
    for i = 1, 200 do run_frames(env, 0.05) bump_remote(env) end -- 10 more seconds
    check(env.dead_asks == asked, "...but only a few times: after 6 looks it is left alone (" .. tostring(asked) .. " then " .. tostring(env.dead_asks) .. ")")
    check(env.dead_asks <= 6, "...at most 6 looks in all: " .. tostring(env.dead_asks))
    -- what was learned is kept from one scan to the next (the records are rebuilt every second)
    local asks_4000 = 0
    local good = dc4000.m.get_health
    dc4000.m.get_health = function() asks_4000 = asks_4000 + 1 return good() end
    for i = 1, 100 do run_frames(env, 0.05) bump_remote(env) end -- 5 s = 5 scans and 50 snapshots
    check(asks_4000 >= 40 and asks_4000 <= 60, "get_health() is read once per snapshot, and the search is not repeated at every scan (" .. asks_4000 .. " calls)")
    -- the object it was learned from goes away: after a few failed reads the enemy is looked at again
    dc4000.m.get_health = function() error("gone") end
    for i = 1, 20 do run_frames(env, 0.05) bump_remote(env) end
    check(snapshot_health().Em4000 == -1, "the dead source gives -1")
    -- the enemy comes back as a NEW component at the same address (a respawn): it has to be found again, not the old object
    local dc4000b = Obj.new("app.Em4000.Em4000DamageController", { get_health = function() return 111 end, get_maxHealth = function() return 400 end }, {})
    comps4000[2] = dc4000b
    for i = 1, 100 do run_frames(env, 0.05) bump_remote(env) end
    check(snapshot_health().Em4000 == 111, "...and the new object's health is found by looking again: " .. tostring(snapshot_health().Em4000))
end

-- =============================================================================================
-- Scenario 2c (9.10): damage dealt by the joiner. The joiner tests its shot against the red boxes and sends a hit; the host applies it
-- through the game's damage call (with fallbacks), answers, and the joiner's box shows the new health.
-- =============================================================================================
do
    local function hits_sent(env) return messages_of_kind(env, 9) end
    local function sent_x(env)
        local out = {}
        for _, p in ipairs(hits_sent(env)) do if p:sub(1, 2) == "x|" then out[#out + 1] = p end end
        return out
    end
    local function sent_a(env)
        local out = {}
        for _, p in ipairs(hits_sent(env)) do if p:sub(1, 2) == "a|" then out[#out + 1] = p end end
        return out
    end
    local function live(env, secs) for _ = 1, math.floor(secs / 0.05) do run_frames(env, 0.05) bump_remote(env) end end
    -- press the test button; the messages are written a moment later, on the next frames
    local function press(env)
        env.ui_press["Test: hit the red box I am aiming at"] = true
        run_ui(env)
        live(env, 0.15)
    end
    -- the camera at (0, 1.6, 0) looks down -z; yaw -90 degrees makes it look down +x
    local YAW_PX = { x = 0, y = -0.70711, z = 0, w = 0.70711 }

    -- ---------------- joiner: the line of fire ----------------
    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "join", "tcp")
    env.files["re7mp_state_in.json"] = { seq = 5, n = 1, p = "Em2000,0.00,0.00,-6.00,0,0,0,1,500,1,2,3,4.0" }
    live(env, 1)
    run_ui(env)
    check(ui_has(env, "Damage to the host's enemies (9.10):") and ui_has(env, "Shot detection: not learned yet"), "the panel has the damage section")
    press(env)
    local xs = sent_x(env)
    check(#xs == 1 and xs[1]:match("^x|Em2000|30|0%.00|0%.00|%-6%.00$"), "aiming at the box and pressing the test button sends a hit: " .. tostring(xs[1]))
    live(env, 0.3)
    check(texts_have(env, "-30"), "...and a damage number floats at the box")
    run_ui(env)
    check(ui_has(env, "hit Em2000 at ") and ui_has(env, "walls not checked"), "...the panel says what was hit, and that the walls were not checked yet")
    -- off the line of fire: a miss, nothing sent
    env.files["re7mp_state_in.json"] = { seq = 6, n = 2, p = "Em2000,3.00,0.00,-6.00,0,0,0,1,500,1,2,3,4.0" }
    live(env, 1)
    press(env)
    check(#sent_x(env) == 1, "a box off to the side is not hit")
    run_ui(env)
    check(ui_has(env, "no red box in the line of fire"), "...and the panel says so")
    -- behind the camera
    env.files["re7mp_state_in.json"] = { seq = 7, n = 3, p = "Em2000,0.00,0.00,6.00,0,0,0,1,500,1,2,3,4.0" }
    live(env, 1)
    press(env)
    check(#sent_x(env) == 1, "a box behind the camera is not hit")
    -- a dead or parked box cannot be hit
    env.files["re7mp_state_in.json"] = { seq = 8, n = 4, p = "Em2000,0.00,0.00,-6.00,0,0,0,1,0,0,2,3,4.0;Em8000,0.00,0.00,-3.00,0,0,0,1,-1,3,0,4294967295,0" }
    live(env, 1)
    press(env)
    check(#sent_x(env) == 1, "a dead enemy and a parked placeholder are not hit")
    -- two boxes in line: the nearer one
    env.files["re7mp_state_in.json"] = { seq = 9, n = 5, p = "Em2000,0.00,0.00,-9.00,0,0,0,1,500,1,2,3,4.0;Em3100,0.00,0.00,-4.00,0,0,0,1,300,1,2,3,4.0" }
    live(env, 1)
    press(env)
    xs = sent_x(env)
    check(#xs == 2 and xs[2]:match("^x|Em3100|"), "with two boxes in line the nearer one is hit: " .. tostring(xs[2]))
    -- damage setting
    env.slider_override["Damage per hit"] = 75
    run_ui(env)
    live(env, 0.3)
    press(env)
    xs = sent_x(env)
    check(xs[#xs]:match("^x|Em3100|75|"), "the damage per hit slider is used: " .. tostring(xs[#xs]))
    live(env, 1.5)
    check(env.files["re7mp_settings.json"].hit_damage == 75 and env.files["re7mp_settings.json"].hit_on == true, "the damage and the switch are remembered")
    -- switched off
    env.check_override["JOINER: my shots hurt the host's enemies (a shot that points at a red box)"] = false
    run_ui(env)
    local n0 = #sent_x(env)
    live(env, 0.3)
    press(env)
    check(#sent_x(env) == n0, "with the joiner switch off nothing is sent")
    env.check_override["JOINER: my shots hurt the host's enemies (a shot that points at a red box)"] = true
    run_ui(env)
    -- the host's answer updates the box at once
    -- (the boxes are only drawn while snapshots keep arriving, so send fresh ones)
    local function snapshot(seq, hp3100)
        env.files["re7mp_state_in.json"] = { seq = seq, n = seq, p = "Em2000,0.00,0.00,-9.00,0,0,0,1,500,1,2,3,4.0;Em3100,0.00,0.00,-4.00,0,0,0,1," .. hp3100 .. ",1,2,3,4.0" }
    end
    snapshot(10, 300)
    env.texts = {}
    live(env, 0.3)
    check(texts_have(env, "Em3100  HP 300"), "the red box shows the host's health")
    push_msgs(env, { { 9, "a|Em3100|addManualDamage|300|225" } })
    env.texts = {}
    live(env, 0.15)
    check(texts_have(env, "Em3100  HP 225"), "the host's answer puts the new health on the red box")
    snapshot(11, 300) -- a snapshot sent just before the hit landed still says 300
    env.texts = {}
    live(env, 0.15)
    check(texts_have(env, "Em3100  HP 225") and not texts_have(env, "Em3100  HP 300"), "...and an older snapshot does not flick it back")
    live(env, 0.8)
    snapshot(12, 260) -- later the host's own number is the truth again
    env.texts = {}
    live(env, 0.15)
    check(texts_have(env, "Em3100  HP 260"), "...but a moment later the host's own number wins")
    push_msgs(env, { { 9, "a|Em3100|addManualDamage|300|225" } })
    live(env, 0.15)
    run_ui(env)
    check(ui_has(env, "host: Em3100 addManualDamage (health 300 -> 225)"), "...and the panel shows the answer")
    push_msgs(env, { { 9, "a|Em3100|refused|-1|-1" } })
    live(env, 0.3)
    check(texts_have(env, "Em3100  HP 225") or texts_have(env, "Em3100  HP 300"), "a refusal does not set the health to -1")
    check(not texts_have(env, "Em3100  HP -1"), "...")

    -- ---------------- joiner: slack of the box, and no enemies at all ----------------
    local envm = new_environment()
    build_world(envm)
    envm.files["re7mp_settings.json"] = { enemy_mode = 1 } -- enemies off
    load_script(envm)
    host_role_files(envm, "join", "tcp")
    live(envm, 1)
    press(envm)
    run_ui(envm)
    check(#sent_x(envm) == 0 and ui_has(envm, "no enemies from the host to hit"), "with the enemy sync off the test button says there is nothing to hit")
    local envk = new_environment()
    build_world(envk)
    load_script(envk)
    host_role_files(envk, "join", "tcp")
    live(envk, 1)
    envk.files["re7mp_state_in.json"] = { seq = 5, n = 1, p = "Em2000,0.52,0.00,-6.00,0,0,0,1,500,1,2,3,4.0" }
    live(envk, 1)
    press(envk)
    check(#sent_x(envk) == 0, "a shot 0.52 m beside the middle of the box misses")
    envk.files["re7mp_state_in.json"] = { seq = 6, n = 2, p = "Em2000,0.40,0.00,-6.00,0,0,0,1,500,1,2,3,4.0" }
    live(envk, 1)
    press(envk)
    check(#sent_x(envk) == 1, "a shot 0.40 m beside the middle (just outside the drawn box) still hits: the box has a little slack")

    -- ---------------- joiner: a wall in the way ----------------
    local envw = new_environment()
    build_world(envw)
    envw.camera_rot = YAW_PX
    envw.wall_x = 4
    load_script(envw)
    host_role_files(envw, "join", "tcp")
    envw.files["re7mp_state_in.json"] = { seq = 5, n = 1, p = "Em2000,8.00,0.00,0.00,0,0,0,1,500,1,2,3,4.0" }
    live(envw, 4) -- the wall test finds its collision layers
    run_ui(envw)
    check(ui_has(envw, "walls: working"), "(the wall test is calibrated)")
    press(envw)
    check(#sent_x(envw) == 0, "a box behind a wall is not hit")
    run_ui(envw)
    check(ui_has(envw, "is behind a wall"), "...and the panel says so")
    envw.wall_x = nil
    live(envw, 0.3)
    press(envw)
    xs = sent_x(envw)
    check(#xs == 1 and xs[1]:match("^x|Em2000|30|8%.00|"), "with the wall gone the same shot hits (camera looking down +x): " .. tostring(xs[1]))
    check(not ui_has(envw, "walls not checked"), "...and this time the walls were checked")
    envw.wall_x = 0.4
    envw.files["re7mp_state_in.json"] = { seq = 6, n = 2, p = "Em2000,1.00,0.00,0.00,0,0,0,1,500,1,2,3,4.0" }
    live(envw, 1)
    press(envw)
    check(#sent_x(envw) == 2, "a box whose near face is closer than 0.8 m is never reported as behind a wall")
    envw.wall_x = nil

    -- ---------------- host: applying a hit ----------------
    local function hp_obj(h) return Obj.new("app.HealthInfo", {}, { _CurrentHealth = h, _MaxHealth = 1000 }) end
    local function info_of(dmg) return Obj.new("app.Collision.HitController.DamageInfo", {}, { dmg = dmg }) end
    local function mk_enemy(env_, name, x, mode)
        -- mode: "manual" (addManualDamage works), "hitdmg" (addManualDamage returns nothing, addHitDamage works),
        --       "direct" (newFakeDamageInfo throws; getHealthInfo().set_health works), "field" (no DamageController methods at all)
        local tn = "app." .. name .. "." .. name .. "DamageController"
        make_td(tn, { fields = { { "HealthInfo", "app.HealthInfo" } } })
        make_td("app." .. name .. "Status", { fields = { { "<isStarted>k__BackingField", "System.Boolean" } } })
        local hi = hp_obj(200)
        local m = {}
        m.getHealthInfo = function() return hi end
        if mode == "manual" or mode == "hitdmg" then
            m.newFakeDamageInfo = function(_, dmg, a, t) calls[#calls + 1] = string.format("%s.newFakeDamageInfo %.1f", name, dmg) return info_of(dmg) end
        elseif mode == "direct" then
            m.newFakeDamageInfo = function() error("no such thing") end
        end
        local function take(_, info)
            hi.f._CurrentHealth = hi.f._CurrentHealth - info.f.dmg
            return Obj.new("app.DamageController.DamageRecord", {}, {})
        end
        if mode == "manual" then
            m.addManualDamage = function(self, info) calls[#calls + 1] = name .. ".addManualDamage" return take(self, info) end
        elseif mode == "hitdmg" then
            m.addManualDamage = function() return nil end
            m.addHitDamage = function(self, info) calls[#calls + 1] = name .. ".addHitDamage" return take(self, info) end
        end
        hi.m.set_health = function(self, v) calls[#calls + 1] = name .. ".set_health " .. v hi.f._CurrentHealth = v end
        local dc = Obj.new(tn, m, { HealthInfo = hi })
        local st = Obj.new("app." .. name .. "Status", { get_IsDead = function() return hi.f._CurrentHealth <= 0 end }, { ["<isStarted>k__BackingField"] = true })
        local l = Obj.new("via.motion.TreeLayer", { get_MotionBankID = function() return 3 end, get_MotionID = function() return 30 end, get_Frame = function() return 1.5 end })
        local mo = Obj.new("via.motion.Motion", { getLayer = function() return l end })
        local comps = { st, dc, mo }
        if mode == "field" then comps = { st, Obj.new(tn, {}, { HealthInfo = hi }), mo } end
        local go = make_go(name, vec(x, 0, 4), comps)
        return go, hi
    end

    local envh = new_environment()
    build_world(envh)
    make_td("app.HealthInfo", { fields = { { "_CurrentHealth", "System.Single" }, { "_MaxHealth", "System.Single" } } })
    local g1, hi1 = mk_enemy(envh, "Em4400", 4, "manual")
    local g2, hi2 = mk_enemy(envh, "Em4500", 6, "hitdmg")
    local g3, hi3 = mk_enemy(envh, "Em4600", 8, "direct")
    local g4, hi4 = mk_enemy(envh, "Em4700", 10, "field")
    for _, g in ipairs({ g1, g2, g3, g4 }) do envh.scene_objects[#envh.scene_objects + 1] = g end
    envh.scene = make_scene(envh.scene_objects)
    load_script(envh)
    host_role_files(envh, "host", "tcp")
    live(envh, 3)
    calls = {}
    push_msgs(envh, { { 9, "x|Em4400|40|4.00|0.00|4.00" } })
    live(envh, 0.5)
    check(hi1.f._CurrentHealth == 160, "the host applies the hit: health 200 -> " .. tostring(hi1.f._CurrentHealth))
    check(calls_have("Em4400.newFakeDamageInfo 40.0") and calls_have("Em4400.addManualDamage"), "...through newFakeDamageInfo and addManualDamage")
    local as = sent_a(envh)
    check(#as >= 1 and as[#as] == "a|Em4400|addManualDamage|200|160", "...and answers with what happened: " .. tostring(as[#as]))
    run_ui(envh)
    check(ui_has(envh, "Em4400: 40 damage by addManualDamage, health 200 -> 160") and ui_has(envh, "received 1, applied 1, refused 0, failed 0"), "...and the panel shows it")
    check(log_has(envh, "enemy hit: Em4400: 40 damage by addManualDamage"), "...and it is logged")

    push_msgs(envh, { { 9, "x|Em4500|25|6.00|0.00|4.00" } })
    live(envh, 0.5)
    check(hi2.f._CurrentHealth == 175 and calls_have("Em4500.addHitDamage"), "when addManualDamage gives nothing, addHitDamage is used: " .. tostring(hi2.f._CurrentHealth))
    push_msgs(envh, { { 9, "x|Em4600|60|8.00|0.00|4.00" } })
    live(envh, 0.5)
    check(hi3.f._CurrentHealth == 140 and calls_have("Em4600.set_health 140"), "when the damage call throws, the health is lowered directly: " .. tostring(hi3.f._CurrentHealth))
    as = sent_a(envh)
    check(as[#as] == "a|Em4600|set_health|200|140", "...and the answer says how: " .. tostring(as[#as]))
    push_msgs(envh, { { 9, "x|Em4700|50|10.00|0.00|4.00" } })
    live(envh, 0.5)
    check(hi4.f._CurrentHealth == 150, "with no damage methods at all the health value itself is lowered: " .. tostring(hi4.f._CurrentHealth))

    -- limits
    push_msgs(envh, { { 9, "x|Em4400|9999|4.00|0.00|4.00" } })
    live(envh, 0.5)
    check(hi1.f._CurrentHealth == 0 or hi1.f._CurrentHealth == -340, "a huge damage number is cut to 500: " .. tostring(hi1.f._CurrentHealth))
    check(calls_have("Em4400.newFakeDamageInfo 500.0"), "...(500)")
    push_msgs(envh, { { 9, "x|Em4500|0|6.00|0.00|4.00" } })
    live(envh, 0.5)
    check(hi2.f._CurrentHealth == 174, "a damage of 0 counts as 1: " .. tostring(hi2.f._CurrentHealth))
    local dead_before = hi1.f._CurrentHealth
    push_msgs(envh, { { 9, "x|Em4400|10|4.00|0.00|4.00" } })
    live(envh, 0.5)
    as = sent_a(envh)
    check(hi1.f._CurrentHealth == dead_before and as[#as]:match("^a|Em4400|failed|"), "a hit on an enemy that is already dead changes nothing: " .. tostring(as[#as]))
    push_msgs(envh, { { 9, "x|Em8000|10|-5.79|-7.77|13.25" } })
    live(envh, 0.5)
    as = sent_a(envh)
    check(as[#as] == "a|Em8000|refused|-1|-1", "a parked enemy is refused: " .. tostring(as[#as]))
    push_msgs(envh, { { 9, "x|Em9999|10|0.00|0.00|0.00" } })
    live(envh, 0.5)
    as = sent_a(envh)
    check(as[#as] == "a|Em9999|refused|-1|-1", "an enemy that does not exist here is refused: " .. tostring(as[#as]))
    push_msgs(envh, { { 9, "x|Em4500|nonsense" } })
    live(envh, 0.5)
    run_ui(envh)
    check(ui_has(envh, "a damaged hit message was ignored"), "a damaged message is ignored")
    -- the host's switch
    envh.check_override["HOST: apply the other player's hits to my enemies"] = false
    run_ui(envh)
    local before_off = hi2.f._CurrentHealth
    push_msgs(envh, { { 9, "x|Em4500|20|6.00|0.00|4.00" } })
    live(envh, 0.5)
    check(hi2.f._CurrentHealth == before_off, "with the host switch off the hit is not applied")
    as = sent_a(envh)
    check(as[#as] == "a|Em4500|refused|-1|-1", "...and is refused")
    envh.check_override["HOST: apply the other player's hits to my enemies"] = true
    run_ui(envh)
    -- ten a second at most
    local before_flood = hi2.f._CurrentHealth
    local flood = {}
    for i = 1, 14 do flood[i] = { 9, "x|Em4500|1|6.00|0.00|4.00" } end
    push_msgs(envh, flood)
    live(envh, 0.2)
    check(before_flood - hi2.f._CurrentHealth <= 10 and before_flood - hi2.f._CurrentHealth >= 1, "no more than ten hits a second are applied: " .. tostring(before_flood - hi2.f._CurrentHealth))
    -- the JOINER never applies a hit
    local envj = new_environment()
    build_world(envj)
    local gj, hij = mk_enemy(envj, "Em4400", 4, "manual")
    envj.scene_objects[#envj.scene_objects + 1] = gj
    envj.scene = make_scene(envj.scene_objects)
    load_script(envj)
    host_role_files(envj, "join", "tcp")
    live(envj, 2)
    push_msgs(envj, { { 9, "x|Em4400|40|4.00|0.00|4.00" } })
    live(envj, 0.5)
    check(hij.f._CurrentHealth == 200, "a joiner never applies a hit to its own enemies")

    -- ---------------- (9.13) the gun's own shoot call is the shot ----------------
    do
        local envg = new_environment()
        build_world(envg)
        make_td("app.PlayerGun", { methods = { shoot = {}, shootStart = {}, reload = {} } })
        weapons_by_type["app.WeaponGun"] = {}
        weapons_by_type["app.PlayerGun"] = {}
        load_script(envg)
        host_role_files(envg, "join", "tcp")
        live(envg, 1)
        envg.files["re7mp_state_in.json"] = { seq = 5, n = 1, p = "Em2000,0.00,0.00,-6.00,0,0,0,1,500,1,2,3,4.0" }
        live(envg, 1)
        check(envg.hooks["app.PlayerGun.shoot"] ~= nil and envg.hooks["app.PlayerGun.shootStart"] ~= nil, "a joiner that gets the host's enemies has the gun's shoot calls hooked")
        do
            local seen = {}
            for _, c in ipairs(envg.crumb_log or {}) do seen[c] = true end
            check(seen["hooking: app.PlayerGun.shoot"] and seen["clean: hook installed: app.PlayerGun.shoot"] and seen["clean: hook installed: app.PlayerGun.shootStart"],
                "each gun hook is named by a crumb while it is installed and cleared right after")
        end
        do -- the host never hooks the gun for this
            local envh = new_environment()
            build_world(envh)
            make_td("app.PlayerGun", { methods = { shoot = {}, shootStart = {}, reload = {} } })
            weapons_by_type["app.WeaponGun"] = {}
            weapons_by_type["app.PlayerGun"] = {}
            load_script(envh)
            host_role_files(envh, "host", "tcp")
            live(envh, 1.5)
            check(envh.hooks["app.PlayerGun.shoot"] == nil, "the host does not hook the gun for shots")
        end
        check(envg.hooks["app.PlayerGun.reload"] == nil, "...and nothing else of the gun")
        do -- a player who is the HOST now (the hook is still there from before) does not send hits for it
            local envr = new_environment()
            build_world(envr)
            make_td("app.PlayerGun", { methods = { shoot = {}, shootStart = {}, reload = {} } })
            weapons_by_type["app.WeaponGun"] = {}
            weapons_by_type["app.PlayerGun"] = {}
            load_script(envr)
            host_role_files(envr, "join", "tcp")
            live(envr, 1)
            envr.files["re7mp_state_in.json"] = { seq = 5, n = 1, p = "Em2000,0.00,0.00,-6.00,0,0,0,1,500,1,2,3,4.0" }
            live(envr, 1)
            envr.hooks["app.PlayerGun.shoot"]({ 0 })
            live(envr, 0.3)
            check(#sent_x(envr) == 1, "(a joiner's shoot call sends a hit)")
            host_role_files(envr, "host", "tcp")
            live(envr, 0.3)
            envr.hooks["app.PlayerGun.shoot"]({ 0 })
            live(envr, 0.3)
            check(#sent_x(envr) == 1, "...and once this player is the host the same call sends nothing")
        end
        do -- the hook box unticked before anything is hooked: not even the learner hooks the gun
            local envq = new_environment()
            build_world(envq)
            make_td("app.PlayerGun", { methods = { shoot = {}, shootStart = {}, reload = {} } })
            weapons_by_type["app.WeaponGun"] = {}
            weapons_by_type["app.PlayerGun"] = {}
            load_script(envq)
            host_role_files(envq, "join", "tcp")
            envq.check_override["JOINER: take my shots from the gun's own shoot call (hooks app.PlayerGun.shoot, once per shot)"] = false
            run_ui(envq) -- (before the first frame: a joiner in enemy mode hooks the gun at the first one)
            envq.ui_press["Learn the shot signal (then fire three shots)"] = true
            run_ui(envq)
            live(envq, 0.5)
            check(envq.hooks["app.PlayerGun.shoot"] == nil and envq.hooks["app.PlayerGun.shootStart"] == nil, "with the hook box unticked the gun is not hooked, not even by the learner")
        end
        envg.hooks["app.PlayerGun.shoot"]({ 0 })
        live(envg, 0.3)
        local xg = sent_x(envg)
        check(#xg == 1 and xg[1]:match("^x|Em2000|30|"), "a shot the game reports through shoot sends a hit at the box in the line of fire: " .. tostring(xg[1]))
        envg.hooks["app.PlayerGun.shootStart"]({ 0 })
        envg.hooks["app.PlayerGun.shoot"]({ 0 })
        live(envg, 0.3)
        check(#sent_x(envg) == 2, "shootStart and shoot of one shot count as one shot")
        run_ui(envg)
        check(ui_has(envg, "Gun hook: shoot, shootStart   (shoot calls seen: 3, used as shots: 2)"), "the panel counts the calls and the shots used")
        envg.check_override["JOINER: take my shots from the gun's own shoot call (hooks app.PlayerGun.shoot, once per shot)"] = false
        run_ui(envg)
        envg.hooks["app.PlayerGun.shoot"]({ 0 })
        live(envg, 0.3)
        check(#sent_x(envg) == 2, "with the hook box unticked a shoot call is not a shot")
        envg.check_override["JOINER: take my shots from the gun's own shoot call (hooks app.PlayerGun.shoot, once per shot)"] = true
        run_ui(envg)
        envg.hooks["app.PlayerGun.shoot"]({ 0 })
        live(envg, 0.3)
        check(#sent_x(envg) == 3, "...and ticked again it is")
        envg.check_override["JOINER: my shots hurt the host's enemies (a shot that points at a red box)"] = false
        run_ui(envg)
        envg.hooks["app.PlayerGun.shoot"]({ 0 })
        live(envg, 0.3)
        run_ui(envg)
        check(#sent_x(envg) == 3 and ui_has(envg, "(shoot calls seen: 6, used as shots: 3)"), "with the damage switch off a shoot call is neither sent nor counted as a shot")
        envg.check_override["JOINER: my shots hurt the host's enemies (a shot that points at a red box)"] = true
        run_ui(envg)
        -- the learner: three calls of shoot while it watches
        envg.ui_press["Learn the shot signal (then fire three shots)"] = true
        run_ui(envg)
        live(envg, 0.3)
        for _ = 1, 3 do
            envg.hooks["app.PlayerGun.shoot"]({ 0 })
            live(envg, 0.5)
        end
        live(envg, 2)
        run_ui(envg)
        check(ui_has(envg, "the gun's own shoot call ran 3 times while you fired"), "the learner says the shoot call was seen when no field changes")
        check(#sent_x(envg) == 3, "...and learning sends no hits")
        run_ui(envg)
        envg.ui_press["Hide them for 60 s"] = true
        run_ui(envg)
        live(envg, 2.3)
        local eg = envg.files["re7mp_debug.json"].health.enemy_hits
        check(eg and eg.gun_hook and #eg.gun_hook.installed == 2 and eg.gun_hook.calls.shoot >= 4 and eg.gun_hook.shots_used >= 3, "the debug file says what the gun hook saw")
    end

    -- ---------------- the shot signal ----------------
    local envs = new_environment()
    build_world(envs)
    make_td("app.WeaponGun", { fields = { { "_bullet", "System.Int32" }, { "_timer", "System.Int32" }, { "_spread", "System.Single" },
        { "_ammoPair", "System.Int32" }, { "_burst", "System.Int32" }, { "_ammoClock", "System.Int32" } } })
    local gun = Obj.new("app.WeaponGun", {}, { _bullet = 7, _timer = 5000, _spread = 0.5, _ammoPair = 20, _burst = 9, _ammoClock = 100 })
    gun.addr = 0x1234
    weapons_by_type["app.WeaponGun"] = { gun }
    weapons_by_type["app.PlayerGun"] = {}
    load_script(envs)
    host_role_files(envs, "join", "tcp")
    envs.files["re7mp_state_in.json"] = { seq = 5, n = 1, p = "Em2000,0.00,0.00,-6.00,0,0,0,1,500,1,2,3,4.0" }
    live(envs, 1)
    -- before it is learned, a falling bullet count does nothing
    gun.f._bullet = 6
    live(envs, 0.5)
    check(#sent_x(envs) == 0, "no shot signal learned: a falling count sends nothing")
    envs.ui_press["Learn the shot signal (then fire three shots)"] = true
    run_ui(envs)
    run_ui(envs)
    check(ui_has(envs, "fire three shots now"), "learning is announced")
    live(envs, 0.3) -- the learner takes its first look at the weapon (a baseline) before the shots start
    for shot = 1, 3 do
        gun.f._bullet = gun.f._bullet - 1
        gun.f._ammoPair = gun.f._ammoPair - 2         -- falls by two: not a bullet counter
        gun.f._ammoClock = gun.f._ammoClock - 1       -- a slow clock: looks like three shots at first, but it keeps counting
        for _ = 1, 6 do
            gun.f._timer = gun.f._timer - 1   -- falls by one every frame: a clock, not a bullet counter
            run_frames(envs, 0.05) bump_remote(envs)
        end
    end
    for i = 1, 9 do
        gun.f._ammoClock = gun.f._ammoClock - 1
        if i == 3 or i == 6 then gun.f._burst = gun.f._burst - 1 end   -- falls by one twice only: not three
        for _ = 1, 6 do run_frames(envs, 0.05) bump_remote(envs) end
    end
    live(envs, 0.5)
    run_ui(envs)
    check(ui_has(envs, "learned: app.WeaponGun._bullet went down by one 3 times"), "three shots teach the bullet counter (not the clock, the pairs or the twice-only field)")
    check(envs.files["re7mp_settings.json"] == nil or true, "")
    live(envs, 1.5)
    local sv = envs.files["re7mp_settings.json"]
    check(sv and sv.shot_signal and sv.shot_signal.type == "app.WeaponGun" and sv.shot_signal.field == "_bullet", "...and it is saved")
    check(#sent_x(envs) == 0, "...learning itself sends no hits")
    -- now a shot at a box sends a hit, a reload does not
    gun.f._bullet = gun.f._bullet - 1
    run_frames(envs, 0.05) bump_remote(envs)
    gun.f._bullet = gun.f._bullet - 1       -- a second drop 0.05 s later: the same trigger pull (no gun fires twice in 0.12 s)
    live(envs, 0.3)
    xs = sent_x(envs)
    check(#xs == 1 and xs[1]:match("^x|Em2000|30|"), "a shot with the box in the line of fire sends one hit: " .. tostring(xs[1]) .. " (" .. #xs .. ")")
    gun.f._bullet = 7 -- a reload
    live(envs, 0.3)
    check(#sent_x(envs) == 1, "a reload (the count goes up) sends nothing")
    gun.f._bullet = gun.f._bullet + 1       -- picking up one bullet
    live(envs, 0.3)
    check(#sent_x(envs) == 1, "picking up one bullet (the count goes up by one) sends nothing")
    gun.f._bullet = 20 -- a different weapon or a big jump
    live(envs, 0.3)
    gun.f._bullet = 3  -- falls by 17: not a shot
    live(envs, 0.3)
    check(#sent_x(envs) == 1, "a big drop (swapping weapons) is not a shot")
    -- missing: the box is somewhere else
    envs.files["re7mp_state_in.json"] = { seq = 6, n = 2, p = "Em2000,5.00,0.00,-6.00,0,0,0,1,500,1,2,3,4.0" }
    live(envs, 1)
    gun.f._bullet = 2
    live(envs, 0.3)
    check(#sent_x(envs) == 1, "a shot that points elsewhere sends nothing")
    run_ui(envs)
    check(ui_has(envs, "shot (ammo): no red box in the line of fire"), "...and the panel says so")
    -- the debug file
    local dbgf = envs.files["re7mp_debug.json"]
    live(envs, 3)
    envs.ui_press["Hide them for 60 s"] = true
    run_ui(envs)
    live(envs, 2.3)
    envs.ui_press["Show them now"] = true
    run_ui(envs)
    dbgf = envs.files["re7mp_debug.json"]
    local eh = dbgf and dbgf.health and dbgf.health.enemy_hits
    check(eh and eh.signal and eh.signal.field == "_bullet" and eh.sent == 1 and eh.signal_shots == 3 and eh.shots_tested == 2 and eh.no_box_in_line == 1, "the debug file reports the hits and the signal")
    check(eh and eh.weapon_components and eh.weapon_components["app.WeaponGun"] == 1 and eh.first_weapon_number_fields, "...the weapon components found")
    check(eh and eh.learner and eh.learner.candidates and #eh.learner.candidates >= 1, "...and what the learner saw")

    -- a learner that finds nothing says so
    local envn = new_environment()
    build_world(envn)
    make_td("app.WeaponGun", { fields = { { "_timer", "System.Int32" } } })
    local gun2 = Obj.new("app.WeaponGun", {}, { _timer = 100 })
    gun2.addr = 0x99
    weapons_by_type["app.WeaponGun"] = { gun2 }
    weapons_by_type["app.PlayerGun"] = {}
    load_script(envn)
    host_role_files(envn, "join", "tcp")
    live(envn, 1)
    envn.ui_press["Learn the shot signal (then fire three shots)"] = true
    run_ui(envn)
    for _ = 1, 400 do
        gun2.f._timer = gun2.f._timer - 1
        run_frames(envn, 0.05) bump_remote(envn)
    end
    run_ui(envn)
    check(ui_has(envn, "no field went down by exactly one 3 to 6 times"), "when nothing looks like a bullet counter the learner says so")
    -- a weapon that never changes: the learner gives up after 15 seconds
    local envt = new_environment()
    build_world(envt)
    make_td("app.WeaponGun", { fields = { { "_timer", "System.Int32" } } })
    local gun3 = Obj.new("app.WeaponGun", {}, { _timer = 100 })
    gun3.addr = 0x77
    weapons_by_type["app.WeaponGun"] = { gun3 }
    weapons_by_type["app.PlayerGun"] = {}
    load_script(envt)
    host_role_files(envt, "join", "tcp")
    live(envt, 1)
    envt.ui_press["Learn the shot signal (then fire three shots)"] = true
    run_ui(envt)
    live(envt, 14)
    run_ui(envt)
    check(ui_has(envt, "fire three shots now") and not ui_has(envt, "time is up"), "(the learner is still waiting after 14 seconds)")
    live(envt, 2)
    run_ui(envt)
    check(ui_has(envt, "time is up"), "the learner gives up after 15 seconds")
    -- a saved signal is loaded, and a damaged one is ignored
    local envl = new_environment()
    build_world(envl)
    envl.files["re7mp_settings.json"] = { shot_signal = { type = "app.WeaponGun", field = "_bullet" }, hit_damage = 55, hit_on = false, hit_accept = false }
    load_script(envl)
    host_role_files(envl, "join", "tcp")
    live(envl, 0.5)
    run_ui(envl)
    check(ui_has(envl, "Shot detection: app.WeaponGun._bullet"), "a saved shot signal is used")
    local envd = new_environment()
    build_world(envd)
    envd.files["re7mp_settings.json"] = { shot_signal = { type = 5, field = "x" }, hit_damage = 99999 }
    load_script(envd)
    host_role_files(envd, "join", "tcp")
    live(envd, 0.5)
    run_ui(envd)
    check(ui_has(envd, "Shot detection: not learned yet") and not ui_has(envd, "UI error"), "a damaged saved signal and an absurd damage are ignored")
    envd.files["re7mp_state_in.json"] = { seq = 5, n = 1, p = "Em2000,0.00,0.00,-6.00,0,0,0,1,500,1,2,3,4.0" }
    live(envd, 1)
    press(envd)
    check(sent_x(envd)[1] ~= nil and sent_x(envd)[1]:match("^x|Em2000|30|"), "...the damage stays at the default (30): " .. tostring(sent_x(envd)[1]))
    for k in pairs(weapons_by_type) do weapons_by_type[k] = nil end
end

-- =============================================================================================
-- Scenario 3: the JOINER sees ghosts, and (mode 3) moves its own enemies
-- =============================================================================================
do
    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "join", "tcp")
    env.files["re7mp_state_in.json"] = { seq = 5, n = 1,
        p = "Em2000,5.00,0.00,6.00,0,0.7071,0,0.7071,500,1,2,3,4.0;Em6100,1.00,2.00,3.00,0,0,0,1,-1,1,0,0,0;Em9999,bad,1,1,0,0,0,1,1,1,0,0,0"
            .. ";Em8000,-5.79,-7.77,13.25,0,0,0,1,-1,3,0,4294967295,0;Em6190,0,0,0,0,0,0,1,-1,15,0,4294967295,0" }
    for i = 1, 10 do run_frames(env, 0.05) bump_remote(env) end
    check(texts_have(env, "Em2000  HP 500"), "ghost label with health is drawn")
    check(texts_have(env, "Em6100"), "ghost label without health is drawn")
    check(not texts_have(env, "Em9999"), "an entry with a bad number is ignored")
    check(not texts_have(env, "Em8000") and not texts_have(env, "Em6190"), "parked / placeholder objects are NOT drawn (the stray red box)")
    check(env.quads > 0 and env.lines > 0, "ghost boxes are drawn")
    run_ui(env)
    check(ui_has(env, "Enemies from the host: 4"), "panel counts received enemies (4 valid entries)")
    check(#calls == 0, "mode 2 does not touch the game's enemies")

    -- the debug checkbox shows them in grey with the reason
    env.check_override["Also draw parked / placeholder objects in grey (to see what a stray box was)"] = true
    run_ui(env)
    env.texts = {}
    for i = 1, 4 do run_frames(env, 0.05) bump_remote(env) end
    check(texts_have(env, "Em8000  (parked)"), "with 'show parked' the parked object is drawn and says why")
    check(texts_have(env, "Em6190  (parked, no Status component, at the origin)"), "...and so is the origin placeholder")
    env.check_override["Also draw parked / placeholder objects in grey (to see what a stray box was)"] = false
    run_ui(env)

    -- the host's enemy list changes: the missing ones disappear
    env.files["re7mp_state_in.json"] = { seq = 6, n = 2, p = "Em2000,5.00,0.00,6.00,0,0,0,1,400,1,0,0,0;Em8000,-5.79,-7.77,13.25,0,0,0,1,-1,3,0,4294967295,0" }
    env.texts = {}
    for i = 1, 6 do run_frames(env, 0.05) bump_remote(env) end
    check(texts_have(env, "Em2000  HP 400") and not texts_have(env, "Em6100"), "ghost list follows the host")

    -- mode 3 (experimental): my Em2000 is moved onto the host's; parked ones are left alone
    env.combo_override["Enemy sync"] = 3
    run_ui(env)
    calls = {}
    for i = 1, 40 do run_frames(env, 0.05) bump_remote(env) end
    check(calls_have("Em2000.set_Position 5.00 0.00 6.00"), "mode 3 moves my Em2000 to the host's position")
    check(calls_have("Em2000.set_EulerAngle"), "mode 3 turns my Em2000")
    check(not calls_have("Em2000Think.set_Enabled false"), "AI is left alone unless asked")
    check(not calls_have("Em6100.set_Position"), "enemies the host did not send are left alone")
    check(not calls_have("Em8000.set_Position"), "a parked enemy is never moved")

    -- host goes quiet: everything it moved is released
    env.clock = env.clock + 10
    calls = {}
    run_frames(env, 0.2)
    check(not calls_have("Em2000.set_Position"), "no more moving once the host is silent")
end

-- =============================================================================================
-- Scenario 4: items. Give (F7), receive give (direct, and fallback), drop on discard, receive drop
-- =============================================================================================
do
    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "host", "tcp")
    run_frames(env, 0.3)
    local item = env.make_item("Herb", 3)

    -- highlight an item in the inventory (the game asks isCanDiscard on it)
    env.hooks["app.Item.isCanDiscard"]({ 0, item })
    run_ui(env)
    check(ui_has(env, "Pointed at in the game's inventory: Herb x3"), "panel shows the item the cursor is on")
    env.hooks["app.Item.isCanDiscard"]({ 0, env.make_item("Herb", 3) })

    -- the inventory list works without pointing at anything (the hover hook never fired in the real game)
    check(ui_has(env, "Your inventory: 3 items"), "panel lists the inventory (3 items)")
    check(ui_has(env, "   Herb x3") and ui_has(env, "   Gunpowder x2") and ui_has(env, "   HandgunBullet x15"),
        "...including the one whose name comes back as a managed string object")
    calls = {}
    env.ui_press["Give all##a3"] = true -- HandgunBullet x15
    run_ui(env)
    run_frames(env, 0.2)
    bump_remote(env)
    check(not calls_have("Inventory.reduceItem"), "'Give all' in the list takes nothing yet (9.13: the other game has to confirm first)")
    local lg = messages_of_kind(env, 5)
    check(lg[#lg] == "HandgunBullet|15", "...it sends a give message: " .. tostring(lg[#lg]))
    push_msgs(env, { { 10, "g|HandgunBullet|15|ok|in the inventory" } })
    run_frames(env, 0.3)
    bump_remote(env)
    check(calls_have("Inventory.reduceItem HandgunBullet 15 true"), "...and when they confirm, the whole stack leaves the inventory")
    calls = {}
    env.ui_press["Give 1##g2"] = true -- Gunpowder
    run_ui(env)
    run_frames(env, 0.2)
    bump_remote(env)
    check(not calls_have("Inventory.reduceItem"), "'Give 1' in the list takes nothing before the answer")
    push_msgs(env, { { 10, "g|Gunpowder|1|ok|in the inventory" } })
    run_frames(env, 0.3)
    bump_remote(env)
    check(calls_have("Inventory.reduceItem Gunpowder 1 true"), "...and one leaves when they confirm")
    calls = {}
    env.hooks["app.Item.isCanDiscard"]({ 0, env.make_item("Herb", 3) }) -- giving from the list clears the pointed-at item

    -- F7 gives one
    env.keys[0x76] = true
    run_frames(env, 0.2)
    bump_remote(env)
    env.keys[0x76] = false
    run_frames(env, 0.2)
    check(not calls_have("Inventory.reduceItem"), "F7 offers one Herb and takes nothing yet")
    local gm = messages_of_kind(env, 5)
    check(gm[#gm] == "Herb|1", "a give message 'Herb|1' is queued last: " .. table.concat(gm, ","))
    push_msgs(env, { { 10, "g|Herb|1|ok|in the inventory" } })
    run_frames(env, 0.3)
    bump_remote(env)
    check(calls_have("Inventory.reduceItem Herb 1 true"), "...and the Herb leaves my inventory when they confirm")

    -- giving with nobody there does nothing
    local env0 = new_environment()
    build_world(env0)
    load_script(env0)
    run_frames(env0, 0.3)
    env0.hooks["app.Item.isCanDiscard"]({ 0, env0.make_item("Herb", 3) })
    env0.keys[0x76] = true
    run_frames(env0, 0.2)
    check(not calls_have("Inventory.reduceItem"), "nothing is taken when nobody is connected")
    check(#messages_of_kind(env0, 5) == 0, "no give message without a peer")

    -- pointing at an item whose name can't be read must not break anything
    do
        local odd = Obj.new("app.Item", { getItemDataId = function() return 12345 end, getTotalStackNum = function() return 2 end })
        env.hooks["app.Item.isCanDiscard"]({ 0, odd })
        run_ui(env)
        check(ui_has(env, "can't read its name"), "panel says the pointed-at item's name can't be read")
        calls = {}
        env.keys[0x76] = true
        run_frames(env, 0.1)
        env.keys[0x76] = false
        run_frames(env, 0.1)
        check(not calls_have("Inventory.reduceItem"), "F7 on an unreadable item takes nothing")
    end

    -- receiving a give: goes into the inventory
    calls = {}
    push_msgs(env, { { 5, "Herb|2" } })
    for i = 1, 6 do run_frames(env, 0.05) bump_remote(env) end
    check(calls_have("ItemManager.createItemInstance Herb"), "received give creates the item")
    check(calls_have("Inventory.addItem Herb x2"), "received give adds 2 Herb to the inventory")
    check(not calls_have("createDropItemInstance"), "no ground drop when the inventory took it")

    -- receiving a give while the inventory is full: it lies at my feet
    calls = {}
    env.inventory_full = true
    push_msgs(env, { { 5, "Herb|2" }, { 5, "Gunpowder|1" } })
    for i = 1, 6 do run_frames(env, 0.05) bump_remote(env) end
    check(calls_have("ItemManager.createDropItemInstance Gunpowder 1"), "full inventory: the item is dropped at my feet")
    check(not calls_have("Item.destroyItem"), "the item object made for a failed add is left alone (destroyItem on it is untested in the real game)")
    env.inventory_full = false

    -- discard with "drops on the ground" on: the item also appears in the world, and the other player is told
    calls = {}
    local focused = env.make_item("Coin", 2)
    env.hooks["app.Item.isCanDiscard"]({ 0, focused })
    env.hooks["app.Item.reduceNum"]({ 0, focused, 2, env.player })
    for i = 1, 10 do run_frames(env, 0.05) bump_remote(env) end
    check(calls_have("ItemManager.createDropItemInstance Coin 2"), "discard spawns the item on the ground")
    local dm = messages_of_kind(env, 6)
    check(#dm == 1 and dm[1]:match("^Coin|2|0%.00|0%.10|0%.80$") ~= nil, "a drop message with the spawn position (in front of the player's feet) is queued: " .. table.concat(dm, ","))

    -- a discard of something that was not highlighted is not touched
    calls = {}
    env.hooks["app.Item.reduceNum"]({ 0, env.make_item("Knife", 1), 1, env.player })
    for i = 1, 10 do run_frames(env, 0.05) bump_remote(env) end
    check(not calls_have("createDropItemInstance Knife"), "a discard of a different item is ignored")

    -- receiving a drop: spawned at the sender's position
    calls = {}
    push_msgs(env, { { 6, "Herb|1|1.00|0.00|2.00" } })
    for i = 1, 6 do run_frames(env, 0.05) bump_remote(env) end
    check(calls_have("ItemManager.createDropItemInstance Herb 1"), "received drop spawns the item")
    check(calls_have("sm1800_Herb_Item.set_Position 1.00 0.00 2.00"), "...at the position the other player dropped it")

    -- garbage messages are ignored
    calls = {}
    push_msgs(env, { { 5, "../../x|9999" }, { 6, "Herb|x|y|z|w" }, { 5, "Herb|0" }, { 6, "Herb|1|1|2" } })
    for i = 1, 6 do run_frames(env, 0.05) bump_remote(env) end
    check(#calls == 0, "malformed give/drop messages do nothing")

    -- drop-on-discard off
    env.files["re7mp_settings.json"] = nil
end

-- drop on discard can be switched off by the saved setting
do
    local env = new_environment()
    build_world(env)
    env.files["re7mp_settings.json"] = { drop_on_discard = false }
    load_script(env)
    host_role_files(env, "host", "tcp")
    run_frames(env, 0.3)
    local focused = env.make_item("Coin", 1)
    env.hooks["app.Item.isCanDiscard"]({ 0, focused })
    env.hooks["app.Item.reduceNum"]({ 0, focused, 1, env.player })
    for i = 1, 10 do run_frames(env, 0.05) bump_remote(env) end
    check(not calls_have("createDropItemInstance"), "setting drop_on_discard=false keeps the normal discard")
end

-- =============================================================================================
-- Scenario 5: the collectors and the settings file
-- =============================================================================================
do
    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "host", "tcp")
    run_frames(env, 0.5)
    env.ui_press["5. Enemy details (stand near Jack or any enemy)"] = true
    env.ui_press["7. Highlighted item details (open the inventory, point at an item)"] = true
    env.ui_press["6. Enemy damage trace (press, then shoot an enemy once)"] = true
    env.hooks["app.Item.isCanDiscard"]({ 0, env.make_item("Herb", 3) })
    run_ui(env)
    run_frames(env, 3.0)
    local dbg = env.files["re7mp_debug.json"]
    check(dbg ~= nil and dbg.script == "re7mp v9.15", "debug file written by v9.15")
    local pinned = table.concat(dbg and dbg.pinned or {}, "\n")
    check(pinned:find("=== enemy details done ===", 1, true) ~= nil, "enemy details finished")
    check(pinned:find("component app.Em2000Status", 1, true) ~= nil, "Status component listed")
    check(pinned:find("<isStarted>k__BackingField : System.Boolean = true", 1, true) ~= nil, "Status fields dumped with their values")
    check(pinned:find("HealthInfo object in field HealthInfo:", 1, true) ~= nil, "the HealthInfo object is dumped")
    check(pinned:find("_CurrentHealth : System.Single = 820", 1, true) ~= nil, "...with its fields")
    check(pinned:find("health read from: app.Em2000.Em2000DamageController.HealthInfo._CurrentHealth; looks like: a live enemy", 1, true) ~= nil,
        "details say where health comes from and that Jack is live")
    check(pinned:find("Status component: NO; health read from: nothing found; looks like: parked, no Status component, at the origin", 1, true) ~= nil,
        "details say why Em6190 is not live")
    check(pinned:find("animation layer 0: bank 7, motion 123, frame 12.5", 1, true) ~= nil, "animation ids dumped")
    check(pinned:find("=== highlighted item done ===", 1, true) ~= nil, "item details finished")
    check(pinned:find("pointed-at item: id Herb, count 3", 1, true) ~= nil, "pointed-at item id and count dumped")
    check(pinned:find("getItemDataId -> string \"Herb\"", 1, true) ~= nil or pinned:find("getItemDataId -> string", 1, true) ~= nil, "id getter result type dumped")
    check(pinned:find("_ItemList has 3 entries", 1, true) ~= nil, "inventory list size dumped")
    check(pinned:find("readable items: 3", 1, true) ~= nil and pinned:find("   Gunpowder x2", 1, true) ~= nil, "readable items listed")
    check(pinned:find("Item : app.Item = ", 1, true) ~= nil, "ItemInfo fields dumped")

    -- the damage trace hooks the controllers of the enemies that exist, and writes damage records out in full
    check(env.hooks["app.Em2000.Em2000DamageController.doDamage"] ~= nil, "damage trace hooked the live Em2000's DamageController")
    check(env.hooks["app.DamageController.addDamage"] ~= nil, "...and the shared DamageController base")
    local record = Obj.new("app.DamageController.DamageRecord", {}, { Damage = 250, WeaponID = 36 })
    local dcobj = Obj.new("app.Em2000.Em2000DamageController", { get_GameObject = function() return env.jack end }, {})
    env.hooks["app.Em2000.Em2000DamageController.doDamage"]({ 0, dcobj, record })
    check(log_has(env, "WeaponID=36") and log_has(env, "Damage=250"), "a traced damage call shows the record's numbers")
    check(log_has(env, "[on Em2000]"), "a traced call says which GameObject it was on")
    env.ui_press["6. Enemy damage trace (press, then shoot an enemy once)"] = true
    run_ui(env)
    check(log_has(env, "0 new methods"), "pressing the damage trace twice says the methods were already traced")

    env.combo_override["Enemy sync"] = 1
    run_ui(env)
    run_frames(env, 2.0)
    local s = env.files["re7mp_settings.json"]
    check(s ~= nil and s.enemy_mode == 1 and s.drop_on_discard == true and s.enemy_drive_ai == false and s.give_hint == true,
        "new settings are saved when one changes")
    check(s ~= nil and s.hide_near == 0.4 and s.show_parked == false, "hide distance (0.4 m default) and show_parked are in the settings file")

    -- the experimental mode is never restored from a saved file
    local env2 = new_environment()
    build_world(env2)
    env2.files["re7mp_settings.json"] = { enemy_mode = 3 }
    load_script(env2)
    env2.files["re7mp_in.json"] = nil
    run_ui(env2)
    check(not ui_has(env2, "EXPERIMENTAL: this moves your own enemies"), "mode 3 is not switched on by a saved setting")
end

-- =============================================================================================
-- Scenario 7: item names that getItemDataId does not hand back as plain text (the real game did this to v9.1)
-- =============================================================================================
do
    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "host", "tcp")
    run_frames(env, 0.3)
    make_td("app.ItemId", { fields = { { "Value", "System.String" } } })
    make_td("app.ItemSaveData", { fields = { { "ItemId", "System.String" }, { "Num", "System.Int32" } } })
    make_td("app.ItemB", { fields = { { "_ItemId", "System.String" } } })

    local function hover_then_id(item)
        env.hooks["app.Item.isCanDiscard"]({ 0, item })
        return env.hooks ~= nil
    end
    local function panel_has(text)
        run_ui(env)
        return ui_has(env, text)
    end

    -- A: the getter returns an object holding the text
    hover_then_id(Obj.new("app.Item", { getItemDataId = function() return Obj.new("app.ItemId", {}, { Value = "Herb" }) end,
        getTotalStackNum = function() return 2 end }))
    check(panel_has("Pointed at in the game's inventory: Herb x2"), "A: an id object with a text field is read")
    -- B: the getter returns a number; the item has a text field
    hover_then_id(Obj.new("app.ItemB", { getItemDataId = function() return 77 end, getTotalStackNum = function() return 4 end },
        { _ItemId = "Gunpowder" }))
    check(panel_has("Pointed at in the game's inventory: Gunpowder x4"), "B: a text field on the item is used when the getter gives a number")
    -- C: no id getter at all; the save data holds the name
    hover_then_id(Obj.new("app.Item", { getItemSaveData = function() return Obj.new("app.ItemSaveData", {}, { ItemId = "RemedyM", Num = 1 }) end }))
    check(panel_has("Pointed at in the game's inventory: RemedyM x1"), "C: the item's save data is used (count unknown -> 1)")
    -- D: only the GameObject's name is left
    local go_item = Obj.new("app.Item", { get_GameObject = function() return make_go("CylinderKey(Clone)", vec(0, 0, 0)) end })
    hover_then_id(go_item)
    check(panel_has("Pointed at in the game's inventory: CylinderKey x1"), "D: the GameObject name is the last resort")

    -- E: nothing works: the panel says what each attempt returned, and the diagnostics reach the debug file by themselves
    hover_then_id(Obj.new("app.Item", { getItemDataId = function() return 12345 end }))
    check(panel_has("Pointed at an item in the game's inventory, but I can't read its name:"), "E: panel admits it can't read the name")
    check(ui_has(env, "   getItemDataId: the number 12345"), "...and says what the getter returned")
    local before = env.files["re7mp_debug.json"]
    run_frames(env, 4.0)
    local dbg = env.files["re7mp_debug.json"]
    local pinned = table.concat(dbg and dbg.pinned or {}, "\n")
    check(pinned:find("=== highlighted item ===", 1, true) ~= nil and pinned:find("name resolved: NO.", 1, true) ~= nil,
        "E: the item diagnostics were written to the debug file without pressing button 7")
    check(pinned:find("getItemDataId -> number 12345", 1, true) ~= nil, "...including what the getter returned")

    -- the inventory list: an entry that carries its own name, and an entry that can't be read
    local env2 = new_environment()
    build_world(env2)
    load_script(env2)
    host_role_files(env2, "host", "tcp")
    run_frames(env2, 0.3)
    make_td("app.ItemInfoX", { fields = { { "Item", "app.Item" }, { "ItemId", "System.String" }, { "Num", "System.Int32" } } })
    local odd_item = Obj.new("app.Item", { getItemDataId = function() return 5 end })
    local list = env2.inventory.f._ItemList
    list.m.get_Count = function() return 2 end
    local entries = {
        Obj.new("app.ItemInfoX", {}, { Item = odd_item, ItemId = "Alcohol", Num = 6 }), -- the entry itself says what it is
        Obj.new("app.ItemInfoX", {}, { Item = Obj.new("app.Item", { getItemDataId = function() return 9 end }), ItemId = "", Num = 1 }),
    }
    list.m.get_Item = function(_, i) return entries[i + 1] end
    run_ui(env2)
    check(ui_has(env2, "   Alcohol x6"), "an entry's own name and count are used when the item won't say")
    check(ui_has(env2, "Your inventory: 1 items   (1 of 2 entries unreadable"), "the panel says how many entries could not be read")
    run_frames(env2, 0.5)
    run_ui(env2)
    -- all unreadable -> automatic diagnostics
    entries[1] = Obj.new("app.ItemInfoX", {}, { Item = odd_item, ItemId = "", Num = 1 })
    env2.clock = env2.clock + 200
    env2.inv_dirty = true
    for i = 1, 3 do
        run_frames(env2, 1.5)
        run_ui(env2)
    end
    run_frames(env2, 3.0)
    local pinned2 = table.concat((env2.files["re7mp_debug.json"] or {}).pinned or {}, "\n")
    check(pinned2:find("_ItemList has 2 entries", 1, true) ~= nil, "an unreadable inventory list is dumped automatically")
end

-- =============================================================================================
-- Scenario 6: how close the other player can get before they disappear
-- =============================================================================================
do
    local env = new_environment()
    build_world(env)
    load_script(env)
    -- they stand 0.42 m from my camera at (0, 1.6, 0)
    env.files["re7mp_in.json"] = { seq = 1, x = 0.3, y = 1.6, z = 0.3, qx = 0, qy = 0, qz = 0, qw = 1, flags = 0, recv_count = 1,
        name = "Bob", transport = "tcp", role = "host" }
    for i = 1, 60 do run_frames(env, 0.05) bump_remote(env) end
    run_ui(env)
    check(not ui_has(env, "Other player not drawn: too close to your camera"), "at 0.42 m they are still drawn with the 0.4 m default")
    env.slider_override["Hide them when closer than (m)"] = 0.5
    run_ui(env)
    run_ui(env)
    check(ui_has(env, "Other player not drawn: too close to your camera"), "the slider can bring the limit back up (0.5 m hides them at 0.42 m)")
    run_frames(env, 2.0)
    check(env.files["re7mp_settings.json"] and env.files["re7mp_settings.json"].hide_near == 0.5, "the chosen distance is saved")

    -- and a saved value is restored on the next start
    local env2 = new_environment()
    build_world(env2)
    env2.files["re7mp_settings.json"] = { hide_near = 0.6 }
    load_script(env2)
    env2.files["re7mp_in.json"] = { seq = 1, x = 0.4, y = 1.6, z = 0.4, qx = 0, qy = 0, qz = 0, qw = 1, flags = 0, recv_count = 1,
        name = "Bob", transport = "tcp", role = "host" }
    for i = 1, 60 do run_frames(env2, 0.05) bump_remote(env2) end
    run_ui(env2)
    check(ui_has(env2, "Other player not drawn: too close to your camera"), "a saved 0.6 m is used (0.57 m away is hidden)")
end


-- =============================================================================================
-- Scenario 8: player health, the downed experiment (death mode 4), reviving, and the new collectors
-- =============================================================================================
do
    local function str(t) return Obj.new("System.String", { ["ToString()"] = function() return t end }) end
    -- what the game does for a hit: set_health is called with the lowered value (the hook runs before and after it)
    local function hit(env, new_hp)
        local hi = env.player_hi
        env.hooks["app.HealthInfo.set_health"]({ 0, hi })
        hi.f._CurrentHealth = new_hp
        env.posthooks["app.HealthInfo.set_health"](nil)
    end
    local function find_msg(env, pattern)
        for _, m in ipairs(messages_of_kind(env, 7)) do
            if m:match(pattern) then return m end
        end
        return nil
    end
    local function connected(env, frames)
        for i = 1, frames or 30 do run_frames(env, 0.05) bump_remote(env) end
    end

    local env = new_environment()
    build_world(env)
    env.files["re7mp_settings.json"] = { death_mode = 4 }
    load_script(env)
    host_role_files(env, "host", "tcp")
    connected(env)
    run_ui(env)
    for _, t in ipairs(env.ui_texts) do check(not t:find("UI error", 1, true), "no UI error with the health panel: " .. t) end
    check(log_has(env, "health: your health is read from app.PlayerDamageController.HealthInfo._CurrentHealth (maximum from _MaxHealth)"),
        "the player's health source is found and logged")
    check(ui_has(env, "Your health: 600 / 1000   (read from app.PlayerDamageController.HealthInfo._CurrentHealth)"), "panel shows your health and where it is read from")
    check(find_msg(env, "^h|600|1000|0$") ~= nil, "my health is sent to the other player: " .. table.concat(messages_of_kind(env, 7), ","))
    check(env.hooks["app.HealthInfo.set_health"] ~= nil and env.hooks["app.Inventory.reduceItem"] ~= nil, "health and item-use hooks installed")

    -- a heal: a Herb is used, then the health rises
    env.hooks["app.Inventory.reduceItem"]({ 0, env.inventory, str("Herb"), 1, true })
    env.player_hi.f._CurrentHealth = 800
    connected(env, 12)
    check(find_msg(env, "^e|heal|Herb|0%.00|1%.60|0%.00$") ~= nil, "a heal after using a Herb is sent as an event: " .. table.concat(messages_of_kind(env, 7), ","))
    check(find_msg(env, "^h|800|1000|0$") ~= nil, "...and the new health value is sent")
    -- a Herb given to the other player leaves the inventory through the same call as a Herb eaten: it is not a heal
    do
        local function heal_events() local n = 0 for _, m in ipairs(messages_of_kind(env, 7)) do if m:find("^e|heal|Herb") then n = n + 1 end end return n end
        local before = heal_events()
        env.player_hi.f._CurrentHealth = 600
        connected(env, 12)
        env.reduce_fires_hook = true
        env.hooks["app.Item.isCanDiscard"]({ 0, env.make_item("Herb", 3) })
        env.keys[0x76] = true
        connected(env, 4)
        env.keys[0x76] = false
        connected(env, 4)
        push_msgs(env, { { 10, "g|Herb|1|ok|in the inventory" } })
        connected(env, 4)
        env.player_hi.f._CurrentHealth = 800 -- the health rises right after
        connected(env, 12)
        env.reduce_fires_hook = nil
        check(heal_events() == before, "a Herb given away is not reported as a heal when the health rises after it (" .. before .. " -> " .. heal_events() .. ")")
        env.player_hi.f._CurrentHealth = 600
        connected(env, 12)
    end
    -- an item that is not a healing item, then a rise: no heal event for it
    env.hooks["app.Inventory.reduceItem"]({ 0, env.inventory, str("Gunpowder"), 1, true })
    env.player_hi.f._CurrentHealth = 900
    connected(env, 12)
    check(find_msg(env, "^e|heal|Gunpowder") == nil, "a non-healing item is not reported as a heal")
    env.player_hi.f._CurrentHealth = 600
    connected(env, 12)

    -- the other player's health shows over their head
    push_msgs(env, { { 7, "h|650|1000|0" } })
    env.texts = {}
    connected(env, 10)
    check(texts_have(env, "Bob  HP 65%"), "the other player's tag shows HP 65%")
    run_ui(env)
    check(ui_has(env, "Bob: 650 / 1000"), "panel shows the other player's health")

    -- a lethal hit in downed mode: held at 1, you are down, they are told
    hit(env, 0)
    check(env.player_hi.f._CurrentHealth == 1, "a lethal hit is put back to 1 health before the game looks at it")
    connected(env, 12)
    run_ui(env)
    check(ui_has(env, "YOU ARE DOWN: waiting for Bob"), "the panel says you are down")
    check(find_msg(env, "^e|down||") ~= nil and find_msg(env, "^h|1|1000|1$") ~= nil, "the other player is told you are down")
    env.texts = {}
    connected(env, 4)
    check(texts_have(env, "YOU ARE DOWN: Bob has to use a Herb or Chem Fluid next to you"), "the down message is drawn on screen")
    -- more hits keep you down; you can't heal yourself
    hit(env, 0)
    check(env.player_hi.f._CurrentHealth == 1, "another lethal hit while down is held at 1 too")
    env.player_hi.f._CurrentHealth = 400
    connected(env, 6)
    check(env.player_hi.f._CurrentHealth == 1, "healing yourself while down is undone")
    run_ui(env)
    check(ui_has(env, "you can't heal yourself while down"), "...and the panel says why")

    -- the partner heals from too far away: nothing; close enough: you are up where you are, with 30% health
    push_msgs(env, { { 7, "e|heal|Herb|50.00|1.60|50.00" } })
    connected(env, 6)
    run_ui(env)
    check(ui_has(env, "YOU ARE DOWN: waiting for Bob") and ui_has(env, "within 3 m of you"), "a Herb used 50 m away does not revive")
    push_msgs(env, { { 7, "e|heal|Herb|4.00|1.60|0.00" } })
    connected(env, 6)
    run_ui(env)
    check(ui_has(env, "YOU ARE DOWN: waiting for Bob"), "a Herb used 4 m away (past 3 m and past the slack for lag) does not revive either")
    env.player.xf:call("set_Position", vec(7, 7, 7)) -- (the player object moves; the position that counts is the camera's)
    env.player.xf:call("set_Position", vec(0, 0, 0))
    push_msgs(env, { { 7, "e|heal|Herb|1.00|1.60|0.50" } })
    connected(env, 12)
    run_ui(env)
    check(not ui_has(env, "YOU ARE DOWN: waiting for Bob"), "a Herb used next to you gets you up")
    check(env.player_hi.f._CurrentHealth == 300, "...with 30% of the maximum (300), not a checkpoint reload: " .. tostring(env.player_hi.f._CurrentHealth))
    check(find_msg(env, "^e|up||") ~= nil, "...and they are told you are up")
    check(ui_has(env, "you are back up"), "the panel reports it")

    -- the other player goes down: tag, hint, F8
    push_msgs(env, { { 7, "e|down||3.00|1.60|4.00" } })
    env.texts = {}
    connected(env, 10)
    check(texts_have(env, "Bob [downed]"), "a downed partner is labelled [downed] after the name, like [crouching] and [healing]")
    env.files["re7mp_in.json"].flags = 64 + 128 -- (their flags still say blocking and healing: a downed player is neither)
    env.texts = {}
    connected(env, 6)
    check(texts_have(env, "Bob [downed]") and not texts_have(env, "[blocking]") and not texts_have(env, "[healing]"), "...and it replaces the pose labels while they are down")
    env.files["re7mp_in.json"].flags = 0
    check(texts_have(env, "Bob is down (5 m away): get within 3 m"), "the hint says how far away they are")
    -- (9.15) F8 uses no item: it must never touch the inventory, and the revive message it sends names no item
    local function inventory_touched() for _, c in ipairs(calls) do if c:find("^Inventory%.") then return true end end return false end
    local function revives_sent() local n = 0 for _, m in ipairs(messages_of_kind(env, 7)) do if m:find("^e|revive|") then n = n + 1 end end return n end
    calls = {}
    env.keys[0x77] = true
    connected(env, 4)
    env.keys[0x77] = false
    connected(env, 4)
    check(not inventory_touched() and revives_sent() == 0, "F8 too far away starts nothing")
    run_ui(env)
    check(ui_has(env, "get within 3 m"), "...and says to get closer")
    -- they stand next to me now
    env.files["re7mp_in.json"].x, env.files["re7mp_in.json"].z = 1, 1
    push_msgs(env, { { 7, "e|down||1.00|1.60|1.00" } })
    env.texts = {}
    connected(env, 6)
    check(texts_have(env, "[F8] revive Bob (stay put 3 s, no item needed)"), "next to them the hint offers F8, says to stay put and that no item is needed")
    calls = {}
    env.keys[0x77] = true
    connected(env, 4)
    env.keys[0x77] = false
    connected(env, 20) -- 1.2 s into the 3 s countdown
    check(not inventory_touched() and revives_sent() == 0, "F8 is not instant: nothing happens while the countdown runs")
    env.texts = {}
    connected(env, 4)
    check(texts_have(env, "Reviving Bob... "), "...and the screen shows the countdown")
    env.keys[0x77] = true -- pressing it again does not start a second one
    connected(env, 2)
    env.keys[0x77] = false
    connected(env, 2)
    check(find_msg(env, "^e|revive|") == nil, "...and nothing is sent before the end")
    connected(env, 50)
    check(find_msg(env, "^e|revive||") ~= nil and revives_sent() == 1, "after 3 s within range F8 tells them, naming no item: " .. table.concat(messages_of_kind(env, 7), ","))
    check(not inventory_touched(), "...and the inventory is not touched at all: no item is used")
    env.texts = {}
    connected(env, 4)
    check(not texts_have(env, "Reviving Bob... "), "...and the countdown is gone")
    do -- (the debug file is rewritten at most every 2 s when something is said: saying something makes it current)
        env.ui_press["Hide them for 60 s"] = true
        run_ui(env)
        connected(env, 46)
        env.ui_press["Show them now"] = true
        run_ui(env)
    end
    local rv = env.files["re7mp_debug.json"].health.revive
    check(rv and rv.radius == 3 and rv.hold == 3 and rv.started == 1 and rv.done == 1 and rv.cancelled == 0, "the debug file counts revives: started / done / cancelled")

    -- walking out of range cancels the countdown and costs nothing
    push_msgs(env, { { 7, "e|down||1.00|1.60|1.00" } })
    connected(env, 6)
    calls = {}
    env.keys[0x77] = true
    connected(env, 4)
    env.keys[0x77] = false
    connected(env, 20)
    env.files["re7mp_in.json"].x, env.files["re7mp_in.json"].z = 20, 20 -- they are carried away / I walk off
    push_msgs(env, { { 7, "h|1|1000|1" } })
    connected(env, 80)
    check(revives_sent() == 1, "leaving the area during the countdown cancels the revive: nothing is sent")
    run_ui(env)
    check(ui_has(env, "revive stopped"), "...and the panel says so")
    env.files["re7mp_in.json"].x, env.files["re7mp_in.json"].z = 1, 1
    push_msgs(env, { { 7, "h|1|1000|1" } })
    connected(env, 6)
    -- the other player getting up by themselves (or the loopback bot's revive) cancels it too
    env.keys[0x77] = true
    connected(env, 4)
    env.keys[0x77] = false
    connected(env, 10)
    push_msgs(env, { { 7, "e|up||1.00|1.60|1.00" } })
    connected(env, 80)
    check(revives_sent() == 1, "they got up during the countdown: nothing is sent")
    push_msgs(env, { { 7, "e|down||1.00|1.60|1.00" } })
    connected(env, 6)
    -- no item needed: with an empty inventory F8 revives all the same
    local saved_entries = {}
    for k = #env.entries, 1, -1 do saved_entries[#saved_entries + 1] = table.remove(env.entries, k) end
    push_msgs(env, { { 7, "h|1|1000|1" } })
    connected(env, 4)
    calls = {}
    env.keys[0x77] = true
    connected(env, 4)
    env.keys[0x77] = false
    connected(env, 80)
    check(revives_sent() == 2 and not inventory_touched(), "with an empty inventory F8 still revives: no item is needed (" .. revives_sent() .. ")")
    for _, e in ipairs(saved_entries) do table.insert(env.entries, e) end
    -- the panel button starts the same countdown, and its Cancel button stops it
    run_ui(env)
    env.ui_press["Revive Bob (stay put until the countdown ends; no item needed)  [F8]"] = true
    run_ui(env)
    connected(env, 20)
    run_ui(env)
    check(ui_has(env, "Reviving Bob: "), "the panel button starts the countdown and the panel shows it")
    env.ui_press["Cancel the revive"] = true
    run_ui(env)
    calls = {}
    connected(env, 80)
    check(revives_sent() == 2 and not inventory_touched(), "...and Cancel stops it for free")
    do -- (the debug file is rewritten at most every 2 s when something is said: saying something makes it current)
        env.ui_press["Hide them for 60 s"] = true
        run_ui(env)
        connected(env, 46)
        env.ui_press["Show them now"] = true
        run_ui(env)
    end
    local rv2 = env.files["re7mp_debug.json"].health.revive
    check(rv2 and rv2.started == 5 and rv2.done == 2 and rv2.cancelled == 3, "every countdown is counted: started 5, done 2, cancelled 3 (" ..
        tostring(rv2 and (rv2.started .. "/" .. rv2.done .. "/" .. rv2.cancelled)) .. ")")
    -- going down yourself during the countdown stops it
    push_msgs(env, { { 7, "h|1|1000|1" } })
    connected(env, 6)
    run_ui(env)
    env.ui_press["Revive Bob (stay put until the countdown ends; no item needed)  [F8]"] = true
    run_ui(env)
    connected(env, 20)
    run_ui(env)
    check(ui_has(env, "Reviving Bob: "), "(a countdown is running before I go down)")
    env.ui_press["Test: go down now (sets your health to 1)"] = true
    run_ui(env)
    connected(env, 4)
    run_ui(env)
    check(ui_has(env, "YOU ARE DOWN"), "(and I am down)")
    calls = {}
    connected(env, 80)
    check(revives_sent() == 2, "going down yourself during the countdown stops it: nothing is sent")
    env.ui_press["Test: pretend Bob used a Herb right next to me"] = true
    run_ui(env)
    connected(env, 6)
    env.player_hi.f._CurrentHealth = 600
    push_msgs(env, { { 7, "h|1|1000|1" } })
    connected(env, 6)
    -- holding the key down does not start a second countdown when the first ends
    push_msgs(env, { { 7, "h|1|1000|1" } })
    connected(env, 4)
    calls = {}
    local sent0 = revives_sent()
    env.keys[0x77] = true
    connected(env, 125)
    env.keys[0x77] = false
    check(revives_sent() == sent0 + 1 and not inventory_touched(), "F8 held down for 8 s revives once, not once every 3 s (" .. (revives_sent() - sent0) .. ")")
    do -- the crumb names the last step of a revive and is cleared right after
        local seen, order = {}, {}
        for i, c in ipairs(env.crumb_log or {}) do seen[c] = i end
        check(seen["revive: finishing the F8 revive of Bob"] and seen["clean: F8 revive finished"] and
            seen["clean: F8 revive finished"] > seen["revive: finishing the F8 revive of Bob"], "a crumb names the end of an F8 revive and is cleared right after")
    end
    -- the receiving side. Nothing is said for an item-less revive when I am not down; a Herb he uses is announced
    push_msgs(env, { { 7, "e|heal|Herb|1.00|1.60|0.50" } })
    connected(env, 8)
    run_ui(env)
    check(ui_has(env, "Bob used a Herb."), "(control) a Herb Bob used is announced in the chat")
    push_msgs(env, { { 7, "e|revive||1.00|1.60|0.50" } })
    connected(env, 8)
    run_ui(env)
    check(not ui_has(env, "used a healing item"), "a revive with no item named, while I am not down, says nothing")
    -- "Bob helped you up" (a revive with no item named) gets a downed player up, from the right distance only
    env.ui_press["Test: go down now (sets your health to 1)"] = true
    run_ui(env)
    connected(env, 4)
    run_ui(env)
    check(ui_has(env, "YOU ARE DOWN"), "(down again for the receiving test)")
    push_msgs(env, { { 7, "e|revive||4.00|1.60|0.00" } })
    connected(env, 6)
    run_ui(env)
    check(ui_has(env, "YOU ARE DOWN"), "a revive from 4 m away (past the distance and its slack) does not get me up")
    check(ui_has(env, "Bob helped you up but they were 4.0 m away"), "...and the panel says why")
    push_msgs(env, { { 7, "e|revive||3.40|1.60|0.00" } })
    connected(env, 12)
    run_ui(env)
    check(not ui_has(env, "YOU ARE DOWN"), "a revive with no item named, from 3.4 m (inside the 25% slack for lag), gets me up")
    check(ui_has(env, "Bob helped you up 3.4 m away"), "...and the panel says Bob helped me up, not that he used an item")
    env.player_hi.f._CurrentHealth = 600
    push_msgs(env, { { 7, "h|1|1000|1" } })
    connected(env, 6)

    -- the saved settings: the old 4 m default is not kept, a chosen distance and the hold time are
    local function revive_settings(s)
        local e = new_environment()
        build_world(e)
        e.files["re7mp_settings.json"] = s
        load_script(e)
        host_role_files(e, "host", "tcp")
        connected(e, 10)
        e.ui_press["Hide them for 60 s"] = true
        run_ui(e)
        connected(e, 46)
        return e.files["re7mp_debug.json"].health.revive
    end
    local rs = revive_settings({ death_mode = 4, revive_radius = 4, revive_hold = 2 })
    check(rs.radius == 3 and rs.hold == 2, "a saved revive distance of 4 (the old default) becomes the new 3 m; a saved hold time is kept")
    rs = revive_settings({ death_mode = 4, revive_radius = 6 })
    check(rs.radius == 6 and rs.hold == 3, "a revive distance someone chose (6 m) is kept, and the hold time defaults to 3 s")
    rs = revive_settings({ death_mode = 4, revive_hold = 30 })
    check(rs.hold == 3, "a hold time outside 1 to 10 s is ignored")

    -- both down: the hold is off and the game ends as usual
    push_msgs(env, { { 7, "e|down||1.00|1.60|1.00" } })
    connected(env, 4)
    hit(env, 0)
    connected(env, 6)
    check(env.player_hi.f._CurrentHealth == 0, "with the partner already down a lethal hit is NOT held (the game ends)")
    run_ui(env)
    check(not ui_has(env, "YOU ARE DOWN: waiting for Bob"), "...and I am not 'down'")
    env.player_hi.f._CurrentHealth = 600
    push_msgs(env, { { 7, "e|up||1.00|1.60|1.00" } })
    connected(env, 10)

    -- the test buttons
    env.ui_press["Test: go down now (sets your health to 1)"] = true
    run_ui(env)
    connected(env, 4)
    check(env.player_hi.f._CurrentHealth == 1, "the go-down test button sets the health to 1")
    run_ui(env)
    check(ui_has(env, "YOU ARE DOWN: waiting for Bob"), "...and marks you down")
    env.ui_press["Test: pretend Bob used a Herb right next to me"] = true
    run_ui(env)
    connected(env, 4)
    run_ui(env)
    check(not ui_has(env, "YOU ARE DOWN: waiting for Bob"), "pretending Bob used a Herb gets you up")

    -- the revive settings are saved and restored
    env.slider_override["Revive distance (m)"] = 6
    env.slider_override["Health after being revived (% of maximum)"] = 50
    run_ui(env)
    connected(env, 40)
    local st = env.files["re7mp_settings.json"]
    check(st and st.revive_radius == 6 and st.revive_pct == 50 and st.death_mode == 4, "revive distance and health are saved")
    env.slider_override["F8 revive: seconds to stay within that distance"] = 5
    run_ui(env)
    connected(env, 40)
    check(env.files["re7mp_settings.json"].revive_hold == 5, "...and so is the F8 hold time")

    -- the new collectors
    env.ui_press["8. Player details and trace (press, then get hit, block, use a Herb)"] = true
    env.ui_press["9. Cutscene / event trace (press, then trigger a cutscene, open a door)"] = true
    env.ui_press["7. Highlighted item details (open the inventory, point at an item)"] = true
    run_ui(env)
    connected(env, 60)
    local pinned = table.concat((env.files["re7mp_debug.json"] or {}).pinned or {}, "\n")
    check(pinned:find("=== player details done ===", 1, true) ~= nil, "player details finished")
    check(pinned:find("components on Pl0000: app.Inventory, app.PlayerDamageController, app.PlayerStatus", 1, true) ~= nil, "player components listed")
    check(pinned:find("health: app.PlayerDamageController.HealthInfo._CurrentHealth = ", 1, true) ~= nil, "player details say where health is read from")
    check(pinned:find("hold-at-1 hook installed, item-use hook installed, object address readable", 1, true) ~= nil, "player details report the hooks")
    check(pinned:find("component app.PlayerStatus:", 1, true) ~= nil and pinned:find("_Guard : System.Boolean = false", 1, true) ~= nil, "PlayerStatus fields dumped")
    check(pinned:find("startGuard", 1, true) ~= nil and pinned:find("doDie", 1, true) ~= nil, "damage / guard / death methods of the player listed")
    check(env.hooks["app.PlayerDamageController.doDamage"] and env.hooks["app.PlayerDamageController.doDie"], "player damage and death methods traced")
    check(env.hooks["app.PlayerStatus.startGuard"] and env.hooks["app.PlayerStatus.endGuard"], "player guard methods traced")
    check(env.hooks["app.PlayerDamageController.setPosition"] == nil, "...but not unrelated methods")
    -- a traced call on the player's own HealthInfo says so
    env.hooks["app.HealthInfo.set_health"]({ 0, env.player_hi })
    check(log_has(env, "[on the PLAYER's HealthInfo]"), "a traced set_health on the player's health says whose it is")
    check(env.hooks["app.GameEventManager.startEvent"] ~= nil and env.hooks["app.GameEventManager.unrelatedThing"] == nil, "event trace hooks start/end/play-like methods only")
    check(log_has(env, "event trace:"), "event trace announces itself")
    check(env.hooks["app.GameEventSetting.doStart"] ~= nil and env.hooks["app.GameEventSetting.set_timelineKickers"] == nil, "a setter that fires 13066 times a second is never hooked (it matches 'kick' but is on the skip list)")
    -- 9.6: the door, story-flag and save classes are opt-in (the 9.5 button 9 hooked all of them at once and the game crashed)
    check(env.hooks["app.DoorPush.playAutoClose"] == nil and env.hooks["app.InteractObjectBase.successInteract"] == nil
        and env.hooks["app.GameManager.setFsmGlobalIntValue"] == nil and env.hooks["app.SaveDataManager.saveFileGameSaveData"] == nil,
        "button 9 alone does not hook the door, story-flag or save classes")
    check(ui_has(env, "The 9+ options hook more of the game and may crash it"), "...they are options under button 9, with a warning")
    check(env.hooks["app.ItemManager.findCombineDataByResultItem"] == nil, "calls the UI makes every frame (item lookups) are never hooked")
    check(pinned:find("=== event objects done ===", 1, true) ~= nil and pinned:find("app.GameEventSetting on ", 1, true) ~= nil
        and pinned:find("Ev_Dinner_Trigger", 1, true) ~= nil and pinned:find("_EventId : System.Int32 = 42", 1, true) ~= nil,
        "button 9 dumps live event objects with the path and the fields that identify them")
    check(pinned:find("app.GameEventSetting: 1 in the scene", 1, true) ~= nil, "...and counts them")
    check(pinned:find("app.InventoryMenu: found", 1, true) ~= nil and pinned:find("refreshList", 1, true) ~= nil and pinned:find("somethingElse", 1, true) == nil,
        "button 7 lists refresh-like methods of the inventory screen")

    -- 9.6: tick the doors option and press 9 again: only the hand-picked methods are hooked, never the hot or teardown ones
    local BTN9 = "9. Cutscene / event trace (press, then trigger a cutscene, open a door)"
    env.check_override["    9+ also trace doors (app.DoorPush and app.InteractObjectBase, hand-picked methods only)##xdoors"] = true
    run_ui(env)
    env.ui_press[BTN9] = true
    run_ui(env)
    for _, k in ipairs({ "setInteract", "playAutoOpen", "playAutoClose", "playClosed", "closeDoorCore", "lockDoor", "lockDoorCore" }) do
        check(env.hooks["app.DoorPush." .. k] ~= nil, "the doors option hooks DoorPush." .. k)
    end
    check(env.hooks["app.InteractObjectBase.successInteract"] ~= nil, "...and InteractObjectBase.successInteract")
    check(env.hooks["app.DoorPush.isMotionJack"] == nil and env.hooks["app.DoorPush.existNear"] == nil and env.hooks["app.DoorPush.notifyInKnockArea"] == nil
        and env.hooks["app.InteractObjectBase.waitFsmExecuteCheck"] == nil, "...but not the methods a trace measured at 355 to 3219 calls a second")
    check(env.hooks["app.DoorPush.doOnDestroy"] == nil and env.hooks["app.DoorPush.releaseComponents"] == nil and env.hooks["app.DoorPush.gatherComponents"] == nil
        and env.hooks["app.DoorPush.getDoorPushSaveData"] == nil, "...nor the methods that run while a door is being taken apart or saved")
    check(env.hooks["app.DoorPush.callSE"] == nil and env.hooks["app.DoorPush.setActiveInteract"] == nil and env.hooks["app.DoorPush.passed"] == nil
        and env.hooks["app.DoorPush.doUpdate"] == nil and env.hooks["app.DoorPush.get_IsOpen"] == nil, "...nor sounds, tiny toggles, collision callbacks, updates or getters")
    check(env.hooks["app.GameManager.setFsmGlobalIntValue"] == nil and env.hooks["app.SaveDataManager.saveFileGameSaveData"] == nil, "only the ticked option is hooked")

    -- the breadcrumb: written before the arguments are read, and again when the call has been dealt with
    local stages = {}
    local real_dump = env.G.json.dump_file
    env.G.json.dump_file = function(name, t)
        if name == "re7mp_lastcall.json" then stages[#stages + 1] = t.stage .. " " .. t.call end
        return real_dump(name, t)
    end
    local door_go = make_go("sm9180_Door07A_1WayDoor", vec(0, 0, 0))
    local door = Obj.new("app.DoorPush", { get_GameObject = function() return door_go end })
    env.hooks["app.DoorPush.playClosed"]({ 0, door })
    check(stages[1] == "enter app.DoorPush.playClosed()" and stages[2] == "done app.DoorPush.playClosed()" and #stages == 2,
        "a traced call writes 'enter' then 'done' to the breadcrumb file: " .. table.concat(stages, " | "))
    check(log_has(env, "app.DoorPush.playClosed()  [on sm9180_Door07A_1WayDoor]"), "...and the log says which door it was")
    local crumb = env.files["re7mp_lastcall.json"]
    check(crumb and crumb.stage == "done" and crumb.call == "app.DoorPush.playClosed()" and crumb.session == 1700000000, "the breadcrumb file names the last call")
    -- the arguments are read AFTER 'enter' was written: a crash while reading one leaves 'enter' behind
    local stage_while_reading
    local sobj = Obj.new("System.String", { ["ToString()"] = function() stage_while_reading = env.files["re7mp_lastcall.json"].stage return "CanOpenMap" end })
    -- (a call beyond the third within a second is only counted and writes nothing)
    stages = {}
    for _ = 1, 6 do env.hooks["app.DoorPush.lockDoor"]({ 0, door }) end
    check(#stages == 6, "three calls a second per method are logged (enter + done each); the rest are only counted: " .. #stages)

    -- an object argument that is not in a register is never opened (it reads as garbage; opening garbage can crash the game)
    env.check_override["    9+ also trace story flags and chapter jumps (app.GameManager)##xflags"] = true
    run_ui(env)
    env.ui_press[BTN9] = true
    run_ui(env)
    check(env.hooks["app.GameManager.chapterJumpRequest"] ~= nil and env.hooks["app.GameManager.setFsmGlobalIntValue"] ~= nil
        and env.hooks["app.GameManager.getFsmGlobalBoolValue"] == nil and env.hooks["app.GameManager.isPause"] == nil
        and env.hooks["app.GameManager.getGameRank"] == nil, "the flags option hooks the setters and chapter jumps, not the getters")
    local opened_late = false
    local late = Obj.new("System.String", { ["ToString()"] = function() opened_late = true return "garbage" end })
    local gm_obj = Obj.new("app.GameManager", {})
    env.hooks["app.GameManager.chapterJumpRequest"]({ 0, gm_obj, sobj, 1, late })
    check(not opened_late and stage_while_reading == "enter", "the third parameter (past the registers) is not opened, and 'enter' was already written when the first was read")
    check(log_has(env, 'chapterJumpRequest("CanOpenMap", true, <System.String: not readable>)'), "...the log says it was not readable: ")

    -- values past the registers carry a '?'
    local line_count_before = #env.log
    env.hooks["app.DoorPush.setInteract"]({ 0, door, door_go, 1, 0 })
    check(log_has(env, "setInteract(GameObject(sm9180_Door07A_1WayDoor), true, false?)"), "a value read from past the registers is marked with a '?'")

    -- the UI flags the game sets hundreds of times a second are logged only when they change
    local function flag(value) env.hooks["app.GameManager.setFsmGlobalBoolValue"]({ 0, gm_obj, sobj, value }) end
    local function flag_lines()
        local n = 0
        for _, l in ipairs(env.log) do if l:find('setFsmGlobalBoolValue("CanOpenMap"', 1, true) then n = n + 1 end end
        return n
    end
    local before = flag_lines()
    for _ = 1, 500 do flag(1) end
    check(flag_lines() == before + 1, "500 identical flag calls are logged once: " .. (flag_lines() - before))
    flag(0)
    flag(1)
    check(flag_lines() == before + 3, "...and a change is logged again")
    check(not log_has(env, "setFsmGlobalBoolValue: fires"), "...without the method being muted as 'too hot'")

    -- the saves option is hand-picked too
    env.check_override["    9+ also trace save and load calls (app.SaveDataManager)##xsaves"] = true
    run_ui(env)
    env.ui_press[BTN9] = true
    run_ui(env)
    check(env.hooks["app.SaveDataManager.saveFileGameSaveData"] ~= nil and env.hooks["app.SaveDataManager.loadFileAutoRequest"] ~= nil
        and env.hooks["app.SaveDataManager.isExistData"] == nil and env.hooks["app.SaveDataManager.saveFileSomethingElse"] == nil
        and env.hooks["app.SaveDataManager.loadFileOther"] == nil, "the saves option hooks the two calls that name a slot, not every method with 'savefile' in its name")

    -- the receive-path self tests
    calls = {}
    env.ui_press["Test: receive 1 Herb as if Bob gave it"] = true
    run_ui(env)
    check(calls_have("Inventory.addItem Herb x1"), "the receive self-test puts a Herb in my inventory")
    calls = {}
    env.ui_press["Test: a Herb that Bob dropped appears at my feet"] = true
    run_ui(env)
    check(calls_have("ItemManager.createDropItemInstance Herb 1"), "the drop self-test spawns a Herb")
end

-- death mode 1 (Independent): nothing is held; downed mode with nobody connected: nothing is held either
do
    local function hit(env, new_hp)
        local hi = env.player_hi
        env.hooks["app.HealthInfo.set_health"]({ 0, hi })
        hi.f._CurrentHealth = new_hp
        env.posthooks["app.HealthInfo.set_health"](nil)
    end
    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "host", "tcp")
    for i = 1, 30 do run_frames(env, 0.05) bump_remote(env) end
    hit(env, 0)
    for i = 1, 6 do run_frames(env, 0.05) bump_remote(env) end
    check(env.player_hi.f._CurrentHealth == 0, "death mode Independent: a lethal hit is left alone")

    local env2 = new_environment()
    build_world(env2)
    env2.files["re7mp_settings.json"] = { death_mode = 4 }
    load_script(env2)
    run_frames(env2, 3.0) -- nobody connected
    hit(env2, 0)
    run_frames(env2, 0.5)
    check(env2.player_hi.f._CurrentHealth == 0, "downed mode without the other player: the game ends as normal (nobody could revive you)")

    -- team wipe: I am down, the other player dies for real -> I die too; if I am not down nothing happens
    local env3 = new_environment()
    build_world(env3)
    env3.files["re7mp_settings.json"] = { death_mode = 4 }
    load_script(env3)
    host_role_files(env3, "host", "tcp")
    for i = 1, 30 do run_frames(env3, 0.05) bump_remote(env3) end
    push_msgs(env3, { { 4, "died" } })
    for i = 1, 6 do run_frames(env3, 0.05) bump_remote(env3) end
    run_ui(env3)
    check(ui_has(env3, "died (you are not down, so nothing happens to you)"), "their death does nothing to me when I am not down")
    hit(env3, 0)
    for i = 1, 8 do run_frames(env3, 0.05) bump_remote(env3) end
    push_msgs(env3, { { 4, "died" } })
    for i = 1, 6 do run_frames(env3, 0.05) bump_remote(env3) end
    run_ui(env3)
    check(ui_has(env3, "died while you were down: you die too"), "their death while I am down kills me too (team wipe)")
    hit(env3, 0) -- the game's own death arrives: the hold must not write 1 back (a debug file showed it fighting for six seconds)
    for i = 1, 8 do run_frames(env3, 0.05) bump_remote(env3) end
    check(env3.player_hi.f._CurrentHealth == 0, "after a team wipe the hold is released: the death is not undone")
end


-- reloads and loading screens: the down state does not outlive the player object, and a health of 0 while loading is not a death
do
    local function hit(env, new_hp)
        local hi = env.player_hi
        env.hooks["app.HealthInfo.set_health"]({ 0, hi })
        hi.f._CurrentHealth = new_hp
        env.posthooks["app.HealthInfo.set_health"](nil)
    end
    local function connected(env, frames)
        for i = 1, frames do run_frames(env, 0.05) bump_remote(env) end
    end
    local env = new_environment()
    build_world(env)
    env.files["re7mp_settings.json"] = { death_mode = 4 }
    load_script(env)
    host_role_files(env, "host", "tcp")
    connected(env, 30)
    hit(env, 0)
    connected(env, 10)
    run_ui(env)
    check(ui_has(env, "YOU ARE DOWN: waiting for Bob"), "reload test: down first")
    env.player.addr = 0x99999 -- the game reloaded: a different player object
    connected(env, 80)
    run_ui(env)
    check(not ui_has(env, "YOU ARE DOWN: waiting for Bob"), "a new player object clears the down state")
    check(ui_has(env, "down state cleared"), "...and the panel says so")

    -- a health of 0 before the player was ever seen alive (loading screen) is not a death
    local env2 = new_environment()
    build_world(env2)
    env2.files["re7mp_settings.json"] = { death_mode = 4 }
    env2.player_hi.f._CurrentHealth = 0
    load_script(env2)
    host_role_files(env2, "host", "tcp")
    connected(env2, 40)
    run_ui(env2)
    check(not ui_has(env2, "YOU ARE DOWN: waiting for Bob") and env2.player_hi.f._CurrentHealth == 0, "0 health before the player was seen alive is left alone")
    env2.player_hi.f._CurrentHealth = 500
    connected(env2, 6)
    env2.player_hi.f._CurrentHealth = 0 -- no hook call: the game changed the field some other way
    connected(env2, 6)
    run_ui(env2)
    check(ui_has(env2, "YOU ARE DOWN: waiting for Bob") and env2.player_hi.f._CurrentHealth == 1, "the 10 Hz check catches a lethal drop the hook missed")
    -- a rise of 1 (the hold fighting the game's death sequence, seen 65 times in a debug file) is not a heal; a real one still is
    local env4 = new_environment()
    build_world(env4)
    env4.files["re7mp_settings.json"] = { death_mode = 4 }
    load_script(env4)
    host_role_files(env4, "host", "tcp")
    connected(env4, 30)
    local hp0 = env4.player_hi.f._CurrentHealth
    env4.player_hi.f._CurrentHealth = hp0 - 100
    connected(env4, 4)
    env4.player_hi.f._CurrentHealth = hp0 - 99
    connected(env4, 4)
    run_frames(env4, 3)
    check(env4.files["re7mp_debug.json"] and env4.files["re7mp_debug.json"].health.heals_seen == 0, "a rise of 1 is not counted as a heal")
    env4.player_hi.f._CurrentHealth = hp0 + 200
    connected(env4, 4)
    run_frames(env4, 3)
    check(env4.files["re7mp_debug.json"].health.heals_seen == 1, "...but a rise of a few hundred is")
    run_frames(env2, 3)
    local dbgf = env2.files["re7mp_debug.json"]
    check(dbgf ~= nil and dbgf.health ~= nil and dbgf.health.read_from == "app.PlayerDamageController.HealthInfo._CurrentHealth"
        and dbgf.health.death_mode == 4 and dbgf.health.held_at_1 >= 1, "the debug file carries a health summary")
end


-- =============================================================================================
-- Scenario 9: release number and the version check between the two players
-- =============================================================================================
do
    local function connected(env, frames)
        for i = 1, frames do run_frames(env, 0.05) bump_remote(env) end
    end
    local function ver_msgs(env) return messages_of_kind(env, 8) end

    -- same release on both sides
    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "host", "tcp")
    connected(env, 30)
    check(ver_msgs(env)[1] == "v|0.7|9.15|0.7|6", "the script introduces its release when the other player appears: " .. tostring(ver_msgs(env)[1]))
    push_msgs(env, { { 8, "v|0.7|9.15|0.7|6" } })
    connected(env, 10)
    run_ui(env)
    check(ui_has(env, "Release v0.7   (script build 9.15, re7mp.exe v0.7)"), "the panel shows the release, build and exe version")
    check(ui_has(env, "Bob runs release v0.7 (script build 9.15, re7mp.exe v0.7)"), "...and the other player's version")
    check(not ui_has(env, "update so you both run the same version"), "same release: no warning")
    local nversions = #ver_msgs(env)
    connected(env, 440) -- 22 s: it is sent again (the other script may have been reloaded)
    check(#ver_msgs(env) > nversions, "the version is re-sent about every 20 s")
    run_frames(env, 3)
    local dbg = env.files["re7mp_debug.json"]
    check(dbg and dbg.release == "0.7" and dbg.build == "9.15" and dbg.exe == "0.7" and dbg.exe_protocol == 6
        and dbg.other_player_version and dbg.other_player_version:find("v0.7", 1, true), "the debug file carries the versions")

    -- the other player is on another release
    push_msgs(env, { { 8, "v|0.5|9.1|0.5|6" } })
    connected(env, 10)
    run_ui(env)
    check(ui_has(env, "Bob is on release v0.5 but you are on v0.7: update so you both run the same version"), "a different release is flagged in the panel")
    check(log_has(env, "version: Bob runs release v0.5"), "...and logged")

    -- an older script sends nothing: flagged after 8 s
    local env2 = new_environment()
    build_world(env2)
    load_script(env2)
    host_role_files(env2, "host", "tcp")
    connected(env2, 100) -- 5 s
    run_ui(env2)
    check(not ui_has(env2, "older than release"), "not flagged straight away")
    connected(env2, 100) -- 10 s
    run_ui(env2)
    check(ui_has(env2, "Bob's script is older than release v0.7"), "no version after 8 s means an older script")

    -- the loopback bot is not a script: never flagged
    local env3 = new_environment()
    build_world(env3)
    load_script(env3)
    host_role_files(env3, "host", "tcp")
    env3.files["re7mp_in.json"].name = "Loopback Bot"
    connected(env3, 260)
    run_ui(env3)
    check(not ui_has(env3, "older than release"), "the loopback bot is never reported as an old script")

    -- ---- 9.13: the loopback bot can go down, so a revive can be tried alone ----
    run_ui(env3)
    check(ui_has(env3, "The loopback bot can go down: walk within 3 m of it and press F8, then stay put for 3 s"), "the panel explains the bot buttons when the other player is the loopback bot")
    env3.ui_press["Loopback bot: make it go down"] = true
    run_ui(env3)
    connected(env3, 4)
    check(#messages_of_kind(env3, 11) == 1 and messages_of_kind(env3, 11)[1] == "down", "'make it go down' sends the bot command (kind 11): " .. table.concat(messages_of_kind(env3, 11), ","))
    env3.ui_press["Loopback bot: make it get up"] = true
    run_ui(env3)
    connected(env3, 4)
    local bm = messages_of_kind(env3, 11)
    check(#bm == 2 and bm[2] == "up", "'make it get up' sends 'up': " .. table.concat(bm, ","))
    -- what the bot sends back is understood: its exact strings (the C++ suite checks they are what the engine sends)
    env3.files["re7mp_in.json"].x, env3.files["re7mp_in.json"].z = 2, 3
    push_msgs(env3, { { 7, "e|down||1.00|2.00|3.00" } })
    env3.texts = {}
    connected(env3, 6)
    check(texts_have(env3, "Loopback Bot [downed]"), "the bot's down event marks it [downed]")
    push_msgs(env3, { { 7, "h|1|1000|1" } })
    connected(env3, 4)
    env3.texts = {}
    connected(env3, 6)
    check(texts_have(env3, "Loopback Bot [downed]"), "...and its once-a-second health report keeps it down")
    push_msgs(env3, { { 7, "e|up||1.00|2.00|3.00" } })
    connected(env3, 4)
    push_msgs(env3, { { 7, "h|1000|1000|0" } })
    env3.texts = {}
    connected(env3, 6)
    check(not texts_have(env3, "[downed]"), "the bot getting up clears the tag")
    -- a real player's panel has no bot buttons
    local envb = new_environment()
    build_world(envb)
    load_script(envb)
    host_role_files(envb, "host", "tcp")
    connected(envb, 260)
    run_ui(envb)
    check(not ui_has(envb, "The loopback bot can go down"), "with a real player the bot buttons are not shown")
    envb.ui_press["Loopback bot: make it go down"] = true
    run_ui(envb)
    check(#messages_of_kind(envb, 11) == 0, "...and nothing is sent to a real player")

    -- the exe and the script disagree
    local env4 = new_environment()
    build_world(env4)
    load_script(env4)
    host_role_files(env4, "host", "tcp")
    env4.files["re7mp_in.json"].exe = "0.5"
    connected(env4, 20)
    run_ui(env4)
    check(ui_has(env4, "re7mp.exe is v0.5 but this script is v0.7"), "an exe from another release than the script is flagged")
    check(ui_has(env4, "script build 9.15, re7mp.exe v0.5"), "...with both versions shown")

    -- the file of an exe that is NOT running (an older release's leftover, never rewritten) is not taken for the exe's version
    local env5 = new_environment()
    build_world(env5)
    load_script(env5)
    host_role_files(env5, "host", "tcp")
    env5.files["re7mp_in.json"].exe = "0.6"
    run_frames(env5, 8) -- the file never changes: nothing is running that rewrites it
    run_ui(env5)
    check(not ui_has(env5, "re7mp.exe is v0.6"), "a leftover file from an exe that is not running does not raise a version warning")
    check(not ui_has(env5, "re7mp.exe v0.6"), "...nor is its release shown as the exe's")
    -- the old exe is started: now it is real, and flagged
    connected(env5, 20)
    run_ui(env5)
    check(ui_has(env5, "re7mp.exe is v0.6 but this script is v0.7"), "an exe that is running and older than the script is flagged")
    -- ...and the warning goes away once the exe is updated and restarted (it used to stay up for the rest of the session)
    env5.files["re7mp_in.json"].exe = "0.7"
    connected(env5, 20)
    run_ui(env5)
    check(not ui_has(env5, "re7mp.exe is v0.6"), "the warning goes away when the exe reports the same release as the script")
    check(ui_has(env5, "script build 9.15, re7mp.exe v0.7"), "...and the panel shows the new exe release")

    -- the first introduction waits for the exe's release, so the other player is not told "re7mp.exe v?"
    check(ver_msgs(env5)[1] and not ver_msgs(env5)[1]:find("|?|", 1, true), "the first version message carries the exe's release: " .. tostring(ver_msgs(env5)[1]))

    -- an exe too old to write its release into the file: the introduction is not held back for ever
    local env6 = new_environment()
    build_world(env6)
    load_script(env6)
    host_role_files(env6, "host", "tcp")
    env6.files["re7mp_in.json"].exe = nil
    env6.files["re7mp_in.json"].proto = nil
    connected(env6, 20) -- 1 s
    check(ver_msgs(env6)[1] == nil, "the introduction waits a moment for the exe's release")
    connected(env6, 60) -- 4 s
    check(ver_msgs(env6)[1] == "v|0.7|9.15|?|?", "...but not for ever: it goes out with '?' when the exe never says: " .. tostring(ver_msgs(env6)[1]))

    -- garbage in a version message does nothing
    push_msgs(env4, { { 8, "v|nonsense" }, { 8, "hello" } })
    connected(env4, 10)
    run_ui(env4)
    check(not ui_has(env4, "runs release"), "malformed version messages are ignored")
end


-- =============================================================================================
-- Scenario 10: [CO-OP: name] labels in the Load screen, and the scan that records the screen.
-- The screen is rebuilt control by control from a real scan of RE7's SaveMenuGUI (tests/data/save_menu_scan.txt):
-- nine recycled rows (item8 .. item1 and selectitem) with m_objective, m_number ("1" .. "8", "Autosave") and more.
-- =============================================================================================
do
    local fixture_path = (os.getenv("RE7MP_TEST_DATA") or "tests/data") .. "/save_menu_scan.txt"
    local fh = assert(io.open(fixture_path, "r"), "missing " .. fixture_path)
    local fixture = fh:read("*a")
    fh:close()

    -- Returns the GUI and handles to its texts: texts[row name][control name] = { v = "..." }, plus open.v for the menu being shown.
    local function build_screen(env, go_name, rename_number)
        local open = { v = true }
        local texts, stack, root, current = {}, {}, nil, nil
        for line in fixture:gmatch("[^\r\n]+") do
            local indent, name, typ, rest = line:match("^(%s*)(%S+) : (%S+)(.*)$")
            local depth = #indent / 2 - 1
            local hidden = rest:find("^ %(hidden%)") ~= nil
            local text = rest:match('"(.*)"$')
            if rename_number and name == "m_number" then name = "m_slot" end
            local kids = {}
            local ctl = Obj.new(typ, {})
            ctl.m.get_Name = function() return name end
            ctl.m.get_Visible = function() return (not hidden) and (depth > 0 or open.v) end
            ctl.m.get_Child = function() return kids[1] end
            ctl.m.get_Next = function(self) return self._next end
            ctl.kids = kids
            if typ == "via.gui.SelectItem" then current = name texts[name] = {} end
            if typ == "via.gui.Text" and text ~= nil then
                local holder = { v = text }
                ctl.m.get_Message = function() return holder.v end
                ctl.m.set_Message = function(_, v) holder.v = v end
                if current then texts[current][name] = holder end
            end
            stack[depth + 1] = ctl
            if depth == 0 then
                root = ctl
            else
                local parent = stack[depth]
                if #parent.kids > 0 then parent.kids[#parent.kids]._next = ctl end
                parent.kids[#parent.kids + 1] = ctl
            end
        end
        local view = Obj.new("via.gui.View", { get_RootWindow = function() return root end })
        local gui, go
        gui = Obj.new("via.gui.GUI", { get_GameObject = function() return go end, get_View = function() return view end })
        go = make_go(go_name, vec(0, 0, 0), go_name == "SaveMenuGUI" and { gui, Obj.new("app.SaveMenu", {}) } or { gui })
        env.guis = env.guis or {}
        env.guis[#env.guis + 1] = gui
        env.scene.m["findComponents(System.Type)"] = function(_, t)
            return { get_elements = function() return t == "via.gui.GUI" and env.guis or {} end }
        end
        return texts, open
    end
    local STEAM_DIR = "C:\\Program Files (x86)\\Steam\\userdata\\759758082\\418370\\remote\\win64_save"
    local function coop_files(env, occupied, slots, dir)
        slots = slots or { sent = 3, received = 7 }
        env.files["re7mp_coop_saves.json"] = { enabled = true, last = "", occupied = occupied, dir = dir or STEAM_DIR, entries = {
            { slot = slots.sent, role = "sent", partner = "Bob", tag = "[CO-OP: sent to Bob]", label = "CO-OP Me 2026-11-07 12:00", from = "Me" },
            { slot = slots.received, role = "received", partner = "Bob", tag = "[CO-OP: Bob]", label = "CO-OP Bob 2026-11-07 12:30", from = "Bob",
              from_slot = 10, why = "slot 10 here holds a save of your own, so it went into the lowest free slot" } } }
    end
    local function start(occupied, settings, opts)
        opts = opts or {}
        local env = new_environment()
        build_world(env)
        env.files["re7mp_settings.json"] = settings
        coop_files(env, occupied, opts.slots, opts.dir)
        if opts.no_tags then for _, e in ipairs(env.files["re7mp_coop_saves.json"].entries) do e.tag = nil end end
        -- the game's own answer to "does a save exist in slot n" (0 is the Autosave); by default the game has the same saves as the folder
        local game = opts.game or { 0, 1, 2, 3, 4, 5, 6, 7, 8 }
        if not opts.no_game then
            env.singletons["app.SaveDataManager"] = Obj.new("app.SaveDataManager", { isExistData = function(_, n)
                if opts.game_error then error("isExistData: no such method") end
                for _, g in ipairs(game) do if g == n then return true end end
                return false
            end })
        end
        local texts, open = build_screen(env, opts.go_name or "SaveMenuGUI", opts.rename_number)
        if opts.closed then open.v = false end
        load_script(env)
        return env, texts, open
    end
    local ALL = { 1, 2, 3, 4, 5, 6, 7, 8 } -- the manual saves re7mp.exe lists (the Autosave, data000.bin, is not one of them)

    -- off by default: nothing is touched
    local env, t = start(ALL, nil)
    run_frames(env, 4)
    check(t.item3.m_objective.v == "Escape from the house" and t.item7.m_objective.v == "Head to the attic", "labels are off by default: the Load screen is untouched")

    -- on: the objective of the co-op rows (slots 3 and 7) gets the tag; the other rows, the Autosave row, the hidden row and every other text do not
    env, t = start(ALL, { label_loadmenu = true })
    run_frames(env, 2)
    check(t.item3.m_objective.v == "[CO-OP: sent to Bob] Escape from the house", "slot 3 (sent by you) says it was sent to the player, not that it is theirs: " .. t.item3.m_objective.v)
    check(t.item7.m_objective.v == "[CO-OP: Bob] Head to the attic", "slot 7 (received) is labelled too: " .. t.item7.m_objective.v)
    check(t.item1.m_objective.v == "Get 3 dog heads and open the door to the yard" and t.item4.m_objective.v == "Get 3 dog heads and open the door to the yard"
        and t.item6.m_objective.v == "Search the old house for the serum", "single-player saves are not labelled")
    check(t.selectitem.m_objective.v == "Get 3 dog heads and open the door to the yard" and t.item8.m_objective.v == "Head to the attic", "the Autosave row and the hidden row are left alone")
    check(t.item3.m_place.v == "Main House 1F" and t.item3.m_number.v == "3" and t.item3.m_day.v == "11/06/2026 03:24:48", "only the objective text changes")
    run_frames(env, 2)
    check(t.item3.m_objective.v:find("%[CO%-OP: Bob%] %[CO%-OP") == nil, "a label is written once, not stacked")
    run_ui(env)
    check(ui_has(env, "Load list found: 9 rows, row N is dataNNNSlot.bin; the game's saves match re7mp.exe's"), "the panel says the list was found, how rows map to files, and that the game agrees with the exe")
    check(ui_has(env, "slot 003   [CO-OP: sent to Bob]   (you saved it)") and ui_has(env, "slot 007   [CO-OP: Bob]   (received)"), "the panel lists co-op saves with the player's name")
    check(ui_has(env, "Bob's slot 10 -> your slot 7: slot 10 here holds a save of your own, so it went into the lowest free slot"), "...and where a received save came from and why it is in that slot")
    check(ui_has(env, "the game lists this slot: Load Game shows it as slot 7"), "...and that the game itself lists the slot")
    check(env.files["re7mp_settings.json"] and env.files["re7mp_settings.json"].label_loadmenu == true, "the label setting is saved")

    -- the game scrolls the list: it re-uses the row controls and writes other saves into them
    t.item3.m_number.v, t.item3.m_objective.v = "5", "[CO-OP: sent to Bob] Escape from the house" -- row now shows slot 5, still carrying the old label
    run_frames(env, 0.4)
    check(t.item3.m_objective.v == "Escape from the house", "a recycled row that now shows a single-player save loses the old label")
    t.item2.m_number.v, t.item2.m_objective.v = "7", "Head to the attic" -- the game puts slot 7 into another row control
    run_frames(env, 0.4)
    check(t.item2.m_objective.v == "[CO-OP: Bob] Head to the attic", "...and a row that now shows a co-op slot gets the label, whichever control it is")
    t.item7.m_objective.v = "Head to the attic" -- the game redraws a row
    run_frames(env, 0.4)
    check(t.item7.m_objective.v == "[CO-OP: Bob] Head to the attic", "a redrawn row is labelled again within a moment")

    -- an exe that sends no tag: the script makes the same ones (a save you sent says so; it never carries his name as if it were his)
    env, t = start(ALL, { label_loadmenu = true }, { no_tags = true })
    run_frames(env, 2)
    check(t.item3.m_objective.v == "[CO-OP: sent to Bob] Escape from the house" and t.item7.m_objective.v == "[CO-OP: Bob] Head to the attic", "without a tag from the exe: sent -> 'sent to Bob', received -> 'Bob'")

    -- the file is in the folder but the game does not list the slot: the panel and the file say so
    local gl = { 0, 1, 2, 3, 4, 5, 6, 8 }
    env, t = start(ALL, { label_loadmenu = true }, { game = gl })
    run_frames(env, 2)
    run_ui(env)
    check(ui_has(env, "THE GAME DOES NOT LIST THIS SLOT") and not ui_has(env, "the game lists this slot"), "a received slot the game does not list is flagged in the panel")
    env.ui_press["Hide them for 60 s"] = true
    run_ui(env)
    run_frames(env, 2.3)
    do
        local cs = env.files["re7mp_debug.json"] and env.files["re7mp_debug.json"].health and env.files["re7mp_debug.json"].health.coop_saves
        local rec
        for _, e in ipairs(cs and cs.entries or {}) do if e.role == "received" then rec = e end end
        check(cs and rec and rec.game_lists_the_slot == false and rec.from_slot == 10 and rec.slot == 7 and #cs.game_says_slots_exist == 7,
            "the debug file lists each co-op save with where it came from, why it is where it is, and whether the game lists the slot")
    end
    gl[#gl + 1] = 7 -- the game lists it a moment later
    run_frames(env, 3)
    run_ui(env)
    check(ui_has(env, "the game lists this slot") and not ui_has(env, "THE GAME DOES NOT LIST THIS SLOT"), "...and when the game lists the slot a little later the panel follows (the question is asked again)")

    -- the exe watches another Steam account's folder: the game lists slots 1-8 but the exe sees 1, 3, 7. Nothing is written.
    env, t = start({ 1, 3, 7 }, { label_loadmenu = true }, { dir = "C:\\Program Files (x86)\\Steam\\userdata\\1055164497\\418370\\remote\\win64_save" })
    run_frames(env, 2)
    check(t.item3.m_objective.v == "Escape from the house" and t.item7.m_objective.v == "Head to the attic", "the exe is watching another account's saves: nothing is labelled")
    run_ui(env)
    check(ui_has(env, "The game has saves in slots 1-8 but re7mp.exe is watching a folder with slots 1, 3, 7 (Steam account 1055164497)"), "...and the panel names both lists and the account")
    check(ui_has(env, "set 'Save folder' in re7mp.exe"), "...and says what to do")

    -- a save was just made: the game has slot 8, the exe has not seen it yet. One slot of difference is fine.
    env, t = start({ 1, 2, 3, 4, 5, 6, 7 }, { label_loadmenu = true })
    run_frames(env, 2)
    check(t.item3.m_objective.v == "[CO-OP: sent to Bob] Escape from the house", "one slot of difference (a save just made) still labels")
    run_ui(env)
    check(ui_has(env, "a save was just added or removed"), "...and the panel mentions it")

    -- the game has only the Autosave but the exe lists saves: not the same account
    env, t = start({ 1, 2, 3 }, { label_loadmenu = true }, { game = { 0 } })
    run_frames(env, 2)
    run_ui(env)
    check(t.item3.m_objective.v == "Escape from the house" and ui_has(env, "The game has saves in slots none but"), "no saves in the game, saves in the folder: nothing labelled")

    -- the game can't be asked (no SaveDataManager, or isExistData fails): labels are written, the panel says it did not check
    env, t = start(ALL, { label_loadmenu = true }, { no_game = true })
    run_frames(env, 2)
    run_ui(env)
    check(t.item3.m_objective.v == "[CO-OP: sent to Bob] Escape from the house" and ui_has(env, "could not be asked which saves exist"), "no SaveDataManager: labelled, with a note that it was not checked")
    env, t = start(ALL, { label_loadmenu = true }, { game_error = true })
    run_frames(env, 2)
    check(t.item3.m_objective.v == "[CO-OP: sent to Bob] Escape from the house", "isExistData failing: labelled, not checked")

    -- the exe's folder is the Autosave only (a fresh install): there are no co-op saves to label, and no error
    env, t = start({}, { label_loadmenu = true })
    env.files["re7mp_coop_saves.json"].entries = {}
    run_frames(env, 2)
    run_ui(env)
    check(ui_has(env, "No co-op saves yet"), "no co-op saves: nothing to label")

    -- old settings files that still carry the removed numbering choice are fine
    env, t = start(ALL, { label_loadmenu = true, label_numbering = 3 })
    run_frames(env, 2)
    check(t.item3.m_objective.v == "[CO-OP: sent to Bob] Escape from the house" and t.item4.m_objective.v == "Get 3 dog heads and open the door to the yard",
        "an old label_numbering setting is ignored: row N is always dataNNNSlot.bin")

    -- the exe has not listed the save files (Share saves is off)
    env, t = start({}, { label_loadmenu = true })
    run_frames(env, 2)
    run_ui(env)
    check(t.item3.m_objective.v == "Escape from the house" and ui_has(env, "has not listed the save files yet"), "no file list from the exe: nothing labelled, and the panel says why")

    -- a list whose rows show no slot number can't be matched
    env, t = start(ALL, { label_loadmenu = true }, { rename_number = true })
    run_frames(env, 2)
    run_ui(env)
    check(t.item3.m_objective.v == "Escape from the house" and ui_has(env, "don't show a slot number"), "rows without a slot number: nothing labelled, and the panel says so")

    -- the Load screen is not showing: nothing is walked or written
    env, t = start(ALL, { label_loadmenu = true }, { closed = true })
    run_frames(env, 2)
    run_ui(env)
    check(t.item3.m_objective.v == "Escape from the house" and ui_has(env, "no save/load screen is open"), "a closed menu is left alone")

    -- a GUI that is not a save/load screen is never touched
    env, t = start(ALL, { label_loadmenu = true }, { go_name = "GUI_PauseMenu" })
    run_frames(env, 2)
    check(t.item3.m_objective.v == "Escape from the house", "other menus are left alone")
    run_ui(env)
    check(ui_has(env, "no save/load screen is open"), "...and the panel says it is waiting")

    -- the game refuses to list its GUIs: say so instead of waiting forever
    env, t = start(ALL, { label_loadmenu = true })
    env.scene.m["findComponents(System.Type)"] = function() error("no such method") end
    run_frames(env, 2)
    run_ui(env)
    check(ui_has(env, "Can't list the game's GUIs from here") and t.item3.m_objective.v == "Escape from the house", "when the GUIs can't be listed the panel says so")

    -- no GUI at all
    local env5 = new_environment()
    build_world(env5)
    env5.files["re7mp_settings.json"] = { label_loadmenu = true }
    coop_files(env5, ALL)
    env5.scene.m["findComponents(System.Type)"] = function() return { get_elements = function() return {} end } end
    load_script(env5)
    run_frames(env5, 3)
    run_ui(env5)
    check(ui_has(env5, "no save/load screen is open"), "no GUI in the scene: waiting, no error")

    -- the scan (button 10) records the screen and the row <-> file table
    env, t = start(ALL, nil)
    run_frames(env, 2) -- the script reads the co-op file once a second
    env.ui_press["10. Load screen scan (open the Load Game screen first, then press)"] = true
    run_ui(env)
    run_frames(env, 3)
    local pinned = table.concat((env.files["re7mp_debug.json"] or {}).pinned or {}, "\n")
    check(pinned:find("=== load screen scan done ===", 1, true) ~= nil, "the scan finishes")
    check(pinned:find("manual saves in the folder re7mp.exe watches (dataNNNSlot.bin): 1, 2, 3, 4, 5, 6, 7, 8", 1, true) ~= nil, "the scan lists the manual save files")
    check(pinned:find("that folder: C:\\Program Files (x86)\\Steam\\userdata\\759758082", 1, true) ~= nil, "...the folder it watches")
    check(pinned:find("manual saves the game says exist (SaveDataManager.isExistData): 1, 2, 3, 4, 5, 6, 7, 8", 1, true) ~= nil
        and pinned:find("check: the game's saves match re7mp.exe's", 1, true) ~= nil, "...what the game says exists, and that the two agree")
    check(pinned:find("co-op slot 3  sent  [CO-OP: sent to Bob]", 1, true) ~= nil and pinned:find("co-op slot 7  received", 1, true) ~= nil, "...and the co-op slots")
    check(pinned:find("<- looks like a save/load screen", 1, true) ~= nil and pinned:find("controls of SaveMenuGUI (119 shown):", 1, true) ~= nil, "...and the GUI that looks like the Load screen, all 119 controls")
    check(pinned:find('m_objective : via.gui.Text  "Escape from the house"', 1, true) ~= nil, "...with their texts")
    check(pinned:find("-> list found: 9 identical rows under node", 1, true) ~= nil, "...and the list of nine rows the first scan could not find")
    check(pinned:find('row item3: number "3" -> data003Slot.bin  CO-OP [CO-OP: sent to Bob]', 1, true) ~= nil
        and pinned:find('row item8 (hidden): number "8" -> data008Slot.bin', 1, true) ~= nil
        and pinned:find('row selectitem: number "Autosave" -> data000.bin (the Autosave: never shared, never labelled)', 1, true) ~= nil, "...and every row with the file it stands for")
    check(pinned:find("app.SaveMenu: not found", 1, true) ~= nil, "...and which candidate types exist")
    check(t.item3.m_objective.v == "Escape from the house", "scanning does not change the screen")

    -- the scan of a mismatch says so in a line that is easy to find
    env, t = start({ 1, 3, 7 }, nil)
    run_frames(env, 2)
    env.ui_press["10. Load screen scan (open the Load Game screen first, then press)"] = true
    run_ui(env)
    run_frames(env, 3)
    pinned = table.concat((env.files["re7mp_debug.json"] or {}).pinned or {}, "\n")
    check(pinned:find("MISMATCH: The game has saves in slots 1-8 but re7mp.exe is watching a folder with slots 1, 3, 7", 1, true) ~= nil, "a scan of the wrong folder prints a MISMATCH line")
end

-- =============================================================================================
-- The breadcrumb file of the previous session (what the trace was doing when the game stopped)
-- =============================================================================================
do
    local function start_with(crumb)
        local env = new_environment()
        build_world(env)
        env.files["re7mp_lastcall.json"] = crumb
        load_script(env)
        run_frames(env, 1)
        run_ui(env)
        return env
    end
    local env = start_with({ stage = "enter", call = "app.DoorPush.playAutoClose(System.Single,System.Int32,System.Boolean)", session = 1699990000, time = 1700000000 - 300 })
    check(log_has(env, "previous session: The last session ended while the trace was reading the arguments of app.DoorPush.playAutoClose(System.Single,System.Int32,System.Boolean) (5 min ago). If the game crashed, that call is the suspect."),
        "'enter' in the last breadcrumb: the call is named as the suspect")
    run_ui(env)
    check(ui_has(env, "reading the arguments of app.DoorPush.playAutoClose"), "...and the panel repeats it under button 9")
    env = start_with({ stage = "hooking", call = "app.DoorPush.setInteract", session = 1699990000, time = 1700000000 })
    check(log_has(env, "installing its hook on app.DoorPush.setInteract"), "'hooking': the hook is named")
    env = start_with({ stage = "done", call = "app.DoorPush.playClosed()", session = 1699990000, time = 1700000000 })
    check(log_has(env, "it had finished"), "'done': the call is named as finished")
    env = start_with({ stage = "clean", call = "scripts reset", session = 1699990000, time = 1700000000 })
    check(not log_has(env, "previous session:"), "'clean' (the scripts were reset normally): nothing is reported")
    env = start_with({ stage = "enter", call = "x", session = 1700000000, time = 1700000000 })
    check(not log_has(env, "previous session:"), "a breadcrumb of this very session is not 'the previous session'")
    env = new_environment()
    build_world(env)
    load_script(env)
    check(not log_has(env, "previous session:"), "no breadcrumb file: nothing is reported")
    -- resetting the scripts leaves a 'clean' mark
    env.reset_cbs[1]()
    check(env.files["re7mp_lastcall.json"] and env.files["re7mp_lastcall.json"].stage == "clean", "a normal script reset writes 'clean'")
end



-- 9.8: the components the real recordings found on the player: the sequence manager (aim / attack / guard gates), the hands and the gun
-- (action ids). Adds them to an environment's player; the fields are the real names.
function add_pose_components(env)
    make_td("app.PlayerSequenceManager", { fields = { { "IsAimAccepted", "System.Boolean" }, { "IsAttackAccepted", "System.Boolean" },
        { "IsGuardAccepted", "System.Boolean" }, { "IsGuardCancelAccepted", "System.Boolean" } },
        -- (the real type has the update*Track methods and onMotionUpdated, and a getter for each gate; `update`/`lateUpdate` stay
        -- in the mock for builds that have them)
        methods = { update = {}, lateUpdate = {}, requestSequence = { params = { "System.Int32" } },
            updateActionTrack = {}, updateMovementTrack = {}, updateJogTrack = {}, onMotionUpdated = {},
            get_isMoveAccepted = { ret = "System.Boolean" }, get_isAimAccepted = { ret = "System.Boolean" } } })
    make_td("app.PlayerGun", { fields = { { "<actionID>k__BackingField", "System.Int32" } },
        methods = { shoot = {}, reload = {}, tryAttack = { ret = "System.Boolean" }, tryAimStart = { ret = "System.Boolean" },
            trySemiAimStart = { ret = "System.Boolean" }, tryReload = { ret = "System.Boolean" } } })
    make_td("app.PlayerMovement", { fields = { { "IsCrouching", "System.Boolean" }, { "StanceType", "System.Int32" }, { "Speed", "System.Single" } } })
    make_td("app.PlayerHands", { fields = { { "<actionID>k__BackingField", "System.Int32" } } })
    local comps = env.player:call("get_Components"):get_elements()
    env.seq = Obj.new("app.PlayerSequenceManager", {}, { IsAimAccepted = true, IsAttackAccepted = true, IsGuardAccepted = true, IsGuardCancelAccepted = false })
    env.hands = Obj.new("app.PlayerHands", {}, { ["<actionID>k__BackingField"] = 34 })
    env.gun = Obj.new("app.PlayerGun", {}, { ["<actionID>k__BackingField"] = 0 })
    env.move = Obj.new("app.PlayerMovement", {}, { IsCrouching = false, StanceType = 0, Speed = 0 })
    comps[#comps + 1], comps[#comps + 2], comps[#comps + 3], comps[#comps + 4] = env.seq, env.hands, env.gun, env.move
    env.player.addr = env.player.addr or 0x55500
end
-- what the game does while you block (both recordings): the gates close and the cancel flag opens; the reverse when you let go
function set_real_block(env, on)
    env.seq.f.IsGuardCancelAccepted = on
    env.seq.f.IsGuardAccepted, env.seq.f.IsAimAccepted, env.seq.f.IsAttackAccepted = not on, not on, not on
end

-- =============================================================================================
-- Scenario 12 (9.7): the stand-in's block and heal poses, and the pose bits in the flags
-- =============================================================================================
do
    local function str(t) return Obj.new("System.String", { ["ToString()"] = function() return t end }) end
    local function live(env, secs)
        for _ = 1, math.floor(secs / 0.05 + 0.5) do run_frames(env, 0.05) bump_remote(env) end
    end
    local function out_flags(env) return (env.files["re7mp_out.json"] or {}).flags end
    local function bit(flags, b) return math.floor(flags / b) % 2 == 1 end
    -- is a skeleton line ending at this height (metres above the floor)? The mock projects y = 540 - 20 * height
    local function line_at(env, height)
        for _, pt in ipairs(env.line_pts or {}) do
            if math.abs(pt[2] - (540 - height * 20)) < 0.12 then return true end
        end
        return false
    end
    local function skeleton_frame(env)
        env.line_pts = {}
        live(env, 0.1)
    end

    local env = new_environment()
    build_world(env)
    add_pose_components(env)
    env.files["re7mp_settings.json"] = { show_skeleton = true }
    load_script(env)
    host_role_files(env, "host", "tcp")
    live(env, 1.5)
    local HK = "<actionID>k__BackingField"
    local f0 = out_flags(env)
    check(f0 ~= nil and f0 % 64 == 0 and not bit(f0, 64) and not bit(f0, 128), "idle: no pose bits and no ready-check bits: " .. tostring(f0))

    -- my own heal: PlayerHands.actionID 16 then 17 is the heal animation (both recordings), 34 / 0 is rest
    env.hands.f[HK] = 16
    live(env, 0.3)
    check(bit(out_flags(env), 128), "the heal animation (hands action 16) sets the heal pose bit at once, not at the end")
    check(not bit(out_flags(env), 64), "...and not the block bit")
    env.hands.f[HK] = 17
    live(env, 2.0)
    check(bit(out_flags(env), 128), "...and it stays while the animation loops (action 17)")
    run_ui(env)
    check(ui_has(env, "you are sending HEAL"), "the panel says I am sending HEAL")
    env.hands.f[HK] = 34
    live(env, 0.25)
    check(bit(out_flags(env), 128), "a short tail keeps the pose from flickering when the animation ends")
    live(env, 0.6)
    check(not bit(out_flags(env), 128), "...then the heal bit clears")
    -- the item leaves the inventory at the END of the animation: that is not the pose trigger any more
    env.hooks["app.Inventory.reduceItem"]({ 0, env.inventory, str("Herb"), 1, true })
    live(env, 0.5)
    check(not bit(out_flags(env), 128), "using up a Herb sets no pose by itself (the animation does)")
    -- with a gun the hands idle at 0 instead of 34; the heal is the same 16 / 17
    env.hands.f[HK] = 0
    live(env, 0.3)
    check(not bit(out_flags(env), 128), "with a gun, hands action 0 is rest")
    env.hands.f[HK] = 16
    live(env, 0.3)
    check(bit(out_flags(env), 128), "with a gun, the heal is hands action 16 too")
    env.hands.f[HK] = 0
    live(env, 1.0)

    -- my own block: IsGuardCancelAccepted, the same with and without a gun
    check(not bit(out_flags(env), 64), "not blocking: no block bit")
    set_real_block(env, true)
    live(env, 0.3)
    check(bit(out_flags(env), 64), "blocking: IsGuardCancelAccepted sets the block bit")
    check(not bit(out_flags(env), 128), "...and not the heal bit")
    run_ui(env)
    check(ui_has(env, "you are sending BLOCK"), "the panel says I am sending BLOCK")
    set_real_block(env, false)
    live(env, 0.3)
    check(not bit(out_flags(env), 64), "letting go clears the block bit")
    env.gun.f[HK] = 108
    live(env, 0.3)
    check(not bit(out_flags(env), 64), "the gun's own action id is not used while the guard flag can be read")
    env.gun.f[HK] = 0
    -- healing does not touch the guard flag in the recordings, so it must not make a block
    env.hands.f[HK] = 17
    live(env, 0.5)
    check(bit(out_flags(env), 128) and not bit(out_flags(env), 64), "healing alone shows heal only")
    env.hands.f[HK] = 34
    live(env, 1.0)
    -- fallbacks: if the guard flag can't be read the hands / gun action ids are used
    env.seq.f.IsGuardCancelAccepted = nil
    env.hands.f[HK] = 35
    live(env, 0.3)
    check(bit(out_flags(env), 64), "fallback: hands action 35 (raise) is a block when the flag is unreadable")
    env.hands.f[HK] = 37
    live(env, 0.3)
    check(not bit(out_flags(env), 64), "...and 37 (lowering) is not")
    env.hands.f[HK] = 0
    env.gun.f[HK] = 107
    live(env, 0.3)
    check(bit(out_flags(env), 64), "fallback: gun action 107 (raise) is a block with a gun")
    env.gun.f[HK] = 109
    live(env, 0.3)
    check(not bit(out_flags(env), 64), "...and 109 (lowering) is not")
    env.gun.f[HK] = 0
    env.seq.f.IsGuardCancelAccepted = false
    live(env, 0.3)
    env.hands.f[HK] = 34
    live(env, 0.3)

    -- the other player's poses, from their flags
    local function their_flags(f)
        env.files["re7mp_in.json"].flags = f
    end
    env.texts = {}
    live(env, 1.0)
    check(not texts_have(env, "[blocking]") and not texts_have(env, "[healing]"), "no pose label while their flags carry no pose")
    skeleton_frame(env)
    check(not line_at(env, 1.5) and not line_at(env, 1.13), "at rest the hands are at their sides (no hand at face or chest height)")

    their_flags(64)
    env.texts = {}
    live(env, 1.0)
    check(texts_have(env, "Bob [blocking]"), "their block bit shows the stand-in blocking")
    run_ui(env)
    check(ui_has(env, "their stand-in: block 100%, heal 0%"), "the panel shows how far into the pose they are")
    skeleton_frame(env)
    check(line_at(env, 1.5), "blocking: the hands come up to face height")

    their_flags(128)
    live(env, 0.6) -- (the block pose eases out in the first moments)
    env.texts = {}
    live(env, 0.5)
    check(texts_have(env, "Bob [healing]"), "their heal bit shows the stand-in healing")
    check(not texts_have(env, "[blocking]"), "...and not blocking")
    skeleton_frame(env)
    check(line_at(env, 1.13), "healing: the left forearm lies across the chest")
    check(not line_at(env, 1.5), "...and the hands are no longer at face height")

    their_flags(192)
    env.texts = {}
    live(env, 1.0)
    check(texts_have(env, "[healing]") and not texts_have(env, "[blocking]"), "both bits at once: healing wins")

    -- the pose bits do not disturb the ready check: difficulty bits and READY are read as before
    their_flags(64 + 1 + 2)
    live(env, 0.3)
    run_ui(env)
    local lobby_ok = true
    for _, t in ipairs(env.ui_texts) do if t:find("UI error", 1, true) then lobby_ok = false end end
    check(lobby_ok, "pose bits next to ready-check bits cause no UI error")

    -- they drop out: the pose fades instead of freezing
    their_flags(64)
    live(env, 0.6)
    for _ = 1, 60 do run_frames(env, 0.05) end -- 3 s without a new packet
    env.texts = {}
    for _ = 1, 10 do run_frames(env, 0.05) end
    check(not texts_have(env, "[blocking]"), "no signal: the stand-in stops blocking (the tag says no signal)")
    check(texts_have(env, "(no signal)"), "...and the tag says so")
end

do
    -- the panel's preview shows each pose on the stand-in whatever the other player does
    local function live(env, secs)
        for _ = 1, math.floor(secs / 0.05 + 0.5) do run_frames(env, 0.05) bump_remote(env) end
    end
    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "host", "tcp")
    live(env, 1.0)
    env.combo_override["Stand-in pose preview"] = 2
    run_ui(env)
    env.texts = {}
    live(env, 1.0)
    check(texts_have(env, "[blocking]"), "preview 'Block' shows the pose with no flags from the other player")
    run_ui(env)
    check(ui_has(env, "Preview is ON"), "...and the panel says the preview is on")
    env.combo_override["Stand-in pose preview"] = 3
    run_ui(env)
    live(env, 0.6)
    env.texts = {}
    live(env, 0.5)
    check(texts_have(env, "[healing]") and not texts_have(env, "[blocking]"), "preview 'Heal' shows healing")
    env.combo_override["Stand-in pose preview"] = 4
    run_ui(env)
    local seen_block, seen_heal, seen_none = false, false, false
    for _ = 1, 140 do
        env.texts = {}
        run_frames(env, 0.05) bump_remote(env)
        if texts_have(env, "[blocking]") then seen_block = true
        elseif texts_have(env, "[healing]") then seen_heal = true
        else seen_none = true end
    end
    check(seen_block and seen_heal and seen_none, "preview 'cycle' goes through block, heal and standing")
    env.combo_override["Stand-in pose preview"] = 1
    run_ui(env)
    live(env, 0.8)
    env.texts = {}
    live(env, 0.5)
    check(not texts_have(env, "[blocking]") and not texts_have(env, "[healing]"), "preview off: back to what the other player does")
end

-- =============================================================================================
-- Scenario 13 (9.7): button 11, the recorder. It reads fields and animation values and learns the block signal.
-- =============================================================================================
do
    local function str(t) return Obj.new("System.String", { ["ToString()"] = function() return t end }) end
    local BTN_GUIDED = "11. Record my player, guided (block twice, then use a Herb)"
    local BTN_FREE = "11. Record my player, free (you mark what you do with F6)"
    local BTN_STOP = "    11. Stop and write the report##recstop"
    local CHK_SIGNAL = "    Use the learned block signal for my block pose##recsig"

    -- a player whose status and animation layer can be driven from the test
    local function recording_world()
        local env = new_environment()
        build_world(env)
        add_pose_components(env)
        make_td("app.PlayerGuardInfo", { fields = { { "_On", "System.Boolean" } } })
        make_td("app.PlayerStatus", { fields = { { "_Guard", "System.Boolean" }, { "_Timer", "System.Single" }, { "_Wobble", "System.Boolean" },
            { "_Action", "System.Int32" }, { "_Latch", "System.Boolean" }, { "_Heal", "System.Boolean" }, { "_Both", "System.Boolean" }, { "_Info", "app.PlayerGuardInfo" },
            { "_Name", "System.String" }, { "_Positions", "System.Int32[]" }, { "_Mode", "app.PlayerStatus.StateEnum" } },
            methods = { startGuard = {}, endGuard = {} } })
        make_td("via.motion.TreeLayer", { methods = {
            get_MotionID = { ret = "System.UInt32" }, get_Frame = { ret = "System.Single" }, get_Speed = { ret = "System.Single" },
            getOwnerCount = { ret = "System.Int32" },               -- "owner" is never called
            get_Weird = { ret = "System.Int32" },                   -- no known keyword: never called
            getNodeName = { params = { "System.Int32" }, ret = "System.String" }, -- takes an argument: never called
            get_MotionNode = { ret = "via.motion.MotionNode" },     -- returns an object: never called
        } })
        local comps = env.player:call("get_Components"):get_elements()
        local ps
        for _, c in ipairs(comps) do if c._type == "app.PlayerStatus" then ps = c end end
        local info = Obj.new("app.PlayerGuardInfo", {}, { _On = false })
        ps.f._Mode = 0
        ps.f._Timer, ps.f._Wobble, ps.f._Action, ps.f._Latch, ps.f._Heal, ps.f._Info, ps.f._Name = 0, false, 0, false, false, info, "Ethan"
        ps.f._Both = false -- like the real isBothHands: true while blocking AND while healing
        local st = { motion = 100, frame = 0 }
        local layer = Obj.new("via.motion.TreeLayer", {
            get_MotionID = function() return st.motion end, get_Frame = function() return st.frame end, get_Speed = function() return 1.0 end,
            getOwnerCount = function() calls[#calls + 1] = "layer.getOwnerCount" return 1 end,
            get_Weird = function() calls[#calls + 1] = "layer.get_Weird" return 1 end,
            getNodeName = function() calls[#calls + 1] = "layer.getNodeName" return "x" end,
            get_MotionNode = function() calls[#calls + 1] = "layer.get_MotionNode" return nil end,
        })
        comps[#comps + 1] = Obj.new("via.motion.Motion", { getLayerCount = function() return 1 end, getLayer = function() return layer end })
        env.ps, env.info, env.st = ps, info, st
        return env
    end
    local function noise(env)
        env.ps.f._Timer = env.ps.f._Timer + 0.37
        env.ps.f._Wobble = not env.ps.f._Wobble
        env.st.frame = env.st.frame + 1
    end
    local function set_block(env, on)
        set_real_block(env, on)
        env.ps.f._Both = on
        env.ps.f._Guard, env.info.f._On = on, on
        env.ps.f._Action = on and 5 or 0
        env.ps.f._Mode = on and 2 or 0
        env.st.motion = on and 3000 or 100
    end
    -- runs frames (calling fn(frame number) before each) until the on-screen prompt contains `needle`
    local function drive(env, needle, max_s, fn)
        for i = 1, math.floor(max_s / 0.05) do
            if fn then fn(i) end
            env.texts = {}
            run_frames(env, 0.05)
            bump_remote(env)
            if texts_have(env, needle) then return true, i end
        end
        return false
    end
    local function pinned_text(env) return table.concat((env.files["re7mp_debug.json"] or {}).pinned or {}, "\n") end
    local function out_flags(env) return (env.files["re7mp_out.json"] or {}).flags end
    local function bit(flags, b) return math.floor(flags / b) % 2 == 1 end
    local function live(env, secs)
        for _ = 1, math.floor(secs / 0.05 + 0.5) do run_frames(env, 0.05) bump_remote(env) end
    end

    local env = recording_world()
    load_script(env)
    host_role_files(env, "host", "tcp")
    live(env, 1.0)
    run_ui(env)
    check(ui_has(env, BTN_GUIDED) == false and ui_has(env, "Only reads fields and writes down what changed"), "button 11 is in the panel and says it hooks nothing")
    env.ui_press[BTN_GUIDED] = true
    run_ui(env)
    check(drive(env, "Starting. Close this menu", 1), "the recorder starts and prompts on screen")
    check(env.files["re7mp_lastcall.json"] and env.files["re7mp_lastcall.json"].stage == "recorder", "a breadcrumb is written before the recorder's first reads")
    check((env.files["re7mp_lastcall.json"].call or ""):find("via.motion.TreeLayer.get_", 1, true) ~= nil,
        "...and the last animation getter called is named (the crash suspect): " .. tostring(env.files["re7mp_lastcall.json"].call))
    local hooks_before = 0
    for _ in pairs(env.hooks) do hooks_before = hooks_before + 1 end

    -- the guided script: prep (quiet), idle (noise is learned), block, let go, block, let go, heal, a last moment
    check(drive(env, "Stand still. Press nothing.", 8, function() noise(env) end), "step 2: stand still")
    check(drive(env, "HOLD the block button now", 6, function() noise(env) end), "step 3: block")
    check(drive(env, "Let go. Stand still.", 6, function(i) noise(env) if i == 6 then set_block(env, true) env.ps.f._Latch = true end end), "step 4: let go")
    check(drive(env, "HOLD the block button again", 5, function(i) noise(env) if i == 1 then set_block(env, false) end end), "step 5: block again")
    check(drive(env, "Let go. Stand still.", 6, function(i) noise(env) if i == 6 then set_block(env, true) end end), "step 6: let go")
    check(drive(env, "Use a Herb / Chem Fluid now", 5, function(i) noise(env) if i == 1 then set_block(env, false) end end), "step 7: use a healing item")
    check(drive(env, "Last moment", 15, function(i)
        noise(env)
        if i == 20 then env.hands.f["<actionID>k__BackingField"] = 16 end
        if i == 30 then env.ps.f._Heal = true env.ps.f._Both = true env.st.motion = 4100 env.hands.f["<actionID>k__BackingField"] = 17 end
        if i == 55 then
            env.ps.f._Heal = false env.ps.f._Both = false env.st.motion = 100 env.hands.f["<actionID>k__BackingField"] = 34
            env.hooks["app.Inventory.reduceItem"]({ 0, env.inventory, str("Herb"), 1, true }) -- the game takes the item at the END of the animation
        end
        if i == 58 then env.player_hi.f._CurrentHealth = env.player_hi.f._CurrentHealth + 300 end -- ...and the health rises right after (this consumes last_use)
    end), "step 8: the heal ends 6 s after its last sign")
    live(env, 3.5)
    local text = pinned_text(env)
    if os.getenv("DUMP_PINNED") then print(text) end
    check(text:find("recorder done: send me the debug file", 1, true) ~= nil, "the recording finishes by itself")
    local hooks_after = 0
    for _ in pairs(env.hooks) do hooks_after = hooks_after + 1 end
    check(hooks_after == hooks_before, "the recorder installed no hooks")
    check(env.files["re7mp_lastcall.json"].stage == "clean", "the breadcrumb is set to 'clean' when the recording ends normally")

    check(text:find("idle: 3 fields change by themselves", 1, true) ~= nil, "idle: the three fields that change by themselves (timer, wobble, frame) are found")
    check(text:find("app.PlayerStatus._Timer", 1, true) and text:find("app.PlayerStatus._Wobble", 1, true) and text:find("motion1.layer0.get_Frame", 1, true),
        "...and named")
    check(text:find("+%d+%.%d+ s  app%.PlayerStatus%._Timer") == nil and text:find("+%d+%.%d+ s  app%.PlayerStatus%._Wobble") == nil, "...and never listed as a change afterwards")
    check(text:find("app.PlayerStatus._Guard : false -> true", 1, true) ~= nil, "the block is listed as a change")
    check(text:find("motion1.layer0.get_MotionID : 100 -> 3000", 1, true) ~= nil, "the animation id change is listed")
    check(text:find("app.PlayerStatus._Mode : 0 -> 2", 1, true) ~= nil, "an enum field (a value type the game names) is read as a number")
    check(text:find("BLOCK candidates", 1, true) ~= nil, "the report has block candidates")
    check(text:find("%d%. app%.PlayerStatus%._Guard : false %-> true  %(4 changes%)") ~= nil, "the clean flag is a candidate")
    check(text:find("%d%. app%.PlayerSequenceManager%.IsGuardCancelAccepted : false %-> true  %(4 changes%)") ~= nil, "...and so is the game's own guard flag")
    check(text:find("app.PlayerStatus._Info._On : false -> true", 1, true) ~= nil, "a flag inside a held object is found too (one level down)")
    check(text:find("%d%. app%.PlayerStatus%._Info%._On") ~= nil, "...as a candidate")
    local cand_block = text:match("BLOCK candidates.-HEAL") or ""
    check(not cand_block:find("_Latch", 1, true), "a field that turned on once and stayed on is not a candidate")
    check(not cand_block:find("_Timer", 1, true) and not cand_block:find("_Wobble", 1, true), "noise is not a candidate")
    do -- a field that is on for a block AND for a heal (the real isBothHands) is ranked below the clean ones and marked
        local pb = text:find("app.PlayerStatus._Both : false -> true", 1, true)
        local lines_b = text:match("[^\n]*_Both : false %-> true  %(%d+ changes%)[^\n]*") or ""
        local pg = text:find("%d%. app%.PlayerStatus%._Guard : false %-> true  %(4 changes%)")
        local pbl = text:find("%d%. app%.PlayerStatus%._Both : false %-> true")
        check(pbl ~= nil and pg ~= nil and pg < pbl, "a field that also turns on while healing is ranked after the clean block fields")
        check(lines_b:find("also does this while healing: not a block signal", 1, true) ~= nil, "...and the report says why")
    end
    check(text:find("HEAL ANIMATION (PlayerHands.actionID 16/17): from +", 1, true) ~= nil, "the report gives the heal animation's start and end")
    check(text:find("item: Herb taken out of the inventory", 1, true) ~= nil and text:find("at the end of the animation", 1, true) ~= nil,
        "the report names the item and says it left the inventory at the END of the animation (even though the heal code consumed it)")
    check(text:find("BUILT-IN BLOCK SIGNAL (IsGuardCancelAccepted)", 1, true) ~= nil and text:find("WORKS", 1, true) ~= nil,
        "the report checks the built-in block signal against the two blocks and says it works")
    check(text:find("MARK heal animation started (PlayerHands.actionID 16)", 1, true) ~= nil and text:find("MARK heal animation over", 1, true) ~= nil,
        "the start and the end of the heal animation are marked")
    check(text:match("%* [^\n]*app%.PlayerStatus%._Heal : false %-> true %-> false") ~= nil, "the heal flag is listed, marked as one that came back, with its peak value")
    check(text:match("%* [^\n]*motion1%.layer0%.get_MotionID : 100 %-> 4100 %-> 100") ~= nil, "...and so is the animation id (100 -> 4100 -> 100)")
    check(text:find("MARK item used: Herb", 1, true) ~= nil, "the moment the item was used is marked")
    check(not calls_have("layer.getOwnerCount") and not calls_have("layer.get_Weird") and not calls_have("layer.getNodeName") and not calls_have("layer.get_MotionNode"),
        "only keyword getters with no arguments and a plain return type are called (not owner / unknown / argument / object ones)")
    check(not text:find("_Positions", 1, true), "array fields are not read")
    check(text:find("_Name : \"Ethan\"", 1, true) == nil, "(a name that never changes is not listed)")

    -- the best candidate is kept as an optional extra, never switched on by itself
    live(env, 1.5)
    local saved = env.files["re7mp_settings.json"]
    check(saved and saved.guard_signal and type(saved.guard_signal.comp) == "string" and #saved.guard_signal.path >= 1,
        "the best candidate is saved in the settings file as an optional extra")
    check(saved.use_guard_signal == false, "...and it is NOT switched on (the built-in signal does the block pose)")
    check(not bit(out_flags(env), 64), "not blocking: no block bit")
    set_real_block(env, true)
    live(env, 0.4)
    check(bit(out_flags(env), 64), "blocking: the built-in signal sets the block bit with no learned signal in use")
    set_real_block(env, false)
    live(env, 0.4)
    check(not bit(out_flags(env), 64), "letting go clears it")
    env.ui_press["    Forget the learned block signal##recforget"] = true
    run_ui(env)
    live(env, 1.5)
    check(env.files["re7mp_settings.json"].guard_signal == nil, "forgetting the signal removes it from the settings file")
    run_ui(env)
    check(not ui_has(env, "signal: "), "...and from the panel")
end

do
    -- a saved signal is loaded at start (and a damaged one is ignored)
    local function world_with(settings)
        local env = new_environment()
        build_world(env)
        env.files["re7mp_settings.json"] = settings
        load_script(env)
        host_role_files(env, "host", "tcp")
        for _ = 1, 30 do run_frames(env, 0.05) bump_remote(env) end
        return env
    end
    local function bit(flags, b) return math.floor(flags / b) % 2 == 1 end
    local env = world_with({ guard_signal = { comp = "app.PlayerStatus", path = { "_Guard" }, on = true }, use_guard_signal = true })
    local ps
    for _, c in ipairs(env.player:call("get_Components"):get_elements()) do if c._type == "app.PlayerStatus" then ps = c end end
    ps.f._Guard = true
    for _ = 1, 20 do run_frames(env, 0.05) bump_remote(env) end
    check(not bit(env.files["re7mp_out.json"].flags, 64), "a saved learned signal that an old build had switched ON starts OFF (the 9.7 pick, isBothHands, also fired while healing)")
    run_ui(env)
    check(ui_has(env, "signal: app.PlayerStatus._Guard"), "...and is still shown in the panel, so it can be ticked")
    env.check_override["    Use the learned block signal for my block pose##recsig"] = true
    run_ui(env)
    for _ = 1, 20 do run_frames(env, 0.05) bump_remote(env) end
    check(bit(env.files["re7mp_out.json"].flags, 64), "...and ticking it uses it")
    env = world_with({ guard_signal = { comp = "app.PlayerStatus", path = { "_Guard" }, on = true }, use_guard_signal = false })
    ps = nil
    for _, c in ipairs(env.player:call("get_Components"):get_elements()) do if c._type == "app.PlayerStatus" then ps = c end end
    ps.f._Guard = true
    for _ = 1, 20 do run_frames(env, 0.05) bump_remote(env) end
    check(not bit(env.files["re7mp_out.json"].flags, 64), "a saved signal that was switched off is not used")
    for _, bad in ipairs({ { comp = 5, path = { "_Guard" }, on = true }, { comp = "app.PlayerStatus", path = {}, on = true },
        { comp = "app.PlayerStatus", path = { "a", "b", "c", "d" }, on = true }, { comp = "app.PlayerStatus", path = { 7 }, on = true },
        { comp = "app.PlayerStatus", path = { "_Guard" } }, "junk" }) do
        env = world_with({ guard_signal = bad, use_guard_signal = true })
        run_ui(env)
        check(not ui_has(env, "signal: ") and not ui_has(env, "UI error"), "a damaged saved signal is ignored")
    end
end

do
    -- keys, free mode, no player, and the previous-session breadcrumb of the recorder
    local function live(env, secs)
        for _ = 1, math.floor(secs / 0.05 + 0.5) do run_frames(env, 0.05) bump_remote(env) end
    end
    local function pinned_text(env) return table.concat((env.files["re7mp_debug.json"] or {}).pinned or {}, "\n") end
    local function prompt_is(env, needle)
        env.texts = {}
        live(env, 0.1)
        return texts_have(env, needle)
    end
    local function press_f6(env)
        env.keys[0x75] = true
        live(env, 0.1)
        env.keys[0x75] = nil
        live(env, 0.1)
    end

    local env = new_environment()
    build_world(env)
    load_script(env)
    host_role_files(env, "host", "tcp")
    live(env, 1)
    env.ui_press["11. Record my player, free (you mark what you do with F6)"] = true
    run_ui(env)
    check(prompt_is(env, "Starting. Close this menu"), "free mode starts")
    press_f6(env)
    check(prompt_is(env, "Stand still for a moment"), "F6 in the first step skips to the next")
    press_f6(env)
    check(prompt_is(env, "Do it now"), "...and again")
    press_f6(env)
    press_f6(env)
    live(env, 2.5)
    local text = pinned_text(env)
    check(text:find("MARK 1 at", 1, true) ~= nil and text:find("MARK 2 at", 1, true) ~= nil, "in the free step F6 drops numbered marks and does not skip")
    check(prompt_is(env, "Do it now"), "...and the free step goes on")
    run_ui(env)
    check(ui_has(env, "RECORDING (free)"), "the panel shows the recording")
    env.ui_press["    11. Stop and write the report##recstop"] = true
    run_ui(env)
    live(env, 2.5)
    text = pinned_text(env)
    check(text:find("recorder stopped from the panel", 1, true) ~= nil, "the stop button ends the recording")
    check(text:find("BLOCK: the guided steps were not all done", 1, true) ~= nil, "a free recording does not claim a block signal")
    run_ui(env)
    check(not ui_has(env, "RECORDING"), "...and the panel is back to the buttons")
    check(not texts_have(env, "RE7MP RECORDER") or true, "(prompts stop)")
    env.texts = {}
    live(env, 0.3)
    check(not texts_have(env, "RE7MP RECORDER"), "the on-screen prompt is gone after stopping")

    -- F6 does nothing when no recording is running
    press_f6(env)
    run_ui(env)
    check(not ui_has(env, "RECORDING"), "F6 alone does not start anything")

    -- no player object yet (title screen)
    local env2 = new_environment()
    load_script(env2)
    host_role_files(env2, "host", "tcp")
    live(env2, 1)
    env2.ui_press["11. Record my player, guided (block twice, then use a Herb)"] = true
    run_ui(env2)
    run_ui(env2)
    check(ui_has(env2, "Load into the game first"), "without a player the recorder says to load into the game")
    check(not ui_has(env2, "RECORDING"), "...and does not start")

    -- the previous session ended inside the recorder
    local env3 = new_environment()
    build_world(env3)
    env3.files["re7mp_lastcall.json"] = { stage = "recorder", call = "via.motion.TreeLayer.get_Frame", session = 1699990000, time = 1700000000 }
    load_script(env3)
    host_role_files(env3, "host", "tcp")
    live(env3, 1)
    local found = false
    for _, l in ipairs(env3.log) do
        if l:find("previous session: The last session ended while the recorder (button 11) was at: via.motion.TreeLayer.get_Frame", 1, true) then found = true end
    end
    check(found, "a breadcrumb left by the recorder is reported at the next start")
end

-- =============================================================================================
-- Scenario 14 (9.8): a downed player can't aim or shoot until revived (PlayerSequenceManager.IsAimAccepted / IsAttackAccepted)
-- =============================================================================================
do
    local function hit(env, new_hp)
        local hi = env.player_hi
        env.hooks["app.HealthInfo.set_health"]({ 0, hi })
        hi.f._CurrentHealth = new_hp
        env.posthooks["app.HealthInfo.set_health"](nil)
    end
    local function connected(env, frames)
        for _ = 1, frames do run_frames(env, 0.05) bump_remote(env) end
    end
    local function world(settings)
        local env = new_environment()
        build_world(env)
        add_pose_components(env)
        env.files["re7mp_settings.json"] = settings or { death_mode = 4 }
        load_script(env)
        host_role_files(env, "host", "tcp")
        connected(env, 30)
        return env
    end

    local env = world()
    check(env.seq.f.IsAimAccepted == true and env.seq.f.IsAttackAccepted == true, "before anything happens the gates are open")
    run_ui(env)
    check(ui_has(env, "weapon lock: idle (you are not down)"), "...and says it is idle while you are not down")
    check(env.seq.f.IsAimAccepted == true, "an upright player's gates are never touched")

    hit(env, 0)
    connected(env, 12)
    run_ui(env)
    check(ui_has(env, "YOU ARE DOWN: waiting for Bob"), "(down)")
    check(env.seq.f.IsAimAccepted == false and env.seq.f.IsAttackAccepted == false, "down: aiming and attacking are switched off")
    check(env.seq.f.IsGuardAccepted == true, "...but blocking is left alone")
    check(ui_has(env, "weapon lock: HOLDING aim and attack off"), "the panel says the lock is holding")
    -- the game switches them back on (it does that on its own transitions): the lock takes them away again within a frame
    env.seq.f.IsAimAccepted, env.seq.f.IsAttackAccepted = true, true
    connected(env, 2)
    check(env.seq.f.IsAimAccepted == false and env.seq.f.IsAttackAccepted == false, "when the game turns them back on, the lock turns them off again")
    run_ui(env)
    check(ui_has(env, "the game opened them again before"), "...and says where the game opened them again (that says whether the lock holds)")

    -- 9.9: a downed player's body still does what it does, so the other player is told the truth (the 9.8 build hid it)
    env.hands.f["<actionID>k__BackingField"] = 16
    connected(env, 6)
    local fl = env.files["re7mp_out.json"].flags
    check(math.floor(fl / 128) % 2 == 1, "while down a heal is still sent: " .. tostring(fl))
    env.hands.f["<actionID>k__BackingField"] = 34
    env.seq.f.IsGuardCancelAccepted = true
    connected(env, 6)
    fl = env.files["re7mp_out.json"].flags
    check(math.floor(fl / 64) % 2 == 1, "...and so is a block: " .. tostring(fl))
    env.seq.f.IsGuardCancelAccepted = false
    connected(env, 4)

    -- revived: the gates come back
    push_msgs(env, { { 7, "e|heal|Herb|1.00|1.60|0.50" } })
    connected(env, 12)
    run_ui(env)
    check(not ui_has(env, "YOU ARE DOWN: waiting for Bob"), "(up again)")
    check(env.seq.f.IsAimAccepted == true and env.seq.f.IsAttackAccepted == true, "revived: aiming and attacking are back")
    check(ui_has(env, "weapon lock: released: aim and attack are back") or ui_has(env, "weapon lock: idle (you are not down)"), "...and the panel says so")
    env.seq.f.IsAimAccepted = false -- the game closes the gate itself (a block): nothing of ours holds it open or closed now
    connected(env, 6)
    check(env.seq.f.IsAimAccepted == false, "after the release the lock does not touch the gates any more")
    env.seq.f.IsAimAccepted = true

    -- down while blocking: letting go of the lock must not open a gate in the middle of the block
    hit(env, 0)
    connected(env, 12)
    check(env.seq.f.IsAimAccepted == false, "down again: locked")
    set_real_block(env, true) -- the game's own block: gates closed, cancel flag open
    env.seq.f.IsAimAccepted, env.seq.f.IsAttackAccepted = false, false
    push_msgs(env, { { 7, "e|heal|Herb|1.00|1.60|0.50" } })
    connected(env, 12)
    check(env.seq.f.IsAimAccepted == false and env.seq.f.IsAttackAccepted == false, "revived in the middle of a block: the gates stay as the block left them")
    set_real_block(env, false)
    env.seq.f.IsAimAccepted, env.seq.f.IsAttackAccepted = true, true
    connected(env, 4)

    -- a new player object while down (a reload): nothing is written to the old one, the lock lets go
    hit(env, 0)
    connected(env, 12)
    check(env.seq.f.IsAimAccepted == false, "down once more: locked")
    env.player.addr = 0x99998
    connected(env, 80)
    run_ui(env)
    check(not ui_has(env, "YOU ARE DOWN: waiting for Bob"), "a new player object clears the down state")
end

do
    -- the checkbox: unticked, a downed player is not locked (and the debug summary says what happened)
    local function hit(env, new_hp)
        local hi = env.player_hi
        env.hooks["app.HealthInfo.set_health"]({ 0, hi })
        hi.f._CurrentHealth = new_hp
        env.posthooks["app.HealthInfo.set_health"](nil)
    end
    local function connected(env, frames)
        for _ = 1, frames do run_frames(env, 0.05) bump_remote(env) end
    end
    local env = new_environment()
    build_world(env)
    add_pose_components(env)
    env.files["re7mp_settings.json"] = { death_mode = 4 }
    load_script(env)
    host_role_files(env, "host", "tcp")
    connected(env, 30)
    env.check_override["A downed player can't aim or shoot until revived (EXPERIMENTAL)"] = false
    run_ui(env)
    hit(env, 0)
    connected(env, 12)
    run_ui(env)
    check(ui_has(env, "YOU ARE DOWN: waiting for Bob"), "(down)")
    check(env.seq.f.IsAimAccepted == true and env.seq.f.IsAttackAccepted == true, "lock switched off: a downed player's gates are untouched")
    check(ui_has(env, "weapon lock: switched off"), "...and the panel says it is off")
    env.check_override["A downed player can't aim or shoot until revived (EXPERIMENTAL)"] = true
    run_ui(env)
    connected(env, 4)
    check(env.seq.f.IsAimAccepted == false and env.seq.f.IsAttackAccepted == false, "ticking the checkbox again locks the downed player")

    -- no PlayerSequenceManager on the player (a different game build): it says so and writes nothing
    local env2 = new_environment()
    build_world(env2)
    env2.files["re7mp_settings.json"] = { death_mode = 4 }
    load_script(env2)
    host_role_files(env2, "host", "tcp")
    connected(env2, 30)
    hit(env2, 0)
    connected(env2, 12)
    run_ui(env2)
    check(ui_has(env2, "weapon lock: app.PlayerSequenceManager not found: the weapon is NOT locked"), "without the component the panel says the weapon is NOT locked")
    check(not ui_has(env2, "UI error"), "...with no error")

    -- writes that fail (the game refuses the field) are counted and do not crash anything
    local env3 = new_environment()
    build_world(env3)
    add_pose_components(env3)
    env3.seq.set_field = function() error("no write") end
    env3.files["re7mp_settings.json"] = { death_mode = 4 }
    load_script(env3)
    host_role_files(env3, "host", "tcp")
    connected(env3, 30)
    hit(env3, 0)
    connected(env3, 12)
    run_ui(env3)
    check(ui_has(env3, "failed writes") and not ui_has(env3, "UI error"), "a refused write is counted and shown, not fatal")

    -- the debug file says what the lock and the pose readers did (that is how a wrong guess in the real game shows up)
    local env4 = new_environment()
    build_world(env4)
    add_pose_components(env4)
    env4.files["re7mp_settings.json"] = { death_mode = 4 }
    load_script(env4)
    host_role_files(env4, "host", "tcp")
    connected(env4, 30)
    env4.hands.f["<actionID>k__BackingField"] = 16
    connected(env4, 6)
    hit(env4, 0)
    connected(env4, 12)
    run_frames(env4, 3)
    local dbg4 = env4.files["re7mp_debug.json"]
    check(dbg4 and dbg4.health and dbg4.health.weapon_lock and dbg4.health.weapon_lock.writes >= 2 and dbg4.health.weapon_lock.failed == 0,
        "the debug file counts the lock's writes")
    check(dbg4 and dbg4.health.poses and dbg4.health.poses.guard_from == "IsGuardCancelAccepted" and dbg4.health.poses.reads > 5 and dbg4.health.poses.unreadable == 0,
        "...and which signal the block pose comes from, and how many readings were taken")
end

-- =============================================================================================
-- Scenario 15 (9.9): crouch, heal while down, the lock's places, walls and menus
-- =============================================================================================
do
    local HK = "<actionID>k__BackingField"
    local function live(env, secs)
        for _ = 1, math.floor(secs / 0.05 + 0.5) do run_frames(env, 0.05) bump_remote(env) end
    end
    local function out_flags(env) return (env.files["re7mp_out.json"] or {}).flags end
    local function bit(flags, b) return math.floor(flags / b) % 2 == 1 end
    local function world(settings)
        local env = new_environment()
        build_world(env)
        add_pose_components(env)
        env.files["re7mp_settings.json"] = settings or {}
        load_script(env)
        host_role_files(env, "host", "tcp")
        return env
    end
    local function hit(env, new_hp)
        local hi = env.player_hi
        env.hooks["app.HealthInfo.set_health"]({ 0, hi })
        hi.f._CurrentHealth = new_hp
        env.posthooks["app.HealthInfo.set_health"](nil)
    end
    -- the debug file is only rewritten when something is said (at most every 2 s): saying something makes it current
    local function refresh_debug(env)
        env.ui_press["Hide them for 60 s"] = true
        run_ui(env)
        live(env, 2.3)
        env.ui_press["Show them now"] = true
        run_ui(env)
    end

    -- ---- crouch, read from how far the camera sits above the player object ----
    local env = world()
    live(env, 2)
    check(not bit(out_flags(env), 256), "standing: no crouch bit")
    env.camera_pos.y = 1.57 -- a head bob
    live(env, 0.5)
    check(not bit(out_flags(env), 256), "a small dip of the camera is not a crouch")
    -- a clear dip of 0.10 m (stepping, a heavy landing) must never show up as a crouch, not even for a moment
    env.camera_pos.y = 1.50
    local ever_crouch = false
    for _ = 1, 40 do
        run_frames(env, 0.05) bump_remote(env)
        if bit(out_flags(env), 256) then ever_crouch = true end
    end
    check(not ever_crouch, "a 0.10 m dip of the camera is never sent as a crouch, not even for one frame")
    run_ui(env)
    check(not ui_has(env, "you are sending CROUCH"), "...and the panel does not say CROUCH")
    env.camera_pos.y = 1.05 -- half a metre lower
    env.move.f.IsCrouching, env.move.f.StanceType = true, 2
    live(env, 0.5)
    check(bit(out_flags(env), 256), "eyes half a metre lower: the crouch bit is sent")
    check(not bit(out_flags(env), 64) and not bit(out_flags(env), 128), "...and it is not mistaken for a block or a heal")
    run_ui(env)
    check(ui_has(env, "you are sending CROUCH"), "the panel says I am sending CROUCH")
    check(ui_has(env, "eyes 1.05 m above your feet (standing 1.60)"), "...and shows the measured eye height")
    env.camera_pos.y = 1.45 -- only 0.15 below standing: still inside the hysteresis
    live(env, 0.5)
    check(bit(out_flags(env), 256), "rising a little does not end the crouch (hysteresis)")
    env.camera_pos.y = 1.6
    env.move.f.IsCrouching, env.move.f.StanceType = false, 0
    live(env, 0.5)
    check(not bit(out_flags(env), 256), "standing up clears it")
    env.camera_pos.y = 0.3 -- not on the player at all (a cutscene camera)
    live(env, 0.5)
    check(not bit(out_flags(env), 256), "a camera that is not near the player's eyes is never a crouch")
    env.camera_pos.y = 1.6
    -- the debug file: which game fields agree with the camera-height crouch, and the action ids the hands / gun went through
    env.hands.f[HK] = 16
    live(env, 0.4)
    env.hands.f[HK] = 34
    live(env, 0.3)
    refresh_debug(env)
    local d = env.files["re7mp_debug.json"]
    check(d and d.health and d.health.crouch ~= nil, "the debug file has a crouch section")
    local flag_entry, stance_entry
    for _, e in ipairs(d and d.health and d.health.crouch.game_fields or {}) do
        if e.field == "app.PlayerMovement.IsCrouching" then flag_entry = e end
        if e.field == "app.PlayerMovement.StanceType" then stance_entry = e end
    end
    check(flag_entry and flag_entry.agrees_with_camera_height_percent and flag_entry.agrees_with_camera_height_percent >= 80,
        "a game field that follows the crouch is listed with how often it agreed: " .. tostring(flag_entry and flag_entry.agrees_with_camera_height_percent))
    check(stance_entry and stance_entry.values and stance_entry.values["2"] and stance_entry.values["2"].while_camera_says_crouched >= 1,
        "...and a numeric stance field lists its values with how often the camera said crouched")
    local po = d and d.health and d.health.poses or {}
    check(po.hands_ids_seen and po.hands_ids_seen["16"] and po.hands_ids_seen["34"], "the hands action ids seen are listed (a heal that is not 16/17 would show here)")
    check(po.packets_with_crouch and po.packets_with_crouch > 3 and po.packets_with_heal and po.packets_with_heal >= 1, "...and so are the packets that carried each pose bit")

    -- ---- the stand-in crouches when THEY do ----
    local envc = world({ show_skeleton = true, show_body = false })
    envc.files["re7mp_in.json"].x, envc.files["re7mp_in.json"].y, envc.files["re7mp_in.json"].z = 0, 1.6, 6
    live(envc, 1)
    local function line_at(e, height)
        for _, pt in ipairs(e.line_pts or {}) do
            if math.abs(pt[2] - (540 - height * 20)) < 0.12 then return true end
        end
        return false
    end
    envc.line_pts = {}
    live(envc, 0.2)
    check(line_at(envc, 0.0), "standing stand-in: the feet are on the floor")
    envc.files["re7mp_in.json"].flags = 256
    live(envc, 2)
    envc.line_pts = {}
    live(envc, 0.2)
    check(line_at(envc, 0.5) and not line_at(envc, 0.0), "crouching stand-in: the feet stay where the floor is under their lowered eyes (0.5 m below standing)")
    check(line_at(envc, 0.5 + 1.6 * 0.56 - 0.40), "...and the hips drop with them")
    run_ui(envc)
    check(ui_has(envc, "crouch 100%"), "the panel shows the crouch fully applied")
    envc.files["re7mp_in.json"].flags = 0
    live(envc, 2)
    envc.combo_override["Stand-in pose preview"] = 5
    run_ui(envc)
    live(envc, 1)
    run_ui(envc)
    check(ui_has(envc, "crouch 100%") and ui_has(envc, "Preview is ON"), "the preview menu can show the crouch")

    -- ---- the weapon lock: more than one place, a hook from the first time you go down ----
    local envl = world({ death_mode = 4 })
    live(envl, 1.5)
    check(envl.hooks["app.PlayerSequenceManager.updateActionTrack"] == nil, "the sequence manager is not hooked while you are upright")
    envl.seq.f.IsAimAccepted = true
    envl.phase_cbs["pre:UpdateBehavior"]()
    check(envl.seq.f.IsAimAccepted == true, "an upright player's gate is never touched by the phase callbacks either")
    hit(envl, 0)
    live(envl, 0.6)
    check(envl.hooks["app.PlayerSequenceManager.updateActionTrack"] ~= nil and envl.hooks["app.PlayerSequenceManager.updateMovementTrack"] ~= nil
        and envl.hooks["app.PlayerSequenceManager.update"] == nil and envl.hooks["app.PlayerSequenceManager.lateUpdate"] == nil,
        "going down hooks the sequence manager's update*Track methods and not the hot inherited update / lateUpdate")
    check(envl.hooks["app.PlayerSequenceManager.requestSequence"] == nil, "...and nothing else of it")
    for _, name in ipairs({ "pre:UpdateBehavior", "post:UpdateBehavior", "pre:LateUpdateBehavior", "pre:UpdateHID" }) do
        envl.seq.f.IsAimAccepted, envl.seq.f.IsAttackAccepted = true, true
        envl.phase_cbs[name]()
        check(envl.seq.f.IsAimAccepted == false and envl.seq.f.IsAttackAccepted == false, "the gate is closed again at " .. name)
    end
    envl.seq.f.IsAimAccepted = true
    envl.posthooks["app.PlayerSequenceManager.updateActionTrack"](nil)
    check(envl.seq.f.IsAimAccepted == false, "...and right after the sequence manager's update")
    live(envl, 0.3)
    refresh_debug(envl)
    local dl = envl.files["re7mp_debug.json"].health.weapon_lock
    check(dl.places["pre:UpdateBehavior"] and dl.places["pre:UpdateBehavior"].open >= 1, "the file says at which place the gate was found open again")
    check(dl.places["hook:updateActionTrack"] and dl.places["hook:updateActionTrack"].open >= 1, "...including after the hooked updateActionTrack")
    check(#dl.hooked_after == 4 and #dl.places_registered >= 10, "...which methods were hooked and which places are registered: " .. #dl.hooked_after)
    local has_update, has_shoot = false, false
    for _, n in ipairs(dl.sequence_manager_methods or {}) do if n == "updateActionTrack" then has_update = true end end
    for _, n in ipairs(dl.other_methods and dl.other_methods["app.PlayerGun"] or {}) do if n == "shoot" then has_shoot = true end end
    check(has_update and has_shoot, "...and lists the methods of the sequence manager and the gun (to find the real shot)")
    envl.check_override["    also close it right after the sequence manager's own update (hooks it the first time you go down)"] = false
    run_ui(envl)
    envl.seq.f.IsAimAccepted = true
    envl.posthooks["app.PlayerSequenceManager.updateActionTrack"](nil)
    check(envl.seq.f.IsAimAccepted == true, "with the hook box unticked the hook does nothing")
    -- revived: neither the phases nor the hook touch the gate any more
    push_msgs(envl, { { 7, "e|heal|Herb|1.00|1.60|0.50" } })
    live(envl, 1.0)
    envl.seq.f.IsAimAccepted, envl.seq.f.IsAttackAccepted = true, true
    envl.phase_cbs["pre:UpdateBehavior"]()
    envl.phase_cbs["post:LateUpdateBehavior"]()
    envl.posthooks["app.PlayerSequenceManager.updateMovementTrack"](nil)
    check(envl.seq.f.IsAimAccepted == true and envl.seq.f.IsAttackAccepted == true, "after the revive the phase callbacks and the hook leave the gate alone (checked at once, before the next frame can tidy up)")
    live(envl, 0.3)
    check(envl.seq.f.IsAimAccepted == true and envl.seq.f.IsAttackAccepted == true, "...and it stays that way")

    -- ---- 9.13: the real file said the game opens the gates INSIDE UpdateBehavior and the sequence manager has no `update`:
    -- the gates are closed after its update*Track methods, the gun's try-calls say no, the move gate says no, and a downed
    -- player who has moved is put back where they fell ----
    local envm = world({ death_mode = 4 })
    live(envm, 1.5)
    check(envm.hooks["app.PlayerGun.tryAttack"] == nil and envm.hooks["app.PlayerSequenceManager.updateActionTrack"] == nil
        and envm.hooks["app.PlayerSequenceManager.get_isMoveAccepted"] == nil, "nothing of the lock is hooked while you are upright")
    hit(envm, 0)
    live(envm, 0.6)
    for _, k in ipairs({ "updateActionTrack", "updateMovementTrack", "updateJogTrack", "onMotionUpdated" }) do
        check(envm.hooks["app.PlayerSequenceManager." .. k] ~= nil, "going down hooks the sequence manager's " .. k)
    end
    for _, k in ipairs({ "tryAttack", "tryAimStart", "trySemiAimStart" }) do
        check(envm.hooks["app.PlayerGun." .. k] ~= nil, "going down hooks the gun's " .. k)
    end
    check(envm.hooks["app.PlayerGun.tryReload"] == nil and envm.hooks["app.PlayerGun.shoot"] == nil, "...but not its reload or the shot itself")
    check(envm.hooks["app.PlayerSequenceManager.get_isMoveAccepted"] ~= nil, "...and the sequence manager's move gate")
    check(envm.hooks["app.PlayerSequenceManager.get_isAimAccepted"] == nil, "...and no other getter")
    -- what the real file showed: between our write before UpdateBehavior and the gun's read the game opens the gates again
    envm.phase_cbs["pre:UpdateBehavior"]()
    envm.seq.f.IsAimAccepted, envm.seq.f.IsAttackAccepted = true, true -- the game, in updateActionTrack
    envm.posthooks["app.PlayerSequenceManager.updateActionTrack"](nil)
    check(envm.seq.f.IsAimAccepted == false and envm.seq.f.IsAttackAccepted == false, "the gates are closed again right after the game's updateActionTrack")
    envm.seq.f.IsAimAccepted = true
    envm.posthooks["app.PlayerSequenceManager.updateMovementTrack"](nil)
    check(envm.seq.f.IsAimAccepted == false, "...and after updateMovementTrack")
    -- the gun's own questions
    local pre = envm.hooks["app.PlayerGun.tryAttack"]({})
    local post = envm.posthooks["app.PlayerGun.tryAttack"]({ ptr = 1 })
    check(pre == 1, "while down the gun's tryAttack is skipped")
    check(type(post) == "table" and post.ptr == 0, "...and answers no")
    check(envm.hooks["app.PlayerGun.tryAimStart"]({}) == 1 and envm.hooks["app.PlayerGun.trySemiAimStart"]({}) == 1, "...and so are tryAimStart and trySemiAimStart")
    -- the move gate
    local mv = envm.posthooks["app.PlayerSequenceManager.get_isMoveAccepted"]({ ptr = 1 })
    check(type(mv) == "table" and mv.ptr == 0, "while down the move gate answers no")
    -- walking away: put back where you fell, only sideways
    local xf = envm.player:call("get_Transform")
    local p0 = { x = xf:call("get_Position").x, y = xf:call("get_Position").y, z = xf:call("get_Position").z }
    xf:call("set_Position", { x = p0.x + 1.0, y = p0.y + 0.2, z = p0.z })
    envm.phase_cbs["post:UpdateBehavior"]()
    local p1 = xf:call("get_Position")
    check(math.abs(p1.x - p0.x) < 1e-6 and math.abs(p1.z - p0.z) < 1e-6, "a downed player who walked a metre is put back where they fell")
    check(math.abs(p1.y - (p0.y + 0.2)) < 1e-6, "...only sideways (height is left to the game)")
    xf:call("set_Position", { x = p0.x + 0.02, y = p0.y, z = p0.z })
    envm.phase_cbs["post:UpdateBehavior"]()
    check(math.abs(xf:call("get_Position").x - (p0.x + 0.02)) < 1e-6, "a shift of a couple of centimetres is left alone (no jitter)")
    xf:call("set_Position", { x = p0.x + 1.0, y = p0.y, z = p0.z })
    envm.phase_cbs["pre:UpdateHID"]()
    check(math.abs(xf:call("get_Position").x - (p0.x + 1.0)) < 1e-6, "the position is only put back at the places after the game has moved you, not at the start of the frame (pre:UpdateHID)")
    envm.phase_cbs["post:UpdateBehavior"]()
    check(math.abs(xf:call("get_Position").x - p0.x) < 1e-6, "...and is put back there")
    xf:call("set_Position", { x = p0.x + 10, y = p0.y, z = p0.z })
    envm.phase_cbs["post:UpdateBehavior"]()
    check(math.abs(xf:call("get_Position").x - (p0.x + 10)) < 1e-6, "a jump of ten metres is the game moving you (a cutscene): not fought")
    xf:call("set_Position", { x = p0.x + 10.8, y = p0.y, z = p0.z })
    envm.phase_cbs["post:UpdateBehavior"]()
    check(math.abs(xf:call("get_Position").x - (p0.x + 10)) < 1e-6, "...the new place is where you are held from then on")
    live(envm, 0.3)
    run_ui(envm)
    check(ui_has(envm, "gun calls refused:") and ui_has(envm, "movement: gate said no"), "the panel says what the lock did")
    refresh_debug(envm)
    local dm = envm.files["re7mp_debug.json"].health.weapon_lock
    check(dm.places["hook:updateActionTrack"] and dm.places["hook:updateActionTrack"].open >= 1, "the file says the gates were found open again after updateActionTrack")
    check(dm.hooks.fired_while_down["hook:updateActionTrack"] >= 1 and #dm.hooks.installed == 4, "...how often each hooked method fired while you were down")
    check(dm.gun.refused >= 3 and #dm.gun.installed == 3, "...how many gun calls were refused")
    check(dm.move.gate_said_no >= 1 and dm.move.gate_asked_while_down >= 1 and dm.move.put_back >= 1 and dm.move.new_place_taken == 1,
        "...and how often the move gate said no, you were put back, and a new place was taken")
    check(dm.move.put_back_where["post:UpdateBehavior"] >= 1, "...and at which place of the frame you were put back")
    check(dm.move.installed[1] == "get_isMoveAccepted" and dm.gun.on == true and dm.move.on == true, "...and which hooks exist")
    -- revived: nothing is skipped, answered or moved any more
    push_msgs(envm, { { 7, "e|heal|Herb|1.00|1.60|0.50" } })
    live(envm, 1.0)
    check(envm.hooks["app.PlayerGun.tryAttack"]({}) == 0, "after the revive the gun's tryAttack is called as normal")
    local post2 = envm.posthooks["app.PlayerGun.tryAttack"]({ ptr = 1 })
    check(type(post2) == "table" and post2.ptr == 1, "...with the game's own answer")
    local mv2 = envm.posthooks["app.PlayerSequenceManager.get_isMoveAccepted"]({ ptr = 1 })
    check(type(mv2) == "table" and mv2.ptr == 1, "...and the move gate gives the game's own answer")
    local pa = xf:call("get_Position")
    xf:call("set_Position", { x = pa.x + 3, y = pa.y, z = pa.z })
    envm.phase_cbs["post:UpdateBehavior"]()
    check(math.abs(xf:call("get_Position").x - (pa.x + 3)) < 1e-6, "...and walking is free")
    -- the switches
    local envs = world({ death_mode = 4, lock_guns = false, lock_move = false })
    live(envs, 1.5)
    hit(envs, 0)
    live(envs, 0.6)
    check(envs.hooks["app.PlayerGun.tryAttack"] == nil and envs.hooks["app.PlayerSequenceManager.get_isMoveAccepted"] == nil,
        "with the gun and move boxes saved as off, those hooks are never installed")
    check(envs.hooks["app.PlayerSequenceManager.updateActionTrack"] ~= nil, "...but the gates still are")
    local xs = envs.player:call("get_Transform")
    local q0 = xs:call("get_Position")
    xs:call("set_Position", { x = q0.x + 2, y = q0.y, z = q0.z })
    envs.phase_cbs["post:UpdateBehavior"]()
    check(math.abs(xs:call("get_Position").x - (q0.x + 2)) < 1e-6, "...and with the move box off a downed player is not put back")
    envs.check_override["    also refuse the gun's own attack and aim calls while down (hooks app.PlayerGun.tryAttack ...)"] = true
    run_ui(envs)
    live(envs, 0.3)
    check(envs.hooks["app.PlayerGun.tryAttack"] ~= nil, "ticking the gun box later installs the gun hooks then")
    check(envs.hooks["app.PlayerGun.tryAttack"]({}) == 1, "...and while down the gun is refused")
    envs.check_override["    also refuse the gun's own attack and aim calls while down (hooks app.PlayerGun.tryAttack ...)"] = false
    run_ui(envs)
    check(envs.hooks["app.PlayerGun.tryAttack"]({}) == 0, "...and unticking the box lets the gun through again at once (the hook stays, it does nothing)")
    envs.check_override["    also stop a downed player moving (the move gate says no; if the game moves you anyway you are put back where you fell)"] = true
    run_ui(envs)
    live(envs, 0.3)
    check(envs.hooks["app.PlayerSequenceManager.get_isMoveAccepted"] ~= nil, "ticking the move box later installs the move gate then")
    local mvs = envs.posthooks["app.PlayerSequenceManager.get_isMoveAccepted"]({ ptr = 1 })
    check(type(mvs) == "table" and mvs.ptr == 0, "...and while down it says no")
    envs.check_override["    also stop a downed player moving (the move gate says no; if the game moves you anyway you are put back where you fell)"] = false
    run_ui(envs)
    mvs = envs.posthooks["app.PlayerSequenceManager.get_isMoveAccepted"]({ ptr = 1 })
    check(type(mvs) == "table" and mvs.ptr == 1, "...and unticking the box gives the game's own answer again")
    local envk = world({ death_mode = 4, lock_hook = false })
    live(envk, 1.5)
    hit(envk, 0)
    live(envk, 0.6)
    check(envk.hooks["app.PlayerSequenceManager.updateActionTrack"] == nil, "with the gate-hook box saved as off the sequence manager's update methods are not hooked")
    envk.check_override["    also close it right after the sequence manager's own update (hooks it the first time you go down)"] = true
    run_ui(envk)
    live(envk, 0.3)
    check(envk.hooks["app.PlayerSequenceManager.updateActionTrack"] ~= nil, "...and ticking it later hooks them then")
    -- a hook that fires absurdly often is muted
    local envh = world({ death_mode = 4 })
    live(envh, 1.5)
    hit(envh, 0)
    live(envh, 0.6)
    local muted_at
    for i = 1, 6500 do
        envh.posthooks["app.PlayerSequenceManager.updateJogTrack"](nil)
        if i > 6001 and not muted_at then
            envh.seq.f.IsAimAccepted = true
            envh.posthooks["app.PlayerSequenceManager.updateJogTrack"](nil)
            if envh.seq.f.IsAimAccepted == true then muted_at = i end
        end
    end
    check(muted_at ~= nil, "a hooked method that fires more than 6000 times in a second is ignored from then on")
    check(log_has(envh, "fires more than 6000 times a second"), "...and the log says so")

    -- ---- walls ----
    local function drawn(e) e.texts = {} live(e, 0.4) return texts_have(e, "Bob") end
    local envw = world()
    envw.wall_x = 5
    envw.files["re7mp_in.json"].x = 8
    live(envw, 3)
    run_ui(envw)
    check(ui_has(envw, "walls: working (collision layers 3, 5)"), "the wall test finds the layers that see the floor")
    check(ui_has(envw, "Other player not drawn: behind a wall or door"), "someone behind a wall is not drawn")
    check(not drawn(envw), "...no body and no name tag")
    envw.files["re7mp_in.json"].x = 3
    live(envw, 1.5)
    check(drawn(envw), "in front of the wall they are drawn again")
    envw.files["re7mp_in.json"].x = 8
    live(envw, 1.5)
    check(not drawn(envw), "...and hidden when they step behind it")
    envw.check_override["Hide them behind walls and doors"] = false
    run_ui(envw)
    live(envw, 0.5)
    check(drawn(envw), "with the box unticked they are always drawn")
    run_ui(envw)
    check(ui_has(envw, "walls: switched off"), "...and the panel says the test is off")
    local dw = envw.files["re7mp_debug.json"]
    check(dw and dw.health.occlusion and dw.health.occlusion.layers[1] == 3 and dw.health.occlusion.rays > 30, "the debug file says which layers were used and how many rays were cast")

    local envb = world()
    envb.wall_x = 5
    envb.physics_broken = true
    envb.files["re7mp_in.json"].x = 8
    live(envb, 3)
    run_ui(envb)
    check(ui_has(envb, "walls: unavailable"), "when the physics call fails the panel says so")
    check(drawn(envb), "...and the stand-in is simply drawn as before")

    local envn = world()
    envn.floor_layers = {}
    envn.wall_x = 5
    envn.files["re7mp_in.json"].x = 8
    live(envn, 8)
    run_ui(envn)
    check(ui_has(envn, "walls: unavailable (no collision layer found the floor)"), "when no layer finds the floor the test gives up and says so")
    check(drawn(envn), "...and does not hide anyone")

    -- right next to you nothing can be in the way, whatever the wall test would say
    local envx = world()
    envx.wall_x = 0.5
    envx.files["re7mp_in.json"].x, envx.files["re7mp_in.json"].z = 1.0, 0
    live(envx, 3)
    check(drawn(envx), "within about a metre they are never hidden by a wall")

    -- ---- game menus ----
    local envm = world()
    local vis = { hud = true, inv = false, logo = true }
    local function mk_gui(name, key)
        local root = Obj.new("via.gui.Control", { get_Visible = function() return vis[key] end })
        local view = Obj.new("via.gui.View", { get_RootWindow = function() return root end })
        local gui, go
        gui = Obj.new("via.gui.GUI", { get_GameObject = function() return go end, get_View = function() return view end })
        go = make_go(name, vec(0, 0, 0), { gui })
        return gui
    end
    envm.guis = { mk_gui("GUI_HUD_Main", "hud"), mk_gui("InventoryMenu", "inv"), mk_gui("TitleLogo", "logo") }
    envm.scene.m["findComponents(System.Type)"] = function(_, t) return { get_elements = function() return t == "via.gui.GUI" and envm.guis or {} end } end
    live(envm, 3)
    check(drawn(envm), "no menu open: they are drawn (an always-showing HUD or logo GUI is not a menu)")
    vis.inv = true
    live(envm, 1)
    run_ui(envm)
    check(ui_has(envm, "Other player not drawn: a game menu is open (InventoryMenu)"), "a GUI that was hidden and now shows, with a menu-like name, hides them")
    check(not drawn(envm), "...no body and no name tag over the inventory")
    vis.inv = false
    live(envm, 1.5)
    check(drawn(envm), "closing the menu brings them back")
    local dm = envm.files["re7mp_debug.json"]
    local seen_inv
    for _, row in ipairs(dm and dm.health.menus and dm.health.menus.guis_watched or {}) do
        if row.path == "InventoryMenu" then seen_inv = row end
    end
    check(seen_inv and seen_inv.seen_hidden and seen_inv.seen_showing and seen_inv.counts_as_menu, "the debug file lists every GUI it watched and what it saw")
    envm.check_override["Hide them while a game menu is open (EXPERIMENTAL)"] = false
    run_ui(envm)
    vis.inv = true
    live(envm, 1)
    check(drawn(envm), "with the menu box unticked they stay drawn")
    -- solo play costs nothing: with nobody connected no GUI is looked at
    local envs = new_environment()
    build_world(envs)
    load_script(envs)
    envs.guis = { mk_gui("InventoryMenu", "inv") }
    local scans = 0
    envs.scene.m["findComponents(System.Type)"] = function() scans = scans + 1 return { get_elements = function() return {} end } end
    run_frames(envs, 3)
    check(scans == 0, "no GUI scan without a remote player")
end


-- =============================================================================================
-- Scenario 16 (9.11): what the first real debug file (build 9.9) and the notes showed
--   journal, menus (MapMask), heal vs inventory, IsCrouch, Pl2000, give / drop answers, death hooks, wall test variants
-- =============================================================================================
do
    local HK = "<actionID>k__BackingField"
    local function live(env, secs)
        for _ = 1, math.floor(secs / 0.05 + 0.5) do run_frames(env, 0.05) bump_remote(env) end
    end
    local function out_flags(env) return (env.files["re7mp_out.json"] or {}).flags end
    local function bit(flags, b) return math.floor(flags / b) % 2 == 1 end
    local function world(settings, with_pose, pre)
        local env = new_environment()
        build_world(env)
        if pre then pre(env) end
        if with_pose then
            add_pose_components(env)
            -- the real field is IsCrouch (the 9.9 file); the camera height is only the fallback
            make_td("app.PlayerMovement", { fields = { { "IsCrouching", "System.Boolean" }, { "StanceType", "System.Int32" },
                { "Speed", "System.Single" }, { "IsCrouch", "System.Boolean" }, { "CrouchRate", "System.Single" } } })
        end
        env.files["re7mp_settings.json"] = settings or {}
        load_script(env)
        host_role_files(env, "host", "tcp")
        return env
    end
    local function refresh_debug(env)
        env.ui_press["Hide them for 60 s"] = true
        run_ui(env)
        live(env, 2.3)
        env.ui_press["Show them now"] = true
        run_ui(env)
    end
    local function last_of(env, kind) local m = messages_of_kind(env, kind) return m[#m] end
    -- (the version nag "Bob's script is older ..." also has his name in it, once it has been 12 s without his version message)
    local function drawn(e)
        e.texts = {}
        live(e, 0.4)
        for _, t in ipairs(e.texts) do
            if t:find("Bob", 1, true) and not t:find("script", 1, true) then return true end
        end
        return false
    end
    local function log_count(env, needle)
        local n = 0
        for _, l in ipairs(env.log) do if l:find(needle, 1, true) then n = n + 1 end end
        return n
    end

    -- ---- the journal: give / drop / death / menu lines are kept apart from the tracer's flood ----
    local envj = world()
    live(envj, 1)
    push_msgs(envj, { { 5, "Herb|2" } })
    live(envj, 0.5)
    local BTN9 = "9. Cutscene / event trace (press, then trigger a cutscene, open a door)"
    envj.check_override["    9+ also trace doors (app.DoorPush and app.InteractObjectBase, hand-picked methods only)##xdoors"] = true
    run_ui(envj)
    envj.ui_press[BTN9] = true
    run_ui(envj)
    local door_go = make_go("sm9180_Door07A_1WayDoor", vec(0, 0, 0))
    local door = Obj.new("app.DoorPush", { get_GameObject = function() return door_go end })
    for i = 1, 600 do
        envj.hooks["app.DoorPush.playClosed"]({ 0, door })
        if i % 10 == 0 then live(envj, 0.05) end
    end
    refresh_debug(envj)
    local dj = envj.files["re7mp_debug.json"]
    local ev_has, ev_trace, any_trace = false, false, false
    for _, l in ipairs(dj and dj.events or {}) do
        if l:find("gave you Herb x2", 1, true) then ev_has = true end
        if l:find("[trace]", 1, true) then ev_trace = true end
    end
    for _, l in ipairs(dj and dj.lines or {}) do if l:find("[trace]", 1, true) then any_trace = true end end
    check(dj and type(dj.events) == "table" and ev_has, "the debug file has an 'events' journal with the give line in it")
    check(any_trace and not ev_trace, "...the tracer's lines are in 'lines' but never in the journal (so a trace cannot push the give / drop lines out)")
    check(#(dj and dj.events or {}) <= 600, "...and the journal is capped at 600 lines")
    local flood = {}
    for _ = 1, 700 do flood[#flood + 1] = { 5, "Herb|1" } end
    push_msgs(envj, flood)
    live(envj, 1)
    refresh_debug(envj)
    check(#envj.files["re7mp_debug.json"].events == 600, "...and a flood of 700 gifts fills it to exactly 600 (the newest): " .. #envj.files["re7mp_debug.json"].events)

    -- ---- give / drop answers: the receiver ----
    local envg = world()
    live(envg, 1.5)
    calls = {}
    push_msgs(envg, { { 5, "Herb|2" } })
    live(envg, 0.5)
    check(last_of(envg, 10) == "g|Herb|2|ok|in the inventory", "a gift that went into the inventory is answered 'ok': " .. tostring(last_of(envg, 10)))
    envg.inventory_full = true
    calls = {}
    push_msgs(envg, { { 5, "Gunpowder|1" } })
    live(envg, 0.5)
    local a = last_of(envg, 10) or ""
    check(a:match("^g|Gunpowder|1|ok|on the ground %(inventory full%)$") ~= nil, "a gift that had to lie on the ground is answered 'ok' with the reason: " .. a)
    envg.singletons["app.ItemManager"].m.createDropItemInstance = function() error("boom") end
    push_msgs(envg, { { 5, "Herb|1" } })
    live(envg, 0.5)
    a = last_of(envg, 10) or ""
    check(a:match("^g|Herb|1|fail|") ~= nil, "a gift that could be neither added nor dropped is answered 'fail': " .. a)
    push_msgs(envg, { { 6, "Coin|1|1.00|0.00|2.00" } })
    live(envg, 0.5)
    a = last_of(envg, 10) or ""
    check(a:match("^d|Coin|1|fail|") ~= nil, "a drop that could not be shown is answered 'fail': " .. a)
    envg.singletons["app.ItemManager"].m.createDropItemInstance = function(_, who, id, n)
        calls[#calls + 1] = string.format("ItemManager.createDropItemInstance %s %d", tostring(id), n)
        return make_go("sm1800_" .. id .. "_Item", vec(0.4, 0, 0.5))
    end
    push_msgs(envg, { { 6, "Coin|1|1.00|0.00|2.00" } })
    live(envg, 0.5)
    check(last_of(envg, 10) == "d|Coin|1|ok|on the ground", "a drop that was shown is answered 'ok': " .. tostring(last_of(envg, 10)))
    -- ---- 9.13: the game's creation calls answer NOTHING (the real file: "createItemInstance failed: nil") ----
    local envn = world()
    live(envn, 1.5)
    local imn = envn.singletons["app.ItemManager"]
    local made = 0
    imn.m.createItemInstance = function(_, who, id) made = made + 1 calls[#calls + 1] = "ItemManager.createItemInstance " .. tostring(id) return nil end
    imn.m.createDropItemInstance = function(_, who, id, n) calls[#calls + 1] = string.format("ItemManager.createDropItemInstance %s %d", tostring(id), n) return nil end
    calls = {}
    push_msgs(envn, { { 5, "Herb|2" } }) -- the inventory holds Herb x3
    live(envn, 0.5)
    check(made == 2, "when the creation call answers nothing it is tried with the plain and the managed name, and with the player only: " .. made)
    check(last_of(envn, 10) == "g|Herb|2|ok|added to the stack you already have", "...and the item you already have grows: " .. tostring(last_of(envn, 10)))
    check(envn.entries[1].f.Item.stack == 5, "...the Herb stack went from 3 to 5")
    check(not calls_have("createDropItemInstance"), "...and nothing is dropped on the ground")
    check(log_has(envn, "give probe (the item could not be created)"), "the failed creation writes the probe: what the game says about the item name")
    check(log_has(envn, "give probe: copy 1, the managed singleton (in use): findItemData -> error"), "...and it lists every copy of the item manager and which one is in use")
    local function probes() local n = 0 for _, l in ipairs(envn.log) do if l:find("give probe (", 1, true) then n = n + 1 end end return n end
    push_msgs(envn, { { 5, "Coin|1" } }) -- nothing to add it to
    live(envn, 0.5)
    local an = last_of(envn, 10) or ""
    check(an:match("^g|Coin|1|fail|") ~= nil and an:find("gave nothing", 1, true), "an item that can neither be created nor added to a stack is answered 'fail' with the reason: " .. an)
    check(an:find("no Coin in the inventory", 1, true), "...which says there was nothing to add it to: " .. an)
    envn.max_stack = 5
    push_msgs(envn, { { 5, "Herb|2" } })
    live(envn, 0.5)
    an = last_of(envn, 10) or ""
    check(an:match("^g|Herb|2|fail|") ~= nil and an:find("is full (5/5)", 1, true), "a stack that would overflow is not touched: " .. an)
    check(envn.entries[1].f.Item.stack == 5, "...it is still 5")
    check(probes() == 1, "the probe is written once: more failures within a minute do not write it again (" .. probes() .. ")")
    envn.max_stack = nil
    envn.stack_ignore = true
    push_msgs(envn, { { 5, "Herb|1" } })
    live(envn, 0.5)
    an = last_of(envn, 10) or ""
    check(an:match("^g|Herb|1|fail|") ~= nil and an:find("would not change", 1, true), "a stack that does not change when asked to is reported as failed, not claimed: " .. an)
    envn.stack_ignore = nil
    push_msgs(envn, { { 6, "Coin|1|1.00|0.00|2.00" } })
    live(envn, 0.5)
    an = last_of(envn, 10) or ""
    check(an:match("^d|Coin|1|fail|") ~= nil and an:find("gave nothing", 1, true), "a drop whose spawn call answered nothing is answered 'fail', not 'on the ground': " .. an)
    run_ui(envn)
    check(not ui_has(envn, "it is on the ground here too"), "...and the screen does not claim it appeared")
    check(log_has(envn, "give probe"), "the first failure writes what the game says about the item name into the log")
    do
        local d = envn.files["re7mp_debug.json"]
        envn.ui_press["Hide them for 60 s"] = true
        run_ui(envn)
        live(envn, 2.3)
        d = envn.files["re7mp_debug.json"]
        check(d and d.health.items and #d.health.items.failed_creations >= 1 and d.health.items.bumped_stacks == 1, "the debug file lists the failed creations and the stacks that were grown")
        local function any(list, needle)
            for _, l in ipairs(list or {}) do if l:find(needle, 1, true) then return true end end
            return false
        end
        check(any(d.lines, "    give probe:"), "(the full log has the probe's indented lines)")
        check(any(d.events, "give probe (") and not any(d.events, "    give probe:"), "the journal has the probe's headline but none of its indented lines")
        local coins = {}
        for i = 1, 14 do coins[#coins + 1] = { 5, "Coin|1" } end
        push_msgs(envn, coins)
        live(envn, 1.0)
        envn.ui_press["Hide them for 60 s"] = true
        run_ui(envn)
        live(envn, 2.3)
        d = envn.files["re7mp_debug.json"]
        check(#d.health.items.failed_creations == 12, "the list of failed creations keeps the last 12: " .. #d.health.items.failed_creations)
        live(envn, 61)
        push_msgs(envn, { { 5, "Coin|1" } })
        live(envn, 0.5)
        check(probes() == 2, "...and after a minute the next failure writes the probe again (" .. probes() .. ")")
    end
    -- 9.14: only the player object is ever handed to the game's creation calls (9.12 and 9.13 also tried an item's own object)
    local envo = world()
    live(envo, 1.5)
    local imo = envo.singletons["app.ItemManager"]
    local owners_seen = {}
    imo.m.createItemInstance = function(_, who, id)
        owners_seen[#owners_seen + 1] = who:call("get_Name")
        return nil
    end
    imo.m.createDropItemInstance = function(_, who, id, n)
        owners_seen[#owners_seen + 1] = who:call("get_Name")
        return nil
    end
    calls = {}
    push_msgs(envo, { { 5, "Coin|2" } })
    live(envo, 0.5)
    local others = 0
    for _, o in ipairs(owners_seen) do if o ~= "Pl0000" then others = others + 1 end end
    check(#owners_seen >= 2 and others == 0, "creation is only ever tried with the player as the owner (" .. table.concat(owners_seen, ",") .. ")")
    local dg = envg.files["re7mp_debug.json"]
    -- ---- 9.13: WHICH item manager. The singleton was an empty shell in the real file (every create call answered nil); the
    -- real one is a component in the scene / on SystemObject. The copy that knows an item is the one used ----
    local function journal_has(env, needle)
        refresh_debug(env)
        for _, l in ipairs(env.files["re7mp_debug.json"].events or {}) do if l:find(needle, 1, true) then return true end end
        return false
    end
    local envq = world()
    live(envq, 1.5)
    local shell = envq.singletons["app.ItemManager"]
    shell.m.createItemInstance = function() calls[#calls + 1] = "shell.createItemInstance" return nil end
    shell.m.createDropItemInstance = function() calls[#calls + 1] = "shell.createDropItemInstance" return nil end
    local real_im = Obj.new("app.ItemManager", {
        findItemData = function(_, id) return Obj.new("app.ItemData", {}) end,
        createItemInstance = function(_, who, id)
            calls[#calls + 1] = "real.createItemInstance " .. tostring(id)
            return envq.make_item(id, 1)
        end,
        createDropItemInstance = function(_, who, id, n)
            calls[#calls + 1] = string.format("real.createDropItemInstance %s %d", tostring(id), n)
            return make_go("sm1800_" .. id .. "_Item", vec(0.4, 0, 0.5))
        end,
    })
    weapons_by_type["app.ItemManager"] = { real_im }
    calls = {}
    push_msgs(envq, { { 5, "Herb|2" } })
    live(envq, 0.5)
    check(calls_have("real.createItemInstance Herb") and not calls_have("shell.createItemInstance"),
        "the item manager that knows the items (a scene component) is used, not the empty singleton")
    check(calls_have("Inventory.addItem Herb x2") and last_of(envq, 10) == "g|Herb|2|ok|in the inventory", "...and the gift lands: " .. tostring(last_of(envq, 10)))
    calls = {}
    push_msgs(envq, { { 6, "Coin|1|1.00|0.00|2.00" } })
    live(envq, 0.5)
    check(calls_have("real.createDropItemInstance Coin 1") and not calls_have("shell.createDropItemInstance"), "...and a drop is created with it too")
    refresh_debug(envq)
    local dim = envq.files["re7mp_debug.json"].health.items.item_manager
    check(dim and dim.knows_items == true and tostring(dim.in_use):find("scene", 1, true) ~= nil, "the file says which copy is in use and that it knows items: " .. tostring(dim and dim.in_use))
    check(dim and #dim.copies >= 2 and dim.copies[1].knows_items == true, "...and lists every copy that was looked at")
    check(journal_has(envq, "item manager: using a component found in the scene (it knows the items)"), "...and the journal says so once")

    -- when none of the copies knows an item the first one is still tried, and the file says plainly that none knew
    local envr = world()
    live(envr, 1.5)
    weapons_by_type["app.ItemManager"] = {}
    calls = {}
    push_msgs(envr, { { 5, "Herb|1" } })
    live(envr, 0.5)
    check(calls_have("ItemManager.createItemInstance Herb"), "no copy knows an item: the first copy is tried anyway")
    refresh_debug(envr)
    check(envr.files["re7mp_debug.json"].health.items.item_manager.knows_items == false, "...and the file says that none knew an item")
    check(journal_has(envr, "NONE of the copies knows an item"), "...with a journal line")
    for _ = 1, 2 do -- (the search repeats after 15 s and after 30 s: the journal line is not repeated with it)
        live(envr, 40)
        push_msgs(envr, { { 5, "Herb|1" } })
        live(envr, 0.5)
    end
    local said_n = 0
    refresh_debug(envr)
    for _, l in ipairs(envr.files["re7mp_debug.json"].events or {}) do if l:find("item manager: using", 1, true) then said_n = said_n + 1 end end
    check(said_n == 1, "'item manager: using ...' is written once even though the search repeats (" .. said_n .. ")")

    -- the game's own creation call hands over the real copy, and that one wins from then on
    local envs2 = world()
    live(envs2, 1.5)
    weapons_by_type["app.ItemManager"] = {}
    local game_im = Obj.new("app.ItemManager", {
        findItemData = function() return Obj.new("app.ItemData", {}) end,
        createItemInstance = function(_, who, id) calls[#calls + 1] = "game.createItemInstance " .. tostring(id) return envs2.make_item(id, 1) end,
        createDropItemInstance = function() return nil end,
    })
    push_msgs(envs2, { { 5, "Herb|1" } }) -- (a first gift, so the empty singleton is the cached copy, and the search waits 15 s)
    live(envs2, 0.5)
    envs2.hooks["app.ItemManager.createItemInstance"]({ 0, game_im, envs2.player })
    calls = {}
    push_msgs(envs2, { { 5, "Herb|1" } })
    live(envs2, 0.5)
    check(calls_have("game.createItemInstance Herb"), "the copy the game's own createItemInstance used is taken over at once, not after the wait")
    -- ...but only as 'knows items' if it does
    local envs3 = world()
    live(envs3, 1.5)
    envs3.hooks["app.ItemManager.createItemInstance"]({ 0, Obj.new("app.ItemManager", {}), envs3.player })
    refresh_debug(envs3)
    local ims3 = envs3.files["re7mp_debug.json"].health.items.item_manager
    check(ims3.knows_items ~= true and tostring(ims3.in_use):find("game's own", 1, true) == nil, "a copy handed over by the game that knows no item is not adopted")
    push_msgs(envs3, { { 5, "Herb|1" } })
    live(envs3, 0.5)
    refresh_debug(envs3)
    local own_listed = false
    for _, c in ipairs(envs3.files["re7mp_debug.json"].health.items.item_manager.copies or {}) do
        if tostring(c.how):find("game's own", 1, true) then own_listed = true end
    end
    check(not own_listed, "...nor is it even among the candidates when it knows nothing")
    -- a copy that works is not replaced by the next one the game hands over
    local envs4 = world()
    live(envs4, 1.5)
    local function knowing_im(tag)
        return Obj.new("app.ItemManager", {
            findItemData = function() return Obj.new("app.ItemData", {}) end,
            createItemInstance = function(_, who, id) calls[#calls + 1] = tag .. ".createItemInstance " .. tostring(id) return envs4.make_item(id, 1) end,
            createDropItemInstance = function() return nil end,
        })
    end
    weapons_by_type["app.ItemManager"] = { knowing_im("first") }
    push_msgs(envs4, { { 5, "Herb|1" } })
    live(envs4, 0.5)
    envs4.hooks["app.ItemManager.createItemInstance"]({ 0, knowing_im("other"), envs4.player })
    calls = {}
    push_msgs(envs4, { { 5, "Herb|1" } })
    live(envs4, 0.5)
    check(calls_have("first.createItemInstance Herb") and not calls_have("other.createItemInstance Herb"), "a copy that already works is not replaced by the next one the game hands over")
    weapons_by_type["app.ItemManager"] = {}

    -- the manager on the object SystemObject is found by walking the scene when no component turns up in the lookup
    local envy = world()
    live(envy, 1.5)
    local sys_im = Obj.new("app.ItemManager", {
        findItemData = function() return Obj.new("app.ItemData", {}) end,
        createItemInstance = function(_, who, id) calls[#calls + 1] = "sysobj.createItemInstance " .. tostring(id) return envy.make_item(id, 1) end,
        createDropItemInstance = function() return nil end,
    })
    weapons_by_type["app.ItemManager"] = {}
    table.insert(envy.scene_objects, make_go("SystemObject", vec(0, 0, 0), { sys_im }))
    envy.scene = make_scene(envy.scene_objects)
    calls = {}
    push_msgs(envy, { { 5, "Herb|1" } })
    live(envy, 0.5)
    check(calls_have("sysobj.createItemInstance Herb"), "the item manager on SystemObject is found and used")
    refresh_debug(envy)
    check(tostring(envy.files["re7mp_debug.json"].health.items.item_manager.in_use):find("SystemObject", 1, true) ~= nil, "...and the file names SystemObject as the source")

    -- a manager that turns up late is picked up after the wait (the search backs off, it does not run every frame)
    local envz = world()
    live(envz, 1.5)
    weapons_by_type["app.ItemManager"] = {}
    calls = {}
    push_msgs(envz, { { 5, "Herb|1" } })
    live(envz, 0.5)
    check(calls_have("ItemManager.createItemInstance Herb"), "at first only the empty singleton is there and it is tried")
    local late_im = Obj.new("app.ItemManager", {
        findItemData = function() return Obj.new("app.ItemData", {}) end,
        createItemInstance = function(_, who, id) calls[#calls + 1] = "late.createItemInstance " .. tostring(id) return envz.make_item(id, 1) end,
        createDropItemInstance = function() return nil end,
    })
    weapons_by_type["app.ItemManager"] = { late_im }
    calls = {}
    push_msgs(envz, { { 5, "Herb|1" } })
    live(envz, 1.0)
    check(not calls_have("late.createItemInstance"), "...the search is not repeated every second")
    live(envz, 20)
    calls = {}
    push_msgs(envz, { { 5, "Herb|1" } })
    live(envz, 0.5)
    check(calls_have("late.createItemInstance Herb"), "...but a late manager that knows the items is taken over after the wait")

    -- the journal says which manager is in use once, not with every gift
    local using = 0
    for i = 1, 3 do
        push_msgs(envq, { { 5, "Herb|1" } })
        live(envq, 0.3)
    end
    refresh_debug(envq)
    for _, l in ipairs(envq.files["re7mp_debug.json"].events or {}) do if l:find("item manager: using", 1, true) then using = using + 1 end end
    check(using == 1, "'item manager: using ...' is written once, not with every gift (" .. using .. ")")

    -- ---- 9.13: discard. The menu's own discardItem(item) -> Boolean is hooked; every discard-like call leaves a journal line ----
    local envd = world()
    live(envd, 1.5)
    check(envd.hooks["app.InventoryMenu.discardItem"] ~= nil and envd.posthooks["app.InventoryMenu.discardItem"] ~= nil, "the menu's discardItem is hooked (before and after)")
    calls = {}
    local coin = envd.make_item("Coin", 2)
    envd.hooks["app.InventoryMenu.discardItem"]({ 0, 0, coin })
    envd.posthooks["app.InventoryMenu.discardItem"](1)
    live(envd, 0.6)
    check(calls_have("ItemManager.createDropItemInstance Coin 2"), "a discard the menu accepted puts the item on the ground")
    check(#messages_of_kind(envd, 6) == 1, "...and tells the other player once")
    check(journal_has(envd, "discard: discardItem: Coin x2 will be put on the ground"), "...with a journal line")
    -- the same discard also runs reduceNum: still only one drop
    calls = {}
    local sent_before = #messages_of_kind(envd, 6)
    local coin2 = envd.make_item("Gold", 1)
    envd.hooks["app.Item.isCanDiscard"]({ 0, coin2 })
    envd.hooks["app.InventoryMenu.discardItem"]({ 0, 0, coin2 })
    envd.posthooks["app.InventoryMenu.discardItem"](1)
    envd.hooks["app.Item.reduceNum"]({ 0, coin2, 1, envd.player })
    live(envd, 0.6)
    check(#messages_of_kind(envd, 6) == sent_before + 1, "discardItem and reduceNum for the same discard drop it only once")
    check(journal_has(envd, "reduceNum: Gold x1 is already queued"), "...and the journal says the second one was recognised")
    -- a refused discard drops nothing
    calls = {}
    envd.hooks["app.InventoryMenu.discardItem"]({ 0, 0, envd.make_item("Knife", 1) })
    envd.posthooks["app.InventoryMenu.discardItem"](0)
    live(envd, 0.6)
    check(not calls_have("createDropItemInstance Knife"), "a discard the menu refused drops nothing")
    check(journal_has(envd, "discardItem(Knife) answered no"), "...and the journal says why")
    -- reduceNum without the menu having been used: logged, nothing dropped
    calls = {}
    envd.clock = envd.clock + 60
    live(envd, 0.2)
    envd.hooks["app.Item.reduceNum"]({ 0, envd.make_item("Herb", 1), 1, envd.player })
    live(envd, 0.6)
    check(not calls_have("createDropItemInstance Herb"), "a reduceNum with no inventory menu in use drops nothing")
    check(journal_has(envd, "reduceNum(Herb x1) is not a discard I drop: the inventory menu was not used"), "...and the journal says why")
    refresh_debug(envd)
    local dd = envd.files["re7mp_debug.json"].health.items.discard
    check(dd and dd.menu_discard_hooked == true and dd.menu_discard_calls == 3 and dd.reduceNum_calls == 2 and dd.switched_on == true, "the file counts the discard calls")
    -- the same item discarded again later is a new discard (the dedup only covers the same discard seen by two hooks)
    calls = {}
    envd.hooks["app.InventoryMenu.discardItem"]({ 0, 0, envd.make_item("Gold", 1) })
    envd.posthooks["app.InventoryMenu.discardItem"](1)
    live(envd, 0.6)
    check(calls_have("ItemManager.createDropItemInstance Gold 1"), "the same item discarded again a minute later is dropped again")
    -- with 'Discard drops the item' switched off the menu's answer is logged but nothing is dropped
    local envf = world({ drop_on_discard = false })
    live(envf, 1.5)
    calls = {}
    envf.hooks["app.InventoryMenu.discardItem"]({ 0, 0, envf.make_item("Coin", 1) })
    envf.posthooks["app.InventoryMenu.discardItem"](1)
    live(envf, 0.6)
    check(not calls_have("createDropItemInstance") and journal_has(envf, "switched off"), "with the setting off the discard is only logged")
    -- an error in the hook does not flood: getExtendLevelState passes a number as args[2] in this game
    local envx = world()
    live(envx, 1.5)
    for _ = 1, 20 do envx.hooks["app.Inventory.getExtendLevelState"]({ 0, 5 }) end
    local flood = 0
    for _, l in ipairs(envx.log) do if l:find("hook error", 1, true) then flood = flood + 1 end end
    check(flood == 0, "getExtendLevelState called with a number does not fill the log with errors (" .. flood .. ")")
    -- a hook that does fail logs at most three times
    envx.hooks["app.Item.reduceNum"]({ 0, nil, "x", nil })
    local fl = 0
    for _ = 1, 10 do
        envx.hooks["app.InventoryMenu.discardItem"](setmetatable({ 0, 0 }, { __index = function(_, k) if k == 3 then error("boom") end end }))
    end
    for _, l in ipairs(envx.log) do if l:find("hook error in discardItem", 1, true) then fl = fl + 1 end end
    check(fl == 3, "a hook that fails keeps exactly three error lines (" .. fl .. ")")
    -- the discard journal stops at 25 lines
    local envk = world()
    live(envk, 1.5)
    for i = 1, 40 do envk.hooks["app.Item.reduceNum"]({ 0, envk.make_item("Herb", 1), 1, envk.player }) end
    refresh_debug(envk)
    local dn = 0
    for _, l in ipairs(envk.files["re7mp_debug.json"].events or {}) do if l:find("discard: ", 1, true) then dn = dn + 1 end end
    check(dn == 25, "forty skipped reduceNum calls leave 25 discard lines in the journal (" .. dn .. ")")

    -- ---- 9.14: adding an item. The 9.13 file had "added" items that never reached the inventory: addItem was called with a nil
    -- list, its answer (an AddItemResult) was ignored, and the gift was reported as delivered. Now each form of addItem is tried,
    -- the answers are written down, and nothing counts as delivered unless the inventory holds more of the item than before ----
    local function stack_of(env, id)
        for _, e in ipairs(env.entries) do if e.f.Item.id == id then return e.f.Item.stack or 1 end end
        return 0
    end
    local enva = world()
    live(enva, 1.5)
    enva.two_arg_add = true
    push_msgs(enva, { { 5, "Coin|2" } })
    live(enva, 0.5)
    check(last_of(enva, 10) == "g|Coin|2|ok|in the inventory" and stack_of(enva, "Coin") == 2, "a gift is really in the inventory afterwards (Coin x2): " .. tostring(last_of(enva, 10)))
    refresh_debug(enva)
    check(enva.files["re7mp_debug.json"].health.items.add_worked_with == "addItem(item, player)", "the 2-parameter addItem is tried first: " .. tostring(enva.files["re7mp_debug.json"].health.items.add_worked_with))
    check(enva.add_owner == enva.player, "...with the player as the owner")
    local laa = enva.files["re7mp_debug.json"].health.items.last_add
    check(laa and laa.id == "Coin" and laa.form == "addItem(item, player)" and tostring(laa.answered):find("-> 0", 1, true) ~= nil,
        "the file keeps what the add that worked answered: " .. tostring(laa and laa.answered))
    local envb2 = world()
    live(envb2, 1.5)
    push_msgs(envb2, { { 5, "Coin|2" } })
    live(envb2, 0.5)
    refresh_debug(envb2)
    check(stack_of(envb2, "Coin") == 2 and envb2.files["re7mp_debug.json"].health.items.add_worked_with == "addItem(item, player, false, no list)", "...then the 4-parameter form without a list")
    check(journal_has(envb2, "add: it took 2 tries"), "...and the journal says how many tries it took")
    local envc = world()
    live(envc, 1.5)
    envc.add_needs_list = true
    push_msgs(envc, { { 5, "Coin|2" } })
    live(envc, 0.5)
    refresh_debug(envc)
    check(stack_of(envc, "Coin") == 2 and envc.files["re7mp_debug.json"].health.items.add_worked_with == "addItem(item, player, false, new list)", "...then the form with a new list (for a game that refuses a nil list)")
    -- a gift onto a stack you already have is a gain too
    push_msgs(envc, { { 5, "Herb|2" } })
    live(envc, 0.5)
    check(stack_of(envc, "Herb") == 5 and last_of(envc, 10) == "g|Herb|2|ok|in the inventory", "a gift of a Herb onto the Herb stack (3 + 2) lands")
    -- addItem that answers but adds nothing: not delivered, and the answers are in the file
    local envd2 = world()
    live(envd2, 1.5)
    envd2.add_refuses = true
    calls = {}
    push_msgs(envd2, { { 5, "Coin|2" } })
    live(envd2, 0.5)
    local ans = last_of(envd2, 10) or ""
    check(stack_of(envd2, "Coin") == 0 and not ans:match("^g|Coin|2|ok|in the inventory"), "an addItem that adds nothing is never reported as 'in the inventory': " .. ans)
    check(ans:match("^g|Coin|2|ok|on the ground") ~= nil, "...it lies on the ground instead and the answer says so: " .. ans)
    refresh_debug(envd2)
    local la = envd2.files["re7mp_debug.json"].health.items.last_add
    check(la and la.form == "none worked" and tostring(la.answered):find("addItem(item, player, false, new list) -> 1", 1, true) ~= nil, "the file keeps what each form answered: " .. tostring(la and la.answered))
    check(journal_has(envd2, "add: Coin x2 was created but not added"), "...and the journal has a line for it")
    -- the AddItemResult names are read from the type when the game has it
    -- isAddItem answering the enum value whose name says "full" is read as a full inventory, and the file names the value
    local enve = world()
    make_td("app.Inventory.AddItemResult", { fields = { { "Success", "System.Int32", static = true, value = 0 }, { "Full", "System.Int32", static = true, value = 3 } } })
    live(enve, 1.5)
    enve.add_refuses = true
    enve.is_add_result = 3
    push_msgs(enve, { { 5, "Coin|2" } })
    live(enve, 0.5)
    check((last_of(enve, 10) or ""):find("on the ground (inventory full)", 1, true) ~= nil, "isAddItem answering the value named Full is read as 'inventory full': " .. tostring(last_of(enve, 10)))
    refresh_debug(enve)
    local lae = enve.files["re7mp_debug.json"].health.items.last_add
    check(lae and lae.isAddItem == "Full=3", "...and the file names the value: " .. tostring(lae and lae.isAddItem))
    -- an inventory that cannot be read cannot confirm anything: the first form that does not fail is taken as done, a failing one is not
    local envu = world()
    live(envu, 1.5)
    envu.inventory.f._ItemList = nil
    push_msgs(envu, { { 5, "Coin|2" } })
    live(envu, 0.5)
    refresh_debug(envu)
    check((envu.add_calls or 0) == 1 and envu.files["re7mp_debug.json"].health.items.add_worked_with == "addItem(item, player, false, no list)",
        "an unreadable inventory: the form that errors is skipped, the next one that does not is taken (" .. tostring(envu.add_calls) .. ")")
    check((last_of(envu, 10) or ""):find("can't be read to check", 1, true) ~= nil, "...and the answer says it could not be checked: " .. tostring(last_of(envu, 10)))
    -- the crumb names the form being tried before addItem runs
    local envf = world()
    live(envf, 1.5)
    local add_stage
    local base_add = envf.inventory.m.addItem
    envf.inventory.m.addItem = function(self, ...)
        local c = envf.files["re7mp_lastcall.json"]
        add_stage = c and (c.stage .. ": " .. tostring(c.call)) or "none"
        return base_add(self, ...)
    end
    push_msgs(envf, { { 5, "Coin|2" } })
    live(envf, 0.5)
    check(add_stage == "give: adding Coin x2 to the inventory: addItem(item, player, false, no list)", "a crumb names the addItem form before it runs: " .. tostring(add_stage))

    -- ---- 9.14: a dropped item must be drawn, placed in front of the player and let go of the player ----
    local envp = world()
    live(envp, 1.5)
    local pm = envp.singletons["app.ItemManager"]
    local drop_drawn, parent_set = false, false
    local dgo
    pm.m.createDropItemInstance = function(_, who, id, n)
        dgo = make_go("sm1800_" .. id .. "_Item", vec(0, 0, 0))
        dgo.m.get_DrawSelf = function() return drop_drawn end
        dgo.m.set_DrawSelf = function(_, v) drop_drawn = v calls[#calls + 1] = "drop.set_DrawSelf " .. tostring(v) end
        dgo.m.get_UpdateSelf = function() return true end
        dgo.m.set_UpdateSelf = function(_, v) calls[#calls + 1] = "drop.set_UpdateSelf " .. tostring(v) end
        dgo.xf.m.get_Parent = function() return envp.player.xf end
        dgo.xf.m.set_Parent = function(_, v) parent_set = (v == nil) calls[#calls + 1] = "drop.set_Parent " .. tostring(v) end
        return dgo
    end
    envp.player.set_rot({ x = 0, y = 0.7071, z = 0, w = 0.7071 }) -- the player faces +x
    local function hit_local(env, new_hp)
        local hi = env.player_hi
        env.hooks["app.HealthInfo.set_health"]({ 0, hi })
        hi.f._CurrentHealth = new_hp
        env.posthooks["app.HealthInfo.set_health"](nil)
    end
    calls = {}
    push_msgs(envp, { { 6, "Coin|1|5.00|0.00|6.00" } })
    live(envp, 0.5)
    check(last_of(envp, 10) == "d|Coin|1|ok|on the ground", "a hidden drop is made visible: " .. tostring(last_of(envp, 10)))
    check(calls_have("drop.set_DrawSelf true") and parent_set, "...it is drawn, and let go of the player it was made under")
    check(calls_have("drop.set_UpdateSelf true"), "...and it is switched on to update")
    check(calls_have("sm1800_Coin_Item.set_Position 5.00 0.00 6.00"), "...and put where the other player dropped it")
    calls = {}
    drop_drawn = false
    envp.hooks["app.InventoryMenu.discardItem"]({ 0, 0, envp.make_item("Gold", 1) })
    envp.posthooks["app.InventoryMenu.discardItem"](1)
    live(envp, 0.6)
    check(calls_have("sm1800_Gold_Item.set_Position 0.80 0.10 0.00"), "my own discard lands 0.8 m in front of the player (facing +x), just above the floor")
    check(journal_has(envp, "drop: Gold x1: object was sm1800_Gold_Item parent=Pl0000 drawn=false"), "...with a journal line about what the object was and what it became")
    -- an object that sits under something else (a container) keeps its parent: only the player's is let go
    local envp2 = world()
    live(envp2, 1.5)
    local drawer = make_go("Drawer01", vec(3, 0, 3))
    local p2_cleared = false
    envp2.singletons["app.ItemManager"].m.createDropItemInstance = function(_, who, id, n)
        local g = make_go("sm1800_" .. id .. "_Item", vec(0, 0, 0))
        g.xf.m.get_Parent = function() return drawer.xf end
        g.xf.m.set_Parent = function() p2_cleared = true end
        return g
    end
    push_msgs(envp2, { { 6, "Coin|1|1.00|0.00|2.00" } })
    live(envp2, 0.5)
    check(last_of(envp2, 10) == "d|Coin|1|ok|on the ground" and not p2_cleared, "a dropped object under a container keeps its parent: " .. tostring(last_of(envp2, 10)))
    -- an object that stays hidden is not reported as dropped
    local envh = world()
    live(envh, 1.5)
    envh.singletons["app.ItemManager"].m.createDropItemInstance = function(_, who, id, n)
        local go = make_go("sm1800_" .. id .. "_Item", vec(0, 0, 0))
        go.m.get_DrawSelf = function() return false end
        go.m.set_DrawSelf = function() end
        return go
    end
    push_msgs(envh, { { 6, "Coin|1|1.00|0.00|2.00" } })
    live(envh, 0.5)
    check((last_of(envh, 10) or ""):match("^d|Coin|1|fail|") ~= nil, "a dropped object that stays hidden is answered 'fail', not 'ok': " .. tostring(last_of(envh, 10)))

    -- ---- 9.14: breadcrumbs around the item calls ----
    local envk2 = world()
    live(envk2, 1.5)
    local seen_stage
    local base_create = envk2.singletons["app.ItemManager"].m.createItemInstance
    envk2.singletons["app.ItemManager"].m.createItemInstance = function(self, who, id)
        local c = envk2.files["re7mp_lastcall.json"]
        seen_stage = c and (c.stage .. ": " .. tostring(c.call)) or "none"
        return base_create(self, who, id)
    end
    push_msgs(envk2, { { 5, "Coin|1" } })
    live(envk2, 0.5)
    check(seen_stage and seen_stage:find("^give: making Coin for the inventory") ~= nil, "a crumb names the item call before it is made: " .. tostring(seen_stage))
    check(envk2.files["re7mp_lastcall.json"].stage == "clean", "...and it is cleared when the item work is done (so an old crumb is never a false suspect)")
    local envk3 = new_environment()
    build_world(envk3)
    envk3.files["re7mp_lastcall.json"] = { stage = "give", call = "adding Herb x1 to the inventory: addItem(item, player)", session = 1, time = os.time() - 120, clock = 5 }
    load_script(envk3)
    host_role_files(envk3, "host", "tcp")
    live(envk3, 0.5)
    check(log_has(envk3, "previous session: The last session ended while the script was handling an item: adding Herb x1 to the inventory: addItem(item, player)"), "the next session reports an item call that was the last thing it did")
    local envk5 = new_environment()
    build_world(envk5)
    envk5.files["re7mp_lastcall.json"] = { stage = "revive", call = "finishing the F8 revive of Bob", session = 1, time = os.time() - 60, clock = 5 }
    load_script(envk5)
    host_role_files(envk5, "host", "tcp")
    live(envk5, 0.5)
    check(log_has(envk5, "previous session: The last session ended while the script was finishing an F8 revive: finishing the F8 revive of Bob"), "the next session reports a crash in the middle of an F8 revive")
    -- the lock's hook crumb no longer stays as the 'suspect' once the hooks are in
    local envk4 = world({ death_mode = 4 }, true)
    live(envk4, 1.5)
    hit_local(envk4, 0)
    live(envk4, 0.6)
    check(envk4.files["re7mp_lastcall.json"] and envk4.files["re7mp_lastcall.json"].stage == "clean", "after the lock's hooks are installed the crumb says 'clean', not 'hooking': " .. tostring(envk4.files["re7mp_lastcall.json"] and (envk4.files["re7mp_lastcall.json"].stage .. " " .. tostring(envk4.files["re7mp_lastcall.json"].call))))

    -- a player object that is not there yet: the gift waits in the inbox and is retried (a chapter change, Mia's chapters)
    local envw0 = world()
    local gone = envw0.scene_objects[1]
    table.remove(envw0.scene_objects, 1)
    envw0.scene = make_scene(envw0.scene_objects)
    live(envw0, 1.5)
    calls = {}
    push_msgs(envw0, { { 5, "Herb|2" } })
    live(envw0, 0.5)
    check(last_of(envw0, 10) == nil and not calls_have("Inventory.addItem"), "no player object yet: nothing is answered and nothing is lost, the gift waits")
    table.insert(envw0.scene_objects, 1, gone)
    envw0.scene = make_scene(envw0.scene_objects)
    live(envw0, 6)
    check(calls_have("Inventory.addItem Herb x2"), "...and when the player object turns up the gift is added")
    check(last_of(envw0, 10) == "g|Herb|2|ok|in the inventory", "...and only then answered: " .. tostring(last_of(envw0, 10)))
    local envw1 = world()
    table.remove(envw1.scene_objects, 1)
    envw1.scene = make_scene(envw1.scene_objects)
    live(envw1, 1.5)
    push_msgs(envw1, { { 5, "Herb|2" } })
    live(envw1, 7)
    a = last_of(envw1, 10) or ""
    check(a:match("^g|Herb|2|fail|") ~= nil, "a player object that never turns up ends in a 'fail' answer after a few tries, so the sender gets it back: " .. a)

    -- ---- give / drop answers: the sender ----
    local envs = world()
    live(envs, 0.5)
    local function give_one(env, id, n)
        calls = {}
        env.hooks["app.Item.isCanDiscard"]({ 0, env.make_item(id, n) })
        env.keys[0x76] = true
        live(env, 0.2)
        env.keys[0x76] = false
        live(env, 0.2)
    end
    give_one(envs, "Herb", 3)
    check(last_of(envs, 5) == "Herb|1" and not calls_have("Inventory.reduceItem"), "the Give hotkey sends the gift and takes NOTHING out of the inventory yet")
    run_ui(envs)
    check(ui_has(envs, "you offered Herb x1 to Bob: it leaves your inventory when they confirm they have it"), "...and says it waits for their answer")
    calls = {}
    push_msgs(envs, { { 10, "g|Herb|1|ok|in the inventory" } })
    live(envs, 0.3)
    run_ui(envs)
    check(ui_has(envs, "Bob has Herb x1 (in the inventory): it left your inventory"), "an 'ok' answer is shown")
    check(calls_have("Inventory.reduceItem Herb 1 true"), "...and only then is the item taken out of my inventory")
    check(not calls_have("Inventory.addItem"), "...nothing is handed back")
    refresh_debug(envs)
    check(envs.files["re7mp_debug.json"].health.items.sent_ok == 1, "...and it is counted as sent in the debug file")
    calls = {}
    push_msgs(envs, { { 10, "g|Herb|1|ok|in the inventory" } })
    live(envs, 0.3)
    check(not calls_have("Inventory.reduceItem"), "...and the same answer again takes nothing a second time (nothing is outstanding)")
    give_one(envs, "Herb", 3)
    calls = {}
    push_msgs(envs, { { 10, "g|Herb|1|fail|inventory object not found" } })
    live(envs, 0.3)
    run_ui(envs)
    check(not calls_have("Inventory.reduceItem") and not calls_have("Inventory.addItem"), "a 'fail' answer changes nothing: the item never left")
    check(ui_has(envs, "Bob could not take Herb x1 (inventory object not found): you keep it"), "...and the reason is shown")
    give_one(envs, "Herb", 3)
    calls = {}
    push_msgs(envs, { { 10, "g|Gunpowder|1|ok|x" }, { 10, "g|Herb|5|ok|x" } })
    live(envs, 0.3)
    check(not calls_have("Inventory.reduceItem"), "an answer about a different item or count does not touch this gift")
    live(envs, 10)
    run_ui(envs)
    check(ui_has(envs, "no answer from Bob about Herb x1: it stays in your inventory"), "a gift nobody answers is reported after 10 s, and nothing was taken")
    calls = {}
    push_msgs(envs, { { 10, "g|Herb|1|ok|late" } })
    live(envs, 0.3)
    check(not calls_have("Inventory.reduceItem"), "...and a late answer to it is ignored (nothing is taken after the report)")
    -- a drop
    calls = {}
    local focused = envs.make_item("Coin", 2)
    envs.hooks["app.Item.isCanDiscard"]({ 0, focused })
    envs.hooks["app.Item.reduceNum"]({ 0, focused, 2, envs.player })
    live(envs, 0.6)
    check(calls_have("createDropItemInstance Coin 2"), "a discard drops the item")
    calls = {}
    push_msgs(envs, { { 10, "g|Coin|2|ok|x" } })
    live(envs, 0.3)
    check(not calls_have("Inventory.reduceItem"), "an answer about a GIFT does not settle a DROP of the same item and count")
    push_msgs(envs, { { 10, "d|Coin|2|fail|nope" } })
    live(envs, 0.3)
    run_ui(envs)
    check(ui_has(envs, "Bob could not show the Coin x2 you dropped (nope)"), "a 'fail' answer about a drop is shown")
    -- garbage answers do nothing
    push_msgs(envs, { { 10, "zzz" }, { 10, "g|x|y|z" }, { 10, "" } })
    live(envs, 0.3)
    check(true, "malformed answers are ignored without an error")
    local dgs = envs.files["re7mp_debug.json"]

    -- ---- Mia is Pl2000: the player object is the one nearest the camera, whatever it is called ----
    local envm = world(nil, false, function(env)
        local ghost = make_go("Pl0000", vec(50, 0, 50), {})
        local mia = make_go("Pl2000", vec(0, 0, 0), env.player:call("get_Components"):get_elements())
        env.scene_objects = { ghost, mia, table.unpack(env.scene_objects, 2) }
        env.scene = make_scene(env.scene_objects)
    end)
    live(envm, 1.5)
    calls = {}
    push_msgs(envm, { { 5, "Herb|2" } })
    live(envm, 0.5)
    check(calls_have("Inventory.addItem Herb x2"), "with a Pl0000 far away and Pl2000 at the camera, the gift goes to the one being played")
    check(log_has(envm, "player object: Pl2000 (2 found)"), "...and the journal says which player object was taken")
    -- only Mia in the scene: found as well
    local envm2 = world(nil, false, function(env)
        env.scene_objects[1] = make_go("Pl2000", vec(0, 0, 0), env.player:call("get_Components"):get_elements())
        env.scene = make_scene(env.scene_objects)
    end)
    live(envm2, 1.5)
    calls = {}
    push_msgs(envm2, { { 5, "Herb|1" } })
    live(envm2, 0.5)
    check(calls_have("Inventory.addItem Herb x1"), "a scene with only Pl2000 (Mia's chapters) works too")
    check(log_has(envm2, "player object: Pl2000 (1 found)"), "...and is journaled")

    -- ---- menus: MapMaskGUI is not a menu; real menu names are; a "menu" that stays up while you walk is dropped ----
    local vis = {}
    local function mk_gui(name, key)
        local root = Obj.new("via.gui.Control", { get_Visible = function() return vis[key] end })
        local view = Obj.new("via.gui.View", { get_RootWindow = function() return root end })
        local gui, go
        gui = Obj.new("via.gui.GUI", { get_GameObject = function() return go end, get_View = function() return view end })
        go = make_go(name, vec(0, 0, 0), { gui })
        return gui
    end
    local function menu_world(names, always_on)
        local env = world()
        vis = {}
        local list = {}
        for _, nm in ipairs(names) do
            vis[nm] = (always_on and always_on[nm]) or false
            list[#list + 1] = mk_gui(nm, nm)
        end
        env.guis = list
        env.scene.m["findComponents(System.Type)"] = function(_, t) return { get_elements = function() return t == "via.gui.GUI" and env.guis or {} end } end
        live(env, 3)
        return env
    end
    local envk = menu_world({ "MapMaskGUI", "GUI_HUD_Main", "PauseMenuGUI", "Gui_Menu", "TapeFade", "ChoiceMenu" }, { ChoiceMenu = true })
    check(drawn(envk), "a GUI with a real menu name that has been showing since the start and was never seen hidden is not a menu (ChoiceMenu)")
    vis.MapMaskGUI = true
    live(envk, 1.5)
    check(drawn(envk), "MapMaskGUI showing (it stays up after a tape): they stay drawn")
    run_ui(envk)
    check(not ui_has(envk, "Other player not drawn: a game menu is open"), "...and the panel does not call it a menu")
    vis.TapeFade = true
    live(envk, 1.5)
    check(drawn(envk), "a fade GUI is not a menu either")
    vis.PauseMenuGUI = true
    live(envk, 1)
    check(not drawn(envk), "PauseMenuGUI showing: hidden")
    vis.PauseMenuGUI = false
    live(envk, 1)
    vis.Gui_Menu = true
    live(envk, 1)
    check(not drawn(envk), "Gui_Menu showing: hidden")
    vis.Gui_Menu = false
    live(envk, 1)
    check(drawn(envk), "...and back when it closes (MapMaskGUI still showing the whole time)")
    refresh_debug(envk)
    local dk = envk.files["re7mp_debug.json"].health.menus
    check(dk and type(dk.ignored_as_not_menus) == "table", "the debug file has the list of GUIs dropped as 'not a menu'")

    -- a menu-like name that never closes while you walk is dropped after 6 s and 3 m
    local envn = menu_world({ "GUI_HUD_Main", "NotesBrowser", "VideoCameraUI", "InventoryMenu" })
    -- a menu that is open while the camera jumps (a cutscene) within 6 s is still a menu
    vis.InventoryMenu = true
    live(envn, 0.5)
    envn.camera_pos.x = 5
    live(envn, 1)
    check(not drawn(envn), "a real menu stays a menu when the camera moves within the first 6 s")
    vis.InventoryMenu = false
    live(envn, 1)
    envn.camera_pos.x = 0
    live(envn, 1)
    vis.NotesBrowser = true
    live(envn, 1)
    check(not drawn(envn), "a GUI named like a menu that just showed: hidden")
    live(envn, 6)
    envn.camera_pos.x = 5 -- walked 5 m
    live(envn, 1)
    check(drawn(envn), "...but after 6 s of you walking about it is not a menu: drawn again")
    check(log_has(envn, "menu: NotesBrowser is not a menu"), "...and the journal says so")
    refresh_debug(envn)
    local dn = envn.files["re7mp_debug.json"].health.menus
    check(dn.ignored_as_not_menus[1] == "NotesBrowser", "...and the debug file lists it")
    vis.NotesBrowser = false
    live(envn, 1)
    vis.NotesBrowser = true
    live(envn, 1)
    check(drawn(envn), "an ignored GUI stays ignored")
    -- the tape player may stay up while you walk about in the tape
    vis.VideoCameraUI = true
    live(envn, 1)
    check(not drawn(envn), "VideoCameraUI showing: hidden")
    live(envn, 7)
    envn.camera_pos.x = 12
    live(envn, 1)
    check(not drawn(envn), "...and still hidden after walking (the tape is a place you walk about in, but the rule is only for the unknown names)")

    -- the real GUI objects of the 0.6 debug file, with their parents: which of them count as a menu
    do
        local REAL = {
            ["GUI_menu"] = true, ["GUI_option"] = true, ["MenuHolder_Chapter/DetailSearchGUI"] = true, ["MenuHolder_Chapter/FileMenu"] = true,
            ["MenuHolder_Chapter/GameOverScreen"] = true, ["MenuHolder_Chapter/InventoryMenu"] = true, ["MenuHolder_Chapter/MultiSubMenu"] = true,
            ["MenuHolder_Chapter/VideoCameraUI"] = true, ["MenuHolder_MainMenu/TitleScreen"] = true, ["MenuHolder_Map/ui5000"] = true,
            ["MenuHolder_Map/ui5001"] = true, ["SystemObject/MenuManager/DifficultySelectGUI"] = true, ["SystemObject/MenuManager/ObjectiveGUI"] = true,
            ["SystemObject/MenuManager/OptionMenu"] = true, ["SystemObject/MenuManager/PauseMenuGUI"] = true,
            ["SystemObject/MenuManager/QuickEquipMenu"] = true, ["SystemObject/MenuManager/SaveMenuGUI"] = true,
            ["SystemObject/MenuManager/TutorialGUI"] = true,
            ["Fade_In_Out_Black"] = false, ["GUIRoot/MessageLabel"] = false, ["LogoMovie"] = false, ["MapMaskGUI"] = false,
            ["MenuHolder_BootFlow/LogoControl/TitleFlow01_PC"] = false, ["MenuHolder_BootFlow/ReticleGUI"] = false,
            ["MenuHolder_Chapter/InteractOperationCursor"] = false, ["MenuHolder_Chapter/InteractPointGuide"] = false,
            ["MenuHolder_Chapter/ReticleGUI"] = false, ["MenuHolder_Chapter/WeaponInfoGUI"] = false, ["MovieScreenGUI"] = false,
            ["Pl2000/Pl2000GenomeCodex/GenomeCodexGUI"] = false, ["SystemObject/MenuManager/AdjustHDRGUI"] = false,
            ["SystemObject/MenuManager/CutinMenu"] = false, ["SystemObject/MenuManager/CutinMenu/Fade"] = false,
            ["SystemObject/MenuManager/FirstSettingMenuGUI"] = false, ["SystemObject/MenuManager/GuideIcon"] = false,
            ["SystemObject/MenuManager/KeyHelpPlayable"] = false, ["SystemObject/MenuManager/MouseCursorGUI"] = false,
            ["SystemObject/MenuManager/NowLoadingScreen"] = false, ["SystemObject/MenuManager/ProcessingIcon"] = false,
            ["SystemObject/MenuManager/SavingIcon"] = false, ["SystemObject/MenuManager/StaffRollGUI"] = false,
            ["SystemObject/MenuManager/TipsGUI"] = false, ["SystemObject/MenuManager/UserIcon"] = false,
            ["SystemObject/MenuManager/damage_ui2102"] = false, ["ToVillageGUI"] = false, ["bg_dummy"] = false,
            ["c01_2F_dynamic/sm0315_VoiceRecorder01A/ui4101"] = false,
            ["c01_Living01_dynamic/sm0121_VideoDeck01A_FfPlay00/InteractPointGuide_FarIcon"] = false,
            ["c01_B1f_dynamic/sm0321_Memo01A_DetailSearch/InteractPointGuide_FarIcon"] = false, ["ui5005"] = false, ["ui5014"] = false,
        }
        local env = world()
        local list = {}
        for path in pairs(REAL) do
            local parts = {}
            for seg in path:gmatch("[^/]+") do parts[#parts + 1] = seg end
            local parent_xf, go
            for i, seg in ipairs(parts) do
                local gui
                if i == #parts then
                    local root = Obj.new("via.gui.Control", { get_Visible = function() return false end })
                    local view = Obj.new("via.gui.View", { get_RootWindow = function() return root end })
                    gui = Obj.new("via.gui.GUI", { get_GameObject = function() return go end, get_View = function() return view end })
                end
                go = make_go(seg, vec(0, 0, 0), gui and { gui } or {})
                local pxf = parent_xf
                go.xf.m.get_Parent = function() return pxf end
                parent_xf = go.xf
                if gui then list[#list + 1] = gui end
            end
        end
        env.guis = list
        env.scene.m["findComponents(System.Type)"] = function(_, t) return { get_elements = function() return t == "via.gui.GUI" and env.guis or {} end } end
        live(env, 3)
        refresh_debug(env)
        local wrong, seen, total = {}, 0, 0
        for _ in pairs(REAL) do total = total + 1 end
        for _, r in ipairs(env.files["re7mp_debug.json"].health.menus.guis_watched) do
            if REAL[r.path] ~= nil then
                seen = seen + 1
                if (r.counts_as_menu == true) ~= REAL[r.path] then wrong[#wrong + 1] = r.path end
            end
        end
        check(seen == total and #wrong == 0, "the real GUI names of the 0.6 file are sorted into menus and not-menus as expected (" .. seen .. "/" .. total
            .. " listed; wrong: " .. table.concat(wrong, ", ") .. ")")
    end

    -- ---- the heal pose is not taken from the inventory screen (hands 16 / 17 play there too) ----
    local envh = world(nil, true)
    vis = { InventoryMenu = false, GUI_HUD_Main = true }
    envh.guis = { mk_gui("GUI_HUD_Main", "GUI_HUD_Main"), mk_gui("InventoryMenu", "InventoryMenu") }
    envh.scene.m["findComponents(System.Type)"] = function(_, t) return { get_elements = function() return t == "via.gui.GUI" and envh.guis or {} end } end
    live(envh, 3)
    vis.InventoryMenu = true
    live(envh, 0.5)
    envh.hands.f[HK] = 16 -- the inventory's hands animation
    live(envh, 1.5)
    check(not bit(out_flags(envh), 128), "hands 16 while the inventory is open: no heal bit is sent")
    vis.InventoryMenu = false
    live(envh, 1)
    check(not bit(out_flags(envh), 128), "...and not after the inventory closes while the same pose is still running")
    envh.hands.f[HK] = 34
    live(envh, 0.6)
    envh.hands.f[HK] = 16
    live(envh, 0.6)
    check(bit(out_flags(envh), 128), "a heal with the menu closed is sent")
    envh.hands.f[HK] = 34
    live(envh, 1)
    refresh_debug(envh)
    local dh = envh.files["re7mp_debug.json"].health.poses
    check(dh.heal_ignored_because_a_menu_was_open and dh.heal_ignored_because_a_menu_was_open >= 1, "the debug file counts the heals it ignored because a menu was open")
    -- not watching menus must not break the heal: with nothing to watch the heal is sent as before
    local envh2 = world(nil, true)
    live(envh2, 2)
    envh2.hands.f[HK] = 16
    live(envh2, 0.6)
    check(bit(out_flags(envh2), 128), "no GUIs found: the heal pose is sent as before")

    -- ---- crouch: the game's own flag first, the camera height only when the game has none ----
    local envc = world(nil, true)
    envc.move.f.IsCrouch, envc.move.f.CrouchRate = false, 0
    live(envc, 2)
    envc.camera_pos.y = 1.05 -- eyes half a metre lower
    live(envc, 1)
    check(not bit(out_flags(envc), 256), "the game says IsCrouch = false: a low camera alone is not a crouch")
    envc.camera_pos.y = 1.6
    envc.move.f.IsCrouch = true
    live(envc, 0.5)
    check(bit(out_flags(envc), 256), "the game says IsCrouch = true: the crouch bit is sent although the camera did not move")
    envc.move.f.IsCrouch = false
    live(envc, 0.5)
    check(not bit(out_flags(envc), 256), "...and it ends with the flag")
    run_ui(envc)
    envc.move.f.IsCrouch = true
    live(envc, 0.5)
    run_ui(envc)
    check(ui_has(envc, "you are sending CROUCH"), "the panel says CROUCH")

    -- ---- the other player using a healing item lifts the stand-in's heal pose for a while ----
    local envi = world({ show_skeleton = true, show_body = false })
    envi.files["re7mp_in.json"].x, envi.files["re7mp_in.json"].y, envi.files["re7mp_in.json"].z = 0, 1.6, 6
    live(envi, 2)
    run_ui(envi)
    check(ui_has(envi, "heal 0%"), "no heal pose on the stand-in to begin with")
    push_msgs(envi, { { 7, "e|heal|Remedy|0.00|1.60|6.00" } })
    live(envi, 2)
    run_ui(envi)
    check(ui_has(envi, "heal 100%"), "'Bob used a Remedy' lifts the heal pose on the stand-in although his hands flags say nothing")
    live(envi, 5)
    run_ui(envi)
    check(ui_has(envi, "heal 0%"), "...and it ends again after a couple of seconds")
    push_msgs(envi, { { 7, "e|revive|Herb|0.00|1.60|6.00" } })
    live(envi, 2)
    run_ui(envi)
    check(ui_has(envi, "heal 0%"), "a revive event alone does not lift it")

    -- ---- death: other ways a death can start are watched too ----
    local function death_pre(env)
        -- (new_environment makes the types afresh, so they are extended here, before the script loads)
        local gmd = TYPES["app.GameManager"]._def
        gmd.methods.setGameOverFlag = { params = { "System.Boolean" } }
        gmd.methods.requestGameOver = {}
        gmd.methods.isGameOver = { ret = "System.Boolean" }
        make_td("app.PlayerDamageController", { methods = { doDie = {}, get_IsDie = { ret = "System.Boolean" }, updateDamage = {} } })
    end
    local envd = world({ death_mode = 4 }, false, death_pre)
    live(envd, 1.5)
    check(envd.hooks["app.GameManager.setGameOverFlag"] and envd.hooks["app.GameManager.requestGameOver"] and envd.hooks["app.PlayerDamageController.doDie"],
        "methods named like a game over or a death are hooked")
    check(not envd.hooks["app.GameManager.isGameOver"] and not envd.hooks["app.PlayerDamageController.get_IsDie"] and not envd.hooks["app.PlayerDamageController.updateDamage"],
        "...but not getters or other methods")
    check(log_has(envd, "death detection also watches:"), "...and the journal lists what is watched")
    local gm_obj = Obj.new("app.GameManager", {})
    envd.hooks["app.GameManager.setGameOverFlag"]({ 0, gm_obj, 0 })
    live(envd, 0.2)
    check(#messages_of_kind(envd, 4) == 0, "a game-over flag being CLEARED is not a death")
    envd.hooks["app.GameManager.setGameOverFlag"]({ 0, gm_obj, 1 })
    live(envd, 0.2)
    check(#messages_of_kind(envd, 4) == 1, "a game-over flag being SET tells the other player")
    check(log_has(envd, "death signal: setGameOverFlag"), "...and the journal names the call")
    envd.hooks["app.GameManager.requestGameOver"]({ 0, gm_obj })
    live(envd, 0.2)
    check(#messages_of_kind(envd, 4) == 1, "a second signal within 30 s is not sent again")
    local envd2 = world({ death_mode = 4 }, false, death_pre)
    live(envd2, 1.5)
    local pdc = Obj.new("app.PlayerDamageController", {})
    envd2.hooks["app.PlayerDamageController.doDie"]({ 0, pdc })
    live(envd2, 0.2)
    check(#messages_of_kind(envd2, 4) == 1 and log_has(envd2, "death signal: doDie"), "the player's damage controller dying tells the other player (a finisher)")
    -- a method that fires all the time is given up after 50 firings
    local envd3 = world({ death_mode = 4 }, false, death_pre)
    live(envd3, 1.5)
    local pdc3 = Obj.new("app.PlayerDamageController", {})
    for _ = 1, 80 do
        envd3.clock = envd3.clock + 31
        envd3.hooks["app.PlayerDamageController.doDie"]({ 0, pdc3 })
    end
    check(log_count(envd3, "death signal: doDie") == 50, "a hook that fires more than 50 times is ignored from then on: " .. log_count(envd3, "death signal: doDie"))
    -- with shared fate off nothing is sent
    local envd4 = world({ death_mode = 1 }, false, death_pre)
    live(envd4, 1.5)
    envd4.hooks["app.PlayerDamageController.doDie"]({ 0, pdc })
    live(envd4, 0.2)
    check(#messages_of_kind(envd4, 4) == 0, "with shared fate off a death is not sent")

    -- ---- the wall test: own body, other ways of casting, trying again, calibrating again ----
    local function wall_world(setup)
        local env = world()
        env.wall_x = 5
        env.files["re7mp_in.json"].x = 8
        if setup then setup(env) end
        live(env, 3.5)
        run_ui(env)
        return env
    end
    local envb = wall_world(function(e) e.body_layers = { [0] = true, [1] = true, [2] = true } end)
    check(ui_has(envb, "walls: working (collision layers 3, 5)"), "hits on your own body do not count as the floor (layers 0-2 hit only Pl0000)")
    check(not drawn(envb), "...and the wall still hides them")
    local envb2 = world()
    envb2.body_layers = { [3] = true }
    envb2.files["re7mp_in.json"].x = 8
    live(envb2, 3.5)
    check(drawn(envb2), "a ray that only touches your own body is not a wall: they are drawn")
    local d2 = envb2.files["re7mp_debug.json"] and envb2.files["re7mp_debug.json"].health.occlusion
    local envc0 = world()
    envc0.camera_collider = true
    envc0.files["re7mp_in.json"].x = 8
    live(envc0, 3.5)
    check(drawn(envc0), "the test ray starts clear of the camera (a collider right at the camera does not hide the other player)")
    local envr = wall_world(function(e) e.reject_clear = true end)
    check(ui_has(envr, "walls: working (collision layers 3, 5), way 2"), "when clearing the ray options blinds the cast, the way that leaves them alone is used")
    check(not drawn(envr), "...and the wall hides them")
    local envf = wall_world(function(e) e.filter_broken = true e.need_front = true end)
    run_ui(envf)
    check(ui_has(envf, "way 3"), "when the filter cannot be set and only the all-hit-kinds cast sees anything, way 3 is used: " .. tostring((function()
        for _, t in ipairs(envf.ui_texts) do if t:find("walls:", 1, true) then return t end end end)()))
    refresh_debug(envr)
    local dr = envr.files["re7mp_debug.json"].health.occlusion
    check(dr.way_used == 2 and dr.calibrated == true, "the debug file says which way was used")
    check(dr.floor_hit_layers_by_way and #dr.floor_hit_layers_by_way["1"] == 0 and #dr.floor_hit_layers_by_way["2"] >= 2, "...and which layers saw the floor with each way")
    local seen_floor, seen_wall
    for _, row in ipairs(dr.things_the_rays_hit or {}) do
        if row.name == "Floor" and row.hits > 0 then seen_floor = true end
        if row.name == "Wall" and row.hits > 0 then seen_wall = true end
    end
    check(seen_floor and seen_wall, "...and the names of the things the rays hit (a histogram, to see what a 'floor' really is)")
    check(type(dr.methods) == "table" and dr.methods["via.physics.System"] ~= nil, "...and the physics method names with their parameter types")

    -- no layer sees the floor: it says so, and tries again later (a new scene may work)
    local enr = world()
    enr.floor_layers = {}
    enr.wall_x = 5
    enr.files["re7mp_in.json"].x = 8
    live(enr, 8)
    run_ui(enr)
    check(ui_has(enr, "walls: unavailable (no collision layer found the floor)"), "no layer found the floor: unavailable")
    check(ui_has(enr, "trying again in 45 s"), "...and it says it will try again")
    enr.floor_layers = { [3] = true, [5] = true }
    live(enr, 50)
    run_ui(enr)
    check(ui_has(enr, "walls: working (collision layers 3, 5)"), "...and when a layer does see the floor later, it works")
    check(not drawn(enr), "...and hides them behind the wall")

    -- the physics call failing is not for ever either
    local enp = world()
    enp.wall_x = 5
    enp.physics_broken = true
    enp.files["re7mp_in.json"].x = 8
    live(enp, 4)
    run_ui(enp)
    check(ui_has(enp, "walls: unavailable"), "a failing physics call: unavailable")
    check(drawn(enp), "...and they are drawn")
    enp.physics_broken = false
    live(enp, 70)
    run_ui(enp)
    check(ui_has(enp, "walls: working (collision layers 3, 5)"), "...but after a minute it tries again and works")

    -- the physics singleton missing at first (a scene that is not ready): found when it tries again
    local ens = world()
    ens.no_physics_singleton = true
    ens.wall_x = 5
    ens.files["re7mp_in.json"].x = 8
    live(ens, 4)
    run_ui(ens)
    check(ui_has(ens, "walls: unavailable"), "no physics singleton: unavailable")
    ens.no_physics_singleton = false
    live(ens, 70)
    run_ui(ens)
    check(ui_has(ens, "walls: working (collision layers 3, 5)"), "...and when it exists a minute later the test looks for it again and works")

    -- 'behind a wall' for 30 s while you walk 8 m means the layers are wrong: calibrate again
    local enc = wall_world()
    check(not drawn(enc), "(behind the wall)")
    for i = 1, 36 do
        enc.camera_pos.z = enc.camera_pos.z + 0.3
        live(enc, 1)
    end
    refresh_debug(enc)
    local dc = enc.files["re7mp_debug.json"].health.occlusion
    check(dc.recalibrations and dc.recalibrations >= 1, "hidden for 30 s while walking 8 m: the layers are calibrated again (" .. tostring(dc.recalibrations) .. ")")
    check(log_has(enc, "walls: calibrating again"), "...and the journal says so")
    local enc3 = wall_world()
    for i = 1, 36 do
        enc3.camera_pos.z = enc3.camera_pos.z + 0.03 -- a metre in all
        live(enc3, 1)
    end
    refresh_debug(enc3)
    check((enc3.files["re7mp_debug.json"].health.occlusion.recalibrations or 0) == 0, "a metre of walking behind a wall for 36 s does not trigger a new calibration either")
    local enc4 = wall_world()
    enc4.camera_pos.z = enc4.camera_pos.z + 9 -- 9 m at once, but only 12 s behind the wall
    live(enc4, 12)
    refresh_debug(enc4)
    check((enc4.files["re7mp_debug.json"].health.occlusion.recalibrations or 0) == 0, "9 m of walking but only 12 s behind the wall does not trigger one either")
    local enc2 = wall_world()
    for i = 1, 36 do live(enc2, 1) end
    refresh_debug(enc2)
    check((enc2.files["re7mp_debug.json"].health.occlusion.recalibrations or 0) == 0, "standing still behind a wall for 36 s does not trigger a new calibration")
end

print(string.format("lua smoke test: %d checks passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
