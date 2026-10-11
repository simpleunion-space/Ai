#!/usr/bin/env python3
"""Offline gate for a native llama.cpp candidate; never loads a model."""
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

MARKER = 'AI_STAND_MODEL_PREFLIGHT_RECEIPT='
CANARY_KEYS = ('generation', 'role', 'modelId', 'path', 'sha256', 'quantization', 'gfx',
               'sourceCommit', 'archiveSha256', 'nativeTag', 'recipeFingerprint', 'dimensions', 'imageReference', 'projectorPath',
               'projectorSha256', 'batchSize', 'ubatchSize', 'parallel', 'gpuLayers',
               'cacheTypeK', 'cacheTypeV', 'flashAttention', 'pooling', 'normalization', 'accelerator')
CONFIG_KEYS = tuple(key for key in CANARY_KEYS if key not in ('generation', 'imageReference')) + ('contextLength', 'imageId')


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def actual_configuration_fingerprint(receipt):
    return canonical_hash({key: receipt[key] for key in CONFIG_KEYS})


def validate_canary(receipt, expected):
    if any(receipt.get(key) != expected.get(key) for key in CANARY_KEYS):
        raise ValueError('Canary does not match the production candidate')
    image_id = receipt.get('imageId', '')
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', image_id) or image_id != expected.get('imageId'):
        raise ValueError('Canary immutable image ID is invalid')
    tests = receipt.get('tests')
    required_tests = ['inference', 'stress', 'contextLimit', 'cancellation']
    if expected['role'] == 'chat':
        required_tests += ['streaming', 'toolLoop', 'reasoning']
        if expected.get('projectorPath'):
            required_tests += ['vision']
    else:
        required_tests += ['batchOrdering', 'normalization']
    if (type(receipt.get('version')) is not int or receipt['version'] != 1
            or receipt.get('state') != 'passed' or not isinstance(tests, dict)
            or any(tests.get(name) is not True for name in required_tests)
            or type(receipt.get('stressDurationSeconds')) is not int or receipt['stressDurationSeconds'] < 1800):
        raise ValueError('Real inference, boundary and 30-minute stress evidence is required')
    if type(receipt.get('contextLength')) is not int or receipt['contextLength'] not in expected['contextCandidates']:
        raise ValueError('Canary context is outside the approved policy')
    try:
        completed = datetime.datetime.fromisoformat(receipt.get('completedAt', '').replace('Z', '+00:00'))
    except (ValueError, TypeError) as exc:
        raise ValueError('Canary timestamp is invalid') from exc
    if completed.tzinfo is None or completed > datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=5):
        raise ValueError('Canary timestamp is invalid')
    if receipt.get('configurationFingerprint') != actual_configuration_fingerprint(receipt):
        raise ValueError('Canary configuration fingerprint disagrees with actual parameters')
    return {key: receipt[key] for key in ('generation', 'role', 'state', 'modelId', 'dimensions', 'gfx',
                                         'contextLength', 'imageId', 'sourceCommit', 'configurationFingerprint')}


def private_json(path):
    for component in (path, *path.parents):
        if component.is_symlink():
            raise ValueError('Symlink in protected candidate metadata')
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 65536:
        raise ValueError('Candidate metadata must be root-owned 0600')
    return json.loads(path.read_text())


def verify_image(expected, marker=Path('/opt/llamacpp-build.json'),
                 library=Path('/opt/llamacpp/bin/libggml-hip.so')):
    build = json.loads(marker.read_text())
    for key, expected_key in (('commit', 'sourceCommit'), ('archiveSha256', 'archiveSha256'),
                              ('nativeTag', 'nativeTag'),
                              ('accelerator', 'accelerator'), ('gfx', 'gfx'),
                              ('recipeFingerprint', 'recipeFingerprint')):
        if build.get(key) != expected[expected_key]:
            raise ValueError('Native image build marker disagrees with candidate')
    if build.get('rocmVersion') != '10.1' or expected['accelerator'] != 'amd':
        raise ValueError('Candidate is not the pinned ROCm image')
    # readobj reports bundled native ISA without extracting files beside the
    # shared library; it therefore works on the immutable read-only image.
    result = subprocess.run(['/opt/rocm/llvm/bin/llvm-readobj', '--offloading', str(library)],
                            capture_output=True, check=True, timeout=60, text=True)
    if not re.search(r'(?<![a-z0-9])' + re.escape(expected['gfx']) + r'(?![a-z0-9])', result.stdout):
        raise ValueError('Native HIP ISA does not contain the physical GFX target')
    return build['commit']


def load_prepare():
    candidate = Path(__file__).with_name('prepare.py')
    if not candidate.is_file():
        candidate = Path(__file__).resolve().parents[1] / 'model-catalog/prepare.py'
    spec = importlib.util.spec_from_file_location('pinned_model_prepare', candidate)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def verify_artifacts(home, catalog, role):
    prepare = load_prepare()
    artifacts = [item for item in catalog['artifacts'] if item['role'] == role]
    if catalog.get('version') != 1 or len(artifacts) != (14 if role == 'chat' else 6):
        raise ValueError('Incomplete primary model catalog')
    identities = set()
    auxiliary = [item for item in catalog.get('auxiliaryArtifacts', []) if item['role'] == role]
    for item in artifacts + auxiliary:
        identity = (item['model'], item.get('kind', 'model'), item['quantization'])
        if identity in identities:
            raise ValueError('Duplicate pinned artifact')
        identities.add(identity)
        path = prepare.safe_path(home / 'models', prepare.validate_artifact(item))
        if not prepare.verify_file(path, item['size'], item['sha256'], item['quantization']):
            raise ValueError('Pinned candidate artifact is missing or unverified')
    return len(artifacts)


def main():
    if len(sys.argv) != 5 or sys.argv[1] != '/candidate' or sys.argv[3] not in ('chat', 'embedding'):
        raise ValueError('Unexpected offline model mount or role')
    home = Path(sys.argv[1])
    expected = json.loads(sys.argv[4])
    if expected['role'] != sys.argv[3] or not re.fullmatch(r'[a-f0-9]{64}', expected['generation']):
        raise ValueError('Invalid candidate identity')
    verify_image(expected)
    proof = validate_canary(private_json(home / 'state/canary' / (expected['generation'] + '.json')), expected)
    catalog = json.loads(Path(sys.argv[2]).read_text())
    count = verify_artifacts(home, catalog, expected['role'])
    print(MARKER + json.dumps(dict(proof, verifiedCount=count), sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        print('Read-only native model preflight failed; production consumers were not touched.', file=sys.stderr)
        sys.exit(1)
