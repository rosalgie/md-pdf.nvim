---@diagnostic disable: undefined-field, need-check-nil

-- Found this helpful site for vim.loop handling
--  https://teukka.tech/vimloop.html

local config = require("md-pdf.config")
local utils = require("md-pdf.utils")
local log = utils.log

local M = {}

---@class MdPdfBuildState
---@field generation integer
---@field timer uv.uv_timer_t?
---@field running boolean
---@field pending boolean
---@field viewer_open boolean
---@field pdf_output_path string
---@field conv_started boolean
---@field next_is_auto boolean?

---@type table<integer, MdPdfBuildState>
local builds = {}

local function get_state(bufnr)
    if bufnr == 0 or bufnr == nil then
        bufnr = vim.api.nvim_get_current_buf()
    end
    if not builds[bufnr] then
        builds[bufnr] = {
            generation = 0,
            running = false,
            pending = false,
            viewer_open = false,
            pdf_output_path = "",
            conv_started = false,
            next_is_auto = false,
        }
    end
    return builds[bufnr]
end

---@param quoted_text string|nil
---@return string|nil
local function trim_quotes(quoted_text)
    if not quoted_text then
        return nil
    end
    quoted_text = vim.trim(quoted_text)
    local first = quoted_text:sub(1, 1)
    local last = quoted_text:sub(-1)
    if (first == '"' and last == '"') or (first == "'" and last == "'") then
        return quoted_text:sub(2, -2)
    end
    return quoted_text
end

---@param fullname string
---@param file_dir string
---@return string|nil
local function resolve_header_logo_path(fullname, file_dir)
    local ok, lines = pcall(vim.fn.readfile, fullname)
    if not ok or #lines == 0 then
        return nil
    end
    if not lines[1]:match("^%-%-%-$") then
        return nil
    end

    for i = 2, #lines do
        local line = lines[i]
        if line:match("^%-%-%-$") then
            break
        end
        local key, value = line:match("^([%w_%-%:]+)%s*:%s*(.+)$")
        if key then
            key = vim.trim(key)
            if key == "logo" or key == "titlegraphic" then
                value = trim_quotes(value)
                if value and value ~= "" then
                    if value:sub(1, 1) == "~" then
                        value = vim.fn.expand(value)
                    elseif not vim.startswith(value, "/") then
                        value = vim.fs.normalize(file_dir .. "/" .. value)
                    end
                    return value
                end
            end
        end
    end
end

local function detokenize_path(path)
    if not path then
        return nil
    end
    return "\\detokenize{" .. path .. "}"
end

---@param fullname string
---@param file_dir string
---@return string[]
---@return string|nil
local function build_title_page_args(fullname, file_dir)
    if not config.options.title_page then
        return {}, nil
    end

    local pandoc_flags = {
        "-V",
        "classoption=titlepage",
    }
    local header_lines = {}
    local header_include
    local logo_path = resolve_header_logo_path(fullname, file_dir)

    if logo_path then
        table.insert(header_lines, [[\usepackage{graphicx}]])
        table.insert(header_lines, [[\usepackage{titling}]])
        table.insert(
            header_lines,
            string.format(
                [[\pretitle{\begin{center}\includegraphics[width=0.4\textwidth]{%s}\\[1em]}]],
                detokenize_path(logo_path)
            )
        )
        table.insert(header_lines, [[\posttitle{\par\end{center}}]])
    end

    if config.options.toc then
        table.insert(header_lines, [[\usepackage{etoolbox}]])
        table.insert(header_lines, [[\pretocmd{\tableofcontents}{\clearpage}{}{}]])
        table.insert(header_lines, [[\apptocmd{\tableofcontents}{\clearpage}{}{}]])
    end

    if #header_lines > 0 then
        local include_path = vim.fn.tempname() .. ".tex"
        local ok, err = pcall(vim.fn.writefile, header_lines, include_path)
        if ok then
            header_include = include_path
            table.insert(pandoc_flags, "--include-in-header=" .. include_path)
        else
            log.warn("Failed to prepare title page header include: " .. tostring(err))
        end
    end

    return pandoc_flags, header_include
end

---@param options md-pdf.config
function M.setup(options)
    config.setup(options)
end

--- @return string: preview command, which can be either a string or a function.
local function get_preview_command()
    local preview_cmd = config.options.preview_cmd
    if type(preview_cmd) == "function" then
        return preview_cmd()
    elseif type(preview_cmd) == "string" then
        return preview_cmd
    else
        log.error("Unknown preview command specified, return defaults")
        return config.default_preview_cmd()
    end
end

--- Opens the previewer
local function open_doc(state)
    if state.viewer_open then
        return
    else
        state.viewer_open = true
    end

    vim.system({ get_preview_command(), state.pdf_output_path }, { text = true }, function()
        state.viewer_open = false
        if not config.options.ignore_viewer_state then
            log.info("Document viewer closed!")
        end
    end)
