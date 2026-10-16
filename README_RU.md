# Лабораторная работа №1

Скрипт `manage_logs.sh` проверяет заполнение папки логов. Если оно превышает
порог X% — архивирует N самых старых файлов в `/backup` и удаляет их из
исходной папки. Удаление происходит только после успешной архивации.

## Использование (Linux/macOS/WSL)

    ./manage_logs.sh LOG_DIR [THRESHOLD_PERCENT] [CAPACITY_MIB] [BACKUP_DIR]

Примеры:

    ./manage_logs.sh ./logs
    ./manage_logs.sh ./logs 50
    ./manage_logs.sh ./logs 50 2000 /tmp/backup

Переменная окружения `LAB1_MAX_COMPRESSION=1` — использовать `tar --lzma`.

## Использование (Windows)

    manage_logs.bat LOG_DIR [THRESHOLD_PERCENT] [CAPACITY_MIB] [BACKUP_DIR]

## Тесты

Linux:

    ./test_manage_logs.sh

Windows:

    test_manage_logs.bat

Оба набора содержат 5 тестов, каждый использует не менее 500 MiB данных
и работает без root-прав.
