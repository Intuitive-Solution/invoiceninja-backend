#!/bin/bash

# Server Setup Script for Invoice Ninja on Amazon Linux 2023
# This script should be run as root or with sudo privileges

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
fi

# Variables
DB_PASSWORD=${1:-"InvoiceNinja2024!"}
APP_KEY=${2:-""}
APP_URL=${3:-""}

log "Starting Invoice Ninja server setup..."

# Update system
log "Updating system packages..."
dnf update -y

# EPEL not needed for Amazon Linux 2023
log "Skipping EPEL installation (not needed for Amazon Linux 2023)..."

# Install basic tools
log "Installing basic tools..."
dnf install -y wget curl git unzip vim nano htop --allowerasing

# Install PHP and required extensions
log "Installing PHP and extensions..."
dnf install -y php php-cli php-fpm php-mysqlnd php-xml php-gd \
    php-mbstring php-curl php-zip php-intl php-bcmath \
    php-opcache php-json php-dom \
    php-fileinfo php-openssl php-pdo php-ctype

# Configure PHP
log "Configuring PHP..."
PHP_INI="/etc/php.ini"
sed -i 's/upload_max_filesize = 2M/upload_max_filesize = 100M/' $PHP_INI
sed -i 's/post_max_size = 8M/post_max_size = 100M/' $PHP_INI
sed -i 's/max_execution_time = 30/max_execution_time = 300/' $PHP_INI
sed -i 's/memory_limit = 128M/memory_limit = 512M/' $PHP_INI
sed -i 's/;date.timezone =/date.timezone = UTC/' $PHP_INI

# Install Nginx
log "Installing Nginx..."
dnf install -y nginx

# Install mariadb
log "Installing mariadb ..."
dnf install -y mariadb105-server mariadb105

# Start and enable services
log "Starting and enabling services..."
systemctl start nginx
systemctl enable nginx
systemctl start mariadb
systemctl enable mariadb
systemctl start php-fpm
systemctl enable php-fpm

# Configure PHP-FPM
log "Configuring PHP-FPM..."
sed -i 's/user = apache/user = ec2-user/' /etc/php-fpm.d/www.conf
sed -i 's/group = apache/group = ec2-user/' /etc/php-fpm.d/www.conf
sed -i 's/listen.owner = apache/listen.owner = ec2-user/' /etc/php-fpm.d/www.conf
sed -i 's/listen.group = apache/listen.group = ec2-user/' /etc/php-fpm.d/www.conf
systemctl restart php-fpm

# Install Composer
log "Installing Composer..."
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer
chmod +x /usr/local/bin/composer

# Install Node.js and npm
log "Installing Node.js and npm..."
dnf install -y nodejs npm

# Secure MySQL installation
log "Securing MySQL installation..."
mysql_secure_installation_script() {
    # Set root password
    mysqladmin -u root password "${DB_PASSWORD}" 2>/dev/null || true
    
    # Remove anonymous users
    mysql -u root -p"${DB_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
    
    # Remove root access from remote machines
    mysql -u root -p"${DB_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true
    
    # Remove test database
    mysql -u root -p"${DB_PASSWORD}" -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
    mysql -u root -p"${DB_PASSWORD}" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null || true
    
    # Flush privileges
    mysql -u root -p"${DB_PASSWORD}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
}

# Wait for MySQL to be ready
sleep 10
mysql_secure_installation_script

# Create Invoice Ninja database and user
log "Creating Invoice Ninja database and user..."
mysql -u root -p"${DB_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS invoiceninja CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p"${DB_PASSWORD}" -e "CREATE USER IF NOT EXISTS 'invoiceninja'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u root -p"${DB_PASSWORD}" -e "GRANT ALL PRIVILEGES ON invoiceninja.* TO 'invoiceninja'@'localhost';"
mysql -u root -p"${DB_PASSWORD}" -e "FLUSH PRIVILEGES;"

# Configure Nginx for Invoice Ninja
log "Configuring Nginx..."
cat > /etc/nginx/conf.d/invoiceninja.conf << 'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/html/public;
    index index.php index.html index.htm;

    client_max_body_size 100M;
    client_body_timeout 300s;
    client_header_timeout 300s;
    send_timeout 300s;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 300;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~ /\. {
        deny all;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
}
EOF

# Remove default Nginx configuration
rm -f /etc/nginx/conf.d/default.conf

# Create application directory
log "Creating application directory..."
mkdir -p /var/www/html
chown -R ec2-user:ec2-user /var/www/html
chmod -R 755 /var/www/html

# Configure firewall (if firewalld is installed)
if systemctl is-active --quiet firewalld; then
    log "Configuring firewall..."
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
fi

