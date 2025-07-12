#!/bin/bash

# Master Deployment Script for Invoice Ninja on AWS
# This script orchestrates the complete deployment process

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
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

header() {
    echo -e "${PURPLE}================================${NC}"
    echo -e "${PURPLE}$1${NC}"
    echo -e "${PURPLE}================================${NC}"
}

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
CONFIG_DIR="$SCRIPT_DIR/config"

# Default values
DEPLOY_MODE="full"  # full, infra-only, app-only
BRANCH="master"
SKIP_CONFIRMATION=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --mode)
            DEPLOY_MODE="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --skip-confirmation)
            SKIP_CONFIRMATION=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --mode MODE              Deployment mode: full, infra-only, app-only (default: full)"
            echo "  --branch BRANCH          Git branch to deploy (default: v5-stable)"
            echo "  --skip-confirmation      Skip confirmation prompts"
            echo "  --help                   Show this help message"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Validate deployment mode
if [[ ! "$DEPLOY_MODE" =~ ^(full|infra-only|app-only)$ ]]; then
    error "Invalid deployment mode: $DEPLOY_MODE. Must be one of: full, infra-only, app-only"
fi

# Check prerequisites
check_prerequisites() {
    header "CHECKING PREREQUISITES"
    
    # Check if running on supported OS
    if [[ "$OSTYPE" != "linux-gnu"* ]] && [[ "$OSTYPE" != "darwin"* ]]; then
        error "This script is designed for Linux or macOS"
    fi
    
    # Check required tools
    local required_tools=("terraform" "aws" "git" "curl")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            error "$tool is required but not installed"
        fi
        log "✓ $tool is available"
    done
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials not configured. Run 'aws configure' first"
    fi
    log "✓ AWS credentials configured"
    
    # Check SSH key
    if [[ ! -f ~/.ssh/id_rsa.pub ]]; then
        warn "SSH public key not found at ~/.ssh/id_rsa.pub"
        info "Generating SSH key pair..."
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -C "invoiceninja-deployment"
        log "✓ SSH key pair generated"
    else
        log "✓ SSH key pair exists"
    fi
    
    # Check terraform files
    if [[ ! -f "$TERRAFORM_DIR/main.tf" ]]; then
        error "Terraform configuration not found at $TERRAFORM_DIR/main.tf"
    fi
    log "✓ Terraform configuration found"
    
    # Check if terraform.tfvars exists
    if [[ ! -f "$TERRAFORM_DIR/terraform.tfvars" ]]; then
        warn "terraform.tfvars not found"
        info "Please create terraform.tfvars file based on terraform.tfvars.example"
        info "Copy example: cp $TERRAFORM_DIR/terraform.tfvars.example $TERRAFORM_DIR/terraform.tfvars"
        info "Then edit the values according to your requirements"
        error "terraform.tfvars is required for deployment"
    fi
    log "✓ terraform.tfvars found"
}

# Deploy infrastructure
deploy_infrastructure() {
    header "DEPLOYING INFRASTRUCTURE"
    
    cd "$TERRAFORM_DIR"
    
    # Initialize Terraform
    log "Initializing Terraform..."
    terraform init
    
    # Plan deployment
    log "Planning infrastructure deployment..."
    terraform plan -out=tfplan
    
    if [[ "$SKIP_CONFIRMATION" == false ]]; then
        echo
        read -p "Do you want to proceed with infrastructure deployment? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error "Infrastructure deployment cancelled"
        fi
    fi
    
    # Apply deployment
    log "Applying infrastructure deployment..."
    terraform apply tfplan
    
    # Get outputs
    log "Retrieving infrastructure information..."
    INSTANCE_IP=$(terraform output -raw instance_public_ip)
    INSTANCE_ID=$(terraform output -raw instance_id)
    
    log "✓ Infrastructure deployed successfully"
    log "Instance IP: $INSTANCE_IP"
    log "Instance ID: $INSTANCE_ID"
    
    # Save outputs for later use
    cat > "$SCRIPT_DIR/.deployment-info" << EOF
INSTANCE_IP=$INSTANCE_IP
INSTANCE_ID=$INSTANCE_ID
DEPLOYMENT_TIME="$(date +'%Y-%m-%d %H:%M:%S')"
EOF
    
    cd - > /dev/null
}

# Wait for instance to be ready
wait_for_instance() {
    header "WAITING FOR INSTANCE TO BE READY"
    
    if [[ -z "$INSTANCE_IP" ]]; then
        if [[ -f "$SCRIPT_DIR/.deployment-info" ]]; then
            source "$SCRIPT_DIR/.deployment-info"
        else
            error "Instance IP not found. Please deploy infrastructure first."
        fi
    fi
    
    log "Waiting for instance $INSTANCE_IP to be ready..."
    
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ec2-user@$INSTANCE_IP "echo 'Instance ready'" &> /dev/null; then
            log "✓ Instance is ready for deployment"
            return 0
        fi
        
        log "Attempt $attempt/$max_attempts - Instance not ready yet, waiting..."
        sleep 30
        ((attempt++))
    done
    
    error "Instance did not become ready within expected time"
}

