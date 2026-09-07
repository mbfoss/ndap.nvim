local M              = {}

local str_util       = require("ndap.util.strutil")
local manager        = require("ndap.manager")
local config         = require("ndap.config").current
local fileextmarks   = require("ndap.util.fileextmarks")
local color          = require("ndap.util.color")

local _group         = fileextmarks.define_group("ndap.inlinevars")
local _PRIORITY      = 100
local _seq           = 0
local _max_size      = 30
-- "eol" pills carry the variable name too, so they get a larger budget; the
-- name is cropped to a third of it, the value to the rest.
local _line_max_size = 45
local _enabled       = true
---@type function[]  unsubscribe fns for the signals, held while enabled
local _unsubs        = {}
local _mark_id       = 0
local _clear_timer   = nil

vim.api.nvim_set_hl(0, "NdapPill", { link = "Visual", default = true })

color.create_themed_hl({
	name = "NdapPillSep",
	spec = function()
		vim.api.nvim_set_hl(0, "NdapPill", { link = "Visual", default = true })
		local hl = vim.api.nvim_get_hl(0, { name = "NdapPill", link = false })
		-- `reverse` (e.g. sorbet) swaps fg/bg on screen; follow what is drawn.
		local shown_bg = hl.bg or hl.fg
		if hl.reverse then
			shown_bg = hl.fg or vim.api.nvim_get_hl(0, { name = "Normal", link = false }).fg
		end
		return {
			fg = shown_bg,
			bg = "NONE",
		}
	end,
})

---Configured placement of inline values; defaults to "inline".
---@return ndap.InlineVarsMode
local function _mode()
	return config.inline_vars or "inline"
end

---Whether inline values should currently be rendered (runtime toggle on, and
---placement not set to "off").
---@return boolean
local function _active()
	return _enabled and _mode() ~= "off"
end

local function _cancel_clear_timer()
	if _clear_timer then
		_clear_timer:stop()
		_clear_timer:close()
		_clear_timer = nil
	end
end

local function _clear()
	_cancel_clear_timer()
	_mark_id = 0
	_group.remove_extmarks()
end

---@param delay_ms integer  milliseconds to wait before clearing the marks
local function _deferred_clear(delay_ms)
	_cancel_clear_timer()
	local t = vim.uv.new_timer()
	if not t then return end
	_clear_timer = t
	t:start(delay_ms, 0, vim.schedule_wrap(function()
		_cancel_clear_timer()
		_mark_id = 0
		_group.remove_extmarks()
	end))
end

---Build the `virt_text` chunks for one value pill: ` ◖text◗`.
---@param text string
---@return table[]
local function _pill(text)
	return {
		{ " " },
		{ "\u{E0B6}", "NdapPillSep" },
		{ text,       "NdapPill" },
		{ "\u{E0B4}", "NdapPillSep" },
	}
end

---Place a value pill inline, right after a variable occurrence. The pill shows
---only the value since the name is already in the source at that column.
---@param file string
---@param row number  -- 0-based
---@param col number  -- 0-based
---@param text string
local function _set_inline_extmark(file, row, col, text)
	text = vim.trim(text)
	if text == "" then return end
	_mark_id = _mark_id + 1
	_group.set_file_extmark({
		id = _mark_id,
		file = file,
		lnum = row + 1,
		col = col,
		opts = {
			virt_text = _pill(text),
			virt_text_pos = "inline",
			hl_mode = "combine",
			priority = _PRIORITY,
		},
	})
end

---Place one detached annotation for a whole line (the "eol"/"eol_right_align"/
---"right_align" modes). Each item becomes a `name: value` pill; since the pills
---are detached from the source they carry the name too.
---@param file string
---@param row number  -- 0-based
---@param items {col:number, name:string, value:string}[]
---@param pos "eol"|"eol_right_align"|"right_align"  -- virt_text_pos
local function _set_line_extmark(file, row, items, pos)
	local name_max = math.floor(_line_max_size / 3)
	local value_max = _line_max_size - name_max
	local virt_text = {}
	for _, item in ipairs(items) do
		local value = vim.trim(tostring(item.value))
		if value ~= "" then
			local name = str_util.crop_for_ui(item.name, name_max)
			value = str_util.crop_for_ui(value, value_max)
			vim.list_extend(virt_text, _pill(name .. ": " .. value))
		end
	end
	if #virt_text == 0 then return end
	_mark_id = _mark_id + 1
	_group.set_file_extmark({
		id = _mark_id,
		file = file,
		lnum = row + 1,
		col = 0,
		opts = {
			virt_text = virt_text,
			virt_text_pos = pos,
			hl_mode = "combine",
			priority = _PRIORITY,
		},
	})
end

