# Mac address of the direct network interface. 
# You got this when you created the direct network interface.
DNI_ETH=$1
IP=
PREFIX=

# Configure routing so that packets meant for the VNI always are sent through eth0.
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
PRIVATE_GATEWAY=$(ip route show to match 0/0 dev eth0 | awk '{print $3}')
ROUTE_TABLE=10001
echo "from $PRIVATE_IP table $ROUTE_TABLE" > /etc/sysconfig/network-scripts/rule-eth0
echo "default via $PRIVATE_GATEWAY dev eth0 table $ROUTE_TABLE" > /etc/sysconfig/network-scripts/route-eth0
echo "169.254.169.254 dev eth0" >> /etc/sysconfig/network-scripts/route-eth0

# Query the persistent DNI name, assigned by udev via ec2net helper.
#   changable in /etc/udev/rules.d/70-persistent-net.rules
DNI_MAC=$(ip link show eth1 | awk '/link\/ether/ { print $2 }')

if [$STATIC = true]; then
# Configure DNI to use static network settings.
cat << EOF > /etc/sysconfig/network-scripts/ifcfg-$DNI_ETH
  DEVICE="$DNI_ETH"
  NAME="$DNI_ETH"
  HWADDR=$DNI_MAC
  ONBOOT=yes
  NOZEROCONF=yes
  IPADDR=$IP #172.16.2.184
  PREFIX=$PREFIX #24
  TYPE=Ethernet
  MAINROUTETABLE=no
  EOF
else
# Configure DNI to use DHCP on boot.
  cat << EOF > /etc/sysconfig/network-scripts/ifcfg-$DNI_ETH
  DEVICE="$DNI_ETH"
  NAME="$DNI_ETH"
  HWADDR=$DNI_MAC
  ONBOOT=yes
  NOZEROCONF=yes
  BOOTPROTO=dhcp
  TYPE=Ethernet
  MAINROUTETABLE=no
  EOF
fi

# Make all changes live.
systemctl restart network
            
