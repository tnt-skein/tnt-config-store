--- Чем кандидат отличается от того, что применено.
---
--- Оператор нажимает «раскатать», держа в голове одну правку, а уезжает
--- в кластер весь текст: чужая правка, сделанная между чтением и записью,
--- потерянный отступ, случайно стёртая строка. Показать разницу до записи
--- дешевле, чем разбирать её после — особенно ночью, когда кластер уже
--- применил то, чего никто не просил.
---
--- Разница считается по разделам, а не по строкам. Текстовое сравнение
--- показало бы переставленные ключи и переформатированный YAML как
--- изменение, а конфигурация — дерево: важно, что лежит по пути, а не
--- в каком порядке оно записано.
---
--- Списки сравниваются целиком и целиком же показываются. Номер элемента
--- не адрес: вставка в начало сдвигает всё, что ниже, и построчная разница
--- списка сообщила бы об изменении каждого элемента вместо одной вставки.
--- Правка по кускам по той же причине заменяет списки целиком.
---
--- Значения секретов сюда не попадают: разницу читают люди, пересылают
--- почтой и оставляют в журнале терминала, а пароль всего кластера нужен
--- оператору не значением, а фактом «изменился».

local json = require('json')

local collection = require('tnt.collection')
local secrets = require('tnt.config.secrets')
local str = require('tnt.str')

local Module = {}

--- Раздела не было, а стал.
Module.ADDED = 'added'

--- Раздел был, а не стало.
Module.REMOVED = 'removed'

--- Раздел был и остался, но с другим содержимым.
Module.CHANGED = 'changed'

--- Длиннее этого значение в описании обрезается.
---
--- Описание — одна строка для человека, а не запись в журнале: целый
--- раздел, вписанный в неё, прячет собой остальные различия. Само
--- значение при этом остаётся в находке целиком.
---
--- Предел считается знаками, а не байтами: значения конфигурации бывают
--- русскими, и байтовый срез разрубил бы букву посреди UTF-8.
local LIMIT = 120

--- Список ли эта таблица по устройству.
---
--- Спрашивается только о таблице: проверку типа делает тот, кто зовёт,
--- и повторять её здесь значит завести ветку, в которую никто не войдёт.
---
--- Пустая таблица списком не считается: о ней ничего не известно, а
--- раздел без ключей встречается чаще пустого списка.
---@param value table
---@return boolean
local function sequence(value)
    -- Ответ копится, а не отдаётся ранним выходом: ранняя ложь ничем
    -- не отличалась бы от пустого значения. Разделы настроек малы,
    -- и обход до конца ничего не стоит.
    local numbered = next(value) ~= nil

    for key in pairs(value) do
        numbered = numbered and type(key) == 'number'
    end

    return numbered
end

--- Раздел ли это: таблица, в которую надо спускаться.
---@param value any
---@return boolean
local function mapping(value)
    return type(value) == 'table' and not sequence(value)
end

--- Ключи таблицы множеством.
---
--- Наличие ключа проверяется по нему, а не сравнением с `nil`: значение
--- `box.NULL` равно `nil` по правилам языка, и раздел, объявленный пустым,
--- выглядел бы отсутствующим.
---@param value table
---@return table<any, boolean>
local function keys_of(value)
    local names = {}

    for key in pairs(value) do
        names[key] = true
    end

    return names
end

--- Одно ли и то же.
---@param left any
---@param right any
---@return boolean
local function same(left, right)
    -- Род сравнивается отдельно: `box.NULL == nil` и `1 == 1LL` истинны
    -- по правилам языка, а для правки это разные значения.
    if type(left) ~= 'table' or type(right) ~= 'table' then
        return type(left) == type(right) and left == right
    end

    -- Ответ копится, а не отдаётся ранним выходом; спуск во вложенное
    -- всё равно обрывается на первом различии — `and` дальше не зовёт.
    local present = keys_of(left)
    local equal = true

    for key, value in pairs(left) do
        equal = equal and same(value, right[key])
    end

    for key in pairs(right) do
        equal = equal and present[key] == true
    end

    return equal
