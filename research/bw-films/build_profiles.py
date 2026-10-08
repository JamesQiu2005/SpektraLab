"""Build kodak_tmax_100.json, fujifilm_neopan_acros_100_ii.json and ilford_hp5_plus_400.json in ./profiles,
the way bw-tri-x/profile/build_profile.py built Tri-X: one panchromatic emulsion written into three channels.
Run:  PYTHONPATH="$REF/src" "$REF/.venv/bin/python" build_profiles.py
Inputs: csv/ from digitise_tmax.py and digitise_raster.py."""
import os, json, numpy as np, warnings
warnings.filterwarnings('ignore')
from scipy.special import ndtr
from scipy.optimize import least_squares
from spektrafilm.utils.spectral_upsampling import rgb_to_raw_hanatos2025
from spektrafilm.model.illuminants import standard_illuminant
from contrast import metrics
S=os.path.dirname(os.path.abspath(__file__)); WL=np.arange(380,781,5.0); LE=np.linspace(-3,4,256)
def rd(n): return np.genfromtxt(S+'/csv/'+n,delimiter=',',skip_header=1)
def single(x,y):
    o=np.argsort(x,kind='stable'); x,y=x[o],y[o]; k=np.r_[True,np.diff(x)>1e-9]; return x[k],y[k]
def sensitivity(x,y):
    """sheet log S on the 5 nm grid: held below the first sheet point, log-linear tail (slope of the last 15 nm) above the last"""
    x,y=single(x,y); t=x>=x[-1]-15; slope=np.polyfit(x[t],y[t],1)[0]
    w=WL; v=np.interp(w,x,y); v=np.where(w>x[-1],y[-1]+slope*(w-x[-1]),v)
    return v,slope,x[0],x[-1]
def norm_to_midgrey(s_lin):
    s3=np.repeat(s_lin[:,None],3,1); r=rgb_to_raw_hanatos2025(np.full((1,1,3),0.184),s3,'sRGB',False,'D55').ravel()[1]
    return s_lin/r
def curve(le_sheet,d_sheet,dmin,dmax_gross,soft=0.25):
    k=le_sheet>=le_sheet[-1]-0.5; g_end,c_end=np.polyfit(le_sheet[k],d_sheet[k],1); dmax=dmax_gross-dmin
    lin=g_end*LE+c_end; sh=-soft*np.logaddexp(-lin/soft,-dmax/soft)
    blend=np.clip((LE-(le_sheet[-1]-0.3))/0.3,0,1); inner=np.interp(LE,le_sheet,d_sheet,left=d_sheet[0])
    dc=np.maximum(np.where(LE<=le_sheet[-1],(1-blend)*inner+blend*sh,sh),0.0)
    model=lambda p,le:np.stack([p[3+i]*ndtr((le-p[i])/p[6+i]) for i in range(3)],1)
    fit=least_squares(lambda p:model(p,LE).sum(1)-dc,[-0.8,0.6,2.2,0.7,0.9,1.0,0.5,0.6,0.6],bounds=([-3,-3,-3,0,0,0,.15,.15,.15],[5,5,5,4,4,4,2,2,2]))
    p=fit.x; o=np.argsort(p[:3]); p=np.r_[p[:3][o],p[3:6][o],p[6:][o]]
    lay=model(p,LE); err=np.abs(lay.sum(1)-dc).max(); lay=lay*(dc/np.maximum(lay.sum(1),1e-12))[:,None]
    return dc,lay,p,err,g_end
