--- Правка конфигурации по кускам.
---
--- Присылать всю конфигурацию ради одной строки — способ рабочий, но
--- опасный: оператор правит текст, девять десятых которого его не
--- касаются, и всякая случайная правка соседнего раздела уезжает
--- в кластер вместе с нужной. Хуже того, между чтением и записью
--- конфигурацию мог поменять кто-то ещё — и присланный целиком текст
--- молча вернёт её к тому, что оператор прочитал полчаса назад.
---
--- Здесь способ другой: назвать место и то, что там должно оказаться.
--- Всё, о чём правка не говорит, остаётся как было, включая чужие правки.
---
--- Место называется путём — именами разделов сверху вниз:
--- `groups.cores.replicasets.lead-001.instances.lead-001-c`. Именами,
--- а не номерами: номер элемента списка адресом не является. Вставка
--- в начало сдвигает всё, что ниже, и правка, написанная по вчерашнему
--- списку, попадёт сегодня в чужой элемент. Поэтому списки заменяются
--- целиком — это честнее, чем правка вслепую.
---
--- Удаление — отдельный признак, а не пустое значение. В Lua `nil`
--- в таблице неотличим от отсутствующего ключа: правка «поставить nil»
--- ничего бы не удалила, а правка, в которой значение просто забыли,
--- молча стёрла бы раздел. Оба исхода дороже лишнего поля в запросе.
---
--- Модуль чистый: он не читает конфигурацию и не пишет её. Он собирает
--- кандидата, а раскатывает его тот же механизм трёх фаз, что и целиком
--- присланный текст, — правка по кускам не повод пропускать проверку.

local Module = {}

--- Чем разделяются имена разделов в пути.
Module.SEPARATOR = '.'

--- Отсутствует ли значение.
---
--- Сравнение с `nil` здесь не годится: `box.NULL` равен ему по правилам
--- языка, а это совсем другое дело — явный пустой раздел в конфигурации.
--- Их надо различать, иначе правка «поставить null» будет понята как
--- «значение забыли».
---@param value any
---@return boolean
local function missing(value)
    return rawequal(value, nil)
end

--- Разбирает путь в список имён разделов.
---@param path string|string[] Путь: строкой через точку или списком имён
---@return string[]|nil names
---@return string|nil err
function Module.split(path)
    if type(path) == 'table' then
        local names = {}

        for _, name in ipairs(path) do
            if type(name) ~= 'string' or name == '' then
                return nil,
                    'путь состоит из имён разделов, и пустых среди них не бывает'
            end

            table.insert(names, name)
        end

        if #names == 0 then
            return nil, 'путь не назван'
        end

        return names
    end

    if type(path) ~= 'string' or path == '' then
        return nil, 'путь не назван'
    end

    local names = {}

    -- Точка внутри набора — обычный знак, а не «любой»: экранировать её
    -- здесь не нужно и нельзя.
    for name in path:gmatch('[^.]+') do
        table.insert(names, name)
    end

    -- Сборка обратно ловит то, чего перебор не заметит: пустое имя между
    -- точками, точку в начале и в конце. Путь `groups..cores` — это
    -- опечатка, и понимать её как `groups.cores` значит угадывать.
    if table.concat(names, Module.SEPARATOR) ~= path then
        return nil, ('путь %s написан с пустым именем раздела'):format(path)
    end

    return names
end

--- Что лежит по пути.
---@param config table Конфигурация
---@param path string|string[] Путь
---@return any value Значение либо nil, если раздела нет
---@return string|nil err
function Module.get(config, path)
    local names, err = Module.split(path)

    if names == nil then
        return nil, err
    end

    local value = config

    for depth, name in ipairs(names) do
        if type(value) ~= 'table' then
            return nil,
                ('путь %s упирается в значение: %s — не раздел'):format(
                    table.concat(names, Module.SEPARATOR),
                    table.concat(names, Module.SEPARATOR, 1, depth - 1)
                )
        end

        value = value[name]
    end

    return value
end

---@class TntConfigChange
---@field path string|string[] Что менять
---@field value any Чем заменить
---@field remove boolean|nil Убрать раздел вместо замены

--- Применяет одну правку к уже сделанной копии.
---@param config table
---@param change TntConfigChange
---@return boolean ok
---@return string|nil err
local function single(config, change)
    if type(change) ~= 'table' then
        return false, 'правка описывается таблицей'
    end

    local names, err = Module.split(change.path)

    if names == nil then
        return false, err
    end

    local removing = change.remove == true
    local written = table.concat(names, Module.SEPARATOR)

    if not removing and missing(change.value) then
        return false,
            ('нечего положить по пути %s: значение не названо'):format(written)
    end

    local holder = config

    for depth = 1, #names - 1 do
        local name = names[depth]
        local deeper = holder[name]

        -- Обычное сравнение здесь к месту, и это единственный раз:
        -- `box.NULL` равен `nil` по правилам языка, а объявленный пустым
        -- раздел и отсутствующий раздел для спуска — одно и то же.
        if deeper == nil then
            -- Убирать из раздела, которого нет, нечего, и заводить его
            -- ради этого — значит менять конфигурацию там, где правка
            -- просила ничего не менять.
            if removing then
                return true
            end

            deeper = {}
            holder[name] = deeper
        elseif type(deeper) ~= 'table' then
            return false,
                ('путь %s упирается в значение: %s — не раздел'):format(
                    written,
                    table.concat(names, Module.SEPARATOR, 1, depth)
                )
        end

        holder = deeper
    end

    local last = names[#names]

    if removing then
        holder[last] = nil

        return true
    end

    -- Копия, а не ссылка: правка вправе прийти из чужой таблицы, и
    -- кандидат, разделяющий с ней память, поменяется вместе с ней.
    holder[last] = type(change.value) == 'table' and table.deepcopy(change.value) or change.value

    return true
end

--- Собирает кандидата из действующей конфигурации и правок.
---
--- Правки применяются по порядку и к копии: действующая конфигурация
--- не меняется ни при успехе, ни при отказе. Отказ означает, что кандидата
--- нет вовсе, — применённые до него правки пропадают вместе с копией,
--- и половинчатого кандидата не бывает.
---@param current table|nil Действующая конфигурация; без неё править нечего
---@param changes TntConfigChange[] Правки по порядку
---@return table|nil candidate
---@return string|nil err
function Module.apply(current, changes)
    if type(current) ~= 'table' then
        return nil,
            'действующая конфигурация не прочитана: править нечего'
    end

    if type(changes) ~= 'table' or #changes == 0 then
        return nil, 'правок не названо'
    end

    local candidate = table.deepcopy(current)

    for index, change in ipairs(changes) do
        local applied, err = single(candidate, change)

        if not applied then
            return nil, ('правка %d: %s'):format(index, err)
        end
    end

    return candidate
end

return Module
