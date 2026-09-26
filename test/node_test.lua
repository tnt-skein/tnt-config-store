--- Тесты узловой части конфигурации: что узел отвечает о кандидате
--- и о том, что у него применено.

local t = require('luatest')

local helper = dofile('test/helper.lua')

--- Узловая часть и то, что она берёт: внешние зависимости, списки, контекст
--- и соседа по пакету. Сосед — тоже из исходников: установленная копия
--- в .rocks идёт раньше package.path и подсунула бы вчерашнюю.
local MODULES = helper.modules({ 'tnt.config.file', 'tnt.config.node' })

local g = t.group('tnt.config.node')

---@type any
local node

--- Что отвечает разбор конфигурации.
---@type any
local schema

--- Что отвечает модуль конфигурации узла.
---@type any
local config

--- Как зовут узел.
---@type string|nil
local instance

g.before_each(function()
    node = helper.load(MODULES, 'tnt.config.node')

    instance = 'storage-001-a'

    schema = {
        validate = function() end,
        methods = {
            find_instance = function(_, candidate, name)
                local instances = candidate.instances or {}

                return instances[name]
            end,
        },
    }

    -- Сведения об источниках ядро складывает по имени источника: так
    -- отвечает Tarantool 3.8, и проверка повторяет его, а не догадку.
    config = {
        info = function()
            return {
                status = 'ready',
                meta = { active = { etcd = { revision = 42 } }, last = { etcd = { revision = 43 } } },
                alerts = {},
            }
        end,
    }

    node._set_source({
        schema = function()
            return schema
        end,
        config = function()
            return config
        end,
        instance_name = function()
            return instance
        end,
    })
end)

g.after_each(function()
    node._set_source(nil)
    helper.unload(MODULES)
end)

--- Кандидат, в котором есть указанные узлы.
---@param names string[]
---@return table
local function candidate_with(names)
    local instances = {}

    for _, name in ipairs(names) do
        instances[name] = {}
    end

    return { instances = instances }
end

-- ── Проверка кандидата ───────────────────────────────────────────────

g.test_valid_candidate_is_accepted = function()
    local check = node.check(candidate_with({ 'storage-001-a', 'storage-001-b' }))

    t.assert_equals(check.ok, true)
    t.assert_equals(check.err, nil)
    t.assert_equals(check.instance, 'storage-001-a')
    t.assert_equals(check.declared, true)
    t.assert_equals(check.warnings, {})
end

g.test_broken_candidate_is_refused_with_the_kernel_reason = function()
    -- Проверка идёт тем же разбором, которым ядро читает конфигурацию
    -- при старте: своя мерка расходилась бы с настоящей ровно в тех
    -- случаях, ради которых проверка и заводится.
    schema.validate = function()
        error('[cluster_config] groups.core: Unexpected field "опечатка"')
    end

    local check = node.check(candidate_with({ 'storage-001-a' }))

    t.assert_equals(check.ok, false)
    t.assert_str_contains(check.err, 'Unexpected field')
    t.assert_equals(check.declared, false, 'до поиска себя дело не дошло')
end

g.test_candidate_that_is_not_a_table_is_refused = function()
    -- Кандидат приходит по сети и вправе оказаться чем угодно.
    local check = node.check('строка вместо конфигурации')

    t.assert_equals(check.ok, false)
    t.assert_str_contains(check.err, 'должна быть таблицей')
    t.assert_equals(check.declared, false, 'себя в такой конфигурации узел не нашёл')
end

g.test_node_missing_from_the_candidate_warns_but_does_not_refuse = function()
    -- Узлы выводят из состава намеренно, и отвергать за это нельзя.
    -- Но узел, которого нет в новой конфигурации, перестанет быть частью
    -- кластера, и знать об этом надо до записи, а не после.
    local check = node.check(candidate_with({ 'storage-001-b' }))

    t.assert_equals(check.ok, true)
    t.assert_equals(check.declared, false)
    t.assert_str_contains(check.warnings[1], 'перестанет быть частью кластера')
end

g.test_unnamed_node_is_not_looked_for = function()
    -- У инстанса вне кластера имени нет вовсе: искать его в кандидате
    -- бессмысленно, и отвечать «тебя тут нет» — тоже.
    instance = nil

    local check = node.check(candidate_with({ 'storage-001-a' }))

    t.assert_equals(check.ok, true)
    t.assert_equals(check.declared, false)
    t.assert_str_contains(check.warnings[1], 'nil')
