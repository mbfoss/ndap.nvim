local M = {}

local _ELLIPSIS = "…"

---The `width` display cells of `str` that survive cutting, keeping the start of
---the string, or its end when `right`. Adds no ellipsis -- callers decorate.
---
---Cuts between graphemes, never inside one, so a combining mark stays with the
---character it decorates. The result is the widest such run that fits.
---@param str string
---@param width integer  display cells
---@param right? boolean  cut from the left, keeping the end of the string
---@return string
function M.fit_to_width(str, width, right)
	if width <= 0 then return "" end
	local total_width = vim.api.nvim_strwidth(str)
	if total_width <= width then return str end
	-- one byte per cell, so the byte slice is already exact
	if total_width == #str then
		return right and str:sub(#str - width + 1) or str:sub(1, width)
	end

	-- Binary search the grapheme count that fits, measuring each candidate whole:
	-- summing per-character widths would miscount composing sequences. Every
	-- grapheme costs at least one cell, so `width` of them is an upper bound --
	-- for a long string cropped to a small window that is most of the search.
	-- `strcharpart` clamps a too-long count, so a left cut never needs the total
	local total = right and vim.fn.strchars(str, 1) or 0
	local lo, hi = 0, right and (total < width and total or width) or width
	local best = "" -- the last candidate that fit, so the search need not redo it
	while lo < hi do
		local mid = math.ceil((lo + hi) / 2)
		local part = right and vim.fn.strcharpart(str, total - mid, mid, 1)
			or vim.fn.strcharpart(str, 0, mid, 1)
		if vim.api.nvim_strwidth(part) <= width then
			lo, best = mid, part
		else
			hi = mid - 1
		end
	end
	return best
end

---@param str string
---@param max_len number  display cells
---@param right? boolean  crop from the left, keeping the end of the string
---@return string preview
---@return boolean is_different
function M.crop_for_ui(str, max_len, right)
	assert(type(str) == 'string', str)
	max_len = math.max(max_len, 2)
	local width = vim.api.nvim_strwidth(str)
	if width <= max_len then return str, false end
	local kept -- the ellipsis takes a cell of the budget
	if width == #str then -- one byte per cell, so the byte slice is already exact
		kept = right and str:sub(#str - max_len + 2) or str:sub(1, max_len - 1)
	else
		kept = M.fit_to_width(str, max_len - 1, right)
	end
	if right then
		return _ELLIPSIS .. kept, true
	end
	return kept .. _ELLIPSIS, true
end

---Split `str` on whitespace into words. There is no quoting: quotes and
---backslashes are ordinary characters. Only for commands whose arguments
---contain no whitespace; otherwise use the list form.
---@param str string
---@return string[]
function M.split_words(str)
	local words = {}
	for word in str:gmatch("%S+") do
		words[#words + 1] = word
	end
	return words
end

---Convert a command line or argv list to an argv list. A string splits on
---whitespace; a list is returned as-is, not copied.
---@param cmd string|string[]|nil
---@return string[]
function M.cmd_to_string_array(cmd)
	local t = type(cmd)
	if t == "string" then
		return M.split_words(cmd)
	elseif t == "table" then
		return cmd
	elseif t ~= "nil" then
		error("command must be a string or a list, got " .. t, 2)
	end
	return {}
end

---@param str string
---@param regex_list vim.regex[]
---@return boolean
local function any_match(str, regex_list)
	for _, pat in ipairs(regex_list) do
		if pat:match_str(str) then
			return true
		end
	end
	return false
end

---@param path string
---@param is_dir boolean
---@param include_regex vim.regex[]?
---@param exclude_regex vim.regex[]?
---@return boolean
function M.check_path_pattern(path, is_dir, include_regex, exclude_regex)
	if is_dir and path:sub(-1) == "/" then
		path = path:sub(1, #path - 1)
	end
	if exclude_regex then
		if any_match(path, exclude_regex) then
			return false
		end
		if is_dir and any_match(path .. '/', exclude_regex) then
			return false
		end
	end
	if include_regex then
		return any_match(path, include_regex)
	end
	return true
end

return M
