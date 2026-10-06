"""Build kodak_tri_x_400.json (+ one baked variant per Wratten filter) and the filter-factor table.
Run:  PYTHONPATH="$REF/src" "$REF/.venv/bin/python" build_profile.py
Inputs: csv/ from digitise.py and parse_wratten.py."""
import os, json, numpy as np, warnings
warnings.filterwarnings('ignore')
from scipy.special import ndtr
from scipy.optimize import least_squares
from spektrafilm.utils.spectral_upsampling import rgb_to_raw_hanatos2025
from spektrafilm.model.illuminants import standard_illuminant
from contrast import metrics
S=os.path.dirname(os.path.abspath(__file__)); WL=np.arange(380,781,5.0)
ISO=400.0; T_NORMAL_SRC='csv/curve_metrics.csv'
# ------------------------------------------------------------------ sensitivity
raw=np.genfromtxt(S+'/csv/spectral_raw_solid.csv',delimiter=',',skip_header=1)   # upper curve (physically the D=0.3 one)
x,y=raw[:,0],raw[:,1]; keep=np.r_[True,np.diff(x)>1e-9]; x,y=x[keep],y[keep]
tail=x>=x[-1]-15; slope=np.polyfit(x[tail],y[tail],1)[0]                          # dex/nm over the last 15 nm of the plot
def logS_sheet(w):
    w=np.asarray(w,float); v=np.interp(w,x,y)
    return np.where(w>x[-1],y[-1]+slope*(w-x[-1]),v)                               # ASSUMED: log-linear red tail beyond the plot floor
logS=logS_sheet(WL)
def norm_to_midgrey(s_lin,ill='D55'):
    """scale so an 18.4 % grey through the engine's own upsampler exposes to raw = 1 (the profile convention)"""
    s3=np.repeat(s_lin[:,None],3,1); r=rgb_to_raw_hanatos2025(np.full((1,1,3),0.184),s3,'sRGB',False,ill).ravel()[1]
    return s_lin/r, r
s_lin,_=norm_to_midgrey(10**logS); logS_n=np.log10(s_lin)
# ------------------------------------------------------------------ characteristic curve at CI 0.56
a=np.genfromtxt(S+'/csv/char_400TX_135_D76.csv',delimiter=',',skip_header=1); H=a[:,0]; times=np.array([6,8,10,12.])
cis=[metrics(H,a[:,k+1])[1] for k in range(4)]; t56=float(np.interp(0.56,cis,times))
w=(t56-6)/2; D=(1-w)*a[:,1]+w*a[:,2]                                               # between the 6 and 8 min curves
dmin,ci,hm,speed,dD=metrics(H,D)
LOGH_MID=np.log10(0.8/ISO)+1.0        # ISO 6 speed point for the RATED 400 + 1.0 logH (meter: Hg = 8/S, ISO 2720 K=12.5,q=0.65)
le_sheet=H-LOGH_MID; d_sheet=D-dmin
LE=np.linspace(-3,4,256)
k=le_sheet>=le_sheet[-1]-0.5; g_end,c_end=np.polyfit(le_sheet[k],d_sheet[k],1)     # slope over the last 0.5 logH on the sheet
DMAX_GROSS=3.0; dmax=DMAX_GROSS-dmin; soft=0.25                                    # ASSUMED ceiling (highest D plotted anywhere for 400TX)
def extend(le):
    le=np.asarray(le,float); lin=g_end*le+c_end
    sh=-soft*np.logaddexp(-lin/soft,-dmax/soft)                                    # smooth-min(line, dmax)
    blend=np.clip((le-(le_sheet[-1]-0.3))/0.3,0,1)                                 # hand over inside the last 0.3 logH of sheet data
    inner=np.interp(le,le_sheet,d_sheet,left=d_sheet[0])                           # ASSUMED flat toe left of the sheet
    return np.where(le<=le_sheet[-1],(1-blend)*inner+blend*sh,sh)
