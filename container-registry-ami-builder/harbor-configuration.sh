#!/bin/bash

########################################################################################################################
# Script to setup a local Harbor registry on a snowball ec2 instance
#
# Prerequisite:
# Start an ec2 instance with harbor artifacts pre-baked AMI, create and attach a vni,
# then ssh into the instance to run this script
#
# Run the script
# `./harbor-configuration.sh -a AdminPassword123 -d DbPassword123 -p 172.16.1.10 -s 192.168.1.10`
#
########################################################################################################################
VNI_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -sS http://169.254.169.254/latest/meta-data/public-ipv4)
while getopts 'a:d:p:s:' OPTION; do
  case "$OPTION" in
    a)
      ADMIN_PASSWORD="$OPTARG"
      ;;
    d)
      DB_PASSWORD="$OPTARG"
      ;;
    p)
      PRIMARY_IP="$OPTARG"
      ;;
    s)
      SECONDARY_IP="$OPTARG"
      ;;
    *)
      echo "script usage: $(basename $0) [-a <Harbor UI Admin Password>] [-d <Harbor DB Root Password>] [-p <PRIMARY IP>] [-s <SECONDARY IP>]"
      echo "-a <Harbor UI Admin Password> Set the Harbor UI Admin Password"
      echo "-d <Harbor DB root Password>  Set the Harbor DB root Password"      
      echo "-p <Primary IP>               Set the Harbor primary IP. This should be the IP your Kubernetes nodes connect to."
      echo "-s <Secondary IP>             Set the Harbor secondary IP. This could be the IP of your management network or Internet path to be able to pull container images from external sources."
      echo ""
      echo "-p <Primary IP> and -s <Secondary IP> are optional and only needed when configuring a multi-homed instance that listen on two IPs (Primary and secondary)."
      echo "Without setting -p or -s the instance VNI IP ($VNI_IP) will be configured as the Harbor IP and will be the ony IP added to the TLS certificate."
      exit 1
      ;;
  esac
done

shift "$(($OPTIND -1))"

if [ -z "$ADMIN_PASSWORD" ]; then
        read -p "Please set up the Harbor UI Admin Password: " ADMIN_PASSWORD
fi
if [ -z "$DB_PASSWORD" ]; then
        read -p "Please set up the Harbor DB Root Password: " DB_PASSWORD
fi
if [ -z "$PRIMARY_IP" ]; then
  PRIMARY_IP=$VNI_IP
fi
if [ -z "$SECONDARY_IP" ]; then
  SECONDARY_IP=$VNI_IP
fi

cat <<EOF > /tmp/ifcfg-lo:1
DEVICE=lo:1
IPADDR=${PRIMARY_IP}
NETMASK=255.255.255.255
NETWORK=127.0.0.0
BROADCAST=127.255.255.255
ONBOOT=yes
NAME=loopback
EOF

sudo mv /tmp/ifcfg-lo:1 /etc/sysconfig/network-scripts/ifcfg-lo:1

sudo systemctl restart network

### configure https access to harbor

## Generate a Certificate Authority Certificate
# Generate a CA certificate private key
openssl genrsa -out ca.key 4096

# Generate the CA certificate using instance-ip as CN
openssl req -x509 -new -nodes -sha512 -days 3650 \
 -subj "/CN=$PRIMARY_IP" \
 -key ca.key \
 -out ca.crt

## Generate a Server Certificate
# Generate a private key
openssl genrsa -out $PRIMARY_IP.key 4096

# Generate a certificate signing request (CSR)
openssl req -sha512 -new \
    -subj "/CN=$PRIMARY_IP" \
    -key $PRIMARY_IP.key \
    -out $PRIMARY_IP.csr

# Generate an
cat > v3.ext <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = IP:$PRIMARY_IP, IP:$SECONDARY_IP
EOF

# Use the v3.ext file to generate a certificate for your Harbor host
openssl x509 -req -sha512 -days 3650 \
    -extfile v3.ext \
    -CA ca.crt -CAkey ca.key -CAcreateserial \
    -in $PRIMARY_IP.csr \
    -out $PRIMARY_IP.crt

