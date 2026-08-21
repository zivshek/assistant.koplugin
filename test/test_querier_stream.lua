-- test_querier_stream.lua
-- Regression tests for the streaming UI update logic in assistant_querier.lua
-- (showStreamDialog).
--
-- Background: commit 6f4b134 introduced a regression where the
-- stream_mode_auto_scroll=false branch still called addTextToInput(delta),
-- which inserts at the cursor and forces the view to follow it to the bottom.
-- The fix restores the pre-6f4b134 behavior for that branch: resyncPos() +
-- setText(full_text, true), preserving the current scroll/cursor position.
--
-- The real flush logic is a local closure inside showStreamDialog that needs
-- the full KOReader UI stack, so (per project testing policy) we inline a copy
-- of the pure helper and a driver that mirrors the closure, and test those.
local helper = require("test.test_helper")
local assert = helper.assert
local strbuf = require("string.buffer")

local function test(name, fn)
    return { name = name, fn = fn }
end

-- =========================================================================
-- Inlined copy of assistant_querier.lua's local `updateStreamText` helper.
-- When auto_scroll=false: manually appends delta to the END of charlist,
-- restores the user's saved charpos+top_line_num, then calls initTextBox.
-- scrollViewToCharPos receives the saved values so the view stays put.
-- =========================================================================
local function setStreamPreviewText(streamDialog, text, auto_scroll)
    local widget = streamDialog._input_widget
    widget:setText(text, true)
    if auto_scroll then
        widget.charpos = #widget.charlist + 1
    end
end

local function updateStreamText(streamDialog, delta, auto_scroll, max_display_chars)
    delta = delta or ""
    max_display_chars = tonumber(max_display_chars)
    if max_display_chars and max_display_chars > 0 then
        local tail = (streamDialog._stream_preview_tail or "") .. delta
        local omitted = streamDialog._stream_preview_omitted or 0
        if #tail > max_display_chars then
            local excess = #tail - max_display_chars
            omitted = omitted + excess
            tail = tail:sub(-max_display_chars)
        end
        streamDialog._stream_preview_tail = tail
        streamDialog._stream_preview_omitted = omitted
        if omitted > 0 then
            setStreamPreviewText(streamDialog,
                string.format("[... %d characters hidden while streaming; full response opens when complete ...]\n\n%s",
                    omitted, tail),
                auto_scroll)
            return
        end
    end

    if auto_scroll then
        streamDialog:addTextToInput(delta)
    else
        local widget = streamDialog._input_widget
        widget:resyncPos()
        local saved_top = widget.top_line_num
        local saved_charpos = widget.charpos
        -- Append delta to the end of charlist
        -- (in test we use a simple char-by-char loop instead of koutil.splitToChars)
        for i = 1, #delta do
            table.insert(widget.charlist, delta:sub(i, i))
        end
        widget.charpos = saved_charpos
        widget.top_line_num = saved_top
        widget:initTextBox(nil, true)
    end
end

-- Mock InputDialog that records every UI call made on it.
local function makeMockDialog()
    local calls = { addTextToInput = {}, addChars = {}, setText = {}, resyncPos = 0, initTextBox = {} }
    local inner_widget = { vertical_string_list = { "line" }, lines_per_page = 1, virtual_line_num = 1 }
    local input_widget = {
        charlist = {},
        charpos = 1,
        top_line_num = nil,
        text_widget = { text_widget = inner_widget, updateScrollBar = function() end },
        resyncPos = function(self)
            calls.resyncPos = calls.resyncPos + 1
            self.top_line_num = inner_widget.virtual_line_num
        end,
        addChars = function(_, chars)
            table.insert(calls.addChars, chars)
        end,
        setText = function(_, text, keep_edited_state)
            table.insert(calls.setText, { text = text, keep = keep_edited_state })
        end,
        initTextBox = function(_, text, keep_edited_state)
            table.insert(calls.initTextBox, { text = text, keep = keep_edited_state })
        end,
    }
    local dialog = {
        _input_widget = input_widget,
        addTextToInput = function(_, text)
            table.insert(calls.addTextToInput, text)
        end,
    }
    return dialog, calls
end