dc=np.maximum(extend(LE),0.0)
# three-CDF model, as the colour profiles carry (centers/amplitudes/sigmas), layers = amp*cdf rescaled to sum to the curve
def model(p,le): c,a_,s=p[:3],p[3:6],p[6:]; return np.stack([a_[i]*ndtr((le-c[i])/s[i]) for i in range(3)],1)
fit=least_squares(lambda p:model(p,LE).sum(1)-dc,[-0.8,0.6,2.2,0.7,0.9,1.0,0.5,0.6,0.6],bounds=([-3,-3,-3,0,0,0,.15,.15,.15],[5,5,5,4,4,4,2,2,2]))
p=fit.x; o=np.argsort(p[:3]); p=np.r_[p[:3][o],p[3:6][o],p[6:][o]]
lay=model(p,LE); fit_err=np.abs(lay.sum(1)-dc).max(); lay=lay*(dc/np.maximum(lay.sum(1),1e-12))[:,None]
# ------------------------------------------------------------------ profile
def profile(logs,stock,name,note):
    return {"metadata":{"version":"research-2026-10-06","created":"2026-10-06",
      "datasource":"Kodak publication F-4017 (Feb 2016), vector paths of p7 (spectral sensitivity) and p8 (D-76 characteristic curves, 400TX 135). "
                   "RESEARCH DRAFT, not an upstream spektrafilm profile. "+note,
      "tags":{"log_sensitivity":"SHEET 380-668 nm (upper curve of p7), ASSUMED log-linear tail %.4f dex/nm above 668 nm; scale MEASURED so grey 0.184 -> raw 1"%slope,
              "density_curves":"SHEET for log_exposure %.2f..%.2f (D-76 large tank, %.2f min = CI 0.56, interpolated between the 6 and 8 min curves); ASSUMED flat toe below, ASSUMED straight line slope %.3f into a ceiling of gross D %.1f above"%(le_sheet[0],le_sheet[-1],t56,g_end,DMAX_GROSS),
              "log_exposure_anchor":"SHEET ISO 400 + LIT: 0 = log10(0.8/400)+1.0 = %.3f log lux-s"%LOGH_MID,
              "base_density":"SHEET level %.3f (135 base+fog at CI 0.56), ASSUMED spectrally flat"%dmin,
              "channel_density":"ASSUMED: neutral silver, 1/3 per channel at every wavelength",
              "density_curves_layers":"ASSUMED: three-CDF fit of the curve (max fit error %.4f D), no sheet data on emulsion sub-layers"%fit_err,
              "hanatos2025_adaptation":"omitted on purpose (no fitted window/surface)"}},
     "info":{"stock":stock,"name":name,"type":"negative","support":"film","stage":"filming","use":"still","antihalation":"weak",
             "target_print":"kodak_portra_endura","channel_model":"bw","densitometer":"diffuse_visual",
             "log_sensitivity_density_over_min":0.3,"reference_illuminant":"D55","viewing_illuminant":"D50"},
     "data":{"wavelengths":WL.tolist(),"log_sensitivity":np.repeat(logs[:,None],3,1).tolist(),
             "channel_density":np.full((81,3),1/3).tolist(),"base_density":np.full(81,dmin).tolist(),
             "midscale_neutral_density":np.full(81,dmin+float(np.interp(0,LE,dc))).tolist(),
             "log_exposure":LE.tolist(),"density_curves":np.repeat(dc[:,None],3,1).tolist(),
             "density_curves_layers":np.repeat(lay[:,:,None],3,2).tolist(),
             "density_curves_model":{"model_type":"cdfs","centers":[p[:3].tolist()]*3,"amplitudes":[p[3:6].tolist()]*3,"sigmas":[p[6:].tolist()]*3}}}