end

-- ── Применённая конфигурация ─────────────────────────────────────────

g.test_applied_revision_is_reported = function()
    -- По ревизии раскатка видит, что узел дошёл до той же конфигурации,
    -- что записана в хранилище: своего признака у ядра нет. Берётся
    -- применённая (active), а не последняя прочитанная (last).
    local applied = node.applied()

    t.assert_equals(applied.status, 'ready')
    t.assert_equals(applied.revision, 42)
    t.assert_equals(applied.alerts, {})
    t.assert_equals(applied.err, nil)
end

g.test_revision_is_asked_of_the_kernel_second_generation_answer = function()
    -- Первое поколение ответа не различает прочитанное и применённое.
    local versions = {}

    config.info = function(_, version)
        table.insert(versions, version)

        return { status = 'ready', meta = {}, alerts = {} }
    end

    node.applied()

    t.assert_equals(versions, { 'v2' })
end

g.test_revision_is_found_under_the_source_name = function()
    -- Ядро кладёт сведения источника под его именем, и имя это ему
    -- безразлично: подойдёт любой источник, назвавший ревизию.
    config.info = function()
        return {
            status = 'ready',
            meta = { active = { storage = { revision = '15' } } },
            alerts = {},
        }
    end

    t.assert_equals(node.applied().revision, 15)
end

g.test_sources_without_a_revision_are_skipped = function()
    -- Источники env и file ревизии не знают, а место в сведениях
    -- занимать могут; строка вместо таблицы тоже не ревизия.
    config.info = function()
        return {
            status = 'ready',
            meta = {
                active = {
                    env = 'нет сведений',
                    file = { path = '/etc/config.yaml' },
                    zeta = { revision = 9 },
                },
            },
            alerts = {},
        }
    end

    t.assert_equals(node.applied().revision, 9)
end

g.test_first_source_by_name_wins = function()
    -- Двух источников с ревизией в одном узле не бывает, но ответ и на
    -- такой случай должен быть один и тот же от вызова к вызову.
    config.info = function()
        return {
            status = 'ready',
            meta = { active = { etcd = { revision = 5 }, alpha = { revision = 4 } } },
            alerts = {},
        }
    end

    t.assert_equals(node.applied().revision, 4)
end

g.test_revision_before_the_first_apply_is_unknown = function()
    -- До первого удачного применения ядро сведений о применённом не
    -- держит вовсе: поле active отсутствует, а не пусто.
    config.info = function()
        return {
            status = 'startup_in_progress',
            meta = { last = { etcd = { revision = 7 } } },
            alerts = {},
        }
    end

    local applied = node.applied()

    t.assert_equals(applied.revision, nil)
    t.assert_equals(applied.status, 'startup_in_progress')
end

g.test_alerts_are_reported_with_their_weight = function()
    -- Замечания отдаются целиком: раскатке нужно назвать, почему узел
    -- не применил конфигурацию, а не сказать «есть две беды». Отметка
    -- времени и прочее ядру нужное отбрасывается.
    config.info = function()
        return {
            status = 'check_errors',
            meta = { active = { etcd = { revision = 7 } } },
            alerts = {
                { type = 'error', message = 'box.cfg() failed', timestamp = 1 },
                { type = 'warn', message = 'replication lag', timestamp = 2 },
            },
        }
    end

    local applied = node.applied()

    t.assert_equals(applied.status, 'check_errors')
    t.assert_equals(applied.alerts, {
        { type = 'error', message = 'box.cfg() failed' },
        { type = 'warn', message = 'replication lag' },
    })
end

g.test_alerts_missing_from_the_answer_are_an_empty_list = function()
    config.info = function()
        return { status = 'ready', meta = {} }
    end

    t.assert_equals(node.applied().alerts, {})
end

g.test_node_outside_the_declarative_config_says_so = function()
    node._set_source({
        config = function()
            error('module config not found')
        end,
    })

    local applied = node.applied()

    t.assert_equals(applied.revision, nil)
    t.assert_equals(
        applied.alerts,
        {},
        'замечаний нет, потому что их некому выставить'
    )
    t.assert_str_contains(applied.err, 'вне декларативной конфигурации')
end

g.test_config_that_refuses_to_report_is_not_a_crash = function()
    -- Старое ядро не знает второго поколения ответа: это не отказ узла.
    config.info = function()
        error('unknown version v2')
    end

    local applied = node.applied()

    t.assert_equals(applied.revision, nil)
    t.assert_equals(applied.alerts, {})
    t.assert_str_contains(applied.err, 'unknown version')
