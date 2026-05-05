#!/usr/bin/env bash
# ==============================================================================
# CPython Android Ultimate Cross-Compiler
# Source: Direct FTP URLs | Targets: 3.13.13, 3.14.5rc1, 3.15.0a8
# ==============================================================================
set -euo pipefail

# Specific URLs provided
PYTHON_URLS=(
    "https://www.python.org/ftp/python/3.13.13/Python-3.13.13.tar.xz"
    "https://www.python.org/ftp/python/3.14.5/Python-3.14.5rc1.tar.xz"
    "https://www.python.org/ftp/python/3.15.0/Python-3.15.0a8.tar.xz"
)

API_LEVEL=24
NDK_HOME="${ANDROID_NDK_HOME:-/opt/android-ndk}"
TOOLCHAIN="${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"

WORKSPACE_DIR="$(pwd)"
OUTPUT_DIR="${WORKSPACE_DIR}/output"
TERMUX_PREFIX="/data/data/com.termux/files/usr"

# Base configuration arguments
TERMUX_CONFIGURE_ARGS=(
    "ac_cv_file__dev_ptmx=yes" "ac_cv_file__dev_ptc=no" "ac_cv_func_wcsftime=no"
    "ac_cv_func_ftime=no" "ac_cv_func_faccessat=no" "ac_cv_func_link=no"
    "ac_cv_func_linkat=no" "ac_cv_buggy_getaddrinfo=no" "ac_cv_little_endian_double=yes"
    "ac_cv_posix_semaphores_enabled=yes" "ac_cv_func_sem_open=yes" "ac_cv_func_sem_timedwait=yes"
    "ac_cv_func_sem_getvalue=yes" "ac_cv_func_sem_unlink=yes" "ac_cv_func_shm_open=yes"
    "ac_cv_func_shm_unlink=yes" "ac_cv_working_tzset=yes" "ac_cv_header_sys_xattr_h=no"
    "ac_cv_func_getgrent=yes"
    "--without-ensurepip" "--enable-loadable-sqlite-extensions"
    "--enable-shared" "--enable-optimizations" "--with-lto" 
    "--with-system-ffi" "--with-system-expat" "--disable-test-modules"
)

# Apply dynamic constraints based on API Level
if [ "${API_LEVEL}" -lt 28 ]; then
    TERMUX_CONFIGURE_ARGS+=("ac_cv_func_fexecve=no" "ac_cv_func_getlogin_r=no")
fi
if [ "${API_LEVEL}" -lt 30 ]; then
    TERMUX_CONFIGURE_ARGS+=("ac_cv_func_sem_clockwait=no")
fi

# 1. NDK SYSROOT POLYFILLS
echo "[*] Injecting Android NDK/SDK Sysroot Polyfills..."
NDK_SYSROOT="${TOOLCHAIN}/sysroot"

if ! grep -q "getgrent" "${NDK_SYSROOT}/usr/include/grp.h"; then
    sed -i 's/__END_DECLS/\/* NDK Polyfill *\/\nstatic __inline__ struct group* getgrent(void) { return 0; }\nstatic __inline__ void setgrent(void) {}\nstatic __inline__ void endgrent(void) {}\n\n__END_DECLS/g' "${NDK_SYSROOT}/usr/include/grp.h"
fi
if ! grep -q "_NL_ITEM" "${NDK_SYSROOT}/usr/include/langinfo.h"; then
    sed -i 's/__BEGIN_DECLS/__BEGIN_DECLS\n\n#ifndef _NL_ITEM\ntypedef int _NL_ITEM;\n#endif\n/g' "${NDK_SYSROOT}/usr/include/langinfo.h"
fi

# 2. TERMUX APT PARSER
fetch_termux_deps() {
    local arch="$1"; local sysroot="$2"; local mirror="https://packages-cf.termux.dev/apt/termux-main"
    echo "   [📦] Fetching Official Termux Libs for ${arch}..."
    mkdir -p "${sysroot}/tmp/apt"
    curl -sL "${mirror}/dists/stable/main/binary-${arch}/Packages" > "${sysroot}/tmp/apt/Packages"
    local deps=("gdbm" "libandroid-posix-semaphore" "libandroid-support" "libbz2" "libcrypt" "libexpat" "libffi" "liblzma" "libsqlite" "ncurses" "ncurses-ui-libs" "openssl" "readline" "zlib" "tk")
    for pkg in "${deps[@]}"; do
        deb_path=$(grep -A 10 "^Package: ${pkg}$" "${sysroot}/tmp/apt/Packages" | grep "^Filename:" | head -n 1 | awk '{print $2}')
        if [ -n "${deb_path}" ]; then
            curl -sL "${mirror}/${deb_path}" -o "${sysroot}/tmp/apt/${pkg}.deb"
            dpkg-deb -x "${sysroot}/tmp/apt/${pkg}.deb" "${sysroot}"
        fi
    done
}

mkdir -p "${OUTPUT_DIR}"

for url in "${PYTHON_URLS[@]}"; do
    filename=$(basename "${url}")
    src_dir="${filename%.tar.xz}"
    ver=$(echo "${src_dir}" | cut -d- -f2)

    echo -e "\n=================================================="
    echo " 🐍 Processing Python ${ver}"
    echo "=================================================="

    if [ ! -d "${src_dir}" ]; then
        echo "[*] Downloading: ${filename}"
        wget -q "${url}"
        tar -xf "${filename}"
    fi

    if [ -d "patches/cpython" ]; then
        for patch_file in patches/cpython/*.patch; do
            if [ -f "${patch_file}" ]; then
                echo "   -> Applying Patch: $(basename "${patch_file}")"
                cp "${patch_file}" /tmp/current.patch
                sed -i "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" /tmp/current.patch
                sed -i "s|@TERMUX_PKG_API_LEVEL@|${API_LEVEL}|g" /tmp/current.patch
                (cd "${src_dir}" && patch -p1 --forward --fuzz=3 < "/tmp/current.patch" || true)
            fi
        done
    fi

    echo "[*] Building Native Python Host..."
    native_dir="build-${ver}-native"
    mkdir -p "${native_dir}"
    (
        cd "${native_dir}"
        ../"${src_dir}"/configure --prefix=
