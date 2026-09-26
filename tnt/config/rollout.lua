--- Раскатка конфигурации: проверить у всех, записать один раз, дождаться.
---
--- В Tarantool 3.x запись в общий источник применяется каждым узлом
--- независимо и асинхронно. Записали YAML в etcd — и половина кластера
--- применила, половина свалилась в алерты; признака «все сошлись на этой
--- ревизии» в ядре нет, есть только локальный статус на каждом узле.
---
--- Отсюда три фазы, и первая из них — не формальность. Битая конфигурация
--- валит кластер веером: узлы применяют её по очереди и падают по очереди,
--- а откатывать уже некуда. Поэтому кандидат сперва проверяется на всех
--- узлах, ничего не применяя, и только потом пишется.
---
--- Запись одна: транзакция в etcd, обусловленная ревизией прочитанного.
--- Это и есть точка атомарности: правка ложится одним ключом, а не
--- файлом на каждом узле, и расходиться записи нечему — либо она
--- прошла, либо нет.
---
--- Отката на фазе записи нет намеренно. Узел, не применивший новую
--- конфигурацию, чинится перечитыванием, а не возвратом всего кластера
--- к прежней ревизии: возврат — это ещё одна правка, и валить ею кластер
--- второй раз незачем. Зато расхождение обнаружимо: третья фаза ждёт,
--- пока все доложат, что применили ту же ревизию, и честно говорит, кто
--- не доложил. Судит она по докладу ядра — состоянию и его замечаниям, —
--- а не по одной ревизии: ревизию узел узнаёт, прочитав хранилище, а
--- применяет прочитанное отдельно и может на этом упасть.
---
--- Узлы спрашиваются веером `tnt-async`, а не по одному: проверка
--- кандидата, просьба перечитать и заход схождения идут ко всем узлам
--- разом, с одним сроком на фазу. По одному молчащий узел задерживал бы
--- каждую фазу на свой срок, а кластер из десяти узлов — на десять.
--- Срок проверки и просьбы — срок схождения; срок захода — пауза между
--- опросами либо остаток срока схождения, что короче. Ответы приходят
--- в порядке узлов вместе с отказами: узел, не ответивший в срок,
--- возражает или не докладывает — как и прежде, не срывая остальных.

local async = require('tnt.async')
local clock = require('tnt.clock')
local diff = require('tnt.config.diff')
local patch = require('tnt.config.patch')
local topology = require('tnt.config.topology')

local Module = {}

--- Сколько ждать схождения, если не задано иное.
local DEFAULT_CONVERGE_TIMEOUT = 30

--- Как часто спрашивать узлы во время ожидания.
local DEFAULT_POLL_INTERVAL = 0.5

--- Имена групп веера по фазам: по ним в журнале и `fiber.info()` видно,
--- на какой фазе завис узел.
local GROUP_PREPARE = 'rollout/prepare'
local GROUP_REFRESH = 'rollout/refresh'
local GROUP_CONVERGE = 'rollout/converge'

--- Чем узел ответил, если ответа не было.
local NO_REASON = 'узел не объяснил отказ'

--- Чем объясняется узел, не ответивший к сроку фазы.
local LATE = 'узел не ответил в срок'

---@class TntConfigRolloutRequest
---@field candidate table|nil Что раскатываем целиком
---@field patch TntConfigChange[]|nil Чем править действующую, если не целиком
---@field current table|nil Действующая конфигурация
---@field removing string[]|nil Узлы, которые выводят намеренно
---@field revision number|nil Ревизия, поверх которой пишем
---@field validate fun(name: string, candidate: table): boolean, string|nil Проверка на одном узле
---@field targets string[] Узлы, у которых спрашиваем
---@field write fun(candidate: table, revision: number|nil): number|nil, string|nil Запись в хранилище
---@field refresh (fun(name: string): boolean, string|nil)|nil Попросить узел перечитать конфигурацию
---@field applied fun(name: string): TntConfigRolloutState|nil, string|nil Что узел применил и что о себе говорит
---@field timeout number|nil Сколько ждать схождения
---@field interval number|nil Как часто спрашивать
---@field sleep fun(seconds: number)|nil Чем ждать между опросами
---@field monotonic (fun(): number)|nil Часы
---@field instance string|nil Имя узла, применяющего правку: его вычёркивать нельзя

---@class TntConfigRolloutAlert
---@field type string Вес замечания: error или warn
---@field message string Что не так

