echo "# EULA accepted on $(date) by docker run -e" > /minecraft/eula.txt
echo "eula=$EULA" >> /minecraft/eula.txt

./start.sh