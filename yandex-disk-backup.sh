#!/bin/bash

# ==================================================
# Настройки скрипта
# ==================================================

# Часовой пояс (по умолчанию - Московское время)
TIMEZONE="Europe/Moscow"

# OAuth-токен для доступа к Яндекс.Диску
TOKEN="y0u_OAuth_ToKen-Insert_here"

# Настройки уведомлений в Telegram
TELEGRAM_NOTIFICATIONS=0  # 0 - выключены, 1 - включены
TELEGRAM_BOT_TOKEN="your_bot_token"  # Токен бота Telegram
TELEGRAM_CHAT_ID="your_chat_id"  # ID чата для уведомлений

# Название папки на Яндекс.Диске для хранения бэкапов
YANDEX_FOLDER="Резервные копии"

# Имя сервера (используется для формирования структуры папок)
SERVER_NAME="SoloBot"

# Массив элементов для резервного копирования
# Формат: "Имя элемента|Путь к файлу/папке|Исключения (через запятую)|d:дней хранения|c:количество копий"  

# Пример: 
#   "nginx|/etc/nginx|venv|c:5"
#   "postgresql|/var/lib/postgresql||d:30|c:10"
#   "my-app|/opt/myapp|temp,logs|d:14"
 
BACKUP_ITEMS=(
# Пример для бэкапа бота
    "solobot|/root/solobot|venv|d:7"
    "ssl|/etc/letsencrypt/live||d:7"
    "html|/var/www/html||d:7"
    "nginx-config|/etc/nginx/sites-available||d:7"
    "ydb|/root/yandex-disk-backup||c:10"

# Пример для бэкапа 3x-ui
#    "3x-ui|/etc/x-ui||d:7"
#    "ssl|/root/cert||d:7"
#    "nginx|/etc/nginx/sites-available/default||d:7"
#    "html|/var/www/html/||d:7"
#    "ydb|/root/yandex-disk-backup||c:10"
)

# Настройки резервного копирования баз данных
ENABLE_MYSQL_BACKUP=0  # 0 - отключено, 1 - включено
ENABLE_POSTGRES_BACKUP=0  # 0 - отключено, 1 - включено

# Базы данных MySQL для резервного копирования
# Формат: "Название|Имя БД|Пользователь|Пароль|Порт|d:дней хранения|c:количество копий"
MYSQL_DATABASES=(
    "my-db-backup|my_database|root|password|3306|d:7"
    "another-db-backup|another_db|admin|secret|3307|c:5"
)

# Базы данных PostgreSQL для резервного копирования
# Формат: "Название|Имя БД|Пользователь|Пароль|Порт|d:дней хранения|c:количество копий"


POSTGRES_DATABASES=(
    "solobot-db|solod_db|myuser|oC0hY58JrF0xdU|5432|d:7"
)

# Максимальное количество потоков для многопоточности
MAX_THREADS=4

# Режим отладки (0 - выключен, 1 - включен)
DEBUG=0

# Файл для записи логов (в той же папке, откуда запускается скрипт)
LOG_FILE="$(dirname "$0")/yandex-disk-backup.log"

# ==================================================
# Цвета для вывода в терминал
# ==================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # Сброс цвета

# ==================================================
# Функции
# ==================================================

# Функция для вывода отладочных сообщений
debug_log() {
    if [[ "$DEBUG" -eq 1 ]]; then
        echo -e "${BLUE}[DEBUG] $1${NC}" | tee -a "$LOG_FILE"
    fi
}

# Функция для логирования сообщений
log() {
    local LEVEL="$1"
    local MESSAGE="$2"
    local COLOR

    case "$LEVEL" in
        INFO) COLOR="${GREEN}" ;;
        WARNING) COLOR="${YELLOW}" ;;
        ERROR) COLOR="${RED}" ;;
        *) COLOR="${NC}" ;;
    esac

    echo -e "${COLOR}$(date '+%Y-%m-%d %H:%M:%S') - [$LEVEL] $MESSAGE${NC}" | tee -a "$LOG_FILE"
}