---@class TntConfigRolloutState
---@field revision number|nil Ревизия применённой на узле конфигурации
---@field status string|nil Что ядро говорит о применении: ready, check_warnings, check_errors
---@field alerts TntConfigRolloutAlert[]|nil Замечания ядра к конфигурации

---@class TntConfigRolloutResult
---@field phase string На какой фазе остановились
---@field changes TntConfigDifference[] Чем кандидат отличался от применённого
---@field revision number|nil Ревизия, которую записали
---@field converged string[] Узлы, применившие новую ревизию
---@field pending string[] Узлы, не применившие её
---@field states table<string, TntConfigRolloutState> Последний доклад каждого узла о себе
---@field errors table<string, string> Почему узел возражал, не ответил или не применил
---@field err string|nil Общая причина отказа

--- Правка не собралась: путь написан с ошибкой или упирается в значение.
Module.PATCH = 'patch'

--- Раскатывать нечего: кандидат совпадает с тем, что уже записано.
---
--- Отдельный исход, а не успешная запись: писать новую ревизию ради
--- того же содержимого значит засорять историю правок и заставлять
--- кластер перечитывать конфигурацию впустую.
Module.UNCHANGED = 'unchanged'

--- Фаза сверки: правку сравнивают с действующей конфигурацией.
Module.TOPOLOGY = 'topology'

--- Фаза проверки: кандидата смотрят все, не применяя.
Module.PREPARE = 'prepare'

--- Фаза записи: одна транзакция в хранилище.
Module.COMMIT = 'commit'

--- Фаза схождения: ждём, пока узлы доложат новую ревизию.
Module.CONVERGE = 'converge'

--- Имена по порядку: списки читают люди.
---@param names string[]
---@return string[]
local function sorted(names)
    local copy = {}

    for _, name in ipairs(names) do
        table.insert(copy, name)
    end

    table.sort(copy)

    return copy
end

--- Исход, на котором раскатка остановилась, ничего не записав.
---@param request TntConfigRolloutRequest
---@param phase string
---@param changes TntConfigDifference[]
---@param errors table<string, string>
---@param err string
---@return TntConfigRolloutResult
local function stopped(request, phase, changes, errors, err)
    return {
        phase = phase,
        revision = nil,
        changes = changes,
        converged = {},
        pending = sorted(request.targets),
        states = {},
        errors = errors,
        err = err,
    }
end

--- Срок фазы, в которую узлы спрашиваются один раз.
---@param request TntConfigRolloutRequest
---@return number
local function phase_timeout(request)
    return request.timeout or DEFAULT_CONVERGE_TIMEOUT
end

--- Почему узел не ответил как надо — по итогу задачи веера.
---
--- Отказ узла — его собственная причина; исключение — его текст;
--- срок фазы — «не ответил в срок»: и не начатая в очереди задача, и
--- не успевшая — для оператора один и тот же молчащий узел.
---@param result TntAsyncResult
---@return string
local function reason_of(result)
    if result.kind == async.TIMEOUT or result.kind == async.NOT_STARTED then
        return LATE
    end

    if result.err == nil then
        return NO_REASON
    end

    return tostring(result.err)
end

--- Спрашивает каждый узел разом и собирает причины отказов по именам.
---@param names string[] Узлы по порядку
---@param ask fun(name: string): any, any Что спросить у узла
---@param timeout number Срок на всех
---@param group string Имя группы веера
---@return TntAsyncResult[] answers Итоги в порядке узлов
---@return table<string, string> reasons Причины отказавших
local function asked(names, ask, timeout, group)
    local answers = async.map(names, ask, { timeout = timeout, name = group })
    local reasons = {}

    for index, name in ipairs(names) do
        local answer = answers[index] --[[@as TntAsyncResult]]

        if not answer.ok then
            reasons[name] = reason_of(answer)
        end
    end

    return answers, reasons
end

--- Спрашивает кандидата у всех узлов, ничего не применяя.
---@param request TntConfigRolloutRequest
---@param candidate table
---@return boolean ok
---@return table<string, string> objections
local function prepare(request, candidate)
    local _, objections = asked(sorted(request.targets), function(name)
        return request.validate(name, candidate)
    end, phase_timeout(request), GROUP_PREPARE)

    return next(objections) == nil, objections
end

