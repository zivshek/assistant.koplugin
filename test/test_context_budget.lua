local helper = require("test.test_helper")
local assert = helper.assert
local ASUtils = helper.ASUtils

local tests = {
    {
        name = "getContextCharLimit returns configured positive value",
        fn = function()
            local config = { features = { ask_context_char_limit = 1234 } }
            assert.equal(ASUtils.getContextCharLimit(config, "ask_context_char_limit", 99), 1234)
        end,
    },
    {
        name = "getContextCharLimit falls back for missing or invalid values",
        fn = function()
            local config = { features = { ask_context_char_limit = -1 } }
            assert.equal(ASUtils.getContextCharLimit(config, "missing_limit", 99), 99)
            assert.equal(ASUtils.getContextCharLimit(config, "ask_context_char_limit", 99), 99)
        end,
    },
    {
        name = "truncateForPrompt keeps short text unchanged",
        fn = function()
            assert.equal(ASUtils.truncateForPrompt("short text", 100, "tail"), "short text")
        end,
    },
    {
        name = "truncateForPrompt keeps tail by default",
        fn = function()
            local text = string.rep("a", 100) .. "THE_END"
            local result = ASUtils.truncateForPrompt(text, 60, "tail")
            assert.isTrue(#result <= 60, "truncated result should fit the character budget")
            assert.matches(result, "THE_END$")
            assert.matches(result, "omitted for token budget")
        end,
    },
    {
        name = "omitLargeContextBlocks removes book and notebook payloads",
        fn = function()
            local content = table.concat({
                "before",
                "[BOOK TEXT BEGIN]very large book text[BOOK TEXT END]",
                "middle",
                "[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT BEGIN]large notes[BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT END]",
                "after",
            }, "\n")
            local result = ASUtils.omitLargeContextBlocks(content)
            assert.notMatches(result, "very large book text")
            assert.notMatches(result, "large notes")
            assert.matches(result, "BOOK TEXT OMITTED")
            assert.matches(result, "BOOK HIGHLIGHTS, NOTES AND NOTEBOOK CONTENT OMITTED")
        end,
    },
}

return helper.runTests("context_budget", tests)
