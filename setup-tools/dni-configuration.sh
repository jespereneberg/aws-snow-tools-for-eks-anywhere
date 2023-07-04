# Script to configure DNI interfaces. Instead of the sample configuration script here: https://docs.aws.amazon.com/snowball/latest/developer-guide/network-config-ec2.html#snowcone-setup-dni
# which uses Interface MAC as input, this script uses interface-name, eg ethX.
#
# script usage"
# -e <interface>   Interface (ethX, enpX) of the DNI to configure."
# -i <ip>          IP to configure on the Interface. Default: DHCP."      
# -p <Prefix>      Prefix to configure on the Interface. Default: DHCP."
# -g <ip>          Default gateway IP. Default: DHCP."
# -d <true/false>  If interface should be used as default gateway. Default: false."
#
########################################################################################
#!/bin/bash
while getopts 'e:i:p:g:d:' OPTION; do
  case "$OPTION" in
    e)
      DNI_ETH="$OPTARG"
      ;;
    i)
      IP="$OPTARG"
      ;;
    p)
      PREFIX="$OPTARG"
      ;;
    g)
      DEF_GATEWAY_IP="$OPTARG"
      ;;
    d) 
      DEF_GATEWAY_BOOLEAN="$OPTARG"
      DEF_GATEWAY_BOOLEAN=$(echo $DEF_GATEWAY_BOOLEAN | tr '[:upper:]' '[:lower:]')
      ;;
    *)
      echo "script usage: $(basename $0) [-e <interface> ] [-i <IP>] [-p <Prefix>] [-g <IP>] [-d <boolean>]"
      echo "-e <interface>   Interface (ethX, enpX) of the DNI to configure."
      echo "-i <ip>          IP to configure on the Interface. Default: DHCP."      
      echo "-p <Prefix>      Prefix to configure on the Interface. Default: DHCP."
      echo "-g <ip>          Default gateway IP. Default: DHCP."
      echo "-d <true/false>  If interface should be used as default gateway. Default: false."
      exit 1
      ;;
  esac
done

if [ -z "$DNI_ETH" ]; then
  echo "-e needs to be set."
  exit 1
fi

if [ -z "$IP" ] && [ -z "$PREFIX" ]; then
  STATIC=false
elif [ -z "$IP" ] || [ -z "$PREFIX" ]; then
  echo "-i and -p need to be configured together."
  exit 1
fi

while ! ip link show $DNI_ETH;do
    echo "$DNI_ETH does not exist yet. Waiting for it to become avaiable."
    sleep 1
done

# Configure routing so that packets meant for the VNI always are sent through eth0.
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
PRIVATE_GATEWAY=$(ip route show to match 0/0 dev eth0 | awk '{print $3}')
ROUTE_TABLE=10001
echo "from $PRIVATE_IP table $ROUTE_TABLE" > /etc/sysconfig/network-scripts/rule-eth0
echo "default via $PRIVATE_GATEWAY dev eth0 table $ROUTE_TABLE" > /etc/sysconfig/network-scripts/route-eth0
echo "169.254.169.254 dev eth0" >> /etc/sysconfig/network-scripts/route-eth0

# Query the persistent DNI name, assigned by udev via ec2net helper.
DNI_MAC=$(ip link show $DNI_ETH | awk '/link\/ether/ { print $2 }')

if $STATIC; then
# Configure DNI to use static network settings.
cat << EOF > /etc/sysconfig/network-scripts/ifcfg-$DNI_ETH
DEVICE="$DNI_ETH"
NAME="$DNI_ETH"
HWADDR=$DNI_MAC
ONBOOT=yes
NOZEROCONF=yes
BOOTPROTO=none
NM_CONTROLLED=no
IPADDR=$IP
PREFIX=$PREFIX
TYPE=Ethernet
MAINROUTETABLE=no
PERSISTENT_DHCLIENT=no
EOF
if [ -n "$DEF_GATEWAY_IP" ]; then
  echo "GATEWAY=$DEF_GATEWAY_IP" >> /etc/sysconfig/network-scripts/ifcfg-$DNI_ETH
fi
if [ "$DEF_GATEWAY_BOOLEAN" ]; then
  echo "DEFROUTE=yes" >> /etc/sysconfig/network-scripts/ifcfg-$DNI_ETH
fi
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
ifdown $DNI_ETH && ifup $DNI_ETH
