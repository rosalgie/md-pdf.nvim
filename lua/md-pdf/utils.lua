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

--- Last build log buffer number (nil if none yet)
---@type integer|nil
M.last_log_buf = nil

--- Show build output in a scratch buffer.
--- Creates (or recreates) a named scratch buffer with the full build log,
--- including command, exit code, stderr, and stdout.
---@param result { code: integer, stderr: string|nil, stdout: string|nil }
---@param command string[] The pandoc command that was run
---@param failed boolean Whether the build failed (exit code ~= 0)
function M.show_build_log(result, command, failed)
    local stderr = vim.trim(result.stderr or "")
    local stdout = vim.trim(result.stdout or "")

    local lines = {}

    if failed then
        table.insert(lines, "md-pdf: build FAILED")
    else
        table.insert(lines, "md-pdf: build log")
    end

    table.insert(lines, "")
    table.insert(lines, "Command:")
    table.insert(lines, "  " .. table.concat(command, " "))
    table.insert(lines, "")
    table.insert(lines, "Exit code: " .. tostring(result.code))

    if stderr ~= "" then
        table.insert(lines, "")
        table.insert(lines, "stderr:")
        vim.list_extend(lines, vim.split(stderr, "\n", { plain = true }))
    end

    if stdout ~= "" then
        table.insert(lines, "")
        table.insert(lines, "stdout:")
        vim.list_extend(lines, vim.split(stdout, "\n", { plain = true }))
    end

    if M.last_log_buf and vim.api.nvim_buf_is_valid(M.last_log_buf) then
        vim.api.nvim_buf_delete(M.last_log_buf, { force = true })
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_name(buf, "md-pdf://build-log")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "log"

    M.last_log_buf = buf

    if failed then
        local win_height = math.min(#lines, 20)
        vim.cmd("botright " .. win_height .. "split")
        vim.api.nvim_win_set_buf(0, buf)
    end
end

function M.open_last_log()
    if not M.last_log_buf or not vim.api.nvim_buf_is_valid(M.last_log_buf) then
        M.log.info("No build log available")
        return
    end

    -- Check if it's already visible in a window
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == M.last_log_buf then
            vim.api.nvim_set_current_win(win)
            return
        end
    end

    local line_count = vim.api.nvim_buf_line_count(M.last_log_buf)
    local win_height = math.min(line_count, 20)
    vim.cmd("botright " .. win_height .. "split")
    vim.api.nvim_win_set_buf(0, M.last_log_buf)
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
