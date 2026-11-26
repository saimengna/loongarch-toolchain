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

# DejaGNU (runtest) drives the GCC/binutils testsuites used by the Tier 2
# gate.  expect/tcl are in AppStream; dejagnu normally needs EPEL, so fall
# back to a source build when the package is unavailable.
RUN dnf -y install expect tcl curl \
 && (dnf -y install epel-release && dnf -y install dejagnu || true) \
 && if ! command -v runtest >/dev/null 2>&1; then \
      curl -fsSL https://ftp.gnu.org/gnu/dejagnu/dejagnu-1.6.1.tar.gz | tar xz -C /tmp \
      && cd /tmp/dejagnu-1.6.1 \
      && ./configure \
      && make -j"$(nproc)" \
      && make install \
      && rm -rf /tmp/dejagnu-1.6.1; \
    fi \
 && runtest --version \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/cache/yum

WORKDIR /work
