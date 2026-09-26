--- Тесты истории правок. Хранилище подменяется двойником.

local double = require('tnt.etcd.double')
local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.config.history')

--- История и то, что она берёт: списки и отпечаток.
local MODULES = helper.modules({ 'tnt.config.history' })

---@type any
local history

---@type any
local client

---@type any
local store

g.before_each(function()
    history = helper.load(MODULES, 'tnt.config.history')

    client, store = double.new()
end)

g.after_each(function()
    helper.unload(MODULES)
end)

--- Конфигурация кластера для записи.
---@param failover string|nil
---@return table
local function config(failover)
    return { replication = { failover = failover or 'supervised' } }
end

g.test_revision_is_recorded = function()
    local written = history.record(client, {
        revision = 7,
        config = config(),
        at = 1789041300,
        author = 'admin',
        comment = 'включили координатора',
    })

    t.assert_equals(written, true)

    local record = json.decode(store.keys[history.key(7)].value)

    t.assert_equals(record.revision, 7)
    t.assert_equals(record.author, 'admin')
    t.assert_equals(record.comment, 'включили координатора')
    t.assert_type(record.checksum, 'string')
end

g.test_failed_write_is_reported = function()
    store.behaviour.put_error = 'нет связи'

    local written, err = history.record(client, { revision = 7, config = config() })

    t.assert_equals(written, false)
    t.assert_str_contains(err, 'не записана в историю')
end

g.test_revision_is_read_back = function()
    history.record(client, { revision = 7, config = config() })

    local record = history.get(client, 7)

    t.assert_equals(record.revision, 7)
    t.assert_equals(record.config.replication.failover, 'supervised')
end

g.test_missing_revision_is_not_an_error = function()
    local record, err = history.get(client, 7)

    t.assert_equals(record, nil)
    t.assert_equals(err, nil)
end

g.test_unreadable_store_is_reported = function()
    store.behaviour.get_error = 'нет связи'

    local record, err = history.get(client, 7)

    t.assert_equals(record, nil)
    t.assert_str_contains(err, 'не прочитана')
end

g.test_broken_record_is_reported = function()
    double.put(store, history.key(7), 'не json')

    local record, err = history.get(client, 7)

    t.assert_equals(record, nil)
    t.assert_str_contains(err, 'не разобрана')
end

g.test_tampered_record_is_refused = function()
    -- Вернуть кластер к битой конфигурации хуже, чем не вернуть вовсе.
    history.record(client, { revision = 7, config = config() })

    local record = json.decode(store.keys[history.key(7)].value)
    record.config.replication.failover = 'off'
    double.put(store, history.key(7), json.encode(record))

    local read, err = history.get(client, 7)

    t.assert_equals(read, nil)
    t.assert_str_contains(err, 'не сходится с контрольной суммой')
end

