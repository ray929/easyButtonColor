-- easyButtonColor/easyButtonColor.lua
-- 动作条按钮变色：整合 GreyOnCooldown（CD 中变灰）与 tullaRange（超出范围变红）的功能，
-- 并新增「资源不足 → 蓝色」状态。三种状态独立判定、由本模块统一设置图标颜色，互不冲突。
-- 常驻生效：无配置界面、无存档、无游戏内开关（停用方式 = 插件列表禁用本插件）。
--
-- 状态优先级（互斥，高优先级覆盖低优先级）：
--   1) CD 中        → 图标去色（灰色）   —— 最高优先级，此时技能根本不可施放
--   2) 资源不足     → 蓝色 vertex color  —— 缺蓝/缺能量/缺怒气等（notEnoughMana）
--   3) 超出范围     → 红色 vertex color  —— 目标在射程外
--   4) 其余         → 正常（白色 vertex + 不透明度恢复）
--
-- 实现要点：
--   · 直接修改原生动作条按钮的 icon 纹理（SetDesaturation / SetVertexColor），属 texture 操作，
--     taint-safe，战斗中照常工作（与原生 ActionButton_UpdateUsable 同性质）。
--   · 通过 ActionBarButtonEventsFrame:ForEachFrame 注册所有原生动作条按钮（含 Multibar 等），
--     hook 其 Update / UpdateUsable（均加 type=="function" 保护），并 hook 全局
--     ActionButton_UpdateCooldown 与 ActionButton_UpdateRangeIndicator 安全函数，
--     以及 cooldown 的 OnCooldownDone / OnShow / OnHide 时刷新；同时 hook RegisterFrame 覆盖
--     登录后动态创建的按钮。
--     ⚠️ 零售版动作按钮【实例】没有 UpdateCooldown 方法，只能钩全局 ActionButton_UpdateCooldown。
--   · CD 判定：CooldownInfo.isOnGCD 字段「只在响应 SPELL_UPDATE_COOLDOWN 事件时可信」，任意时机
--     读它会把 GCD 误判成真实冷却导致全灰。故只在 SPELL_UPDATE_COOLDOWN 事件里读取并缓存每个按钮的
--     真实冷却态（cdCache），其余刷新时机复用缓存，绝不跨时机读 isOnGCD。
--     效果：有 CD 技能用了立即灰（使用即触发该事件），纯 GCD 波及的技能不灰，且不再全灰。
--     另一条无时机限制的合法通道：cooldown OnShow 时若脱战（数据明文），
--     用 C_ActionBar.GetActionCooldownDuration(action, true)（ignoreGCD 在 C 层剔除 GCD）
--     + DurationObject:GetRemainingDuration() 直接精算写缓存，解决翻页回来 CD 技能不灰的问题。
--     ⚠️ 也绝不可比较 startTime/duration/GetRemainingDuration 等 secret number 数值（tainted 下报错；
--     故 OnShow 精算前必查 HasSecretValues()，战斗中放弃精算）。
--   · 资源判定用 C_ActionBar.IsUsableAction → (isUsable, notEnoughMana)，缺资源且不可用即变蓝。
--   · 范围判定用 IsActionInRange(action) 明确为 false/0 才认作超范围（无射程技能返回 nil 不处理）。
--   · 事件驱动刷新（同帧合并 + 最小间隔 0.1s 限频），事件兜底覆盖 CD / 资源 / 范围 / 翻页 / 姿态切换。

-- 颜色（RGB，0~1）；变灰走 desaturation 不依赖颜色
-- 资源不足 → 红10% 绿30% 蓝100%（偏蓝）；超出范围 → 红100% 绿30% 蓝10%（偏红）
local COLOR = {
    oom    = { 0.10, 0.30, 1.00 },  -- 资源不足
    oor    = { 1.00, 0.30, 0.10 },  -- 超出范围
}
-- 彩色态降饱和度强度（0=原色，1=全灰）；CD 灰态仍用 1
local DESAT_COLOR = 0.6

