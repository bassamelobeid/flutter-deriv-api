cat > /etc/rmg/chronicle.yml <<EOL
write:
    host: 127.0.0.1
    port: 6380
    password:
read:
    host: 127.0.0.1
    port: 6380
    password:
chronicle:
    ip: 127.0.0.1
    password: picabo
EOL

echo "Done creating chronicle.yml file";

cat /etc/rmg/chronicle.yml
