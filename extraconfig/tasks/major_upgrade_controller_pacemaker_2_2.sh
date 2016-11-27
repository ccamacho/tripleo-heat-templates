#!/bin/bash

set -eu

cluster_sync_timeout=1800

# Calling this function will set the DO_MYSQL_UPGRADE variable which is used
# later
mysql_need_update

# The reason we do an sql dump *and* we move the old dir out of
# the way is because it gives us an extra level of safety in case
# something goes wrong during the upgrade. Once the restore is
# successful we go ahead and remove it. If the directory exists
# we bail out as it means the upgrade process had issues in the last
# run.
if [ $DO_MYSQL_UPGRADE -eq 1 ]; then
    if [ -d $MYSQL_TEMP_UPGRADE_BACKUP_DIR ]; then
        echo_error "ERROR: mysql backup dir already exist"
        exit 1
    fi
    mv /var/lib/mysql $MYSQL_TEMP_UPGRADE_BACKUP_DIR
fi

# Special-case OVS for https://bugs.launchpad.net/tripleo/+bug/1635205
if [[ -n $(rpm -q --scripts openvswitch | awk '/postuninstall/,/*/' | grep "systemctl.*try-restart") ]]; then
    echo "Manual upgrade of openvswitch - restart in postun detected"
    mkdir OVS_UPGRADE || true
    pushd OVS_UPGRADE
    echo "Attempting to downloading latest openvswitch with yumdownloader"
    yumdownloader --resolve openvswitch
    echo "Updating openvswitch with nopostun option"
    rpm -U --replacepkgs --nopostun ./*.rpm
    popd
else
    echo "Skipping manual upgrade of openvswitch - no restart in postun detected"
fi

yum -y install python-zaqarclient  # needed for os-collect-config
yum -y -q update

# Check the correct value for this workers can't be 0...
sed -i 's/osapi_compute_workers=0/osapi_compute_workers=1/g' /etc/nova/nova.conf

# We need to ensure at least those two configuration settings, otherwise
# mariadb 10.1+ won't activate galera replication.
# wsrep_cluster_address must only be set though, its value does not
# matter because it's overriden by the galera resource agent.
cat >> /etc/my.cnf.d/galera.cnf <<EOF
[mysqld]
wsrep_on = ON
wsrep_cluster_address = gcomm://localhost
EOF

if [ $DO_MYSQL_UPGRADE -eq 1 ]; then
    # Scripts run via heat have no HOME variable set and this confuses
    # mysqladmin
    export HOME=/root

    mkdir /var/lib/mysql || /bin/true
    chown mysql:mysql /var/lib/mysql
    chmod 0755 /var/lib/mysql
    restorecon -R /var/lib/mysql/
    mysql_install_db --datadir=/var/lib/mysql --user=mysql
    chown -R mysql:mysql /var/lib/mysql/

    if [ "$(hiera -c /etc/puppet/hiera.yaml bootstrap_nodeid)" = "$(facter hostname)" ]; then
        mysqld_safe --wsrep-new-cluster &
        # We have a populated /root/.my.cnf with root/password here so
        # we need to temporarily rename it because the newly created
        # db is empty and no root password is set
        mv /root/.my.cnf /root/.my.cnf.temporary
        timeout 60 sh -c 'while ! mysql -e "" &> /dev/null; do sleep 1; done'
        mysql -u root < "$MYSQL_BACKUP_DIR/openstack_database.sql"
        mv /root/.my.cnf.temporary /root/.my.cnf
        mysqladmin -u root shutdown
        # The import was successful so we may remove the folder
        rm -r "$MYSQL_BACKUP_DIR"
    fi
fi

# If we reached here without error we can safely blow away the origin
# mysql dir from every controller

# TODO: What if the upgrade fails on the bootstrap node, but not on
# this controller.  Data may be lost.
if [ $DO_MYSQL_UPGRADE -eq 1 ]; then
    rm -r $MYSQL_TEMP_UPGRADE_BACKUP_DIR
fi

# Let's reset the stonith back to true if it was true, before starting the cluster
if [[ -n $(is_bootstrap_node) ]]; then
    if [ -f /var/tmp/stonith-true ]; then
        pcs -f /var/lib/pacemaker/cib/cib.xml property set stonith-enabled=true
    fi
    rm -f /var/tmp/stonith-true
fi

# Pin messages sent to compute nodes to kilo, these will be upgraded later
crudini  --set /etc/nova/nova.conf upgrade_levels compute "$upgrade_level_nova_compute"
# https://bugzilla.redhat.com/show_bug.cgi?id=1284047
# Change-Id: Ib3f6c12ff5471e1f017f28b16b1e6496a4a4b435
crudini  --set /etc/ceilometer/ceilometer.conf DEFAULT rpc_backend rabbit
# https://bugzilla.redhat.com/show_bug.cgi?id=1284058
# Ifd1861e3df46fad0e44ff9b5cbd58711bbc87c97 Swift Ceilometer middleware no longer exists
crudini --set /etc/swift/proxy-server.conf pipeline:main pipeline "catch_errors healthcheck cache ratelimit tempurl formpost authtoken keystone staticweb proxy-logging proxy-server"
# LP: 1615035, required only for M/N upgrade.
crudini --set /etc/nova/nova.conf DEFAULT scheduler_host_manager host_manager
# LP: 1627450, required only for M/N upgrade
crudini --set /etc/nova/nova.conf DEFAULT scheduler_driver filter_scheduler

crudini --set /etc/sahara/sahara.conf DEFAULT plugins ambari,cdh,mapr,vanilla,spark,storm

