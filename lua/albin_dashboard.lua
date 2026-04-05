local M = {}

local api = vim.api
local fn = vim.fn
local uv = vim.uv

math.randomseed(os.time())

local tc = require "timeclock"

local state = {
  weather = "Fetching weather...",
  timer = nil,
}

local BUF_NAME = "Albin Dashboard"
local RIGHT_COL = 57
local BAR_MAX = 8
local AGENDA_DAYS = 3
local DASH_DIR = fn.stdpath("data") .. "/dashboard/"
local TASKS_FILE = DASH_DIR .. "tasks.md"
local INBOX_FILE = DASH_DIR .. "inbox.md"

local quotes = {
  "Neovim is a text editor and a programmable UI toolkit.",
  "Tip: :Telescope oldfiles is your speed dial.",
  "Tip: :checkhealth catches setup drift fast.",
  "Tip: Keep capture friction near zero.",
  "Tip: A dashboard should answer, not ask.",
  "Tip: Use marks and jump lists like a GPS.",
}

local function ensure_dashboard_files()
  fn.mkdir(DASH_DIR, "p")
  if fn.filereadable(TASKS_FILE) == 0 then
    fn.writefile({ "# Tasks", "", "- [ ] " .. os.date("%Y-%m-%d") .. " Example task" }, TASKS_FILE)
  end
  if fn.filereadable(INBOX_FILE) == 0 then
    fn.writefile({ "# Inbox", "" }, INBOX_FILE)
  end
end

local function data_dir()
  local dir = fn.expand(vim.g.timeclock_data_dir or "~/timeclock/")
  if dir:sub(-1) ~= "/" then
    dir = dir .. "/"
  end
  return dir
end

local function profile_suffix()
  return tc.current_profile:lower()
end

local function log_file()
  return data_dir() .. "timelog-" .. profile_suffix()
end

local function projects_file()
  return data_dir() .. "projects-" .. profile_suffix() .. ".json"
end

local function flex_offset_file()
  return data_dir() .. "flex-offset-" .. profile_suffix() .. ".txt"
end

local function is_empty(s)
  return s == nil or s == ""
end

local function format_hm(decimal)
  local h = math.floor(decimal)
  local m = math.floor((decimal - h) * 60)
  if h > 0 then
    return string.format("%dh %02dm", h, m)
  end
  return string.format("%dm", m)
end

local function load_projects()
  local path = projects_file()
  if fn.filereadable(path) == 0 then
    return {}
  end
  local ok, parsed = pcall(vim.json.decode, table.concat(fn.readfile(path), "\n"))
  if ok and type(parsed) == "table" then
    return parsed
  end
  return {}
end

local function load_offset()
  if fn.filereadable(flex_offset_file()) == 1 then
    local v = tonumber(fn.readfile(flex_offset_file())[1])
    if v then
      return v
    end
  end
  return 0.0
end

local function parse_sessions()
  local sessions = {}
  local path = log_file()
  if fn.filereadable(path) == 0 then
    return sessions
  end

  local start_t, proj = nil, nil
  for _, line in ipairs(fn.readfile(path)) do
    local code, date_s, time_s, text = line:match("([ioO]) (%d+/%d+/%d+) (%d+:%d+:%d+)%s*(.*)")
    if code then
      local y, m, d = date_s:match("(%d+)/(%d+)/(%d+)")
      local hh, mm, ss = time_s:match("(%d+):(%d+):(%d+)")
      local t = os.time({ year = y, month = m, day = d, hour = hh, min = mm, sec = ss })
      if code == "i" then
        start_t = t
        proj = text
      elseif (code == "o" or code == "O") and start_t then
        if not text:match("---BREAK---") then
          table.insert(sessions, {
            date = os.date("%Y-%m-%d", start_t),
            proj = proj,
            desc = text,
            dur = (t - start_t) / 3600,
            start_time = os.date("%H:%M:%S", start_t),
            end_time = os.date("%H:%M:%S", t),
          })
        end
        start_t = nil
      end
    end
  end

  if start_t then
    table.insert(sessions, {
      date = os.date("%Y-%m-%d", start_t),
      proj = proj,
      desc = "Ongoing session",
      dur = (os.time() - start_t) / 3600,
      start_time = os.date("%H:%M:%S", start_t),
      end_time = os.date("%H:%M:%S"),
    })
  end

  return sessions
