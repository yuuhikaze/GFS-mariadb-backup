#!/usr/bin/env bash

set -uo pipefail
IFS=$'\n'

# GFS MariaDB backup script

# Author: Steven Merino
# Version: 1.5.2
# License: MIT

# REQUIREMENTS
# Run this script as superuser
# Set up `mariabackup` user: https://mariadb.com/kb/en/mariabackup-overview/#authentication-and-privileges

QUIET=""
DEBUG_LEVEL=5
SCRIPT_PATH=$(dirname "$(readlink -f "$0")")
SCRIPT_NAME="$(basename "$0" ".${0##*.}")"

STORAGE_PATH="/var"
BACKUP_PATH=""
BACKUP_MODALITY=""
BACKUP_CMD=""
BACKUP_BINARY=""
USAGE_THRESHOLD=70

NODE_NAME="${HOSTNAME}"
BACKUP_USER_PASSWORD=""
THREADS=$(($(nproc) * 30 / 100))

N_KEEP_DAILY=7
N_KEEP_WEEKLY=5
N_KEEP_MONTHLY=12
N_KEEP_ANNUALLY=""

IS_DAILY_COMPRESSED=0
IS_WEEKLY_COMPRESSED=0
IS_MONTHLY_COMPRESSED=1
IS_ANNUALLY_COMPRESSED=1

RESTORATION_PATH=""
declare -a BACKUP_STACK

exceptions() {
    throw_argument_exception() {
        echo -e "ERROR: Unrecognized argument.\nTry \`${0##*/} -h\` for more information." >&2
        exit 1
    }
    throw_option_exception() {
        echo -e "ERROR: Unrecognized option.\nTry \`${0##*/} -h\` for more information." >&2
        exit 1
    }
    throw_superuser_exception() {
        echo "ERROR: Superuser privileges are required for the script to run. Try \`sudo !!\`." >&2
        exit 1
    }
    throw_env_file_exception() {
        echo -e "ERROR: Environment file does not exist.\nRead \`README.md\` for more information." >&2
        exit 1
    }
    throw_password_exception() {
        echo -e "ERROR: BACKUP_USER_PASSWORD is not declared in envinronment file." >&2
        exit 1
    }
    throw_backup_binary_exception() {
        echo "ERROR: Could not find 'mariadb-backup' or 'mariabackup' in PATH." >&2
        exit 1
    }
    throw_rotate_exception() {
        echo "ERROR: User attempted to rotate all backups, at least one should be retained." >&2
        exit 1
    }
    throw_partition_usage_exception() {
        print_and_log "ERROR" "Partition usage exceeds the defined threshold [$USAGE_THRESHOLD%].\nGeneration or restoration of backups will be suspended until sufficient space is freed.\nCurrent partion usage: $1%!"
        exit 1
    }
    throw_stack_exception() {
        print_and_log "ERROR" "Previous backup was not found. It should be available by now after resolving stack. This is unexpected."
        exit 1
    }
    throw_unsupported_service_action() {
        print_and_log "ERROR" "Tried to perform an unsupported or unvalid service action. Supported actions are: stop|start"
        exit 1
    }
    throw_unsuccessful_service_action() {
        print_and_log "ERROR" "Performed service action ($1) was not successful!"
        exit 1
    }
    throw_unsuccessful_backup_preparation() {
        print_and_log "ERROR" "MariaDB backup could not be prepared. Make sure the path you are providing is not empty and valid"
        exit 1
    }
    throw_unresolvable_backup() {
        echo "ERROR: Could not resolve the base backup of the specified backup. Missing \`mariadb_backup_info\`."
        exit 1
    }
    throw_socket_exception() {
        echo "ERROR: MariaDB socket not found. Ensure the service is running." >&2
        exit 1
    }
}
exceptions

# Debug levels:
#   3 = INFO  — Print evaluated MariaDB commands (for visibility into what's being executed).
#   5 = TRACE — Enable shell tracing with 'set -x' for detailed command execution flow.
attach_debugger() {
    case "$DEBUG_LEVEL" in
        5) set -x ;;
    esac
}

print_and_log() {
    local YMDHMS
    YMDHMS="$(date -u +'%Y-%m-%d %H:%M:%S+00')"
    level="$1"
    message="$2"
    case "${level,,}" in
        error) tput setaf 1 ;;
        info)
            if grep -qi "success" <<< "$message"; then
                tput setaf 2
            else
                tput setaf 4
            fi
            ;;
    esac
    identifier="[$YMDHMS] [$NODE_NAME]"
    echo -e "$identifier\n[$level] $message" >&2
    echo -ne "$identifier\n[$level] $message" | tr '\n' ' ' >> "$BACKUP_PATH/status.log"
    echo >> "$BACKUP_PATH/status.log"
    tput sgr0
}

