--- Тесты раскатки конфигурации. Узлы, хранилище и часы подменяются;
--- веер, которым раскатка спрашивает узлы, — настоящий, из исходников.

local fiber = require('fiber')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.config.rollout')

--- Раскатка и то, что она берёт: веер, часы, списки, строки и соседей
--- по пакету.
local MODULES = helper.modules({
    'tnt.config.secrets',
    'tnt.config.diff',
    'tnt.config.patch',
    'tnt.config.topology',
    'tnt.config.rollout',
})

---@type any
local rollout

--- Что происходило по ходу раскатки.
---@type string[]
local journal

--- Часы раскатки: их двигает только проверка.
---@type TntTestingClock
local clock

--- Какую ревизию применил каждый узел.
---@type table<string, number>
local applied

--- Доклад узла о себе: ревизия без состояния ядра — узел, который
--- о ядре ничего не сказал, судится по одной ревизии.
---@param revision number|nil
---@param status string|nil
---@param alerts table[]|nil
---@return table
local function report(revision, status, alerts)
    return { revision = revision, status = status, alerts = alerts }
end

g.before_each(function()
    rollout = helper.load(MODULES, 'tnt.config.rollout')

    journal = {}
    clock = helper.clock()
    applied = { ['storage-001-a'] = 0, ['storage-001-b'] = 0 }
end)

g.after_each(function()
    helper.unload(MODULES)
end)

--- Запрос на раскатку с разумными умолчаниями.
---@param overrides table|nil
---@return table
local function request(overrides)
    overrides = overrides or {}

    local values = {
        candidate = { groups = {} },
        revision = 7,
        targets = { 'storage-001-b', 'storage-001-a' },

        validate = function(name)
            table.insert(journal, ('проверка %s'):format(name))

            return true
        end,

        write = function()
            table.insert(journal, 'запись')

            return 8
        end,

        applied = function(name)
            return report(applied[name])
        end,

        timeout = 5,
        interval = 1,

        monotonic = clock.monotonic,

        sleep = function(seconds)
            clock.sleep(seconds)

            -- Узлы применяют конфигурацию, пока мы ждём: без этого
            -- ожидание всегда упиралось бы в срок.
            for name in pairs(applied) do
                if applied[name] < 8 then
                    applied[name] = 8
                end
            end
        end,
    }

    for key, value in pairs(overrides) do
        values[key] = value
    end

    return values
end

g.test_configuration_is_checked_before_it_is_written = function()
    -- Битая конфигурация валит кластер веером: узлы применяют её по
    -- очереди и падают по очереди.
    rollout.apply(request())

    t.assert_equals(journal, { 'проверка storage-001-a', 'проверка storage-001-b', 'запись' })
end

g.test_refused_candidate_is_never_written = function()
    local result = rollout.apply(request({
        validate = function(name)
            table.insert(journal, ('проверка %s'):format(name))

            if name == 'storage-001-b' then
                return false, 'спейс уже существует'
            end

            return true
        end,
    }))

    t.assert_equals(result.phase, 'prepare')
    t.assert_equals(result.revision, nil)
    t.assert_equals(result.errors['storage-001-b'], 'спейс уже существует')
    t.assert_str_contains(result.err, 'отвергнута узлами')
    t.assert_equals(journal, { 'проверка storage-001-a', 'проверка storage-001-b' })
end

g.test_silent_refusal_is_still_a_refusal = function()
    -- Узел отказался, но не объяснил: это не повод продолжать.
    local result = rollout.apply(request({
        validate = function()
            return false
        end,
    }))

    t.assert_equals(result.phase, 'prepare')
    t.assert_str_contains(result.errors['storage-001-a'], 'не объяснил отказ')
end

g.test_failed_write_stops_the_rollout = function()
    local result = rollout.apply(request({
        write = function()
            return nil, 'ревизия изменилась'
        end,
    }))

    t.assert_equals(result.phase, 'commit')
    t.assert_equals(result.revision, nil)
    t.assert_str_contains(result.err, 'ревизия изменилась')
