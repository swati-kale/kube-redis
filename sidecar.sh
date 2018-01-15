#!/usr/bin/env bash
set -e
[ "$DEBUG" == "true" ] && set -x
# Set vars
hostname=$(hostname)                                         # hostname of pod
ip=${POD_IP-$(hostname -i)}                                  # ip address of pod
redis_port=${NODE_PORT_NUMBER-6379}                         # redis port
sentinel_port=${SENTINEL_PORT_NUMBER-26379}                 # sentinel port
group_name="$POD_NAMESPACE-$(hostname | sed 's/-[0-9]$//')" # master group name
quorum="${SENTINEL_QUORUM-2}"                               # quorum needed

# Sentinel options
down_after_milliseconds=${DOWN_AFTER_MILLESECONDS-1000}
failover_timeout=${FAILOVER_TIMEOUT-$(($down_after_milliseconds * 10))}
parallel_syncs=${PARALEL_SYNCS-1}

# Curl envs
KUBE_TOKEN=$(</var/run/secrets/kubernetes.io/serviceaccount/token)
KUBE_CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
KUBE_NS=$(</var/run/secrets/kubernetes.io/serviceaccount/namespace)
KUBE_URL="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT_HTTPS"

# Retry a command until max tries is reached
try_step_interval=${TRY_STEP_INTERVAL-"1"}
max_tries=${MAX_TRIES-"3"}
retry() {
  local tries=0
  until $@ ; do
    status=$?
    tries=$(($tries + 1))
    if [ "$tries" -gt "$max_tries" ] ; then
      log ERROR "failed to run \`$@\` after $max_tries tries..."
      return $status
    fi
    sleepsec=1
    log ERROR "failed: \`$@\`, retryring in $sleepsec seconds..."
    sleep $sleepsec
  done
  return $?
}

# Call the cli for the redis instance
cli(){
  #log DEBUG redis-cli -p $redis_port $@
  retry timeout 5 redis-cli -p $redis_port $@
}

# Call the cli for the sentinel instance
sentinel-cli(){
  #log DEBUG redis-cli -p $sentinel_port $@
  retry timeout 5 redis-cli -p $sentinel_port $@
}

# Ping redis to see if it is up
ping() {
  cli ping > /dev/null
}

# Ping sentinel to see if it is up
ping-sentinel() {
  sentinel-cli ping > /dev/null
}

# Ping redis and sentinel to see if they are up
ping-both(){
  ping && ping-sentinel
}

# Get the role for this node or the specified ip/host
role() {
  host=${1-"127.0.0.1"}
  (cli -h $host info || echo -n "role:none") | grep "role:" | sed "s/role://" | tr -d "\n" | tr -d "\r"
}

sentinel-reset() {
  host=$1
  desired_sentinels_cnt=$2
  log DEBUG "RESET SENTINEL $host ($desired_sentinels_cnt)"
  cli -h $host -p $sentinel_port ping;
  if [[ "$?" != "0" ]]; then
    return 1;
  fi
  cli -h $host -p $sentinel_port SENTINEL RESET $group_name
  tmp_cnt=0
  while true; do
    sleep 1;
    sentinels_in_redis_cnt=`cli -h $host -p $sentinel_port SENTINEL sentinels $group_name | grep name | wc -l`
    if [[ "$sentinels_in_redis_cnt" > "0" ]]; then
      log DEBUG "Sentinel reset OK"
      break
    elif [[ "$tmp_cnt" > "30" ]]; then
      #не дождались сентинелей за 30 секунд
      log DEBUG "Sentinel reset NOT OK $tmp_cnt"
      break
    fi
    tmp_cnt=$((tmp_cnt+1))
  done;
}

# Convert this node to a slave of the specified master
become-slave-of() {
  host=$1
  log INFO "becoming a slave of $host"
  sentinel-monitor $host
  cli slaveof $host $redis_port > /dev/null
}

# Tell sentinel to monitor a particular master
sentinel-monitor() {
  sentinel_master_host=$1
  sentinel_host=${2-localhost}
  sentinel-cli -h $sentinel_host sentinel remove $group_name &> /dev/null
  sentinel-cli -h $sentinel_host sentinel monitor $group_name $sentinel_master_host $redis_port $quorum > /dev/null
  sentinel-cli -h $sentinel_host sentinel set $group_name down-after-milliseconds $down_after_milliseconds > /dev/null
  sentinel-cli -h $sentinel_host sentinel set $group_name failover-timeout $failover_timeout > /dev/null
  sentinel-cli -h $sentinel_host sentinel set $group_name parallel-syncs $parallel_syncs > /dev/null
}

