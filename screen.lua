local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase        = lrequire_common("screen_base")
local MenuHelper        = lrequire_common("menu_helper")
local GenProgress       = lrequire_common("gen_progress")
local SignpostBoard       = lrequire("board")
local SignpostBoardWidget = lrequire("board_widget")

local GAME_RULES_EN = _([[
Signpost — Rules

Number every cell from 1 to the last number so that each number's successor lies somewhere along its arrow — next to it or further away, in the direction the arrow points.

• The first and the last numbers are given, and sometimes a few more (on a grey background).
• The last cell has no arrow: it shows a ring instead.

Controls:
• Tap a cell to select it: the cells along its arrow get a light frame.
• Tap one of them to link it as the next cell. It becomes the selection, so you can build a chain by tapping its cells in order.
• Tap the selected cell's successor again to undo that link, or tap the selected cell to deselect it.
• Hold a cell to cut both of its links.

Linked cells show their numbers when their chain holds a given number. A chain without one is labelled with a letter: a, a+1, a+2… A cell's arrow turns grey once it has a successor.
]])

local GAME_RULES_FR = [[
Signpost — Règles

Numérotez toutes les cases de 1 au dernier nombre de sorte que le successeur de chaque nombre se trouve quelque part le long de sa flèche — juste à côté ou plus loin, dans la direction indiquée.

• Le premier et le dernier nombre sont donnés, parfois quelques autres aussi (sur fond gris).
• La dernière case n'a pas de flèche : elle porte un anneau.

Commandes :
• Touchez une case pour la sélectionner : les cases le long de sa flèche reçoivent un cadre clair.
• Touchez l'une d'elles pour en faire la case suivante. Elle devient la sélection : on construit ainsi une chaîne en touchant ses cases dans l'ordre.
• Touchez de nouveau le successeur de la case sélectionnée pour défaire ce lien, ou la case sélectionnée pour la désélectionner.
• Appui long sur une case pour couper ses deux liens.

Les cases liées affichent leur numéro quand leur chaîne contient un nombre donné. Une chaîne sans nombre est étiquetée par une lettre : a, a+1, a+2… La flèche d'une case devient grise une fois son successeur choisi.
]]

local SignpostScreen = ScreenBase:extend{}

function SignpostScreen:init()
    local state = self.plugin:loadState()
    self.board  = SignpostBoard:new{
        n          = self.plugin:getSetting("grid_n", SignpostBoard.DEFAULT_N),
        difficulty = self.plugin:getSetting("difficulty", "easy"),
    }
    if not self.board:load(state) then
        GenProgress.run(function(on_progress) self.board:generate(nil, nil, on_progress) end)
    end
    ScreenBase.init(self)
end

function SignpostScreen:serializeState()
    return self.board:serialize()
end

function SignpostScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Signpost"), function()
        return {
            { text = _("New game"),              callback = function() self:onNewGame() end },
            self:makeDailyButtonConfig(),
            { text = self:getGridButtonText(),   callback = function() self:openGridMenu() end },
            { text = self:getDiffButtonText(),   callback = function() self:openDifficultyMenu() end },
            { text = self:getRevealButtonText(), callback = function() self:onToggleReveal() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    self.status_text:setMaxWidth(self:getControlsWidth())
    local action_bar = self:buildActionBar({
        { id = "undo_button", text = _("Undo"), callback = function() self:onUndo() end },
        { text = _("Hint"),  callback = function() self:onHint() end },
        { text = _("Clear"), callback = function() self:onClear() end },
    })
    self.undo_button = action_bar:getButtonById("undo_button")
    self:_updateUndoButton()
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        action_bar,
    }

    -- The widget draws its own outer grid line, so the frame only pads.
    local frame_pad   = Size.padding.large
    local frame_extra = 2 * frame_pad
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = SignpostBoardWidget:new{
        board        = self.board,
        max_size     = math.min(budget_w, budget_h) - frame_extra,
        onCellAction = function(r, c, is_hold) self:onCellAction(r, c, is_hold) end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }

    if is_landscape then
        self:buildLandscapeLayout(title_bar, HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        })
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

