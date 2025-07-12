# Invoice Ninja AWS Deployment

This repository contains a complete automated deployment solution for Invoice Ninja on AWS using Terraform and bash scripts.

## Architecture

- **EC2 Instance**: Amazon Linux 2023 (t2.small)
- **Database**: MySQL 8.0 (installed on EC2)
- **Web Server**: Nginx with PHP 8.2-FPM
- **Storage**: EBS gp3 8GB encrypted volume
- **Region**: ap-south-1 (Mumbai)
- **Security**: Security groups with HTTP/HTTPS/SSH access

## Prerequisites

Before running the deployment, ensure you have:

1. **AWS CLI** installed and configured
   ```bash
   aws configure
   ```

2. **Terraform** installed (version >= 1.0)
   ```bash
   # On macOS
   brew install terraform
   
   # On Linux
   wget https://releases.hashicorp.com/terraform/1.6.0/terraform_1.6.0_linux_amd64.zip
   unzip terraform_1.6.0_linux_amd64.zip
   sudo mv terraform /usr/local/bin/
   ```

3. **Git** installed
4. **SSH key pair** (will be generated automatically if not present)

## Quick Start

1. **Clone and navigate to the deployment directory**:
   ```bash
   cd aws-deploy
   ```

2. **Configure deployment variables**:
   ```bash
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   ```
   
   Edit `terraform/terraform.tfvars` with your specific values:
   ```hcl
   # AWS Configuration
   aws_region = "ap-south-1"
   
   # Project Configuration
   project_name = "invoice-ninja"
   environment  = "production"
   
   # EC2 Configuration
   instance_type    = "t2.small"
   ebs_volume_size  = 8
   public_key_path  = "~/.ssh/id_rsa.pub"
   ssh_cidr         = "YOUR_IP_ADDRESS/32"  # Replace with your IP
   
   # Database Configuration
   db_password = "apple1234"
   
   # Application Configuration
   app_key     = ""  # Leave empty to auto-generate
   app_url     = "http://your-domain.com"
   domain_name = "your-domain.com"
   ```

3. **Run the deployment**:
   ```bash
   chmod +x deploy.sh
   ./deploy.sh
   ```

## Deployment Modes

The deployment script supports three modes:

### Full Deployment (Default)
Deploys infrastructure and application:
```bash
./deploy.sh --mode full
```

### Infrastructure Only
Deploys only the AWS infrastructure:
```bash
./deploy.sh --mode infra-only
```

### Application Only
Deploys only the application (requires existing infrastructure):
```bash
./deploy.sh --mode app-only
```

## Advanced Options

### Deploy Specific Branch
```bash
./deploy.sh --branch v5-stable
```

### Skip Confirmation Prompts
```bash
./deploy.sh --skip-confirmation
```

### Combined Options
```bash
./deploy.sh --mode full --branch v5-stable --skip-confirmation
```

## File Structure

```
aws-deploy/
├── deploy.sh                          # Master deployment script
├── terraform/
│   ├── main.tf                        # Main Terraform configuration
│   ├── variables.tf                   # Terraform variables
│   ├── outputs.tf                     # Terraform outputs
│   ├── user-data.sh                   # EC2 initialization script
│   ├── terraform.tfvars.example       # Example variables file
│   └── terraform.tfvars               # Your variables (create this)
├── scripts/
│   ├── server-setup.sh                # Server setup script
│   └── deploy-app.sh                  # Application deployment script
├── config/
│   └── env.production.template        # Environment template
└── README.md                          # This file
```

## What Gets Deployed

### Infrastructure Components
- **VPC** with public subnet
- **Internet Gateway** and routing
- **Security Group** with HTTP/HTTPS/SSH access
- **EC2 Instance** (t2.small, Amazon Linux 2023)
- **EBS Volume** (8GB gp3, encrypted)
- **Elastic IP** for static IP address
- **Key Pair** for SSH access

### Software Stack
- **PHP 8.2** with required extensions
- **Nginx** web server
- **MySQL 8.0** database
- **Composer** for PHP dependencies
- **Node.js** and npm for frontend assets
- **SSL/TLS tools** (certbot)

### Application Setup
- **Invoice Ninja** latest stable version
- **Database** creation and migration
- **File permissions** and security
- **Caching** and optimization
- **Log rotation** configuration

## Post-Deployment Steps

1. **Access your application**:
   ```
   http://YOUR_INSTANCE_IP
   ```

2. **Complete the setup wizard**:
   - Create admin account
   - Configure company settings
   - Set up email configuration

3. **Configure SSL certificate** (recommended):
   ```bash
   ssh ec2-user@YOUR_INSTANCE_IP
   sudo certbot --nginx -d your-domain.com
   ```

4. **Set up domain name**:
   - Point your domain to the Elastic IP
   - Update APP_URL in the application settings

## Management Commands

### SSH to Instance
```bash
ssh ec2-user@YOUR_INSTANCE_IP
```

### View Application Logs
```bash
ssh ec2-user@YOUR_INSTANCE_IP 'tail -f /var/www/html/storage/logs/laravel.log'
```

