#!/bin/bash

# Invoice Ninja Application Deployment Script
# This script deploys the Invoice Ninja Laravel application

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
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

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Configuration
REPO_URL="https://github.com/Intuitive-Solution/invoiceninja-backend"
APP_DIR="/var/www/html"
BACKUP_DIR="/home/ec2-user/backups/invoiceninja"
BRANCH=${1:-"v5-stable"}
DB_PASSWORD=${2:-""}
APP_KEY=${3:-""}
APP_URL=${4:-""}

# Validate parameters
if [ -z "$DB_PASSWORD" ]; then
    error "Database password is required as second parameter"
fi

if [ -z "$APP_KEY" ]; then
    warn "APP_KEY not provided, will generate new one"
fi

if [ -z "$APP_URL" ]; then
    warn "APP_URL not provided, using default"
fi

log "Starting Invoice Ninja deployment..."
log "Branch: $BRANCH"
log "App Directory: $APP_DIR"

# Create necessary directories
mkdir -p $BACKUP_DIR
mkdir -p $APP_DIR

# Backup current installation if exists
if [ -d "$APP_DIR/.git" ]; then
    log "Creating backup of current installation..."
    BACKUP_FILE="$BACKUP_DIR/invoiceninja-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$BACKUP_FILE" -C /var/www html 2>/dev/null || warn "Backup creation failed"
    log "Backup created: $BACKUP_FILE"
fi

# Clone or update repository
if [ ! -d "$APP_DIR/.git" ]; then
    log "Cloning Invoice Ninja repository..."
    if [ -d "$APP_DIR" ] && [ "$(ls -A $APP_DIR)" ]; then
        warn "Directory not empty, moving existing files to backup"
        mv "$APP_DIR" "$BACKUP_DIR/old-html-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$APP_DIR"
    fi
    
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

# Copy environment file FIRST
log "Setting up environment configuration..."
if [ ! -f "$APP_DIR/.env" ]; then
    if [ -f "$APP_DIR/.env.example" ]; then
        cp "$APP_DIR/.env.example" "$APP_DIR/.env"
        log "Created .env file from .env.example"
    else
        error ".env.example file not found"
    fi
fi

# Create storage directories BEFORE composer install
log "Creating storage directories..."
mkdir -p $APP_DIR/storage/app/public
mkdir -p $APP_DIR/storage/framework/cache
mkdir -p $APP_DIR/storage/framework/sessions
mkdir -p $APP_DIR/storage/framework/views
mkdir -p $APP_DIR/storage/logs

# Set storage permissions
chown -R ec2-user:ec2-user $APP_DIR/storage
chmod -R 775 $APP_DIR/storage

# Install Composer dependencies AFTER storage setup
log "Installing Composer dependencies..."
composer install --no-dev --optimize-autoloader --no-interaction

# Configure environment variables
log "Configuring environment variables..."
sed -i "s/APP_ENV=.*/APP_ENV=production/" "$APP_DIR/.env"
sed -i "s/APP_DEBUG=.*/APP_DEBUG=false/" "$APP_DIR/.env"
sed -i "s/DB_CONNECTION=.*/DB_CONNECTION=mysql/" "$APP_DIR/.env"
sed -i "s/DB_HOST=.*/DB_HOST=127.0.0.1/" "$APP_DIR/.env"
sed -i "s/DB_PORT=.*/DB_PORT=3306/" "$APP_DIR/.env"
sed -i "s/DB_DATABASE=.*/DB_DATABASE=invoiceninja/" "$APP_DIR/.env"
sed -i "s/DB_USERNAME=.*/DB_USERNAME=invoiceninja/" "$APP_DIR/.env"
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$DB_PASSWORD/" "$APP_DIR/.env"

# Set APP_URL if provided
if [ -n "$APP_URL" ]; then
    sed -i "s|APP_URL=.*|APP_URL=$APP_URL|" "$APP_DIR/.env"
fi

# Generate application key if not provided
if [ -z "$APP_KEY" ]; then
    log "Generating application key..."
    php artisan key:generate --force
else
    log "Setting provided application key..."
    sed -i "s/APP_KEY=.*/APP_KEY=$APP_KEY/" "$APP_DIR/.env"
fi

# Set additional configurations
sed -i "s/CACHE_DRIVER=.*/CACHE_DRIVER=file/" "$APP_DIR/.env"
sed -i "s/SESSION_DRIVER=.*/SESSION_DRIVER=file/" "$APP_DIR/.env"
sed -i "s/QUEUE_CONNECTION=.*/QUEUE_CONNECTION=sync/" "$APP_DIR/.env"

# Set proper permissions
log "Setting file permissions..."
chown -R ec2-user:ec2-user $APP_DIR
chmod -R 755 $APP_DIR
chmod -R 775 $APP_DIR/storage
chmod -R 775 $APP_DIR/bootstrap/cache

# Create symbolic link for storage
log "Creating storage symbolic link..."
if [ ! -L "$APP_DIR/public/storage" ]; then
    php artisan storage:link
fi

# Run database migrations
log "Running database migrations..."
php artisan migrate --force


# Check if this is a fresh installation
TABLES_COUNT=$(mysql -u invoiceninja -p"$DB_PASSWORD" -D invoiceninja -e "SHOW TABLES;" | wc -l)
if [ "$TABLES_COUNT" -le 1 ]; then
    log "Fresh installation detected, running database seeder..."
    php artisan db:seed --force
fi

# Clear all caches
log "Clearing application caches..."
php artisan config:clear
php artisan route:clear
php artisan view:clear
php artisan cache:clear

# Optimize application for production
log "Optimizing application for production..."
php artisan config:cache
php artisan route:cache
php artisan view:cache

# Install and build frontend assets (if package.json exists)
if [ -f "$APP_DIR/package.json" ]; then
    log "Skipping frontend asset build (using pre-built assets)..."
    # npm install --production
    # npm run production
fi

# Set final permissions
log "Setting final permissions..."
chown -R ec2-user:ec2-user $APP_DIR
chmod -R 755 $APP_DIR
chmod -R 775 $APP_DIR/storage
chmod -R 775 $APP_DIR/bootstrap/cache

# Restart services
log "Restarting services..."
sudo systemctl restart nginx
sudo systemctl restart php-fpm

# Verify deployment
log "Verifying deployment..."
if curl -s -o /dev/null -w "%{http_code}" http://localhost | grep -q "200"; then
    log "✓ Web server is responding"
else
    warn "Web server may not be responding correctly"
fi

if php artisan --version >/dev/null 2>&1; then
    log "✓ Laravel application is working"
else
    error "Laravel application is not working correctly"
fi

# Display deployment summary
log "=== DEPLOYMENT SUMMARY ==="
log "Application: Invoice Ninja"
log "Version/Branch: $BRANCH"
log "Directory: $APP_DIR"
log "Database: invoiceninja"
log "Environment: production"
log "Status: DEPLOYED"

# Display post-deployment instructions
info "=== POST-DEPLOYMENT INSTRUCTIONS ==="
info "1. Access your application at: ${APP_URL:-http://your-server-ip}"
info "2. Complete the initial setup wizard"
info "3. Configure your email settings in the admin panel"
info "4. Set up SSL certificate: certbot --nginx -d your-domain.com"
info "5. Configure backup schedule"
info "6. Monitor logs: tail -f $APP_DIR/storage/logs/laravel.log"

log "Invoice Ninja deployment completed successfully!" 