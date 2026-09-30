--[[
  conference_cdr.lua — FreeSWITCH-native conference CDR generator.

  Runs as a mod_lua startup script (see lua.conf.xml). It consumes the
  CUSTOM `conference::maintenance` events that mod_conference emits for every
  member join/leave and every conference create/destroy, and writes CDR rows to
  /cdr-logs/conf_cdr.csv via the SHARED logger (ims_base/conf_cdr_logger.sh),
  so the schema, newest-on-top prepend, and 7-day retention are identical to
  the previous P-CSCF-sourced CDR.

  WHY FreeSWITCH-sourced: the conference bridge lives on the NIB that hosts the
  room, and EVERY participant — dialled locally or relayed in from another NIB —
  is a member of THIS bridge. So this one consumer produces a COMPLETE CDR for
  all UEs on the hosting NIB, which the per-P-CSCF split-ledger could not do
  (each P-CSCF only saw its own NIB's legs). Because a single EventConsumer
  processes events serially, there is also no write race (unlike the parallel
  per-BYE exec's of the old path), so no lock contention.

  Rooms are the conference numbers 1NNR (see freeswitch/default.xml
  `optimus_conferences_1xxx`, which runs `conference <1NNR>@<profile>`, so the
  Conference-Name is exactly the room number). Only those are logged.

  Row semantics (matches conf_cdr_logger.sh positional args):
    LEG  : one per member leg (join -> leave). Participants = that member,
           TotalParticipantCount = 1, Duration = that leg's join->leave.
    CONF : one per room. Participants = ';'-joined distinct non-host callers,
           TotalParticipantCount = peak concurrent members,
           Duration = first-join -> destroy.
    All rows of a room are written together on conference-destroy, so the file
    shows the CONF row followed by its LEG rows in join order (first joiner
    first).
    (There is no ConfScope column: since the CDR lives on the bridge's own
    host NIB, every row would be LOCAL, and per-participant origin-NIB cannot
    be determined reliably here - so the redundant column was dropped.)
]]--

-- Normalized copy of the shared logger made by freeswitch_init.sh; run through
-- bash so a missing exec bit on the host file cannot break CDR writes.
local LOGGER = "/bin/bash /usr/local/freeswitch/scripts/conf_cdr_logger.sh"
local ROOM_PATTERN = "^1%d%d%d$"          -- conference rooms are 1NNR

-- name -> { host, start, active, peak, parts={}, video=bool, members={mid->{cid,join}} }
local confs = {}

local function log(level, msg)
  freeswitch.consoleLog(level, "[conf_cdr] " .. msg .. "\n")
end

-- Single-quote a value for safe shell interpolation.
local function q(s)
  s = tostring(s == nil and "" or s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function write_row(rec, host, parts, count, media, start_epoch, dur,
                         bridge, reason)
  local cmd = table.concat({
    LOGGER, q(rec), q(host), q(parts), q(count), q(media),
    q(start_epoch), q(dur), q(bridge), q(reason),
  }, " ")
  -- Lua 5.2 returns true/nil, 5.1 returns the exit status
  local ok, how, code = os.execute(cmd)
  if ok ~= true and ok ~= 0 then
    log("err", string.format("CDR write failed (%s %s): %s",
          tostring(how), tostring(code or ok), cmd))
  end
end

-- Media classification: a negotiated video codec on the member leg means a
-- video conference. We check the event headers first (names vary across
-- FreeSWITCH versions) and then, authoritatively, query the member channel for
-- a negotiated video codec via the API - which does not depend on guessing
-- header names.
local function _truthy(v)
  return v and v ~= "" and v ~= "false" and v ~= "_undef_" and v ~= "0"
end

local function leg_is_video(e)
  -- 1) Direct event headers (best-effort; present on some FS builds).
  for _, h in ipairs({
    "Channel-Video-Read-Codec-Name", "Channel-Video-Write-Codec-Name",
    "variable_video_read_codec", "variable_rtp_use_video",
    "variable_video_possible",
  }) do
    if _truthy(e:getHeader(h)) then return true end
  end
  -- 2) Authoritative: ask the channel for its negotiated video codec.
  local uuid = e:getHeader("Caller-Unique-ID") or e:getHeader("Unique-ID")
  if uuid and uuid ~= "" then
    local api = freeswitch.API()
    for _, var in ipairs({"video_read_codec", "video_write_codec", "rtp_use_video"}) do
      if _truthy(api:execute("uuid_getvar", uuid .. " " .. var)) then
        return true
      end
    end
  end
  return false
end

local function media_of(c)
  if c.video then return "video" else return "audio" end
end

-- Record a finished LEG; rows are written together at conference-destroy.
local function add_leg(c, cid, join, now)
  table.insert(c.legs, { cid = cid, join = join, dur = now - join })
end

-- Write one conference's rows as a block. conf_cdr_logger.sh prepends, so the
-- LEGs go out latest joiner first and the CONF row last: the file then reads
-- CONF on top followed by its LEGs in join order, first joiner first (longer
-- leg first on ties).
local function flush_conf(c, now)
  table.sort(c.legs, function(a, b)
    if a.join ~= b.join then return a.join > b.join end
    return a.dur < b.dur
  end)
  for _, l in ipairs(c.legs) do
    write_row("LEG", c.host, l.cid, 1, media_of(c), l.join, l.dur,
              c.name, "NORMAL")
  end
  write_row("CONF", c.host, table.concat(c.parts, ";"), c.peak, media_of(c),
            c.start, now - c.start, c.name, "CONF_ENDED")
end

local con = freeswitch.EventConsumer("CUSTOM", "conference::maintenance")
log("info", "started; logging conference rooms matching " .. ROOM_PATTERN
             .. " via " .. LOGGER)

while true do
  local e = con:pop(1)                     -- block up to 1s for the next event
  if e then
    local action = e:getHeader("Action")
    local name = e:getHeader("Conference-Name")
    if action and name and name:match(ROOM_PATTERN) then
      local mid = e:getHeader("Member-ID")
      local cid = e:getHeader("Caller-Caller-ID-Number")
                  or e:getHeader("Caller-ANI") or "unknown"
      local now = os.time()

      if action == "add-member" then
        local c = confs[name]
        if not c then
          c = { name = name, host = cid, start = now, active = 0, peak = 0,
                parts = {}, seen = {}, video = false, members = {}, legs = {} }
          confs[name] = c
        end
        if leg_is_video(e) then c.video = true end
        if mid and c.members[mid] then
          -- Repeated add-member for a member already in the room: don't count
          -- it again or reset its join time.
          log("info", string.format("add room=%s cid=%s mid=%s already a member, ignored",
                name, cid, tostring(mid)))
        else
          c.active = c.active + 1
          if c.active > c.peak then c.peak = c.active end
          -- Participants lists each caller once, even if they rejoin.
          if cid ~= c.host and not c.seen[cid] then
            c.seen[cid] = true
            table.insert(c.parts, cid)
          end
          if mid then c.members[mid] = { cid = cid, join = now } end
          log("info", string.format("add room=%s cid=%s mid=%s active=%d peak=%d",
                name, cid, tostring(mid), c.active, c.peak))
        end

      elseif action == "del-member" then
        local c = confs[name]
        if c then
          local m = mid and c.members[mid] or nil
          local join = m and m.join or c.start
          add_leg(c, cid, join, now)
          if mid then c.members[mid] = nil end
          c.active = c.active - 1
          if c.active < 0 then c.active = 0 end
          log("info", string.format("del room=%s cid=%s dur=%ds active=%d",
                name, cid, now - join, c.active))
        end

      elseif action == "conference-destroy" then
        local c = confs[name]
        if c then
          -- Defensive: close legs for any members that never got an
          -- explicit del-member (whole-conference teardown).
          for _, m in pairs(c.members) do
            add_leg(c, m.cid, m.join, now)
          end
          flush_conf(c, now)
          log("info", string.format("destroy room=%s host=%s peak=%d dur=%ds",
                name, c.host, c.peak, now - c.start))
          confs[name] = nil
        end
      end
    end
  end
end
