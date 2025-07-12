#!/bin/bash

# Invoice Ninja Backup Script
# This script creates backups of the database and application files

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Configuration
BACKUP_DIR="/var/backups/invoiceninja"
APP_DIR="/var/www/html"
DB_NAME="invoiceninja"
DB_USER="invoiceninja"
DB_PASSWORD=${1:-""}
RETENTION_DAYS=30

# Validate parameters
if [ -z "$DB_PASSWORD" ]; then
    error "Database password is required as first parameter"
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Generate timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log "Starting backup process..."

# Database backup
log "Creating database backup..."
DB_BACKUP_FILE="$BACKUP_DIR/database_backup_$TIMESTAMP.sql"
mysqldump -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" > "$DB_BACKUP_FILE"
gzip "$DB_BACKUP_FILE"
log "Database backup created: ${DB_BACKUP_FILE}.gz"

# Application files backup
log "Creating application files backup..."
APP_BACKUP_FILE="$BACKUP_DIR/app_backup_$TIMESTAMP.tar.gz"
tar -czf "$APP_BACKUP_FILE" -C "$(dirname $APP_DIR)" "$(basename $APP_DIR)" \
    --exclude="$APP_DIR/storage/logs/*" \
    --exclude="$APP_DIR/storage/framework/cache/*" \
    --exclude="$APP_DIR/storage/framework/sessions/*" \
    --exclude="$APP_DIR/storage/framework/views/*" \
    --exclude="$APP_DIR/node_modules" \
    --exclude="$APP_DIR/.git"
log "Application backup created: $APP_BACKUP_FILE"

# Configuration backup
log "Creating configuration backup..."
CONFIG_BACKUP_FILE="$BACKUP_DIR/config_backup_$TIMESTAMP.tar.gz"
tar -czf "$CONFIG_BACKUP_FILE" \
    /etc/nginx/conf.d/invoiceninja.conf \
    /etc/php-fpm.d/www.conf \
    /etc/my.cnf.d/invoiceninja.cnf \
    "$APP_DIR/.env" 2>/dev/null || warn "Some configuration files may not exist"
log "Configuration backup created: $CONFIG_BACKUP_FILE"

# Create backup manifest
log "Creating backup manifest..."
MANIFEST_FILE="$BACKUP_DIR/backup_manifest_$TIMESTAMP.txt"
cat > "$MANIFEST_FILE" << EOF
Invoice Ninja Backup Manifest
Generated: $(date)
Hostname: $(hostname)
Server IP: $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "Unknown")

Database Backup: ${DB_BACKUP_FILE}.gz
Application Backup: $APP_BACKUP_FILE
Configuration Backup: $CONFIG_BACKUP_FILE

Database Size: $(du -h "${DB_BACKUP_FILE}.gz" | cut -f1)
Application Size: $(du -h "$APP_BACKUP_FILE" | cut -f1)
Configuration Size: $(du -h "$CONFIG_BACKUP_FILE" | cut -f1)

Total Backup Size: $(du -sh "$BACKUP_DIR" | cut -f1)
EOF
log "Backup manifest created: $MANIFEST_FILE"

# Cleanup old backups
log "Cleaning up old backups (older than $RETENTION_DAYS days)..."
find "$BACKUP_DIR" -name "*.gz" -mtime +$RETENTION_DAYS -delete
find "$BACKUP_DIR" -name "*.txt" -mtime +$RETENTION_DAYS -delete
log "Old backups cleaned up"

# Display backup summary
log "=== BACKUP SUMMARY ==="
log "Database backup: ${DB_BACKUP_FILE}.gz"
log "Application backup: $APP_BACKUP_FILE"
log "Configuration backup: $CONFIG_BACKUP_FILE"
log "Manifest: $MANIFEST_FILE"
log "Total backup size: $(du -sh "$BACKUP_DIR" | cut -f1)"

log "Backup completed successfully!" 