# Функция для отправки уведомлений в Telegram
send_telegram_notification() {
    if [[ "$TELEGRAM_NOTIFICATIONS" -eq 1 ]]; then
        local MESSAGE="$1"
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d "chat_id=$TELEGRAM_CHAT_ID" \
            -d "text=$MESSAGE" > /dev/null
    fi
}

# Функция для проверки зависимостей
check_dependencies() {
    local dependencies=("curl" "jq" "tar" "gzip")
    if [[ "$ENABLE_MYSQL_BACKUP" -eq 1 ]]; then
        dependencies+=("mysqldump")
    fi
    if [[ "$ENABLE_POSTGRES_BACKUP" -eq 1 ]]; then
        dependencies+=("pg_dump")
    fi

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log "ERROR" "Ошибка: $dep не установлен. Установите его и повторите попытку."
            send_telegram_notification "Ошибка: $dep не установлен. Установите его и повторите попытку."
            exit 1
        fi
    done
}

# Функция для проверки валидности OAuth-токена
check_token() {
    local RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: OAuth $TOKEN" \
        "https://cloud-api.yandex.net/v1/disk")
    if [[ "$RESPONSE" != "200" ]]; then
        log "ERROR" "Ошибка: неверный OAuth-токен."
        send_telegram_notification "Ошибка: неверный OAuth-токен."
        exit 1
    fi
}

# Функция для проверки свободного места на Яндекс.Диске
check_yandex_disk_space() {
    local REQUIRED_SPACE="$1"
    local AVAILABLE_SPACE=$(curl -s -H "Authorization: OAuth $TOKEN" \
        "https://cloud-api.yandex.net/v1/disk" | jq -r '.total_space - .used_space')
    if [[ "$REQUIRED_SPACE" -gt "$AVAILABLE_SPACE" ]]; then
        log "ERROR" "Ошибка: недостаточно свободного места на Яндекс.Диске."
        send_telegram_notification "Ошибка: недостаточно свободного места на Яндекс.Диске."
        exit 1
    fi
}

# Функция для проверки целостности архива
check_archive_integrity() {
    local ARCHIVE_PATH="$1"
    if ! gzip -t "$ARCHIVE_PATH" &> /dev/null; then
        log "ERROR" "Ошибка: архив $ARCHIVE_PATH поврежден."
        send_telegram_notification "Ошибка: архив $ARCHIVE_PATH поврежден."
        rm -f "$ARCHIVE_PATH"  # Удаляем поврежденный архив
        exit 1
    else
        log "INFO" "Архив $ARCHIVE_PATH успешно проверен на целостность."
    fi
}

# Функция для кодирования строки в URL-формат
urlencode() {
    echo -n "$1" | jq -sRr @uri
}

# Функция для создания папок на Яндекс.Диске
create_yandex_folder() {
    local FOLDER_PATH="$1"
    local ENCODED_PATH=$(urlencode "$FOLDER_PATH")
    local RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
        -H "Authorization: OAuth $TOKEN" \
        "https://cloud-api.yandex.net/v1/disk/resources?path=$ENCODED_PATH")
    
    if [[ "$RESPONSE" == "201" ]]; then
        debug_log "Папка $FOLDER_PATH создана."
    elif [[ "$RESPONSE" == "409" ]]; then
        debug_log "Папка $FOLDER_PATH уже существует."
    else
        log "ERROR" "Ошибка: не удалось создать папку $FOLDER_PATH. Код ответа: $RESPONSE"
        send_telegram_notification "Ошибка: не удалось создать папку $FOLDER_PATH. Код ответа: $RESPONSE"
        exit 1
    fi
}

