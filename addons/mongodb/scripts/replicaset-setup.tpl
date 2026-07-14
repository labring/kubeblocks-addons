#!/bin/sh

{{- $mongodb_root := getVolumePathByName ( index $.podSpec.containers 0 ) "data" }}
{{- $mongodb_port_info := getPortByName ( index $.podSpec.containers 0 ) "mongodb" }}

# require port
{{- $mongodb_port := 27017 }}
{{- if $mongodb_port_info }}
{{- $mongodb_port = $mongodb_port_info.containerPort }}
{{- end }}

PORT={{ $mongodb_port }}
MONGODB_ROOT={{ $mongodb_root }}
RPL_SET_NAME=$(echo $KB_POD_NAME | grep -o ".*-");
RPL_SET_NAME=${RPL_SET_NAME%-};
mkdir -p $MONGODB_ROOT/db
mkdir -p $MONGODB_ROOT/logs
mkdir -p $MONGODB_ROOT/tmp

repair_single_member_replset_host() {
  if [ -z "$KB_POD_NAME" ] || [ -z "$KB_NAMESPACE" ] || [ -z "$RPL_SET_NAME" ]; then
    echo "INFO: skip replset host compatibility repair, pod metadata is empty."
    return 0
  fi
  if [ ! -d "$MONGODB_ROOT/db/local" ] && [ ! -f "$MONGODB_ROOT/db/WiredTiger" ]; then
    return 0
  fi

  REPAIR_PORT=${MONGODB_REPLSET_HOST_REPAIR_PORT:-27028}
  REPAIR_LOG=$MONGODB_ROOT/logs/mongodb-replset-host-repair.log
  REPAIR_PIDFILE=$MONGODB_ROOT/tmp/mongodb-replset-host-repair.pid
  EXPECTED_HOST="$KB_POD_NAME.$RPL_SET_NAME-headless.$KB_NAMESPACE.svc.cluster.local:$PORT"
  SHORT_HOST="$KB_POD_NAME.$RPL_SET_NAME-headless.$KB_NAMESPACE.svc:$PORT"

  echo "INFO: checking single-member MongoDB replset host compatibility."
  rm -f "$REPAIR_PIDFILE"
  mongod --bind_ip 127.0.0.1 --port $REPAIR_PORT --dbpath $MONGODB_ROOT/db --directoryperdb --logpath "$REPAIR_LOG" --logappend --pidfilepath "$REPAIR_PIDFILE" --setParameter enableLocalhostAuthBypass=true &
  REPAIR_PID=$!

  i=0
  until $CLIENT --quiet --port $REPAIR_PORT --eval "print('repair process is ready')" >/dev/null 2>&1; do
    i=$(( i + 1 ))
    if [ $i -ge 30 ]; then
      echo "WARN: skip replset host compatibility repair, standalone mongod is not ready."
      cat "$REPAIR_LOG" 2>/dev/null || true
      $CLIENT --quiet --port $REPAIR_PORT admin --eval 'db.shutdownServer({force:true})' >/dev/null 2>&1 || true
      wait $REPAIR_PID 2>/dev/null || true
      return 0
    fi
    sleep 1
  done

  repair_output=$($CLIENT --quiet --port $REPAIR_PORT local --eval "
var expectedRS = '$RPL_SET_NAME';
var expectedHost = '$EXPECTED_HOST';
var shortHost = '$SHORT_HOST';
var cfg = db.system.replset.findOne();
if (!cfg || !cfg._id) {
  print('compat_result=no_local_replset_config');
  quit(0);
}
if (cfg._id !== expectedRS) {
  print('compat_result=unexpected_replset_name current=' + cfg._id + ' expected=' + expectedRS);
  quit(0);
}
if (!cfg.members || cfg.members.length !== 1) {
  print('compat_result=skip_member_count count=' + (cfg.members ? cfg.members.length : 0));
  quit(0);
}
if (cfg.members[0].host === expectedHost) {
  print('compat_result=already_expected host=' + expectedHost);
  quit(0);
}
if (cfg.members[0].host !== shortHost) {
  print('compat_result=skip_unexpected_host current=' + cfg.members[0].host + ' expected_short=' + shortHost);
  quit(0);
}
print('compat_previous_host=' + cfg.members[0].host);
cfg.version = (cfg.version || 1) + 1;
cfg.members[0].host = expectedHost;
cfg.members[0].priority = 2;
cfg.members[0].votes = 1;
cfg.members[0].hidden = false;
cfg.members[0].arbiterOnly = false;
var res = db.system.replset.replaceOne({_id: cfg._id}, cfg);
print('compat_reconfig_result=' + JSON.stringify(res));
print('compat_result=repaired host=' + expectedHost);
" 2>&1 || true)
  echo "$repair_output"

  $CLIENT --quiet --port $REPAIR_PORT admin --eval 'db.shutdownServer({force:true})' >/dev/null 2>&1 || true
  wait $REPAIR_PID 2>/dev/null || true
}

BACKUPFILE=$MONGODB_ROOT/db/mongodb.backup
PORT_FOR_RESTORE=27027
CLIENT=`which mongosh>/dev/null&&echo mongosh||echo mongo`
if [ -f $BACKUPFILE ]
then
  mongod --bind_ip_all --port $PORT_FOR_RESTORE --dbpath $MONGODB_ROOT/db --directoryperdb --logpath $MONGODB_ROOT/logs/mongodb.log  --logappend --pidfilepath $MONGODB_ROOT/tmp/mongodb.pid&
  until $CLIENT --quiet --port $PORT_FOR_RESTORE --eval "print('restore process is ready')"; do sleep 1; done
  PID=`cat $MONGODB_ROOT/tmp/mongodb.pid`

  $CLIENT --quiet --port $PORT_FOR_RESTORE local --eval "db.system.replset.deleteOne({})"
  $CLIENT --quiet --port $PORT_FOR_RESTORE local --eval "db.system.replset.find()"
  $CLIENT --quiet --port $PORT_FOR_RESTORE admin --eval 'db.dropUser("root", {w: "majority", wtimeout: 4000})' || true
  kill $PID
  wait $PID
  echo "INFO: restore set-up configuration successfully."
  rm $BACKUPFILE
fi

repair_single_member_replset_host

exec mongod  --bind_ip_all --port $PORT --replSet $RPL_SET_NAME  --config /etc/mongodb/mongodb.conf
