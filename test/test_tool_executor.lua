-- test_tool_executor.lua
-- Tests for assistant_tool_executor.lua quota and search execution behavior.
local helper = require("test.test_helper")
local assert = helper.assert
local ToolExecutor = helper.ToolExecutor
local ASUtils = helper.ASUtils
local OpenAIHandler = require("api_handlers.openai")

local function test(name, fn)
    return { name = name, fn = fn }
end

local handler = {
    resetTrapWidget = function()
        return {}
    end,
}

local tests = {
    test("Tavily remote quota allows search when credits remain", function()
        ToolExecutor.SetSearchAPIConfig({
            provider_settings = {
                tavilyapi = { api_key = "tvly-test" },
            },
            features = {
                tavily_search_credit_cost = 1,
                tavily_remote_quota_check = true,
            },
        })
        helper.mockFetchJSON({
            {
                parsed = {
                    key = {
                        usage = 1498,
                        limit = 1500,
                    },
                    account = {
                        current_plan = "Researcher",
                        plan_usage = 1498,
                        plan_limit = 1500,
                    },
                },
            },
            {
                parsed = {
                    answer = "ok",
                    results = {
                        { title = "Result", content = "Content" },
                    },
                },
            },
        })

        local ok, result = ToolExecutor.executeWebSearch("query", "tavilyapi", handler, 1)

        assert.isTrue(ok)
        assert.matches(result, "verified search results")
        assert.equal(helper.fetchJSON_call_index, 2)
    end),

    test("Tavily remote quota cap blocks before search call", function()
        ToolExecutor.SetSearchAPIConfig({
            provider_settings = {
                tavilyapi = { api_key = "tvly-test" },
            },
            features = {
                tavily_search_credit_cost = 1,
                tavily_remote_quota_check = true,
            },
        })
        helper.mockFetchJSON({
            {
                parsed = {
                    key = {
                        usage = 1500,
                        limit = 1500,
                    },
                    account = {
                        current_plan = "Researcher",
                        plan_usage = 1500,
                        plan_limit = 1500,
                    },
                },
            },
        })

        local ok, err = ToolExecutor.executeWebSearch("query", "tavilyapi", handler, 1)

        assert.isFalse(ok)
        assert.matches(err, "remote quota limit")
        assert.equal(helper.fetchJSON_call_index, 1)
    end),

    test("search audit markdown shows tool and query", function()
        local message = {
            role = "assistant",
            content = nil,
        }
        ASUtils.set_attr(message, "search_keywords", "⌗ deepseek web search\n\n")
        ASUtils.set_attr(message, "search_tool_name", "Tavily")

        local audit = ToolExecutor.getSearchAuditMarkdown({ message })

        assert.matches(audit, "Web search used")
        assert.matches(audit, "Tavily")
        assert.matches(audit, "deepseek web search")
    end),

    test("OpenAI-compatible handler forces tool choice only when requested", function()
        local tool_def = { ToolExecutor.buildExternalSearchToolDef("openai") }

        local forced = OpenAIHandler:buildRequestBody({}, {
            use_stream_mode = false,
            force_websearch = true,
        }, tool_def)
        local automatic = OpenAIHandler:buildRequestBody({}, {
            use_stream_mode = false,
            force_websearch = false,
        }, tool_def)

        assert.equal(forced.tool_choice, "required")
        assert.equal(automatic.tool_choice, "auto")
    end),
}

return helper.runTests("assistant_tool_executor.lua", tests)
