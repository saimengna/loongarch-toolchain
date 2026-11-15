ARG BASE_IMAGE=quay.io/pypa/manylinux_2_28_x86_64
FROM ${BASE_IMAGE}

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1

# manylinux_2_28 is based on a distribution with glibc 2.28.  Do not replace
# this base with a normal Ubuntu image: the point of this image is to make the
# compiler binaries run on hosts with glibc 2.28 or newer.
RUN dnf -y install \
        autoconf \
        automake \
        binutils \
        bison \
        bzip2 \
        cmake \
        diffutils \
        expat-devel \
        file \
        findutils \
        flex \
        gawk \
        gcc \
        gcc-c++ \
        gperf \
        git \
        gmp-devel \
        libmpc-devel \
        libtool \
        make \
        mpfr-devel \
        ncurses-devel \
        patch \
        perl \
        python3 \
        python3-devel \
        sed \
        tar \
        texinfo \
        which \
        xz \
        zlib-devel \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/cache/yum

WORKDIR /work
