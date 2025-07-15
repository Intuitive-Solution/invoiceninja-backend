#!/bin/bash

# Update system
dnf update -y

# Install basic tools
dnf install -y wget curl git unzip

# Create log file
LOG_FILE="/var/log/user-data.log"
exec > >(tee -a $LOG_FILE) 2>&1

echo "Starting user-data script at $(date)"

# Install PHP 8.2 and extensions
sudo dnf clean all
dnf install -y php8.2 php8.2-cli php8.2-fpm php8.2-mysql php8.2-xml php8.2-gd \
    php8.2-mbstring php8.2-curl php8.2-zip php8.2-intl php8.2-bcmath \
    php8.2-opcache php8.2-json php8.2-redis php8.2-dom php8.2-simplexml

# Install Nginx
sudo dnf clean all
dnf install -y nginx

# Install MySQL 8.0
sudo dnf clean all
dnf install -y mysql-server mysql

# Start and enable services
systemctl start nginx
systemctl enable nginx
systemctl start mariadb
systemctl enable mariadb

# Install Composer
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer
chmod +x /usr/local/bin/composer

# Install Node.js and npm
sudo dnf clean all
dnf install -y nodejs npm

# Create application directory
mkdir -p /var/www/html
chown -R ec2-user:ec2-user /var/www/html

# Configure PHP-FPM
sed -i 's/user = apache/user = ec2-user/' /etc/php-fpm.d/www.conf
sed -i 's/group = apache/group = ec2-user/' /etc/php-fpm.d/www.conf
systemctl start php-fpm
systemctl enable php-fpm

# Set up MySQL
mysql_secure_installation_script() {
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${db_password}';"
    mysql -u root -p${db_password} -e "DELETE FROM mysql.user WHERE User='';"
    mysql -u root -p${db_password} -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    mysql -u root -p${db_password} -e "DROP DATABASE IF EXISTS test;"
    mysql -u root -p${db_password} -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
    mysql -u root -p${db_password} -e "FLUSH PRIVILEGES;"
}

# Wait for MySQL to be ready
sleep 10
mysql_secure_installation_script

# Create Invoice Ninja database
mysql -u root -p${db_password} -e "CREATE DATABASE IF NOT EXISTS invoiceninja CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p${db_password} -e "CREATE USER IF NOT EXISTS 'invoiceninja'@'localhost' IDENTIFIED BY '${db_password}';"
mysql -u root -p${db_password} -e "GRANT ALL PRIVILEGES ON invoiceninja.* TO 'invoiceninja'@'localhost';"
mysql -u root -p${db_password} -e "FLUSH PRIVILEGES;"

# Configure Nginx
cat > /etc/nginx/conf.d/invoiceninja.conf << 'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/html/public;
    index index.php index.html index.htm;

    client_max_body_size 100M;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~ /\. {
        deny all;
    }
}
EOF

# Restart Nginx
systemctl restart nginx

# Set proper permissions
chown -R ec2-user:ec2-user /var/www/html
chmod -R 755 /var/www/html

echo "User-data script completed at $(date)" 