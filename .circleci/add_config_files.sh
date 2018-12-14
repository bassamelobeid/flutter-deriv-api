cat > /etc/rmg/redis-feed.yml <<EOL
master-write:
  host: 127.0.0.1
  port: 6359
  password:
master-read:
  host: 127.0.0.1
  port: 6359
  password:
write:
  host: 127.0.0.1
  port: 6359
  password:
read:
  host: 127.0.0.1
  port: 6359
  password:
EOL
