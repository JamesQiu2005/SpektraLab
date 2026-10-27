// Synchronous catalogue facts copied from the original Mac data. These are
// caller-side stock rules; no measured material/profile data is rewritten.
import stocks from './stockMetadata.json';
export const isMonochromeStock=(id:string)=>stocks.find(s=>s.id===id)?.monochrome===true;
/** Model/Params.swift ownGrain(of:); the existing slider multiplies this. */
export const ownGrain=(id:string)=>( {kodak_tri_x_400:1.70,ilford_hp5_plus_400:1.49,kodak_tmax_100:.74,fujifilm_neopan_acros_100_ii:.64} as Record<string,number>)[id]??1;
