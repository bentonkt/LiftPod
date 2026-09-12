"""Frozen full-stream held-out A/B/C comparison. Never fits or tunes a model.

Uses saved authorization timestamps (not rep end/weak phase times). Seven legacy
captures lack recorded generic commitments: report A/B, mark C unavailable there.
All rows, including setup/holds, reach inference; review intervals only score it.
"""
import argparse, collections, hashlib, json, subprocess, sys, zipfile
from pathlib import Path
import numpy as np
import joblib
from threadpoolctl import threadpool_limits

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--repository',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--policy-binary',type=Path,required=True)
    args=parser.parse_args()
    sys.path.insert(0,str(args.repository/'training/exercise_classifier'))
    from features import causal_filter,extract
    from train_with_legacy import load_capture
    read=lambda p:json.loads(p.read_text())
    run=args.repository/'data/exercise_classification/training_runs/legacy69_v1'
    manifest=read(run/'dataset_manifest.json')
    specs={s['sourceFile']:s for s in read(args.repository/'data/phase_annotations/manual_phase_labels.json')['captures']}
    models={str(i):joblib.load(run/f'outer_fold_{i}.joblib') for i in [1,2,3]}
    args.output.mkdir(parents=True,exist_ok=False)
    captures=[]; metadata={}
    with zipfile.ZipFile(manifest['archive']) as z:
        bundles={}
        for name in z.namelist():
            if name.endswith('/generic-configuration.json'):
                cfg=json.loads(z.read(name)); bundles[cfg['setID']]=name.rsplit('/',1)[0]+'/'
        for spec in manifest['sets']:
            sid=spec['setID']; person=spec['participantID']; label=spec['exercise']
            commits=[]; resets=[]; has_commits=not sid.startswith('legacy-')
            if has_commits:
                base=bundles[sid]
                samples=[json.loads(line)['sample'] for line in z.read(base+'prepared-motion.jsonl').splitlines()]
                t=np.array([s['sourceTimestamp'] for s in samples]); origin=t[0]
                x=np.array([[s[v][a] for v in ['userAcceleration','rotationRate','gravity'] for a in 'xyz'] for s in samples])
                epochs=np.array([s['epoch'] for s in samples])
                events=json.loads(z.read(base+'summary.json'))['events']
                commits=sorted(e['authorizationTimestamp']-origin for e in events)
                transactions=[json.loads(line) for line in z.read(base+'processor-transactions.jsonl').splitlines()]
                ends=[r['input'].get('timestamp') for r in transactions if r['input']['kind']=='end']
                if ends:
                    keep=t<=ends[0]+1e-8; t=t[keep]; x=x[keep]; epochs=epochs[keep]
                # Initial learning epoch is not a pattern change. Subsequent changes clear evidence.
                prior=0
                for r in transactions:
                    decision=r.get('decision') or {}; pattern=decision.get('pattern') or {}
                    epoch=pattern.get('learningEpoch',prior)
                    if epoch!=prior:
                        resets.append(decision['timestamp']-origin); prior=epoch
                t=t-origin
                cuts=np.r_[0,np.flatnonzero((abs(np.diff(t)-.02)>1e-6)|(np.diff(epochs)!=0))+1,len(t)]
            else:
                t,x,cuts=load_capture(specs[spec['sourceFile']]); t=t-t[0]
            rows=[]
            for epoch,(begin,end) in enumerate(zip(cuts[:-1],cuts[1:])):
                filtered=causal_filter(x[begin:end]); scores={}
                endpoints=list(range(200,end-begin+1,25))
                if endpoints:
                    matrix=np.array([extract(filtered[e-200:e])[0] for e in endpoints])
                    predictions=models[person].predict_proba(matrix)
                    scores={e-1:p.tolist() for e,p in zip(endpoints,predictions)}
                for local,i in enumerate(range(begin,end)):
                    at=float(t[i]); before=float(t[i-1]) if i else -1
                    rows.append(dict(time=at,epoch=epoch,scores=scores.get(local),
                        reset=any(before<r<=at for r in resets),
                        count=int(sum(c<=at+1e-8 for c in commits)) if has_commits else None))
            captures.append(dict(id=sid,rows=rows))
            metadata[sid]=dict(participant=person,exercise=label,cohort=spec['cohort'],
                reviewedIntervals=spec['reviewedIntervals'],thirdCommit=commits[2] if len(commits)>=3 else None,
                cAvailable=has_commits,duration=float(t[-1]),recordingNumber=spec['recordingNumber'])
    inputs=args.output/'inputs.json'; inputs.write_text(json.dumps(captures,allow_nan=False))
    completed=subprocess.run([str(args.policy_binary),str(inputs)],capture_output=True,check=True)
    timelines=json.loads(completed.stdout); (args.output/'timelines.json').write_bytes(completed.stdout)
    results=[]
    for capture in timelines:
        meta=metadata[capture['id']]; intervals=meta['reviewedIntervals']; onset=intervals[0][0]
        for arm in 'abc':
            if arm=='c' and not meta['cAvailable']: continue
            correct=wrong=unknown=unavailable=context_labeled=0.; first=None; firstwrong=None; switches=0; previous=None
            for point,nxt in zip(capture['changes'],capture['changes'][1:]):
                lo,hi=point['time'],nxt['time']; duration=max(0,hi-lo)
                active=sum(max(0,min(hi,b)-max(lo,a)) for a,b in intervals)
                label=point.get(arm)
                if label and previous and label!=previous: switches+=1
                if label: previous=label
                context_labeled+=(duration-active) if label else 0
                if active>0:
                    if label==meta['exercise']:
                        correct+=active
                        if first is None: first=max(lo,onset)-onset
                    elif label:
                        wrong+=active
                        if firstwrong is None: firstwrong=max(lo,onset)-onset
                    elif point['status']=='unavailable': unavailable+=active
                    else: unknown+=active
            results.append(dict(setID=capture['id'],arm=arm,**meta,correctSeconds=correct,wrongSeconds=wrong,
                unknownSeconds=unknown,unavailableSeconds=unavailable,contextLabeledSeconds=context_labeled,
                firstCorrectLatency=first,firstWrongLatency=firstwrong,switches=switches,
                recognized=correct>0 and wrong==0))
    def aggregate(items):
        correct=sum(r['correctSeconds'] for r in items); wrong=sum(r['wrongSeconds'] for r in items)
        latency=[r['firstCorrectLatency'] for r in items if r['firstCorrectLatency'] is not None]
        return dict(sets=len(items),displayPrecision=correct/(correct+wrong) if correct+wrong else None,
            recognizedSetCoverage=sum(r['recognized'] for r in items)/len(items),wrongSeconds=wrong,
            switches=sum(r['switches'] for r in items),unknownSeconds=sum(r['unknownSeconds'] for r in items),
            unavailableSeconds=sum(r['unavailableSeconds'] for r in items),
            medianFirstCorrectLatency=float(np.median(latency)) if latency else None)
    groups={}
    for arm in 'abc':
        groups[f'paired62/arm={arm}']=aggregate([r for r in results if r['arm']==arm and r['cAvailable']])
    for field in ['arm','participant','exercise','cohort']:
        for key in sorted({r[field] for r in results}):
            for arm in 'abc':
                items=[r for r in results if r[field]==key and r['arm']==arm]
                if items: groups[f'{field}={key}/arm={arm}']=aggregate(items)
    report=dict(policy='auto-label-policy-v1',groups=groups,sets=results,
        policySourceSHA256=hashlib.sha256((Path(__file__).resolve().parents[2]/'LiftPod/Workout/ExerciseClassification.swift').read_bytes()).hexdigest(),
        limitations=['Development replay, not independent validation; no threshold tuning.',
        'C uses recorded generic authorization arrival times for 62 ZIP sets. No commitment records exist for seven legacy captures; C is explicitly unavailable, not assigned a guessed count.',
        'Inference latency is zero in this deterministic replay; device scheduling is tested separately.',
        'Non-reviewed context is reported separately, not treated as verified negative truth. No dedicated negative captures or fresh confirmation supplied.'],
        foldHashes={str(i):hashlib.sha256((run/f'outer_fold_{i}.joblib').read_bytes()).hexdigest() for i in [1,2,3]})
    (args.output/'report.json').write_text(json.dumps(report,indent=2,allow_nan=False))
    lines=['# Frozen temporal-policy development replay','',*report['limitations'],'','| Arm | Sets | Display precision | Correct-only set coverage | Wrong-label seconds | Switches |','|---|---:|---:|---:|---:|---:|']
    for arm in 'abc':
        r=groups[f'arm={arm}/arm={arm}']; lines.append(f"| {arm.upper()} | {r['sets']} | {r['displayPrecision']:.1%} | {r['recognizedSetCoverage']:.1%} | {r['wrongSeconds']:.1f} | {r['switches']} |")
    lines+=['','## Matched 62-capture comparison','','| Arm | Display precision | Correct-only set coverage | Wrong-label seconds | Switches |','|---|---:|---:|---:|---:|']
    for arm in 'abc':
        r=groups[f'paired62/arm={arm}']; lines.append(f"| {arm.upper()} | {r['displayPrecision']:.1%} | {r['recognizedSetCoverage']:.1%} | {r['wrongSeconds']:.1f} | {r['switches']} |")
    (args.output/'REPORT.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines))

if __name__=='__main__':
    with threadpool_limits(limits=2): main()
