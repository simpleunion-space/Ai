#!/usr/bin/env python3
"""Quiesced, generation-scoped migration of installation embedding consumers.

The controller runs on ai01. A short-lived, node-pinned Swarm job migrates
LanceDB on ai02 without SSH credentials or mounting the Gateway's secrets.
No old vectors, documents or memory databases are deleted by this program.
"""

import argparse
import contextlib
import datetime
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import sqlite3
import stat
import subprocess
import sys
import time
import uuid


# The installation's storage root (the installation wrapper exports STORAGE_ROOT); no path below it is a literal.
STORAGE_ROOT = os.environ.get('STORAGE_ROOT', '')
if not STORAGE_ROOT.startswith('/') or STORAGE_ROOT.endswith('/') or '..' in STORAGE_ROOT:
    raise SystemExit("STORAGE_ROOT must be the installation's absolute storage root")
STATE_ROOT = Path(f'{STORAGE_ROOT}/ai-stand-data/model-migration')
WEBUI_ROOT = Path(f'{STORAGE_ROOT}/openwebui-data/server')
MEMORY_ROOT = f'{STORAGE_ROOT}/openclaw-data/gateway/.openclaw/memory'
PACKAGES_ROOT = f'{STORAGE_ROOT}/openclaw-data/gateway/.openclaw/npm'
LLAMACPP01_ROOT = f'{STORAGE_ROOT}/llamacpp-data/llamacpp01'
LLAMACPP02_ROOT = f'{STORAGE_ROOT}/llamacpp-data/llamacpp02'
CONSUMERS = ('ai-stand_openwebui', 'ai-stand_openclaw-gateway')
RECEIPT_PREFIX = 'AI_STAND_MODEL_MIGRATION_RECEIPT='
PREFLIGHT_PREFIX = 'AI_STAND_MODEL_PREFLIGHT_RECEIPT='
CHAT_CONTEXT_CANDIDATES = (262144, 131072, 65536, 32768, 24576, 16384, 8192, 4096)
AI02_NODE_LABEL = 'ai-stand.node'
AI02_NODE_VALUE = 'ai02'
AI02_CONSTRAINT = f'node.labels.{AI02_NODE_LABEL}=={AI02_NODE_VALUE}'