end

g.test_local_configuration_has_no_revision = function()
    -- Конфигурация из файла ревизии не имеет вовсе: это законно, и
    -- раскатка по такому узлу просто не сойдётся.
    config.info = function()
        return { status = 'ready', meta = {}, alerts = {} }
    end

    local applied = node.applied()

    t.assert_equals(applied.revision, nil)
    t.assert_equals(applied.status, 'ready')
end

-- ── Публикация ───────────────────────────────────────────────────────

g.test_functions_are_published = function()
    node.publish()

    t.assert_type(rawget(_G, 'config_check'), 'function')
    t.assert_type(rawget(_G, 'config_applied'), 'function')
    t.assert_type(rawget(_G, 'config_write'), 'function')

    t.assert_equals(rawget(_G, 'config_check')(candidate_with({ 'storage-001-a' })).ok, true)
    t.assert_equals(rawget(_G, 'config_applied')().revision, 42)
    -- Файл узлу не назначен: публикация есть, а писать некуда.
    t.assert_equals(rawget(_G, 'config_write')('groups: {}').ok, false)

    rawset(_G, 'config_check', nil)
    rawset(_G, 'config_applied', nil)
    rawset(_G, 'config_write', nil)
end

g.test_published_functions_take_the_carrier_of_the_rollout_off = function()
    local context = helper.module('tnt.context')
    local carrier = { ['x-request-id'] = 'r-7' }
    local seen = {}

    -- Имя узла и модуль конфигурации спрашиваются внутри тела: по ним
    -- видно, в какой области оно идёт.
    node._set_source({
        schema = function()
            return schema
        end,
        config = function()
            table.insert(seen, context.get('request_id'))

            return config
        end,
        instance_name = function()
            table.insert(seen, context.get('request_id'))

            return instance
        end,
    })

    node.publish()

    local checked = rawget(_G, 'config_check')(candidate_with({ 'storage-001-a' }), carrier)
    local refused = rawget(_G, 'config_check')(carrier)

    t.assert_equals({ checked.ok, checked.declared }, { true, true })
    -- Перенос — единственный аргумент: кандидата нет вовсе.
    t.assert_equals(refused.err, 'конфигурация должна быть таблицей')
    t.assert_equals(rawget(_G, 'config_applied')(carrier).revision, 42)
    t.assert_equals(rawget(_G, 'config_write')('groups: {}', carrier).ok, false)
    t.assert_equals(seen, { 'r-7', 'r-7', 'r-7' })
    t.assert_equals(context.get('request_id'), nil)

    rawset(_G, 'config_check', nil)
    rawset(_G, 'config_applied', nil)
    rawset(_G, 'config_write', nil)
end

g.test_names_can_be_given = function()
    node.publish({ check = 'my_check', applied = 'my_applied', write = 'my_write' })

    t.assert_type(rawget(_G, 'my_check'), 'function')
    t.assert_type(rawget(_G, 'my_applied'), 'function')
    t.assert_type(rawget(_G, 'my_write'), 'function')
    t.assert_equals(rawget(_G, 'config_check'), nil)

    rawset(_G, 'my_check', nil)
    rawset(_G, 'my_applied', nil)
    rawset(_G, 'my_write', nil)
end

-- ── Настоящее ядро ───────────────────────────────────────────────────

g.test_real_schema_catches_an_unknown_key = function()
    -- Проверка берётся у ядра, а не пишется своя: подмена в остальных
    -- проверках скрывает как раз этот вызов, а разойтись с настоящим
    -- разбором значит пропустить то, ради чего проверка и нужна.
    node._set_source({
        instance_name = function()
            return 'core-001-a'
        end,
    })

    local yaml = require('yaml')
    local broken = yaml.decode(table.concat({
        'groups:',
        '  core:',
        '    replicasets:',
        '      core-001:',
        '        instances:',
        '          core-001-a: { опечатка: 1 }',
    }, '\n'))

    local check = node.check(broken)

    t.assert_equals(check.ok, false)
    t.assert_str_contains(check.err, 'Unexpected field')
end

