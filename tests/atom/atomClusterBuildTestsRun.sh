#!/bin/bash

RUNNER_PASS=$1
REPO=$2
BRANCH=$3
VERSION=$4
CEPH_SHA=$5
ATOM_SHA=$6

echo "=> The atom test is about to run with the next parameters:"
echo "   NVMEoF repo: $REPO"
echo "   Branch: $BRANCH"
echo "   NVMEoF version: $VERSION"
echo "   Ceph SHA: $CEPH_SHA"

if [ $BRANCH = "merge" ]; then
    REPO="ceph/ceph-nvmeof"
    BRANCH="devel"
fi

echo "atom test script run:"
echo $RUNNER_PASS | sudo -S docker run -v /root/.ssh:/root/.ssh nvmeof_atom:$ATOM_SHA python3 cephnvme_atom.py quay.ceph.io/ceph-ci/ceph:$CEPH_SHA quay.io/ceph/nvmeof:$VERSION quay.io/ceph/nvmeof-cli:$VERSION https://github.com/$REPO $BRANCH None None None 4 1 2 4 1024 2 2 200M 0 1 --stopNvmeofDaemon --stopNvmeofSystemctl --stopMonLeader --gitHubActionDeployment --dontUseMTLS --dontPowerOffCloudVMs noKey --multiIBMCloudServers_m2