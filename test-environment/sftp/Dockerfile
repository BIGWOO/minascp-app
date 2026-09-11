FROM alpine:3.22
RUN apk add --no-cache openssh-server && adduser -D -u 1000 tester && passwd -d tester && mkdir -p /home/tester/.ssh /data && chown -R tester:tester /home/tester /data
COPY sshd_config /etc/ssh/sshd_config
CMD ["/bin/sh", "-c", "ssh-keygen -A && chown -R tester:tester /data && exec /usr/sbin/sshd -D -e"]
