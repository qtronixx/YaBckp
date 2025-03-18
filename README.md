# YaBckp
Backup script

Создайте файл скрипта:
```
sudo nano yandex-disk-backup.sh
```
Сделайте файл исполняемым:
```
sudo chmod +x yandex-disk-backup.sh
```

Запустите скрипт для проверки:
```
sudo ./yandex-disk-backup.sh
```

Создайте файл службы:
```
sudo nano /etc/systemd/system/yandex-disk-backup.service
```

Вставьте конфигурацию:
```
[Unit]
# Описание службы
Description=Yandex.Disk Backup Service
# Запускать после подключения сети
After=network.target

[Service]
# Тип службы: одноразовое выполнение
Type=oneshot
# Команда для запуска скрипта
ExecStart=/root/yandex-disk-backup/yandex-disk-backup.sh
# Запуск от имени пользователя root
User=root
```

Создайте файл таймера:
```
sudo nano /etc/systemd/system/yandex-disk-backup.timer
```

Вставьте конфигурацию:
```
[Unit]
# Описание таймера
Description=Run every hour Yandex.Disk Backup Service

[Timer]
# Запускать каждый час
OnCalendar=hourly
# Выполнить пропущенные задачи после перезагрузки
Persistent=true

[Install]
# Активировать таймер при загрузке системы
WantedBy=timers.target
```

Перезагрузите systemd и активируйте таймер:
```
sudo systemctl daemon-reload
sudo systemctl enable --now yandex-disk-backup.timer
```


Дополнительно

Проверка статуса таймера:
```
sudo systemctl status yandex-disk-backup.timer
```

Просмотр логов:
```
sudo journalctl -u 3x-ui_backup.service
sudo journalctl -u 3x-ui_backup.timer
```
