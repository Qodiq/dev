#!/bin/bash
# Phideus Research Platform - Immutable Container Bootstrap
# This script creates a self-organizing research platform that runs in 
# immutable containers, applying Phideus principles at the infrastructure level

set -euo pipefail

# ============================================================================
# PART 1: Core Configuration and Variable Initialization
# ============================================================================

# Defensive variable initialization - ensure all critical vars have values
export USER="${USER:-$(whoami 2>/dev/null || echo 'phideus')}"
export HOME="${HOME:-$(getent passwd $(whoami) 2>/dev/null | cut -d: -f6 || echo '/home/phideus')}"
export HOSTNAME="${HOSTNAME:-$(hostname 2>/dev/null || echo 'phideus-node')}"

# Platform configuration
PLATFORM_NAME="phideus-research-platform"
PLATFORM_VERSION="2.0.0"
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-container}"  # 'container' or 'traditional'

# Container configuration
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}"  # podman is more secure than docker
CONTAINER_REGISTRY="${CONTAINER_REGISTRY:-localhost:5000}"
BASE_IMAGE="${BASE_IMAGE:-alpine:3.19}"  # Minimal attack surface

# Paths - different for container vs traditional deployment
if [ "$DEPLOYMENT_MODE" = "container" ]; then
    PLATFORM_ROOT="/opt/phideus"
    CONFIG_ROOT="/etc/phideus"
    DATA_ROOT="/var/lib/phideus"
    LOG_ROOT="/var/log/phideus"
else
    PLATFORM_ROOT="${HOME}/.phideus-platform"
    CONFIG_ROOT="${PLATFORM_ROOT}/config"
    DATA_ROOT="${PLATFORM_ROOT}/data"
    LOG_ROOT="${PLATFORM_ROOT}/logs"
fi

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# ============================================================================
# PART 2: Validation Functions
# ============================================================================