---Place the inline annotations for a frame using an already-parsed tree.
---@param root TSNode
---@param ctx { bufnr:integer, path:string, locals_query:vim.treesitter.Query, dbg:table<string,string>, target_row:integer }
local function _place_from_tree(root, ctx)
	local bufnr, path, locals_query, dbg, target_row =
		ctx.bufnr, ctx.path, ctx.locals_query, ctx.dbg, ctx.target_row

	-- narrow to the innermost scope containing the frame line
	local scope_node = root
	for id, node in locals_query:iter_captures(root, bufnr) do
		if locals_query.captures[id] == "scope" then
			local sr, _, er, _ = node:range()
			if sr <= target_row and target_row <= er then
				local cur_sr, _, cur_er, _ = scope_node:range()
				if (er - sr) < (cur_er - cur_sr) then
					scope_node = node
				end
			end
		end
	end

	-- pre-collect direct child scopes so the walk does not descend into them
	local _child_scopes = {}
	for id, node in locals_query:iter_captures(scope_node, bufnr) do
		if locals_query.captures[id] == "scope" and node ~= scope_node then
			_child_scopes[node:id()] = true
		end
	end

	-- collect every occurrence of each variable name within the current scope only
	---@type table<string, {sr:number, ec:number}[]>
	local occurrences = {}

	---@param node TSNode
	local function walk(node)
		if not node then return end
		if _child_scopes[node:id()] then return end

		local node_type = node:type()
		if node_type == "identifier" and node:parent() then
			local name = vim.treesitter.get_node_text(node, bufnr)
			if dbg[name] then
				local sr, _, _, ec = node:range()
				occurrences[name] = occurrences[name] or {}
				occurrences[name][#occurrences[name] + 1] = { sr = sr, ec = ec }
			end
		end

		for child in node:iter_children() do
			walk(child)
		end
	end

	walk(scope_node)

	-- pick one occurrence per variable: the closest at/before the execution line,
	-- falling back to the closest after it. The score keeps every at/before-line
	-- occurrence ahead of every after-line one (n bounds any in-buffer distance).
	local n = vim.api.nvim_buf_line_count(bufnr)
	---@type table<string, {sr:number, ec:number}>
	local best_by_name = {}
	for name, positions in pairs(occurrences) do
		local best, best_score = nil, math.huge
		for _, pos in ipairs(positions) do
			local d = pos.sr - target_row
			local score = d <= 0 and -d or n + d
			if score < best_score then
				best, best_score = pos, score
			end
		end
		if best then best_by_name[name] = best end
	end

	local mode = _mode()
	if mode == "inline" then
		for name, best in pairs(best_by_name) do
			local text = str_util.crop_for_ui(tostring(dbg[name]), _max_size)
			_set_inline_extmark(path, best.sr, best.ec, text)
		end
		return
	end
	-- "off" is filtered out upstream by _active(); only detached modes remain
	---@cast mode "eol"|"eol_right_align"|"right_align"

	-- detached modes: one annotation per line, with the mode used directly as the
	-- virt_text_pos. Multiple eol/right-aligned marks on one line would stack or
	-- overlap, so group each line's variables into one extmark, ordered by column.
	---@type table<number, {col:number, name:string, value:string}[]>
	local by_line = {}
	for name, best in pairs(best_by_name) do
		by_line[best.sr] = by_line[best.sr] or {}
		local items = by_line[best.sr]
		-- value is cropped (with the line-mode budget) in _set_line_extmark
		items[#items + 1] = {
			col = best.ec,
			name = name,
			value = dbg[name],
		}
	end

	for row, items in pairs(by_line) do
		table.sort(items, function(a, b) return a.col < b.col end)
		_set_line_extmark(path, row, items, mode)
	end
end

---Render the inline value pills for `variables` into `frame`'s source buffer.
---@param frame     ndap.dap.StackFrame
---@param variables ndap.dap.Variable[]?
local function _render_variables(frame, variables)
	if not frame or not frame.source or not frame.source.path then return end

	local path = frame.source.path
	local bufnr = vim.fn.bufnr(path)
	if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then return end

	local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype)
	if not lang then return end

	local dbg = {}
	for _, v in ipairs(variables or {}) do
		if v.name and v.value then
			dbg[v.name] = vim.trim(v.value)
		end
	end
	if vim.tbl_isempty(dbg) then return end

	-- the locals query defines scope boundaries; without it we cannot tell a
	-- local variable from an unrelated identifier, so skip rather than guess
	local locals_query_ok, locals_query = pcall(vim.treesitter.query.get, lang, "locals")
	if not locals_query_ok or not locals_query then
		return
	end

	local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
	if not (parser_ok and parser) then return end

	local ctx = {
		bufnr = bufnr,
		path = path,
		locals_query = locals_query,
		dbg = dbg,
		target_row = (frame.line or 1) - 1,
	}

	local seq = _seq
	local placed = false
	---@param trees TSTree[]?  parse result; nil on a synchronous parse
	local function place(trees)
		if placed or seq ~= _seq then return end
		if not vim.api.nvim_buf_is_valid(bufnr) then return end

		local tree = trees and trees[1]
		if not tree then return end
		placed = true
		_place_from_tree(tree:root(), ctx)
	end

	local trees = parser:parse(nil, place)
	if trees then place(trees) end