end

local function merge_empty_sessions(sessions)
  local merged = {}
  local active = {}

  for i = #sessions, 1, -1 do
    local s = sessions[i]
    local key = s.date .. "|" .. (s.proj or "")
    if is_empty(s.desc) or s.desc == "Ongoing session" then
      local idx = active[key]
      if idx then
        merged[idx].dur = merged[idx].dur + s.dur
      else
        table.insert(merged, vim.deepcopy(s))
        active[key] = #merged
      end
    else
      table.insert(merged, vim.deepcopy(s))
      active[key] = #merged
    end
  end

  local out = {}
  for i = #merged, 1, -1 do
    table.insert(out, merged[i])
  end
  return out
end

local function round_hours(hours, resolution, round_up)
  if not resolution or resolution <= 0 then
    return hours
  end
  local factor = 1.0 / resolution
  if round_up then
    return math.ceil(hours * factor) / factor
  end
  return math.floor(hours * factor + 0.5) / factor
end

local function apply_time_carry(sessions)
  local projects = load_projects()
  local carry = 0.0
  local out = {}

  for _, s in ipairs(sessions) do
    local p = projects[s.proj] or { rounding = 0.5, round_up = false }
    local exact = s.dur + carry
    local rounded = round_hours(exact, p.rounding or 0.5, p.round_up == true)
    carry = exact - rounded

    local copy = vim.deepcopy(s)
    copy.dur = rounded
    table.insert(out, copy)
  end

  return out
end

local function get_easter(year)
  local a = year % 19
  local b = math.floor(year / 100)
  local c = year % 100
  local d = math.floor(b / 4)
  local e = b % 4
  local f = math.floor((b + 8) / 25)
  local g = math.floor((b - f + 1) / 3)
  local h = (19 * a + b - d - g + 15) % 30
  local i = math.floor(c / 4)
  local k = c % 4
  local l = (32 + 2 * e + 2 * i - h - k) % 7
  local m = math.floor((a + 11 * h + 22 * l) / 451)
  local month = math.floor((h + l - 7 * m + 114) / 31)
  local day = ((h + l - 7 * m + 114) % 31) + 1
  return os.time({ year = year, month = month, day = day })
end

local function red_days(year)
  local easter = get_easter(year)
  local midsummer_eve
  for d = 19, 25 do
    local t = os.time({ year = year, month = 6, day = d })
    if tonumber(os.date("%u", t)) == 5 then
      midsummer_eve = t
      break
    end
  end

  return {
    [os.date("%Y-%m-%d", os.time({ year = year, month = 1, day = 1 }))] = true,
    [os.date("%Y-%m-%d", os.time({ year = year, month = 1, day = 6 }))] = true,
    [os.date("%Y-%m-%d", easter - 2 * 86400)] = true,
    [os.date("%Y-%m-%d", easter)] = true,
    [os.date("%Y-%m-%d", easter + 86400)] = true,
    [os.date("%Y-%m-%d", os.time({ year = year, month = 5, day = 1 }))] = true,
    [os.date("%Y-%m-%d", easter + 39 * 86400)] = true,
    [os.date("%Y-%m-%d", os.time({ year = year, month = 6, day = 6 }))] = true,
    [os.date("%Y-%m-%d", midsummer_eve)] = true,
    [os.date("%Y-%m-%d", os.time({ year = year, month = 12, day = 24 }))] = true,
    [os.date("%Y-%m-%d", os.time({ year = year, month = 12, day = 25 }))] = true,
    [os.date("%Y-%m-%d", os.time({ year = year, month = 12, day = 26 }))] = true,
    [os.date("%Y-%m-%d", os.time({ year = year, month = 12, day = 31 }))] = true,
  }
end

local function expected_hours(date_str)
  local y, m, d = date_str:match("(%d+)-(%d+)-(%d+)")
  local t = os.time({ year = y, month = m, day = d })
  if tonumber(os.date("%u", t)) > 5 then
    return 0.0
  end
  if red_days(tonumber(y))[date_str] then
    return 0.0
  end
  return 8.0
end

