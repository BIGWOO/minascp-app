FROM alpine:3.22
RUN apk add --no-cache openssh-server python3 zip unzip tar coreutils && adduser -D -u 1000 tester && passwd -d tester && mkdir -p /data && chown tester:tester /data
COPY sshd_config /etc/ssh/sshd_config
CMD ["/bin/sh", "-c", "test -f /hostkeys/ssh_host_ed25519_key || ssh-keygen -q -t ed25519 -N '' -f /hostkeys/ssh_host_ed25519_key; chown -R tester:tester /data; exec /usr/sbin/sshd -D -e"]