end

local cached_pandoc_version = nil

local function get_pandoc_version()
    if cached_pandoc_version then
        return cached_pandoc_version
    end
    local result = vim.system({ "pandoc", "--version" }, { text = true }):wait()
    cached_pandoc_version = utils.parse_semver(result.stdout)
    return cached_pandoc_version
end

--- Converts markdown file to pdf. Starts auto-conversion on save.
function M.convert_md_to_pdf(bufnr, is_auto)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].filetype ~= "markdown" then
        log.error("Filetype " .. vim.bo[bufnr].filetype .. " not supported!")
        return
    end

    local state = get_state(bufnr)
    state.generation = state.generation + 1
    state.next_is_auto = is_auto
    local expected_gen = state.generation

    if state.running then
        state.pending = true
        return
    end

    local function start_build()
        state.running = true
        state.pending = false
        local start_time = vim.uv.hrtime()
        local current_is_auto = state.next_is_auto

        local fullname = vim.api.nvim_buf_get_name(bufnr)
        local file_dir = vim.fn.fnamemodify(fullname, ":h")
        local file_name_without_ext = vim.fn.fnamemodify(fullname, ":t:r")
        local updated_file_name = file_name_without_ext .. ".pdf"

        local output_dir = file_dir .. "/" .. config.options.output_path
        vim.fn.mkdir(output_dir, "p")

        state.pdf_output_path = output_dir .. "/" .. updated_file_name
        local temp_pdf = output_dir .. "/." .. file_name_without_ext .. ".md-pdf-tmp.pdf"

        local engine = config.options.pdf_engine or "pdflatex"
        local is_latex = engine:match("latex") or engine == "tectonic"

        local cache_dir = output_dir .. "/.md-pdf-cache"
        local tex_file = cache_dir .. "/" .. file_name_without_ext .. ".tex"

        if is_latex then
            vim.fn.mkdir(cache_dir, "p")
        end

        local pandoc_args = {
            "pandoc",
            "--standalone",
            "-V",
            "geometry:margin=" .. config.options.margins,
            fullname,
            "--resource-path=" .. file_dir,
        }

        if is_latex then
            table.insert(pandoc_args, "--output=" .. tex_file)
        else
            table.insert(pandoc_args, "--output=" .. temp_pdf)
            if config.options.pdf_engine then
                table.insert(pandoc_args, "--pdf-engine=" .. config.options.pdf_engine)
            end
        end

        local version = get_pandoc_version()

        if version.major >= 3 and version.minor >= 8 then
            table.insert(pandoc_args, "--syntax-highlight=" .. config.options.highlight)
        else
            table.insert(pandoc_args, "--highlight-style=" .. config.options.highlight)
        end

        local header_include
        if config.options.title_page then
            local title_page_args
            title_page_args, header_include = build_title_page_args(fullname, file_dir)
            vim.list_extend(pandoc_args, title_page_args)
        end

        local use_toc = config.options.toc
        if current_is_auto and config.options.preview_toc == false then
            use_toc = false
        end

        if use_toc then
            table.insert(pandoc_args, "--toc")
        end

        if config.options.fonts then
            local ftable = config.options.fonts
            if ftable.main_font then
                table.insert(pandoc_args, "-V")
                table.insert(pandoc_args, "mainfont:" .. ftable.main_font)
            end
            if ftable.sans_font then
                table.insert(pandoc_args, "-V")
                table.insert(pandoc_args, "sansfont:" .. ftable.sans_font)
            end
            if ftable.mono_font then
                table.insert(pandoc_args, "-V")
                table.insert(pandoc_args, "monofont:" .. ftable.mono_font)
            end
            if ftable.math_font then
                table.insert(pandoc_args, "-V")
                table.insert(pandoc_args, "mathfont:" .. ftable.math_font)
            end
        end

        if config.options.pandoc_user_args then
            for _, value in ipairs(config.options.pandoc_user_args) do
                for token in string.gmatch(value, "[^%s]+") do
                    table.insert(pandoc_args, token)
                end
            end
        end

        if config.options.fonts then
            for _, value in ipairs(pandoc_args) do
                if string.gmatch(value, "[pdflatex]") then
                    log.warn(
                        "When specifying custom fonts, you may encounter utf-8 error. Consider switching to another engine, ex. lualatex :)"
                    )
                    break
                end
            end
        end

        local function finalize_build(obj, cmd_args, generated_pdf, is_cleanup_temp)
            vim.schedule(function()
                if state.generation ~= expected_gen then
                    if is_cleanup_temp then
                        pcall(vim.loop.fs_unlink, temp_pdf)
                    end
                    state.running = false
                    if state.pending then
                        start_build()
                    end
                    return
                end

                if obj.code ~= 0 then
                    if is_cleanup_temp then
                        pcall(vim.loop.fs_unlink, temp_pdf)
                    end
                    log.error(
                        "PDF conversion failed (exit code "
                            .. tostring(obj.code)
                            .. "). See :MdPdfLog for details."
                    )
                    utils.show_build_log(obj, cmd_args, true)
                    state.running = false
                    if state.pending then
                        start_build()
                    end
                    return
                end

                local ok, rename_err = vim.uv.fs_rename(generated_pdf, state.pdf_output_path)
                if not ok then
                    log.error("Failed to install PDF: " .. tostring(rename_err))
                    state.running = false
                    if state.pending then
                        start_build()
                    end
                    return
                end

                local stderr = vim.trim(obj.stderr or "")
                if stderr ~= "" then
                    local warning_count = 0
                    for _ in stderr:gmatch("[Ww][Aa][Rr][Nn]") do
                        warning_count = warning_count + 1
                    end
                    if warning_count > 0 then
                        log.warn(
                            warning_count
                                .. " warning(s) during conversion. See :MdPdfLog for details."
                        )
                    end
                end

                utils.show_build_log(obj, cmd_args, false)

                open_doc(state)
                state.conv_started = true
                state.running = false

                local elapsed_ms = (vim.uv.hrtime() - start_time) / 1e6
                log.info(string.format("PDF built in %.2fs", elapsed_ms / 1000))

                if state.pending then
                    start_build()
                end
            end)
        end

        log.info("Markdown to PDF conversion started...")
        vim.system(pandoc_args, { text = true }, function(pandoc_obj)
            if header_include then
                pcall(vim.loop.fs_unlink, header_include)
            end

            if not is_latex then
                -- Single-step fallback
                finalize_build(pandoc_obj, pandoc_args, temp_pdf, true)
                return
            end

            -- If pandoc failed to generate .tex, abort early
            if pandoc_obj.code ~= 0 then
                finalize_build(pandoc_obj, pandoc_args, temp_pdf, true)
                return
            end

            -- Run LaTeX engine
            local engine_args = { engine }
            if engine:match("latex") then
                table.insert(engine_args, "-interaction=nonstopmode")
                table.insert(engine_args, "-halt-on-error")
                table.insert(engine_args, "-output-directory=" .. cache_dir)
            elseif engine == "tectonic" then
                table.insert(engine_args, "--outdir=" .. cache_dir)
            end
            table.insert(engine_args, tex_file)

            vim.system(engine_args, { text = true, cwd = file_dir }, function(engine_obj)
                local generated_pdf = cache_dir .. "/" .. file_name_without_ext .. ".pdf"

                -- Combine outputs for the log
                local combined_obj = {
                    code = engine_obj.code,
                    stdout = engine_obj.stdout,
                    stderr = (pandoc_obj.stderr or "") .. "\n" .. (engine_obj.stderr or ""),
                }

                local full_cmd =
                    { table.concat(pandoc_args, " ") .. " && " .. table.concat(engine_args, " ") }

                finalize_build(combined_obj, full_cmd, generated_pdf, false)
            end)
        end)
    end

    start_build()