local function dashboard_data()
  local raw = parse_sessions()
  local merged = merge_empty_sessions(raw)
  local rounded = apply_time_carry(merged)

  local daily = {}
  local monthly = {}
  local week = {}
  local now = os.time()
  local week_start = now - ((tonumber(os.date("%u", now)) - 1) * 86400)
  local current_month = os.date("%Y-%m")

  local total_flex = load_offset()
  for _, s in ipairs(rounded) do
    daily[s.date] = (daily[s.date] or 0) + s.dur

    if s.date:sub(1, 7) == current_month then
      table.insert(monthly, s)
    end

    local ts = os.time({ year = s.date:sub(1, 4), month = s.date:sub(6, 7), day = s.date:sub(9, 10), hour = 12 })
    if ts >= week_start then
      table.insert(week, s)
    end
  end

  for date, hrs in pairs(daily) do
    total_flex = total_flex + (hrs - expected_hours(date))
  end

  table.sort(monthly, function(a, b)
    return a.date > b.date
  end)

  return {
    raw = raw,
    rounded = rounded,
    daily = daily,
    monthly = monthly,
    week = week,
    total_flex = total_flex,
  }
end

local function section(title)
  return {
    "   " .. title,
    "  ─────────────────────────────────────────────────",
  }
end

local function timeclock_widget(data)
  local lines = section("TIME STATUS")
  local is_in = false
  local active_proj = ""
  local elapsed = 0.0

  local log = log_file()
  if fn.filereadable(log) == 1 then
    local ls = fn.readfile(log)
    if #ls > 0 then
      local event, ds, ts, txt = ls[#ls]:match("([ioO]) (%d+/%d+/%d+) (%d+:%d+:%d+)%s*(.*)")
      if event == "i" then
        is_in = true
        active_proj = txt or ""
        local y, m, d = ds:match("(%d+)/(%d+)/(%d+)")
        local hh, mm, ss = ts:match("(%d+):(%d+):(%d+)")
        local start = os.time({ year = y, month = m, day = d, hour = hh, min = mm, sec = ss })
        elapsed = (os.time() - start) / 3600
      end
    end
  end

  local today = os.date("%Y-%m-%d")
  local today_hours = (data.daily[today] or 0) + elapsed

  table.insert(lines, string.format("  %-16s %s", "Current profile:", tc.current_profile))
  table.insert(lines, string.format("  %-16s %s%.2f h", "Total flex:", data.total_flex >= 0 and "+" or "", data.total_flex))
  if is_in then
    table.insert(lines, string.format("  %-16s Clocked in on %s (%s)", "Status:", active_proj, format_hm(elapsed)))
  else
    table.insert(lines, string.format("  %-16s Clocked out / On break", "Status:"))
  end
  table.insert(lines, string.format("  %-16s %.2f h", "Today:", today_hours))

  local bars = { "_", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
  local labels = { "M", "Tu", "W", "Th", "F", "Sa", "Su" }
  local bar_line = "  Last 7 days:      "
  local label_line = "                  "

  for i = 6, 0, -1 do
    local t = os.time() - i * 86400
    local date = os.date("%Y-%m-%d", t)
    local hrs = data.daily[date] or 0
    local idx = math.max(1, math.min(9, math.floor(hrs + 0.5) + 1))
    bar_line = bar_line .. bars[idx] .. " "

    local dow = tonumber(os.date("%u", t))
    label_line = label_line .. labels[dow] .. " "
  end

  table.insert(lines, bar_line)
  table.insert(lines, label_line)
  table.insert(lines, "")

  return lines
end

local function tasks_widget()
  local lines = section("UPCOMING TASKS")
  ensure_dashboard_files()
  if fn.filereadable(TASKS_FILE) == 0 then
    table.insert(lines, "  No tasks file")
    table.insert(lines, "")
    return lines
  end

  local raw = fn.readfile(TASKS_FILE)
  local shown = 0
  local today = os.date("%Y-%m-%d")
  local last = os.date("%Y-%m-%d", os.time() + (AGENDA_DAYS - 1) * 86400)

  for _, l in ipairs(raw) do
    local is_done = l:match("^%s*%- %[[xX]%]") ~= nil
    local d = l:match("(%d%d%d%d%-%d%d%-%d%d)")
    if d and d >= today and d <= last and not is_done then
      local title = l:gsub("^%s*%- %[[ xX]%]%s*", "")
      table.insert(lines, "  • " .. title)
      shown = shown + 1
      if shown >= 8 then
        break
      end
    end
  end

  if shown == 0 then
    table.insert(lines, "  Nothing queued")
  end
  table.insert(lines, "")
  return lines
end

local function projects_widget(data)
  local lines = section("PROJECTS")
  local totals = {}
  for _, s in ipairs(data.rounded) do
    local p = is_empty(s.proj) and "Other" or s.proj
    totals[p] = (totals[p] or 0) + s.dur
  end

  local names = vim.tbl_keys(totals)
  table.sort(names, function(a, b)
    return totals[a] > totals[b]
  end)

  if #names == 0 then
    table.insert(lines, "  No projects found")
  else
    for i = 1, math.min(5, #names) do
      table.insert(lines, string.format("  %s (%.2f h)", names[i], totals[names[i]]))
    end
  end
  table.insert(lines, "")
  return lines
end

local function recent_widget()
  local lines = section("RECENT FILES")
  if #vim.v.oldfiles == 0 then
    table.insert(lines, "  No recent files")
    table.insert(lines, "")
    return lines
  end

  local count = 0
  for _, p in ipairs(vim.v.oldfiles) do
    if uv.fs_stat(p) then
      local name = fn.fnamemodify(p, ":t")
      local dir = fn.fnamemodify(p, ":h:~")
      table.insert(lines, string.format("  %s  (%s)", name, dir))
      count = count + 1
      if count >= 5 then
        break
      end
    end
  end

  table.insert(lines, "")
  return lines
end

local function quick_commands_widget()
  local lines = section("QUICK COMMANDS")
  table.insert(lines, "  i in   o out   b break   r resume")
  table.insert(lines, "  C switch   p profile   P project")
  table.insert(lines, "  e csv   s weekly   d diary   c capture")
  table.insert(lines, "  g refresh   q close")
  table.insert(lines, "")
  return lines
end

local function right_month_logs(data)
  local lines = {
    "󱑆  THIS MONTH",
    "─────────────────────────────────────────────────",
  }

  local total = 0.0
  for _, s in ipairs(data.monthly) do
    total = total + s.dur
  end
  table.insert(lines, string.format("Total accumulated: %.2f h", total))
  table.insert(lines, "")
  table.insert(lines, "Date        Project                 Time")

  for i = 1, math.min(20, #data.monthly) do
    local s = data.monthly[i]
    local date = s.date:sub(6)
    local proj = (is_empty(s.proj) and "Other" or s.proj):sub(1, 22)
    table.insert(lines, string.format("%s    %-22s  %6.2f h", date, proj, s.dur))
  end

  if #data.monthly == 0 then
    table.insert(lines, "No entries this month yet")
  end

  return lines
end

local function right_week_report(data)
  local lines = {
    "",
    "",
    "󰃭  WEEKLY REPORT",
    "─────────────────────────────────────────────────",
  }

  local week_total = 0.0
  local by_day = {}
  for _, s in ipairs(data.week) do
    by_day[s.date] = (by_day[s.date] or 0) + s.dur
  end

  local now = os.time()
  local week_start = now - ((tonumber(os.date("%u", now)) - 1) * 86400)
  local names = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

  for i = 0, 6 do
    local ts = week_start + i * 86400
    local d = os.date("%Y-%m-%d", ts)
    local hrs = by_day[d] or 0.0
    week_total = week_total + hrs

    local filled = math.min(BAR_MAX, math.floor(hrs))
    local bar = string.rep("█", filled) .. string.rep("·", BAR_MAX - filled)
    table.insert(lines, string.format("%s  %s  %.2f h", names[i + 1], bar, hrs))
  end

  table.insert(lines, 5, string.format("This week: %.2f h", week_total))
  return lines
end

local function left_column(data)
  local lines = {}
  local banner = {
    "",
    "  ███╗   ██╗██╗   ██╗██╗███╗   ███╗",
    "  ████╗  ██║██║   ██║██║████╗ ████║",
    "  ██╔██╗ ██║██║   ██║██║██╔████╔██║",
    "  ██║╚██╗██║╚██╗ ██╔╝██║██║╚██╔╝██║",
    "  ██║ ╚████║ ╚████╔╝ ██║██║ ╚═╝ ██║",
    "  ╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═╝     ╚═╝",
    "           Control Dashboard",
    "",
  }

  vim.list_extend(lines, banner)

  local q = quotes[math.random(#quotes)]
  table.insert(lines, "  \"" .. q .. "\"")
  table.insert(lines, "")
  table.insert(lines, "  " .. os.date("%A, %d %B %Y") .. "  │  " .. state.weather)
  table.insert(lines, "")

  vim.list_extend(lines, timeclock_widget(data))
  vim.list_extend(lines, tasks_widget())
  vim.list_extend(lines, projects_widget(data))
  vim.list_extend(lines, recent_widget())
  vim.list_extend(lines, quick_commands_widget())

  local ok_lazy, lazy = pcall(require, "lazy")
  if ok_lazy then
    local stats = lazy.stats()
    table.insert(lines, string.format("  Plugins: %d/%d loaded in %dms", stats.loaded, stats.count, math.floor(stats.startuptime)))
  end
  table.insert(lines, "  Tip: g refreshes dashboard")
  table.insert(lines, "")

  return lines
end

local function combine_columns(left, right)
  local out = {}
  local max_lines = math.max(#left, #right)
  for i = 1, max_lines do
    local l = left[i] or ""
    local r = right[i] or ""
    out[i] = string.format("%-" .. tostring(RIGHT_COL) .. "s%s", l, r)
  end
  return out
end

local function setup_buffer_keymaps(buf)
  local map = function(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end

  map("i", tc.clock_in)
  map("o", tc.clock_out)
  map("b", tc.take_break)
  map("r", tc.resume)
  map("C", tc.switch_project)
  map("p", tc.switch_profile_select)
  map("P", tc.edit_project)
  map("e", tc.export_csv)
  map("s", tc.weekly_summary)
  map("d", tc.open_diary)

  map("c", function()
    ensure_dashboard_files()
    vim.cmd("edit " .. INBOX_FILE)
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "", "- [ ] " .. os.date("%Y-%m-%d") .. " " })
    vim.cmd "normal! G$"
    vim.cmd "startinsert"
  end)

  map("g", function()
    M.open(true)
  end)

  map("q", function()
    vim.cmd "close"
  end)
end

local function render(silent)
  local data = dashboard_data()
  local left = left_column(data)
  local right = {}
  vim.list_extend(right, right_month_logs(data))
  vim.list_extend(right, right_week_report(data))

  local lines = combine_columns(left, right)

  local buf = fn.bufnr(BUF_NAME)
  if buf == -1 then
    buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, BUF_NAME)
  end

  api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  api.nvim_set_option_value("swapfile", false, { buf = buf })
  api.nvim_set_option_value("modifiable", true, { buf = buf })
  api.nvim_set_option_value("filetype", "dashboard", { buf = buf })
  api.nvim_set_option_value("number", false, { win = 0 })
  api.nvim_set_option_value("relativenumber", false, { win = 0 })
  api.nvim_set_option_value("cursorline", false, { win = 0 })
  api.nvim_set_option_value("modifiable", true, { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = buf })

  if not silent then
    api.nvim_set_current_buf(buf)
  end

  setup_buffer_keymaps(buf)
end

local function fetch_weather_async()
  if fn.executable "curl" == 0 then
    state.weather = "curl not found"
    return
  end

  vim.system({ "curl", "-s", "wttr.in/Jonkoping?format=3" }, { text = true }, function(obj)
    local result = (obj.stdout or ""):gsub("%s+$", "")
    if obj.code == 0 and result ~= "" and not result:match "^Unknown" then
      state.weather = result
    else
      state.weather = "Could not fetch weather"
    end

    vim.schedule(function()
      if fn.bufnr(BUF_NAME) ~= -1 then
        render(true)
      end
    end)
  end)
end

function M.open(silent)
  fetch_weather_async()
  render(silent)
end

function M.start_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end

  local timer = uv.new_timer()
  timer:start(0, 60000, vim.schedule_wrap(function()
    if fn.bufnr(BUF_NAME) ~= -1 then
      fetch_weather_async()
      render(true)
    end
  end))

  state.timer = timer
end

function M.setup()
  ensure_dashboard_files()

  api.nvim_create_user_command("AlbinDashboard", function()
    M.open(false)
  end, {})

  M.start_timer()
end

return M
