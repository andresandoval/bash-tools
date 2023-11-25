#!/bin/bash
set -e
cd /home/serverpre/Git/sinexar

echo "***********************";
echo "***Deploying sinexar PROD mode***"
echo "***********************";
echo ""
echo "*** Getting latest changes"
echo ""
git fetch
git checkout master
git pull
echo ""
echo "*** Building executable"
sh gradlew clean
sh gradlew build -PbuildForProduction -PbuildProfile=prod
echo ""
echo "*** Configuring service"
sudo chattr -i /var/sinexar/sinexar.jar
sudo rm -rf /var/sinexar/sinexar.jar

sudo find ./build/libs -maxdepth 1 -type f -regextype posix-basic -regex '^.*\/sinexar\-\([0-9]\{1,\}\.\)\{3\}jar$' -print0 -quit | xargs -0 -I{} sudo mv {} /var/sinexar/sinexar.jar

sudo chown sinexar:sinexar /var/sinexar/sinexar.jar
sudo chmod 500 /var/sinexar/sinexar.jar
sudo chattr +i /var/sinexar/sinexar.jar
echo ""
echo "*** Restarting service"
sudo /bin/systemctl stop sinexar.service
sudo /bin/systemctl start sinexar.service
echo ""
echo "*** Monitoring service"
sudo journalctl -u sinexar.service -f
cd -