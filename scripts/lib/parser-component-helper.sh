#!/usr/bin/env bash
# Private preparation/service adapter for parser_components.py. Never run prepare
# on the live environment: the engine owns PARSER_CANDIDATE and the transaction.
set -euo pipefail
mode=${1:?component helper mode required}
helper_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1 OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
export TMPDIR="${PARSER_TX_DIR:-/tmp}"
export NIMO_DL_TMPDIR="$TMPDIR"
export UV_CACHE_DIR="$TMPDIR/uv-cache"
export NIMO_DEPS_BASE="${PARSER_DEPS_BASE:-${NIMO_DEPS_BASE:-https://get.nimotech.ai/deps}}"

load_functions() {
    local payload=${1:-${PARSER_SOURCE:?}}
    # The library guard is before the installer main; none of its functions run.
    export NIMO_PARSER_LIBRARY_ONLY=1
    export NIMO_PARSER_INSTALL_DIR="${PARSER_CANDIDATE:-${PARSER_RELEASE:-/opt/nimoos-parser}}"
    set --
    source "$helper_dir/../install-parser.sh"
    RESOLVED="$payload"
    SYSROOT="$RESOLVED/build/sysroot"
    UNIT_SRC="$SYSROOT/usr/lib/systemd/system/nimoos-parser.service"
    [[ -f "$UNIT_SRC" ]] || UNIT_SRC="$SYSROOT/lib/systemd/system/nimoos-parser.service"
    CONF_SAMPLE_SRC="$SYSROOT/etc/nimoos/parser.conf"
}

python_for_runtime() {
    local root=$1 py
    py=$(find "$root/uv-python" -path '*/bin/python3.11' -type f -print -quit 2>/dev/null || true)
    [[ -n "$py" ]] || py=$(find "$root/uv-python" -path '*/bin/python3.11' -type l -print -quit 2>/dev/null || true)
    [[ -n "$py" && -x "$py" ]] || { echo "candidate has no Python 3.11 interpreter" >&2; return 1; }
    printf '%s\n' "$py"
}

move_contents() {
    local src=$1 dst=$2
    mkdir -p "$dst"
    # Renames within the store: no second full copy and no leftover hidden files.
    python3 - "$src" "$dst" <<'PY'
import os, pathlib, shutil, sys
src, dst = map(pathlib.Path, sys.argv[1:])
for item in src.iterdir():
    target = dst / item.name
    if target.is_dir() and not target.is_symlink(): shutil.rmtree(target)
    elif os.path.lexists(target): target.unlink()
    item.rename(target)
PY
}

runtime_interpreter() {
    local dst=$1 old="${PARSER_LIVE:-/opt/nimoos-parser}/uv-python"
    mkdir -p "$dst/uv-python"
    # Copy the standalone interpreter, never a symlink back into overlay. uv's
    # distribution is relocatable; venvs are created at their final stable path.
    if [[ -d "$old" ]] && find -H "$old" -path '*/bin/python3.11' -print -quit | grep -q .; then
        cp -aL "$old/." "$dst/uv-python/"
    else
        (load_functions
         ensure_uv
         env UV_PYTHON_INSTALL_DIR="$dst/uv-python" "$UV_BIN" python install --no-bin 3.11)
    fi
    python_for_runtime "$dst"
}

validate_component() {
    local component=${PARSER_COMPONENT:?} root=${PARSER_CANDIDATE:?} py
    case "$component" in
        runtime)
            py="$root/venv/bin/python"
            "$py" -I -c 'import sys; assert sys.version_info[:2] == (3,11); import torch, torchvision, torchaudio, docling, rapidocr, onnxruntime, openvino, openvino_genai, llama_cpp, FlagEmbedding, ctranslate2, scenedetect, qdrant_client, fastapi, uvicorn'
            branch=$(bash "$0" profile)
            "$py" -I - "${PARSER_SOURCE:?}/requirements.txt" "$branch" <<'PY'
