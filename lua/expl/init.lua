local M = {}

M.config = {
	cmd = "claude",
	model = "sonnet",
	context_lines = 40,
	width = 72,
	max_height = 30,
	border = "rounded",
	cache = true,
	highlights = {
		ExplNormal = { link = "NormalFloat" },
		ExplBorder = { link = "FloatBorder" },
		ExplTitle = { link = "FloatTitle" },
		ExplFooter = { link = "FloatFooter" },
	},
	system_prompt = [[Explain the selected text. Be plain, direct, and concise.
Format:
- One sentence: what the code does (and its purpose, if clear from context).
- 2–4 short bullets: walk through the execution steps in order, putting variable, function, and type names in `backticks`.
- Optional: one `Note:` line if there is a non-obvious language idiom, edge case, or bug.
- Optional: a 1–3 line fenced code block with a language tag, only if a concrete example makes the behavior clearer.

Rules:
- Use Markdown.
- No preamble and do not repeat the input code.
- Stay under 150 words unless the code is genuinely complex.
- For follow-up questions, answer only what was asked using the same concise style (skip the template above).]],
}

local state = {
	win = nil,
	buf = nil,
	job = nil,
	timer = nil,
	session = nil,
	sessions = {},
	prompt = nil,
	answer = nil,
	cache_key = nil,
	asking = false,
}

local function cache_dir()
	return vim.fn.stdpath("cache") .. "/expl"
end

local function cache_path(key)
	return cache_dir() .. "/" .. key .. ".md"
end

local function cache_read(key)
	local f = io.open(cache_path(key), "r")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return text ~= "" and text or nil
end

local function cache_write(key, text)
	vim.fn.mkdir(cache_dir(), "p")
	local f = io.open(cache_path(key), "w")
	if f then
		f:write(text)
		f:close()
	end
end

local function delete_sessions(ids)
	local root = (vim.env.CLAUDE_CONFIG_DIR or (vim.env.HOME .. "/.claude")) .. "/projects"
	for _, id in ipairs(ids) do
		for _, file in ipairs(vim.fn.glob(root .. "/*/" .. id .. ".jsonl", false, true)) do
			os.remove(file)
		end
	end
end

local function stop_spinner()
	if state.timer then
		state.timer:stop()
		state.timer:close()
		state.timer = nil
	end
end

local function close()
	if state.job then
		pcall(function()
			state.job:kill(15)
		end)
		state.job = nil
	end
	stop_spinner()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_close(state.win, true)
	end
	local ids = state.sessions
	vim.defer_fn(function()
		delete_sessions(ids)
	end, 500)
	state.win, state.buf, state.session, state.sessions = nil, nil, nil, {}
	state.prompt, state.answer, state.cache_key, state.asking = nil, nil, nil, false
end

M.close = close

local function get_selection()
	local mode = vim.fn.mode()
	local vpos, cpos
	if mode:match("^[vV\22]") then
		vpos, cpos = vim.fn.getpos("v"), vim.fn.getpos(".")
	else
		mode = vim.fn.visualmode()
		vpos, cpos = vim.fn.getpos("'<"), vim.fn.getpos("'>")
	end
	local lines = vim.fn.getregion(vpos, cpos, { type = mode })
	local srow, erow = math.min(vpos[2], cpos[2]), math.max(vpos[2], cpos[2])
	return table.concat(lines, "\n"), srow, erow
end

local function build_prompt(code, srow, erow)
	local buf = vim.api.nvim_get_current_buf()
	local n = M.config.context_lines
	local total = vim.api.nvim_buf_line_count(buf)
	local before = vim.api.nvim_buf_get_lines(buf, math.max(0, srow - 1 - n), srow - 1, false)
	local after = vim.api.nvim_buf_get_lines(buf, erow, math.min(total, erow + n), false)
	local ft = vim.bo[buf].filetype
	local name = vim.fn.expand("%:t")

	return table.concat({
		("File: %s (%s), lines %d-%d"):format(name ~= "" and name or "[No Name]", ft, srow, erow),
		"",
		"Surrounding context (for reference only):",
		"```" .. ft,
		table.concat(before, "\n"),
		"<<< SELECTION >>>",
		table.concat(after, "\n"),
		"```",
		"",
		"Explain this selection:",
		"```" .. ft,
		code,
		"```",
	}, "\n")
end

