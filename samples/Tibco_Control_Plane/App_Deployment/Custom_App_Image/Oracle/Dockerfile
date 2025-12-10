FROM alpine:3.19
LABEL maintainer="Cloud Software Group, Inc."

# Set language and locale related variables
# Set LD_LIBRARY_PATH for native libraries
# Update PATH to include required directories
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    LD_LIBRARY_PATH=/opt/oracle/instantclient_21_13 \
    PATH=/opt/oracle/instantclient_21_13:$PATH


# Install dependencies:
# - apache2-utils: required by rotatelogs command in the buildpack script
# - bash: required for running shell scripts
# - ca-certificates: for SSL/TLS support
# - curl: to download Oracle Instant Client
# - gcompat: provides compatibility for glibc applications on Alpine
# - libaio, libnsl: required for Oracle
# - libstdc++: required for C++ applications, including Oracle Instant Client
# - libpq: required for PostgreSQL
# - shadow: to run groupadd and useradd commands
# - unixodbc, unixodbc-dev: required for TDV
# - unzip: to extract supplement zip files
RUN apk add --no-cache apache2-utils bash ca-certificates curl gcompat libaio libnsl libstdc++ shadow unzip && \
    mkdir -p /opt/oracle /home/flogo /app/logs /usr/tp/flogo && \
    groupadd -g 1000 flogo && \
    useradd -u 1000 -g 1000 -s /bin/sh -M flogo

# Download and extract Oracle Instant Client    
WORKDIR /opt/oracle
RUN curl -O https://download.oracle.com/otn_software/linux/instantclient/2113000/instantclient-basic-linux.x64-21.13.0.0.0dbru.zip && \
    unzip instantclient-basic-linux.x64-21.13.0.0.0dbru.zip && \
    rm instantclient-basic-linux.x64-21.13.0.0.0dbru.zip

# Set working directory and copy application files
WORKDIR /usr/tp/flogo
COPY start.sh flogo-oracle ./

# Set permissions and ownership
RUN chown -R flogo:flogo /opt/oracle /home/flogo /app/logs /usr/tp/flogo && \
    chmod +x start.sh flogo-oracle

# Run as non-root user
USER flogo

# Start the application
ENTRYPOINT ["./start.sh"]
