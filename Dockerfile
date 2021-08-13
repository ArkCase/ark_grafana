#
# This one houses the main git clone
#
FROM 345280441424.dkr.ecr.ap-south-1.amazonaws.com/ark_base:latest as src

#
# Basic Parameters
#
ARG ARCH="amd64"
ARG OS="linux"
ARG VER="8.1.1"
ARG PKG="grafana"
ARG SRC="https://github.com/grafana/grafana.git"

#
# Some important labels
#
LABEL ORG="Armedia LLC"
LABEL MAINTAINER="Armedia Devops Team <devops@armedia.com>"
LABEL APP="Grafana"
LABEL VERSION="${VER}"

WORKDIR /src

#
# Download the primary artifact
#
RUN yum -y update && yum -y install git && git clone -b "v${VER}" --single-branch "${SRC}" "/src"

#
# This one builds the JS artifacts
#
FROM 345280441424.dkr.ecr.ap-south-1.amazonaws.com/ark_base:latest as js-builder

#
# Basic Parameters
#
ARG ARCH="amd64"
ARG OS="linux"
ARG VER="8.1.1"
ARG PKG="grafana"
ARG NODE_SRC="https://rpm.nodesource.com/setup_16.x"

#
# Some important labels
#
LABEL ORG="Armedia LLC"
LABEL MAINTAINER="Armedia Devops Team <devops@armedia.com>"
LABEL APP="Grafana"
LABEL VERSION="${VER}"

WORKDIR /usr/src/app/

#
# Install NodeJS and Yarn
#
RUN curl --silent --location https://dl.yarnpkg.com/rpm/yarn.repo | tee /etc/yum.repos.d/yarn.repo
RUN rpm --import https://dl.yarnpkg.com/rpm/pubkey.gpg
RUN curl --silent --location "${NODE_SRC}" | bash -
RUN yum -y update && yum -y install nodejs git yarn

#
# Copy the base files for the build
#
COPY --from=src /src/package.json /src/yarn.lock ./
COPY --from=src /src/packages packages
RUN yarn install --pure-lockfile --no-progress

#
# Pull in more artifacts for the build
#
COPY --from=src /src/tsconfig.json /src/.eslintrc /src/.editorconfig /src/.browserslistrc /src/.prettierrc.js ./
COPY --from=src /src/public public
COPY --from=src /src/tools tools
COPY --from=src /src/scripts scripts
COPY --from=src /src/emails emails

#
# Run the build
#
ENV NODE_ENV="production"
RUN yarn build

#
# This one builds the Go artifacts
#
FROM 345280441424.dkr.ecr.ap-south-1.amazonaws.com/ark_base:latest as go-builder

#
# Basic Parameters
#
ARG ARCH="amd64"
ARG OS="linux"
ARG VER="8.1.1"
ARG PKG="grafana"
ARG GO_VER="1.16.7"
ARG GO_SRC="https://golang.org/dl/go${GO_VER}.${OS}-${ARCH}.tar.gz"

#
# Some important labels
#
LABEL ORG="Armedia LLC"
LABEL MAINTAINER="Armedia Devops Team <devops@armedia.com>"
LABEL APP="Grafana"
LABEL VERSION="${VER}"

#
# Set the Go environment
#
ENV GOROOT="/usr/local/go"
ENV GOPATH="/go"
ENV PATH="${PATH}:${GOROOT}/bin"

WORKDIR "${GOROOT}"

#
# Download and install go and GCC (needed for compilation/linking)
#
RUN curl -L "${GO_SRC}" -o - | tar -C "/usr/local" -xzf -
RUN yum -y update && yum -y install gcc g++

WORKDIR "${GOPATH}/src/github.com/grafana/grafana"

#
# Pull in more artifacts for the build
#
COPY --from=src /src/go.mod /src/go.sum /src/embed.go ./
COPY --from=src /src/cue cue
COPY --from=src /src/public/app/plugins public/app/plugins
COPY --from=src /src/pkg pkg
COPY --from=src /src/build.go /src/package.json ./

