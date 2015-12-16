#!/usr/bin/env bash

#docker login --username=seanorama --email=seanorama@gmail.com

sudo mkdir -p /etc/sysctl.d
sudo tee /etc/sysctl.d/99-hadoop-ipv6.conf > /dev/null <<-'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sudo sysctl -e -p /etc/sysctl.d/99-hadoop-ipv6.conf

sudo yum update -y
sudo yum install -y docker git python-argparse
sudo service docker start
sudo groupadd docker
sudo gpasswd -a ${USER} docker
sudo su - ${USER}
#docker run hello-world
cd

sudo sed -i -- 's/\(PasswordAuthentication\) no/\1 yes/g' /etc/ssh/sshd_config
sudo service sshd restart
sudo sed -i -e 's/^# \(%wheel\)/\1/' /etc/sudoers
sudo useradd student
sudo usermod -aG wheel student
echo 'student:BadPass#1' | sudo chpasswd
ssh-keygen -q -t rsa -f ~/.ssh/id_rsa -N "" ; cp ~/.ssh/id_rsa.pub ~/.ssh/authorized_keys
sudo mkdir -p ~student/; sudo cp -a ~/.ssh/* ~student/.ssh/; sudo chown -R student:student ~/.ssh

## build docker-ambari 2.2.0
git clone https://github.com/seanorama/docker-ambari
cd docker-ambari; git checkout 2.2.0
docker build -t sequenceiq/ambari ambari-server ; cd

## extend docker-ambari for training
git clone https://github.com/seanorama/masterclass
docker build -t seanorama/ambari masterclass/security-official/containers/ambari

export IMAGE="seanorama/ambari"
export EXPOSE_AMBARI=true
export EXPOSE_DNS=true
export DOCKER_OPTS="-v ~/.ssh:/student/.ssh -v ~student/.ssh:/home/student/.ssh --privileged=true --restart=unless-stopped --cap-add=ALL"
. ./docker-ambari/ambari-functions && amb-start-cluster
docker exec -it amb-server sh -c 'chkconfig ambari-agent on; ambari-agent start'
sleep 20

get-ambari-server-ip
sudo iptables -t nat -A  DOCKER -p tcp --dport 8080 -j DNAT --to-destination $AMBARI_SERVER_IP:8080

sudo sed -i -e "s/nameserver .*/nameserver $(get-consul-ip)/" /etc/resolv.conf
echo "search service.consul node.dc1.consul" | sudo tee -a /etc/resolv.conf

## deploy hdp
get-ambari-server-ip
export ambari_server=${AMBARI_SERVER_IP}
export ambari_services="HDFS MAPREDUCE2 PIG YARN HIVE ZOOKEEPER"
export host_count=skip
git clone https://github.com/seanorama/ambari-bootstrap
cd ambari-bootstrap/deploy
./deploy-recommended-cluster.bash
cd

docker run ${DOCKER_OPTS} -d \
    -h kerberos.node.dc1.consul --name kerberos \
    -e BOOTSTRAP=1 \
    -e BRIDGE_IP=$(get-consul-ip) \
    -e NAMESERVER_IP=$(get-consul-ip) \
    -e REALM=NODE.DC1.CONSUL \
    -e DOMAIN_REALM=node.dc1.consul \
    -v /etc/krb5.conf:/etc/krb5.conf \
    -v /dev/urandom:/dev/random sequenceiq/kerberos

_consul-register-service kerberos \
    $(docker inspect --format="{{.NetworkSettings.IPAddress}}" kerberos)

########################################
## guacamole
docker run --rm glyptodon/guacamole /opt/guacamole/bin/initdb.sh --postgres > initdb.sql
cat << EOF >> initdb.sql
CREATE USER guacamole_user WITH PASSWORD 'some_password';
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO guacamole_user;
GRANT SELECT,USAGE ON ALL SEQUENCES IN SCHEMA public TO guacamole_user;
EOF

PGPASSWORD=mysecretpassword
docker run ${DOCKER_OPTS} --name postgres -h postgres.node.dc1.consul --dns $(get-consul-ip) -e POSTGRES_PASSWORD=${PGPASSWORD} -d postgres
docker exec -it postgres sh -c 'createdb -U postgres guacamole_db'

docker cp initdb.sql postgres:/tmp/initdb.sql
docker exec -it postgres \
    sh -c 'exec psql -h "$POSTGRES_PORT_5432_TCP_ADDR" -p "$POSTGRES_PORT_5432_TCP_PORT" -d guacamole_db -U postgres -f /tmp/initdb.sql'

docker run ${DOCKER_OPTS} --name guacd -h guacd.node.dc1.consul --dns $(get-consul-ip) -d -p 4822:4822 glyptodon/guacd
docker run ${DOCKER_OPTS} --name guacamole -h guacamole.node.dc1.consul --dns $(get-consul-ip) --link guacd:guacd \
    --link postgres:postgres      \
    -e POSTGRES_DATABASE=guacamole_db  \
    -e POSTGRES_USER=guacamole_user    \
    -e POSTGRES_PASSWORD=some_password \
    -d -p 80:8080 glyptodon/guacamole
docker run ${DOCKER_OPTS} --name desktop -h desktop.node.dc1.consul --dns $(get-consul-ip) -d -p 5901:5901 -p 6901:6901 consol/centos-xfce-vnc
docker cp ~/masterclass/security-official/nodes/desktop/hortonworks.jpg desktop:/root/.config/hortonworks.jpg
docker cp ~/masterclass/security-official/nodes/desktop/hortonworks.jpg desktop:/root/.config/bg_sakuli.jpg
docker exec -it desktop sh -c 'xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/image-path -s /root/.config/hortonworks.jpg'
docker exec -it desktop sh -c 'nohup firefox http://amb-server.node.dc1.consul:8080/ &'

_consul-register-service postgres \
    $(docker inspect --format="{{.NetworkSettings.IPAddress}}" postgres)
_consul-register-service guacd \
    $(docker inspect --format="{{.NetworkSettings.IPAddress}}" guacd)
_consul-register-service guacamole \
    $(docker inspect --format="{{.NetworkSettings.IPAddress}}" guacamole)
_consul-register-service desktop \
    $(docker inspect --format="{{.NetworkSettings.IPAddress}}" desktop)

##


exit

kadmin -p admin/admin
addprinc -randkey ambari/amb-server.node.dc1.consul@NODE.DC1.CONSUL
ktadd -norandkey -k ambari.keytab ambari/amb-server.node.dc1.consul@NODE.DC1.CONSUL
ktadd -k bigsql.domain.name.keytab bigsql/domain.name@YOUR_REALM.COM

