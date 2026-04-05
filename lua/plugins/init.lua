return {
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    init = function()
      local group = vim.api.nvim_create_augroup("albin_dashboard_statusline", { clear = true })
      local refresh_group = vim.api.nvim_create_augroup("albin_dashboard_refresh", { clear = true })

      local function dashboard_visible()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.bo[buf].filetype == "snacks_dashboard" then
            return true
          end
        end
        return false
      end

      local function refresh_dashboard()
        if not dashboard_visible() then
          return
        end

        local ok, dashboard = pcall(require, "snacks.dashboard")
        if ok and type(dashboard.update) == "function" then
          pcall(dashboard.update)
        end
      end

      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = "snacks_dashboard",
        callback = function()
          vim.o.laststatus = 3
        end,
      })

      vim.api.nvim_create_autocmd({ "FocusGained", "CursorHold", "BufEnter" }, {
        group = refresh_group,
        callback = refresh_dashboard,
      })

      vim.api.nvim_create_autocmd("BufWritePost", {
        group = refresh_group,
        pattern = (function()
          local tc_dir = vim.fn.expand(vim.g.timeclock_data_dir or "~/timeclock")
          if tc_dir:sub(-1) == "/" then
            tc_dir = tc_dir:sub(1, -2)
          end
          return {
            "*/dashboard/tasks.md",
            tc_dir .. "/timelog-*",
            tc_dir .. "/active_profile.txt",
          }
        end)(),
        callback = refresh_dashboard,
      })

      local dashboard_timer = vim.uv.new_timer()
      if dashboard_timer then
        dashboard_timer:start(60000, 60000, vim.schedule_wrap(refresh_dashboard))

        vim.api.nvim_create_autocmd("VimLeavePre", {
          group = refresh_group,
          callback = function()
            if dashboard_timer then
              dashboard_timer:stop()
              dashboard_timer:close()
              dashboard_timer = nil
            end
          end,
        })
      end
    end,
    opts = function()
      local has_nerd_font = vim.g.have_nerd_font == true
      local function icon(nerd, ascii)
        return has_nerd_font and nerd or ascii
      end

      local function dashboard_dir()
        local dir = vim.fn.stdpath("data") .. "/dashboard"
        vim.fn.mkdir(dir, "p")
        return dir
      end

      local function tasks_file()
        return dashboard_dir() .. "/tasks.md"
      end

      local function inbox_file()
        return dashboard_dir() .. "/inbox.md"
      end

      local function timeclock_dir()
        local dir = vim.fn.expand(vim.g.timeclock_data_dir or "~/timeclock")
        vim.fn.mkdir(dir, "p")
        return dir
      end

      local function active_profile()
        local f = timeclock_dir() .. "/active_profile.txt"
        if vim.fn.filereadable(f) == 1 then
          local p = (vim.fn.readfile(f)[1] or "work"):lower()
          if p ~= "" then
            return p
          end
        end
        return "work"
      end

      local function weather_line()
        if vim.fn.executable("curl") == 0 then
          return "curl not found"
        end
        local out = vim.fn.systemlist("curl -s wttr.in/Jonkoping?format=3")
        if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then
          return "Could not fetch weather"
        end
        return out[1]
      end

      local function upcoming_tasks(max_items)
        local file = tasks_file()
        if vim.fn.filereadable(file) == 0 then
          vim.fn.writefile({ "# Tasks", "", "- [ ] " .. os.date("%Y-%m-%d") .. " Example task" }, file)
        end

        local today = os.date("%Y-%m-%d")
        local last = os.date("%Y-%m-%d", os.time() + 2 * 86400)
        local lines = {}
        for _, l in ipairs(vim.fn.readfile(file)) do
          if l:match("^%s*%- %[[xX]%]") == nil then
            local d = l:match("(%d%d%d%d%-%d%d%-%d%d)")
            if d and d >= today and d <= last then
              local title = l:gsub("^%s*%- %[[ xX]%]%s*", "")
              table.insert(lines, "• " .. title)
            end
          end
          if #lines >= max_items then
            break
          end
        end
        if #lines == 0 then
          return { "No upcoming tasks" }
        end
        return lines
      end

      local function latest_timelog(max_items)
        local function shorten(text, max_len)
          if #text <= max_len then
            return text
          end
          return text:sub(1, max_len - 3) .. "..."
        end

        local ok, tc = pcall(require, "timeclock")
        if not ok or type(tc.export_rows) ~= "function" then
          return { "Timeclock export rows unavailable" }
        end

        local rows = tc.export_rows()
        if #rows == 0 then
          return { "No timelog yet" }
        end

        local p = active_profile()
        local start = math.max(1, #rows - max_items + 1)
        local out = { "Profile: " .. p, "Project | Description | Date | Duration" }
        for i = start, #rows do
          local row = rows[i]
          local proj = shorten(row.proj or "", 16)
          local desc = row.desc and row.desc ~= "" and shorten(row.desc, 18) or "-"
          table.insert(out, string.format("%s | %s | %s | %.2f", proj, desc, row.date or "", row.dur or 0))
        end
        return out
      end

      return {
        notifier = { enabled = true },
        quickfile = { enabled = true },
        dashboard = {
          enabled = true,
          width = 38,
          pane_gap = 3,
          preset = {
            header = [[
███╗   ██╗██╗   ██╗██╗███╗   ███╗
████╗  ██║██║   ██║██║████╗ ████║
██╔██╗ ██║██║   ██║██║██╔████╔██║
██║╚██╗██║╚██╗ ██╔╝██║██║╚██╔╝██║
██║ ╚████║ ╚████╔╝ ██║██║ ╚═╝ ██║
╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═╝     ╚═╝
          ]],
            keys = {
              { icon = icon(" ", "[F] "), key = "f", desc = "Find File", action = ":Telescope find_files" },
              { icon = icon("󰈚 ", "[R] "), key = "r", desc = "Recent Files", action = ":Telescope oldfiles" },
              { icon = icon("󰊄 ", "[G] "), key = "g", desc = "Live Grep", action = ":Telescope live_grep" },
              { icon = icon(" ", "[S] "), key = "S", desc = "Git Status", action = ":Telescope git_status" },
              { icon = icon("󱑆 ", "[T] "), key = "t", desc = "Timeclock Menu", action = function() require("timeclock").menu() end },
              { icon = icon(" ", "[M] "), key = "m", desc = "Mappings", action = ":NvCheatsheet" },
              {
                icon = icon("󰐕 ", "[C] "),
                key = "c",
                desc = "Quick Capture",
                action = function()
                  local inbox = inbox_file()
                  if vim.fn.filereadable(inbox) == 0 then
                    vim.fn.writefile({ "# Inbox", "" }, inbox)
                  end
                  vim.cmd("edit " .. inbox)
                  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "", "- [ ] " .. os.date("%Y-%m-%d") .. " " })
                  vim.cmd("normal! G$")
                  vim.cmd("startinsert")
                end,
              },
              { icon = icon(" ", "[Q] "), key = "q", desc = "Quit", action = ":qa" },
              { icon = icon("󱑆 ", "[I] "), key = "i", desc = "Clock In", action = function() require("timeclock").clock_in() end },
              { icon = icon("󱑆 ", "[O] "), key = "o", desc = "Clock Out", action = function() require("timeclock").clock_out() end },
              { icon = icon("󱑆 ", "[B] "), key = "b", desc = "Break", action = function() require("timeclock").take_break() end },
              { icon = icon("󱑆 ", "[R] "), key = "R", desc = "Resume", action = function() require("timeclock").resume() end },
              { icon = icon("󱑆 ", "[W] "), key = "w", desc = "Weekly Summary", action = function() require("timeclock").weekly_summary() end },
              { icon = icon("󱑆 ", "[F] "), key = "F", desc = "Show Flex", action = function() require("timeclock").show_flex() end },
            },
          },
          sections = {
            { section = "header", pane = 2, padding = 1 },
            { section = "keys", pane = 1, gap = 1, padding = 1 },
            function()
              local ok, line = pcall(function()
                return require("timeclock").modeline()
              end)
              if not ok then
                line = "Timeclock unavailable"
              elseif type(line) ~= "string" or line == "" then
                line = "No active clock"
              end
              return {
                pane = 2,
                title = "Timeclock",
                icon = icon("󱑆 ", "[T] "),
                text = line,
                padding = 1,
              }
            end,
            function()
              return {
                pane = 2,
                title = "Weather",
                icon = icon(" ", "[W] "),
                text = weather_line(),
              }
            end,
            function()
              return {
                pane = 2,
                title = "Upcoming Tasks",
                icon = icon("󰝒 ", "[T] "),
                text = table.concat(upcoming_tasks(8), "\n"),
                padding = 1,
              }
            end,
            {
              pane = 3,
              icon = icon(" ", "[R] "),
              title = "Recent Files",
              section = "recent_files",
              limit = 8,
              indent = 2,
              padding = 1,
            },
            {
              pane = 3,
              icon = icon(" ", "[P] "),
              title = "Projects",
              section = "projects",
              limit = 6,
              indent = 2,
              padding = 1,
            },
            function()
              return {
                pane = 3,
                title = "Latest Timelog Entries",
                icon = icon("󱑆 ", "[L] "),
                text = table.concat(latest_timelog(10), "\n"),
                padding = 1,
              }
            end,
            { section = "startup", pane = 1, padding = 1 },
          },
        },
      }
    end,
  },

  {
    "stevearc/conform.nvim",
    -- event = 'BufWritePre', -- uncomment for format on save
    opts = require "configs.conform",
  },

  -- These are some examples, uncomment them if you want to see them work!
  {
    "neovim/nvim-lspconfig",
    config = function()
      require "configs.lspconfig"
    end,
  },

  {
    "zbirenbaum/copilot.lua",
    event = "InsertEnter",
    cmd = "Copilot",
    opts = {
      panel = { enabled = false },
      suggestion = {
        enabled = true,
        auto_trigger = true,
        keymap = {
          accept = "<C-l>",
          next = "<M-]>",
          prev = "<M-[>",
          dismiss = "<C-]>",
        },
      },
    },
  },

  {
    "NeogitOrg/neogit",
    cmd = "Neogit",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-telescope/telescope.nvim",
      "nvim-tree/nvim-web-devicons",
    },
    keys = {
      {
        "<leader>gg",
        function()
          require("neogit").open()
        end,
        desc = "Open Neogit",
      },
    },
    opts = {
      integrations = {
        telescope = true,
      },
      kind = "tab",
    },
  },

  -- test new blink
  -- { import = "nvchad.blink.lazyspec" },

  -- {
  -- 	"nvim-treesitter/nvim-treesitter",
  -- 	opts = {
  -- 		ensure_installed = {
  -- 			"vim", "lua", "vimdoc",
  --      "html", "css"
  -- 		},
  -- 	},
  -- },
}
