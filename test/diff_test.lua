--- Тесты разницы конфигураций. Модуль чистый: обе стороны подаются
--- таблицами, и проверяется, что он о них рассказывает.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.config.diff')

--- Разница и то, что она берёт у своего пакета.
local MODULES = helper.modules({ 'tnt.config.secrets', 'tnt.config.diff' })

---@type any
local diff

--- Различия по путям: так проверяется набор, а не порядок полей.
---@param before table
---@param after table
---@return table<string, string>
local function kinds(before, after)
    local found = {}

    for _, difference in ipairs(diff.of(before, after)) do
        found[difference.path] = difference.kind
    end

    return found
end

--- Пути различий по порядку.
---@param before table|nil
---@param after table|nil
---@return string[]
local function paths(before, after)
    local found = {}

    for _, difference in ipairs(diff.of(before, after)) do
        table.insert(found, difference.path)
    end

    return found
end

g.before_each(function()
    diff = helper.load(MODULES, 'tnt.config.diff')
end)

g.after_each(function()
    helper.unload(MODULES)
end)

g.test_same_configuration_differs_in_nothing = function()
    local config = { labels = { zone = 'a' }, iproto = { listen = { 'a', 'b' } } }

    t.assert_equals(diff.of(config, { labels = { zone = 'a' }, iproto = { listen = { 'a', 'b' } } }), {})
end

