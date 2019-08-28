init() {
  install -d -o redis -g svc /data/redis; install -d -o syslog -g svc /data/redis/logs
  local htmlFile=/data/index.html; [ -e "$htmlFile" ] || ln -s /opt/app/conf/caddy/index.html $htmlFile
  _init
}

start() {
  isInitialized || execute init
  configure && _start
}

stop() {
  if [ -z "$LEAVING_REDIS_NODES" ] && isSvcEnabled redis-sentinel; then
    stopSvc redis-sentinel
    local sentinelHost; for sentinelHost in $REDIS_NODES; do
      retry 15 1 0 checkSentinelStopped ${sentinelHost##*/} || log "WARN: sentinel '$sentinelHost' is still up."
    done
  fi

  _stop
}

revive() {
  _revive $@
  checkVip || setUpVip
}

measure() {
  runRedisCmd info all | awk -F: 'BEGIN {
    g["hash_based_count"] = "^h"
    g["list_based_count"] = "^(bl|br|l|rp)"
    g["set_based_count"] = "^s[^e]"
    g["sorted_set_based_count"] = "^(bz|z)"
    g["stream_based_count"] = "^x"
    g["key_based_count"] = "^(del|dump|exists|expire|expireat|keys|migrate|move|object|persist|pexpire|pexpireat|pttl|randomkey|rename|renamenx|restore|sort|touch|ttl|type|unlink|wait|scan)"
    g["string_based_count"] = "^(append|bitcount|bitfield|bitop|bitpos|decr|decrby|get|getbit|getrange|getset|incr|incrby|incrbyfloat|mget|mset|msetnx|psetex|set|setbit|setex|setnx|setrange|strlen)"
    g["set_count"] = "^(getset|hmset|hset|hsetnx|lset|mset|msetnx|psetex|set|setbit|setex|setnx|setrange)"
    g["get_count"] = "^(get|getbit|getrange|getset|hget|hgetall|hmget|mget)"
  }
  {
    if($1~/^(cmdstat_|connected_c|db|evicted_|expired_k|keyspace_|maxmemory$|role|total_conn|used_memory$)/) {
      r[$1] = gensub(/^(keys=|calls=)?([0-9]+).*/, "\\2", 1, $2);
    }
  }
  END {
    for(k in r) {
      if(k~/^cmdstat_/) {
        cmd = gensub(/^cmdstat_/, "", 1, k)
        for(regexp in g) {
          if(cmd ~ g[regexp]) {
            m[regexp] += r[k]
          }
        }
      } else if(k~/^db[0-9]+/) {
        m["key_count"] += r[k]
      } else if(k!~/^(used_memory|maxmemory|connected_c)/) {
        m[k=="role" ? "node_role" : k] = gensub("\r", "", 1, r[k])
      }
    }
    memUsage = r["maxmemory"] ? 10000 * r["used_memory"] / r["maxmemory"] : 0
    m["memory_usage_min"] = m["memory_usage_avg"] = m["memory_usage_max"] = memUsage
    totalOpsCount = r["keyspace_hits"] + r["keyspace_misses"]
    m["hit_rate_min"] = m["hit_rate_avg"] = m["hit_rate_max"] = totalOpsCount ? 10000 * r["keyspace_hits"] / totalOpsCount : 0
    m["connected_clients_min"] = m["connected_clients_avg"] = m["connected_clients_max"] = r["connected_clients"]
    for(k in m) print k FS m[k]
  }' | jq -R 'split(":")|{(.[0]):.[1]}' | jq -sc add || ( local rc=$?; log "Failed to measure Redis: $metrics" && return $rc )
}

preScaleIn() {
  [ -n "$LEAVING_REDIS_NODES" ] || return 210
  local master; master="$(findMasterIp)" || return 211
  if [[ "$LEAVING_REDIS_NODES " == *"/$master "* ]]; then return 212; fi
}

destroy() {
  preScaleIn && execute stop
  checkVip || ( execute start && return 213 )
}

scaleIn() {
  stopSvc redis-sentinel && rm -f $runtimeSentinelFile*
}

# edge case: 4.0.9 flushall -> 5.0.5 -> backup -> restore rename flushall
restore() {
  find /data/redis -mindepth 1 ! -name appendonly.aof -delete
  execute start
}