def source_module(name, source):
    spec = importlib.util.spec_from_file_location(name, source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CANDIDATE = source_module('native_model_candidate', Path(__file__).with_name('verify-candidate.py'))
SELECTOR = source_module('native_model_selection', Path(__file__).resolve().parents[1] / 'model-catalog/selection.py')


class MigrationError(RuntimeError):
    pass


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def require_generation(value):
    if not re.fullmatch(r'[a-f0-9]{64}', value or ''):
        raise MigrationError('Migration generation must be a lowercase SHA-256')
    return value


def memory_relative_path(value):
    """Only the existing Gateway memory mount is an admissible source."""
    prefix = '/home/ai/.openclaw/memory/'
    if not value.startswith(prefix):
        raise MigrationError('Existing LanceDB path is outside the managed memory directory')
    relative = value[len(prefix):]
    path = PurePosixPath(relative)
    if not relative or path.is_absolute() or any(part in ('..', '.') for part in relative.split('/')):
        raise MigrationError('Unsafe existing LanceDB relative path')
    if '\\' in relative or any(part.startswith('.ai-stand-migration') for part in path.parts):
        raise MigrationError('Unsafe existing LanceDB relative path')
    return relative


def parse_service_environment(service):
    result = {}
    for item in service['Spec']['TaskTemplate'].get('ContainerSpec', {}).get('Env', []):
        key, sep, value = item.partition('=')
        if sep:
            result[key] = value
    return result


def replica_count(service):
    replicated = service['Spec']['Mode'].get('Replicated')
    if replicated is None or type(replicated.get('Replicas')) is not int:
        raise MigrationError('Embedding consumers must be replicated Swarm services')
    count = replicated['Replicas']
    if count not in (0, 1):
        raise MigrationError('This migration supports at most one replica per consumer')
    return count


def run(command, *, input_bytes=None, timeout=120):
    try:
        result = subprocess.run(command, input=input_bytes, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise MigrationError('A required deployment operation could not complete') from exc
    if result.returncode:
        # Docker/API/adapter output may contain request details. Never relay it
        # into terminal output, state.json or an operator's deployment log.
        raise MigrationError('A required deployment operation failed')
    return result.stdout.decode('utf-8', errors='strict').strip()


def docker_json(*arguments):
    try:
        return json.loads(run(['docker', *arguments]))
    except json.JSONDecodeError as exc:
        raise MigrationError('Docker returned an invalid deployment response') from exc


def service_snapshot(name):
    response = docker_json('service', 'inspect', name)
    if len(response) != 1 or response[0]['Spec']['Name'] != name:
        raise MigrationError('Unexpected deployment service identity')
    return response[0]


def initialization_state():
    """Service absence alone never proves that persistent data is fresh."""
    names = set(run(['docker', 'service', 'ls', '--format', '{{.Name}}']).splitlines())
    present = [name in names for name in CONSUMERS]
    if all(present):
        return 'existing'
    if any(present):
        raise MigrationError('Partial consumer deployment requires recovery, not fresh initialization')
    memory = Path(MEMORY_ROOT)
    if memory.is_symlink():
        raise MigrationError('Persistent memory path must not be a symlink')
    # Any file (including LanceDB fragments, manifests or prior migration
    # snapshots) is retained and treated as restoration, never as empty.
    if memory.exists() and any(item.is_file() or item.is_symlink() for item in memory.rglob('*')):
        raise MigrationError('Persistent memory exists without consumers; restore services before migration')
    database = WEBUI_ROOT / 'webui.db'
    if database.exists():
        assert_empty_webui_documents(webui_document_inventory(database))
    return 'fresh'


def require_ai02_managed_node():
    # Docker's Hostname may be an FQDN. The installation-owned label is the
    # stable placement contract, shared with apply.sh's host stage.
    ids = run(['docker', 'node', 'ls', '--quiet']).splitlines()
    nodes = docker_json('node', 'inspect', *ids) if ids else []
    targets = [node for node in nodes
               if node.get('Spec', {}).get('Labels', {}).get(AI02_NODE_LABEL) == AI02_NODE_VALUE]
    if len(targets) != 1:
        raise MigrationError('Exactly one ai02 managed-label node is required for migration jobs')
    if targets[0].get('Status', {}).get('State') != 'ready' \
            or targets[0].get('Spec', {}).get('Availability') != 'active':
        raise MigrationError('The ai02 managed-label node must be ready and active before migration jobs')
    return targets[0]['ID']


def private_directory(path):
    path = Path(path)
    if path.exists():
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise MigrationError('Migration storage is not a plain directory')
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise MigrationError('Existing migration directory ownership or mode is unsafe')
    else:
        path.mkdir(mode=0o700, parents=True)
        path.chmod(0o700)
    return path


def atomic_state(path, state):
    temporary = path.with_name(f'.{path.name}.{uuid.uuid4().hex}.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(state, stream, sort_keys=True, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def load_state(path):
    if not path.exists():
        return None
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise MigrationError('Existing migration state ownership or mode is unsafe')
    with path.open(encoding='utf-8') as stream:
        state = json.load(stream)
    if state.get('version') != 1:
        raise MigrationError('Unsupported embedding migration state version')
    return state


def webui_document_inventory(database):
    if not database.exists():
        return {'file': 0, 'knowledge': 0}
    if database.is_symlink():
        raise MigrationError('Open WebUI database must not be a symlink')
    with contextlib.closing(sqlite3.connect(f'{database.as_uri()}?mode=ro', uri=True)) as connection:
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        counts = {}
        for name in ('file', 'knowledge'):
            if name not in tables:
                raise MigrationError('Open WebUI schema lacks the expected document inventory tables')
            counts[name] = connection.execute(f'SELECT count(*) FROM "{name}"').fetchone()[0]
    return counts


def assert_empty_webui_documents(inventory):
    if any(inventory.get(name, 0) for name in ('file', 'knowledge')):
        raise MigrationError(
            'Open WebUI has existing documents: official reindex must be completed '
            'in a separately controlled maintenance workflow before this migration')


def backup_webui(database, backup_directory):
    if not database.exists():
        return None
    destination = backup_directory / 'openwebui.db'
    if destination.exists():
        return destination
    with contextlib.closing(sqlite3.connect(f'{database.as_uri()}?mode=ro', uri=True)) as source:
        with contextlib.closing(sqlite3.connect(destination)) as backup:
            source.backup(backup)
    destination.chmod(0o600)
    return destination


def stop_consumers():
    # Do not inherit a consumer's long Swarm update-monitor as a CLI wait.
    # Quiescence is checked explicitly across every task below, not inferred
    # from successful asynchronous submission or desired replicas alone.
    run(['docker', 'service', 'scale', '--detach=true', *[f'{name}=0' for name in CONSUMERS]])
    wait_consumer_tasks_stopped()


def wait_consumer_tasks_stopped(timeout=600):
    deadline = time.monotonic() + timeout
    live_states = {'new', 'pending', 'assigned', 'accepted', 'preparing', 'ready', 'starting', 'running'}
    while time.monotonic() < deadline:
        task_ids = []
        for name in CONSUMERS:
            output = run(['docker', 'service', 'ps', '--quiet', '--no-trunc', name])
            task_ids.extend(output.splitlines() if output else [])
        tasks = docker_json('inspect', *task_ids) if task_ids else []
        if not any(task.get('Status', {}).get('State', '').lower() in live_states for task in tasks):
            return
        time.sleep(2)
    raise MigrationError('Embedding consumers did not fully stop across the Swarm cluster')


def restore_consumers(snapshot):
    # consumers-ready performs the separate bounded readiness check.
    run(['docker', 'service', 'scale', '--detach=true', *[f'{name}={snapshot[name]}' for name in CONSUMERS]])


def run_profile(script, command, generation=None, replicas=None, approved_chat_context=None, approved_images=None):
    environment = os.environ.copy()
    if generation:
        environment['MODEL_MIGRATION_GENERATION'] = generation
    if replicas:
        environment['MODEL_MIGRATION_OPENWEBUI_REPLICAS'] = str(replicas[CONSUMERS[0]])
        environment['MODEL_MIGRATION_OPENCLAW_REPLICAS'] = str(replicas[CONSUMERS[1]])
    if approved_chat_context is not None:
        environment['MODEL_MIGRATION_APPROVED_CHAT_CONTEXT'] = str(approved_chat_context)
    if approved_images:
        environment['MODEL_MIGRATION_CHAT_IMAGE_ID'] = approved_images['chat']['imageId']
        environment['MODEL_MIGRATION_EMBEDDING_IMAGE_ID'] = approved_images['embedding']['imageId']
    try:
        process = subprocess.run(['bash', str(script), command], env=environment, check=False)
    except OSError as exc:
        raise MigrationError(f'Model profile stage {command} could not start') from exc
    if process.returncode:
        raise MigrationError(f'Model profile stage {command} failed')


def validate_receipt(log_output, generation, dimensions):
    receipts = []
    for line in log_output.splitlines():
        if RECEIPT_PREFIX in line:
            try:
                receipts.append(json.loads(line.split(RECEIPT_PREFIX, 1)[1]))
            except json.JSONDecodeError as exc:
                raise MigrationError('Migration worker receipt was malformed') from exc
    if len(receipts) != 1:
        raise MigrationError('Migration worker did not produce exactly one completion receipt')
    receipt = receipts[0]
    if receipt.get('state') != 'complete' or receipt.get('generation') != generation \
            or receipt.get('dimensions') != dimensions:
        raise MigrationError('Migration worker receipt does not match the requested generation')
    if type(receipt.get('rows')) is not int or receipt['rows'] < 0:
        raise MigrationError('Migration worker receipt has an invalid row count')
    # Keep only non-secret, predefined metadata in the controller manifest.
    return {key: receipt[key] for key in ('state', 'generation', 'dimensions', 'rows')}


def wait_job_complete(service_name, generation, dimensions, timeout=86400):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        output = run(['docker', 'service', 'ps', '--quiet', '--no-trunc', service_name])
        task_ids = output.splitlines() if output else []
        tasks = docker_json('inspect', *task_ids) if task_ids else []
        if any(task.get('Status', {}).get('State') in ('failed', 'rejected', 'orphaned') for task in tasks):
            raise MigrationError('The node-pinned LanceDB migration worker failed')
        if len(tasks) == 1 and tasks[0].get('Status', {}).get('State') == 'complete':
            return validate_receipt(run(['docker', 'service', 'logs', '--raw', service_name]), generation, dimensions)
        time.sleep(5)
    raise MigrationError('The node-pinned LanceDB migration worker timed out')


def safe_remove(kind, name):
    with contextlib.suppress(MigrationError):
        run(['docker', kind, 'rm', name])


def remove_preflight_network(name, timeout=30):
    if not re.fullmatch(r'ai-model-preflight-[a-f0-9]{12}', name):
        raise MigrationError('Unexpected preflight network cleanup target')
    # Swarm service removal is asynchronous. Retry only this temporary network
    # while its completed/dead task endpoints are detached by the daemon.
    deadline = time.monotonic() + timeout
    while True:
        try:
            run(['docker', 'network', 'rm', name], timeout=10)
            return
        except MigrationError:
            if time.monotonic() >= deadline:
                raise MigrationError('Temporary internal preflight network cleanup did not complete')
            time.sleep(2)


def pinned_source_value(source, expression, label):
    matches = re.findall(expression, source, re.MULTILINE)
    if len(matches) != 1:
        raise MigrationError(f'Pinned {label} is missing or ambiguous')
    return matches[0]


def pinned_memory_plugin_version(apply_script):
    source = (apply_script.resolve().parents[2] / 'apply.sh').read_text(encoding='utf-8')
    return pinned_source_value(source, r'^OPENCLAW_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$',
                               'OpenClaw memory plugin version')


def candidate_expectations(args):
    source_root = args.apply_script.resolve().parents[2]
    catalog_path = source_root / 'model-catalog/catalog.lock.json'
    apply_source = (source_root / 'apply.sh').read_text(encoding='utf-8')
    image_version = pinned_source_value(apply_source, r'^LLAMACPP_IMAGE_VERSION="([0-9.]+-[0-9]+)"$', 'image version')
    lock = json.loads(catalog_path.read_text(encoding='utf-8'))
    selected = SELECTOR.selection(lock, 'qwen/qwen3.8-27b', args.model, image_version, 'gfx1151', 'gfx1103')
    if selected['generation'] != args.generation:
        raise MigrationError('Requested generation disagrees with the checked-in native model selection')
    try:
        bindings = CANDIDATE.private_json(STATE_ROOT / args.installation / 'candidate-images.json')
    except (OSError, ValueError) as exc:
        raise MigrationError('Passed immutable candidate image bindings are missing; consumers remain running') from exc
    if bindings.get('generation') != args.generation:
        raise MigrationError('Immutable candidate image bindings belong to a different generation')
    expected = selected['roles']
    for role in ('chat', 'embedding'):
        image_id = bindings.get(role, '')
        if not re.fullmatch(r'sha256:[a-f0-9]{64}', image_id):
            raise MigrationError('Candidate image binding must be an immutable image ID')
        expected[role]['imageId'] = image_id
    return source_root, catalog_path, expected


def validate_canary(receipt, expected):
    try:
        return CANDIDATE.validate_canary(receipt, expected)
    except (ValueError, KeyError) as exc:
        raise MigrationError(str(exc)) from exc


def read_private_canary(home, expected):
    try:
        receipt = CANDIDATE.private_json(home / 'state/canary' / (expected['generation'] + '.json'))
    except (OSError, ValueError) as exc:
        raise MigrationError('Passed root-owned native canary receipt is missing; consumers remain running') from exc
    return validate_canary(receipt, expected)


def parse_preflight_receipt(log_output, expected):
    records = []
    for line in log_output.splitlines():
        if PREFLIGHT_PREFIX in line:
            try:
                records.append(json.loads(line.split(PREFLIGHT_PREFIX, 1)[1]))
            except json.JSONDecodeError as exc:
                raise MigrationError('Candidate preflight receipt was malformed') from exc
    if len(records) != 1:
        raise MigrationError('Candidate preflight completion receipt is missing or ambiguous')
    receipt = records[0]
    for key in ('generation', 'role', 'modelId', 'dimensions', 'gfx', 'imageId'):
        if receipt.get(key) != expected[key]:
            raise MigrationError('Candidate preflight identity is inconsistent')
    if receipt.get('state') != 'passed' or receipt.get('verifiedCount') != 6 \
            or receipt.get('contextLength') != 32768 \
            or not re.fullmatch(r'[a-f0-9]{64}', receipt.get('configurationFingerprint', '')):
        raise MigrationError('Embedding candidate catalog/canary is not ready')
    return {key: receipt[key] for key in ('generation', 'role', 'modelId', 'dimensions', 'gfx', 'state', 'contextLength', 'imageId', 'configurationFingerprint')}


def wait_preflight_job(name, expected, timeout=7200):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ids = run(['docker', 'service', 'ps', '--quiet', '--no-trunc', name]).splitlines()
        tasks = docker_json('inspect', *ids) if ids else []
        if any(task.get('Status', {}).get('State') in ('failed', 'rejected', 'orphaned') for task in tasks):
            raise MigrationError('ai02 candidate image/catalog/canary preflight failed; production consumers were not stopped')
        if len(tasks) == 1 and tasks[0].get('Status', {}).get('State') == 'complete':
            return parse_preflight_receipt(run(['docker', 'service', 'logs', '--raw', name]), expected)
        time.sleep(5)
    raise MigrationError('ai02 read-only candidate preflight timed out; production consumers were not stopped')


def remote_candidate_preflight(source_root, catalog_path, expected):
    require_ai02_managed_node()
    nonce = uuid.uuid4().hex[:12]
    name = f'ai-stand-model-preflight-{nonce}'
    network_name = f'ai-model-preflight-{nonce}'
    script_name, catalog_name, prepare_name = name + '-script', name + '-catalog', name + '-prepare'
    created = []
    try:
        for config_name, file in ((script_name, source_root / 'model-migration/verify-candidate.py'),
                                  (catalog_name, catalog_path),
                                  (prepare_name, source_root / 'model-catalog/prepare.py')):
            run(['docker', 'config', 'create', config_name, str(file)])
            created.append(('config', config_name))
        # Built-in network "none" is not a Swarm service network. A dedicated
        # internal, non-attachable overlay gives this offline verifier no
        # external egress or access to the production backend services.
        run(['docker', 'network', 'create', '--driver', 'overlay', '--scope', 'swarm',
             '--internal', '--label', 'ai-stand.model-preflight=true', network_name])
        created.append(('network', network_name))
        run(['docker', 'service', 'create', '--name', name, '--detach=true', '--mode', 'replicated-job',
             '--replicas', '1', '--restart-condition', 'none', '--constraint', AI02_CONSTRAINT,
             '--no-resolve-image', '--user', '0:20000', '--read-only', '--cap-drop', 'ALL', '--no-healthcheck',
             '--entrypoint', 'python3', '--network', network_name,
             '--mount', f'type=bind,source={LLAMACPP02_ROOT},destination=/candidate,readonly',
             '--config', f'source={script_name},target=/run/configs/verify-candidate.py,mode=0444',
             '--config', f'source={prepare_name},target=/run/configs/prepare.py,mode=0444',
             '--config', f'source={catalog_name},target=/run/configs/catalog.lock.json,mode=0444',
             '--label', 'ai-stand.model-preflight=true', expected['imageId'],
             '/run/configs/verify-candidate.py', '/candidate', '/run/configs/catalog.lock.json',
             'embedding', json.dumps(expected, separators=(',', ':'))])
        created.append(('service', name))
        return wait_preflight_job(name, expected)
    finally:
        cleanup_error = None
        for kind, resource in reversed(created):
            if kind == 'network':
                try:
                    remove_preflight_network(resource)
                except MigrationError as exc:
                    cleanup_error = exc
            else:
                safe_remove(kind, resource)
        if cleanup_error:
            raise cleanup_error


def verify_offline_image(source_root, expected):
    verifier = source_root / 'model-migration/verify-candidate.py'
    if not verifier.is_file() or verifier.is_symlink():
        raise MigrationError('Pinned offline image verifier is missing or unsafe')
    # UID 0 without DAC_OVERRIDE cannot read a bind-mounted checkout file
    # owned by another host UID with mode 0600. Pass the exact checked-in
    # verifier on stdin instead of widening permissions or capabilities.
    run(['docker', 'run', '--rm', '--interactive', '--network', 'none', '--read-only',
         '--cap-drop', 'ALL', '--user', '0:20000', '--entrypoint', 'python3',
         expected['imageId'], '-c',
         'import json,sys,types; m=types.ModuleType("proof"); '
         'm.__file__="/run/verify-candidate.py"; '
         'exec(compile(sys.stdin.buffer.read(),m.__file__,"exec"),m.__dict__); '
         'm.verify_image(json.loads(sys.argv[1]))',
         json.dumps(expected, separators=(',', ':'))], input_bytes=verifier.read_bytes())


def preflight_before_maintenance(args):
    source_root, catalog_path, expected = candidate_expectations(args)
    chat_image = docker_json('image', 'inspect', expected['chat']['imageId'])
    if (len(chat_image) != 1 or chat_image[0].get('Id') != expected['chat']['imageId']
            or chat_image[0].get('Config', {}).get('Labels', {}).get('org.ai-stand.rocm.gfx') != expected['chat']['gfx']):
        raise MigrationError('ai01 immutable candidate image/GFX is unavailable; consumers remain running')
    chat = read_private_canary(Path(LLAMACPP01_ROOT), expected['chat'])
    # Narrow offline image inspection has no models, secrets, Docker socket or
    # GPU devices. The probe executes the same actual ID validated in canary.
    verify_offline_image(source_root, expected['chat'])
    run(['python3', str(source_root / 'model-catalog/prepare.py'), '--role', 'chat',
         '--root', LLAMACPP01_ROOT, '--catalog', str(catalog_path), '--verify-only'], timeout=7200)
    embedding = remote_candidate_preflight(source_root, catalog_path, expected['embedding'])
    return {'chat': chat, 'embedding': embedding}


def protected_migration_token(token_file):
    info = token_file.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o077:
        raise MigrationError('Agentgateway migration token file ownership or mode is unsafe')
    token = token_file.read_bytes().strip()
    if len(token) < 20 or b'\n' in token or b'\r' in token:
        raise MigrationError('Agentgateway migration token file is invalid')
    return token


def run_lancedb_worker(adapter, gateway, source_relative, args):
    plugin_version = pinned_memory_plugin_version(args.apply_script)
    require_ai02_managed_node()
    task_id = uuid.uuid4().hex[:12]
    name = f'ai-stand-model-migration-{task_id}'
    config_name = f'{name}-script'
    secret_name = f'{name}-token'
    labels = ['--label', 'ai-stand.model-migration=true', '--label', f'ai-stand.generation={args.generation}']
    image = gateway['Spec']['TaskTemplate']['ContainerSpec']['Image']
    token = protected_migration_token(args.token_file)
    created = []
    try:
        run(['docker', 'config', 'create', *labels, config_name, str(adapter)])
        created.append(('config', config_name))
        run(['docker', 'secret', 'create', *labels, secret_name, '-'], input_bytes=token)
        created.append(('secret', secret_name))
        # This trusted deployment-only job receives memory and packages, never
        # the Gateway home, OAuth cache, Telegram token or Docker socket.
        command = [
            'docker', 'service', 'create', '--name', name, '--detach=true',
            '--mode', 'replicated-job', '--replicas', '1', '--restart-condition', 'none',
            '--constraint', AI02_CONSTRAINT, '--no-resolve-image',
            '--user', '10000:20000', '--read-only', '--cap-drop', 'ALL', '--no-healthcheck',
            '--network', 'ai-stand_ai-models-backend', '--entrypoint', 'node',
            '--mount', f'type=bind,source={MEMORY_ROOT},destination=/memory',
            '--mount', f'type=bind,source={PACKAGES_ROOT},destination=/packages,readonly',
            '--mount', 'type=tmpfs,destination=/tmp,tmpfs-size=67108864,tmpfs-mode=1777',
            '--config', f'source={config_name},target=/run/configs/lancedb-migrate.mjs,mode=0444',
            '--secret', f'source={secret_name},target=agentgateway-token,mode=0444',
            *labels, image, '/run/configs/lancedb-migrate.mjs', 'migrate',
            '--packages', '/packages', '--plugin-version', plugin_version, '--memory-root', '/memory',
            '--source-path', source_relative,
            '--target-path', f'lancedb-{args.generation[:16]}',
            '--generation', args.generation, '--backend-url', 'http://agentgateway:4000/v1',
            '--token-file', '/run/secrets/agentgateway-token',
            '--model', args.model, '--dimensions', str(args.dimensions),
        ]
        run(command)
        created.append(('service', name))
        return wait_job_complete(name, args.generation, args.dimensions)
    finally:
        token = b''
        for kind, resource in reversed(created):
            safe_remove(kind, resource)


def migrate(args):
    require_generation(args.generation)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', args.installation):
        raise MigrationError('Unsupported installation name')
    if args.model != 'qwen3-embedding-8b' or args.dimensions != 4096:
        raise MigrationError('This migration is pinned to Qwen3-Embedding-8B / 4096 dimensions')
    if args.backend_url != 'http://127.0.0.1:4000/v1':
        raise MigrationError('Controller backend URL must be the local Agentgateway boundary')
    if os.geteuid() != 0:
        raise MigrationError('Embedding migration must be run as root on ai01')
    state_directory = private_directory(STATE_ROOT / args.installation)
    state_path = state_directory / 'state.json'
    lock_path = state_directory / '.lock'
    import fcntl
    with lock_path.open('a') as lock:
        lock_path.chmod(0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise MigrationError('Another embedding migration is active') from exc
        previous = load_state(state_path)
        if previous and previous.get('generation') == args.generation and previous.get('phase') == 'complete':
            if previous.get('fresh') is True and initialization_state() == 'fresh':
                # A failed control-plane bootstrap may be retried while both
                # consumers and persistent databases are still absent.
                preflight_before_maintenance(args)
                print('[model-migration] Empty initialization gate still verified; generic deployment may resume')
                return
            # Reconcile the same env/image idempotently; do not stop users or
            # rebuild vectors simply because an ordinary deploy is repeated.
            try:
                run_profile(args.apply_script, 'backend-apply')
                run_profile(args.apply_script, 'consumers-apply', args.generation)
                current_replicas = {name: replica_count(service_snapshot(name)) for name in CONSUMERS}
                run_profile(args.apply_script, 'consumers-ready', replicas=current_replicas)
            except BaseException:
                previous['failed_phase'] = 'completed_reconcile'
                previous['phase'] = 'failed'
                previous['failed_at'] = utc_now()
                atomic_state(state_path, previous)
                with contextlib.suppress(MigrationError):
                    stop_consumers()
                raise
            print('[model-migration] Existing index generation verified; no reindex or maintenance stop')
            return

        # A source synchronization is not permission to begin downtime. Both
        # complete catalogs and root-owned, actually passed GPU/stress canaries
        # must be established while the existing services are still running.
        preflight = preflight_before_maintenance(args)
        if initialization_state() == 'fresh':
            # Empty installation: bind only the actually tested native images
            # and context before the generic stack creates consumers. This is
            # not a legacy model-copy or session conversion operation.
            run_profile(args.apply_script, 'prepare-backend-state',
                        approved_chat_context=preflight['chat']['contextLength'], approved_images=preflight)
            atomic_state(state_path, {
                'version': 1, 'installation': args.installation, 'generation': args.generation,
                'phase': 'complete', 'fresh': True, 'completed_at': utc_now(),
                'model': args.model, 'dimensions': args.dimensions, 'preflight': preflight,
                'target_relative': f'lancedb-{args.generation[:16]}',
                'receipt': {'state': 'complete', 'generation': args.generation, 'dimensions': args.dimensions, 'rows': 0},
            })
            print('[model-migration] Empty persistent installation validated; no legacy vectors were imported')
            return
        # Fresh offline gates need no machine credential. Existing consumer
        # imports do, and a missing/unsafe token must fail before quiescence.
        protected_migration_token(args.token_file)
        inventory = webui_document_inventory(WEBUI_ROOT / 'webui.db')
        assert_empty_webui_documents(inventory)
        gateway = service_snapshot(CONSUMERS[1])
        snapshots = {name: replica_count(service_snapshot(name)) for name in CONSUMERS}
        if previous and previous.get('generation') == args.generation:
            snapshots = previous.get('original_replicas', snapshots)
        if set(snapshots) != set(CONSUMERS) or any(type(value) is not int or value not in (0, 1) for value in snapshots.values()):
            raise MigrationError('Stored replica restoration metadata is invalid')
        environment = parse_service_environment(gateway)
        source_relative = memory_relative_path(environment.get('OPENCLAW_LANCEDB_DB_PATH', '/home/ai/.openclaw/memory/lancedb'))
        if previous and previous.get('generation') == args.generation:
            source_relative = memory_relative_path('/home/ai/.openclaw/memory/' + previous['source_relative'])
        adapter = Path(__file__).with_name('lancedb-migrate.mjs')
        if not adapter.is_file() or adapter.is_symlink():
            raise MigrationError('Pinned LanceDB migration adapter is missing')
        state = {
            'version': 1, 'installation': args.installation, 'generation': args.generation,
            'phase': 'prepared', 'started_at': utc_now(), 'original_replicas': snapshots,
            'source_relative': source_relative, 'target_relative': f'lancedb-{args.generation[:16]}',
            'model': args.model, 'dimensions': args.dimensions, 'openwebui_documents': inventory,
            'worker_backup_relative': f'.ai-stand-migration/{args.generation}',
            'preflight': preflight,
        }
        recovered_receipt = None
        if previous and previous.get('generation') == args.generation \
                and previous.get('failed_phase') in ('consumer_apply', 'consumers_ready', 'completed_reconcile'):
            recovered_receipt = previous.get('receipt')
            if recovered_receipt:
                recovered_receipt = validate_receipt(RECEIPT_PREFIX + json.dumps(recovered_receipt),
                                                     args.generation, args.dimensions)
        backup_directory = private_directory(state_directory / 'backup' / args.generation)
        atomic_state(state_path, state)
        try:
            stop_consumers()
            state['phase'] = 'consumers_stopped'
            atomic_state(state_path, state)
            # Recheck after stop to catch a document uploaded between preflight
            # and quiescence. A failure leaves both consumers stopped safely.
            inventory = webui_document_inventory(WEBUI_ROOT / 'webui.db')
            assert_empty_webui_documents(inventory)
            backup_webui(WEBUI_ROOT / 'webui.db', backup_directory)
            state['phase'] = 'backend_apply'
            atomic_state(state_path, state)
            run_profile(args.apply_script, 'backend-apply', approved_chat_context=preflight['chat']['contextLength'], approved_images=preflight)
            state['phase'] = 'lancedb_reembed'
            atomic_state(state_path, state)
            # Once a generation has been imported, do not rewrite it on retry:
            # the running Gateway may already have added new memory records.
            state['receipt'] = recovered_receipt or run_lancedb_worker(adapter, gateway, source_relative, args)
            state['phase'] = 'consumer_apply'
            atomic_state(state_path, state)
            run_profile(args.apply_script, 'consumers-apply', args.generation)
            restore_consumers(snapshots)
            state['phase'] = 'consumers_ready'
            atomic_state(state_path, state)
            run_profile(args.apply_script, 'consumers-ready', replicas=snapshots)
            state['phase'] = 'complete'
            state['completed_at'] = utc_now()
            atomic_state(state_path, state)
            print('[model-migration] Embedding-8B Q4 index generation activated; backups retained')
        except BaseException:
            state['failed_phase'] = state['phase']
            state['phase'] = 'failed'
            state['failed_at'] = utc_now()
            atomic_state(state_path, state)
            with contextlib.suppress(MigrationError):
                stop_consumers()
            raise


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installation', required=True)
    parser.add_argument('--apply-script', required=True, type=Path)
    parser.add_argument('--backend-url', required=True)
    parser.add_argument('--token-file', required=True, type=Path)
    parser.add_argument('--model', required=True)
    parser.add_argument('--dimensions', required=True, type=int)
    parser.add_argument('--generation', required=True)
    return parser.parse_args(argv)


def main():
    os.umask(0o077)
    try:
        migrate(parse_arguments())
    except KeyboardInterrupt:
        print('[model-migration] Interrupted; consumers remain stopped and backups are retained', file=sys.stderr)
        return 130
    except (MigrationError, OSError, sqlite3.Error, ValueError) as exc:
        # Unexpected library/database exception details may contain record
        # content. Only controlled migration errors are safe to print.
        detail = str(exc) if isinstance(exc, MigrationError) else 'A protected migration operation failed'
        print(f'[model-migration] ERROR: {detail}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