end

g.test_revision_is_passed_to_the_store = function()
    -- Запись обусловлена ревизией прочитанного: иначе правка затрёт чужую.
    local seen

    rollout.apply(request({
        write = function(_, revision)
            seen = revision

            return 8
        end,
    }))

    t.assert_equals(seen, 7)
end

g.test_rollout_waits_until_everyone_applies = function()
    local result = rollout.apply(request())

    t.assert_equals(result.phase, 'converge')
    t.assert_equals(result.revision, 8)
    t.assert_equals(result.converged, { 'storage-001-a', 'storage-001-b' })
    t.assert_equals(result.pending, {})
    t.assert_equals(result.err, nil)
end

g.test_nodes_that_already_applied_are_not_waited_for = function()
    applied = { ['storage-001-a'] = 8, ['storage-001-b'] = 8 }

    local waited = false

    local result = rollout.apply(request({
        sleep = function()
            waited = true
        end,
    }))

    t.assert_equals(result.converged, { 'storage-001-a', 'storage-001-b' })
    t.assert_equals(waited, false)
end

g.test_newer_revision_on_a_node_counts_as_applied = function()
    -- Узел успел получить ещё более свежую конфигурацию: ждать его нечего.
    applied = { ['storage-001-a'] = 9, ['storage-001-b'] = 9 }

    t.assert_equals(rollout.apply(request()).pending, {})
end

g.test_lagging_node_is_named = function()
    -- Расхождение обнаружимо: это не повод откатывать кластер, это повод
    -- перечитать конфигурацию на отставшем.
    local result = rollout.apply(request({
        sleep = function(seconds)
            clock.sleep(seconds)
            applied['storage-001-a'] = 8
        end,
    }))

    t.assert_equals(result.phase, 'converge')
    t.assert_equals(result.converged, { 'storage-001-a' })
    t.assert_equals(result.pending, { 'storage-001-b' })
    t.assert_str_contains(result.err, 'применена не всеми')
end

g.test_unreachable_node_explains_itself = function()
    local result = rollout.apply(request({
        applied = function(name)
            if name == 'storage-001-b' then
                return nil, 'нет связи'
            end

            return report(8)
        end,
    }))

    t.assert_equals(result.pending, { 'storage-001-b' })
    t.assert_equals(result.errors['storage-001-b'], 'нет связи')
    t.assert_equals(result.states['storage-001-b'], nil, 'доклада от узла не было')
end

g.test_node_that_failed_to_apply_is_not_converged = function()
    -- Ревизию узел узнаёт, прочитав хранилище, а применяет прочитанное
    -- отдельно и может упасть: занятый порт, недоступный каталог. Такой
    -- узел называет новую ревизию и check_errors — и живёт на прежней
    -- конфигурации. Считать его сошедшимся значит отпустить оператора
    -- от живой беды.
    local result = rollout.apply(request({
        applied = function(name)
            if name == 'storage-001-b' then
                return report(8, 'check_errors', {
                    { type = 'error', message = 'box.cfg() failed: port is busy' },
                    { type = 'warn', message = 'replication lag' },
                })
            end

            return report(8, 'ready', {})
        end,
        sleep = function(seconds)
            clock.sleep(seconds)
        end,
    }))

    t.assert_equals(result.phase, 'converge')
    t.assert_equals(result.converged, { 'storage-001-a' })
    t.assert_equals(result.pending, { 'storage-001-b' })
    t.assert_equals(
        result.errors['storage-001-b'],
        'конфигурация не применена, ядро в состоянии check_errors: '
            .. 'error: box.cfg() failed: port is busy; warn: replication lag'
    )
    t.assert_str_contains(result.err, 'применена не всеми')
end

