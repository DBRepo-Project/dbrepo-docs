---
author: Martin Weise
---

!!! danger "Security Disclaimer"

    This quick default installation should **not be considered secure**. It is intended for local testing and
    demonstration and should not be used in public deployments or in production. It is a quick installation method and
    is intended for a quick look at DBRepo.

## TL;DR

Clone the source code repository and build the container images:

=== "SSH"

    ```shell
    git clone git@github.com:DBRepo-Project/dbrepo.git && \
    cd dbrepo && \
    git checkout release-1.14 && \
    make build-java-lib build-images
    ```

=== "HTTPS"

    ```shell
    git clone https://github.com/DBRepo-Project/dbrepo.git && \
    cd dbrepo && \
    git checkout release-1.14 && \
    make build-java-lib build-images
    ```

Then start DBRepo and visit [`http://localhost`](http://localhost) in the VM browser:

```shell
docker compose up -d
```

## Prerequisites

### Buildtime

!!! info

    * Docker 28+ with Docker Compose v2
    * JDK 21, and Maven running on JDK 21 (newer JDKs fail with `TypeTag :: UNKNOWN` from Lombok)
    * Python 3.11 as `python3`, with `pipenv`
    * [bun](https://bun.sh/), only for `make build-ui`

The build locks the Python dependencies with the `python3` found on your `PATH`. The service images use Python 3.11,
so a different version (e.g. 3.12) can produce a lock file that does not install in the images.

Utility tools to run the build commands:

=== "Debian"

    ```shell
    apt install git make bash openjdk-21-jdk-headless maven
    ```

If several JDKs are installed, point Maven to JDK 21, e.g. on macOS:

```shell
export JAVA_HOME=$(/usr/libexec/java_home -v 21)
```

### Runtime

!!! info

    * min. 8 vCPU cores
    * min. 10GB free RAM memory

## Build

Clone the source code repository:

=== "SSH"

    ```shell
    git clone git@github.com:DBRepo-Project/dbrepo.git && \
    cd dbrepo && \
    git checkout release-1.14
    ```

=== "HTTPS"

    ```shell
    git clone https://github.com/DBRepo-Project/dbrepo.git && \
    cd dbrepo && \
    git checkout release-1.14
    ```

Build the Docker container images and auxiliary files needed for the Auth Service:

```shell
make build-java-lib build-images
```

## Run

Then start DBRepo and visit [`http://localhost`](http://localhost) in the VM browser:

```shell
docker compose up -d
```

!!! debug "Shorthand Dev Build"

    You can build everything and (re-)start the necessary services between each build conveniently:

    ```shell
    make start-dev
    ```