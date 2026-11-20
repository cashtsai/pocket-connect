FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y python3 python3-venv dpkg-dev ca-certificates tmux systemd dbus-user-session curl && rm -rf /var/lib/apt/lists/*
