from __future__ import annotations

import json
import os
import sys

from copy import deepcopy
from enum import Enum
from typing import (Any,
                    Dict,
                    List,
                    Optional,
                    Tuple)


class ConfigStage(Enum):
    BUILD_SDIST = 1
    BUILD_WHEEL = 2
    VALIDATE_WHEEL = 3


class SdkProject(Enum):
    Columnar = 'PYCBCC'
    Operational = 'PYCBC'

    @classmethod
    def from_env(cls, env_key: Optional[str] = 'CBCI_PROJECT_TYPE') -> SdkProject:
        env = get_env_variable(env_key)
        if env.upper() in ['COLUMNAR', 'PYCBCC']:
            return SdkProject.Columnar
        if env.upper() in ['OPERATIONAL', 'PYCBC']:
            return SdkProject.Operational
        else:
            print(f'Invalid SDK project: {env}')
            sys.exit(1)


# TODO: TypeDict? or maybe Dict[str, dataclass]; more config options
DEFAULT_CONFIG = {
    'USE_OPENSSL': {
        'default': 'OFF',
        'description': 'Use OpenSSL instead of boringssl',
        'required': True,
        'sdk_alias': 'SDKPROJECT_USE_OPENSSL'
    },
    'OPENSSL_VERSION': {
        'default': None,
        'description': 'The version of OpenSSL to use instead of boringssl',
        'required': False,
        'sdk_alias': 'SDKPROJECT_OPENSSL_VERSION'
    },
    'SET_CPM_CACHE': {
        'default': 'ON',
        'description': 'Initialize the C++ core CPM cache',
        'required': False,
        'sdk_alias': 'SDKPROJECT_SET_CPM_CACHE'
    },
    'USE_LIMITED_API': {
        'default': None,
        'description': 'Set to enable use of Py_LIMITED_API',
        'required': False,
        'sdk_alias': 'SDKPROJECT_LIMITED_API'
    },
    'VERBOSE_MAKEFILE': {
        'default': None,
        'description': 'Use verbose logging when configuring/building',
        'required': False,
        'sdk_alias': 'SDKPROJECT_VERBOSE_MAKEFILE'
    },
    'BUILD_TYPE': {
        'default': 'RelWithDebInfo',
        'description': 'Sets the build type when configuring/building',
        'required': False,
        'sdk_alias': 'SDKPROJECT_BUILD_TYPE'
    },
    'CB_CACHE_OPTION': {
        'default': None,
        'description': 'Sets the builds ccache option',
        'required': False,
        'sdk_alias': 'SDKPROJECT_CB_CACHE_OPTION'
    },
}

STAGE_MATRIX_KEYS = ['python-versions', 'python_versions', 'arches', 'platforms']


def get_env_variable(key: str, quiet: Optional[bool] = False) -> str:
    try:
        return os.environ[key]
    except KeyError:
        if not quiet:
            print(f'Environment variable {key} not set.')
            sys.exit(1)
    except Exception as e:
        if not quiet:
            print(f'Error getting environment variable {key}: {e}')
            sys.exit(1)
    return None

def build_default_config(stage: ConfigStage, project: SdkProject) -> dict:
    config = deepcopy(DEFAULT_CONFIG)
    if stage == ConfigStage.BUILD_SDIST:
        config['SET_CPM_CACHE']['required'] = True
    elif stage == ConfigStage.BUILD_WHEEL:
        config['BUILD_TYPE']['required'] = True
        prefer_ccache = get_env_variable('PREFER_CCACHE', quiet=True)
        if prefer_ccache:
            config['CB_CACHE_OPTION']['required'] = True
            config['CB_CACHE_OPTION']['default'] = 'ccache'
            config['CCACHE_DIR'] = {'required': True, 'default': prefer_ccache, 'sdk_alias': 'CCACHE_DIR'}
        prefer_verbose = get_env_variable('PREFER_VERBOSE_MAKEFILE', quiet=True)
        if prefer_verbose:
            config['VERBOSE_MAKEFILE']['required'] = True
            config['VERBOSE_MAKEFILE']['default'] = 'ON'

    for v in config.values():
        v['sdk_alias'] = v['sdk_alias'].replace('SDKPROJECT', project.value)

    return config


def user_config_as_json(config_key: str) -> Dict[str, Any]:
    config_str = get_env_variable(config_key, quiet=True)
    config = {}
    if config_str:
        # for GHA linux, we pass the JSON config as a string into the docker container
        if config_str.startswith('"'):
            config_str = config_str[1:-1]
        try:    
            config = json.loads(config_str)
        except Exception as e:
            print(f'Invalid JSON: {e}')
            sys.exit(1)

    return config


