FROM swift:6.0-noble
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libgtk-4-dev libadwaita-1-dev libwebkitgtk-6.0-dev pkg-config libgstreamer-plugins-bad1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-nice \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav \
    xvfb xauth dbus-x11 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN swift test && swift build -c release
CMD ["dbus-run-session", "--", "xvfb-run", "-a", "./.build/release/overlook", "--native-smoke-test"]