g.test_added_section_is_named_by_its_path = function()
    local found = diff.of({ labels = {} }, { labels = { zone = 'a' } })

    t.assert_equals(#found, 1)
    t.assert_equals(found[1].path, 'labels.zone')
    t.assert_equals(found[1].kind, diff.ADDED)
    t.assert_equals(found[1].after, 'a')
end

g.test_removed_section_keeps_what_was_there = function()
    local found = diff.of({ labels = { zone = 'a' } }, { labels = {} })

    t.assert_equals(found[1].kind, diff.REMOVED)
    t.assert_equals(found[1].before, 'a')
end

g.test_changed_value_carries_both_sides = function()
    local found = diff.of({ labels = { zone = 'a' } }, { labels = { zone = 'b' } })

    t.assert_equals(found[1].kind, diff.CHANGED)
    t.assert_equals(found[1].before, 'a')
    t.assert_equals(found[1].after, 'b')
end

g.test_deep_sections_are_walked_into = function()
    local before = { groups = { cores = { replicasets = { ['lead-001'] = { instances = { a = {} } } } } } }
    local after = { groups = { cores = { replicasets = { ['lead-001'] = { instances = { a = {}, b = {} } } } } } }

    t.assert_equals(paths(before, after), { 'groups.cores.replicasets.lead-001.instances.b' })
end

g.test_list_is_compared_whole = function()
    -- Номер элемента не адрес: построчная разница списка сообщила бы
    -- об изменении каждого элемента вместо одной вставки.
    local found = diff.of({ roles = { 'router' } }, { roles = { 'router', 'storage' } })

    t.assert_equals(#found, 1)
    t.assert_equals(found[1].path, 'roles')
    t.assert_equals(found[1].after, { 'router', 'storage' })
end

g.test_single_element_list_is_still_a_list = function()
    -- Список из одного элемента легко принять за раздел: у него один ключ,
    -- как у раздела с одним именем. Разница видна по адресу — `roles`,
    -- а не `roles.1`.
    local found = diff.of({ roles = { 'a' } }, { roles = { 'b' } })

    t.assert_equals(#found, 1)
    t.assert_equals(found[1].path, 'roles')
end

g.test_equal_lists_are_not_a_difference = function()
    t.assert_equals(diff.of({ roles = { 'router', 'storage' } }, { roles = { 'router', 'storage' } }), {})
end

g.test_reordered_list_is_a_difference = function()
    -- Порядок ролей и адресов значим: это не переставленные ключи.
    t.assert_equals(#diff.of({ roles = { 'a', 'b' } }, { roles = { 'b', 'a' } }), 1)
end

g.test_shorter_list_is_a_difference = function()
    t.assert_equals(#diff.of({ roles = { 'a', 'b' } }, { roles = { 'a' } }), 1)
end

g.test_section_replaced_by_a_value_is_a_change = function()
    local found = diff.of({ labels = { zone = 'a' } }, { labels = 'a' })

    t.assert_equals(found[1].path, 'labels')
    t.assert_equals(found[1].kind, diff.CHANGED)
end

g.test_empty_section_is_not_a_list = function()
    -- О пустой таблице ничего не известно, а раздел без ключей встречается
    -- чаще пустого списка: спускаться в неё надо как в раздел.
    t.assert_equals(kinds({ labels = {} }, { labels = { zone = 'a' } }), { ['labels.zone'] = diff.ADDED })
end

g.test_explicit_null_is_not_an_absent_section = function()
    -- `box.NULL` равен `nil` по правилам языка: раздел, объявленный
    -- пустым, выглядел бы отсутствующим при сравнении в лоб.
    t.assert_equals(kinds({ labels = { zone = box.NULL } }, { labels = {} }), { ['labels.zone'] = diff.REMOVED })
end

g.test_differences_keep_their_order = function()
    -- Без порядка список перетасовывался бы от вызова к вызову, и сравнить
    -- два показа стало бы нельзя.
    local before = { a = 1, b = 1, c = 1 }
    local after = { a = 2, b = 2, c = 2 }

    t.assert_equals(paths(before, after), { 'a', 'b', 'c' })
end

g.test_missing_side_is_survived = function()
    -- Разницу спрашивают и до первого чтения конфигурации.
    t.assert_equals(diff.of(nil, nil), {})
    -- Появившийся раздел называется целиком, а не по листьям: перечислять
    -- содержимое того, чего не было вовсе, — это пересказ, а не разница.
    t.assert_equals(paths(nil, { labels = { zone = 'a' } }), { 'labels' })
end

-- ── Описание для человека ────────────────────────────────────────────

g.test_added_section_is_described = function()
    local found = diff.of({}, { labels = { zone = 'a' } })

    t.assert_equals(diff.describe(found[1]), 'добавлено labels: {"zone":"a"}')
end

g.test_removed_section_is_described = function()
    local found = diff.of({ labels = { zone = 'a' } }, {})

    t.assert_str_contains(diff.describe(found[1]), 'убрано labels: было')
end

g.test_changed_value_is_described_with_both_sides = function()
    local found = diff.of({ labels = { zone = 'a' } }, { labels = { zone = 'b' } })

    t.assert_equals(diff.describe(found[1]), 'изменено labels.zone: было a, стало b')
end

g.test_absent_side_is_described_as_nothing = function()
    t.assert_equals(diff.render(nil), 'ничего')
end

g.test_empty_section_is_described_as_a_section = function()
    -- json отдал бы `[]`, и раздел выглядел бы списком, которым не является.
    t.assert_equals(diff.render({}), '{}')
end

g.test_value_of_the_limit_length_is_shown_whole = function()
    -- Граница проверяется с обеих сторон: «длиннее» и «ровно столько» —
    -- разные случаи, и путать их значит обрезать то, что помещается.
    local value = ('x'):rep(120)

    t.assert_equals(diff.render(value), value)
end

g.test_longer_value_is_cut = function()
    -- Описание — одна строка для человека: целый раздел, вписанный в неё,
    -- прячет собой остальные различия.
    local value = ('x'):rep(121)

    t.assert_equals(diff.render(value), ('x'):rep(120) .. '…')
end

g.test_russian_value_is_measured_in_letters = function()
    -- Значения конфигурации бывают русскими: предел считается буквами,
    -- и срез не рвёт букву посреди UTF-8. Сто двадцать букв — это
    -- двести сорок байт, и показываются они целиком.
    local whole = ('ж'):rep(120)

    t.assert_equals(diff.render(whole), whole)
    t.assert_equals(diff.render(whole .. 'и'), whole .. '…')
end