## Provide the Certificates to Harbor
# Copy the server certificate and key into the certificates folder on your Harbor host.
sudo mkdir -p /data/cert
sudo cp $PRIMARY_IP.crt /data/cert/
sudo cp $PRIMARY_IP.key /data/cert/

## Provide the Certificates to Docker
# Convert .crt file to .cert file, for use by Docker
openssl x509 -inform PEM -in $PRIMARY_IP.crt -out $PRIMARY_IP.cert

# Copy the server certificate, key and CA files into the Docker certificates folder on the Harbor host
sudo mkdir -p /etc/docker/certs.d/$PRIMARY_IP
sudo cp $PRIMARY_IP.cert /etc/docker/certs.d/$PRIMARY_IP/
sudo cp $PRIMARY_IP.key /etc/docker/certs.d/$PRIMARY_IP/
sudo cp ca.crt /etc/docker/certs.d/$PRIMARY_IP/

# Restart docker
sudo systemctl restart docker

### Configure the Harbor YML File
sed "s/hostname: reg.mydomain.com/hostname: $PRIMARY_IP/" /home/ec2-user/harbor/harbor.yml.tmpl | \
sed "s/\/your\/certificate\/path/\/data\/cert\/$PRIMARY_IP.crt/" | \
sed "s/\/your\/private\/key\/path/\/data\/cert\/$PRIMARY_IP.key/" | \
sed "s/root123/$DB_PASSWORD/" | \
sed "s/Harbor12345/$ADMIN_PASSWORD/" > /home/ec2-user/harbor/harbor.yml

## Run the harbor install script
sudo /home/ec2-user/harbor/prepare
sudo /home/ec2-user/harbor/install.sh

## Waiting for harbor to start
while ! curl -sS $PRIMARY_IP --connect-timeout 1; do 
  echo "Harbor not yet started. Waiting for it to become avaiable."
  sleep 1
done

## Create needed Projects in Harbor
curl -u admin:$ADMIN_PASSWORD -k -X 'POST' https://$PRIMARY_IP/api/v2.0/projects -H 'Content-Type: application/json' -d '{ "project_name": "eks-anywhere", "public": true }'
curl -u admin:$ADMIN_PASSWORD -k -X 'POST' https://$PRIMARY_IP/api/v2.0/projects -H 'Content-Type: application/json' -d '{ "project_name": "eks-distro", "public": true }'
curl -u admin:$ADMIN_PASSWORD -k -X 'POST' https://$PRIMARY_IP/api/v2.0/projects -H 'Content-Type: application/json' -d '{ "project_name": "isovalent", "public": true }'
curl -u admin:$ADMIN_PASSWORD -k -X 'POST' https://$PRIMARY_IP/api/v2.0/projects -H 'Content-Type: application/json' -d '{ "project_name": "bottlerocket", "public": true }'
curl -u admin:$ADMIN_PASSWORD -k -X 'POST' https://$PRIMARY_IP/api/v2.0/projects -H 'Content-Type: application/json' -d '{ "project_name": "cilium-chart", "public": true }'
curl -u admin:$ADMIN_PASSWORD -k -X 'PUT' https://$PRIMARY_IP/api/v2.0/projects/library -H 'Content-Type: application/json' -d '{ "public": true }'

## login to harbor from local docker
sudo docker login $PRIMARY_IP --username admin --password $ADMIN_PASSWORD

## Load images from images file from customer
for file in /home/ec2-user/images/*
    do
        sudo docker load --input "$file"
    done

# Iterate over images in the docker excluding habor images
IMAGES=$(sudo docker images --format "{{.Repository}}:{{.Tag}}" | grep -v goharbor)
for image in $IMAGES; do
  # Tag the image with a new name
    docker tag $image $PRIMARY_IP/library/$image

    # Push the image to a registry
    sudo docker push $PRIMARY_IP/library/$image
done

echo "All images are uploaded"
