#!/bin/sh
set -eu

version=2.39.0
archive_name="git-${version}.tar.xz"
archive_sha256=ba199b13fb5a99ca3dec917b0bd736bc0eb5a9df87737d435eddfdf10d69265b
source_url="https://mirrors.edge.kernel.org/pub/software/scm/git/${archive_name}"

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: scripts/install_git_minimum.sh <absolute-prefix>" >&2
  exit 64
fi

prefix=$1
case "$prefix" in
  /*) ;;
  *)
    echo "Git installation prefix must be absolute" >&2
    exit 64
    ;;
esac

if [ -x "$prefix/bin/git" ]; then
  installed_version=$("$prefix/bin/git" --version)
  if [ "$installed_version" = "git version ${version}" ]; then
    echo "Git ${version} is already installed at the requested prefix."
    exit 0
  fi

  echo "Refusing to replace a different Git installation at $prefix" >&2
  exit 73
fi

if [ -e "$prefix" ]; then
  echo "Refusing to replace an existing path at $prefix" >&2
  exit 73
fi

build_root=$(mktemp -d "${TMPDIR:-/tmp}/twelvgaige-git-minimum.XXXXXX")
case "$build_root" in
  "${TMPDIR:-/tmp}"/twelvgaige-git-minimum.*) ;;
  *)
    echo "Temporary Git build root was not created under the expected directory" >&2
    exit 70
    ;;
esac

cleanup() {
  rm -rf "$build_root"
}
trap cleanup EXIT HUP INT TERM

archive="$build_root/$archive_name"
curl --fail --location --retry 3 --output "$archive" "$source_url"

if command -v sha256sum >/dev/null 2>&1; then
  observed_sha256=$(sha256sum "$archive" | awk '{print $1}')
else
  observed_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
fi

if [ "$observed_sha256" != "$archive_sha256" ]; then
  echo "Git source checksum mismatch" >&2
  exit 65
fi

tar -C "$build_root" -xf "$archive"
source_root="$build_root/git-${version}"

make -C "$source_root" -j2 \
  prefix="$prefix" \
  NO_CURL=YesPlease \
  NO_EXPAT=YesPlease \
  NO_GETTEXT=YesPlease \
  NO_OPENSSL=YesPlease \
  NO_PERL=YesPlease \
  NO_PYTHON=YesPlease \
  NO_TCLTK=YesPlease

make -C "$source_root" install \
  prefix="$prefix" \
  NO_CURL=YesPlease \
  NO_EXPAT=YesPlease \
  NO_GETTEXT=YesPlease \
  NO_OPENSSL=YesPlease \
  NO_PERL=YesPlease \
  NO_PYTHON=YesPlease \
  NO_TCLTK=YesPlease

if [ "$("$prefix/bin/git" --version)" != "git version ${version}" ]; then
  echo "Installed Git version did not match ${version}" >&2
  exit 70
fi

echo "Installed Git ${version} at $prefix"