set_backup_binary() {
    BACKUP_BINARY="mariadb-backup"
    command -v "$BACKUP_BINARY" &> /dev/null || BACKUP_BINARY="mariabackup"
    command -v "$BACKUP_BINARY" &> /dev/null || throw_backup_binary_exception
}

parse_options() {
    OPTS="$(getopt -o q,R:,c:,r:,n:,s:,t:,h -l usage-threshold:,compression-strategy:,rotation-strategy:,restore:,node-name:,storage-path:,help,debug-level:,debug,quiet -- "$@" 2> /dev/null)"
    [ $? -ne 0 ] && throw_option_exception
    eval set -- "$OPTS"
    while true; do
        case "$1" in
            -h | --help)
                documentation
                exit 0
                ;;
            -q | --quiet)
                QUIET="2> /dev/null"
                shift
                ;;
            -n | --node-name)
                NODE_NAME="$2"
                shift 2
                ;;
            -s | --storage-path)
                STORAGE_PATH="${2%/}"
                shift 2
                ;;
            -t | --usage-threshold)
                USAGE_THRESHOLD="${2//%/}"
                shift 2
                ;;
            -R | --rotation-strategy)
                IFS=':' read -r N_KEEP_DAILY N_KEEP_WEEKLY N_KEEP_MONTHLY N_KEEP_ANNUALLY <<< "$2"
                shift 2
                ;;
            -c | --compression-strategy)
                IFS=':' read -r N_KEEP_DAILY N_KEEP_WEEKLY N_KEEP_MONTHLY N_KEEP_ANNUALLY <<< "$2"
                shift 2
                ;;
            -r | --restore)
                RESTORATION_PATH="${2%/}"
                shift 2
                ;;
            --debug-level) # This option needs to be passed before --debug
                DEBUG_LEVEL="$2"
                shift 2
                ;;
            --debug)
                attach_debugger
                shift
                ;;
            --)
                shift
                break
                ;;
            *) throw_option_exception ;;
        esac
    done
    BACKUP_MODALITY="${1:-daily}"
    BACKUP_PATH="$STORAGE_PATH/mariadb-backup"
}

source_env_file() {
    if [ -f "$SCRIPT_PATH/.env" ]; then
        source "$SCRIPT_PATH/.env"
    else
        throw_env_file_exception
    fi
    [ -z "$BACKUP_USER_PASSWORD" ] && throw_password_exception
}

check_available_space() {
    used_space="$(df --output=pcent "$STORAGE_PATH" | tail -n 1 | tr -d ' %')"
    [ "$used_space" -ge "$USAGE_THRESHOLD" ] && throw_partition_usage_exception "$used_space"
}

rotate() {
    local backup_modality="$1"
    local i="$2"
    [ -z "$i" ] && return 0 # Don't rotate backup if `i` is empty/null => indefinite backups
    [ "$i" -lt 1 ] && throw_rotate_exception
    i=$(($2 + 1))
    find "$BACKUP_PATH/$NODE_NAME/backups/$backup_modality" -mindepth 1 -maxdepth 1 2> /dev/null | sort | tail -n +"$i" | xargs rm -rf -- {} \;
    find "$BACKUP_PATH/$NODE_NAME/checkpoints/$backup_modality" -mindepth 1 -maxdepth 1 2> /dev/null | sort | tail -n +"$i" | xargs rm -rf -- {} \;
}

