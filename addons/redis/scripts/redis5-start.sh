#!/bin/bash

# shellcheck disable=SC2153
# shellcheck disable=SC2207
# shellcheck disable=SC2034

# This is magic for shellspec ut framework. "test" is a `test [expression]` well known as a shell command.
# Normally test without [expression] returns false. It means that __() { :; }
# function is defined if this script runs directly.
#
# shellspec overrides the test command and returns true *once*. It means that
# __() function defined internally by shellspec is called.
#
# In other words. If not in test mode, __ is just a comment. If test mode, __
# is a interception point.
# you should set ut_mode="true" when you want to run the script in shellspec file.
ut_mode="false"
test || __() {
  # when running in non-unit test mode, set the options "set -ex".
  set -ex;
}

primary=""
primary_port="6379"
redis_template_conf="/etc/conf/redis.conf"
redis_real_conf="/etc/redis/redis.conf"
redis_acl_file="/data/users.acl"
redis_acl_file_bak="/data/users.acl.bak"
retry_times=3
retry_delay_second=2

extract_lb_host_by_svc_name() {
  local svc_name="$1"
  for lb_composed_name in $(echo "$REDIS_LB_ADVERTISED_HOST" | tr ',' '\n' ); do
    if [[ ${lb_composed_name} == *":"* ]]; then
       if [[ ${lb_composed_name%:*} == "$svc_name" ]]; then
         echo "${lb_composed_name#*:}"
         break
       fi
    else
       break
    fi
  done
}

load_common_library() {
  # the common.sh scripts is mounted to the same path which is defined in the cmpd.spec.scripts
  common_library_file="/scripts/common.sh"
  # shellcheck disable=SC1090
  source "${common_library_file}"
}

load_redis_template_conf() {
  echo "include $redis_template_conf" >> $redis_real_conf
}

build_redis_default_accounts() {
  unset_xtrace_when_ut_mode_false
  if ! is_empty "$REDIS_DEFAULT_PASSWORD"; then
    echo "protected-mode yes" >> $redis_real_conf
    echo "requirepass $REDIS_DEFAULT_PASSWORD" >> $redis_real_conf
    echo "masterauth $REDIS_DEFAULT_PASSWORD" >> $redis_real_conf
  else
    echo "protected-mode no" >> $redis_real_conf
  fi
  set_xtrace_when_ut_mode_false
  echo "build default accounts succeeded!"
}

build_announce_ip_and_port() {
  # build announce ip and port according to whether the announce addr is exist
  if ! is_empty "$redis_announce_host_value" && ! is_empty "$redis_announce_port_value"; then
    echo "redis use nodeport $redis_announce_host_value:$redis_announce_port_value to announce"
    {
      echo "replica-announce-port $redis_announce_port_value"
      echo "replica-announce-ip $redis_announce_host_value"
    } >> $redis_real_conf
  elif [ "$FIXED_POD_IP_ENABLED" == "true" ]; then
      echo "" > /data/.fixed_pod_ip_enabled
      echo "redis use immutable pod ip $CURRENT_POD_IP to announce"
      echo "replica-announce-ip $CURRENT_POD_IP" >> $redis_real_conf
  else
    # only above v6.2.x sentinel has optional support for host names.
    # https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/#ip-addresses-and-dns-names
    echo "redis use kb pod fqdn $current_pod_fqdn to announce"
    echo "replica-announce-ip $CURRENT_POD_IP" >> $redis_real_conf
  fi
}

build_redis_service_port() {
  service_port=6379
  if env_exist SERVICE_PORT; then
    service_port=$SERVICE_PORT
  fi
  echo "port $service_port" >> $redis_real_conf
}

build_replicaof_config() {
  init_or_get_primary_from_redis_sentinel
  if check_current_pod_is_primary; then
    return
  else
    echo "replicaof $primary $primary_port" >> $redis_real_conf
  fi
}

