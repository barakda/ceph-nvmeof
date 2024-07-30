#!/bin/bash
VM_PASS=$1

echo $VM_PASS | sudo -S cp -r /root/.ssh/atom_backup/artifact /tmp/
sudo ls -lta /tmp/artifact
sudo chmod -R +rx /tmp/artifact
rm -rf /tmp/busyServer.txt