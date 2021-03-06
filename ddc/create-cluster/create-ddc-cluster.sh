#!/bin/bash
set -e

CONFIG_DIR="/config"
CONFIG_FILE="$CONFIG_DIR/config.json"
CERT_PATH="/certs"
MASTER_NAME="manager1"
NODE_CREATE_RETRY="3"
LOG_DIR="$CONFIG_DIR/logs"
SSH_CERT_PATH="$CERT_PATH/.ssh"

# Clear and create log dir
[ -d $LOG_DIR ] && rm -fr $LOG_DIR
mkdir -p $LOG_DIR

validate_config()
{
   set +e
   if [ -z ${DOCKER_HOST+x} ]; then
      echo "Environment variable DOCKER_HOST needs to be set to a valid VCH"
      exit 1
   fi 

   if [ ! -f "$CERT_PATH/key.pem" ]; then
      echo "Certificate path needs to be mounted as a volume at $CERT_PATH"
      exit 1
   fi

   if [ ! -f $CONFIG_FILE ]; then
      echo "JSON config file must be at path /config/config.json by mounting /config as a volume"
      exit 1
   fi
   
   docker info > "$LOG_DIR/docker-info-test" 2>&1
   if [ ! $? -eq 0 ]; then
      echo "Could not connect to DOCKER_HOST, please check that it is correctly configured"
      cat "$LOG_DIR/docker-info-test"
      exit 1
   fi
}

export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH=$CERT_PATH

validate_config

NODE_NETWORK="$(jq -r ".swarm.node.network" $CONFIG_FILE)"
NODE_IMAGE="$(jq -r ".image.node.path" $CONFIG_FILE)"
MASTER_IMAGE="$(jq -r ".image.master.path" $CONFIG_FILE)"
SWARM_ADMIN="$(jq -r ".ucp.admin.name" $CONFIG_FILE)"
SWARM_ADMIN_PWD="$(jq -r ".ucp.admin.password" $CONFIG_FILE)"
SWARM_NODE_MEM="$(jq -r ".swarm.node.mem" $CONFIG_FILE)"
SWARM_NODE_VCPU="$(jq -r ".swarm.node.cpus" $CONFIG_FILE)"
SWARM_NODE_IMAGE_CACHE="$(jq -r ".swarm.node.image_cache" $CONFIG_FILE)"
MANAGER_COUNT="$(jq -r ".swarm.manager_count" $CONFIG_FILE)"
WORKER_COUNT="$(jq -r ".swarm.worker_count" $CONFIG_FILE)"
NESTED_DOCKER_OPTS="$(jq -r ".swarm.docker_opts" $CONFIG_FILE)"
MASTER_DOCKER_OPTS="$(jq -r ".image.master.docker_opts" $CONFIG_FILE)"
NODE_DOCKER_OPTS="$(jq -r ".image.node.docker_opts" $CONFIG_FILE)"
UCP_VERSION="$(jq -r ".ucp.version" $CONFIG_FILE)"

# Params:
#   volume name
#   node name
#   image namei
#   docker options
create_node()
{
   echo "Creating node $2..."
   docker volume create --name=$1 --opt Capacity="$SWARM_NODE_IMAGE_CACHE"
   local n=0
   until [ $n -ge $NODE_CREATE_RETRY ]
   do
      docker run $4 -e DOCKER_OPTS=$NESTED_DOCKER_OPTS -d --name=$2 -v $1:/var/lib/docker -m "$SWARM_NODE_MEM" --cpuset-cpus $SWARM_NODE_VCPU --net=$NODE_NETWORK $3 && break
      n=$[$n+1]
      sleep 1
      echo "Node did not come up correclty. Deleting and retrying..."
      docker rm $2
   done
}

join_swarm_nodes()
{
   echo "Joining swarm nodes..."
   for ((i=2; i<=$MANAGER_COUNT; i++))
   do
      docker exec -d "manager"$i"" /usr/bin/docker swarm join --token $MTOKEN $MANAGER1_IP:2377
      sleep 2
   done

   for ((i=1; i<=$WORKER_COUNT; i++))
   do
      docker exec -d "worker"$i"" /usr/bin/docker swarm join --token $WTOKEN $MANAGER1_IP:2377
      sleep 2
   done
}