-- Driver that mirrors the pending_delta/flush closure and the
-- reasoning->answer transition in assistant_querier.lua showStreamDialog.
local function makeStreamDriver(dialog, auto_scroll, max_display_chars)
    local pending_delta = strbuf.new() -- delta since the last UI flush
    local flush_scheduled = false
    local reasoning_was_ended = false

    local function flush_to_ui()
        flush_scheduled = false
        local delta = pending_delta:get()
        if #delta == 0 then return end
        updateStreamText(dialog, delta, auto_scroll, max_display_chars)
    end

    return {
        -- Mirror of the processStream trunk_callback (coalesced 500ms updates).
        onContent = function(content, reasoning_phase_ended)
            if reasoning_phase_ended and not reasoning_was_ended then
                reasoning_was_ended = true
                if flush_scheduled then
                    flush_scheduled = false
                    flush_to_ui()
                end
                dialog._input_widget.charlist = {}
                dialog._input_widget.charpos = 1
                dialog._input_widget:initTextBox("", true)
                dialog._stream_preview_tail = ""
                dialog._stream_preview_omitted = 0
            end
            pending_delta:put(content or "")
            if not flush_scheduled then
                flush_scheduled = true
            end
        end,
        -- Mirror of the final unschedule+flush in showStreamDialog.
        flush = function()
            if flush_scheduled then
                flush_scheduled = false
                flush_to_ui()
            end
        end,
    }
end

-- Inlined copy of the tool-loop state transition in assistant_querier.lua:
-- explicit forced search and max-search prompts must lead to one final answer
-- request with web_search disabled.
local function applyWebSearchPostToolState(query_option, is_added_maximum_prompt, tool_rounds, max_tool_rounds)
    local function disableWebSearchForFinalAnswer()
        query_option.force_websearch = false
        query_option.use_websearch = "none"
    end

    if query_option.force_websearch then
        disableWebSearchForFinalAnswer()
    end
    if is_added_maximum_prompt or tool_rounds >= max_tool_rounds then
        disableWebSearchForFinalAnswer()
    end
end

-- Inlined copy of assistant_querier.lua's interrupted-stream recovery helper.
local function cleanStreamError(err)
    return tostring(err or ""):gsub("^[\n%s]*", "")
end

local function addInterruptedStreamNotice(content, err)
    if type(content) ~= "string" or #content:gsub("^%s+", ""):gsub("%s+$", "") == 0 then
        return nil, cleanStreamError(err)
    end
    local notice = "\n\n---\n\n**Response interrupted before completion.**"
    local clean_err = cleanStreamError(err)
    if #clean_err > 0 then
        notice = notice .. "\n\nError: " .. clean_err
    end
    return content .. notice, nil
end

local function isOutputLimitStopReason(reason)
    if type(reason) ~= "string" then
        return false
    end
    local lowered = reason:lower()
    return lowered == "length"
        or lowered == "max_tokens"
        or lowered == "max_output_tokens"
        or lowered:find("max", 1, true) ~= nil and lowered:find("token", 1, true) ~= nil
end