-- 已注册按钮集合（用于全量刷新）
local buttons = {}

-- =========================================================
-- 取按钮当前指向的 spellID（spell / macro 兼容）
-- ⚠️ 性能：带按钮级缓存（weak key）。战斗中 UNIT_POWER_UPDATE 高频触发全量刷新，
--   每次对 96 按钮做 GetActionInfo pcall + 宏解析是最大开销；槽位内容只在动作条
--   事件（换技能/翻页/姿态/天赋）时变化，届时整体失效缓存即可，热路径零解析。
--   缓存值用 false 哨兵表示"无技能"，避免空槽每帧重复解析。
-- =========================================================
local sidCache = setmetatable({}, { __mode = "k" })

local function ComputeButtonSpellID(btn)
    if not btn.action then return nil end
    local ok, at, id = pcall(GetActionInfo, btn.action)
    if not ok or not at or not id then return nil end
    if at == "spell" then
        return (id > 0) and id or nil
    elseif at == "macro" then
        if not (id and id > 0) then return nil end
        local sid
        if C_Macro and C_Macro.GetMacroSpell then
            local _, spellID = C_Macro.GetMacroSpell(id)
            sid = spellID
        elseif GetMacroSpell then
            local _, spellID = GetMacroSpell(id)
            sid = spellID
        end
        if not (sid and sid > 0) then
            local okN, nm = pcall(function()
                return (C_Spell and C_Spell.GetSpellName) and C_Spell.GetSpellName(id) or GetSpellInfo(id)
            end)
            if okN and nm then sid = id end
        end
        return (sid and sid > 0) and sid or nil
    end
    return nil
end

local function GetButtonSpellID(btn)
    local cached = sidCache[btn]
    if cached ~= nil then return cached or nil end
    local sid = ComputeButtonSpellID(btn)
    sidCache[btn] = sid or false
    return sid
end

-- 槽位内容可能变化的时机：换技能 / 翻页 / 姿态 / 载具 / 天赋（整体失效重建）
local SID_INVALIDATE_EVENTS = {
    ACTIONBAR_SLOT_CHANGED     = true,
    ACTIONBAR_PAGE_CHANGED     = true,
    UPDATE_BONUS_ACTIONBAR     = true,
    UPDATE_VEHICLE_ACTIONBAR   = true,
    UPDATE_POSSESS_BAR         = true,
    SPELLS_CHANGED             = true,
    PLAYER_TALENT_UPDATE       = true,
    ACTIVE_TALENT_GROUP_CHANGED = true,
}

-- =========================================================
-- 判定动作是否处于“真实冷却”（排除纯 GCD）。
-- 关键：CooldownInfo.isOnGCD 字段 wiki 明确「只在响应 SPELL_UPDATE_COOLDOWN 事件时可信」，
-- 任意时机（UNIT_POWER_UPDATE / ACTIONBAR_UPDATE_COOLDOWN / hook UpdateUsable 等）读它不可靠，
-- 会把 GCD 误判成真实冷却导致全灰。故采用【缓存】策略：
--   · 只在 SPELL_UPDATE_COOLDOWN 事件（isOnGCD 唯一可信时机）里读取并缓存每个按钮的真实冷却态；
--   · 其余所有刷新时机复用缓存，绝不跨时机读 isOnGCD。
-- =========================================================
-- 冷却状态缓存：btn -> true/false（是否真实冷却）。weak keys，按钮回收自动清。
local cdCache = setmetatable({}, { __mode = "k" })

