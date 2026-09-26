--- Тесты правки конфигурации по кускам. Модуль чистый: конфигурация
--- подаётся таблицей, и проверяется, что получается из неё и из правок.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.config.patch')

local MODULES = helper.modules({ 'tnt.config.patch' })

---@type any
local patch

--- Конфигурация из двух узлов и пары настроек.
---@return table
local function cluster()
    return {
        groups = {
            cores = {
                replicasets = {
                    ['lead-001'] = {
                        instances = {
                            ['lead-001-a'] = { iproto = { listen = '127.0.0.1:3361' } },
                            ['lead-001-b'] = { iproto = { listen = '127.0.0.1:3362' } },
                        },
                    },
                },
            },
        },
        labels = { zone = 'a' },
    }
end

--- Узлы репликасета после правки.
---@param config table
---@return table
local function instances(config)
    return config.groups.cores.replicasets['lead-001'].instances
end

g.before_each(function()
    patch = helper.load(MODULES, 'tnt.config.patch')
end)

g.after_each(function()
    helper.unload(MODULES)
end)

-- ── Путь ─────────────────────────────────────────────────────────────

g.test_path_is_split_by_dots = function()
    t.assert_equals(patch.split('groups.cores.replicasets'), { 'groups', 'cores', 'replicasets' })
end

g.test_path_can_be_given_as_a_list = function()
    -- Списком путь приходит от того, кто собирает его сам: склеивать имена
    -- в строку ради обратного разбора незачем.
    t.assert_equals(patch.split({ 'groups', 'cores' }), { 'groups', 'cores' })
end

g.test_empty_section_name_is_a_typo = function()
    -- Понимать `groups..cores` как `groups.cores` значит угадывать.
    local names, err = patch.split('groups..cores')

    t.assert_equals(names, nil)
    t.assert_str_contains(err, 'пустым именем')
end

g.test_trailing_dot_is_a_typo_too = function()
    t.assert_str_contains(select(2, patch.split('groups.')), 'пустым именем')
end

g.test_missing_path_is_refused = function()
    -- Отказ называет причину: «путь не назван» и «пустое имя раздела» —
    -- разные опечатки, и чинятся они по-разному.
    for _, path in ipairs({ '', {} }) do
        t.assert_equals(select(2, patch.split(path)), 'путь не назван')
    end

    t.assert_equals(select(2, patch.split(nil)), 'путь не назван')
    t.assert_str_contains(select(2, patch.split({ 'groups', '' })), 'пустых среди них не бывает')
end

-- ── Чтение ───────────────────────────────────────────────────────────

g.test_value_is_read_by_path = function()
    t.assert_equals(patch.get(cluster(), 'labels.zone'), 'a')
end

g.test_absent_section_reads_as_nothing = function()
    local value, err = patch.get(cluster(), 'labels.rack')

    t.assert_equals(value, nil)
    t.assert_equals(err, nil)
end

g.test_path_through_a_value_is_refused_on_reading = function()
    -- Отказ называет и весь путь, и то место, на котором спуск кончился:
    -- без второго оператор ищет опечатку во всей строке.
    local value, err = patch.get(cluster(), 'labels.zone.deeper')

    t.assert_equals(value, nil)
    t.assert_equals(
        err,
        'путь labels.zone.deeper упирается в значение: labels.zone — не раздел'
    )
end

g.test_broken_path_is_refused_on_reading = function()
    t.assert_str_contains(select(2, patch.get(cluster(), 'labels..zone')), 'пустым именем')
end

-- ── Правка ───────────────────────────────────────────────────────────

g.test_value_is_replaced_by_path = function()
    local candidate = patch.apply(cluster(), { { path = 'labels.zone', value = 'b' } })

    t.assert_equals(candidate.labels.zone, 'b')
end

g.test_section_is_added_where_there_was_none = function()
    local candidate = patch.apply(cluster(), {
        {
            path = 'groups.cores.replicasets.lead-001.instances.lead-001-c',
            value = { iproto = { listen = '127.0.0.1:3363' } },
        },
    })

    t.assert_equals(instances(candidate)['lead-001-c'].iproto.listen, '127.0.0.1:3363')