g.test_real_schema_finds_the_node_in_a_valid_config = function()
    node._set_source({
        instance_name = function()
            return 'core-001-a'
        end,
    })

    local yaml = require('yaml')
    local good = yaml.decode(table.concat({
        'groups:',
        '  core:',
        '    replicasets:',
        '      core-001:',
        '        instances:',
        '          core-001-a: {}',
        '          core-001-b: {}',
    }, '\n'))

    local check = node.check(good)

    t.assert_equals(check.ok, true, tostring(check.err))
    t.assert_equals(check.declared, true)

    -- И не находит того, кого там нет.
    node._set_source({
        instance_name = function()
            return 'core-001-z'
        end,
    })

    t.assert_equals(node.check(good).declared, false)
end

g.test_name_is_asked_of_the_instance_itself = function()
    -- Имя узла берётся у box.info: конфигурация говорит, что узлу велено,
    -- а box.info — кто он на самом деле.
    node._set_source(nil)

    local saved = rawget(_G, 'box')

    rawset(_G, 'box', { info = { name = 'lead-001-c' } })

    local ok, check = pcall(node.check, { groups = {} })

    rawset(_G, 'box', saved)

    t.assert_equals(ok, true, tostring(check))
    t.assert_equals(check.instance, 'lead-001-c')
end

g.test_config_module_is_taken_from_the_instance = function()
    -- Вне кластера, собранного по схеме, модуля config нет вовсе, и это
    -- законный ответ, а не отказ узла.
    node._set_source(nil)

    local applied = node.applied()

    t.assert_type(applied, 'table')
    t.assert_equals(applied.revision, nil)
end

-- ── Поставщик ревизии ────────────────────────────────────────────────

g.test_revision_can_come_from_the_source_itself = function()
    -- Источник, который ядру ничего не рассказал, для него безымянен,
    -- и ревизию знает лишь он сам.
    config.info = function()
        return { status = 'ready', meta = {}, alerts = {} }
    end

    node.configure({
        revision = function()
            return 77
        end,
    })

    local applied = node.applied()

    t.assert_equals(applied.revision, 77)
    t.assert_equals(applied.status, 'ready')

    -- Причины нет: поставщик ответил без оговорок. Идиома «а and б or в»
    -- на этом месте отдавала бы саму ревизию как причину — живой запуск
    -- это и показал.
    t.assert_equals(applied.err, nil)

    node.configure()
end

g.test_provider_that_knows_nothing_is_honest_about_it = function()
    node.configure({
        revision = function()
            return nil, 'источник ещё не читал хранилище'
        end,
    })

    local applied = node.applied()

    t.assert_equals(applied.revision, nil)
    t.assert_str_contains(applied.err, 'ещё не читал')

    node.configure()
end

g.test_provider_that_raises_does_not_break_the_answer = function()
    -- Поставщика задаёт приложение, и падать вместе с ним узел не должен:
    -- ответ о конфигурации нужен и тогда, когда с источником беда.
    node.configure({
        revision = function()
            error('источник недоступен')
        end,
    })

    local applied = node.applied()

    t.assert_equals(applied.revision, nil)
    t.assert_str_contains(applied.err, 'источник недоступен')

    node.configure()
end

g.test_kernel_revision_is_used_without_a_provider = function()
    t.assert_equals(node.applied().revision, 42)
end

-- ── Запись файла конфигурации ────────────────────────────────────────

g.test_node_without_a_path_writes_nothing = function()
    -- Право позвать эту функцию по сети означало бы право переписать
    -- на узле любой файл, поэтому путь приходит от приложения, а не
    -- аргументом. Не назначен — значит писать некуда.
    node.configure({})

    local result = node.write('groups: {}')

    t.assert_equals(result.ok, false)
    t.assert_str_contains(result.err, 'не назначен файл')
end

g.test_configured_node_writes_its_own_file = function()
    local fio = require('fio')
    local workdir = fio.tempdir()
    local path = fio.pathjoin(workdir, 'config.yaml')

    node.configure({ path = path })

    local result = node.write('groups: {}')

    t.assert_equals(result.ok, true)
    t.assert_equals(result.path, path)

    local written = fio.open(path, { 'O_RDONLY' })
    local text = written:read()
    written:close()
    fio.rmtree(workdir)

    t.assert_equals(text, 'groups: {}')
end

g.test_failed_write_is_reported_as_it_is = function()
    node.configure({ path = '/нет/такого/каталога/config.yaml' })

    local result = node.write('groups: {}')

    t.assert_equals(result.ok, false)
    t.assert_str_contains(result.err, 'не создан')
end
