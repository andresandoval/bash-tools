#!/bin/bash
set -e
cd /home/serverpre/Git/sinexar

echo "***********************";
echo "***Deploying sinexar DEV mode***"
echo "***********************";
echo ""
echo "*** Getting latest changes"
echo ""
git fetch
git checkout dev
git pull
echo ""
echo "*** Building executable"
sh gradlew clean
sh gradlew build -PbuildForProduction -PbuildProfile=dev
echo ""
echo "*** Configuring service"
sudo chattr -i /var/sinexar-dev/sinexar-dev.jar
sudo rm -rf /var/sinexar-dev/sinexar-dev.jar

sudo find ./build/libs -maxdepth 1 -type f -regextype posix-basic -regex '^.*\/sinexar\-\([0-9]\{1,\}\.\)\{2\}[0-9]\{1,\}\-SNAPSHOT\.jar$' -print0 -quit | xargs -0 -I{} sudo mv {} /var/sinexar-dev/sinexar-dev.jar

sudo chown sinexar-dev:sinexar-dev /var/sinexar-dev/sinexar-dev.jar
sudo chmod 500 /var/sinexar-dev/sinexar-dev.jar
sudo chattr +i /var/sinexar-dev/sinexar-dev.jar
echo ""
echo "*** Restarting service"
sudo /bin/systemctl stop sinexar-dev.service
sudo /bin/systemctl start sinexar-dev.service
echo ""
echo "*** Monitoring service"
sudo journalctl -u sinexar-dev.service -f
cd -