end

-- Inline annotations should reflect what is in lexical scope at the current frame,
-- so restrict to the locals/arguments scopes and skip globals, statics, registers.
-- Prefer the adapter's presentationHint, falling back to the scope name.
---@param scope ndap.dap.proto.Scope
---@return boolean
local function _is_local_scope(scope)
	local hint = scope.presentationHint
	if hint then
		return hint == "locals" or hint == "arguments"
	end
	local name = (scope.name or ""):lower()
	return name:find("local", 1, true) ~= nil or name:find("argument", 1, true) ~= nil
end

---@param session ndap.dap.Session
---@param frame table
---@param cb function
local function _collect_variables(session, frame, cb)
	local scopes = frame.scopes
	if not scopes then
		return session:fetch_scopes(frame, function()
			_collect_variables(session, frame, cb)
		end)
	end

	local vars = {}
	local pending = 0

	for _, scope in ipairs(scopes) do
		if _is_local_scope(scope) and scope.variablesReference and scope.variablesReference ~= 0 then
			pending = pending + 1

			session:fetch_variables(scope, function()
				if scope.variables then
					vim.list_extend(vars, scope.variables)
				end

				pending = pending - 1
				if pending == 0 then
					cb(vars)
				end
			end)
		end
	end

	if pending == 0 then
		cb(vars)
	end
end

---Render `frame`'s values, once the adapter has served them.
---
---Two guards, for two different races: `_seq` drops a reply that a newer update
---has already superseded, and the context id drops one whose pause is over. The
---latter is not implied by the former: a resume schedules a clear rather than an
---update, so nothing would bump `_seq`, and the reply would land, cancel that
---pending clear and paint values from the finished pause over running code.
---@param session ndap.dap.Session
---@param frame   ndap.dap.StackFrame?
local function _update(session, frame)
	if not _active() then return end
	if not frame or not frame.source or not frame.source.path then return end

	_seq = _seq + 1
	local my_seq = _seq
	local context = manager.context_id()

	_collect_variables(session, frame, function(vars)
		if my_seq ~= _seq or manager.context_id() ~= context then return end

		_clear()
		_render_variables(frame, vars)
	end)
end

function M.clear()
	_clear()
end

---@param v boolean?  false disables; omitted/nil enables
function M.enable(v)
	_enabled = v ~= false
	if not _enabled then
		_clear()
	end
	-- All of these listen to the session-independent signals and filter on the
	-- active id, so disabling really does detach: handlers registered on a session
	-- object cannot be taken off it again, and would keep firing after the unsub.
	if _enabled and #_unsubs == 0 then
		---@param signal  ndap.util.Signal
		---@param handler any
		local function sub(signal, handler)
			_unsubs[#_unsubs + 1] = signal:subscribe(handler)
		end

		sub(manager.on_variable_changed, function(id, sess)
			if id ~= manager.active_id() then return end
			vim.schedule(function()
				_update(sess, sess:current_stack_frame())
			end)
		end)

		sub(manager.on_active_changed, function(_, sess)
			_clear()
			if sess and sess.state == "stopped" then
				_update(sess, sess:current_stack_frame())
			end
		end)

		sub(manager.on_session_stopped, function(id)
			local sess = manager.session()
			if id ~= manager.active_id() or not sess then return end
			_update(sess, sess:current_stack_frame())
		end)

		-- Values belong to a pause, so they go once it ends: at once for a session
		-- that is over, late for a resume so stepping doesn't blink them. A thread
		-- starting under a live breakpoint also reads as "running", which is why
		-- the thread the values were collected for is what decides.
		sub(manager.on_session_updated, function(id, info)
			if id ~= manager.active_id() then return end
			if info.state == "terminated" or info.state == "exited" then
				_clear()
				return
			end
			if info.is_paused then return end
			local sess   = manager.session()
			local thread = sess and sess:current_thread()
			if thread and thread.status == "stopped" then return end
			_deferred_clear(config.antiflicker_delay)
		end)
	end

	if not _enabled then
		for _, unsub in ipairs(_unsubs) do unsub() end
		_unsubs = {}
	end
end

---Re-render inline values for the active session's current frame, honouring the
---current placement mode. Clears when inactive or the session is not stopped.
function M.refresh()
	_clear()
	if not _active() then return end
	local sess = manager.session()
	if sess and sess.state == "stopped" then
		_update(sess, sess:current_stack_frame())
	end
end

---Change where inline values are rendered at runtime and re-render immediately.
---@param mode ndap.InlineVarsMode
function M.set_mode(mode)
	config.inline_vars = mode
	M.refresh()
end

return M
