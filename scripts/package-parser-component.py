#!/usr/bin/env python3
"""Package a complete independently versioned Parser Python component.

No platform dependencies are removed. Emits an archive and a descriptor for
parser/component-manifest.json; publishing a code-only change reuses the same
descriptor. Run against an already validated reference installation.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('kind',choices=['runtime','asr'])
    p.add_argument('version')
    p.add_argument('output',type=Path)
    p.add_argument('--root',type=Path,default=Path('/opt/nimoos-parser'))
    a=p.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]{0,63}',a.version):p.error('invalid independent component version')
    source=a.root/('venv' if a.kind=='runtime' else 'asr-venv')/'lib/python3.11/site-packages'
    if not source.is_dir():p.error('reference site-packages is missing')
    spec=importlib.util.spec_from_file_location('parser_components',Path(__file__).parent/'lib/parser_components.py')
    engine=importlib.util.module_from_spec(spec);spec.loader.exec_module(engine)
    a.output.mkdir(parents=True,exist_ok=True)
    name=f'parser-{a.kind}-{a.version}-cp311-linux-x86_64.tar.zst'
    targets=[a.output/name,a.output/(name+'.sha256'),a.output/(name+'.json')]
    if any(x.exists() for x in targets):p.error('version already exists; never overwrite an artifact')
    fingerprint=engine.legacy_digest([(x.name,x) for x in source.iterdir() if x.name!='__pycache__' and x.suffix!='.pyc'])
    with tempfile.TemporaryDirectory(prefix='.parser-package-',dir=a.output) as work:
        work=Path(work);archive=work/name
        env=os.environ.copy();env['ZSTD_CLEVEL']='3';env['ZSTD_NBTHREADS']='2'
        subprocess.run(['tar','--sort=name','--mtime=@0','--owner=0','--group=0','--numeric-owner','--zstd','-cf',str(archive),'-C',str(source),'.'],env=env,check=True)
        after=engine.legacy_digest([(x.name,x) for x in source.iterdir() if x.name!='__pycache__' and x.suffix!='.pyc'])
        if after!=fingerprint:raise RuntimeError('reference changed during packaging; retry from a stable reference')
        with archive.open('rb') as f:sha=hashlib.file_digest(f,'sha256').hexdigest()
        # Account for allocation and inode overhead; extraction also enforces
        # this bound, and the updater adds its own free-space margin.
        size=engine.tree_size(source)+4096*sum(1 for _ in source.rglob('*'))
        body={'id':a.version,'archive':'parser/'+name,'sha256':sha,'size_bytes':archive.stat().st_size,'unpacked_bytes':size,'content_fingerprint':fingerprint}
        (work/(name+'.sha256')).write_text(f'{sha}  {name}\n')
        (work/(name+'.json')).write_text(json.dumps(body,indent=2)+'\n')
        # Atomic no-clobber names; nothing writes through a previously published
        # inode (the mirrors may hard-link different release aliases).
        made=[]
        try:
            for target in targets:
                os.link(work/target.name,target);made.append(target)
        except BaseException:
            for target in made:target.unlink()
            raise
    print(json.dumps(body,indent=2))

if __name__=='__main__':main()
