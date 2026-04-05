require "nvchad.mappings"

-- add yours here

local map = vim.keymap.set
local tc = require "timeclock"

tc.setup()

map("n", ";", ":", { desc = "CMD enter command mode" })
map("i", "jk", "<ESC>")

-- map({ "n", "i", "v" }, "<C-s>", "<cmd> w <cr>")

map("n", "<leader>tt", tc.menu, { desc = "Timeclock menu" })

map("n", "<leader>ti", tc.clock_in, { desc = "Timeclock in" })
map("n", "<leader>to", tc.clock_out, { desc = "Timeclock out" })
map("n", "<leader>tb", tc.take_break, { desc = "Timeclock break" })
map("n", "<leader>tr", tc.resume, { desc = "Timeclock resume" })
map("n", "<leader>tc", tc.switch_project, { desc = "Timeclock switch project" })
map("n", "<leader>ta", function()
	tc.adjust_start()
end, { desc = "Timeclock adjust start" })

map("n", "<leader>ts", tc.weekly_summary, { desc = "Timeclock summary" })
map("n", "<leader>tf", tc.show_flex, { desc = "Timeclock flex" })
map("n", "<leader>th", tc.show_red_days, { desc = "Timeclock holidays" })
map("n", "<leader>te", tc.export_csv, { desc = "Timeclock export CSV" })

map("n", "<leader>tp", tc.switch_profile, { desc = "Timeclock switch profile" })
map("n", "<leader>tP", tc.switch_profile_select, { desc = "Timeclock choose profile" })
map("n", "<leader>tC", tc.edit_project, { desc = "Timeclock edit project" })
map("n", "<leader>td", tc.open_diary, { desc = "Timeclock open diary" })
map("n", "<leader>tE", tc.edit_log, { desc = "Timeclock edit log" })
map("n", "<leader>tB", tc.git_backup, { desc = "Timeclock git backup" })

map("n", "<leader>ad", function()
	local ok_dashboard, dashboard = pcall(require, "snacks.dashboard")
	if ok_dashboard and type(dashboard.open) == "function" then
		dashboard.open()
		return
	end

	local ok, snacks = pcall(require, "snacks")
	if not ok then
		vim.notify("Snacks dashboard is not available", vim.log.levels.WARN)
		return
	end

	if type(snacks.dashboard) == "function" then
		snacks.dashboard()
	elseif type(snacks.dashboard) == "table" and type(snacks.dashboard.open) == "function" then
		snacks.dashboard.open()
	else
		vim.notify("Could not open dashboard", vim.log.levels.WARN)
	end
end, { desc = "Open Albin dashboard" })