g.test_failure_without_alerts_is_still_named = function()
    local result = rollout.apply(request({
        applied = function()
            return report(8, 'check_errors')
        end,
        sleep = function(seconds)
            clock.sleep(seconds)
        end,
    }))

    t.assert_equals(
        result.errors['storage-001-a'],
        'конфигурация не применена, ядро в состоянии check_errors'
    )
end

g.test_warnings_do_not_stop_the_convergence = function()
    -- check_warnings — конфигурация применена, и замечания к ней
    -- оператор увидит в докладе узла, а не в списке отказов.
    local warning = { type = 'warn', message = 'health: узел выведен' }

    local result = rollout.apply(request({
        applied = function(name)
            if name == 'storage-001-b' then
                return report(8, 'check_warnings', { warning })
            end

            return report(8, 'ready', {})
        end,
    }))

    t.assert_equals(result.converged, { 'storage-001-a', 'storage-001-b' })
    t.assert_equals(result.errors, {})
    t.assert_equals(result.err, nil)
    t.assert_equals(result.states['storage-001-b'], report(8, 'check_warnings', { warning }))
    t.assert_equals(result.states['storage-001-a'], report(8, 'ready', {}))
end

g.test_node_still_applying_is_waited_for = function()
    -- Узел посреди применения назвал новую ревизию, но ядро ещё не
    -- сказало, чем кончилось: это ни схождение, ни отказ.
    local asked = 0

    local result = rollout.apply(request({
        applied = function()
            asked = asked + 1

            if asked <= 2 then
                return report(8, 'reload_in_progress', {})
            end

            return report(8, 'ready', {})
        end,
        sleep = function(seconds)
            clock.sleep(seconds)
        end,
    }))

    t.assert_equals(result.converged, { 'storage-001-a', 'storage-001-b' })
    t.assert_equals(result.errors, {})
    t.assert_equals(
        asked,
        4,
        'два узла по два опроса: первый круг в пути, второй сошлись'
    )
end

g.test_old_revision_with_a_settled_status_is_just_lagging = function()
    -- Узел на прежней ревизии и ready — не отказ, а отставание: причины
    -- у него нет, он просто ещё не дошёл.
    local result = rollout.apply(request({
        applied = function()
            return report(7, 'ready', {})
        end,
        sleep = function(seconds)
            clock.sleep(seconds)
        end,
    }))

    t.assert_equals(result.pending, { 'storage-001-a', 'storage-001-b' })
    t.assert_equals(result.errors, {})
end

g.test_states_keep_the_last_report_of_each_node = function()
    -- Узел, ответивший со второй попытки, не должен тащить за собой
    -- прежний ответ: в докладе — последнее, что он сказал.
    local asked = 0

    local result = rollout.apply(request({
        applied = function()
            asked = asked + 1

            if asked <= 2 then
                return report(7, 'check_errors', { { type = 'error', message = 'первая беда' } })
            end

            return report(8, 'ready', {})
        end,
        sleep = function(seconds)
            clock.sleep(seconds)
        end,
    }))

    t.assert_equals(result.errors, {})
    t.assert_equals(result.states['storage-001-a'], report(8, 'ready', {}))
    t.assert_equals(result.states['storage-001-b'], report(8, 'ready', {}))
end

g.test_reason_from_the_caller_wins_over_the_report = function()
    -- Отказ связи главнее рассказа узла: он объясняет, почему рассказа
    -- может не быть вовсе, а рассказ при нём — прошлый или неполный.
    local result = rollout.apply(request({
        applied = function()
            return report(8, 'check_errors', {}), 'узел живёт на устаревшем снимке'
        end,
        sleep = function(seconds)
            clock.sleep(seconds)
        end,
    }))

    t.assert_equals(result.errors['storage-001-a'], 'узел живёт на устаревшем снимке')
end

g.test_report_without_a_revision_is_not_converged = function()
    local result = rollout.apply(request({
        applied = function()
            return report(nil, 'ready', {})
        end,
        sleep = function(seconds)
            clock.sleep(seconds)
        end,
    }))

    t.assert_equals(result.pending, { 'storage-001-a', 'storage-001-b' })
