#!/bin/bash
set -ex

declare -g primary
declare -g primary_port
declare -g default_initialize_pod_ordinal
declare -g headless_postfix="headless"

redis_acl_file="/data/users.acl"
redis_acl_file_bak="/data/users.acl.bak"

replace_user_entry_in_acl() {
  local username="$1"
  local new_entry="$2"
  local tmp_acl_file

  tmp_acl_file="$(mktemp "${redis_acl_file}.XXXXXX")" || {
    echo "Failed to create temporary ACL file when updating user $username" >&2
    return 1
  }
  if ! sed "/^user $username /d" "$redis_acl_file" > "$tmp_acl_file"; then
    echo "Failed to rewrite ACL file for user $username" >&2
    rm -f "$tmp_acl_file"
    return 1
  fi
  if ! printf '%s\n' "$new_entry" >> "$tmp_acl_file"; then
    echo "Failed to append updated ACL entry for user $username" >&2
    rm -f "$tmp_acl_file"
    return 1
  fi
  if ! cp "$redis_acl_file" "$redis_acl_file_bak"; then
    echo "Failed to backup ACL file to $redis_acl_file_bak for user $username" >&2
    rm -f "$tmp_acl_file"
    return 1
  fi
  if ! mv "$tmp_acl_file" "$redis_acl_file"; then
    echo "Failed to replace ACL file for user $username, original backup kept at $redis_acl_file_bak" >&2
    rm -f "$tmp_acl_file"
    return 1
  fi
}

ensure_password_in_user() {
  local username="$1"
  local password="$2"
  local permissions="$3"
  local password_hash=""

  if command -v sha256sum >/dev/null 2>&1; then
    password_hash=$(printf '%s' "$password" | sha256sum | cut -d' ' -f1)
  fi

  if [ -f "$redis_acl_file" ] && grep -q "^user $username " "$redis_acl_file"; then
    local existing_entry
    existing_entry="$(grep "^user $username " "$redis_acl_file" | tail -n 1)"

    if printf '%s\n' "$existing_entry" | grep -F -q -- ">$password" || \
       { [ -n "$password_hash" ] && printf '%s\n' "$existing_entry" | grep -F -q -- "#$password_hash"; }; then
      echo "Password from Secret already exists for user $username, preserving existing entry"
      if [ -n "$permissions" ]; then
        local entry_prefix
        entry_prefix=$(printf '%s\n' "$existing_entry" | awk '{
          last = 0;
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^[>#]/) {
              last = i;
            }
          }
          if (last == 0) {
            print $0;
          } else {
            for (i = 1; i <= last; i++) {
              printf "%s%s", $i, (i < last ? " " : "");
            }
          }
        }')
        if [ -n "$entry_prefix" ]; then
          if replace_user_entry_in_acl "$username" "$entry_prefix $permissions"; then
            echo "Updated permissions for existing user $username from Secret"
          else
            return 1
          fi
        fi
      fi
    else
      local entry_prefix
      entry_prefix=$(printf '%s\n' "$existing_entry" | awk -v username="$username" -v password="$password" '{
        on_idx = 0;
        for (i = 1; i <= NF; i++) {
          if ($i == "on" || $i == "off") {
            on_idx = i;
            break;
          }
        }
        if (on_idx == 0) {
          printf "user %s on >%s", username, password;
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^[>#]/) {
              printf " %s", $i;
            }
          }
          printf "\n";
          next;
        }
        for (i = 1; i <= on_idx; i++) {
          printf "%s%s", $i, (i < on_idx ? " " : "");
        }
        printf " >%s", password;
        for (i = on_idx + 1; i <= NF; i++) {
          if ($i ~ /^[>#]/) {
            printf " %s", $i;
          }
        }
        printf "\n";
      }')
      if [ -n "$entry_prefix" ]; then
        if [ -n "$permissions" ]; then
          entry_prefix="$entry_prefix $permissions"
        fi
        if replace_user_entry_in_acl "$username" "$entry_prefix"; then
          echo "Added Secret password to existing user $username, preserved other passwords and updated permissions"
        else
          return 1
        fi
      fi
    fi
  else
    local new_entry="user $username on >$password"
    if [ -n "$permissions" ]; then
      new_entry="$new_entry $permissions"
    fi
    printf '%s\n' "$new_entry" >> "$redis_acl_file"
    echo "Created new user $username with password from Secret"
  fi
}

extract_ordinal_from_object_name() {
  local object_name="$1"
  local ordinal="${object_name##*-}"
  echo "$ordinal"
}

