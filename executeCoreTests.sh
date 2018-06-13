#!/bin/bash

# parameters
coreVer=$1
adminVer=$2
testMode=$3
browser=$4
suite=$5
testPlanId=$6
stackName=$7
branchName=$8

# grab awscli
curl -O https://bootstrap.pypa.io/get-pip.py
python3 get-pip.py
pip install urllib3
pip install awscli --upgrade

# setup ssh for git by looping through ec2 parameter stores
for paramStore in qa-auto-neolocal qa-auto-admin qa-auto-bfadmin qa-auto-core qa-auto-onboarding qa-auto-reporting; do
	/usr/local/bin/aws ssm get-parameters \
	--with-decryption \
	--names $paramStore \
	--region us-west-1 \
	--query Parameters[*].{Value:Value} \
	--output text > /root/$paramStore
done

chmod 600 /root/qa-auto*

# populate ssh config file
cat << EOF > /root/.ssh/config
Host neo-local
HostName github.com
IdentityFile /root/qa-auto-neolocal

Host admin
HostName github.com
IdentityFile /root/qa-auto-admin

Host core
HostName github.com
IdentityFile /root/qa-auto-core

Host bfadmin
HostName github.com
IdentityFile /root/qa-auto-bfadmin

Host onboarding
HostName github.com
IdentityFile /root/qa-auto-onboarding

Host reporting
HostName github.com
IdentityFile /root/qa-auto-reporting
EOF

# clone neo repos
apt-get install git docker.io daemon -y
ssh-keyscan -H github.com >> ~/.ssh/known_hosts

git clone git@neo-local:IDEXX/neo-local.git /vagrant
git clone git@admin:IDEXX/saas-admin.git /vagrant/dev/admin
git clone git@bfadmin:IDEXX/beefree-admin.git /vagrant/dev/bfadmin
git clone git@core:IDEXX/beefree-src.git /vagrant/dev/core
git clone git@onboarding:IDEXX/saas-onboarding.git /vagrant/dev/onboarding
git clone git@reporting:IDEXX/saas-reporting-server.git /vagrant/dev/reporting

echo $branchName
cd /vagrant/dev/core && git checkout $branchName



# get ec2 ip
ip=$(ec2metadata | awk '/local-ipv4/ {print $2}')

# populate hosts file
cat << EOF >> /etc/hosts
$ip       onboarding.idexxneolocal.com
$ip       admin.idexxneolocal.com
$ip       bfadmin.idexxneolocal.com
$ip       core.idexxneolocal.com
$ip       reporting.idexxneolocal.com
$ip       manage.idexxneolocal.com
$ip       db.idexxneolocal.com
$ip       memcache.idexxneolocal.com
EOF

# run provisioning scripts
chmod +x /vagrant/ops/vagrant-scripts/provision/*
/vagrant/ops/vagrant-scripts/provision/general_provision.sh
apt-get install python-pip -y
/vagrant/ops/vagrant-scripts/provision/setup_awscli.sh
/vagrant/ops/vagrant-scripts/provision/setup_docker.sh
/vagrant/ops/vagrant-scripts/provision/setup_memcached.sh

# setup mysql
debconf-set-selections <<< 'mysql-server-5.6 mysql-server/root_password password root'
debconf-set-selections <<< 'mysql-server-5.6 mysql-server/root_password_again password root'
apt-get -yq install mysql-server-5.6
mysql -uroot -proot -e "CREATE USER 'root'@'%' IDENTIFIED BY 'root';"
mysql -uroot -proot -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;"
mysql -uroot -proot -e "CREATE USER 'admin'@'%' IDENTIFIED BY 'admin';"
mysql -uroot -proot -e "GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%' WITH GRANT OPTION;"
mysql -uroot -proot -e "CREATE DATABASE IF NOT EXISTS onboarding;"

sed -i "s/bind-address.*/bind-address = $ip/" /etc/mysql/my.cnf

service mysql restart

# run seed DB scripts
zcat /vagrant/dev/core/db/vet_authenticate.sql.gz | mysql -uroot -proot
zcat /vagrant/dev/core/db/tstserv_testdata.sql.gz | mysql -uroot -proot

# setup nginx
/vagrant/ops/vagrant-scripts/provision/setup_nginx.sh

