FROM openjdk:18.0-jdk-oraclelinux7

WORKDIR /minecraft
USER root

RUN adduser minecraft
RUN yum update -y
RUN yum install wget -y
RUN chown -R minecraft:minecraft /minecraft

COPY custom_start.sh .
RUN chmod u+x custom_start.sh

USER minecraft

ARG MODPACK_ID=95
ARG MODPACK_VERSION=2234
ENV BASE_URL="https://api.modpacks.ch/public/modpack" \
    SERVER_FILE="ftb_server" \
    SERVER_PORT=25565

RUN mkdir -p /minecraft/world && echo ${BASE_URL} && \
    wget -O ${SERVER_FILE} ${BASE_URL}/${MODPACK_ID}/${MODPACK_VERSION}/server/linux && \
    chmod u+x ${SERVER_FILE}

RUN ./${SERVER_FILE} ${MODPACK_ID} ${MODPACK_VERSION} --auto

EXPOSE ${SERVER_PORT}
VOLUME ["/minecraft/world", "/minecraft/backups"]
CMD ["/bin/sh", "/minecraft/custom_start.sh"]