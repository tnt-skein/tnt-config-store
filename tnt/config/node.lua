--- Что конфигурация означает для самого узла.
---
--- Остальные модули пакета чистые: они решают, что записать и как дождаться
--- схождения. Здесь — единственное место, которое разговаривает с ядром,
--- и поэтому оно названо отдельно.
---
--- Главное здесь — проверка кандидата без применения. Битая конфигурация
--- валит кластер веером: узлы применяют её по очереди и падают по очереди,
--- а откатывать уже некуда. Проверка идёт тем же разбором, которым ядро
--- проверяет конфигурацию при старте, — своя мерка расходилась бы с
--- настоящей ровно в тех случаях, ради которых проверка и заводится.
---
--- Отдельно узел говорит, видит ли он себя в кандидате. Отвергать за это
--- нельзя — узлы выводят из состава намеренно, — но и молчать нельзя:
--- узел, которого нет в новой конфигурации, после применения перестанет
--- быть частью кластера, и знать об этом оператор должен до записи,
--- а не после.
---
--- Опубликованные функции принимают перенос контекста раскатчика
--- последним аргументом (`context.accept`): проверка кандидата, доклад
--- и запись идут на узле с `request_id` правки, которую затеял оператор.

local collection = require('tnt.collection')
local context = require('tnt.context')
local external = require('tnt.external')

local file = require('tnt.config.file')

local Module = {}

--- Внешние средства: разбор конфигурации и сведения о применённой.
local DEFAULT_SOURCE = {
    --- Разбор конфигурации кластера тем же кодом, которым её читает ядро.
    ---
    --- Модуль внутренний, и в аннотациях Tarantool его нет: он приходит
    --- вместе с ядром, а не объявлен его публичным договором. Пользоваться
    --- им — осознанное решение: своя проверка расходилась бы с настоящей.
    schema = function()
        ---@diagnostic disable-next-line: unresolved-require
        return require('internal.config.cluster_config')
    end,

    config = function()
        return require('config')
    end,

    instance_name = function()
        return box.info.name
    end,
}

local source = DEFAULT_SOURCE

--- Подменяет средства. Только для тестов.
---@param replacement table|nil
function Module._set_source(replacement)
    source = external.merge(DEFAULT_SOURCE, replacement)
end

--- Откуда узел узнаёт ревизию применённой конфигурации.
---
--- По умолчанию — у ядра: оно помнит ревизию за каждым источником, который
--- её рассказал (встроенный источник Enterprise и tnt-ce-etcd
--- рассказывают). Источник, который ядру ничего не говорит, для него
--- безымянен, и ревизию знает лишь он сам. На такой случай приложение
--- вправе подставить своего поставщика — оно одно и знает, каким
--- источником собран этот кластер. Поставщик отвечает за применённую
--- ревизию, а не за прочитанную: раскатка судит по нему о схождении.
---@type (fun(): number|nil, string|nil)|nil
local revision_provider = nil

--- Какой файл конфигурации узлу позволено переписать.
---
--- Задаётся приложением и только им. Принимать путь аргументом нельзя:
--- право позвать эту функцию по сети означало бы право переписать на узле
--- любой файл, до которого дотянется процесс.
---@type string|nil
local config_path = nil

--- Задаёт поставщика ревизии и путь к файлу конфигурации.
---@param opts { revision: (fun(): number|nil, string|nil)|nil, path: string|nil }|nil
function Module.configure(opts)
    opts = opts or {}

    revision_provider = opts.revision
    config_path = opts.path
end

--- Переписывает файл конфигурации этого узла.
---
--- Нужно там, где хранилища нет вовсе: кластер, поднятый из файла,
--- иначе правится только руками на каждом узле. Записью дело и
--- ограничивается — перечитывает конфигурацию узел по отдельной просьбе,
--- и разделение это намеренное: записать и применить — разные решения,
--- и второе принимает тот, кто раскатывает, а не тот, кто пишет.
---@param text string Конфигурация целиком
---@return { ok: boolean, err: string|nil, path: string|nil }
function Module.write(text)
    if config_path == nil then
        return {
            ok = false,
            err = 'этому узлу не назначен файл конфигурации: писать некуда',
        }
    end

    local written, err = file.write(config_path, text)

    return { ok = written, err = err, path = config_path }
end

---@class TntConfigNodeCheck
---@field ok boolean Примет ли узел такую конфигурацию
---@field err string|nil Почему не примет
---@field instance string|nil Как зовут узел
---@field declared boolean Объявлен ли узел в кандидате
---@field warnings string[] О чём стоит знать до записи

--- Смотрит кандидата, ничего не применяя.
---
--- Отказ означает «эту конфигурацию применять нельзя»: она не пройдёт
--- и у ядра, а значит уронит узел при попытке применения.
---@param candidate table Конфигурация целиком
---@return TntConfigNodeCheck
function Module.check(candidate)
    local instance = source.instance_name()
    local warnings = {}

    if type(candidate) ~= 'table' then
        return {
            ok = false,
            err = 'конфигурация должна быть таблицей',
            instance = instance,
            declared = false,
            warnings = warnings,
        }
    end

    local schema = source.schema()
    local valid, err = pcall(schema.validate, schema, candidate)

    if not valid then
        return {
            ok = false,
            err = tostring(err),
            instance = instance,
            declared = false,
            warnings = warnings,
        }
    end

    -- Узел ищет себя тем же способом, каким ядро ищет его при старте:
    -- по имени в разобранной топологии, а не обходом таблиц руками.
    local found = instance ~= nil and schema.methods.find_instance(schema, candidate, instance) ~= nil

    if not found then
        table.insert(
            warnings,
            ('узла %s в этой конфигурации нет: после применения он перестанет быть частью кластера'):format(
                tostring(instance)
            )
        )
    end

    return {
        ok = true,
        instance = instance,
        declared = found,
        warnings = warnings,
    }
