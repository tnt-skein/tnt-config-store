--- Что из конфигурации нельзя показывать.
---
--- Конфигурацию кластера показывают целиком: в панели, в разнице перед
--- раскаткой, в выводе инструмента. А в ней лежат пароли всех учётных
--- записей кластера, ключи и адреса с учётными данными. Оператору нужен
--- факт «пароль изменился», а не значение: по значению он ничего
--- не решает, зато оно остаётся в истории браузера, в журнале терминала
--- и в почте, куда эту разницу переслали.
---
--- Заглушка ставится ПОСЛЕ сравнения и ДО выдачи, и порядок здесь —
--- всё содержание. Спрячь раньше — и два «[скрыто]» окажутся одинаковыми:
--- разница выйдет пустой, раскатка ответит «раскатывать нечего», и смена
--- пароля молча не доедет до кластера. Спрячь позже, у потребителя, —
--- и каждый следующий потребитель обязан вспомнить про это сам; первый же
--- забывший вернёт дыру на место.
---
--- Прятать значение — не то же самое, что править его. Всякая таблица,
--- которой коснулись, копируется: `before` и `after` в разнице — это
--- ссылки внутрь кандидата, и правка на месте записала бы слово «скрыто»
--- настоящим паролем всего кластера.
---
--- Ещё одно правило — о щедрости. Лишняя заглушка стоит оператору одного
--- вопроса «а что там было», утечка стоит кластера. Поэтому сомнительное
--- имя прячется.

local Module = {}

--- Чем заменяется секрет.
---
--- То же слово, что и в журнале: заглушка должна читаться одинаково,
--- где бы её ни встретили.
Module.HIDDEN = '[скрыто]'

--- Окончания имён, за которыми прячется секрет.
---
--- `key` покрывает и `api_key`, и `private_key`, и `ssl_key` — а заодно
--- оставляет на виду `ssl_key_file`: путь к ключу не ключ, и по нему
--- оператор проверяет, тот ли файл подставили.
local HINTS = {
    'password',
    'passwd',
    'secret',
    'token',
    'cookie',
    'authorization',
    'key',
}

