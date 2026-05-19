#!/usr/bin/env python3
import re,sys,json
text=open(sys.argv[1],encoding='utf-8',errors='ignore').read()
notes=[]
entry='detected_entry'
for k in ['EncDecTest_CCA','EncDecTest_CPA','Recommended Parameter','CCA']:
    if k in text:
        notes.append(k)
if 'EncDecTest_CCA' in text or 'CCA' in text:
    entry='cca_or_kem_like'
elif 'EncDecTest_CPA' in text:
    entry='cpa_or_pke'

def grab(p):
    m=re.search(p,text,re.I)
    return m.group(1) if m else 'NA'
key=grab(r'Keygen\s+Cycles:\s*([0-9]+(?:\.[0-9]+)?)')
enc=grab(r'Enc\s+cycles:\s*([0-9]+(?:\.[0-9]+)?)')
dec=grab(r'Dec\s+cycles:\s*([0-9]+(?:\.[0-9]+)?)')
for n,v in [('keygen',key),('enc',enc),('dec',dec)]:
    if v!='NA':
        try:
            fv=float(v)
            if fv>1e9 and n=='keygen': notes.append('keygen_outlier_check_raw_log')
        except: pass
if key==enc==dec=='NA': notes.append('no cycle output found')
res={'entry':entry,'keygen':key,'enc':enc,'dec':dec,'notes':notes}
print(json.dumps(res))