# Deploy application
deploy_application() {
    header "DEPLOYING APPLICATION"
    
    if [[ -z "$INSTANCE_IP" ]]; then
        if [[ -f "$SCRIPT_DIR/.deployment-info" ]]; then
            source "$SCRIPT_DIR/.deployment-info"
        else
            error "Instance IP not found. Please deploy infrastructure first."
        fi
    fi
    
    # Get deployment variables
    DB_PASSWORD=$(cd "$TERRAFORM_DIR" && terraform output -raw db_password 2>/dev/null || echo "")
    APP_KEY=$(cd "$TERRAFORM_DIR" && terraform output -raw app_key 2>/dev/null || echo "")
    APP_URL=$(cd "$TERRAFORM_DIR" && terraform output -raw app_url 2>/dev/null || echo "http://$INSTANCE_IP")
    
    if [[ -z "$DB_PASSWORD" ]]; then
        error "Database password not found in Terraform outputs"
    fi
    
    # Copy deployment scripts to instance
    log "Copying deployment scripts to instance..."
    scp -o StrictHostKeyChecking=no "$SCRIPTS_DIR/server-setup.sh" ec2-user@$INSTANCE_IP:/tmp/
    scp -o StrictHostKeyChecking=no "$SCRIPTS_DIR/deploy-app.sh" ec2-user@$INSTANCE_IP:/tmp/
    
    # Run server setup
    log "Running server setup on instance..."
    ssh -o StrictHostKeyChecking=no ec2-user@$INSTANCE_IP "sudo chmod +x /tmp/server-setup.sh && sudo /tmp/server-setup.sh '$DB_PASSWORD' '$APP_KEY' '$APP_URL'"
    
    # Deploy application
    log "Deploying Invoice Ninja application..."
    ssh -o StrictHostKeyChecking=no ec2-user@$INSTANCE_IP "chmod +x /tmp/deploy-app.sh && /tmp/deploy-app.sh '$BRANCH' '$DB_PASSWORD' '$APP_KEY' '$APP_URL'"
    
    log "✓ Application deployed successfully"
}

# Verify deployment
verify_deployment() {
    header "VERIFYING DEPLOYMENT"
    
    if [[ -z "$INSTANCE_IP" ]]; then
        if [[ -f "$SCRIPT_DIR/.deployment-info" ]]; then
            source "$SCRIPT_DIR/.deployment-info"
        else
            error "Instance IP not found"
        fi
    fi
    
    # Test web server response
    log "Testing web server response..."
    if curl -s -o /dev/null -w "%{http_code}" "http://$INSTANCE_IP" | grep -q "200"; then
        log "✓ Web server is responding"
    else
        warn "Web server may not be responding correctly"
    fi
    
    # Test SSH access
    log "Testing SSH access..."
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ec2-user@$INSTANCE_IP "echo 'SSH OK'" &> /dev/null; then
        log "✓ SSH access is working"
    else
        warn "SSH access may have issues"
    fi
    
    # Get system status
    log "Getting system status..."
    ssh -o StrictHostKeyChecking=no ec2-user@$INSTANCE_IP "sudo /usr/local/bin/monitor-invoiceninja.sh" || warn "System monitoring failed"
}

# Display deployment summary
display_summary() {
    header "DEPLOYMENT SUMMARY"
    
    if [[ -f "$SCRIPT_DIR/.deployment-info" ]]; then
        source "$SCRIPT_DIR/.deployment-info"
    fi
    
    log "=== DEPLOYMENT COMPLETED ==="
    log "Application: Invoice Ninja"
    log "Branch: $BRANCH"
    log "Instance IP: ${INSTANCE_IP:-'Not available'}"
    log "Instance ID: ${INSTANCE_ID:-'Not available'}"
    log "Deployment Time: ${DEPLOYMENT_TIME:-'Not available'}"
    log "Application URL: http://${INSTANCE_IP:-'your-instance-ip'}"
    
    info "=== NEXT STEPS ==="
    info "1. Access your application at: http://${INSTANCE_IP:-'your-instance-ip'}"
    info "2. Complete the Invoice Ninja setup wizard"
    info "3. Configure your domain name and SSL certificate"
    info "4. Set up regular backups"
    info "5. Configure monitoring and alerting"
    
    info "=== USEFUL COMMANDS ==="
    info "SSH to instance: ssh ec2-user@${INSTANCE_IP:-'your-instance-ip'}"
    info "View logs: ssh ec2-user@${INSTANCE_IP:-'your-instance-ip'} 'tail -f /var/www/html/storage/logs/laravel.log'"
    info "Monitor system: ssh ec2-user@${INSTANCE_IP:-'your-instance-ip'} 'sudo /usr/local/bin/monitor-invoiceninja.sh'"
    info "Redeploy app: ssh ec2-user@${INSTANCE_IP:-'your-instance-ip'} 'sudo /usr/local/bin/deploy-invoiceninja.sh'"
}

# Main deployment function
main() {
    header "INVOICE NINJA AWS DEPLOYMENT"
    
    log "Deployment mode: $DEPLOY_MODE"
    log "Branch: $BRANCH"
    log "Skip confirmation: $SKIP_CONFIRMATION"
    
    # Check prerequisites
    check_prerequisites
    
    # Deploy based on mode
    case $DEPLOY_MODE in
        "full")
            deploy_infrastructure
            wait_for_instance
            deploy_application
            verify_deployment
            ;;
        "infra-only")
            deploy_infrastructure
            ;;
        "app-only")
            wait_for_instance
            deploy_application
            verify_deployment
            ;;
    esac
    
    # Display summary
    display_summary
    
    log "Deployment completed successfully!"
}

# Cleanup function
cleanup() {
    log "Cleaning up temporary files..."
    cd "$TERRAFORM_DIR" && rm -f tfplan
}

# Set up trap for cleanup
trap cleanup EXIT

# Run main function
main "$@" 