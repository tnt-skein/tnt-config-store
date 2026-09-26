--- Тесты сокрытия секретов. Модуль чистый: на входе имя и значение,
--- на выходе — что увидит человек.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.config.secrets')

local MODULES = helper.modules({ 'tnt.config.secrets' })

---@type any
local secrets

g.before_each(function()
    secrets = helper.load(MODULES, 'tnt.config.secrets')
end)

g.after_each(function()
    helper.unload(MODULES)
end)

-- ── Что считается секретом ───────────────────────────────────────────

g.test_secret_names_are_recognised = function()
    for _, name in ipairs({
        'password',
        'passwd',
        'secret',
        'token',
        'cookie',
        'authorization',
        'key',
        'db_password',
        'api_key',
        'private_key',
        'ssl_key',
        'ssl_password',
        'cluster_cookie',
    }) do
        t.assert_equals(secrets.secret(name), true, name)
    end
end

g.test_password_policy_stays_visible = function()
    -- Сверяется конец имени, а не вхождение подстроки: в схеме ядра лежит
    -- целая политика паролей, и спрятать её значит спрятать от оператора
    -- ровно то, что он обязан видеть.
    for _, name in ipairs({
        'password_min_length',
        'password_lifetime_days',
        'password_history_length',
        'password_enforce_digits',
    }) do
        t.assert_equals(secrets.secret(name), false, name)
    end
end

g.test_addresses_of_secrets_are_not_secrets = function()
    -- Путь к ключу не ключ: по нему проверяют, тот ли файл подставили.
    for _, name in ipairs({ 'ssl_key_file', 'ssl_cert_file', 'login', 'username', 'env' }) do
        t.assert_equals(secrets.secret(name), false, name)
    end
end

g.test_number_of_a_list_element_is_not_a_secret = function()
    t.assert_equals(secrets.secret(1), false)
end

-- ── Подмена значений ─────────────────────────────────────────────────

g.test_password_becomes_a_placeholder = function()
    t.assert_equals(secrets.mask('password', 'hunter2'), secrets.HIDDEN)
end

g.test_section_is_masked_inside = function()
    local masked = secrets.mask('client', { password = 'hunter2', roles = { 'super' } })

    t.assert_equals(masked.password, secrets.HIDDEN)
    -- Права — самое важное в правке: спрятав их, мы спрятали бы
    -- проверяемое.
    t.assert_equals(masked.roles, { 'super' })
end

g.test_list_elements_are_masked_too = function()
    local masked = secrets.mask('listen', {
        { uri = '127.0.0.1:3301', params = { ssl_password = 'hunter2' } },
    })

    t.assert_equals(masked[1].params.ssl_password, secrets.HIDDEN)
    t.assert_equals(masked[1].uri, '127.0.0.1:3301')
end

g.test_original_is_not_touched = function()
    -- `before` и `after` в разнице — ссылки внутрь кандидата, и правка
    -- на месте записала бы слово «скрыто» настоящим паролем кластера.
    local users = { client = { password = 'hunter2' } }

    secrets.mask('users', users)

    t.assert_equals(users.client.password, 'hunter2')
end

g.test_plain_values_pass_through = function()
    t.assert_equals(secrets.mask('timeout', 3), 3)
    t.assert_equals(secrets.mask('enabled', true), true)
    t.assert_equals(secrets.mask('zone', 'a'), 'a')
end

-- ── Адреса с учётными данными ────────────────────────────────────────

g.test_password_in_an_address_is_hidden = function()
    -- Хост, порт и логин остаются на виду: по ним оператор понимает,
    -- куда переехал узел.
    t.assert_equals(
        secrets.mask('endpoints', { 'http://root:hunter2@127.0.0.1:2379' })[1],
        'http://root:' .. secrets.HIDDEN .. '@127.0.0.1:2379'
    )
end

g.test_address_without_credentials_is_untouched = function()
    t.assert_equals(secrets.mask(1, 'http://127.0.0.1:2379'), 'http://127.0.0.1:2379')
    t.assert_equals(secrets.mask(1, '127.0.0.1:3301'), '127.0.0.1:3301')
end

g.test_address_with_an_empty_password_is_untouched = function()
    -- Двоеточие без ничего означает, что пароля в адресе нет вовсе.
    t.assert_equals(secrets.mask(1, 'http://root:@127.0.0.1:2379'), 'http://root:@127.0.0.1:2379')