g.test_history_is_listed_newest_first = function()
    -- Оператор ищет то, что было до последней правки, а не первую
    -- конфигурацию в жизни кластера.
    for _, revision in ipairs({ 2, 11, 7 }) do
        history.record(client, { revision = revision, config = config() })
    end

    local records = history.list(client)

    t.assert_equals(#records, 3)
    t.assert_equals(records[1].revision, 11)
    t.assert_equals(records[2].revision, 7)
    t.assert_equals(records[3].revision, 2)
end

g.test_records_of_one_revision_keep_the_order_of_keys = function()
    -- Две записи с одной ревизией — след ручной правки хранилища. Список
    -- не переставляет их от чтения к чтению: идут в порядке ключей.
    history.record(client, { revision = 7, config = config() })

    for key, comment in pairs({ [8] = 'восьмой ключ', [9] = 'девятый ключ' }) do
        double.put(store, history.key(key), json.encode({ revision = 5, comment = comment, config = config() }))
    end

    local records = history.list(client)

    t.assert_equals(#records, 3)
    t.assert_equals(records[1].revision, 7)
    t.assert_equals(records[2].comment, 'восьмой ключ')
    t.assert_equals(records[3].comment, 'девятый ключ')
end

g.test_record_whose_revision_is_not_a_number_goes_last = function()
    -- Разбор JSON Tarantool читает `nan` как число, и такая запись
    -- проходит проверку вида. Сравнить её не с чем: она стоит последней
    -- и не ломает порядок остальных.
    double.put(store, history.key(3), '{"revision": nan, "comment": "без номера"}')
    history.record(client, { revision = 2, config = config() })
    history.record(client, { revision = 11, config = config() })

    local records = history.list(client)

    t.assert_equals(#records, 3)
    t.assert_equals(records[1].revision, 11)
    t.assert_equals(records[2].revision, 2)
    t.assert_equals(records[3].comment, 'без номера')
end

g.test_unreadable_history_is_reported = function()
    store.behaviour.range_error = 'нет связи'

    local records, err = history.list(client)

    t.assert_equals(records, nil)
    t.assert_str_contains(err, 'история не прочитана')
end

g.test_broken_entries_are_skipped_in_the_list = function()
    history.record(client, { revision = 7, config = config() })
    double.put(store, history.key(8), 'не json')

    local records = history.list(client)

    t.assert_equals(#records, 1)
    t.assert_equals(records[1].revision, 7)
end

g.test_old_revisions_are_pruned = function()
    -- Хранилище решений — не архив: история нужна, чтобы вернуться
    -- на шаг-другой назад.
    for revision = 1, 5 do
        history.record(client, { revision = revision, config = config() })
    end

    local removed = history.prune(client, 2)

    t.assert_equals(removed, 3)

    local left = history.list(client)

    t.assert_equals(#left, 2)
    t.assert_equals(left[1].revision, 5)
    t.assert_equals(left[2].revision, 4)
end

g.test_short_history_is_left_alone = function()
    history.record(client, { revision = 1, config = config() })

    t.assert_equals(history.prune(client, 5), 0)
end

g.test_failed_prune_is_reported = function()
    for revision = 1, 3 do
        history.record(client, { revision = revision, config = config() })
    end

    store.behaviour.delete_error = 'нет связи'

    local removed, err = history.prune(client, 1)

    t.assert_equals(removed, 0)
    t.assert_str_contains(err, 'не убрана')
end

g.test_prune_on_unreadable_history_is_reported = function()
    store.behaviour.range_error = 'нет связи'

    local removed, err = history.prune(client)

    t.assert_equals(removed, 0)
    t.assert_str_contains(err, 'история не прочитана')
end

g.test_keys_keep_their_order = function()
    -- Без выравнивания нулями десятая ревизия оказывается между первой
    -- и второй: хранилище отдаёт ключи по алфавиту.
    t.assert_equals(history.key(2) < history.key(10), true)
    t.assert_equals(history.revision_of('/prefix/' .. history.key(42)), 42)
    t.assert_equals(history.revision_of('что-то другое'), nil)
    t.assert_equals(history.revision_of(nil), nil)
end

g.test_key_keeps_the_written_layout = function()
    -- Раскладка ключа — договор с уже записанными ревизиями: номер ровно
    -- в двадцать цифр, и разбор понимает ту же ширину, что пишет ключ.
    t.assert_equals(history.key(7), 'history/00000000000000000007')
    t.assert_equals(history.revision_of('/tarantool/history/00000000000000000007'), 7)
    t.assert_equals(history.revision_of('/tarantool/history/7'), nil)
    t.assert_equals(history.revision_of('/tarantool/history-00000000000000000007'), nil)
end

g.test_history_stays_out_of_the_configuration_branch = function()
    -- Enterprise читает всю ветку `<prefix>/config/` и сливает её ключи
    -- в конфигурацию: запись истории там стала бы неизвестными полями,
    -- и кластер с историей на Enterprise не поднялся бы.
    for revision = 1, 3 do
        history.record(client, { revision = revision, config = config() })
    end

    history.get(client, 3)
    history.prune(client, 2)

    -- Запись, чтение, перебор и уборка — каждая ходит только в ветку
    -- истории: три записи, одно чтение, один перебор, одно удаление.
    t.assert_equals(#store.calls, 6)

    for _, call in ipairs(store.calls) do
        t.assert_equals(call.key:startswith('history/'), true, call.key)
        t.assert_equals(call.key:startswith('config/'), false, call.key)
    end

    -- Так ветку видит Enterprise: история в ней не появилась.
    t.assert_equals(client:range_prefix('config/').count, 0)
    t.assert_equals(client:range_prefix('history/').count, 2)
end

g.test_checksum_is_taken_from_the_configuration_when_not_given = function()
    history.record(client, { revision = 7, config = config() })

    local record = json.decode(store.keys[history.key(7)].value)

    t.assert_equals(record.checksum, require('tnt.fingerprint').of(config()))
end

g.test_entry_without_a_revision_is_skipped = function()
    -- По записи без номера нельзя ни вернуться, ни понять, что было
    -- раньше: считать её записью незачем.
    history.record(client, { revision = 7, config = config() })
    double.put(store, history.key(8), json.encode({ config = config(), checksum = 'aaaa' }))

    local records = history.list(client)

    t.assert_equals(#records, 1)
    t.assert_equals(records[1].revision, 7)
end

g.test_entry_that_is_not_an_object_is_skipped = function()
    -- Разбор удался, но это число: полей у него не спросишь.
    history.record(client, { revision = 7, config = config() })
    double.put(store, history.key(8), '42')

    t.assert_equals(#history.list(client), 1)
end

g.test_revision_that_is_not_an_object_is_reported = function()
    double.put(store, history.key(7), '42')

    local record, err = history.get(client, 7)

    t.assert_equals(record, nil)
    t.assert_str_contains(err, 'не разобрана')
end

g.test_kept_depth_defaults_to_twenty = function()
    -- Хранилище решений — не архив: история нужна, чтобы вернуться
    -- на шаг-другой назад.
    for revision = 1, 21 do
        history.record(client, { revision = revision, config = config() })
    end

    t.assert_equals(history.prune(client), 1)

    local left = history.list(client)

    t.assert_equals(#left, 20)
    t.assert_equals(left[1].revision, 21)
    t.assert_equals(left[20].revision, 2)
end
