FROM debian:bookworm-slim

ARG TARGETARCH
ARG ZIG_VERSION=0.15.2
ARG GUI_REPO=https://github.com/smithersai/gui.git

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        coreutils \
        curl \
        git \
        libsqlite3-dev \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) zig_arch="x86_64" ;; \
        arm64) zig_arch="aarch64" ;; \
        *) echo "unsupported Docker target arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt; \
    tar -xJf /tmp/zig.tar.xz -C /opt; \
    ln -s "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig; \
    rm /tmp/zig.tar.xz

RUN git clone --depth=1 "${GUI_REPO}" /workspace

COPY . /workspace/libsmithers/fuzz

WORKDIR /workspace/libsmithers/fuzz
ENV LIBSMITHERS_FUZZ_IN_DOCKER=1

RUN chmod +x ./run.sh && zig version && zig build

CMD ["./run.sh", "--short"]
