#!/bin/bash
# ==============================================================================
# CPython Android Ultimate Cross-Compiler
# Features: NDK Sysroot Patching + Termux Native Lib Injection + Disabling Tests
# ==============================================================================
set -euo pipefail

PYTHON_VERSIONS=("3.13" "3.14" "3.15")
API_LEVEL=24
NDK_HOME=${ANDROID_NDK_HOME:-/opt/android-ndk}
TOOLCHAIN="${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"
OUTPUT_DIR="$(pwd)/output"
TERMUX_PREFIX="/data/data/com.termux/files/usr"

TERMUX_CONFIGURE_ARGS=(
    "ac_cv_file__dev_ptmx=yes" "ac_cv_file__dev_ptc=no" "ac_cv_func_wcsftime=no"
    "ac_cv_func_ftime=no" "ac_cv_func_faccessat=no" "ac_cv_func_link=no"
    "ac_cv_func_linkat=no" "ac_cv_buggy_getaddrinfo=no" "ac_cv_little_endian_double=yes"
    "ac_cv_posix_semaphores_enabled=yes" "ac_cv_func_sem_open=yes" "ac_cv_func_sem_timedwait=yes"
    "ac_cv_func_sem_getvalue=yes" "ac_cv_func_sem_unlink=yes" "ac_cv_func_shm_open=yes"
    "ac_cv_func_shm_unlink=yes" "ac_cv_working_tzset=yes" "ac_cv_header_sys_xattr_h=no"
    "ac_cv_func_getgrent=yes" "ac_cv_func_fexecve=no" "ac_cv_func_getlogin_r=no"
    "ac_cv_func_getloadavg=no" "ac_cv_func_sem_clockwait=no"
    "--without-ensurepip" "--enable-loadable-sqlite-extensions"
    "--enable-shared" "--enable-optimizations" "--with-lto" "--with-system-ffi"
    
    # NEW: Highly shrink payload and compile time by skipping internal test modules
    "--disable-test-modules"
)