end

--- Stops automatic conversion for the given buffer
function M.stop_auto_conversion(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local state = get_state(bufnr)
    state.conv_started = false
    log.info("Stopped auto-conversion for current buffer")
end

local mdaugroup = vim.api.nvim_create_augroup("md-pdf", { clear = true })

vim.api.nvim_create_autocmd("BufWritePost", {
    group = mdaugroup,
    pattern = "*.md",
    callback = function(ev)
        local bufnr = ev.buf
        local state = get_state(bufnr)

        if not config.options.ignore_viewer_state and not state.viewer_open then
            return
        end
        if not state.conv_started then
            return
        end

        if state.timer then
            state.timer:stop()
            state.timer:close()
        end

        state.timer = vim.uv.new_timer()
        state.timer:start(
            300,
            0,
            vim.schedule_wrap(function()
                if state.timer then
                    state.timer:stop()
                    state.timer:close()
                    state.timer = nil
                end
                if vim.api.nvim_buf_is_valid(bufnr) then
                    M.convert_md_to_pdf(bufnr, true)
                end
            end)
        )
    end,
})

-- Cleanup state when buffer is deleted
vim.api.nvim_create_autocmd("BufDelete", {
    group = mdaugroup,
    pattern = "*.md",
    callback = function(ev)
        local bufnr = ev.buf
        local state = builds[bufnr]
        if state then
            if state.timer then
                state.timer:stop()
                state.timer:close()
            end
            builds[bufnr] = nil
        end
    end,
})

vim.api.nvim_create_user_command("MdPdf", function()
    M.convert_md_to_pdf()
end, { desc = "Convert current markdown buffer to PDF" })

vim.api.nvim_create_user_command("MdPdfStop", function()
    M.stop_auto_conversion()
end, { desc = "Stop auto-conversion for current buffer" })

vim.api.nvim_create_user_command("MdPdfLog", function()
    utils.open_last_log()
end, { desc = "Show the last md-pdf build log" })

return M
