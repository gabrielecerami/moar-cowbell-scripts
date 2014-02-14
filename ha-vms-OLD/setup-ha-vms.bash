# set these 5 variables
export INITIMAGE=${INITIMAGE:=rhel6rdo}
FOREMAN_NODE=${FOREMAN_NODE:=s14fore1}
VMSET_CHUNK=${VMSET_CHUNK:=s14ha2}
CLUSUBNET=${CLUSUBNET:=192.168.203}
# nic for the CLUSUBNET network that mysql lives on
HANIC=${HANIC:=eth3}

## TODO -- use ../foreman/new-foreman-clients.bash for basic setup

# you may want to hold off on foreman_client.sh registration for later
# (especially if you are going to be in the habit of reverting
#  foreman to a pre-foreman_server.sh state as part of testing),
# in which case set this to true
SKIP_FOREMAN_CLIENT_REGISTRATION=${SKIP_FOREMAN_CLIENT_REGISTRATION:=false}

# This client script must exist (if above var is true) before running
# this script.  For now, cp it from /tmp on your foreman server to
# your chosen location/name, will automate more in future
FOREMAN_CLIENT_SCRIPT=${FOREMAN_CLIENT_SCRIPT:=/mnt/vm-share/rdo/${FOREMAN_NODE}_foreman_client.sh}
SNAPNAME=${SNAPNAME:=new_foreman_cli}

# if false, wait for user input to continue after key steps.
UNATTENDED=${UNATTENDED:=false}

# if you want to run a script that registers and configures your rhel
# repos, this is the place to reference that script.  otherwise, leave
# blank.
SCRIPT_HOOK_REGISTRATION=${SCRIPT_HOOK_REGISTRATION:=''}

# 3 VM's in a mysql HA-cluster.  one VM houses nfs shared-storage.
export VMSET="${VMSET_CHUNK}c1 ${VMSET_CHUNK}c2 ${VMSET_CHUNK}c3 ${VMSET_CHUNK}nfs"

SETUP_COMMANDS="create_images prep_images start_guests"

for setup_command in $SETUP_COMMANDS; do
  echo "running bash -x vftool.bash $setup_command"
  bash -x vftool.bash $setup_command
  if [ "$UNATTENDED" = "false" ]; then
    echo "press enter to continue"
    read
  fi
done

echo "waiting for all hosts to write their /mnt/vm-share/<vmname>.hello files"
# this needs to happen so populate_etc_hosts can succeed
all_hosts_seen=1
while [[ $all_hosts_seen -ne 0 ]] ; do
  all_hosts_seen=0
  for vm in $VMSET; do
    if [[ ! -e /mnt/vm-share/$vm.hello ]]; then
      all_hosts_seen=1
    fi
  done
  sleep 6
  echo -n .
done

bash -x vftool.bash populate_etc_hosts
bash -x vftool.bash populate_default_dns
if [ "$UNATTENDED" = "false" ]; then
  echo 'press enter when the network is back up'
  read
else
  sleep 10
fi

# restarting the network means need to restart the guests (tragically)
bash -x vftool.bash stop_guests
if [ "$UNATTENDED" = "false" ]; then
  echo 'press enter when the guests have stopped'
  read
else
  sleep 10
fi

bash -x vftool.bash first_snaps
bash -x vftool.bash start_guests

ssh_up_cmd="true"
for vm in $VMSET; do
  ssh_up_cmd="$ssh_up_cmd && nc -w1 -z $vm 22"
done
echo "waiting for the sshd on hosts { $VMSET } to come up"
sleep 15
exit_status=1
while [[ $exit_status -ne 0 ]] ; do
  eval $ssh_up_cmd > /dev/null
  exit_status=$?
  sleep 6
  echo -n .
done
if [ "$UNATTENDED" = "false" ]; then
  echo 'verify the hosts are up and reachable by ssh'
  read
fi

if [ "x$SCRIPT_HOOK_REGISTRATION" != "x" ]; then
  for domname in $VMSET; do
    echo "running SCRIPT_HOOK_REGISTRATION"
    sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" \
      $domname "bash ${SCRIPT_HOOK_REGISTRATION}"
  done
fi

# populating dns restarts the network, so need to restart the foreman server
if [ "$SKIP_FOREMAN_CLIENT_REGISTRATION" = "false" ]; then
  VMSET=$FOREMAN_NODE bash -x vftool.bash stop_guests
  VMSET=$FOREMAN_NODE bash -x vftool.bash start_guests

  if [ "$UNATTENDED" = "false" ]; then
    echo 'press a key to continue when the foreman web UI is up'
    read
  else
    test_https="nc -w1 -z $FOREMAN_NODE 443"
    echo "waiting for https on $FOREMAN_NODE to come up"
    sleep 10
    exit_status=1
    while [[ $exit_status -ne 0 ]] ; do
      eval $test_https > /dev/null
      exit_status=$?
      sleep 6
      echo -n .
    done
  fi

  for domname in $VMSET; do
    if [ "$domname" != "${VMSET_CHUNK}nfs" ]; then
      ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" \
        root@$domname "bash ${FOREMAN_CLIENT_SCRIPT}"
    fi
  done
