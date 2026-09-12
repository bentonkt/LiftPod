"""Compare the native analyzer with the frozen development reference and labels.
Requires the existing phase-research checkout and its verified archive; no labels
or exercise identity enter the native analyzer. Writes only the requested output.
"""
import argparse,json,sys,subprocess,time
from pathlib import Path
import numpy as np
p=argparse.ArgumentParser();p.add_argument('--reference-root',type=Path,required=True);p.add_argument('--executable',required=True);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
sys.path.insert(0,str(args.reference_root/'training/phase_segmentation'))
from corpus import load,read
from experiment_bounded_phases import inputs
from compare_representations import principal,band,evaluate,summarize,rotate
from experiment_smoothing import signals
from experiment_local_cycles import run_variants
from experiment_acceleration_band import phase_segments,annotations
from experiment_physical_boundaries import fixture,metrics
from signal_experiment import boundary_evaluate
import os
os.chdir(args.reference_root)
captures,manifest=load();world,counters,_=inputs(captures,manifest)
labels=read(args.reference_root/'data/exercise_classification/phase_labels_v2/phase_labels.json')['captures']+read(args.reference_root/'data/exercise_classification/corpus_20260912_112521/phase_labels_v1/phase_labels.json')['captures']
labels={c.get('id',c.get('setID')):c['reps'] for c in labels}
import zipfile
orientation={}
with zipfile.ZipFile(manifest['archive']) as archive:
 for name in archive.namelist():
  if not name.endswith('/generic-configuration.json'):continue
  sid=json.loads(archive.read(name))['setID']
  if sid not in world:continue
  base=name.rsplit('/',1)[0]+'/'
  frames=[json.loads(line)['sample'] for line in archive.read(base+'prepared-motion.jsonl').splitlines()]
  g=np.array([[f['gravity'][k] for k in 'xyz'] for f in frames]);q=np.array([[f['attitude'][k] for k in 'wxyz'] for f in frames])
  up=-rotate(g,q)/np.linalg.norm(g,axis=1)[:,None]
  events=json.loads(archive.read(base+'summary.json'))['events']
  orientation[sid]=(up,[f['epoch'] for f in frames],events)
request=[];references=[]
for c in captures:
 sid=c['id'];a=world[sid];t=c['t']
 _,info=principal(band(a));raw=signals(t,a@np.array(info['axis']))['local_drift_6s'];ref=run_variants(t,raw)[0]['local_amplitude_balanced'][0];references.append(ref)
 up,epochs,events=orientation[sid]
 request.append(dict(setID=sid,samples=[dict(time=float(at),epoch=int(e),acceleration=v.tolist(),up=u.tolist()) for at,v,u,e in zip(t,a,up,epochs)],counted=[dict(id=ev['id'],epoch=ev['sourceEpoch'],start=r['start'],end=r['end']) for r,ev in zip(counters[sid],events)]))
synthetics=[]
for stress,kw in [('clean',{}),('noise_bias',dict(noise=.08,bias=.12)),('varying_drift',dict(noise=.08,bias=.12,drift=.004,vary=True))]:
 for up,down,hold in [(.8,.8,0),(.6,2.4,0),(2.4,.6,0),(1,1,.5)]:
  c,a,_,_=fixture(up,down,hold,**kw);synthetics.append((stress,up,down,hold,c))
  request.append(dict(setID='00000000-0000-0000-0000-000000000000',samples=[dict(time=float(t),epoch=0,acceleration=[0,0,float(v)],up=[0,0,1]) for t,v in zip(c['t'],a)],counted=[]))
start=time.monotonic()
completed=subprocess.run([args.executable],input='\n'.join(json.dumps(r) for r in request)+'\n',capture_output=True,text=True,check=True)
results=[json.loads(line) for line in completed.stdout.splitlines()]
assert len(results)==len(request)
rows=[];legs=[];parity=[]
for c,ref,r in zip(captures,references,results):
 cycles=r['reps'];row=evaluate(cycles,labels[c['id']]);row.update(setID=c['id'],person=c['person'],exercise=c['exercise']);rows.append(row)
 phase_cycles=[dict(v,available=v['end']) for v in cycles];legs.append(boundary_evaluate(c,phase_segments(phase_cycles)))
 delta=max([abs(a[k]-b[k]) for a,b in zip(cycles,ref) for k in ('start','reversal','end')],default=0) if len(cycles)==len(ref) else None
 parity.append(dict(setID=c['id'],reference=len(ref),native=len(cycles),maximumBoundaryDifference=delta,passOneSample=delta is not None and delta<=.020001))
analytic=[]
for (stress,up,down,hold,c),r in zip(synthetics,results[len(captures):]):
 analytic.append(dict(stress=stress,up=up,down=down,hold=hold,reps=summarize([evaluate(r['reps'],annotations(c))]),phases=metrics([boundary_evaluate(c,phase_segments([dict(v,available=v['end']) for v in r['reps']]))]),mapped=sum(v['aDirection']!='unknown' for v in r['reps'])))
out=args.output;out.mkdir(parents=True,exist_ok=True)
values=dict(metrics=summarize(rows),phaseMetrics=metrics(legs),parity=parity,perSet=rows,predictions=results[:len(captures)],analytic=analytic,validation=dict(recordings=len(captures),oneSampleParity=sum(v['passOneSample'] for v in parity),nativeElapsedSeconds=time.monotonic()-start,sourceManifest=manifest,limitation='already-viewed weak-label corpus; direction uses recorded gravity and attitude, without physical direction ground truth'))
for name,value in values.items():(out/(name+'.json')).write_text(json.dumps(value,indent=2))
print(json.dumps(dict(metrics=values['metrics'],phaseMetrics=values['phaseMetrics'],oneSampleParity=values['validation']['oneSampleParity'],seconds=values['validation']['nativeElapsedSeconds']),indent=2))