end

g.test_missing_levels_are_created = function()
    local candidate = patch.apply(cluster(), { { path = 'labels.rack.number', value = 7 } })

    t.assert_equals(candidate.labels.rack.number, 7)
end

g.test_section_is_removed_by_a_separate_mark = function()
    local candidate = patch.apply(cluster(), {
        { path = 'groups.cores.replicasets.lead-001.instances.lead-001-b', remove = true },
    })

    t.assert_equals(instances(candidate)['lead-001-b'], nil)
    t.assert_not_equals(instances(candidate)['lead-001-a'], nil)
end

g.test_removing_what_is_not_there_changes_nothing = function()
    local candidate = patch.apply(cluster(), { { path = 'sharding.roles.router', remove = true } })

    t.assert_equals(candidate.sharding, nil)
end

g.test_forgotten_value_does_not_delete_anything = function()
    -- В Lua `nil` в таблице неотличим от отсутствующего ключа: правка,
    -- в которой значение забыли, молча стёрла бы раздел.
    local candidate, err = patch.apply(cluster(), { { path = 'labels.zone' } })

    t.assert_equals(candidate, nil)
    t.assert_str_contains(err, 'значение не названо')
end

g.test_explicit_null_is_a_value_and_not_an_omission = function()
    -- `box.NULL` равен `nil` по правилам языка, но означает другое: раздел
    -- объявлен пустым, а не забыт.
    local candidate = patch.apply(cluster(), { { path = 'labels.zone', value = box.NULL } })

    t.assert_equals(candidate.labels.zone, box.NULL)
end

g.test_changes_are_applied_in_order = function()
    local candidate = patch.apply(cluster(), {
        { path = 'labels.zone', value = 'b' },
        { path = 'labels.zone', value = 'c' },
    })

    t.assert_equals(candidate.labels.zone, 'c')
end

g.test_current_configuration_is_not_touched = function()
    -- Кандидат собирается на копии: правка не должна менять то, что
    -- применено, ни при успехе, ни при отказе.
    local current = cluster()

    patch.apply(current, { { path = 'labels.zone', value = 'b' } })

    t.assert_equals(current.labels.zone, 'a')
end

g.test_value_is_copied_and_not_shared = function()
    -- Правка вправе прийти из чужой таблицы, и кандидат, разделяющий
    -- с ней память, поменяется вместе с ней.
    local value = { number = 7 }
    local candidate = patch.apply(cluster(), { { path = 'labels.rack', value = value } })

    value.number = 8

    t.assert_equals(candidate.labels.rack.number, 7)
end

g.test_half_applied_candidate_does_not_happen = function()
    local candidate, err = patch.apply(cluster(), {
        { path = 'labels.zone', value = 'b' },
        { path = 'labels.zone.deeper', value = 'c' },
    })

    t.assert_equals(candidate, nil)
    t.assert_str_contains(err, 'правка 2: путь labels.zone.deeper')
end

g.test_path_through_a_value_is_refused = function()
    local candidate, err = patch.apply(cluster(), { { path = 'labels.zone.deeper', value = 1 } })

    t.assert_equals(candidate, nil)
    t.assert_equals(
        err,
        'правка 1: путь labels.zone.deeper упирается в значение: labels.zone — не раздел'
    )
end

g.test_broken_path_is_refused = function()
    local candidate, err = patch.apply(cluster(), { { path = 'labels..zone', value = 1 } })

    t.assert_equals(candidate, nil)
    t.assert_str_contains(err, 'пустым именем')
end

g.test_change_must_be_a_table = function()
    local candidate, err = patch.apply(cluster(), { 'labels.zone' })

    t.assert_equals(candidate, nil)
    t.assert_str_contains(err, 'таблицей')
end

g.test_nothing_to_patch_is_refused = function()
    t.assert_str_contains(
        select(2, patch.apply(nil, { { path = 'labels.zone', value = 'b' } })),
        'действующая конфигурация не прочитана'
    )

    t.assert_equals(select(2, patch.apply(cluster(), {})), 'правок не названо')
    t.assert_equals(select(2, patch.apply(cluster(), nil)), 'правок не названо')
end