local function win_opts(srow, erow, height)
	local cfg = M.config
	local width = math.min(cfg.width, vim.o.columns - 4)
	local win = vim.api.nvim_get_current_win()
	local top = vim.fn.screenpos(win, srow, 1).row
	local bottom = vim.fn.screenpos(win, erow, 1).row
	if top == 0 then
		top = vim.fn.screenrow()
	end
	if bottom == 0 then
		bottom = vim.fn.screenrow()
	end

	local longest = 0
	for _, l in ipairs(vim.api.nvim_buf_get_lines(0, srow - 1, erow, false)) do
		longest = math.max(longest, vim.fn.strdisplaywidth(l))
	end
	local wininfo = vim.fn.getwininfo(win)[1]
	local right_col = wininfo.wincol + wininfo.textoff + longest + 2

	local row, col
	if right_col + width + 2 <= vim.o.columns then
		row, col = top - 1, right_col
	elseif bottom + height + 2 <= vim.o.lines - 2 then
		row, col = bottom, wininfo.wincol + wininfo.textoff
	else
		row, col = math.max(0, top - height - 3), wininfo.wincol + wininfo.textoff
	end
	row = math.max(0, math.min(row, vim.o.lines - height - 4))
	col = math.max(0, math.min(col, vim.o.columns - width - 2))

	return {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = cfg.border,
		title = " expl ",
		title_pos = "left",
		footer = " q close ",
		footer_pos = "right",
	}
end

local function resize()
	if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
		return
	end
	local h = vim.api.nvim_win_text_height(state.win, {}).all
	h = math.max(1, math.min(h, M.config.max_height, vim.o.lines - 4))
	if h ~= vim.api.nvim_win_get_height(state.win) then
		vim.api.nvim_win_set_config(state.win, { height = h })
	end
end

local function append(text)
	local buf = state.buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	local last = vim.api.nvim_buf_line_count(buf)
	local tail = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
	local parts = vim.split(tail .. text, "\n", { plain = true })
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, last - 1, last, false, parts)
	vim.bo[buf].modifiable = false
	resize()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_set_cursor(state.win, { vim.api.nvim_buf_line_count(buf), 0 })
	end
end

local function set_chrome(title, footer)
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_set_config(state.win, {
			title = title,
			title_pos = "left",
			footer = footer,
			footer_pos = "right",
		})
	end
end

local function idle_chrome(cached)
	set_chrome(" expl ", cached and " cached · r refresh · f ask · q close " or " f ask · q close ")
end

local function start_spinner()
	local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
	local i = 0
	state.timer = vim.uv.new_timer()
	state.timer:start(
		0,
		80,
		vim.schedule_wrap(function()
			i = i % #frames + 1
			set_chrome((" expl %s "):format(frames[i]), " q close ")
		end)
	)
end