# Install SSL certificate tools (Let's Encrypt)
log "Installing SSL certificate tools..."
dnf install -y certbot python3-certbot-nginx

# Configure log rotation
log "Configuring log rotation..."
cat > /etc/logrotate.d/invoiceninja << 'EOF'
/var/www/html/storage/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 644 ec2-user ec2-user
}
EOF

# Configure MySQL for better performance
log "Configuring MySQL for better performance..."
mkdir -p /etc/my.cnf.d
cat >> /etc/my.cnf.d/invoiceninja.cnf << 'EOF'
[mariadb]
innodb_buffer_pool_size = 128M
innodb_log_file_size = 64M
max_connections = 100
tmp_table_size = 32M
max_heap_table_size = 32M
EOF

# Restart services
log "Restarting services..."
systemctl restart nginx
systemctl restart php-fpm
systemctl restart mariadb

# Create deployment script
log "Creating deployment script..."
cat > /usr/local/bin/deploy-invoiceninja.sh << 'EOF'
#!/bin/bash

# Invoice Ninja Deployment Script
set -e

log() {
    echo -e "\033[0;32m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

error() {
    echo -e "\033[0;31m[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1\033[0m"
    exit 1
}

# Variables
REPO_URL="https://github.com/invoiceninja/invoiceninja.git"
APP_DIR="/var/www/html"
BACKUP_DIR="/home/ec2-user/backups/invoiceninja"
BRANCH=${1:-"master"}

# Create backup directory
sudo mkdir -p $BACKUP_DIR
sudo chown ec2-user:ec2-user $BACKUP_DIR

# Backup current installation if exists
if [ -d "$APP_DIR/.git" ]; then
    log "Creating backup of current installation..."
    tar -czf "$BACKUP_DIR/invoiceninja-backup-$(date +%Y%m%d-%H%M%S).tar.gz" -C /var/www html
fi

# Clone or update repository
if [ ! -d "$APP_DIR/.git" ]; then
    log "Cloning Invoice Ninja repository..."
    git clone $REPO_URL $APP_DIR
    cd $APP_DIR
    git checkout $BRANCH
else
    log "Updating Invoice Ninja repository..."
    cd $APP_DIR
    git fetch origin
    git checkout $BRANCH
    git pull origin $BRANCH
fi

# Install dependencies
log "Installing Composer dependencies..."
composer install --no-dev --optimize-autoloader

# Set permissions
log "Setting permissions..."
chown -R ec2-user:ec2-user $APP_DIR
chmod -R 755 $APP_DIR
chmod -R 775 $APP_DIR/storage
chmod -R 775 $APP_DIR/bootstrap/cache

# Run migrations
log "Running database migrations..."
php artisan migrate --force

# Clear caches
log "Clearing caches..."
php artisan config:clear
php artisan route:clear
php artisan view:clear
php artisan cache:clear

# Optimize application
log "Optimizing application..."
php artisan config:cache
php artisan route:cache
php artisan view:cache

log "Deployment completed successfully!"
EOF

chmod +x /usr/local/bin/deploy-invoiceninja.sh

# Create system monitoring script
log "Creating system monitoring script..."
cat > /usr/local/bin/monitor-invoiceninja.sh << 'EOF'
#!/bin/bash

# System monitoring script for Invoice Ninja
log() {
    echo -e "\033[0;32m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

log "=== Invoice Ninja System Status ==="
log "System Load: $(uptime)"
log "Memory Usage: $(free -h | grep Mem)"
log "Disk Usage: $(df -h / | tail -1)"
log "Nginx Status: $(systemctl is-active nginx)"
log "PHP-FPM Status: $(systemctl is-active php-fpm)"
log "MySQL Status: $(systemctl is-active mariadb)"

# Check application status
if [ -f "/var/www/html/artisan" ]; then
    log "Application Status: OK"
else
    log "Application Status: NOT DEPLOYED"
fi

# Check database connection
if mysql -u invoiceninja -p"$DB_PASSWORD" -e "USE invoiceninja; SELECT 1;" >/dev/null 2>&1; then
    log "Database Connection: OK"
else
    log "Database Connection: FAILED"
fi
EOF

chmod +x /usr/local/bin/monitor-invoiceninja.sh

log "Server setup completed successfully!"
log "Next steps:"
log "1. Run the deployment script: /usr/local/bin/deploy-invoiceninja.sh"
log "2. Configure your .env file with proper settings"
log "3. Generate application key: php artisan key:generate"
log "4. Run initial setup: php artisan migrate --seed"
log "5. Monitor system: /usr/local/bin/monitor-invoiceninja.sh" 