end

g.test_address_without_a_login_still_hides_the_password = function()
    -- Пустой логин в адресе встречается, и пароль при нём прятать надо
    -- по-прежнему.
    t.assert_equals(
        secrets.mask(1, 'http://:hunter2@127.0.0.1:2379'),
        'http://:' .. secrets.HIDDEN .. '@127.0.0.1:2379'
    )
end

g.test_short_scheme_is_still_an_address = function()
    t.assert_equals(secrets.mask(1, 'a://root:hunter2@host'), 'a://root:' .. secrets.HIDDEN .. '@host')
end

g.test_scheme_with_a_hyphen_is_still_an_address = function()
    -- Дефис в схеме законен (`svn-ssh`), и пароль в таком адресе прячется
    -- так же, как в любом другом.
    t.assert_equals(secrets.mask(1, 'svn-ssh://root:hunter2@host'), 'svn-ssh://root:' .. secrets.HIDDEN .. '@host')
end

g.test_password_is_hidden_whole_whatever_its_characters = function()
    -- Звёздочка в пароле — обычный знак: пароль прячется целиком,
    -- а не до первого непривычного знака.
    t.assert_equals(secrets.mask(1, 'http://root:hun*ter@host'), 'http://root:' .. secrets.HIDDEN .. '@host')
end

g.test_at_sign_in_the_path_is_not_a_password = function()
    -- Реестр пакетов со scope в пути: двоеточие перед портом — не начало
    -- пароля, собака после косой — не конец учётных данных.
    t.assert_equals(secrets.mask(1, 'http://registry:4873/@scope/pkg'), 'http://registry:4873/@scope/pkg')
end

g.test_colon_in_the_path_is_not_a_login = function()
    -- Учётные данные стоят до пути: двоеточие после косой черты логин
    -- не отделяет.
    t.assert_equals(secrets.mask(1, 'http://host/a:b@c'), 'http://host/a:b@c')
end

-- ── Разница ──────────────────────────────────────────────────────────

g.test_differences_are_hidden_on_both_sides = function()
    local hidden = secrets.hide({
        { path = 'credentials.users.client.password', kind = 'changed', before = 'было', after = 'стало' },
    })

    t.assert_equals(hidden[1].before, secrets.HIDDEN)
    t.assert_equals(hidden[1].after, secrets.HIDDEN)
    t.assert_equals(hidden[1].path, 'credentials.users.client.password')
end

g.test_absent_side_stays_absent = function()
    -- Заглушка вместо отсутствующей стороны сказала бы, что раздел был,
    -- а его не было.
    local hidden = secrets.hide({
        { path = 'credentials.users.health.password', kind = 'added', after = 'новый' },
    })

    t.assert_equals(hidden[1].before, nil)
    t.assert_equals(hidden[1].after, secrets.HIDDEN)
end

g.test_whole_user_keeps_its_rights_visible = function()
    local hidden = secrets.hide({
        {
            path = 'credentials.users.health',
            kind = 'added',
            after = { password = 'hunter2', privileges = { { permissions = { 'execute' } } } },
        },
    })

    t.assert_equals(hidden[1].after.password, secrets.HIDDEN)
    t.assert_equals(hidden[1].after.privileges[1].permissions, { 'execute' })
end

-- ── Обратный ход ─────────────────────────────────────────────────────

g.test_placeholder_becomes_the_real_value_again = function()
    -- Панель отдаёт конфигурацию текстом и тем же текстом принимает
    -- обратно: без возврата оператор записал бы слово «скрыто» паролями
    -- всех учётных записей.
    local restored = secrets.restore(
        { credentials = { users = { client = { password = secrets.HIDDEN } } } },
        { credentials = { users = { client = { password = 'hunter2' } } } }
    )

    t.assert_equals(restored.credentials.users.client.password, 'hunter2')
end

g.test_real_new_value_survives_the_restore = function()
    local restored = secrets.restore(
        { credentials = { users = { client = { password = 'новый' } } } },
        { credentials = { users = { client = { password = 'hunter2' } } } }
    )

    t.assert_equals(restored.credentials.users.client.password, 'новый')
end

