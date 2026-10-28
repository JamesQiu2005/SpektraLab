#!/usr/bin/env python3
"""Pinned static Lensfun/GLib build. Python 3.12+, Meson 1.9.2 and Ninja required.

All downloaded archives and reused source files are verified. Meson is forbidden
from fetching dependencies; mutable wrap branches are replaced by fixed commits.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request


def run(args, **kw):
    subprocess.run([str(x) for x in args], check=True, **kw)


def download(pin, target):
    if not target.exists():
        with urllib.request.urlopen(pin['url'], timeout=120) as r:
            target.write_bytes(r.read())
    with target.open('rb') as f:
        if hashlib.file_digest(f, 'sha256').hexdigest() != pin['sha256']:
            raise RuntimeError(f'Checksum mismatch: {target}')


def sources(pin, root):
    suffix = '.tar.xz' if pin['url'].endswith('.xz') else '.tar.gz'
    archive = root / (pin['name'] + suffix)
    download(pin, archive)
    dest = root / pin['name']
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            if not (root / member.name).resolve().is_relative_to(dest.resolve()):
                raise RuntimeError(f'Unexpected archive member: {member.name}')
        if not dest.exists():
            tar.extractall(root, filter='data')
        for member in tar.getmembers():
            if member.isfile():
                target = root / member.name
                with target.open('rb') as actual, tar.extractfile(member) as expected:
                    if hashlib.file_digest(actual,'sha256').digest() != hashlib.file_digest(expected,'sha256').digest():
                        raise RuntimeError(f'Pinned source was modified: {target}')
    return dest


def main():
    p=argparse.ArgumentParser()
    for flag in ('sources','build','install'):
        p.add_argument('--'+flag,type=Path,required=True)
    p.add_argument('--cmake',default='cmake')
    p.add_argument('--generator')
    p.add_argument('--cc');p.add_argument('--cxx');p.add_argument('--make')
    p.add_argument('--toolchain',type=Path)
    p.add_argument('--meson-cross-file',type=Path)
    p.add_argument('--jobs',type=int,default=4)
    a=p.parse_args();here=Path(__file__).resolve().parent
    root=a.sources.resolve();root.mkdir(parents=True,exist_ok=True)
    prefix=a.install.resolve();build=a.build.resolve()
    pins=json.loads((here/'cmake/lens-codecs-pins.json').read_text(encoding='utf-8-sig'))
    lens,glib=[sources(pin,root) for pin in pins['sources']]
    cache=glib/'subprojects/packagecache';cache.mkdir(parents=True,exist_ok=True)
    for pin in pins['wraps']:download(pin,cache/pin['name'])
    git_network=['git']
    # This workaround belongs to Git for Windows on the build host. Linux
    # cross-builds must keep their installed Git TLS backend (often GnuTLS).
    if sys.platform=='win32':git_network+=['-c','http.sslBackend=openssl']
    for pin in pins['git']:
        dest=glib/'subprojects'/pin['name']
        if not dest.exists():
            run(git_network+['clone','--no-checkout',pin['url'],dest])
            run(['git','-C',dest,'checkout','--detach',pin['revision']])
        actual=subprocess.check_output(['git','-C',str(dest),'rev-parse','HEAD'],text=True).strip()
        dirty=subprocess.check_output(['git','-C',str(dest),'status','--porcelain','--untracked-files=no'],text=True).strip()
        if actual!=pin['revision'] or dirty:raise RuntimeError(f'Pinned dependency modified: {dest}')
    env=dict(os.environ)
    if a.cc:env['CC']=a.cc
    if a.cxx:env['CXX']=a.cxx
    meson=[sys.executable,'-m','mesonbuild.mesonmain']
    gb=build/'glib'
    configure=meson+['setup',str(gb),str(glib),'--prefix='+str(prefix),'--libdir=lib',
        '--buildtype=release','--default-library=static','--wrap-mode=nodownload',
        '--force-fallback-for=zlib,libpcre2-8,libffi,intl','-Dtests=false','-Dinstalled_tests=false',
        '-Dnls=disabled','-Dintrospection=disabled','-Dman-pages=disabled','-Ddocumentation=false',
        '-Dsysprof=disabled','-Dlibelf=disabled','-Dlibmount=disabled','-Dselinux=disabled']
    if (gb/'meson-private/coredata.dat').exists():configure.append('--reconfigure')
    if a.meson_cross_file:configure+=['--cross-file',str(a.meson_cross_file.resolve())]
    run(configure,env=env)
    run(meson+['compile','-C',str(gb),'-j',str(max(1,a.jobs))],env=env)
    run(meson+['install','-C',str(gb),'--no-rebuild'],env=env)
    lb=build/'lensfun'
    configure=[a.cmake,'-S',lens.as_posix(),'-B',lb.as_posix(),'-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_INSTALL_PREFIX='+prefix.as_posix(),'-DCMAKE_INSTALL_LIBDIR=lib','-DCMAKE_INSTALL_DATAROOTDIR=share',
        '-DGLIB2_BASE_DIR='+prefix.as_posix(),'-DBUILD_STATIC=ON','-DBUILD_TESTS=OFF','-DBUILD_LENSTOOL=OFF',
        '-DBUILD_DOC=OFF','-DINSTALL_PYTHON_MODULE=OFF','-DINSTALL_HELPER_SCRIPTS=OFF',
        '-DCMAKE_CXX_FLAGS=-DGLIB_STATIC_COMPILATION']
    if a.generator:configure+=['-G',a.generator]
    if a.toolchain:
        configure+=['-DCMAKE_TOOLCHAIN_FILE='+a.toolchain.resolve().as_posix(),
                    '-DCMAKE_FIND_ROOT_PATH='+prefix.as_posix()]
        # Lensfun must discover the GLib just built for the target, never the
        # build host's .pc files (including a developer's PKG_CONFIG_PATH).
        env['PKG_CONFIG_LIBDIR']=(prefix/'lib/pkgconfig').as_posix()
        env['PKG_CONFIG_PATH']=''
    for key,value in (('CMAKE_C_COMPILER',a.cc),('CMAKE_CXX_COMPILER',a.cxx),('CMAKE_MAKE_PROGRAM',a.make)):
        if value:configure.append('-D'+key+'='+value.replace('\\','/'))
    run(configure,env=env)
    run([a.cmake,'--build',lb,'--target','install','--parallel',max(1,a.jobs)],env=env)
    notices=prefix/'share/spektralab-lens';notices.mkdir(parents=True,exist_ok=True)
    for name,file in [('Lensfun-GPL.txt',lens/'COPYING'),('Lensfun-LGPL.txt',lens/'COPYING.LESSER'),
                      ('Lensfun-database-CC-BY-SA-3.0.txt',lens/'data/COPYING.CC_BY-SA_3.0'),
                      ('Lensfun-README.txt',lens/'README.md'),
                      ('libffi-LICENSE.txt',glib/'subprojects/libffi/LICENSE'),
                      ('proxy-libintl-LICENSE.txt',glib/'subprojects/proxy-libintl/COPYING'),
                      ('PCRE2-LICENSE.txt',glib/'subprojects/pcre2-10.44/LICENCE'),
                      ('zlib-LICENSE.txt',glib/'subprojects/zlib-1.3.1/LICENSE')]:
        shutil.copyfile(file,notices/name)
    for file in (glib/'LICENSES').glob('*.txt'):shutil.copyfile(file,notices/('GLib-'+file.name))
    shutil.copyfile(here/'cmake/lens-codecs-pins.json',notices/'lens-codecs-pins.json')
    (notices/'README.txt').write_text('Lensfun library: LGPL-3.0-or-later. Calibration database: CC-BY-SA-3.0.\n'
        'GLib: LGPL-2.1-or-later, with individual source notices in LICENSES.\n'
        'Dependencies and exact source revisions: lens-codecs-pins.json; build with engine/setup-lens-codecs.py.\n',encoding='utf-8')
    print('Pinned lens dependencies, calibration data and notices installed:',prefix)


if __name__=='__main__':main()
