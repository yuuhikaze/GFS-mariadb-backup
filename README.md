# GFS MariaDB Backup Script

Automates **MariaDB** backups using the **GFS (Grandfather-Father-Son)** backup strategy. It supports daily, weekly, monthly, and annually backups, and can be run manually or scheduled with systemd timers.

### Requirements

-   Run the script as superuser.
-   Have `MariaDB` and `mariadb-backup/mariabackup` installed.
-   Set up [`mariabackup` user](https://mariadb.com/kb/en/mariabackup-overview/#authentication-and-privileges) in MariaDB.

### Setup

1.  Create secrets file inside script's directory. Edit `.env`:

    ```bash
    BACKUP_USER_PASSWORD='<your_password>'
    ```

1.  Create a symlink to `/usr/local/bin`.

    ```bash
    sudo ln -s "$(pwd)"/gfsmbkp.sh /usr/local/bin/gfsmbkp.sh
    ```

### Scheduled execution

1.  Create systemd service. Edit `/etc/systemd/system/mariadb-backup@.service`:

     ```ini
     [Unit]
     Description=MariaDB Backup Service

     [Service]
     Type=oneshot
     ExecStart=/usr/local/bin/gfsmbkp.sh %i
     ```

1.  Create systemd timers to run service periodically.

    For example, to run a daily timer. Create the file `/etc/systemd/system/mariadb-backup@daily.timer` and add:

    ```ini
    [Unit]
    Description=Daily MariaDB Backup Timer

    [Timer]
    OnCalendar=*-*-* 00:00:00
    RandomizedDelaySec=1800
    Persistent=true

    [Install]
    WantedBy=timers.target
    ```

    > `RandomizedDelaySec`: adds a random delay before executing the backup task to avoid staggering, preventing network or storage contention.

1.  Enable the timers.

    ```bash
    sudo systemctl daemon-reload # reload systemd
    sudo systemctl enable --now mariadb-backup@daily.timer
    ```

1.  Check that timers are set up correctly.

    ```bash
    systemctl list-timers # list all timers
    systemctl status mariadb-backup@daily.timer # check status of specific timer
    ```
