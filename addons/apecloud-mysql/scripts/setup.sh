#!/bin/bash

set -ex

get_hostname_suffix() {
    IFS='.' read -ra fields <<< "$KB_POD_FQDN"
    if [ "${#fields[@]}" -gt "2" ]; then
        echo "${fields[1]}"
    fi
}

get_cluster_members() {
    local cluster_members=""
    IFS=',' read -ra PODS <<< "$KB_POD_LIST"
    for pod in "${PODS[@]}"; do
        hostname=${pod}.${hostname_suffix}
        cluster_members="${cluster_members};${hostname}:${MYSQL_CONSENSUS_PORT:-13306}"
    done
    echo "${cluster_members#;}"
}

get_pod_index() {
    local pod_name="${1:?missing pod name}"
    local pod_index=0

    IFS=',' read -ra PODS <<< "$KB_POD_LIST"
    for pod in "${PODS[@]}"; do
        if [ "$pod" = "$pod_name" ]; then
            break
        fi
        ((pod_index++))
    done
    
    echo "$pod_index"
}

generate_cluster_info() {
    local pod_name="${KB_POD_NAME:?missing pod name}"
    local cluster_members=""
    local hostname_suffix=$(get_hostname_suffix)

    export MYSQL_PORT=${MYSQL_PORT:-3306}
    export MYSQL_CONSENSUS_PORT=${MYSQL_CONSENSUS_PORT:-13306}
    export KB_MYSQL_VOLUME_DIR=${KB_MYSQL_VOLUME_DIR:-/data/mysql/}
    export KB_MYSQL_CONF_FILE=${KB_MYSQL_CONF_FILE:-/opt/mysql/my.cnf}

    if [ -z "$KB_MYSQL_N" ]; then
        export KB_MYSQL_N=${KB_REPLICA_COUNT:?missing pod numbers}
    fi
    echo "KB_MYSQL_N=${KB_MYSQL_N}"

    if [ -z "$KB_MYSQL_CLUSTER_UID" ]; then
        export KB_MYSQL_CLUSTER_UID=${KB_CLUSTER_UID:?missing cluster uid}
    fi
    echo "KB_MYSQL_CLUSTER_UID=${KB_MYSQL_CLUSTER_UID}"

    export KB_MYSQL_CLUSTER_MEMBERS=`get_cluster_members`
    echo "${KB_MYSQL_CLUSTER_MEMBERS:?missing cluster members}"

    export KB_MYSQL_CLUSTER_MEMBER_INDEX=`get_pod_index $pod_name`
    local pod_host=${pod_name}.${hostname_suffix}
    export KB_MYSQL_CLUSTER_MEMBER_HOST=${pod_host:?missing current member hostname}

    if [ -n "$KB_LEADER" ]; then
        echo "KB_LEADER=${KB_LEADER}"

        local leader_host=$KB_LEADER.${hostname_suffix}
        export KB_MYSQL_CLUSTER_LEADER_HOST=${leader_host:?missing leader hostname}

        # compatiable with old version images
        export KB_MSYQL_LEADER=${KB_LEADER}
    fi
}