#
# Run the build
#
RUN go mod verify
RUN go run build.go build

#
# The actual runnable container
#
FROM 345280441424.dkr.ecr.ap-south-1.amazonaws.com/ark_base:latest

#
# Basic Parameters
#
ARG ARCH="amd64"
ARG OS="linux"
ARG VER="8.1.1"
ARG PKG="grafana"
ARG UID="grafana"

#
# Some important labels
#
LABEL ORG="Armedia LLC"
LABEL MAINTAINER="Armedia Devops Team <devops@armedia.com>"
LABEL APP="Grafana"
LABEL VERSION="${VER}"
LABEL IMAGE_SOURCE="https://github.com/ArkCase/ark_grafana"

#
# Create the required user
#
RUN useradd --system --user-group "${UID}"

#
# Define some important environment variables
#
ENV GF_PATHS_LOGS="/var/log/grafana"
# Data Directories
ENV GF_PATHS_DATA="/var/lib/grafana"
ENV GF_PATHS_PLUGINS="${GF_PATHS_DATA}/plugins"
# Configuration Directories
ENV GF_PATHS_ETC="/etc/grafana"
ENV GF_PATHS_PROVISIONING="${GF_PATHS_ETC}/provisioning"
ENV GF_PATHS_CONFIG="${GF_PATHS_ETC}/grafana.ini"
# Application Base Directory
ENV GF_PATHS_HOME="/usr/share/grafana"
# Running Path
ENV PATH="${GF_PATHS_HOME}/bin:${PATH}"

#
# Create and use the work directory
#
RUN mkdir -p "${GF_PATHS_HOME}"
WORKDIR "${GF_PATHS_HOME}"

#
# Pull in some artifacts from the source image
#
COPY --from=src /src/conf ./conf
COPY --from=src /src/packaging/docker/run.sh /run.sh

#
# Update and install required packages
#
RUN yum -y update && yum -y install openssl tzdata && yum -y clean all

RUN mkdir -p \
        "${GF_PATHS_HOME}/.aws" \
        "${GF_PATHS_PROVISIONING}/datasources" \
        "${GF_PATHS_PROVISIONING}/dashboards" \
        "${GF_PATHS_PROVISIONING}/notifiers" \
        "${GF_PATHS_PROVISIONING}/plugins" \
        "${GF_PATHS_PROVISIONING}/access-control" \
        "${GF_PATHS_LOGS}" \
        "${GF_PATHS_PLUGINS}" \
        "${GF_PATHS_DATA}" && \
    cp "${GF_PATHS_HOME}/conf/sample.ini" "${GF_PATHS_CONFIG}" && \
    cp "${GF_PATHS_HOME}/conf/ldap.toml"  "${GF_PATHS_ETC}/ldap.toml" && \
    chown -R "${UID}:" \
        "${GF_PATHS_DATA}" \
        "${GF_PATHS_HOME}/.aws" \
        "${GF_PATHS_LOGS}" \
        "${GF_PATHS_PLUGINS}" \
        "${GF_PATHS_PROVISIONING}" && \
    chmod -R ug+rwX,o-rwx \
        "${GF_PATHS_DATA}" \
        "${GF_PATHS_HOME}/.aws" \
        "${GF_PATHS_LOGS}" \
        "${GF_PATHS_PLUGINS}" \
        "${GF_PATHS_PROVISIONING}"

#
# Pull the built artifacts over from the other images
#
COPY --from=go-builder /go/src/github.com/grafana/grafana/bin/*/grafana-server /go/src/github.com/grafana/grafana/bin/*/grafana-cli ./bin/
COPY --from=js-builder /usr/src/app/public ./public
COPY --from=js-builder /usr/src/app/tools ./tools

#
# Final parameters
#
USER        ${UID}
EXPOSE      3000
VOLUME      [ "/var/lib/grafana" ]
WORKDIR     /app/data
ENTRYPOINT  [ "/run.sh" ]