import importlib.metadata as m, sys
from packaging.requirements import Requirement
# In particular, do not bless an old OpenVINO archive just because it imports.
for line in open(sys.argv[1]):
    line=line.split('#',1)[0].strip()
    if not line: continue
    r=Requirement(line)
    if sys.argv[2]=='amd' and r.name=='onnxruntime-openvino':continue
    if r.marker and not r.marker.evaluate(): continue
    assert m.version(r.name) in r.specifier, f'{r.name} does not satisfy {r.specifier}'
PY
            if [[ "${NIMO_PARSER_IMAGE_RUNTIME:-0}" != 1 ]]; then
                branch=$(bash "$0" profile)
                if [[ "$branch" == amd ]]; then
                    "$py" -I -c 'import onnxruntime, onnxruntime_ep_webgpu, llama_cpp; assert onnxruntime.__version__ == "1.27.0"; assert llama_cpp.llama_supports_gpu_offload()'
                else
                    "$py" -I -c 'import onnxruntime; assert "OpenVINOExecutionProvider" in onnxruntime.get_available_providers()'
                fi
            fi
            ;;
        asr)
            "$root/asr-venv/bin/python" -I -c 'import optimum.intel, transformers, librosa, soundfile, silero_vad'
            ;;
        models)
            [[ -d "$root/models" && -d "$root/hf-cache" && -s "$root/MANIFEST.files.sha256" ]]
            python3 - "$root" "${PARSER_MANIFEST:?}" <<'PY'
import hashlib, json, os, pathlib, re, sys
root=pathlib.Path(sys.argv[1]);spec=json.load(open(sys.argv[2]))['components']['models']
for name in ('VERSION','MANIFEST.txt','manifest.json','MANIFEST.files.sha256'):
    if not (root/name).is_file():raise ValueError('missing model metadata: '+name)
if (root/'VERSION').read_text().strip()!=spec['id']:raise ValueError('model VERSION differs from release manifest')
if json.loads((root/'manifest.json').read_text()).get('bundle')!=spec['id']:raise ValueError('model catalog differs from release manifest')
for name, expected in spec.get('legacy_metadata_sha256',{}).items():
    if pathlib.PurePosixPath(name).name!=name:raise ValueError('invalid model metadata path')
    if hashlib.sha256((root/name).read_bytes()).hexdigest()!=expected:raise ValueError('model metadata checksum mismatch: '+name)
cache=root/'.models-verified'
try:old=json.loads(cache.read_text())
except (OSError,ValueError):old={}
now={}
for line in (root/'MANIFEST.files.sha256').read_text().splitlines():
    match=re.fullmatch(r'([a-f0-9]{64}) [ *](.+)',line)
    if not match:raise ValueError('invalid model checksum entry')
    expected,name=match.groups();rel=pathlib.PurePosixPath(name)
    if rel.is_absolute() or '..' in rel.parts or rel.parts[0] not in ('models','hf-cache'):
        raise ValueError('invalid model checksum path')
    path=root/rel
    if not path.resolve().is_relative_to(root.resolve()):raise ValueError('model link escapes its component')
    st=path.stat();signature=[expected,st.st_size,st.st_mtime_ns,st.st_ctime_ns]
    if old.get(name)!=signature:
        with path.open('rb') as f:actual=hashlib.file_digest(f,'sha256').hexdigest()
        if actual!=expected:raise ValueError('model checksum mismatch: '+name)
    now[name]=signature
if not now:raise ValueError('empty model checksum list')
if now!=old:
    tmp=cache.with_suffix('.tmp')
    with tmp.open('w') as f:
        json.dump(now,f);f.flush();os.fsync(f.fileno())
    os.replace(tmp,cache)
PY
            ;;
        *) echo "unknown Parser component: $component" >&2; return 1 ;;
    esac
}

case "$mode" in
    profile)
        # This is existing backend selection, not dependency removal.
        if [[ "${NIMO_PARSER_IMAGE_RUNTIME:-0}" == 1 ]]; then
            echo image
        else
            source "$helper_dir/parser-gpu-branch.sh"
            detect_parser_gpu_branch
        fi
        ;;
    preflight-host)
        # Host tools are prerequisites, not part of the immutable Python tree.
        export PARSER_CANDIDATE="${PARSER_LIVE:?}"
        load_functions
        check_libreoffice
        check_ffmpeg
        check_qdrant
        ensure_zstd
        mkdir -p "$DATA_DIR" "$LOG_DIR" "$RUN_DIR" "$INSTALL_DIR"
        # FLM must remain a real directory: both existing verifiers reject
        # linked ancestors. Record only this invocation's precise scratch paths.
        python3 - "$TMPDIR/host-flm.json" "$INSTALL_DIR" "$$" <<'PY'