# Find the first host that identifys as a master
active-master(){
  master=""
  for host in `get-hosts` ; do
    #log DEBUG "checking to see if '$host' is master..."
    if [ "$(role $host)" = "master" ] ; then
      #log DEBUG "found master: '$host'"
      master=$host
      break
    fi
  done
  if [ -z "$master" ] ; then
    log DEBUG "active-master: found no active master"
  else
    log DEBUG "active-master: $master"
  fi
  echo -n $master
}

active-sentinel-master(){
  master=""
  for host in `get-hosts` ; do
    #log DEBUG "checking to see if '$host' is master..."
    master=`redis-cli -h $host -p 26379 SENTINEL get-master-addr-by-name $group_name | grep -Po "[^\s]+" | xargs | tr -d '\r\n' | awk {'print $1'}`
    #log DEBUG "MASTER: $? $master"
    if [ -z "$master" ]; then
      master=`active-master`
    fi
    break;
  done

  if [ -z "$master" ] ; then
    log DEBUG "active-sentinel-master: found no active master"
  else
    log DEBUG "active-sentinel-master: $master"
  fi
  echo -n $master
}

fix-sentinel-if-needed(){
    sentinel_host=$1
    sentinel_master=$2
    master=`redis-cli -h $sentinel_host -p 26379 SENTINEL get-master-addr-by-name $group_name | grep -Po "[^\s]+" | xargs | tr -d '\r\n' | awk {'print $1'}`
    if [ -z "$master" ]; then
      log DEBUG "sentinel-monitor $sentinel_host $sentinel_master"
      sentinel-monitor $sentinel_master $sentinel_host
    fi
}

unset-label-on-other-masters(){
  labels=$(echo $(cat /etc/pod-info/labels | grep -v "role=") | tr -d '"' | tr " " ","),role=master
  for i in `curl -sS --cacert $KUBE_CA -H "Authorization: Bearer $KUBE_TOKEN" \
    https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT_HTTPS/api/v1/namespaces/$KUBE_NS/pods?labelSelector=$labels \
  | jq -r '.["items"][] | .status.conditions[].type + "=" + .status.conditions[].status + " " +.status.podIP + " " +.metadata.name' | grep 'Ready=True' | grep -v $ip | awk '{print $3}' | sort | uniq`; do
    set-role-label "$i" "none"
  done

}

get-hosts(){
  labels=$(echo $(cat /etc/pod-info/labels | grep -v "role=" ) | tr -d '"' | tr " " ",")
  curl -sS --cacert $KUBE_CA -H "Authorization: Bearer $KUBE_TOKEN" \
    https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT_HTTPS/api/v1/namespaces/$KUBE_NS/pods?labelSelector=$labels \
  | jq -r '.["items"][] | .status.conditions[].type + "=" + .status.conditions[].status + " " +.status.podIP' | grep 'Ready=True' | awk '{print $2}' | sort | uniq | grep -v $ip
}

get-all-hosts(){
  labels=$(echo $(cat /etc/pod-info/labels | grep -v "role=" ) | tr -d '"' | tr " " ",")
  curl -sS --cacert $KUBE_CA -H "Authorization: Bearer $KUBE_TOKEN" \
    https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT_HTTPS/api/v1/namespaces/$KUBE_NS/pods?labelSelector=$labels \
  | jq -r '.["items"][] | .status.conditions[].type + "=" + .status.conditions[].status + " " +.status.podIP' | grep 'Ready=True' | awk '{print $2}' | sort | uniq
}


# Set the role label on the pod to the specified value
set-role-label () {
  pod_hostname=$1
  pod_role=$2
  log INFO "set label \"role=$pod_role\""
#  (kubectl label --overwrite pods `hostname` role=$1 > /dev/null) || panic "set-role-label failed"
  curl -sfS --cacert $KUBE_CA -H "Authorization: Bearer $KUBE_TOKEN" \
    -H "Content-Type:application/merge-patch+json" -X PATCH \
    --data "{\"metadata\":{\"labels\":{\"role\":\"$pod_role\" }}}" \
    https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT_HTTPS/api/v1/namespaces/$KUBE_NS/pods/$pod_hostname >>/dev/null || panic "set-role-label failed"
}

