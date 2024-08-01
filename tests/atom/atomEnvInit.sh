#!/bin/bash

ATOM_REPO_OWNER=$1
NVMEOF_REPO_OWNER=$2
ATOM_REPO_TOKEN=$3
RUNNER_PASS=$4
ATOM_BRANCH=$5
ATOM_SHA=$6

TRIMMED_ATOM_REPO_OWNER="${ATOM_REPO_OWNER%?}"

cleanup_docker_images() {
    local HOST=$1
    ssh -o StrictHostKeyChecking=no root@$HOST << EOF
    sudo docker ps -q | xargs -r sudo docker stop
    sudo docker ps -q | xargs -r sudo docker rm -f
    sudo yes | sudo docker system prune -fa
    sudo docker ps
    sudo docker images
EOF
}

# Remove repo folder
rm -rf /home/cephnvme/actions-runner-$NVMEOF_REPO_OWNER/ceph-nvmeof-atom

# Check if cluster is busy with another run
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

# Cleanup docker images
echo $RUNNER_PASS | sudo -S sh -c 'docker ps -q | xargs -r sudo docker stop; sudo docker ps -q | xargs -r sudo docker rm -f; sudo yes | docker system prune -fa; docker ps; docker images'

# Cloning atom repo
git clone --branch $ATOM_BRANCH https://$TRIMMED_ATOM_REPO_OWNER:$ATOM_REPO_TOKEN@github.ibm.com/NVME-Over-Fiber/ceph-nvmeof-atom.git /home/cephnvme/actions-runner-$NVMEOF_REPO_OWNER/ceph-nvmeof-atom
if [ $? -ne 0 ]; then
    echo "Error: Failed to clone the atom repository."
    exit 1
fi

# Switch to given SHA
cd /home/cephnvme/actions-runner-$NVMEOF_REPO_OWNER/ceph-nvmeof-atom
git checkout $ATOM_SHA
if [ $? -ne 0 ]; then
    echo "Error: Failed to checkout the specified SHA."
    exit 1
fi

# Build atom images based on the cloned repo
docker build -t nvmeof_atom:$ATOM_SHA /home/cephnvme/actions-runner-$NVMEOF_REPO_OWNER/ceph-nvmeof-atom
if [ $? -ne 0 ]; then
    echo "Error: Failed to build Docker image."
    exit 1
fi

# Remove ceph cluster
docker run -v /root/.ssh:/root/.ssh nvmeof_atom:$ATOM_SHA ansible-playbook -i custom_inventory.ini cephnvmeof_remove_cluster.yaml --extra-vars 'SELECTED_ENV=multiIBMCloudServers_m2'
if [ $? -ne 0 ]; then
    echo "Error: Failed to run cephnvmeof_remove_cluster ansible-playbook."
    exit 1
fi

echo "Cleanup remain images after ceph cluster removal:"
HOSTS=("cephnvme-vm9" "cephnvme-vm7" "cephnvme-vm6" "cephnvme-vm1")
for HOST in "${HOSTS[@]}"; do
    echo "=> Cleaning up Docker images on $HOST"
    cleanup_docker_images "$HOST"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to clean up Docker images on $HOST."
    fi
done

# ssh -o StrictHostKeyChecking=no root@cephnvme-vm9 'sudo docker ps -q | xargs -r sudo docker stop; sudo docker ps -q | xargs -r sudo docker rm -f; sudo yes | docker system prune -fa; sudo docker ps; sudo docker images'
# ssh -o StrictHostKeyChecking=no root@cephnvme-vm7 'sudo docker ps -q | xargs -r sudo docker stop; sudo docker ps -q | xargs -r sudo docker rm -f; sudo yes | docker system prune -fa; sudo docker ps; sudo docker images'
# ssh -o StrictHostKeyChecking=no root@cephnvme-vm6 'sudo docker ps -q | xargs -r sudo docker stop; sudo docker ps -q | xargs -r sudo docker rm -f; sudo yes | docker system prune -fa; sudo docker ps; sudo docker images'
# ssh -o StrictHostKeyChecking=no root@cephnvme-vm1 'sudo docker ps -q | xargs -r sudo docker stop; sudo docker ps -q | xargs -r sudo docker rm -f; sudo yes | docker system prune -fa; sudo docker ps; sudo docker images'
echo $RUNNER_PASS | sudo -S sh -c 'podman ps -q | xargs -r sudo podman stop; sudo podman ps -q | xargs -r sudo podman rm -f; sudo yes | podman system prune -fa; podman ps; podman images'