def get_supported_python_versions() -> List[str]:
    return get_env_variable('CBCI_SUPPORTED_PYTHON_VERSIONS').split()


def get_supported_architectures() -> List[str]:
    return ['x86_64', 'arm64', 'aarch64']


def get_supported_platforms(arch: str) -> List[str]:
    if arch == 'x86_64':
        return get_env_variable('CBCI_SUPPORTED_X86_64_PLATFORMS').split()
    elif arch in ['arm64', 'aarch64']:
        return get_env_variable('CBCI_SUPPORTED_ARM64_PLATFORMS').split()
    else:
        print(f'Unsupported architecture: {arch}')
        return []


def is_supported_python_version(version: str) -> bool:
    version_tokens = version.split('.')
    # shouldn't happen, but in case, we only support Python 3.x
    if len(version_tokens) == 1:
        return version_tokens[0] == '3'
    if len(version_tokens) == 2:
        return version in get_supported_python_versions()
    if len(version_tokens) == 3:
        return '.'.join(version_tokens[:2]) in get_supported_python_versions()

    return False


def set_python_versions(user_config: str) -> List[str]:
    versions = []
    try:
        user_python_versions = user_config.replace(',', ' ').split()
        for version in user_python_versions:
            if not is_supported_python_version(version):
                print(f'Unsupported Python version: {version}. Ignoring.')
                continue
            versions.append(version)

    except Exception as e:
        print(f'Unable to parse user provided Python versions: {e}. Ignoring.')

    return versions


def set_os_and_arch(user_platforms: str, user_arches: str) -> Tuple[List[str], List[str]]:
    arches = []
    try:
        arches = list(map(lambda a: a.strip().lower(), user_arches.replace(',', ' ').split()))
        for arch in arches:
            if arch not in get_supported_architectures():
                print(f'Unsupported architecture: {arch}. Ignoring.')
                arches.remove(arch)
    except Exception as e:
        print(f'Unable to parse user provided arches: {e}. Ignoring.')

    if not arches:
        arches = get_supported_architectures()[:-1]

    if 'arm64' in arches and 'aarch64' in arches:
        # we don't need both arm64 and aarch64
        arches.remove('aarch64')

    x86_64_platforms = []
    if 'x86_64' in arches:
        try:
            platforms = list(map(lambda p: p.strip().lower(), user_platforms.replace(',', ' ').split()))
            for platform in platforms:
                if platform not in get_supported_platforms(arch):
                    print(f'Unsupported x86_64 platform: {platform}. Ignoring.')
                    continue
                x86_64_platforms.append(platform)
        except Exception as e:
            print(f'Unable to parse user provided arches: {e}. Ignoring.')

        if not x86_64_platforms:
            x86_64_platforms = get_supported_platforms('x86_64')

    arm64_platforms = []
    if 'arm64' in arches or 'aarch64' in arches:
        try:
            platforms = list(map(lambda p: p.strip().lower(), user_platforms.replace(',', ' ').split()))
            for platform in platforms:
                if platform not in get_supported_platforms(arch):
                    print(f'Unsupported arm64 platform: {platform}. Ignoring.')
                    continue
                arm64_platforms.append(platform)
        except Exception as e:
            print(f'Unable to parse user provided arches: {e}. Ignoring.')

        if not arm64_platforms:
            arm64_platforms = get_supported_platforms('arm64')

    return x86_64_platforms, arm64_platforms


