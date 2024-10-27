#!/bin/bash

sudo rm -rf /home/cephnvme/artifact/multiIBMCloudServers_m6
sudo cp -r /root/.ssh/atom_backup/artifact/multiIBMCloudServers_m6 /home/cephnvme/artifact
sudo chown -R cephnvme:cephnvme /home/cephnvme/artifact
tar -czf /home/cephnvme/artifact.tar.gz -C /home/cephnvme/artifact .
ls -lta /home/cephadm/artifact
ls -lta /home/cephadm
chmod +rx /home/cephnvme/artifact.tar.gz
rm -rf /home/cephnvme/busyServer.txt