end

g.test_stopped_rollout_has_no_reports = function()
    -- До схождения дело не дошло: докладов не спрашивали.
    local result = rollout.apply(request({
        validate = function()
            return false
        end,
    }))

    t.assert_equals(result.states, {})
end

g.test_deadline_is_passed_not_hit_exactly = function()
    -- Часы не обязаны попасть в срок секунда в секунду: между опросами
    -- они перескакивают его, и ждать точного совпадения значит ждать
    -- вечно.
    local result = rollout.apply(request({
        timeout = 3,
        interval = 2,
        applied = function()
            return report(0)
        end,
        sleep = function(seconds)
            clock.sleep(seconds)
        end,
    }))

    t.assert_equals(result.pending, { 'storage-001-a', 'storage-001-b' })
end

g.test_waiting_stops_at_the_deadline = function()
    local slept = 0

    local result = rollout.apply(request({
        timeout = 3,
        interval = 1,
        applied = function()
            return report(0)
        end,
        sleep = function(seconds)
            slept = slept + 1
            clock.sleep(seconds)
        end,
    }))

    t.assert_equals(result.pending, { 'storage-001-a', 'storage-001-b' })
    t.assert_equals(slept, 3)
end

-- ── Узлы спрашиваются веером ─────────────────────────────────────────

g.test_nodes_are_checked_at_once_not_one_after_another = function()
    -- Два узла по десятой доле каждый: по одному фаза заняла бы пятую
    -- долю, разом — десятую.
    local started = require('clock').monotonic()

    rollout.apply(request({
        validate = function()
            fiber.sleep(0.05)

            return true
        end,
    }))

    t.assert_le(require('clock').monotonic() - started, 0.09)
end

g.test_node_that_throws_during_the_check_objects_with_the_error = function()
    local result = rollout.apply(request({
        validate = function(name)
            if name == 'storage-001-b' then
                error('зонд упал', 0)
            end

            return true
        end,
    }))

    t.assert_equals(result.phase, 'prepare')
    t.assert_equals(result.errors['storage-001-b'], 'зонд упал')
    t.assert_equals(result.errors['storage-001-a'], nil)
end

g.test_node_silent_during_the_check_objects_with_the_deadline = function()
    -- Срок проверки — срок схождения: молчащий узел не держит фазу дольше.
    local result = rollout.apply(request({
        timeout = 0.02,
        validate = function(name)
            if name == 'storage-001-b' then
                fiber.sleep(1)
            end

            return true
        end,
    }))

    t.assert_equals(result.phase, 'prepare')
    t.assert_equals(result.errors['storage-001-b'], 'узел не ответил в срок')
end

g.test_node_silent_during_the_refresh_is_recorded_without_stopping = function()
    local result = rollout.apply(request({
        timeout = 0.02,
        refresh = function(name)
            if name == 'storage-001-a' then
                fiber.sleep(1)
            end

            return true
        end,
        sleep = function(seconds)
            clock.sleep(seconds)
        end,
        applied = function()
            return report(8)
        end,
    }))

    t.assert_equals(result.phase, 'converge')
    t.assert_equals(result.pending, {})
    t.assert_equals(result.errors['storage-001-a'], 'узел не ответил в срок')
end

g.test_node_silent_during_the_convergence_is_lagging_with_the_deadline_as_the_reason = function()
    -- Срок захода — пауза между опросами либо остаток срока схождения,
    -- что короче: здесь остаток короче паузы, и молчащий узел не держит
    -- заход дольше остатка, а его причина — срок, а не пустота.
    local started = require('clock').monotonic()
    local result = rollout.apply(request({
        timeout = 0.05,
        interval = 0.1,
        applied = function(name)
            if name == 'storage-001-b' then
                fiber.sleep(1)
            end

            -- Заход съел весь срок схождения: второго захода не будет.
            clock.advance(1)

            return report(8)
        end,
        sleep = function(seconds)
            clock.sleep(seconds)
        end,
    }))

    t.assert_le(require('clock').monotonic() - started, 0.08)
    t.assert_equals(result.converged, { 'storage-001-a' })
    t.assert_equals(result.pending, { 'storage-001-b' })
    t.assert_equals(result.errors['storage-001-b'], 'узел не ответил в срок')