get_minimum_initialize_pod_ordinal() {
  if [ -z "$KB_POD_LIST" ]; then
    echo "KB_POD_LIST is empty, use default initialize pod_ordinal:0 as primary node."
    default_initialize_pod_ordinal=0
    return
  fi

  # parse minimum ordinal from env $KB_POD_LIST, the value format is "pod1,pod2,..."
  IFS=',' read -ra pod_list <<< "$KB_POD_LIST"
  for pod in "${pod_list[@]}"; do
    if [ -z "$default_initialize_pod_ordinal" ]; then
      default_initialize_pod_ordinal=$(extract_ordinal_from_object_name "$pod")
      continue
    fi
    pod_ordinal=$(extract_ordinal_from_object_name "$pod")
    if [ "$pod_ordinal" -lt "$default_initialize_pod_ordinal" ]; then
      default_initialize_pod_ordinal="$pod_ordinal"
    fi
  done
}

load_redis_template_conf() {
  echo "include /etc/conf/redis.conf" >> /etc/redis/redis.conf
}

build_redis_default_accounts() {
  set +x
  if [ -n "$REDIS_REPL_PASSWORD" ]; then
    echo "masteruser $REDIS_REPL_USER" >> /etc/redis/redis.conf
    echo "masterauth $REDIS_REPL_PASSWORD" >> /etc/redis/redis.conf
    ensure_password_in_user "$REDIS_REPL_USER" "$REDIS_REPL_PASSWORD" "+psync +replconf +ping"
  fi
  if [ -n "$REDIS_SENTINEL_PASSWORD" ]; then
    ensure_password_in_user "$REDIS_SENTINEL_USER" "$REDIS_SENTINEL_PASSWORD" "allchannels +multi +slaveof +ping +exec +subscribe +config|rewrite +role +publish +info +client|setname +client|kill +script|kill"
  fi
  if [ -n "$REDIS_DEFAULT_PASSWORD" ]; then
    echo "protected-mode yes" >> /etc/redis/redis.conf
    ensure_password_in_user "default" "$REDIS_DEFAULT_PASSWORD" "~* &* +@all"
  else
    echo "protected-mode no" >> /etc/redis/redis.conf
  fi
  set -x
  echo "aclfile /data/users.acl" >> /etc/redis/redis.conf
  echo "build default accounts succeeded!"
}

build_announce_ip_and_port() {
  # build announce ip and port according to whether the announce addr is exist
  if [ -n "$redis_announce_host_value" ] && [ -n "$redis_announce_port_value" ]; then
    echo "redis use nodeport $redis_announce_host_value:$redis_announce_port_value to announce"
    {
      echo "replica-announce-port $redis_announce_port_value"
      echo "replica-announce-ip $redis_announce_host_value"
    } >> /etc/redis/redis.conf
  else
    if [ -n "$FIXED_POD_IP_ENABLED" ]; then
      echo "redis use immutable pod ip $KB_POD_IP to announce"
      echo "replica-announce-ip $KB_POD_IP" >> /etc/redis/redis.conf
    else
      kb_pod_fqdn="$KB_POD_NAME.$KB_CLUSTER_COMP_NAME-headless.$KB_NAMESPACE.svc.cluster.local"
      echo "redis use kb pod fqdn $kb_pod_fqdn to announce"
      echo "replica-announce-ip $kb_pod_fqdn" >> /etc/redis/redis.conf
    fi
  fi
}

build_redis_service_port() {
  service_port=6379
  if [ -n "$SERVICE_PORT" ]; then
    service_port=$SERVICE_PORT
  fi
  echo "port $service_port" >> /etc/redis/redis.conf
}

build_replicaof_config() {
  init_or_get_primary_node
  if check_current_pod_is_primary; then
    return
  else
    echo "replicaof $primary $primary_port" >> /etc/redis/redis.conf
  fi
}

rebuild_redis_acl_file() {
  if [ -f "$redis_acl_file" ]; then
    echo "rebuild_redis_acl_file: preserving existing acl file with user passwords"
  else
    touch "$redis_acl_file"
    echo "rebuild_redis_acl_file: created new acl file"
  fi
}

init_or_get_primary_node() {
  # the global primary variable maybe the fqdn format or the primary node ip.
  init_or_get_primary_from_redis_sentinel

  # check the primary node role in kernel
  # check_pod_is_primary_in_kernel
}

