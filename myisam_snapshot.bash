#!/bin/bash

#set -x
set -e

export LANG=C
export PATH=/usr/gnu/bin:/usr/bin:/bin

mysql="/opt/mysql-5.6/bin/mysql"
mysqlbinlog="/opt/mysql-5.6/bin/mysqlbinlog"
zfs="/usr/sbin/zfs"
sudo="/usr/bin/sudo"

### 23:55 時点での今日。 2013/03/01 23:59:59 が済んだ時点で hoge を hoge_20130301 にする。
date=today

### snapshot つくるデータベース名
db=$2

date=$(date +%Y%m%d -d"$date")
path=$($zfs list -H -o mountpoint tank/origin)

### とりあえず sql_thread 止める
$mysql -e'STOP SLAVE SQL_THREAD'

### {{{ 0 時ちょうどを調べる
echo "detecting relaylog file and pos..."

relaylog_base=$($mysql -NB -e "SHOW VARIABLES LIKE 'relay_log_basename'" | cut -f2)
relaylog_index=$($mysql -e'SHOW SLAVE STATUS\G' | grep ' Relay_Log_File: ' | cut -f2 -d.)
date_next=$(date +%Y-%m-%d -d"+1day $date")
echo "checking ${relaylog_base}.${relaylog_index}"

while :; do
    relaylog_pos=$($sudo -u mysql $mysqlbinlog \
        --start-datetime="${date_next} 00:00:00" --stop-datetime="${date_next} 00:00:01" \
        ${relaylog_base}.${relaylog_index} \
        | sed -n '/^# at [0-9]\+/{N; /#[0-9].*Query/{P; q}}' \
        | cut -f3 -d' ')

    ### break if found
    if [ ! -z "${relaylog_pos}" ]; then
        echo "found in pos=${relaylog_pos}."
        break
    fi

    ### if not found, and if next index has already exists, go to next index.
    relaylog_index_next=$(printf %06d $(expr ${relaylog_index} + 1))
    if [ -f ${relaylog_base}.${relaylog_index_next} ]; then
        relaylog_index=${relaylog_index_next}
        echo "checking ${relaylog_base}.${relaylog_index}"
        continue
    fi

    sleep 5
    echo -n '+'
done
### }}}

### {{{ 調べたとこまで進める
echo "waiting for replication..."

relaylog_file=$(basename ${relaylog_base}.${relaylog_index})
$mysql -e"START SLAVE SQL_THREAD UNTIL RELAY_LOG_FILE='${relaylog_file}', RELAY_LOG_POS=${relaylog_pos}"
sleep 10
while :; do
    if [ -z "$($mysql -e'SHOW SLAVE STATUS\G' | grep 'Slave_SQL_Running:' | grep 'Yes')" ]; then
        break
    fi

    sleep 5
    echo -n '*'
done
### }}}

### slave 全部止める
$mysql -e'STOP SLAVE'

### {{{ zfs snaspshot
echo "taking zfs snapshot for db=${db}, date=${date}..."

$mysql -e'FLUSH TABLES WITH READ LOCK; SELECT SLEEP(3600)' &
lock_pid=$(jobs -p)
disown
sleep 5

$sudo $zfs snapshot -r tank/origin@$date
$sudo $zfs clone -o readonly=on -o mountpoint=$path/${db}_${date} tank/origin/$db@$date tank/snap/$db/$date

$sudo kill $lock_pid
wait
### }}}

### slave 戻す
$mysql -e'FLUSH TABLES'
$mysql -e'START SLAVE'

exit