-- 计算单按钮是否处于真实冷却（⚠️ 仅在 SPELL_UPDATE_COOLDOWN 等 isOnGCD 可信时机调用）
local function ComputeRealCooldown(btn)
    local action = btn.action
    if action then
        local ok, cd = pcall(C_ActionBar.GetActionCooldown, action)
        if ok and cd and cd.isActive == true and not cd.isOnGCD then
            return true
        end
        return false
    end
    local sid = GetButtonSpellID(btn)
    if sid and C_Spell and C_Spell.GetSpellCooldown then
        local ok, cd = pcall(C_Spell.GetSpellCooldown, sid)
        if ok and cd and type(cd) == "table" and cd.isActive == true and not cd.isOnGCD then
            return true
        end
    end
    return false
end

-- 刷新全部按钮的冷却缓存（只在 SPELL_UPDATE_COOLDOWN 事件调用）
local function RefreshCooldownCache()
    for btn in pairs(buttons) do
        cdCache[btn] = ComputeRealCooldown(btn)
    end
end

-- =========================================================
-- 判定按钮状态："cooldown" / "oom" / "unusable" / "oor" / "normal"
-- =========================================================
local function GetButtonState(btn)
    local action = btn.action
    local sid = GetButtonSpellID(btn)
    if not action and not sid then return "normal" end

    -- 1) CD 中（最高优先级）：读冷却缓存（由 SPELL_UPDATE_COOLDOWN 可信时机维护）。
    --    用了的有 CD 技能：使用即触发 SPELL_UPDATE_COOLDOWN → 缓存立即置真 → 立即灰；
    --    纯 GCD 波及的技能：可信读到 isOnGCD=true → 缓存为假 → 不灰。绝不跨时机读 isOnGCD。
    if cdCache[btn] then
        return "cooldown"
    end

    -- 2) 可用性：取一次 usable 状态，分别判定 资源不足 / 不可用（复用，省一次 pcall）
    local isUsable, notEnoughMana
    if action and C_ActionBar and C_ActionBar.IsUsableAction then
        local ok, u, m = pcall(C_ActionBar.IsUsableAction, action)
        if ok then isUsable, notEnoughMana = u, m end
    elseif sid and C_Spell and C_Spell.IsSpellUsable then
        local ok, u, m = pcall(C_Spell.IsSpellUsable, sid)
        if ok then isUsable, notEnoughMana = u, m end
    end

    -- 2a) 资源不足（缺蓝/缺资源）→ 蓝色
    if isUsable == false and notEnoughMana == true then
        return "oom"
    end
    -- 2b) 不可用（背包中不存在的物品 / 无可用次数 / 其它）→ 灰色（原生灰显行为的还原）
    --     ⚠️ 关键：Blizzard 本就用 desaturation 把"不可用"按钮灰掉；若在 "normal" 态把图标
    --        强制 Reset 成满色，会把这种原生灰显覆盖成彩色（用户反馈"不存在的物品也是彩色的"）。
    if isUsable == false and notEnoughMana == false then
        return "unusable"
    end

    -- 3) 超出范围（最后）：IsActionInRange 明确 false/0 才认作超范围（nil = 无射程，不处理）
    local inRange
    if action then
        if C_ActionBar and C_ActionBar.IsActionInRange then
            local ok, r = pcall(C_ActionBar.IsActionInRange, action)
            if ok then inRange = r end
        elseif IsActionInRange then
            local ok, r = pcall(IsActionInRange, action)
            if ok then inRange = r end
        end
    end
    if inRange == false or inRange == 0 then return "oor" end

    return "normal"
end

-- =========================================================
-- 应用状态到按钮 icon（统一收口，各态不互相覆盖）
-- =========================================================
local function ApplyState(btn, state)
    local icon = btn.icon
    if not icon then return end
    if state == "cooldown" then
        icon:SetDesaturation(1)
    elseif state == "unusable" then
        -- 背包中不存在的物品 / 不可用：原生灰显，与原生 ActionButton_UpdateUsable 一致
        icon:SetDesaturation(1)
    elseif state == "oom" then
        icon:SetDesaturation(DESAT_COLOR)
        icon:SetVertexColor(COLOR.oom[1], COLOR.oom[2], COLOR.oom[3], 1)
    elseif state == "oor" then
        icon:SetDesaturation(DESAT_COLOR)
        icon:SetVertexColor(COLOR.oor[1], COLOR.oor[2], COLOR.oor[3], 1)
    else
        icon:SetDesaturation(0)
        icon:SetVertexColor(1, 1, 1, 1)
    end
