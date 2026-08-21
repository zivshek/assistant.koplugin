local TrapWidget  = require("ui/widget/trapwidget")
local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local Font = require("ui/font")
local logger = require("logger")
local _ = require("assistant_gettext")
local FFIUtil = require("ffi/util")
local T = FFIUtil.template
local koutil = require("util")
local ASUtils = require("assistant_utils")

-- Variadic path join. Uses FFIUtil.joinPath so we don't sprinkle "/" literals
-- and get the right separator handling for free.
local function join(...)
    local args = { ... }
    local result = args[1]
    if not result then return "" end
    for i = 2, #args do
        result = FFIUtil.joinPath(result, args[i])
    end
    return result
end

local CONFIGURATION = nil
local meta = nil

local DEFAULT_GITHUB_BASE = "https://github.com"
local DEFAULT_GITHUB_API_BASE = "https://api.github.com"
local DEFAULT_GITHUB_REPO = "zivshek/assistant.koplugin"
local DEFAULT_RELEASE_ASSET_PATTERN = "assistant.koplugin-%s.zip"

-- Returns true if the path should be excluded from OTA extraction.
-- Exposed at module level for testing; also used inside otaUpgrade.
function is_excluded(path)
    if path:find("/%.") or path:sub(1,1) == "." then
        return true
    end
    if path:find(".+%.md$") then
        return true
    end
    -- l10n: only keep .po files (exclude .py, .sh, Makefile, .pot, etc.)
    if path:find("l10n/.+") and not path:find("%.po$") then
        return true
    end
    -- test/ is source-only, not shipped to end users
    if path:find("^test/") or path:find("/test/") then
        return true
    end
    return false
end