set_backup_cmd() {
    local backup_kind_tags="full"
    local modality="$1" timestamp="$2" incremental_basedir="$3" is_compressed="${4:-0}"
    # Check if a backup for the current timestamp already exists.
    # If it does, incrementally append a counter (e.g., &1, &2, ...) to avoid overwriting existing backups.
    enumerate_nth() {
        local dir="$1"
        if [ -n "$(ls "$dir" 2> /dev/null)" ]; then
            enumeratedDirname="$(find "$dir"*\&[0-9]* -mindepth 0 -maxdepth 0 -printf "%f\n" 2> /dev/null | tr -d '/' | tail -n 1)"
            if [ -n "$enumeratedDirname" ]; then
                counter="$(grep -Po '&\K\d$' <<< "$enumeratedDirname")"
                counter=$((counter + 1))
                dir="$dir&$counter"
            else
                dir="$dir&1"
            fi
        fi
        echo "$dir"
    }
    local target_dir
    target_dir="$(enumerate_nth "$BACKUP_PATH/$NODE_NAME/backups/$modality/$timestamp")"
    mkdir -p "$target_dir"
    BACKUP_CMD="mariadb-backup"
    if [ -n "$incremental_basedir" ]; then
        BACKUP_CMD="$BACKUP_CMD --incremental-basedir='$incremental_basedir'"
        backup_kind_tags="differential"
        [ "$modality" == "daily" ] && backup_kind_tags="incremental"
    fi
    if [ "$is_compressed" -eq 1 ]; then
        local lsndir="${target_dir//backups/checkpoints}"
        mkdir -p "$lsndir"
        BACKUP_CMD="$BACKUP_CMD --stream=mbstream --extra-lsndir='$lsndir'"
        backup_kind_tags="$backup_kind_tags, compressed"
    fi
    BACKUP_CMD="$BACKUP_CMD --backup --target-dir='$target_dir' --user=mariabackup --password='$BACKUP_USER_PASSWORD' --parallel='$THREADS' $QUIET"
    [ "$is_compressed" -eq 1 ] && BACKUP_CMD="$BACKUP_CMD | gzip > '$target_dir/stream_data.gz'"
    print_and_log "INFO" "Configuring ${backup_modality^^} backup (${backup_kind_tags})\nStoring backup at '$target_dir'"
}

perform_backup() {
    resolve_queue() {
        local hierarchy=("monthly" "weekly" "daily")
        for ((i = 0; i < ${#hierarchy[@]}; i++)); do
            [ "${hierarchy[$i]}" == "$1" ] && break
            perform_backup "${hierarchy[$i]}"
        done
    }
    find_latest_backup() {
        local backup_modality="$1"
        if ! find "$BACKUP_PATH/$NODE_NAME/checkpoints/$backup_modality" -mindepth 1 -maxdepth 1 -type d 2> /dev/null | sort | tail -n 1; then
            ! find "$BACKUP_PATH/$NODE_NAME/backups/$backup_modality" -mindepth 1 -maxdepth 1 -type d 2> /dev/null | sort | tail -n 1 && return 1
        fi
        return 0
    }
    local backup_modality="$1"
    case "$backup_modality" in
        daily)
            local previous_backup
            previous_backup="$(find_latest_backup "daily")"
            if [ -z "$previous_backup" ]; then
                previous_backup="$(find_latest_backup "weekly")"
                if [ -z "$previous_backup" ]; then
                    resolve_queue "$backup_modality"
                    previous_backup="$(find_latest_backup "weekly" || throw_stack_exception)"
                fi
            else
                rotate "$backup_modality" "$N_KEEP_DAILY"
            fi
            set_backup_cmd "$backup_modality" "$(date +"%Y-%m-%d")" "$previous_backup" "$IS_DAILY_COMPRESSED"
            ;;
        weekly)
            local previous_backup
            previous_backup="$(find_latest_backup "monthly")"
            if [ -z "$previous_backup" ]; then
                resolve_queue "$backup_modality"
                previous_backup="$(find_latest_backup "monthly" || throw_stack_exception)"
            else
                rotate "$backup_modality" "$N_KEEP_WEEKLY"
            fi
            set_backup_cmd "$backup_modality" "$(date +"%Y-%U")" "$previous_backup" "$IS_WEEKLY_COMPRESSED"
            ;;
        monthly)
            rotate "$backup_modality" "$N_KEEP_MONTHLY"
            set_backup_cmd "$backup_modality" "$(date +"%Y-%m")" "" "$IS_MONTHLY_COMPRESSED"
            ;;
        annually)
            rotate "$backup_modality" "$N_KEEP_ANNUALLY"
            set_backup_cmd "$backup_modality" "$(date +"%Y")" "" "$IS_ANNUALLY_COMPRESSED"
            ;;
        *) throw_argument_exception ;;
    esac
    tput dim
    [ "$DEBUG_LEVEL" -eq 3 ] && echo "${BACKUP_CMD//--/$'\n'   --}"
    if eval "$BACKUP_CMD"; then
        tput sgr0
        print_and_log "INFO" "Backup generation was successful!"
    else
        tput sgr0
        print_and_log "ERROR" "Backup generation was NOT successful!"
    fi
}

manage_mariadb_service() {
    local action="$1"
    if [ "${action,,}" != "start" ] && [ "${action,,}" != "stop" ]; then
        throw_unsupported_service_action
    fi
    command -v systemctl &> /dev/null && {
        systemctl "$action" mariadb &> /dev/null
        return $?
    }
    command -v rc-service &> /dev/null && {
        rc-service mariadb "$action" &> /dev/null
        return $?
    }
    throw_unsuccessful_service_action "$action"
}