# Print a message to stderr
log () {
  label=$1
  shift
  message="$@"
  >&2 echo "$hostname $label: $message"
}


# Exit, printing an error message
panic () {
  log CRITICAL $1
  exit 1
}

# Boot the sidecar
boot(){
  log INFO "booting (ip: $ip)"

  # set roll label to "none"
  set-role-label $(hostname) "none"

  # wait, as things may still be failing over
  sleep $(($failover_timeout / 1000))

  active_master=$(active-sentinel-master)
  #self_healing $active_master

  if [ -n "$active_master" ] && [ "$active_master" != "$ip" ] ; then
    become-slave-of $active_master
  else
    sentinel-monitor $ip
  fi

  # Check to ensure both the sentinel and redis are up,
  # if not, exit with an error
  ping-both || panic "redis and/or sentinel is not up"
  log INFO "booting completed"
  touch booted
}

monitor-state-ng(){
  last_role=none
  while true; do

    current_role=`role`
    active_master=$(active-sentinel-master)

    if [ "$last_role" != "$current_role" ] ; then
      if [ "$current_role" = "master" ]; then
        if [ ! -z "$active_master" ]; then
          if [ "$ip" != "$active_master" ]; then
            # я, судя по кворуму, на самом деле не мастер
  	    # redis перезапустился в мастер-режиме, делаем его none, а дальше sentinel проставит правильную role
            set-role-label $(hostname) "none"
            #sentinel-monitor $active_master
            #become-slave-of $active_master
            last_role="none"
            current_role="none"
	  else
            # я теперь мастер, метим насильно другие мастер-узлы слейвами (если перед этим нода с мастером упала - мастером остается под на упавшей ноде еще несколько минут)
            unset-label-on-other-masters
            set-role-label $(hostname) $current_role
          fi
        else
          log DEBUG "QUORUM active_master: $active_master"
        fi
      #else
        #if [ "$ip" != "$active_master" ]; then
        #  become-slave-of $active_master
        #fi
      fi

      set-role-label $(hostname) $current_role
      last_role=$current_role
    elif [ "$current_role" = "master" ]; then
      # checking all instances for dead sentinels and resetting them
      HOSTS_FROM_KUBE_NEW=`get-all-hosts | sort`
      for host in $HOSTS_FROM_KUBE_NEW; do
        #probably need to reset sentinels
        DATA_FROM_SENTINEL=`(sentinel-cli -h $host SENTINEL sentinels $group_name || echo "") | grep -v 'ERR No such master'`
        if [ ! -z "$DATA_FROM_SENTINEL" ]; then
          HOSTS_FROM_SENTINEL=`echo "$DATA_FROM_SENTINEL" | grep -A1 ip  | grep -v ip | grep -v '\-'`
       	  HOSTS_FROM_SENTINEL="$HOSTS_FROM_SENTINEL
$host"
          HOSTS_FROM_SENTINEL=`echo "$HOSTS_FROM_SENTINEL" | sort`
	  if ! diff <(echo "$HOSTS_FROM_KUBE_NEW") <(echo "$HOSTS_FROM_SENTINEL"); then
            log DEBUG "Checking SENTINEL HOSTS ON '$host'..."
            log DEBUG "HOSTS_FROM_KUBE_NEW: $HOSTS_FROM_KUBE_NEW"
            log DEBUG "HOSTS_FROM_SENTINEL: $HOSTS_FROM_SENTINEL"

            sentinel-reset $host $(($(echo "$HOSTS_FROM_SENTINEL" | wc -l)-1)) || panic "Can't SENTINEL RESET ON '$host'!"
	  fi
        elif [ ! -z "`sentinel-cli -h $host ping`" ]; then
          if [ "$host" != "$active_master" ]; then
            fix-sentinel-if-needed $host $active_master
          fi
        fi
      done
    fi;
    #TODO repair if cluster is fully broken

    sleep 1
    if [ -f "/data/$HOSTNAME.restart" ]; then
      rm -f /data/$HOSTNAME.restart;
      exit 0;
    fi
  done
}


boot
monitor-state-ng
