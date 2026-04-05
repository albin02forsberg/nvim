-- This file needs to have same structure as nvconfig.lua 
-- https://github.com/NvChad/ui/blob/v3.0/lua/nvconfig.lua
-- Please read that file to know all available options :( 

---@type ChadrcConfig
local M = {}

M.base46 = {
	theme = "onedark",

	-- hl_override = {
	-- 	Comment = { italic = true },
	-- 	["@comment"] = { italic = true },
	-- },
}

M.ui = {
	statusline = {
		order = { "mode", "file", "git", "%=", "lsp_msg", "%=", "diagnostics", "lsp", "timeclock", "cwd", "cursor" },
		modules = {
			timeclock = function()
				local ok, tc = pcall(require, "timeclock")
				if not ok then
					return ""
				end
				local text = tc.modeline()
				if not text or text == "" then
					return ""
				end
				return "%#St_cwd_text# " .. text .. " "
			end,
		},
	},
}

-- M.nvdash = { load_on_startup = true }
-- M.ui = {
--       tabufline = {
--          lazyload = false
--      }
-- }

return M
