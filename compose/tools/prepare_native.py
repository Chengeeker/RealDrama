import argparse
import hashlib
import os
from pathlib import Path
import platform
import subprocess
from urllib.request import urlopen
import zipfile

root = Path(__file__).resolve().parents[2]
project = root / 'compose'
parser = argparse.ArgumentParser()
parser.add_argument('--go', default='go')
parser.add_argument('--sdk', default=os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT'))
args = parser.parse_args()
if not args.sdk:
    parser.error('set ANDROID_HOME or pass --sdk')
host = {'Windows': 'windows-x86_64', 'Linux': 'linux-x86_64', 'Darwin': 'darwin-x86_64'}[platform.system()]
suffix = '.cmd' if platform.system() == 'Windows' else ''
compiler = Path(args.sdk) / f'ndk/28.2.13676358/toolchains/llvm/prebuilt/{host}/bin/aarch64-linux-android26-clang{suffix}'
if not compiler.is_file():
    parser.error(f'Android NDK compiler missing: {compiler}')
archive = project / 'build/dependencies/libmpv-v1.1.7-arm64.jar'
digest = '4363dfa5d3d415b91c1f16f6fb90c3fe59a77dfd3f9b824d2b24b492d6b09df9'
if not archive.is_file():
    url = 'https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-arm64-v8a.jar'
    with urlopen(url, timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != digest:
        raise SystemExit('Downloaded libmpv archive failed SHA-256 verification')
    archive.parent.mkdir(parents=True, exist_ok=True)
    archive.write_bytes(data)
if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
    raise SystemExit(f'Cached libmpv archive failed SHA-256 verification: {archive}')
output = project / 'app/src/main/jniLibs/arm64-v8a'
output.mkdir(parents=True, exist_ok=True)
environment = os.environ.copy()
environment.update(GOOS='android', GOARCH='arm64', CGO_ENABLED='1', CC=str(compiler), CGO_LDFLAGS='-Wl,-z,max-page-size=16384')
subprocess.run([args.go, 'build', '-trimpath', '-buildmode=c-shared', '-ldflags=-s -w -X duanjuapp/native/core.buildAllSources=false', '-o', str(output / 'libduanju_core.so'), './bridge'], cwd=root / 'native', env=environment, check=True)
with zipfile.ZipFile(archive) as bundle:
    names = [name for name in bundle.namelist() if name.endswith('.so') and '/arm64-v8a/' in name]
    assert names and any(name.endswith('/libmpv.so') for name in names)
    for name in names:
        (output / Path(name).name).write_bytes(bundle.read(name))
print('Prepared ARM64 Go core and pinned libmpv libraries.')
