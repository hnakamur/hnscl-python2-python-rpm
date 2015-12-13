#!/bin/bash -x
set -eu

# NOTE: Edit project_name and rpm_name.
scl_project_name=hnscl-python2
project_name=${scl_project_name}-python

scl_meta_rpm_name=hn-python2
scl_build_rpm_name=${scl_meta_rpm_name}-build
spec_name=python
rpm_name=${scl_meta_rpm_name}-python
arch=x86_64

spec_file=${spec_name}.spec
base_chroot=epel-7-${arch}
mock_chroot=epel-7-${scl_project_name}-${arch}

usage() {
  cat <<'EOF' 1>&2
Usage: build.sh subcommand

subcommand:
  srpm          build the srpm
  mock          build the rpm locally with mock
  copr          upload the srpm and build the rpm on copr
EOF
}

topdir=`rpm --eval '%{_topdir}'`
topdir_in_chroot=/builddir/build

download_source_files() {
  # NOTE: Edit commands here.
  (cd "${topdir}/SOURCES/" \
    && tarball=Python-${version}.tar.xz \
    && if [ ! -f ${tarball} ]; then curl -sLO http://www.python.org/ftp/python/${version}/${tarball}; fi)
}

download_scl_repo() {
  scl_repo_file=${COPR_USERNAME}-${scl_project_name}-epel-7.repo
  (cd ${topdir} \
    && curl -sLO https://copr.fedoraproject.org/coprs/${COPR_USERNAME}/${scl_project_name}/repo/epel-7/${scl_repo_file})
}

create_mock_chroot_cfg() {
  download_scl_repo

  # Insert ${scl_repo_file} before closing """ of config_opts['yum.conf']
  # See: http://unix.stackexchange.com/a/193513/135274
  #
  # NOTE: Support of adding repository was added to mock,
  #       so you can use it in the future.
  # See: https://github.com/rpm-software-management/ci-dnf-stack/issues/30
  (cd ${topdir} \
    && echo | sed -e '$d;N;P;/\n"""$/i\
' -e '/\n"""$/r '${scl_repo_file} -e '/\n"""$/a\
' -e D /etc/mock/${base_chroot}.cfg - | sudo sh -c "cat > /etc/mock/${mock_chroot}.cfg")
}

build_srpm() {
  version=`rpmspec -P ${topdir}/SPECS/${spec_file} | awk '$1=="Version:" { print $2 }'`
  download_source_files
  create_mock_chroot_cfg
  /usr/bin/mock -r ${mock_chroot} --init
  /usr/bin/mock -r ${mock_chroot} --install scl-utils-build ${scl_build_rpm_name}
  /usr/bin/mock -r ${mock_chroot} --no-clean --buildsrpm --spec "${topdir}/SPECS/${spec_file}" --sources "${topdir}/SOURCES/"
  release=`/usr/bin/mock -r ${mock_chroot} --chroot "rpmspec -P ${topdir_in_chroot}/SPECS/${spec_file}" | awk '$1=="Release:" { print $2 }'`
  rpm_version_release=${version}-${release}
  srpm_file=${rpm_name}-${rpm_version_release}.src.rpm
  mock_result_dir=/var/lib/mock/${base_chroot}/result
  cp ${mock_result_dir}/${srpm_file} ${topdir}/SRPMS/
}

build_rpm_with_mock() {
  build_srpm
  /usr/bin/mock -r ${mock_chroot} --no-clean --rebuild ${topdir}/SRPMS/${srpm_file}

  if [ -n "`find ${mock_result_dir} -maxdepth 1 -name \"${rpm_name}-*${rpm_version_release}.${arch}.rpm\" -print -quit`" ]; then
    mkdir -p ${topdir}/RPMS/${arch}
    cp ${mock_result_dir}/${rpm_name}-*${rpm_version_release}.${arch}.rpm ${topdir}/RPMS/${arch}/
  fi
  if [ -n "`find ${mock_result_dir} -maxdepth 1 -name \"${rpm_name}-*${rpm_version_release}.noarch.rpm\" -print -quit`" ]; then
    mkdir -p ${topdir}/RPMS/noarch
    cp ${mock_result_dir}/${rpm_name}-*${rpm_version_release}.noarch.rpm ${topdir}/RPMS/noarch/
  fi
}

build_rpm_on_copr() {
  build_srpm

  # Check the project is already created on copr.
  status=`curl -s -o /dev/null -w "%{http_code}" https://copr.fedoraproject.org/api/coprs/${COPR_USERNAME}/${project_name}/detail/`
  if [ $status = "404" ]; then
    # Create the project on copr.
    # We call copr APIs with curl to work around the InsecurePlatformWarning problem
    # since system python in CentOS 7 is old.
    # I read the source code of https://pypi.python.org/pypi/copr/1.62.1
    # since the API document at https://copr.fedoraproject.org/api/ is old.
    #
    # NOTE: Edit description here. You may or may not need to edit instructions.
    curl -s -X POST -u "${COPR_LOGIN}:${COPR_TOKEN}" \
      --data-urlencode "name=${project_name}" --data-urlencode "${base_chroot}=y" \
      --data-urlencode "description=[Software collection metapackage for python 2 with the prefix directory /opt/hn" \
      --data-urlencode "instructions=\`\`\`
sudo curl -sL -o /etc/yum.repos.d/${COPR_USERNAME}-${project_name}.repo https://copr.fedoraproject.org/coprs/${COPR_USERNAME}/${project_name}/repo/epel-7/${COPR_USERNAME}-${project_name}-epel-7.repo
\`\`\`

\`\`\`
sudo yum install ${rpm_name}-runtime
\`\`\`" \
      https://copr.fedoraproject.org/api/coprs/${COPR_USERNAME}/new/

    # NOTE: Add scl-utils-build package to chroot.
    # We call "Chroot Modification" API with curl since it is not supported in copr-cli 0.3.0.
    # See "Chroot Modification" at https://copr.fedoraproject.org/api/
    curl -s -X POST -u "${COPR_LOGIN}:${COPR_TOKEN}" -d 'buildroot_pkgs=scl-utils-build' https://copr.fedoraproject.org/api/coprs/${COPR_USERNAME}/${project_name}/modify/${base_chroot}/
  fi

  # Add a new build on copr with uploading a srpm file.
  curl -s -X POST -u "${COPR_LOGIN}:${COPR_TOKEN}" \
    -F "${base_chroot}=y" \
    -F "pkgs=@${topdir}/SRPMS/${srpm_file};type=application/x-rpm" \
    https://copr.fedoraproject.org/api/coprs/${COPR_USERNAME}/${project_name}/new_build_upload/
}

case "${1:-}" in
srpm)
  build_srpm
  ;;
mock)
  build_rpm_with_mock
  ;;
copr)
  build_rpm_on_copr
  ;;
*)
  usage
  ;;
esac
