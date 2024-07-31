#!/bin/bash

ATOM_IMAGE=0.0.9942
VM_PASS=$1

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <parameter1> <parameter2>"
    exit 1
fi

REPO="$2"
BRANCH="$3"
if [ $BRANCH = "merge" ]; then
    REPO="ceph/ceph-nvmeof"
    BRANCH="devel"
fi

echo $VM_PASS | sudo -S ls -lta
VERSION=$(curl -s https://raw.githubusercontent.com/$REPO/$BRANCH/.env | grep -o 'VERSION="[^"]*"' | awk -F '"' '{print $2}' | head -n 1)
CEPH_SHA=$(curl -s https://raw.githubusercontent.com/$REPO/$BRANCH/.env | grep CEPH_SHA | cut -d'=' -f2)

echo "atom test script run:"
sudo docker run -v /root/.ssh:/root/.ssh quay.io/barakda1/nvmeof_atom:$ATOM_IMAGE python3 cephnvme_atom.py quay.ceph.io/ceph-ci/ceph:$CEPH_SHA quay.io/ceph/nvmeof:$VERSION quay.io/ceph/nvmeof-cli:$VERSION https://github.com/$REPO $BRANCH None None None 4 1 2 4 1024 2 2 200M 0 1 --stopNvmeofDaemon --stopNvmeofSystemctl --stopMonLeader --gitHubActionDeployment --dontUseMTLS --dontPowerOffCloudVMs noKey --multiIBMCloudServers_m2