# Requires MariaDB v10.2+
restore_backup() {
    resolve_stack() {
        local from="$1"
        [ ! -f "$from" ] && return 1
        grepped="$(grep -Po 'incremental-basedir[=\s]\K[^\s]*(?=\s)' "$from")"
        if [ -n "$grepped" ]; then
            BACKUP_STACK+=("$(grep -Po '[^/]+/[^/]+$' <<< "$grepped")")
            resolve_stack "$grepped/mariadb_backup_info"
        fi
        return 0
    }
    manage_mariadb_service stop
    tput dim
    resolve_stack "$RESTORATION_PATH/mariadb_backup_info" ||
        resolve_stack "${RESTORATION_PATH//backups/checkpoints}/mariadb_backup_info" ||
        throw_unresolvable_backup
    base_dir="$(mktemp -d /tmp/"$SCRIPT_NAME".XXXXXX)"
    base_backup="${BACKUP_STACK[-1]}"
    BACKUP_STACK=("${BACKUP_STACK[@]::${#BACKUP_STACK[@]}-1}")
    rsync -avz "$BACKUP_PATH/$NODE_NAME/backups/$base_backup"/* "$base_dir" > /dev/null
    if [ -f "$base_dir/stream_data.gz" ]; then
        gunzip -c "$base_dir/stream_data.gz" | mbstream -x -C "$base_dir"
        rm -f "$base_dir/stream_data.gz"
    fi
    eval mariadb-backup --prepare --target-dir="$base_dir" "$QUIET" || {
        tput sgr0
        throw_unsuccessful_backup_preparation
    }
    for ((i = ${#BACKUP_STACK[@]} - 1; i >= 0; i--)); do
        fragment="$BACKUP_PATH/$NODE_NAME/backups/${BACKUP_STACK[i]//$'\n'/}"
        tmpdir=""
        if [ -f "$fragment/stream_data.gz" ]; then
            tmpdir="$(mktemp -d /tmp/"$SCRIPT_NAME".XXXXXX)"
            gunzip -c "$fragment/stream_data.gz" | mbstream -x -C "$tmpdir"
            rm -f "$tmpdir/stream_data.gz"
            fragment="$tmpdir"
        fi
        eval mariadb-backup --prepare --target-dir="$base_dir" --incremental-dir="$fragment" "$QUIET" || {
            tput sgr0
            throw_unsuccessful_backup_preparation
        }
        [ -n "$tmpdir" ] && rm -rf "$tmpdir"
    done
    if eval mariadb-backup --move-back --target-dir="$base_dir" "$QUIET"; then
        tput sgr0
        print_and_log "INFO" "Backup restoration was successful! You can now start MariaDB\nRestored DB from '$RESTORATION_PATH'"
        chown -R mysql:mysql /var/lib/mysql/
    else
        tput sgr0
        print_and_log "ERROR" "Backup restoration was NOT successful!"
    fi
    rm -rf "$base_dir"
}

documentation() {
    tabular_print() {
        counter=0
        result=""
        for el in "$@"; do
            ((counter++))
            result+="$el"
            [ $((counter % 2)) -ne 0 ] && result+="\t" || result+="\n"
        done
        echo -e "$result" | awk -v n=4 '{printf "%*s%s\n", n, "", $0}' | column -t -s $'\t'
    }
    cat << EOF
USAGE
    ${0##*/} [OPTIONS] [ARGUMENTS]
ARGUMENTS
$(
        tabular_print \
            "\$1" "daily[default]|weekly|monthly|annually"
    )
DESCRIPTION
$(
        tabular_print \
            "daily" "incremental backup [1-7]" \
            "weekly" "differential backup [1-5]" \
            "monthly" "full [compressed] backup [1-12]" \
            "annually" "full [compressed] backup [indefinite]"
    )
OPTIONS
$(
        tabular_print \
            "-r | --restore-backup" "restores backup from specified path" \
            "-n | --node-name" "sets machine identifier on logs and backups [default is \$HOSTNAME]" \
            "-s | --storage-path" "specifies path to store backups [default is '/var']" \
            "-t | --usage-threshold" "sets the max partition usage threshold [default is '70%']" \
            "-R | --rotation-strategy" "specifies the rotation strategy [default is '7:5:12:']" \
            "-c | --comrpession-strategy" "specifies the compression strategy [default is '0:0:1:1']"
    )
EOF
}

parse_options "$@"
[ "$EUID" -ne 0 ] && throw_superuser_exception
check_available_space
if [ -n "$RESTORATION_PATH" ]; then
    restore_backup
    exit 0
fi
[ -S /run/mysqld/mysqld.sock ] || throw_socket_exception
set_backup_binary
source_env_file
perform_backup "$BACKUP_MODALITY"
