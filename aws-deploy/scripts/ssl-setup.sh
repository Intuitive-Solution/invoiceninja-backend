#!/bin/bash

# SSL Certificate Setup Script for Invoice Ninja
# This script sets up SSL certificates using Let's Encrypt

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
DOMAIN=${1:-""}
EMAIL=${2:-""}

# Validate parameters
if [ -z "$DOMAIN" ]; then
    error "Domain name is required as first parameter"
fi

if [ -z "$EMAIL" ]; then
    error "Email address is required as second parameter"
fi

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
fi

log "Setting up SSL certificate for domain: $DOMAIN"

# Check if domain resolves to this server
log "Checking domain resolution..."
DOMAIN_IP=$(dig +short "$DOMAIN" | tail -n1)
SERVER_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "Unknown")

if [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
    warn "Domain $DOMAIN resolves to $DOMAIN_IP but server IP is $SERVER_IP"
    warn "SSL certificate generation may fail if domain doesn't point to this server"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        error "SSL setup cancelled"
    fi
fi

# Install certbot if not already installed
if ! command -v certbot &> /dev/null; then
    log "Installing certbot..."
    sudo dnf clean all
    dnf install -y certbot python3-certbot-nginx
fi

# Stop nginx temporarily
log "Stopping nginx temporarily..."
systemctl stop nginx

# Generate SSL certificate
log "Generating SSL certificate..."
certbot certonly --standalone \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    -d "$DOMAIN"

# Start nginx
log "Starting nginx..."
systemctl start nginx

# Update nginx configuration for SSL
log "Updating nginx configuration for SSL..."
cat > /etc/nginx/conf.d/invoiceninja.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    root /var/www/html/public;
    index index.php index.html index.htm;

    # SSL Configuration
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_stapling on;
    ssl_stapling_verify on;

    client_max_body_size 100M;
    client_body_timeout 300s;
    client_header_timeout 300s;
    send_timeout 300s;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
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
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
}
EOF

# Test nginx configuration
log "Testing nginx configuration..."
nginx -t

# Reload nginx
log "Reloading nginx..."
systemctl reload nginx

# Update application URL
log "Updating application URL..."
if [ -f "/var/www/html/.env" ]; then
    sed -i "s|APP_URL=.*|APP_URL=https://$DOMAIN|" /var/www/html/.env
    
    # Clear application cache
    cd /var/www/html
    php artisan config:clear
    php artisan config:cache
    
    log "Application URL updated to https://$DOMAIN"
fi

# Set up auto-renewal
log "Setting up SSL certificate auto-renewal..."
CRON_CMD="0 12 * * * /usr/bin/certbot renew --quiet --nginx"
(crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -

# Test SSL certificate
log "Testing SSL certificate..."
if curl -s -I "https://$DOMAIN" | grep -q "200 OK"; then
    log "✓ SSL certificate is working correctly"
else
    warn "SSL certificate test failed"
fi

# Display SSL information
log "=== SSL SETUP SUMMARY ==="
log "Domain: $DOMAIN"
log "Certificate: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
log "Private Key: /etc/letsencrypt/live/$DOMAIN/privkey.pem"
log "Auto-renewal: Enabled (daily at 12:00)"
log "Application URL: https://$DOMAIN"

info "=== NEXT STEPS ==="
info "1. Test your site: https://$DOMAIN"
info "2. Update any hardcoded URLs in your application"
info "3. Test SSL rating: https://www.ssllabs.com/ssltest/"
info "4. Set up monitoring for certificate expiration"

log "SSL setup completed successfully!" 