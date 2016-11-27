#!/bin/bash

set -eu

cluster_sync_timeout=1800

# After migrating the cluster to HA-NG the services not under pacemaker's control
# are still up and running. We need to stop them explicitely otherwise during the yum
# upgrade the rpm %post sections will try to do a systemctl try-restart <service>, which
# is going to take a long time because rabbit is down. By having the service stopped
# systemctl try-restart is a noop

for service in $(services_to_migrate); do
    manage_systemd_service stop "${service%%-clone}"
    # So the reason for not reusing check_resource_systemd is that
    # I have observed systemctl is-active returning unknown with at least
    # one service that was stopped (See LP 1627254)
    timeout=600
    tstart=$(date +%s)
    tend=$(( $tstart + $timeout ))
    check_interval=3
    while (( $(date +%s) < $tend )); do
      if [[ "$(systemctl is-active ${service%%-clone})" = "active" ]]; then
        echo "$service still active, sleeping $check_interval seconds."
        sleep $check_interval
      else
        # we do not care if it is inactive, unknown or failed as long as it is
        # not running
        break
      fi

    done
done

# In case the mysql package is updated, the database on disk must be
# upgraded as well. This typically needs to happen during major
# version upgrades (e.g. 5.5 -> 5.6, 5.5 -> 10.1...)
#
# Because in-place upgrades are not supported across 2+ major versions
# (e.g. 5.5 -> 10.1), we rely on logical upgrades via dump/restore cycle
# https://bugzilla.redhat.com/show_bug.cgi?id=1341968
#
# The default is to determine automatically if upgrade is needed based
# on mysql package versionning, but this can be overriden manually
# to support specific upgrade scenario

# Calling this function will set the DO_MYSQL_UPGRADE variable which is used
# later
mysql_need_update

if [[ -n $(is_bootstrap_node) ]]; then
    if [ $DO_MYSQL_UPGRADE -eq 1 ]; then
        mysqldump $backup_flags > "$MYSQL_BACKUP_DIR/openstack_database.sql"
        cp -rdp /etc/my.cnf* "$MYSQL_BACKUP_DIR"
    fi

    pcs resource disable redis
    check_resource redis stopped 600
    pcs resource disable rabbitmq
    check_resource rabbitmq stopped 600
    pcs resource disable galera
    check_resource galera stopped 600
    pcs resource disable openstack-cinder-volume
    check_resource openstack-cinder-volume stopped 600
    # Disable all VIPs before stopping the cluster, so that pcs doesn't use one as a source address:
    #   https://bugzilla.redhat.com/show_bug.cgi?id=1330688
    for vip in $(pcs resource show | grep ocf::heartbeat:IPaddr2 | grep Started | awk '{ print $1 }'); do
      pcs resource disable $vip
      check_resource $vip stopped 60
    done
    pcs cluster stop --all
fi


# Swift isn't controlled by pacemaker
systemctl_swift stop

tstart=$(date +%s)
while systemctl is-active pacemaker; do
    sleep 5
    tnow=$(date +%s)
    if (( tnow-tstart > cluster_sync_timeout )) ; then
        echo_error "ERROR: cluster shutdown timed out"
        exit 1
    fi
done
