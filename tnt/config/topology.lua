--- Проверка правки конфигурации кластера на монотонность.
---
--- Схему конфигурации проверяет само ядро: оно отвергнет неизвестное поле
--- и неверный тип. Чего оно не проверяет — не сломает ли эта правка живой
--- кластер. А сломать можно молча: вычеркнуть узел из конфигурации,
--- перенести его в другой репликасет, выдать двум узлам один адрес. Всё
--- это синтаксически безупречно.
---
--- Правила здесь не выдуманы: за каждым стоит отказ, который иначе
--- случается в проде и выглядит как загадка.
---
--- Модуль чистый: на входе два документа конфигурации, на выходе список
--- возражений. Ни кластера, ни сети — поэтому правку можно проверить
--- до того, как она куда-то поедет.

local collection = require('tnt.collection')

local Module = {}

--- Узел исчез из конфигурации.
Module.REMOVED = 'removed'

--- Узел переехал в другой репликасет.
Module.MOVED = 'moved'

--- Репликасет переехал в другую группу.
Module.REGROUPED = 'regrouped'

--- Два узла объявлены с одним адресом.
Module.ADDRESS_TAKEN = 'address_taken'

--- Правка вычёркивает сам применяющий узел.
Module.SELF_REMOVED = 'self_removed'

---@class TntConfigObjection
---@field kind string Что именно не так
---@field target string Кого это касается
---@field message string Объяснение для человека

---@class TntConfigInstance
---@field name string Имя узла
---@field replicaset string Репликасет, в котором он объявлен
---@field group string Группа, в которой объявлен репликасет
---@field uri string|nil Адрес, по которому его ищут соседи

--- Разбирает конфигурацию в плоскую карту узлов.
---
--- Конфигурация 3.x вложена тремя уровнями — группы, репликасеты, узлы, —
--- и сравнивать её в таком виде неудобно: почти все правила смотрят на
--- узел и на то, где он объявлен.
---@param config table|nil Документ конфигурации кластера
---@return table<string, TntConfigInstance>
function Module.instances(config)
    local found = {}

    for group_name, group in pairs((config or {}).groups or {}) do
        for replicaset_name, replicaset in pairs(group.replicasets or {}) do
            for name, instance in pairs(replicaset.instances or {}) do
                local listen = instance.iproto ~= nil and instance.iproto.listen or nil
                local uri = nil

                -- Адрес объявляют списком: узел вправе слушать несколько,
                -- но соседи ищут его по первому.
                if type(listen) == 'table' and type(listen[1]) == 'table' then
                    uri = listen[1].uri
                end

                found[name] = {
                    name = name,
                    replicaset = replicaset_name,
                    group = group_name,
                    uri = uri,
                }
            end
        end
    end

    return found
end

--- Добавляет возражение.
---@param objections TntConfigObjection[]
---@param kind string
---@param target string
---@param message string
local function object(objections, kind, target, message)
    table.insert(objections, { kind = kind, target = target, message = message })
end

---@class TntConfigValidateOptions
---@field self_name string|nil Имя узла, который применяет правку
---@field removing string[]|nil Кого удаляют намеренно

--- Что не так с правкой конфигурации.
---
--- Возвращается список возражений, а не первое из них: оператор должен
--- увидеть всё сразу, а не чинить по одному за подход.
---@param current table|nil Действующая конфигурация
---@param candidate table|nil Предлагаемая конфигурация
---@param opts TntConfigValidateOptions|nil
---@return TntConfigObjection[]
function Module.validate(current, candidate, opts)
    opts = opts or {}

    local was = Module.instances(current)
    local becomes = Module.instances(candidate)
    local objections = {}

    local removing = {}
    for _, name in ipairs(opts.removing or {}) do
        removing[name] = true
    end

    for _, name in ipairs(collection.keys(was)) do
        local before = was[name]
        local after = becomes[name]

        if after == nil then
            -- Узел, вычеркнутый из конфигурации, не исчезает из кластера:
            -- он остаётся в системном спейсе, портит статус репликации
            -- и однажды возвращается — с данными, о которых никто не знал.
            if not removing[name] then
                object(
                    objections,
                    Module.REMOVED,
                    name,
                    ('узел %s вычеркнут из конфигурации; удаление узла объявляется явно'):format(
                        name
                    )
                )
            end
        else
            if after.replicaset ~= before.replicaset then
                -- Перенос правкой конфигурации означает, что узел придёт
                -- в новый репликасет с чужими данными.
                object(
                    objections,
                    Module.MOVED,
                    name,
                    ('узел %s переносится из %s в %s; правкой конфигурации это не делается'):format(
                        name,
                        before.replicaset,
                        after.replicaset
                    )
                )
            end

            if after.group ~= before.group then
                object(
                    objections,
                    Module.REGROUPED,
                    before.replicaset,
                    ('репликасет %s переносится из группы %s в %s'):format(
                        before.replicaset,
                        before.group,
                        after.group
                    )
                )
            end
        end
    end

    local taken = {}
    for _, name in ipairs(collection.keys(becomes)) do
        local uri = becomes[name].uri

        if uri ~= nil then
            if taken[uri] ~= nil then
                -- Два узла по одному адресу: один из них недостижим, и это
                -- выясняется в первый же обход кластера.
                object(
                    objections,
                    Module.ADDRESS_TAKEN,
                    name,
                    ('адрес %s объявлен и у %s, и у %s'):format(uri, taken[uri], name)
                )
            else
                taken[uri] = name
            end
        end
    end

    -- Узел, вычеркнувший сам себя, применяет правку последний раз в жизни:
    -- дальше он не в кластере, и вернуть его будет нечем.
    if opts.self_name ~= nil and was[opts.self_name] ~= nil and becomes[opts.self_name] == nil then
        object(
            objections,
            Module.SELF_REMOVED,
            opts.self_name,
            ('правка вычёркивает применяющий узел %s'):format(opts.self_name)
        )
    end

    return objections
end

--- Годится ли правка.
---@param current table|nil
---@param candidate table|nil
---@param opts TntConfigValidateOptions|nil
---@return boolean ok
---@return TntConfigObjection[] objections
function Module.acceptable(current, candidate, opts)
    local objections = Module.validate(current, candidate, opts)

    return #objections == 0, objections
end

return Module
