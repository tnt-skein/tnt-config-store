-- Формат 3.0: в нём есть test_dependencies — зависимости проверок,
-- которые не ставятся тому, кто берёт пакет для дела.
rockspec_format = '3.0'

package = 'tnt-config-store'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-config-store.git',
    branch = 'main',
}

description = {
    summary = 'Правка конфигурации кластера Tarantool 3.x: проверка, раскатка в три фазы, история',
    detailed = [[
        Схему конфигурации кластера проверяет само ядро Tarantool 3.x:
        оно отвергнет неизвестное поле и неверный тип. Не проверяет
        оно другое — не сломает ли правка живой кластер: вычеркнутый
        узел, узел, переехавший в другой репликасет, два узла с одним
        адресом. Пакет находит такие правки до записи.

        Согласованного применения в ядре тоже нет: запись в общий
        источник каждый узел применяет сам и когда придётся, и признака
        «все сошлись на этой ревизии» не существует. Раскатка идёт
        в три фазы: кандидата проверяют все узлы, ничего не применяя,
        затем он пишется одной транзакцией, обусловленной прочитанной
        ревизией, и раскатка ждёт, пока каждый узел доложит, что
        применил её, — а кто не доложил, называет.

        Вокруг раскатки — правка по кускам по путям, разница по разделам
        с заглушками вместо паролей и их возвратом, история ревизий
        рядом с конфигурацией в etcd с контрольной суммой, функции узла
        для проверки кандидата и доклада о применённом, запись файла
        конфигурации для кластера без хранилища.

        Клиент хранилища пакет получает аргументом, а не берёт сам.
        Зависит от tnt-async, tnt-clock, tnt-collection, tnt-context,
        tnt-external, tnt-fingerprint и tnt-str. Покрытие строк
        и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-config-store',
    issues_url = 'https://github.com/tnt-skein/tnt-config-store/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'config', 'cluster', 'etcd', 'rollout' },
}

dependencies = {
    'lua >= 5.1',
    -- Узлы спрашиваются веером, с одним сроком на фазу раскатки.
    'tnt-async',
    -- Внешние зависимости — диск и сведения ядра — подменяются в проверках.
    'tnt-external',
    -- Срок схождения и паузы между опросами узлов.
    'tnt-clock',
    -- Разделы и ревизии по порядку.
    'tnt-collection',
    -- Перенос раскатчика последним аргументом функций узла.
    'tnt-context',
    -- Контрольная сумма ревизии в истории.
    'tnt-fingerprint',
    -- Значение в описании разницы режется знаками, а не байтами.
    'tnt-str',
}

-- Настоящий клиент нужен только проверкам: сам пакет получает
-- его аргументом, а не через require.
test_dependencies = {
    'tnt-etcd-client',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.config.topology'] = 'tnt/config/topology.lua',
        ['tnt.config.rollout'] = 'tnt/config/rollout.lua',
        ['tnt.config.node'] = 'tnt/config/node.lua',
        ['tnt.config.history'] = 'tnt/config/history.lua',
        ['tnt.config.patch'] = 'tnt/config/patch.lua',
        ['tnt.config.diff'] = 'tnt/config/diff.lua',
        ['tnt.config.file'] = 'tnt/config/file.lua',
        ['tnt.config.secrets'] = 'tnt/config/secrets.lua',
    },
}
