#!/bin/bash

echo "HELLO BARAK"

# ATOM_IMAGE=0.0.9946
# VM_PASS=$1

# # echo $VM_PASS | sudo -S pwd;ls -lta

# while true; do
#     if [ -f "/home/cephnvme/busyServer.txt" ]; then
#         echo "The server is busy with another github action job, please wait..."
#         sleep 90
#     else
#         echo "The server is available for use!"
# 	touch /tmp/busyServer.txt
#         chmod +rx /home/cephnvme/busyServer.txt
#         break
#     fi
# done

# echo "atom cleanup script run."

# echo $VM_PASS | sudo -S docker run -v /root/.ssh:/root/.ssh quay.io/barakda1/nvmeof_atom:$ATOM_IMAGE ansible-playbook -i custom_inventory.ini cephnvmeof_remove_cluster.yaml --extra-vars 'SELECTED_ENV=multiIBMCloudServers_m2'

# cleanup_containers() {
#     local command=$1
#     sudo $command ps -q | xargs -r sudo $command stop
#     sudo $command ps -q | xargs -r sudo $command rm -f
#     sudo yes | $command system prune -fa
#     $command ps
#     $command images
# }
# cleanup_containers docker
# cleanup_containers podman

# remote_cleanup() {
#     local host=$1
#     ssh -o StrictHostKeyChecking=no root@$host "sudo docker ps -q | xargs -r sudo docker stop; \
#     sudo docker ps -q | xargs -r sudo docker rm -f; sudo yes | docker system prune -fa; \
#     sudo docker ps; sudo docker images"
# }
# hosts=("cephnvme-vm9" "cephnvme-vm7" "cephnvme-vm6" "cephnvme-vm1")

# for host in "${hosts[@]}"; do
#     remote_cleanup $host
# done