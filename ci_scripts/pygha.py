from __future__ import annotations

import json
import os
import sys

from copy import deepcopy
from enum import Enum
from typing import Optional

class ConfigStage(Enum):
    SDIST = 1
    WHEEL = 2

class SdkProject(Enum):
    Columnar = 'PYCBCC'
    Operational = 'PYCBC'

    @classmethod
    def from_env(cls, env_key: Optional[str]='PROJECT_TYPE') -> SdkProject:
        env = get_env_variable(env_key)
        if env.upper() in ['COLUMNAR', 'PYCBCC']:
            return SdkProject.Columnar
        if env.upper() in ['OPERATIONAL', 'PYCBC']:
            return SdkProject.Operational
        else:
            print(f'Invalid SDK project: {env}')
            sys.exit(1)
    

DEFAULT_CONFIG = {
    'USE_OPENSSL': {
        'default': 'OFF',
        'description': 'Use OpenSSL instead of boringssl',
        'required': True,
        'sdk_alias': 'SDKPROJECT_USE_OPENSSL'
    },
    'SET_CPM_CACHE': {
        'default': 'ON',
        'description': 'Initialize the C++ core CPM cache',
        'required': False,
        'sdk_alias': 'SDKPROJECT_SET_CPM_CACHE'
    }
}

def get_env_variable(key: str) -> str:
    try:
        return os.environ[key]
    except KeyError:
        print(f'Environment variable {key} not set.')
        sys.exit(1)

def get_config(stage: ConfigStage, project: SdkProject) -> dict:
    config = deepcopy(DEFAULT_CONFIG)
    if stage == ConfigStage.SDIST:
        config['SET_CPM_CACHE']['required'] = True
    elif stage == ConfigStage.WHEEL:
        pass

    for v in config.values():
        v['sdk_alias'] = v['sdk_alias'].replace('SDKPROJECT', project.value)

    return config

def parse_sdist_config(config_key: str) -> None:
    config = get_env_variable(config_key)
    sdk_project = SdkProject.from_env()
    default_cfg = get_config(ConfigStage.SDIST, sdk_project)
    if not config:
        config = '{}'

    try:
        test_config = json.loads(config)
    except Exception as e:
        print(f'Invalid JSON: {e}')
        sys.exit(1)

    cfg = {}
    for key, value in test_config.items():
        if key not in default_cfg:
            print(f'Invalid key: {key}.')
            sys.exit(1)
        if value in [True, False]:
            cfg[key] = 'ON' if value else 'OFF'
        else:
            cfg[key] = value

    # handle defaults
    required_defaults = [k for k, v in default_cfg.items() if v['required'] is True]
    for k in required_defaults:
        if k not in cfg:
            cfg[k] = default_cfg[k]['default']

    # print(f'{json.dumps({default_cfg[k]["sdk_alias"]:v for k, v in cfg.items()})}')
    print(' '.join([f'{default_cfg[k]["sdk_alias"]}={v}' for k, v in cfg.items()]))


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f'Expected more input args. Got {sys.argv[1:]}.')
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == 'parse_sdist_config':
        parse_sdist_config(sys.argv[2])
    else:
        print(f'Invalid command: {cmd}')
        sys.exit(1)