def write(stock,name,source,licence,logs_n,dc,lay,p,dmin,tags):
    prof={"metadata":{"version":"research-2026-10-09","created":"2026-10-09","datasource":source,"tags":tags,
      "copyright":"SpektraLab product data. Not a spektrafilm profile; no array is derived from one.","license":licence+" See engine/resources_product/NOTICE.md."},
     "info":{"stock":stock,"name":name,"type":"negative","support":"film","stage":"filming","use":"still","antihalation":"weak",
             "target_print":"ilford_multigrade_iv_rc","channel_model":"bw","densitometer":"diffuse_visual",
             "log_sensitivity_density_over_min":0.3,"reference_illuminant":"D55","viewing_illuminant":"D50"},
     "data":{"wavelengths":WL.tolist(),"log_sensitivity":np.repeat(logs_n[:,None],3,1).tolist(),
             "channel_density":np.full((81,3),1/3).tolist(),"base_density":np.full(81,dmin).tolist(),
             "midscale_neutral_density":np.full(81,dmin+float(np.interp(0,LE,dc))).tolist(),
             "log_exposure":LE.tolist(),"density_curves":np.repeat(dc[:,None],3,1).tolist(),
             "density_curves_layers":np.repeat(lay[:,:,None],3,2).tolist(),
             "density_curves_model":{"model_type":"cdfs","centers":[p[:3].tolist()]*3,"amplitudes":[p[3:6].tolist()]*3,"sigmas":[p[6:].tolist()]*3}}}
    os.makedirs(S+'/profiles',exist_ok=True); json.dump(prof,open(S+'/profiles/%s.json'%stock,'w'))
    np.savetxt(S+'/csv/profile_curve_%s.csv'%stock,np.c_[LE,dc,dc+dmin],delimiter=',',fmt='%.5f',header='log_exposure_rel_midgrey,D_over_min,D_gross',comments='')
    np.savetxt(S+'/csv/profile_sensitivity_%s.csv'%stock,np.c_[WL,logs_n],delimiter=',',fmt='%.5f',header='wavelength_nm,logS_profile',comments='')
COMMON={"channel_density":"ASSUMED: neutral silver, 1/3 per channel at every wavelength",
        "hanatos2025_adaptation":"omitted on purpose (no fitted window/surface)"}
def tags(sens,curve_,anchor,base,err):
    return {"log_sensitivity":sens,"density_curves":curve_,"log_exposure_anchor":anchor,"base_density":base,**COMMON,
            "density_curves_layers":"ASSUMED: three-CDF fit of the curve (max fit error %.4f D), no sheet data on emulsion sub-layers"%err}
summary=[]
def report(stock,dmin,ci,speed,dD,dc,g_end,err,extra=''):
    summary.append('%s: Dmin %.3f  CI %.3f  own speed %s  dD(1.3 logH) %.3f  D over min at mid-grey %.3f  end slope %.3f  ceiling %.2f net  cdf err %.4f %s'%(stock,dmin,ci,speed,dD,np.interp(0,LE,dc),g_end,dc[-1],err,extra))

# ================================================================== Kodak T-MAX 100 (F-4016)
ISO=100.; MID=np.log10(0.8/ISO)+1.0
r=rd('spectral_tmax_raw_0.3.csv'); logS,slope,w0,w1=sensitivity(r[:,0],r[:,1]); logs_n=np.log10(norm_to_midgrey(10**logS))
a=rd('char_tmax_D76.csv'); a=a[~np.isnan(a).any(1)]; H=a[:,0]; times=np.array([10,7.5,6.]); cis=np.array([metrics(H,a[:,k+1])[1] for k in range(3)])
t56=float(np.interp(0.56,cis[::-1],times[::-1])); print('T-MAX 100 D-76 small tank: CI at 10/7.5/6 min',np.round(cis,3),'-> CI 0.56 at %.2f min'%t56)
lo,hi=(2,1) if t56<=7.5 else (1,0); w=(t56-times[lo])/(times[hi]-times[lo]); D=(1-w)*a[:,lo+1]+w*a[:,hi+1]
dmin,ci,hm,speed,dD=metrics(H,D); DMAXG=3.2
dc,lay,p,err,g_end=curve(H-MID,D-dmin,dmin,DMAXG)
write('kodak_tmax_100','Kodak T-Max 100',"Kodak publication F-4016 (June 2018), vector paths of p8 (spectral sensitivity; D-76 small-tank characteristic curves).",
      "Built from Kodak publication F-4016 (June 2018).",logs_n,dc,lay,p,dmin,
      tags("SHEET %.0f-%.0f nm (the 0.3-above-D-min curve of p8), ASSUMED held below %.0f nm, ASSUMED log-linear tail %.4f dex/nm above %.0f nm; scale MEASURED so grey 0.184 -> raw 1"%(w0,w1,w0,slope,w1),
           "SHEET for log_exposure %.2f..%.2f (D-76 small tank, daylight, %.2f min = CI 0.56, interpolated between the plotted curves); ASSUMED flat toe below, ASSUMED straight line slope %.3f into a ceiling of gross D %.1f above (the highest density the sheet plots)"%(H[0]-MID,H[-1]-MID,t56,g_end,DMAXG),
           "SHEET ISO 100 + LIT: 0 = log10(0.8/100)+1.0 = %.3f log lux-s"%MID,"SHEET level %.3f (base+fog at CI 0.56), ASSUMED spectrally flat"%dmin,err))