import json, os, pathlib, sys
p, root, pid = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
body={'root':str(root),'stage':str(root/('.flm-staging-'+pid)), 'old':str(root/('.flm-old-'+pid)), 'prior_exists':os.path.lexists(root/'flm')}
tmp=p.with_suffix('.tmp')
with tmp.open('w') as f:
    json.dump(body,f); f.flush(); os.fsync(f.fileno())
os.replace(tmp,p)
fd=os.open(p.parent,os.O_RDONLY|os.O_DIRECTORY); os.fsync(fd); os.close(fd)
PY
        export NIMO_PARSER_TRANSACTIONAL_NPU=1
        ensure_amd_npu_package
        ;;
    cleanup)
        python3 - "$TMPDIR/host-flm.json" "${PARSER_LIVE:?}" "${PARSER_TX_OUTCOME:?}" <<'PY'
import json, os, pathlib, re, shutil, sys
record=pathlib.Path(sys.argv[1]);root=pathlib.Path(sys.argv[2])
if record.exists():
    data=json.loads(record.read_text())
    if data['root']!=str(root): raise ValueError('foreign FLM transaction')
    stage,old=pathlib.Path(data['stage']),pathlib.Path(data['old'])
    for path,prefix in [(stage,'.flm-staging-'),(old,'.flm-old-')]:
        if path.parent!=root or not re.fullmatch(re.escape(prefix)+r'[0-9]+',path.name):raise ValueError('invalid FLM scratch path')
        if path.is_symlink():raise ValueError('linked FLM scratch path')
    live=root/'flm'
    if sys.argv[3]=='rollback':
        if old.exists():
            if live.is_symlink():raise ValueError('linked live FLM')
            if live.exists():shutil.rmtree(live)
            old.rename(live)
        elif not data['prior_exists'] and live.exists():
            if live.is_symlink():raise ValueError('linked live FLM')
            shutil.rmtree(live)
    elif old.exists() and not os.path.lexists(live):
        old.rename(live)
    for path in (stage,old):
        if path.exists():shutil.rmtree(path)
    record.unlink()
PY
        ;;
    prepare)
        root=${PARSER_CANDIDATE:?}
        extracted=${PARSER_EXTRACTED:?}
        case "${PARSER_COMPONENT:?}" in
            runtime)
                # Keep stdout of interpreter provisioning away from its path.
                runtime_interpreter "$root" > "$TMPDIR/interpreter.log"
                py=$(python_for_runtime "$root")
                "$py" -m venv "$root/venv"
                move_contents "$extracted" "$root/venv/lib/python3.11/site-packages"
                cp "${PARSER_SOURCE:?}/requirements.txt" "$root/requirements.txt"
                load_functions
                ensure_openvino_runtime
                if [[ "${NIMO_PARSER_IMAGE_RUNTIME:-0}" == 1 ]]; then
                    # Preserve the existing stock image's complete OV runtime;
                    # this profile is independent of the build host's GPU.
                    ensure_onnxruntime_openvino
                    ensure_openvino_pins
                else
                    reconcile_parser_gpu_runtime
                fi
                validate_component
                ;;
            asr)
                py=$(python_for_runtime "${PARSER_RUNTIME:?}")
                "$py" -m venv "$root/asr-venv"
                move_contents "$extracted" "$root/asr-venv/lib/python3.11/site-packages"
                validate_component
                ;;
            models)
                move_contents "$extracted" "$root"
                validate_component
                python3 - "${PARSER_MANIFEST:?}" "$root/models/.bundle-version" <<'PY'