fi

# install packages we'll need on the HA nodes
# (puppet/foreman_client.sh would do this for us later, but we can
# save time by having the packages pre-installed in our snap)
#
# Need upstream repo for pacemaker
sudo mkdir -p /mnt/vm-share/tmp; sudo chmod ogo+rwx /mnt/vm-share/tmp;
cat >/mnt/vm-share/tmp/clusterlabs.repo <<EOF
[clusterlabs]
baseurl=http://clusterlabs.org/64z.repo
enabled=1
gpgcheck=0
priority=1
EOF

for domname in ${VMSET_CHUNK}c1 ${VMSET_CHUNK}c2 ${VMSET_CHUNK}c3; do
  ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" \
    root@$domname "yum-config-manager --enable rhel-ha-for-rhel-6-server-rpms"
  # set clusterlabs repo
  ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" \
    root@$domname "cp /mnt/vm-share/tmp/clusterlabs.repo /etc/yum.repos.d/clusterlabs.repo"
  ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" \
    root@$domname "yum -y install mysql-server MySQL-python ccs pcs cman"
  ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" \
    root@$domname "yum -y install puppet"
done


# install augeas on nfs server (its not subscribed to foreman and
# didn't run the client script that normally installs augeas...
ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" \
 root@${VMSET_CHUNK}nfs "yum -y install augeas"
# ...and install augeas on the clients if they didn't run the foreman
# client script
if [ "$SKIP_FOREMAN_CLIENT_REGISTRATION" != "false" ]; then
  for domname in ${VMSET_CHUNK}c1 ${VMSET_CHUNK}c2 ${VMSET_CHUNK}c3; do
     ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" \
      root@$domname "yum -y install augeas"
  done
fi

# TODO script augeas-is-installed check (pause script if not)

mkdir -p /mnt/vm-share/tmp
for i in 1 2 3 4; do
  DOMNAME=${VMSET_CHUNK}c$i
  IPADDR=$CLUSUBNET.1$i
  if [ "$DOMNAME" = "${VMSET_CHUNK}c4" ]; then
     DOMNAME=${VMSET_CHUNK}nfs
     IPADDR=$CLUSUBNET.200
  fi

  cat > /mnt/vm-share/tmp/$DOMNAME-ifconfig.bash <<EOCAT

augtool <<EOA
set /files/etc/sysconfig/network-scripts/ifcfg-$HANIC/BOOTPROTO none
set /files/etc/sysconfig/network-scripts/ifcfg-$HANIC/IPADDR    $IPADDR
set /files/etc/sysconfig/network-scripts/ifcfg-$HANIC/NETMASK   255.255.255.0
set /files/etc/sysconfig/network-scripts/ifcfg-$HANIC/NM_CONTROLLED no
set /files/etc/sysconfig/network-scripts/ifcfg-$HANIC/ONBOOT    yes
save
EOA

ifup $HANIC
EOCAT
done

for i in 1 2 3 4; do
  DOMNAME=${VMSET_CHUNK}c$i
  IPADDR=$CLUSUBNET.1$i
  if [ "$DOMNAME" = "${VMSET_CHUNK}c4" ]; then
     DOMNAME=${VMSET_CHUNK}nfs
  fi

  sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" $DOMNAME "bash -x /mnt/vm-share/tmp/$DOMNAME-ifconfig.bash"
done

# disable nfs v4 so that mounted /var/lib/mysql works
sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" ${VMSET_CHUNK}nfs "sed -i 's/#RPCNFSDARGS=\"-N 4\"/RPCNFSDARGS=\"-N 4\"/' /etc/sysconfig/nfs"
# install the nfs rpm so we get the mysql system (/etc/passwd) user
sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" ${VMSET_CHUNK}nfs "yum -y install mysql"
# create nfs mount point on the nfs server.  ready to be mounted!
sudo ssh -o "UserKnownHostsFile /dev/null" -o "StrictHostKeyChecking no" ${VMSET_CHUNK}nfs "mkdir -p /mnt/mysql; chmod ugo+rwx /mnt/mysql; echo '/mnt/mysql $CLUSUBNET.0/16(rw,sync,no_root_squash)' >> /etc/exports; /sbin/service nfs restart; /sbin/chkconfig nfs on"

SNAPNAME=$SNAPNAME bash -x vftool.bash reboot_snap_take $VMSET $FOREMAN_NODE