end

-- 更新单个按钮（hook 到 Update / UpdateUsable / UpdateCooldown 时回调）
local function UpdateButton(btn)
    if not btn or not btn.icon then return end
    ApplyState(btn, GetButtonState(btn))
end

-- 更新所有已注册按钮（⚠️ 性能：跳过隐藏按钮——隐藏条上的按钮无需判定；
--   条重新显示时按钮 Update/UpdateUsable 会触发 hook 即时补色）
local function RefreshAll()
    for btn in pairs(buttons) do
        if btn:IsShown() then
            UpdateButton(btn)
        end
    end
end

-- 注册单个按钮：记录 + hook 刷新时机（幂等）
local function RegisterButton(btn)
    if not btn or buttons[btn] then return end
    buttons[btn] = true
    if type(btn.UpdateUsable) == "function" then
        hooksecurefunc(btn, "UpdateUsable", UpdateButton)
    end
    if type(btn.Update) == "function" then
        hooksecurefunc(btn, "Update", UpdateButton)
    end
    if btn.cooldown then
        btn.cooldown:HookScript("OnCooldownDone", function()
            cdCache[btn] = false       -- 冷却结束，直接清缓存
            UpdateButton(btn)
        end)
        -- 翻页/姿态/载具/占据切换后按钮换了技能，cdCache 仍持有旧技能的冷却态（页面事件只
        -- 应用缓存不重算）→ 残留错误灰显。冷却帧被引擎隐藏 = 无冷却漩涡 = 必然不在真实 CD，
        -- 缓存安全置 false（即使误触「条隐藏」场景，条重现后下次施法也会全量重算自愈）。
        btn.cooldown:HookScript("OnHide", function()
            cdCache[btn] = false
            UpdateButton(btn)
        end)
        -- OnShow：脱战时用 DurationObject 通道精算真实冷却并写缓存（ignoreGCD=true 在
        -- C 层剔除 GCD，绕开 isOnGCD 的时序可信性问题，脱战数据明文可直接比较）；
        -- 战斗中数据 secret，只补刷新不写缓存，待下次任意施法（SPELL_UPDATE_COOLDOWN
        -- 全量重算）自愈——战斗中施法频繁，延迟无感。
        btn.cooldown:HookScript("OnShow", function()
            if not InCombatLockdown() and btn.action
                and C_ActionBar and C_ActionBar.GetActionCooldownDuration then
                local ok, duration = pcall(C_ActionBar.GetActionCooldownDuration, btn.action, true)
                if ok and type(duration) == "table" then
                    local okS, hasSecret = pcall(duration.HasSecretValues, duration)
                    if okS and not hasSecret then
                        local okR, rem = pcall(duration.GetRemainingDuration, duration)
                        if okR and type(rem) == "number" then
                            cdCache[btn] = rem > 0
                        end
                    end
                end
            end
            UpdateButton(btn)
        end)
    end
end

-- 射程实时刷新（10.1.5+ 事件式 API）：目标进出射程时引擎直接调用此安全函数，
-- 仅此路径能可靠捕获射程变化（ACTIONBAR_UPDATE_USABLE 不会因单纯射程变动而触发）。
hooksecurefunc("ActionButton_UpdateRangeIndicator", function(button)
    if not button or not button.icon then return end
    RegisterButton(button)            -- 幂等，确保按钮已注册
    if buttons[button] then UpdateButton(button) end
end)

