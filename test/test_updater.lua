-- test_updater.lua
-- Tests for the pure helper functions exported from assistant_updater.lua:
--   isVersionNewer, is_excluded, join
--
-- The destructive otaUpgrade function itself is not tested headlessly.
local helper = require("test.test_helper")
local assert = helper.assert
local updater = require("assistant_updater")

local function test(name, fn)
    return { name = name, fn = fn }
end

local tests = {

    -- =========================================================================
    -- isVersionNewer
    -- =========================================================================

    test("isVersionNewer: nil/empty returns false", function()
        assert.isFalse(updater.isVersionNewer(nil, "1.0"))
        assert.isFalse(updater.isVersionNewer("1.0", nil))
        assert.isFalse(updater.isVersionNewer(nil, nil))
    end),

    test("isVersionNewer: major version comparison", function()
        assert.isTrue(updater.isVersionNewer("2.0", "1.0"))
        assert.isFalse(updater.isVersionNewer("1.0", "2.0"))
        assert.isFalse(updater.isVersionNewer("1.0", "1.0"))
    end),

    test("isVersionNewer: minor version comparison", function()
        assert.isTrue(updater.isVersionNewer("1.2", "1.1"))
        assert.isFalse(updater.isVersionNewer("1.1", "1.2"))
    end),

    test("isVersionNewer: patch version comparison", function()
        assert.isTrue(updater.isVersionNewer("1.0.2", "1.0.1"))
        assert.isFalse(updater.isVersionNewer("1.0.1", "1.0.2"))
    end),

    test("isVersionNewer: unequal length versions", function()
        assert.isTrue(updater.isVersionNewer("2", "1.9.9"))
        assert.isFalse(updater.isVersionNewer("1.9", "2.0"))
        assert.isTrue(updater.isVersionNewer("1.9.1", "1.9"))
    end),

    test("isVersionNewer: release vs pre-release", function()
        assert.isTrue(updater.isVersionNewer("1.0.0", "1.0.0-rc.1"))
        assert.isFalse(updater.isVersionNewer("1.0.0-rc.1", "1.0.0"))
    end),

    test("isVersionNewer: pre-release comparison (numeric)", function()
        assert.isTrue(updater.isVersionNewer("1.0.0-rc.2", "1.0.0-rc.1"))
        assert.isFalse(updater.isVersionNewer("1.0.0-rc.1", "1.0.0-rc.2"))
    end),

    test("isVersionNewer: pre-release comparison (numeric vs non-numeric)", function()
        -- Numeric identifiers have lower precedence than non-numeric (SemVer spec)
        assert.isFalse(updater.isVersionNewer("1.0.0-1", "1.0.0-alpha"))
        assert.isTrue(updater.isVersionNewer("1.0.0-alpha", "1.0.0-1"))
    end),

    test("isVersionNewer: pre-release with different lengths", function()
        assert.isTrue(updater.isVersionNewer("1.0.0-alpha.1", "1.0.0-alpha"))
        assert.isFalse(updater.isVersionNewer("1.0.0-alpha", "1.0.0-alpha.1"))
    end),

    test("isVersionNewer: equal versions return false", function()
        assert.isFalse(updater.isVersionNewer("1.2.3", "1.2.3"))
        assert.isFalse(updater.isVersionNewer("1.0.0-rc.1", "1.0.0-rc.1"))
    end),

    test("isSameVersion: treats equivalent versions as equal", function()
        assert.isTrue(updater.isSameVersion("1.20", "1.20.0"))
        assert.isTrue(updater.isSameVersion("v1.20", "1.20.0"))
        assert.isFalse(updater.isSameVersion("1.21", "1.20"))
    end),

    test("isVersionNewer: handles 'v' prefix", function()
        -- isVersionNewer doesn't strip 'v' prefix, so "v2.0" is treated as non-numeric
        -- but main version parse uses %d+, so it correctly extracts 2 and 0
        assert.isTrue(updater.isVersionNewer("v2.0", "v1.0"))
        assert.isFalse(updater.isVersionNewer("v1.0", "v2.0"))
    end),

    -- =========================================================================
    -- is_excluded
    -- =========================================================================

    test("is_excluded: dotfiles excluded", function()
        assert.isTrue(updater.is_excluded(".gitignore"))
        assert.isTrue(updater.is_excluded(".hidden"))
        assert.isTrue(updater.is_excluded(".github/workflows/release.yml"))
        -- purely dot prefixes via path:find("/%.")
        assert.isTrue(updater.is_excluded("assistant.koplugin/.hidden"))
    end),

    test("is_excluded: markdown files excluded", function()
        assert.isTrue(updater.is_excluded("README.md"))
        assert.isTrue(updater.is_excluded("docs/guide.md"))
        assert.isTrue(updater.is_excluded("AGENTS.md"))
    end),

    test("is_excluded: l10n non-po files excluded", function()
        assert.isTrue(updater.is_excluded("l10n/Makefile"))
        assert.isTrue(updater.is_excluded("l10n/translate.py"))
        assert.isTrue(updater.is_excluded("l10n/template.pot"))
        assert.isFalse(updater.is_excluded("l10n/fr/assistant.koplugin.po"))
    end),

    test("is_excluded: test directory excluded", function()
        assert.isTrue(updater.is_excluded("test/run.sh"))
        assert.isTrue(updater.is_excluded("test/test_helper.lua"))
        assert.isTrue(updater.is_excluded("assistant.koplugin/test/run.sh"))
    end),

    test("is_excluded: normal source files NOT excluded", function()
        assert.isFalse(updater.is_excluded("main.lua"))
        assert.isFalse(updater.is_excluded("assistant_utils.lua"))
        assert.isFalse(updater.is_excluded("api_handlers/openai.lua"))
        assert.isFalse(updater.is_excluded("lib/libhoedown.so.3"))
    end),

    test("is_excluded: configuration.lua NOT excluded", function()
        assert.isFalse(updater.is_excluded("configuration.lua"))
    end),

    -- =========================================================================
    -- join
    -- =========================================================================

    test("join: single path returns as-is", function()
        assert.equal(updater.join("/foo"), "/foo")
    end),

    test("join: two paths", function()
        local result = updater.join("/foo", "bar")
        assert.isTrue(result:find("bar") ~= nil)
        assert.isTrue(result:find("foo") ~= nil)
    end),

    test("join: empty call returns empty string", function()
        assert.equal(updater.join(), "")
    end),

    test("join: nil first arg returns empty string", function()
        assert.equal(updater.join(nil), "")
    end),

    -- =========================================================================
    -- OTA URL helpers
    -- =========================================================================

    test("buildUpdateCheckUrl: uses configured API base and repo", function()
        local result = updater.buildUpdateCheckUrl({
            github_api_base = "https://api.github.example",
            repo = "owner/repo",
        })
        assert.equal(result, "https://api.github.example/repos/owner/repo/releases/latest")
    end),

    test("buildReleaseAssetUrl: formats tag into asset pattern", function()
        local result = updater.buildReleaseAssetUrl({
            github_base = "https://github.com",
            repo = "zivshek/assistant.koplugin",
            release_asset_pattern = "assistant.koplugin-%s.zip",
        }, "v1.15")
        assert.equal(result, "https://github.com/zivshek/assistant.koplugin/releases/download/v1.15/assistant.koplugin-v1.15.zip")
    end),

    test("buildSourceArchiveUrl: builds branch archive URL", function()
        local result = updater.buildSourceArchiveUrl({
            github_base = "https://github.com",
            repo = "zivshek/assistant.koplugin",
        }, "main")
        assert.equal(result, "https://github.com/zivshek/assistant.koplugin/archive/refs/heads/main.zip")
    end),

    test("buildSourceArchiveUrl: builds tag archive URL", function()
        local result = updater.buildSourceArchiveUrl({
            github_base = "https://github.com",
            repo = "zivshek/assistant.koplugin",
        }, "v1.15")
        assert.equal(result, "https://github.com/zivshek/assistant.koplugin/archive/refs/tags/v1.15.zip")
    end),

    test("versionFromRef: extracts version only from release tags", function()
        assert.equal(updater.versionFromRef("v1.20"), "1.20")
        assert.equal(updater.versionFromRef("v1.20-beta.1"), "1.20-beta.1")
        assert.equal(updater.versionFromRef("v1.20+build.5"), "1.20+build.5")
        assert.equal(updater.versionFromRef("main"), nil)
        assert.equal(updater.versionFromRef("1.20"), nil)
    end),
}

return helper.runTests("assistant_updater.lua", tests)
