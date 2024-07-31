#!/bin/bash

ATOM_REPO_OWNER=$1
ATOM_REPO_TOKEN=$2
RUNNER_PASS=$3
ATOM_IMAGE=latest

pwd;ls -lta
# echo $RUNNER_PASS | sudo -S pwd;ls -lta

TRIMMED_ATOM_REPO_OWNER="${ATOM_REPO_OWNER%?}"

echo "Cloning atom repo:"
git clone --branch devel https://$TRIMMED_ATOM_REPO_OWNER:$ATOM_REPO_TOKEN@github.ibm.com/NVME-Over-Fiber/ceph-nvmeof-atom.git /home/cephnvme/ceph-nvmeof-atom

docker build -t quay.io/@ATOM_REPO_OWNER/nvmeof_atom:test1 /home/cephnvme/ceph-nvmeof-atom

while true; do
    if [ -f "/home/cephnvme/busyServer.txt" ]; then
        echo "The server is busy with another github action job, please wait..."
        sleep 90
    else
        echo "The server is available for use!"
	    touch /home/cephnvme/busyServer.txt
        chmod +rx /home/cephnvme/busyServer.txt
        break
    fi
done

cleanup_containers() {
    local command=$1
    sudo $command ps -q | xargs -r sudo $command stop
    sudo $command ps -q | xargs -r sudo $command rm -f
    sudo yes | $command system prune -fa
    $command ps
    $command images
}
cleanup_containers docker
cleanup_containers podman

remote_cleanup() {
    local host=$1
    ssh -o StrictHostKeyChecking=no root@$host "sudo docker ps -q | xargs -r sudo docker stop; \
    sudo docker ps -q | xargs -r sudo docker rm -f; sudo yes | docker system prune -fa; \
    sudo docker ps; sudo docker images"
}
hosts=("cephnvme-vm9" "cephnvme-vm7" "cephnvme-vm6" "cephnvme-vm1")

for host in "${hosts[@]}"; do
    remote_cleanup $host
done

echo $RUNNER_PASS | sudo -S docker run -v /root/.ssh:/root/.ssh quay.io/barakda1/nvmeof_atom:$ATOM_IMAGE ansible-playbook -i custom_inventory.ini cephnvmeof_remove_cluster.yaml --extra-vars 'SELECTED_ENV=multiIBMCloudServers_m2'