-- 冷却刷新：钩全局 ActionButton_UpdateCooldown（零售版动作按钮实例没有 UpdateCooldown
-- 方法，实例钩子会报 "not a function"）。引擎每次刷新冷却都会调用此全局函数。
hooksecurefunc("ActionButton_UpdateCooldown", function(self)
    if self and buttons[self] then UpdateButton(self) end
end)

-- =========================================================
-- 事件驱动刷新（合并同帧多次事件 + 限频）
-- ⚠️ 性能：UNIT_POWER_UPDATE 在战斗中可达每秒十几次（能量/连击点/怒气 tick），
--   每次全量刷 96 按钮的可用性/射程判定开销不小。改为「同帧合并 + 最小间隔 0.1s」：
--   事件连发时每 0.1s 至多刷一次，颜色变化最多延迟 0.1s（无感）；
--   单按钮 hook（Update/UpdateUsable/UpdateCooldown/RangeIndicator）仍即时响应。
-- =========================================================
local REFRESH_MIN_INTERVAL = 0.1
local dirty = false
local dirtyElapsed = 0
local dispatchFrame = CreateFrame("Frame")
dispatchFrame:Hide()
dispatchFrame:SetScript("OnUpdate", function(self, elapsed)
    dirtyElapsed = dirtyElapsed + elapsed
    if dirtyElapsed < REFRESH_MIN_INTERVAL then return end
    self:Hide()
    dirty = false
    RefreshAll()
end)

local function ScheduleRefresh()
    if dirty then return end
    dirty = true
    dirtyElapsed = 0
    dispatchFrame:Show()
end

-- =========================================================
-- 启动
-- =========================================================
local regHooked = false

local function Start()
    -- 注册现有按钮
    if ActionBarButtonEventsFrame and ActionBarButtonEventsFrame.ForEachFrame then
        pcall(ActionBarButtonEventsFrame.ForEachFrame, ActionBarButtonEventsFrame, RegisterButton)
    end
    -- 未来动态创建的按钮（动作条重建/扩展）
    if ActionBarButtonEventsFrame and not regHooked then
        hooksecurefunc(ActionBarButtonEventsFrame, "RegisterFrame", function(f)
            if f then RegisterButton(f) end
        end)
        regHooked = true
    end
    RefreshCooldownCache()  -- 初始化冷却缓存
    RefreshAll()            -- 立即刷新一次
end

-- =========================================================
-- 事件帧（PLAYER_LOGIN 启动并注册全部事件；其余事件合并刷新）
-- =========================================================
local evFrame = CreateFrame("Frame")
evFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        evFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
        evFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
        evFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
        evFrame:RegisterEvent("UPDATE_VEHICLE_ACTIONBAR")
        evFrame:RegisterEvent("UPDATE_POSSESS_BAR")
        evFrame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
        evFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        evFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
        evFrame:RegisterEvent("ACTIONBAR_UPDATE_USABLE")
        evFrame:RegisterEvent("ACTIONBAR_UPDATE_STATE")
        evFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
        evFrame:RegisterEvent("UNIT_FLAGS")
        evFrame:RegisterEvent("UNIT_POWER_UPDATE")
        evFrame:RegisterEvent("SPELLS_CHANGED")
        evFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
        evFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
        Start()
        return
    end
    -- 槽位内容可能变化（换技能/翻页/姿态/载具/天赋）→ 失效 spellID 缓存
    if SID_INVALIDATE_EVENTS[event] then
        wipe(sidCache)
    end
    if event == "SPELL_UPDATE_COOLDOWN" then
        -- isOnGCD 唯一可信时机：同步更新冷却缓存，再合并刷新应用
        RefreshCooldownCache()
        ScheduleRefresh()
        return
    end
    if event == "UNIT_POWER_UPDATE" then
        local unit = ...
        if unit == "player" or unit == "pet" then ScheduleRefresh() end
        return
    end
    ScheduleRefresh()
end)
evFrame:RegisterEvent("PLAYER_LOGIN")
