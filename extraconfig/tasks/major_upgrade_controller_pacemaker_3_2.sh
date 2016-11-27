#!/bin/bash

set -eu

galera_sync_timeout=600

if [[ -n $(is_bootstrap_node) ]]; then
    tstart=$(date +%s)
    while ! clustercheck; do
        sleep 5
        tnow=$(date +%s)
        if (( tnow-tstart > galera_sync_timeout )) ; then
            echo_error "ERROR galera sync timed out"
            exit 1
        fi
    done

    # Run all the db syncs
    # TODO: check if this can be triggered in puppet and removed from here
    ceilometer-upgrade --config-file=/etc/ceilometer/ceilometer.conf --skip-gnocchi-resource-types
    cinder-manage db sync
    glance-manage --config-file=/etc/glance/glance-registry.conf db_sync
    heat-manage --config-file /etc/heat/heat.conf db_sync
    keystone-manage db_sync
    neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugin.ini upgrade head
    nova-manage db sync
    nova-manage api_db sync
    nova-manage db online_data_migrations
    sahara-db-manage --config-file /etc/sahara/sahara.conf upgrade head
fi