# Функция для загрузки файла на Яндекс.Диск
upload_file() {
    local LOCAL_PATH="$1"
    local DISK_PATH="$2"

    # Кодируем путь для URL
    local ENCODED_DISK_PATH=$(urlencode "$DISK_PATH")

    # Получаем URL для загрузки
    RESPONSE=$(curl -s -H "Authorization: OAuth $TOKEN" \
        "https://cloud-api.yandex.net/v1/disk/resources/upload?path=$ENCODED_DISK_PATH&overwrite=true")
    debug_log "Ответ API: $RESPONSE"

    UPLOAD_URL=$(echo "$RESPONSE" | jq -r '.href')

    if [ -z "$UPLOAD_URL" ] || [ "$UPLOAD_URL" == "null" ]; then
        log "ERROR" "Ошибка: не удалось получить ссылку для загрузки!"
        log "ERROR" "Проверьте путь: $DISK_PATH"
        log "ERROR" "Ответ API: $RESPONSE"
        send_telegram_notification "Ошибка: не удалось получить ссылку для загрузки!"
        exit 1
    fi

    # Загружаем файл или папку
    if [[ -f "$LOCAL_PATH" ]]; then
        log "INFO" "Начало загрузки файла: $LOCAL_PATH"
        curl -T "$LOCAL_PATH" -H "Authorization: OAuth $TOKEN" "$UPLOAD_URL" >/dev/null 2>&1
        log "INFO" "Загрузка файла завершена: $LOCAL_PATH"
    elif [[ -d "$LOCAL_PATH" ]]; then
        # Архивируем папку и загружаем архив
        ARCHIVE_NAME="$(basename "$LOCAL_PATH").tar.gz"
        TEMP_ARCHIVE="/tmp/$ARCHIVE_NAME"
        log "INFO" "Начало архивирования: $LOCAL_PATH"
        tar -czf "$TEMP_ARCHIVE" -C "$(dirname "$LOCAL_PATH")" "$(basename "$LOCAL_PATH")"
        log "INFO" "Архивирование завершено: $TEMP_ARCHIVE"

        # Проверяем целостность архива
        check_archive_integrity "$TEMP_ARCHIVE"

        # Загружаем архив на Яндекс.Диск
        log "INFO" "Начало загрузки архива: $TEMP_ARCHIVE"
        curl -T "$TEMP_ARCHIVE" -H "Authorization: OAuth $TOKEN" "$UPLOAD_URL" >/dev/null 2>&1
        log "INFO" "Загрузка архива завершена: $TEMP_ARCHIVE"

        # Удаляем временный архив
        if rm -f "$TEMP_ARCHIVE"; then
            log "INFO" "Временный архив $TEMP_ARCHIVE успешно удален."
        else
            log "ERROR" "Ошибка при удалении временного архива: $TEMP_ARCHIVE"
        fi
    fi

    if [ $? -eq 0 ]; then
        log "INFO" "Файл/папка успешно загружены на Яндекс.Диск: $DISK_PATH"
        send_telegram_notification "Файл/папка успешно загружены на Яндекс.Диск: $DISK_PATH"
    else
        log "ERROR" "Ошибка: загрузка файла/папки не удалась!"
        send_telegram_notification "Ошибка: загрузка файла/папки не удалась!"
        exit 1
    fi
}

