#!/bin/bash
USER=rhel

echo "Adding wheel" > /root/post-run.log
usermod -aG wheel rhel

echo "Setup build host for advanced lab" > /tmp/progress.log
chmod 666 /tmp/progress.log

# Set up libvirt
systemctl enable --now libvirtd
sed -i 's/hosts:\s\+ files/& libvirt libvirt_guest/' /etc/nsswitch.conf

# Set up registry authentication
mkdir -p ~/.config/containers
cat <<EOF> ~/.config/containers/auth.json
{
    "auths": {
      "registry.redhat.io": {
        "auth": "${REGISTRY_PULL_TOKEN}"
      }
    }
  }
EOF

# Pull needed images
BOOTC_RHEL_VER=10.1
podman pull registry.redhat.io/rhel10/rhel-bootc:$BOOTC_RHEL_VER
podman pull registry.redhat.io/rhel10/bootc-image-builder:$BOOTC_RHEL_VER

# Install EPEL
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm

# Generate SSH key
ssh-keygen -t ed25519 -f ~/.ssh/${GUID}key -N '' -C "Lab SSH Key"

# Create config.toml
cat <<EOF> /root/config.toml
[[customizations.user]]
name = "core"
password = "redhat"
groups = ["wheel"]
key = "$(cat ~/.ssh/${GUID}key.pub)"
EOF

# Clone the application repository
git clone --single-branch --branch bootc https://github.com/rhel-labs/python-hostinfo.git /root/bootc-version

# Create the secure baseline directory structure
mkdir -p ~/bootc-base/{etc/sudoers.d,etc/ostree,usr/lib/bootc/kargs.d}
cd ~/bootc-base

# Create baseline Containerfile (secure version from security lab)
cat <<'CONTAINERFILE'> Containerfile
FROM registry.redhat.io/rhel10/rhel-bootc:10.1

RUN dnf -y install pcp-zeroconf rsyslog tmux tuned

RUN dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
RUN sed -e '/^metalink=https:\/\/mirrors.fedoraproject.org\/metalink/ s/^/#/' \
    -e '/^#baseurl=http:/ s/http/https/' \
    -e '/^#baseurl=https:\/\/download.example/ s/^#//' \
    -e '/^baseurl=https:\/\/download.example/ s_https://download.example_https://dl.fedoraproject.org_' \
    -i /etc/yum.repos.d/epel*.repo
RUN dnf -y install btop iftop

COPY etc/ /etc
COPY usr/ /usr

LABEL org.opencontainers.image.authors="sysadmins@example.com"
LABEL vendor="Example Corp"

RUN systemctl mask bootc-fetch-apply-updates.timer

# Security packages
RUN dnf -y install audit fapolicyd openscap-utils scap-security-guide setroubleshoot-server
RUN systemctl enable fapolicyd

# SCAP policy
LABEL profile="CIS Server Level 1 base image"
ENV profileID=cis_server_l1_customized
CONTAINERFILE

# Build the baseline image (for students to build FROM)
podman build --file Containerfile --tag localhost/secure-base

# Wait script for app-vm
cat <<'SCRIPT'> /root/.wait_for_app_vm.sh
#!/bin/bash
echo "Waiting for VM 'app-vm' to be running..."
VM_NAME=app-vm
while true; do
    VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null)
    if [[ "$VM_STATE" == "running" ]]; then
        break
    fi
    sleep 10
done
echo "Waiting for SSH to be available..."
while true; do
    if ping -c 1 -W 1 ${VM_NAME} &>/dev/null; then
        break
    fi
    sleep 5
done
ssh -i ~/.ssh/${GUID}key -o StrictHostKeyChecking=no core@${VM_NAME}
SCRIPT

chmod u+x /root/.wait_for_app_vm.sh

# Export environment variables
echo "export GUID=${GUID}" >> /etc/profile.d/lab.sh
echo "export DOMAIN=${DOMAIN}" >> /etc/profile.d/lab.sh

echo "Advanced lab setup complete" >> /tmp/progress.log