report('kodak_tmax_100',dmin,ci,'EI %.0f'%speed,dD,dc,g_end,err,'(t %.2f min)'%t56)

# ================================================================== Fujifilm Neopan 100 Acros II (AF3-0258E)
r=rd('spectral_acros_raw.csv'); E=np.log10(standard_illuminant('BB5400'))
x,y=single(r[:,0],r[:,1]); y=y-np.interp(x,WL,E)                      # a spectrogram is the response to its source: divide the source out
logS,slope,w0,w1=sensitivity(x,y); logs_n=np.log10(norm_to_midgrey(10**logS))
a=rd('char_acros_D76.csv'); a=a[~np.isnan(a).any(1)]; H=a[:,0]; times=np.array([10,7,4.]); cis=np.array([metrics(H,a[:,k+1])[1] for k in range(3)])
T=7.25; w=(T-7)/3; D=(1-w)*a[:,2]+w*a[:,1]                               # the sheet's own D-76 time at 20 C
print('Acros II D-76 small tank: CI at 10/7/4 min',np.round(cis,3),'; CI 0.56 would be %.2f min; taken at the sheet time %.2f min'%(np.interp(0.56,cis[::-1],times[::-1]),T))
dmin,ci,hm,speed,dD=metrics(H,D); DMAXG=3.0
dc,lay,p,err,g_end=curve(H-MID,D-dmin,dmin,DMAXG)
write('fujifilm_neopan_acros_100_ii','Fujifilm Neopan 100 Acros II',"FUJIFILM data sheet AF3-0258E (NEOPAN 100 ACROS II, 135), p3: charts are 300 dpi raster images, traced at 600 dpi (spectrogram to 5400 K daylight; D-76 characteristic curves).",
      "Built from FUJIFILM data sheet AF3-0258E.",logs_n,dc,lay,p,dmin,
      tags("SHEET (raster) %.0f-%.0f nm: the spectrogram to 5400 K daylight with a 5400 K black body divided out (ASSUMED source spectrum); ASSUMED held below %.0f nm, ASSUMED log-linear tail %.4f dex/nm above %.0f nm; scale MEASURED so grey 0.184 -> raw 1"%(w0,w1,w0,slope,w1),
           "SHEET (raster) for log_exposure %.2f..%.2f (D-76 small tank, 20 C, %.2f min: the sheet's own time, interpolated between the 7 and 10 min curves; contrast index %.3f); ASSUMED flat toe below, ASSUMED straight line slope %.3f into a ceiling of gross D %.1f above"%(H[0]-MID,H[-1]-MID,T,ci,g_end,DMAXG),
           "SHEET ISO 100 + LIT: 0 = log10(0.8/100)+1.0 = %.3f log lux-s"%MID,"SHEET (raster) level %.3f (base+fog), ASSUMED spectrally flat"%dmin,err))
report('fujifilm_neopan_acros_100_ii',dmin,ci,'EI %.0f'%speed,dD,dc,g_end,err,'(t %.2f min)'%T)

