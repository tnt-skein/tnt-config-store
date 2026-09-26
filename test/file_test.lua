--- Тесты записи конфигурации в файл. Диск настоящий: проверяется именно
--- то, что на нём остаётся, — а двойник файловой системы показал бы
--- только порядок вызовов.

local fio = require('fio')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.config.file')

--- Файл конфигурации и внешняя зависимость, через которую ему подменяют диск.
local MODULES = helper.modules({ 'tnt.config.file' })

---@type any
local file

--- Каталог под файлы одной проверки.
---@type string
local workdir

--- Путь к файлу конфигурации внутри него.
---@return string
local function config_path()
    return fio.pathjoin(workdir, 'config.yaml')
end

g.before_each(function()
    file = helper.load(MODULES, 'tnt.config.file')
    workdir = fio.tempdir()
end)

g.after_each(function()
    file._set_source(nil)
    fio.rmtree(workdir)
    helper.unload(MODULES)
end)

g.test_file_is_written_and_read_back = function()
    t.assert_equals(file.write(config_path(), 'groups: {}'), true)
    t.assert_equals(file.read(config_path()), 'groups: {}')
end

g.test_previous_content_is_kept_aside = function()
    -- Это не резервная копия, а последняя конфигурация, на которой узел
    -- точно поднимался: нужна она в тот единственный час, когда новая
    -- не поднимается.
    file.write(config_path(), 'было')
    file.write(config_path(), 'стало')

    t.assert_equals(file.read(config_path()), 'стало')
    t.assert_equals(file.read(config_path() .. file.PREVIOUS), 'было')
end

g.test_first_write_leaves_no_previous = function()
    file.write(config_path(), 'первое')

    t.assert_equals(fio.path.exists(config_path() .. file.PREVIOUS), false)
end

g.test_temporary_file_does_not_stay = function()
    -- Запись идёт рядом и переименовывается поверх: временный файл,
    -- оставшийся в каталоге, однажды прочитают вместо настоящего.
    file.write(config_path(), 'groups: {}')

    t.assert_equals(fio.path.exists(config_path() .. file.TEMPORARY), false)
end

g.test_written_file_is_closed_to_others = function()
    -- В конфигурации лежат пароли всех учётных записей кластера: файл
    -- читают владелец и его группа, посторонним он закрыт. Права нового
    -- файла режет ещё и маска процесса, поэтому на время записи она
    -- ставится известной.
    local previous = fio.umask(assert(tonumber('022', 8)))
    -- Под защитой: маска возвращается и тогда, когда запись бросила
    -- исключение, — иначе она досталась бы следующим проверкам.
    local called, written = pcall(file.write, config_path(), 'groups: {}')

    fio.umask(previous)

    t.assert_equals({ called, written }, { true, true })
    -- Права — младшие девять битов режима, то есть остаток от деления
    -- на восьмеричные 1000; тип файла стоит выше них.
    t.assert_equals(('%o'):format(fio.stat(config_path()).mode % 512), '640')
end

g.test_unwritable_directory_is_reported = function()
    local ok, err = file.write(fio.pathjoin(workdir, 'нет', 'такого', 'config.yaml'), 'groups: {}')

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'не создан')
end

g.test_missing_file_is_reported_on_reading = function()
    local text, err = file.read(config_path())

    t.assert_equals(text, nil)
    t.assert_str_contains(err, 'не открыт')
end

g.test_unreadable_file_is_reported = function()
    -- Файл открылся, а содержимого не отдал: такое бывает на битом диске,
    -- и пустая строка вместо конфигурации хуже отказа.
    file.write(config_path(), 'groups: {}')

    file._set_source({
        fs = function()
            local fs = setmetatable({}, { __index = fio })

            fs.open = function()
                return {
                    read = function()
                        return nil
                    end,

                    close = function() end,
                }
            end

            return fs
        end,
    })

    local text, err = file.read(config_path())

    t.assert_equals(text, nil)
    t.assert_str_contains(err, 'не прочитан')
end

g.test_only_text_is_written = function()
    -- Конфигурацию присылают деревом, и записать его как есть нельзя:
    -- файл должен остаться читаемым и ядром, и человеком.
    local ok, err = file.write(config_path(), { groups = {} })

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'текстом')
end

g.test_failed_write_does_not_touch_the_previous_file = function()
    -- Отказ на записи обязан оставить прежнюю конфигурацию на месте:
    -- узел, перезапущенный в этот момент, поднимается по ней.
    file.write(config_path(), 'прежнее')

    file._set_source({
        fs = function()
            local fs = setmetatable({}, { __index = fio })

            fs.open = function()
                return nil, 'диск кончился'
            end

            return fs
        end,
    })

    local ok, err = file.write(config_path(), 'новое')

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'диск кончился')
    t.assert_equals(file.read(config_path()), nil)

    file._set_source(nil)

    t.assert_equals(file.read(config_path()), 'прежнее')
end

g.test_broken_sync_leaves_nothing_behind = function()
    -- Сброс на диск обязателен до переименования: без него файл появится
    -- на месте, а содержимое его — когда-нибудь потом.
    file._set_source({
        fs = helper.fs_without_fsync('диск не отозвался'),
    })

    local ok, err = file.write(config_path(), 'новое')

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'не отозвался')

    file._set_source(nil)

    t.assert_equals(fio.path.exists(config_path()), false)
    t.assert_equals(fio.path.exists(config_path() .. file.TEMPORARY), false)
end

g.test_failed_rename_leaves_nothing_behind = function()
    file._set_source({
        fs = function()
            local fs = setmetatable({}, { __index = fio })

            fs.rename = function()
                return false, 'каталог только для чтения'
            end

            return fs
        end,
    })

    local ok, err = file.write(config_path(), 'новое')

    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'только для чтения')

    file._set_source(nil)

    t.assert_equals(fio.path.exists(config_path() .. file.TEMPORARY), false)
end
