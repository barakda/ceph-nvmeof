#!/bin/bash

ATOM_IMAGE=1.0.0
ATOM_REPO_OWNER=$1
NVMEOF_REPO_OWNER=$2
ATOM_REPO_TOKEN=$3
RUNNER_PASS=$4


pwd;ls -lta

#######rm -rf /home/cephnvme/actions-runner-$NVMEOF_REPO_OWNER/brkd_work/ceph-nvmeof/ceph-nvmeof
rm -rf /home/cephnvme/actions-runner-$NVMEOF_REPO_OWNER/ceph-nvmeof-atom

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

TRIMMED_ATOM_REPO_OWNER="${ATOM_REPO_OWNER%?}"

echo "=> Cleanup docker images:"
echo $RUNNER_PASS | sudo -S sh -c 'docker ps -q | xargs -r sudo docker stop; sudo docker ps -q | xargs -r sudo docker rm -f; sudo yes | docker system prune -fa; docker ps; docker images'

echo "=> Cloning atom repo:"
git clone --branch devel https://$TRIMMED_ATOM_REPO_OWNER:$ATOM_REPO_TOKEN@github.ibm.com/NVME-Over-Fiber/ceph-nvmeof-atom.git /home/cephnvme/actions-runner-$NVMEOF_REPO_OWNER/ceph-nvmeof-atom
echo "=> Build atom images based on the cloned repo:"
docker build -t nvmeof_atom:$ATOM_IMAGE /home/cephnvme/actions-runner-$NVMEOF_REPO_OWNER/ceph-nvmeof-atom
echo "=> Remove ceph cluster:"
docker run -v /root/.ssh:/root/.ssh nvmeof_atom:$ATOM_IMAGE ansible-playbook -i custom_inventory.ini cephnvmeof_remove_cluster.yaml --extra-vars 'SELECTED_ENV=multiIBMCloudServers_m2'

echo "Cleanup remain ceph images:"
ssh -o StrictHostKeyChecking=no root@cephnvme-vm9 'sudo docker ps -q | xargs -r sudo docker stop; sudo docker ps -q | xargs -r sudo docker rm -f; sudo yes | docker system prune -fa; sudo docker ps; sudo docker images'
ssh -o StrictHostKeyChecking=no root@cephnvme-vm7 'sudo docker ps -q | xargs -r sudo docker stop; sudo docker ps -q | xargs -r sudo docker rm -f; sudo yes | docker system prune -fa; sudo docker ps; sudo docker images'
ssh -o StrictHostKeyChecking=no root@cephnvme-vm6 'sudo docker ps -q | xargs -r sudo docker stop; sudo docker ps -q | xargs -r sudo docker rm -f; sudo yes | docker system prune -fa; sudo docker ps; sudo docker images'
ssh -o StrictHostKeyChecking=no root@cephnvme-vm1 'sudo docker ps -q | xargs -r sudo docker stop; sudo docker ps -q | xargs -r sudo docker rm -f; sudo yes | docker system prune -fa; sudo docker ps; sudo docker images'

echo $RUNNER_PASS | sudo -S sh -c 'podman ps -q | xargs -r sudo podman stop; sudo podman ps -q | xargs -r sudo podman rm -f; sudo yes | podman system prune -fa; podman ps; podman images'