runtimeSentinelFile=/data/redis/sentinel.conf
findMasterIp() {
  local firstRedisNode=${REDIS_NODES%% *}
  isSvcEnabled redis-sentinel && \
  # 防止 revive 时从本地文件获取，导致双主以及vip 解绑
  if [[ $command == revive ]];then
    local nodeInfo;for nodeInfo in $REDIS_NODES;do
      [[ ${nodeInfo##*/} == $MY_IP ]] && continue
      runRedisCmd --ip ${nodeInfo##*/} -p 26379 sentinel get-master-addr-by-name master |xargs \
      |awk '{if ($2 == '$REDIS_PORT') print $1; else exit 1}' && break
      done
  else  
    [ -f "$runtimeSentinelFile" ] \
      && awk 'BEGIN {rc=1} $0~/^sentinel monitor master / {print $4; rc=0} END {exit rc}' $runtimeSentinelFile 
  fi \
    || echo -n ${firstRedisNode##*/}
}

findMasterNodeId() {
  echo $REDIS_NODES | xargs -n1 | awk -F/ '$3=="'$(findMasterIp)'" {print $2}'
}

runRedisCmd() {
  local redisIp=$MY_IP; if [ "$1" == "--ip" ]; then redisIp=$2 && shift 2; fi
  timeout --preserve-status 5s /opt/redis/current/redis-cli -h $redisIp --no-auth-warning -a "$REDIS_PASSWORD" $(echo $@ |grep -q "-p" || echo "-p $REDIS_PORT") $@
}

checkVip() {
  local vipResponse; vipResponse="$(runRedisCmd --ip $REDIS_VIP ROLE | sed -n '1{p;q}')"
  [ "$vipResponse" == "master" ]
}

setUpVip() {
  local masterIp; masterIp="${1:-$(findMasterIp)}"
  local myIps; myIps="$(hostname -I)"
  log --debug "setting up vip: [master=$masterIp me=$myIps] ..."
  if [ "$MY_IP" == "$masterIp" ]; then
    [[ " $myIps " == *" $REDIS_VIP "* ]] || bindVip
  else
    [[ " $myIps " != *" $REDIS_VIP "* ]] || unbindVip
  fi
}

bindVip() {
  ip addr add $REDIS_VIP/24 dev eth0 || [ "$?" -eq 2 ] # 2: already bound
  arping -q -c 3 -A $REDIS_VIP -I eth0
}

unbindVip() {
  ip addr del $REDIS_VIP/24 dev eth0 || [ "$?" -eq 2 ] # 2: not bound
}

checkSentinelStopped() {
  ! nc -z -w3 $1 26379
}

encodeCmd() {
  echo -n ${1?command is required}${CLUSTER_ID} | sha256sum | cut -d' ' -f1
}

nodesFile=/data/redis/nodes
rootConfDir=/opt/app/conf/redis-standalone
changedConfigFile=$rootConfDir/redis.changed.conf
changedSentinelFile=$rootConfDir/sentinel.changed.conf
reload() {
  isInitialized || return 0

  if [ -n "${JOINING_REDIS_NODES}" ]; then
    log --debug "scaling out ..."
    configure && startSvc redis-sentinel
  elif [ -n "${LEAVING_REDIS_NODES}" ]; then
    log --debug "scaling in ..."
  elif checkFileChanged $changedConfigFile; then
    execute restart
  elif checkFileChanged $changedSentinelFile; then
    _update redis-sentinel
  fi
}

checkFileChanged() {
  ! ([ -f "$1.1" ] && cmp -s $1 $1.1)
}

configureForRedis() {
  local runtimeConfigFile=/data/redis/redis.conf defaultConfigFile=$rootConfDir/redis.default.conf \
        slaveofFile=$rootConfDir/redis.slaveof.conf
  sudo -u redis touch $runtimeConfigFile && rotate $runtimeConfigFile
  local masterIp; masterIp="$(findMasterIp)" 
  log --debug "masterIp is $masterIp"
  # flush every time even no master IP switches, but port is changed or in case double-master in revive
  [ "$MY_IP" == "$masterIp" ] && > $slaveofFile || echo -e "slaveof $masterIp $REDIS_PORT\nreplicaof $masterIp $REDIS_PORT" > $slaveofFile

  awk '$0~/^[^ #$]/ ? $1~/^(client-output-buffer-limit|rename-command)$/ ? !a[$1$2]++ : !a[$1]++ : 0' \
    $changedConfigFile $slaveofFile $runtimeConfigFile.1 $defaultConfigFile > $runtimeConfigFile
}

configureForChangeVxnet() {
  local runtimeConfigFile=/data/redis/redis.conf 
  sudo -u redis touch $nodesFile && rotate $nodesFile
  echo $REDIS_NODES | xargs -n1 > $nodesFile

  if checkFileChanged $nodesFile; then
    log "IP addresses changed from [$(paste -s $nodesFile.1)] to [$(paste -s $nodesFile)]. Updating config files accordingly ..."
    local replaceCmd="$(join -j1 -t/ -o1.3,2.3 $nodesFile.1 $nodesFile | sed 's#/# / #g; s#^#s/ #g; s#$# /g#g' | paste -sd';')"
    sed -i "$replaceCmd" $runtimeConfigFile $runtimeSentinelFile
  fi
}

configureForSentinel() {
  local monitorFile=$rootConfDir/sentinel.monitor.conf
  sudo -u redis touch $runtimeSentinelFile && rotate $runtimeSentinelFile
  local masterIp; masterIp="$(findMasterIp)"
  log --debug "masterIp is $masterIp"
  # flush every time even no master IP switches, but port is changed
  echo "sentinel monitor master $masterIp $REDIS_PORT 2" > $monitorFile

  if isSvcEnabled redis-sentinel; then
    awk '$0~/^[^ #$]/ ? $1~/^sentinel/ ? $2~/^rename-/ ? !a[$1$2$3$4]++ : $2~/^(anno|deny-scr)/ ? !a[$1$2]++ : !a[$1$2$3]++ : !a[$1]++ : 0' \
      $monitorFile $changedSentinelFile <(sed -r '/^sentinel (auth-pass master|rename-slaveof|rename-config|known-replica)/d' $runtimeSentinelFile.1) > $runtimeSentinelFile
  else
    rm -f $runtimeSentinelFile*
  fi
}


configure() {
  configureForChangeVxnet
  configureForSentinel
  configureForRedis  
  local masterIp; masterIp="$(findMasterIp)"
  setUpVip $masterIp
}

flushData(){
  local db=$(echo $1 |jq .db) flushCmd=$(echo $1 |jq -r .cmd)
  local cmd=$(echo -e $ALLOWED_COMMANDS | grep -o $flushCmd || encodeCmd $flushCmd)
  runRedisCmd --ip $REDIS_VIP -n $db $cmd
}