end

---@class TntConfigDifference
---@field path string Где различие
---@field kind string Что с этим разделом стало
---@field before any Что было
---@field after any Что стало

--- Путь до раздела.
---@param prefix string[] Путь до текущего места
---@param name any Имя раздела
---@return string
local function joined(prefix, name)
    if #prefix == 0 then
        return tostring(name)
    end

    return ('%s.%s'):format(table.concat(prefix, '.'), tostring(name))
end

--- Имена обоих разделов по порядку, каждое по разу.
---
--- Сравнение через `tostring`: ключи конфигурации — имена, но сортировка
--- смешанных типов падает, а падать разбору правки не за что.
---@param present_before table<any, boolean>
---@param present_after table<any, boolean>
---@return any[]
local function names_of(present_before, present_after)
    local names = {}

    for key in pairs(present_before) do
        table.insert(names, key)
    end

    for key in pairs(present_after) do
        if not present_before[key] then
            table.insert(names, key)
        end
    end

    -- Различия читают люди: без порядка список перетасовывался бы
    -- от вызова к вызову, и сравнить два показа стало бы нельзя.
    return collection.sort_by(names, tostring)
end

--- Собирает различия двух разделов.
---@param before table
---@param after table
---@param prefix string[] Путь до текущего места
---@param found TntConfigDifference[]
local function walk(before, after, prefix, found)
    local present_before = keys_of(before)
    local present_after = keys_of(after)

    for _, name in ipairs(names_of(present_before, present_after)) do
        local was = before[name]
        local now = after[name]
        local path = joined(prefix, name)

        if not present_before[name] then
            table.insert(found, { path = path, kind = Module.ADDED, after = now })
        elseif not present_after[name] then
            table.insert(found, { path = path, kind = Module.REMOVED, before = was })
        elseif mapping(was) and mapping(now) then
            table.insert(prefix, tostring(name))
            walk(was, now, prefix, found)
            table.remove(prefix)
        elseif not same(was, now) then
            table.insert(found, { path = path, kind = Module.CHANGED, before = was, after = now })
        end
    end
end

--- Чем кандидат отличается от действующей конфигурации.
---@param before table|nil Что применено
---@param after table|nil Что предлагается
---@return TntConfigDifference[]
function Module.of(before, after)
    local found = {}

    walk(type(before) == 'table' and before or {}, type(after) == 'table' and after or {}, {}, found)

    -- Заглушки ставятся последним шагом и безусловно. Последним — потому
    -- что сравнение обязано идти по настоящим значениям: два «[скрыто]»
    -- равны между собой, и смена пароля выглядела бы отсутствием правки.
    -- Безусловно — потому что необязательное сокрытие это ветка, которую
    -- однажды забудут включить.
    return secrets.hide(found)
end

--- Значение одной строкой.
---@param value any
---@return string
function Module.render(value)
    if rawequal(value, nil) then
        return 'ничего'
    end

    -- Пустая таблица — это раздел без содержимого, а не пустой список:
    -- json отдал бы `[]`, и раздел выглядел бы тем, чем не является.
    if type(value) == 'table' and next(value) == nil then
        return '{}'
    end

    local shown = type(value) == 'table' and json.encode(value) or tostring(value)

    -- Многоточие — сверх предела, как и было: по нему видно, что значение
    -- в описании не целиком.
    return str.limit(shown, LIMIT)
end

--- Различие одной строкой для человека.
---@param difference TntConfigDifference
---@return string
function Module.describe(difference)
    if difference.kind == Module.ADDED then
        return ('добавлено %s: %s'):format(difference.path, Module.render(difference.after))
    end

    if difference.kind == Module.REMOVED then
        return ('убрано %s: было %s'):format(difference.path, Module.render(difference.before))
    end

    return ('изменено %s: было %s, стало %s'):format(
        difference.path,
        Module.render(difference.before),
        Module.render(difference.after)
    )
end

return Module
