# syntax=docker/dockerfile:1
# artifacts: true
# platforms: linux/amd64,linux/arm64/v8
# platforms_pr: linux/amd64
# no-cache-filters: prism-base,artifacts,prism
ARG BASE=ubuntu
ARG TAG=22.04
FROM ${BASE}:${TAG} AS prism-base

ENV DEBIAN_FRONTEND=noninteractive

FROM prism-base AS prism-deps

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Copy only the build script first for better layer caching
WORKDIR /build/prism/
COPY --link scripts/linux_build.sh ./scripts/linux_build.sh

# Install dependencies first - this layer will be cached
RUN <<_DEPS
#!/bin/bash
set -e
chmod +x ./scripts/linux_build.sh
./scripts/linux_build.sh \
  --step=deps \
  --ubuntu-test-repo \
  --sudo-off
apt-get clean
rm -rf /var/lib/apt/lists/*
_DEPS

FROM prism-deps AS prism-build

ARG BRANCH
ARG BUILD_VERSION
ARG COMMIT
# note: BUILD_VERSION may be blank

ENV BRANCH=${BRANCH}
ENV BUILD_VERSION=${BUILD_VERSION}
ENV COMMIT=${COMMIT}

# Now copy the full repository
COPY --link .. .

# Configure, validate, build and package
RUN <<_BUILD
#!/bin/bash
set -e
./scripts/linux_build.sh \
  --step=cmake \
  --publisher-name='LizardByte' \
  --publisher-website='https://app.lizardbyte.dev' \
  --publisher-issue-url='https://app.lizardbyte.dev/support' \
  --sudo-off

./scripts/linux_build.sh \
  --step=validation \
  --sudo-off

./scripts/linux_build.sh \
  --step=build \
  --sudo-off

./scripts/linux_build.sh \
  --step=package \
  --sudo-off
_BUILD

# run tests
WORKDIR /build/prism/build/tests
RUN <<_TEST
#!/bin/bash
set -e
export DISPLAY=:1
Xvfb ${DISPLAY} -screen 0 1024x768x24 &
./test_prism --gtest_color=yes
_TEST

FROM prism-base AS prism

ARG BASE
ARG TAG
ARG TARGETARCH

# artifacts to be extracted in CI
COPY --link --from=prism-build /build/prism/build/cpack_artifacts/Prism.deb /artifacts/prism-${BASE}-${TAG}-${TARGETARCH}.deb

# copy deb from builder
COPY --link --from=prism-build /build/prism/build/cpack_artifacts/Prism.deb /prism.deb

# install prism
RUN <<_INSTALL_PRISM
#!/bin/bash
set -e
apt-get update -y
apt-get install -y --no-install-recommends /prism.deb
apt-get clean
rm -rf /var/lib/apt/lists/*
_INSTALL_PRISM

# network setup
EXPOSE 47984-47990/tcp
EXPOSE 48010
EXPOSE 47998-48000/udp

# setup user
ARG PGID=1000
ENV PGID=${PGID}
ARG PUID=1000
ENV PUID=${PUID}
ENV TZ="UTC"
ARG UNAME=lizard
ENV UNAME=${UNAME}

ENV HOME=/home/$UNAME

# setup user
RUN <<_SETUP_USER
#!/bin/bash
set -e
groupadd -f -g "${PGID}" "${UNAME}"
useradd -lm -d ${HOME} -s /bin/bash -g "${PGID}" -u "${PUID}" "${UNAME}"
mkdir -p ${HOME}/.config/prism
ln -s ${HOME}/.config/prism /config
chown -R ${UNAME} ${HOME}
_SETUP_USER

USER ${UNAME}
WORKDIR ${HOME}

# entrypoint
ENTRYPOINT ["/usr/bin/prism"]