# Функция для удаления старых резервных копий
delete_old_backups() {
    local YANDEX_BASE_PATH="$1"
    local DAYS_TO_KEEP="$2"
    local COPIES_TO_KEEP="$3"

    # Получаем список файлов в папке
    ENCODED_PATH=$(urlencode "$YANDEX_BASE_PATH")
    RESPONSE=$(curl -s -H "Authorization: OAuth $TOKEN" \
        "https://cloud-api.yandex.net/v1/disk/resources?path=$ENCODED_PATH&limit=1000")
    FILES=$(echo "$RESPONSE" | jq -r '._embedded.items[] | select(.type == "file") | .name + "|" + .created')

    # Сортируем файлы по дате создания (от старых к новым)
    SORTED_FILES=$(echo "$FILES" | sort -t '|' -k2)

    # Удаляем файлы, если превышено количество дней хранения
    if [[ -n "$DAYS_TO_KEEP" ]]; then
        CURRENT_TIME=$(date +%s)
        while IFS='|' read -r FILE_NAME CREATED_DATE; do
            FILE_TIME=$(date -d "$CREATED_DATE" +%s)
            DIFF_DAYS=$(( (CURRENT_TIME - FILE_TIME) / 86400 ))
            if [[ "$DIFF_DAYS" -gt "$DAYS_TO_KEEP" ]]; then
                ENCODED_FILE_PATH=$(urlencode "$YANDEX_BASE_PATH/$FILE_NAME")
                curl -s -X DELETE -H "Authorization: OAuth $TOKEN" \
                    "https://cloud-api.yandex.net/v1/disk/resources?path=$ENCODED_FILE_PATH"
                log "INFO" "Удален файл: $FILE_NAME (возраст: $DIFF_DAYS дней)"
                send_telegram_notification "Удален файл: $FILE_NAME (возраст: $DIFF_DAYS дней)"
            fi
        done <<< "$SORTED_FILES"
    fi

    # Удаляем файлы, если превышено количество копий
    if [[ -n "$COPIES_TO_KEEP" ]]; then
        TOTAL_FILES=$(echo "$SORTED_FILES" | wc -l)
        if [[ "$TOTAL_FILES" -gt "$COPIES_TO_KEEP" ]]; then
            FILES_TO_DELETE=$((TOTAL_FILES - COPIES_TO_KEEP))
            while IFS='|' read -r FILE_NAME CREATED_DATE; do
                if [[ "$FILES_TO_DELETE" -le 0 ]]; then
                    break
                fi
                ENCODED_FILE_PATH=$(urlencode "$YANDEX_BASE_PATH/$FILE_NAME")
                curl -s -X DELETE -H "Authorization: OAuth $TOKEN" \
                    "https://cloud-api.yandex.net/v1/disk/resources?path=$ENCODED_FILE_PATH"
                log "INFO" "Удален файл: $FILE_NAME (старая копия)"
                send_telegram_notification "Удален файл: $FILE_NAME (старая копия)"
                FILES_TO_DELETE=$((FILES_TO_DELETE - 1))
            done <<< "$SORTED_FILES"
        fi
    fi
}

# Функция для проверки, пуста ли папка
is_folder_empty() {
    local FOLDER_PATH="$1"
    if [[ -d "$FOLDER_PATH" ]]; then
        if [[ -z "$(ls -A "$FOLDER_PATH")" ]]; then
            return 0  # Папка пуста
        else
            return 1  # Папка не пуста
        fi
    else
        return 2  # Это не папка
    fi
}

