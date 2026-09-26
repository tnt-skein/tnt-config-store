--- Тесты проверки правок конфигурации. Модуль чистый: документы подаются
--- таблицами, кластер не нужен.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.config.topology')

local MODULES = helper.modules({ 'tnt.config.topology' })

---@type any
local topology

g.before_each(function()
    topology = helper.load(MODULES, 'tnt.config.topology')
end)

g.after_each(function()
    helper.unload(MODULES)
end)

--- Конфигурация кластера из описания «репликасет → узлы».
---@param layout table<string, table<string, string|nil>> Репликасет → узел → адрес
---@param group string|nil Имя группы
---@return table
local function config(layout, group)
    local replicasets = {}

    for replicaset_name, members in pairs(layout) do
        local instances = {}

        for name, uri in pairs(members) do
            instances[name] = { iproto = { listen = { { uri = uri } } } }
        end

        replicasets[replicaset_name] = { instances = instances }
    end

    return { groups = { [group or 'storages'] = { replicasets = replicasets } } }
end

--- Возражение указанного вида.
---@param objections table[]
---@param kind string
---@return table
local function of(objections, kind)
    for _, objection in ipairs(objections) do
        if objection.kind == kind then
            return objection
        end
    end

    return {}
end

g.test_unchanged_configuration_is_acceptable = function()
    local current = config({ ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301' } })

    t.assert_equals(topology.acceptable(current, current), true)
end

g.test_added_node_is_acceptable = function()
    local current = config({ ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301' } })
    local candidate = config({
        ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301', ['storage-001-b'] = '127.0.0.1:3302' },
    })

    t.assert_equals(topology.acceptable(current, candidate), true)
end

g.test_added_replicaset_is_acceptable = function()
    local current = config({ ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301' } })
    local candidate = config({
        ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301' },
        ['storage-002'] = { ['storage-002-a'] = '127.0.0.1:3302' },
    })

    t.assert_equals(topology.acceptable(current, candidate), true)
end

g.test_removed_node_is_refused = function()
    -- Узел, вычеркнутый из конфигурации, не исчезает из кластера: он
    -- остаётся в системном спейсе и однажды возвращается с данными,
    -- о которых никто не знал.
    local current = config({
        ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301', ['storage-001-b'] = '127.0.0.1:3302' },
    })
    local candidate = config({ ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301' } })

    local ok, objections = topology.acceptable(current, candidate)

    t.assert_equals(ok, false)
    t.assert_equals(of(objections, 'removed').target, 'storage-001-b')
    t.assert_str_contains(of(objections, 'removed').message, 'явно')
end

g.test_declared_removal_is_acceptable = function()
    -- Удаление объявлено: оператор знает, что делает, и берёт на себя
    -- уборку в системном спейсе.
    local current = config({
        ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301', ['storage-001-b'] = '127.0.0.1:3302' },
    })
    local candidate = config({ ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301' } })

    t.assert_equals(topology.acceptable(current, candidate, { removing = { 'storage-001-b' } }), true)
end

g.test_moved_node_is_refused = function()
    -- Узел придёт в новый репликасет с чужими данными.
    local current = config({
        ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301' },
        ['storage-002'] = { ['storage-002-a'] = '127.0.0.1:3302' },
    })
    local candidate = config({
        ['storage-001'] = {},
        ['storage-002'] = { ['storage-002-a'] = '127.0.0.1:3302', ['storage-001-a'] = '127.0.0.1:3301' },
    })

    local ok, objections = topology.acceptable(current, candidate)

    t.assert_equals(ok, false)
    t.assert_equals(of(objections, 'moved').target, 'storage-001-a')
    t.assert_str_contains(of(objections, 'moved').message, 'storage-002')
end

g.test_regrouped_replicaset_is_refused = function()
    local current = config({ ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301' } }, 'storages')
    local candidate = config({ ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301' } }, 'routers')

    local ok, objections = topology.acceptable(current, candidate)

    t.assert_equals(ok, false)
    t.assert_equals(of(objections, 'regrouped').target, 'storage-001')
end

g.test_duplicate_address_is_refused = function()
    -- Два узла по одному адресу: один из них недостижим, и выясняется это
    -- в первый же обход кластера.
    local current = config({ ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301' } })
    local candidate = config({
        ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301', ['storage-001-b'] = '127.0.0.1:3301' },
    })

    local ok, objections = topology.acceptable(current, candidate)

    t.assert_equals(ok, false)
    t.assert_str_contains(of(objections, 'address_taken').message, '127.0.0.1:3301')
end

g.test_nodes_without_addresses_do_not_collide = function()
    -- Адрес объявлен не у всех: узлы без него не считаются занявшими
    -- один и тот же.
    local candidate = {
        groups = {
            storages = {
                replicasets = {
                    ['storage-001'] = { instances = { ['storage-001-a'] = {}, ['storage-001-b'] = {} } },
                },
            },
        },
    }

    t.assert_equals(topology.acceptable(candidate, candidate), true)
end

g.test_self_removal_is_refused = function()
    -- Узел, вычеркнувший сам себя, применяет правку последний раз в жизни.
    local current = config({
        ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301', ['storage-001-b'] = '127.0.0.1:3302' },
    })
    local candidate = config({ ['storage-001'] = { ['storage-001-b'] = '127.0.0.1:3302' } })

    local ok, objections = topology.acceptable(current, candidate, {
        self_name = 'storage-001-a',
        removing = { 'storage-001-a' },
    })

    t.assert_equals(ok, false)
    t.assert_equals(of(objections, 'self_removed').target, 'storage-001-a')
end

g.test_removing_someone_else_is_fine_for_us = function()
    local current = config({
        ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301', ['storage-001-b'] = '127.0.0.1:3302' },
    })
    local candidate = config({ ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301' } })

    t.assert_equals(
        topology.acceptable(current, candidate, { self_name = 'storage-001-a', removing = { 'storage-001-b' } }),
        true
    )
end

g.test_objections_come_all_at_once = function()
    -- Оператор должен увидеть всё сразу, а не чинить по одному за подход.
    local current = config({
        ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301', ['storage-001-b'] = '127.0.0.1:3302' },
        ['storage-002'] = { ['storage-002-a'] = '127.0.0.1:3303' },
    })
    local candidate = config({
        ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301' },
        ['storage-002'] = { ['storage-002-a'] = '127.0.0.1:3301' },
    })

    local _, objections = topology.acceptable(current, candidate)

    t.assert_equals(#objections, 2)
end

g.test_empty_configuration_is_survived = function()
    -- Кластер, которого ещё нет: первая конфигурация сравнивается с пустотой.
    local candidate = config({ ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301' } })

    t.assert_equals(topology.acceptable(nil, candidate), true)
    t.assert_equals(topology.instances(nil), {})
end

g.test_instances_are_flattened = function()
    local flattened = topology.instances(config({ ['storage-001'] = { ['storage-001-a'] = '127.0.0.1:3301' } }))

    t.assert_equals(flattened['storage-001-a'], {
        name = 'storage-001-a',
        replicaset = 'storage-001',
        group = 'storages',
        uri = '127.0.0.1:3301',
    })
end

g.test_listen_of_an_unexpected_shape_is_skipped = function()
    -- Адрес объявлен строкой, а не записью: разобрать его нечем, и
    -- придумывать за оператора нельзя.
    local candidate = {
        groups = {
            storages = {
                replicasets = {
                    ['storage-001'] = {
                        instances = { ['storage-001-a'] = { iproto = { listen = '127.0.0.1:3301' } } },
                    },
                },
            },
        },
    }

    t.assert_equals(topology.instances(candidate)['storage-001-a'].uri, nil)
end
