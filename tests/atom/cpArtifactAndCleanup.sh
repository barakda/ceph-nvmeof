#!/bin/bash

RUNNER_PASS=$1

echo $RUNNER_PASS | sudo -S rm -rf /tmp/artifact
cp -r /root/.ssh/atom_backup/artifact/multiIBMCloudServers_m2/* /tmp/artifact
sudo ls -lta /tmp/artifact
sudo chmod -R +rx /tmp/artifact
rm -rf /home/cephnvme/busyServer.txt