# Функция для резервного копирования базы данных
backup_database() {
    local DB_TYPE="$1"
    local BACKUP_NAME="$2"  # Это имя берется из первого элемента массива (например, "my-db-backup")
    local DB_NAME="$3"      # Это имя базы данных (например, "my_database")
    local DB_USER="$4"
    local DB_PASS="$5"
    local DB_PORT="$6"
    local BACKUP_FILE_NAME="${DB_NAME}-$(date +"%d%m%y-%H%M").sql.gz"  # Используем DB_NAME вместо BACKUP_NAME
    local BACKUP_PATH="/tmp/${BACKUP_FILE_NAME}"

    case "$DB_TYPE" in
        mysql)
            mysqldump -u "$DB_USER" -p"$DB_PASS" -h localhost -P "$DB_PORT" "$DB_NAME" | gzip > "$BACKUP_PATH"
            ;;
        postgres)
            PGPASSWORD="$DB_PASS" pg_dump -U "$DB_USER" -h localhost -p "$DB_PORT" "$DB_NAME" | gzip > "$BACKUP_PATH"
            ;;
        *)
            log "ERROR" "Неподдерживаемый тип базы данных: $DB_TYPE"
            send_telegram_notification "Неподдерживаемый тип базы данных: $DB_TYPE"
            return
            ;;
    esac

    if [[ $? -eq 0 ]]; then
        log "INFO" "Резервная копия базы данных $DB_NAME успешно создана."
        send_telegram_notification "Резервная копия базы данных $DB_NAME успешно создана."

        # Создаем папку на Яндекс.Диске с именем базы данных
        YANDEX_DATABASES_PATH="disk:/${YANDEX_FOLDER}/${SERVER_NAME}/${BACKUP_NAME}"
        create_yandex_folder "$YANDEX_DATABASES_PATH"

        # Загружаем файл на Яндекс.Диск
        upload_file "$BACKUP_PATH" "${YANDEX_DATABASES_PATH}/${BACKUP_FILE_NAME}"

        # Удаляем временный файл
        if rm -f "$BACKUP_PATH"; then
            log "INFO" "Временный файл $BACKUP_PATH успешно удален."
        else
            log "ERROR" "Ошибка при удалении временного файла: $BACKUP_PATH"
            send_telegram_notification "Ошибка при удалении временного файла: $BACKUP_PATH"
        fi
    else
        log "ERROR" "Ошибка при создании резервной копии базы данных $DB_NAME."
        send_telegram_notification "Ошибка при создании резервной копии базы данных $DB_NAME."
        rm -f "$BACKUP_PATH"
    fi
}

