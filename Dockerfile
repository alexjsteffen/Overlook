# syntax=docker/dockerfile:1
# Build from the repository root. The default target runs the native smoke test;
# `make docker` uses the export target to copy only the release executable.
FROM swift:6.0-noble AS build

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libgtk-4-dev libadwaita-1-dev libsecret-1-dev libwebkitgtk-6.0-dev pkg-config \
    libgstreamer-plugins-bad1.0-dev libgstreamer-plugins-base1.0-dev \
    gstreamer1.0-nice gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-libav xvfb xauth dbus-x11 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src/Linux
COPY Linux/ .
RUN swift test && swift build -c release --static-swift-stdlib

# BuildKit local-output stage used by `make docker`.
FROM scratch AS export
COPY --from=build /src/Linux/.build/release/overlook /overlook

# Keep the smoke-test image as the default when running `docker build` directly.
FROM build AS test
CMD ["dbus-run-session", "--", "xvfb-run", "-a", "./.build/release/overlook", "--native-smoke-test"]