local REFUSALS = {
    [SignpostBoard.ERR_LOOP]    = _("That link would close a loop."),
    [SignpostBoard.ERR_NUMBERS] = _("Those numbers cannot follow each other."),
}

-- The unit is a cell's link to its successor, not the cell's own content.
function SignpostScreen:describeHintStep(step, level)
    if level == 1 then
        return step.kind == "mistake"
            and T(_("The link leaving R%1C%2 is wrong. Tap Hint again to cut it."), step.r, step.c)
            or  T(_("The cell after R%1C%2 can be worked out. Tap Hint again to link it."), step.r, step.c)
    end
    return step.kind == "mistake"
        and T(_("Cut the link leaving R%1C%2."), step.r, step.c)
        or  T(_("Linked R%1C%2 to the next cell."), step.r, step.c)
end
function SignpostScreen:onCellAction(r, c, is_hold)
    if self.board:isShowingSolution() or self.board:isSolved() then return end
    local ok, err
    if is_hold then
        ok, err = self.board:holdCell(r, c)
    else
        ok, err = self.board:tapCell(r, c)
    end
    self.hint_cell = nil
    self.plugin:saveState(self.board:serialize())
    self:_updateUndoButton()
    self.board_widget:refresh()
    if not ok and err and REFUSALS[err] then
        self:updateStatus(REFUSALS[err])
    else
        self:updateStatus()
    end
end

function SignpostScreen:onNewGame()
    local n    = self.plugin:getSetting("grid_n", SignpostBoard.DEFAULT_N)
    local diff = self.plugin:getSetting("difficulty", "easy")
    self.board = SignpostBoard:new{ n = n, difficulty = diff }
    GenProgress.run(function(on_progress) self.board:generate(nil, nil, on_progress) end)
    self.hint_cell = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function SignpostScreen:onUndo()
    if self.board:isShowingSolution() then return end
    if not self.board:undoLast() then
        self:updateStatus(_("Nothing to undo."))
        return
    end
    self.hint_cell = nil
    self.plugin:saveState(self.board:serialize())
    self:_updateUndoButton()
    self.board_widget:refresh()
    self:updateStatus()
end

function SignpostScreen:onClear()
    if self.board:isShowingSolution() then return end
    if self.board:clearAll() then
        self.board.selected = nil
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        self.board_widget:refresh()
    end
    self:updateStatus()
end

function SignpostScreen:onHint()
    ScreenBase.onHint(self)
    self:_updateUndoButton()
end

function SignpostScreen:onToggleReveal()
    self.board:toggleSolution()
    self.board_widget:refresh()
    self:updateStatus()
end

function SignpostScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(SignpostBoard.SIZES) do
        sizes[#sizes + 1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", SignpostBoard.DEFAULT_N),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

function SignpostScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "easy"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            self:onNewGame()
        end,
    }
end

function SignpostScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board:isShowingSolution() then
        status = _("Solution is shown; editing is disabled.")
    elseif self.board:isSolved() then
        status = T(_("Solved! Time: %1"), self.board.timer:format())
    else
        local diff = self.board.difficulty
        status = self:joinStatus(
            T("%1×%1", self.board.n),
            MenuHelper.DIFFICULTY_LABELS[diff] or diff,
            T(_("Links: %1/%2"), self.board:countLinks(), self.board.N - 1))
    end
    ScreenBase.updateStatus(self, status)
    -- Every move, hint, undo and reveal ends here, so the bar follows the board.
    self:refreshActionBar()
end

-- Showing the solution can be hidden again, so only solving it ends the round.
function SignpostScreen:isRoundOver()
    return self.board:isSolved()
end

function SignpostScreen:getGridButtonText()
    return T(_("Size: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function SignpostScreen:getDiffButtonText()
    local diff = self.plugin:getSetting("difficulty", "easy")
    return T(_("Difficulty: %1"), MenuHelper.DIFFICULTY_LABELS[diff] or diff)
end

function SignpostScreen:getRevealButtonText()
    return self.board:isShowingSolution() and _("Hide solution") or _("Show solution")
end

function SignpostScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo() and not self.board:isSolved())
end

return SignpostScreen
