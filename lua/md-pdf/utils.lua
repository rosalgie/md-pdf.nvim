local M = {}

---@class SemanticVersion
---@field major integer
---@field minor integer
---@field patch integer?
---@field build_num integer?
---@field prerelease string?
---@field build string?
local SemanticVersion = {}
SemanticVersion.__index = SemanticVersion

function M.has_value(tab, val)
    for index, _ in pairs(tab) do
        if index == val then
            return true
        end
    end

    return false
end

M.log = {}

---@param str string Log Message
function M.log.info(str)
    if type(str) ~= "string" then
        str = tostring(str)
    end
    pcall(vim.notify, "md-pdf: " .. str)
end

---@param str string Log Message
function M.log.warn(str)
    if type(str) ~= "string" then
        str = tostring(str)
    end
    pcall(vim.notify, "md-pdf: " .. str, vim.log.levels.WARN)
end

---@param str string Log Message
function M.log.error(str)
    if type(str) ~= "string" then
        str = tostring(str)
    end
    pcall(vim.notify, "md-pdf: " .. str, vim.log.levels.ERROR)
end

--- Parse semver into a table with components. Support following formats:
--- - `1.2`
--- - `v1.2.3`
--- - `1.2.3`
--- - `v1.2.3.4`
--- - `1.2.3.4`
--- - `1.2.3.4-beta`
--- - `1.2.3-alpha.1`
---@param version string
---@return SemanticVersion?
function M.parse_semver(version)
    -- Try 4-part version first
    local major, minor, patch, build_num = version:match("v? (%d+)%.(%d+)%.(%d+)%.(%d+)")
    if major then
        -- 4-part version
        local prerelease = version:match("v?%d+%.%d+%.%d+%. %d+%-([^%+]+)")
        local build = version:match("v?%d+%. %d+%.%d+%. %d+[^%+]*%+(.+)")

        return {
            major = tonumber(major),
            minor = tonumber(minor),
            patch = tonumber(patch),
            build_num = tonumber(build_num),
            prerelease = prerelease,
            build = build,
            full = version:match("v?(%d+%. %d+%.%d+%. %d+[%-%.%w]*[%+%.%w]*)"),
        }
    end

    -- Try 3-part version
    major, minor, patch = version:match("v?(%d+)%.(%d+)%.(%d+)")
    if major then
        local prerelease = version:match("v?%d+%.%d+%.%d+%-([^%+]+)")
        local build = version:match("v?%d+%.%d+%.%d+[^%+]*%+(.+)")

        return {
            major = tonumber(major),
            minor = tonumber(minor),
            patch = tonumber(patch),
            prerelease = prerelease,
            build = build,
            full = version:match("v?(%d+%.%d+%.%d+[%-%.%w]*[%+%.%w]*)"),
        }
    end

    -- Finally, try 2-part version
    major, minor = version:match("v?(%d+)%.(%d+)")
    if major then
        local prerelease = version:match("v?%d+%.%d+%.%d+%-([^%+]+)")
        local build = version:match("v?%d+%.%d+%.%d+[^%+]*%+(.+)")

        return {
            major = tonumber(major),
            minor = tonumber(minor),
            prerelease = prerelease,
            build = build,
            full = version:match("v?(%d+%.%d+%.%d+[%-%.%w]*[%+%.%w]*)"),
        }
    end

    -- no success in parsing values
    return nil
end

return M
