local M = {}

local fn = vim.fn
local api = vim.api

M.profiles = { "Work", "Personal" }

local default_data_dir = fn.expand("~/timeclock/")
local legacy_data_dirs = {
  fn.expand("~/.local/share/timeclock/"),
  fn.stdpath("data") .. "/timeclock/",
}
local data_dir = fn.expand(vim.g.timeclock_data_dir or default_data_dir)
if data_dir:sub(-1) ~= "/" then
  data_dir = data_dir .. "/"
end

fn.mkdir(data_dir, "p")

local function migrate_legacy_data()
  for _, legacy_dir in ipairs(legacy_data_dirs) do
    if legacy_dir:sub(-1) ~= "/" then
      legacy_dir = legacy_dir .. "/"
    end

    if legacy_dir ~= data_dir and fn.isdirectory(legacy_dir) == 1 then
      for _, src in ipairs(fn.glob(legacy_dir .. "*", false, true)) do
        local name = fn.fnamemodify(src, ":t")
        local dst = data_dir .. name
        if fn.filereadable(src) == 1 and fn.filereadable(dst) == 0 then
          local ok, lines = pcall(fn.readfile, src)
          if ok then
            fn.writefile(lines, dst)
          end
        end
      end
    end
  end
end

migrate_legacy_data()

local active_profile_file = data_dir .. "active_profile.txt"

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Timeclock" })
end

local function load_profile()
  if fn.filereadable(active_profile_file) == 1 then
    local p = fn.readfile(active_profile_file)[1]
    if vim.tbl_contains(M.profiles, p) then
      return p
    end
  end
  return "Work"
end

M.current_profile = load_profile()

local function get_file(kind)
  local suffix = M.current_profile:lower()
  if kind == "log" then
    return data_dir .. "timelog-" .. suffix
  end
  if kind == "proj" then
    return data_dir .. "projects-" .. suffix .. ".json"
  end
  if kind == "pause" then
    return data_dir .. "paused-" .. suffix .. ".txt"
  end
  if kind == "diary" then
    return data_dir .. "diary-" .. suffix .. ".md"
  end
  if kind == "flex" then
    return data_dir .. "flex-offset-" .. suffix .. ".txt"
  end
  return nil
end

local function ensure_profile_files()
  local log_file = get_file("log")
  if fn.filereadable(log_file) == 0 then
    fn.writefile({}, log_file)
  end
end

local function load_projects()
  local path = get_file("proj")
  if fn.filereadable(path) == 1 then
    local content = table.concat(fn.readfile(path), "\n")
    local ok, parsed = pcall(vim.json.decode, content)
    if ok and type(parsed) == "table" then
      return parsed
    end
  end
  return {}
end

local function save_projects(data)
  fn.writefile({ vim.json.encode(data) }, get_file("proj"))
end

local function load_flex_offset()
  local path = get_file("flex")
  if fn.filereadable(path) == 1 then
    local v = tonumber(fn.readfile(path)[1])
    if v then
      return v
    end
  end
  return 0.0
end

local function is_empty(s)
  return s == nil or s == ""
end

local function format_hours_to_hm(decimal_hours)
  local h = math.floor(decimal_hours)
  local m = math.floor((decimal_hours - h) * 60)
  if h > 0 then
    return string.format("%dh %02dm", h, m)
  end
  return string.format("%dm", m)
end