ln -s /etc/ssl/idexxneo.crt /usr/share/ca-certificates/idexxneo.crt
echo "idexxneo.crt" >> /etc/ca-certificates.conf
update-ca-certificates
service nginx restart

# cleanup env file
rm -rf /vagrant/dev/core/application/config/.env
rm -rf vagrant/dev/admin/.env
cp /vagrant/dev/core/application/config/.env.example /vagrant/dev/core/application/config/.env
cp /vagrant/dev/admin/.env.example /vagrant/dev/admin/.env

sed -i "s/NEO_API_URL=http:\/\/admin.idexxneolocal.com/NEO_API_URL=https:\/\/admin.idexxneolocal.com/" /vagrant/dev/core/application/config/.env


eval $(aws ecr get-login --no-include-email --region us-east-1)

docker run -d -p 8081:80 -t \
	-e DB_MIGRATION='true' \
	-e NEO_ENV='local' \
	--add-host=db.idexxneolocal.com:$ip \
	--add-host=core.idexxneolocal.com:$ip \
	--add-host=admin.idexxneolocal.com:$ip \
	-v /vagrant/dev/admin/.env:/srv/www/neo/current/.env --net="bridge" \
	--name admin-app 840394902108.dkr.ecr.us-east-1.amazonaws.com/neo-admin-app:$adminVer

docker run -d -p 8083:80 -t \
	-e DB_MIGRATION='true' \
	-e NEO_ENV='local' \
	--add-host=db.idexxneolocal.com:$ip \
	--add-host=admin.idexxneolocal.com:$ip \
	--add-host=core.idexxneolocal.com:$ip \
	--add-host=memcache.idexxneolocal.com:$ip \
	-v /vagrant/dev/core/application/config/.env:/srv/www/neo/current/application/config/.env --net="bridge" \
	--name core-app 840394902108.dkr.ecr.us-east-1.amazonaws.com/neo-core-app:$coreVer

# get sauce connect and setup tunnel
curl -s https://saucelabs.com/downloads/sc-4.4.12-linux.tar.gz | tar zxv
chmod 755 sc-4.4.12-linux
chmod 755 sc-4.4.12-linux/bin
tunnelName=coreAuto-$(date +"%T")
ulimit -n 8192 && daemon -- /root/sc-4.4.12-linux/bin/sc -v -u idexx_saas_pims -k 85a0270e-7a4a-4c61-991d-e8cf47519c13 -i $tunnelName

# add saucelabs tunnel identifier to env file
echo SAUCE_TUNNEL_ID=$tunnelName >> /vagrant/dev/core/application/config/.env.example
#echo SAUCE_TUNNEL_ID=$tunnelName >> /vagrant/dev/core/tests/acceptance/config/.env.example
sed -i -e "s/SAUCE_TUNNEL_ID=/SAUCE_TUNNEL_ID=$tunnelName/" /vagrant/dev/core/tests/acceptance/config/.env.example

cat /vagrant/dev/core/tests/acceptance/config/.env.example

# run test
docker run -d --name core-test --network=host \
    --log-driver syslog --log-opt syslog-address=tcp+tls://logs.papertrailapp.com:37569 --log-opt syslog-format=rfc5424 --log-opt tag=core-test-automation \
	-e NEO_ENV=local \
	-e "TEST_MODE=$testMode" \
	-e "BROWSER=$browser" \
	-e "SUITE=$suite" \
	-e "TEST_PLAN_ID=$testPlanId" \
	--add-host=db.idexxneolocal.com:$ip \
	--add-host=admin.idexxneolocal.com:$ip \
	--add-host=core.idexxneolocal.com:$ip \
	--add-host=memcache.idexxneolocal.com:$ip \
	-v /vagrant/dev/core/application/config/.env:/srv/www/neo/current/application/config/.env \
	-v /vagrant/dev/core/tests/acceptance/config/.env.example:/srv/www/neo/current/tests/acceptance/config/.env \
	840394902108.dkr.ecr.us-east-1.amazonaws.com/neo-core-smoketest:$coreVer

# check if smoketest container is still running
containerStat=$(docker ps -a --filter name=core-test --filter=status=running |grep -v CONTAINER)

while [ ! -z "$containerStat" ]; do
    containerStat=$(docker ps -a --filter name=core-test --filter=status=running |grep -v CONTAINER)
    sleep 5
done

# delete stack when finished
aws cloudformation delete-stack --stack-name $stackName --region us-west-1

# end