# Основной цикл для обработки элементов резервного копирования
process_backup_item() {
    local item="$1"
    # Разделяем строку на имя элемента, путь, исключения и параметры хранения
    IFS='|' read -r ITEM_NAME SOURCE_PATH EXCLUSIONS STORAGE_PARAMS <<< "$item"

    # Приводим имя файла к нижнему регистру
    BACKUP_NAME=$(echo "${SERVER_NAME}-${ITEM_NAME}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

    # Устанавливаем часовой пояс
    export TZ="$TIMEZONE"

    # Текущая дата и время в формате ДДММГГ-ЧЧММ
    NOW=$(date +"%d%m%y-%H%M")

    # Формируем имя файла/архива
    BACKUP_NAME="${BACKUP_NAME}-${NOW}.tar.gz"

    # Формируем путь на Яндекс.Диске (папки сохраняют регистр, имя файла в нижнем регистре)
    YANDEX_BASE_PATH="disk:/${YANDEX_FOLDER}/${SERVER_NAME}/${ITEM_NAME}"
    YANDEX_PATH="${YANDEX_BASE_PATH}/${BACKUP_NAME}"

    # Проверка наличия исходного файла/папки
    if [[ ! -e "$SOURCE_PATH" ]]; then
        log "ERROR" "Ошибка: файл/папка $SOURCE_PATH не найдены!"
        send_telegram_notification "Ошибка: файл/папка $SOURCE_PATH не найдены!"
        return
    fi

    # Проверка, является ли путь папкой и пуста ли она
    if [[ -d "$SOURCE_PATH" ]]; then
        if is_folder_empty "$SOURCE_PATH"; then
            log "INFO" "Папка $SOURCE_PATH пуста. Пропускаем резервное копирование."
            send_telegram_notification "Папка $SOURCE_PATH пуста. Пропускаем резервное копирование."
            return
        fi
    fi

    log "INFO" "Обработка элемента: $ITEM_NAME"
    log "INFO" "Источник: $SOURCE_PATH"

    # Создание всех родительских папок на Яндекс.Диске
    IFS='/' read -r -a PATH_PARTS <<< "$YANDEX_BASE_PATH"
    CURRENT_PATH="disk:"

    for part in "${PATH_PARTS[@]:1}"; do
        CURRENT_PATH="$CURRENT_PATH/$part"
        if [[ "$CURRENT_PATH" != "$YANDEX_PATH" ]]; then
            create_yandex_folder "$CURRENT_PATH"
        fi
    done

    # Архивирование и загрузка
    if [[ -d "$SOURCE_PATH" ]]; then
        # Создаем временный архив
        TEMP_ARCHIVE="/tmp/${BACKUP_NAME}"
        EXCLUDE_ARGS=""

        # Добавляем исключения, если они есть
        if [[ -n "$EXCLUSIONS" ]]; then
            IFS=',' read -r -a EXCLUDE_LIST <<< "$EXCLUSIONS"
            for exclude in "${EXCLUDE_LIST[@]}"; do
                EXCLUDE_ARGS+=" --exclude=${exclude}"
            done
        fi

        # Архивируем папку с учетом исключений
        log "INFO" "Начало архивирования: $SOURCE_PATH"
        tar -czf "$TEMP_ARCHIVE" -C "$(dirname "$SOURCE_PATH")" $EXCLUDE_ARGS "$(basename "$SOURCE_PATH")"
        log "INFO" "Архивирование завершено: $TEMP_ARCHIVE"

        # Проверяем целостность архива
        check_archive_integrity "$TEMP_ARCHIVE"

        # Загружаем архив на Яндекс.Диск
        upload_file "$TEMP_ARCHIVE" "$YANDEX_PATH"
        
        # Удаляем временный архив
        if rm -f "$TEMP_ARCHIVE"; then
            log "INFO" "Временный архив $TEMP_ARCHIVE успешно удален."
        else
            log "ERROR" "Ошибка при удалении временного архива: $TEMP_ARCHIVE"
        fi
    else
        # Загружаем файл на Яндекс.Диск
        upload_file "$SOURCE_PATH" "$YANDEX_PATH"
    fi

    # Удаление старых резервных копий
    DAYS_TO_KEEP=$(echo "$STORAGE_PARAMS" | grep -oP 'd:\K\d+')
    COPIES_TO_KEEP=$(echo "$STORAGE_PARAMS" | grep -oP 'c:\K\d+')
    delete_old_backups "$YANDEX_BASE_PATH" "$DAYS_TO_KEEP" "$COPIES_TO_KEEP"
}

# Основной цикл для обработки элементов резервного копирования
for item in "${BACKUP_ITEMS[@]}"; do
    # Ограничиваем количество одновременно выполняемых потоков
    while [[ $(jobs -r | wc -l) -ge $MAX_THREADS ]]; do
        sleep 1
    done

    # Запускаем обработку элемента в фоновом режиме
    process_backup_item "$item" &
done

# Ожидаем завершения всех фоновых процессов
wait

# Резервное копирование баз данных (если включено)
if [[ "$ENABLE_MYSQL_BACKUP" -eq 1 ]]; then
    for db in "${MYSQL_DATABASES[@]}"; do
        IFS='|' read -r BACKUP_NAME DB_NAME DB_USER DB_PASS DB_PORT STORAGE_PARAMS <<< "$db"
        backup_database "mysql" "$BACKUP_NAME" "$DB_NAME" "$DB_USER" "$DB_PASS" "$DB_PORT"
    done
fi

if [[ "$ENABLE_POSTGRES_BACKUP" -eq 1 ]]; then
    for db in "${POSTGRES_DATABASES[@]}"; do
        IFS='|' read -r BACKUP_NAME DB_NAME DB_USER DB_PASS DB_PORT STORAGE_PARAMS <<< "$db"
        backup_database "postgres" "$BACKUP_NAME" "$DB_NAME" "$DB_USER" "$DB_PASS" "$DB_PORT"
    done
fi

log "INFO" "Резервное копирование завершено. Проверьте Яндекс.Диск."
send_telegram_notification "Резервное копирование завершено. Проверьте Яндекс.Диск."