end

g.test_tasks_of_each_phase_are_named_after_the_phase = function()
    -- По имени файбера видно, на какой фазе завис узел.
    local names = {}

    rollout.apply(request({
        validate = function()
            table.insert(names, fiber.self():name())

            return true
        end,
        refresh = function()
            table.insert(names, fiber.self():name())

            return true
        end,
        applied = function()
            table.insert(names, fiber.self():name())

            return report(8)
        end,
    }))

    t.assert_equals(names, {
        'async/rollout/prepare/1',
        'async/rollout/prepare/2',
        'async/rollout/refresh/1',
        'async/rollout/refresh/2',
        'async/rollout/converge/1',
        'async/rollout/converge/2',
    })
end

g.test_node_that_throws_during_the_convergence_explains_itself = function()
    local result = rollout.apply(request({
        applied = function(name)
            if name == 'storage-001-b' then
                error('доклад не собрался', 0)
            end

            return report(8)
        end,
        sleep = function(seconds)
            clock.sleep(seconds)
        end,
    }))

    t.assert_equals(result.pending, { 'storage-001-b' })
    t.assert_equals(result.errors['storage-001-b'], 'доклад не собрался')
end

g.test_the_last_round_after_the_deadline_still_asks_with_the_usual_pause = function()
    -- Срок вышел ровно во сне: заход после него — последний, и узлы
    -- спрашиваются с обычной паузой — не с нулевым сроком и не со сроком
    -- по умолчанию. Часы двойника: сон длится две секунды, какой бы срок
    -- ни просили; третий заход застаёт остаток ровно нулевым, и молчащий
    -- в нём узел отпускается через паузу, а не через пять секунд.
    local rounds = 0
    local started = require('clock').monotonic()

    local result = rollout.apply(request({
        timeout = 4,
        interval = 0.02,
        applied = function(name)
            if name == 'storage-001-a' then
                rounds = rounds + 1

                if rounds == 3 then
                    fiber.sleep(1)
                end
            end

            return report(0)
        end,
        sleep = function()
            clock.advance(2)
        end,
    }))

    t.assert_equals(rounds, 3)
    t.assert_le(require('clock').monotonic() - started, 0.1)
    t.assert_equals(result.pending, { 'storage-001-a', 'storage-001-b' })
    t.assert_equals(result.errors['storage-001-a'], 'узел не ответил в срок')
end

-- ── Правка по кускам и разница ───────────────────────────────────────

g.test_patch_is_built_and_rolled_out = function()
    -- Правка по кускам проходит те же три фазы, что и присланный целиком
    -- текст: пропускающая проверку рано или поздно уронит кластер ровно
    -- тем, от чего проверка и защищает.
    ---@type any
    local written

    local result = rollout.apply(request({
        candidate = nil,
        current = { labels = { zone = 'a' } },
        patch = { { path = 'labels.zone', value = 'b' } },
        write = function(candidate)
            written = candidate

            return 8
        end,
    }))

    t.assert_equals(result.phase, rollout.CONVERGE)
    t.assert_equals(written.labels.zone, 'b')
end

g.test_broken_patch_stops_before_anything_else = function()
    local result = rollout.apply(request({
        candidate = nil,
        current = { labels = { zone = 'a' } },
        patch = { { path = 'labels.zone.deeper', value = 'b' } },
    }))

    t.assert_equals(result.phase, rollout.PATCH)
    t.assert_str_contains(result.err, 'не раздел')
    t.assert_equals(journal, {})
end