# Comprehensive variable validation
validate_required_vars() {
    local missing_vars=()
    local required_vars=(
        "USER" "HOME" "HOSTNAME" "PLATFORM_ROOT" 
        "CONFIG_ROOT" "DATA_ROOT" "LOG_ROOT"
        "DEPLOYMENT_MODE" "CONTAINER_RUNTIME"
    )
    
    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            missing_vars+=("$var")
        fi
    done
    
    if [ ${#missing_vars[@]} -ne 0 ]; then
        echo -e "${RED}ERROR: Required variables not defined: ${missing_vars[*]}${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ All required variables validated${NC}"
    return 0
}

# Check if running in container
is_containerized() {
    # Multiple methods to detect container environment
    if [ -f /.dockerenv ]; then
        return 0
    elif [ -f /run/.containerenv ]; then
        return 0
    elif grep -q 'docker\|lxc\|kubepods' /proc/1/cgroup 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# PART 3: Immutable Container Creation
# ============================================================================

# Create multi-stage Dockerfile for minimal attack surface
create_dockerfile() {
    echo -e "${YELLOW}🐳 Creating multi-stage Dockerfile...${NC}"
    
    cat > Dockerfile << 'EOF'
# Stage 1: Builder - Compile and prepare everything
FROM alpine:3.19 AS builder

# Install build dependencies
RUN apk add --no-cache \
    python3 \
    py3-pip \
    py3-virtualenv \
    ansible \
    git \
    gcc \
    musl-dev \
    python3-dev \
    libffi-dev \
    openssl-dev \
    cargo \
    rust

# Create non-root user for building
RUN adduser -D -s /bin/sh phideus

# Switch to non-root user
USER phideus
WORKDIR /home/phideus

# Create virtual environment
RUN python3 -m venv /home/phideus/venv

# Activate venv and install Python packages
RUN . /home/phideus/venv/bin/activate && \
    pip install --upgrade pip && \
    pip install \
        ansible==2.16.0 \
        ansible-lint \
        jmespath \
        cryptography \
        pyyaml

# Copy platform files (will be added via build context)
COPY --chown=phideus:phideus platform/ /home/phideus/platform/

# Pre-compile Python files for faster startup
RUN . /home/phideus/venv/bin/activate && \
    python -m compileall /home/phideus/venv

# Stage 2: Runtime - Minimal image with only necessary files
FROM alpine:3.19 AS runtime

# Install only runtime dependencies
RUN apk add --no-cache \
    python3 \
    libffi \
    openssl \
    ca-certificates \
    tzdata \
    tini  # Proper init system for containers

# Create non-root user
RUN adduser -D -s /bin/sh -u 1000 phideus && \
    mkdir -p /opt/phideus /etc/phideus /var/lib/phideus /var/log/phideus && \
    chown -R phideus:phideus /opt/phideus /etc/phideus /var/lib/phideus /var/log/phideus

# Copy only necessary files from builder
COPY --from=builder --chown=phideus:phideus /home/phideus/venv /opt/phideus/venv
COPY --from=builder --chown=phideus:phideus /home/phideus/platform /opt/phideus/platform

# Make filesystem read-only except for specific directories
# This is key for immutability!
USER root
RUN chmod -R a-w /opt/phideus && \
    chmod -R u+w /var/lib/phideus /var/log/phideus

# Switch to non-root user
USER phideus
WORKDIR /opt/phideus

# Set environment variables
ENV PATH="/opt/phideus/venv/bin:$PATH" \
    PYTHONPATH="/opt/phideus/platform:$PYTHONPATH" \
    ANSIBLE_CONFIG="/etc/phideus/ansible.cfg" \
    PHIDEUS_MODE="container"

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD test -f /var/lib/phideus/platform_state.json || exit 1

# Use tini as init system to properly handle signals
ENTRYPOINT ["/sbin/tini", "--"]

# Default command runs the platform
CMD ["/opt/phideus/venv/bin/ansible-playbook", \
     "/opt/phideus/platform/ansible/playbooks/master-orchestrator.yml"]
EOF
}

# Create container-specific Ansible configuration
create_container_ansible_config() {
    echo -e "${YELLOW}📝 Creating container-optimized Ansible configuration...${NC}"
    
    mkdir -p platform/ansible
    cat > platform/ansible/ansible.cfg << 'EOF'
[defaults]
# Container-optimized settings
inventory = /etc/phideus/inventory
host_key_checking = False
retry_files_enabled = False
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 3600
stdout_callback = yaml
callbacks_enabled = profile_tasks, timer

# Security settings for containers
host_key_checking = False
command_warnings = False
deprecation_warnings = False
action_warnings = False

# Performance settings
forks = 10
poll_interval = 15
internal_poll_interval = 0.001

# Container-specific paths
local_tmp = /tmp/ansible
remote_tmp = /tmp/ansible

[inventory]
enable_plugins = host_list, script, auto, yaml, ini

[privilege_escalation]
become = False  # Running as non-root in container
EOF
}

# Create Kubernetes manifests for orchestration
create_kubernetes_manifests() {
    echo -e "${YELLOW}☸️  Creating Kubernetes manifests...${NC}"
    
    mkdir -p k8s
    
    # ConfigMap for platform configuration
    cat > k8s/configmap.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: phideus-config
  namespace: phideus-system
data:
  platform.yml: |
    ---
    platform:
      name: phideus-research-platform
      version: 2.0.0
      mode: kubernetes
      
    entropy:
      pool_size: 8192
      refresh_rate: 100
      sources:
        - kubernetes_events
        - pod_entropy
        - node_entropy
        
    methodology_weights:
      linear: 0.20
      circular: 0.20
      rotating: 0.15
      modular: 0.15
      iterative: 0.15
      inverted: 0.15
      
    m_loop:
      micro:
        frequency: 1000
        control_type: PID
      meso:
        frequency: 1
        control_type: adaptive
      macro:
        frequency: 0.016
        control_type: model_predictive
EOF

    # StatefulSet for operators (ensures stable identity)
    cat > k8s/statefulset.yaml << 'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: phideus-operators
  namespace: phideus-system
spec:
  serviceName: phideus-operators
  replicas: 6  # One for each methodology operator
  selector:
    matchLabels:
      app: phideus-operator
  template:
    metadata:
      labels:
        app: phideus-operator
    spec:
      # Security context for the pod
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
          
      containers:
      - name: operator
        image: ${CONTAINER_REGISTRY}/phideus-operator:${PLATFORM_VERSION}
        imagePullPolicy: Always
        
        # Security context for the container
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
            
        # Resource limits for stability
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
            
        # Environment variables
        env:
        - name: OPERATOR_ID
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: METHODOLOGY
          value: "auto"  # Will be assigned based on pod ordinal
          
        # Volume mounts
        volumeMounts:
        - name: config
          mountPath: /etc/phideus
          readOnly: true
        - name: data
          mountPath: /var/lib/phideus
        - name: logs
          mountPath: /var/log/phideus
        - name: tmp
          mountPath: /tmp
          
      volumes:
      - name: config
        configMap:
          name: phideus-config
      - name: tmp
        emptyDir: {}
        
  # Persistent volumes for data and logs
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 10Gi
  - metadata:
      name: logs
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 5Gi
EOF

    # CronJob for periodic evolution cycles
    cat > k8s/cronjob.yaml << 'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: phideus-evolution
  namespace: phideus-system
spec:
  schedule: "*/5 * * * *"  # Every 5 minutes
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            
          containers:
          - name: evolution
            image: ${CONTAINER_REGISTRY}/phideus-operator:${PLATFORM_VERSION}
            command:
            - /opt/phideus/venv/bin/ansible-playbook
            - /opt/phideus/platform/ansible/playbooks/evolution-cycle.yml
            
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities:
                drop:
                - ALL
                
            volumeMounts:
            - name: config
              mountPath: /etc/phideus
              readOnly: true
            - name: shared-data
              mountPath: /var/lib/phideus
              
          volumes:
          - name: config
            configMap:
              name: phideus-config
          - name: shared-data
            persistentVolumeClaim:
              claimName: phideus-shared-data
EOF

    # NetworkPolicy for pod isolation
    cat > k8s/networkpolicy.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: phideus-isolation
  namespace: phideus-system
spec:
  podSelector:
    matchLabels:
      app: phideus-operator
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: phideus-operator
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: phideus-operator
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 53  # DNS
    - protocol: UDP
      port: 53  # DNS
EOF
}

# Create systemd-nspawn configuration for immutable containers
create_nspawn_config() {
    echo -e "${YELLOW}🔒 Creating systemd-nspawn immutable container config...${NC}"
    
    mkdir -p nspawn
    
    # Create nspawn container configuration
    cat > nspawn/phideus-operator.nspawn << 'EOF'
[Exec]
# Run as non-root user inside container
User=phideus
WorkingDirectory=/opt/phideus
Environment=PHIDEUS_MODE=nspawn

# Security settings
PrivateUsers=yes
PrivateNetwork=no
NoNewPrivileges=yes

# Capabilities - drop everything except what's needed
DropCapability=ALL
Capability=CAP_NET_BIND_SERVICE

# System call filtering
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete

[Files]
# Make root filesystem read-only
ReadOnly=yes

# Bind mount only necessary directories as read-write
Bind=/var/lib/phideus
Bind=/var/log/phideus
TemporaryFileSystem=/tmp:mode=1777

# Overlay for /etc to allow runtime config changes
Overlay=/etc:/var/lib/phideus/etc-overlay:/etc

[Network]
# Use host networking but with restrictions
VirtualEthernet=no
Zone=phideus
EOF

    # Create launch script for nspawn
    cat > nspawn/launch-operator.sh << 'EOF'
#!/bin/bash
# Launch Phideus operator in immutable systemd-nspawn container

set -euo pipefail

OPERATOR_ID="${1:-operator-1}"
IMAGE_PATH="/var/lib/machines/phideus-operator"

# Ensure image exists
if [ ! -d "$IMAGE_PATH" ]; then
    echo "Error: Container image not found at $IMAGE_PATH"
    echo "Run: sudo debootstrap --arch=amd64 bookworm $IMAGE_PATH"
    exit 1
fi

# Launch container with systemd-nspawn
sudo systemd-nspawn \
    --machine="phideus-$OPERATOR_ID" \
    --directory="$IMAGE_PATH" \
    --settings=trusted \
    --bind-ro=/usr/share/zoneinfo \
    --bind=/var/lib/phideus/$OPERATOR_ID:/var/lib/phideus \
    --bind=/var/log/phideus/$OPERATOR_ID:/var/log/phideus \
    --setenv=OPERATOR_ID="$OPERATOR_ID" \
    --setenv=PHIDEUS_MODE=nspawn \
    /opt/phideus/venv/bin/ansible-playbook \
    /opt/phideus/platform/ansible/playbooks/operator-loop.yml
EOF
    chmod +x nspawn/launch-operator.sh
}

# Create AppArmor/SELinux profiles for additional security
create_security_profiles() {
    echo -e "${YELLOW}🛡️  Creating security profiles...${NC}"
    
    mkdir -p security
    
    # AppArmor profile
    cat > security/phideus-operator.apparmor << 'EOF'
#include <tunables/global>

profile phideus-operator flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  #include <abstractions/python>
  
  # Allow reading platform files
  /opt/phideus/** r,
  
  # Allow writing to specific directories only
  /var/lib/phideus/** rw,
  /var/log/phideus/** rw,
  /tmp/** rw,
  
  # Network access - only localhost
  network inet stream,
  network inet6 stream,
  
  # Deny everything else
  deny /** w,
  deny @{HOME}/** rw,
  deny /root/** rw,
  deny /etc/** w,
}
EOF

    # SELinux policy module
    cat > security/phideus-operator.te << 'EOF'
policy_module(phideus_operator, 1.0.0)

# Define types
type phideus_operator_t;
type phideus_operator_exec_t;
type phideus_data_t;
type phideus_log_t;

# Mark as application domain
application_domain(phideus_operator_t, phideus_operator_exec_t)

# Allow execution
can_exec(phideus_operator_t, phideus_operator_exec_t)

# File access
allow phideus_operator_t phideus_data_t:dir manage_dir_perms;
allow phideus_operator_t phideus_data_t:file manage_file_perms;
allow phideus_operator_t phideus_log_t:dir manage_dir_perms;
allow phideus_operator_t phideus_log_t:file manage_file_perms;

# Network access
corenet_tcp_sendrecv_generic_node(phideus_operator_t)
corenet_tcp_bind_generic_node(phideus_operator_t)

# Deny other access
neverallow phideus_operator_t ~{phideus_data_t phideus_log_t}:file write;
EOF
}

# Create the main platform structure (container-optimized)
create_platform_structure() {
    echo -e "${YELLOW}🏗️  Creating platform structure...${NC}"
    
    # Create directory structure
    mkdir -p platform/{
        ansible/roles,
        ansible/playbooks,
        ansible/inventories,
        ansible/group_vars/all,
        research/experiments,
        research/results,
        research/models,
        scripts,
        tests
    }
    
    # Create container-aware inventory
    cat > platform/ansible/inventories/container << 'EOF'
[operators]
localhost ansible_connection=local

[operators:vars]
ansible_python_interpreter=/opt/phideus/venv/bin/python3
platform_mode=container
data_root=/var/lib/phideus
log_root=/var/log/phideus
config_root=/etc/phideus
EOF
}

# Create container-aware playbooks
create_container_playbooks() {
    echo -e "${YELLOW}📚 Creating container-aware playbooks...${NC}"
    
    # Master orchestrator adapted for containers
    cat > platform/ansible/playbooks/master-orchestrator.yml << 'EOF'
---
- name: Phideus Container Orchestrator
  hosts: operators
  gather_facts: yes
  vars:
    platform_mode: "{{ lookup('env', 'PHIDEUS_MODE') | default('container') }}"
    operator_id: "{{ lookup('env', 'OPERATOR_ID') | default('operator-0') }}"
    
  pre_tasks:
    - name: Initialize container-specific entropy
      block:
        # Gather entropy from container-specific sources
        - name: Collect container entropy
          set_fact:
            container_entropy: >-
              {{
                (ansible_date_time.epoch | int) ^
                (ansible_hostname | hash('sha256') | int) ^
                (1000000 | random)
              }}
              
        - name: Mix with hardware entropy if available
          shell: |
            if [ -c /dev/urandom ]; then
              od -An -N4 -tu4 /dev/urandom | tr -d ' '
            else
              echo {{ container_entropy }}
            fi
          register: entropy_result
          changed_when: false
          
        - name: Set final entropy value
          set_fact:
            system_entropy: "{{ entropy_result.stdout | int % 1000000 }}"
            
    - name: Determine methodology based on operator ordinal
      set_fact:
        assigned_methodology: >-
          {%- set methodologies = [
            'linear-operator',
            'circular-operator', 
            'rotating-operator',
            'modular-operator',
            'iterative-operator',
            'inverted-operator'
          ] -%}
          {%- set ordinal = operator_id.split('-')[-1] | int % 6 -%}
          {{ methodologies[ordinal] }}
          
  tasks:
    - name: Run assigned methodology operator
      include_role:
        name: "{{ assigned_methodology }}"
      vars:
        operator_entropy: "{{ system_entropy }}"
        immutable_mode: true
        
    - name: Persist state to volume
      copy:
        content: |
          {
            "timestamp": "{{ ansible_date_time.iso8601 }}",
            "operator_id": "{{ operator_id }}",
            "methodology": "{{ assigned_methodology }}",
            "entropy": {{ system_entropy }},
            "platform_mode": "{{ platform_mode }}",
            "events_processed": {{ events_processed | default(0) + 1 }}
          }
        dest: "/var/lib/phideus/{{ operator_id }}-state.json"
        
    - name: Log operator activity
      lineinfile:
        path: "/var/log/phideus/{{ operator_id }}.log"
        line: "{{ ansible_date_time.iso8601 }} | {{ assigned_methodology }} | entropy={{ system_entropy }}"
        create: yes
EOF
}

# Build and push container images
build_container_images() {
    echo -e "${YELLOW}🏗️  Building container images...${NC}"
    
    # Build the image
    ${CONTAINER_RUNTIME} build \
        --tag ${CONTAINER_REGISTRY}/phideus-operator:${PLATFORM_VERSION} \
        --tag ${CONTAINER_REGISTRY}/phideus-operator:latest \
        --security-opt label=disable \
        --cap-drop ALL \
        .
        
    # For rootless podman, no push needed for local registry
    if [ "$CONTAINER_RUNTIME" = "podman" ]; then
        echo -e "${GREEN}✓ Image built and available locally${NC}"
    else
        echo -e "${YELLOW}Pushing to registry...${NC}"
        ${CONTAINER_RUNTIME} push ${CONTAINER_REGISTRY}/phideus-operator:${PLATFORM_VERSION}
    fi
}

# Deploy the platform
deploy_platform() {
    echo -e "${YELLOW}🚀 Deploying Phideus platform...${NC}"
    
    case "$DEPLOYMENT_MODE" in
        "kubernetes")
            echo "Deploying to Kubernetes..."
            kubectl create namespace phideus-system || true
            kubectl apply -f k8s/
            ;;
            
        "podman")
            echo "Deploying with Podman..."
            # Create pod for all operators
            podman pod create \
                --name phideus-platform \
                --network bridge \
                --share net
                
            # Launch operators
            for i in {0..5}; do
                podman run -d \
                    --name phideus-operator-$i \
                    --pod phideus-platform \
                    --env OPERATOR_ID=operator-$i \
                    --volume phideus-data-$i:/var/lib/phideus:Z \
                    --volume phideus-logs-$i:/var/log/phideus:Z \
                    --volume phideus-config:/etc/phideus:ro,Z \
                    --security-opt label=disable \
                    --security-opt seccomp=unconfined \
                    --read-only \
                    --tmpfs /tmp:rw,noexec,nosuid \
                    ${CONTAINER_REGISTRY}/phideus-operator:${PLATFORM_VERSION}
            done
            ;;
            
        "nspawn")
            echo "Deploying with systemd-nspawn..."
            for i in {0..5}; do
                ./nspawn/launch-operator.sh operator-$i &
            done
            ;;
            
        *)
            echo -e "${RED}Unknown deployment mode: $DEPLOYMENT_MODE${NC}"
            exit 1
            ;;
    esac
}

# Main execution flow
main() {
    echo -e "${BLUE}"
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════════╗
║              PHIDEUS IMMUTABLE CONTAINER PLATFORM v2.0                        ║
║                                                                               ║
║    "Security through Immutability, Evolution through Containers"              ║
║                                                                               ║
║    Applying Phideus principles at the infrastructure level for                ║
║    unprecedented security and adaptability.                                   ║
╚═══════════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    # Validate environment
    validate_required_vars || exit 1
    
    # Check if already in container
    if is_containerized; then
        echo -e "${YELLOW}⚠️  Already running in a container!${NC}"
        echo "This script should be run on the host system."
        exit 1
    fi
    
    # Create all necessary files
    create_platform_structure
    create_container_ansible_config
    create_container_playbooks
    create_dockerfile
    create_kubernetes_manifests
    create_nspawn_config
    create_security_profiles
    
    # Build images
    build_container_images
    
    # Deploy based on mode
    deploy_platform
    
    echo -e "${GREEN}✨ Phideus Immutable Container Platform deployed successfully!${NC}"
    echo ""
    echo "Platform mode: $DEPLOYMENT_MODE"
    echo "Container runtime: $CONTAINER_RUNTIME"
    echo ""
    
    case "$DEPLOYMENT_MODE" in
        "kubernetes")
            echo "Check status with: kubectl get pods -n phideus-system"
            echo "View logs with: kubectl logs -n phideus-system -l app=phideus-operator"
            ;;
        "podman")
            echo "Check status with: podman pod ps"
            echo "View logs with: podman logs phideus-operator-0"
            ;;
        "nspawn")
            echo "Check status with: machinectl list"
            echo "View logs with: journalctl -M phideus-operator-0"
            ;;
    esac
    
    echo ""
    echo -e "${YELLOW}The platform is now self-organizing within immutable containers.${NC}"
    echo -e "${YELLOW}Each operator evolves independently while maintaining system coherence.${NC}"
}

# Execute main function
main "$@"
