FROM quay.io/almalinuxorg/almalinux-bootc:10

# Set to 0 to build a test variant with no application quadlets enabled.
# Tailscale and the base system services remain enabled either way, which
# lets the networking be tested in isolation.
ARG ENABLE_QUADLETS=1

COPY root/ /

RUN dnf install -y epel-release && \
    dnf config-manager --set-enabled crb && \
    dnf install -y \
        btop \
        htop \
        jq \
        tar \
    && dnf clean all

RUN useradd --create-home --groups wheel jono && \
    chmod 0440 /etc/sudoers.d/jono && \
    chmod 0755 /usr/local/sbin/randomize-passwords.sh && \
    systemctl enable randomize-passwords.service

RUN chmod 0755 /usr/local/sbin/show-host-key.sh && \
    systemctl enable show-host-key.service

COPY vendor/bootc-secrets/install /tmp/bootc-secrets-install
RUN /tmp/bootc-secrets-install/install.sh && rm -rf /tmp/bootc-secrets-install

RUN mkdir -p /etc/bootc-secrets && \
    printf 'SECRETS_BASE_URL=https://secrets.jonohill.nz\n' > /etc/bootc-secrets/config.env

RUN dnf install -y tailscale && dnf clean all && \
    systemctl enable tailscaled.service tailscale-up.service

# configure bootc for logically bound images
# (enables downloading on update of host image)
RUN mkdir -p /usr/lib/bootc/bound-images.d && \
    find /usr/share/containers/systemd \
        \( -name '*.container' -o -name '*.image' \) \
        -exec ln -sf -t /usr/lib/bootc/bound-images.d {} +

# data volume
RUN systemctl enable var-mnt-data.mount

# daily updates at 3am, reboot if needed
RUN systemctl enable bootc-fetch-apply-updates.timer

RUN dnf install -y greenboot && dnf clean all && \
    chmod 0755 /etc/greenboot/check/required.d/*.sh && \
    systemctl enable greenboot-healthcheck.service

# Test variant: strip the application quadlets (and their bound-image links)
# so nothing but the base system + tailscale starts. Run last so all layers
# above are shared with the normal image.
RUN if [ "$ENABLE_QUADLETS" != "1" ]; then \
        rm -rf /usr/share/containers/systemd/* /usr/lib/bootc/bound-images.d/*; \
    fi