os.makedirs(S+'/profiles',exist_ok=True)
json.dump(profile(logS_n,'kodak_tri_x_400','Kodak Tri-X 400',''),open(S+'/kodak_tri_x_400.json','w'))
json.dump(profile(logS_n,'kodak_tri_x_400','Kodak Tri-X 400',''),open(S+'/profiles/kodak_tri_x_400.json','w'))
np.savetxt(S+'/csv/profile_curve.csv',np.c_[LE,LE+LOGH_MID,dc,dc+dmin,(LE>=le_sheet[0])&(LE<=le_sheet[-1])],delimiter=',',fmt='%.5f',header='log_exposure_rel_midgrey,logH_lux_s,D_over_min,D_gross,is_sheet_range',comments='')
np.savetxt(S+'/csv/profile_sensitivity.csv',np.c_[WL,logS,logS_n,WL<=x[-1]],delimiter=',',fmt='%.5f',header='wavelength_nm,logS_sheet_units,logS_profile,is_sheet_range',comments='')
print('curve: t(CI .56)=%.2f min  w8=%.3f  Dmin %.3f  CI %.3f  own speed point logH %.3f (EI %.0f)  dD(1.3)=%.3f'%(t56,w,dmin,ci,hm,speed,dD))
print('anchor logH_mid %.3f ; sheet covers log_exposure %.2f..%.2f ; D_over_min at mid-grey %.3f ; end slope %.3f ; D at le=4: %.3f ; cdf fit err %.4f'%(LOGH_MID,le_sheet[0],le_sheet[-1],np.interp(0,LE,dc),g_end,dc[-1],fit_err))
print('cdfs centers',np.round(p[:3],3),'amps',np.round(p[3:6],3),'sigmas',np.round(p[6:],3))
print('red tail slope %.4f dex/nm from %.1f nm; logS(380)=%.2f, at 780 %.2f'%(slope,x[-1],logS[0],logS[-1]))
# ------------------------------------------------------------------ filter factors
SHEET={'8':(2,1.5),'11':(4,3),'12':(2.5,None),'15':(2.5,1.5),'21':(None,None),'25':(8,5),'47':(6,12),'58':(6,6)}
def T_of(wn,grid):
    d=np.genfromtxt(S+'/csv/wratten_%s.csv'%wn,delimiter=',',skip_header=1)
    lo=max(d[0,1]-(d[1,1]-d[0,1])*(d[0,0]-grid)/10.0,0) if False else None
    t=np.interp(grid,d[:,0],d[:,1])                       # holds T(700) above 700
    below=grid<d[0,0]; t[below]=np.clip(d[0,1]+(d[1,1]-d[0,1])*(grid[below]-d[0,0])/10.0,0,None)   # linear run-out below 400
    return t
ills={'D55':standard_illuminant('D55'),'D65':standard_illuminant('D65'),'T':standard_illuminant('T'),'BB3200':standard_illuminant('BB3200'),'A':standard_illuminant('A')}
Slin=10**logS; rows=['filter,sheet_daylight,calc_D55,calc_D65,sheet_tungsten,calc_BB3200,calc_A,calc_T_engine,stops_err_daylight(D55),stops_err_tungsten(BB3200)']
fac={}
for wn,(sd,st) in SHEET.items():
    T=T_of(wn,WL); f={k:float((E*Slin).sum()/(E*Slin*T).sum()) for k,E in ills.items()}; fac[wn]=f
    e1='' if sd is None else '%+.2f'%np.log2(f['D55']/sd); e2='' if st is None else '%+.2f'%np.log2(f['BB3200']/st)
    rows.append('W%s,%s,%.2f,%.2f,%s,%.2f,%.2f,%.2f,%s,%s'%(wn,sd or '',f['D55'],f['D65'],st or '',f['BB3200'],f['A'],f['T'],e1,e2))
    np.savetxt(S+'/csv/wratten_%s_5nm.csv'%wn,np.c_[WL,T],delimiter=',',fmt='%.4f',header='wavelength_nm,transmittance (10 nm table, linear to 5 nm; held above 700; linear run-out below 400)',comments='')
    # baked variants: (a) metered = renormalised so grey still exposes to 1 (filter factor already given), (b) raw = T only
    sm,_=norm_to_midgrey(10**logS*np.maximum(T,1e-10))
    json.dump(profile(np.log10(sm),'kodak_tri_x_400_w%s'%wn,'Kodak Tri-X 400 + Wratten %s'%wn,'Wratten No. %s baked into log_sensitivity and renormalised to mid-grey (factor given).'%wn),open(S+'/profiles/kodak_tri_x_400_w%s.json'%wn,'w'))
    json.dump(profile(logS_n+np.log10(np.maximum(T,1e-10)),'kodak_tri_x_400_w%sraw'%wn,'Kodak Tri-X 400 + Wratten %s (no factor)'%wn,'Wratten No. %s baked into log_sensitivity, NOT renormalised (exposure not compensated).'%wn),open(S+'/profiles/kodak_tri_x_400_w%sraw.json'%wn,'w'))
open(S+'/csv/filter_factors.csv','w').write('\n'.join(rows)+'\n'); print('\n'.join(rows))