local function get_last_event()
  local log = get_file("log")
  if fn.filereadable(log) == 0 then
    return nil
  end

  local lines = fn.readfile(log)
  if #lines == 0 then
    return nil
  end

  local last = lines[#lines]
  local event, date_str, time_str, text = last:match("([ioO]) (%d+/%d+/%d+) (%d+:%d+:%d+)%s*(.*)")
  if not event then
    return nil
  end

  local y, m, d = date_str:match("(%d+)/(%d+)/(%d+)")
  local hh, mm, ss = time_str:match("(%d+):(%d+):(%d+)")
  local t = os.time({ year = y, month = m, day = d, hour = hh, min = mm, sec = ss })

  return { event = event, time = t, text = text or "" }
end

local function is_clocked_in()
  local last = get_last_event()
  return last and last.event == "i"
end

function M.raw_log(code, text)
  local f = io.open(get_file("log"), "a")
  if not f then
    notify("Could not open timelog for writing", vim.log.levels.ERROR)
    return
  end

  f:write(string.format("%s %s %s\n", code, os.date("%Y/%m/%d %H:%M:%S"), text or ""))
  f:close()
end

local function parse_sessions()
  local sessions = {}
  local path = get_file("log")
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
        local desc = text
        if text:match("---BREAK---") then
          desc = ""
        end

        table.insert(sessions, {
          date = os.date("%Y-%m-%d", start_t),
          proj = proj,
          desc = desc,
          dur = (t - start_t) / 3600,
          start_time = os.date("%H:%M:%S", start_t),
          end_time = os.date("%H:%M:%S", t)
          

        })
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

local function round_hours_custom(hours, resolution, round_up)
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
  local rounded = {}

  for _, s in ipairs(sessions) do
    local p = projects[s.proj] or { rounding = 0.5, round_up = false }
    local exact = s.dur + carry
    local rounded_hours = round_hours_custom(exact, p.rounding or 0.5, p.round_up == true)
    carry = exact - rounded_hours

    local copy = vim.deepcopy(s)
    copy.dur = rounded_hours
    table.insert(rounded, copy)
  end

  return rounded, carry
end

local function calculate_easter(year)
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

local function swedish_red_days(year)
  local easter = calculate_easter(year)

  local midsummer_eve
  for d = 19, 25 do
    local t = os.time({ year = year, month = 6, day = d })
    if tonumber(os.date("%u", t)) == 5 then
      midsummer_eve = t
      break
    end
  end

  local all_saints
  for month = 10, 11 do
    local start_day = month == 10 and 31 or 1
    local end_day = month == 10 and 31 or 6
    for d = start_day, end_day do
      local t = os.time({ year = year, month = month, day = d })
      if tonumber(os.date("%u", t)) == 6 then
        all_saints = t
        break
      end
    end
    if all_saints then
      break
    end
  end

  local days = {
    [os.date("%Y-%m-%d", os.time({ year = year, month = 1, day = 1 }))] = "New Year's Day",
    [os.date("%Y-%m-%d", os.time({ year = year, month = 1, day = 6 }))] = "Epiphany",
    [os.date("%Y-%m-%d", easter - 2 * 86400)] = "Good Friday",
    [os.date("%Y-%m-%d", easter)] = "Easter Sunday",
    [os.date("%Y-%m-%d", easter + 86400)] = "Easter Monday",
    [os.date("%Y-%m-%d", os.time({ year = year, month = 5, day = 1 }))] = "May 1st",
    [os.date("%Y-%m-%d", easter + 39 * 86400)] = "Ascension Day",
    [os.date("%Y-%m-%d", easter + 49 * 86400)] = "Pentecost",
    [os.date("%Y-%m-%d", os.time({ year = year, month = 6, day = 6 }))] = "National Day",
    [os.date("%Y-%m-%d", midsummer_eve)] = "Midsummer Eve",
    [os.date("%Y-%m-%d", midsummer_eve + 86400)] = "Midsummer Day",
    [os.date("%Y-%m-%d", all_saints)] = "All Saints' Day",
    [os.date("%Y-%m-%d", os.time({ year = year, month = 12, day = 24 }))] = "Christmas Eve",
    [os.date("%Y-%m-%d", os.time({ year = year, month = 12, day = 25 }))] = "Christmas Day",
    [os.date("%Y-%m-%d", os.time({ year = year, month = 12, day = 26 }))] = "Boxing Day",
    [os.date("%Y-%m-%d", os.time({ year = year, month = 12, day = 31 }))] = "New Year's Eve",
  }

  return days
end

local function expected_hours_for_date(date_str)
  local y, m, d = date_str:match("(%d+)-(%d+)-(%d+)")
  local t = os.time({ year = y, month = m, day = d })
  if tonumber(os.date("%u", t)) > 5 then
    return 0.0
  end

  local red_days = swedish_red_days(tonumber(y))
  if red_days[date_str] then
    return 0.0
  end

  return 8.0
end

local function append_to_diary(project, reason, duration_hours)
  if is_empty(reason) or reason:match("---BREAK---") then
    return
  end

  local date_heading = "## " .. os.date("%Y-%m-%d %A")
  local time_str = os.date("%H:%M")
  local proj = is_empty(project) and "Other" or project
  local entry = string.format("- [%s] **%s** (%s): %s", time_str, proj, format_hours_to_hm(duration_hours), reason)

  local path = get_file("diary")
  local lines = {}
  if fn.filereadable(path) == 1 then
    lines = fn.readfile(path)
  end

  local has_heading = false
  for _, line in ipairs(lines) do
    if line == date_heading then
      has_heading = true
      break
    end
  end

  if #lines > 0 and lines[#lines] ~= "" then
    table.insert(lines, "")
  end
  if not has_heading then
    table.insert(lines, date_heading)
  end
  table.insert(lines, entry)

  fn.writefile(lines, path)
end

local function create_project_interactive(projects, proj, done)
  vim.ui.input({ prompt = "Export code (default: " .. proj .. "): " }, function(export_code)
    local code = (export_code and export_code ~= "") and export_code or proj

    vim.ui.input({ prompt = "Rounding in hours (default: 0.5, 0 disables): " }, function(rounding_input)
      local rounding = tonumber(rounding_input)
      if rounding == nil then
        rounding = 0.5
      end
      if rounding < 0 then
        rounding = 0.5
      end

      vim.ui.select({ "Nearest", "Always up" }, { prompt = "Rounding mode:" }, function(mode)
        projects[proj] = {
          export_code = code,
          rounding = rounding,
          round_up = (mode == "Always up"),
          active = true,
        }
        save_projects(projects)
        done(projects[proj])
      end)
    end)
  end)
end

function M.clock_in()
  ensure_profile_files()
  local projects = load_projects()

  local active = {}
  for name, props in pairs(projects) do
    if props.active ~= false then
      table.insert(active, name)
    end
  end
  table.sort(active)

  vim.ui.select(active, { prompt = "Clock in on project (or cancel for new):" }, function(choice)
    if choice then
      M._do_clock_in(choice)
      return
    end

    vim.ui.input({ prompt = "New project: " }, function(input)
      if input and input ~= "" then
        M._do_clock_in(input)
      end
    end)
  end)
end

function M._do_clock_in(proj, opts)
  opts = opts or {}
  ensure_profile_files()

  if is_clocked_in() then
    M.clock_out("Auto-switch", { silent = true })
  end

  local projects = load_projects()

  local finalize = function(project)
    local pause_file = get_file("pause")
    if fn.filereadable(pause_file) == 1 then
      fn.delete(pause_file)
    end

    M.raw_log("i", project.export_code or proj)
    if not opts.silent then
      notify("Clocked in on: " .. proj)
    end
  end

  if projects[proj] then
    finalize(projects[proj])
    return
  end

  if opts.skip_new_project_prompt then
    projects[proj] = { export_code = proj, rounding = 0.5, round_up = false, active = true }
    save_projects(projects)
    finalize(projects[proj])
    return
  end

  create_project_interactive(projects, proj, finalize)
end

function M.clock_out(auto_reason, opts)
  opts = opts or {}
  if not is_clocked_in() then
    notify("Not clocked in", vim.log.levels.WARN)
    return
  end

  local finish = function(reason)
    reason = reason or ""
    local last = get_last_event()
    local duration_hours = 0.0
    if last then
      duration_hours = math.max(0, (os.time() - last.time) / 3600)
      append_to_diary(last.text, reason, duration_hours)
    end

    M.raw_log("o", reason)
    if not opts.silent then
      notify("Clocked out")
    end
  end

  if auto_reason then
    finish(auto_reason)
  else
    vim.ui.input({ prompt = "What did you do? " }, finish)
  end
end

function M.take_break()
  local last = get_last_event()
  if not last or last.event ~= "i" then
    notify("Not clocked in", vim.log.levels.WARN)
    return
  end

  fn.writefile({ last.text }, get_file("pause"))
  M.raw_log("o", "---BREAK---")
  notify("Break started")
end

function M.resume()
  local pause_file = get_file("pause")
  if fn.filereadable(pause_file) == 0 then
    notify("No break to resume", vim.log.levels.WARN)
    return
  end

  local proj = fn.readfile(pause_file)[1]
  M.raw_log("i", proj)
  fn.delete(pause_file)
  notify("Resumed: " .. proj)
end

function M.switch_project()
  if not is_clocked_in() then
    M.clock_in()
    return
  end

  vim.ui.input({ prompt = "Switching project. What did you do until now? " }, function(reason)
    M.clock_out(reason)
    M.clock_in()
  end)
end

function M.adjust_start(minutes)
  if minutes == nil then
    vim.ui.input({ prompt = "Minutes ago you started: " }, function(input)
      M.adjust_start(tonumber(input))
    end)
    return
  end

  local m = tonumber(minutes)
  if not m then
    notify("Invalid minutes", vim.log.levels.WARN)
    return
  end

  if not is_clocked_in() then
    notify("Must be clocked in", vim.log.levels.WARN)
    return
  end

  local path = get_file("log")
  local lines = fn.readfile(path)
  if #lines == 0 then
    return
  end

  local last_line = lines[#lines]
  local _, d_str, t_str, text = last_line:match("([i]) (%d+/%d+/%d+) (%d+:%d+:%d+)%s*(.*)")
  if not d_str then
    notify("Could not parse latest clock-in event", vim.log.levels.WARN)
    return
  end

  local y, mo, d = d_str:match("(%d+)/(%d+)/(%d+)")
  local hh, mm, ss = t_str:match("(%d+):(%d+):(%d+)")
  local old_t = os.time({ year = y, month = mo, day = d, hour = hh, min = mm, sec = ss })
  local new_t = old_t - (m * 60)

  lines[#lines] = string.format("i %s %s", os.date("%Y/%m/%d %H:%M:%S", new_t), text)
  fn.writefile(lines, path)
  notify("Adjusted start time back " .. m .. " minutes")
end

function M.edit_project()
  local projects = load_projects()
  local names = vim.tbl_keys(projects)
  table.sort(names)

  if #names == 0 then
    notify("No projects to edit", vim.log.levels.WARN)
    return
  end

  vim.ui.select(names, { prompt = "Edit project:" }, function(name)
    if not name then
      return
    end

    local props = projects[name] or {}
    local current_code = props.export_code or name
    local current_rounding = props.rounding or 0.5
    local current_round_up = props.round_up == true
    local current_active = props.active ~= false

    vim.ui.input({ prompt = "Export code (" .. current_code .. "): " }, function(code_input)
      local code = (code_input and code_input ~= "") and code_input or current_code
      vim.ui.input({ prompt = "Rounding (" .. tostring(current_rounding) .. "): " }, function(rounding_input)
        local rounding = tonumber(rounding_input)
        if rounding == nil then
          rounding = current_rounding
        end

        vim.ui.select({ "Nearest", "Always up" }, { prompt = "Rounding mode:" }, function(mode)
          local round_up = mode == nil and current_round_up or (mode == "Always up")
          vim.ui.select({ "Active", "Inactive" }, { prompt = "Project status:" }, function(status)
            local active = status == nil and current_active or (status == "Active")
            projects[name] = {
              export_code = code,
              rounding = rounding,
              round_up = round_up,
              active = active,
            }
            save_projects(projects)
            notify("Project updated: " .. name)
          end)
        end)
      end)
    end)
  end)
end

function M.show_red_days()
  local year = tonumber(os.date("%Y"))
  local days = swedish_red_days(year)
  local sorted = vim.tbl_keys(days)
  table.sort(sorted)

  local lines = {
    "SWEDISH PUBLIC HOLIDAYS " .. year,
    string.rep("-", 44),
  }

  for _, date in ipairs(sorted) do
    table.insert(lines, string.format("%s : %s", date, days[date]))
  end

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"
  vim.cmd("split | buffer " .. buf)
end

function M.show_flex()
  local sessions = parse_sessions()
  local merged = merge_empty_sessions(sessions)
  local rounded = apply_time_carry(merged)

  local daily = {}
  for _, s in ipairs(rounded) do
    daily[s.date] = (daily[s.date] or 0) + s.dur
  end

  local total = load_flex_offset()
  for date, hrs in pairs(daily) do
    total = total + (hrs - expected_hours_for_date(date))
  end

  notify(string.format("Total flextime (%s): %s%.2f hours", M.current_profile, total >= 0 and "+" or "", total))
end

function M.weekly_summary()
  local end_date = os.date("%Y-%m-%d")
  local start_date = os.date("%Y-%m-%d", os.time() - 7 * 86400)

  local raw_sessions = parse_sessions()
  local merged = merge_empty_sessions(raw_sessions)
  local rounded = apply_time_carry(merged)

  local project_raw = {}
  local project_billable = {}
  local daily = {}
  local total_raw = 0.0
  local total_billable = 0.0
  local session_count = 0

  for _, s in ipairs(merged) do
    if s.date >= start_date and s.date <= end_date then
      local proj = is_empty(s.proj) and "Other" or s.proj
      total_raw = total_raw + s.dur
      session_count = session_count + 1
      project_raw[proj] = (project_raw[proj] or 0.0) + s.dur
      daily[s.date] = daily[s.date] or {}
      table.insert(daily[s.date], s)
    end
  end

  for _, s in ipairs(rounded) do
    if s.date >= start_date and s.date <= end_date then
      local proj = is_empty(s.proj) and "Other" or s.proj
      total_billable = total_billable + s.dur
      project_billable[proj] = (project_billable[proj] or 0.0) + s.dur
    end
  end

  local lines = {
    "# Time Report (" .. M.current_profile .. ")",
    "Range: " .. start_date .. " to " .. end_date,
    "",
    "## Summary",
    string.format("- Hours worked: %.2f h", total_raw),
    string.format("- Billable: %.2f h", total_billable),
    string.format("- Sessions: %d", session_count),
    "",
    "## Project Breakdown",
    "| Project | Worked | Billable | Share |",
    "|---|---:|---:|---:|",
  }

  local proj_names = vim.tbl_keys(project_billable)
  table.sort(proj_names, function(a, b)
    return (project_billable[a] or 0) > (project_billable[b] or 0)
  end)

  for _, name in ipairs(proj_names) do
    local raw = project_raw[name] or 0
    local bill = project_billable[name] or 0
    local share = total_billable > 0 and math.floor((bill / total_billable) * 100 + 0.5) or 0
    table.insert(lines, string.format("| %s | %.2f h | %.2f h | %d%% |", name, raw, bill, share))
  end

  table.insert(lines, "")
  table.insert(lines, "## Detailed Log")

  local dates = vim.tbl_keys(daily)
  table.sort(dates)
  for _, date in ipairs(dates) do
    local total_day = 0.0
    for _, s in ipairs(daily[date]) do
      total_day = total_day + s.dur
    end

    table.insert(lines, "")
    table.insert(lines, string.format("### %s (%.2f h)", date, total_day))
    for _, s in ipairs(daily[date]) do
      local proj = is_empty(s.proj) and "Other" or s.proj
      local desc = is_empty(s.desc) and "No description" or s.desc
      table.insert(lines, string.format("- [%s - %s] **%s** (%.2f h) - %s", s.start_time, s.end_time, proj, s.dur, desc))
    end
  end

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"
  vim.cmd("vsplit | buffer " .. buf)
end

function M.export_csv()
  local sessions = apply_time_carry(parse_sessions())

  if #sessions == 0 then
    notify("No sessions to export", vim.log.levels.WARN)
    return
  end

  local function csv_escape(s)
    s = tostring(s or "")
    return '"' .. s:gsub('"', '""') .. '"'
  end

  local function aggregate_for_csv(rows)
    local groups = {}
    local group_order = {}

    for _, s in ipairs(rows) do
      local date = s.date or ""
      local proj = s.proj or ""
      local desc = s.desc or ""
      if desc == "Ongoing session" then
        desc = ""
      end

      local group_key = date .. "\31" .. proj
      local g = groups[group_key]
      if not g then
        g = {
          rows = {},
          row_by_desc = {},
          pending_empty = 0.0,
          has_non_empty = false,
          last_non_empty_idx = nil,
        }
        groups[group_key] = g
        table.insert(group_order, group_key)
      end

      if is_empty(desc) then
        if g.has_non_empty and g.last_non_empty_idx then
          g.rows[g.last_non_empty_idx].dur = g.rows[g.last_non_empty_idx].dur + s.dur
        else
          g.pending_empty = g.pending_empty + s.dur
        end
      else
        local idx = g.row_by_desc[desc]
        if not idx then
          table.insert(g.rows, { proj = proj, desc = desc, date = date, dur = 0.0 })
          idx = #g.rows
          g.row_by_desc[desc] = idx
        end

        g.rows[idx].dur = g.rows[idx].dur + s.dur
        if not g.has_non_empty and g.pending_empty > 0 then
          g.rows[idx].dur = g.rows[idx].dur + g.pending_empty
          g.pending_empty = 0.0
        end

        g.has_non_empty = true
        g.last_non_empty_idx = idx
      end
    end

    local out = {}
    for _, key in ipairs(group_order) do
      local g = groups[key]
      if (not g.has_non_empty) and g.pending_empty > 0 then
        local date, proj = key:match("^(.*)\31(.*)$")
        table.insert(g.rows, { proj = proj or "", desc = "", date = date or "", dur = g.pending_empty })
      end
      for _, row in ipairs(g.rows) do
        table.insert(out, row)
      end
    end

    return out
  end

  local min_date = sessions[1].date
  local max_date = sessions[1].date
  for _, s in ipairs(sessions) do
    if s.date < min_date then
      min_date = s.date
    end
    if s.date > max_date then
      max_date = s.date
    end
  end

  vim.ui.input({ prompt = "Export from date (YYYY-MM-DD, default " .. min_date .. "): " }, function(start_input)
    local start_date = (start_input and start_input ~= "") and start_input or min_date

    vim.ui.input({ prompt = "Export to date (YYYY-MM-DD, default " .. max_date .. "): " }, function(end_input)
      local end_date = (end_input and end_input ~= "") and end_input or max_date
      local path = fn.expand("~/timeclock_export_" .. M.current_profile:lower() .. ".csv")
      local lines = { "Project,Description,Date,Duration" }

      local selected = {}

      for _, s in ipairs(sessions) do
        if s.date >= start_date and s.date <= end_date then
          table.insert(selected, s)
        end
      end

      local aggregated = aggregate_for_csv(selected)
      for _, s in ipairs(aggregated) do
        table.insert(lines, string.format("%s,%s,%s,%s", csv_escape(s.proj), csv_escape(s.desc), csv_escape(s.date), csv_escape(string.format("%.2f", s.dur))))
      end

      fn.writefile(lines, path)
      notify("CSV exported to " .. path)
    end)
  end)
end

local function next_profile(current)
  local idx = 1
  for i, p in ipairs(M.profiles) do
    if p == current then
      idx = i
      break
    end
  end
  return M.profiles[(idx % #M.profiles) + 1]
end

local function set_profile(choice)
  if not choice or choice == M.current_profile then
    return
  end

  if not vim.tbl_contains(M.profiles, choice) then
    notify("Unknown profile: " .. tostring(choice), vim.log.levels.WARN)
    return
  end

  local active_project = nil
  if is_clocked_in() then
    local last = get_last_event()
    active_project = last and last.text or nil
    M.clock_out("Switched profile", { silent = true })
  end

  M.current_profile = choice
  fn.writefile({ choice }, active_profile_file)
  ensure_profile_files()

  if active_project and active_project ~= "" then
    M._do_clock_in(active_project, { skip_new_project_prompt = true, silent = true })
    notify("Profile switched to " .. choice .. " (continued: " .. active_project .. ")")
  else
    notify("Profile switched to " .. choice)
  end
end

function M.switch_profile()
  set_profile(next_profile(M.current_profile))
end

function M.switch_profile_select()
  vim.ui.select(M.profiles, { prompt = "Switch profile:" }, function(choice)
    set_profile(choice)
  end)
end

function M.open_diary()
  ensure_profile_files()
  vim.cmd("edit " .. get_file("diary"))
end

function M.edit_log()
  ensure_profile_files()
  vim.cmd("edit " .. get_file("log"))
end

function M.git_backup()
  ensure_profile_files()
  local cmds = {
    { "git", "-C", data_dir, "add", "." },
    { "git", "-C", data_dir, "commit", "-m", "Auto-backup " .. os.date("%Y-%m-%d %H:%M") },
    { "git", "-C", data_dir, "push" },
  }

  for _, cmd in ipairs(cmds) do
    fn.system(cmd)
    if vim.v.shell_error ~= 0 then
      notify("Git backup failed. Is " .. data_dir .. " a git repo?", vim.log.levels.WARN)
      return
    end
  end

  notify("Timeclock backup pushed")
end

function M.modeline()
  local sessions = parse_sessions()
  local today = os.date("%Y-%m-%d")
  local hours_today = 0.0

  for _, s in ipairs(sessions) do
    if s.date == today then
      hours_today = hours_today + s.dur
    end
  end

  local last = get_last_event()
  local current_proj = nil
  if last and last.event == "i" then
    current_proj = last.text
  end

  local h = math.floor(hours_today)
  local m = math.floor((hours_today - h) * 60)

  if current_proj then
    return string.format("[%s] [%s] %dh %02dm", M.current_profile, current_proj, h, m)
  end
  return string.format("[%s] [Paused] %dh %02dm", M.current_profile, h, m)
end

function M.menu()
  local actions = {
    { key = "i", label = "Clock in", fn = M.clock_in },
    { key = "o", label = "Clock out", fn = M.clock_out },
    { key = "b", label = "Take break", fn = M.take_break },
    { key = "r", label = "Resume", fn = M.resume },
    { key = "c", label = "Switch project", fn = M.switch_project },
    { key = "a", label = "Adjust start", fn = function() M.adjust_start() end },
    { key = "s", label = "Weekly summary", fn = M.weekly_summary },
    { key = "f", label = "Show flex", fn = M.show_flex },
    { key = "h", label = "Public holidays", fn = M.show_red_days },
    { key = "e", label = "Export CSV", fn = M.export_csv },
    { key = "p", label = "Switch profile", fn = M.switch_profile_select },
    { key = "P", label = "Edit project", fn = M.edit_project },
    { key = "d", label = "Open diary", fn = M.open_diary },
    { key = "E", label = "Edit raw log", fn = M.edit_log },
    { key = "B", label = "Git backup", fn = M.git_backup },
  }

  local items = {}
  local map = {}
  for _, a in ipairs(actions) do
    local text = a.key .. " - " .. a.label
    table.insert(items, text)
    map[text] = a.fn
  end

  vim.ui.select(items, { prompt = "Timeclock menu (" .. M.current_profile .. ")" }, function(choice)
    if choice and map[choice] then
      map[choice]()
    end
  end)
end

function M.setup()
  ensure_profile_files()

  local cmds = {
    TimeclockMenu = M.menu,
    TimeclockIn = M.clock_in,
    TimeclockOut = M.clock_out,
    TimeclockBreak = M.take_break,
    TimeclockResume = M.resume,
    TimeclockSwitch = M.switch_project,
    TimeclockFlex = M.show_flex,
    TimeclockSummary = M.weekly_summary,
    TimeclockProfile = M.switch_profile_select,
  }

  for name, cb in pairs(cmds) do
    pcall(api.nvim_del_user_command, name)
    api.nvim_create_user_command(name, cb, {})
  end
end

return M