-- A more robust version comparison function compliant with Semantic Versioning.
-- Returns true if v1_str is newer than v2_str, false otherwise.
-- Handles versions like "1.8", "1.8.0-rc.1", "1.8.0-rc.11", "1.8.0".
local function isVersionNewer(v1_str, v2_str)
    if not v1_str or not v2_str then return false end

    -- Helper to parse a version string into its main and pre-release parts
    -- according to SemVer rules.
    local function parseVersion(v_str)
        local parts = {}
        local pre_release_parts = {}
        local main_part = v_str

        -- Separate pre-release tag (e.g., -alpha.1)
        local pre_release_start = v_str:find("-")
        if pre_release_start then
            main_part = v_str:sub(1, pre_release_start - 1)
            local pre_release_str = v_str:sub(pre_release_start + 1)
            -- Split pre-release by '.' and convert numeric parts to numbers
            for part in pre_release_str:gmatch("([^.]+)") do
                local num = tonumber(part)
                -- A valid numeric identifier in SemVer is just digits.
                if num and part:match("^[0-9]+$") then
                    table.insert(pre_release_parts, num)
                else
                    table.insert(pre_release_parts, part)
                end
            end
        end

        -- Split main part (e.g., 1.8.0) into numbers
        for part in main_part:gmatch("%d+") do
            table.insert(parts, tonumber(part))
        end

        return parts, pre_release_parts
    end

    local parts1, pre1_parts = parseVersion(tostring(v1_str))
    local parts2, pre2_parts = parseVersion(tostring(v2_str))

    -- 1. Compare main version parts (MAJOR.MINOR.PATCH)
    local max_len = math.max(#parts1, #parts2)
    for i = 1, max_len do
        local p1 = parts1[i] or 0
        local p2 = parts2[i] or 0
        if p1 > p2 then return true end
        if p1 < p2 then return false end
    end

    -- Main versions are equal, so we proceed to pre-release comparison.
    local has_pre1 = #pre1_parts > 0
    local has_pre2 = #pre2_parts > 0

    -- 2. A version with a pre-release has lower precedence than a normal version.
    if has_pre1 and not has_pre2 then return false end -- e.g., 1.0.0-rc < 1.0.0
    if not has_pre1 and has_pre2 then return true end  -- e.g., 1.0.0 > 1.0.0-rc
    if not has_pre1 and not has_pre2 then return false end -- e.g., 1.0.0 == 1.0.0

    -- 3. Both have pre-release tags, compare them identifier by identifier.
    local pre_max_len = math.max(#pre1_parts, #pre2_parts)
    for i = 1, pre_max_len do
        local p1 = pre1_parts[i]
        local p2 = pre2_parts[i]

        if p1 == nil then return false end -- v1 is shorter, so older (e.g., 1.0-alpha < 1.0-alpha.1)
        if p2 == nil then return true end  -- v2 is shorter, so older

        local p1_is_num, p2_is_num = type(p1) == "number", type(p2) == "number"

        if p1_is_num and p2_is_num then
            if p1 > p2 then return true elseif p1 < p2 then return false end
        elseif p1_is_num then return false -- Numeric identifiers have lower precedence
        elseif p2_is_num then return true  -- Non-numeric has higher precedence
        else -- Both are strings
            if p1 > p2 then return true elseif p1 < p2 then return false end
        end
    end

    return false -- Versions are identical
end

local function getFeature(key, default)
  local value = koutil.tableGetValue(CONFIGURATION, "features", key)
  if value == nil then
    return default
  end
  return value
end

local function getGithubSettings()
  return {
    github_base = getFeature("ota_github_base", DEFAULT_GITHUB_BASE),
    github_api_base = getFeature("ota_github_api_base", DEFAULT_GITHUB_API_BASE),
    repo = getFeature("ota_github_repo", DEFAULT_GITHUB_REPO),
    release_asset_pattern = getFeature("ota_release_asset_pattern", DEFAULT_RELEASE_ASSET_PATTERN),
  }
end

local function buildUpdateCheckUrl(settings)
  return string.format("%s/repos/%s/releases/latest", settings.github_api_base, settings.repo)
end

local function buildReleaseAssetUrl(settings, tag)
  local pattern = settings.release_asset_pattern or DEFAULT_RELEASE_ASSET_PATTERN
  local asset_name
  if pattern:find("%%s", 1, true) then
    asset_name = string.format(pattern, tag)
  else
    asset_name = pattern
  end
  return string.format("%s/%s/releases/download/%s/%s", settings.github_base, settings.repo, tag, asset_name)
end

local function buildSourceArchiveUrl(settings, version)
  local repo_ref = version:sub(1, 1) == "v" and "tags" or "heads"
  return string.format("%s/%s/archive/refs/%s/%s.zip", settings.github_base, settings.repo, repo_ref, version)
end

local function versionFromRef(version)
  if type(version) ~= "string" then return nil end
  return version:match("^v([%w%.%-%+]+)$")
end

local function rewriteMetaVersion(plugin_dir, version)
  local normalized_version = versionFromRef(version)
  if not normalized_version then return true end

  local meta_path = join(plugin_dir, "_meta.lua")
  local file = io.open(meta_path, "rb")
  if not file then return false, "Could not open _meta.lua" end
  local content = file:read("*a")
  file:close()

  local updated, count = content:gsub('(version%s*=%s*)["\'][^"\']+["\']', '%1"' .. normalized_version .. '"', 1)
  if count ~= 1 then
    return false, "Could not update version in _meta.lua"
  end

  file = io.open(meta_path, "wb")
  if not file then return false, "Could not write _meta.lua" end
  file:write(updated)
  file:close()
  return true
end

local function findReleaseAssetUrl(release_data, settings, tag)
  if release_data and release_data.assets then
    local expected_url = buildReleaseAssetUrl(settings, tag)
    local expected_name = expected_url:match("/([^/]+)$")
    for _, asset in ipairs(release_data.assets) do
      if asset.name == expected_name and asset.browser_download_url then
        return asset.browser_download_url
      end
    end
  end
  return buildReleaseAssetUrl(settings, tag)
end

local function fetchReleaseByTag(settings, tag)
  local release_url = string.format("%s/repos/%s/releases/tags/%s", settings.github_api_base, settings.repo, tag)
  return ASUtils.fetchJSON(
    release_url,
    { ["Accept"] = "application/vnd.github.v3+json" },
    _("Checking release asset...")
  )
end

local function resolveOtaDownload(version)
  local settings = getGithubSettings()
  local requested_version = version or "latest"
  if requested_version == "" then requested_version = "latest" end

  if requested_version == "latest" then
    local release_data, err = ASUtils.fetchJSON(
      buildUpdateCheckUrl(settings),
      { ["Accept"] = "application/vnd.github.v3+json" },
      _("Checking latest release...")
    )
    if not release_data or not release_data.tag_name then
      return nil, T(_("Could not resolve latest release: %1"), tostring(err or _("missing tag_name")))
    end
    local tag = release_data.tag_name
    return {
      version = tag,
      repo = settings.repo,
      github_base = settings.github_base,
      urls = {
        findReleaseAssetUrl(release_data, settings, tag),
        buildSourceArchiveUrl(settings, tag),
      },
    }
  end

  if requested_version:sub(1, 1) == "v" then
    local release_data = fetchReleaseByTag(settings, requested_version)
    return {
      version = requested_version,
      repo = settings.repo,
      github_base = settings.github_base,
      urls = {
        findReleaseAssetUrl(release_data, settings, requested_version),
        buildSourceArchiveUrl(settings, requested_version),
      },
    }
  end

  return {
    version = requested_version,
    repo = settings.repo,
    github_base = settings.github_base,
    urls = {
      buildSourceArchiveUrl(settings, requested_version),
    },
  }
end

local function checkForUpdates()
  if koutil.tableGetValue(CONFIGURATION, "features", "updater_disabled") then
    return
  end

  local update_url = koutil.tableGetValue(CONFIGURATION, "features", "update_check_url")
    or buildUpdateCheckUrl(getGithubSettings())

  local parsed_data, err = ASUtils.fetchJSON(update_url,
      { ["Accept"] = "application/vnd.github.v3+json" },
      _("Checking for updates..."))

  if not parsed_data then
    Notification:notify(T(_("AI Assistant: Failed to check updates: %2"), err or _("Empty Error")), Notification.SOURCE_ALWAYS_SHOW)
    return
  end

  local latest_version_tag = parsed_data.tag_name
  if latest_version_tag and meta and meta.version then
    local latest_version_str = latest_version_tag:match("^v?(.*)$")
    local current_version_str = tostring(meta.version)

    if isVersionNewer(latest_version_str, current_version_str) then
      local message = T(_("A new version of the %1 plugin (%2) is available. Please update!"),
        meta.fullname, latest_version_tag)
      Notification:notify(message, Notification.SOURCE_ALWAYS_SHOW)
    end
  end
end

local function otaUpgrade(version)
  local PLUGIN_NAME = "assistant.koplugin"

  local download_info, resolve_err = resolveOtaDownload(version)
  if not download_info then
    Notification:notify(T(_("OTA update failed: %1"), tostring(resolve_err)), Notification.SOURCE_ALWAYS_SHOW)
    return
  end
  version = download_info.version

  local DataStorage = require("datastorage")
  local lfs = require("libs/libkoreader-lfs")
  local Archiver = require("ffi/archiver")
  local util = require("util")

  local KOREADER_DIR = DataStorage:getFullDataDir()
  local PLUGIN_DIR = join(KOREADER_DIR, "plugins")
  local ASSISTANT_DIR = join(PLUGIN_DIR, PLUGIN_NAME)
  local UPDATE_TMPDIR = join(KOREADER_DIR, "ota", PLUGIN_NAME .. ".update")
  local UPDATE_BAKDIR = join(UPDATE_TMPDIR, "backup")
  local TARGET_PLUGIN_PATH = ASSISTANT_DIR
  local BACKUP_PLUGIN_PATH = join(UPDATE_BAKDIR, PLUGIN_NAME)
  local DL_TAR = join(UPDATE_TMPDIR, string.format("SOURCE-%s-%s.zip", PLUGIN_NAME, version))

  util.makePath(UPDATE_BAKDIR)

  -- Phase 1: Download the archive (dismissable by user)
  local download_msg = InfoMessage:new{
    face = Font:getFace("xx_smallinfofont"),
      text = ASUtils.bold_format(
      T(_("<b>Downloading ...</b>\n<b>Github: </b>%1\n<b>Repo: </b>%2\n<b>Branch/Tag: </b>%3"),
        download_info.github_base, download_info.repo, version)
    ),
  }
  UIManager:show(download_msg)

  local completed, dl_result, dl_err = Trapper:dismissableRunInSubprocess(function()
    local http = require("socket.http")
    local https = require("ssl.https")
    local ltn12 = require("ltn12")

    https.cert_verify = false

    local function getHeader(headers, name)
      if not headers then return nil end
      name = name:lower()
      for key, value in pairs(headers) do
        if tostring(key):lower() == name then
          return value
        end
      end
      return nil
    end

    local function resolveRedirectUrl(current_url, location)
      if not location or location == "" then return nil end
      if location:match("^https?://") then
        return location
      end
      local scheme, host = current_url:match("^(https?://)([^/]+)")
      if not scheme or not host then
        return location
      end
      if location:sub(1, 1) == "/" then
        return scheme .. host .. location
      end
      return current_url:gsub("[^/]*$", "") .. location
    end

    local function downloadUrl(initial_url)
      local url = initial_url
      for redirect_count = 0, 5 do
        local file_handle = io.open(DL_TAR, "wb")
        if not file_handle then
          return false, "Could not create temp file"
        end

        local requester = url:sub(1, 8) == "https://" and https or http
        local body_sink = ltn12.sink.file(file_handle)
        local ok, status_code, headers, status = requester.request{
          url = url,
          method = "GET",
          sink = body_sink,
          headers = {
            ["User-Agent"] = "KOReader assistant.koplugin OTA",
          },
        }

        status_code = tonumber(status_code) or status_code
        if status_code == 200 then
          return true, nil
        end

        os.remove(DL_TAR)

        if status_code == 301 or status_code == 302 or status_code == 303
            or status_code == 307 or status_code == 308 then
          local redirected_url = resolveRedirectUrl(url, getHeader(headers, "location"))
          if redirected_url then
            url = redirected_url
          else
            return false, T(_("Download redirected without a Location header: %1"), initial_url)
          end
        else
          local reason = status or tostring(status_code or ok or _("unknown"))
          return false, T(_("Download failed: %1\nURL: %2"), reason, url)
        end
      end

      return false, T(_("Too many redirects while downloading:\n%1"), initial_url)
    end

    local last_err = nil
    for _, url in ipairs(download_info.urls) do
      local ok, err = downloadUrl(url)
      if ok then
        return { ok = true }
      end
      last_err = err
    end

    return {
      ok = false,
      err = last_err or _("Download failed before any URL was attempted"),
    }
  end, download_msg)

  UIManager:close(download_msg)

  if not completed then
    FFIUtil.purgeDir(UPDATE_TMPDIR)
    Notification:notify(_("OTA update canceled."), Notification.SOURCE_ALWAYS_SHOW)
    return
  end

  if type(dl_result) ~= "table" or not dl_result.ok then
    FFIUtil.purgeDir(UPDATE_TMPDIR)
    local err_msg = type(dl_result) == "table" and dl_result.err or dl_err
    Notification:notify(T(_("OTA update failed: %1"), tostring(err_msg or _("Unknown download error"))), Notification.SOURCE_ALWAYS_SHOW)
    return
  end

  -- Phase 2: Extract and install (NOT dismissable)
  local extract_msg = InfoMessage:new{
    text = ASUtils.bold_format(
          T(_("<b>Installing %1...</b>"), version)
      ),
  }
  UIManager:show(extract_msg)
  UIManager:forceRePaint()

  local function do_install()
    -- Open the downloaded archive for reading
    local arc = Archiver.Reader:new()
    if not arc:open(DL_TAR) then
      FFIUtil.purgeDir(UPDATE_TMPDIR)
      return false, "Failed to open archive"
    end

    -- Extract entries from the archive into UPDATE_TMPDIR, skipping excluded paths
    for entry in arc:iterate() do
      if not is_excluded(entry.path) then
        local dest_path = join(UPDATE_TMPDIR, entry.path)
        local parent_dir = dest_path:match("(.*)" .. package.config:sub(1,1))
        if parent_dir and not util.pathExists(parent_dir) then
          util.makePath(parent_dir)
        end
        if not arc:extractToPath(entry.path, dest_path) then
          arc:close()
          FFIUtil.purgeDir(UPDATE_TMPDIR)
          return false, "Failed to extract: " .. entry.path
        end
      end
    end
    arc:close()

    -- Locate the extracted top-level plugin directory (e.g. assistant.koplugin-<ver>)
    -- Fail early before touching the existing installation so we don't have to roll back.
    local found_extracted_dir = nil
    for file in lfs.dir(UPDATE_TMPDIR) do
      if file:sub(1, #PLUGIN_NAME) == PLUGIN_NAME then
        local candidate = join(UPDATE_TMPDIR, file)
        if util.directoryExists(candidate) then
          found_extracted_dir = candidate
          break
        end
      end
    end
    if not found_extracted_dir then
      FFIUtil.purgeDir(UPDATE_TMPDIR)
      return false, "Could not find extracted plugin directory"
    end

    -- Move the currently installed plugin aside as a backup
    if util.pathExists(TARGET_PLUGIN_PATH) then
      if util.pathExists(BACKUP_PLUGIN_PATH) then
        FFIUtil.purgeDir(BACKUP_PLUGIN_PATH)
      end
      os.rename(TARGET_PLUGIN_PATH, BACKUP_PLUGIN_PATH)
    end

    -- Install the freshly extracted plugin into its target location
    os.rename(found_extracted_dir, TARGET_PLUGIN_PATH)

    local meta_ok, meta_err = rewriteMetaVersion(TARGET_PLUGIN_PATH, version)
    if not meta_ok then
      if util.pathExists(BACKUP_PLUGIN_PATH) then
        FFIUtil.purgeDir(TARGET_PLUGIN_PATH)
        os.rename(BACKUP_PLUGIN_PATH, TARGET_PLUGIN_PATH)
      end
      FFIUtil.purgeDir(UPDATE_TMPDIR)
      return false, meta_err
    end

    -- Restore user-owned files from the backup
    if util.pathExists(BACKUP_PLUGIN_PATH) then
      local restore_targets = {"configuration.lua"}
      for _, filename in ipairs(restore_targets) do
        local old_file = join(BACKUP_PLUGIN_PATH, filename)
        local new_file = join(TARGET_PLUGIN_PATH, filename)
        if util.pathExists(old_file) then
          if util.pathExists(new_file) then FFIUtil.purgeDir(new_file) end
          os.rename(old_file, new_file)
        end
      end
    end

    -- Clean up temp/backup directory
    FFIUtil.purgeDir(UPDATE_TMPDIR)
    return true, nil
  end

  local ok, err_msg = do_install()
  UIManager:close(extract_msg)

  if not ok then
    Notification:notify(T(_("OTA update failed: %1"), tostring(err_msg)), Notification.SOURCE_ALWAYS_SHOW)
    return
  end

  Notification:notify(T(_("OTA UPDATE OK.\n Restart is required.")), Notification.SOURCE_ALWAYS_SHOW)
  UIManager:askForRestart()
end

return {
  isVersionNewer = isVersionNewer,
  is_excluded = is_excluded,
  join = join,
  buildUpdateCheckUrl = buildUpdateCheckUrl,
  buildReleaseAssetUrl = buildReleaseAssetUrl,
  buildSourceArchiveUrl = buildSourceArchiveUrl,
  versionFromRef = versionFromRef,
  checkForUpdates = function(assistant)
    CONFIGURATION = assistant.CONFIGURATION
    meta = assistant.meta
    return Trapper:wrap(checkForUpdates)
  end,
  otaUpgrade = function(assistant, version)
    CONFIGURATION = assistant.CONFIGURATION
    meta = assistant.meta
    return Trapper:wrap(function() otaUpgrade(version) end)
  end,
}
