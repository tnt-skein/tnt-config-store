--- История правок конфигурации.
---
--- Раскатка не откатывается сама: возврат к прежней конфигурации — это
--- такая же правка, и делать её автоматически значит валить кластер второй
--- раз подряд. Но вернуться оператор должен уметь, а для этого нужно
--- хранить то, что было.
---
--- Ревизии складываются рядом с самой конфигурацией, в том же хранилище:
--- отдельная база под историю — это ещё один отказ в момент, когда всё
--- и так плохо.
---
--- Рядом, но не в её ветке: ключи истории лежат в `<prefix>/history/`,
--- а не под `<prefix>/config/`. Enterprise читает всю ветку `config/`
--- и сливает значения её ключей в конфигурацию кластера: запись истории
--- там стала бы неизвестными полями, ядро отвергло бы конфигурацию,
--- и кластер с историей не поднялся бы после переезда на Enterprise.
---
--- Запись хранит конфигурацию как есть, с паролями: с заглушками
--- вернуться к ней было бы нельзя. Поэтому ветке истории в etcd нужны
--- те же права, что и ключу конфигурации, и выдаются они отдельно:
--- доступ к ветке `config/` историю больше не покрывает.
---
--- Каждая запись несёт контрольную сумму. По ней видно, что две ревизии
--- различаются только заголовком, и по ней же проверяется, что прочитанное
--- не побилось по дороге. Считает её общий пакет отпечатков: так сумма
--- одной и той же конфигурации сходится везде, где её считают.

local json = require('json')

local collection = require('tnt.collection')
local fingerprint = require('tnt.fingerprint')

local Module = {}

--- Ветка, в которой живёт история, относительно префикса клиента.
---
--- Не под `config/`: эту ветку целиком читает Enterprise (шапка модуля).
--- Имя — договор с уже записанными ревизиями, как и ширина номера.
Module.PREFIX = 'history'

--- Сколько ревизий держать, если не сказано иное.
---
--- История нужна, чтобы вернуться на шаг-другой назад после неудачной
--- правки, а не чтобы вести летопись: хранилище решений — не архив.
Module.KEEP = 20

--- Ширина номера в ключе.
---
--- Номер дополняется нулями слева: хранилище отдаёт ключи ветки в
--- лексикографическом порядке, и без выравнивания десятая ревизия
--- оказывается между первой и второй. Ширина — договор с уже записанными
--- ключами.
local WIDTH = 20

--- Номер в ключе как образец: ровно `WIDTH` цифр.
---
--- Разбор принимает ту же ширину, что пишет `key`, а не «сколько-нибудь
--- цифр»: у повтора `%d+` перед якорем `$` мутанты `%d*` и `%d-` дают тот
--- же номер, и убить их нечем, а ключ другой ширины модуль не пишет.
local DIGITS = ('%d'):rep(WIDTH)

--- Ключ ревизии относительно префикса клиента: `history/<номер>`.
---@param revision number
---@return string
function Module.key(revision)
    return ('%s/%0' .. WIDTH .. 'd'):format(Module.PREFIX, math.floor(revision))
end

--- Номер ревизии из полного ключа: `<prefix>/history/<номер>`.
---
--- Префикс клиента разбору не известен, поэтому ключ опознаётся
--- по хвосту — ветке истории и номеру в ширину ключа.
---@param key string
---@return number|nil
function Module.revision_of(key)
    if type(key) ~= 'string' then
        return nil
    end

    local digits = key:match('/' .. Module.PREFIX .. '/(' .. DIGITS .. ')$')

    return digits ~= nil and tonumber(digits) or nil
end

---@class TntConfigRecord
---@field revision number Ревизия хранилища
---@field checksum string Контрольная сумма конфигурации
---@field at number|nil Когда записана
---@field author string|nil Кто записал
---@field comment string|nil Зачем
---@field config table|nil Сама конфигурация

--- Записывает ревизию в историю.
---@param client table Клиент хранилища
---@param record TntConfigRecord
---@return boolean written
---@return string|nil err
function Module.record(client, record)
    local payload = json.encode({
        revision = record.revision,
        checksum = record.checksum or fingerprint.of(record.config or {}),
        at = record.at,
        author = record.author,
        comment = record.comment,
        config = record.config,
    })

    local written, err = client:put(Module.key(record.revision), payload)

    if written == nil then
        return false,
            ('ревизия %s не записана в историю: %s'):format(
                tostring(record.revision),
                tostring(err)
            )
    end

    return true
end

--- Разбирает запись истории.
---@param kv table
---@return TntConfigRecord|nil
local function decode(kv)
    local ok, value = pcall(json.decode, kv.value)

    -- Запись без номера ревизии бесполезна: по ней нельзя ни вернуться,
    -- ни понять, что было раньше, — и считать её записью незачем.
    if not ok or type(value) ~= 'table' or type(value.revision) ~= 'number' then
        return nil
    end

    return value
end

--- Все ревизии, новые первыми.
---
--- Порядок обратный не ради красоты: оператор ищет то, что было до
--- последней правки, а не первую конфигурацию в жизни кластера.
---@param client table
---@return TntConfigRecord[]|nil records
---@return string|nil err
function Module.list(client)
    local range, err = client:range_prefix(Module.PREFIX .. '/')

    if range == nil then
        return nil, ('история не прочитана: %s'):format(tostring(err))
    end

    local records = {}

    for _, kv in ipairs(range.items) do
        local record = decode(kv)

        if record ~= nil then
            table.insert(records, record)
        end
    end

    -- Устойчиво: две записи одной ревизии остаются в порядке ключей
    -- хранилища, а не переставляются от чтения к чтению.
    return collection.sort_by(records, 'revision', 'desc')
end

--- Одна ревизия.
---@param client table
---@param revision number
---@return TntConfigRecord|nil record
---@return string|nil err
function Module.get(client, revision)
    local kv, err = client:get(Module.key(revision))

    if err ~= nil then
        return nil, ('ревизия %s не прочитана: %s'):format(tostring(revision), tostring(err))
    end

    if kv == nil then
        return nil
    end

    local record = decode(kv)

    if record == nil then
        return nil, ('запись ревизии %s не разобрана'):format(tostring(revision))
    end

    -- Сумма считается заново: запись могла побиться по дороге, и вернуть
    -- кластер к битой конфигурации хуже, чем не вернуть вовсе.
    if record.config ~= nil and record.checksum ~= fingerprint.of(record.config) then
        return nil,
            ('ревизия %s не сходится с контрольной суммой'):format(
                tostring(revision)
            )
    end

    return record
end

--- Убирает лишние ревизии, оставляя последние.
---@param client table
---@param keep number|nil Сколько оставить
---@return number removed Сколько убрано
---@return string|nil err
function Module.prune(client, keep)
    local limit = keep or Module.KEEP
    local records, err = Module.list(client)

    if records == nil then
        return 0, err
    end

    local removed = 0

    for index = limit + 1, #records do
        local dropped, drop_error = client:delete(Module.key(records[index].revision))

        if dropped == nil then
            return removed,
                ('ревизия %s не убрана: %s'):format(
                    tostring(records[index].revision),
                    tostring(drop_error)
                )
        end

        removed = removed + 1
    end

    return removed
end

return Module
