#!/bin/bash
#
# Note there some interactive prompts in this script, so be prepared
# to respond to those.
#
# This should set up one node with a single 1.5GB osd and a few
# monitors.  Make sure to set the following *name* vars with vm's that
# make sense for your setup.
#
# Typical order of operations:
#  * get an HA-all-in-one-controller running on nodes $monnames
#  * run bm-simple-server-prep.bash on the bare-metal host (make sure
#     $nodename in script is correct)
#  * run this script *on the $osdnodename vm*


ice_tarball=/mnt/vm-share/ice12/ICE-1.2-rhel7.tar.gz
icedir=/mnt/vm-share/ice-work2
nodenames="d1a1 d1a2 d1a3 c1a4"
monnames="d1a1 d1a2 d1a3"
osdnodename=c1a4

setup_ice_repo() {
  mkdir -p $icedir
  cd $icedir
  tar -zxvf $ice_tarball -C $icedir
  python $icedir/ice_setup.py
}

setup_ice_repo
cd $icedir

calamari-ctl initialize

ceph-deploy new $nodenames
echo 'osd pool default size = 1' >> ceph.conf
echo 'osd journal size = 1500' >> ceph.conf

ceph-deploy install $nodenames
ceph-deploy mon create-initial
ceph-deploy mon create $monnames
ceph-deploy gatherkeys $nodenames

mkdir /osd0
ceph-deploy osd prepare $osdnodename:/osd0
ceph-deploy osd activate $osdnodename:/osd0
ceph-deploy mds create $osdnodename

ceph osd pool create volumes 128
ceph osd pool create images 128
ceph osd pool create backups 128

ceph-authtool --create-keyring /etc/ceph/ceph.client.images.keyring
chmod +r /etc/ceph/ceph.client.images.keyring
ceph-authtool /etc/ceph/ceph.client.images.keyring -n client.images --gen-key
ceph-authtool -n client.images --cap mon 'allow r' --cap osd 'allow class-read object_prefix rbd_children, allow rwx pool=images' /etc/ceph/ceph.client.images.keyring
ceph auth add client.images -i /etc/ceph/ceph.client.images.keyring

ceph-authtool --create-keyring /etc/ceph/ceph.client.volumes.keyring
chmod +r /etc/ceph/ceph.client.volumes.keyring
ceph-authtool /etc/ceph/ceph.client.volumes.keyring -n client.volumes --gen-key
ceph-authtool -n client.volumes --cap mon 'allow r' --cap osd 'allow class-read object_prefix rbd_children, allow rwx pool=volumes' /etc/ceph/ceph.client.volumes.keyring
ceph auth add client.volumes -i /etc/ceph/ceph.client.volumes.keyring

ceph-authtool --create-keyring /etc/ceph/ceph.client.backups.keyring
chmod +r /etc/ceph/ceph.client.backups.keyring
ceph-authtool /etc/ceph/ceph.client.backups.keyring -n client.backups --gen-key
ceph-authtool -n client.backups --cap mon 'allow r' --cap osd 'allow class-read object_prefix rbd_children, allow rwx pool=backups' /etc/ceph/ceph.client.backups.keyring
ceph auth add client.backups -i /etc/ceph/ceph.client.backups.keyring

echo '[client.images]
keyring = /etc/ceph/ceph.client.images.keyring

[client.volumes]
keyring = /etc/ceph/ceph.client.volumes.keyring

[client.backups]
keyring = /etc/ceph/ceph.client.backups.keyring' >> /etc/ceph/ceph.conf


for h in $monnames; do
 rsync -a -e ssh /etc/ceph/ root@$h:/etc/ceph
done

# not sure if this is necessary or not
VMSET="monnames" vftool.bash run "chmod +r /etc/ceph/ceph.client.admin.keyring"
chmod +r /etc/ceph/ceph.client.admin.keyring

# now kick the tires
#  ceph osd lspools
#  echo test123 > /tmp/test123.txt; rados put test123 /tmp/test123.txt --pool=data
#  rados -p data ls
