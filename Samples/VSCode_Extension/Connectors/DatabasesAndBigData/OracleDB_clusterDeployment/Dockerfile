FROM alpine:latest

# Install necessary dependencies
RUN apk add --no-cache ca-certificates libaio bash curl unzip \
    && mkdir -p /opt/oracle \
    && apk add gcompat

# Download and install Oracle Instant Client
WORKDIR /opt/oracle
RUN curl -O https://download.oracle.com/otn_software/linux/instantclient/2113000/instantclient-basic-linux.x64-21.13.0.0.0dbru.zip \
    && unzip instantclient-basic-linux.x64-21.13.0.0.0dbru.zip \
    && rm instantclient-basic-linux.x64-21.13.0.0.0dbru.zip

# Set up environment variables
ENV LD_LIBRARY_PATH="/opt/oracle/instantclient_21_13"
ENV PATH="/opt/oracle/instantclient_21_13:$PATH"


# Set working directory and add Flogo app
WORKDIR /app

ADD oracleapp /app/flogoapp

# Set entrypoint
CMD ["/app/flogoapp"]