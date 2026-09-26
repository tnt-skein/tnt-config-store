--- Запись конфигурации в файл — для кластеров, у которых нет хранилища.
---
--- Кластер, поднятый из файла, править было нечем: вся раскатка идёт
--- через хранилище, а там, где его нет, конфигурация меняется руками
--- на каждом узле. Здесь то, чего для этого не хватало, — запись файла,
--- которую не оборвёт ни отказ диска, ни падение процесса посередине.
---
--- Атомарность здесь узловая и только узловая, и об этом надо сказать
--- прямо. Запись идёт во временный файл рядом, сбрасывается на диск
--- и переименовывается поверх: переименование в пределах каталога
--- атомарно, и прочитать полуфайл нельзя даже при выключении питания.
--- Но кластер из этого атомарности не получает: узлов много, файлов
--- столько же, и между первым и последним переименованием кластер живёт
--- на двух разных конфигурациях сразу.
---
--- Это свойство способа, а не недоработка. Там, где нужна одна точка
--- записи, ставят хранилище — одна транзакция, обусловленная ревизией,
--- и расходиться нечему. Файлам этого дать неоткуда, и притворяться
--- обратным опаснее, чем сказать вслух: раскатка по файлам защищена
--- проверкой на всех узлах до записи и докладом о ревизии после неё,
--- а не атомарностью.
---
--- Прежнее содержимое остаётся рядом с суффиксом `.bak`. Это не резервная
--- копия — это последняя конфигурация, на которой узел точно поднимался,
--- и нужна она в тот единственный час, когда новая не поднимается.

local external = require('tnt.external')

local Module = {}

--- Суффикс временного файла, в который идёт запись.
Module.TEMPORARY = '.new'

--- Суффикс копии прежнего содержимого.
Module.PREVIOUS = '.bak'

--- Работа с диском. Вынесена, чтобы проверки обходились без него.
local DEFAULT_SOURCE = {
    fs = function()
        return require('fio')
    end,
}

local source = DEFAULT_SOURCE

--- Подменяет работу с диском. Только для тестов.
---@param replacement table|nil
function Module._set_source(replacement)
    source = external.merge(DEFAULT_SOURCE, replacement)
end

--- Читает файл целиком.
---@param path string
---@return string|nil text
---@return string|nil err
function Module.read(path)
    local fs = source.fs()
    local file, open_error = fs.open(path, { 'O_RDONLY' })

    if file == nil then
        return nil, ('файл %s не открыт: %s'):format(path, tostring(open_error))
    end

    local text = file:read()

    file:close()

    if text == nil then
        return nil, ('файл %s не прочитан'):format(path)
    end

    return text
end

--- Пишет файл так, чтобы половины не осталось.
---
--- Порядок шагов — и есть всё содержание: запись рядом, сброс на диск,
--- копия прежнего, переименование поверх. Сброс до переименования
--- обязателен: без него файл появится на месте, а содержимое его —
--- когда-нибудь потом, и переживший отключение питания узел поднимется
--- на пустом файле.
---@param path string Куда писать
---@param text string Что писать
---@return boolean ok
---@return string|nil err
function Module.write(path, text)
    if type(text) ~= 'string' then
        return false, 'конфигурация записывается текстом'
    end

    local fs = source.fs()
    local temporary = path .. Module.TEMPORARY
    local file, open_error = fs.open(temporary, { 'O_WRONLY', 'O_CREAT', 'O_TRUNC' }, tonumber('640', 8))

    if file == nil then
        return false, ('файл %s не создан: %s'):format(temporary, tostring(open_error))
    end

    local written, write_error = file:write(text)

    if written then
        written, write_error = file:fsync()
    end

    file:close()

    if not written then
        fs.unlink(temporary)

        return false, ('файл %s не записан: %s'):format(temporary, tostring(write_error))
    end

    -- Прежнее содержимое отходит в сторону, а не пропадает: это последняя
    -- конфигурация, на которой узел точно поднимался.
    if fs.path.exists(path) then
        fs.copyfile(path, path .. Module.PREVIOUS)
    end

    local renamed, rename_error = fs.rename(temporary, path)

    if not renamed then
        fs.unlink(temporary)

        return false, ('файл %s не переименован: %s'):format(temporary, tostring(rename_error))
    end

    return true
end

return Module