migrate_legacy_binlog_path() {
    local data_root="${KB_MYSQL_VOLUME_DIR:-/data/mysql}"
    data_root="${data_root%/}"

    local old_index="$data_root/data/mysql-bin.index"
    local new_dir="$data_root/binlog"
    local new_index="$new_dir/mysql-bin.index"
    local marker="$new_dir/.kb-binlog-path-migrated"
    local backup=""

    [ -f "$old_index" ] || return 0
    mkdir -p "$new_dir"

    ensure_binlog_migration_backup() {
        if [ -n "$backup" ]; then
            return 0
        fi

        local ts
        ts=$(date +%Y%m%d%H%M%S 2>/dev/null || echo now)
        backup="$data_root/repair-binlog-path-$ts"
        mkdir -p "$backup"
        cp -a "$old_index" "$backup/mysql-bin.index.from-data"
        if [ -f "$new_index" ]; then
            cp -a "$new_index" "$backup/mysql-bin.index.from-binlog"
        fi
    }

    all_indexed_binlogs_exist() {
        local index_file="$1"
        local indexed_path

        [ -r "$index_file" ] || return 1
        while IFS= read -r indexed_path || [ -n "$indexed_path" ]; do
            [ -n "$indexed_path" ] || continue
            [ -s "$indexed_path" ] || return 1
        done < "$index_file"
        return 0
    }

    finish_legacy_binlog_index_migration() {
        ensure_binlog_migration_backup
        mv "$old_index" "$backup/mysql-bin.index.migrated"
        chown -R mysql:mysql "$backup" "$new_dir" 2>/dev/null || true
        sync
        date > "$marker" 2>/dev/null || true
        sync
    }

    if [ ! -s "$old_index" ]; then
        finish_legacy_binlog_index_migration
        return 0
    fi

    if [ -f "$marker" ]; then
        if [ -s "$new_index" ] && all_indexed_binlogs_exist "$new_index"; then
            finish_legacy_binlog_index_migration
            return 0
        fi
        echo "mysql binlog migration marker exists but target index is incomplete; resume migration"
        rm -f "$marker"
    fi

    local tmp_index="$new_index.kb-migrate.$$"
    awk -v dir="$new_dir" '{
      base=$0
      sub(/^.*\//, "", base)
      if (base != "") print dir "/" base
    }' "$old_index" > "$tmp_index"

    if [ ! -s "$tmp_index" ]; then
        rm -f "$tmp_index"
        finish_legacy_binlog_index_migration
        return 0
    fi

    local indexes_match=false
    local index_cmp_status=0
    if [ -s "$new_index" ]; then
        if cmp -s "$new_index" "$tmp_index"; then
            indexes_match=true
        else
            index_cmp_status=$?
            if [ "$index_cmp_status" -gt 1 ]; then
                echo "failed to compare mysql binlog indexes: $new_index, $tmp_index" >&2
                rm -f "$tmp_index"
                return 1
            fi
        fi
    fi

    if [ "$indexes_match" = true ]; then
        if all_indexed_binlogs_exist "$tmp_index"; then
            rm -f "$tmp_index"
            finish_legacy_binlog_index_migration
            return 0
        fi
    elif [ -s "$new_index" ]; then
        local non_bootstrap
        non_bootstrap=$(awk 'NF && $0 !~ /(^|\/)mysql-bin\.000001$/ { print; exit }' "$new_index")
        if [ -n "$non_bootstrap" ]; then
            if ! all_indexed_binlogs_exist "$new_index"; then
                echo "existing mysql binlog index references missing files: $new_index" >&2
                rm -f "$tmp_index"
                return 1
            fi
            echo "existing mysql binlog index is already beyond bootstrap; skip migration: $non_bootstrap"
            rm -f "$tmp_index"
            finish_legacy_binlog_index_migration
            return 0
        fi
    fi

    local entry
    while IFS= read -r entry || [ -n "$entry" ]; do
        [ -n "$entry" ] || continue
        local base="${entry##*/}"
        local src="$data_root/data/$base"
        local dst="$new_dir/$base"
        if [ ! -s "$src" ] && [ ! -s "$dst" ]; then
            echo "missing binlog in both legacy and target paths: $src, $dst" >&2
            rm -f "$tmp_index"
            return 1
        fi
    done < "$old_index"

    ensure_binlog_migration_backup

    while IFS= read -r entry || [ -n "$entry" ]; do
        [ -n "$entry" ] || continue
        local base="${entry##*/}"
        local src="$data_root/data/$base"
        local dst="$new_dir/$base"
        if [ ! -s "$src" ]; then
            if [ -e "$src" ]; then
                mv "$src" "$backup/$base.invalid-legacy"
            fi
            continue
        fi
        if [ -e "$dst" ]; then
            local binlog_cmp_status=0
            if cmp -s "$src" "$dst"; then
                mv "$src" "$backup/$base.legacy-duplicate"
                continue
            else
                binlog_cmp_status=$?
                if [ "$binlog_cmp_status" -gt 1 ]; then
                    echo "failed to compare mysql binlogs: $src, $dst" >&2
                    rm -f "$tmp_index"
                    return 1
                fi
            fi
            mv "$dst" "$backup/$base.existing"
        fi
        mv "$src" "$dst"
    done < "$old_index"

    local path
    while IFS= read -r path || [ -n "$path" ]; do
        [ -n "$path" ] || continue
        if [ ! -s "$path" ]; then
            echo "missing migrated binlog: $path" >&2
            rm -f "$tmp_index"
            return 1
        fi
    done < "$tmp_index"

    mv "$tmp_index" "$new_index"
    finish_legacy_binlog_index_migration
    echo "migrated mysql binlog index to $new_index"
}

rmdir /docker-entrypoint-initdb.d && mkdir -p /data/mysql/auditlog && mkdir -p /data/mysql/binlog && mkdir -p /data/mysql/docker-entrypoint-initdb.d && ln -s /data/mysql/docker-entrypoint-initdb.d /docker-entrypoint-initdb.d;
generate_cluster_info
migrate_legacy_binlog_path
exec docker-entrypoint.sh