def build_linux_stage_matrix(python_versions: List[str],
                             x86_64_platforms: List[str],
                             arm64_platforms: List[str],
                             stage: ConfigStage) -> Dict[str, Any]:
    linux_matrix = {}
    if stage == ConfigStage.BUILD_WHEEL:
        if 'linux' in x86_64_platforms:
            linux_matrix['linux-type'] = ['manylinux']
            linux_matrix['arch'] = ['x86_64']
        if 'linux' in arm64_platforms:
            if 'linux-type' not in linux_matrix:
                linux_matrix['linux-type'] = ['manylinux']
            if 'arch' not in linux_matrix:
                linux_matrix['arch'] = ['aarch64']
            else:
                linux_matrix['arch'].append('aarch64')
        if 'alpine' in x86_64_platforms:
            if 'linux-type' not in linux_matrix:
                linux_matrix['linux-type'] = ['musllinux']
            else:
                linux_matrix['linux-type'].append('musllinux')
            if 'arch' not in linux_matrix:
                linux_matrix['arch'] = ['x86_64']

        if linux_matrix:
            linux_matrix['python-version'] = python_versions
            if 'aarch64' in linux_matrix['arch'] and 'musllinux' in linux_matrix['linux-type']:
                linux_matrix['exlude'] = [{'linux-type': 'musllinux', 'arch': 'aarch64'}]
    elif stage == ConfigStage.VALIDATE_WHEEL:
        if 'linux' in x86_64_platforms:
            linux_container = get_env_variable('CBCI_DEFAULT_LINUX_CONTAINER')
            linux_matrix['container'] = [linux_container]
            linux_matrix['arch'] = ['x86_64']
        if 'linux' in arm64_platforms:
            linux_container = get_env_variable('CBCI_DEFAULT_LINUX_CONTAINER')
            if 'container' not in linux_matrix:
                linux_matrix['container'] = [linux_container]
            if 'arch' not in linux_matrix:
                linux_matrix['arch'] = ['aarch64']
            else:
                linux_matrix['arch'].append('aarch64')
        if 'alpine' in x86_64_platforms:
            alpine_container = get_env_variable('CBCI_DEFAULT_ALPINE_CONTAINER')
            if 'container' not in linux_matrix:
                linux_matrix['container'] = [alpine_container]
            else:
                linux_matrix['container'].append(alpine_container)
            if 'arch' not in linux_matrix:
                linux_matrix['arch'] = ['x86_64']

        if linux_matrix:
            default_linux_plat = get_env_variable('CBCI_DEFAULT_LINUX_PLATFORM')
            linux_matrix['os'] = [default_linux_plat]
            linux_matrix['python-version'] = python_versions
            if 'aarch64' in linux_matrix['arch'] and 'container' in linux_matrix:
                alpine_container = get_env_variable('CBCI_DEFAULT_ALPINE_CONTAINER')
                if alpine_container in linux_matrix['container']:
                    linux_matrix['exlude'] = [{'container': alpine_container, 'arch': 'aarch64'}]

    return linux_matrix


def build_macos_stage_matrix(python_versions: List[str],
                             x86_64_platforms: List[str],
                             arm64_platforms: List[str],
                             stage: ConfigStage) -> Dict[str, Any]:
    macos_matrix = {}
    if stage == ConfigStage.BUILD_WHEEL:
        if 'macos' in x86_64_platforms:
            macos_plat = get_env_variable('CBCI_DEFAULT_MACOS_X86_64_PLATFORM')
            macos_matrix['os'] = [macos_plat]
            macos_matrix['arch'] = ['x86_64']
        if 'macos' in arm64_platforms:
            macos_plat = get_env_variable('CBCI_DEFAULT_MACOS_ARM64_PLATFORM')
            if 'os' not in macos_matrix:
                macos_matrix['os'] = [macos_plat]
            else:
                macos_matrix['os'].append(macos_plat)
            if 'arch' not in macos_matrix:
                macos_matrix['arch'] = ['arm64']
            else:
                macos_matrix['arch'].append('arm64')

        if macos_matrix:
            macos_matrix['python-version'] = python_versions
            if 'arm64' in macos_matrix['arch'] and 'x86_64' in macos_matrix['arch']:
                macos_x86_64_plat = get_env_variable('CBCI_DEFAULT_MACOS_X86_64_PLATFORM')
                macos_arm64_plat = get_env_variable('CBCI_DEFAULT_MACOS_ARM64_PLATFORM')
                macos_matrix['exlude'] = [{'os': macos_x86_64_plat, 'arch': 'arm64'},
                                          {'os': macos_arm64_plat, 'arch': 'x86_64'}]
    elif stage == ConfigStage.VALIDATE_WHEEL:
        if 'macos' in x86_64_platforms:
            macos_plat = get_env_variable('CBCI_DEFAULT_MACOS_X86_64_PLATFORM')
            macos_matrix['os'] = [macos_plat]
        if 'macos' in arm64_platforms:
            macos_plat = get_env_variable('CBCI_DEFAULT_MACOS_ARM64_PLATFORM')
            if 'os' not in macos_matrix:
                macos_matrix['os'] = [macos_plat]
            else:
                macos_matrix['os'].append(macos_plat)
        if macos_matrix:
            macos_matrix['python-version'] = python_versions

    return macos_matrix


def build_windows_stage_matrix(python_versions: List[str],
                               x86_64_platforms: List[str],
                               arm64_platforms: List[str],
                               stage: ConfigStage) -> Dict[str, Any]:
    windows_matrix = {}
    if stage == ConfigStage.BUILD_WHEEL or stage == ConfigStage.VALIDATE_WHEEL:
        if 'windows' in x86_64_platforms:
            windows_plat = get_env_variable('CBCI_DEFAULT_WINDOWS_PLATFORM')
            windows_matrix['os'] = [windows_plat]
            windows_matrix['arch'] = ['AMD64']

        if windows_matrix:
            windows_matrix['python-version'] = python_versions

    return windows_matrix


