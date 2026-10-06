import json
o=json.load(open("out_t2_bw.json"))
for k,v in o.items():
    if k.startswith("A_"):
        print(k, " ".join("%s: px %.4f/%.4f rms %.2f/%.2f (selwyn %.2f)"%(c,v[c]["sigma_px"],v[c]["sigma_px_model"],v[c]["rms48"],v[c]["rms48_model"],v[c]["rms48_selwyn"]) for c in "RGB"))
        print("    corr", ["%.4f"%x for x in v["corr_RG_RB_GB"]], "sum3 rms %.2f indep-pred %.2f corr-pred %.2f mean %.4f"%(v["sum3"]["rms48"],v["sum3"]["rms48_pred_independent"],v["sum3"]["rms48_pred_if_correlated"],v["sum3"]["mean"]))
    else:
        for r in v: print(k, {a:(round(b,4) if isinstance(b,float) else b) for a,b in r.items()})