--- Просит узлы перечитать конфигурацию.
---
--- Нужно там, где за хранилищем никто не следит. В Enterprise встроенный
--- источник сам замечает новую ревизию и применяет её; в Community
--- источник читает хранилище при старте, и без просьбы узел останется
--- на прежней конфигурации сколько угодно долго — запись прошла, а кластер
--- о ней не знает.
---
--- Отказ одного узла не отменяет остальных и не прерывает раскатку:
--- перечитывание — просьба, а не команда, и узел вправе подхватить
--- конфигурацию сам, пока мы ждём.
---@param request TntConfigRolloutRequest
---@return table<string, string> failures
local function refresh(request)
    local ask = request.refresh

    if ask == nil then
        return {}
    end

    local _, failures = asked(sorted(request.targets), ask, phase_timeout(request), GROUP_REFRESH)

    return failures
end

--- Состояния ядра, в которых конфигурация применена.
---
--- `check_warnings` — применена с замечаниями, и это схождение: узел
--- живёт на новой ревизии, а замечания попадут в доклад. `check_errors`
--- — не применена, какую бы ревизию узел ни назвал. Остальные — ещё
--- в пути.
local SETTLED = { ready = true, check_warnings = true }

--- Применил ли узел записанную ревизию.
---
--- Одной ревизии мало: источник узнаёт её, прочитав хранилище, а ядро
--- применяет прочитанное отдельно и может провалиться. Узел, доложивший
--- новую ревизию и `check_errors`, живёт на прежней конфигурации, и
--- считать его сошедшимся значит отпустить оператора от живой беды.
--- Узел без статуса судится по ревизии: о ядре он ничего не сказал.
---@param state TntConfigRolloutState
---@param revision number
---@return boolean
local function has_applied(state, revision)
    local reached = state.revision ~= nil and state.revision >= revision
    local settled = state.status == nil or SETTLED[state.status] == true

    return reached and settled
end

--- Замечания ядра одной строкой: доклад читает человек.
---@param alerts TntConfigRolloutAlert[]|nil
---@return string
local function alert_messages(alerts)
    local messages = {}

    for _, alert in ipairs(alerts or {}) do
        table.insert(messages, ('%s: %s'):format(tostring(alert.type), tostring(alert.message)))
    end

    return table.concat(messages, '; ')
end

--- Почему узел не применил конфигурацию, если сам об этом сказал.
---
--- Только провал применения: узел, который ещё в пути или на прежней
--- ревизии, объяснять нечего — он просто не дошёл.
---@param state TntConfigRolloutState
---@return string|nil
local function apply_failure(state)
    if state.status ~= 'check_errors' then
        return nil
    end

    local messages = alert_messages(state.alerts)

    return ('конфигурация не применена, ядро в состоянии check_errors%s'):format(
        messages ~= '' and (': ' .. messages) or ''
    )
end

--- Срок одного захода схождения: пауза между опросами либо остаток
--- срока схождения — что короче.
---
--- Остаток бывает и исчерпан: срок вышел, пока заход спал, а спросить
--- узлы напоследок всё равно нужно — это последний заход, и дальше цикл
--- кончается. Такому заходу достаётся обычная пауза: без срока он ждал бы
--- молчащий узел вечно, а нулевой срок веер не принимает.
---@param interval number
---@param left number Остаток срока схождения
---@return number
local function round_timeout(interval, left)
    if left > 0 then
        return math.min(interval, left)
    end

    return interval
end

--- Ждёт, пока узлы доложат, что применили новую ревизию.
---@param request TntConfigRolloutRequest
---@param revision number
---@return string[] converged
---@return string[] pending
---@return table<string, TntConfigRolloutState> states
---@return table<string, string> errors
local function converge(request, revision)
    local timeout = request.timeout or DEFAULT_CONVERGE_TIMEOUT
    local interval = request.interval or DEFAULT_POLL_INTERVAL
    local monotonic = request.monotonic or clock.monotonic
    local sleep = request.sleep or clock.sleep

    local deadline = monotonic() + timeout
    local converged = {}
    local pending = sorted(request.targets)

    -- Доклады хранятся последние: узел, ответивший со второй попытки,
    -- не должен тащить за собой прежний ответ. Причины по той же мерке
    -- собираются заново на каждом заходе.
    local states = {}
    local errors

    while true do
        local still_waiting = {}
        errors = {}

        local answers, reasons =
            asked(pending, request.applied, round_timeout(interval, deadline - monotonic()), GROUP_CONVERGE)

        for index, name in ipairs(pending) do
            local answer = answers[index] --[[@as TntAsyncResult]]
            local state = answer.ok and answer.value or nil

            if state ~= nil then
                states[name] = state
            end

            if state ~= nil and has_applied(state, revision) then
                table.insert(converged, name)
            else
                table.insert(still_waiting, name)

                -- Отказ связи главнее рассказа узла: он объясняет, почему
                -- рассказа может не быть вовсе. У ответившего узла отказ —
                -- второе значение доклада, у не ответившего — причина веера.
                ---@type string|nil
                local reason = reasons[name]

                if reason == nil and answer.extra ~= nil then
                    reason = tostring(answer.extra)
                end

                if reason == nil then
                    reason = apply_failure(state)
                end

                errors[name] = reason
            end
        end

        pending = still_waiting

        if #pending == 0 or monotonic() >= deadline then
            break
        end

        sleep(interval)
    end

    table.sort(converged)

    return converged, pending, states, errors