def build_stage_matrices(python_versions: List[str],
                         x86_64_platforms: List[str],
                         arm64_platforms: List[str]) -> Dict[str, Any]:
    matrices = {}
    for stage in [ConfigStage.BUILD_WHEEL, ConfigStage.VALIDATE_WHEEL]:
        stage_matrices = {}
        linux_matrix = build_linux_stage_matrix(python_versions, x86_64_platforms, arm64_platforms, stage)
        if linux_matrix:
            stage_matrices['linux'] = linux_matrix
            stage_matrices['has_linux'] = True
        else:
            stage_matrices['has_linux'] = False
        macos_matrix = build_macos_stage_matrix(python_versions, x86_64_platforms, arm64_platforms, stage)
        if macos_matrix:
            stage_matrices['macos'] = macos_matrix
            stage_matrices['has_macos'] = True
        else:
            stage_matrices['has_macos'] = False
        windows_matrix = build_windows_stage_matrix(python_versions, x86_64_platforms, arm64_platforms, stage)
        if windows_matrix:
            stage_matrices['windows'] = windows_matrix
            stage_matrices['has_windows'] = True
        else:
            stage_matrices['has_windows'] = False
        stage_name = 'build_wheels' if stage == ConfigStage.BUILD_WHEEL else 'validate_wheels'
        matrices[stage_name] = stage_matrices

    return matrices


def parse_user_config(config_key: str) -> Dict[str, List[str]]:
    user_config = user_config_as_json(config_key)
    cfg = {}
    versions = set_python_versions(user_config.get('python_versions', user_config.get('python-versions', '')))
    if versions:
        cfg['python_versions'] = versions
    else:
        cfg['python_versions'] = get_supported_python_versions()

    user_platforms = user_config.get('platforms', '')
    user_arches = user_config.get('arches', '')
    x86_64_platforms, arm64_platforms = set_os_and_arch(user_platforms, user_arches)
    cfg['x86_64_platforms'] = x86_64_platforms
    cfg['arm64_platforms'] = arm64_platforms
    return cfg


def get_stage_matrices(config_key: str) -> None:
    config = parse_user_config(config_key)
    matrices = build_stage_matrices(config['python_versions'], config['x86_64_platforms'], config['arm64_platforms'])
    print(f'{json.dumps(matrices)}')


def parse_config(config_stage: ConfigStage, config_key: str) -> None:
    sdk_project = SdkProject.from_env()
    default_cfg = build_default_config(config_stage, sdk_project)
    user_config = user_config_as_json(config_key)

    cfg = {}
    for key, value in user_config.items():
        if key in STAGE_MATRIX_KEYS:
            continue
        if key not in default_cfg:
            # print(f'Invalid key: {key}. Ignoring.')
            continue
        if value in [True, False]:
            cfg[key] = 'ON' if value else 'OFF'
        else:
            cfg[key] = value

    # handle defaults
    required_defaults = [k for k, v in default_cfg.items() if v['required'] is True]
    for k in required_defaults:
        if k not in cfg and default_cfg[k]['default'] is not None:
            cfg[k] = default_cfg[k]['default']

    # print(f'{json.dumps({default_cfg[k]["sdk_alias"]:v for k, v in cfg.items()})}')
    print(' '.join([f'{default_cfg[k]["sdk_alias"]}={v}' for k, v in cfg.items()]))


def parse_wheel_name(wheelname: str, project_name: str) -> None:
    tokens = wheelname.split('-')
    if len(tokens) < 5:
        print(f'Expected at least 5 tokens, found {len(tokens)}.')
        sys.exit(1)
    if tokens[0] != project_name:
        print(f'Expected at project name to be {project_name}, found {tokens[0]}.')
        sys.exit(1)

    print('-'.join(tokens[:2]))

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f'Expected more input args. Got {sys.argv[1:]}.')
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == 'parse_sdist_config':
        parse_config(ConfigStage.BUILD_SDIST, sys.argv[2])
    elif cmd == 'get_stage_matrices':
        get_stage_matrices(sys.argv[2])
    elif cmd == 'parse_wheel_config':
        parse_config(ConfigStage.BUILD_WHEEL, sys.argv[2])
    elif cmd == 'parse_wheel_name':
        parse_wheel_name(sys.argv[2], sys.argv[3])
    else:
        print(f'Invalid command: {cmd}')
        sys.exit(1)