init_or_get_primary_from_redis_sentinel() {
  # check redis sentinel component env
  if ! env_exist SENTINEL_COMPONENT_NAME; then
    # return default primary node if redis sentinel component name is not set
    echo "SENTINEL_COMPONENT_NAME env is not set, try to use default primary node."
    get_default_initialize_primary_node
    return
  fi

  # parse redis sentinel pod fqdn list from $SENTINEL_POD_FQDN_LIST env
  if ! env_exist SENTINEL_POD_FQDN_LIST; then
    echo "Error: Required environment variable SENTINEL_POD_FQDN_LIST is not set."
    exit 1
  fi

  declare -A master_count_map
  local first_redis_primary_host=""
  local first_redis_primary_port=""
  sentinel_pod_fqdn_list=($(split "$SENTINEL_POD_FQDN_LIST" ","))
  local sentinel_count=${#sentinel_pod_fqdn_list[@]}
  local quorum=$((sentinel_count / 2 + 1))
  for sentinel_pod_fqdn in "${sentinel_pod_fqdn_list[@]}"; do
    # get primary info from sentinel
    sentinel_pod_ip=$(getent hosts "$sentinel_pod_fqdn" | awk '{ print $1 }')
    if [ -z "$sentinel_pod_ip" ]; then
      echo "Failed to resolve the IP address of sentinel: $sentinel_pod_fqdn. Skipping this sentinel."
      continue
    fi
    if retry_get_master_addr_by_name_from_sentinel $retry_times $retry_delay_second "$sentinel_pod_ip"; then
      echo "sentinel:$sentinel_pod_fqdn has master info: ${REDIS_SENTINEL_PRIMARY_INFO[*]}"
      if [ "${#REDIS_SENTINEL_PRIMARY_INFO[@]}" -ne 2 ] || [ -z "${REDIS_SENTINEL_PRIMARY_INFO[0]}" ] || [ -z "${REDIS_SENTINEL_PRIMARY_INFO[1]}" ]; then
        echo "Empty primary info retrieved from sentinel: $sentinel_pod_fqdn. Skipping this sentinel."
        continue
      fi

      # increment the count of this master in the map
      host_port_key="${REDIS_SENTINEL_PRIMARY_INFO[0]}:${REDIS_SENTINEL_PRIMARY_INFO[1]}"
      master_count_map[$host_port_key]=$((${master_count_map[$host_port_key]} + 1))

      # track the primary host and port from the first sentinel
      if is_empty "$first_redis_primary_host" && is_empty "$first_redis_primary_port"; then
        first_redis_primary_host=${REDIS_SENTINEL_PRIMARY_INFO[0]}
        first_redis_primary_port=${REDIS_SENTINEL_PRIMARY_INFO[1]}
      fi

      # log if sentinel has different primary node info
      if ! equals "$first_redis_primary_host" "${REDIS_SENTINEL_PRIMARY_INFO[0]}" || ! equals "$first_redis_primary_port" "${REDIS_SENTINEL_PRIMARY_INFO[1]}"; then
        echo "The sentinel:$sentinel_pod_fqdn has different primary node info. First: $first_redis_primary_host:$first_redis_primary_port, Current: ${REDIS_SENTINEL_PRIMARY_INFO[0]}:${REDIS_SENTINEL_PRIMARY_INFO[1]}"
      fi
    else
      echo "Failed to retrieve primary info from sentinel: $sentinel_pod_fqdn. Skipping this sentinel."
    fi
  done

  # if there is no primary node found, use the default primary node
  echo "get all primary info from redis sentinel master_count_map: ${master_count_map[*]}"
  if [ ${#master_count_map[@]} -eq 0 ]; then
    echo "no primary node found from all redis sentinels, try redis kernel status or default primary node."
    init_primary_from_redis_kernel_or_default
    return
  fi

  # get the primary node only when sentinels have a quorum agreement.
  # Otherwise inspect redis kernel roles or use the deterministic default
  # primary to avoid different pods selecting different masters during
  # transient sentinel split-brain.
  max_count=0
  for host_port in "${!master_count_map[@]}"; do
    if (( ${master_count_map[$host_port]} > max_count )); then
      max_count=${master_count_map[$host_port]}
      primary=$(echo $host_port | cut -d: -f1)
      primary_port=$(echo $host_port | cut -d: -f2)
    fi
  done
  if (( max_count < quorum )); then
    echo "no quorum primary found from redis sentinels, max count: $max_count, quorum: $quorum, try redis kernel status or default primary node."
    init_primary_from_redis_kernel_or_default
  fi
}

init_primary_from_redis_kernel_or_default() {
  local status
  if get_primary_from_redis_kernel; then
    return
  else
    status=$?
  fi
  if [ "$status" -eq 2 ]; then
    echo "multiple redis masters found from kernel status, cannot choose a safe primary. Exiting."
    exit 1
  fi
  get_default_initialize_primary_node
}

build_redis_info_replication_command() {
  local redis_pod_fqdn="$1"
  local timeout_value=5
  if is_empty "$REDIS_DEFAULT_PASSWORD"; then
    echo "timeout $timeout_value redis-cli -h $redis_pod_fqdn -p $service_port INFO replication"
  else
    echo "timeout $timeout_value redis-cli -h $redis_pod_fqdn -p $service_port -a $REDIS_DEFAULT_PASSWORD INFO replication"
  fi
}

get_redis_role_from_kernel() {
  local redis_pod_fqdn="$1"
  local redis_role_command
  local logging_mask_password_command
  local output
  local exit_code
  unset_xtrace_when_ut_mode_false
  redis_role_command=$(build_redis_info_replication_command "$redis_pod_fqdn")
  logging_mask_password_command="$redis_role_command"
  if ! is_empty "$REDIS_DEFAULT_PASSWORD"; then
    logging_mask_password_command="${redis_role_command/$REDIS_DEFAULT_PASSWORD/********}"
  fi
  echo "execute redis role command: $logging_mask_password_command" >&2
  output=$(eval "$redis_role_command")
  exit_code=$?
  set_xtrace_when_ut_mode_false

  if [ $exit_code -ne 0 ]; then
    echo "Failed to retrieve redis role from $redis_pod_fqdn." >&2
    return 1
  fi
  if echo "$output" | grep -q "^role:master"; then
    echo "master"
    return 0
  fi
  if echo "$output" | grep -q "^role:slave"; then
    echo "slave"
    return 0
  fi
  echo "Unknown redis role from $redis_pod_fqdn." >&2
  return 1
}

get_primary_from_redis_kernel() {
  if ! env_exist REDIS_POD_FQDN_LIST; then
    echo "REDIS_POD_FQDN_LIST env is not set, cannot inspect redis kernel role."
    return 1
  fi

  local redis_pod_fqdn_list
  local redis_pod_fqdn
  local role
  local master_count=0
  local master_host=""
  redis_pod_fqdn_list=($(split "$REDIS_POD_FQDN_LIST" ","))
  for redis_pod_fqdn in "${redis_pod_fqdn_list[@]}"; do
    if ! role=$(get_redis_role_from_kernel "$redis_pod_fqdn"); then
      continue
    fi
    echo "redis:$redis_pod_fqdn role:$role"
    if [ "$role" = "master" ]; then
      master_count=$((master_count + 1))
      master_host="$redis_pod_fqdn"
    fi
  done

  if [ "$master_count" -eq 1 ]; then
    primary="$master_host"
    primary_port=$service_port
    echo "found primary from redis kernel status: $primary:$primary_port"
    return 0
  fi
  if [ "$master_count" -gt 1 ]; then
    echo "found multiple primaries from redis kernel status, count: $master_count"
    return 2
  fi
  echo "no primary found from redis kernel status."
  return 1
}

build_sentinel_get_master_addr_by_name_command() {
  local sentinel_pod_addr="$1"
  local timeout_value=5
  # TODO: replace $SENTINEL_SERVICE_PORT with each sentinel pod's port when sentinel service port is not the same, for example in HostNetwork mode
  if is_empty "$SENTINEL_PASSWORD"; then
    echo "timeout $timeout_value redis-cli -h $sentinel_pod_addr -p $SENTINEL_SERVICE_PORT sentinel get-master-addr-by-name $REDIS_COMPONENT_NAME"
  else
    echo "timeout $timeout_value redis-cli -h $sentinel_pod_addr -p $SENTINEL_SERVICE_PORT -a $SENTINEL_PASSWORD sentinel get-master-addr-by-name $REDIS_COMPONENT_NAME"
  fi
}

get_master_addr_by_name_from_sentinel() {
  local master_addr_by_name_command
  local sentinel_pod_addr="$1"
  unset_xtrace_when_ut_mode_false
  master_addr_by_name_command=$(build_sentinel_get_master_addr_by_name_command "$sentinel_pod_addr")
  logging_mask_password_command="${master_addr_by_name_command/$SENTINEL_PASSWORD/********}"
  echo "execute get-master-addr-by-name command: $logging_mask_password_command"
  output=$(eval "$master_addr_by_name_command")
  exit_code=$?
  set_xtrace_when_ut_mode_false

  if [ $exit_code -eq 0 ]; then
    read -r -d '' -a REDIS_SENTINEL_PRIMARY_INFO <<< "$output"
    if [ "${#REDIS_SENTINEL_PRIMARY_INFO[@]}" -eq 2 ] && [ -n "${REDIS_SENTINEL_PRIMARY_INFO[0]}" ] && [ -n "${REDIS_SENTINEL_PRIMARY_INFO[1]}" ]; then
      echo "Successfully retrieved primary info from sentinel"
      return 0
    else
      echo "Empty primary info retrieved from sentinel"
      return 1
    fi
  else
    if [ $exit_code -eq 124 ]; then
      echo "Timeout occurred while retrieving primary info from sentinel. Retrying..."
    else
      echo "Error occurred while retrieving primary info from sentinel. Retrying..."
    fi
    return 1
  fi
}

retry_get_master_addr_by_name_from_sentinel() {
  local max_retry="$1"
  local retry_delay="$2"
  local sentinel_pod_fqdn="$3"
  if call_func_with_retry "$max_retry" "$retry_delay" get_master_addr_by_name_from_sentinel "$sentinel_pod_fqdn"; then
    return 0
  else
    echo "Failed to retrieve primary info from sentinel: $sentinel_pod_fqdn after $max_retry retries."
    return 1
  fi
}

get_default_initialize_primary_node() {
  # TODO: if has advertise svc and port, we should use it as default primary node info instead of the fqdn
  min_lex_pod=$(min_lexicographical_order_pod "$REDIS_POD_NAME_LIST")
  min_lex_pod_fqdn=$(get_target_pod_fqdn_from_pod_fqdn_vars "$REDIS_POD_FQDN_LIST" "$min_lex_pod")
  if is_empty "$min_lex_pod_fqdn"; then
    echo "Error: Failed to get min lexicographical order pod: $CURRENT_POD_NAME fqdn from redis pod fqdn list: $REDIS_POD_FQDN_LIST. Exiting."
    exit 1
  fi
  echo "get the minimum lexicographical order pod name: $min_lex_pod_fqdn as default primary node"
  primary="$min_lex_pod_fqdn"
  primary_port=$service_port
}

check_current_pod_is_primary() {
  current_pod_fqdn_prefix="$CURRENT_POD_NAME.$REDIS_COMPONENT_NAME"
  if contains "$primary" "$current_pod_fqdn_prefix"; then
    echo "current pod is primary with name mapping, primary node: $primary, pod fqdn prefix:$current_pod_fqdn_prefix"
    return 0
  fi

  if ! is_empty "$redis_announce_host_value" && ! is_empty "$redis_announce_port_value"; then
    if equals "$primary" "$redis_announce_host_value" && equals "$primary_port" "$redis_announce_port_value"; then
      echo "current pod is primary with advertised svc mapping, primary: $primary, primary port: $primary_port, advertised ip:$redis_announce_host_value, advertised port:$redis_announce_port_value"
      return 0
    fi
    echo "redis advertised svc host and port exist but not match, primary: $primary, primary port: $primary_port, advertised ip:$redis_announce_host_value, advertised port:$redis_announce_port_value"
  fi

  if equals "$primary" "$CURRENT_POD_IP" && equals "$primary_port" "$service_port"; then
    echo "current pod is primary with pod ip mapping, primary node: $primary, pod ip:$CURRENT_POD_IP, service port:$service_port"
    return 0
  fi
  return 1
}

start_redis_server() {
  exec_cmd="exec redis-server /etc/redis/redis.conf"
  echo "Starting redis server cmd: $exec_cmd"
  eval "$exec_cmd"
}

# TODO: if instanceTemplate is specified, the pod service could not be parsed from the pod ordinal.
parse_redis_announce_addr() {
  if is_empty "$REDIS_ADVERTISED_PORT"; then
     REDIS_ADVERTISED_PORT="$REDIS_LB_ADVERTISED_PORT"
  fi
  # try to get the announce ip and port from REDIS_ADVERTISED_PORT(support NodePort currently) first
  if is_empty "${REDIS_ADVERTISED_PORT}"; then
    echo "Environment variable REDIS_ADVERTISED_PORT not found. Ignoring."
    # if redis is in host network mode, use the host ip and port as the announce ip and port
    if ! is_empty "${REDIS_HOST_NETWORK_PORT}"; then
      echo "redis is in host network mode, use the host ip:$CURRENT_POD_HOST_IP and port:$REDIS_HOST_NETWORK_PORT as the announce ip and port."
      redis_announce_port_value="$REDIS_HOST_NETWORK_PORT"
      redis_announce_host_value="$CURRENT_POD_HOST_IP"
    fi
    return 0
  fi

  local pod_name="$1"
  local found=false
  pod_name_ordinal=$(extract_obj_ordinal "$pod_name")
  # the value format of REDIS_ADVERTISED_PORT is "pod1Svc:advertisedPort1,pod2Svc:advertisedPort2,..."
  advertised_ports=($(split "$REDIS_ADVERTISED_PORT" ","))
  for advertised_port in "${advertised_ports[@]}"; do
    parts=($(split "$advertised_port" ":"))
    local svc_name="${parts[0]}"
    local port="${parts[1]}"
    svc_name_ordinal=$(extract_obj_ordinal "$svc_name")
    if [[ "$svc_name_ordinal" == "$pod_name_ordinal" ]]; then
      echo "Found matching svcName and port for podName '$pod_name', REDIS_ADVERTISED_PORT: $REDIS_ADVERTISED_PORT. svcName: $svc_name, port: $port."
      redis_announce_port_value="$port"
      lb_host=$(extract_lb_host_by_svc_name "$svc_name")
      if [ -n "$lb_host" ]; then
        echo "Found load balancer host for svcName '$svc_name', value is '$lb_host'."
        redis_announce_host_value="$lb_host"
        redis_announce_port_value="6379"
      else
        redis_announce_host_value="$CURRENT_POD_HOST_IP"
      fi
      found=true
      break
    fi
  done

  if equals "$found" false; then
    echo "Error: No matching svcName and port found for podName '$pod_name', REDIS_ADVERTISED_PORT: $REDIS_ADVERTISED_PORT. Exiting."
    exit 1
  fi
}

# build redis.conf
build_redis_conf() {
  # Truncate before building to guarantee a clean slate on every container start.
  # See: https://github.com/apecloud/kubeblocks-addons/issues/2686
  > "$redis_real_conf"
  load_redis_template_conf
  build_announce_ip_and_port
  build_redis_service_port
  build_replicaof_config
  rebuild_redis_acl_file
  build_redis_default_accounts
}

# This is magic for shellspec ut framework.
# Sometime, functions are defined in a single shell script.
# You will want to test it. but you do not want to run the script.
# When included from shellspec, __SOURCED__ variable defined and script
# end here. The script path is assigned to the __SOURCED__ variable.
${__SOURCED__:+false} : || return 0

# main
load_common_library
parse_redis_announce_addr "$CURRENT_POD_NAME"
build_redis_conf
start_redis_server
