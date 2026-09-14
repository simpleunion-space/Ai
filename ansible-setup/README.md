# ansible-setup

Самостоятельный Ansible-модуль. По inventory задаёт hostname (когда он указан)
и создаёт на всех перечисленных хостах четыре системные учётные записи:

| Аккаунт   | UID:GID     | Shell     | SSH-ключ | sudo                 | Пароль |
|-----------|-------------|-----------|----------|----------------------|--------|
| storage   | 20000:20000 | /bin/bash | нет      | нет                  | вход по паролю заблокирован |
| service   | 10000:10000 | /bin/bash | нет      | нет                  | вход по паролю заблокирован |
| setup     | 9999:9999   | /bin/bash | да       | без пароля (NOPASSWD)| не задаётся |
| kurkinps  | 30000:30000 | /bin/bash | да       | обычный (с паролем)  | задаётся локально при наличии `password_plaintext` |

Поле `password_plaintext` допускается только в локальном игнорируемом
inventory. Роль преобразует его в SHA-512 hash с постоянной для пары
хост/аккаунт солью и скрывает задачу из вывода Ansible. Не добавляйте
plaintext-пароли в отслеживаемые файлы.

Для `kurkinps` добавьте поле рядом с остальными параметрами аккаунта в
локальном inventory:

```yaml
password_plaintext: <локальный пароль>
```

Чтобы задать hostname, раскомментируйте и заполните `target_hostname` в блоке
нужного хоста. Если переменная не задана, системное имя не меняется.

## Структура

```text
ansible-setup/
├── ansible.cfg
├── requirements.yml
├── playbook.yml
├── requirements.txt        # Python-зависимости control node
├── roles/
│   └── accounts/          # общая для всех inventory роль
│       ├── defaults/main.yml
│       └── tasks/main.yml
│   └── system/             # необязательная настройка hostname
│       ├── defaults/main.yml
│       └── tasks/main.yml
└── inventories/
    └── <name>/             # один каталог на площадку/проект
        ├── inventory.yaml
        └── group_vars/
            └── all.yml     # реальные UID/GID/ключи для этой площадки
```

Новая площадка добавляется как ещё один каталог под `inventories/`, без
изменений в роли `accounts`.

## Зависимости

```bash
ansible-galaxy collection install -r requirements.yml
python -m pip install -r requirements.txt
```

`requirements.txt` устанавливает `passlib`, необходимый control node для
преобразования `password_plaintext` в SHA-512 hash.

## Запуск

```bash
ansible-playbook -i inventories/<name>/inventory.yaml playbook.yml --check --diff   # сухой прогон
ansible-playbook -i inventories/<name>/inventory.yaml playbook.yml                  # реальный
```

## Локальный inventory и первое подключение

Создайте или используйте локальный `inventories/<name>/inventory.yaml`. Добавьте
разные `ansible_user` и `ansible_password` под каждым host, а чувствительные
значения из `accounts_list`, включая `password_plaintext`, храните только там.
Файлы под `inventories/` намеренно игнорируются Git, поэтому учётные данные не
попадут в репозиторий.

Если пользователя `setup` на хосте ещё нет, самый первый прогон должен идти
под каким-то УЖЕ существующим пользователем (root по паролю/ключу или другой
существующий sudo-аккаунт) — именно он создаст `setup` и остальных. При
необходимости переопределите подключение, например:

```bash
ansible-playbook -i inventories/<name>/inventory.yaml playbook.yml \
  -u root --ask-pass       # или -u root --private-key ~/.ssh/<ключ>
```

После первого прогона, когда `setup` уже создан со своим ключом и
NOPASSWD-sudo, обычные последующие прогоны выполняются под ним.
