#!/bin/bash
# Copyright (C) 2017 SUSE LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

## --->
# Project-specific options and functions. In *theory* you shouldn't need to
# touch anything else in this script in order to use this elsewhere.
project="runc"
root="$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")"

# shellcheck source=./script/lib.sh
source "$root/script/lib.sh"

# This function takes an output path as an argument, where the built
# (preferably static) binary should be placed.
# Parameters:
#   $1 -- destination directory to place build artefacts to.
#   $2 -- native architecture (a .suffix for a native binary file name).
#   $@ -- additional architectures to cross-build for.
function build_project() {
	local libseccomp_version=2.5.2
	local builddir
	builddir="$(dirname "$1")"
	shift
	local native_arch="$1"
	shift
	local arches=("$@")

	# Assume that if /usr/local/src/libseccomp/.env-file exists, then
	# we are run via Dockerfile, and seccomp is already built.
	if [ -r /usr/local/src/libseccomp/.env-file ]; then
		# shellcheck disable=SC1091
		source /usr/local/src/libseccomp/.env-file
		# Copy the source tarball.
		cp /usr/local/src/libseccomp/* "$builddir"
	else
		"$root/script/seccomp.sh" "$libseccomp_version" "$builddir" "./env-file" "${arches[@]}"
		# shellcheck disable=SC1091
		source ./env-file
	fi

	# For reproducible builds, add these to EXTRA_LDFLAGS:
	#  -w to disable DWARF generation;
	#  -s to disable symbol table;
	#  -buildid= to remove variable build id.
	local ldflags="-w -s -buildid="
	# Add -a to go build flags to make sure it links against
	# the provided libseccomp, not the system one (otherwise
	# it can reuse cached pkg-config results).
	local make_args=(COMMIT_NO= EXTRA_FLAGS="-a" EXTRA_LDFLAGS="${ldflags}" static)

	# Build natively.
	make -C "$root" \
		PKG_CONFIG_PATH="${LIBSECCOMP_PREFIX}/lib/pkgconfig" \
		LD_LIBRARY_PATH="${LIBSECCOMP_PREFIX}/lib" \
		"${make_args[@]}"
	strip "$root/$project"
	mv "$root/$project" "$builddir/$project.$native_arch"
	rm -rf "${LIBSECCOMP_PREFIX}"

	# Cross-build for for other architectures.
	local prefix arch
	for arch in "${arches[@]}"; do
		eval prefix=\$"LIBSECCOMP_PREFIX_$arch"
		if [ -z "$prefix" ]; then
			echo "LIBSECCOMP_PREFIX_$arch is empty (unsupported arch?)" >&2
			exit 1
		fi
		set_cross_vars "$arch"
		make -C "$root" \
			PKG_CONFIG_PATH="${prefix}/lib/pkgconfig" "${make_args[@]}"
		"$STRIP" "$root/$project"
		mv "$root/$project" "$builddir/$project.$arch"
		rm -rf "$prefix"
	done
}

# End of the easy-to-configure portion.
## <---

# Print usage information.
function usage() {
	echo "usage: release.sh [-S <gpg-key-id>] [-c <commit-ish>] [-r <release-dir>] [-v <version>] [-a <cross-arch>]" >&2
	exit 1
}

# Log something to stderr.
function log() {
	echo "[*] $*" >&2
}

# Log something to stderr and then exit with 0.
function bail() {
	log "$@"
	exit 0
}

# Conduct a sanity-check to make sure that GPG provided with the given
# arguments can sign something. Inability to sign things is not a fatal error.
function gpg_cansign() {
	gpg "$@" --clear-sign </dev/null >/dev/null
}

# When creating releases we need to build static binaries, an archive of the
# current commit, and generate detached signatures for both.
keyid=""
commit="HEAD"
version=""
releasedir=""
hashcmd=""
declare -a add_arches

while getopts "S:c:r:v:h:a:" opt; do
	case "$opt" in
	S)
		keyid="$OPTARG"
		;;
	c)
		commit="$OPTARG"
		;;
	r)
		releasedir="$OPTARG"
		;;
	v)
		version="$OPTARG"
		;;
	h)
		hashcmd="$OPTARG"
		;;
	a)
		add_arches+=("$OPTARG")
		;;
	:)
		echo "Missing argument: -$OPTARG" >&2
		usage
		;;
	\?)
		echo "Invalid option: -$OPTARG" >&2
		usage
		;;
	esac
done

version="${version:-$(<"$root/VERSION")}"
releasedir="${releasedir:-release/$version}"
hashcmd="${hashcmd:-sha256sum}"
native_arch="$(go env GOARCH || echo "amd64")"
# Suffixes of files to checksum/sign.
suffixes=("$native_arch" "${add_arches[@]}" tar.xz)

log "creating $project release in '$releasedir'"
log "  version: $version"
log "   commit: $commit"
log "      key: ${keyid:-DEFAULT}"
log "     hash: $hashcmd"

# Make explicit what we're doing.
set -x

# Make the release directory.
rm -rf "$releasedir" && mkdir -p "$releasedir"

# Build project.
build_project "$releasedir/$project" "$native_arch" "${add_arches[@]}"

# Generate new archive.
git archive --format=tar --prefix="$project-$version/" "$commit" | xz >"$releasedir/$project.tar.xz"

# Generate sha256 checksums for binaries and libseccomp tarball.
(
	cd "$releasedir"
	# Add $project. prefix to all suffixes.
	"$hashcmd" "${suffixes[@]/#/$project.}" >"$project.$hashcmd"
)

# Set up the gpgflags.
gpgflags=()
[[ "$keyid" ]] && gpgflags=(--default-key "$keyid")
gpg_cansign "${gpgflags[@]}" || bail "Could not find suitable GPG key, skipping signing step."

# Sign everything.
for sfx in "${suffixes[@]}"; do
	gpg "${gpgflags[@]}" --detach-sign --armor "$releasedir/$project.$sfx"
done
gpg "${gpgflags[@]}" --clear-sign --armor \
	--output "$releasedir/$project.$hashcmd"{.tmp,} &&
	mv "$releasedir/$project.$hashcmd"{.tmp,}