local function run(stdin, resume, on_done)
	local args = {
		M.config.cmd,
		"-p",
		"--output-format",
		"stream-json",
		"--verbose",
		"--include-partial-messages",
		"--system-prompt",
		M.config.system_prompt,
		"--tools",
		"",
		"--strict-mcp-config",
		"--setting-sources",
		"",
	}
	if M.config.model then
		vim.list_extend(args, { "--model", M.config.model })
	end
	if resume then
		vim.list_extend(args, { "--resume", resume })
	end

	start_spinner()
	local pending, chunks, failed = "", {}, false
	local job
	job = vim.system(args, {
		stdin = stdin,
		cwd = vim.fn.stdpath("cache"),
		stdout = function(_, data)
			if not data then
				return
			end
			pending = pending .. data
			while true do
				local nl = pending:find("\n", 1, true)
				if not nl then
					break
				end
				local line = pending:sub(1, nl - 1)
				pending = pending:sub(nl + 1)
				local ok, ev = pcall(vim.json.decode, line)
				if ok and type(ev) == "table" then
					local id = ev.session_id
					if id and ev.type == "system" and ev.subtype == "init" then
						vim.schedule(function()
							if state.job == job then
								state.session = id
								if not vim.tbl_contains(state.sessions, id) then
									table.insert(state.sessions, id)
								end
							end
						end)
					end
					local delta = ev.type == "stream_event" and ev.event and ev.event.delta
					if delta and delta.type == "text_delta" and delta.text then
						table.insert(chunks, delta.text)
						vim.schedule(function()
							if state.job == job then
								append(delta.text)
							end
						end)
					elseif ev.type == "result" and ev.is_error then
						failed = true
						vim.schedule(function()
							if state.job == job then
								append("\n**Error:** " .. tostring(ev.result))
							end
						end)
					end
				end
			end
		end,
	}, function(res)
		vim.schedule(function()
			if state.job ~= job then
				return
			end
			state.job = nil
			stop_spinner()
			if res.code ~= 0 and #chunks == 0 then
				append(("**claude exited with %d**\n%s"):format(res.code, res.stderr or ""))
			end
			on_done(res.code == 0 and not failed and #chunks > 0, table.concat(chunks))
		end)
	end)
	state.job = job
end

local function ask_claude(stdin)
	run(stdin, nil, function(ok, text)
		if ok then
			state.answer = text
			if M.config.cache and state.cache_key then
				cache_write(state.cache_key, text)
			end
		end
		idle_chrome(false)
	end)
end

local function set_lines(lines)
	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.bo[state.buf].modifiable = false
	resize()
end

function M.follow_up()
	if not (state.win and vim.api.nvim_win_is_valid(state.win)) or state.job then
		return
	end
	state.asking = true
	vim.ui.input({ prompt = "Ask expl: " }, function(question)
		state.asking = false
		if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
			return
		end
		vim.api.nvim_set_current_win(state.win)
		if not question or vim.trim(question) == "" then
			return
		end
		append("\n\n---\n\n**You:** " .. question .. "\n\n")

		local stdin, resume = question, state.session
		if not resume then
			stdin = table.concat({
				state.prompt,
				"",
				"You already explained it like this:",
				state.answer or "",
				"",
				"Follow-up question: " .. question,
			}, "\n")
		end
		run(stdin, resume, function()
			idle_chrome(false)
		end)
	end)
end

function M.refresh()
	if not (state.win and vim.api.nvim_win_is_valid(state.win)) or state.job or not state.prompt then
		return
	end
	set_lines({ "" })
	ask_claude(state.prompt)
end

function M.explain()
	if vim.fn.executable(M.config.cmd) == 0 then
		vim.notify("expl: `" .. M.config.cmd .. "` not found in PATH", vim.log.levels.ERROR)
		return
	end
	close()

	local code, srow, erow = get_selection()
	local prompt = build_prompt(code, srow, erow)
	local key = vim.fn.sha256(table.concat({
		vim.bo.filetype,
		M.config.model or "",
		M.config.system_prompt,
		code,
	}, "\0"))
	vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)

	state.buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.buf].filetype = "markdown"
	vim.bo[state.buf].bufhidden = "wipe"
	vim.bo[state.buf].modifiable = false
	state.win = vim.api.nvim_open_win(state.buf, true, win_opts(srow, erow, 1))
	vim.wo[state.win].wrap = true
	vim.wo[state.win].linebreak = true
	vim.wo[state.win].conceallevel = 2
	vim.wo[state.win].winhighlight =
		"Normal:ExplNormal,NormalFloat:ExplNormal,FloatBorder:ExplBorder,FloatTitle:ExplTitle,FloatFooter:ExplFooter"
	pcall(vim.treesitter.start, state.buf, "markdown")
	state.prompt, state.cache_key = prompt, key

	local map = function(lhs, fn)
		vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, silent = true })
	end
	map("q", close)
	map("<Esc>", close)
	map("f", M.follow_up)
	map("r", M.refresh)
	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = state.buf,
		callback = function()
			vim.schedule(function()
				if not state.asking then
					close()
				end
			end)
		end,
	})

	local cached = M.config.cache and cache_read(key)
	if cached then
		state.answer = cached
		set_lines(vim.split(cached, "\n", { plain = true }))
		idle_chrome(true)
		return
	end
	ask_claude(prompt)
end

function M.clear_cache()
	vim.fn.delete(cache_dir(), "rf")
	vim.notify("expl: cache cleared")
end

function M.setup(opts)
	opts = opts or {}
	local hls = vim.tbl_extend("force", M.config.highlights, opts.highlights or {})
	M.config = vim.tbl_deep_extend("force", M.config, opts)
	M.config.highlights = hls
	local function set_hl()
		for group, spec in pairs(M.config.highlights) do
			vim.api.nvim_set_hl(0, group, spec)
		end
	end
	set_hl()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("expl_hl", { clear = true }),
		callback = set_hl,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("expl_sessions", { clear = true }),
		callback = function()
			delete_sessions(state.sessions)
		end,
	})
	vim.api.nvim_create_user_command("Expl", function()
		M.explain()
	end, { range = true, desc = "Explain selection" })
	vim.api.nvim_create_user_command("ExplClearCache", M.clear_cache, { desc = "Delete cached explanations" })
end

return M
