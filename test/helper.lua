--- Общие средства проверок правки конфигурации.
---
--- Модули пакета чистые и независимые друг от друга, и каждый файл
--- проверок грузит только свои: называет их по порядку, а помощник
--- складывает из имён пути к исходникам.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt-async`, `tnt-clock`, `tnt-collection`, `tnt-context`,
--- `tnt-external`, `tnt-fingerprint` и `tnt-str` — берутся из `.rocks`
--- обычным `require`: проверяется этот пакет, а не они.
---
--- Двойник хранилища `tnt.etcd.double` нужен только проверкам истории:
--- клиент etcd пакету приходит аргументом. Он приходит из `.rocks`
--- вместе с `tnt-etcd-client` (`make deps`).
---
--- Оснастка в `test/testing/` — загрузчик исходников и часы-двойник —
--- грузится так же, файлами, и один раз на процесс: второй экземпляр
--- загрузчика не знал бы, что вытеснил первый, и не вернул бы вытесненное
--- на место.
---
--- Проверки берут всё через этот помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в наборе, где пакет живёт рядом со своими зависимостями.

local fio = require('fio')

--- Модули оснастки в порядке зависимостей.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.clock', path = 'test/testing/clock.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

local sources = package.loaded['tnt.testing.sources']

local helper = {}

--- Модули пакета по именам: путь складывается из имени.
---
--- Соседей в списке нет — их `require` находит в `.rocks`; порядок
--- списка и есть порядок загрузки модулей пакета.
---@param names string[] Модули пакета в порядке зависимостей
---@return TntTestingSource[]
function helper.modules(names)
    local list = {}

    for _, name in ipairs(names) do
        table.insert(list, { name = name, path = name:gsub('%.', '/') .. '.lua' })
    end

    return list
end

--- Загружает исходники в `package.loaded` и отдаёт названный модуль.
helper.load = sources.load

--- Убирает исходники и возвращает то, что они вытеснили.
helper.unload = sources.unload

--- Уже загруженный модуль — пакета или его зависимости.
helper.module = sources.module

--- Часы, которые двигает только проверка.
helper.clock = package.loaded['tnt.testing.clock'].new

--- Файловая система, у которой не удаётся сброс на диск.
---
--- Файл, записанный без сброса и переименованный поверх прежнего,
--- хуже отказа записи, и проверить это без двойника нечем: настоящий
--- диск сбрасывается всегда. Всё, кроме сброса, — настоящий `fio`.
---@param reason string Что сказать вместо успеха
---@return fun(): table
function helper.fs_without_fsync(reason)
    return function()
        local fs = setmetatable({}, { __index = fio })

        fs.open = function(name, flags, mode)
            local opened = fio.open(name, flags, mode)

            return {
                write = function(_, text)
                    return opened:write(text)
                end,

                fsync = function()
                    return false, reason
                end,

                close = function()
                    return opened:close()
                end,
            }
        end

        return fs
    end
end

return helper