# ==============================================================================
# 1. APPLY ANDROID NDK / SDK SYSROOT PATCHES
# ==============================================================================
echo "[*] Patching Android NDK/SDK Sysroot..."
NDK_SYSROOT="${TOOLCHAIN}/sysroot"
if [ -d "patches/ndk" ]; then
    for patch_file in patches/ndk/*.patch; do
        [ -f "$patch_file" ] || continue
        echo "   -> Applying NDK patch: $(basename "$patch_file")"
        (cd "${NDK_SYSROOT}" && patch -p1 --forward --fuzz=3 < "$(pwd)/../../${patch_file}" || true)
    done
fi

# ==============================================================================
# 2. DYNAMIC TERMUX APT PARSER
# ==============================================================================
fetch_termux_deps() {
    local arch=$1; local sysroot=$2; local mirror="https://packages-cf.termux.dev/apt/termux-main"
    echo "   [📦] Downloading Official Termux Libs for $arch..."
    mkdir -p "${sysroot}/tmp/apt"
    curl -sL "${mirror}/dists/stable/main/binary-${arch}/Packages" > "${sysroot}/tmp/apt/Packages"
    
    local deps=("openssl" "libffi" "zlib" "sqlite" "readline" "bzip2" "xz-utils" "libandroid-posix-semaphore")
    for pkg in "${deps[@]}"; do
        deb_path=$(grep -A 10 "Package: ${pkg}$" "${sysroot}/tmp/apt/Packages" | grep "Filename:" | head -n 1 | awk '{print $2}')
        if[ -n "$deb_path" ]; then
            curl -sL "${mirror}/${deb_path}" -o "${sysroot}/tmp/apt/${pkg}.deb"
            dpkg-deb -x "${sysroot}/tmp/apt/${pkg}.deb" "${sysroot}"
        fi
    done
}

mkdir -p "${OUTPUT_DIR}"

for version in "${PYTHON_VERSIONS[@]}"; do
    echo -e "\n=================================================="
    echo " 🐍 Processing Python ${version}"
    echo "=================================================="

    src_dir="cpython-${version}"
    branch=$([ "$version" == "3.15" ] && echo "main" || echo "${version}")
    
    if [ ! -d "${src_dir}" ]; then
        git clone --depth 1 --branch "${branch}" https://github.com/python/cpython.git "${src_dir}"
    fi

    # Apply Hybrid CPython Patches
    if[ -d "patches/cpython" ]; then
        for patch_file in patches/cpython/*.patch; do[ -f "$patch_file" ] || continue
            cp "$patch_file" /tmp/current.patch
            sed -i "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" /tmp/current.patch
            sed -i "s|@TERMUX_PKG_API_LEVEL@|${API_LEVEL}|g" /tmp/current.patch
            (cd "${src_dir}" && patch -p1 --forward --fuzz=3 < "/tmp/current.patch" || true)
        done
    fi

    echo "[*] Building Native Python Host Compiler..."
    native_dir="build-${version}-native"
    mkdir -p "${native_dir}"
    (
        cd "${native_dir}"
        ../${src_dir}/configure --prefix="$(pwd)/prefix" > native_config.log 2>&1
        make -j$(nproc) > native_make.log 2>&1
    )

    build_arch() {
        local arch=$1; local triple=$2; local cc_target=$3; local termux_arch=$4
        local build_dir="build-${version}-${arch}"
        local dest="${OUTPUT_DIR}/${version}/${arch}"
        local sysroot="${build_dir}/sysroot"
        
        echo "   [>>>] Starting ${arch}..."
        mkdir -p "${sysroot}" && cd "${build_dir}"

        fetch_termux_deps "${termux_arch}" "${sysroot}"

        export CC="${TOOLCHAIN}/bin/${cc_target}${API_LEVEL}-clang"
        export CXX="${TOOLCHAIN}/bin/${cc_target}${API_LEVEL}-clang++"
        export AR="${TOOLCHAIN}/bin/llvm-ar"
        export RANLIB="${TOOLCHAIN}/bin/llvm-ranlib"
        export STRIP="${TOOLCHAIN}/bin/llvm-strip"
        
        export PKG_CONFIG=""
        export PKG_CONFIG_LIBDIR="${sysroot}${TERMUX_PREFIX}/lib/pkgconfig"
        export CFLAGS="-O3 -fPIC -I${sysroot}${TERMUX_PREFIX}/include"
        export LDFLAGS="-Wl,-O1 -L${sysroot}${TERMUX_PREFIX}/lib -landroid-posix-semaphore"

        ../${src_dir}/configure --host="${triple}" --build=x86_64-linux-gnu \
            --with-build-python="../${native_dir}/python" --prefix="${dest}" \
            "${TERMUX_CONFIGURE_ARGS[@]}" > "configure.log" 2>&1 || exit 1

        make -j$(nproc) > "make.log" 2>&1 || exit 1
        make install > "install.log" 2>&1 || exit 1
        
        find "${dest}/lib" -name "*.so" -exec ${STRIP} --strip-all {} +
        rm -rf "${dest}/lib/python${version}/test" "${dest}/lib/python${version}"/*/test
        
        echo "   [<<<] Thread complete: ${arch}."
    }

    pids=()
    build_arch "arm64-v8a"   "aarch64-linux-android"    "aarch64-linux-android" "aarch64" & pids+=($!)
    build_arch "armeabi-v7a" "armv7a-linux-androideabi" "armv7a-linux-androideabi" "arm" & pids+=($!)
    build_arch "x86_64"      "x86_64-linux-android"     "x86_64-linux-android" "x86_64" & pids+=($!)
    build_arch "x86"         "i686-linux-android"       "i686-linux-android" "i686" & pids+=($!)

    for pid in "${pids[@]}"; do wait "$pid"; done
    echo "[✔] Finished Python ${version}."
done
