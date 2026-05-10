# ------------------------------------------------------------
# Base Image
# ------------------------------------------------------------
FROM ubuntu:22.04

# ------------------------------------------------------------
# Install dependencies
# ------------------------------------------------------------
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl \
        unzip \
        tar \
        gzip \
        libuuid1 \
        openssl \
        procps \
        libc6 \
        libnsl-dev \
        libstdc++6 \
        apache2 \
        net-tools \
        inetutils-ping \
        lsb-release \
        software-properties-common \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------
# Set environment variables for TIBCO libraries
# ------------------------------------------------------------
ENV TIBCO_HOME=/opt/tibco
ENV TIBCO_FTL=$TIBCO_HOME/ftl/7.0
ENV TIBCO_AS=$TIBCO_HOME/as/4.10
ENV LD_LIBRARY_PATH=$TIBCO_AS/lib:$TIBCO_FTL/lib:$TIBCO_AS/lib64:/usr/lib:/lib

# Ensure dynamic linker knows about TIBCO libs
RUN echo "$TIBCO_AS/lib" > /etc/ld.so.conf.d/tibco-as.conf && \
    echo "$TIBCO_AS/lib64" >> /etc/ld.so.conf.d/tibco-as.conf && \
    echo "$TIBCO_FTL/lib" > /etc/ld.so.conf.d/tibco-ftl.conf && \
    ldconfig

# ------------------------------------------------------------
# Download & Install FTL 7.0 (.deb)
# ------------------------------------------------------------
WORKDIR /opt/tibco
RUN curl -O http://reldist.tibco.com/package/ftl/7.0.0/V11-GA/TIB_ftl_7.0.0_linux_x86_64.zip && \
    unzip TIB_ftl_7.0.0_linux_x86_64.zip && \
    rm TIB_ftl_7.0.0_linux_x86_64.zip && \
    dpkg -i TIB_ftl_7.0.0/deb/*.deb || true && \
    rm -rf TIB_ftl_7.0.0

# ------------------------------------------------------------
# Download & Install ActiveSpaces 4.10 (.deb)
# ------------------------------------------------------------
RUN curl -O http://reldist.tibco.com/package/as/4.10.0/V5-GA/TIB_as_4.10.0_linux_x86_64.zip && \
    unzip TIB_as_4.10.0_linux_x86_64.zip && \
    rm TIB_as_4.10.0_linux_x86_64.zip && \
    dpkg -i TIB_as_4.10.0/deb/*.deb || true && \
    rm -rf TIB_as_4.10.0 && \
    ldconfig

# ------------------------------------------------------------
# Copy Flogo app and start script
# ------------------------------------------------------------
WORKDIR /app
COPY activespaceapp /app/activespaceapp
COPY start.sh /app/start.sh
RUN chmod +x /app/activespaceapp /app/start.sh

# ------------------------------------------------------------
# Set entrypoint
# ------------------------------------------------------------
ENTRYPOINT ["/app/start.sh"]