# ================================================================== Ilford HP5 Plus (Nov 2018)
r=rd('spectral_hp5_raw.csv')
# Read as drawn, in log units, WITHOUT dividing the 2850 K source out: Ilford's own daylight filter factors for
# HP5 Plus (motion picture fact sheet: W8 1.7, W15 2.0, W25 4.0) come out 1.64 / 2.04 / 6.2 this way and
# 2.9 / 4.2 / 16 with the source divided out. A linear reading of the axis gives 1.70 / 2.17 / 6.3.
x,y=single(r[:,0],r[:,1]); k=(x>=380)&(y>0.06); x,y=x[k],y[k]                          # the floor of the plot dropped
logS,slope,w0,w1=sensitivity(x,y); logs_n=np.log10(norm_to_midgrey(10**logS))
a=rd('char_hp5_ILFOTEC_HC.csv'); a=a[~np.isnan(a).any(1)]; R=a[:,0]; D=a[:,1]
dmin,ci,rm,_,dD=metrics(R,D)                                              # rm: the relative log exposure of D = base+fog + 0.1
le=R-rm-1.0                                                               # the sheet's axis is relative: the speed point is put where ISO 400 says it is
DMAXG=3.0; dc,lay,p,err,g_end=curve(le,D-dmin,dmin,DMAXG)
write('ilford_hp5_plus_400','Ilford HP5 Plus 400',"HARMAN technology Ltd, 'HP5 PLUS Technical Information' (Nov 2018), p1 (wedge spectrogram to 2850 K tungsten) and p5 (characteristic curve, ILFOTEC HC 1+31, 6.5 min): raster charts, traced at 600 dpi.",
      "Built from HARMAN technology Ltd's HP5 PLUS technical information (Nov 2018).",logs_n,dc,lay,p,dmin,
      tags("SHEET (raster) %.0f-%.0f nm: the 'wedge spectrogram to tungsten light (2850K)' taken as drawn; ASSUMED its 0-1 'Sensitivity' axis is log units and ASSUMED the source is not to be divided out -- the reading that reproduces Ilford's own daylight filter factors for HP5 Plus (W8 1.7, W15 2.0; W25 comes out 6.2 against 4.0), where dividing a 2850 K black body out gives 2.9 / 4.2 / 16; ASSUMED log-linear tail %.4f dex/nm above %.0f nm; scale MEASURED so grey 0.184 -> raw 1"%(w0,w1,slope,w1),
           "SHEET (raster) for log_exposure %.2f..%.2f (ILFOTEC HC 1+31, 6.5 min, 20 C: the one curve the sheet plots; contrast index %.3f); ASSUMED flat toe below, ASSUMED straight line slope %.3f into a ceiling of gross D %.1f above"%(le[0],le[-1],ci,g_end,DMAXG),
           "ASSUMED: the sheet's exposure axis is relative. 0 = one log unit above the curve's own D = base+fog + 0.1 point, i.e. the film is taken to have exactly its rated speed (ISO 400: log10(0.8/400)+1.0 = %.3f log lux-s)"%(np.log10(0.8/400)+1),
           "SHEET (raster) level %.3f (base+fog), ASSUMED spectrally flat"%dmin,err))
report('ilford_hp5_plus_400',dmin,ci,'(anchored)',dD,dc,g_end,err)
print('\n'.join(summary)); open(S+'/csv/profile_summary.txt','w').write('\n'.join(summary)+'\n')

# ------------------------------------------------------------------ filter factors against each maker's table (daylight / tungsten)
W=S+'/../bw-tri-x/profile/csv/wratten_%s_5nm.csv'; ills=[standard_illuminant('D55'),standard_illuminant('BB3200')]
SHEET={'kodak_tmax_100':{'8':(1.5,1.2),'11':(3,3),'12':(2,1.2),'15':(2,1.5),'25':(8,4),'47':(8,25),'58':(6,6)},           # F-4016 p2
       'fujifilm_neopan_acros_100_ii':{'8':(2,1.5),'21':(4,3),'25':(8,6)},                                              # AF3-0258E section 5
       'ilford_hp5_plus_400':{'8':(1.7,None),'12':(2,None),'15':(2,None),'21':(2.6,None),'25':(4,None)}}                 # HP5 Plus motion picture fact sheet, daylight only
rows=['stock,filter,sheet_daylight,calc_D55,stops_err,sheet_tungsten,calc_BB3200,stops_err']
for st,tab in SHEET.items():
    s_=10**rd('profile_sensitivity_%s.csv'%st)[:,1]
    for n,(sd,stn) in tab.items():
        T=rd('../../bw-tri-x/profile/csv/wratten_%s_5nm.csv'%n)[:,1]; f=[(E*s_).sum()/(E*s_*T).sum() for E in ills]
        rows.append('%s,W%s,%g,%.2f,%+.2f,%s,%.2f,%s'%(st,n,sd,f[0],np.log2(f[0]/sd),stn or '',f[1],'' if stn is None else '%+.2f'%np.log2(f[1]/stn)))
open(S+'/csv/filter_factors.csv','w').write('\n'.join(rows)+'\n'); print('\n'.join(rows))