local tests = {

    -- =========================================================================
    -- updateStreamText: auto_scroll=true branch (existing behavior kept)
    -- =========================================================================

    test("auto_scroll=true: appends each delta via addTextToInput", function()
        local dialog, calls = makeMockDialog()
        updateStreamText(dialog, "delta1", true)
        updateStreamText(dialog, "delta2", true)
        assert.equal(#calls.addTextToInput, 2, "addTextToInput should be called for each delta")
        assert.equal(calls.addTextToInput[1], "delta1")
        assert.equal(calls.addTextToInput[2], "delta2")
        assert.equal(#calls.addChars, 0, "addChars must not be used when auto-scroll is on")
        assert.equal(calls.resyncPos, 0, "resyncPos must not be used when auto-scroll is on")
    end),

    -- =========================================================================
    -- updateStreamText: auto_scroll=false branch (regression 6f4b134)
    -- =========================================================================

    test("auto_scroll=false: calls initTextBox instead of addTextToInput", function()
        local dialog, calls = makeMockDialog()
        updateStreamText(dialog, "delta", false)
        assert.equal(#calls.addTextToInput, 0,
            "addTextToInput must NOT be called when auto-scroll is off (regression 6f4b134)")
        assert.equal(calls.resyncPos, 1, "resyncPos preserves the current scroll/cursor position")
        assert.equal(#calls.initTextBox, 1, "initTextBox rebuilds the widget with saved view state")
        assert.equal(calls.initTextBox[1].text, nil)
        assert.equal(calls.initTextBox[1].keep, true)
    end),

    -- =========================================================================
    -- Flush flow: auto_scroll=false preserves view via initTextBox
    -- =========================================================================

    test("flow auto_scroll=false: initTextBox called with coalesced delta", function()
        local dialog, calls = makeMockDialog()
        local driver = makeStreamDriver(dialog, false)
        driver.onContent("Hello ")
        driver.onContent("world")
        driver.flush()
        assert.equal(#calls.addTextToInput, 0,
            "addTextToInput must never be used when auto-scroll is off")
        assert.equal(#calls.initTextBox, 1)
        driver.onContent("!")
        driver.flush()
        assert.equal(#calls.initTextBox, 2)
    end),

    -- =========================================================================
    -- Flush flow: auto_scroll=true keeps existing append behavior
    -- =========================================================================

    test("flow auto_scroll=true: appends coalesced delta via addTextToInput", function()
        local dialog, calls = makeMockDialog()
        local driver = makeStreamDriver(dialog, true)
        driver.onContent("Hello ")
        driver.onContent("world")
        driver.flush()
        -- deltas are coalesced into a single flush (0.5s cadence)
        assert.equal(#calls.addTextToInput, 1)
        assert.equal(calls.addTextToInput[1], "Hello world")
        assert.equal(#calls.addChars, 0)
    end),

    test("preview cap rebuilds stream dialog with only the latest text", function()
        local dialog, calls = makeMockDialog()
        updateStreamText(dialog, "12345", true, 5)
        updateStreamText(dialog, "67890", true, 5)
        assert.equal(#calls.addTextToInput, 1,
            "content under the cap should use the normal append path")
        assert.equal(#calls.setText, 1,
            "content over the cap should rebuild the preview instead of appending forever")
        assert.isTrue(calls.setText[1].text:find("hidden while streaming", 1, true) ~= nil)
        assert.isTrue(calls.setText[1].text:find("67890", 1, true) ~= nil)
        assert.equal(dialog._stream_preview_tail, "67890")
    end),

    -- =========================================================================
    -- Flush flow: reasoning->answer transition
    -- =========================================================================

    test("flow auto_scroll=false: reasoning->answer transition clears the widget", function()
        local dialog, calls = makeMockDialog()
        local driver = makeStreamDriver(dialog, false)
        -- reasoning phase
        driver.onContent("thinking...")
        driver.flush()
        -- answer phase begins
        driver.onContent("answer one", true)
        driver.onContent(" answer two")
        driver.flush()
        -- Verify transition cleared the widget (initTextBox with text="" and keep=true)
        local found_clear = false
        for _, call in ipairs(calls.initTextBox) do
            if call.text == "" and call.keep == true then
                found_clear = true
                break
            end
        end
        assert.isTrue(found_clear, "transition should clear the input text box")
    end),

    test("flow resets bounded preview when reasoning switches to answer", function()
        local dialog, calls = makeMockDialog()
        local driver = makeStreamDriver(dialog, true, 5)
        driver.onContent("thinking")
        driver.flush()
        assert.isTrue((dialog._stream_preview_omitted or 0) > 0)
        driver.onContent("answer", true)
        driver.flush()
        assert.equal(dialog._stream_preview_tail, "answer")
        assert.equal(dialog._stream_preview_omitted, 0)
        assert.isTrue(#calls.setText >= 2)
    end),

    test("flow auto_scroll=false: pending reasoning is flushed before the transition", function()
        local dialog, calls = makeMockDialog()
        local driver = makeStreamDriver(dialog, false)
        driver.onContent("thinking part1")
        driver.onContent(" part2")             -- flush still scheduled
        driver.onContent("answer", true)       -- transition forces the pending flush first
        -- After transition + flush, there should be initTextBox calls both for
        -- the pending reasoning flush and for the transition clear
        assert.isTrue(#calls.initTextBox >= 2,
            "pending reasoning flush + transition clear should each call initTextBox")
    end),

    test("tool loop disables web_search before final answer after max searches", function()
        local query_option = { use_websearch = "tavilyapi", force_websearch = false }
        applyWebSearchPostToolState(query_option, true, 4, 3)
        assert.equal(query_option.use_websearch, "none")
        assert.isFalse(query_option.force_websearch)
    end),

    test("tool loop makes explicit forced search one-shot", function()
        local query_option = { use_websearch = "tavilyapi", force_websearch = true }
        applyWebSearchPostToolState(query_option, false, 1, 3)
        assert.equal(query_option.use_websearch, "none")
        assert.isFalse(query_option.force_websearch)
    end),

    test("interrupted stream keeps partial content with a notice", function()
        local content, err = addInterruptedStreamNotice("partial X-Ray answer", "\n timeout")
        assert.equal(err, nil)
        assert.isTrue(content:find("partial X-Ray answer", 1, true) ~= nil)
        assert.isTrue(content:find("Response interrupted before completion", 1, true) ~= nil)
        assert.isTrue(content:find("timeout", 1, true) ~= nil)
    end),

    test("interrupted stream without content remains an error", function()
        local content, err = addInterruptedStreamNotice("   ", "\n upstream closed")
        assert.equal(content, nil)
        assert.equal(err, "upstream closed")
    end),

    test("output limit stop reasons trigger stream continuation", function()
        assert.isTrue(isOutputLimitStopReason("length"))
        assert.isTrue(isOutputLimitStopReason("MAX_TOKENS"))
        assert.isTrue(isOutputLimitStopReason("max_output_tokens"))
        assert.isFalse(isOutputLimitStopReason("stop"))
        assert.isFalse(isOutputLimitStopReason("tool_calls"))
    end),
}

return helper.runTests("assistant_querier.lua (stream UI)", tests)