### Monitor System Status
```bash
ssh ec2-user@YOUR_INSTANCE_IP 'sudo /usr/local/bin/monitor-invoiceninja.sh'
```

### Redeploy Application
```bash
ssh ec2-user@YOUR_INSTANCE_IP 'sudo /usr/local/bin/deploy-invoiceninja.sh'
```

### Update Application
```bash
ssh ec2-user@YOUR_INSTANCE_IP 'sudo /usr/local/bin/deploy-invoiceninja.sh v5-stable'
```

## Backup and Recovery

### Database Backup
```bash
ssh ec2-user@YOUR_INSTANCE_IP
mysqldump -u invoiceninja -p invoiceninja > backup.sql
```

### Application Backup
```bash
ssh ec2-user@YOUR_INSTANCE_IP
tar -czf invoice-ninja-backup.tar.gz /var/www/html
```

### Automated Backups
Set up a cron job for regular backups:
```bash
# Add to crontab
0 2 * * * /usr/local/bin/backup-invoiceninja.sh
```

## Security Considerations

1. **SSH Access**: Restrict SSH access to your IP address in terraform.tfvars
2. **Database**: MySQL is only accessible locally
3. **SSL Certificate**: Set up SSL/TLS encryption for production
4. **Firewall**: Security groups restrict access to necessary ports only
5. **Updates**: Keep the system and application updated regularly

## Troubleshooting

### Common Issues

1. **Terraform fails to apply**:
   - Check AWS credentials: `aws sts get-caller-identity`
   - Verify region permissions
   - Check terraform.tfvars syntax

2. **SSH connection fails**:
   - Verify security group allows SSH from your IP
   - Check SSH key permissions: `chmod 600 ~/.ssh/id_rsa`
   - Wait for instance to fully initialize

3. **Application not accessible**:
   - Check security group allows HTTP/HTTPS
   - Verify Nginx is running: `sudo systemctl status nginx`
   - Check application logs

4. **Database connection issues**:
   - Verify MySQL is running: `sudo systemctl status mariadb`
   - Check database credentials in .env file
   - Test connection: `mysql -u invoiceninja -p`

### Log Files
- **Application logs**: `/var/www/html/storage/logs/laravel.log`
- **Nginx logs**: `/var/log/nginx/error.log`
- **PHP-FPM logs**: `/var/log/php-fpm/www-error.log`
- **System logs**: `/var/log/messages`

## Customization

### Modify Instance Size
Edit `terraform/terraform.tfvars`:
```hcl
instance_type = "t3.medium"  # or t3.large, etc.
```

### Add More Storage
Edit `terraform/terraform.tfvars`:
```hcl
ebs_volume_size = 20  # GB
```

### Change Region
Edit `terraform/terraform.tfvars`:
```hcl
aws_region = "us-east-1"  # or your preferred region
```

## Cost Estimation

**Monthly costs (approximate)**:
- EC2 t2.small: $17/month
- EBS 8GB gp3: $1/month
- Elastic IP: $0 (when attached)
- Data transfer: Variable

**Total**: ~$18-25/month (excluding data transfer)

## Cleanup

To destroy all resources:
```bash
cd terraform
terraform destroy
```

## Support

For issues related to:
- **Invoice Ninja**: Visit [Invoice Ninja GitHub](https://github.com/invoiceninja/invoiceninja)
- **AWS**: Check [AWS Documentation](https://docs.aws.amazon.com/)
- **Terraform**: See [Terraform Documentation](https://www.terraform.io/docs/)

## License

This deployment solution is provided as-is. Invoice Ninja is subject to its own license terms. 

## Fix the DNF Cache Issue

**SSH into your instance and run these commands:**

```bash
ssh ec2-user@13.202.215.35

# Clear the dnf cache
sudo dnf clean all

# Rebuild the cache
sudo dnf makecache

# Update package metadata
sudo dnf update -y
```

## Alternative Fix: Force Cache Refresh

If the above doesn't work, try:

```bash
# Remove the problematic cache directory
sudo rm -rf /var/cache/dnf/*

# Rebuild cache
sudo dnf makecache

# Try installing packages again
sudo dnf install -y nginx
```

## Update the Server Setup Script

To prevent this issue in the future, add cache cleaning to the server setup script. **In `aws-deploy/scripts/server-setup.sh`, find this section:**

```bash
<code_block_to_apply_changes_from>
```

**Replace with:**
```bash
# Update system
log "Updating system packages..."
dnf update -y
```

## If the Issue Persists

If you're still getting the error, try installing packages one by one to identify which one is causing the problem:

```bash
sudo dnf install -y nginx
sudo dnf install -y mariadb105-server
sudo dnf install -y php
```

## Quick Resolution

The fastest way to resolve this right now:

1. **SSH into the instance:**
   ```bash
   ssh ec2-user@13.202.215.35
   ```

2. **Clear DNF cache:**
   ```bash
   sudo dnf clean all && sudo dnf makecache
   ```

3. **Re-run the deployment:**
   ```bash
   exit  # Exit from SSH
   ./deploy.sh --mode app-only
   ```

This should resolve the corrupted package cache issue and allow the installation to proceed. 