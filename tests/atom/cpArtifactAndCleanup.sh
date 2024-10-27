!/bin/bash -x

sudo rm -rf /tmp/artifact/multiIBMCloudServers_m6
sudo cp -r /root/.ssh/atom_backup/artifact/multiIBMCloudServers_m6 /tmp/artifact
sudo ls -lta /tmp/artifact
sudo chmod -R +rx /tmp/artifact
rm -rf /home/cephnvme/busyServer.txt

# sudo rm -rf /home/cephnvme/artifact/*
# sudo ls -lta /home/cephnvme/artifact

# sudo rm -rf /home/cephnvme/artifact.tar.gz
# sudo ls -lta /home/cephnvme/

# sudo cp -r /root/.ssh/atom_backup/artifact/multiIBMCloudServers_m6 /home/cephnvme/artifact
# # sudo chown -R cephnvme:cephnvme /home/cephnvme/artifact
# sudo ls -lta /home/cephnvme/artifact

# # sudo tar -czf /home/cephnvme/artifact.tar.gz -C /home/cephnvme/artifact .
# sudo ls -lta /home/cephnvme/artifact
# sudo ls -lta /home/cephnvme
# # sudo chmod +rx /home/cephnvme/artifact.tar.gz
# sudo rm -rf /home/cephnvme/busyServer.txt