g.test_placeholder_with_nothing_to_restore_is_refused = function()
    -- Заглушка, которой нечем стать, означает, что оператор перенёс её
    -- туда, где значения не было: записывать её как есть нельзя тем более.
    local restored, err = secrets.restore(
        { credentials = { users = { health = { password = secrets.HIDDEN } } } },
        { credentials = { users = { client = { password = 'hunter2' } } } }
    )

    t.assert_equals(restored, nil)
    t.assert_str_contains(err, 'credentials.users.health.password')
end

g.test_password_inside_an_address_is_restored = function()
    local restored = secrets.restore(
        { config = { etcd = { endpoints = { 'http://root:' .. secrets.HIDDEN .. '@127.0.0.1:2379' } } } },
        { config = { etcd = { endpoints = { 'http://root:hunter2@127.0.0.1:2379' } } } }
    )

    t.assert_equals(restored.config.etcd.endpoints[1], 'http://root:hunter2@127.0.0.1:2379')
end

g.test_operator_may_move_the_host_without_knowing_the_password = function()
    -- Возвращается только пароль: хост с логином остаются те, что прислал
    -- оператор, и переезд узла не требует знания пароля.
    local restored = secrets.restore(
        { config = { etcd = { endpoints = { 'http://root:' .. secrets.HIDDEN .. '@10.0.0.9:2379' } } } },
        { config = { etcd = { endpoints = { 'http://root:hunter2@127.0.0.1:2379' } } } }
    )

    t.assert_equals(restored.config.etcd.endpoints[1], 'http://root:hunter2@10.0.0.9:2379')
end

g.test_address_placeholder_with_nothing_to_restore_is_refused = function()
    -- Два случая, и оба означают одно: пароля, который надо вернуть,
    -- в применённой конфигурации нет. В первом адрес есть, но без
    -- учётных данных; во втором адреса нет вовсе.
    local shown = { config = { etcd = { endpoints = { 'http://root:' .. secrets.HIDDEN .. '@10.0.0.9:2379' } } } }

    local restored, err = secrets.restore(shown, { config = { etcd = { endpoints = { 'http://127.0.0.1:2379' } } } })

    t.assert_equals(restored, nil)
    t.assert_str_contains(err, 'config.etcd.endpoints.1')

    t.assert_equals(secrets.restore(shown, { config = { etcd = { endpoints = {} } } }), nil)
    t.assert_equals(secrets.restore(shown, {}), nil)
end

g.test_placeholder_outside_the_password_is_refused = function()
    -- Пароль возвращается только на место пароля: подставленный в путь
    -- или приклеенный к другим знакам, он уехал бы из адреса в чужое поле.
    local applied = { config = { etcd = { endpoints = { 'http://root:hunter2@127.0.0.1:2379' } } } }

    for _, shown in ipairs({
        'http://127.0.0.1:2379/' .. secrets.HIDDEN,
        'http://root:x' .. secrets.HIDDEN .. '@127.0.0.1:2379',
        'http://' .. secrets.HIDDEN .. ':@127.0.0.1:2379',
    }) do
        local restored, err = secrets.restore({ config = { etcd = { endpoints = { shown } } } }, applied)

        t.assert_equals(restored, nil, shown)
        t.assert_equals(
            err,
            'заглушку нечем заменить: config.etcd.endpoints.1 — в применённой конфигурации на этом месте секрета нет',
            shown
        )
    end
end

g.test_password_with_pattern_characters_is_restored_as_is = function()
    -- Пароль встаёт склейкой: знаки, значимые для образца замены,
    -- в нём остаются собой.
    local restored = secrets.restore(
        { endpoints = { 'http://root:' .. secrets.HIDDEN .. '@10.0.0.9:2379' } },
        { endpoints = { 'http://root:a%1b%%c@127.0.0.1:2379' } }
    )

    t.assert_equals(restored.endpoints[1], 'http://root:a%1b%%c@10.0.0.9:2379')
end

g.test_untouched_configuration_survives_the_restore = function()
    local candidate = { labels = { zone = 'a' }, iproto = { listen = { 'x' } } }
    local restored = secrets.restore(candidate, {})

    t.assert_equals(restored, candidate)
end

g.test_nothing_to_restore_is_refused = function()
    t.assert_equals(secrets.restore(nil, {}), nil)
    t.assert_str_contains(select(2, secrets.restore('текст', {})), 'не разобрана')
end