g.test_result_tells_what_changed = function()
    local result = rollout.apply(request({
        current = { labels = { zone = 'a' } },
        candidate = { labels = { zone = 'b' } },
    }))

    t.assert_equals(#result.changes, 1)
    t.assert_equals(result.changes[1].path, 'labels.zone')
    t.assert_equals(result.changes[1].kind, 'changed')
end

g.test_refusal_also_tells_what_was_meant = function()
    -- Отказ без разницы оставляет оператора гадать, что он раскатывал.
    local result = rollout.apply(request({
        current = { labels = { zone = 'a' } },
        candidate = { labels = { zone = 'b' } },
        validate = function()
            return false, 'узел возражает'
        end,
    }))

    t.assert_equals(result.phase, rollout.PREPARE)
    t.assert_equals(result.changes[1].path, 'labels.zone')
end

g.test_identical_candidate_is_not_written = function()
    -- Писать новую ревизию ради того же содержимого значит засорять
    -- историю правок и заставлять кластер перечитывать её впустую.
    local result = rollout.apply(request({
        current = { labels = { zone = 'a' } },
        candidate = { labels = { zone = 'a' } },
    }))

    t.assert_equals(result.phase, rollout.UNCHANGED)
    t.assert_equals(result.changes, {})
    t.assert_equals(result.err, nil)
    t.assert_equals(journal, {})
end

g.test_nothing_to_do_means_everyone_is_already_there = function()
    -- Узлы уже на той самой конфигурации: числить их ждущими значит
    -- обещать схождение, которого не будет.
    local result = rollout.apply(request({
        current = { labels = { zone = 'a' } },
        candidate = { labels = { zone = 'a' } },
    }))

    t.assert_equals(result.converged, { 'storage-001-a', 'storage-001-b' })
    t.assert_equals(result.pending, {})
end

g.test_converge_timeout_defaults_to_half_a_minute = function()
    -- Умолчания здесь не украшение: раскатку зовут и без настроек.
    local started = clock.monotonic()

    rollout.apply({
        candidate = { labels = { zone = 'a' } },
        targets = { 'storage-001-a' },
        validate = function()
            return true
        end,
        write = function()
            return 8
        end,
        applied = function()
            return report(0)
        end,
        monotonic = clock.monotonic,
        sleep = function(seconds)
            clock.sleep(seconds)
        end,
    })

    t.assert_equals(clock.monotonic() - started, 30)
end

g.test_real_clock_is_used_when_not_replaced = function()
    -- Часы не подменены: с неработающими раскатка не дойдёт даже до
    -- вычисления срока.
    local result = rollout.apply({
        candidate = { labels = { zone = 'a' } },
        targets = { 'storage-001-a' },
        validate = function()
            return true
        end,
        write = function()
            return 8
        end,
        applied = function()
            return report(8)
        end,
    })

    t.assert_equals(result.pending, {})
    t.assert_equals(result.converged, { 'storage-001-a' })
end

-- ── Просьба перечитать ───────────────────────────────────────────────

g.test_nodes_are_asked_to_reread_after_the_write = function()
    -- В Community за хранилищем никто не следит: источник читает его при
    -- старте, и без просьбы узел останется на прежней конфигурации
    -- сколько угодно долго — запись прошла, а кластер о ней не знает.
    local result = rollout.apply(request({
        refresh = function(name)
            table.insert(journal, ('перечитывание %s'):format(name))

            return true
        end,
    }))

    t.assert_equals(result.phase, 'converge')
    t.assert_equals(journal, {
        'проверка storage-001-a',
        'проверка storage-001-b',
        'запись',
        'перечитывание storage-001-a',
        'перечитывание storage-001-b',
    })
end

g.test_refusal_to_reread_does_not_stop_the_rollout = function()
    -- Перечитывание — просьба, а не команда: узел вправе подхватить
    -- конфигурацию сам, пока мы ждём.
    local result = rollout.apply(request({
        refresh = function(name)
            return name ~= 'storage-001-a', 'узел не отвечает'
        end,
    }))

    t.assert_equals(result.pending, {})
    t.assert_str_contains(result.errors['storage-001-a'], 'не отвечает')
    t.assert_equals(result.err, nil, 'все сошлись, хотя один не ответил на просьбу')
end

g.test_refusal_without_a_reason_is_still_recorded = function()
    local result = rollout.apply(request({
        refresh = function()
            return false
        end,
    }))

    t.assert_str_contains(result.errors['storage-001-a'], 'не объяснил отказ')
end

g.test_report_from_the_node_wins_over_the_refusal = function()
    -- Если узел и не ответил на просьбу, и не сошёлся, важнее вторая
    -- причина: она объясняет, почему раскатка не закончилась.
    applied = { ['storage-001-a'] = 0, ['storage-001-b'] = 0 }

    local result = rollout.apply(request({
        refresh = function()
            return false, 'просьба не дошла'
        end,
        applied = function(name)
            return nil, ('узел %s молчит'):format(name)
        end,
        sleep = function(seconds)
            clock.sleep(seconds)
        end,
    }))

    t.assert_str_contains(result.errors['storage-001-a'], 'молчит')
end

g.test_rollout_without_a_refresh_step_asks_nobody = function()
    -- В Enterprise встроенный источник сам замечает новую ревизию:
    -- просить его незачем, и шага просто нет.
    rollout.apply(request())

    for _, line in ipairs(journal) do
        t.assert_not_str_contains(line, 'перечитывание')
    end
end

-- ── Сверка с действующей конфигурацией ───────────────────────────────

--- Конфигурация с одним узлом в одном репликасете.
---@param instances table<string, table>
---@return table
local function topology_of(instances)
    return { groups = { cores = { replicasets = { ['storage-001'] = { instances = instances } } } } }
end

g.test_edit_that_erases_a_node_never_reaches_it = function()
    -- Правка, вычёркивающая узел, синтаксически безупречна: узлы приняли
    -- бы её охотно. Сломается от неё кластер, а не конфигурация.
    local result = rollout.apply(request({
        current = topology_of({ ['storage-001-a'] = {}, ['storage-001-b'] = {} }),
        candidate = topology_of({ ['storage-001-a'] = {} }),
    }))

    t.assert_equals(result.phase, 'topology')
    t.assert_equals(result.revision, nil)
    t.assert_str_contains(result.err, 'ломает топологию')
    t.assert_str_contains(result.errors['storage-001-b'], 'storage-001-b')
    t.assert_equals(journal, {}, 'до узлов дело не дошло')
end

g.test_intentional_removal_is_allowed = function()
    -- Узлы выводят из состава намеренно: об этом говорят заранее, и тогда
    -- правка проходит.
    local result = rollout.apply(request({
        current = topology_of({ ['storage-001-a'] = {}, ['storage-001-b'] = {} }),
        candidate = topology_of({ ['storage-001-a'] = {} }),
        removing = { 'storage-001-b' },
    }))

    t.assert_equals(result.phase, 'converge')
end

g.test_edit_that_erases_the_applying_node_is_refused = function()
    -- Узел, применяющий правку, которая его вычёркивает, перестал бы быть
    -- частью кластера ровно в тот миг, когда её применил.
    local result = rollout.apply(request({
        current = topology_of({ ['storage-001-a'] = {}, ['storage-001-b'] = {} }),
        candidate = topology_of({ ['storage-001-a'] = {} }),
        removing = { 'storage-001-b' },
        instance = 'storage-001-b',
    }))

    t.assert_equals(result.phase, 'topology')
    t.assert_str_contains(result.errors['storage-001-b'], 'вычёркивает применяющий узел')
end

g.test_edit_without_a_previous_configuration_is_not_compared = function()
    -- Первая запись сравнивать не с чем, и это не повод отказывать.
    local result = rollout.apply(request({
        current = nil,
        candidate = topology_of({ ['storage-001-a'] = {} }),
    }))

    t.assert_equals(result.phase, 'converge')
end