end

--- Доклад узла — это то, чем раскатка судит о схождении, плюс причина,
--- если доклада нет.
---@class TntConfigNodeState: TntConfigRolloutState
---@field status string|nil Что говорит о себе ядро
---@field revision number|nil Ревизия применённой конфигурации
---@field alerts TntConfigRolloutAlert[] Замечания ядра к конфигурации
---@field err string|nil Почему состояние неизвестно

--- Ревизия применённой конфигурации из сведений ядра об источниках.
---
--- Сведения лежат по имени источника — `meta.active.etcd.revision`,
--- а не `meta.active.revision`: так их складывает ядро 3.8, и ключ
--- источника ему безразличен. Источников, знающих ревизию, в одном узле
--- не бывает больше одного, а обход по порядку имён держит ответ
--- одинаковым от вызова к вызову.
---@param active table Сведения об источниках применённой конфигурации
---@return number|nil
local function active_revision(active)
    for _, name in ipairs(collection.keys(active)) do
        local revision = type(active[name]) == 'table' and tonumber(active[name].revision) or nil

        if revision ~= nil then
            return revision
        end
    end

    return nil
end

--- Замечания ядра без лишнего: раскатке нужны вес и текст.
---@param alerts any Что отдало ядро
---@return TntConfigRolloutAlert[]
local function trimmed_alerts(alerts)
    local kept = {}

    for _, alert in ipairs(type(alerts) == 'table' and alerts or {}) do
        table.insert(kept, {
            type = tostring(alert.type),
            message = tostring(alert.message),
        })
    end

    return kept
end

--- Какая конфигурация применена на узле.
---
--- Ревизия нужна раскатке: по ней видно, что узел дошёл до той же
--- конфигурации, что записана в хранилище. Ядро само такого признака
--- не даёт — есть только локальное состояние каждого узла.
---
--- Ревизия берётся из сведений о применённой конфигурации, а не о
--- последней прочитанной: узел, прочитавший новую ревизию и упавший
--- на применении, живёт на прежней, и говорить о нём надо прежнюю.
--- Замечания отдаются целиком, а не числом: раскатке нужно назвать,
--- почему узел не применил конфигурацию, а не сказать «есть две беды».
---@return TntConfigNodeState
function Module.applied()
    local available, config = pcall(source.config)

    if not available then
        return {
            alerts = {},
            err = 'модуль config недоступен: узел живёт вне декларативной конфигурации',
        }
    end

    -- Второе поколение ответа несёт сведения об источниках: по ним видно,
    -- какая ревизия применена и откуда она взялась. Старое ядро о нём
    -- не знает — это отказ ответа, а не отказ узла.
    ---@type boolean, any
    ---@diagnostic disable-next-line: param-type-mismatch
    local read, info = pcall(config.info, config, 'v2')

    if not read then
        return { alerts = {}, err = tostring(info) }
    end

    local meta = type(info.meta) == 'table' and info.meta or {}
    local active = type(meta.active) == 'table' and meta.active or {}

    local state = {
        status = info.status,
        revision = active_revision(active),
        alerts = trimmed_alerts(info.alerts),
    }

    if revision_provider ~= nil then
        -- Поставщик задан — значит ревизию ядра брать нельзя: она либо
        -- пуста, либо относится к другому источнику. Отказ поставщика
        -- означает «ревизия неизвестна», а не «осталась прежней».
        --
        -- Ветки написаны явно, а не идиомой «а and б or в»: на пустом
        -- значении она отдаёт третью ветвь, и успешный ответ без причины
        -- превращался бы в причину, равную самой ревизии.
        local asked, revision, err = pcall(revision_provider)

        if asked then
            state.revision = tonumber(revision)
            state.err = err ~= nil and tostring(err) or nil
        else
            state.revision = nil
            state.err = tostring(revision)
        end
    end

    return state
end

--- Имена глобальных функций, которыми узел отвечает о конфигурации.
Module.FUNCTIONS = {
    check = 'config_check',
    applied = 'config_applied',
    write = 'config_write',
}

--- Публикует их.
---
--- Как и зонд диагностики: тело живёт в коде приложения, право на вызов
--- выдаётся конфигурацией. Прав на данные для этого не нужно. Перенос
--- раскатчика последним аргументом снимается до тела.
---@param names { check: string|nil, applied: string|nil, write: string|nil }|nil
function Module.publish(names)
    names = names or {}

    local bodies = {
        [names.write or Module.FUNCTIONS.write] = function(text)
            return Module.write(text)
        end,
        [names.check or Module.FUNCTIONS.check] = function(candidate)
            return Module.check(candidate)
        end,
        [names.applied or Module.FUNCTIONS.applied] = function()
            return Module.applied()
        end,
    }

    for name, body in pairs(bodies) do
        rawset(_G, name, context.accept(body))
    end
end

return Module
