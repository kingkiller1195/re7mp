-- Settings persisted to reframework/data/re7_mp.json
local M = {}

local FILE = "re7_mp.json"

local DEFAULTS = {
    name = "Player",
    port = 7777,
    last_ip = "127.0.0.1",
    max_players = 4,
    pose_smoothing = 18.0,    -- higher = snappier remote avatars, lower = smoother
    show_nameplates = true,
    show_chat_overlay = true,
    avatar_backend = "overlay", -- "overlay" (ImGui draw list) or "prefab" (experimental, world-space)
    avatar_prefab = "",         -- prefab path for the "prefab" backend, e.g. "ObjectPrefab/....pfb"
}

local function copy_defaults()
    local t = {}
    for k, v in pairs(DEFAULTS) do t[k] = v end
    return t
end

function M.load()
    local cfg = copy_defaults()
    if json and json.load_file then
        local ok, data = pcall(json.load_file, FILE)
        if ok and type(data) == "table" then
            for k, v in pairs(data) do
                if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then cfg[k] = v end
            end
        end
    end
    return cfg
end

function M.save(cfg)
    if json and json.dump_file then
        pcall(json.dump_file, FILE, cfg)
    end
end

M.DEFAULTS = DEFAULTS
return M
