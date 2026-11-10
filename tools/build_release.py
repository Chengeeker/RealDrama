import os
import re
from pathlib import Path
import shutil
import subprocess
import sys

project = Path(__file__).resolve().parents[1]
environment = os.environ.copy()
if not environment.get('JAVA_HOME'):
    raise SystemExit('Set JAVA_HOME to a JDK 17 installation')
java = Path(environment['JAVA_HOME'])
java_temp = project / 'build/java-tmp'
java_temp.mkdir(parents=True, exist_ok=True)
environment['JAVA_TOOL_OPTIONS'] = '-Djava.io.tmpdir=' + java_temp.as_posix() + ' -Djdk.net.unixdomain.tmpdir=' + java_temp.as_posix()
names = ['COMPOSE_BKS', 'COMPOSE_STORE_PASSWORD', 'COMPOSE_KEY_ALIAS', 'COMPOSE_KEY_PASSWORD', 'COMPOSE_BCPROV']
assert all(environment.get(name) for name in names), 'Set the release signing environment variables before building'
keystore = project / 'app/build/signing/compose-release.p12'
properties = project / 'key.properties'
assert not properties.exists() and not keystore.exists(), 'Existing signing files retained; inspect them before replacing'
keystore.parent.mkdir(parents=True, exist_ok=True)
try:
    subprocess.run([str(java / 'bin/keytool.exe'), '-importkeystore', '-noprompt', '-srckeystore', environment['COMPOSE_BKS'], '-srcstoretype', 'BKS', '-providerclass', 'org.bouncycastle.jce.provider.BouncyCastleProvider', '-providerpath', environment['COMPOSE_BCPROV'], '-srcstorepass:env', 'COMPOSE_STORE_PASSWORD', '-srcalias', environment['COMPOSE_KEY_ALIAS'], '-srckeypass:env', 'COMPOSE_KEY_PASSWORD', '-destkeystore', str(keystore), '-deststoretype', 'PKCS12', '-deststorepass:env', 'COMPOSE_STORE_PASSWORD', '-destkeypass:env', 'COMPOSE_STORE_PASSWORD'], env=environment, check=True)
    def escape(value):
        return ''.join('\\' + char if char in '\\:=#! ' else '\\u%04x' % ord(char) if ord(char) > 126 else char for char in value)
    values = dict(storeFile=keystore.as_posix(), storePassword=environment['COMPOSE_STORE_PASSWORD'], keyAlias=environment['COMPOSE_KEY_ALIAS'], keyPassword=environment['COMPOSE_STORE_PASSWORD'])
    properties.write_text(''.join(key + '=' + escape(value) + '\n' for key, value in values.items()), encoding='ascii')
    gradle = [str(project / 'gradlew.bat'), ':app:assembleRelease', ':app:testDebugUnitTest', '--console=plain']
    if '--ui-audit' in sys.argv[1:]:
        gradle.append('-PuiAudit')
    subprocess.run(gradle, cwd=project, env=environment, check=True)
    version = re.search(r'versionName\s*=\s*"([\w.+-]+)"', (project / 'app/build.gradle.kts').read_text(encoding='utf-8')).group(1)
    output = project / f'RealDrama-{version}-arm64-v8a.apk'
    shutil.copy2(project / 'app/build/outputs/apk/release/app-release.apk', output)
    print('APK: ' + str(output))
finally:
    properties.unlink(missing_ok=True)
    keystore.unlink(missing_ok=True)