init_or_get_primary_from_redis_sentinel() {
  # check redis sentinel component env
  if [ -z "$SENTINEL_COMPONENT_NAME" ]; then
    # return default primary node if redis sentinel component name is not set
    echo "SENTINEL_COMPONENT_NAME env is not set, try to use default primary node."
    get_default_initialize_primary_node
    return
  fi

  # parse redis sentinel pod list from $SENTINEL_POD_NAME_LIST env
  if [ -z "$SENTINEL_POD_NAME_LIST" ]; then
    echo "Error: Required environment variable SENTINEL_POD_NAME_LIST: $SENTINEL_POD_NAME_LIST is not set."
    exit 1
  fi

  # get redis sentinel headless service name from $SENTINEL_HEADLESS_SERVICE_NAME env
  if [ -z "$SENTINEL_HEADLESS_SERVICE_NAME" ]; then
    echo "Error: Required environment variable SENTINEL_HEADLESS_SERVICE_NAME: $SENTINEL_HEADLESS_SERVICE_NAME is not set."
    exit 1
  fi

  old_ifs="$IFS"
  IFS=','
  set -f
  read -ra sentinel_pod_list <<< "${SENTINEL_POD_NAME_LIST}"
  set +f
  IFS="$old_ifs"
  declare -A master_count_map
  local first_redis_primary_host=""
  local first_redis_primary_port=""
  for sentinel_pod in "${sentinel_pod_list[@]}"; do
    sentinel_pod_fqdn="$sentinel_pod.$SENTINEL_HEADLESS_SERVICE_NAME"

    # get primary info from sentinel
    if retry_get_master_addr_by_name_from_sentinel "$sentinel_pod_fqdn"; then
      echo "sentinel:$sentinel_pod_fqdn has master info: ${REDIS_SENTINEL_PRIMARY_INFO[*]}"
      if [ "${#REDIS_SENTINEL_PRIMARY_INFO[@]}" -ne 2 ] || [ -z "${REDIS_SENTINEL_PRIMARY_INFO[0]}" ] || [ -z "${REDIS_SENTINEL_PRIMARY_INFO[1]}" ]; then
        echo "Empty primary info retrieved from sentinel: $sentinel_pod_fqdn. Skipping this sentinel."
        continue
      fi

      # increment the count of this master in the map
      host_port_key="${REDIS_SENTINEL_PRIMARY_INFO[0]}:${REDIS_SENTINEL_PRIMARY_INFO[1]}"
      master_count_map[$host_port_key]=$((${master_count_map[$host_port_key]} + 1))

      # track the primary host and port from the first sentinel
      if [[ -z "$first_redis_primary_host" ]] && [[ -z "$first_redis_primary_port" ]]; then
        first_redis_primary_host=${REDIS_SENTINEL_PRIMARY_INFO[0]}
        first_redis_primary_port=${REDIS_SENTINEL_PRIMARY_INFO[1]}
      fi

      # log if sentinel has different primary node info
      if [ "$first_redis_primary_host" != "${REDIS_SENTINEL_PRIMARY_INFO[0]}" ] || [ "$first_redis_primary_port" != "${REDIS_SENTINEL_PRIMARY_INFO[1]}" ]; then
        echo "The sentinel:$sentinel_pod_fqdn has different primary node info. First: $first_redis_primary_host:$first_redis_primary_port, Current: ${REDIS_SENTINEL_PRIMARY_INFO[0]}:${REDIS_SENTINEL_PRIMARY_INFO[1]}"
      fi
    else
      echo "Failed to retrieve primary info from sentinel: $sentinel_pod_fqdn. Skipping this sentinel."
    fi
  done

  # if there is no primary node found, use the default primary node
  echo "get all primary info from redis sentinel master_count_map: ${master_count_map[*]}"
  if [ ${#master_count_map[@]} -eq 0 ]; then
    echo "no primary node found from all redis sentinels, use default primary node."
    get_default_initialize_primary_node
    return
  fi

  # get the primary node with the most counts
  max_count=0
  for host_port in "${!master_count_map[@]}"; do
    if (( ${master_count_map[$host_port]} > max_count )); then
      max_count=${master_count_map[$host_port]}
      primary=$(echo $host_port | cut -d: -f1)
      primary_port=$(echo $host_port | cut -d: -f2)
    fi
  done
}

retry_get_master_addr_by_name_from_sentinel() {
  local sentinel_pod_fqdn="$1"
  local retry_count=0
  local max_retry=3
  local retry_delay=2
  local timeout_value=5

  while [ $retry_count -lt $max_retry ]; do
    set +x
    echo "execute command: timeout $timeout_value redis-cli -h $sentinel_pod_fqdn -p $SENTINEL_SERVICE_PORT -a ******** sentinel get-master-addr-by-name $KB_CLUSTER_COMP_NAME"
    output=$(timeout "$timeout_value" redis-cli -h "$sentinel_pod_fqdn" -p "$SENTINEL_SERVICE_PORT" -a "$SENTINEL_PASSWORD" sentinel get-master-addr-by-name "$KB_CLUSTER_COMP_NAME")
    set -x
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
      old_ifs="$IFS"
      IFS=$'\n'
      set -f
      read -r -d '' -a REDIS_SENTINEL_PRIMARY_INFO <<< "$output"
      set +f
      IFS="$old_ifs"
      if [ "${#REDIS_SENTINEL_PRIMARY_INFO[@]}" -eq 2 ] && [ -n "${REDIS_SENTINEL_PRIMARY_INFO[0]}" ] && [ -n "${REDIS_SENTINEL_PRIMARY_INFO[1]}" ]; then
        echo "Successfully retrieved primary info from sentinel: $sentinel_pod_fqdn"
        return 0
      else
        echo "Empty primary info retrieved from sentinel: $sentinel_pod_fqdn"
        return 0
      fi
    else
      if [ $exit_code -eq 124 ]; then
        echo "Timeout occurred while retrieving primary info from sentinel: $sentinel_pod_fqdn. Retrying..."
      else
        echo "Error occurred while retrieving primary info from sentinel: $sentinel_pod_fqdn. Retrying..."
      fi
    fi

    retry_count=$((retry_count + 1))
    sleep $retry_delay
  done

  echo "Failed to retrieve primary info from sentinel: $sentinel_pod_fqdn after $max_retry retries."
  return 1
}

get_default_initialize_primary_node() {
  # TODO: if has advertise svc and port, we should use it as default primary node info instead of the headless svc
  get_minimum_initialize_pod_ordinal
  echo "use default initialize pod_ordinal:$default_initialize_pod_ordinal as primary node."
  primary="$KB_CLUSTER_COMP_NAME-$default_initialize_pod_ordinal.$KB_CLUSTER_COMP_NAME-$headless_postfix.$KB_NAMESPACE"
  primary_port=$service_port
}

check_current_pod_is_primary() {
  current_pod="$KB_POD_NAME.$KB_CLUSTER_COMP_NAME"
  if [[ "$primary" == *"$current_pod"* ]]; then
    echo "current pod is primary, skip check role in kernel, primary node: $primary, pod name:$current_pod"
    return 0
  fi

  if [ -n "$redis_announce_host_value" ] && [ -n "$redis_announce_port_value" ]; then
    if [[ "$primary" == "$redis_announce_host_value" ]] && [[ "$primary_port" == "$redis_announce_port_value" ]]; then
      echo "current pod is primary, skip check role in kernel, primary node: $primary, advertised ip:$redis_announce_host_value, advertised port:$redis_announce_port_value"
      return 0
    fi
  fi

  if [[ "$primary" == "$KB_POD_IP" ]] && [[ "$primary_port" == "$service_port" ]]; then
    echo "current pod is primary, skip check role in kernel, primary node: $primary, pod ip:$KB_HOST_IP, service port:$service_port"
    return 0
  fi
  return 1
}

check_pod_is_primary_in_kernel() {
  # skip check role in kernel if the primary contains the pod name
  if check_current_pod_is_primary; then
    return
  fi

  # check the primary is real master role or not
  set +x
  if [ -n "$REDIS_DEFAULT_PASSWORD" ]; then
    check_kernel_role_cmd="redis-cli -h $primary -p $primary_port -a $REDIS_DEFAULT_PASSWORD info replication | grep 'role:' | awk -F: '{print \$2}'"
  else
    check_kernel_role_cmd="redis-cli -h $primary -p $primary_port info replication | grep 'role:' | awk -F: '{print \$2}'"
  fi
  retry_times=10
  while true; do
    check_role=$(eval "$check_kernel_role_cmd")
    if [[ "$check_role" =~ "master" ]]; then
      break
    else
      echo "the selected primary node is not the real master in kernel, existing primary node: $primary, role: $check_role"
    fi
    sleep 3
    retry_times=$((retry_times - 1))
    if [ $retry_times -eq 0 ]; then
      echo "check primary node role failed after 20 times, existing primary node: $primary, role: $check_role"
      exit 1
    fi
  done
  set -x
}

start_redis_server() {
    exec_cmd="exec redis-server /etc/redis/redis.conf"
    if [ -f /opt/redis-stack/lib/redisearch.so ]; then
        exec_cmd="$exec_cmd --loadmodule /opt/redis-stack/lib/redisearch.so ${REDISEARCH_ARGS}"
    fi
    if [ -f /opt/redis-stack/lib/redistimeseries.so ]; then
        exec_cmd="$exec_cmd --loadmodule /opt/redis-stack/lib/redistimeseries.so ${REDISTIMESERIES_ARGS}"
    fi
    if [ -f /opt/redis-stack/lib/rejson.so ]; then
        exec_cmd="$exec_cmd --loadmodule /opt/redis-stack/lib/rejson.so ${REDISJSON_ARGS}"
    fi
    if [ -f /opt/redis-stack/lib/redisbloom.so ]; then
        exec_cmd="$exec_cmd --loadmodule /opt/redis-stack/lib/redisbloom.so ${REDISBLOOM_ARGS}"
    fi
    if [ -f /opt/redis-stack/lib/redisgraph.so ]; then
        exec_cmd="$exec_cmd --loadmodule /opt/redis-stack/lib/redisgraph.so ${REDISGRAPH_ARGS}"
    fi
    if [ -f /opt/redis-stack/lib/rediscompat.so ]; then
        exec_cmd="$exec_cmd --loadmodule /opt/redis-stack/lib/rediscompat.so"
    fi
    if [ -f /opt/redis-stack/lib/redisgears.so ]; then
        exec_cmd="$exec_cmd --loadmodule /opt/redis-stack/lib/redisgears.so v8-plugin-path /opt/redis-stack/lib/libredisgears_v8_plugin.so ${REDISGEARS_ARGS}"
    fi
    echo "Starting redis server cmd: $exec_cmd"
    eval "$exec_cmd"
}

parse_redis_announce_addr() {
  local pod_name="$1"

  # try to get the announce ip and port from REDIS_ADVERTISED_PORT(support NodePort currently) first
  if [[ -z "${REDIS_ADVERTISED_PORT}" ]]; then
    echo "Environment variable REDIS_ADVERTISED_PORT not found. Ignoring."
    # if redis is in host network mode, use the host ip and port as the announce ip and port
    if [[ -n "${REDIS_HOST_NETWORK_PORT}" ]] && [[ -n "$HOST_NETWORK_ENABLED" ]]; then
      echo "redis is in host network mode, use the host ip:$KB_HOST_IP and port:$REDIS_HOST_NETWORK_PORT as the announce ip and port."
      redis_announce_port_value="$REDIS_HOST_NETWORK_PORT"
      redis_announce_host_value="$KB_HOST_IP"
    fi
    return 0
  fi

  # the value format of REDIS_ADVERTISED_PORT is "pod1Svc:advertisedPort1,pod2Svc:advertisedPort2,..."
  IFS=',' read -ra advertised_ports <<< "${REDIS_ADVERTISED_PORT}"

  local found=false
  pod_name_ordinal=$(extract_ordinal_from_object_name "$pod_name")
  for advertised_port in "${advertised_ports[@]}"; do
    IFS=':' read -ra parts <<< "$advertised_port"
    local svc_name="${parts[0]}"
    local port="${parts[1]}"
    svc_name_ordinal=$(extract_ordinal_from_object_name "$svc_name")
    if [[ "$svc_name_ordinal" == "$pod_name_ordinal" ]]; then
      echo "Found matching svcName and port for podName '$pod_name', REDIS_ADVERTISED_PORT: $REDIS_ADVERTISED_PORT. svcName: $svc_name, port: $port."
      redis_announce_port_value="$port"
      redis_announce_host_value="$KB_HOST_IP"
      found=true
      break
    fi
  done

  if [[ "$found" == false ]]; then
    echo "Error: No matching svcName and port found for podName '$pod_name', REDIS_ADVERTISED_PORT: $REDIS_ADVERTISED_PORT. Exiting."
    exit 1
  fi
}

# build redis.conf
build_redis_conf() {
  load_redis_template_conf
  build_announce_ip_and_port
  build_redis_service_port
  build_replicaof_config
  rebuild_redis_acl_file
  build_redis_default_accounts
}

parse_redis_announce_addr "$KB_POD_NAME"
build_redis_conf
start_redis_server