end

--- Раскатывает конфигурацию по кластеру.
---
--- Отказ на фазе проверки не оставляет следов: ничего не записано,
--- и кластер живёт как жил. Отказ на фазе схождения означает, что запись
--- прошла, а часть узлов её ещё не применила — это не повод откатывать,
--- это повод перечитать конфигурацию на отставших.
---@param request TntConfigRolloutRequest
---@return TntConfigRolloutResult
function Module.apply(request)
    -- Правка по кускам собирается здесь же, а не у вызывающего: так она
    -- проходит те же три фазы, что и присланный целиком текст. Правка,
    -- пропускающая проверку, рано или поздно уронит кластер ровно тем,
    -- от чего проверка и защищает.
    -- Кандидат приходит либо целиком, либо правками: аннотация обещает
    -- необязательным и то, и другое, а дальше он обязан быть таблицей.
    ---@type any
    local candidate = request.candidate

    if request.patch ~= nil then
        local built, patch_error = patch.apply(request.current, request.patch)

        if built == nil then
            return stopped(request, Module.PATCH, {}, {}, tostring(patch_error))
        end

        candidate = built
    end

    -- Разница считается до всего остального: по ней видно, есть ли о чём
    -- говорить вообще.
    local changes = diff.of(request.current, candidate)

    if #changes == 0 then
        return {
            phase = Module.UNCHANGED,
            revision = nil,
            changes = changes,
            -- Узлы уже там, куда их звали: они на той самой конфигурации.
            converged = sorted(request.targets),
            pending = {},
            states = {},
            errors = {},
        }
    end

    -- Сверка с действующей конфигурацией идёт первой и никуда не ходит:
    -- правку, вычёркивающую узел или переносящую его в другой репликасет,
    -- узлы приняли бы охотно — она синтаксически безупречна, и сломается
    -- от неё кластер, а не конфигурация.
    local acceptable, breaches = topology.acceptable(request.current, candidate, {
        self_name = request.instance,
        removing = request.removing,
    })

    if not acceptable then
        local reasons = {}

        for _, breach in ipairs(breaches) do
            reasons[breach.target] = breach.message
        end

        return stopped(
            request,
            Module.TOPOLOGY,
            changes,
            reasons,
            'правка ломает топологию кластера'
        )
    end

    local ready, objections = prepare(request, candidate)

    if not ready then
        return stopped(
            request,
            Module.PREPARE,
            changes,
            objections,
            'конфигурация отвергнута узлами'
        )
    end

    local revision, write_error = request.write(candidate, request.revision)

    if revision == nil then
        return stopped(
            request,
            Module.COMMIT,
            changes,
            {},
            ('конфигурация не записана: %s'):format(tostring(write_error))
        )
    end

    -- Просьба перечитать идёт до ожидания, а не вместо него: узел мог
    -- не ответить на просьбу и всё равно применить конфигурацию, а мог
    -- ответить и не применить. Судим по докладу узла о себе.
    local refused = refresh(request)
    local converged, pending, states, errors = converge(request, revision)

    for name, err in pairs(refused) do
        if errors[name] == nil then
            errors[name] = err
        end
    end

    return {
        phase = Module.CONVERGE,
        revision = revision,
        changes = changes,
        converged = converged,
        pending = pending,
        states = states,
        errors = errors,
        err = #pending > 0 and 'конфигурация записана, но применена не всеми'
            or nil,
    }
end

return Module
