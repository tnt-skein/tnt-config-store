# tnt-config-store

Правка конфигурации кластера Tarantool 3.x, которая не роняет кластер:
сверка правки с действующей топологией, раскатка в три фазы — проверить
у всех, записать один раз, дождаться, — правка по кускам, разница
без паролей, история ревизий в etcd и функции, которыми узел отвечает
раскатке.

```lua
local rollout = require('tnt.config.rollout')

local result = rollout.apply({
    current = current,              -- что применено сейчас
    patch = { { path = 'app.cfg.limit', value = 100 } },
    revision = stored.revision,     -- запись пройдёт только поверх этой ревизии
    targets = { 'storage-001-a', 'storage-002-a' },
    validate = validate, write = write, applied = applied,
})

result.phase     --> 'converge': кандидата приняли все, записан одной транзакцией
result.pending   --> {}: каждый узел доложил, что применил новую ревизию
```

Зависимости: [tnt-async](https://github.com/tnt-skein/tnt-async),
[tnt-clock](https://github.com/tnt-skein/tnt-clock),
[tnt-collection](https://github.com/tnt-skein/tnt-collection),
[tnt-context](https://github.com/tnt-skein/tnt-context),
[tnt-external](https://github.com/tnt-skein/tnt-external),
[tnt-fingerprint](https://github.com/tnt-skein/tnt-fingerprint),
[tnt-str](https://github.com/tnt-skein/tnt-str). Клиент хранилища —
например, [tnt-etcd-client](https://github.com/tnt-skein/tnt-etcd-client) —
пакет получает аргументом.

## Зачем

- **Правка, которую ядро примет, а кластер нет.** Схему конфигурации
  проверяет ядро, но вычеркнутый узел, узел, переехавший в другой
  репликасет, и два узла с одним адресом синтаксически безупречны.
  Сверка топологии находит их до записи и возвращает все возражения
  разом.
- **Согласованное применение.** Запись в общий источник каждый узел
  применяет сам. Раскатка сперва даёт кандидата на проверку всем узлам,
  ничего не применяя, пишет его одной транзакцией, обусловленной
  прочитанной ревизией, и ждёт, пока каждый доложит, что применил, —
  а кто не доложил, называет с причиной.
- **Разница без паролей.** Разница по разделам, а не по строкам; пароль
  в ней — факт «изменился», не значение, а показанное с заглушками
  принимается обратно с настоящими значениями.
- **Правка по кускам.** Назвать путь и значение; всё остальное, включая
  чужие правки между чтением и записью, остаётся как было.

## Установка

```sh
tt rocks install tnt-config-store --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-config-store.git
cd tnt-config-store && tt rocks make --server=https://tnt-skein.github.io/rocks
```

## Как пользоваться

| Модуль | Что делает |
|---|---|
| `tnt.config.rollout` | `apply(request)` — раскатка в три фазы; итог называет фазу, разницу, сошедшихся и отставших |
| `tnt.config.node` | `publish()` — функции узла `config_check`, `config_applied`, `config_write`; `configure({ revision, path })` |
| `tnt.config.topology` | `acceptable(current, candidate, opts)` — годится ли правка и все возражения |
| `tnt.config.patch` | `apply(current, changes)` — кандидат из правок по путям |
| `tnt.config.diff` | `of(before, after)`, `describe(difference)` — разница по разделам |
| `tnt.config.secrets` | `mask(name, value)`, `restore(candidate, current)` — заглушки и их возврат |
| `tnt.config.history` | `record`, `list`, `get`, `prune` — история ревизий в etcd |
| `tnt.config.file` | `write(path, text)` — файл конфигурации без половинок |

Функции `validate`, `write` и `applied` пишет приложение: только оно знает,
где хранится конфигурация и как дойти до узлов; узел отвечает на них
функциями `tnt.config.node`. Правка по кускам и разница работают и без
раскатки — например, чтобы показать правку до записи:

```lua
local patch = require('tnt.config.patch')
local diff = require('tnt.config.diff')

local candidate = patch.apply(current, {
    { path = 'app.cfg.limit', value = 100 },
    { path = 'credentials.users.replicator.password', value = 'secret-2' },
})

for _, difference in ipairs(diff.of(current, candidate)) do
    print(diff.describe(difference))
end
--> изменено app.cfg.limit: было 50, стало 100
--> изменено credentials.users.replicator.password: было [скрыто], стало [скрыто]
```

## Проверки

```sh
make deps          # luatest, luacheck, luacov, cluacov, зависимости пакета и tnt-etcd-client в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
```

Проверок — 205; покрытие строк — 100 %, убитых мутантов — 100 %
(452 мутанта в восьми модулях). Узлы, хранилище и часы подменяются;
веер, разбор конфигурации ядром и диск — настоящие.

## Документ

Полное описание с обоснованием решений: [docs/config-store.md](docs/config-store.md).

## Лицензия

MIT.
