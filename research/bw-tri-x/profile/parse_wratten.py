"""Parse the Repacholi (1992, Usenet) transcription of Kodak publication B-3 Wratten tables, as hosted at
http://www.mat.uc.pt/~rps/photos/{filter-data,other-filters}.html. Run with python -I. '--' = below 0.1 % -> 0."""
import re, sys, os
S=os.path.dirname(os.path.abspath(__file__)); want=['8','11','12','15','21','25','47','58','29']
data={}
for fn in ('other-filters.html','filter-data.html'):
    cur=None
    for line in open(S+'/dl_wratten/'+fn,errors='replace'):
        m=re.match(r'^\s*<LI>\s*<A NAME="(\w+)">',line)
        if m: cur=m.group(1); data.setdefault(cur,{}); continue
        m=re.match(r'^\s{1,6}(\d+[A-Z]*)\s*$',line)
        if m: cur=m.group(1); data.setdefault(cur,{}); continue
        m=re.match(r'^\s*(?:[A-Z]{3})?\s+(\d{3})\s+(--|[\d.]+)\s+(--|[\d.]+)\s*$',line)
        if m and cur: data[cur][int(m.group(1))]=0.0 if m.group(2)=='--' else float(m.group(2))/100
os.makedirs(S+'/csv',exist_ok=True)
print(len(data),'filters parsed:',' '.join(sorted(data)))
for w in want:
    if w not in data or not data[w]: print('MISSING',w); continue
    d=data[w]; ks=sorted(d)
    open(S+'/csv/wratten_%s.csv'%w,'w').write('wavelength_nm,transmittance\n'+''.join('%d,%.4f\n'%(k,d[k]) for k in ks))
    print('W%-3s %d..%d nm n=%d  T(450)=%.3f T(550)=%.3f T(650)=%.3f'%(w,ks[0],ks[-1],len(ks),d.get(450,-1),d.get(550,-1),d.get(650,-1)))