--- Похоже ли имя раздела на секрет.
---
--- Сверяется конец имени, а не вхождение подстроки, и это не придирка.
--- Журнал ищет подстроку — там имена полей выбирает наш же код. Здесь
--- имена задаёт схема ядра, а в ней лежит целая политика паролей:
--- `password_min_length`, `password_lifetime_days`,
--- `password_enforce_digits`. Спрятав их по подстроке, мы спрятали бы
--- от оператора ровно то, что он обязан видеть: ужесточили правила
--- или ослабили.
---@param name any Имя раздела
---@return boolean
function Module.secret(name)
    local shown = tostring(name)

    for _, hint in ipairs(HINTS) do
        if shown == hint or shown:sub(-#hint - 1) == '_' .. hint then
            return true
        end
    end

    return false
end

--- Заглушка как образец поиска: знаки в ней значимы, и экранировать их
--- приходится, а писать дважды одно слово нельзя — разойдутся.
---
--- Образцом, а не простым поиском: у `find(заглушка, 1, true)` мутанты
--- начала `0` и `1-1` находят то же самое, и убить их нечем.
local HIDDEN_PATTERN = (Module.HIDDEN:gsub('%p', '%%%0'))

--- Адрес с учётными данными по частям: всё до пароля, пароль и всё после.
---
--- Логин допускается пустым, пароль — нет. Пустой логин в адресе
--- встречается (`http://:слово@хост`), и прятать там пароль надо
--- по-прежнему; пустого же пароля не бывает — двоеточие без ничего
--- означает, что пароля в адресе нет вовсе.
---
--- Один образец на сокрытие и на возврат: адрес делится и собирается
--- обратно по одним и тем же местам, а два образца одного адреса однажды
--- разошлись бы. Пароль при сборке встаёт склейкой, а не заменой, и знаки,
--- значимые для образца замены, ему не страшны.
---@param value any
---@return string|nil head До пароля, вместе с двоеточием
---@return string|nil password
---@return string|nil tail От собаки до конца
local function address_parts(value)
    if type(value) ~= 'string' then
        return nil
    end

    return value:match('^(%a[%w+.%-]*://[^:@/]*:)([^@/]+)(@.*)$')
end

--- Прячет пароль в адресе, оставив всё остальное.
---
--- Хост, порт и логин остаются на виду: по ним оператор и понимает, куда
--- переехал узел. `http://root:hunter2@127.0.0.1:2379` — законная строка
--- в списке адресов хранилища, и без этой замены пароль хранилища уехал бы
--- в разницу целиком.
---@param value string
---@return string
local function without_password(value)
    local head, password, tail = address_parts(value)

    if password == nil then
        return value
    end

    return head .. Module.HIDDEN .. tail
end

--- Копия значения с заглушками вместо секретов.
---
--- Имя раздела подаётся отдельно: по значению секрет не отличить,
--- а по имени — можно.
---@param name any Под каким именем лежит значение
---@param value any
---@return any
function Module.mask(name, value)
    if Module.secret(name) then
        return Module.HIDDEN
    end

    if type(value) == 'string' then
        return without_password(value)
    end

    if type(value) ~= 'table' then
        return value
    end

    local copy = {}

    for key, inner in pairs(value) do
        copy[key] = Module.mask(key, inner)
    end

    return copy
end

--- Прячет секреты в найденных различиях.
---
--- Различие правится на месте, но значения в нём заменяются копиями:
--- сам список сюда приходит свежесобранным, а вот значения в нём —
--- ссылки в чужие таблицы.
---@param differences TntConfigDifference[]
---@return TntConfigDifference[]
function Module.hide(differences)
    for _, difference in ipairs(differences) do
        -- Имя — последнее звено пути. Делением, а не образцом `[^.]+$`:
        -- у образца мутанты `*` и `-` дают то же имя либо пустое, а пустое
        -- имя секретом не считается, как и отсутствующее.
        local segments = tostring(difference.path):split('.')
        local name = segments[#segments]

        -- Отсутствующая сторона так и остаётся отсутствующей: заглушка
        -- вместо неё сказала бы, что раздел был, а его не было.
        if difference.before ~= nil then
            difference.before = Module.mask(name, difference.before)
        end

        if difference.after ~= nil then
            difference.after = Module.mask(name, difference.after)
        end
    end

    return differences
end

--- Путь до раздела.
---@param prefix string
---@param name any
---@return string
local function joined(prefix, name)
    if prefix == '' then
        return tostring(name)
    end

    return ('%s.%s'):format(prefix, tostring(name))
end

--- Возвращает настоящие значения на место заглушек.
---@param candidate table Что прислал оператор
---@param current table|nil Что применено сейчас
---@param prefix string
---@param missing string[]
---@return table
local function put_back(candidate, current, prefix, missing)
    local restored = {}
    local applied = type(current) == 'table' and current or nil

    for key, value in pairs(candidate) do
        local at = applied ~= nil and applied[key] or nil
        local path = joined(prefix, key)

        if value == Module.HIDDEN then
            -- Целиком заглушка: на её месте было значение, и вернуть
            -- можно только его.
            if at == nil then
                table.insert(missing, path)
                restored[key] = value
            else
                restored[key] = at
            end
        elseif type(value) == 'string' and value:find(HIDDEN_PATTERN) ~= nil then
            -- Заглушка внутри адреса: возвращается только пароль, а хост
            -- с логином остаются те, что прислал оператор. Он вправе
            -- переехать, не зная пароля. Заглушка не на месте пароля —
            -- в пути, в логине, рядом с другими знаками — отказ: пароль,
            -- подставленный туда, уехал бы из адреса в чужое поле.
            local _, secret = address_parts(at)
            local head, shown, tail = address_parts(value)

            if secret == nil or shown ~= Module.HIDDEN then
                table.insert(missing, path)
                restored[key] = value
            else
                restored[key] = head .. secret .. tail
            end
        elseif type(value) == 'table' then
            restored[key] = put_back(value, at, path, missing)
        else
            restored[key] = value
        end
    end

    return restored
end

--- Возвращает настоящие значения на место заглушек.
---
--- Обратный ход к `mask`, и без него прятать нельзя вовсе: панель отдаёт
--- конфигурацию текстом и тем же текстом её принимает обратно. Оператор,
--- сохранивший показанное, записал бы слово «скрыто» паролями всех
--- учётных записей кластера — то есть запер бы себя сам.
---
--- Заглушка, которой нечем стать, — отказ, а не пропуск: она означает,
--- что оператор перенёс её туда, где значения не было, и записывать её
--- как есть нельзя тем более. Так же отказывает заглушка внутри строки
--- не на месте пароля: адрес без учётных данных в применённой
--- конфигурации, заглушка в пути или слитая с другими знаками.
---@param candidate table Что прислал оператор
---@param current table|nil Что применено сейчас
---@return table|nil restored
---@return string|nil err
function Module.restore(candidate, current)
    if type(candidate) ~= 'table' then
        return nil, 'конфигурация не разобрана: восстанавливать нечего'
    end

    local missing = {}
    local restored = put_back(candidate, current, '', missing)

    if #missing > 0 then
        table.sort(missing)

        return nil,
            ('заглушку нечем заменить: %s — в применённой конфигурации на этом месте секрета нет'):format(
                table.concat(missing, ', ')
            )
    end

    return restored
end

return Module