add_udev()
{
   echo "Adding udev..."
   for ((i=1; i<=$MANAGER_COUNT; i++))
   do
      docker exec -d "manager"$i"" /lib/systemd/systemd-udevd --daemon
   done

   for ((i=1; i<=$WORKER_COUNT; i++))
   do
      docker exec -d "worker"$i"" /lib/systemd/systemd-udevd --daemon
   done
}

add_volume_driver()
{
   echo "Adding volume driver..."
   for ((i=1; i<=$MANAGER_COUNT; i++))
   do
      docker exec -d "manager"$i"" /usr/bin/docker plugin install --grant-all-permissions --alias vsphere vmware/docker-volume-vsphere:0.13
   done

   for ((i=1; i<=$WORKER_COUNT; i++))
   do
      docker exec -d "worker"$i"" /usr/bin/docker plugin install --grant-all-permissions --alias vsphere vmware/docker-volume-vsphere:0.13
   done
}

create_manager()
{
   # Make sure that this completes, even if there's an error, otherwise the outer script will hang waiting for /tmp/ddc_up
   set +e
   create_node "m1-vol" "$MASTER_NAME" "$MASTER_IMAGE" "$MASTER_DOCKER_OPTS"

   if [ ! -f "$SSH_CERT_PATH/id_rsa" ]; then
      echo "Generating new SSH keys for root user into $SSH_CERT_PATH"
      mkdir -p $SSH_CERT_PATH
      ssh-keygen -b 2048 -t rsa -f "$SSH_CERT_PATH/id_rsa" -q -N "" > /dev/null 2>&1
   fi
   echo "Copying root SSH key to $MASTER_NAME"
   docker exec -d $MASTER_NAME /usr/bin/adduserkey root "$(cat $SSH_CERT_PATH/id_rsa.pub)"

   # Wait for the user and key to be added before trying SSH
   sleep 5

   MANAGER1_IP=$(docker inspect --format "{{ .NetworkSettings.Networks.$NODE_NETWORK.IPAddress }}" manager1)
   echo "Installing UCP $UCP_VERSION to $MANAGER1_IP"
   ssh-keyscan $MANAGER1_IP >> "$SSH_CERT_PATH/known_hosts"
   ssh -i "$SSH_CERT_PATH/id_rsa" -o "UserKnownHostsFile=$SSH_CERT_PATH/known_hosts" $MANAGER1_IP docker run --rm --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp:$UCP_VERSION install --host-address $MANAGER1_IP --admin-username $SWARM_ADMIN --admin-password $SWARM_ADMIN_PWD > $LOG_DIR/install_output 2>&1
   echo "Done installing UCP"
   touch /tmp/ddc_up
}

echo "Pulling node images..."

# Pull the image for the master first and get that going
docker pull $MASTER_IMAGE > $LOG_DIR/pull-master-output 2>&1

# Create the manager in parallel to the other nodes
create_manager &

# Pull the image for the non-master nodes
docker pull $NODE_IMAGE > $LOG_DIR/pull-node-output 2>&1

for ((i=2; i<=$MANAGER_COUNT; i++))
do
   create_node "m"$i"-vol" "manager"$i"" "$NODE_IMAGE" "$NODE_DOCKER_OPTS"
done

for ((i=1; i<=$WORKER_COUNT; i++))
do
   create_node "w"$i"-vol" "worker"$i"" "$NODE_IMAGE" "$NODE_DOCKER_OPTS"
done

# Wait for master creation to complete
echo "Waiting for UCP to come up on master..."
while [ ! -f /tmp/ddc_up ] ;
do
   sleep 2
done

tail -n 11 $LOG_DIR/install_output

MANAGER1_IP=$(docker inspect --format "{{ .NetworkSettings.Networks.$NODE_NETWORK.IPAddress }}" manager1)
MTOKEN=$(ssh -i "$SSH_CERT_PATH/id_rsa" -o "UserKnownHostsFile=$SSH_CERT_PATH/known_hosts" $MANAGER1_IP docker swarm join-token -q manager)
WTOKEN=$(ssh -i "$SSH_CERT_PATH/id_rsa" -o "UserKnownHostsFile=$SSH_CERT_PATH/known_hosts" $MANAGER1_IP docker swarm join-token -q worker)

join_swarm_nodes

add_volume_driver

add_udev

echo "Log into your new DDC cluster with: > ssh -i <certs-vol>/.ssh/id_rsa <master-ip>"
