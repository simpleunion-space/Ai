#!/usr/bin/env python3
"""Read-only single source of selection and deployment generation."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex

CHAT_CONTEXT_POLICY = [262144, 131072, 65536, 32768, 24576, 16384, 8192, 4096]


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def runtime_recipe_fingerprint():
    directory = Path(__file__).resolve().parents[1] / 'docker/llamacpp'
    files = ('Dockerfile', 'service-entrypoint.sh', 'healthcheck.sh', 'runtime.py')
    return canonical_hash({name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in files})


def one_artifact(catalog, role, model, kind=None):
    source = catalog.get('auxiliaryArtifacts', []) if kind else catalog['artifacts']
    found = [item for item in source if item['role'] == role and item['model'] == model
             and (item.get('kind') == kind if kind else item['quantization'] == 'Q4_K_M')]
    if kind and not found:
        return None
    if len(found) != 1:
        raise ValueError('Missing or ambiguous pinned model artifact')
    artifact = found[0]
    relative = artifact['path']
    if (relative.startswith('/') or '\\' in relative or len(relative.split('/')) != 3
            or any(part in ('', '.', '..') for part in relative.split('/'))
            or not re.fullmatch(r'[a-f0-9]{64}', artifact.get('sha256', ''))
            or type(artifact.get('size')) is not int or artifact['size'] <= 0):
        raise ValueError('Invalid pinned model artifact')
    return {key: artifact[key] for key in ('path', 'sha256', 'size', 'quantization')}


def selection(catalog, chat_model, embedding_model, image_version, chat_gfx, embedding_gfx,
              chat_context=262144, embedding_context=32768, recipe_digest=None,
              accelerator='amd', chat_policy_max_context=None):
    if catalog.get('version') != 1 or not re.fullmatch(r'\d{4}\.\d{2}\.\d{2}-\d+', image_version):
        raise ValueError('Unpinned catalog or image version')
    if accelerator not in ('cpu', 'nvidia', 'amd'):
        raise ValueError('Unsupported accelerator')
    for gfx in (chat_gfx, embedding_gfx):
        if accelerator == 'amd' and not re.fullmatch(r'gfx[0-9a-f]+', gfx):
            raise ValueError('Invalid native GFX target')
    if accelerator != 'amd':
        chat_gfx = embedding_gfx = ''
    chat_policy_max_context = chat_policy_max_context or chat_context
    if (chat_context not in CHAT_CONTEXT_POLICY or chat_policy_max_context not in CHAT_CONTEXT_POLICY
            or chat_context > chat_policy_max_context or embedding_context not in (4096, 8192, 16384, 32768)
            or (embedding_model == 'qwen3-embedding-8b' and embedding_context != 32768)):
        raise ValueError('Context is outside the approved model policy')
    # Inference upgrades must never change the toolchain that produced already
    # locked weights. In particular the locally quantized 0.6B Q4 artifact keeps
    # its original quantizer provenance and checksum across runtime releases.
    toolchain = catalog.get('runtime')
    if (not isinstance(toolchain, dict)
            or not re.fullmatch(r'[a-f0-9]{40}', str(toolchain.get('commit', '')))
            or not re.fullmatch(r'[a-f0-9]{64}', str(toolchain.get('archiveSha256', '')))
            or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', str(toolchain.get('tag', '')))):
        raise ValueError('Native runtime source must be an immutable stable release')
    dimensions = {'qwen3-embedding-0.6b': 1024, 'qwen3-embedding-4b': 2560, 'qwen3-embedding-8b': 4096}
    if embedding_model not in dimensions:
        raise ValueError('Unsupported embedding dimension contract')
    recipe_digest = recipe_digest or runtime_recipe_fingerprint()
    if not re.fullmatch(r'[a-f0-9]{64}', recipe_digest):
        raise ValueError('Native runtime recipe fingerprint is invalid')
    shared = {'sourceCommit': toolchain['commit'], 'archiveSha256': toolchain['archiveSha256'],
              'recipeFingerprint': recipe_digest,
              'nativeTag': toolchain['tag'], 'imageVersion': image_version, 'accelerator': accelerator,
              'quantization': 'Q4_K_M', 'parallel': 1, 'batchSize': 512, 'ubatchSize': 512,
              'gpuLayers': '0' if accelerator == 'cpu' else 'all', 'cacheTypeK': 'f16', 'cacheTypeV': 'f16'}
    roles = {}
    for role, model_id, gfx, context in (('chat', chat_model, chat_gfx, chat_context),
                                        ('embedding', embedding_model, embedding_gfx, embedding_context)):
        artifact = one_artifact(catalog, role, model_id)
        projector = one_artifact(catalog, role, model_id, 'projector') if role == 'chat' else None
        suffix = f'-amd-{gfx}' if accelerator == 'amd' else '-nvidia' if accelerator == 'nvidia' else '-cpu'
        roles[role] = {**shared, **artifact, 'role': role, 'modelId': model_id, 'gfx': gfx,
                       'dimensions': dimensions[model_id] if role == 'embedding' else 0,
                       'contextLength': context, 'contextCandidates': [value for value in CHAT_CONTEXT_POLICY if value <= chat_policy_max_context] if role == 'chat' else [embedding_context],
                       'projectorPath': projector['path'] if projector else '',
                       'projectorSha256': projector['sha256'] if projector else '',
                       'flashAttention': 'on' if role == 'chat' else 'off',
                       'pooling': 'last' if role == 'embedding' else '',
                       'normalization': 'l2' if role == 'embedding' else '',
                       'imageReference': f'ghcr.io/kukurusik/ai-stand-llamacpp:{image_version}{suffix}'}
    # Source/policy generation does not depend on mutable runtime receipts.
    # Lower tested chat context is bound by the separate actual canary digest.
    policy = {role: dict(value, contextLength=value['contextCandidates'][0]) for role, value in roles.items()}
    generation = canonical_hash(policy)
    for value in roles.values():
        value['generation'] = generation
    return {'generation': generation, 'roles': roles}


def shell_exports(value):
    exports = {'LLAMACPP_MODEL_CATALOG_FINGERPRINT': value['generation']}
    for role, selected in value['roles'].items():
        prefix = 'LLAMACPP_' + role.upper() + '_'
        for suffix, key in (('MODEL_ID', 'modelId'), ('MODEL_PATH', 'path'), ('MODEL_SHA256', 'sha256'),
                            ('CONTEXT_LENGTH', 'contextLength'), ('PROJECTOR_PATH', 'projectorPath'),
                            ('PROJECTOR_SHA256', 'projectorSha256'), ('DIMENSIONS', 'dimensions')):
            exports[prefix + suffix] = str(selected[key])
    return '\n'.join(f'export {key}={shlex.quote(item)}' for key, item in sorted(exports.items()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path, default=Path(__file__).with_name('catalog.lock.json'))
    parser.add_argument('--chat-model', default='qwen/qwen3.8-27b')
    parser.add_argument('--embedding-model', default='qwen3-embedding-8b')
    parser.add_argument('--chat-gfx', default='gfx1151')
    parser.add_argument('--embedding-gfx', default='gfx1103')
    parser.add_argument('--chat-context', type=int, default=262144)
    parser.add_argument('--chat-policy-max-context', type=int)
    parser.add_argument('--embedding-context', type=int, default=32768)
    parser.add_argument('--accelerator', choices=('cpu', 'nvidia', 'amd'), default='amd')
    parser.add_argument('--image-version', required=True)
    parser.add_argument('--format', choices=('shell', 'json', 'fingerprint'), default='json')
    args = parser.parse_args()
    value = selection(json.loads(args.catalog.read_text()), args.chat_model, args.embedding_model,
                      args.image_version, args.chat_gfx, args.embedding_gfx,
                      args.chat_context, args.embedding_context, accelerator=args.accelerator,
                      chat_policy_max_context=args.chat_policy_max_context)
    print(shell_exports(value) if args.format == 'shell' else value['generation']
          if args.format == 'fingerprint' else json.dumps(value, sort_keys=True, separators=(',', ':')))


if __name__ == '__main__':
    main()