import json, pathlib, sys
spec=json.load(open(sys.argv[1]))['components']['models']
pathlib.Path(sys.argv[2]).write_text(spec['id']+'\n')
PY
                ;;
        esac
        ;;
    validate) validate_component ;;
    check-release)
        [[ -f "${PARSER_RELEASE:?}/parser/main.py" && -f "$PARSER_RELEASE/requirements.txt" ]]
        if [[ "${NIMO_PARSER_IMAGE_RUNTIME:-0}" == 1 && -d /opt/nimoos-parser/flm ]]; then
            [[ ! -L /opt/nimoos-parser/flm && ! -L /opt/nimoos-parser ]] || { echo "legacy FLM has an untrusted linked root" >&2; exit 1; }
            # Core verifies the original tree, Parser its byte-identical private
            # namespace copy. A real directory preserves both strict verifiers.
            cp -a --reflink=auto /opt/nimoos-parser/flm "$PARSER_RELEASE/flm"
        fi
        "$PARSER_RELEASE/venv/bin/python" -I - "$PARSER_RELEASE" <<'PY'
import pathlib, sys
root=pathlib.Path(sys.argv[1])
# Compile without emitting bytecode or starting worker/model imports.
for p in (root/'parser').rglob('*.py'):
    compile(p.read_bytes(), str(p), 'exec')
PY
        ;;
    service-active)
        rc=0; systemctl is-active --quiet nimoos-parser.service || rc=$?
        case "$rc" in 0) exit 0 ;; 3|4) exit 1 ;; *) exit "$rc" ;; esac
        ;;
    service-stop) systemctl stop nimoos-parser.service ;;
    service-start) systemctl start nimoos-parser.service ;;
    service-health)
        for attempt in $(seq 1 60); do
            if systemctl is-active --quiet nimoos-parser.service && curl -fsS --max-time 2 http://127.0.0.1:8283/v1/parser/stats > "$TMPDIR/health.json"; then
                python3 - "$TMPDIR/health.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1])); assert isinstance(x.get('queue_depth'),dict)
PY
                exit 0
            fi
            sleep 1
        done
        echo 'Parser failed its post-update health check' >&2; exit 1
        ;;
    service-configure)
        load_functions "${PARSER_RELEASE:?}"
        backup="$TMPDIR/service-backup"
        # Backups are complete before anything in /etc or /usr is changed.
        if [[ ! -e "$backup/ready" ]]; then
            mkdir -p "$backup"
            for file in /usr/lib/systemd/system/nimoos-parser.service /etc/nimoos/parser.conf.sample /etc/nimoos/parser.conf /etc/systemd/system/nimoos-parser.service.d/40-component-store.conf /etc/systemd/system/multi-user.target.wants/nimoos-parser.service; do
                name=${file//\//_}
                if [[ -e "$file" || -L "$file" ]]; then cp -a "$file" "$backup/$name"; else touch "$backup/$name.absent"; fi
            done
            touch "$backup/ready"
            sync -f "$backup"
        fi
        mkdir -p /etc/nimoos /etc/systemd/system/nimoos-parser.service.d
        python3 - "${PARSER_STORE:?}" > /etc/systemd/system/nimoos-parser.service.d/40-component-store.conf <<'PY'
import sys
p=sys.argv[1].replace('\\','\\x5c').replace(' ','\\x20').replace('%','%%')
print('[Unit]\nRequiresMountsFor='+p)
PY
        install_conf
        install_unit
        ;;
    service-restore)
        backup="$TMPDIR/service-backup"
        [[ -f "$backup/ready" ]] || exit 0
        for file in /usr/lib/systemd/system/nimoos-parser.service /etc/nimoos/parser.conf.sample /etc/nimoos/parser.conf /etc/systemd/system/nimoos-parser.service.d/40-component-store.conf /etc/systemd/system/multi-user.target.wants/nimoos-parser.service; do
            name=${file//\//_}
            if [[ -f "$backup/$name.absent" ]]; then rm -f "$file"; else rm -f "$file"; cp -a "$backup/$name" "$file"; fi
        done
        systemctl daemon-reload
        ;;
    *) echo "unknown component helper mode: $mode" >&2; exit 2 ;;
esac
