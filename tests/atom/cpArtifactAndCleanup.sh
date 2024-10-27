#!/bin/bash

rm -rf /home/cephnvme/artifact/*
ls -lta /home/cephnvme/artifact

rm -rf /home/cephnvme/artifact.tar.gz
ls -lta /home/cephnvme/

sudo cp -r /root/.ssh/atom_backup/artifact/multiIBMCloudServers_m6 /home/cephnvme/artifact
sudo chown -R cephnvme:cephnvme /home/cephnvme/artifact
ls -lta /home/cephnvme/artifact

tar -czf /home/cephnvme/artifact.tar.gz -C /home/cephnvme/artifact .
ls -lta /home/cephnvme/artifact
ls -lta /home/cephnvme
chmod +rx /home/cephnvme/artifact.tar.gz
rm -rf /home/cephnvme/busyServer.txt
